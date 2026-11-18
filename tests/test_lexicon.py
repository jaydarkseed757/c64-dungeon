import json
from pathlib import Path

import pytest

import lexicon
import tokenizer
import vocab

ROOT = Path(__file__).resolve().parents[1]


def test_char_lexicon_is_vocab_v1():
    lex = lexicon.load("char")
    assert lex.TOKENS == vocab.TOKENS and lex.FIRST_CONTROL_ID == vocab.FIRST_CONTROL_ID
    ex = {"ctx": ["TASK:ROOM", "LOC:CRYPT"], "text": "a cold crypt."}
    assert lex.encode_example(ex) == tokenizer.encode_example(ex)


@pytest.fixture(scope="module")
def bpe():
    if not lexicon.MERGES_FILE.exists():
        pytest.skip("run tools/learn_merges.py first")
    return lexicon.load("bpe72")


def test_bpe72_layout(bpe):
    assert bpe.VOCAB_SIZE == 256
    assert bpe.FIRST_CONTROL_ID == 123
    assert bpe.TOKENS[5:51] == list(vocab.TEXT_CHARS)          # characters keep their ids
    assert all(":" in t for t in bpe.TOKENS[123:])
    assert len(set(bpe.TOKENS)) == 256
    assert len(bpe.text_ids) == 46 + 72


def test_bpe72_round_trip_and_compression(bpe):
    rows = [json.loads(l) for l in (ROOT / "datasets/validation/val.jsonl").open()][:300]
    chars = tokens = 0
    for ex in rows:
        ids, n = bpe.encode_example(ex)
        assert bpe.decode(ids[n:]) == ex["text"]
        chars += len(ex["text"])
        tokens += len(ids) - n - 1
    assert chars / tokens > 1.5


def test_typed_prompts_are_never_merged(bpe):
    ids = bpe.encode_prompt(["TASK:FREE"], "the dark")
    assert ids[2:-1] == [bpe.CHAR_ID[c] for c in "the dark"]


def test_merges_are_deterministic():
    texts = ["the cold crypt.", "you see the door.", "the door is locked."] * 5
    assert lexicon.learn_merges(texts, 10) == lexicon.learn_merges(list(texts), 10)
