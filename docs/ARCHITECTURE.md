# Architecture

Status: written as the Milestone 1 proposal; **implemented in Milestones 2–4** (2026-11-16). The design held. Implementation deviations, marked (M2)/(M3) where they occur:

- **KV cache:** int8 with per-head power-of-two exponents.
- **Attention scale:** 1/√head_dim folded into Wq.
- **exp table:** capped at 2²⁴−1.
- **Engine v1 limits:** ctx ≤ 128 and d_ff ≤ 256.
- **Entry points:** `AI_GENERATE_STEP` (one token per call) is the main API.
- **Hardware helpers:** turbo and UCI are separate modules called by the host, not inside `AI_LOAD_MODEL`.

The implemented details live in `docs/ENGINE.md`, `docs/INFERENCE.md`, `docs/MODEL_FORMAT.md` and `docs/TERMINAL.md`.

Evidence labels follow `REFERENCE_IMPLEMENTATIONS.md`. Parameter and MAC counts come from `tools/arch_sizing.py` (`python3 tools/arch_sizing.py`). MAC means multiply-accumulate.

## 1. System overview

```text
 Mac (host)                                          C64 Ultimate (target)
 ─────────────────────────────                       ─────────────────────────────────────────
 tools/dataset_generator.py  ─┐                      ┌───────────── game (ACME) ─────────────┐
 python/tokenizer.py          │ datasets/            │ map, movement, combat, loot, quests   │
 python/model.py, train.py    ├─► checkpoint          │ owns ALL authoritative state          │
 python/quantize.py           │                      └───────┬───────────────────────────────┘
 python/reference_int.py  ◄───┤ bit-exact oracle             │ DM interface: context record → text
 python/convert.py/package.py ┴─► DM64AI.REU (.d64ai) ─USB─► │  (fallback text if AI unavailable)
                                   + manifest.json      ┌────▼──────── inference engine (ACME) ──┐
                                   + dm64_tokens.inc    │ AI_INIT / LOAD / RESET / SET_PROMPT    │
                                                        │ GENERATE_STEP / GET_OUTPUT / RELEASE   │
                                                        └────┬───────────────────────────────────┘
                                                             │ hw layer: REU DMA, UCI, turbo, timer
                                                        ┌────▼────┐
                                                        │ 16 MB   │ model image, KV cache, scratch
                                                        │ REU     │
                                                        └─────────┘
```

There are four independent components, as `CLAUDE.md` requires.

1. **Python toolchain:** data, tokenizer, training, quantization, a bit-exact integer reference, and packaging.
2. **Inference engine:** an ACME library with a fixed jump table. It knows nothing about the game.
3. **Game:** ACME. It owns all state. It works with AI disabled.
4. **DM interface:** a thin ACME module in the game. It turns game state into a context-token record, calls the engine, and falls back to stock text on any error.

## 2. Recommended model architecture

### 2.1 Decision summary

| Choice | Recommendation | Main reason |
| --- | --- | --- |
| Family | Decoder-only transformer, pre-norm | Standard; both references prove it on a C64 |
| Tokens | **Character-level text plus structured control tokens**, vocab ≤ 256 (one-byte ids) | Trivial 6502 tokenizer and very short prompts (see 2.2) |
| Width d | **64** baseline; 48 and 96 as experiments | Fits 8-bit loop counters; 4 heads of 16 |
| Layers | **4** | Middle of the research range |
| Heads | **4**, head size 16 | Small; mirrors Tiny21's 4-head layout |
| FFN | **ReLU, 4×d = 256** | No exp/sigmoid per hidden unit and 2 matrices instead of 3 (Tiny21 proves ReLU) |
| Norm | RMSNorm | Cheap; integer sqrt proven by Tiny21 |
| Positions | **Learned absolute** | No sin/cos at run time; avoids llama2.c64's RoPE shortcut |
| Context | **128** baseline; test 192/256 | Bounded prompt plus 1–2 sentences of output |
| Output head | Tied to token embedding | Saves vocab×d parameters |
| Weights | int8, one Q0.24 scale per row | Tiny21 shows 63/64 exact answers vs float [AUTHOR] |
| Activations | int16 block-shifted dense inputs; Q16.16 residual | Same scheme; proven overflow behaviour |
| KV cache | int8 + 16-bit peak per vector, in REU | 4× smaller than int16; Tiny21-proven |
| Decoding | Greedy (tests) and temperature with top-k ≤ 8 (play) | Top-k needs no full sort |

