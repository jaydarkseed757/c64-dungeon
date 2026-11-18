; rules.asm - player actions, monsters, combat, items (docs/GAME_DESIGN.md section 4).
; Every narrated outcome goes through dm_begin/dm_tok/dm_end, then fallback text.

EV_QUEST = 1
EV_FLOOR = 2
EV_ROOM = 3
EV_SEEN = 4
EV_ATTACK = 5
EV_HURT = 6
EV_ITEM = 7
EV_DOOR = 8
EV_TRAP = 9
EV_DRINK = 10
EV_REST = 11

; ---------------------------------------------------------------- movement / attack
!zone act_move
act_move:                       ; A = dx, X = dy (as signed bytes)
        clc
        adc p_x
        sta new_x
        txa
        clc
        adc p_y
        sta new_y
        ldx new_x
        ldy new_y
        jsr mon_at_xy
        bcs +
        sta target
        jsr player_attack
        jmp end_turn
+       jsr tile_at
        and #$1f
        bne +
        rts                     ; wall: no turn
+       cmp #T_LOCKED
        beq .lbx3_38
        jmp .walk
.lbx3_38:
        ; locked: a key opens it
        ldx #I_KEY
        jsr inv_find
        bcc .unlock
        lda #EV_DOOR
        ldx #TOK_TASK_ACTION
        jsr dm_begin
        lda #TOK_OBJ_DOOR
        jsr dm_tok
        lda #TOK_ACT_OPEN
        jsr dm_tok
        lda #TOK_OUT_LOCKED
        jsr dm_tok
        jsr dm_end
        bcs .lk_ai
        jsr say
        !scr "The door is locked. You need a key.", 0
.lk_ai: rts
.unlock:
        lda #0
        sta p_inv,x
        ldx new_x
        ldy new_y
        lda #T_DOOR
        jsr tile_set
        lda #EV_DOOR
        ldx #TOK_TASK_ACTION
        jsr dm_begin
        lda #TOK_OBJ_DOOR
        jsr dm_tok
        lda #TOK_ITEM_KEY
        jsr dm_tok
        lda #TOK_ACT_USE
        jsr dm_tok
        lda #TOK_OUT_SUCCESS
        jsr dm_tok
        jsr dm_end
        bcs .ul_ai
        jsr say
        !scr "The key turns. The door swings open.", 0
.ul_ai: jmp end_turn
.walk:  lda new_x
        sta p_x
        lda new_y
        sta p_y
        ; hidden trap?
        ldx p_x
        ldy p_y
        jsr tile_at
        and #$1f
        cmp #T_TRAP
        bne .items
        lda #T_TRAPV
        jsr tile_set
        lda #4
        jsr rnd_mod
        clc
        adc #1
        sta dmg
        lda #EV_TRAP
        ldx #TOK_TASK_ACTION
        jsr dm_begin
        lda #TOK_ACT_SEARCH
        jsr dm_tok
        lda #TOK_OUT_TRAP
        jsr dm_tok
        jsr dm_end
        bcs .tr_ai
        jsr say
        !scr "A trap springs! You take ", 0
        lda dmg
        jsr say_num
        jsr say
        !scr " damage.", 0
        jmp .tr_hp
.tr_ai: jsr num_minus_hp
.tr_hp: jsr hurt_player
.items: ldx p_x
        ldy p_y
        jsr item_at_xy
        bcs +
        tax
        lda i_type,x
        tax
        jsr log_para
        lda #C_SYS
        sta color
        jsr say
        !scr "You see ", 0
        lda #0
        sta t7
        +say_a item_lo, item_hi
        jsr say
        !scr " here (G to take).", 0
        lda #C_TEXT
        sta color
+       jsr check_room
        jmp end_turn

; ---------------------------------------------------------------- turn end
!zone end_turn
end_turn:
        inc turns
        bne +
        inc turns+1
+       jsr monsters_act
        jsr reveal
        jsr draw_all
        lda p_hp
        bne +
        lda #2
        sta gstate
+       rts

