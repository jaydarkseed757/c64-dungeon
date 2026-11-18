; terminal.asm - Dungeon Master 64 AI terminal (Milestone 4).
;
; A standalone C64 program: checks the REU, selects turbo when the C64 Ultimate's
; turbo registers are enabled, finds or loads the model, then generates text on the
; C64 from a typed prompt or a random scene (structured control tokens).
;
; Build: make terminal  ->  terminal/build/dm64.prg
; Memory: this code $0801-$1fff, engine $2000-, terminal data after the engine,
; host buffers $c800-$cfff (docs/ENGINE.md, docs/TERMINAL.md).

!cpu 6510
!source "engine/include/memory.inc"
!source "engine/include/ai_api.inc"

; ---------------------------------------------------------------- constants
SCREEN   = $0400
COLRAM   = $d800
WIN_TOP  = 3
WIN_BOT  = 19
ROW_THINK = 20
ROW_IN   = 21
ROW_HELP = 24
LEFT     = 1
RIGHT    = 38
MAX_IN   = 60
GETIN    = $ffe4
STOP     = $ffe1
JIFFY    = $a0              ; KERNAL jiffy clock, $a0 (hi) $a1 $a2 (lo), 60 Hz

C_TITLE  = 7                ; yellow
C_TEXT   = 13               ; light green
C_SYS    = 15               ; light grey
C_PROMPT = 7                ; yellow
C_CTX    = 3                ; cyan
C_STAT   = 12               ; grey
C_ERR    = 10               ; light red

; zero page (host range $50-$8f)
scr      = $50
colp     = $52
str      = $54
t0       = $56
t1       = $57
t2       = $58
t3       = $59

; host RAM ($c800-$cfff)
TS       = $c800            ; state block for tests: "DMT1", phase, status, count, mode, model
ts_phase = TS+4             ; 0 boot, 1 idle, 2 busy, 3 error/wait
ts_status = TS+5
ts_count = TS+6
ts_mode  = TS+7             ; 0 creative, 1 exact
ts_model = TS+8
in_tok   = $c840            ; typed prompt tokens (MAX_IN)
in_pet   = $c880            ; typed prompt PETSCII for display
in_len   = $c8c0
prompt   = $c900            ; length byte + ids (<= 127)
word_buf = $c980            ; current output word (screen codes)
cur_row  = $c9c0
cur_col  = $c9c1
word_len = $c9c2
word_start = $c9c3
color    = $c9c4
printed  = $c9c5
t_start  = $c9c6            ; 3 bytes jiffy at request start
rnd_lo   = $c9c9
rnd_hi   = $c9ca
turbo_ok = $c9cb
reu_mb_v = $c9cc
numbuf   = $c9d0            ; decimal digits
ctx_n    = $c9e0            ; scene: OUT token while building a fight
col_tmp  = $c9e1

* = $0801
        !word .bas_end, 10
        !byte $9e
        !text "2061"
        !byte 0
.bas_end: !word 0
* = $080d
        jmp start

model_path:                     ; length byte + path used with the Command Interface
        !byte .path_end - .path
.path:  !text "/USB1/dist/dungeon-master/DM64AI.REU"
.path_end:

start:
        sei
        lda #$36                ; BASIC ROM out (engine tables), KERNAL + I/O in
        sta $01
        ldx #$ff
        txs
        cld
        lda #"D"
        sta TS
        lda #"M"
        sta TS+1
        lda #"T"
        sta TS+2
        lda #"1"
        sta TS+3
        lda #0
        sta ts_phase
        sta ts_count
        sta ts_mode
        sta ts_model
        sta in_len
        sta turbo_ok
        lda #$ff
        sta ts_status
        sta $cc                 ; KERNAL cursor blink off
        lda $dc04
        sta rnd_lo
        lda $d012
        ora #1
        sta rnd_hi
        cli
        jsr init_screen

