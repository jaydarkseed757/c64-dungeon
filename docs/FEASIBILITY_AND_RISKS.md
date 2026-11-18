# Feasibility, Performance Plan and Risks

Status: Milestone 1, 2026-11-16. No benchmark in this document has been run by this project. Measured figures are attributed to their authors. Our own numbers will be recorded in `docs/BENCHMARKS.md` as they are obtained, always labelled VICE or HARDWARE.

## 1. Feasibility verdict

**Feasible, with speed as the dominant risk.**

**Evidence that it can work:**

- Tiny21 runs a 367K-parameter int8 transformer in native 6502 assembly on a physical C64 Ultimate at 64 MHz with a 16 MB REU [AUTHOR, with published hardware evidence].
- Its Python integer oracle reproduces the published answers on this Mac [RUN].
- Its quantized image matches the published binary byte for byte [RUN].
- Our baseline (d=64, 4 layers) needs about 60% of Tiny21's MACs per token (`tools/arch_sizing.py`).
- Our control-token prompts are far shorter than Tiny21's character prompts.

**What is unknown:**

- Whether a ~200K-parameter model trained on our fantasy corpus writes acceptable 1–3 sentence narration. This is a model-quality risk.
- Whether response times are tolerable in a game. Tiny21's derived rate is about 1 s per character at 64 MHz. A 120-character response at that rate would take about two minutes. Our baseline is smaller, but we have no measurement.
- C64 Ultimate details we have not tested ourselves: the REU 512 KiB wrap, DMA speed, the turbo register names on current firmware, and `.REU` menu loading.

## 2. Where the time goes

Per generated token, from the source analysis in `REFERENCE_IMPLEMENTATIONS.md`:

1. **Dense matvecs.** These dominate. For the baseline, 196,608 of the 209,408 MACs at position 0 are layer weights, and 12,288 are the output head.
2. **Attention.** 2 × (pos+1) × d MACs per layer. At position 127 this is 65,536 MACs, about 24% of that token's work. It also includes exp lookups per head and position.
3. **REU transfers.** About 226 KB of weights plus the live KV prefix per token. At Tiny21's 3.98 MiB/s for 4 KiB DMAs that is roughly 0.05–0.07 s per token [DERIVED; our rate unmeasured]. This is a small fraction if compute stays near Tiny21's level.
4. **Norms, packing, sampling, tokenizing.** Small, linear in d or vocab.
5. **Model admission.** The CRC32 over ~230 KB is a one-time cost per load.

## 3. Arithmetic candidates

The candidates are compared on cost per MAC on a 6502 and on accuracy. Nothing here is measured yet. "Ops" are rough operation descriptions, not cycle counts.

| Format | Inner-loop work per MAC | Accuracy | Notes |
| --- | --- | --- | --- |
| float32 (llama2.c64) | Software float multiply + add | Reference | ~1,800 cycles/MAC at 1 MHz [DERIVED from AUTHOR estimate]. Host reference only. |
| INT16 weights × INT16 activations | Four 8×8 products + 32-bit add | Best integer | 2× REU traffic; about 2× the MAC work of 8×16 |
| **INT8 weights × INT16 activations** (baseline) | Two 8×8 quarter-square products + 24/32-bit add | Tiny21: 63/64 exact answers [AUTHOR] | Proven path |
| INT8 × INT8 | One 8×8 product + 16/24-bit add | Lower. Activation quantization error. | Up to ~2× faster inner loop; needs a quality check |
| INT8 weights, bitplane subset-sum (Tiny21 group-8) | ~8 table lookups + adds per 8 weights, plus a 256-entry table build per 8 inputs | Exact with respect to int8 × int16 | Amortizes well for wide matrices sharing an input (Q/K/V); [AUTHOR] gave ~10% overall saving over group-4 |
| INT4 weights | Bitplane approach with 4 planes | Likely too lossy at this size | Halves REU traffic, which is not the bottleneck |

Lower precision is not automatically faster. The cost is the 6502 multiply and add sequence, not memory traffic. INT8 × INT8 saves a multiply but adds activation re-quantization. Bitplanes trade multiplies for table construction. Each candidate is benchmarked in isolation and then in the full forward pass.

