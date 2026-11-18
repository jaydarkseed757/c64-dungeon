; ai_api.asm - public entry points, sampling and text output (docs/ENGINE.md).
;
; Calling convention: carry clear = success (A = AI_OK or a step status),
; carry set = error with A = AI_ERR_*, also stored in AI_PB_STATUS.
; X/Y are not preserved. $01 must map I/O and keep BASIC ROM out ($36).

; ---------------------------------------------------------------- API calls
!zone api
api_init:
        jsr engine_init
        jmp api_ret

api_load_model:                 ; model must already be in the REU at $000000
        lda eng_state
        bne +
        lda #AI_ERR_NOT_INIT
        sec
        jmp api_ret
+       lda #1
        sta eng_state           ; a failed load leaves no model
        jsr load_model
        jmp api_ret

api_reset_context:
        jsr .need_model
        bcc .lbx5_26
        jmp api_ret
.lbx5_26:
        jsr model_reset
        lda #0
        sta gen_phase
        sta out_buf
        lda #AI_OK
        clc
        jmp api_ret

; X/Y -> token buffer: length byte, then ids. Starts a new request.
api_set_prompt:
        stx ptr0
        sty ptr0+1
        jsr .need_model
        bcc .lbx4_40
        jmp api_ret
.lbx4_40:
        ldy #0
        lda (ptr0),y
        beq .bad_tok            ; empty prompt
        sta prompt_len
        cmp m_ctx
        bcs .ctx                ; prompt must leave room for at least one output token
        tax
-       lda (ptr0),y            ; copy length + ids (Y = 0..len)
        sta prompt_buf,y
        iny
        dex
        bpl -
        ; validate ids
        ldx prompt_len
-       lda prompt_buf,x
        cmp m_vocab
        bcc +
        ldy m_vocab             ; vocab 256 (stored 0) accepts every id
        bne .bad_tok
+       dex
        bne -
        jsr model_reset
        lda #0
        sta prompt_idx
        sta gen_count
        sta out_buf
        sta AI_PB_CANCEL
        lda #1
        sta cap_next
        sta gen_phase           ; prefill
        ldx #3
-       lda AI_PB_SEED,x
        sta rng,x
        dex
        bpl -
        lda rng
        ora rng+1
        ora rng+2
        ora rng+3
        bne +
        inc rng                 ; xorshift state must be non-zero
+       lda #AI_OK
        clc
        jmp api_ret
.bad_tok:
        lda #AI_ERR_BAD_TOKEN
        sec
        jmp api_ret
.ctx:   lda #AI_ERR_CONTEXT
        sec
        jmp api_ret

; One token of work. A = AI_STEP_MORE or AI_STEP_DONE (carry clear).
api_generate_step:
        jsr .need_model
        bcc .lbx3_96
        jmp api_ret
.lbx3_96:
        lda AI_PB_CANCEL
        beq +
        lda #3
        sta gen_phase
        lda #AI_ERR_CANCELLED
        sec
        jmp api_ret
+       lda gen_phase
        cmp #1
        beq .prefill
        cmp #2
        beq .generate
        cmp #3
        bne +
        lda #AI_STEP_DONE
        clc
        jmp api_ret
+       lda #AI_ERR_STATE
        sec
        jmp api_ret
.prefill:
        ldx prompt_idx
        inx                     ; prompt ids are prompt_buf[1..len]
        stx prompt_idx
        lda prompt_buf,x
        sta cur_token
        lda #0
        cpx prompt_len
        bne +
        lda #1                  ; logits only for the last prompt token
+       sta want_logits
        jsr model_step
        bcc .lbx2_129
        jmp api_ret
.lbx2_129:
        lda prompt_idx
        cmp prompt_len
        bne .more
        lda #2
        sta gen_phase
        jmp .more
.generate:
        jsr sample
        lda best_tok
        sta AI_PB_LAST_TOKEN
        cmp m_eos
        beq .finish
        jsr out_append
        inc gen_count
        lda gen_count
        cmp AI_PB_MAX_CHARS
        bcs .finish
        lda ctx_pos
        cmp m_ctx
        bcs .finish             ; context full: stop cleanly
        lda best_tok
        sta cur_token
        lda #1
        sta want_logits
        jsr model_step
        bcs api_ret
.more:  lda #AI_STEP_MORE
        clc
        jmp api_ret
.finish:
        lda #3
        sta gen_phase
        lda #AI_STEP_DONE
        clc
        jmp api_ret