; ---------------------------------------------------------------- combat
!zone player_attack
player_attack:                  ; target = monster index
        ldx target
        ; d20
        lda #20
        jsr rnd_mod
        clc
        adc #1
        sta roll
        clc
        adc p_str
        sta t0
        ldx target
        ldy m_type,x
        lda mon_def,y
        clc
        adc #10
        sta t1
        lda t0
        cmp t1
        bcs .hit
        ; miss
        lda #TOK_OUT_MISS
        jsr .record
        jsr say
        !scr "You miss the ", 0
        jsr say_target
        jsr say
        !scr ".", 0
        rts
.hit:   ; damage = weapon roll + STR/2, doubled on a critical
        ldx p_weapon
        lda wpn_max,x
        sec
        sbc wpn_min,x
        clc
        adc #1
        jsr rnd_mod
        clc
        ldx p_weapon
        adc wpn_min,x
        sta dmg
        lda p_str
        lsr
        clc
        adc dmg
        sta dmg
        lda #0
        sta t2                  ; critical flag
        lda roll
        cmp #20
        beq .crit
        cmp #19
        bne .apply
        lda p_cls
        cmp #1                  ; rogue
        bne .apply
.crit:  asl dmg
        inc t2
.apply: ldx target
        lda m_hp,x
        sec
        sbc dmg
        bcc .kill
        beq .kill
        sta m_hp,x
        lda t2
        beq +
        lda #TOK_OUT_CRIT
        jsr .record
        jsr say
        !scr "A critical hit! The ", 0
        jsr say_target
        jsr say
        !scr " takes ", 0
        lda dmg
        jsr say_num
        jsr say
        !scr ".", 0
        rts
+       lda #TOK_OUT_HIT
        jsr .record
        jsr say
        !scr "You hit the ", 0
        jsr say_target
        jsr say
        !scr " for ", 0
        lda dmg
        jsr say_num
        jsr say
        !scr ".", 0
        rts
.kill:  ldx target
        lda #0
        sta m_hp,x
        lda #TOK_OUT_KILLED
        jsr .record
        bcs .kill_ai
        jsr say
        !scr "You slay the ", 0
        jsr say_target
        jsr say
        !scr "! ", 0
        jmp .kill_xp
.kill_ai:                       ; the narrator described it: the game adds the numbers
        lda #C_SYS
        sta color
        jsr say
        !scr "+", 0
.kill_xp:
        ldx target
        ldy m_type,x
        lda #$ff
        sta m_type,x
        inc p_kills
        bne +
        inc p_kills+1
+       lda mon_xp,y
        pha
        clc
        adc p_xp
        sta p_xp
        bcc +
        inc p_xp+1
+       pla
        jsr say_num
        jsr say
        !scr " XP.", 0
        ; 40% gold drop
        lda #10
        jsr rnd_mod
        cmp #4
        bcs +
        lda #8
        jsr rnd_mod
        clc
        adc #1
        ldx p_floor
-       dex
        beq ++
        clc
        adc #2
        bne -
++      sta dmg
        jsr add_gold
        jsr say
        !scr " It carried ", 0
        lda dmg
        jsr say_num
        jsr say
        !scr " gold.", 0
+       lda #C_TEXT
        sta color
        jmp check_level

; context record for an attack: A = OUT token
; order: TASK:COMBAT MON MST ACT:ATTACK OUT HP (no MST on a miss)
.record:
        sta rec_out
        lda #EV_ATTACK
        ldx #TOK_TASK_COMBAT
        jsr dm_begin
        ldx target
        ldy m_type,x
        lda mon_tok,y
        jsr dm_tok
        lda rec_out
        cmp #TOK_OUT_MISS
        beq .nomst
        cmp #TOK_OUT_KILLED
        bne .alive
        lda #TOK_MST_DEAD
        jmp .mst
.alive: jsr mon_state_tok
.mst:   jsr dm_tok
.nomst: lda #TOK_ACT_ATTACK
        jsr dm_tok
        lda rec_out
        jsr dm_tok
        jsr hp_tok
        jsr dm_tok
        jmp dm_end

!zone say_target
say_target:                     ; name of the monster being fought (before removal)
        ldx target
        lda m_type,x
        tax
        +say_name mon_lo, mon_hi
        rts

