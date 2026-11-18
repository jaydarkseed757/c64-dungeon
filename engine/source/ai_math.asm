; ai_math.asm - integer arithmetic for the DM64 engine.
;
; Rounding rules follow docs/INFERENCE.md: round_div and round_shift round to
; nearest with ties away from zero. All multi-byte values are little-endian.
;
; Routines (inputs/outputs in zero page, see memory.inc):
;   math_init        build quarter-square and |x| tables (needs $01 = $36)
;   mul8_set         A = multiplicand a           (patches mul8_y)
;   mul8_y           Y = b  ->  A:m8lo = a*b      (X preserved)
;   umul             mA[mLenA] * mB[mLenB] -> mP[8] (unsigned)
;   udiv64           mA[8] / mB[4] -> mA[8] quotient, mR remainder (unsigned)
;   round_div64      signed mA[8] / positive mB[4], rounded -> mA[8]
;   round_shift64    signed mA[8], A = signed shift s  -> mA[8]
;   neg64            mA[8] = -mA[8]
;   isqrt64          mA[8] -> mP[4] = floor(sqrt)
;   exp_neg          mA[4] = delta (Q16.16, >= 0) -> mP[3] = exp(-delta) Q0.24

!zone math_init
math_init:
        ; sq1[i] = floor(i*i/4) for i = 0..511, using s = i*i built incrementally
        lda #0
        sta mT
        sta mT+1
        sta mT+2                ; s = 0
        sta ptr0                ; i lo
        sta ptr0+1              ; i hi
.sq_loop:
        ; store s >> 2 (fits 16 bits for i <= 511)
        lda mT+2
        sta tmp2
        lda mT+1
        sta tmp1
        lda mT
        lsr tmp2
        ror tmp1
        ror
        lsr tmp2
        ror tmp1
        ror
        ldx ptr0
        ldy ptr0+1
        bne .hi_half
        sta sq1lo,x
        lda tmp1
        sta sq1hi,x
        jmp .next
.hi_half:
        sta sq1lo+$100,x
        lda tmp1
        sta sq1hi+$100,x
.next:
        ; s += 2*i + 1
        lda ptr0
        asl
        sta tmp3
        lda ptr0+1
        rol
        sta tmp4                ; 2*i (fits 16 bits)
        sec                     ; +1
        lda mT
        adc tmp3
        sta mT
        lda mT+1
        adc tmp4
        sta mT+1
        lda mT+2
        adc #0
        sta mT+2
        inc ptr0
        bne .sq_loop
        inc ptr0+1
        lda ptr0+1
        cmp #2
        bne .sq_loop

        ; sq2[i] = sq1[|i-255|] for i = 0..511
        ldx #0
.sq2_lo:                        ; i = 0..255 -> k = 255-i (0..255)
        txa
        eor #$ff
        tay
        lda sq1lo,y
        sta sq2lo,x
        lda sq1hi,y
        sta sq2hi,x
        inx
        bne .sq2_lo
.sq2_hi:                        ; i = 256..511 -> k = i-255 = x+1 (1..256)
        txa
        clc
        adc #1
        tay
        bcs .k256
        lda sq1lo,y
        sta sq2lo+$100,x
        lda sq1hi,y
        sta sq2hi+$100,x
        jmp .k_next
.k256:
        lda sq1lo+$100          ; k = 256
        sta sq2lo+$100,x
        lda sq1hi+$100
        sta sq2hi+$100,x
.k_next:
        inx
        bne .sq2_hi

        ; absval[b] = |signed b| (absval[$80] = $80)
        ldx #0
.abs_loop:
        txa
        bpl .abs_pos
        eor #$ff
        clc
        adc #1
.abs_pos:
        sta absval,x
        inx
        bne .abs_loop
        rts

; ---------------------------------------------------------------- 8x8 multiply
!zone mul8
mul8_set:                       ; A = a (unsigned)
        sta .s1+1
        sta .s3+1
        eor #$ff
        sta .s2+1
        sta .s4+1
        rts
mul8_y:                         ; Y = b. Returns A = hi, m8lo = lo. X preserved.
        sec
.s1     lda sq1lo,y             ; SMC: low byte = a
.s2     sbc sq2lo,y             ; SMC: low byte = 255 - a
        sta m8lo
.s3     lda sq1hi,y
.s4     sbc sq2hi,y
        rts

