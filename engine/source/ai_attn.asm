; ai_attn.asm - KV cache and causal attention (docs/INFERENCE.md section 3).
; Loop counters around round_shift64/round_div64 use lp0: those routines clobber cnt0.
;
; KV record per (layer, position), REU_KV_BASE + layer*$10000 + pos*rec:
;   K8[d] V8[d] ke[H] ve[H]          rec = 2d + 2H bytes

lp0 = att_cpk+2

!zone kv_base_set
kv_base_set:                    ; kv_base = REU_KV_BASE + cur_layer * $10000
        lda #0
        sta kv_base
        sta kv_base+1
        lda cur_layer
        clc
        adc #>(REU_KV_BASE >> 8)
        sta kv_base+2
        rts

; ---------------------------------------------------------------- append
!zone kv_append
kv_append:
        lda #7
        sta pk_bits
        lda m_hd
        sta vec_len
        lda #0
        sta att_head
        sta head_lo
.head:
        ; K
        lda #<vec_k
        ldx #>vec_k
        ldy #S128
        jsr set_src
        jsr range_shift
        lda pack_shift
        ldx att_head
        ldy m_d
        jsr .store_exp          ; kv_rec[2d + h] = ke
        lda #0
        jsr .store_vals         ; kv_rec[head_lo + j]
        ; V
        lda #<vec_v
        ldx #>vec_v
        ldy #S128
        jsr set_src
        jsr range_shift
        lda m_d
        clc
        adc m_heads
        tay                     ; kv_rec[2d + H + h] = ve  (offset 2d + H via Y = d + H)
        lda pack_shift
        ldx att_head
        jsr .store_exp
        lda m_d
        jsr .store_vals         ; kv_rec[d + head_lo + j]
        clc
        lda head_lo
        adc m_hd
        sta head_lo
        inc att_head
        lda att_head
        cmp m_heads
        bne .head
        ; stash the record at kv_base + pos * rec
        jsr kv_base_set
        lda ctx_pos
        sta mA
        lda m_kvrec
        sta mB
        lda m_kvrec+1
        sta mB+1
        lda #1
        sta mLenA
        lda #2
        sta mLenB
        jsr umul
        lda mP
        sta reu_adr
        lda mP+1
        sta reu_adr+1
        lda kv_base+2
        sta reu_adr+2
        lda m_kvrec
        sta reu_len
        lda m_kvrec+1
        sta reu_len+1
        lda #<kv_rec
        sta reu_c64
        lda #>kv_rec
        sta reu_c64+1
        jmp reu_stash

; A = exponent, X = head, Y = base offset (d or d+H): kv_rec[d + Y + X] = A
.store_exp:
        sta tmp0
        stx tmp1
        tya
        clc
        adc m_d
        adc tmp1
        tax
        lda tmp0
        sta kv_rec,x
        rts
; A = record offset (0 for K, d for V): kv_rec[A + head_lo + j] = round_shift(src[head_lo + j])
.store_vals:
        sta tmp3
        lda #0
        sta lp0
.v:     lda head_lo
        clc
        adc lp0
        tax
        stx cnt1
        jsr vget
        lda pack_shift
        beq +
        jsr round_shift64
+       lda cnt1
        clc
        adc tmp3
        tax
        lda mA
        sta kv_rec,x
        inc lp0
        lda lp0
        cmp m_hd
        bne .v
        rts

; ---------------------------------------------------------------- attention
!zone attention
attention:
        ; q packed once (whole vector, one shift)
        lda #<vec_q
        ldx #>vec_q
        ldy #S128
        jsr set_src
        ldx m_d
        jsr pack15
        lda pack_shift
        sta att_qs
        ; records per chunk = floor(8192 / rec)
        lda #0
        sta att_per
        lda #<REU_TILE_SIZE
        sta tmp0
        lda #>REU_TILE_SIZE
        sta tmp1
-       sec
        lda tmp0
        sbc m_kvrec
        sta tmp0
        lda tmp1
        sbc m_kvrec+1
        sta tmp1
        bcc +
        inc att_per
        jmp -
+       jsr kv_base_set
        lda #0
        sta att_head
        sta head_lo
.head:
        ; ---------- pass 1: scores into vec_l (S256 planes), V exponents ----------
        lda #<vec_l
        ldx #>vec_l
        ldy #S256
        jsr set_dst
        jsr .chunks_begin
        lda #0
        sta att_t
