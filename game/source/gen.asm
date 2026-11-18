; gen.asm - deterministic dungeon generation (docs/GAME_DESIGN.md section 3).
; Same seed + floor -> same floor. Uses $6000-$6fff as BFS queue (engine buffers,
; idle while a floor is generated).

QX       = $6000            ; BFS queue x (2048)
QY       = $6800            ; BFS queue y
g_try    = $c9c0
g_w      = $c9c1
g_h      = $c9c2
g_x      = $c9c3
g_y      = $c9c4
g_i      = $c9c5
q_head   = $c9c6            ; 2
q_tail   = $c9c8            ; 2
g_cnt    = $c9ca            ; 2
g_k      = $c9cc            ; 2
g_r      = $c9ce            ; current room
g_ax     = $c9cf
g_bx     = $c9d0
g_ay     = $c9d1
g_by     = $c9d2
g_cx     = $c9d3
g_cy     = $c9d4

; ---------------------------------------------------------------- random numbers
!zone rnd
rnd:                            ; 16-bit xorshift (7, 9, 8) -> A = rng_hi
        lda rng_hi
        lsr
        lda rng_lo
        ror
        eor rng_hi
        sta rng_hi
        ror
        eor rng_lo
        sta rng_lo
        eor rng_hi
        sta rng_hi
        rts

!zone rnd_mod
rnd_mod:                        ; A = n (1..255) -> A = random 0..n-1. X, Y preserved.
        sta t6
        txa
        pha
        jsr rnd
        tax
        pla
        sta t7
        txa
-       cmp t6
        bcc +
        sec
        sbc t6
        jmp -
+       ldx t7
        rts

; ---------------------------------------------------------------- floor
!zone gen_floor
gen_floor:
        lda seed
        eor p_floor
        sta rng_lo
        lda p_floor
        asl
        asl
        asl
        asl
        eor seed+1
        ora #1
        sta rng_hi
        ; warm up the generator
        ldx #8
-       jsr rnd
        dex
        bne -
.again:
        ; clear map, monsters, items, rooms
        lda #<MAP
        sta mp
        lda #>MAP
        sta mp+1
        ldx #8
        ldy #0
        lda #T_WALL
-       sta (mp),y
        iny
        bne -
        inc mp+1
        dex
        bne -
        ldx #MAX_MON-1
        lda #$ff
-       sta m_type,x
        dex
        bpl -
        ldx #MAX_ITEM-1
        lda #0
-       sta i_type,x
        dex
        bpl -
        ldx #MAX_ROOMS-1
-       sta r_seen,x
        dex
        bpl -
        sta n_rooms
        lda #60
        sta g_try
        ; ---------------- rooms
.room:  lda n_rooms
        cmp #MAX_ROOMS
        bne +
        jmp .rooms_done
+       dec g_try
        bne +
        jmp .rooms_done
+       lda #8
        jsr rnd_mod
        clc
        adc #4
        sta g_w
        lda #4
        jsr rnd_mod
        clc
        adc #3
        sta g_h
        lda #62
        sec
        sbc g_w
        jsr rnd_mod
        clc
        adc #1
        sta g_x
        lda #30
        sec
        sbc g_h
        jsr rnd_mod
        clc
        adc #1
        sta g_y
        ; overlap test with a 1-tile margin
        ldx #0
.ov:    cpx n_rooms
        beq .place
        ; x < rx + rw + 2 ?
        lda r_x,x
        clc
        adc r_w,x
        adc #2
        sta t0
        lda g_x
        cmp t0
        bcs .ov_next
        ; rx < x + w + 2 ?
        lda g_x
        clc
        adc g_w
        adc #2
        sta t0
        lda r_x,x
        cmp t0
        bcs .ov_next
        lda r_y,x
        clc
        adc r_h,x
        adc #2
        sta t0
        lda g_y
        cmp t0
        bcs .ov_next
        lda g_y
        clc
        adc g_h
        adc #2
        sta t0
        lda r_y,x
        cmp t0
        bcs .ov_next
        jmp .room               ; overlaps
.ov_next:
        inx
        bne .ov
.place: ldx n_rooms
        lda g_x
        sta r_x,x
        lda g_y
        sta r_y,x
        lda g_w
        sta r_w,x
        lda g_h
        sta r_h,x
        inc n_rooms
        ; carve
        ldy g_y
.cy:    ldx g_x
.cx:    lda #T_FLOOR
        jsr tile_set
        inx
        txa
        sec
        sbc g_x
        cmp g_w
        bne .cx
        iny
        tya
        sec
        sbc g_y
        cmp g_h
        bne .cy
        jmp .room
.rooms_done:
        lda n_rooms
        cmp #3
        bcs +
        jmp .again
+       ; ---------------- corridors between consecutive rooms
        lda #1
        sta g_i
