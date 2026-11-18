; ai_matvec.asm - matrix x vector over bitplane weight blocks (format 1.1, layout 2).
;
; W (rows x cols, int8) is stored in blocks of up to 64 rows x 64 columns. Inside a block,
; for each group of 8 columns and each bit plane b (b = 7 is the sign bit), there is one
; mask byte per row: bit j set = bit b of w[row][8g + j] is set. With SS[m] = the sum of the
; group's inputs selected by mask m (built once per group, 255 additions),
;
;     sum_j w_j p_j = sum_{b<7} 2^b sum_groups SS[mask_b]  -  2^7 sum_groups SS[mask_7]
;
; holds exactly, so the row sum equals the plain int8 x int16 dot product bit for bit and
; the rest (row scale, rounding) is unchanged. Per row and group the kernel does eight
; 24-bit table additions instead of eight multiplications.
;
; Inputs: pk_lo/pk_hi/pk_sg + pack_shift (pack15 of the input), A = directory slot.
; Output via set_dst (rows outputs). Uses the window areas BP_* (memory.inc).
; Accumulator ranges: |SS| <= 8 * 32767; a plane sum over <= 32 groups stays below 2^23.

BP_N = 64

; ---------------------------------------------------------------- generated kernels
; BP_CODE, X = rows (1..64); masks at operand+1/+2 of each plane block (patched per group):
;   8 x { ldy mask-1,x / clc / 3 x (lda acc-1,x / adc ssK,y / sta acc-1,x) }
;   dex / beq + / jmp BP_CODE / + rts
; BP_ZERO: lda #0 / ldx #64 / 24 x sta acc-1,x / dex / bne / rts
!zone bp_gen
bp_gen:
        lda #<(BP_ACC - 1)
        sta ptr2
        lda #>(BP_ACC - 1)
        sta ptr2+1
        ldy #0
        lda #8
        sta cnt0
.plane: lda #$bc                ; ldy abs,x
        jsr .put
        lda #0
        jsr .put
        jsr .put
        lda #$18                ; clc
        jsr .put
        ldx #0
.k:     lda #$bd                ; lda abs,x
        jsr .put
        jsr .putacc
        lda #$79                ; adc abs,y
        jsr .put
        lda #0
        jsr .put
        lda .sspage,x
        jsr .put
        lda #$9d                ; sta abs,x
        jsr .put
        jsr .putacc
        jsr .nextacc
        inx
        cpx #3
        bne .k
        dec cnt0
        bne .plane
        ldx #0
-       lda .tail,x
        jsr .put
        inx
        cpx #7
        bne -
        ; clearing kernel
        lda #<(BP_ACC - 1)
        sta ptr2
        lda #>(BP_ACC - 1)
        sta ptr2+1
        ldx #3
-       lda .zhead,x
        sta BP_ZERO,x
        dex
        bpl -
        ldy #4
        lda #24
        sta cnt0
-       lda #$9d
        sta BP_ZERO,y
        lda ptr2
        sta BP_ZERO+1,y
        lda ptr2+1
        sta BP_ZERO+2,y
        iny
        iny
        iny
        jsr .nextacc
        dec cnt0
        bne -
        ldx #0
-       lda .ztail,x
        sta BP_ZERO,y
        iny
        inx
        cpx #4
        bne -
        rts
.put:   sta BP_CODE,y
        iny
        rts
.putacc:
        lda ptr2
        jsr .put
        lda ptr2+1
        jmp .put
.nextacc:
        clc
        lda ptr2
        adc #64
        sta ptr2
        bcc +
        inc ptr2+1
+       rts
.sspage: !byte >BP_SS0, >BP_SS1, >BP_SS2
.tail:  !byte $ca, $f0, $03, $4c, <BP_CODE, >BP_CODE, $60
.zhead: !byte $a9, $00, $a2, BP_N
.ztail: !byte $ca, $d0, $b5, $60  ; dex / bne (back 75 bytes to the first sta) / rts