; ---------------------------------------------------------------- multi-byte multiply
; mP[0..7] = mA[0..mLenA-1] * mB[0..mLenB-1], unsigned. mLenA + mLenB <= 8.
!zone umul
umul:
        lda #0
        ldx #7
.clr:   sta mP,x
        dex
        bpl .clr
        lda #0
        sta mI
.row:
        ldx mI
        lda mA,x
        beq .row_next
        sta .l+1                ; quarter-square pointers for this byte of A
        sta .h+1
        eor #$ff
        sta .m+1
        sta .n+1
        lda #0
        sta mJ
.col:
        ldy mJ
        lda mB,y
        beq .col_next
        tay
        sec
.l      lda sq1lo,y
.m      sbc sq2lo,y
        sta m8lo
.h      lda sq1hi,y
.n      sbc sq2hi,y
        sta m8hi
        clc
        lda mP,x
        adc m8lo
        sta mP,x
        lda mP+1,x
        adc m8hi
        sta mP+1,x
        bcc .col_next
        txa
        pha
-       inx
        lda mP+1,x
        adc #0                  ; C = 1 here
        sta mP+1,x
        bcs -
        pla
        tax
.col_next:
        inx
        inc mJ
        lda mJ
        cmp mLenB
        bne .col
.row_next:
        inc mI
        lda mI
        cmp mLenA
        bne .row
        rts

; ---------------------------------------------------------------- negate
!zone neg64
neg64:                          ; note: loops count with DEY; CPX would clobber carry
        sec
        ldx #0
        ldy #8
.l:     lda #0
        sbc mA,x
        sta mA,x
        inx
        dey
        bne .l
        rts

; ---------------------------------------------------------------- unsigned division
; mA[8] / mB[4] -> quotient in mA[8], remainder in mR[0..3]. mB must be non-zero.
!zone udiv64
udiv64:
        lda #0
        sta mR+4
        ; fast path: 0 < high half < divisor -> the quotient fits 32 bits. Start with
        ; R = high half and run 32 steps over the low half (same result, half the steps).
        lda mA+7
        ora mA+6
        ora mA+5
        ora mA+4
        bne .lbx1_221
        jmp .full
.lbx1_221:
        lda mA+7
        cmp mB+3
        bne +
        lda mA+6
        cmp mB+2
        bne +
        lda mA+5
        cmp mB+1
        bne +
        lda mA+4
        cmp mB
+       bcs .full               ; high half >= divisor
        ldx #3
-       lda mA+4,x
        sta mR,x
        lda #0
        sta mA+4,x
        dex
        bpl -
        ; 32 steps: mA[0..3] shifts the low half out and the quotient in; compare
        ; first, subtract in place only when R >= d (mR+4 = 0 on entry)
        ldy #32
.fl:    asl mA
        rol mA+1
        rol mA+2
        rol mA+3
        rol mR
        rol mR+1
        rol mR+2
        rol mR+3
        rol mR+4
        lda mR+4
        bne .fsub
        lda mR+3
        cmp mB+3
        bcc .fnx
        bne .fsub
        lda mR+2
        cmp mB+2
        bcc .fnx
        bne .fsub
        lda mR+1
        cmp mB+1
        bcc .fnx
        bne .fsub
        lda mR
        cmp mB
        bcc .fnx
.fsub:  sec
        lda mR
        sbc mB
        sta mR
        lda mR+1
        sbc mB+1
        sta mR+1
        lda mR+2
        sbc mB+2
        sta mR+2
        lda mR+3
        sbc mB+3
        sta mR+3
        lda mR+4
        sbc #0
        sta mR+4
        inc mA
.fnx:   dey
        bne .fl
        rts
.full:  lda #0
        sta mR
        sta mR+1
        sta mR+2
        sta mR+3
        lda #64
        sta cnt0
.skip:                          ; leading zero bytes contribute zero quotient bits
        lda mA+7
        bne .loop
        lda cnt0
        beq .done
        ldx #6
.mv:    lda mA,x
        sta mA+1,x
        dex
        bpl .mv
        lda #0
        sta mA
        lda cnt0
        sec
        sbc #8
        sta cnt0
        jmp .skip
