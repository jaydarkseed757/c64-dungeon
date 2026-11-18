; ai_model.asm - transformer forward pass (arch 1), bit-exact with
; python/reference_int.py (docs/INFERENCE.md).
;
; Vectors are Q16.16 in four byte planes (memory.inc). A vector is described by
; its base address and a stride code: 0 = 128-byte planes, 1 = 256-byte planes.
;
;   model_reset          ctx_pos = 0
;   model_step           cur_token, want_logits -> updates KV cache, vec_l if logits
;                        carry set + A = AI_ERR_CONTEXT when the context is full

S128 = 0
S256 = 1

; ---------------------------------------------------------------- plane helpers
!zone planes_of
planes_of:                      ; A = base lo, X = base hi, Y = stride code
        sta pl_lo
        stx pl_hi
        ldx #0
.l:     lda pl_lo,x
        cpy #0                  ; (compare before clc: CPY sets carry)
        bne .s256
        clc
        adc #$80
        sta pl_lo+1,x
        lda pl_hi,x
        adc #0
        jmp .st
.s256:  sta pl_lo+1,x
        lda pl_hi,x
        clc
        adc #1
.st:    sta pl_hi+1,x
        inx
        cpx #3
        bne .l
        rts

!macro patch .ins, .n {
        lda pl_lo+.n
        sta .ins+1
        lda pl_hi+.n
        sta .ins+2
}

set_src:                        ; vget reads this vector
        jsr planes_of
        +patch vget_g0, 0
        +patch vget_g1, 1
        +patch vget_g2, 2
        +patch vget_g3, 3
        rts
set_dst:                        ; vput writes this vector
        jsr planes_of
        +patch vput_p0, 0
        +patch vput_p1, 1
        +patch vput_p2, 2
        +patch vput_p3, 3
        rts

!zone vget
vget:                           ; X = index -> mA[0..7] (sign-extended). X kept.
vget_g0 lda $ffff,x
        sta mA
vget_g1 lda $ffff,x
        sta mA+1
vget_g2 lda $ffff,x
        sta mA+2
vget_g3 lda $ffff,x
        sta mA+3
        and #$80
        beq .p
        lda #$ff
.p:     sta mA+4
        sta mA+5
        sta mA+6
        sta mA+7
        rts
vput:                           ; X = index <- mA[0..3]. X kept.
        lda mA
vput_p0 sta $ffff,x
        lda mA+1
vput_p1 sta $ffff,x
        lda mA+2
vput_p2 sta $ffff,x
        lda mA+3
vput_p3 sta $ffff,x
        rts

; mA (8-byte signed) -> magnitude in mA, sign in vel_sign (bit 7)
!zone abs64
abs64:
        lda mA+7
        sta vel_sign
        bpl +
        jsr neg64
+       rts

; bit length of the unsigned 32-bit value in mA[0..3] -> A (0..32)
!zone bitlen32
bitlen32:
        ldx #3
.byte:  lda mA,x
        bne .found
        dex
        bpl .byte
        lda #0
        rts
.found: ldy #8
.bit:   asl
        bcs .got
        dey
        bne .bit
.got:   tya                     ; bits in this byte
        sta tmp0
        txa
        asl
        asl
        asl
        clc
        adc tmp0
        rts

; ---------------------------------------------------------------- tensor geometry
; A = directory slot -> mv_rows, mv_cols (16-bit), tile_adr, tile_step.
!zone geom
geom:
        sta mv_slot
        tax
        lda dir_lo,x
        sta tile_adr
        lda dir_mid,x
        sta tile_adr+1
        lda dir_hi,x
        sta tile_adr+2
        cpx #0
        bne +
        lda m_vocab
        ldy m_d
        jmp .set
+       cpx #1
        bne +
        lda m_ctx
        ldy m_d
        jmp .set
+       txa
        sec
        sbc #8
        and #7                  ; 1..4 wq..wo, 6 w1, 7 w2
        cmp #6
        bne +
        lda m_ff
        ldy m_d
        jmp .set
+       cmp #7
        bne +
        lda m_d
        ldy m_ff
        jmp .set
+       lda m_d
        ldy m_d