; ---------------------------------------------------------------- boot
boot:
        lda #0
        sta ts_phase
        lda #C_SYS
        sta color
        lda #<m_reu
        ldy #>m_reu
        jsr win_msg_noline
        jsr AI_INIT
        bcc +
        jmp boot_no_reu
+       lda AI_PB_REU_MB
        sta reu_mb_v
        jsr print_dec8
        lda #<m_mb
        ldy #>m_mb
        jsr win_msg
        ; turbo
        jsr turbo_on
        bcs .slow
        lda #1
        sta turbo_ok
        lda #<m_turbo
        ldy #>m_turbo
        jsr win_msg
        jmp .model
.slow:  lda #C_ERR
        sta color
        lda #<m_slow
        ldy #>m_slow
        jsr win_msg
        lda #C_SYS
        sta color
.model:
        jsr draw_status
        ldx #3                  ; this terminal needs the vocabulary it was built for
-       lda vocab_hash_bytes,x
        sta AI_PB_EXPECT_HASH,x
        dex
        bpl -
        lda #<m_check
        ldy #>m_check
        jsr win_msg
        jsr AI_LOAD_MODEL
        bcc model_ok
        sta ts_status           ; any rejected REU model (none, damaged, old format,
                                ; other vocabulary): load the file from USB instead
try_file:
        jsr uci_present
        bcc +
        jmp no_model
+       lda #<m_file
        ldy #>m_file
        jsr win_msg
        ldx #<model_path
        ldy #>model_path
        jsr uci_load_model
        bcc +
        sta ts_status
        jmp file_failed
+       lda #<m_check
        ldy #>m_check
        jsr win_msg
        jsr AI_LOAD_MODEL
        bcc model_ok
        sta ts_status
        jmp model_bad

model_ok:
        lda #1
        sta ts_model
        lda #<m_model_ok
        ldy #>m_model_ok
        jsr win_msg
        jsr draw_status
        lda #<m_ready
        ldy #>m_ready
        jsr win_msg
        jsr draw_input
        lda #AI_OK
        sta ts_status
        jmp main

boot_no_reu:
        sta ts_status
        lda #C_ERR
        sta color
        lda #<m_no_reu
        ldy #>m_no_reu
        jsr win_msg
        jmp wait_retry
no_model:
        lda #C_ERR
        sta color
        lda #<m_no_model
        ldy #>m_no_model
        jsr win_msg
        jmp wait_retry
file_failed:
        lda #C_ERR
        sta color
        lda #<m_file_bad
        ldy #>m_file_bad
        jsr win_msg
        jmp wait_retry
model_bad:
        lda #C_ERR
        sta color
        lda #<m_bad_model
        ldy #>m_bad_model
        jsr win_msg_noline
        lda ts_status
        jsr print_hex8
        jsr win_nl
        jmp wait_retry

wait_retry:
        lda #3
        sta ts_phase
        lda #C_SYS
        sta color
        lda #<m_retry
        ldy #>m_retry
        jsr win_msg
.w:     jsr GETIN
        cmp #13
        bne .w
        jsr win_nl
        jmp boot

; ---------------------------------------------------------------- main loop
main:
        lda #1
        sta ts_phase
main_idle:                      ; tests stop here: idle, waiting for a key
        jsr GETIN
        beq main_idle
        cmp #13
        bne +
        jmp key_return
+       cmp #$14                ; DEL
        bne +
        jmp key_del
+       cmp #$85                ; F1
        bne +
        jmp scene_room
+       cmp #$86                ; F3
        bne +
        jmp scene_monster
+       cmp #$87                ; F5
        bne +
        jmp scene_treasure
+       cmp #$88                ; F7
        bne +
        jmp scene_combat
+       cmp #$89                ; F2
        bne +
        lda ts_mode
        eor #1
        sta ts_mode
        jsr draw_status
        jmp main_idle
+       cmp #$8c                ; F8 quit
        bne +
        jsr turbo_restore
        jmp ($fffc)
