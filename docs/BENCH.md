# BENCH.PRG — Benchmark on the C64

`bench/build/bench.prg` (`make bench`) measures the on-device model for 5 minutes and checks that every token it computed is correct. It uses the same engine, model and REU setup as the game.

## What it runs

- **Requests:** 12 fixed requests from `tools/bench.py` (`REQUESTS`), in a loop. Ten are game events (rooms, monsters, a kill, treasure, doors, a trap) and two are typed questions.
- **Settings:** the game's settings: temperature 0.8, top-8, at most 48 tokens per request.
- **Seed:** request k (counting from 0) uses the seed bytes `k lo, k hi, $5A, $A5`, so `python/reference_int.py` can repeat it exactly.
- **CRC:** the C64 keeps a CRC32 (the same as zlib's) over the generated token ids of all completed requests. `tools/bench.py` compares it with the reference. A match means every token of the run was correct.
- **End of the run:** the run ends at 5:00 (`cfg_secs`), or when you press RUN/STOP. The request in progress at that moment is left out of the request count and the CRC; its timed steps still count.

## Timing

| What | How |
|---|---|
| Each step | CIA2 timers A and B chained: a 32-bit count of CIA cycles, read before and after each `AI_GENERATE_STEP`. The CIA stays at 1 MHz under the C64U turbo, so the count is real time. |
| Wall clock | The CIA1 time-of-day clock, set to 50 Hz on PAL machines and 60 Hz on NTSC (KERNAL flag `$02A6`). |
| CIA rate | Measured against the time-of-day clock after 5 s and shown as "CIA kHz" (PAL 985, NTSC 1023). If it isn't between 900 and 1100 kHz, or the time-of-day clock doesn't run, the bench switches to the CIA count at the nominal rate ("Clock: CIA count"). |

- **One step, one forward pass:** a step is a prompt token while the context position is below the prompt length, and a generated token after that.
- **Not timed:** the last call of a request only notices the end of the text and runs no forward pass.
- **Throughput:** "Tokens/s" and "Chars/s" divide by the whole run time, including prompts and screen updates.

## Screen

| Row | Left | Right |
|---|---|---|
| Time | m:ss of 5:00 | |
| Requests | completed | Characters (completed requests) |
| Prompt tok | prompt tokens | ms/token for prompt tokens |
| Gen tokens | generated tokens | ms/token for generated tokens |
| Fastest ms | fastest generated step | Slowest ms |
| Last ms | last generated step | Position: context position now |
| Tokens/s | generated tokens per second | Chars/s |
| CIA kHz | measured CIA rate | CRC so far |

Below the statistics are the current request's label and text. At the end the text area becomes a summary. Then RETURN runs the benchmark again, and F8 restores turbo and resets the C64.

**Results block** at `$C800`, read by the tool: `"DMB1"`, phase (1 running, 2 done, 3 error), the counters above as cycles, the CRC, tenths of a second, the clock source, the turbo flag and kHz. The full layout is in `tools/bench.py`.

## Running it

```bash
make bench
```

```bash
python tools/bench.py vice --requests 2 --max-tokens 6 --png /tmp/bench.png
```

```bash
make hw-bench
```

- **`vice`** runs BENCH.PRG in VICE with a small model (`bringup_bpe72`) for a few requests. It checks the CRC and can save the final screen as a PNG. At 1 MHz one token takes seconds, so the full 5 minutes is meant for hardware.
- **`make hw-bench`** (`tools/bench.py ultimate --turbo`):
  - starts BENCH.PRG over REST, which resets the C64; the REU keeps the model;
  - waits for the end and prints the results with the Mac's wall clock next to the C64's;
  - checks the CRC against the reference.
  - With `--turbo`, it switches Turbo Control to "C64U Turbo Registers" if it is off, for this run only. It never saves to flash, and it restores and re-reads the old value at the end.
- **On the C64 alone:** copy `BENCH.PRG` next to `DM64AI.REU` and run it from the file browser. It finds the model in the REU, or loads `/USB1/dist/dungeon-master/DM64AI.REU` when the Command Interface is enabled.

Tests: `tests/test_bench.py` (VICE) checks two requests against the reference, and a time limit that ends mid-request.

## Results

| Date | Where | Model | Tokens/s | Chars/s | Prompt ms/token | Gen ms/token | CRC |
|---|---|---|---|---|---|---|---|
| 2026-11-18 | VICE (1 MHz, PAL) | bringup_bpe72, 6 tokens per request | 0.06 | 0.16 | 4,762 | 6,367 | matches |
| 2026-11-18 | C64U, 64 MHz, 5:00 | baseline_bpe72 (what the REU held), 48 tokens | 1.44 | 2.31 | 460 | 565 | matches (13 requests) |
| 2026-11-18 | C64U, 64 MHz, 5:00 | baseline_bpe72_v3q (shipped), 48 tokens | 1.44 | 2.29 | 463 | 563 | matches (14 requests) |

Details: `docs/HW_RESULTS.md`.