.set:   ; A = rows, Y = cols (0 means 256)
        sta mv_rows
        ldx #0
        cmp #0
        bne +
        inx
+       stx mv_rows+1
        sty mv_cols
        ldx #0
        cpy #0
        bne +
        inx
+       stx mv_cols+1
        ; tile_step = tile_rows * (cols + 3)
        clc
        lda mv_cols
        adc #3
        sta mA
        lda mv_cols+1
        adc #0
        sta mA+1
        lda m_tile
        sta mB
        lda #2
        sta mLenA
        lda #1
        sta mLenB
        jsr umul
        lda mP
        sta tile_step
        lda mP+1
        sta tile_step+1
        lda #0
        sta tile_step+2
        rts

; ---------------------------------------------------------------- embedding
; A = slot (0 tok_emb or 1 pos_emb), Y = row. Carry clear: x = row, set: x += row.
!zone emb_row
emb_row:
        php
        sty cnt1
        jsr geom
        lda mv_slot
        bne .rowtile
        jsr emb_fetch_bp        ; tok_emb: bitplane blocks (layout 2)
        jmp .decoded
.rowtile:                       ; pos_emb: row tiles (layout 1)
        ; t = row / tile, i = row % tile
        lda cnt1
        ldx #0
.div:   cmp m_tile
        bcc .divd
        sbc m_tile
        inx
        jmp .div
.divd:  sta att_cpk+1                ; i
        stx att_cpk                ; t
        ; tile start = tile_adr + t * tile_step
.adv:   cpx #0
        beq .start
        clc
        lda tile_adr
        adc tile_step
        sta tile_adr
        lda tile_adr+1
        adc tile_step+1
        sta tile_adr+1
        lda tile_adr+2
        adc #0
        sta tile_adr+2
        dex
        jmp .adv
.start: ; n = rows in this tile = min(tile, rows - t*tile)
        lda m_tile
        sta mA
        lda att_cpk
        sta mB
        lda #1
        sta mLenA
        sta mLenB
        jsr umul                ; t*tile (16-bit)
        sec
        lda mv_rows
        sbc mP
        sta tmp2
        lda mv_rows+1
        sbc mP+1
        bne .full               ; >= 256 left
        lda tmp2
        cmp m_tile
        bcc .short
.full:  lda m_tile
        sta tmp2
.short: ; tmp2 = n. weights at start + i*cols, scale at start + n*cols + 3i
        lda att_cpk+1
        sta mA
        lda mv_cols
        sta mB
        jsr umul                ; i*cols (cols <= 128 here)
        clc
        lda tile_adr
        adc mP
        sta reu_adr
        lda tile_adr+1
        adc mP+1
        sta reu_adr+1
        lda tile_adr+2
        adc #0
        sta reu_adr+2
        lda mv_cols
        sta reu_len
        lda #0
        sta reu_len+1
        lda #<EMB_W
        sta reu_c64
        lda #>EMB_W
        sta reu_c64+1
        jsr reu_fetch           ; clobbers tmp0-att_cpk+1: i is kept in cnt0 below
        lda att_cpk+1
        sta mA
        lda #3
        sta mB
        jsr umul
        lda mP
        sta cnt0                ; 3i
        ; n again (reu_fetch clobbered tmp2): n = min(tile, rows - t*tile)
        lda m_tile
        sta mA
        lda att_cpk
        sta mB
        jsr umul
        sec
        lda mv_rows
        sbc mP
        sta tmp2
        lda mv_rows+1
        sbc mP+1
        bne .full2
        lda tmp2
        cmp m_tile
        bcc .short2
.full2: lda m_tile
        sta tmp2
.short2:
        lda tmp2
        sta mA
        lda mv_cols
        sta mB
        jsr umul                ; n*cols
        clc
        lda mP
        adc cnt0
        sta mP
        lda mP+1
        adc #0
        sta mP+1
        clc
        lda tile_adr
        adc mP
        sta reu_adr
        lda tile_adr+1
        adc mP+1
        sta reu_adr+1
        lda tile_adr+2
        adc #0
        sta reu_adr+2
        lda #3
        sta reu_len
        lda #0
        sta reu_len+1
        lda #<EMB_S
        sta reu_c64
        lda #>EMB_S
        sta reu_c64+1
        jsr reu_fetch
