# Model Pipeline and Milestone 2 Results

Status: Milestone 2, 2026-11-16. The results below were measured on the development Mac (Apple A18 Pro, 8 GB RAM, PyTorch 2.15.0 on MPS). The baseline package has since run on the C64 Ultimate with identical output (docs/HW_RESULTS.md). C64 speed figures are in that file, not here.

## 1. Pipeline

```text
datasets/raw/phrasebank.yaml ──tools/dataset_generator.py──► datasets/{processed,training,validation}
        │                                                         │
        │                         python/train.py (configs/*.yaml)│
        │                                                         ▼
        │                                   models/checkpoints/<name>/best.pt
        │                                                         │ python/convert.py
        │                         (quantize.py → d64ai.py write → d64ai.read round trip)
        ▼                                                         ▼
 python/vocab.py ─────────────► models/exported/<name>.d64ai  + .manifest.json + .tokens.inc
                                                                  │
                         tools/format_validator.py (independent)  │  python/reference_int.py
                         tools/model_inspector.py                 │  python/evaluate.py → .eval.json
```

## 2. Dataset

- **Source:** `datasets/raw/phrasebank.yaml`, a context-bound grammar of original phrases.
- **Provenance:** **the phrase bank was written by Claude (an AI model) in this session.** The Milestone 1 report asked you whether LLM-authored training text is acceptable, and that question is still open. The text copies no game, book or dataset. It can be edited or replaced by hand, and the generator validates characters, lengths and comma-split YAML lists.
- **Generator:**
  - 9 tasks: ROOM, MONSTER, TREASURE, NPC, QUEST, EVENT, COMBAT, ACTION, FREE.
  - Each example is control tokens plus a narration consistent with them. The outcome (for example `OUT:LOCKED`) is always an input.
  - Deterministic for a given seed (64).
- **Size:** 200,000 generated examples (80,526 unique). Train: 190,704, with repeats kept to preserve the task mix. Validation: 3,975 unique examples.
- **Split:** by a hash of the whole example, so no identical example is in both splits.
- **Sequences:** 26–128 tokens, mean 69.0. All 133 control tokens are used.
- **Known limitation:** the corpus is templated. 67% of validation *texts* also appear in training under a different context, and the model mostly reproduces and recombines phrase-bank sentences (see §5). Variety is limited by the phrase bank, not by the model.

## 3. Tokenizer and vocabulary (`python/vocab.py`, `python/tokenizer.py`)

- 197 entries, all with one-byte ids:
  - 5 specials
  - 46 lowercase text characters (ids 5–50), with 13 unused ids up to 63
  - 133 control tokens starting at id 64
- Sequence: `BOS ctx… [typed prompt chars for TASK:FREE] SEP text… EOS`. The training loss covers only the tokens after SEP.
- The package carries a 256-byte PETSCII → token-id table (shifted letters map to the same tokens) and a PETSCII display byte per text token.
- `tokens.inc` gives the game symbolic ids plus `DM64_VOCAB_HASH`.
- The output module capitalizes sentence starts (`tokenizer.display`).

## 4. Training results (measured)

| Model | Config | Params | Steps | Wall time | Best val loss (nats/char) |
| --- | --- | ---: | ---: | --- | ---: |
| bring-up | d32 L2 H2 F64 | 26,944 | 3,000 | ~3.5 min | 0.972 |
| **baseline** | **d64 L4 H4 F256** | **217,984** | **12,000** | **~33 min** | **0.0631** |

The baseline's validation loss fell steadily: 0.152 (2k steps), 0.099 (4k), 0.071 (8k), 0.066 (10k), 0.063 (12k). It was still improving slowly at the end. `configs/small.yaml` (d48 L3) exists but was not trained in this milestone.

## 5. Quantization and integer inference (measured)

Baseline package: `models/exported/baseline.d64ai`, 233,216 bytes (REU `$000000–$038EFF`), tile_rows 31. It passes the independent validator.

| Metric | bring-up | baseline |
| --- | ---: | ---: |
| Max per-row relative quantization error (worst tensor kind) | 0.76% (w2) | 0.93% (w2) |
| Teacher-forced top-1 agreement, float vs integer | 95.98% (4,233 positions) | **99.80%** (7,115 positions, 100 val examples) |
| Float loss / integer loss on those positions | 0.932 / 0.941 | **0.0574 / 0.0575** |
| Greedy response identical, float vs integer | 0/20 | **25/30** |
| Largest matvec accumulator | 26 bits | 27 bits |
| Largest attention score / value accumulator | 23 / 26 bits | 22 / 27 bits |
| Largest residual (Q16.16) | 18 bits | 21 bits |

**Conclusions:**

