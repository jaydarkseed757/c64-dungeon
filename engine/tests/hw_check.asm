; hw_check.asm - first hardware check of the DM64 engine on the C64 Ultimate.
; Started by REST runners:run_prg (tools/hw_check.py). The model must already be
; in the REU (menu "Load into REU" or REU Preload). Writes a result block at RES
; for machine:readmem and prints a summary on screen.
;
; If the turbo registers answer ($D031 != $FF) it selects 64 MHz with badline
; timing off for the run (index 15 | bit 7) and restores the old value at the end.
; CIA timers stay at 1 MHz under turbo (measured by c64-tyrian on this unit), so
; cycle counts below are 1 MHz CIA ticks = microseconds (PAL ~0.985 MHz).

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
        jmp start

RES     = $c800
NONCE   = $c900         ; patched into the PRG image by hw_check.py (2 bytes)
TURBO   = $d031

prompt: !byte 6, 1, 0, 0, 0, 0, 3     ; patched: BOS TASK:ACTION OBJ:DOOR ACT:OPEN OUT:LOCKED SEP
nonce_src: !word $0000                ; patched
gen_max: !byte 40
mode:   !byte 0                       ; patched: bit0 = load the model file through the Command Interface first
model_path:
        !byte .pend - .p
.p:     !text "/USB1/dist/dungeon-master/DM64AI.REU"
.pend:

start:
        sei
        lda #$36
        sta $01
        ldx #$ff
        txs
        ldx #$9f
        lda #0
-       sta RES,x
        dex
        bpl -
        lda nonce_src
        sta RES+4
        lda nonce_src+1
        sta RES+5
        lda #"D"
        sta RES
        lda #"M"
        sta RES+1
        lda #"6"
        sta RES+2
        lda #"4"
        sta RES+3
        ; turbo
        lda TURBO
        sta RES+12
        sta old_turbo
        cmp #$ff
        beq +
        and #$70
        ora #$8f
        sta TURBO
        lda TURBO
        sta RES+28
+       lda #1
        sta RES+7
        jsr AI_INIT
        sta RES+8
        rol RES+9
        lda AI_PB_REU_MB
        sta RES+10
        lda AI_PB_CAPS
        sta RES+11
        lda RES+9
        beq .lbx1_75
        jmp .fail
.lbx1_75:
        lda mode
        and #1
        beq .no_uci
        lda mode
        and #2                  ; bit1: damage the REU header first, so only a real load passes
        beq .nodamage
        lda #"X"
        sta damage_byte
        lda #<damage_byte
        sta reu_c64
        lda #>damage_byte
        sta reu_c64+1
        lda #0
        sta reu_adr
        sta reu_adr+1
        sta reu_adr+2
        sta reu_len+1
        lda #1
        sta reu_len
        jsr reu_stash
        inc RES+106             ; damage done
.nodamage:
        lda #4
        sta RES+7
        jsr timer_start
        ldx #<model_path
        ldy #>model_path
        jsr uci_load_model
        php
        sta RES+100
        jsr timer_stop
        ldx #3
-       lda cyc,x
        sta RES+102,x
        dex
        bpl -
        plp
        rol RES+101
        ldx #0                  ; last status text
-       lda uci_text,x
        sta RES+108,x
        inx
        cpx #24
        bne -
        lda RES+101
        and #1
        beq .no_uci
        jmp .fail
.no_uci:
        lda #2
        sta RES+7
        jsr timer_start
        jsr AI_LOAD_MODEL
        php
        sta RES+13
        jsr timer_stop
        ldx #3
-       lda cyc,x
        sta RES+15,x
        dex
        bpl -
        plp
        rol RES+14
        lda RES+14
        bne .fail
        ; generation only with turbo (about 33 minutes at 1 MHz)
        lda old_turbo
        cmp #$ff
        beq .done
        lda #3
        sta RES+7
        lda gen_max
        sta AI_PB_MAX_CHARS
        ldx #<prompt
        ldy #>prompt
        jsr AI_SET_PROMPT
        sta RES+20
        bcs .fail
        inc RES+19
        jsr timer_start
        jsr AI_GENERATE
        php
        sta RES+21
        jsr timer_stop
        ldx #3
-       lda cyc,x
        sta RES+23,x
        dex
        bpl -
        plp
        rol RES+22
        lda RES+22
        bne .fail
        lda out_buf
        sta RES+27
        ; copy output text
        ldx #0
-       lda out_buf+1,x
        sta RES+33,x
        inx
        cpx out_buf
        beq +
        cpx #64
        bne -
+       lda out_buf
        sta RES+32
.done:  lda #1
        sta RES+6
        jmp finish
.fail:  lda #2
        sta RES+6
finish:
        lda old_turbo
        cmp #$ff
        beq +
        sta TURBO
+       cli
        jsr show
-       jmp -

; screen summary (KERNAL CHROUT, mixed-case character set)
show:
        lda #14                 ; lowercase/uppercase set
        jsr $ffd2
        lda #147                ; clear
        jsr $ffd2
        ldx #0
-       lda msg,x
        beq +
        jsr $ffd2
        inx
        bne -
+       lda RES+6
        cmp #1
        bne .bad
        ldx #0
-       lda msg_ok,x
        beq +
        jsr $ffd2
        inx
        bne -
+       ldx #0
-       cpx RES+32
        beq +
        lda RES+33,x
        jsr $ffd2
        inx
        bne -
+       lda #13
        jmp $ffd2
.bad:   ldx #0
-       lda msg_bad,x
        beq +
        jsr $ffd2
        inx
        bne -
+       rts

msg:     !pet "DM64 engine hardware check", 13, 13, 0
msg_ok:  !pet "Model in REU verified (CRC32 OK).", 13, 13, 0
msg_bad: !pet "FAILED - see result block at $C800.", 13, 0
old_turbo: !byte $ff
cyc:     !byte 0, 0, 0, 0
damage_byte: !byte 0

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
        sta cyc,x
        dex
        bpl -
        rts

!source "engine/source/engine.asm"