.decoded:
        ; destination vec_x
        lda #<vec_x
        ldx #>vec_x
        ldy #S128
        jsr set_dst
        lda #<vec_x
        ldx #>vec_x
        ldy #S128
        jsr set_src
        ldx #0
.el:    stx cnt1
        lda EMB_W,x
        sta tmp1                ; signed weight
        tay
        lda absval,y
        sta mA
        lda EMB_S
        sta mB
        lda EMB_S+1
        sta mB+1
        lda EMB_S+2
        sta mB+2
        lda #1
        sta mLenA
        lda #3
        sta mLenB
        jsr umul
        ldx #7
-       lda mP,x
        sta mA,x
        dex
        bpl -
        lda tmp1
        bpl +
        jsr neg64
+       lda #8
        jsr round_shift64
        plp                     ; add or store?
        php
        bcc .store
        ; mA += x[i]
        ldx cnt1
        lda mA
        sta mT
        lda mA+1
        sta mT+1
        lda mA+2
        sta mT+2
        lda mA+3
        sta mT+3
        jsr vget
        clc
        lda mA
        adc mT
        sta mA
        lda mA+1
        adc mT+1
        sta mA+1
        lda mA+2
        adc mT+2
        sta mA+2
        lda mA+3
        adc mT+3
        sta mA+3
.store: ldx cnt1
        jsr vput
        inx
        cpx m_d
        bne .el
        plp
        rts

; ---------------------------------------------------------------- RMSNorm
; src set via set_src (length m_d), A = gain slot; result written via set_dst.
!zone rmsnorm
rmsnorm:
        sta mv_slot
        ldx #7
        lda #0
-       sta energy,x
        dex
        bpl -
        ldx #0
.sq:    stx cnt1
        jsr vget
        jsr abs64
        ldx #3
-       lda mA,x
        sta mB,x
        dex
        bpl -
        lda #4
        sta mLenA
        sta mLenB
        jsr umul
        clc
        ldx #0
        ldy #8
-       lda energy,x
        adc mP,x
        sta energy,x
        inx
        dey
        bne -
        ldx cnt1
        inx
        cpx m_d
        bne .sq
        ; ms = round_div(energy, d) + eps
        ldx #7
-       lda energy,x
        sta mA,x
        dex
        bpl -
        lda m_d
        sta mB
        lda #0
        sta mB+1
        sta mB+2
        sta mB+3
        jsr round_div64
        clc
        ldx #0
        ldy #4
-       lda mA,x
        adc m_eps,x
        sta mA,x
        inx
        dey
        bne -
        ldy #4
-       lda mA,x
        adc #0
        sta mA,x
        inx
        dey
        bne -
        ; root = isqrt(ms << 16)
        ldx #5
-       lda mA,x
        sta mA+2,x
        dex
        bpl -
        lda #0
        sta mA
        sta mA+1
        jsr isqrt64
        ldx #3
-       lda mP,x
        sta rms_root,x
        dex
        bpl -
        ; fetch gains (2d bytes) into the window
        ldx mv_slot
        lda dir_lo,x
        sta reu_adr
        lda dir_mid,x
        sta reu_adr+1
        lda dir_hi,x
        sta reu_adr+2
        lda m_d
        asl
        sta reu_len
        lda #0
        rol
        sta reu_len+1
        lda #<REU_TILE
        sta reu_c64
        lda #>REU_TILE
        sta reu_c64+1
        jsr reu_fetch
        ; out_i = round_div((x_i * g_i) << 12, root)
        ldx #0
.el:    stx cnt1
        jsr vget
        jsr abs64
        lda cnt1
        asl
        tay
        lda REU_TILE,y
        sta mB
        lda REU_TILE+1,y
        sta mB+1
        eor vel_sign
        sta tmp4                ; bit 7 = product sign
        lda mB+1
        bpl +
        sec                     ; |g|
        lda #0
        sbc mB
        sta mB
        lda #0
        sbc mB+1
        sta mB+1
