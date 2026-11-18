import pytest
import torch

import vocab
from helpers import tiny_model
from model import ModelConfig, generate


def test_forward_shape_and_causality():
    model = tiny_model().eval()
    ids = torch.randint(0, vocab.VOCAB_SIZE, (2, 20))
    out = model(ids)
    assert out.shape == (2, 20, vocab.VOCAB_SIZE)
    changed = ids.clone()
    changed[:, 15:] = (changed[:, 15:] + 1) % vocab.VOCAB_SIZE
    assert torch.allclose(model(changed)[:, :15], out[:, :15], atol=1e-5)


def test_param_count_baseline_matches_formula():
    from model import DM64Model
    m = DM64Model(ModelConfig(vocab_size=197, ctx_len=128, d_model=64, n_layers=4, n_heads=4, d_ff=256))
    per_layer = 4 * 64 * 64 + 2 * 64 * 256 + 2 * 64
    assert m.param_count() == 197 * 64 + 128 * 64 + 4 * per_layer + 64


@pytest.mark.parametrize("bad", [dict(d_model=130, n_heads=2), dict(d_ff=600), dict(n_heads=3),
                                 dict(vocab_size=300), dict(ctx_len=300), dict(n_layers=9)])
def test_engine_limits_enforced(bad):
    cfg = dict(vocab_size=197, d_model=64, n_heads=4, d_ff=256)
    cfg.update(bad)
    with pytest.raises(ValueError):
        ModelConfig(**cfg).validate()


def test_generate_respects_bans_and_eos():
    model = tiny_model()
    banned = [i for i in range(vocab.VOCAB_SIZE) if i not in vocab.CHAR_ID.values() and i != vocab.EOS]
    out = generate(model, [vocab.BOS, vocab.ID["TASK:ROOM"], vocab.SEP], max_new=20, banned=banned)
    assert out and all(i not in banned for i in out)
    assert vocab.EOS not in out[:-1]
