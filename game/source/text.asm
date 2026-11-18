; text.asm - screen helpers, the Dungeon Master message log, and dm_event.
;
; Printing: `jsr say` followed by `!scr "text", 0` prints the inline string to the
; log and continues after it. say_at does the same directly at (row via scr, column Y).
; Log: rows LOG_TOP..LOG_BOT, columns LOG_LEFT..LOG_RIGHT, word-wrapped, scrolling.

; ---------------------------------------------------------------- screen
!zone row_ptr
row_ptr:                        ; X = row -> scr, colp
        lda row_lo,x
        sta scr
        sta colp
        lda row_hi,x
        sta scr+1
        clc
        adc #>(COLRAM - SCREEN)
        sta colp+1
        rts

!zone clear_screen
clear_screen:
        ldx #0
-       lda #$20
        sta SCREEN,x
        sta SCREEN+$100,x
        sta SCREEN+$200,x
        sta SCREEN+$2e8,x
        lda #C_TEXT
        sta COLRAM,x
        sta COLRAM+$100,x
        sta COLRAM+$200,x
        sta COLRAM+$2e8,x
        inx
        bne -
        rts

!zone say_at
say_at:                         ; inline string at (scr row, column Y)
        sty t3
        pla
        sta str
        pla
        sta str+1
        ldy #0
.l:     iny                     ; str points at the last byte of the JSR
        lda (str),y
        beq .end
        sty t2
        ldy t3
        sta (scr),y
        inc t3
        ldy t2
        bne .l
.end:   tya
        clc
        adc str
        tax
        lda str+1
        adc #0
        pha
        txa
        pha
        rts

!zone pet2scr
pet2scr:                        ; PETSCII (mixed-case set) -> screen code
        cmp #$20
        bcc .q
        cmp #$40
        bcc .same
        cmp #$60
        bcc .sub40
        cmp #$c1
        bcc .q
        cmp #$db
        bcs .q
        sec
        sbc #$80
        rts
.sub40: sec
        sbc #$40
.same:  rts
.q:     lda #$3f
        rts

; ---------------------------------------------------------------- log window
!zone log_clear
log_clear:
        lda #LOG_TOP
        sta log_row
        lda #LOG_LEFT
        sta log_col
        sta word_start
        lda #0
        sta word_len
        lda #C_TEXT
        sta color
        ldx #LOG_TOP
-       jsr row_ptr
        ldy #39
        lda #$20
--      sta (scr),y
        dey
        bpl --
        inx
        cpx #LOG_BOT+1
        bne -
        rts

!zone log_para
log_para:                       ; start a new line unless at the start of one
        lda log_col
        cmp #LOG_LEFT
        beq +
        jmp log_nl
+       rts

!zone log_nl
log_nl:
        lda #LOG_LEFT
        sta log_col
        sta word_start
        lda #0
        sta word_len
        inc log_row
        lda log_row
        cmp #LOG_BOT+1
        bcc +
        jsr log_scroll
        lda #LOG_BOT
        sta log_row
+       rts

!zone log_scroll
log_scroll:
        ldx #LOG_TOP
.r:     jsr row_ptr
        lda scr
        sta sp1
        lda scr+1
        sta sp1+1
        lda colp
        sta sp2
        lda colp+1
        sta sp2+1
        inx
        jsr row_ptr
        ldy #39
-       lda (scr),y
        sta (sp1),y
        lda (colp),y
        sta (sp2),y
        dey
        bpl -
        cpx #LOG_BOT
        bne .r
        ldx #LOG_BOT
        jsr row_ptr
        ldy #39
        lda #$20
-       sta (scr),y
        dey
        bpl -
        rts

!zone log_putc
log_putc:                       ; A = screen code; word wraps. Keeps str intact.
        cmp #$20
        bne .ch
        lda log_col
        cmp #LOG_RIGHT+1
        bcc +
        jmp log_nl
+       lda #$20
        jsr .store
        inc log_col
        lda #0
        sta word_len
        lda log_col
        sta word_start
        rts
.ch:    sta t5
        lda log_col
        cmp #LOG_RIGHT+1
        bcc .fits
        lda word_start
        cmp #LOG_LEFT
        beq .hard
        lda word_len            ; carry the partial word to the next line
        sta word_lsave
        ldx log_row
        jsr row_ptr
        ldy word_start
        lda #$20
-       cpy #LOG_RIGHT+1
        bcs +
        sta (scr),y
        iny
        bne -
+       jsr log_nl
        ldx #0
-       cpx word_lsave
        beq +
        stx t4
        lda word_buf,x
        jsr .store
        inc log_col
        ldx t4
        inx
        bne -
+       lda word_lsave
        sta word_len
        jmp .fits
.hard:  jsr log_nl
.fits:  lda t5
        jsr .store
        ldx word_len
        cpx #40
        bcs +
        lda t5
        sta word_buf,x
        inc word_len
+       inc log_col
        rts
