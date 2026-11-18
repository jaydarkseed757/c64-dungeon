# Reference Implementations: Tiny21 and llama2.c64

Status: Milestone 1 research, 2026-11-16.

This document compares the two reference projects named in `CLAUDE.md`. It records what was inspected, what was verified, and what remains unknown.

## Evidence labels

Every claim below carries one of these labels.

| Label | Meaning |
| --- | --- |
| **[SRC]** | Verified by reading the source file named. |
| **[RUN]** | Verified by running code on the Mac during this milestone. |
| **[DOC]** | Stated in the authoritative hardware documentation cited. |
| **[AUTHOR]** | Claimed by the reference author. Not independently reproduced. |
| **[DERIVED]** | Computed from other labelled figures. The inputs are shown. |
| **[OPEN]** | Unknown. Needs an experiment or more information. |

## What was inspected

| Item | Source | Revision | Location |
| --- | --- | --- | --- |
| llama2.c64 | https://github.com/ytmytm/llama2.c64 | `12b5bec82eb980362b8a7bfe86992a552a492481` (2025-04-30) | `reference/llama2.c64/` |
| Tiny21 (C64 port) | https://github.com/ReadyOS-C64/UltimateExperiments, folder `Tiny21/`, version 0.6 | `30089f7858bbb0f9bed199bffd67a8f256855171` (2026-11-15) | `reference/UltimateExperiments/Tiny21/` |
| Tiny 2.1 (upstream DOS original and checkpoint) | https://github.com/WollyMonjac/Tiny-2.1 | `1d5cf54677addf188a090ca1c91acb3d02989a1d` | `reference/Tiny-2.1/` |
| Tiny21 published pages | https://readyos-c64.github.io/UltimateExperiments/tiny21/ (index, TECHNICAL, DOWNLOAD, FUTURE) | fetched 2026-11-16 | not stored |

All three checkouts are unmodified clones. Nothing from them is copied into project source.

**Read in full:**

- llama2.c64: `transformer64.c/.h`, `nnet64.c`, `tokenizer64.c`, `sampler64.c`, `math.c`, `generate64.c`, `util64.c`, `llama2c64.c`, `generate-model-files.py`, `Makefile`, `README.md`, `config.bin` (hex dump).
- Tiny21: `src/reu.s`, `src/core.cfg`, `tools/model.py`, `tools/oracle.py`, `probe/clock.s`, `probe/README.md`, `docs/TECHNICAL.md` (via the web page), `README.md`, `LICENSE`, `Makefile`.
- Tiny 2.1 upstream: `README.md`, `README.TXT`.

**Read in part:** Tiny21 `src/dot.s` (quarter-square tables and setup), `src/dot_group8.s` (group-eight workspace), `src/attention_exp.s` (exp table interface), `src/network.s` (constants and exports), `tools/fetch_reference.py`. Not read: the rest of the Tiny21 assembly (`attention.s`, `wide.s`, `vector.s`, `cache.s`, `matrix.s`, `scale.s`, `embedding.s`), the probe console/UCI code, the Peddle emulator sources, `ui64.c` beyond its timing code, and upstream `TINY.C`.

**Run on the Mac [RUN]:**

1. The Tiny 2.1 checkpoint `TINY.BIN` has SHA-256 `4b603237…7e095`. This matches the value Tiny21 pins in `tools/model.py`.
2. The Tiny21 integer oracle (`tools/oracle.py`, pure Python, run with system Python 3.9.6) answered `what is 7 times 8` with `7 times 8 is 56.` at 34 positions. It answered `what is the capital of peru` with `Lima.` at 33 positions. Both match the published hardware answers.
3. The Tiny21 converter (`tools/model.py --layout group8`) produced a 380,995-byte image with SHA-256 `ba89630a…f61a1b`. This matches the size and hash of the published `MODEL.REU` on the DOWNLOAD page.
4. `tools/arch_sizing.py` (this project) reproduces both reference parameter counts. It gives 366,528 parameters for Tiny 2.1, against the upstream claim of 367,000. It gives 260,032 for stories260K. 260,032 × 4 bytes + 28 header bytes + 16,384 bytes of legacy RoPE tables = 1,056,540 bytes, which is exactly the size of `stories260K.bin`.