; monster health band of target -> A = MST token (after damage)
!zone mon_state_tok
mon_state_tok:
        ldx target
        ldy m_type,x
        lda m_hp,x
        cmp mon_hp,y
        bcc +
        lda #TOK_MST_HEALTHY
        rts
+       sta t0                  ; hp*3 <= max -> dying
        asl
        clc
        adc t0
        cmp mon_hp,y
        beq +
        bcs ++
+       lda #TOK_MST_DYING
        rts
++      lda #TOK_MST_WOUNDED
        rts

!zone hp_tok
hp_tok:                         ; player health band -> A = HP token
        lda p_hp
        sta t0
        asl
        clc
        adc t0                  ; 3*hp
        sta t0
        lda p_maxhp
        asl                     ; 2*max
        cmp t0
        bcs +
        lda #TOK_HP_HIGH        ; 3hp > 2max
        rts
+       lda t0
        cmp p_maxhp
        bcs +
        lda #TOK_HP_LOW         ; 3hp < max
        rts
+       lda #TOK_HP_MID
        rts

!zone armor_total
armor_total:                    ; -> A = armor bonus from worn items and rings (uses t4 only)
        lda #0
        sta t4
        lda p_worn
        lsr
        bcc +
        inc t4                  ; leather 1
+       lsr
        bcc +
        inc t4
        inc t4                  ; chain 2
+       lsr
        bcc +
        inc t4                  ; shield 1
+       lsr
        bcc +
        inc t4                  ; helm 1
+       lda t4
        clc
        adc p_ring
        rts

; monster X attacks the player
!zone monster_attack
monster_attack:
        stx target
        lda #20
        jsr rnd_mod
        clc
        adc #1
        ldx target
        ldy m_type,x
        clc
        adc mon_atk,y
        sta t0
        jsr armor_total
        sta t1
        clc
        adc p_def
        adc #10
        sta t2
        lda t0
        cmp t2
        bcs .hit
        jsr log_para
        lda #C_SYS
        sta color
        jsr say
        !scr "The ", 0
        jsr say_target
        jsr say
        !scr " misses you.", 0
        lda #C_TEXT
        sta color
        rts
.hit:   ldx target
        ldy m_type,x
        lda mon_dmax,y
        sec
        sbc mon_dmin,y
        clc
        adc #1
        jsr rnd_mod
        clc
        ldx target
        ldy m_type,x
        adc mon_dmin,y
        sta dmg
        lda t1
        lsr
        sta t1
        lda dmg
        sec
        sbc t1
        beq +
        bcs ++
+       lda #1
++      sta dmg
        lda #EV_HURT
        ldx #TOK_TASK_COMBAT
        jsr dm_begin
        ldx target
        ldy m_type,x
        lda mon_tok,y
        jsr dm_tok
        lda #TOK_ACT_ATTACK
        jsr dm_tok
        lda #TOK_OUT_HURT
        jsr dm_tok
        jsr hurt_player         ; HP band after the blow
        jsr hp_tok
        jsr dm_tok
        jsr dm_end
        lda #10
        sta color
        jsr say
        !scr "The ", 0
        jsr say_target
        jsr say
        !scr " hits you for ", 0
        lda dmg
        jsr say_num
        jsr say
        !scr ".", 0
        lda #C_TEXT
        sta color
        rts

!zone hurt_player
hurt_player:                    ; p_hp -= dmg (floor 0)
        lda p_hp
        sec
        sbc dmg
        bcs +
        lda #0
+       sta p_hp
        bne +
        lda #2
        sta gstate
+       rts

!zone add_gold
add_gold:                       ; dmg = amount
        lda p_gold
        clc
        adc dmg
        sta p_gold
        bcc +
        inc p_gold+1
+       rts

!zone check_level
check_level:
        ldx p_lvl
        dex                     ; level 1 needs lvl_xp[0]
        lda p_xp+1
        cmp lvl_xp_hi,x
        bcc .no
        bne .up
        lda p_xp
        cmp lvl_xp_lo,x
        bcc .no
.up:    inc p_lvl
        lda p_maxhp
        clc
        adc #6
        sta p_maxhp
        lda p_hp
        clc
        adc #6
        sta p_hp
        inc p_str
        lda p_lvl
        and #1
        bne +
        inc p_def