## 4. Benchmark plan

Every benchmark runs through a shared harness:

- **Timer:** cascaded CIA2 Timer A/B counting PHI2, as Tiny21 does in `clock.s`. Raw tick counts are kept.
- **Configurations:** VICE x64sc PAL (1 MHz, cycle-exact, with `-reu -reusize 16384`), then C64 Ultimate at 1 MHz and at 64 MHz with badlines disabled. VICE does not emulate `$D031`, so turbo can only be measured on hardware.
- **Screen:** blank the VIC (`$D011` bit 4 = 0) for compute benchmarks. Repeat with the screen on to measure the game-relevant case.
- **Output:** a result block written to a known RAM address, read back by VICE monitor or the Ultimate REST/FTP tooling, and saved as JSON under `benchmarks/results/` with environment, firmware, engine commit and model hash.

| ID | Benchmark | Measures | Pass/record |
| --- | --- | --- | --- |
| B1 | REU register access | Time for 1,000 `$DF00` reads/writes | Settles the internal vs. external bus question |
| B2 | REU DMA throughput | 1 B, 256 B, 4 KiB, 8 KiB fetch/stash; crossing 512 KiB | MiB/s at 1 and 64 MHz; wrap behaviour |
| B3 | REU qualification | Capacity detection, alias detection, save/restore integrity | Pass/fail + detected size |
| B4 | Turbo | Set index 15 + badline off, calibrated loop ticks; restore | Effective MHz; register readback |
| B5 | Multiply kernels | 8×8, 8×16 signed quarter-square, 10,000 random pairs vs. Python | Cycles/op, bit-exact |
| B6 | Dot product | 64-, 96-, 256-column int8 × int16 rows | Cycles per MAC (overhead per row reported separately) |
| B7 | Matvec | Full Wq (64×64), W1 (256×64), W2 (64×256) including DMA | Cycles; DMA share |
| B8 | Attention | Positions 0, 31, 63, 127 | Cycles per head per position |
| B9 | Forward pass | Full token at positions 0 and 127, prefill vs. generate | Ticks/token; compare with oracle logits |
| B10 | Tokenization | Typed prompt of 72 chars; control-token record | Ticks |
| B11 | Model load | UCI LOAD_REU time; CRC32 admission time; preloaded path | Seconds |
| B12 | End-to-end response | 10 fixed prompts, greedy, 120-char cap | Time to first char, total, chars/s |
| B13 | Memory footprint | Code/table sizes from the ACME symbol file; REU bytes used | Bytes (static) |
| B14 | Format/size comparison | B9 and B12 for bring-up, small, baseline, Tiny21-geometry, int8 × int8 variant | Quality (validation loss, agreement) vs. speed table |

Speed estimates are "unknown" until B6/B9 run. Nothing is extrapolated into the README.

## 5. Accuracy plan

- **`python/reference_int.py`:** our integer oracle, using the same arithmetic as the planned ACME code, bit for bit. The assembly must match its logits **exactly** for every token in the test prompts. Any mismatch is a bug in one of them.
- **Float vs. integer:** report the top-1 agreement rate over validation sequences (teacher-forced), the validation loss for both, and the complete-response match rate on fixed prompts. This follows Tiny21's methodology.
- **Range analysis:** the oracle records the maximum magnitude of every accumulator per tensor over the validation set. Accumulator widths (24 vs. 32 bit) are chosen from these maxima with margin. Debug builds trap overflow.

## 6. Risk register

L = likelihood, I = impact (H/M/L), where reasonably assessable.

