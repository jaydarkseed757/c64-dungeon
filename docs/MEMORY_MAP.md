# Memory Map

Status: updated in Milestone 4, 2026-11-16. **The authoritative addresses are now in `engine/include/memory.inc` and `engine/include/ai_api.inc`; docs/ENGINE.md section 3 summarizes the implemented layout.** Section 2 below is the Milestone 1 plan. Differences:

- The engine tables moved from `$C000` host space into `$C000–$C7FF`, leaving the host `$C800–$CFFF`.
- The exp table lives inside the engine image.
- KV records use per-head exponent bytes.
- The zero-page assignment differs in detail.

The implemented layout runs on the user's C64 Ultimate (docs/HW_RESULTS.md).

## 0. Implemented layout (engine v1 + AI terminal)

**Milestone 7:** the exp table now lives in the host PRG at `$6000` (vector RAM) and in REU `$1F0000` after `AI_INIT`; the engine code ends at `$48F0`.


| Range | Owner | Use |
| --- | --- | --- |
| `$10–$4F` | engine | Zero page |
| `$50–$59` | terminal | Zero page (pointers, temps) |
| `$90–$FF`, `$0200–$03FF` | KERNAL | Preserved. The KERNAL IRQ stays on for the keyboard, jiffy clock and STOP. |
| `$0400–$07E7` | terminal | Text screen, mixed-case character set (`$D018 = $17`) |
| `$0801–$12B6` | terminal | Code (below `$2000`, enforced at assembly) |
| `$2000–$4E2C` | engine | Code, jump table at `$2000`, hardware helpers, exp table |
| `$4E2D–$557B` | terminal | Scene tables and texts (below `$6000`, enforced) |
| `$6000–$7D0F` | engine | Vectors, packed input, attention buffers, KV record |
| `$8000–$9FFF` | engine | REU DMA window (7 KiB general use) + matvec work areas and generated kernels at `$9C00` (Milestone 7, `docs/ENGINE.md` section 3) |
| `$A000–$ACFF` | engine | RAM under BASIC: quarter squares, CRC32 table, \|x\| table |
| `$C000–$C7FF` | engine | Token tables, directory, state, `AI_PB` (`$C5E0`), prompt and output buffers |
| `$C800–$C9FF` | terminal | State block (`$C800` `"DMT1"`), input, prompt, word buffer |
| `$0801–$16BE`, `$5000–$5E81`, `$B500–$BDBF` | game | Dungeon game code and data (`DM64GAME.PRG`, Milestone 5). The game is a separate program from the terminal; in Milestone 6 it is assembled together with the engine. |
| `$AD00–$B4FF` | game | Map, 64 × 32 tiles |
| `$C800–$C9DF` | game | Game state, monsters, items, rooms, log, `dm_ctx` narration record |
| REU `$000000–$0FFFFF` | model | `.d64ai` image. Read-only to the engine, except the UCI loader writing it. |
| REU `$100000+` | engine | KV cache, `$10000` per layer |

## 1. Hardware facts this map relies on