+       ; printable: accept only characters the model knows
        tax
        lda tok_in,x
        cmp m_unk
        beq main_idle
        ldy in_len
        cpy #MAX_IN
        bcs main_idle
        sta in_tok,y
        txa
        sta in_pet,y
        inc in_len
        jsr draw_input
        jmp main_idle

key_del:
        lda in_len
        beq +
        dec in_len
        jsr draw_input
+       jmp main_idle

key_return:
        lda in_len
        bne +
        jmp main_idle
+       ; echo "> text" in the window
        jsr win_para
        lda #C_PROMPT
        sta color
        lda #$3e                ; ">"
        jsr win_putc
        lda #$20
        jsr win_putc
        ldx #0
-       stx t3
        lda in_pet,x
        jsr pet2scr
        jsr win_putc
        ldx t3
        inx
        cpx in_len
        bne -
        ; prompt: BOS TASK:FREE chars SEP
        lda #TOK_BOS
        sta prompt+1
        lda #TOK_TASK_FREE
        sta prompt+2
        ldx #0
-       lda in_tok,x
        sta prompt+3,x
        inx
        cpx in_len
        bne -
        lda #TOK_SEP
        sta prompt+3,x
        txa
        clc
        adc #3
        sta prompt
        lda #0
        sta in_len
        jsr draw_input
        jmp run_request

; ---------------------------------------------------------------- scenes
; prompt is built as BOS TASK:x ... SEP, context text printed in cyan.
scene_begin:                    ; A = task token
        pha
        jsr win_para
        lda #C_CTX
        sta color
        lda #$1b                ; "["
        jsr win_putc
        lda #TOK_BOS
        sta prompt+1
        pla
        sta prompt+2
        lda #2
        sta prompt
        rts
scene_add:                      ; A = token
        inc prompt
        ldx prompt
        sta prompt,x
        rts
scene_end:
        lda #$1d                ; "]"
        jsr win_putc
        lda #TOK_SEP
        jsr scene_add
        jmp run_request
; pick from a group: A = count, X/Y = id table -> A = id, t2 = index
pick:
        stx t0
        sty t1
        sta t3
        jsr rnd
-       cmp t3
        bcc +
        sec
        sbc t3
        jmp -
+       sta t2
        tay
        lda (t0),y
        rts
!macro pick_group .n, .id, .lo, .hi {
        lda #.n
        ldx #<.id
        ldy #>.id
        jsr pick
        pha
        ldy t2
        lda .lo,y
        ldx .hi,y
        jsr win_puts_scr
        pla
}
!macro comma {
        lda #$2c
        jsr win_putc
        lda #$20
        jsr win_putc
}

scene_room:
        lda #TOK_TASK_ROOM
        jsr scene_begin
        lda #<s_room
        ldx #>s_room
        jsr win_puts_scr
        +pick_group grp_loc_n, grp_loc_id, grp_loc_lo, grp_loc_hi
        jsr scene_add
        +comma
        +pick_group grp_room_n, grp_room_id, grp_room_lo, grp_room_hi
        jsr scene_add
        jsr rnd
        and #3
        beq .mon
        cmp #1
        beq .obj
        cmp #2
        beq .env
        jmp scene_end
.mon:   +comma
        +pick_group grp_mon_n, grp_mon_id, grp_mon_lo, grp_mon_hi
        jsr scene_add
        jmp scene_end
.obj:   +comma
        +pick_group grp_obj_n, grp_obj_id, grp_obj_lo, grp_obj_hi
        jsr scene_add
        jmp scene_end
.env:   +comma
        +pick_group grp_env_n, grp_env_id, grp_env_lo, grp_env_hi
        jsr scene_add
        jmp scene_end

scene_monster:
        lda #TOK_TASK_MONSTER
        jsr scene_begin
        lda #<s_monster
        ldx #>s_monster
        jsr win_puts_scr
        +pick_group grp_loc_n, grp_loc_id, grp_loc_lo, grp_loc_hi
        jsr scene_add
        +comma
        +pick_group grp_mon_n, grp_mon_id, grp_mon_lo, grp_mon_hi
        jsr scene_add
        +comma
        +pick_group grp_mst_n, grp_mst_id, grp_mst_lo, grp_mst_hi
        jsr scene_add
        jmp scene_end

