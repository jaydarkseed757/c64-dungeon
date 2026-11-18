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