+       jsr log_para
        lda #7
        sta color
        jsr say
        !scr "You feel stronger! You reach level ", 0
        lda p_lvl
        jsr say_num
        jsr say
        !scr ".", 0
        lda #C_TEXT
        sta color
        jmp check_level
.no:    rts

; ---------------------------------------------------------------- monsters
!zone monsters_act
monsters_act:
        ldx #0
.m:     stx g_i
        lda m_type,x
        bmi .next
        lda gstate
        cmp #1
        bne .next
        jsr mon_dist
        sta t3
        cmp #1
        bne +
        ldx g_i
        jsr monster_attack
        jmp .next
+       cmp #7
        bcs .next
        ldx g_i
        jsr mon_step
.next:  ldx g_i
        ; announce monsters coming into view
        lda m_type,x
        bmi +
        lda mon_flags,x
        and #1
        bne +
        jsr mon_dist
        cmp #6
        bcs +
        ldx g_i
        jsr ev_seen
+       ldx g_i
        inx
        cpx #MAX_MON
        bne .m
        rts

!zone mon_step
mon_step:                       ; X = monster: step toward the player if possible
        stx target
        lda p_x
        sec
        sbc m_x,x
        jsr sign
        sta t0                  ; dx
        lda p_y
        sec
        sbc m_y,x
        jsr sign
        sta t1                  ; dy
        jsr .try                ; diagonal
        bcc .ok
        lda t1
        pha
        lda #0
        sta t1
        jsr .try                ; horizontal
        pla
        sta t1
        bcc .ok
        lda t0
        pha
        lda #0
        sta t0
        jsr .try                ; vertical
        pla
        sta t0
.ok:    rts
.try:   ldx target
        lda m_x,x
        clc
        adc t0
        sta t2
        lda m_y,x
        clc
        adc t1
        tay
        ldx t2
        cpx p_x
        bne +
        cpy p_y
        beq .no
+       jsr tile_at
        and #$1f
        beq .no
        cmp #T_LOCKED
        beq .no
        jsr mon_at_xy
        bcc .no
        ldx target
        lda t2
        sta m_x,x
        tya
        sta m_y,x
        clc
        rts
.no:    sec
        rts

!zone sign
sign:                           ; A = difference -> -1, 0, 1
        beq +
        bmi ++
        lda #1
+       rts
++      lda #$ff
        rts

; ---------------------------------------------------------------- items
!zone act_get
act_get:
        ldx p_x
        ldy p_y
        jsr item_at_xy
        bcc +
        jsr log_para
        jsr say
        !scr "There is nothing here.", 0
        rts
+       sta t3                  ; item slot
        tax
        lda i_type,x
        sta t2
        cmp #I_GOLD
        beq .gold
        cmp #I_GEM
        bne .lbx2_673
        jmp .gem
.lbx2_673:
        cmp #I_AMULET
        bne .lbx1_675
        jmp .amulet
.lbx1_675:
        ; into the pack
        ldx #0
        jsr inv_find_free
        bcc +
        jsr log_para
        jsr say
        !scr "Your pack is full.", 0
        rts
+       lda t2
        sta p_inv,x
        jsr .event
        bcc .lbx1_708
        jmp .taken
.lbx1_708:
        jsr say
        !scr "You pick up ", 0
        ldx t2
        lda #0
        sta t7
        +say_a item_lo, item_hi
        jsr say
        !scr ".", 0
        jmp .taken
.gold:  lda p_floor
        asl
        asl
        jsr rnd_mod
        clc
        adc #3
        sta dmg
        jsr add_gold
        jsr .event
        bcs .gold_ai
        jsr say
        !scr "You pick up ", 0
        lda dmg
        jsr say_num
        jsr say
        !scr " gold.", 0
        jmp .taken
.gold_ai:
        jsr num_plus_gold
        jmp .taken
.gem:   lda #25
        sta dmg
        jsr add_gold
        jsr .event
        bcs .gold_ai
        jsr say
        !scr "You pick up a gem worth 25 gold.", 0
        jmp .taken
.amulet:
        jsr .event
        bcs .am_ai
        jsr say
        !scr "You lift the Amulet of Dawn. Its light fills the hall!", 0
