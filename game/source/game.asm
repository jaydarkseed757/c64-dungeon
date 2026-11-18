; game.asm - Dungeon Master 64, the dungeon game (Milestone 5) with the AI narrator
; (Milestone 6: narrator.asm + the engine at $2000).
;
; Design: docs/GAME_DESIGN.md. The game owns every rule; narration goes through
; dm_event (text.asm), which records the model context and prints fallback text.
; Memory: code $0801-$1fff, $5000-$5fff, $b500-$bfff; map $ad00-$b4ff;
; state $c800-$cfff; $2000-$4fff and $6000-$9fff are left for the engine (M6).

!cpu 6510
!source "engine/include/memory.inc"
!source "engine/include/ai_api.inc"

; ---------------------------------------------------------------- constants
SCREEN   = $0400
COLRAM   = $d800
MAP      = $ad00            ; 64 x 32 tiles
MAPW     = 64
MAPH     = 32
VIEW_ROWS = 15
VIEW_TOP = 1
LOG_TOP  = 17
LOG_BOT  = 23
LOG_LEFT = 1
LOG_RIGHT = 38
GETIN    = $ffe4
JIFFY    = $a0
MAX_ROOMS = 9
MAX_MON  = 24
MAX_ITEM = 32
MAX_INV  = 8
LAST_FLOOR = 5

; tiles (bits 0-4), bit 7 = seen
T_WALL   = 0
T_FLOOR  = 1
T_DOOR   = 2
T_LOCKED = 3
T_STAIRS = 4
T_TRAP   = 5                ; hidden trap: looks like floor
T_TRAPV  = 6                ; revealed trap
SEEN     = $80

; items
I_GOLD = 1
I_POTION = 2
I_DAGGER = 3
I_SWORD = 4
I_AXE = 5
I_MACE = 6
I_LEATHER = 7
I_CHAIN = 8
I_SHIELD = 9
I_HELM = 10
I_KEY = 11
I_SCROLL = 12
I_RING = 13
I_GEM = 14
I_AMULET = 15

; monsters
M_RAT = 0
M_BAT = 1
M_SKELETON = 2
M_GOBLIN = 3
M_ZOMBIE = 4
M_SPIDER = 5
M_ORC = 6
M_TROLL = 7
M_MAGE = 8
M_DRAGON = 9

; room types
R_HALL = 0
R_BURIAL = 1
R_TREASURE = 2
R_LAIR = 3
R_LIBRARY = 4
R_ARMORY = 5
R_SECRET = 6
R_TRAP = 7
R_MAGIC = 8
R_SHRINE = 9
R_PRISON = 10
R_STAIRS = 11
R_BOSS = 12

; colours
C_WALL   = 11
C_FLOOR  = 12
C_DOOR   = 8
C_STAIRS = 7
C_PLAYER = 1
C_TEXT   = 13
C_SYS    = 15
C_ITEM   = 7
C_MON    = 10

; ---------------------------------------------------------------- zero page $50-$6f
scr      = $50
colp     = $52
str      = $54
mp       = $56              ; map pointer
t0       = $58
t1       = $59
t2       = $5a
t3       = $5b
t4       = $5c
t5       = $5d
t6       = $5e
t7       = $5f
ptr      = $60
sp1      = $62              ; log_scroll only
sp2      = $64