**Not run:**

- Neither C64 program was built. `ca65`/`ld65` (Tiny21) and `oscar64` (llama2.c64) are not installed on this Mac.
- Neither program was run in VICE or on hardware.
- No C64 Ultimate hardware was available in this milestone.

Every performance figure below is therefore [AUTHOR] or [DERIVED].

## Summary comparison

| Aspect | llama2.c64 | Tiny21 v0.6 |
| --- | --- | --- |
| Model | Karpathy `stories260K` (Llama-2 architecture) [SRC] | WollyMonjac Tiny 2.1 Q&A model [SRC] |
| Geometry | d=64, 5 layers, 8 query heads, 4 KV heads (GQA), head size 8, FFN 172 SwiGLU, vocab 512, ctx 512 [SRC `config.bin`] | d=96, 4 layers, 4 heads of 24, FFN 256 ReLU, vocab 97, ctx 128 [SRC `tools/model.py`] |
| Parameters | 260,032 [RUN] | 366,528 [RUN] |
| Positional encoding | RoPE [SRC] | Learned absolute [SRC] |
| Norm | RMSNorm, float [SRC] | RMSNorm, integer sqrt, Q4.12 gains [SRC] |
| Output head | Tied to embedding (`shared_weights=1`) [SRC] | Tied to embedding [SRC] |
| Tokenizer | SentencePiece BPE, 512 tokens, byte fallback [SRC] | Character: token = ASCII − 30, 0/1 special [SRC `oracle.py`] |
| Weights | IEEE float32, unchanged [SRC] | int8 per row, row scale Q0.24 [SRC] |
| Activations | float32 [SRC] | Q16.16 residual; int16 block-shifted dense inputs [SRC] |
| Weight bytes | 1,040,128 (2 MB REU image) [SRC/RUN] | 380,995-byte image [RUN] |
| KV cache | float32 in REU, 655,360 bytes for ctx 512 [DERIVED from source] | int8 + peak per vector in REU, 200-byte K+V record per position per layer [SRC/AUTHOR] |
| Sampling | Greedy, temperature, top-p [SRC] | Greedy only [SRC/AUTHOR] |
| Language/toolchain | C, Oscar64 compiler, Exomizer [SRC] | ca65/ld65 6502 assembly; Python tools; Peddle 6502 emulator for tests [SRC] |
| CPU assumption | Stock 1 MHz C64 [SRC/AUTHOR] | C64 Ultimate at 64 MHz, required [SRC/AUTHOR] |
| REU required | ≥ 2 MB [SRC] | 16 MB setting required [AUTHOR] |
| Reported speed | About 8 min per token at 1 MHz [AUTHOR, an estimate] | 0.795–0.829 generated chars/s at 64 MHz; 34–36 s per standard question [AUTHOR, measured on hardware] |
| Code license | README says MIT; no LICENSE file in the repository [SRC] | MIT, `LICENSE` file [SRC] |
| Model license | stories260K from `karpathy/tinyllamas`; license not checked [OPEN] | Upstream Tiny-2.1 has no license file [SRC]; terms unknown [OPEN] |

## llama2.c64 in detail

### Architecture and conversion

- `generate-model-files.py` reads the 7-int32 llama2.c header. A negative vocab means an untied classifier. It writes `config.bin` as eight `uint16` values: dim, hidden, layers, heads, kv_heads, vocab, seq_len, shared. The dump `40 00 ac 00 05 00 08 00 04 00 00 02 00 02 01 00` decodes to 64/172/5/8/4/512/512/1. [SRC/RUN]
- Weights are copied byte for byte after the 28-byte header. The 4-byte magic `L264` is prepended, and the file is padded to the next of 2, 4, 8 or 16 MB to make a VICE/Ultimate REU image. No validation of dimensions, NaNs or ranges is done. [SRC]
- `config.bin` and `tokenizer.bin` are compiled into the PRG with `#embed`. A different model needs a rebuild. [SRC]