.p1_chunk:
        jsr .chunk_fetch
        bcc +
        jmp .p1_done
+       lda #<REU_TILE
        sta att_rec
        lda #>REU_TILE
        sta att_rec+1
.p1_rec:
        ; dot = sum_j qp[head_lo + j] * K8[head_lo + j]
        lda att_rec
        sta .k+1
        lda att_rec+1
        sta .k+2
        jsr .dot_k
        ; ke / ve: ptr2 (record, set by .dot_k) += 2d, then index by head
        ldx #2
-       clc
        lda ptr2
        adc m_d
        sta ptr2
        bcc +
        inc ptr2+1
+       dex
        bne -
        ldy att_head
        lda (ptr2),y            ; ke
        sta tmp4
        tya
        clc
        adc m_heads
        tay
        lda (ptr2),y            ; ve
        ldx att_t
        sta att_ve,x
        ; score = round_shift(dot, 16 - qs - ke)
        ldx #3
-       lda acc,x
        sta mA,x
        dex
        bpl -
        lda #0
        ldx acc+3
        bpl +
        lda #$ff
+       sta mA+4
        sta mA+5
        sta mA+6
        sta mA+7
        sec
        lda #16
        sbc att_qs
        sec
        sbc tmp4
        jsr round_shift64
        ldx att_t
        jsr vput
        ; max
        lda att_t
        beq .newmax
        sec                     ; signed compare score - max
        lda mA
        sbc att_max
        lda mA+1
        sbc att_max+1
        lda mA+2
        sbc att_max+2
        lda mA+3
        sbc att_max+3
        bvc +
        eor #$80
+       bmi .nomax
.newmax:
        ldx #3
-       lda mA,x
        sta att_max,x
        dex
        bpl -
.nomax:
        inc att_t
        clc
        lda att_rec
        adc m_kvrec
        sta att_rec
        lda att_rec+1
        adc m_kvrec+1
        sta att_rec+1
        dec att_chunk
        beq +
        jmp .p1_rec
+       jmp .p1_chunk
.p1_done:
        ; ---------- softmax weights f[t] = exp_neg(max - score[t]), F = sum ----------
        lda #<vec_l
        ldx #>vec_l
        ldy #S256
        jsr set_src
        lda #0
        sta att_F
        sta att_F+1
        sta att_F+2
        sta att_F+3
        ldx #0
.w:     stx att_t
        jsr vget
        sec
        lda att_max
        sbc mA
        sta mA
        lda att_max+1
        sbc mA+1
        sta mA+1
        lda att_max+2
        sbc mA+2
        sta mA+2
        lda att_max+3
        sbc mA+3
        sta mA+3
        jsr exp_neg
        ldx att_t
        lda mP
        sta att_f0,x
        clc
        adc att_F
        sta att_F
        lda mP+1
        sta att_f1,x
        adc att_F+1
        sta att_F+1
        lda mP+2
        sta att_f2,x
        adc att_F+2
        sta att_F+2
        lda att_F+3
        adc #0
        sta att_F+3
        inx
        cpx att_t_end
        bne .w
        ; ---------- coefficients c[t] = f[t] << ve[t], packed to 15 bits ----------
        lda #0
        ldx #3
-       sta peak,x              ; peak (4 bytes) + pk_tmp as byte 4
        dex
        bpl -
        lda #0
        sta pk_tmp
        ldx #0
.cpeak: stx att_t
        jsr .coef               ; mA = c[t]
        ; 5-byte compare with peak:peak+3, pk_tmp (byte 4)
        lda mA+4
        cmp pk_tmp
        bcc .cnext
        bne .ctake
        ldx #3
-       lda mA,x
        cmp peak,x
        bcc .cnext
        bne .ctake
        dex
        bpl -
.ctake: ldx #3
-       lda mA,x
        sta peak,x
        dex
        bpl -
        lda mA+4
        sta pk_tmp
.cnext: ldx att_t
        inx
        cpx att_t_end
        bne .cpeak
        ; cs = max(0, bitlen(peak) - 15), +1 if rounding overflows 15 bits
        ldx #3
-       lda peak,x
        sta mA,x
        dex
        bpl -
        lda pk_tmp
        sta mA+4
        lda #0
        sta mA+5
        sta mA+6
        sta mA+7
        jsr bitlen40
        sec
        sbc #15
        bcs +
        lda #0