scene_treasure:
        lda #TOK_TASK_TREASURE
        jsr scene_begin
        lda #<s_treasure
        ldx #>s_treasure
        jsr win_puts_scr
        +pick_group grp_cont_n, grp_cont_id, grp_cont_lo, grp_cont_hi
        jsr scene_add
        +comma
        +pick_group grp_item_n, grp_item_id, grp_item_lo, grp_item_hi
        jsr scene_add
        lda #TOK_OUT_FOUND
        jsr scene_add
        jmp scene_end

scene_combat:
        lda #TOK_TASK_COMBAT
        jsr scene_begin
        lda #<s_combat
        ldx #>s_combat
        jsr win_puts_scr
        +pick_group grp_mon_n, grp_mon_id, grp_mon_lo, grp_mon_hi
        jsr scene_add
        +comma
        ; outcome decides the monster state token, which comes before ACT/OUT
        lda #grp_cout_n
        ldx #<grp_cout_id
        ldy #>grp_cout_id
        jsr pick
        sta t3                  ; OUT token (kept across the next calls in ctx_n)
        sta ctx_n
        lda t2
        pha
        cmp #3                  ; KILLED -> MST:DEAD
        bne +
        lda #TOK_MST_DEAD
        jsr scene_add
        jmp .act
+       cmp #1                  ; MISS -> no state
        beq .act
        +pick_group grp_mst_n, grp_mst_id, grp_mst_lo, grp_mst_hi
        jsr scene_add
        +comma
.act:   lda #TOK_ACT_ATTACK
        jsr scene_add
        lda ctx_n
        jsr scene_add
        pla
        tay
        lda grp_cout_lo,y
        ldx grp_cout_hi,y
        jsr win_puts_scr
        +comma
        lda #<s_hp
        ldx #>s_hp
        jsr win_puts_scr
        +pick_group grp_hp_n, grp_hp_id, grp_hp_lo, grp_hp_hi
        jsr scene_add
        jmp scene_end

; ---------------------------------------------------------------- generation
run_request:
        lda #2
        sta ts_phase
        lda #120
        sta AI_PB_MAX_CHARS
        lda #8
        sta AI_PB_TOP_K
        lda ts_mode
        bne .exact
        lda #<320               ; temperature 0.8
        sta AI_PB_INV_TEMP
        lda #>320
        sta AI_PB_INV_TEMP+1
        jmp +
.exact: lda #0
        sta AI_PB_INV_TEMP
        sta AI_PB_INV_TEMP+1
+       lda $dc04               ; seed from timer, raster and jiffy clock
        sta AI_PB_SEED
        lda $d012
        sta AI_PB_SEED+1
        lda JIFFY+2
        sta AI_PB_SEED+2
        lda rnd_lo
        ora #1
        sta AI_PB_SEED+3
        ldx #<prompt
        ldy #>prompt
        jsr AI_SET_PROMPT
        bcc +
        jmp gen_error
+       jsr win_para
        lda #C_TEXT
        sta color
        lda #0
        sta printed
        sei
        lda JIFFY
        sta t_start
        lda JIFFY+1
        sta t_start+1
        lda JIFFY+2
        sta t_start+2
        cli
.step:  jsr STOP                ; RUN/STOP held?
        bne +
        lda #1
        sta AI_PB_CANCEL
+       jsr AI_GENERATE_STEP
        bcs gen_error
        pha
        jsr stream_output
        jsr draw_think
        pla
        cmp #AI_STEP_MORE
        beq .step
        ; done: stats line
        jsr win_para
        lda #C_STAT
        sta color
        lda #$28                ; "("
        jsr win_putc
        lda out_buf
        jsr print_dec8
        lda #<s_chars
        ldx #>s_chars
        jsr win_puts_scr
        jsr elapsed_tenths      ; -> t0/t1
        jsr print_tenths
        lda #<s_secs
        ldx #>s_secs
        jsr win_puts_scr
        lda #AI_OK
        sta ts_status
