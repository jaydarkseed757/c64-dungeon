; view.asm - map access, visibility, map view, status bar.

; X = x, Y = y -> mp = MAP + y*64 + x. X, Y preserved.
!zone map_addr
map_addr:
        tya
        and #3
        asl
        asl
        asl
        asl
        asl
        asl
        sta mp
        txa
        ora mp
        sta mp
        tya
        lsr
        lsr
        clc
        adc #>MAP
        sta mp+1
        rts

; X = x, Y = y -> A = tile byte. X, Y preserved.
!zone tile_at
tile_at:
        jsr map_addr
        sty t4
        ldy #0
        lda (mp),y
        ldy t4
        rts

; X = x, Y = y, A = new tile (keeps the seen bit). X, Y preserved.
!zone tile_set
tile_set:
        sta t5
        jsr map_addr
        sty t4
        ldy #0
        lda (mp),y
        and #SEEN
        ora t5
        sta (mp),y
        ldy t4
        rts

; ---------------------------------------------------------------- visibility
!zone reveal
reveal:
        ; radius 2 around the player
        lda p_y
        sec
        sbc #2
        bcs +
        lda #0
+       sta t0                  ; y from
        lda p_y
        clc
        adc #2
        cmp #MAPH
        bcc +
        lda #MAPH-1
+       sta t1                  ; y to
        lda p_x
        sec
        sbc #2
        bcs +
        lda #0
+       sta t2
        lda p_x
        clc
        adc #2
        cmp #MAPW
        bcc +
        lda #MAPW-1
+       sta t3
        jsr mark_rect
        ; whole room if the player stands in one
        jsr room_of_player
        cmp #$ff
        beq .done
        tax
        lda r_y,x
        sec
        sbc #1
        sta t0
        clc
        adc r_h,x
        adc #1
        sta t1
        lda r_x,x
        sec
        sbc #1
        sta t2
        clc
        adc r_w,x
        adc #1
        sta t3
        jsr mark_rect
.done:  rts

!zone mark_rect
mark_rect:                      ; seen for x t2..t3, y t0..t1
        ldy t0
.y:     ldx t2
.x:     jsr map_addr
        sty t4
        ldy #0
        lda (mp),y
        ora #SEEN
        sta (mp),y
        ldy t4
        cpx t3
        beq +
        inx
        bne .x
+       cpy t1
        beq +
        iny
        bne .y
+       rts

; -> A = room index containing the player (interior), $ff if none
!zone room_of_player
room_of_player:
        ldx p_x
        ldy p_y
!zone point_room
point_room:                     ; X, Y = point -> A = room or $ff
        stx t6
        sty t7
        ldx #0
.r:     cpx n_rooms
        bne .lbx4_130
        jmp .none
.lbx4_130:
        lda t6
        cmp r_x,x
        bcc .next
        lda r_x,x
        clc
        adc r_w,x
        sta t5
        lda t6
        cmp t5
        bcs .next
        lda t7
        cmp r_y,x
        bcc .next
        lda r_y,x
        clc
        adc r_h,x
        sta t5
        lda t7
        cmp t5
        bcs .next
        txa
        ldx t6
        ldy t7
        rts
.next:  inx
        beq .lbx3_156
        jmp .r
.lbx3_156:
.none:  ldx t6
        ldy t7
        lda #$ff
        rts

; room entry: announce a room the first time the player stands in it
!zone check_room
check_room:
        jsr room_of_player
        cmp cur_room
        bne .lbx2_166
        jmp .same
.lbx2_166:
        sta cur_room
        cmp #$ff
        bne .lbx6_175
        jmp .same
.lbx6_175:
        tax
        lda r_seen,x
        beq .lbx5_178
        jmp .same
.lbx5_178:
        lda #1
        sta r_seen,x
        txa
        jmp ev_room
.same:  rts

; ---------------------------------------------------------------- drawing
!zone draw_all
draw_all:
        jsr draw_status
        jmp draw_view

!zone draw_frame
draw_frame:
        ldx #16
        jsr row_ptr
        ldy #39
-       lda #$40
        sta (scr),y
        lda #C_WALL
        sta (colp),y
        dey
        bpl -
!zone draw_help
draw_help:
        ldx #24
        jsr row_ptr
        ldy #39
        lda #$20
-       sta (scr),y
        dey
        bpl -
        ldy #0
        jsr say_at
        !scr "WASD move G get I items C char R rest", 0
        ldy #39
        lda #C_SYS
-       sta (colp),y
        dey
        bpl -
        rts

!zone draw_view
draw_view:
        ; view origin: x in 0..24, y in 0..17
        lda p_x
        sec
        sbc #20
        bcs +
        lda #0
+       cmp #MAPW-40+1
        bcc +
        lda #MAPW-40
+       sta view_x
        lda p_y
        sec
        sbc #7
        bcs +
        lda #0
+       cmp #MAPH-VIEW_ROWS+1
        bcc +
        lda #MAPH-VIEW_ROWS
+       sta view_y
        ; tiles
        lda #0
        sta t0                  ; view row
.row:   lda t0
        clc
        adc #VIEW_TOP
        tax
        jsr row_ptr
        ldx view_x
        lda t0
        clc
        adc view_y
        tay
        jsr map_addr
        ldy #39