| # | Risk | L | I | Mitigation | Resolving experiment |
| --- | --- | :-: | :-: | --- | --- |
| R1 | **Inference too slow for gameplay** (minutes per response) | H | H | Small model; control-token prompts; prefill without logits; step API so the game stays responsive; short outputs with a sentence budget; KV prefix caching; optimization ladder (unroll, subset-sum, int8 × int8) | B6, B9, B12 on hardware with the bring-up then baseline model |
| R2 | **Model architecture incompatibility** between the trained model and the engine | M | H | One arch id; the converter validates against engine limits; the engine checks the header; tiny bring-up model exercises all code paths early | Package the bring-up model; loader unit tests with deliberately malformed images |
| R3 | **Numerical accuracy loss** from int8/fixed point | M | H | Tiny21 scheme (proven); quantization-aware fine-tuning if needed; range analysis | Float vs. int agreement report in M2; assembly vs. oracle bit-exactness in M3 |
| R4 | **Poor narrative quality** at ~200K parameters | H | H | Narrow domain; structured inputs; templated + varied synthetic corpus; evaluate before engine work depends on it; allow d96 if quality demands | M2: train bring-up/small/baseline/d96, human-rated sample sheets + validation loss |
| R5 | **Training data quality/licensing** | M | H | Original procedural generator + hand-written seed text; document provenance; no commercial game text; decide whether LLM-assisted authoring is acceptable | Dataset validation tests (duplicates, length, charset, coverage per control token) |
| R6 | **REU access and allocation** (wrap at 512 KiB, capacity detection, conflicts with UCI masking `$DF1B–$DF1F`) | M | M | Split at 512 KiB; non-destructive alias test; never touch `$DF0B+` from the REU driver | B2, B3 in VICE and on hardware |
| R7 | **Turbo configuration** (menu setting not enabled; 48 vs. 64 MHz boards; naming differs by firmware) | M | M | Detect `$FF`; calibrate the actual speed; run at 1 MHz with a warning; document the menu setting | B4 on hardware; record firmware version |
| R8 | **Tokenizer size/complexity** | L | M | Char + control tokens = table lookups; BPE only if it clearly wins | M2 BPE vs. char comparison (chars/token, loss, 6502 work) |
| R9 | **Assembly debugging complexity** | H | M | Tiny kernels tested individually against Python; trace dumps of every intermediate tensor; VICE monitor scripts; optional Python-hosted 6502 emulator for unit tests | Harness bring-up is the first M3 task |
| R10 | **Emulator vs. hardware differences** (no turbo in VICE; DMA timing; UCI absent in VICE) | H | M | VICE for correctness and cycle counts only; every performance claim from hardware; UCI path tested on hardware, preloaded path in VICE | B1–B4 on hardware early |
| R11 | **Conventional memory pressure** once the game is added | M | M | Fixed 40 K engine budget; game overlays from the REU; VIC bank move | Size report (B13) at each milestone |
| R12 | **Ultimate menu won't preload `.d64ai`** | M | L | Distribute as `DM64AI.REU`; UCI load path | Hardware test of the menu action |
| R13 | **Upstream license ambiguity** (llama2.c64 has no LICENSE file; Tiny 2.1 checkpoint unlicensed) | L | M | Copy no code; reimplement from documented techniques; credit sources | Already applied in M1 docs |
| R14 | **Hardware availability for benchmarking** | [OPEN] | H | Plan VICE-first; batch hardware sessions | Confirm access to a C64 Ultimate with 16 MB REU and firmware details |

## 7. Unresolved hardware questions

1. Is REU register and DMA access on the C64 Ultimate subject to the 1 MHz external-bus rule? (B1/B2)
2. Does REU DMA address counting wrap at 512 KiB on the C64 Ultimate? (B2/B3)
3. Which firmware versions name the option "C64U Turbo Registers" vs. "U64 Turbo Registers"? Does the C64 Ultimate use the U64E2 speed table (index 15 = 64 MHz)? The docs list only the U64 and U64E2 tables. (B4)
4. Does REU DMA run during badlines with badline timing disabled? How much does the screen-on case cost? (B9 with the screen on and off)
5. With the REU enabled and no cartridge, is `$8000–$9FFF` plain RAM on the C64 Ultimate? (Simple RAM test)
6. Can the Ultimate menu "Load into REU" a file with a non-`.REU` extension? (Manual test)
7. Is the Command Interface enabled by default? Which menu setting is required? (Manual test; documented in DEVELOPMENT.md)

