# Hardware Results (C64 Ultimate)

Only results measured on real hardware go here. VICE numbers are in docs/ENGINE.md.

Device: the user's C64 Ultimate, reached at 192.168.10.148 over REST/FTP. Its firmware is 1.1.0, FPGA 122, core 1.49, PAL-60, as recorded by `../c64-tyrian/docs/hw-results.md`. This project has not re-read those versions.

## 2026-11-16: engine hardware check 1 (`tools/hw_check.py --ultimate`)

**Setup:**

- The model `DM64AI.REU` (= `models/exported/baseline.d64ai`, 233,216 bytes) was uploaded with `make ultimate`.
- The user loaded it with the menu's "Load into REU".
- `engine/build/hw_check_run.prg` was started with `POST /v1/runners:run_prg` (raw body).
- The result block at `$C800` was read with `GET /v1/machine:readmem`.

| Check | Result |
| --- | --- |
| REST API without a password (`/v1/version`, `machine:readmem`, `runners:run_prg`) | Works |
| `AI_INIT`: engine REU detection | **PASS:** 16 MB, capabilities `$03` |
| `AI_LOAD_MODEL`: header, payload CRC32 over 233 KB, directory, tokenizer | **PASS** |
| Load time (CIA2 cascade, 1 MHz ticks, turbo off) | 23,052,343 ticks ≈ 23.4 s. VICE measures 20,719,469 cycles for the same code. Hardware is 11% slower; cause not yet investigated. |
| Turbo registers | `$D031` read `$FF`: the menu's Turbo Control is not "C64U Turbo Registers" at the moment. **No generation was attempted.** At 1 MHz it would take about 30 min. |

**Not yet measured on hardware:**

- Token generation speed at 64 MHz
- The 512 KiB DMA wrap
- Loading through the Command Interface

## 2026-11-16: engine hardware check 2, first on-device generation

**Setup:** as in check 1, plus Turbo Control. It was set over REST (`PUT /v1/configs/U64 Specific Settings/Turbo Control`) from "Off" to "C64U Turbo Registers" for this run only. It was not saved to flash, and was **restored to "Off" afterwards** (verified). The PRG wrote `$D031 = $8F` (speed index 15, badline timing off) and restored the old value on exit.

| Check | Result |
| --- | --- |
| `$D031` before / after selection | `$00` / `$8F`. Turbo registers active. |
| `AI_LOAD_MODEL` at 64 MHz (header, CRC32 over 233 KB, directory, tokenizer) | **PASS:** 2,652,177 CIA ticks (≈2.6–2.7 s). At 1 MHz it took 23.05M (check 1). |
| Generation: prompt `TASK:ACTION OBJ:DOOR ACT:OPEN OUT:LOCKED`, greedy | **PASS:** output **"A heavy oak door is locked tight."** This is identical to VICE and to `python/reference_int.py`. |
| Generation time (6 prompt tokens + 33 characters + EOS = 39 forward passes) | 33,105,699 CIA ticks ≈ **32–34 s**, or ≈0.85 s per forward pass. That is about **1 character per second** including prefill. |
| Speed-up over the same work at 1 MHz | The same run takes 2,023,047,118 cycles in VICE at 1 MHz: **61× faster** on hardware at 64 MHz |

The CIA time base is 1 MHz under turbo, as measured by c64-tyrian on this unit. Seconds depend on the CIA clock (0.985 MHz PAL vs 1.023 MHz NTSC timing, and this unit runs PAL-60), so a range is given and the raw tick counts are kept.

**For comparison:** Tiny21 reports 0.795–0.829 generated characters per second on a 367K-parameter model. That rate is measured from first output and is author-reported, so the figures are not directly comparable.

## 2026-11-16: check 3, model file loading through the Command Interface

**Setup:**

- The menu's "Command Interface" and "Turbo Control" were set over REST for the run only: Enabled / "C64U Turbo Registers". Neither was saved to flash. Both were **restored afterwards** (Disabled / Off, verified).
- `tools/hw_check.py --ultimate --uci --damage` first overwrote REU byte 0, breaking the model signature.
- It then ran `uci_load_model("/USB1/dist/dungeon-master/DM64AI.REU")`, then `AI_LOAD_MODEL`.

| Check | Result |
| --- | --- |
| Command Interface identification (`$DF1D = $C9`) | Present |
| OPEN_FILE, FILE_INFO, LOAD_REU, CLOSE | Status "00,OK" |
| Model after the load: signature, header CRC, payload CRC32, directory, tokenizer | **PASS.** Only a real file load could restore the damaged byte. |
| Generation afterwards | "A heavy oak door is locked tight." (same as checks 1–2) |
| Duration of the file load | **Not measured.** `hw_uci.asm` reuses CIA2 for its own timeout, which resets the check program's stopwatch (the recorded 719 ticks covers only the last command). |

