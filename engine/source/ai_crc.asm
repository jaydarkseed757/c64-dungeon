; ai_crc.asm - CRC32 (IEEE 802.3, reflected, poly $edb88320), same as zlib.crc32.
;   crc_init        build the 1 KiB table (four byte planes at crc_t0..crc_t3)
;   crc_begin       crc = $ffffffff
;   crc_mem         update over (ptr0), length tmp0/tmp1 (16-bit, 0 = none)
;   crc_reu         update over REU bytes at reu_adr, length crc_left (32-bit),
;                   streamed through the tile window
;   crc_end         crc ^= $ffffffff

!zone crc_init
crc_init:
        ldx #0
.entry:
        stx mT
        lda #0
        sta mT+1
        sta mT+2
        sta mT+3
        ldy #8
.bit:   lsr mT+3
        ror mT+2
        ror mT+1
        ror mT
        bcc .nox
        lda mT
        eor #$20
        sta mT
        lda mT+1
        eor #$83
        sta mT+1
        lda mT+2
        eor #$b8
        sta mT+2
        lda mT+3
        eor #$ed
        sta mT+3
.nox:   dey
        bne .bit
        lda mT
        sta crc_t0,x
        lda mT+1
        sta crc_t1,x
        lda mT+2
        sta crc_t2,x
        lda mT+3
        sta crc_t3,x
        inx
        bne .entry
        rts

crc_begin:
        lda #$ff
        sta crc
        sta crc+1
        sta crc+2
        sta crc+3
        rts

crc_end:
        ldx #3
-       lda crc,x
        eor #$ff
        sta crc,x
        dex
        bpl -
        rts

!zone crc_mem
crc_mem:
        ldy #0
.loop:  lda tmp0
        ora tmp1
        beq .done
        lda (ptr0),y
        eor crc
        tax
        lda crc+1
        eor crc_t0,x
        sta crc
        lda crc+2
        eor crc_t1,x
        sta crc+1
        lda crc+3
        eor crc_t2,x
        sta crc+2
        lda crc_t3,x
        sta crc+3
        iny
        bne +
        inc ptr0+1
+       lda tmp0
        bne +
        dec tmp1
+       dec tmp0
        jmp .loop
.done:  rts

!zone crc_reu
crc_reu:
.chunk:
        lda crc_left+3
        ora crc_left+2
        bne .full
        lda crc_left+1
        cmp #>REU_TILE_SIZE
        bcs .full
        lda crc_left+1          ; last chunk: < 8 KiB
        sta reu_len+1
        lda crc_left
        sta reu_len
        ora reu_len+1
        bne .xfer
        clc
        rts
.full:  lda #0
        sta reu_len
        lda #>REU_TILE_SIZE
        sta reu_len+1
.xfer:
        lda reu_len
        sta crc_n
        lda reu_len+1
        sta crc_n+1
        lda #<REU_TILE
        sta reu_c64
        sta ptr0
        lda #>REU_TILE
        sta reu_c64+1
        sta ptr0+1
        jsr reu_fetch           ; advances reu_adr
        bcs .err
        ; crc_left -= chunk
        sec
        lda crc_left
        sbc crc_n
        sta crc_left
        lda crc_left+1
        sbc crc_n+1
        sta crc_left+1
        lda crc_left+2
        sbc #0
        sta crc_left+2
        lda crc_left+3
        sbc #0
        sta crc_left+3
        lda crc_n
        sta tmp0
        lda crc_n+1
        sta tmp1
        lda #<REU_TILE
        sta ptr0
        lda #>REU_TILE
        sta ptr0+1
        jsr crc_mem
        jmp .chunk
.err:   rts
