import json
import random
from pathlib import Path

import pytest
import yaml

import dataset_generator as gen
import tokenizer
import vocab

ROOT = Path(__file__).resolve().parents[1]
BANK = yaml.safe_load((ROOT / "datasets/raw/phrasebank.yaml").read_text())


def test_generation_is_deterministic():
    a = gen.generate(BANK, seed=5, count=300, ctx_len=128)[0]
    b = gen.generate(BANK, seed=5, count=300, ctx_len=128)[0]
    assert a == b


def test_examples_are_valid_and_fit():
    examples, _, _ = gen.generate(BANK, seed=6, count=2000, ctx_len=128)
    for ex in examples:
        ids, n_prompt = tokenizer.encode_example(ex)
        assert len(ids) <= 128
        assert ex["ctx"][0] == f"TASK:{ex['task']}"
        assert " a " + "o" not in f" {ex['text']}"


def test_every_task_and_control_token_appears():
    examples, _, _ = gen.generate(BANK, seed=7, count=20000, ctx_len=128)
    assert {e["task"] for e in examples} == set(vocab.CONTROL_GROUPS["TASK"])
    used = {t for e in examples for t in e["ctx"]}
    assert set(vocab.TOKENS[vocab.FIRST_CONTROL_ID:]) <= used


def test_lint_catches_comma_split_lists():
    with pytest.raises(ValueError):
        gen.lint_bank({"x": ["it staggers", "close to death.", "fine."]})
    gen.lint_bank(BANK)


def test_article_fix():
    assert gen.fix_articles("a old door and a iron gate, a key") == "an old door and an iron gate, a key"


def test_committed_splits_are_disjoint():
    train_p, val_p = ROOT / "datasets/training/train.jsonl", ROOT / "datasets/validation/val.jsonl"
    if not train_p.exists():
        pytest.skip("dataset not generated (run make dataset)")
    val = {json.dumps(json.loads(l), sort_keys=True) for l in val_p.open()}
    sample = random.Random(0).sample(train_p.read_text().splitlines(), 20000)
    assert not val & {json.dumps(json.loads(l), sort_keys=True) for l in sample}


V2 = ROOT / "datasets/raw/phrasebank_v2_additions.yaml"


def test_v2_additions_merge_and_generate():
    extra = yaml.safe_load(V2.read_text())
    bank = gen.merge_bank(BANK, extra)
    gen.lint_bank(bank)
    assert len(bank["room_hall"]) == len(BANK["room_hall"]) + len(extra["room_hall"])
    opens = bank["act_open"][0]
    assert len(opens["locked"]) == len(BANK["act_open"][0]["locked"]) + len(extra["act_open"][0]["locked"])
    assert BANK["room_hall"] != bank["room_hall"]          # v1 bank left untouched
    examples, _, _ = gen.generate(bank, seed=8, count=20000, ctx_len=128)
    used = {t for e in examples for t in e["ctx"]}
    assert set(vocab.TOKENS[vocab.FIRST_CONTROL_ID:]) <= used
    for ex in examples[:2000]:
        assert len(tokenizer.encode_example(ex)[0]) <= 128