.corr:  lda g_i
        cmp n_rooms
        bne +
        jmp .corr_done
+       tax
        jsr room_center         ; -> g_cx, g_cy
        lda g_cx
        sta g_bx
        lda g_cy
        sta g_by
        dex
        jsr room_center
        lda g_cx
        sta g_ax
        lda g_cy
        sta g_ay
        jsr rnd
        and #1
        beq .vh
        ; horizontal at ay, then vertical at bx
        lda g_ay
        sta g_cy
        jsr .hline
        lda g_bx
        sta g_cx
        jsr .vline
        jmp .cn
.vh:    lda g_ax
        sta g_cx
        jsr .vline
        lda g_by
        sta g_cy
        jsr .hline
.cn:    inc g_i
        jmp .corr
.hline:                         ; ax..bx at row g_cy
        ldx g_ax
        lda g_bx
        sta t0
        cpx t0
        bcc .hl
        ldx g_bx
        lda g_ax
        sta t0
.hl:    ldy g_cy
        jsr carve_corr
        cpx t0
        beq +
        inx
        bne .hl
+       rts
.vline:                         ; ay..by at column g_cx
        ldy g_ay
        lda g_by
        sta t0
        cpy t0
        bcc .vl
        ldy g_by
        lda g_ay
        sta t0
.vl:    ldx g_cx
        jsr carve_corr
        cpy t0
        beq +
        iny
        bne .vl
+       rts
.corr_done:
        ; ---------------- doors on room rings (1 in 3)
        ldx #0
.dr:    cpx n_rooms
        beq .doors_done
        stx g_r
        jsr ring_begin
.ring:  jsr ring_next
        bcs .rnext
        jsr tile_at
        and #$1f
        cmp #T_FLOOR
        bne .ring
        lda #3
        jsr rnd_mod
        bne .ring
        lda #T_DOOR
        jsr tile_set
        jmp .ring
.rnext: ldx g_r
        inx
        bne .dr
.doors_done:
        ; ---------------- room types
        lda #R_HALL
        sta r_type
        ldx #1
-       cpx n_rooms
        beq +
        lda #11
        jsr rnd_mod
        sta r_type,x
        inx
        bne -
+       ldx n_rooms
        dex
        stx g_r
        lda p_floor
        cmp #LAST_FLOOR
        beq .boss
        lda #R_STAIRS
        sta r_type,x
        jsr room_center
        ldx g_cx
        ldy g_cy
        lda #T_STAIRS
        jsr tile_set
        jmp .locks
.boss:  lda #R_BOSS
        sta r_type,x
        jsr room_center
        ldx g_cx
        ldy g_cy
        lda #I_AMULET
        jsr place_item
        ldx g_cx
        inx
        ldy g_cy
        lda #M_DRAGON
        jsr place_mon
.locks: ; ---------------- floors 2+: the last room's entrances are locked
        lda p_floor
        cmp #2
        bcc .start
        ldx g_r
        jsr ring_begin
-       jsr ring_next
        bcs .start
        jsr tile_at
        and #$1f
        beq -                   ; wall
        lda #T_LOCKED
        jsr tile_set
        jmp -
.start: ; player starts in the middle of room 0
        ldx #0
        jsr room_center
        lda g_cx
        sta p_x
        lda g_cy
        sta p_y
        ; ---------------- contents
        lda #1
        sta g_r
.cont:  lda g_r
        cmp n_rooms
        bne +
        jmp .cont_done
+       tax
        lda r_type,x
        cmp #R_TREASURE
        bne +
        lda #I_GOLD
        jsr room_item
        lda #I_GEM
        jsr room_item
        jmp .mon
+       cmp #R_ARMORY
        bne +
        lda #8
        jsr rnd_mod
        tax
        lda armory_items,x
        jsr room_item
        jmp .mon
+       cmp #R_LIBRARY
        bne +
        lda #I_SCROLL
        jsr room_item
        jmp .mon
+       cmp #R_MAGIC
        bne +
        jsr rnd
        and #1
        clc
        adc #I_POTION           ; potion, or ...
        cmp #I_POTION
        beq ++
        lda #I_RING             ; ... ring
++      jsr room_item
        jmp .mon
+       cmp #R_SHRINE
        bne +
        lda #I_POTION
        jsr room_item
        jmp .mon
+       cmp #R_TRAP
        bne +
        lda #3
        sta tmp_cnt
-       jsr room_point
        bcs ++
        lda #T_TRAP
        jsr tile_set
++      dec tmp_cnt
        bne -
        jmp .mon
+       cmp #R_LAIR
        bne .mon
        jsr room_monster
        jsr room_monster
.mon:   ldx g_r
        lda r_type,x
        cmp #R_BOSS
        beq .cnext
        jsr rnd
        bmi +
        jsr room_monster