gen_finish:
        inc ts_count
        jsr clear_think
        lda #0
        sta $c6                 ; drop keys typed (or RUN/STOP) during generation
        lda #1
        sta ts_phase
        jmp main_idle
gen_error:
        sta ts_status
        pha
        jsr stream_output
        jsr win_para
        lda #C_ERR
        sta color
        pla
        cmp #AI_ERR_CANCELLED
        bne +
        lda #<m_cancel
        ldy #>m_cancel
        jsr win_msg_noline
        jmp gen_finish
+       pha
        lda #<m_gen_err
        ldy #>m_gen_err
        jsr win_msg_noline
        pla
        jsr print_hex8
        jmp gen_finish

stream_output:                  ; print out_buf characters not yet shown
        lda printed
        cmp out_buf
        bcs +
        tax
        lda out_buf+1,x
        jsr pet2scr
        jsr win_putc
        inc printed
        jmp stream_output
+       rts

; ---------------------------------------------------------------- thinking line
draw_think:
        ldx #ROW_THINK
        jsr row_ptr
        ldy #39
        lda #$20
-       sta (scr),y
        dey
        bpl -
        lda #<s_think
        ldx #>s_think
        ldy #0
        jsr put_scr_at          ; columns 0-25
        lda out_buf
        jsr dec8_str
        ldy #27
        jsr put_num_at          ; character count, up to 3 digits
        lda #<s_ch
        ldx #>s_ch
        jsr put_scr_at
        iny
        sty col_tmp
        jsr elapsed_tenths
        jsr tenths_str
        ldy col_tmp
        jsr put_num_at
        lda #$13                ; "s"
        sta (scr),y
        ldy #39
        lda #C_STAT
-       sta (colp),y
        dey
        bpl -
        rts
clear_think:
        ldx #ROW_THINK
        jsr row_ptr
        ldy #39
        lda #$20
-       sta (scr),y
        dey
        bpl -
        rts

; elapsed time since t_start in tenths of a second -> t0/t1 (jiffies / 6)
elapsed_tenths:
        sei
        sec
        lda JIFFY+2
        sbc t_start+2
        sta t0
        lda JIFFY+1
        sbc t_start+1
        sta t1
        cli
        ; t0/t1 = t0/t1 / 6
        lda #0
        sta t2
        ldx #16
-       asl t0
        rol t1
        rol t2
        lda t2
        cmp #6
        bcc +
        sbc #6
        sta t2
        inc t0
+       dex
        bne -
        rts

; ---------------------------------------------------------------- screen
init_screen:
        lda #0
        sta $d020
        sta $d021
        lda #$17                ; screen $0400, lowercase/uppercase character set
        sta $d018
        lda #$1b
        sta $d011
        ldx #0
-       lda #$20
        sta SCREEN,x
        sta SCREEN+$100,x
        sta SCREEN+$200,x
        sta SCREEN+$2e8,x
        lda #C_SYS
        sta COLRAM,x
        sta COLRAM+$100,x
        sta COLRAM+$200,x
        sta COLRAM+$2e8,x
        inx
        bne -
        ; title bar (reverse)
        ldx #0
        jsr row_ptr
        ldy #39
-       lda #$a0
        sta (scr),y
        lda #C_TITLE
        sta (colp),y
        dey
        bpl -
        ldy #1
        ldx #0
-       lda s_title,x
        beq +
        ora #$80
        sta (scr),y
        iny
        inx
        bne -
+       ; separators
        ldx #2
        jsr hline
        ldx #23
        jsr hline
        ; help
        ldx #ROW_HELP
        jsr row_ptr
        lda #<s_help
        ldx #>s_help
        ldy #0
        jsr put_scr_at
        lda #WIN_TOP
        sta cur_row
        lda #LEFT
        sta cur_col
        lda #0
        sta word_len
        lda #LEFT
        sta word_start
        rts

