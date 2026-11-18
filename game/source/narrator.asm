; narrator.asm - the Dungeon Master narrates with the on-device model (Milestone 6).
;
; ai_boot   once at start: REU, turbo, model (REU, else USB through the Command
;           Interface). Never fails: without a model the game uses built-in text.
; narrate   called by dm_end for events in ai_kinds: sends BOS + dm_ctx + SEP to the
;           engine, streams the text into the log, returns carry set if text was
;           shown. Carry clear = the caller prints its built-in (fallback) text.
; Rules stay with the game: callers print numbers (damage, XP, gold) themselves.

C_AI     = 14               ; light blue: generated text
AI_MAX_TOKENS = 48          ; about 80 characters with the letter-group model
ai_ok    = $c9e0            ; model loaded and verified
ai_on    = $c9e1            ; narrator enabled (N toggles)
ai_turbo = $c9e2            ; turbo registers active
ai_temp  = $c9e3            ; 2: inverse temperature Q8.8 (0 = greedy; tests set it)
ai_shown = $c9e5            ; characters already printed
ai_why   = $c9e6            ; 0 ready, 1 no REU, 2 no model, 3 model rejected
dm_prompt = $c9f0           ; length byte + BOS + context + SEP

; EV_* kinds narrated by the model (1) or always built-in (0)
;                 -  QUEST FLOOR ROOM SEEN ATTACK HURT ITEM DOOR TRAP DRINK REST
; QUEST stays built-in: the model only knows a generic relic quest and could state the
; wrong goal (the narrator must never contradict game facts).
ai_kinds: !byte  0,   0,    1,   1,   1,    1,    0,   1,   1,   1,    0,    0

model_path:
        !byte .pend - .p
.p:     !text "/USB1/dist/dungeon-master/DM64AI.REU"
.pend:

!zone ai_boot
ai_boot:
        lda #0
        sta ai_ok
        sta ai_on
        sta ai_turbo
        lda #<320               ; temperature 0.8
        sta ai_temp
        lda #>320
        sta ai_temp+1
        lda #1
        sta ai_why
        jsr AI_INIT
        bcs .done               ; no usable REU
        jsr turbo_on
        bcs +
        inc ai_turbo
+       ldx #3                  ; only a model with the game's vocabulary
-       lda vocab_hash_bytes,x
        sta AI_PB_EXPECT_HASH,x
        dex
        bpl -
        jsr AI_LOAD_MODEL       ; any rejected REU model: load the file from USB
        bcc .ok
.file:  lda #2
        sta ai_why
        jsr uci_present
        bcs .done
        ldx #<model_path
        ldy #>model_path
        jsr uci_load_model
        bcs .done
        jsr AI_LOAD_MODEL
        bcc .ok
.rejected:
        lda #3
        sta ai_why
        rts
.ok:    lda #0
        sta ai_why
        lda #1
        sta ai_ok
        lda ai_turbo            ; at 1 MHz narration takes minutes: start silent
        sta ai_on
.done:  rts

; title-screen line about the narrator (row via scr)
ai_status_line:
        lda ai_why
        bne +
        lda ai_turbo
        beq .slow
        ldy #4
        jsr say_at
        !scr "The Dungeon Master is awake (64 MHz).", 0
        rts
.slow:  ldy #1
        jsr say_at
        !scr "Model ready, no turbo: narrator off (N).", 0
        rts
+       cmp #1
        bne +
        ldy #2
        jsr say_at
        !scr "No REU: the Dungeon Master is silent.", 0
        rts
+       cmp #2
        bne +
        ldy #1
        jsr say_at
        !scr "No model in the REU: narrator silent.", 0
        rts
+       ldy #2
        jsr say_at
        !scr "Model rejected: narrator silent.", 0
        rts

; N key
toggle_narrator:
        jsr log_para
        lda #C_SYS
        sta color
        lda ai_ok
        bne +
        jsr say
        !scr "No model is loaded: built-in text only.", 0
        jmp .out
+       lda ai_on
        eor #1
        sta ai_on
        beq +
        jsr say
        !scr "The Dungeon Master will narrate.", 0
        jmp .out
+       jsr say
        !scr "The Dungeon Master falls silent.", 0
.out:   lda #C_TEXT
        sta color
        rts

; ---------------------------------------------------------------- narration
; -> carry set: generated text shown; carry clear: caller prints its fallback.
!zone narrate
narrate:
        lda ai_on
        bne +
        clc
        rts
+       ldx dm_kind
        lda ai_kinds,x
        bne +
        clc
        rts
+       cpx #EV_ATTACK          ; of all attacks, only kills are narrated
        bne +
        lda rec_out
        cmp #TOK_OUT_KILLED
        beq +
        clc
        rts
+       ; prompt = BOS, context tokens, SEP
        ldx dm_ctx
        lda #TOK_BOS
        sta dm_prompt+1
-       lda dm_ctx,x
        sta dm_prompt+1,x
        dex
        bne -
        ldx dm_ctx
        lda #TOK_SEP
        sta dm_prompt+2,x
        inx
        inx
        stx dm_prompt
        lda #AI_MAX_TOKENS
        sta AI_PB_MAX_CHARS
        lda ai_temp
        sta AI_PB_INV_TEMP
        lda ai_temp+1
        sta AI_PB_INV_TEMP+1
        lda #8
        sta AI_PB_TOP_K
        lda $dc04
        sta AI_PB_SEED
        lda $d012
        sta AI_PB_SEED+1
        lda JIFFY+2
        ora #1
        sta AI_PB_SEED+2
        lda turns
        sta AI_PB_SEED+3
        ldx #<dm_prompt
        ldy #>dm_prompt
        jsr AI_SET_PROMPT
        bcc +
        clc
        rts
+       jsr .thinking
        lda #0
        sta ai_shown
        lda #C_AI
        sta color
.step:  jsr $ffe1               ; KERNAL STOP: RUN/STOP skips
        bne +
        lda #1
        sta AI_PB_CANCEL
+       jsr AI_GENERATE_STEP
        php
        pha
        jsr .stream
        pla
        plp
        bcs .stopped
        cmp #AI_STEP_MORE
        beq .step
        jsr .finish
        lda ai_shown
        beq .none
        sec
        rts
.stopped:                       ; cancelled or failed
        jsr .finish
        lda ai_shown
        beq .none
        jsr say
        !scr "...", 0
        sec
        rts
.none:  clc
        rts
.stream:
        lda ai_shown
        cmp out_buf
        bcs +
        tax
        lda out_buf+1,x
        jsr pet2scr
        jsr log_putc
        inc ai_shown
        jmp .stream
+       rts
.finish:
        lda #0
        sta $c6                 ; drop keys pressed while the narrator was busy
        lda #C_TEXT
        sta color
        jsr log_para
        jmp draw_help
.thinking:
        ldx #24
        jsr row_ptr
        ldy #39
        lda #$20
-       sta (scr),y
        dey
        bpl -
        ldy #0
        jsr say_at
        !scr "Dungeon Master thinking... (RUN/STOP)", 0
        ldy #39
        lda #C_AI
-       sta (colp),y
        dey
        bpl -
        rts