- The int8 / int16 / Q16.16 scheme from `docs/INFERENCE.md` costs essentially nothing at the baseline size.
- 32-bit accumulators are sufficient with margin: 27 of 31 magnitude bits are used.
- The residual stays within ±10 in real terms (21 bits of Q16.16), so it could fit 24-bit storage. This is a possible optimization, not adopted.

### Sample output (integer model, from the package)

Greedy results:

| Context | Output |
| --- | --- |
| `TASK:ROOM LOC:CRYPT ROOM:ARMORY OBJ:ALTAR OBJ:GATE` | Dented shields and broken blades litter the dusty armory. Here are a cracked altar and a barred gate. |
| `TASK:ACTION OBJ:DOOR ACT:OPEN OUT:LOCKED` | A heavy oak door is locked tight. |
| `TASK:COMBAT MON:DRAGON ACT:ATTACK OUT:CRIT MST:DYING HP:LOW` | You find a gap and strike deep. It staggers, close to death. |
| `TASK:NPC LOC:CAVERN NPC:HERMIT MOOD:FRIENDLY` | A ragged hermit is here. "Welcome, traveler. Few come this deep." |
| `TASK:TREASURE OBJ:CHEST ITEM:BOW OUT:FOUND` | Inside an iron chest you find a hunting bow. It is finely made. |

**Weaknesses observed:**

- **Novelty:** 22 of 30 sampled top-k outputs (T = 0.8, k = 8) are identical to a sentence in the dataset. The model is a reliable, context-faithful recombiner of the phrase bank, not an inventive writer.
- **Free text:** typed prompts (`TASK:FREE`) at T = 0.8 sometimes produce errors, for example "…stirs in the dawch" and "…reeks of thick with sharpened stakes". Free prompts are 7% of the data, with only 4 prompt families.

## 6. BPE side experiment (measured compression only)

`tools/bpe_experiment.py` learns byte-pair merges on the training narration. MACs/char counts only dense layers plus the head (attention excluded), for the baseline geometry.

| Option | Merges | Vocab | Chars/token | MACs per char (pos 0) |
| --- | ---: | ---: | ---: | ---: |
| char only (current) | 0 | 197 | 1.00 | 209,216 |
| fill one-byte ids | 72 | 256 | 1.69 | 125,995 |
| two-byte ids | 200 | 384 | 2.18 | 101,591 |
| two-byte ids | 328 | 512 | 2.51 | 91,228 |

72 merges fill the unused one-byte ids and cut forward passes per character by about 40%. If prompts stay character-encoded, the C64 needs only a merge **decode** table (multi-byte display strings, already supported by the tokenizer section), with no BPE encoder. Model quality with merges has **not** been measured. That needs a trained comparison model.

## 7. Reproduce

```bash
make venv
```

```bash
make dataset
```

```bash
make train MODEL=baseline
```

```bash
make convert MODEL=baseline VERSION=dm64-base-0001
```

```bash
make evaluate MODEL=baseline
```

```bash
make test
```

MPS training is not bit-reproducible. Dataset generation, conversion and integer inference are deterministic.

## 8. Open items for review

1. Is the AI-authored phrase bank acceptable as training source material, or should it be replaced or extended by hand?
2. Should a 72-merge BPE variant be trained and compared before engine work fixes the tokenizer?
3. Should the dataset be broadened (more phrase families, more free-prompt variety) to reduce verbatim reproduction?

## 9. Letter-pair (BPE) tokenizer experiment (2026-11-17)

**Setup.**

- `python/lexicon.py` adds a second token layout, **bpe72**. It keeps the same specials, the 46 characters (ids 5–50) and the 133 control tokens (moved to ids 123–255), and adds **72 letter groups** (ids 51–122).
- The groups are learned by byte-pair merging the training narration (`tools/learn_merges.py` → `datasets/processed/bpe72_merges.json`): " a", " s", "th", "in", "ou", " th", "er", …, " the", "you", "ll". Every id is still one byte (256 in total).
- Narration is encoded with the merges. **Typed prompts stay one character per token**, so the C64 never encodes merges; it only prints them.
- The model, `configs/baseline_bpe72.yaml`, has the baseline geometry (d64, 4 layers, 4 heads, FFN 256, ctx 128) and the same training settings. It has 221,760 parameters; its package `models/exported/baseline_bpe72.d64ai` is 237,312 bytes.

**Results** (`tools/compare_tokenizers.py` → `models/exported/tokenizer_comparison.json`):