; Run steps until done, error or cancel.
api_generate:
-       jsr api_generate_step
        bcs api_ret
        cmp #AI_STEP_MORE
        beq -
        lda #AI_OK
        clc
        jmp api_ret

api_get_output:                 ; -> X/Y = out_buf (length byte + PETSCII)
        ldx #<out_buf
        ldy #>out_buf
        lda #AI_OK
        clc
        rts

api_release:
        lda #1
        sta eng_state           ; model forgotten; REU contents untouched
        lda #0
        sta gen_phase
        lda #AI_OK
        clc
        jmp api_ret

.need_model:
        lda eng_state
        cmp #2
        bcc +
        clc
        rts
+       lda #AI_ERR_NO_MODEL
        sec
        rts

api_ret:                        ; record the status, keep carry and A
        php
        sta AI_PB_STATUS
        lda ctx_pos
        sta AI_PB_POS
        lda AI_PB_STATUS
        plp
        rts

; ---------------------------------------------------------------- sampling
; Uses vec_l (logits, S256). Greedy when AI_PB_INV_TEMP == 0 or AI_PB_TOP_K <= 1.
; -> best_tok
!zone sample
sample:
        lda #<vec_l
        ldx #>vec_l
        ldy #S256
        jsr set_src
        ; candidate list: up to k emittable ids by (logit desc, id asc)
        lda AI_PB_TOP_K
        beq +
        cmp #9
        bcc ++
+       lda #1
++      sta tmp4                ; k (1..8)
        lda AI_PB_INV_TEMP
        ora AI_PB_INV_TEMP+1
        bne +
        lda #1
        sta tmp4                ; greedy
+       lda #0
        sta cand_n
        ldx #0
.scan:  stx cnt1
        lda tok_emit,x
        beq .next
        jsr vget                ; mA = logit
        jsr .insert
.next:  ldx cnt1
        inx
        cpx m_vocab
        bne .scan
        lda cand_tok
        sta best_tok
        lda tmp4
        cmp #2
        bcs .weighted
        rts
.weighted:
        ; w_i = exp_neg(round_shift((top - l_i) * inv_temp, 8)); top = cand 0
        lda #0
        sta att_F
        sta att_F+1
        sta att_F+2
        sta att_F+3
        lda #0
        sta lp1
.w:     ldx lp1
        txa
        asl
        asl
        tay                     ; cand_w index * 4
        ; delta = top - l_i (non-negative)
        sec
        lda cand_w
        sbc cand_w,y
        sta mA
        lda cand_w+1
        sbc cand_w+1,y
        sta mA+1
        lda cand_w+2
        sbc cand_w+2,y
        sta mA+2
        lda cand_w+3
        sbc cand_w+3,y
        sta mA+3
        lda AI_PB_INV_TEMP
        sta mB
        lda AI_PB_INV_TEMP+1
        sta mB+1
        lda #4
        sta mLenA
        lda #2
        sta mLenB
        jsr umul
        ldx #7
-       lda mP,x
        sta mA,x
        dex
        bpl -
        lda #8
        jsr round_shift64
        lda mA+4                ; huge delta: weight 0
        ora mA+5
        ora mA+6
        ora mA+7
        beq +
        lda #$ff
        sta mA+3
+       jsr exp_neg
        ldx lp1
        lda mP
        sta cand_wq0,x
        clc
        adc att_F
        sta att_F
        lda mP+1
        sta cand_wq1,x
        adc att_F+1
        sta att_F+1
        lda mP+2
        sta cand_wq2,x
        adc att_F+2
        sta att_F+2
        lda att_F+3
        adc #0
        sta att_F+3
        inc lp1
        lda lp1
        cmp cand_n
        beq .lbx1_322
        jmp .w
.lbx1_322:
        ; target = ((xorshift32 >> 8) * sum) >> 24
        jsr xorshift
        lda rng+1
        sta mA
        lda rng+2
        sta mA+1
        lda rng+3
        sta mA+2
        ldx #3
-       lda att_F,x
        sta mB,x
        dex
        bpl -
        lda #3
        sta mLenA
        lda #4
        sta mLenB
        jsr umul                ; target = mP[3..6]
        ; first candidate whose cumulative weight > target
        lda #0
        sta mT
        sta mT+1
        sta mT+2
        sta mT+3
        ldx #0
