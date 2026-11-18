# DM64 Inference Engine v1 (ACME, 6502)

Status: Milestone 3, 2026-11-16. The engine runs in VICE and matches the Python integer reference bit for bit. **On the user's C64 Ultimate (64 MHz turbo registers) it loaded and verified the model and generated the same text as the reference, at about 0.85 s per forward pass** (docs/HW_RESULTS.md). Cycle figures below are VICE x64sc measurements (PAL, cycle-exact, 1 MHz) unless marked otherwise.

## 1. What exists

| Module | File | Role | Tested |
| --- | --- | --- | --- |
| Arithmetic | `engine/source/ai_math.asm` | Quarter-square 8×8 multiply, multi-byte multiply, 64/32 division, rounded division and shift, integer sqrt, exp table lookup | `tests/test_engine_math.py`: randomized, bit-exact vs `python/fixedpoint.py` |
| CRC32 | `ai_crc.asm` | zlib-compatible CRC over memory or REU ranges | via the loader tests |
| REU | `hw_reu.asm` | Fetch/stash with 512 KiB splitting; non-destructive detection and size | `tests/test_engine_load.py`: 16 MB and 512 KB REUs, contents preserved |
| Loader | `ai_load.asm` | `.d64ai` header checks, engine limits, payload CRC, directory, tokenizer tables | Valid images; bad signature, version, header and payload CRC rejected |
| Forward pass | `ai_model.asm`, `ai_attn.asm` | Embedding, RMSNorm, block packing, tiled matvec over the REU, int8 KV cache, attention, ReLU FFN, logits | `tests/test_engine_model.py`: q/k/v/attention/residual/logits identical to `python/reference_int.py` for every token (bring-up and baseline) |
| API, sampling, output | `ai_api.asm` | Jump table, prefill/generate state machine, greedy and top-k sampling, xorshift32, PETSCII output with sentence capitals. Multi-letter text tokens (bpe72) are printed from `tok_pool`. | `tests/test_engine_api.py`: generated text identical to the reference, greedy and sampled |
| Constants | `engine/source/generated/exp_table.asm` | exp(−i/64) table | Generated from `python/fixedpoint.py` by `tools/gen_engine_tables.py` |

**Hardware helpers (added in Milestone 4).** These are host-callable by label and not part of the jump table:

| Module | File | Role | Tested |
| --- | --- | --- | --- |
| Turbo | `hw_turbo.asm` | `turbo_on` (index 15 + badlines off, readback check) and `turbo_restore` | Hardware (checks 2–4). VICE path: `$D031` reads `$FF`. |
| Command Interface | `hw_uci.asm` | `uci_present`; `uci_load_model(path)`: OPEN_FILE, FILE_INFO size check, LOAD_REU to `$000000`, CLOSE, with a CIA2 timeout | Hardware (check 3, with the REU header damaged first). Not available in VICE. |

`AI_LOAD_MODEL` still only adopts an image that is already in the REU. A host calls `uci_load_model` first when it wants to load from a file, as the terminal does.

## 2. Using the engine

A host assembles the engine into its own program:

```text
!source "engine/include/memory.inc"
!source "engine/include/ai_api.inc"
; ... host code (below $2000 or above $c800) ...
!source "engine/source/engine.asm"      ; assembles at $2000
```

Minimal flow (`engine/tests/api_host.asm` is a complete example):

```text
        lda #$36 : sta $01      ; BASIC ROM out (engine tables live under it), KERNAL + I/O in
        jsr AI_INIT             ; tables, REU detection, parameter-block defaults
        bcs error
        ; optional: set AI_PB_MAX_CHARS, AI_PB_INV_TEMP, AI_PB_TOP_K, AI_PB_SEED, AI_PB_EXPECT_HASH
        jsr AI_LOAD_MODEL       ; image must be in the REU at $000000
        bcs error
        ldx #<prompt : ldy #>prompt
        jsr AI_SET_PROMPT       ; prompt = length byte, then token ids (from tokens.inc)
        bcs error
loop:   jsr AI_GENERATE_STEP    ; one token per call: keep the UI alive between calls
        bcs error
        cmp #AI_STEP_MORE
        beq loop
        jsr AI_GET_OUTPUT       ; X/Y -> length byte + PETSCII text
```

### Calling convention

