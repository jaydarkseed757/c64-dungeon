; hw_reu.asm - 17xx-compatible REU access for the DM64 engine.
;
; Registers (Commodore 1700/1750 REU guide, 8726 REC; same use in llama2.c64 and Tiny21):
;   $df00 status   $df01 command   $df02/03 C64 address   $df04/05/06 REU address
;   $df07/08 length   $df09 IRQ mask   $df0a address control
; Command $90 = C64 -> REU (stash), $91 = REU -> C64 (fetch), executed at once.
;
; reu_fetch / reu_stash: reu_c64 (2), reu_adr (3), reu_len (2; 0 = nothing).
;   Splits transfers at 512 KiB REU boundaries (Tiny21 reports the C64 Ultimate's
;   address counter wraps there; splitting is harmless if it does not).
;   On return reu_adr and reu_c64 have advanced past the data. Carry set = DMA error.
; reu_detect: sets reu_present / reu_mb, never destroys REU contents.

REU_STATUS  = $df00
REU_CMD     = $df01
REU_C64LO   = $df02
REU_C64HI   = $df03
REU_ADRLO   = $df04
REU_ADRHI   = $df05
REU_BANK    = $df06
REU_LENLO   = $df07
REU_LENHI   = $df08
REU_IRQMASK = $df09
REU_ADRCTL  = $df0a

!zone reu_xfer
reu_fetch:
        lda #$91
        bne reu_xfer
reu_stash:
        lda #$90
reu_xfer:
        sta .cmd+1
        lda reu_len
        ora reu_len+1
        bne .go
        clc
        rts
.go:
        ; bytes left in this 512 KiB bank = $80000 - (adr & $7ffff)
        lda reu_adr+2
        and #$07
        sta tmp2
        sec
        lda #0
        sbc reu_adr
        sta tmp0
        lda #0
        sbc reu_adr+1
        sta tmp1
        lda #8
        sbc tmp2
        ; tmp0/tmp1/A = room (1 .. $80000). If room >= len, one transfer.
        bne .whole              ; room >= $10000 > any len
        lda tmp1
        cmp reu_len+1
        bcc .split
        bne .whole
        lda tmp0
        cmp reu_len
        bcs .whole
.split:                         ; chunk = room (< len)
        lda tmp0
        sta tmp3
        lda tmp1
        sta tmp4
        jmp .issue
.whole:
        lda reu_len
        sta tmp3
        lda reu_len+1
        sta tmp4
.issue:
        lda REU_STATUS          ; clear pending status
        lda reu_c64
        sta REU_C64LO
        lda reu_c64+1
        sta REU_C64HI
        lda reu_adr
        sta REU_ADRLO
        lda reu_adr+1
        sta REU_ADRHI
        lda reu_adr+2
        sta REU_BANK
        lda tmp3
        sta REU_LENLO
        lda tmp4
        sta REU_LENHI
        lda #0
        sta REU_IRQMASK
        sta REU_ADRCTL
.cmd    lda #$91                ; SMC: command
        sta REU_CMD
        lda REU_STATUS
        and #$40                ; end of block
        bne .ok
        sec
        rts
.ok:    ; advance addresses, consume length
        clc
        lda reu_adr
        adc tmp3
        sta reu_adr
        lda reu_adr+1
        adc tmp4
        sta reu_adr+1
        lda reu_adr+2
        adc #0
        sta reu_adr+2
        clc
        lda reu_c64
        adc tmp3
        sta reu_c64
        lda reu_c64+1
        adc tmp4
        sta reu_c64+1
        sec
        lda reu_len
        sbc tmp3
        sta reu_len
        lda reu_len+1
        sbc tmp4
        sta reu_len+1
        ora reu_len
        beq +
        jmp .go
+       clc
        rts

; ---------------------------------------------------------------- detection
; Probe register read-back, then a DMA round trip, then aliasing at 512 KiB
; multiples. All REU bytes touched are saved first and restored afterwards.
!zone reu_detect
reu_detect:
        lda #0
        sta reu_mb
        sta reu_present
        ; register read-back: the REU address registers are read/write
        lda #$55
        sta REU_ADRLO
        lda #$aa
        sta REU_ADRHI
        lda REU_ADRLO
        cmp #$55
        beq .lb9
        jmp .none
