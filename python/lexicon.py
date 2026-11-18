"""Token layouts ("lexicons") for DM64 models.

    char   - vocabulary v1 (python/vocab.py): 46 characters + 133 control tokens, 197 ids.
             Every model before the BPE experiment uses it.
    bpe72  - the same specials, characters and control tokens plus 72 letter groups
             learned by byte-pair merging the training narration (256 ids, all one byte):
               0..4 specials   5..50 characters   51..122 merges   123..255 control tokens
             Narration is encoded with merges; typed prompts stay one character per token,
             so the C64 only ever decodes merges (for display), never encodes them.

The merges come from datasets/processed/bpe72_merges.json (tools/learn_merges.py).
"""
import json
from pathlib import Path

import vocab

ROOT = Path(__file__).resolve().parents[1]
MERGES_FILE = ROOT / "datasets/processed/bpe72_merges.json"
# The lexicon of the shipped model. The terminal's and the game's token tables are generated
# from it (tools/gen_terminal_tables.py, tools/gen_game_tables.py). Adopted 2026-11-17.
DEFAULT = "bpe72"
N_MERGES = 72


class Lexicon:
    def __init__(self, name, tokens, first_control_id, merges=()):
        self.name = name
        self.TOKENS = tokens
        self.VOCAB_SIZE = len(tokens)
        self.ID = {t: i for i, t in enumerate(tokens)}
        self.PAD, self.BOS, self.EOS, self.SEP, self.UNK = (self.ID[s] for s in vocab.SPECIALS)
        self.SPECIALS = list(vocab.SPECIALS)
        self.FIRST_CONTROL_ID = first_control_id
        self.CHAR_ID = {c: self.ID[c] for c in vocab.TEXT_CHARS}
        self.merges = [tuple(m) for m in merges]               # (left, right) in priority order
        self.merge_rank = {m: r for r, m in enumerate(self.merges)}
        # ids the model may emit as text: characters, merges, and EOS
        self.text_ids = [i for i in range(first_control_id)
                         if i >= vocab.FIRST_TEXT_ID and not tokens[i].startswith("<")]
        self.banned = [i for i in range(self.VOCAB_SIZE) if i not in set(self.text_ids) and i != self.EOS]
        self._word_cache = {}

    # ---- encoding
    def encode_chars(self, text):
        try:
            return [self.CHAR_ID[c] for c in text]
        except KeyError as e:
            raise ValueError(f"character {e.args[0]!r} is not in the vocabulary") from None

    def _encode_word(self, word):
        cached = self._word_cache.get(word)
        if cached is not None:
            return cached
        parts = list(word)
        while len(parts) > 1:
            best = None
            for i in range(len(parts) - 1):
                r = self.merge_rank.get((parts[i], parts[i + 1]))
                if r is not None and (best is None or r < best[0]):
                    best = (r, i)
            if best is None:
                break
            _, i = best
            parts[i:i + 2] = [parts[i] + parts[i + 1]]
        ids = [self.ID[p] for p in parts]
        self._word_cache[word] = ids
        return ids

    def encode_text(self, text):
        """Narration: characters, merged where the learned merges apply."""
        if not self.merges:
            return self.encode_chars(text)
        self.encode_chars(text)                               # validate characters
        ids = []
        for i, w in enumerate(text.split(" ")):
            ids += self._encode_word((" " if i else "") + w)
        return ids

    def encode_prompt(self, ctx, prompt=None):
        ids = [self.BOS]
        for name in ctx:
            if self.ID.get(name, -1) < self.FIRST_CONTROL_ID:
                raise ValueError(f"unknown control token {name!r}")
            ids.append(self.ID[name])
        if prompt:
            ids += self.encode_chars(prompt)                  # typed text: never merged
        ids.append(self.SEP)
        return ids

    def encode_example(self, example):
        prompt_ids = self.encode_prompt(example["ctx"], example.get("prompt"))
        return prompt_ids + self.encode_text(example["text"]) + [self.EOS], len(prompt_ids)

    def decode(self, ids):
        out = []
        for i in ids:
            if i == self.EOS:
                break
            out.append(self.TOKENS[i] if i in set(self.text_ids) else f"‹{self.TOKENS[i]}›")
        return "".join(out)


def learn_merges(texts, n=N_MERGES):
    """Byte-pair merges over words (a leading space belongs to the word), most frequent first.
    Returns (left, right) pairs whose results are n distinct new strings."""
    from collections import Counter
    words = Counter()
    for t in texts:
        for i, w in enumerate(t.split(" ")):
            words[tuple((" " if i else "") + w)] += 1
    merges, made = [], set()
    while len(made) < n:
        pairs = Counter()
        for w, c in words.items():
            for a, b in zip(w, w[1:]):
                pairs[(a, b)] += c
        if not pairs:
            break
        (a, b), _ = max(pairs.items(), key=lambda kv: (kv[1], kv[0]))   # deterministic ties
        merges.append((a, b))
        made.add(a + b)
        new = Counter()
        for w, c in words.items():
            out, i = [], 0
            while i < len(w):
                if i + 1 < len(w) and w[i] == a and w[i + 1] == b:
                    out.append(a + b)
                    i += 2
                else:
                    out.append(w[i])
                    i += 1
            new[tuple(out)] += c
        words = new
    return merges


def load(name="char"):
    if name == "char":
        return Lexicon("char", list(vocab.TOKENS), vocab.FIRST_CONTROL_ID)
    if name == "bpe72":
        merges = [tuple(m) for m in json.loads(MERGES_FILE.read_text())["merges"]]
        strings = []
        for a, b in merges:
            if a + b not in strings:
                strings.append(a + b)
        base = list(vocab.SPECIALS) + [f"<pad{i}>" for i in range(len(vocab.SPECIALS), vocab.FIRST_TEXT_ID)]
        base += list(vocab.TEXT_CHARS)
        tokens = base + strings
        first_control = len(tokens)
        for group, values in vocab.CONTROL_GROUPS.items():
            tokens += [f"{group}:{v}" for v in values]
        if len(tokens) > 256:
            raise ValueError(f"bpe72 vocabulary has {len(tokens)} entries")
        return Lexicon("bpe72", tokens, first_control, merges)
    raise ValueError(f"unknown lexicon {name!r}")


def display(text):
    out, cap = [], True
    for c in text:
        if cap and c.isalpha():
            out.append(c.upper())
            cap = False
        else:
            out.append(c)
        if c in ".!?":
            cap = True
    return "".join(out)