; ---------------------------------------------------------------- state $c800-$cfff
p_name   = $c800            ; 11 screen codes + 0
p_cls    = $c80c            ; 0 warrior, 1 rogue, 2 cleric
p_hp     = $c80d
p_maxhp  = $c80e
p_str    = $c80f
p_def    = $c810
p_lvl    = $c811
p_xp     = $c812            ; 2
p_gold   = $c814            ; 2
p_floor  = $c816            ; 1..5
p_x      = $c817
p_y      = $c818
p_weapon = $c819            ; item id, 0 = fists
p_worn   = $c81a            ; bit0 leather, bit1 chain, bit2 shield, bit3 helm
p_ring   = $c81b            ; bonus DEF from rings
p_kills  = $c81c            ; 2
p_inv    = $c820            ; MAX_INV item ids
seed     = $c828            ; 2
rng_lo   = $c82a
rng_hi   = $c82b
gstate   = $c82c            ; 1 playing, 2 dead, 3 won
turns    = $c82d            ; 2
n_rooms  = $c830
cur_room = $c831
view_x   = $c832
view_y   = $c833
last_joy = $c834
joy_time = $c835
dmg      = $c836
roll     = $c837
target   = $c838            ; monster index being fought
new_x    = $c839
new_y    = $c83a
r_x      = $c840            ; MAX_ROOMS each
r_y      = $c849
r_w      = $c852
r_h      = $c85b
r_type   = $c864
r_seen   = $c86d
m_type   = $c880            ; MAX_MON each, $ff = empty
m_x      = $c898
m_y      = $c8b0
m_hp     = $c8c8
mon_flags  = $c8e0            ; bit0 announced
i_type   = $c900            ; MAX_ITEM each, 0 = empty
i_x      = $c920
i_y      = $c940
log_row  = $c960
log_col  = $c961
word_len = $c962
word_start = $c963
word_lsave = $c964
color    = $c965
word_buf = $c968            ; 40
dm_ctx   = $c990            ; context record for the narrator: length + token ids (<= 15)
dm_kind  = $c9a0            ; event kind of the last record
dm_count = $c9a1            ; events so far (tests)
numbuf   = $c9a8            ; 8
GS       = $c9b0            ; test-visible block: "DMG1", gstate, floor, turns lo
in_len   = $c9b8
fill_chg = $c9b9
tmp_cnt  = $c9ba
rec_out  = $c9bb
num_or   = $c9bc            ; $b0 reversed digits (status bar), $30 plain
GAME_STATE_END = $c9c0

; ---------------------------------------------------------------- part 1: $0801-$1fff
* = $0801
        !word .bas_end, 10
        !byte $9e
        !text "2061"
        !byte 0
.bas_end: !word 0
* = $080d
        jmp start

!zone start
start:
        sei
        lda #$36                ; BASIC ROM out: the map lives under it
        sta $01
        ldx #$ff
        txs
        cld
        lda #$ff
        sta $cc                 ; no KERNAL cursor
        lda #0
        sta $d020
        sta $d021
        lda #$17                ; mixed-case character set, screen $0400
        sta $d018
        cli
        jsr clear_screen
        ldx #12
        jsr row_ptr
        ldy #6
        jsr say_at
        !scr "Waking the Dungeon Master...", 0
        jsr ai_boot             ; once per power-on: REU, turbo, model
!zone new_game
new_game:
        lda #"D"
        sta GS
        lda #"M"
        sta GS+1
        lda #"G"
        sta GS+2
        lda #"1"
        sta GS+3
        lda #0
        sta gstate
        sta GS+4
        sta dm_count
        jsr title
        jsr init_player
        lda #1
        sta gstate
        sta p_floor
        jsr clear_screen
        jsr draw_frame
        jsr log_clear
        jsr ev_quest
        jsr enter_floor

; ---------------------------------------------------------------- main loop
!zone main_loop
main_loop:
        jsr update_gs
        lda gstate
        cmp #1
        beq main_idle
        jmp end_screen
!zone main_idle
main_idle:                      ; tests stop here: waiting for input
        jsr GETIN
        bne key
        jsr read_joy
        beq main_idle
!zone key
key:    jsr do_key
        jmp main_loop

!zone update_gs
update_gs:
        lda gstate
        sta GS+4
        lda p_floor
        sta GS+5
        lda turns
        sta GS+6
        lda p_hp
        sta GS+7
        rts

; joystick port 2 -> A = key code (0 none), with auto-repeat every 10 jiffies
!zone read_joy
read_joy:
        lda $dc00
        and #$1f
        eor #$1f                ; 1 = pressed
        beq .none
        cmp last_joy
        bne .new
        lda JIFFY+2
        sec
        sbc joy_time
        cmp #10
        bcc .none_keep