hline:                          ; X = row
        jsr row_ptr
        ldy #39
-       lda #$40                ; horizontal line in the mixed-case set
        sta (scr),y
        lda #11
        sta (colp),y
        dey
        bpl -
        rts

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

put_scr_at:                     ; A/X = 0-terminated screen-code string, Y = column, row via scr
        sta str
        stx str+1
        sty t3
        ldy #0
-       lda (str),y
        beq +
        sty t2
        ldy t3
        sta (scr),y
        inc t3
        ldy t2
        iny
        bne -
+       ldy t3
        rts
put_num_at:                     ; numbuf (0-terminated screen codes) at column Y of scr row
        sty t3
        ldx #0
-       lda numbuf,x
        beq +
        ldy t3
        sta (scr),y
        inc t3
        inx
        bne -
+       ldy t3
        rts

draw_status:
        ldx #1
        jsr row_ptr
        ldy #39
-       lda #$20
        sta (scr),y
        lda #C_STAT
        sta (colp),y
        dey
        bpl -
        lda #<s_reu
        ldx #>s_reu
        ldy #1
        jsr put_scr_at
        sty col_tmp
        lda reu_mb_v
        jsr dec8_str
        ldy col_tmp
        jsr put_num_at
        lda #$20
        sta (scr),y
        iny
        lda #$4d                ; "M"
        sta (scr),y
        iny
        lda #$42                ; "B"
        sta (scr),y
        lda turbo_ok
        beq +
        lda #<s_64
        ldx #>s_64
        jmp ++
+       lda #<s_1
        ldx #>s_1
++      ldy #11
        jsr put_scr_at
        lda ts_model
        beq +
        lda #<s_mok
        ldx #>s_mok
        ldy #20
        jsr put_scr_at
+       lda ts_mode
        bne +
        lda #<s_creative
        ldx #>s_creative
        jmp ++
+       lda #<s_exact
        ldx #>s_exact
++      ldy #31
        jmp put_scr_at

draw_input:
        ldx #ROW_IN
        jsr row_ptr
        ldy #79
-       lda #$20
        sta (scr),y
        lda #C_PROMPT
        sta (colp),y
        dey
        bpl -
        ldy #0
        lda #$3e                ; ">"
        sta (scr),y
        ldx #0
        ldy #2
-       cpx in_len
        beq +
        stx t3
        sty t2
        lda in_pet,x
        jsr pet2scr
        ldy t2
        sta (scr),y
        ldx t3
        inx
        iny
        bne -
+       lda #$a0                ; reverse-space cursor
        sta (scr),y
        rts

; ---------------------------------------------------------------- output window
win_para:                       ; start a new line unless at the start of one
        lda cur_col
        cmp #LEFT
        beq +
        jsr win_nl
+       rts

win_nl:
        lda #LEFT
        sta cur_col
        sta word_start
        lda #0
        sta word_len
        inc cur_row
        lda cur_row
        cmp #WIN_BOT+1
        bcc +
        jsr win_scroll
        lda #WIN_BOT
        sta cur_row
+       rts

win_scroll:                     ; move rows WIN_TOP+1..WIN_BOT up one, clear the last
        ldx #WIN_TOP
.r:     jsr row_ptr
        lda scr
        sta str
        lda scr+1
        sta str+1
        lda colp
        sta t0
        lda colp+1
        sta t1
        inx
        jsr row_ptr
        ldy #39
-       lda (scr),y
        sta (str),y
        lda (colp),y
        sta (t0),y
        dey
        bpl -
        cpx #WIN_BOT
        bne .r
        ldx #WIN_BOT
        jsr row_ptr
        ldy #39
        lda #$20
-       sta (scr),y
        dey
        bpl -
        rts

win_putc:                       ; A = screen code; word-wraps at RIGHT
        cmp #$20
        bne .ch
        lda cur_col
        cmp #RIGHT+1
        bcc +
        jsr win_nl              ; space at the edge: just wrap
        rts