.am_ai: lda #3
        sta gstate
.taken: ldx t3
        lda #0
        sta i_type,x
        jmp end_turn
.event: lda #EV_ITEM
        ldx #TOK_TASK_TREASURE
        jsr dm_begin
        ldx t2
        lda item_tok,x
        jsr dm_tok
        lda #TOK_OUT_FOUND
        jsr dm_tok
        jmp dm_end

!zone inv_find
inv_find:                       ; X = item type -> carry clear, X = slot if carried
        stx t0
        ldx #0
-       lda p_inv,x
        cmp t0
        beq +
        inx
        cpx #MAX_INV
        bne -
        sec
        rts
+       clc
        rts
!zone inv_find_free
inv_find_free:
        ldx #0
        jmp inv_find

; ---------------------------------------------------------------- inventory
!zone inventory
inventory:
        jsr clear_view
        ldx #2
        jsr row_ptr
        ldy #2
        jsr say_at
        !scr "Your pack (1-8 use, any other key closes)", 0
        lda #0
        sta t3
.l:     lda t3
        clc
        adc #4
        tax
        jsr row_ptr
        lda t3
        clc
        adc #$31
        ldy #3
        sta (scr),y
        iny
        lda #$2e
        sta (scr),y
        ldx t3
        lda p_inv,x
        beq .empty
        tax
        lda item_lo,x
        sta ptr
        lda item_hi,x
        sta ptr+1
        ldy #0
-       lda (ptr),y
        beq .empty
        sty t4
        pha
        tya
        clc
        adc #6
        tay
        pla
        sta (scr),y
        ldy t4
        iny
        bne -
.empty: inc t3
        lda t3
        cmp #MAX_INV
        bne .l
        ; weapon line
        ldx #13
        jsr row_ptr
        ldy #3
        jsr say_at
        !scr "Weapon:", 0
        ldx p_weapon
        lda item_lo,x
        sta ptr
        lda item_hi,x
        sta ptr+1
        ldy #0
-       lda (ptr),y
        beq +
        pha
        tya
        clc
        adc #11
        sty t4
        tay
        pla
        sta (scr),y
        ldy t4
        iny
        bne -
+
-       jsr GETIN
        beq -
        cmp #$31
        bcc .close
        cmp #$39
        bcs .close
        sec
        sbc #$31
        tax
        lda p_inv,x
        beq .close
        stx t3
        jsr use_item
.close: jmp draw_view

!zone use_item
use_item:                       ; X = slot t3
        lda p_inv,x
        cmp #I_POTION
        bne +
        lda #8
        jsr rnd_mod
        clc
        adc #8
        sta dmg
        lda p_hp
        clc
        adc dmg
        cmp p_maxhp
        bcc ++
        lda p_maxhp
++      sta p_hp
        jsr .consume
        lda #EV_DRINK
        ldx #TOK_TASK_ACTION
        jsr dm_begin
        lda #TOK_ACT_DRINK
        jsr dm_tok
        lda #TOK_OUT_SUCCESS
        jsr dm_tok
        jsr dm_end
        jsr say
        !scr "You drink the potion. Warmth spreads through you.", 0
        jmp draw_status
+       cmp #I_LEATHER
        bcs +
        cmp #I_DAGGER
        bcc +
        ; weapons: swap with the one in hand
        ldx t3
        lda p_weapon
        pha
        lda p_inv,x
        sta p_weapon
        pla
        sta p_inv,x
        jsr log_para
        jsr say
        !scr "You wield the ", 0
        ldx p_weapon
        +say_name item_lo, item_hi
        jsr say
        !scr ".", 0
        rts
+       cmp #I_KEY
        bcs +
        ; armor: wear it (bit = type - I_LEATHER)
        sec
        sbc #I_LEATHER
        tax
        lda bit_tab,x
        ora p_worn
        sta p_worn
        jsr .consume
        jsr log_para
        jsr say
        !scr "You put it on. You feel safer.", 0
        rts
+       cmp #I_SCROLL
        bne +
        jsr .consume
        jsr reveal_all
        jsr log_para
        jsr say
        !scr "The scroll crumbles. The level's map burns into your mind.", 0
        rts