| Fact | Source |
| --- | --- |
| The REU controller registers sit at `$DF00–$DF0A`: status, command, C64 address (2), REU address (3), length (2), IRQ mask, address control. Command `$90` = C64→REU, `$91` = REU→C64, both executed immediately. | Commodore 1700/1750 REU User's Guide (8726 REC); used identically in llama2.c64 `transformer64.c` and Tiny21 `src/reu.s` [SRC]. Bit-level confirmation against the guide is still to be done before coding (Milestone 3). |
| The Ultimate Command Interface uses `$DF1B–$DF1F`, which masks the last five REU registers. It must be enabled in the Ultimate menu. `$DF1D` reads `$C9` as identification. | [Core UCI Architecture](https://1541u-documentation.readthedocs.io/en/latest/uci/core_uci_architecture.html) [DOC] |
| `DOS_CMD_LOAD_REU ($21)` loads the open file into the REU at a 32-bit address for a 32-bit length. It does not wrap; it truncates at the end of the REU. It "assumes a 16 MB REU configuration". | [Ultimate DOS Target](https://1541u-documentation.readthedocs.io/en/latest/uci/ultimate_dos_target.html) [DOC] |
| `$D031` (U64 Turbo Control) exists only when the menu's Turbo Control is set to "U64 Turbo Registers" or "Turbo Enable Bit". Otherwise it reads `$FF`. Bits 0–3 are the speed index (on the U64E2, index 15 = 64 MHz). Bit 7 = 1 disables badline timing. | [Turbo mode settings](https://1541u-documentation.readthedocs.io/en/latest/config/turbo_mode.html) [DOC] |
| On firmware 3.14 the menu option is named "C64U Turbo Registers". | Tiny21 DOWNLOAD/probe README [AUTHOR] |
| Accesses to the external cartridge bus always run at 1 MHz and respect BA (badlines) even in turbo. The VIC still takes priority. | Turbo mode settings page [DOC] |
| REU DMA requests crossing a 512 KiB boundary must be split. | Tiny21 [AUTHOR]; [OPEN] to be confirmed by our REU test |

[OPEN] Is the C64 Ultimate's REU and `$DF00` register access "internal" (turbo speed) or "external" (1 MHz bus)? Tiny21's measurements (3.98 MiB/s DMA at 64 MHz vs 0.854 at 1 MHz) suggest DMA is not limited to one byte per 1 MHz cycle. Our register-access and DMA benchmarks will settle it.

## 2. Conventional C64 memory (engine + AI terminal build)

The memory configuration while running is `$01 = $36`: BASIC ROM out, KERNAL and I/O in. Using RAM under the KERNAL (`$E000–$FFFF`) is deferred. It would need `$01` switching around every KERNAL call and IRQ.

| Range | Size | Owner | Use |
| --- | ---: | --- | --- |
| `$0000–$0001` | 2 | CPU | 6510 port |
| `$0002–$000F` | 14 | host | free for host |
| `$0010–$004F` | 64 | **engine** | engine zero page (see §3) |
| `$0050–$008F` | 64 | host/game | host zero page |
| `$0090–$00FF` | 112 | KERNAL | preserved |
| `$0100–$01FF` | 256 | CPU | stack |
| `$0200–$03FF` | 512 | KERNAL | buffers and vectors, preserved |
| `$0400–$07E7` | 1000 | VIC | text screen (bank 0); `$07F8–$07FF` sprite pointers |
| `$0801–$1FFF` | ~6 K | host | BASIC stub, AI terminal UI, prompt editor |
| `$2000–$5FFF` | 16 K | **engine** | engine code + small constant tables (budget) |
| `$6000–$6FFF` | 4 K | **engine** | activations, logits, prompt/token buffers, directory table |
| `$7000–$7FFF` | 4 K | **engine** | exp table (1,025 × 3 = 3,075 B) + ~1 K spare |
| `$8000–$9FFF` | 8 K | **engine** | REU tile window (DMA target). Cartridge ROML is absent when no cartridge is active; the Ultimate's cartridge emulation must be off. [OPEN: confirm the REU-only configuration leaves `$8000` as RAM] |
| `$A000–$BFFF` | 8 K | **engine** | RAM under BASIC: quarter-square tables (2 K, page aligned) + CRC32 table (1 K) + 5 K reserved for subset-sum workspace |
| `$C000–$CFFF` | 4 K | host/game | output text buffer, game state, fallback text (terminal build mostly free) |
| `$D000–$DFFF` | 4 K | I/O | VIC, SID, CIA, `$D031` turbo, `$DF00` REU, `$DF1C` UCI |
| `$E000–$FFFF` | 8 K | KERNAL ROM | not used for data |

The engine budget is 40 K (`$2000–$BFFF`). Activations for the baseline model are about 3.3 KB (`ARCHITECTURE.md` §2.4). For d=128 they are about 7 KB, which still fits in `$6000–$6FFF` plus spill.

**Game build (Milestone 5+):** the game needs code, maps, a character set and sprites. The likely approach is to move the VIC to bank 3 (`$C000–$FFFF`), with the screen and charset under the KERNAL area or at `$C000`. Game logic stays in `$0801–$1FFF` plus overlays from the REU. The engine region stays fixed so the engine binary does not change between terminal and game. This is a [OPEN] decision for Milestone 5.

## 3. Engine zero page (`$10–$4F`) — planned allocation

| Range | Use |
| --- | --- |
| `$10–$17` | quarter-square table pointers (plus/minus, lo/hi) |
| `$18–$1F` | matvec: weight pointer, activation pointer, column counter, row counter |
| `$20–$27` | 32-bit accumulator + 32-bit product temp |
| `$28–$2F` | REU request: C64 address (2), REU address (3), length (2), direction (1) |
| `$30–$37` | general pointers (source, destination, gains) |
| `$38–$3F` | attention: position counter, head index, tile counters |
| `$40–$47` | RNG state (4), sampler temporaries |
| `$48–$4F` | reserved |

Engine routines may clobber only this range plus A/X/Y and flags. IRQ handlers must not use it.

## 4. REU allocation (16 MB, `$000000–$FFFFFF`)

The engine never assumes the whole REU is free. It allocates from fixed regions and checks the detected capacity at `AI_INIT`.

| REU range | Size | Use |
| --- | ---: | --- |
| `$000000–$0FFFFF` | 1 MB | **Model image** (`.d64ai`, loaded at address 0 by the Ultimate menu, UCI `LOAD_REU`, or VICE `-reuimage`). The baseline uses about 230 KB; d128 about 720 KB. |
| `$100000–$17FFFF` | 512 KB | **KV cache**: one slice per layer, each 64 KB aligned. Baseline per layer: 128 positions × (2×64 + 2×4) bytes = 17.4 KB (record format updated in M2). |
| `$180000–$1FFFFF` | 512 KB | **Engine scratch**: spilled activations (for d>128 experiments), saved prompt-prefix KV snapshots, benchmark buffers |
| `$200000–$2FFFFF` | 1 MB | **Game data**: fallback text, dungeon tiles, overlays, save staging |
| `$300000–$FEFFFF` | ~13 MB | unallocated; reserved for larger models or game use; never touched implicitly |
| `$FF0000–$FFFFFF` | 64 KB | **REU probe area**: capacity-test tags (saved and restored) |

**Minimum REU for the baseline:** about 2 MB (the model region rounded up, KV, and scratch). The engine checks for at least `$200000` of usable capacity. With the game region added, the target is ≥ 4 MB. The 16 MB configuration is the development and release target.

**Capacity test (non-destructive):** save 4 bytes at each candidate boundary ($080000, $100000, $200000, $400000, $800000, top). Write distinct tags from the top down. Read them back, looking for aliases. Restore the saved bytes. This follows both references' alias approach. The real ordering is designed so a preloaded model at `$000000` is never overwritten. The model header itself serves as an alias witness (read it after each tag write).

**DMA rules:**

1. Split at every 512 KiB boundary (cheap insurance even if [OPEN] turns out false).
2. Prefer transfers of ≥ 4 KiB. Tiny21 measured 3.98 MiB/s for 4 KiB DMAs vs 3.05 MiB/s for 256-byte calls at 64 MHz [AUTHOR].
3. Never DMA into the zero page, the stack, or I/O.
4. Address control (`$DF0A`) stays at 0 (both addresses increment). Fixed-address modes are not used.

## 5. Model image layout inside the REU

See `MODEL_FORMAT.md`. The image is position-independent but loaded at `$000000`. All tensor offsets are absolute REU addresses in the default load, and are relative to the image base if a future loader relocates it.