.pick:  clc
        lda mT
        adc cand_wq0,x
        sta mT
        lda mT+1
        adc cand_wq1,x
        sta mT+1
        lda mT+2
        adc cand_wq2,x
        sta mT+2
        lda mT+3
        adc #0
        sta mT+3
        ; cumulative > target ?  (compare target - cumulative < 0)
        sec
        lda mP+3
        sbc mT
        lda mP+4
        sbc mT+1
        lda mP+5
        sbc mT+2
        lda mP+6
        sbc mT+3
        bcc .chosen
        inx
        cpx cand_n
        bne .pick
        dex                     ; rounding: last candidate
.chosen:
        lda cand_tok,x
        sta best_tok
        rts

; insert token cnt1 with logit mA[0..3] into the candidate list (descending
; logit; equal logits keep the lower id first because ids arrive ascending)
.insert:
        ldx cand_n
.cmp:   cpx #0
        beq .place
        ; new > cand[x-1] ?  (signed: cand - new < 0)
        txa
        asl
        asl
        tay                     ; Y = 4x
        sec
        lda cand_w-4,y
        sbc mA
        lda cand_w-3,y
        sbc mA+1
        lda cand_w-2,y
        sbc mA+2
        lda cand_w-1,y
        sbc mA+3
        bvc +
        eor #$80
+       bpl .place              ; cand[x-1] >= new: new goes at x
        ; move cand[x-1] to x if x < k
        cpx tmp4
        bcs +
        lda cand_tok-1,x
        sta cand_tok,x
        lda cand_w-4,y
        sta cand_w,y
        lda cand_w-3,y
        sta cand_w+1,y
        lda cand_w-2,y
        sta cand_w+2,y
        lda cand_w-1,y
        sta cand_w+3,y
+       dex
        jmp .cmp
.place: cpx tmp4
        bcs .done               ; not among the best k
        lda cnt1
        sta cand_tok,x
        txa
        asl
        asl
        tay
        lda mA
        sta cand_w,y
        lda mA+1
        sta cand_w+1,y
        lda mA+2
        sta cand_w+2,y
        lda mA+3
        sta cand_w+3,y
        lda cand_n
        cmp tmp4
        bcs .done
        inc cand_n
.done:  rts

; xorshift32: x ^= x << 13; x ^= x >> 17; x ^= x << 5  (state in rng)
!zone xorshift
xorshift:
        ; t = x << 13 = (x << 8) << 5
        lda #0
        sta mT
        lda rng
        sta mT+1
        lda rng+1
        sta mT+2
        lda rng+2
        sta mT+3
        ldy #5
-       asl mT
        rol mT+1
        rol mT+2
        rol mT+3
        dey
        bne -
        jsr .xor_t
        ; t = x >> 17 = (x >> 16) >> 1
        lda rng+2
        sta mT
        lda rng+3
        sta mT+1
        lda #0
        sta mT+2
        sta mT+3
        lsr mT+1
        ror mT
        jsr .xor_t
        ; t = x << 5
        ldx #3
-       lda rng,x
        sta mT,x
        dex
        bpl -
        ldy #5
-       asl mT
        rol mT+1
        rol mT+2
        rol mT+3
        dey
        bne -
.xor_t: ldx #3
-       lda rng,x
        eor mT,x
        sta rng,x
        dex
        bpl -
        rts

; ---------------------------------------------------------------- output text
; Append the display text of best_tok (one character, or a letter group from
; tok_pool) to out_buf, capitalizing sentence starts.
!zone out_append
out_append:
        ldx best_tok
        lda tok_len,x
        cmp #2
        bcs .group
        lda tok_disp,x
        jmp out_char
.group: sta cnt1
        lda tok_off,x
        sta lp1
-       ldx lp1
        lda tok_pool,x
        jsr out_char
        inc lp1
        dec cnt1
        bne -
        rts

out_char:                       ; A = PETSCII character
        sta tmp0
        beq .done               ; no display form
        ldx out_buf
        cpx #255
        beq .done
        lda tmp0
        cmp #$41                ; letters $41-$5a
        bcc .other
        cmp #$5b
        bcs .other
        ldy cap_next
        beq .store
        ora #$80                ; PETSCII shifted letter ($c1-$da) = capital
        ldy #0
        sty cap_next
        jmp .store
.other: cmp #$2e                ; . ! ? start a new sentence
        beq .cap
        cmp #$21
        beq .cap
        cmp #$3f
        bne .store
.cap:   ldy #1
        sty cap_next
.store: inx
        sta out_buf,x
        stx out_buf
.done:  rts