+       lda #4
        sta mLenA
        lda #2
        sta mLenB
        jsr umul                ; <= 48 bits
        ; mA = mP << 12  (one byte + 4 bits)
        lda #0
        sta mA
        ldx #0
-       lda mP,x
        sta mA+1,x
        inx
        cpx #7
        bne -
        ldy #4
-       asl mA
        rol mA+1
        rol mA+2
        rol mA+3
        rol mA+4
        rol mA+5
        rol mA+6
        rol mA+7
        dey
        bne -
        lda tmp4
        bpl +
        jsr neg64
+       ldx #3
-       lda rms_root,x
        sta mB,x
        dex
        bpl -
        jsr round_div64
        ldx cnt1
        jsr vput
        inx
        cpx m_d
        bne .el
        rts

; ---------------------------------------------------------------- pack (int16, shared shift)
; Source via set_src, X = length (0 = 256). -> pk_lo/pk_hi/pk_sg, pack_shift.
!zone pack15
pack15:
        stx tmp0
        lda tmp0
        sta vec_len
        lda #15
        sta pk_bits
        lda #0
        sta head_lo
        jsr range_shift
        ldx #0
.el:    stx cnt1
        jsr vget
        lda pack_shift
        beq +
        jsr round_shift64
+       ldx cnt1
        lda mA+7
        and #$80
        sta pk_sg,x
        beq +
        jsr neg64
        ldx cnt1
+       lda mA
        sta pk_lo,x
        lda mA+1
        sta pk_hi,x
        inx
        cpx vec_len
        bne .el
        rts

; shift for elements [head_lo, head_lo + vec_len) of the source (vec_len 0 = 256),
; so magnitudes fit pk_bits bits. -> pack_shift
!zone range_shift
range_shift:
        lda #0
        sta peak
        sta peak+1
        sta peak+2
        sta peak+3
        ldx head_lo
        lda vec_len
        sta cnt0
.l:     stx cnt1
        jsr vget
        jsr abs64
        ; peak = max(peak, |v|)
        lda mA+3
        cmp peak+3
        bcc .next
        bne .take
        lda mA+2
        cmp peak+2
        bcc .next
        bne .take
        lda mA+1
        cmp peak+1
        bcc .next
        bne .take
        lda mA
        cmp peak
        bcc .next
.take:  ldx #3
-       lda mA,x
        sta peak,x
        dex
        bpl -
.next:  ldx cnt1
        inx
        dec cnt0
        bne .l
        ; shift = max(0, bitlen(peak) - bits)
        ldx #3
-       lda peak,x
        sta mA,x
        dex
        bpl -
        jsr bitlen32
        sec
        sbc pk_bits
        bcs +
        lda #0
+       sta pack_shift
        beq .done
        ; if round_shift(peak, shift) > 2^bits - 1: shift += 1
        ldx #3
-       lda peak,x
        sta mA,x
        dex
        bpl -
        lda #0
        sta mA+4
        sta mA+5
        sta mA+6
        sta mA+7
        lda pack_shift
        jsr round_shift64
        ; value >= 2^bits?  (bits is 7 or 15)
        lda pk_bits
        cmp #15
        beq .b15
        lda mA+1
        ora mA+2
        ora mA+3
        bne .inc
        lda mA
        bmi .inc
        rts
.b15:   lda mA+2
        ora mA+3
        bne .inc
        lda mA+1
        bmi .inc
        rts
.inc:   inc pack_shift
.done:  rts

; matrix x vector: ai_matvec.asm (bitplane blocks, format 1.1)

; ---------------------------------------------------------------- vector ops
!zone vec_add_xo
vec_add_xo:                     ; x += o (length d)
        ldx #0
-       clc
        lda vec_x,x
        adc vec_o,x
        sta vec_x,x
        lda vec_x+VSTRIDE,x
        adc vec_o+VSTRIDE,x
        sta vec_x+VSTRIDE,x
        lda vec_x+2*VSTRIDE,x
        adc vec_o+2*VSTRIDE,x
        sta vec_x+2*VSTRIDE,x
        lda vec_x+3*VSTRIDE,x
        adc vec_o+3*VSTRIDE,x
        sta vec_x+3*VSTRIDE,x
        inx
        cpx m_d
        bne -
        rts

