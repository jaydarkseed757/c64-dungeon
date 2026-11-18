; engine.asm - DM64 inference engine v1 (ACME). Include from a host program
; after the engine includes:
;     !source "engine/include/memory.inc"
;     !source "engine/include/ai_api.inc"
;     ...host code...
;     !source "engine/source/engine.asm"
; The engine assembles at ENGINE_BASE ($2000). Public entry points are the jump
; table at engine_start (docs/ENGINE.md).

!source "engine/source/ai_state.asm"

* = ENGINE_BASE
engine_start:
; ---- public jump table (addresses fixed; see engine/include/ai_api.inc) ----
        jmp api_init            ; $2000 AI_INIT
        jmp api_load_model      ; $2003 AI_LOAD_MODEL
        jmp api_reset_context   ; $2006 AI_RESET_CONTEXT
        jmp api_set_prompt      ; $2009 AI_SET_PROMPT     (X/Y -> len, ids)
        jmp api_generate_step   ; $200c AI_GENERATE_STEP
        jmp api_generate        ; $200f AI_GENERATE
        jmp api_get_output      ; $2012 AI_GET_OUTPUT     (-> X/Y)
        jmp api_release         ; $2015 AI_RELEASE
!source "engine/source/ai_math.asm"
!source "engine/source/ai_crc.asm"
!source "engine/source/hw_reu.asm"
!source "engine/source/hw_turbo.asm"
!source "engine/source/hw_uci.asm"
!source "engine/source/ai_load.asm"
!source "engine/source/ai_model.asm"
!source "engine/source/ai_matvec.asm"
!source "engine/source/ai_api.asm"

; engine_init: tables, REU detection. Carry set + A = error if no usable REU.
!zone engine_init
engine_init:
        ; parameter block defaults (the host may change them after engine_init)
        ldx #31
        lda #0
-       sta AI_PB,x
        dex
        bpl -
        lda #120
        sta AI_PB_MAX_CHARS
        lda #1
        sta AI_PB_TOP_K
        sta AI_PB_SEED          ; seed = 1 (xorshift state must be non-zero)
        jsr math_init
        jsr crc_init
        lda #0
        sta eng_state
        jsr reu_detect
        bcc +
        lda #AI_ERR_NO_REU
        rts
+       lda reu_mb
        sta AI_PB_REU_MB
        lda #1
        sta AI_PB_CAPS
        lda reu_mb
        cmp #2
        bcs +
        lda #AI_ERR_REU_SMALL
        sec
        rts
+       jsr exp_to_reu
        lda #$03
        sta AI_PB_CAPS
        lda #1
        sta eng_state
        lda #AI_OK
        clc
        rts

; First call after the PRG was loaded: copy the exp table (assembled at EXP_DATA, in
; vector RAM) to REU_EXP. Later calls do nothing: the vectors may hold data by then.
exp_to_reu:
        lda exp_copied
        bne +
        lda #<exp_tab
        sta reu_c64
        lda #>exp_tab
        sta reu_c64+1
        lda #<REU_EXP
        sta reu_adr
        lda #>REU_EXP
        sta reu_adr+1
        lda #^REU_EXP
        sta reu_adr+2
        lda #<(EXP_ENTRIES * 3)
        sta reu_len
        lda #>(EXP_ENTRIES * 3)
        sta reu_len+1
        jsr reu_stash
        inc exp_copied
+       rts
exp_copied: !byte 0             ; in the PRG image: 0 after every load

engine_end:
* = EXP_DATA
!source "engine/source/generated/exp_table.asm"
* = engine_end
!if engine_end > $6000 { !error "engine code exceeds $2000-$5fff" }