; ---------------------------------------------------------------- matvec
!zone matvec
matvec:
        jsr geom
        jsr bp_gen
        lda #0
        sta bp_r0
        lda mv_rows
        sta mv_left
        lda mv_rows+1
        sta mv_left+1
.rblock:
        lda mv_left+1
        bne .n64
        lda mv_left
        cmp #BP_N
        bcc .nset
.n64:   lda #BP_N
.nset:  sta bp_n
        jsr BP_ZERO
        lda #0
        sta bp_c0
        lda mv_cols
        sta bp_cleft
        lda mv_cols+1
        sta bp_cleft+1
.cblock:
        lda bp_cleft+1
        bne .k64
        lda bp_cleft
        cmp #BP_N
        bcc .kset
.k64:   lda #BP_N
.kset:  sta bp_k
        ; masks of this block: n * k bytes
        lda bp_n
        sta mA
        lda bp_k
        sta mB
        lda #1
        sta mLenA
        sta mLenB
        jsr umul
        lda mP
        sta bp_len
        lda mP+1
        sta bp_len+1
        lda #<BP_TILE
        ldx #>BP_TILE
        jsr bp_fetch
        lda #<(BP_TILE - 1)
        sta bp_mptr
        lda #>(BP_TILE - 1)
        sta bp_mptr+1
        lda bp_c0
        sta bp_col
.grp:   jsr bp_group
        clc
        lda bp_col
        adc #8
        sta bp_col
        sec
        sbc bp_c0
        cmp bp_k
        bne .grp
        lda bp_col
        sta bp_c0
        sec
        lda bp_cleft
        sbc bp_k
        sta bp_cleft
        lda bp_cleft+1
        sbc #0
        sta bp_cleft+1
        ora bp_cleft
        bne .cblock
        ; row scales: n * 3 bytes
        lda bp_n
        asl
        clc
        adc bp_n
        sta bp_len
        lda #0
        adc #0
        sta bp_len+1
        lda #<BP_SCALE
        ldx #>BP_SCALE
        jsr bp_fetch
        lda #<BP_SCALE
        sta bp_sptr
        lda #>BP_SCALE
        sta bp_sptr+1
        lda #0
        sta bp_i
.fin:   ldx bp_i
        jsr bp_row_sum
        jsr bp_finish
        clc
        lda bp_sptr
        adc #3
        sta bp_sptr
        bcc +
        inc bp_sptr+1
+       inc bp_i
        lda bp_i
        cmp bp_n
        bne .fin
        ; next row block
        clc
        lda bp_r0
        adc bp_n
        sta bp_r0
        sec
        lda mv_left
        sbc bp_n
        sta mv_left
        lda mv_left+1
        sbc #0
        sta mv_left+1
        ora mv_left
        beq +
        jmp .rblock
+       rts

; DMA bp_len bytes from REU tile_adr to A/X (lo/hi); tile_adr += bp_len.
bp_fetch:
        sta reu_c64
        stx reu_c64+1
        lda tile_adr
        sta reu_adr
        lda tile_adr+1
        sta reu_adr+1
        lda tile_adr+2
        sta reu_adr+2
        lda bp_len
        sta reu_len
        lda bp_len+1
        sta reu_len+1
        jsr reu_fetch
        clc
        lda tile_adr
        adc bp_len
        sta tile_adr
        lda tile_adr+1
        adc bp_len+1
        sta tile_adr+1
        lda tile_adr+2
        adc #0
        sta tile_adr+2
        rts

; ---------------------------------------------------------------- one group of 8 columns
!zone bp_group
bp_group:
        ldx bp_col
        ldy #0
        sty bp_nz
.v:     lda pk_lo,x
        sta BP_V0,y
        lda pk_hi,x
        sta BP_V1,y
        ora pk_lo,x
        ora bp_nz
        sta bp_nz
        lda #0
        sta BP_V2,y
        lda pk_sg,x
        bpl +
        sec                     ; negate (0 stays 0)
        lda #0
        sbc BP_V0,y
        sta BP_V0,y
        lda #0
        sbc BP_V1,y
        sta BP_V1,y
        lda #0
        sbc #0
        sta BP_V2,y