| Metric | char (`baseline`) | bpe72 (`baseline_bpe72`) |
| --- | ---: | ---: |
| Characters per token (training narration / greedy outputs) | 1.00 / 1.00 | 1.69 / 1.66 |
| Validation loss per **character** (float / int8), 100 val examples | 0.0574 / 0.0575 | **0.0561 / 0.0562** |
| Teacher-forced top-1 agreement, float vs int8 | 99.8% | 99.6% |
| Greedy response identical, float vs int8 | 25/30 | 26/30 |
| Engine output equals the reference (4 prompts, VICE) | 4/4 | 4/4 |
| **VICE cycles per output character**, prompt included | 59.8M | **34.4M (1.74× faster)** |
| VICE cycles per token | ≈53.6M | ≈52.0M |

**Conclusions.**

- **Speed:** the same model size gives **1.74× more characters per second**. On the C64U at 64 MHz that would be about 1.8 characters per second instead of about 1. That figure is projected from the VICE ratio; it has not been measured on hardware.
- **Quality:** slightly better per character, with the same int8 agreement. Samples are equally coherent.
- **Engine support:** letter groups need a 170-byte string pool in the engine (`tok_pool`, at most 240 bytes).
- **Cost of adopting it:** the control-token ids change, so the terminal's and game's generated tables must be regenerated, and the vocabulary hash protects against mixing them up.

**Adopted on 2026-11-17** at the user's request:

- `lexicon.DEFAULT = "bpe72"`, `make` `MODEL ?= baseline_bpe72`.
- The terminal and game tables were regenerated (vocabulary hash `$11B711A3`).
- `make ultimate` and `ultimate-dist` ship `baseline_bpe72` as `DM64AI.REU`.
- The terminal tests use the new `bringup_bpe72` model (`configs/bringup_bpe72.yaml`).
- The one-character `baseline` and `bringup` models stay for engine regression tests.

**Measurement note:** the CIA2 cycle counter is 32-bit and wraps every 4.29 billion cycles. Runs longer than that are corrected with each run's token count (`tools/compare_tokenizers.py:unwrap`).

## 10. More training data: the v2 dataset (2026-11-17)

**Data.** `datasets/raw/phrasebank_v2_additions.yaml` adds new original phrases (written by Claude, like v1) to every rule of `phrasebank.yaml`: rooms, objects, monsters, items, actions, combat, NPCs, quests, events, and 37 more typed-prompt phrasings. The generator merges it onto v1 (`--extra`) and writes separate files (`--tag v2`), so the v1 dataset and models stay reproducible. `make dataset-v2` runs it with 300,000 examples and a larger share of typed prompts (FREE 12%, was 8%).

| | v1 | v2 |
|---|---|---|
| Phrase source | 22 KB | 22 KB + 23 KB additions |
| Unique examples | 80,526 | 159,147 |
| Train / val | 190,704 / 3,975 | 284,737 / 7,921 |
| Narration characters | 12.2 M | 18.6 M |

**Model.** `configs/baseline_bpe72_v2.yaml`: the same shape and the same 72 letter groups as `baseline_bpe72` (vocabulary hash unchanged, so the engine, terminal and game need no changes), 16,000 steps (was 12,000), 37 minutes on the Mac GPU. Package `models/exported/baseline_bpe72_v2.d64ai`, 237,312 bytes.

**Results (measured on the Mac; float model unless noted).**

| Metric | baseline_bpe72 | baseline_bpe72_v2 |
|---|---|---|
| Val loss on its own val split (nats/token) | 0.103 (v1) | 0.155 (v2) |
| Val loss on the v2 val split | 3.15 | 0.155 |
| Val loss on the v1 val split | 0.103 | 0.159 |
| Distinct answers, 9 contexts x 20 samples (temp 0.8, top-k 8) | 121/180 | 143/180 |
| Answers not found verbatim in training text | 11/180 | 34/180 |
| Answers with a non-word, 200 v2 val contexts, temp 0.8 | 6/200 | 3/200 |
| Same, temp 0.5 | 0/200 | 0/200 |
| Integer vs float greedy exact match (`make evaluate`) | 26/30 | 21/30 |
| Greedy characters per token | 1.66 | 1.68 |

The higher loss is expected: v2 offers more valid phrasings per situation, so each next token is less certain. The v2 model knows both phrase sets (v1 loss 0.159), varies its answers more, writes more new combinations, and makes fewer non-words. Integer/float greedy agreement is lower because near-ties between phrasings are more common; the engine still matches `reference_int.py` bit for bit in VICE (`tests/test_engine_model.py`, slow set). Adopted as the shipped model on 2026-11-17. Not yet run on hardware.

## 11. Better text: v3 data, fact checks and C64-aware training (Milestone 8, 2026-11-18)

### Measuring: `tools/fact_check.py` (`make fact-check`)

It builds the context records the game sends: rooms (half with a monster), monster sightings, kills, treasure, locked doors, unlocked doors and traps. It then generates with the game's settings (temperature 0.8, top-8, at most 48 tokens), by default on the bit-exact integer reference, so the text is what the C64 computes. For each answer it counts:

- **fact_ok:** no rule in `python/facts.py` is broken.
  - wrong_monster: names a monster that isn't in the record.
  - missing_monster: a sighting that doesn't name its monster.
  - missing_item, wrong_item: treasure that doesn't name its item, or names another one.
  - missing_lock: a locked door that doesn't say "lock".
- **cut:** stopped by the 48-token limit instead of ending.
- **distinct:** different answers.
- **new:** answers not found word for word in the training text.
- **nonword:** answers containing a word the training text never uses.

### What was wrong with v2

- **Cut-off text:** 65% of v2 room texts and 47% of monster texts were longer than 48 tokens. On the C64 about a third of room and monster narrations stopped mid-word ("it looks strong and ready to f"). For a room with a monster, the monster sentence was usually the part cut off.
- **Facts in the data:** 1.4% of the v2 training examples broke a rule themselves. For example, "a shambling corpse" never says zombie, and "rats scratch behind the walls" turns up with no rat.
- **Locked doors:** they were rare in the data and sometimes came out garbled.

### v3 data (`make dataset-v3`)

`datasets/raw/phrasebank_v3_additions.yaml` holds new original phrases written by Claude, like v1 and v2:

- short room openings (`roomshort_*`, 8 per room type), used for 80% of rooms that have a second sentence;
- more rooms, monsters and treasure lines;
- more locked-door, key and trap lines;
- 25 more typed-question phrasings.

New generator options, all off by default, so v1 and v2 rebuild byte for byte:

- `--fact-filter` drops examples that break a fact rule.
- `--max-game-tokens 44` drops game-event texts longer than 44 tokens.
- `--typos 0.3` gives 30% of typed questions one keyboard slip, such as "waht is coming".
- The bank setting `game_boost: 0.3` draws 30% of action examples from the game's own door and trap records.

The v3 dataset has 300,000 examples (151,257 unique). The filters dropped 47,593 over-long game texts and 5,200 fact breaks; none are left.

### C64-aware training (`model.qat`)

With `qat: true` the PyTorch forward pass rounds the way the engine does: every weight matrix to int8 per row, and attention keys and values to 7-bit magnitudes with one power-of-two step per head and position. Gradients pass straight through the rounding. On v2 weights this simulation brings logits 4× closer to the integer engine (mean absolute difference 0.022 against 0.091).

- `baseline_bpe72_v3`: v3 data, 16,000 steps from scratch, 37 minutes on the Mac GPU.
- `baseline_bpe72_v3q`: `baseline_bpe72_v3` fine-tuned with `qat` for 4,000 steps (`init_from`, learning rate 3e-4), 10 minutes.

Both keep the shape and letter groups of v2 (vocabulary hash `$11B711A3`), so the engine, terminal and game need no changes.

### Results

Integer reference, the game's settings, 3 seeds × 420 game records (60 per kind) = 1,260 answers per model. Measured on the Mac.

| | v2 | v3 | v3q |
|---|---:|---:|---:|
| Fact rules kept | 1,237 (98.2%) | 1,251 (99.3%) | 1,254 (99.5%) |
| Cut off by the 48-token limit | 136 (10.8%) | 4 | 1 |
| Answers with a non-word | 24 | 19 | 14 |
| Distinct answers | 712 | 751 | 768 |
| Not word for word in the training text | 217 | 133 | 111 |
| Integer vs float greedy exact match (`make evaluate`, 30) | 21/30 | 26/30 | 29/30 |
| Teacher-forced top-1 agreement, integer vs float | — | 99.54% | 99.95% |
| Integer-model loss, `make evaluate` sample of v3 val (nats/token) | — | 0.1951 | 0.1897 |

- For v3q, "float" in `make evaluate` is the C64-aware forward pass, which is what v3q was trained to match.
- v3 and v3q copy more whole training sentences than v2: shorter texts leave fewer ways to combine phrases. They still give more distinct answers.
- Misspelled typed questions (30 prompts, temperature 0.8): 1 answer with a non-word for v2 and 1 for v3q. There is no measurable gain on this small test.

`baseline_bpe72_v3q` was adopted as the shipped model on 2026-11-18. It hasn't run on hardware yet.

### The game's own check

`game/source/narrator.asm` now prints narration one whole word at a time and checks each word against `game/source/generated/fact_words.asm`. That list is generated from `python/facts.py`, 427 bytes.

- **Wrong monster:** a word naming a monster that isn't in the record is never shown. The sentence ends with "..." and the game prints its built-in line.
- **Missing name:** if a monster sighting never names its monster, treasure never names its item, or a locked door never says "lock", the game adds its built-in line after the text.

See `docs/GAME_DESIGN.md` section 10 and `tests/test_facts.py`.