+       lda #10
        jsr rnd_mod
        cmp #3
        bcs .cnext
        lda #I_GOLD
        jsr room_item
.cnext: inc g_r
        jmp .cont
.cont_done:
        ; one potion somewhere
        lda n_rooms
        sec
        sbc #1
        jsr rnd_mod
        clc
        adc #1
        sta g_r
        lda #I_POTION
        jsr room_item
        ; ---------------- key for the locked doors (floors 2+)
        lda p_floor
        cmp #2
        bcc .done
        jsr place_key
.done:  rts

!zone armory_items
armory_items: !byte I_SWORD, I_AXE, I_MACE, I_LEATHER, I_CHAIN, I_SHIELD, I_HELM, I_SWORD

; X = room -> g_cx, g_cy (centre). X preserved.
!zone room_center
room_center:
        lda r_w,x
        lsr
        clc
        adc r_x,x
        sta g_cx
        lda r_h,x
        lsr
        clc
        adc r_y,x
        sta g_cy
        rts

; turn a wall into floor (corridors never overwrite doors or rooms). X, Y preserved.
!zone carve_corr
carve_corr:
        jsr tile_at
        and #$1f
        bne +
        lda #T_FLOOR
        jsr tile_set
+       rts

; ring walk around room g_r (outside the interior, corners excluded)
; ring_begin; then ring_next -> carry clear with X, Y = next ring tile, carry set at end
!zone ring_begin
ring_begin:
        lda #0
        sta g_k                 ; side 0 top, 1 bottom, 2 left, 3 right
        sta g_k+1               ; position along the side
        rts
!zone ring_next
ring_next:
        ldx g_r
        lda g_k
        cmp #2
        bcs .sides
        ; top / bottom: x = rx + pos, pos < rw
        lda g_k+1
        cmp r_w,x
        bcc +
        inc g_k
        lda #0
        sta g_k+1
        jmp ring_next
+       clc
        adc r_x,x
        sta t0
        lda g_k
        beq .top
        lda r_y,x
        clc
        adc r_h,x
        jmp .ty
.top:   lda r_y,x
        sec
        sbc #1
.ty:    tay
        ldx t0
        inc g_k+1
        clc
        rts
.sides: cmp #4
        bcc +
        sec
        rts
+       lda g_k+1
        cmp r_h,x
        bcc +
        inc g_k
        lda #0
        sta g_k+1
        jmp ring_next
+       clc
        adc r_y,x
        tay
        lda g_k
        cmp #2
        beq .left
        lda r_x,x
        clc
        adc r_w,x
        jmp .tx
.left:  lda r_x,x
        sec
        sbc #1
.tx:    tax
        inc g_k+1
        clc
        rts

; random free floor point in room g_r -> carry clear, X, Y; carry set if none found
!zone room_point
room_point:
        lda #12
        sta t3
.p:     ldx g_r
        lda r_w,x
        jsr rnd_mod
        clc
        adc r_x,x
        sta t1
        lda r_h,x
        jsr rnd_mod
        clc
        adc r_y,x
        tay
        ldx t1
        jsr tile_at
        and #$1f
        cmp #T_FLOOR
        bne .no
        cpx p_x
        bne +
        cpy p_y
        beq .no
+       jsr item_at_xy
        bcc .no
        jsr mon_at_xy
        bcc .no
        clc
        rts
.no:    dec t3
        bne .p
        sec
        rts

!zone room_item
room_item:                      ; A = item type, placed in room g_r
        pha
        jsr room_point
        pla
        bcs +
        jmp place_item
+       rts
!zone room_monster
room_monster:                   ; a floor-appropriate monster in room g_r
        jsr room_point
        bcs +
        stx t1
        lda p_floor
        sec
        sbc #1
        asl
        asl
        sta t2
        lda #4
        jsr rnd_mod
        clc
        adc t2
        tax
        lda floor_mon,x
        ldx t1
        jmp place_mon
+       rts

!zone place_item
place_item:                     ; A = type, X, Y = position
        sta t2
        stx t1
        ldx #0
-       lda i_type,x
        beq +
        inx
        cpx #MAX_ITEM
        bne -
        ldx t1
        rts
+       lda t2
        sta i_type,x
        lda t1
        sta i_x,x
        tya
        sta i_y,x
        ldx t1
        rts

!zone place_mon
place_mon:                      ; A = type, X, Y = position
        sta t2
        stx t1
        ldx #0
-       lda m_type,x
        bmi +
        inx
        cpx #MAX_MON
        bne -
        ldx t1
        rts
+       lda t2
        sta m_type,x
        lda t1
        sta m_x,x
        tya
        sta m_y,x
        sty t0
        ldy t2
        lda mon_hp,y
        sta m_hp,x
        lda #0
        sta mon_flags,x
        ldy t0
        ldx t1
        rts