.store: pha
        ldx log_row
        jsr row_ptr
        pla
        ldy log_col
        sta (scr),y
        lda color
        sta (colp),y
        rts

; ---------------------------------------------------------------- printing to the log
!zone say
say:                            ; inline string -> log
        pla
        sta str
        pla
        sta str+1
.l:     inc str
        bne +
        inc str+1
+       ldy #0
        lda (str),y
        bne .lbx1_237
        jmp .end
.lbx1_237:
        jsr log_putc
        jmp .l
.end:   lda str+1
        pha
        lda str
        pha
        rts

!zone say_ptr
say_ptr:                        ; A/X = 0-terminated screen-code string
        sta str
        stx str+1
        ldy #0
-       lda (str),y
        beq +
        sty t3
        jsr log_putc
        ldy t3
        iny
        bne -
+       rts

!zone say_num
say_num:                        ; A = 0..255
        ldx #0
        jmp say_num16
!zone say_num16
say_num16:                      ; A = lo, X = hi
        sta t0
        stx t1
        ldy #0                  ; digits produced
        ldx #4
        lda #0
        sta t4                  ; leading-zero flag
.d:     lda #0
        sta t2
.s:     lda t0
        sec
        sbc p10_lo,x
        sta t3
        lda t1
        sbc p10_hi,x
        bcc .dig
        sta t1
        lda t3
        sta t0
        inc t2
        jmp .s
.dig:   lda t2
        bne +
        lda t4
        bne +
        cpx #0
        bne .skip
+       lda t2
        ora #$30
        stx t3
        jsr log_putc
        ldx t3
        inc t4
.skip:  dex
        bpl .d
        rts
!zone p10_lo
p10_lo: !byte <1, <10, <100, <1000, <10000
!zone p10_hi
p10_hi: !byte >1, >10, >100, >1000, >10000

; name from a generated table: X = id, A/Y = lo/hi table addresses (via macro below)
!macro say_name .lo, .hi {
        lda .lo,x
        pha
        lda .hi,x
        tax
        pla
        jsr say_ptr
}
; "a"/"an" + name; capital A when t7 bit 7 is set
!macro say_a .lo, .hi {
        lda .lo,x
        sta ptr
        lda .hi,x
        sta ptr+1
        jsr say_article
        lda ptr
        ldx ptr+1
        jsr say_ptr
}
!zone say_article
say_article:                    ; ptr = name; prints "a " / "an " (capital if t7 bit 7)
        ldy #0
        lda (ptr),y
        ldx #0
        cmp #$01                ; a
        beq .an
        cmp #$05                ; e
        beq .an
        cmp #$09                ; i
        beq .an
        cmp #$0f                ; o
        beq .an
        cmp #$15                ; u
        beq .an
        jmp .a
.an:    ldx #1
.a:     lda #$01                ; "a"
        bit t7
        bpl +
        lda #$41                ; "A"
+       stx t6
        jsr log_putc
        lda t6
        beq +
        lda #$0e                ; "n"
        jsr log_putc
+       lda #$20
        jmp log_putc

!zone say_cap
say_cap:                        ; capitalized name: X = id; A/Y set like say_name (lo in ptr)
        ldy #0
        lda (ptr),y
        cmp #$01
        bcc +
        cmp #$1b
        bcs +
        ora #$40
+       jsr log_putc
        ldy #1
-       lda (ptr),y
        beq +
        sty t3
        jsr log_putc
        ldy t3
        iny
        bne -
+       rts

; ---------------------------------------------------------------- narrator interface
; dm_begin(A = kind, X = TASK token): start a context record. Tokens must follow the
; training order (python/vocab.py CONTEXT_ORDER): TASK LOC ROOM NPC MOOD QUEST MON MST OBJ
; ITEM ACT OUT ENV HP LVL; LOC only for ROOM/MONSTER/EVENT/NPC records.
; dm_tok(A = token): append. dm_end: count the event. Milestone 6 hands dm_ctx to the
; engine here; Milestone 5 prints only the fallback text that follows each call.
!zone dm_begin
dm_begin:
        sta dm_kind
        lda #0
        sta dm_ctx
        txa
        jmp dm_tok
!zone dm_loc
dm_loc:                         ; append LOC:<floor> (only for task types trained with LOC)
        ldx p_floor
        dex
        lda floor_tok,x
!zone dm_tok
dm_tok:
        ldx dm_ctx
        cpx #15
        bcs +
        inx
        sta dm_ctx,x
        stx dm_ctx
+       rts
!zone dm_end
dm_end:                         ; -> carry set if the narrator showed generated text
        inc dm_count
        jsr log_para
        lda #C_TEXT
        sta color
        jmp narrate

!zone row_lo
row_lo:
!for r, 0, 24 { !byte <(SCREEN + r * 40) }
!zone row_hi
row_hi:
!for r, 0, 24 { !byte >(SCREEN + r * 40) }