### REU use

- The REU registers are accessed through a struct at `$DF00`: status, command, C64 address, 24-bit REU address, length, IRQ mask, address control. Command `$91` fetches from the REU into C64 RAM. Command `$90` stashes from the C64 into the REU. Both execute immediately because of the `$FF00` trigger bit. [SRC `transformer64.c`]
- Size check: the program reads the magic at REU `$000000`. It then checks for aliases at `$080000` and `$100000`, rejecting configurations below 2 MB. [SRC]
- The REU holds the weights, the `q` vector, the float32 key and value caches, and the attention-score buffer. C64 RAM holds `x`, `xb`, `xb2`, `hb`, `hb2`, logits and the RoPE cache. [SRC]
- Every matmul fetches one weight row at a time (`n*4` bytes per DMA). Softmax over attention scores does one 4-byte DMA per element, three passes, with read-modify-write. This is a heavy small-transfer pattern. [SRC `nnet64.c`]

### Inference flow and maths

- `forward()` follows llama2.c exactly: embedding, then for each layer RMSNorm, Q/K/V, RoPE, attention, output projection, residual, RMSNorm, SwiGLU FFN, residual; then the final norm and classifier. [SRC]
- Every prompt token runs the full forward pass, including the 512×64 classifier, even though the logits are discarded. [SRC `generate64.c`]
- `math.c` replaces Oscar64's `sin`, `cos` and `exp` with polynomials whose coefficients come from the C64 BASIC ROM. [SRC]
- Dimensions are held in `uint8_t`. The code assumes dim, hidden_dim and heads are below 256. [SRC]

### Defects and limits found by reading the source

These are observations from reading, not reproduced failures.

1. **RoPE is specialised to head size 8.** `rope()` derives each successive frequency with `val /= 10.0`. llama2.c uses θ = 10000^(−2i/head_size). That ratio is 10 per step only when head_size = 8, which is true for stories260K but not in general. [SRC]
2. **The top-p bubble sort is incorrect.** It compares `arr[j]` with `arr[j+1]` but swaps `arr[i]` with `arr[j]`. It is also called with `last_idx` (n0 − 1) as the count, so the last candidate is never sorted. Top-p output can therefore differ from llama2.c. Greedy and plain temperature sampling are unaffected. [SRC `sampler64.c`]
3. The README's "SCPU turbo gives wrong results" note is [AUTHOR], uninvestigated.
4. The README says no optimization flags beyond `-O0/-O1/-O2` work. [AUTHOR]

### Performance

- [AUTHOR] "one output token approximately every 8 minutes" at 1 MHz. This is labelled an estimate. Attention cost grows with position.
- [AUTHOR] The `feature-fastmult` branch (8×8 table multiply for floats, table in REU) was about twice as slow.
- [DERIVED] At about 260K MACs per token at position 0 (from `arch_sizing.py`), 8 min ≈ 480 M cycles per token, or roughly **1,800 cycles per MAC** at 1 MHz. This assumes the author's estimate and ignores attention growth and badline losses.

### What is reusable

- **Algorithms:** the clean reference ordering of a Llama-style forward pass, KV cache layout per layer, xorshift sampling, the sampling logic (with the sort fixed), the BPE encode/decode logic (if a BPE tokenizer is chosen), and the alias-based REU size check.
- **Not reusable:** the float32 numerical path (too slow), the Oscar64 C code itself (the runtime must be ACME assembly), and the model-specific RoPE shortcut.

## Tiny21 in detail

### Architecture and model format