- **Entry points** are a jump table at `$2000`: `AI_INIT $2000`, `AI_LOAD_MODEL $2003`, `AI_RESET_CONTEXT $2006`, `AI_SET_PROMPT $2009`, `AI_GENERATE_STEP $200C`, `AI_GENERATE $200F`, `AI_GET_OUTPUT $2012`, `AI_RELEASE $2015`.
- **Return:** carry clear means success, with A = `AI_OK` or a step status (`AI_STEP_MORE` / `AI_STEP_DONE`). Carry set means failure, with A = `AI_ERR_*`. The code is also stored in `AI_PB_STATUS`. X and Y are not preserved.
- **Parameter block** `AI_PB` at `$C5E0`, 32 bytes, field list in `engine/include/ai_api.inc`. `AI_INIT` resets it to defaults:
  - max 120 characters
  - greedy decoding (inverse temperature 0, top-k 1)
  - seed 1
  - CRC check on
  - no vocabulary-hash requirement
- **Cancel:** set `AI_PB_CANCEL` non-zero between steps. The next `AI_GENERATE_STEP` returns `AI_ERR_CANCELLED`.
- **Memory configuration:** `$01 = $36`. The engine never touches KERNAL vectors and does not need the KERNAL. Interrupts may stay enabled, but an IRQ handler must not use zero page `$10–$4F`, the REU registers, or the engine RAM listed below.
- **Not re-entrant.** Never call it from an interrupt.

### Error codes

| Code | Name | Meaning |
| --- | --- | --- |
| `$01` | NO_REU | No REU answered the detection |
| `$02` | REU_SMALL | REU smaller than 2 MB |
| `$04` | IO | REU DMA did not complete |
| `$05` | SIGNATURE | No `D64AI` image at REU `$000000` |
| `$06` | VERSION | Unsupported format major version |
| `$07` | ARCH | Header or tensor directory outside engine v1 limits |
| `$08` | CHECKSUM | Header or payload CRC32 mismatch |
| `$09` | VOCAB | Tokenizer hash mismatch, or differs from `AI_PB_EXPECT_HASH` |
| `$0A` | NOT_INIT | `AI_INIT` not called or failed |
| `$0B` | NO_MODEL | No model loaded |
| `$0C` | BAD_TOKEN | Empty prompt or token id ≥ vocab |
| `$0D` | CONTEXT | Prompt does not fit, or the context is full |
| `$0E` | CANCELLED | Host cancelled |
| `$10` | STATE | Call not valid now (for example generating without a prompt) |

### Engine v1 limits

These are checked at load and are tighter than the format allows:

- multi-letter text tokens: 240 bytes of strings in total (bpe72 needs 170)
- `AI_PB_MAX_CHARS` limits generated **tokens** (equal to characters for the char model)
- d_model ≤ 128 and divisible by heads
- heads and layers ≤ 8
- d_ff ≤ 256
- vocab ≤ 256
- **ctx ≤ 128**, so softmax sums stay below 2³¹
- tile ≤ 8 KiB
- image ≤ 1 MB at REU `$000000`

## 3. Memory used

| Range | Use |
| --- | --- |
| `$10–$4F` | Zero page (`memory.inc`) |
| `$2000–$48F0` | Engine code and hardware helpers (Milestone 7; the game needs it below `$5000`) |
| `$6000–$7D0F` | Vectors (Q16.16 byte planes), packed input, attention buffers, KV record. The host PRG carries the exp table at `$6000–$6C02`; the first `AI_INIT` copies it to REU `$1F0000` before the vectors are used |
| `$7D10–$7FFF` | Letter-group strings (`tok_pool`, 240 bytes), per-token display length and pool offset |
| `$8000–$9BFF` | REU DMA window for loading, attention and row tiles (7 KiB); during matvec: masks `$8000`, scales `$9000`, plane accumulators `$9101–$9700`, group inputs `$9741`, subset sums `$9800–$9AFF`, embedding row `$9B00` |
| `$9C00–$9DFF` | Generated matvec kernels (rebuilt by every matvec) |
| `$A000–$ACFF` | RAM under BASIC: quarter squares, CRC32 table, \|x\| table, built by `AI_INIT` |
| `$C000–$C5FF` | Token tables, directory, engine state, `AI_PB` at `$C5E0` |
| `$C600–$C7FF` | Prompt buffer, output buffer |
| REU `$000000–$0FFFFF` | Model image (read-only to the engine) |
| REU `$1F0000–$1F0C02` | exp table copy (`exp_neg` fetches 6 bytes per call) |
| REU `$100000+` | KV cache, `$10000` per layer |
| REU `$FF..` | Not used. Detection touches 4 bytes at `$000000` and at each 512 KB multiple, then restores them. |