.new:   sta last_joy
        lda JIFFY+2
        sta joy_time
        lda last_joy
        lsr
        bcs .up
        lsr
        bcs .down
        lsr
        bcs .left
        lsr
        bcs .right
        lda #"G"
        rts
.up:    lda #$91
        rts
.down:  lda #$11
        rts
.left:  lda #$9d
        rts
.right: lda #$1d
        rts
.none:  sta last_joy
.none_keep:
        lda #0
        rts

; A = PETSCII key
!zone do_key
do_key:
        ldx #0
        cmp #$91                ; cursor up
        beq .n
        cmp #$57                ; w
        beq .n
        cmp #$11
        beq .s
        cmp #$53                ; s
        beq .s
        cmp #$9d
        beq .w
        cmp #$41                ; a
        beq .w
        cmp #$1d
        beq .e
        cmp #$44                ; d
        beq .e
        cmp #$47                ; g
        bne +
        jmp act_get
+       cmp #$49                ; i
        bne +
        jmp inventory
+       cmp #$43                ; c
        bne +
        jmp char_sheet
+       cmp #$58                ; x
        bne +
        jmp act_look
+       cmp #$52                ; r
        bne +
        jmp act_rest
+       cmp #$3e                ; >
        beq .down
        cmp #$2e                ; .
        beq .down
        cmp #$4e                ; n: narrator on/off
        bne +
        jmp toggle_narrator
+       cmp #$85                ; F1
        bne +
        jmp help
+       rts
.down:  jmp act_descend
.n:     lda #0
        ldx #$ff
        jmp act_move
.s:     lda #0
        ldx #1
        jmp act_move
.w:     lda #$ff
        ldx #0
        jmp act_move
.e:     lda #1
        ldx #0
        jmp act_move

; ---------------------------------------------------------------- player setup
!zone init_player
init_player:
        ldx #MAX_INV-1
        lda #0
-       sta p_inv,x
        dex
        bpl -
        sta p_xp
        sta p_xp+1
        sta p_gold
        sta p_gold+1
        sta p_worn
        sta p_ring
        sta p_kills
        sta p_kills+1
        sta turns
        sta turns+1
        lda #1
        sta p_lvl
        lda #I_DAGGER
        sta p_weapon
        ldx p_cls
        lda cls_hp,x
        sta p_hp
        sta p_maxhp
        lda cls_str,x
        sta p_str
        lda cls_def,x
        sta p_def
        ; one potion to start
        lda #I_POTION
        sta p_inv
        rts

!zone cls_hp
cls_hp:  !byte 30, 24, 26
!zone cls_str
cls_str: !byte 4, 3, 3
!zone cls_def
cls_def: !byte 2, 3, 2

; ---------------------------------------------------------------- floors
!zone enter_floor
enter_floor:
        jsr gen_floor
        lda #$ff
        sta cur_room
        jsr reveal
        jsr draw_all
        jsr ev_floor
        jmp check_room

; ---------------------------------------------------------------- title and character creation
!zone title
title:
        jsr clear_screen
        ldx #3
        jsr row_ptr
        ldy #8
        jsr say_at
        !scr "Dungeon Master 64", 0
        ldx #5
        jsr row_ptr
        ldy #4
        jsr say_at
        !scr "A dungeon adventure for the C64", 0
        ldx #21
        jsr row_ptr
        jsr ai_status_line
        ldx #9
        jsr row_ptr
        ldy #4
        jsr say_at
        !scr "What is your name, adventurer?", 0
        ; name entry (letters and space, up to 10)
        lda #0
        sta in_len
.name:  jsr .show_name
-       jsr GETIN
        beq -
        cmp #13
        beq .name_done
        cmp #$14
        bne +
        lda in_len
        beq .name
        dec in_len
        jmp .name