- The checkpoint `TNY2` header has d=96, 4 layers, 4 heads, hidden 256. `decode()` rejects anything else. Matrices are stored row by row as `float32 scale + int8 weights`. Gains are 96 × float32. [SRC `tools/model.py`]
- Tensor order: embedding (97×96), position (128×96), then per layer g1, q, k, v, o (96×96 each), g2, f1 (256×96), f2 (96×256), then the final gain. [SRC]
- `T64M` REU image (versions 1–3, for the canonical, group4 and group8 layouts):
  - A 4,096-byte header holds magic, version, the d/L/H/hidden geometry, matrix count, payload length, gain base and source SHA-256.
  - A directory of `(offset u32, rows u16, cols u16)` entries starts at byte 64.
  - Matrices are stored in tiles of 16 rows. Each tile holds 16 rows of weight bytes followed by 16 three-byte Q0.24 scales.
  - Gains follow as int16 Q4.12. [SRC]
- **The engine is checkpoint-specific.** `network.s` hard-codes `MATRICES = 26`, `GAIN_BASE = 379267` and `IMAGE_SIZE`. The converter only accepts the pinned checkpoint SHA-256. The format does not support arbitrary architectures, as `CLAUDE.md` warned. [SRC]

### Tokenizer and decoding

- Token = ASCII code − 30 for printable ASCII (space→2 … `~`→96). Token 1 marks the end of the question and the start of the answer, and token ≤ 1 ends the answer. Input is truncated to 72 characters, trailing spaces are removed, and all-uppercase input is lowercased. [SRC `oracle.py`]
- Prompt tokens are ingested with `logits=False`, so the 97×96 output head is skipped during prefill. [SRC]
- Greedy decoding only. Ties keep the lowest token id. [SRC/AUTHOR]

### Fixed-point arithmetic [SRC `oracle.py`, AUTHOR `TECHNICAL`]

- The residual stream, normalization inputs and logits use signed Q16.16 (32-bit).
- **Dense input packing:** before each projection, the input vector is scaled to int16 by a shared right shift. The shift is chosen from the largest magnitude so the peak fits in 15 bits (block floating point). Each weight row keeps its int8 values. The products are accumulated, multiplied by the Q0.24 row scale, shifted back and rounded half away from zero.
- **RMSNorm:** the sum of squares plus d·ε goes into a wide accumulator. The integer square root keeps 8 fractional guard bits, then the Q4.12 gain is applied.
- **Attention:** the cache stores each K/V vector as int8 (value·127/peak) plus the peak. Scores include the peak and a Q0.24 1/√24. Softmax uses max-subtraction and a 1,025-entry table of exp(−i/64) in Q0.24, with linear interpolation. Deltas of 16.0 or more give zero.
- **Accuracy [AUTHOR]:** the integer path reproduced 63 of 64 complete holdout answers and 2,408 of 2,415 teacher-forced choices against the float original.

### 6502 techniques

- **Quarter-square multiply [SRC `dot.s`]:** a×b = ⌊(a+b)²/4⌋ − ⌊(a−b)²/4⌋. Tables `square_lo/hi` (512 entries) and `difference_lo/hi` (offset by 255) are page-aligned byte planes, 2 KiB in total. Weights use a magnitude/sign table. A signed 16-bit activation is multiplied as byte planes.
- **Subset-sum ("group-eight") dot product [SRC `dot_group8.s`, `model.py`; AUTHOR `TECHNICAL`]:**
  - Offline, every 8 consecutive int8 weights in a row are transposed into 8 bitplane masks, one byte per bit position.
  - At run time, for each group of 8 activations, the engine builds a 256-entry table of all subset sums (3 bytes each).
  - A row's dot product over that group is then Σ over bitplanes of `table[mask] << plane`, with the sign plane subtracted. That costs 8 lookups per 8 weights instead of 8 multiplies.
  - The table is built once per input vector and shared across all rows. Q, K and V share it because they have the same input.
  - The workspace occupies 9 KiB at `$8000–$9FFF` and `$C000–$C3FF`. Tiles stream into `$C400–$CAFF` while it is live.
  - v0.6 uses group-eight for Q/K/V/F1, group-four for O, and quarter-square for F2 and the embedding.
  - [AUTHOR] v0.6 used 10.92% fewer CPU cycles than the previous build.