+       sta att_cs
        beq .cs_ok
        ldx #3
-       lda peak,x
        sta mA,x
        dex
        bpl -
        lda pk_tmp
        sta mA+4
        lda #0
        sta mA+5
        sta mA+6
        sta mA+7
        lda att_cs
        jsr round_shift64
        lda mA+2
        ora mA+3
        ora mA+4
        bne .cs_inc
        lda mA+1
        bpl .cs_ok
.cs_inc:
        inc att_cs
.cs_ok:
        ldx #0
.cpack: stx att_t
        jsr .coef
        lda att_cs
        beq +
        jsr round_shift64
+       ldx att_t
        lda mA
        sta att_c0,x
        lda mA+1
        sta att_c1,x
        inx
        cpx att_t_end
        bne .cpack
        ; ---------- pass 2: acc_j = sum_t cp[t] * V8[t][head_lo + j] (in vec_o planes) ----------
        ldx m_hd
        dex
        lda #0
-       sta vec_o,x
        sta vec_o+VSTRIDE,x
        sta vec_o+2*VSTRIDE,x
        sta vec_o+3*VSTRIDE,x
        dex
        bpl -
        jsr .chunks_begin
        lda #0
        sta att_t
.p2_chunk:
        jsr .chunk_fetch
        bcc +
        jmp .p2_done
+       lda #<REU_TILE
        sta att_rec
        lda #>REU_TILE
        sta att_rec+1
.p2_rec:
        ; V row for this head starts at rec + d + head_lo
        clc
        lda att_rec
        adc m_d
        sta tmp0
        lda att_rec+1
        adc #0
        sta tmp1
        clc
        lda tmp0
        adc head_lo
        sta .v+1
        lda tmp1
        adc #0
        sta .v+2
        ldx att_t
        lda att_c0,x
        sta tmp2                ; cp lo
        lda att_c1,x
        sta tmp3                ; cp hi
        ora tmp2
        bne +
        jmp .p2_next            ; zero coefficient
+       ldx #0
.vj:
.v      ldy $ffff,x             ; SMC: V8 row. Y = signed value
        bne +
        jmp .vnext
+       tya
        sta psgn
        lda absval,y
        jsr mul8_set
        ldy tmp2
        jsr mul8_y
        sta prod+1
        lda m8lo
        sta prod
        ldy tmp3
        jsr mul8_y
        sta prod+2
        clc
        lda m8lo
        adc prod+1
        sta prod+1
        bcc +
        inc prod+2
+       bit psgn
        bmi .vsub
        clc
        lda vec_o,x
        adc prod
        sta vec_o,x
        lda vec_o+VSTRIDE,x
        adc prod+1
        sta vec_o+VSTRIDE,x
        lda vec_o+2*VSTRIDE,x
        adc prod+2
        sta vec_o+2*VSTRIDE,x
        bcc .vnext
        inc vec_o+3*VSTRIDE,x
        jmp .vnext
.vsub:  sec
        lda vec_o,x
        sbc prod
        sta vec_o,x
        lda vec_o+VSTRIDE,x
        sbc prod+1
        sta vec_o+VSTRIDE,x
        lda vec_o+2*VSTRIDE,x
        sbc prod+2
        sta vec_o+2*VSTRIDE,x
        bcs .vnext
        dec vec_o+3*VSTRIDE,x
.vnext: inx
        cpx m_hd
        bne .vj
.p2_next:
        inc att_t
        clc
        lda att_rec
        adc m_kvrec
        sta att_rec
        lda att_rec+1
        adc m_kvrec+1
        sta att_rec+1
        dec att_chunk
        beq +
        jmp .p2_rec
+       jmp .p2_chunk
.p2_done:
        ; ---------- out[head_lo + j] = round_div(acc_j << cs, F) ----------
        lda #<vec_a
        ldx #>vec_a
        ldy #S128
        jsr set_dst
        lda #0
        sta lp0
.out:   ldx lp0
        lda vec_o,x
        sta mA
        lda vec_o+VSTRIDE,x
        sta mA+1
        lda vec_o+2*VSTRIDE,x
        sta mA+2
        lda vec_o+3*VSTRIDE,x
        sta mA+3
        lda #0
        ldx mA+3
        bpl +
        lda #$ff