.col:   lda (mp),y
        bmi .seen
        lda #$20
        sta (scr),y
        lda #0
        sta (colp),y
        jmp .nx
.seen:  and #$1f
        tax
        lda tile_glyph,x
        sta (scr),y
        lda tile_color,x
        sta (colp),y
.nx:    dey
        bpl .col
        inc t0
        lda t0
        cmp #VIEW_ROWS
        bne .row
        ; items on seen tiles
        ldx #MAX_ITEM-1
.it:    lda i_type,x
        beq .itn
        stx t1
        lda i_x,x
        ldy i_y,x
        jsr view_cell           ; carry set if off view; scr/colp row, Y column
        bcs .itd
        ldx t1
        lda i_x,x
        sta t2
        lda i_y,x
        tay
        ldx t2
        jsr tile_at
        bpl .itd                ; not seen
        ldx t1
        lda i_type,x
        tax
        lda item_glyph,x
        ldy t3
        sta (scr),y
        lda #C_ITEM
        sta (colp),y
.itd:   ldx t1
.itn:   dex
        bpl .it
        ; monsters within 5 steps
        ldx #MAX_MON-1
.mo:    lda m_type,x
        bmi .mon
        stx t1
        jsr mon_dist            ; A = Chebyshev distance to the player
        cmp #6
        bcs .mod
        ldx t1
        lda m_x,x
        ldy m_y,x
        jsr view_cell
        bcs .mod
        ldx t1
        lda m_type,x
        tax
        lda mon_glyph,x
        ldy t3
        sta (scr),y
        lda #C_MON
        sta (colp),y
.mod:   ldx t1
.mon:   dex
        bpl .mo
        ; player
        lda p_x
        ldy p_y
        jsr view_cell
        ldy t3
        lda #$00                ; "@"
        sta (scr),y
        lda #C_PLAYER
        sta (colp),y
        rts

; A = map x, Y = map y -> carry clear and row pointers set, t3 = column; carry set if off view
!zone view_cell
view_cell:
        sec
        sbc view_x
        bcc .off
        cmp #40
        bcs .off
        sta t3
        tya
        sec
        sbc view_y
        bcc .off
        cmp #VIEW_ROWS
        bcs .off
        clc
        adc #VIEW_TOP
        tax
        jsr row_ptr
        clc
        rts
.off:   sec
        rts

; X = monster -> A = max(|dx|, |dy|) to the player
!zone mon_dist
mon_dist:
        lda m_x,x
        sec
        sbc p_x
        bcs +
        eor #$ff
        adc #1
+       sta t5
        lda m_y,x
        sec
        sbc p_y
        bcs +
        eor #$ff
        adc #1
+       cmp t5
        bcs +
        lda t5
+       rts

; ---------------------------------------------------------------- status bar (row 0, reverse)
!zone draw_status
draw_status:
        lda #$b0
        sta num_or
        ldx #0
        jsr row_ptr
        ldy #39
-       lda #$a0
        sta (scr),y
        lda #C_STAIRS
        sta (colp),y
        dey
        bpl -
        ldy #0
        ldx #0
-       lda p_name,x
        beq +
        ora #$80
        iny
        sta (scr),y
        inx
        cpx #10
        bne -
+       ldy #11
        lda #$c6                ; "F" reversed
        sta (scr),y
        iny
        lda #$8c                ; "l"
        sta (scr),y
        iny
        lda p_floor
        ldx #0
        jsr stat_num
        iny
        lda #$c8                ; "H"
        sta (scr),y
        iny
        lda #$d0                ; "P"
        sta (scr),y
        iny
        lda p_hp
        ldx #0
        jsr stat_num
        lda #$af                ; "/"
        sta (scr),y
        iny
        lda p_maxhp
        ldx #0
        jsr stat_num
        iny
        lda #$cc                ; "L"
        sta (scr),y
        iny
        lda #$96                ; "v"
        sta (scr),y
        iny
        lda p_lvl
        ldx #0
        jsr stat_num
        iny
        lda #$a4                ; "$"
        sta (scr),y
        iny
        lda p_gold
        ldx p_gold+1
        jmp stat_num

; A/X = value, Y = column -> reversed digits written, Y = next column
!zone stat_num
stat_num:
        sty t3
        sta t0
        stx t1
        ldx #4
        lda #0
        sta t4
.d:     lda #0
        sta t2
.s:     lda t0
        sec
        sbc p10_lo,x
        sta t6
        lda t1
        sbc p10_hi,x
        bcs .lbx7_456
        jmp .dig
.lbx7_456:
        sta t1
        lda t6
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
        ora num_or              ; $b0 reversed, $30 plain
        ldy t3
        sta (scr),y
        inc t3
        inc t4
.skip:  dex
        bpl .d
        ldy t3
        rts

!zone tile_glyph
tile_glyph: !byte $a0, $2e, $2b, $25, $3e, $2e, $1e
!zone tile_color
tile_color: !byte C_WALL, C_FLOOR, C_DOOR, 2, C_STAIRS, C_FLOOR, 10
!zone mon_glyph
mon_glyph:  !byte $12, $02, $53, $07, $5a, $13, $4f, $54, $4d, $44
!zone item_glyph
item_glyph: !byte $20, $24, $21, $29, $29, $29, $29, $1b, $1b, $1b, $1b, $2d, $3f, $0f, $2a, $22