## 4. Measured performance (VICE, 1 MHz cycles)

### Milestone 7 optimization (2026-11-17), `baseline_bpe72_v2`, format 1.1

| Item | Before (M6) | After (M7) |
| --- | ---: | ---: |
| Pack + 64×64 matvec | 1,014,594 (248 cycles/MAC) | 516,172 (126) |
| One RMSNorm | 576,912 | 405,164 |
| Token at position 0, with logits | 50,454,306 | 28,730,682 (**1.76×**) |
| Token at position 0, no logits | — | 26,411,865 |
| Token at position 40, no logits | not measured | 33,814,833 |
| Token at position 41, with logits | not measured | 36,344,527 |

All bit-exact with `python/reference_int.py` (fast tests on the bring-up models, slow test on the shipped model). Changes:

1. **Bitplane matvec** (`ai_matvec.asm`, layout 2): for each group of 8 inputs the engine builds the 256 subset sums once, then each weight bit costs one 24-bit table addition (a generated, unrolled kernel at `$9C00`, about 46 cycles per multiply-accumulate instead of about 200).
2. **Row finish:** a dedicated 32×24 quarter-square multiply and byte-plus-bit rounding shift instead of the generic 64-bit routines.
3. **Division:** `udiv64` runs 32 steps (compare, then subtract in place) when the quotient fits 32 bits — every RMSNorm and attention division.
4. **`umul`:** inline quarter-square products.
5. **Space:** the exp table moved from engine code to the REU, freeing 3 KB.

Where a position-40 token goes now (PC sampling in VICE): row kernel ~28%, subset-sum builds ~14%, attention ~10% plus its helpers, divisions ~10%, row finish ~10%. Further gains need structural changes (larger row blocks to share subset sums, fused Q/K/V).

**Projection, not measured:** hardware ran about 0.85 s per 50.5M-cycle step at 64 MHz, so 28.7M cycles should take about 0.5 s, about 3 characters/s with the letter-group model. A hardware run will settle it.

### Earlier measurements (format 1.0 engine)


From `tools/engine_profile.py` (`make profile MODEL=baseline`) and the test runs.

| Item | Baseline (d64 L4 ff256 V197) | Bring-up (d32 L2 ff64) |
| --- | ---: | ---: |
| `load_model` incl. payload CRC32 | 20,719,570 (233 KB image) | 3,392,733 (36 KB) |
| Embedding | 152,989 | — |
| One RMSNorm | 572,914 | — |
| Pack + 64×64 matvec | 1,008,045 (246 cycles/MAC) | — |
| Token at position 0, with logits | 48,190,817 (≈230 cycles/MAC) | ≈6.2M |
| Token cost late in a prompt | 50,439,110 (position 9) | 8,663,377 |

**Projection, not measured:** at 64 MHz with the same cycle count, one baseline token would take about 0.75 s. REU DMA, I/O and VIC behaviour on the Ultimate differ from VICE, so the real figure needs a hardware run (Milestone 4).

Where the time goes, in order of likely payoff:

1. Per-row scale and rounding in matvec. It uses generic multi-byte routines and is a large share of the 246 cycles/MAC.
2. RMSNorm divisions: 64 generic 64-bit divisions per norm, nine norms per token.
3. The inner multiply loop itself: self-modified quarter-square lookups, about 100–130 cycles per MAC by inspection.

Each optimization must keep `tests/test_engine_model.py` bit-exact.

## 5. Testing

- **`make test`:** fast set, about 3 minutes. Python tests plus the VICE engine tests on the bring-up model.
- **`make test-slow`:** adds the baseline forward-pass and generation runs in VICE (several minutes each).
- **`tools/vice_harness.py`:** drives `x64sc` through its binary monitor. It loads a PRG, runs it to a breakpoint, and reads memory and registers.
- **`tools/acme_longbranch.py`:** rewrites ACME "target out of range" branches into an inverted branch plus `JMP`, with unique labels.