.loop:
        asl mA
        rol mA+1
        rol mA+2
        rol mA+3
        rol mA+4
        rol mA+5
        rol mA+6
        rol mA+7
        rol mR
        rol mR+1
        rol mR+2
        rol mR+3
        rol mR+4
        sec
        lda mR
        sbc mB
        sta mT
        lda mR+1
        sbc mB+1
        sta mT+1
        lda mR+2
        sbc mB+2
        sta mT+2
        lda mR+3
        sbc mB+3
        sta mT+3
        lda mR+4
        sbc #0
        bcc .no
        sta mR+4
        lda mT
        sta mR
        lda mT+1
        sta mR+1
        lda mT+2
        sta mR+2
        lda mT+3
        sta mR+3
        inc mA                  ; quotient bit (bit 0 was shifted in as 0)
.no:
        dec cnt0
        bne .loop
.done:
        rts

; ---------------------------------------------------------------- signed rounded division
; mA[8] signed / mB[4] (positive) -> mA[8] = round_div(n, d)
!zone round_div64
round_div64:
        lda mA+7
        sta mSign
        bpl .pos
        jsr neg64
.pos:
        ; mA += d >> 1
        lda mB+3
        lsr
        sta mT+3
        lda mB+2
        ror
        sta mT+2
        lda mB+1
        ror
        sta mT+1
        lda mB
        ror
        clc
        adc mA
        sta mA
        ldx #1
        ldy #3
.add:   lda mA,x
        adc mT,x
        sta mA,x
        inx
        dey
        bne .add
        ldy #4
.prop:  lda mA,x
        adc #0
        sta mA,x
        inx
        dey
        bne .prop
        jsr udiv64
        bit mSign
        bpl .done
        jsr neg64
.done:  rts

; ---------------------------------------------------------------- signed rounded shift
; mA[8] signed; A = s (signed). s > 0: round to nearest (ties away) of mA / 2^s.
; s <= 0: mA << -s.
!zone round_shift64
round_shift64:
        tay
        beq .done
        bmi .left
        sty cnt0
        lda mA+7
        sta mSign
        bpl .pos
        jsr neg64
.pos:
        ; add 2^(s-1)
        ldy cnt0
        dey
        tya
        lsr
        lsr
        lsr
        tax                     ; byte index
        tya
        and #7
        tay
        lda bit_tab,y
        clc
        adc mA,x
        sta mA,x
.c:     inx
        bcc .shift              ; no carry left to propagate
        txa                     ; X == 8 means the carry fell off the top
        eor #8
        beq .shift
        lda mA,x
        adc #0                  ; C = 1 (txa/eor/beq leave carry untouched)
        sta mA,x
        jmp .c
.shift:
        ; whole-byte shifts
        lda cnt0
.bytes: cmp #8
        bcc .bits
        ldx #0
.mvb:   lda mA+1,x
        sta mA,x
        inx
        cpx #7
        bne .mvb
        lda #0
        sta mA+7
        lda cnt0
        sec
        sbc #8
        sta cnt0
        jmp .bytes
.bits:  tay
        beq .sign
.bl:    lsr mA+7
        ror mA+6
        ror mA+5
        ror mA+4
        ror mA+3
        ror mA+2
        ror mA+1
        ror mA
        dey
        bne .bl
.sign:  bit mSign
        bpl .done
        jsr neg64
.done:  rts
.left:  ; shift left by -s
        eor #$ff
        clc
        adc #1
        tay
.ll:    asl mA
        rol mA+1
        rol mA+2
        rol mA+3
        rol mA+4
        rol mA+5
        rol mA+6
        rol mA+7
        dey
        bne .ll
        rts

bit_tab: !byte 1, 2, 4, 8, 16, 32, 64, 128

; ---------------------------------------------------------------- integer square root
; mA[8] -> mP[0..3] = floor(sqrt(mA)). Uses mA (destroyed), mR/mT scratch.
; Classic bit-by-bit method on 64-bit values: res in mP[8], bit in mR[8 via mR+mT].
!zone isqrt64
isqrt64:
        ldx #7
        lda #0
.clr:   sta mP,x
        sta isq_bit,x
        dex
        bpl .clr
        lda #$40                ; bit = 1 << 62
        sta isq_bit+7
.shrink:                        ; while bit > num: bit >>= 2
        ldx #7
.cmp1:  lda isq_bit,x
        cmp mA,x
        bcc .loop               ; bit < num
        bne .down               ; bit > num
        dex
        bpl .cmp1
        jmp .loop               ; equal
.down:  jsr .bit_shr2
        jsr .bit_zero
        bne .shrink
        rts                     ; num == 0