+       lda #$20
        jsr .store
        inc cur_col
        lda #0
        sta word_len
        lda cur_col
        sta word_start
        rts
.ch:    sta t2
        lda cur_col
        cmp #RIGHT+1
        bcc .fits
        ; overflow: carry the partial word to the next line if it is not the whole line
        lda word_start
        cmp #LEFT
        beq .hard
        jsr .erase_word
        jsr win_nl
        ldx #0
-       cpx word_len_saved
        beq +
        stx t3
        lda word_buf,x
        jsr .store
        inc cur_col
        ldx t3
        inx
        bne -
+       lda word_len_saved
        sta word_len
        jmp .fits
.hard:  jsr win_nl
.fits:  lda t2
        jsr .store              ; (returns with A = color)
        ldx word_len
        cpx #40
        bcs +
        lda t2
        sta word_buf,x
        inc word_len
+       inc cur_col
        rts
.store: pha                     ; A at (cur_row, cur_col) in the current color
        ldx cur_row
        jsr row_ptr
        pla
        ldy cur_col
        sta (scr),y
        lda color
        sta (colp),y
        rts
.erase_word:
        lda word_len
        sta word_len_saved
        ldx cur_row
        jsr row_ptr
        ldy word_start
        lda #$20
-       cpy #RIGHT+1
        bcs +
        sta (scr),y
        iny
        bne -
+       rts
word_len_saved: !byte 0

win_puts_scr:                   ; A/X = 0-terminated screen-code string
        sta str
        stx str+1
        ldy #0
-       lda (str),y
        beq +
        sty t0
        jsr win_putc
        ldy t0
        iny
        bne -
+       rts
win_msg_noline:                 ; A/Y = string, no newline
        tax
        tya
        stx str
        sta str+1
        lda str
        ldx str+1
        jmp win_puts_scr
win_msg:                        ; A/Y = string, then newline
        jsr win_msg_noline
        jmp win_nl

; ---------------------------------------------------------------- numbers / text
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

dec8_str:                       ; A -> numbuf (screen codes, 0-terminated, no leading zeros)
        ldx #0
        ldy #0
-       cmp #100
        bcc +
        sbc #100
        iny
        bne -
+       sta t1
        tya
        beq .no100
        ora #$30
        sta numbuf,x
        inx
        lda #1
        sta t0
        jmp .tens
.no100: lda #0
        sta t0
.tens:  lda t1
        ldy #0
-       cmp #10
        bcc +
        sbc #10
        iny
        bne -
+       sta t1
        tya
        bne .put
        lda t0
        beq .ones
        lda #0
.put:   ora #$30
        sta numbuf,x
        inx
.ones:  lda t1
        ora #$30
        sta numbuf,x
        inx
        lda #0
        sta numbuf,x
        rts

print_dec8:                     ; A -> window
        jsr dec8_str
        lda #<numbuf
        ldx #>numbuf
        jmp win_puts_scr

tenths_str:                     ; t0/t1 tenths -> "ss.t" in numbuf (up to 6553.5)
        lda #0
        sta t2
        ; t0/t1 / 10: quotient in t0/t1, remainder t2
        ldx #16
-       asl t0
        rol t1
        rol t2
        lda t2
        cmp #10
        bcc +
        sbc #10
        sta t2
        inc t0
+       dex
        bne -
        lda t2
        pha
        ; integer part (16-bit) to decimal
        ldx #0
        ldy #4
        lda #0
        sta numbuf+8            ; leading-zero flag
.d16:   lda #0
        sta t3
.sub:   lda t0
        sec
        sbc pow10_lo,y
        sta t2
        lda t1
        sbc pow10_hi,y
        bcc .digit
        sta t1
        lda t2
        sta t0
        inc t3
        jmp .sub
.digit: lda t3
        bne +
        lda numbuf+8
        bne +
        cpy #0
        bne .skip
+       lda t3
        ora #$30
        sta numbuf,x
        inx
        inc numbuf+8