+       cmp #I_RING
        bne +
        jsr .consume
        inc p_ring
        jsr log_para
        jsr say
        !scr "You slip on the ring. It hums softly.", 0
        rts
+       jsr log_para
        jsr say
        !scr "Keys open locked doors when you walk into them.", 0
        rts
.consume:
        ldx t3
        lda #0
        sta p_inv,x
        rts

; bit_tab (1, 2, 4, 8, ...) comes from the engine (ai_math.asm)

!zone reveal_all
reveal_all:
        lda #<MAP
        sta mp
        lda #>MAP
        sta mp+1
        ldx #8
        ldy #0
-       lda (mp),y
        and #$1f
        beq +
        lda (mp),y
        ora #SEEN
        sta (mp),y
+       iny
        bne -
        inc mp+1
        dex
        bne -
        rts

!zone clear_view
clear_view:
        ldx #VIEW_TOP
-       jsr row_ptr
        ldy #39
        lda #$20
--      sta (scr),y
        lda #C_TEXT
        sta (colp),y
        dey
        bpl --
        inx
        cpx #VIEW_TOP+VIEW_ROWS
        bne -
        rts

; ---------------------------------------------------------------- character sheet
!zone char_sheet
char_sheet:
        jsr clear_view
        ldx #2
        jsr row_ptr
        ldy #2
        lda #<p_name
        ldx #>p_name
        jsr .str_at
        ldx #3
        jsr row_ptr
        ldy #2
        jsr say_at
        !scr "Level      class", 0
        ldx p_cls
        lda cls_name_lo,x
        pha
        lda cls_name_hi,x
        tax
        pla
        ldy #17
        jsr .str_at_keep
        ldx #3
        jsr row_ptr
        ldy #8
        lda p_lvl
        jsr .num_at
        lda #5
        ldy #2
        jsr .line
        !scr "Health", 0
        ldy #12
        lda p_hp
        jsr .num_at
        lda #$2f
        sta (scr),y
        iny
        lda p_maxhp
        jsr .num_at
        lda #6
        ldy #2
        jsr .line
        !scr "Strength", 0
        ldy #12
        lda p_str
        jsr .num_at
        lda #7
        ldy #2
        jsr .line
        !scr "Defense", 0
        ldy #12
        jsr armor_total
        clc
        adc p_def
        jsr .num_at
        lda #8
        ldy #2
        jsr .line
        !scr "Experience", 0
        ldy #13
        lda p_xp
        ldx p_xp+1
        jsr .num16_at
        lda #9
        ldy #2
        jsr .line
        !scr "Gold", 0
        ldy #13
        lda p_gold
        ldx p_gold+1
        jsr .num16_at
        lda #10
        ldy #2
        jsr .line
        !scr "Foes slain", 0
        ldy #13
        lda p_kills
        ldx p_kills+1
        jsr .num16_at
        lda #12
        ldy #2
        jsr .line
        !scr "Press any key.", 0
-       jsr GETIN
        beq -
        jmp draw_view
.line:                          ; A = row, Y = column, inline string follows
        tax
        tya
        pha
        jsr row_ptr
        pla
        tay
        jmp say_at
.str_at:
        sta ptr
        stx ptr+1
.sa:    sty t3
        ldy #0
-       lda (ptr),y
        beq +
        sty t4
        ldy t3
        sta (scr),y
        inc t3
        ldy t4
        iny
        bne -
+       ldy t3
        rts
.str_at_keep:
        sta ptr
        stx ptr+1
        jmp .sa
.num_at:
        ldx #0
.num16_at:
        pha
        lda #$30                ; plain digits
        sta num_or
        pla
        jmp stat_num

; ---------------------------------------------------------------- other actions
!zone act_look
act_look:
        lda cur_room
        cmp #$ff
        bne +
        jsr log_para
        jsr say
        !scr "A narrow passage of cold stone.", 0
        rts
+       jmp ev_room

!zone act_rest
act_rest:
        ldx #0
-       lda m_type,x
        bmi +
        jsr mon_dist
        cmp #7
        bcs +
        lda #EV_REST
        ldx #TOK_TASK_ACTION
        jsr dm_begin
        lda #TOK_ACT_REST
        jsr dm_tok
        lda #TOK_OUT_FAIL
        jsr dm_tok
        jsr dm_end
        jsr say
        !scr "You cannot rest with enemies near.", 0
        rts