.lb9:
        lda REU_ADRHI
        cmp #$aa
        beq .lb10
        jmp .none
.lb10:
        ; save REU[0..3]
        lda #0
        sta reu_adr
        sta reu_adr+1
        sta reu_adr+2
        jsr .fetch_probe0
        bcc .lb11
        jmp .none
.lb11:
        ; DMA round trip at REU 0: write a pattern, read it back
        ldx #3
-       lda .pattern,x
        sta reu_probe1,x
        dex
        bpl -
        jsr .stash1_at_adr
        bcs .restore0_fail
        jsr .fetch2_at_adr
        bcs .restore0_fail
        ldx #3
-       lda reu_probe2,x
        cmp .pattern,x
        bne .restore0_fail
        dex
        bpl -
        lda #1
        sta reu_present
        ; aliasing: for boundary B = 512K * 2^k, save REU[B], write tag there, check REU[0]
        lda #$08                ; B high byte (in units of 64K): $08 = 512K
        sta cnt1
.alias_loop:
        lda #0
        sta reu_adr
        sta reu_adr+1
        lda cnt1
        sta reu_adr+2
        jsr .fetch_saveB
        lda cnt1                ; tag = B high byte, unlike the pattern at 0
        sta reu_probe1
        sta reu_probe1+1
        sta reu_probe1+2
        sta reu_probe1+3
        jsr .stash1_at_B
        lda #0
        sta reu_adr
        sta reu_adr+1
        sta reu_adr+2
        jsr .fetch2_at_adr
        jsr .restore_B
        ldx #3
-       lda reu_probe2,x
        cmp .pattern,x
        bne .aliased            ; REU[0] changed: B wraps to 0, size = B
        dex
        bpl -
        asl cnt1
        bcc .alias_loop         ; up to B = 8 MB ($80); next would be 16 MB
        lda #16                 ; no alias below 16 MB
        sta reu_mb
        jmp .restore0
.aliased:
        lda cnt1                ; B in 64K units -> MB = cnt1 / 16
        lsr
        lsr
        lsr
        lsr
        sta reu_mb              ; 512K -> 0
.restore0:
        jsr .restore_probe0
        clc
        rts
.restore0_fail:
        jsr .restore_probe0
.none:
        sec
        rts

.pattern: !byte $d6, $4a, $49, $21

.fetch_probe0:                  ; reu_probe0 <- REU[adr]
        lda #<reu_probe0
        ldx #>reu_probe0
        jmp .fetch4
.fetch2_at_adr:
        lda #<reu_probe2
        ldx #>reu_probe2
.fetch4:
        sta reu_c64
        stx reu_c64+1
        lda #4
        sta reu_len
        lda #0
        sta reu_len+1
        lda reu_adr
        pha
        lda reu_adr+1
        pha
        lda reu_adr+2
        pha
        jsr reu_fetch
        jmp .restore_adr
.stash1_at_adr:
.stash1_at_B:
        lda #<reu_probe1
        ldx #>reu_probe1
.stash4:
        sta reu_c64
        stx reu_c64+1
        lda #4
        sta reu_len
        lda #0
        sta reu_len+1
        lda reu_adr
        pha
        lda reu_adr+1
        pha
        lda reu_adr+2
        pha
        jsr reu_stash
.restore_adr:
        pla
        sta reu_adr+2
        pla
        sta reu_adr+1
        pla
        sta reu_adr
        rts
.fetch_saveB:                   ; reu_probeB <- REU[B] (reu_adr = B)
        lda #<reu_probeB
        ldx #>reu_probeB
        jmp .fetch4
.restore_B:                     ; REU[B] <- reu_probeB
        lda #0
        sta reu_adr
        sta reu_adr+1
        lda cnt1
        sta reu_adr+2
        lda #<reu_probeB
        ldx #>reu_probeB
        jmp .stash4
.restore_probe0:                ; REU[0] <- reu_probe0
        lda #0
        sta reu_adr
        sta reu_adr+1
        sta reu_adr+2
        lda #<reu_probe0
        ldx #>reu_probe0
        jmp .stash4
