; hw_turbo.asm - C64 Ultimate turbo control through $D031.
;
; Source: Ultimate documentation "Turbo mode settings" (U64 Turbo Control,
; https://1541u-documentation.readthedocs.io/en/latest/config/turbo_mode.html):
;   $D031 exists only when the menu's Turbo Control is "U64/C64U Turbo Registers"
;   or "TurboEnable Bit"; otherwise it reads $FF.
;   bits 0-3 speed index (15 = 64 MHz on U64E2/C64U), bit 7 = 1 disables badline timing.
; Measured on the user's C64U (fw 1.1.0): index 15 = ~64 MHz; CIA timers stay 1 MHz.
;
;   turbo_on       select index 15 + badlines off. Carry clear = active, set = no registers.
;   turbo_restore  put back the value found by turbo_on (no-op if nothing changed)

TURBO_REG = $d031

!zone turbo
turbo_on:
        lda TURBO_REG
        cmp #$ff
        beq .none
        sta turbo_saved
        and #$70
        ora #$8f
        sta TURBO_REG
        lda #1
        sta turbo_changed
        lda TURBO_REG           ; read back: speed bits must say 15
        and #$0f
        cmp #$0f
        bne .none
        clc
        rts
.none:  sec
        rts

turbo_restore:
        lda turbo_changed
        beq +
        lda turbo_saved
        sta TURBO_REG
        lda #0
        sta turbo_changed
+       rts

turbo_saved:   !byte $ff
turbo_changed: !byte 0