## 2026-11-16: check 4, the AI terminal (`tools/terminal_hw.py`)

**Setup:** Turbo Control was set over REST to "C64U Turbo Registers" for the runs, then restored to Off. The model was already in the REU.

| Run | Result |
| --- | --- |
| `run_prg dm64.prg`, boot to Ready | 3.1 s (host clock). Status line "REU 16 MB 64 MHz model ok". |
| F2 (exact), typed "describe an ancient dungeon", RETURN, keys written to `$0277`/`$C6` over REST | "A small shrine stands here, its candles long cold. A scrawny goblin stirs in the dark." **Identical to `python/reference_int.py`.** The terminal reported 110.4 s for 30 prompt tokens + 86 characters ≈ 0.95 s per forward pass. |
| F7 fight scene, creative | `[fight: goblin, miss, your hp mid]` → "You swing wide and miss the goblin." 35.2 s for 6 prompt tokens + 35 characters. |

The terminal's per-pass time (≈0.95 s) is higher than the bare check (≈0.85 s, check 2). It includes screen updates, the KERNAL IRQ and RUN/STOP polling. The per-component cost has not been profiled on hardware.

## 2026-11-16: user session and screen capture

**The user's own session.** The user ran `DM64.PRG` from the menu with turbo registers on. Screen read back over REST with `tools/ult_screenshot.py`; image: `docs/screenshots/terminal_hw_session.png`.

| Request | Output | Time (terminal clock) |
| --- | --- | --- |
| F3 `[monster: crypt, spider, healthy]` | "A bloated spider clicks its fangs, eight eyes gleaming." | 55 chars, 53.1 s |
| typed "describe the weather" | "Scrolls and tomes lie heaped across a dark reading room." (off-topic: weather is not in the training data) | 56 chars, 70.4 s |
| typed "look at the flor" (typo) | began "Pilas hoock idd": garbled, the known free-text weakness | captured mid-answer at 15 chars, 27.2 s |

**Screen capture:** the Ultimate's VIC video stream (`PUT /v1/streams/video:start`) fails on this unit with "No Operational Network Interface". Streams need the wired Ethernet port; the unit appears to be on WiFi. `tools/ult_screenshot.py --mode memory` reconstructs text mode instead:

- It reads screen RAM, colour RAM, `$D018`, `$D020` and `$D021` over REST.
- It draws them with the C64 character ROM from the local VICE installation.

This is exact for standard text mode only.

## Letter-group model on hardware (2026-11-17, `baseline_bpe72_v2`)

C64U, turbo registers at 64 MHz, REU 16 MB. `DM64AI.REU` = `baseline_bpe72_v2` loaded into the REU from the Ultimate menu; terminal `DM64.PRG` driven by `tools/terminal_hw.py --exact` (greedy). Times are the terminal's own clock (jiffies), from RETURN or the F-key to the last character, and include reading the prompt.

| Request | Output | Time | Characters/s |
|---|---|---|---|
| Typed "describe an ancient dungeon" | 48 characters, matches `reference_int.py` exactly | 52.1 s | 0.92 overall |
| F1 room scene | 50 characters | 26.5 s | 1.89 |
| F3 monster scene | 76 characters | 44.1 s | 1.72 |

- The typed prompt is about 30 one-character tokens; at about 0.85 s per step (measured earlier) that is about 25 s of prompt reading (estimate), leaving roughly 1.8 characters/s for the answer itself.
- Scene keys send a few context tokens, so their speed is close to the generation rate: 1.7–1.9 characters/s, against about 1 character/s for the one-character model (Milestone 4).
- The user also ran the game with the narrator on this build: it runs (user report; no timings taken).

## Format 1.1 engine on hardware (2026-11-17, Milestone 7)

C64U, turbo registers at 64 MHz (`$D031` read back `$8F`), REU 16 MB, format 1.1 `DM64AI.REU` (`baseline_bpe72_v2`) in the REU ("Model OK"). The user ran `DM64.PRG` and pressed F1; the screen was read over REST (`machine:readmem $0400`), read-only.

| Request | Output | Time (terminal clock) | Characters/s |
|---|---|---|---|
| F1 room scene, creative mode | "You enter a great hall. Broken tables lie overturned. Near the wall is an old spear rack." | 89 characters, 33.4 s | 2.66 |

- Previous build, same model: F1 1.89, F3 1.72 characters/s. This one run is about 1.4–1.5× faster; VICE predicted 1.76× per step at position 0, less at later positions where attention grows. One sample only; a `tools/terminal_hw.py --exact` run is still to do.