.skip:  dey
        bpl .d16
        lda #$2e                ; "."
        sta numbuf,x
        inx
        pla
        ora #$30
        sta numbuf,x
        inx
        lda #0
        sta numbuf,x
        rts
pow10_lo: !byte <1, <10, <100, <1000, <10000
pow10_hi: !byte >1, >10, >100, >1000, >10000

print_tenths:
        jsr tenths_str
        lda #<numbuf
        ldx #>numbuf
        jmp win_puts_scr

print_hex8:                     ; A -> "$xx" in the window
        pha
        lda #$24
        jsr win_putc
        pla
        pha
        lsr
        lsr
        lsr
        lsr
        jsr .nib
        pla
        and #$0f
.nib:   cmp #10
        bcc +
        sbc #9                  ; screen codes 1-6 = a-f
        jmp win_putc
+       ora #$30
        jmp win_putc

rnd:                            ; 16-bit xorshift (7, 9, 8) -> A
        lda rnd_hi
        lsr
        lda rnd_lo
        ror
        eor rnd_hi
        sta rnd_hi
        ror
        eor rnd_lo
        sta rnd_lo
        eor rnd_hi
        sta rnd_hi
        rts


row_lo:
!for r, 0, 24 { !byte <(SCREEN + r * 40) }
row_hi:
!for r, 0, 24 { !byte >(SCREEN + r * 40) }

end_low_code:
!if end_low_code > $2000 { !error "terminal code overlaps the engine at $2000" }

; ---------------------------------------------------------------- engine
!source "engine/source/engine.asm"

; ---------------------------------------------------------------- terminal data (after the engine)
!source "terminal/source/generated/scene_tables.asm"

s_title:    !scr "Dungeon Master 64  -  AI Terminal", 0
s_help:     !scr "F1 room F3 foe F5 loot F7 fight F2 mode", 0
s_reu:      !scr "REU ", 0
s_64:       !scr "64 MHz", 0
s_1:        !scr "1 MHz ", 0
s_mok:      !scr "model ok", 0
s_creative: !scr "creative", 0
s_exact:    !scr "exact   ", 0
s_think:    !scr "Dungeon Master thinking...", 0
s_ch:       !scr " ch", 0
s_chars:    !scr " characters, ", 0
s_secs:     !scr " s)", 0
s_room:     !scr "room: ", 0
s_monster:  !scr "monster: ", 0
s_treasure: !scr "treasure: ", 0
s_combat:   !scr "fight: ", 0
s_hp:       !scr "your hp ", 0
m_reu:      !scr "REU: ", 0
m_mb:       !scr " MB", 0
m_turbo:    !scr "Turbo registers: 64 MHz.", 0
m_slow:     !scr "Turbo registers off: running at 1 MHz (very slow). Ultimate menu: U64 Specific Settings, Turbo Control = C64U Turbo Registers.", 0
m_check:    !scr "Checking the model in the REU...", 0
m_file:     !scr "Loading DM64AI.REU from USB...", 0
m_model_ok: !scr "Model OK.", 0
m_ready:    !scr "Ready. Type a question and press RETURN, or press F1-F7 for a scene. F2: creative/exact. RUN/STOP cancels.", 0
m_no_reu:   !scr "No usable REU. Enable the REU with 16 MB in the Ultimate menu (C64 and Cartridge Settings).", 0
m_no_model: !scr "No model in the REU. In the Ultimate file browser select DM64AI.REU and choose Load into REU (or enable the Command Interface).", 0
m_file_bad: !scr "Could not load /USB1/dist/dungeon-master/DM64AI.REU. Copy it there (make ultimate) or use Load into REU.", 0
m_bad_model: !scr "The model in the REU cannot be used, error ", 0
m_retry:    !scr "Press RETURN to try again.", 0
m_cancel:   !scr "[cancelled]", 0
m_gen_err:  !scr "[generation error ", 0

end_data:
!if end_data > $6000 { !error "terminal data overlaps engine buffers at $6000" }