+       sta mA+4
        sta mA+5
        sta mA+6
        sta mA+7
        lda att_cs
        beq +
        eor #$ff                ; shift left by cs
        clc
        adc #1
        jsr round_shift64
+       ldx #3
-       lda att_F,x
        sta mB,x
        dex
        bpl -
        jsr round_div64
        lda head_lo
        clc
        adc lp0
        tax
        jsr vput
        inc lp0
        lda lp0
        cmp m_hd
        bne .out
        ; next head
        clc
        lda head_lo
        adc m_hd
        sta head_lo
        inc att_head
        lda att_head
        cmp m_heads
        beq +
        jmp .head
+       rts

; ---- helpers ----
.chunks_begin:                  ; positions 0..ctx_pos
        ldx ctx_pos
        inx
        stx kv_left
        stx att_t_end
        lda kv_base
        sta kv_adr
        lda kv_base+1
        sta kv_adr+1
        lda kv_base+2
        sta kv_adr+2
        rts
.chunk_fetch:                   ; carry set when no positions remain
        lda kv_left
        bne +
        sec
        rts
+       cmp att_per
        bcc +
        lda att_per
+       sta att_chunk
        sec
        lda kv_left
        sbc att_chunk
        sta kv_left
        lda att_chunk
        sta mA
        lda m_kvrec
        sta mB
        lda m_kvrec+1
        sta mB+1
        lda #1
        sta mLenA
        lda #2
        sta mLenB
        jsr umul
        lda mP
        sta reu_len
        lda mP+1
        sta reu_len+1
        lda kv_adr
        sta reu_adr
        lda kv_adr+1
        sta reu_adr+1
        lda kv_adr+2
        sta reu_adr+2
        lda #<REU_TILE
        sta reu_c64
        lda #>REU_TILE
        sta reu_c64+1
        jsr reu_fetch           ; advances reu_adr
        lda reu_adr
        sta kv_adr
        lda reu_adr+1
        sta kv_adr+1
        lda reu_adr+2
        sta kv_adr+2
        clc
        rts

.dot_k:                         ; acc = sum over head of qp * K8 (record at .k operand)
        lda .k+1
        sta ptr2
        lda .k+2
        sta ptr2+1
        lda #0
        sta acc
        sta acc+1
        sta acc+2
        sta acc+3
        lda m_hd
        sta cnt0
        ldx head_lo
.dk:
.k      ldy $ffff,x             ; SMC: record base. Y = signed K8
        beq .dnext
        lda pk_lo,x
        ora pk_hi,x
        beq .dnext
        tya
        eor pk_sg,x
        sta psgn
        lda absval,y
        jsr mul8_set
        ldy pk_lo,x
        jsr mul8_y
        sta prod+1
        lda m8lo
        sta prod
        ldy pk_hi,x
        jsr mul8_y
        sta prod+2
        clc
        lda m8lo
        adc prod+1
        sta prod+1
        bcc +
        inc prod+2
+       bit psgn
        bmi .dsub
        clc
        lda acc
        adc prod
        sta acc
        lda acc+1
        adc prod+1
        sta acc+1
        lda acc+2
        adc prod+2
        sta acc+2
        bcc .dnext
        inc acc+3
        jmp .dnext
.dsub:  sec
        lda acc
        sbc prod
        sta acc
        lda acc+1
        sbc prod+1
        sta acc+1
        lda acc+2
        sbc prod+2
        sta acc+2
        bcs .dnext
        dec acc+3
.dnext: inx
        dec cnt0
        bne .dk
        rts

.coef:                          ; X = t -> mA[0..7] = f[t] << ve[t]
        lda att_f0,x
        sta mA
        lda att_f1,x
        sta mA+1
        lda att_f2,x
        sta mA+2
        lda #0
        sta mA+3
        sta mA+4
        sta mA+5
        sta mA+6
        sta mA+7
        lda att_ve,x
        beq +
        eor #$ff
        clc
        adc #1
        jmp round_shift64       ; negative shift = left shift
+       rts

; bit length of mA[0..4] (40-bit unsigned) -> A
!zone bitlen40
bitlen40:
        lda mA+4
        beq +
        ldy #8
-       asl
        bcs .got
        dey
        bne -
.got:   tya
        clc
        adc #32
        rts
+       jmp bitlen32
