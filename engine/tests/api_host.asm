; api_host.asm - end-to-end test of the public engine API (jump table only).
; Python writes: $c800 prompt (len, ids); $c900 settings block:
;   +0 max chars, +1/+2 inv_temp, +3 top_k, +4..+7 seed, +8 flags (bit0 skip CRC)
; Results: $c940 status of each call, $c950 cycles (4 bytes), output via AI_GET_OUTPUT.

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

SET     = $c900
RES     = $c940

test_entry:
        sei
        lda #$36
        sta $01
        ldx #$ff
        txs
        lda #$ff
        ldx #4
-       sta RES,x
        dex
        bpl -
        jsr AI_INIT
        sta RES
        bcs test_done
        lda SET
        sta AI_PB_MAX_CHARS
        lda SET+1
        sta AI_PB_INV_TEMP
        lda SET+2
        sta AI_PB_INV_TEMP+1
        lda SET+3
        sta AI_PB_TOP_K
        ldx #3
-       lda SET+4,x
        sta AI_PB_SEED,x
        dex
        bpl -
        lda SET+8
        sta AI_PB_FLAGS
        jsr AI_LOAD_MODEL
        sta RES+1
        bcs test_done
        ldx #<$c800
        ldy #>$c800
        jsr AI_SET_PROMPT
        sta RES+2
        bcs test_done
        jsr timer_start
        jsr AI_GENERATE
        sta RES+3
        jsr timer_stop
        jsr AI_GET_OUTPUT
        stx RES+4
test_done:
        jmp test_done

timer_start:
        lda #0
        sta $dd0e
        sta $dd0f
        lda #$ff
        sta $dd04
        sta $dd05
        sta $dd06
        sta $dd07
        lda #$51
        sta $dd0f
        lda #$11
        sta $dd0e
        rts
timer_stop:
        lda #0
        sta $dd0e
        ldx #3
-       lda $dd04,x
        eor #$ff
        sta $c950,x
        dex
        bpl -
        rts

!source "engine/source/engine.asm"
