; test_host.asm - VICE test dispatcher for engine kernels (not part of the engine).
; Python (tests/engine/) writes a command block at TCMD, sets PC = test_entry and
; runs until test_done. Results are written back to the block.

!cpu 6510
!source "engine/include/memory.inc"
!source "engine/include/ai_api.inc"
* = $0801
        !word .bas_end, 10
        !byte $9e
        !text "2061"
        !byte 0
.bas_end: !word 0
* = $080d
        jmp test_entry

TCMD    = $c800         ; command byte
T_LENA  = $c801
T_LENB  = $c802
T_S     = $c803
T_A     = $c810         ; 8 bytes
T_B     = $c818         ; 4 bytes
T_OA    = $c820         ; 8 bytes result A
T_OP    = $c828         ; 8 bytes result P
T_OR    = $c830         ; 5 bytes remainder
T_CYC   = $c840         ; 4 bytes cycles
T_RES   = $c838         ; A and carry after the call


test_entry:
        sei
        lda #$36
        sta $01
        ldx #$ff
        txs
        lda init_flag
        bne +
        jsr math_init
        jsr exp_to_reu          ; exp_neg reads its table from the REU
        inc init_flag
+       ; load operands
        ldx #7
-       lda T_A,x
        sta mA,x
        dex
        bpl -
        ldx #3
-       lda T_B,x
        sta mB,x
        dex
        bpl -
        lda T_LENA
        sta mLenA
        lda T_LENB
        sta mLenB
        jsr timer_start
        lda TCMD
        asl
        tax
        lda op_table,x
        sta .call+1
        lda op_table+1,x
        sta .call+2
.call   jsr $ffff
        sta T_RES
        lda #0
        rol                     ; carry -> bit 0
        sta T_RES+1
        jsr timer_stop
        ldx #7
-       lda mA,x
        sta T_OA,x
        lda mP,x
        sta T_OP,x
        dex
        bpl -
        ldx #4
-       lda mR,x
        sta T_OR,x
        dex
        bpl -
test_done:
        jmp test_done

op_table:
        !word op_nop, umul, udiv64, round_div64, op_round_shift, isqrt64, exp_neg
        !word engine_init, load_model, op_step, model_reset, op_emb, op_norm, op_mv, op_emb1
op_nop: rts
init_flag: !byte 0          ; in the PRG image, so it starts at 0
op_step:                        ; T_A[0] = token, T_A[1] = want_logits
        lda T_A
        sta cur_token
        lda T_A+1
        sta want_logits
        jmp model_step
op_emb:                         ; x = tok_emb[T_A0] + pos_emb[T_A1]
        lda #0
        ldy T_A
        clc
        jsr emb_row
        lda #1
        ldy T_A+1
        sec
        jmp emb_row
op_emb1:                        ; x = tok_emb[T_A0] only
        lda #0
        ldy T_A
        clc
        jmp emb_row
op_norm:                        ; n = rmsnorm(x, slot T_A0)
        lda #<vec_x
        ldx #>vec_x
        ldy #0
        jsr set_src
        lda #<vec_n
        ldx #>vec_n
        ldy #0
        jsr set_dst
        lda T_A
        jmp rmsnorm
op_mv:                          ; q = matvec(slot T_A0, pack15(n))
        lda #<vec_n
        ldx #>vec_n
        ldy #0
        jsr set_src
        ldx m_d
        jsr pack15
        lda #<vec_q
        ldx #>vec_q
        ldy #0
        jsr set_dst
        lda T_A
        jmp matvec
op_round_shift:
        lda T_S
        jmp round_shift64

; CIA2 timer A counts PHI2, timer B counts A underflows -> 32-bit down counter.
timer_start:
        lda #0
        sta $dd0e
        sta $dd0f
        lda #$ff
        sta $dd04
        sta $dd05
        sta $dd06
        sta $dd07
        lda #$51                ; B: count A underflows, force load, start
        sta $dd0f
        lda #$11                ; A: count PHI2, force load, start
        sta $dd0e
        rts
timer_stop:
        lda #0
        sta $dd0e               ; stop A (B then stops counting)
        lda $dd04
        eor #$ff
        sta T_CYC
        lda $dd05
        eor #$ff
        sta T_CYC+1
        lda $dd06
        eor #$ff
        sta T_CYC+2
        lda $dd07
        eor #$ff
        sta T_CYC+3
        rts

!source "engine/source/engine.asm"