!zone relu_h
relu_h:                         ; h = max(0, h) (length d_ff, 0 = 256)
        ldx #0
-       lda vec_h+3*HSTRIDE,x
        bpl +
        lda #0
        sta vec_h,x
        sta vec_h+HSTRIDE,x
        sta vec_h+2*HSTRIDE,x
        sta vec_h+3*HSTRIDE,x
+       inx
        cpx m_ff
        bne -
        rts

!source "engine/source/ai_attn.asm"

; ---------------------------------------------------------------- one token
!zone model_reset
model_reset:
        lda #0
        sta ctx_pos
        rts

!zone model_step
model_step:
        lda ctx_pos
        cmp m_ctx
        bcc +
        lda #AI_ERR_CONTEXT
        sec
        rts
+       ; x = tok_emb[token] + pos_emb[pos]
        lda #0
        ldy cur_token
        clc
        jsr emb_row
        lda #1
        ldy ctx_pos
        sec
        jsr emb_row
        lda #0
        sta cur_layer
.layer:
        ; n = rmsnorm(x, attn_norm)
        jsr .x_to_n_setup
        jsr .slot_base
        jsr rmsnorm             ; A = slot of attn_norm (k = 0)
        ; q, k, v
        jsr .pack_n
        lda #<vec_q
        ldx #>vec_q
        jsr .dst128
        lda #1
        jsr .slot_k
        jsr matvec
        lda #<vec_k
        ldx #>vec_k
        jsr .dst128
        lda #2
        jsr .slot_k
        jsr matvec
        lda #<vec_v
        ldx #>vec_v
        jsr .dst128
        lda #3
        jsr .slot_k
        jsr matvec
        jsr kv_append
        jsr attention           ; -> vec_a
        ; x += Wo a
        lda #<vec_a
        ldx #>vec_a
        ldy #S128
        jsr set_src
        ldx m_d
        jsr pack15
        lda #<vec_o
        ldx #>vec_o
        jsr .dst128
        lda #4
        jsr .slot_k
        jsr matvec
        jsr vec_add_xo
        ; n2 = rmsnorm(x, ffn_norm)
        jsr .x_to_n_setup
        lda #5
        jsr .slot_k
        jsr rmsnorm
        jsr .pack_n
        lda #<vec_h
        ldx #>vec_h
        ldy #S256
        jsr set_dst
        lda #6
        jsr .slot_k
        jsr matvec
        jsr relu_h
        lda #<vec_h
        ldx #>vec_h
        ldy #S256
        jsr set_src
        ldx m_ff
        jsr pack15
        lda #<vec_o
        ldx #>vec_o
        jsr .dst128
        lda #7
        jsr .slot_k
        jsr matvec
        jsr vec_add_xo
        inc cur_layer
        lda cur_layer
        cmp m_layers
        beq +
        jmp .layer
+       inc ctx_pos
        lda want_logits
        beq .done
        ; logits = tok_emb . pack(rmsnorm(x, final))
        jsr .x_to_n_setup
        lda #2
        jsr rmsnorm
        jsr .pack_n
        lda #<vec_l
        ldx #>vec_l
        ldy #S256
        jsr set_dst
        lda #0
        jsr matvec
.done:  lda #AI_OK
        clc
        rts

.x_to_n_setup:
        lda #<vec_x
        ldx #>vec_x
        ldy #S128
        jsr set_src
        lda #<vec_n
        ldx #>vec_n
        ldy #S128
        jmp set_dst
.slot_base:                     ; A = slot of attn_norm for cur_layer
        lda #0
.slot_k:                        ; A = k (0..7) -> A = 8 + layer*8 + k
        sta tmp0
        lda cur_layer
        asl
        asl
        asl
        clc
        adc #8
        adc tmp0
        rts
.pack_n:
        lda #<vec_n
        ldx #>vec_n
        ldy #S128
        jsr set_src
        ldx m_d
        jmp pack15
.dst128:
        ldy #S128
        jmp set_dst