; X, Y -> carry clear + A = index if an item lies there, else carry set. X, Y kept.
!zone item_at_xy
item_at_xy:
        stx t6
        sty t7
        ldx #0
-       lda i_type,x
        beq +
        lda i_x,x
        cmp t6
        bne +
        lda i_y,x
        cmp t7
        bne +
        txa
        ldx t6
        clc
        rts
+       inx
        cpx #MAX_ITEM
        bne -
        ldx t6
        sec
        rts

; X, Y -> carry clear + A = index if a monster stands there, else carry set. X, Y kept.
!zone mon_at_xy
mon_at_xy:
        stx t6
        sty t7
        ldx #0
-       lda m_type,x
        bmi +
        lda m_x,x
        cmp t6
        bne +
        lda m_y,x
        cmp t7
        bne +
        txa
        ldx t6
        clc
        rts
+       inx
        cpx #MAX_MON
        bne -
        ldx t6
        sec
        rts

; ---------------------------------------------------------------- key placement
; BFS from the player, locked doors and walls block; bit 6 marks reachable tiles.
; The key goes on a random reachable floor tile without an item.
!zone place_key
place_key:
        jsr bfs
        ; count candidates
        lda #0
        sta g_cnt
        sta g_cnt+1
        jsr .scan_count
        lda g_cnt
        ora g_cnt+1
        bne +
        rts                     ; nowhere (cannot happen: room 0 is reachable)
+       ; k = rnd16 mod count
        jsr rnd
        sta g_k
        jsr rnd
        and #$7f
        sta g_k+1
-       lda g_k
        sec
        sbc g_cnt
        tax
        lda g_k+1
        sbc g_cnt+1
        bcc +
        sta g_k+1
        stx g_k
        jmp -
+       ; find the k-th candidate
        ldy #0
.ky:    ldx #0
.kx:    jsr .cand
        bcs .knext
        lda g_k
        ora g_k+1
        bne +
        lda #I_KEY
        jmp place_item
+       lda g_k
        bne +
        dec g_k+1
+       dec g_k
.knext: inx
        cpx #MAPW
        bne .kx
        iny
        cpy #MAPH
        bne .ky
        rts
.scan_count:
        ldy #0
.cy:    ldx #0
.cx:    jsr .cand
        bcs +
        inc g_cnt
        bne +
        inc g_cnt+1
+       inx
        cpx #MAPW
        bne .cx
        iny
        cpy #MAPH
        bne .cy
        rts
.cand:                          ; X, Y candidate? carry clear if yes
        jsr tile_at
        and #$5f
        cmp #$40 | T_FLOOR      ; reachable floor
        bne .notc
        cpx p_x
        bne +
        cpy p_y
        beq .notc
+       jsr item_at_xy
        bcc .notc
        clc
        rts
.notc:  sec
        rts

!zone bfs
bfs:
        ; clear bit 6 everywhere
        lda #<MAP
        sta mp
        lda #>MAP
        sta mp+1
        ldx #8
        ldy #0
-       lda (mp),y
        and #$bf
        sta (mp),y
        iny
        bne -
        inc mp+1
        dex
        bne -
        lda #0
        sta q_head
        sta q_head+1
        sta q_tail
        sta q_tail+1
        ldx p_x
        ldy p_y
        jsr .visit
.loop:  lda q_head
        cmp q_tail
        bne .pop
        lda q_head+1
        cmp q_tail+1
        bne .pop
        rts
.pop:   lda q_head
        sta ptr
        lda q_head+1
        clc
        adc #>QX
        sta ptr+1
        ldy #0
        lda (ptr),y
        sta g_cx
        lda ptr+1
        clc
        adc #>(QY - QX)
        sta ptr+1
        lda (ptr),y
        sta g_cy
        inc q_head
        bne +
        inc q_head+1
+       ldx g_cx
        ldy g_cy
        dex
        jsr .visit
        inx
        inx
        jsr .visit
        dex
        dey
        jsr .visit
        iny
        iny
        jsr .visit
        jmp .loop
.visit:                         ; X, Y: mark and enqueue if passable and new
        jsr tile_at
        and #$1f
        beq .vx                 ; wall
        cmp #T_LOCKED
        beq .vx
        jsr map_addr
        sty t4
        ldy #0
        lda (mp),y
        and #$40
        bne .vy
        lda (mp),y
        ora #$40
        sta (mp),y
        lda q_tail
        sta ptr
        lda q_tail+1
        clc
        adc #>QX
        sta ptr+1
        txa
        sta (ptr),y
        lda ptr+1
        clc
        adc #>(QY - QX)
        sta ptr+1
        lda t4
        sta (ptr),y
        inc q_tail
        bne .vy
        inc q_tail+1
.vy:    ldy t4
.vx:    rts
