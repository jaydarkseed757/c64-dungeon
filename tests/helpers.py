"""Shared fixtures: a tiny random model packaged as .d64ai."""
import torch

import convert
import d64ai
import quantize
import vocab
from model import DM64Model, ModelConfig


def tiny_model(seed=0, **kw):
    torch.manual_seed(seed)
    cfg = dict(vocab_size=vocab.VOCAB_SIZE, ctx_len=32, d_model=32, n_layers=2, n_heads=2, d_ff=64)
    cfg.update(kw)
    model = DM64Model(ModelConfig(**cfg))
    with torch.no_grad():                       # larger weights than the 0.02 init, so outputs are non-trivial
        for p in model.parameters():
            if p.dim() == 2:
                p.mul_(10)
    return model


def package(model):
    cfg = model.cfg.to_dict()
    tensors = quantize.quantize_state(model.state_dict(), cfg)
    image = d64ai.write(cfg, tensors, convert.build_tokenizer_section(), "test=1\n",
                        rms_eps_q32=round(model.cfg.rms_eps * 2**32),
                        inv_sqrt_head_q24=round(2**24 / model.cfg.head_dim ** 0.5),
                        special={n: vocab.ID[n] for n in vocab.SPECIALS},
                        first_control_id=vocab.FIRST_CONTROL_ID, model_version="test",
                        model_name=b"TEST", source_sha256=bytes(32))
    return image, tensors
