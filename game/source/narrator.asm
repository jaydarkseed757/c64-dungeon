; narrator.asm - the Dungeon Master narrates with the on-device model (Milestone 6).
;
; ai_boot   once at start: REU, turbo, model (REU, else USB through the Command
;           Interface). Never fails: without a model the game uses built-in text.
; narrate   called by dm_end for events in ai_kinds: sends BOS + dm_ctx + SEP to the
;           engine, streams the text into the log, returns carry set if text was
;           shown. Carry clear = the caller prints its built-in (fallback) text.
; Rules stay with the game: callers print numbers (damage, XP, gold) themselves.
;
; Fact check (Milestone 8, python/facts.py): text is printed one whole word at a
; time. A word naming a monster that is not in the record is never shown; the
; sentence ends with "..." and the caller adds its built-in line. A monster
; sighting must name its monster, treasure its item, a locked door "lock(ed)";
; when that word never came, the caller adds its built-in line after the text.

C_AI     = 14               ; light blue: generated text
AI_MAX_TOKENS = 48          ; about 80 characters with the letter-group model
ai_ok    = $c9e0            ; model loaded and verified
ai_on    = $c9e1            ; narrator enabled (N toggles)
ai_turbo = $c9e2            ; turbo registers active
ai_temp  = $c9e3            ; 2: inverse temperature Q8.8 (0 = greedy; tests set it)
ai_shown = $c9e5            ; characters already printed
ai_why   = $c9e6            ; 0 ready, 1 no REU, 2 no model, 3 model rejected
f_mon    = $c9e7            ; fact check: the record's monster token (0 = none)
f_need   = $c9e8            ; token the text must name (0 = none)
f_seen   = $c9e9            ; the text named f_need
f_bad    = $c9ea            ; the text named a monster that is not there
f_end    = $c9eb            ; end (exclusive) of the word being checked
f_wl     = $c9ec            ; its length
f_kl     = $c9ed            ; length of the word-list entry
f_item   = $c9ee            ; the record's item token (0 = none)
f_tok    = $c9ef            ; token of the word-list entry
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
        jsr fact_setup
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
        ldx f_bad
        bne .wrong
        cmp #AI_STEP_MORE
        beq .step
        jsr .flush
        lda f_bad
        bne .wrong
        jsr .finish
        lda ai_shown
        beq .none
        lda f_need              ; a fact the text had to name ...
        beq +
        lda f_seen
        beq .none               ; ... but did not: the caller adds its built-in line
+       sec
        rts
.wrong:                         ; a wrong monster: that word is never shown
        jsr .finish
        lda ai_shown
        beq .none
        jsr say
        !scr "...", 0
        clc
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
.stream:                        ; print every complete, checked word
        ldx ai_shown
-       cpx out_buf
        bcs .s_out              ; no word boundary yet: wait for more text
        lda out_buf+1,x
        and #$7f
        cmp #$41                ; letters $41-$5a (capitals $c1-$da)
        bcc .s_bound
        cmp #$5b
        bcs .s_bound
        inx
        bne -
.s_bound:
        jsr fact_word           ; the word ai_shown..X-1 (keeps X)
        lda f_bad
        bne .s_out
        inx                     ; print through the boundary character
        jsr .show
        jmp .stream
.s_out: rts
.show:                          ; print out_buf characters ai_shown..X-1
        stx f_end
-       ldx ai_shown
        cpx f_end
        bcs +
        lda out_buf+1,x
        jsr pet2scr
        jsr log_putc
        inc ai_shown
        jmp -
+       rts
.flush:                         ; the last word (no boundary after it)
        ldx out_buf
        cpx ai_shown
        beq +
        bcc +
        jsr fact_word
        lda f_bad
        bne +
        ldx out_buf
        jsr .show
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

; ---------------------------------------------------------------- fact check
; fact_setup: read the monster, item and must-name token from dm_ctx.
!zone fact_setup
fact_setup:
        lda #0
        sta f_mon
        sta f_item
        sta f_need
        sta f_seen
        sta f_bad
        ldx dm_ctx
-       lda dm_ctx,x
        cmp #TOK_MON_SKELETON   ; MON:SKELETON .. MON:BAT are consecutive
        bcc +
        cmp #TOK_MON_BAT+1
        bcs +
        sta f_mon
+       cmp #TOK_ITEM_GOLD      ; ITEM:GOLD .. ITEM:MAP
        bcc +
        cmp #TOK_ITEM_MAP+1
        bcs +
        sta f_item
+       cmp #TOK_OUT_LOCKED
        bne +
        sta f_need
+       dex
        bne -
        lda dm_ctx+1            ; the TASK token
        cmp #TOK_TASK_MONSTER
        bne +
        lda f_mon
        sta f_need
        rts
+       cmp #TOK_TASK_TREASURE
        bne +
        lda f_item
        sta f_need
+       rts

; fact_word: look up the word out_buf[ai_shown .. X-1] in fact_words and update
; f_seen / f_bad. Keeps X. A word matches an entry equal to it, or to it minus a
; final "s" or "es".
!zone fact_word
fact_word:
        stx f_end
        txa
        sec
        sbc ai_shown
        bne .lbx2_369
        jmp .done
.lbx2_369:
        sta f_wl
        lda #<fact_words
        sta .rd+1
        lda #>fact_words
        sta .rd+2
.entry: jsr .next               ; token (0 = end of list)
        beq .done
        sta f_tok
        jsr .next
        sta f_kl
        lda f_wl
        cmp f_kl
        beq .cmp
        sec
        sbc f_kl
        cmp #1
        beq .s
        cmp #2
        bne .skip
        ldx f_end               ; "...es": the second-last letter is e
        lda out_buf-1,x
        and #$7f
        cmp #$45
        bne .skip
.s:     ldx f_end               ; the last letter is s
        lda out_buf,x
        and #$7f
        cmp #$53
        bne .skip
.cmp:   ldx ai_shown
        ldy f_kl
-       jsr .next
        sta f_ch
        lda out_buf+1,x
        and #$7f
        cmp f_ch
        bne .skipn
        inx
        dey
        bne -
        lda f_tok               ; a match
        cmp f_need
        bne +
        lda #1
        sta f_seen
        lda f_tok
+       cmp #TOK_MON_SKELETON
        bcc .done
        cmp #TOK_MON_BAT+1
        bcs .done
        cmp f_mon
        beq .done
        lda #1
        sta f_bad
.done:  ldx f_end
        rts
.skipn: dey                     ; skip the letters not yet read
        tya
        jmp .adv
.skip:  lda f_kl
.adv:   clc
        adc .rd+1
        sta .rd+1
        bcs .lbx1_433
        jmp .entry
.lbx1_433:
        inc .rd+2
        jmp .entry
.next:                          ; A = next byte of fact_words, Z set when 0
.rd:    lda $ffff
        inc .rd+1
        bne +
        inc .rd+2
+       cmp #0
        rts
f_ch:   !byte 0

!source "game/source/generated/fact_words.asm"