### 2.2 Character-level vs. token-level vocabulary

| Factor | Character (≈48 text symbols) | BPE 512 (llama2.c64 style) |
| --- | --- | --- |
| 6502 tokenizer | One 256-byte PETSCII → id table | Merge loop, string compares, score table; complex and slow [SRC llama2.c64] |
| Sequence length | ~1 token per char | Fewer tokens per char. [OPEN] The real ratio on our corpus has to be measured. |
| Output head cost/token | vocab×d = 12,288 MACs (V=192) | 32,768 MACs (V=512) |
| Parameters (d64 L4) | 217,664 | 238,144 |
| Quality at fixed parameters | Spelling errors possible | Usually better wording [OPEN] |
| Generated characters per forward pass | 1 | >1 |

A pure character model makes structured game context expensive. The example prompt in `CLAUDE.md` is about 100 characters. At ctx 128 that leaves little room for output, and every prompt character costs one forward pass.

**The proposal combines both:** text is generated character by character, and the game context is given as **control tokens**. Each control token is a single vocabulary id that stands for one slot value. Examples are `‹ROOM:BURIAL_CHAMBER›`, `‹MON:SKELETON›`, `‹ACT:EXAMINE›` and `‹HP:LOW›`.

```text
‹BOS›‹TASK:ROOM›‹LOC:CRYPT›‹ROOM:BURIAL_CHAMBER›‹MON:SKELETON›‹ACT:EXAMINE›‹OBJ:SARCOPHAGUS›‹HP:MID›‹SEP›
  → "the lid grinds aside. bones stir in the dark below."
```

That prompt is 9 tokens instead of about 100 characters. The AI terminal can still accept typed text through a `‹TASK:FREE›` token followed by characters.

Proposed vocabulary layout:

- ids 0–4: specials (PAD, BOS, EOS, SEP, UNK)
- ids 5–63: text symbols
- ids 64–255: up to 192 control tokens

The converter emits `dm64_tokens.inc` so the game uses symbolic ids. A vocabulary hash in the model header must match the hash compiled into the game.

**Case handling:** train on single-case text and let the output module capitalize after sentence ends. This saves 26 vocabulary entries and model capacity. It can be revisited if the quality is poor.

**BPE remains a Milestone 2 experiment.** Train a BPE-256/512 model on the same corpus. Measure characters per token and validation loss. Count the 6502 work per token. Adopt BPE only if it wins on characters per second with acceptable tokenizer complexity.

### 2.3 Candidate geometries

All candidates use int8 weights. Bytes include 3-byte row scales. KV bytes are for the full context.

| Candidate | Params | int8 bytes | KV bytes | MAC/token @pos 0 | MAC/token @pos 127 | Head MACs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Bring-up D32 L2 H2 F64 V96 C64 | 21,664 | 23,488 | 8,704 | 19,584 | 27,648 | 3,072 |
| Small D48 L3 H3 F128 V160 C128 | 78,672 | 82,848 | 39,168 | 72,480 | 109,056 | 7,680 |
| **Baseline D64 L4 H4 F256 V192 C128** | **217,664** | **225,536** | **69,632** | **209,408** | **274,432** | **12,288** |
| D64 L4 H4 F192 V192 C128 | 184,896 | 192,000 | 69,632 | 176,640 | 241,664 | 12,288 |
| BPE512 D64 L4 H4 F256 V512 C128 | 238,144 | 246,976 | 69,632 | 229,888 | 294,912 | 32,768 |
| Tiny21 geometry D96 L4 H4 F256 V97 C128 | 366,528 | 376,035 | 102,400 | 354,144 | 451,680 | 9,312 |
| D128 L4 H4 F384 V192 C128 | 697,472 | 710,720 | 135,168 | 680,960 | 811,008 | 24,576 |