## 8. Hardware evidence from the user's other projects (added Milestone 3, 2026-11-16)

The user's sibling projects record measurements made on **their own C64 Ultimate**: Starlight Edition, firmware 1.1.0, FPGA 122, core 1.49, PAL-60. They were measured by those projects, not by this one. Sources: `../c64-tyrian/docs/hw-results.md` and `DECISIONS.md`, and `../c64-meshcore/docs/REU.md`.

| Question (section 7) | Evidence | Status for DM64 |
| --- | --- | --- |
| REU registers and capacity on the C64U | 16 MB detected; 256 banks; 8-bit bank register; `$DF00` reads `$10`. Non-destructive detection verified on the same machine (meshcore). | **Answered** for this unit. Our detector still needs its own hardware run. |
| REU DMA speed | 16 KB REU→C64: 16,407 cycles at 1 MHz with the screen off (≈1 byte/cycle). 3,906 CIA cycles at 64 MHz (4.2× faster). This agrees with Tiny21's 3.98 MiB/s. | **Answered:** DMA is not limited to the 1 MHz bus rate |
| Turbo register name and speed | Menu "C64U Turbo Registers": `$D031` reads `$00`. Index 15 measured ≈59× (64 MHz). CIA timers stay at 1 MHz, so they remain a valid time base. | **Answered** (firmware 1.1.0) |
| Turbo with a cartridge active | No effect in any turbo mode while a cartridge runs | **Constraint:** DM64 must ship as a PRG, never a cartridge |
| EasyFlash + REU | EasyFlash disables the REU | Same constraint |
| Getting the model into the REU | "REU Preload" loads an image only at power-on, from settings saved to flash. Resets keep REU contents. A REST reboot does not load a changed image. The USB path is `/USB1`. | Model delivery: preload, or the menu's "Load into REU", or UCI. The engine verifies the image on every start (it already does: header + payload CRC). |
| 512 KiB DMA wrap | Not tested by those projects | **Still open.** The engine splits transfers anyway. |
| Command Interface default | Menu item "Command Interface" (`$DF1C–$DF1F`) defaults to Disabled | Needed only for loading from a file (Milestone 4) |

Reusable tooling in those projects:

- FTP deploy: `../ultimate-dist/ultimate_dist.py`, `../c64-tyrian/tools/ultftp.py`
- REST-driven hardware tests: c64-tyrian
- Loadable Ultimate settings files with a checker: `../c64-meshcore/docs/ultimate-config.md`, `tools/ultimate/check_cfg.py`

## 9. Status after Milestone 4 (2026-11-16)

| Risk | Status |
| --- | --- |
| R1 inference speed | **Measured:** ≈0.85 s per forward pass at 64 MHz, ≈1 character per second. A 1–2 sentence answer takes 30–110 s. Usable for a narrator with a "thinking" display; optimization (per-row scaling, RMSNorm division) is the next lever. |
| R2 architecture compatibility | Closed for arch 1. The converter, independent validator, engine loader and vocabulary-hash check all agree. |
| R3 numerical accuracy | Closed. 99.8% float/int top-1 agreement; engine bit-exact with the reference in VICE and on hardware. |
| R4 narrative quality | Open. Context-faithful but repetitive; free text is weak. |
| R5 training data | Open. The phrase bank is AI-authored; the user decision is pending. |
| R6 REU access | Closed for detection, DMA, model admission and file loading on the user's unit. The 512 KiB wrap is still untested (transfers are split anyway). |
| R7 turbo | Closed. `$D031` index 15 works from a PRG. It needs the menu's "C64U Turbo Registers"; it does nothing under a cartridge (c64-tyrian). |
| R9 assembly debugging | Mitigated: VICE binary-monitor harness, per-kernel bit-exact tests, hang localization by PC sampling |
| R10 emulator vs hardware | Same results bit for bit. Loading at 1 MHz was 11% slower on hardware than in VICE (cause not investigated). |
| R14 hardware access | Resolved: REST/FTP to the user's unit (no password); settings changed only per run and restored |
