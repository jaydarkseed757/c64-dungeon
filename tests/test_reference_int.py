import numpy as np
import pytest
import torch

import d64ai
import vocab
from helpers import package, tiny_model
from reference_int import ContextFull, IntEngine


@pytest.fixture(scope="module")
def pair():
    model = tiny_model(seed=3).eval()
    image, _ = package(model)
    return model, IntEngine(d64ai.read(image))


def test_int_logits_track_float(pair):
    model, engine = pair
    ids = [vocab.BOS, vocab.ID["TASK:ROOM"], vocab.ID["LOC:CRYPT"], vocab.SEP] + \
        [vocab.CHAR_ID[c] for c in "the cold crypt"]
    with torch.no_grad():
        flog = model(torch.tensor([ids]))[0].numpy()
    engine.reset()
    agree = 0
    for pos, tok in enumerate(ids):
        ilog = np.array(engine.step(tok)) / 65536
        corr = np.corrcoef(ilog, flog[pos])[0, 1]
        assert corr > 0.995, f"position {pos}: correlation {corr:.4f}"
        agree += int(np.argmax(ilog) == np.argmax(flog[pos]))
    assert agree >= len(ids) - 1


def test_deterministic_and_prefill_equivalent(pair):
    _, engine = pair
    prompt = [vocab.BOS, vocab.ID["TASK:EVENT"], vocab.SEP]
    a = engine.generate(prompt, max_chars=10)
    b = engine.generate(prompt, max_chars=10)
    assert a == b
    engine.reset()
    for tok in prompt[:-1]:
        engine.step(tok, want_logits=True)        # computing logits must not change state
    logits = engine.step(prompt[-1])
    assert engine.pick(logits)[0] == a[0]


def test_only_text_or_eos_emitted(pair):
    _, engine = pair
    out = engine.generate([vocab.BOS, vocab.ID["TASK:ROOM"], vocab.SEP], max_chars=20,
                          inv_temp_q8=256, top_k=8, seed=99)
    assert all(t == vocab.EOS or t in vocab.CHAR_ID.values() for t in out)


def test_context_full_is_rejected(pair):
    _, engine = pair
    engine.reset()
    for i in range(engine.ctx_len):
        engine.step(vocab.CHAR_ID["a"], want_logits=False)
    with pytest.raises(ContextFull):
        engine.step(vocab.CHAR_ID["a"])
    assert engine.pos == engine.ctx_len


def test_accumulators_fit_32_bits(pair):
    _, engine = pair
    assert all(v < 2**31 for v in engine.max_abs.values())
