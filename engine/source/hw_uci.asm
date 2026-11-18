; hw_uci.asm - load a model file into the REU through the Ultimate Command Interface.
;
; Sources (official Ultimate docs): "Core UCI Architecture" (registers, protocol) and
; "Ultimate DOS Target" (commands), https://1541u-documentation.readthedocs.io/en/latest/uci/
;   $DF1C write: control (bit0 PUSH_CMD, bit1 DATA_ACC, bit2 ABORT, bit3 CLR_ERR)
;   $DF1C read : status  (bit7 DATA_AV, bit6 STAT_AV, bits5-4 state 00 idle 01 busy
;                         10 data-last 11 data-more, bit3 ERROR, bit1 DATA_ACC pending)
;   $DF1D write: command bytes; read: identification ($C9 when the interface is enabled)
;   $DF1E read : response data   $DF1F read: status text ("00,OK")
; DOS target 1 commands used: OPEN_FILE $02 (attr $01 read), FILE_INFO $07 (data starts
; with the 32-bit file size, as Tiny21 relies on), LOAD_REU $21 (addr32, len32), CLOSE $03.
; Untested in VICE (no Command Interface there); hardware-tested via tools/hw_check.py.
;
;   uci_present       carry clear if the interface answers
;   uci_load_model    X/Y -> path (length byte + PETSCII/ASCII text).
;                     Loads the file to REU $000000. Carry clear = loaded; carry set:
;                     A = AI_ERR_NO_FILE (interface absent / open failed), AI_ERR_ARCH
;                     (file size unusable) or AI_ERR_IO (protocol error / timeout).
;                     uci_text holds the last status text (length byte + bytes).

UCI_CTRL   = $df1c
UCI_CMD    = $df1d
UCI_DATA   = $df1e
UCI_STAT   = $df1f

!zone uci
uci_present:
        lda UCI_CMD
        cmp #$c9
        beq +
        sec
        rts
+       clc
        rts

uci_load_model:
        stx ptr1
        sty ptr1+1
        jsr uci_present
        bcc +
        lda #AI_ERR_NO_FILE
        rts
+       ; OPEN_FILE: $01 $02 $01 <path>
        lda #$01
        sta uci_buf
        lda #$02
        sta uci_buf+1
        lda #$01
        sta uci_buf+2
        ldy #0
        lda (ptr1),y
        sta tmp0
        tax
        bne .lbx2_54
        jmp .no_file
.lbx2_54:
-       iny
        lda (ptr1),y
        sta uci_buf+2,y
        dex
        bne -
        lda tmp0
        clc
        adc #3
        jsr uci_exchange
        bcs .no_file
        lda #1
        sta uci_open
        ; FILE_INFO: size in the first 4 data bytes
        lda #$01
        sta uci_buf
        lda #$07
        sta uci_buf+1
        lda #2
        jsr uci_exchange
        bcs .io_close
        lda uci_dlen
        cmp #4
        bcc .io_close
        ; 256 < size <= $100000 (engine model region)
        lda uci_data+3
        bne .size_bad
        lda uci_data+2
        cmp #$10
        bcc +
        bne .size_bad
        lda uci_data+1
        ora uci_data
        bne .size_bad
+       lda uci_data+2
        ora uci_data+1
        beq .size_bad
        ; LOAD_REU: $01 $21 addr(0) len(size)
        lda #$01
        sta uci_buf
        lda #$21
        sta uci_buf+1
        lda #0
        sta uci_buf+2
        sta uci_buf+3
        sta uci_buf+4
        sta uci_buf+5
        ldx #3
-       lda uci_data,x
        sta uci_buf+6,x
        dex
        bpl -
        lda #10
        jsr uci_exchange
        bcs .io_close
        jsr .close
        clc
        rts
.size_bad:
        jsr .close
        lda #AI_ERR_ARCH
        sec
        rts
.io_close:
        jsr .close
        lda #AI_ERR_IO
        sec
        rts
.no_file:
        lda #AI_ERR_NO_FILE
        sec
        rts
.close: lda uci_open
        beq +
        lda #0
        sta uci_open
        lda #$01
        sta uci_buf
        lda #$03
        sta uci_buf+1
        lda #2
        jsr uci_exchange        ; result ignored
+       rts

; Send uci_buf[0..A-1], collect response data (first 32 bytes) and status text.
; Carry clear when the status text starts with "00".
uci_exchange:
        sta uci_clen
        lda #0
        sta uci_dlen
        sta uci_text
        jsr .deadline_start
        lda #$08                ; clear an earlier state error
        sta UCI_CTRL
.idle:  lda UCI_CTRL
        and #$3f                ; state, error, abort and busy bits
        beq .send
        jsr .expired
        bcc .idle
        jmp .abort
.send:  ldx #0
-       lda uci_buf,x
        sta UCI_CMD
        inx
        cpx uci_clen
        bne -
        lda #$01                ; PUSH_CMD
        sta UCI_CTRL
.wait:  lda UCI_CTRL
        sta uci_st
        and #$08                ; ERROR
        beq .lbx1_165
        jmp .abort
.lbx1_165:
        lda uci_st
        and #$02                ; previous DATA_ACC still being handled
        bne .wait_more
        lda uci_st
        and #$30
        cmp #$20                ; data-last or data-more
        bcs .drain
.wait_more:
        jsr .expired
        bcc .wait
        jmp .abort
.drain:
        sta uci_state
.dr:    lda UCI_CTRL
        bpl .dstat              ; bit 7 DATA_AV
        lda UCI_DATA
        ldx uci_dlen
        cpx #32
        bcs .dr
        sta uci_data,x
        inc uci_dlen
        jmp .dr
.dstat: and #$40                ; STAT_AV
        beq .acc
        lda UCI_STAT
        ldx uci_text
        cpx #31
        bcs .dr
        inx
        sta uci_text,x
        stx uci_text
        jmp .dr
.acc:   lda #$02                ; DATA_ACC
        sta UCI_CTRL
        lda uci_state
        cmp #$30
        bne .final
        jmp .wait               ; data-more: another block follows
.final: lda UCI_CTRL            ; back to idle
        and #$30
        beq .check
        jsr .expired
        bcc .final
        jmp .abort
.check: lda uci_text
        cmp #2
        bcc .bad
        lda uci_text+1
        cmp #"0"
        bne .bad
        lda uci_text+2
        cmp #"0"
        bne .bad
        clc
        rts
.bad:   sec
        rts
.abort: lda #$0c                ; ABORT + CLR_ERR
        sta UCI_CTRL
        sec
        rts

; deadline: CIA2 timer A counts PHI2 (1 MHz even under turbo), B counts A underflows.
; Expired after ~30 s (B has counted down 460 x 65536 ticks).
.deadline_start:
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
.expired:                       ; carry set when expired
        lda $dd07
        cmp #>($ffff - 460)
        bcc +
        clc
        rts
+       sec
        rts

uci_buf:   !fill 64, 0
uci_data:  !fill 32, 0
uci_text:  !fill 32, 0          ; length byte + status text
uci_clen:  !byte 0
uci_dlen:  !byte 0
uci_st:    !byte 0
uci_state: !byte 0
uci_open:  !byte 0