- **Linker layout [SRC `core.cfg`]:** zero page `$80–$EF`, code `$1000–$4FFF`, BSS `$5000–$7FFF`, REU tile window `$8000–$9FFF` (8 KiB, `REU_TILE` in `reu.s`).

### REU and Ultimate hardware use

- **REU driver [SRC `reu.s`]:**
  - Programs the same `$DF02–$DF0A` registers as llama2.c64 and issues `$90 | direction`.
  - Checks status bit 6 after the transfer and fails if it is clear.
  - Validates that the C64 destination lies inside the tile window and that the REU span stays inside the configured capacity.
  - **Splits any transfer that crosses a 512 KiB boundary.** [AUTHOR `TECHNICAL`] "the hardware counter wraps there". This is consistent with the original 8726 controller having a 19-bit (512 KiB) address counter, but [OPEN] for this project until our own REU test confirms it.
- **Capacity qualification [AUTHOR/SRC probe README]:**
  - Writes tags at the end of each of 32 × 512 KiB banks and tests both directions across `$F7FFFF/$F80000`.
  - Checks `$FFFFFF`, then restores the original 544 bytes.
  - Detects aliased 8 MiB and 512 KiB configurations.
- **Turbo [SRC `clock.s`]:**
  - Reads `$D031`. `$FF` means the turbo registers are unavailable.
  - Writes `(old & $70) | $8F`: speed index 15 plus bit 7 to disable badline timing.
  - Verifies the readback, then times a fixed 329,217-cycle loop against cascaded CIA2 timers counting PHI2. It accepts 4,608–5,887 ticks (64 MHz) and rejects a 48 MHz board. The old value is restored on exit.
- **Model loading [SRC/AUTHOR]:**
  - Release path: the user selects `MODEL.REU` in the Ultimate file browser and chooses "Load into REU". The DOWNLOAD guide says the `.REU` extension is needed for the browser to offer that action.
  - The PRG computes a CRC32 of the REU contents to verify the image.
  - Developer path: Ultimate DOS through the Command Interface (open the file, `DOS_CMD_LOAD_REU` at address 0, close).
  - [AUTHOR] Loading 380,995 bytes took 0.214 s.

### Performance [AUTHOR unless stated otherwise]

- PAL C64 Ultimate at verified 64 MHz, firmware 3.14, FPGA 121, core 1.47. Times come from CIA2 PHI2 counts.
- `what is 7 times 8` took 36.321 s and `what is the capital of peru` took 34.442 s for v0.6. An earlier build took 48.294 and 46.008 s.
- 0.795–0.829 generated characters per second, measured from first output.
- The full 128-position context took 213.084 s.
- REU transfer microbenchmarks:

  | Path | 1 MHz | 64 MHz |
  | --- | ---: | ---: |
  | One 4 KiB DMA | 0.854 MiB/s | 3.984 MiB/s |
  | Sixteen 256-byte DMA calls | 0.407 MiB/s | 3.050 MiB/s |
  | One DMA per byte | 0.00277 MiB/s | 0.0557 MiB/s |
  | Unrolled internal RAM copy | 0.101 MiB/s | 6.330 MiB/s |

- The GeoRAM aperture failed verification on the tested unit.
- **[DERIVED]** The 7×8 question uses 34 positions in 36.3 s, or about 1.07 s per position. At an assumed ~354K–452K MACs per position (`arch_sizing.py`, positions 0–127; prefill positions skip the 9K-MAC head), that is roughly **150–190 cycles per MAC at 64 MHz**, all overheads included. This is about 10× fewer cycles per MAC than the llama2.c64 estimate.
- **[DERIVED]** One full forward pass streams about 380 KB of weights. At 3.98 MiB/s that is about 0.09 s of DMA per position, under 10% of the ~1.07 s total. Compute dominates.

### What is reusable