The "@pos 127" column is computed at position 127 (the 128th token), or the last position for C64.

The bring-up model exists to validate the engine end to end quickly in VICE. It is not meant to produce good text.

**Speed:** no wall-clock prediction is made here. Tiny21's hardware result works out to roughly 150–190 cycles per MAC at 64 MHz [DERIVED]. At a similar efficiency, the baseline has about 60% of Tiny21's MACs per token. Whether that holds for d=64 is [OPEN], since per-row overhead weighs more on shorter rows. It is the first thing Milestone 3 measures.

### 2.4 Memory footprint (baseline)

- **Weights:** about 226 KB in the REU. They are streamed once per forward pass.
- **KV cache:** 69.6 KB in the REU (int8 K and V plus one exponent byte per head; updated M2).
- **C64-resident activations:**
  - residual x: 64 × 4 bytes
  - normalized input: 64 × 4 bytes
  - packed int16 input: 64 × 2 bytes
  - q, k, v: 3 × 64 × 4 bytes
  - attention out: 64 × 4 bytes
  - hidden: 256 × 4 bytes
  - logits: 192 × 4 bytes
  - total: about 3.3 KB
- **Tables:** quarter-square 2 KB, exp 3 KB, CRC32 1 KB.

See `MEMORY_MAP.md`.

## 3. Inference engine design

### 3.1 Modules

| Module | Responsibility | Status |
| --- | --- | --- |
| `ai_api.asm` | Jump table, parameter block, state machine, error codes | New |
| `hw_reu.asm` | Detect, size, DMA (splits at 512 KiB), save/restore probe bytes | New; technique from both references |
| `hw_uci.asm` | Ultimate Command Interface: DOS open/LOAD_REU/close | New, from Ultimate docs |
| `hw_turbo.asm` | `$D031` detect/set/restore, CIA timer calibration | New, from Ultimate docs; Tiny21 shows the verification idea |
| `hw_timer.asm` | Cascaded CIA2 timer for benchmarks | New |
| `ai_load.asm` | Header and directory parse, compatibility checks, CRC32 | New |
| `ai_tokenizer.asm` | PETSCII → id table, control-token append, id → display string | New, simple |
| `ai_math.asm` | Quarter-square 8×8 multiply, 8×16 signed, 32-bit add/shift/round, isqrt, exp table | New; technique from Tiny21 |
| `ai_matvec.asm` | int8-row × int16-vector dot products over REU tiles, row scale, shift | New; the hot loop |
| `ai_norm.asm` | RMSNorm, residual add, ReLU, vector pack | New |
| `ai_attention.asm` | KV append (int8 + peak), scores, softmax by table, weighted sum | New |
| `ai_transformer.asm` | Embedding + position, layer loop, final norm, logits (skipped during prefill) | New |
| `ai_sampling.asm` | Greedy, temperature, top-k, xorshift RNG | New; logic from llama2.c64 |
| `ai_context.asm` | Position counter, overflow rejection, reset | New |
| `ai_output.asm` | Decoded text buffer, capitalization rule, length and EOS limits | New |

`CLAUDE.md` suggested `ai_embedding/ai_feedforward/ai_reu`. These are folded into `ai_transformer/ai_norm/hw_reu`. Hardware drivers are split out because the game needs them too.

### 3.2 Calling convention

