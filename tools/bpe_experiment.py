#!/usr/bin/env python3
"""Measure what byte-pair merges would buy on the DM64 corpus.

Learns BPE merges on the training narration (within words, spaces kept as a
prefix of the following word, sentencepiece style) and reports characters per
token and estimated MACs per generated character for the baseline geometry.
This measures sequence compression only; output quality would need a trained
BPE model (not done here).

    .venv/bin/python tools/bpe_experiment.py
"""
import collections
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))
import vocab  # noqa: E402

D, L, FF = 64, 4, 256
LAYER_MACS = L * (4 * D * D + 2 * D * FF)


def words(texts):
    counts = collections.Counter()
    for t in texts:
        for i, w in enumerate(t.split(" ")):
            counts[tuple((" " if i else "") + w)] += 1
    return counts


def learn(counts, n_merges):
    counts = {tuple(c for c in w): n for w, n in counts.items()}
    merges = []
    for _ in range(n_merges):
        pairs = collections.Counter()
        for w, n in counts.items():
            for a, b in zip(w, w[1:]):
                pairs[(a, b)] += n
        if not pairs:
            break
        (a, b), _ = pairs.most_common(1)[0]
        merges.append(a + b)
        new = {}
        for w, n in counts.items():
            out, i = [], 0
            while i < len(w):
                if i + 1 < len(w) and w[i] == a and w[i + 1] == b:
                    out.append(a + b)
                    i += 2
                else:
                    out.append(w[i])
                    i += 1
            new[tuple(out)] = new.get(tuple(out), 0) + n
        counts = new
    tokens = sum(len(w) * n for w, n in counts.items())
    return merges, tokens


def main():
    texts = [json.loads(line)["text"] for line in (ROOT / "datasets/training/train.jsonl").open()]
    chars = sum(len(t) for t in texts)
    counts = words(texts)
    control = len(vocab.TOKENS) - vocab.FIRST_CONTROL_ID
    text_syms = len(vocab.TEXT_CHARS)
    rows = []
    budgets = {"char only (current)": 0,
               "fill one-byte ids (vocab 256)": 256 - 5 - control - text_syms,
               "vocab 384 (two-byte ids)": 384 - 5 - control - text_syms,
               "vocab 512 (two-byte ids)": 512 - 5 - control - text_syms}
    for name, n in budgets.items():
        merges, tokens = learn(counts, n) if n else ([], chars)
        # char-only uses the real vocabulary (it has unused padding ids below 64)
        v = vocab.VOCAB_SIZE if not n else 5 + text_syms + len(merges) + control
        cpt = chars / tokens
        macs_per_char = (LAYER_MACS + v * D) / cpt
        rows.append((name, len(merges), v, cpt, macs_per_char, merges[:12]))
    print(f"corpus: {len(texts):,} training narrations, {chars:,} characters\n")
    print(f"{'option':32} {'merges':>6} {'vocab':>5} {'chars/token':>11} {'MACs/char (pos 0)':>18}")
    for name, m, v, cpt, mpc, _ in rows:
        print(f"{name:32} {m:6} {v:5} {cpt:11.2f} {mpc:18,.0f}")
    print("\nfirst merges learned:", rows[-1][5])


if __name__ == "__main__":
    main()