+       inx
        cpx #MAX_MON
        bne -
        lda p_hp
        cmp p_maxhp
        bcs .full
        inc p_hp
        lda p_cls
        cmp #2                  ; cleric
        bne +
        lda p_hp
        cmp p_maxhp
        bcs +
        inc p_hp
+       jmp end_turn
.full:  jsr log_para
        jsr say
        !scr "You are fully rested.", 0
        rts

!zone act_descend
act_descend:
        ldx p_x
        ldy p_y
        jsr tile_at
        and #$1f
        cmp #T_STAIRS
        beq +
        jsr log_para
        jsr say
        !scr "There are no stairs here.", 0
        rts
+       inc p_floor
        jsr log_para
        lda #7
        sta color
        jsr say
        !scr "You descend to level ", 0
        lda p_floor
        jsr say_num
        jsr say
        !scr ".", 0
        jmp enter_floor

; ---------------------------------------------------------------- events with fallback text
!zone ev_quest
ev_quest:
        lda #EV_QUEST
        ldx #TOK_TASK_QUEST
        jsr dm_begin
        lda #TOK_NPC_PRIEST
        jsr dm_tok
        lda #TOK_QUEST_FIND_RELIC
        jsr dm_tok
        jsr dm_end
        lda #7
        sta color
        jsr say
        !scr "A priest whispers: ", $22, "The Amulet of Dawn lies on the fifth level. Bring it back to the light.", $22, 0
        lda #C_TEXT
        sta color
        rts

!zone ev_floor
ev_floor:
        lda #8
        jsr rnd_mod
        pha
        lda #EV_FLOOR
        ldx #TOK_TASK_EVENT
        jsr dm_begin
        jsr dm_loc
        pla
        pha
        tax
        lda env_tok,x
        jsr dm_tok
        jsr dm_end
        pla
        bcs .f_ai
        tax
        +say_name env_text_lo, env_text_hi
.f_ai:  rts

!zone ev_room
ev_room:                        ; A = room index
        tax
        lda r_type,x
        pha
        lda #EV_ROOM
        ldx #TOK_TASK_ROOM
        jsr dm_begin
        jsr dm_loc
        pla
        pha
        tax
        lda roomt_tok,x
        jsr dm_tok
        jsr dm_end
        bcc .r_fb
        pla
        rts
.r_fb:  jsr say
        !scr "You enter ", 0
        pla
        pha
        tax
        lda #0
        sta t7
        +say_a roomt_lo, roomt_hi
        jsr say
        !scr ". ", 0
        pla
        tax
        +say_name room_text_lo, room_text_hi
        rts

!zone ev_seen
ev_seen:                        ; X = monster now in view
        lda mon_flags,x
        ora #1
        sta mon_flags,x
        stx target
        lda #EV_SEEN
        ldx #TOK_TASK_MONSTER
        jsr dm_begin
        jsr dm_loc
        ldx target
        ldy m_type,x
        lda mon_tok,y
        jsr dm_tok
        jsr mon_state_tok
        jsr dm_tok
        jsr dm_end
        bcc .s_fb
        rts
.s_fb:  lda #C_MON
        sta color
        ldx target
        lda m_type,x
        tax
        lda #$80
        sta t7
        +say_a mon_lo, mon_hi
        jsr say
        !scr " appears!", 0
        lda #C_TEXT
        sta color
        rts

; ---------------------------------------------------------------- numbers after narration
; The narrator never states game numbers; these print them in grey.
!zone num_minus_hp
num_minus_hp:                   ; "(-dmg HP)"
        lda #C_SYS
        sta color
        jsr say
        !scr "(-", 0
        lda dmg
        jsr say_num
        jsr say
        !scr " HP)", 0
        lda #C_TEXT
        sta color
        rts
num_plus_gold:                  ; "(+dmg gold)"
        lda #C_SYS
        sta color
        jsr say
        !scr "(+", 0
        lda dmg
        jsr say_num
        jsr say
        !scr " gold)", 0
        lda #C_TEXT
        sta color
        rts