- **Entry:** fixed jump table at the engine base (`ENGINE_BASE + 3·n`). A host can be linked against `engine/include/ai_api.inc` without knowing internals.
- **Parameters:** a 32-byte **parameter block** `AI_PB` at a fixed address in engine RAM, plus X/Y = lo/hi of a pointer where a call needs a buffer.
- **Return:** carry clear means success. Carry set means error, with **A = error code** (also stored at `AI_PB+0`). X and Y are undefined. The engine preserves `$01` (memory configuration), the I flag, and the host's zero page outside the engine's reserved range.
- **Re-entrancy:** none. The host must not call the engine from an IRQ handler.
- **IRQs:** left enabled. IRQ handlers must not touch engine zero page, the REU registers, or the tile window. REU DMA stalls the CPU, so long DMAs delay IRQs.
- **Memory configuration:** the engine expects I/O visible at `$D000–$DFFF`. It may bank BASIC out but never touches KERNAL vectors.

| Call | Inputs | Effect |
| --- | --- | --- |
| `AI_INIT` | — | Detect REU and capacity, turbo availability, build tables. Returns capability flags in `AI_PB`. |
| `AI_LOAD_MODEL` | X/Y → filename (PETSCII, NUL-terminated), or `AI_PB.flags.preloaded` | Load via UCI or adopt a preloaded image; verify header, compatibility and CRC32 |
| `AI_RESET_CONTEXT` | — | Position = 0, KV invalidated |
| `AI_SET_PROMPT` | X/Y → token buffer (len, ids…) | Validate ids and length; queue for prefill |
| `AI_GENERATE_STEP` | `AI_PB`: temperature, top-k, max chars, seed | Process **one** token (prefill or generate); return status: MORE / DONE / error |
| `AI_GENERATE` | same | Convenience loop over `STEP`, polling the cancel flag between tokens |
| `AI_GET_OUTPUT` | — | X/Y → output buffer (len, PETSCII) |
| `AI_RELEASE` | — | Mark the REU regions free; restore turbo if the engine changed it |
| `AI_CANCEL` | (a flag byte, not a call) | The host sets `AI_PB.cancel`; checked between tokens and layers |

`GENERATE_STEP` is the key to a responsive game. The game can redraw, animate or read the joystick between tokens. A token takes on the order of a second at 64 MHz [DERIVED from Tiny21], so a per-layer step mode is a possible refinement.

**Error codes:**

| Code | Name |
| --- | --- |
| `$00` | OK |
| `$01` | NO_REU |
| `$02` | REU_TOO_SMALL |
| `$03` | FILE_NOT_FOUND / UCI unavailable |
| `$04` | IO_ERROR |
| `$05` | BAD_SIGNATURE |
| `$06` | BAD_VERSION |
| `$07` | UNSUPPORTED_ARCH (dimension or format outside engine limits) |
| `$08` | CHECKSUM |
| `$09` | VOCAB_MISMATCH |
| `$0A` | NOT_INITIALIZED |
| `$0B` | NO_MODEL |
| `$0C` | BAD_TOKEN |
| `$0D` | CONTEXT_FULL |
| `$0E` | CANCELLED |
| `$0F` | NUMERIC_OVERFLOW (an accumulator range guard tripped) |

A missing turbo is a capability flag, not an error. The engine still runs at 1 MHz.

### 3.3 Zero page

- **Engine:** `$10–$4F` (64 bytes). This holds pointers for matvec, accumulators, multiply table pointers and the DMA parameters.
- **Host/game:** `$50–$8F`.
- **KERNAL:** `$90–$FF`, left alone so the KERNAL keyboard and screen routines work.
- **Unused:** `$02–$0F` stays free for host use.

The exact allocation is fixed in `engine/include/memory.inc` during Milestone 3. It is documented in `MEMORY_MAP.md`.

### 3.4 Model loading workflow