+       inx
        iny
        cpy #8
        bne .v
        lda bp_nz
        bne .build
        ; all eight inputs are zero: nothing to add, skip the eight mask arrays
        ldx #8
-       clc
        lda bp_mptr
        adc bp_n
        sta bp_mptr
        bcc +
        inc bp_mptr+1
+       dex
        bne -
        rts
.build: ; SS[0] = 0; SS[m] = SS[m - 2^k] + v_k for 2^k <= m < 2^(k+1)
        lda #0
        sta BP_SS0
        sta BP_SS1
        sta BP_SS2
        ldy #0
.bk:    lda BP_V0,y
        sta .i0+1
        lda BP_V1,y
        sta .i1+1
        lda BP_V2,y
        sta .i2+1
        lda bit_tab,y
        tax                     ; m starts at 2^k
        asl
        sta .end+1              ; 2^(k+1) (0 for k = 7: wraps)
        txa
        eor #$ff
        clc
        adc #1
        sta .s0+1               ; source = SS - 2^k
        sta .s1+1
        sta .s2+1
.l:     clc
.s0     lda BP_SS0 - 256,x
.i0     adc #0
        sta BP_SS0,x
.s1     lda BP_SS1 - 256,x
.i1     adc #0
        sta BP_SS1,x
.s2     lda BP_SS2 - 256,x
.i2     adc #0
        sta BP_SS2,x
        inx
.end    cpx #0
        bne .l
        iny
        cpy #8
        bne .bk
        ; point the eight plane blocks of the kernel at this group's mask arrays
        ldx #0
.mb:    lda bp_mptr
        sta BP_CODE+1,x
        lda bp_mptr+1
        sta BP_CODE+2,x
        clc
        lda bp_mptr
        adc bp_n
        sta bp_mptr
        bcc +
        inc bp_mptr+1
+       txa
        clc
        adc #31
        tax
        cpx #8 * 31
        bne .mb
        ldx bp_n
        jmp BP_CODE

; ---------------------------------------------------------------- combine planes
; X = row -> acc = sum_{b<7} 2^b A_b - 2^7 A_7 (signed 32-bit), Horner in zero page.
!zone bp_row_sum
bp_row_sum:
        lda BP_ACC + (7 * 3 + 2) * 64,x
        asl
        lda #0
        adc #$ff
        eor #$ff                ; sign extension of A_7
        sta acc+3
        sec
        lda #0
        sbc BP_ACC + (7 * 3 + 0) * 64,x
        sta acc
        lda #0
        sbc BP_ACC + (7 * 3 + 1) * 64,x
        sta acc+1
        lda #0
        sbc BP_ACC + (7 * 3 + 2) * 64,x
        sta acc+2
        lda #0
        sbc acc+3
        sta acc+3
!for i, 0, 6 {
        asl acc
        rol acc+1
        rol acc+2
        rol acc+3
        lda BP_ACC + ((6 - i) * 3 + 2) * 64,x
        asl
        lda #0
        adc #$ff
        eor #$ff
        tay
        clc
        lda acc
        adc BP_ACC + ((6 - i) * 3 + 0) * 64,x
        sta acc
        lda acc+1
        adc BP_ACC + ((6 - i) * 3 + 1) * 64,x
        sta acc+1
        lda acc+2
        adc BP_ACC + ((6 - i) * 3 + 2) * 64,x
        sta acc+2
        tya
        adc acc+3
        sta acc+3
}
        rts

; ---------------------------------------------------------------- finish one row
; acc (signed 32-bit row sum) -> round_shift(acc * scale, 24 - pack_shift) -> vput row r0+i.
; Rounding is symmetric (ties away from zero), so it is done on |acc| * scale and the sign
; is applied afterwards, exactly as python/fixedpoint.round_shift. Shift 24 - pack_shift is
; 8..24 (pack_shift <= 16 for Q16.16 inputs).
!zone bp_finish
bp_finish:
        lda acc+3
        sta vel_sign
        bpl .pos
        sec
        lda #0
        sbc acc
        sta mA
        lda #0
        sbc acc+1
        sta mA+1
        lda #0
        sbc acc+2
        sta mA+2
        lda #0
        sbc acc+3
        sta mA+3
        jmp .mag
