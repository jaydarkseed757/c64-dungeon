#!/usr/bin/env python3
"""Learn the 72 letter-group merges for the bpe72 lexicon from the training narration.

    .venv/bin/python tools/learn_merges.py  -> datasets/processed/bpe72_merges.json
Deterministic for a given datasets/training/train.jsonl.
"""
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))
import lexicon  # noqa: E402

train = ROOT / "datasets/training/train.jsonl"
texts = [json.loads(line)["text"] for line in train.open()]
merges = lexicon.learn_merges(texts)
out = lexicon.MERGES_FILE
out.write_text(json.dumps({"source": str(train.relative_to(ROOT)),
                           "source_sha256": hashlib.sha256(train.read_bytes()).hexdigest(),
                           "merges": merges}, indent=1) + "\n")
lex = lexicon.load("bpe72")
chars = sum(len(t) for t in texts)
tokens = sum(len(lex.encode_text(t)) for t in texts)
print(f"{len(merges)} merges, vocab {lex.VOCAB_SIZE}, first control id {lex.FIRST_CONTROL_ID}, "
      f"{chars / tokens:.2f} chars/token on the training narration")
print("merges:", [a + b for a, b in merges][:24], "...")