1. Run `AI_INIT`. It finds the REU, measures capacity non-destructively (save → tag → check aliases → restore), and records the capacity.
2. Check for a preloaded image. Fetch the 256-byte header from REU `$000000`. If the signature, version and header CRC are valid, compute the payload CRC32 by streaming through the tile window. If it matches, the model is adopted. This is the Tiny21 "preloaded" path, and it suits the Ultimate menu's "Load into REU".
3. If there is no valid image and the Command Interface responds at `$DF1D` (identification `$C9` [DOC]), use the UCI path. Open the file with `DOS_CMD_OPEN_FILE`, load it with `DOS_CMD_LOAD_REU` at address 0 for the file length, close it, then return to step 2.
4. Run the compatibility checks:
   - The architecture id is supported.
   - d ≤ 128 and divisible by the head count.
   - d_ff ≤ 512.
   - vocab ≤ 256.
   - ctx ≤ 256.
   - Weight, activation and norm format codes are known.
   - The image length is within capacity, and the KV region fits.
   - The vocabulary hash matches the host's expectation (game builds only).
5. Parse the tensor directory into an engine table of REU offsets.

### 3.5 Forward pass (per token)

```text
x  = tok_emb[id] · row_scale + pos_emb[pos] · row_scale              (Q16.16)
for layer in 0..L-1:
    n  = rmsnorm(x, g_att[layer])         ; isqrt, guard bits, Q4.12 gain
    p  = pack_int16(n)                    ; shared shift from peak magnitude
    q,k,v = matvec(Wq|Wk|Wv, p)           ; int8 rows × int16, Σ in 32-bit, row scale, shift back
    kv_append(layer, pos, k, v)           ; int8 + peak → REU
    a  = attention(q, KV[layer][0..pos])  ; per head: scores, max, exp-table, weighted V sum
    x += matvec(Wo, pack_int16(a))
    n  = rmsnorm(x, g_ffn[layer])
    h  = relu(matvec(W1, pack_int16(n)))
    x += matvec(W2, pack_int16(h))
if generating: logits = matvec(tok_emb, pack_int16(rmsnorm(x, g_final)))
```

**Matvec:**

- Weight rows stream from the REU in tiles of R rows (R × cols bytes followed by R × 3 scale bytes). The tile window is 8 KiB. Large DMAs are about 30% more efficient than 256-byte DMAs on the Ultimate [AUTHOR Tiny21].
- The inner loop multiplies an int8 weight by an int16 activation with two 8×8 quarter-square lookups. It accumulates in 32 bits.
- Self-modifying operand addresses are allowed in this loop and documented.

**Optimization ladder** (each step is gated by bit-exact agreement with the Python oracle):

1. Correct baseline: generic loop.
2. Unrolled inner loop, table pointers in zero page, per-input precomputation of sign and magnitude (`active_columns` idea from Tiny21 `dot.s`).
3. Subset-sum bitplane dot products for matrices with 96- or 64-column rows. This needs a model layout code for bitplane-transposed tiles (reserved in `MODEL_FORMAT.md`).
4. Test int8 × int8 activations. One lookup per MAC, but lower accuracy. Adopt only if the quality metrics hold.

**Attention** (Tiny21 scheme, reimplemented):

- Scores = q·k × peak_k × (1/√16) as a Q0.24 constant.
- Softmax by max-subtraction and a 1,025-entry exp(−i/64) table with interpolation.
- The value pass reuses the last key tile.
- KV records are laid out per layer as contiguous `[pos][K int8 ×d | V int8 ×d | ke u8 ×H | ve u8 ×H]` so one DMA fetches a run of positions. **(M2)** Per-head power-of-two exponents replace the per-vector peak, so a score needs only a shift (see `docs/INFERENCE.md`).

**Prefill:** prompt tokens skip the final norm and the logits matvec, as Tiny21 does.

### 3.6 Sampling and output

- **Greedy:** argmax over Q16.16 logits. Ties go to the lowest id. This is the deterministic test mode.
- **Temperature + top-k:**
  - Keep the top k ≤ 8 logits with an insertion pass (no full sort).
  - Divide by temperature, which is a Q8.8 reciprocal table entry.
  - Exponentiate with the exp table relative to the max, then draw from the CDF with a 32-bit xorshift RNG.