.pos:   lda acc
        sta mA
        lda acc+1
        sta mA+1
        lda acc+2
        sta mA+2
        lda acc+3
        sta mA+3
.mag:   lda bp_sptr
        sta ptr0
        lda bp_sptr+1
        sta ptr0+1
        ldy #0
        lda (ptr0),y
        sta mB
        iny
        lda (ptr0),y
        sta mB+1
        iny
        lda (ptr0),y
        sta mB+2
        jsr mul32x24            ; mP[0..7] = |acc| * scale
        sec
        lda #24
        sbc pack_shift
        sta mI                  ; sh
        beq .noround
        ; + 2^(sh-1)
        tax
        dex
        txa
        and #7
        tay
        lda bit_tab,y
        sta mJ
        txa
        lsr
        lsr
        lsr
        tay
        clc
        lda mP,y
        adc mJ
        sta mP,y
        bcc .noround
-       iny
        lda mP,y
        adc #0
        sta mP,y
        bcs -
.noround:
        ; >> sh: whole bytes, then bits, on a 40-bit window
        lda mI
        lsr
        lsr
        lsr
        tay
        ldx #0
-       lda mP,y
        sta mA,x
        iny
        inx
        cpx #5
        bne -
        lda mI
        and #7
        tax
        beq .sign
-       lsr mA+4
        ror mA+3
        ror mA+2
        ror mA+1
        ror mA
        dex
        bne -
.sign:  lda vel_sign
        bpl +
        sec
        lda #0
        sbc mA
        sta mA
        lda #0
        sbc mA+1
        sta mA+1
        lda #0
        sbc mA+2
        sta mA+2
        lda #0
        sbc mA+3
        sta mA+3
+       clc
        lda bp_r0
        adc bp_i
        tax
        jmp vput

; mA[0..3] x mB[0..2] (unsigned) -> mP[0..7], with quarter-square 8x8 products:
; a*b = sq1[b+a] - sq2[255-b+a] (tables built by math_init). The table pointers are set
; once per call from the three scale bytes; the four bytes of A index them.
!zone mul32x24
mul32x24:
        lda mB
        sta .l0+1
        sta .h0+1
        eor #$ff
        sta .m0+1
        sta .n0+1
        lda mB+1
        sta .l1+1
        sta .h1+1
        eor #$ff
        sta .m1+1
        sta .n1+1
        lda mB+2
        sta .l2+1
        sta .h2+1
        eor #$ff
        sta .m2+1
        sta .n2+1
        lda #0
        ldx #7
-       sta mP,x
        dex
        bpl -
        ldx #0
.a:     ldy mA,x                ; q = mA[x] * (b2:b1:b0), 32-bit in mT
        sec
.l0     lda sq1lo,y
.m0     sbc sq2lo,y
        sta mT
.h0     lda sq1hi,y
.n0     sbc sq2hi,y
        sta mT+1
        sec
.l1     lda sq1lo,y
.m1     sbc sq2lo,y
        sta m8lo
.h1     lda sq1hi,y
.n1     sbc sq2hi,y
        sta mT+2
        clc
        lda mT+1
        adc m8lo
        sta mT+1
        bcc +
        inc mT+2
+       sec
.l2     lda sq1lo,y
.m2     sbc sq2lo,y
        sta m8lo
.h2     lda sq1hi,y
.n2     sbc sq2hi,y
        sta mT+3
        clc
        lda mT+2
        adc m8lo
        sta mT+2
        bcc +
        inc mT+3