+       ldx in_len
        cpx #10
        bcs .name
        cmp #$20
        beq .ok
        cmp #$41
        bcc .name
        cmp #$5b
        bcc .ok
        cmp #$c1
        bcc .name
        cmp #$db
        bcs .name
.ok:    jsr pet2scr
        ldx in_len
        sta p_name,x
        inc in_len
        jmp .name
.name_done:
        lda in_len
        bne +
        ; default name
        ldx #0
-       lda def_name,x
        sta p_name,x
        beq ++
        inx
        bne -
+       ldx in_len
        lda #0
        sta p_name,x
++      ; seed from the time the name took
        lda JIFFY+2
        eor $dc04
        sta seed
        lda $d012
        eor JIFFY+1
        ora #1
        sta seed+1
        ; class
        ldx #13
        jsr row_ptr
        ldy #4
        jsr say_at
        !scr "Choose your class:", 0
        ldx #15
        jsr row_ptr
        ldy #6
        jsr say_at
        !scr "1  Warrior  (strong, tough)", 0
        ldx #16
        jsr row_ptr
        ldy #6
        jsr say_at
        !scr "2  Rogue    (deadly criticals)", 0
        ldx #17
        jsr row_ptr
        ldy #6
        jsr say_at
        !scr "3  Cleric   (heals when resting)", 0
-       jsr GETIN
        cmp #$31
        bcc -
        cmp #$34
        bcs -
        sec
        sbc #$31
        sta p_cls
        rts
.show_name:                     ; row 11: name from column 6, then a cursor block
        ldx #11
        jsr row_ptr
        ldy #39
        lda #$20
-       sta (scr),y
        dey
        bpl -
        ldx #0
        ldy #6
-       cpx in_len
        beq +
        lda p_name,x
        sta (scr),y
        inx
        iny
        bne -
+       lda #$a0
        sta (scr),y
        ldy #39
        lda #C_TEXT
-       sta (colp),y
        dey
        bpl -
        rts
!zone def_name
def_name: !scr "Adventurer", 0

; ---------------------------------------------------------------- end screens
!zone end_screen
end_screen:
        jsr log_para
        lda gstate
        cmp #3
        beq .won
        lda #10
        sta color
        jsr say
        !scr "You have died on level ", 0
        jmp .tail
.won:   lda #7
        sta color
        jsr say
        !scr "Victory! You carry the Amulet of Dawn out of the depths. Level ", 0
.tail:  lda p_floor
        jsr say_num
        jsr say
        !scr ", ", 0
        lda p_kills
        jsr say_num
        jsr say
        !scr " foes slain. Press RETURN for a new game.", 0
        jsr update_gs
!zone end_wait
end_wait:                       ; tests stop here after death or victory
        jsr GETIN
        cmp #13
        bne end_wait
        jmp new_game

!zone help
help:
        jsr log_para
        lda #C_SYS
        sta color
        jsr say
        !scr "WASD/cursor/joystick move and attack. G get, I items, C character, X look, R rest, > descend, N narrator on/off. RUN/STOP skips the narrator.", 0
        rts

!source "game/source/text.asm"
!source "game/source/view.asm"
!source "game/source/data.asm"
!source "game/source/narrator.asm"

!zone end_part1
end_part1:
!if end_part1 > $2000 { !error "game part 1 overlaps $2000 (engine space)" }

; ---------------------------------------------------------------- the engine: $2000-$4fff
!source "engine/source/engine.asm"
!if engine_end > $5000 { !error "engine overlaps game part 2 at $5000" }

; ---------------------------------------------------------------- part 2: $5000-$5fff
* = $5000
!source "game/source/rules.asm"
!zone end_part2
end_part2:
!if end_part2 > $6000 { !error "game part 2 overlaps $6000 (engine buffers)" }

; ---------------------------------------------------------------- part 3: $b500-$bfff
* = $b500
!source "game/source/gen.asm"
!source "game/source/generated/game_tables.asm"
!zone end_part3
end_part3:
!if end_part3 > $c000 { !error "game part 3 overlaps $c000" }