- **Seeding:** from CIA timer, raster and jiffy clock bytes (as llama2.c64 does), or from a fixed seed for reproducibility.
- **Constraints the engine always applies:**
  - Never emit control tokens or PAD as text. Mask ids ≥ 64 except EOS.
  - Stop at EOS, at the max-characters limit, or at `CONTEXT_FULL`.
  - A "sentence budget" option stops after N sentence terminators.
- **Output:** PETSCII text. It is capitalized after `.`/`!`/`?` and at the start. The game is responsible for word wrap in its window.

### 3.7 Context management

- Position runs from 0 to ctx−1. Token ctx is rejected with `CONTEXT_FULL` without corrupting state. Tiny21's full-context diagnostic shows this approach.
- `AI_RESET_CONTEXT` makes requests independent. The DM interface sends a fresh bounded context record per request, as `CLAUDE.md` requires.
- **Later optimization:** cache the KV state of common prompt prefixes (for example the room description context) in REU scratch, so follow-up actions on the same room skip prefill. 16 MB makes this cheap in space.

### 3.8 Error handling principles

- Every hardware or format failure maps to an error code. Nothing is retried forever. UCI waits use CIA-timed deadlines.
- No call leaves the engine half-initialized. A failed `AI_LOAD_MODEL` leaves the state at NO_MODEL.
- Range guards on accumulator high bytes are compiled in for debug builds and report NUMERIC_OVERFLOW. Release builds rely on bounds proven by the Python oracle on the validation set.
- The game treats any non-OK result as "use fallback text".

## 4. Dungeon Master interface

- The game builds a context record: task, location, room type, up to 2 objects, up to 1 monster with a health band, the player health band, the action, the outcome (success/fail/locked/killed…), and up to 1 quest flag.
- `dm_context.asm` maps the record to control-token ids from `dm64_tokens.inc`. It calls `AI_RESET_CONTEXT`, `AI_SET_PROMPT`, then `AI_GENERATE_STEP` repeatedly from the main loop while showing "DUNGEON MASTER THINKING…".
- **Outcome is always an input, never an output.** The game decides "the door is locked", and the model only narrates `‹ACT:OPEN›‹OBJ:DOOR›‹OUT:LOCKED›`.
- **Fallbacks:** every event type has stock text, indexed by the same record, stored in game data (C64 RAM or REU). It is used when `AI_INIT` or `AI_LOAD_MODEL` failed, on any generation error, on cancel, or when the player turns AI off.

## 5. Inspiration vs. new work

| Area | Taken as inspiration | Must be newly implemented |
| --- | --- | --- |
| Numerics | Tiny21: int8 row weights, Q0.24 scales, int16 block shift, Q16.16, isqrt with guard bits, exp table | All ACME code; our own oracle and bounds analysis for d=64 |
| Multiply | Tiny21 quarter-square; subset-sum bitplanes | ACME kernels; bitplane tile layout in our format |
| REU | Both: register use; Tiny21: 512 KiB split, qualification | Driver, allocator, our capacity check |
| Turbo | Tiny21: `$D031` + timer verification; Ultimate docs | Our module with a 1 MHz fallback |
| Loading | Tiny21: preloaded REU + CRC32 + UCI fallback | `.d64ai` parser, compatibility checks |
| Forward pass | llama2.c64: readable structure; Tiny21: prefill without logits | Generic over d/L/H/F/V/C within limits |
| Tokenizer | Tiny21: arithmetic character map | Control-token scheme, PETSCII tables |
| Sampling | llama2.c64: temperature, xorshift | Integer top-k with exp table; token masking |
| Format | Tiny21: tiled rows with scales; llama2.c64: header idea | Versioned self-describing `.d64ai` |
| Testing | Tiny21: Python oracle, emulator harness, hardware probes | Our harness (VICE and/or a Python 6502 emulator) |