+       clc                     ; mP[x..] += q
        lda mP,x
        adc mT
        sta mP,x
        lda mP+1,x
        adc mT+1
        sta mP+1,x
        lda mP+2,x
        adc mT+2
        sta mP+2,x
        lda mP+3,x
        adc mT+3
        sta mP+3,x
        bcc +
        lda mP+4,x
        adc #0
        sta mP+4,x
        bcc +
        lda mP+5,x
        adc #0
        sta mP+5,x
        bcc +
        inc mP+6,x
+       inx
        cpx #4
        bne .a
        rts

; ---------------------------------------------------------------- embedding row (layout 2)
; tile_adr = tensor start (geom), mv_rows/mv_cols set, cnt1 = row (cols <= 128).
; -> EMB_W[0..cols-1] (signed weights), EMB_S (3-byte row scale).
!zone emb_fetch_bp
emb_fetch_bp:
        ; skip whole 64-row blocks: each is 64 * (cols + 3) bytes
        clc
        lda mv_cols
        adc #3
        sta bp_len
        lda #0
        sta bp_len+1
        ldx #6
-       asl bp_len
        rol bp_len+1
        dex
        bne -
        lda cnt1
        and #$c0
        sta bp_r0               ; first row of the block
        lsr
        lsr
        lsr
        lsr
        lsr
        lsr
        tax
        beq .blk
-       clc
        lda tile_adr
        adc bp_len
        sta tile_adr
        lda tile_adr+1
        adc bp_len+1
        sta tile_adr+1
        lda tile_adr+2
        adc #0
        sta tile_adr+2
        dex
        bne -
.blk:   ; n = min(64, rows - r0)
        sec
        lda mv_rows
        sbc bp_r0
        tax
        lda mv_rows+1
        sbc #0
        bne .n64
        cpx #BP_N
        bcc .nset
.n64:   ldx #BP_N
.nset:  stx bp_n
        lda cnt1
        and #$3f
        sta bp_i
        ldx #0
        txa
-       sta EMB_W,x
        inx
        cpx mv_cols
        bne -
        lda #0
        sta bp_c0
        lda mv_cols
        sta bp_cleft
.cblock:
        lda bp_cleft
        cmp #BP_N
        bcc +
        lda #BP_N
+       sta bp_k
        lda bp_n
        sta mA
        lda bp_k
        sta mB
        lda #1
        sta mLenA
        sta mLenB
        jsr umul
        lda mP
        sta bp_len
        lda mP+1
        sta bp_len+1
        lda #<BP_TILE
        ldx #>BP_TILE
        jsr bp_fetch
        clc
        lda #<BP_TILE
        adc bp_i
        sta ptr0
        lda #>BP_TILE
        adc #0
        sta ptr0+1
        lda bp_c0
        sta bp_col
.grp:   lda #0
        sta cnt0                ; plane b
.pl:    ldy #0
        lda (ptr0),y
        sta tmp0                ; mask
        ldy cnt0
        lda bit_tab,y
        sta tmp1
        ldx bp_col
        ldy #8
.bit:   lsr tmp0
        bcc +
        lda EMB_W,x
        ora tmp1
        sta EMB_W,x
+       inx
        dey
        bne .bit
        clc
        lda ptr0
        adc bp_n
        sta ptr0
        bcc +
        inc ptr0+1
+       inc cnt0
        lda cnt0
        cmp #8
        bne .pl
        clc
        lda bp_col
        adc #8
        sta bp_col
        sec
        sbc bp_c0
        cmp bp_k
        bne .grp
        lda bp_col
        sta bp_c0
        sec
        lda bp_cleft
        sbc bp_k
        sta bp_cleft
        beq +
        jmp .cblock
+       ; row scale at tile_adr + 3i
        lda bp_i
        asl
        clc
        adc bp_i
        clc
        adc tile_adr
        sta tile_adr
        lda tile_adr+1
        adc #0
        sta tile_adr+1
        lda tile_adr+2
        adc #0
        sta tile_adr+2
        lda #3
        sta bp_len
        lda #0
        sta bp_len+1
        lda #<EMB_S
        ldx #>EMB_S
        jmp bp_fetch
