; ai_api.inc - public interface constants of the DM64 engine v1.
; See docs/ENGINE.md for the calling convention.

; ---- entry points (jump table at the engine base) ----
AI_INIT            = $2000
AI_LOAD_MODEL      = $2003
AI_RESET_CONTEXT   = $2006
AI_SET_PROMPT      = $2009
AI_GENERATE_STEP   = $200c
AI_GENERATE        = $200f
AI_GET_OUTPUT      = $2012
AI_RELEASE         = $2015

; ---- error codes (A on return with carry set; also AI_PB_STATUS) ----
AI_OK              = $00
AI_ERR_NO_REU      = $01
AI_ERR_REU_SMALL   = $02
AI_ERR_NO_FILE     = $03
AI_ERR_IO          = $04
AI_ERR_SIGNATURE   = $05
AI_ERR_VERSION     = $06
AI_ERR_ARCH        = $07
AI_ERR_CHECKSUM    = $08
AI_ERR_VOCAB       = $09
AI_ERR_NOT_INIT    = $0a
AI_ERR_NO_MODEL    = $0b
AI_ERR_BAD_TOKEN   = $0c
AI_ERR_CONTEXT     = $0d
AI_ERR_CANCELLED   = $0e
AI_ERR_OVERFLOW    = $0f
AI_ERR_STATE       = $10    ; call not valid in the current state

; ---- AI_GENERATE_STEP results (A with carry clear) ----
AI_STEP_MORE       = $00    ; call again
AI_STEP_DONE       = $01    ; output complete

; ---- parameter block (32 bytes) ----
AI_PB              = $c5e0
AI_PB_STATUS       = AI_PB + 0   ; last error code
AI_PB_CAPS         = AI_PB + 1   ; bit0 REU present, bit1 REU >= 2 MB, bit2 turbo registers seen
AI_PB_REU_MB       = AI_PB + 2   ; detected REU size in MB (0 = < 1 MB)
AI_PB_MAX_CHARS    = AI_PB + 3   ; generation limit (characters)
AI_PB_INV_TEMP     = AI_PB + 4   ; 2 bytes: round(256 / temperature); 0 = greedy
AI_PB_TOP_K        = AI_PB + 6   ; candidates for sampling (1..8)
AI_PB_SEED         = AI_PB + 7   ; 4 bytes xorshift32 state (non-zero)
AI_PB_CANCEL       = AI_PB + 11  ; host sets non-zero to cancel generation
AI_PB_FLAGS        = AI_PB + 12  ; bit0: skip payload CRC check (development only)
AI_PB_POS          = AI_PB + 13  ; current context position (read-only)
AI_PB_LAST_TOKEN   = AI_PB + 14  ; last generated token id (read-only)
AI_PB_EXPECT_HASH  = AI_PB + 16  ; 4 bytes: expected vocab hash, 0 = do not check

; REU allocation (docs/MEMORY_MAP.md)
REU_MODEL_BASE     = $000000
REU_MODEL_LIMIT    = $100000
REU_KV_BASE        = $100000
REU_KV_LAYER_STRIDE = $010000