.loop:
        ; t = res + bit
        clc
        ldx #0
        ldy #8
.add:   lda mP,x
        adc isq_bit,x
        sta isq_t,x
        inx
        dey
        bne .add
        ; if num >= t
        ldx #7
.cmp2:  lda mA,x
        cmp isq_t,x
        bcc .less
        bne .ge
        dex
        bpl .cmp2
.ge:    ; num -= t
        sec
        ldx #0
        ldy #8
.sub:   lda mA,x
        sbc isq_t,x
        sta mA,x
        inx
        dey
        bne .sub
        ; res = (res >> 1) + bit
        jsr .res_shr1
        clc
        ldx #0
        ldy #8
.add2:  lda mP,x
        adc isq_bit,x
        sta mP,x
        inx
        dey
        bne .add2
        jmp .next
.less:  jsr .res_shr1
.next:  jsr .bit_shr2
        jsr .bit_zero
        bne .loop
        rts
.res_shr1:
        lsr mP+7
        ror mP+6
        ror mP+5
        ror mP+4
        ror mP+3
        ror mP+2
        ror mP+1
        ror mP
        rts
.bit_shr2:
        ldy #2
.bs:    lsr isq_bit+7
        ror isq_bit+6
        ror isq_bit+5
        ror isq_bit+4
        ror isq_bit+3
        ror isq_bit+2
        ror isq_bit+1
        ror isq_bit
        dey
        bne .bs
        rts
.bit_zero:                      ; Z clear if bit != 0
        lda isq_bit
        ora isq_bit+1
        ora isq_bit+2
        ora isq_bit+3
        ora isq_bit+4
        ora isq_bit+5
        ora isq_bit+6
        ora isq_bit+7
        rts

; ---------------------------------------------------------------- exp(-delta)
; mA[0..3] = delta >= 0 (Q16.16) -> mP[0..2] = exp(-delta) in Q0.24.
; i = delta >> 10, frac = delta & 1023; E[i] - round_shift((E[i]-E[i+1]) * frac, 10)
!zone exp_neg
exp_neg:
        lda mA+3
        beq +
        jmp .zero
+       lda mA+2
        cmp #$10                ; delta >= 16.0 (2^20)?
        bcc +
        jmp .zero
+
        ; i = delta >> 10 = (b2:b1) >> 2  (10 bits)
        lda mA+2
        sta tmp1
        lda mA+1
        lsr tmp1
        ror
        lsr tmp1
        ror
        sta tmp0                ; i lo
        ; frac = delta & $3ff
        lda mA+1
        and #3
        sta exp_frac+1
        lda mA
        sta exp_frac
        ; E[i], E[i+1] from the REU copy: 6 bytes at REU_EXP + 3i
        lda tmp0
        asl
        sta reu_adr
        lda tmp1
        rol
        sta reu_adr+1
        clc
        lda reu_adr
        adc tmp0
        sta reu_adr
        lda reu_adr+1
        adc tmp1
        sta reu_adr+1
        lda #^REU_EXP
        sta reu_adr+2
        lda #<exp_buf
        sta reu_c64
        lda #>exp_buf
        sta reu_c64+1
        lda #6
        sta reu_len
        lda #0
        sta reu_len+1
        jsr reu_fetch
        lda exp_buf
        sta exp_left
        lda exp_buf+1
        sta exp_left+1
        lda exp_buf+2
        sta exp_left+2
        ; diff = E[i] - E[i+1] (>= 0)
        sec
        lda exp_left
        sbc exp_buf+3
        sta mA
        lda exp_left+1
        sbc exp_buf+4
        sta mA+1
        lda exp_left+2
        sbc exp_buf+5
        sta mA+2
        lda #3
        sta mLenA
        lda exp_frac
        sta mB
        lda exp_frac+1
        sta mB+1
        lda #2
        sta mLenB
        jsr umul
        ldx #7
.cp:    lda mP,x
        sta mA,x
        dex
        bpl .cp
        lda #10
        jsr round_shift64       ; non-negative, so plain rounding
        sec
        lda exp_left
        sbc mA
        sta mP
        lda exp_left+1
        sbc mA+1
        sta mP+1
        lda exp_left+2
        sbc mA+2
        sta mP+2
        rts
.zero:  lda #0
        sta mP
        sta mP+1
        sta mP+2
        rts