- **Techniques to reimplement independently in ACME:**
  - int8 per-row weights with Q0.24 scales
  - int16 block-shifted activations
  - Q16.16 residual
  - integer RMSNorm with guard bits
  - int8 + peak KV cache
  - exp-table softmax
  - quarter-square multiply
  - subset-sum bitplane dot products (as a later optimization)
  - prefill without logits
  - 512 KiB DMA splitting
  - REU capacity qualification with save/restore
  - turbo register setup with timer verification
  - CRC32 model admission
  - Python integer oracle as the bit-exact reference for the assembly
- **Not reusable:** the ca65 source as-is (wrong assembler, and checkpoint-specific constants), the `T64M` format, and the Tiny 2.1 checkpoint (no license, Q&A domain).

## Side-by-side assessment

| Question | llama2.c64 | Tiny21 | Implication for Dungeon Master 64 |
| --- | --- | --- | --- |
| Is the numerical path fast enough? | No (float32, ~1,800 cycles/MAC derived) | Much closer (~150–190 cycles/MAC derived, at 64 MHz) | Use integer weights and activations |
| Does the format support new architectures? | Partly (config is generic; RoPE is not) | No (hard-coded constants) | Design a new self-describing format |
| Tokenizer cost on the 6502 | BPE with merge loop, binary search, `sprintf` | Trivial arithmetic map | Character-level core plus structured control tokens (see ARCHITECTURE.md) |
| Proof on real Ultimate hardware | Ultimate II+ load instructions only | Yes, measured | Follow Tiny21's verification discipline |
| Bit-exact host reference | Float llama2.c (same maths) | Python integer oracle | Build our own integer oracle first |

**Recommendation:** use neither project as a code base. Adopt Tiny21's numerical scheme and verification approach as the starting design, reimplemented independently in ACME for our own self-describing format. Use llama2.c64 as the readable reference for the forward-pass structure and sampling. Details are in `ARCHITECTURE.md`.

## License and attribution constraints

| Artifact | License | Constraint for this project |
| --- | --- | --- |
| llama2.c64 code | MIT per README only; no LICENSE file in the repository | Do not copy code. If any snippet is adapted later, credit Maciej Witkowiak and note the missing license file. |
| llama2.c (upstream of llama2.c64) | MIT (Karpathy); not re-checked in this milestone | Algorithmic reference only |
| stories260K weights, TinyStories data | [OPEN]; not used | Not used. We train our own model. |
| Tiny21 C64 port | MIT, © 2026 Ultimate Experiments contributors | Techniques reimplemented, not copied. Credit in docs. If code is ever adapted, keep the MIT notice. |
| Peddle 6502 emulator | MIT, © 2022 Dirk Hoffmann | Optional host test tool only; keep its notice if vendored |
| Tiny 2.1 upstream code and checkpoint | No license file found | Do not redistribute or reuse `TINY.BIN` or `TINY.C`. Used here only for local verification of the Tiny21 oracle. |

## Open questions

1. [OPEN] Does the 512 KiB DMA wrap occur on the C64 Ultimate REU? Planned test: the REU qualification in `FEASIBILITY_AND_RISKS.md`.
2. [OPEN] Why is REU DMA faster at 64 MHz (3.98 MiB/s) than one byte per 1 MHz cycle? Is the throughput stable across firmware versions?
3. [OPEN] Do the cycles-per-MAC figures hold for our narrower geometry (d=64)? Per-row overhead becomes a larger share as rows get shorter.
4. [OPEN] What license applies to stories260K? It is irrelevant unless we use it as a test vector.
5. [OPEN] Can llama2.c64 be built and run in VICE to obtain an independent cycle count? This needs `oscar64`. It is optional and low priority.

## Follow-up (Milestones 3–4)

- **Question 2 (DMA speed): answered** for the user's unit. DMA at 64 MHz is about 4.2× faster than at 1 MHz (c64-tyrian measurement), matching Tiny21's figure.
- **Question 3 (cycles per MAC at d=64): answered.** Our engine needs about 230 cycles/MAC in VICE and about 0.85 s per forward pass at 64 MHz. Tiny21's derived figure is 150–190. The difference is mostly per-row overhead (docs/ENGINE.md section 4).
- **Question 1 (512 KiB wrap):** still open.
