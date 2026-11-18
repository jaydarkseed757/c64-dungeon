"""Quantize a float DM64 checkpoint into engine integer tensors.

    weights  int8 per row, symmetric, unsigned Q0.24 row scale (max|w| / 127)
    gains    int16 Q4.12
    Wq       pre-multiplied by 1/sqrt(head_dim), so attention needs no scale step

Refuses (QuantizeError) anything that would need clamping or silent changes.
"""
import math

import numpy as np

import d64ai
from fixedpoint import GAIN_BITS, SCALE_BITS


class QuantizeError(ValueError):
    pass


def quantize_matrix(w, name):
    w = np.asarray(w, dtype=np.float64)
    if not np.isfinite(w).all():
        raise QuantizeError(f"{name}: non-finite weights")
    maxabs = np.abs(w).max(axis=1)
    if (maxabs >= 127).any():
        raise QuantizeError(f"{name}: a row needs a scale >= 1 (max |w| = {maxabs.max():.3f})")
    s24 = np.round(maxabs / 127 * (1 << SCALE_BITS)).astype(np.int64)
    s24[s24 == 0] = 1                                   # all-zero (or tiny) rows: weights round to 0
    if (s24 >= 1 << SCALE_BITS).any():
        raise QuantizeError(f"{name}: row scale overflows Q0.24")
    w8 = np.round(w * (1 << SCALE_BITS) / s24[:, None])
    if np.abs(w8).max() > 127:
        raise QuantizeError(f"{name}: quantized weight outside -127..127")
    return d64ai.Matrix(w8.astype(np.int8), s24)


def quantize_gain(g, name):
    g = np.asarray(g, dtype=np.float64)
    q = np.round(g * (1 << GAIN_BITS))
    if not np.isfinite(g).all() or q.min() < -32768 or q.max() > 32767:
        raise QuantizeError(f"{name}: gain outside Q4.12 range (-8 .. <8)")
    return q.astype(np.int64)


def quantize_state(state, cfg):
    """state: float state_dict (tensors or arrays). cfg: model config dict."""
    def arr(key):
        v = state[key]
        return v.detach().cpu().double().numpy() if hasattr(v, "detach") else np.asarray(v, np.float64)

    head_dim = cfg["d_model"] // cfg["n_heads"]
    t = {("tok_emb", d64ai.GLOBAL): quantize_matrix(arr("tok_emb.weight"), "tok_emb"),
         ("pos_emb", d64ai.GLOBAL): quantize_matrix(arr("pos_emb.weight"), "pos_emb"),
         ("final_norm", d64ai.GLOBAL): quantize_gain(arr("final_norm.weight"), "final_norm")}
    for layer in range(cfg["n_layers"]):
        p = f"blocks.{layer}."
        t[("attn_norm", layer)] = quantize_gain(arr(p + "attn_norm.weight"), p + "attn_norm")
        t[("wq", layer)] = quantize_matrix(arr(p + "wq.weight") / math.sqrt(head_dim), p + "wq")
        for k in ("wk", "wv", "wo", "w1", "w2"):
            t[(k, layer)] = quantize_matrix(arr(p + k + ".weight"), p + k)
        t[("ffn_norm", layer)] = quantize_gain(arr(p + "ffn_norm.weight"), p + "ffn_norm")
    return t


def quantization_error(state, tensors, cfg):
    """Relative RMS error per tensor kind (float vs. dequantized)."""
    head_dim = cfg["d_model"] // cfg["n_heads"]
    report = {}
    for (kind, layer), q in tensors.items():
        if not isinstance(q, d64ai.Matrix):
            continue
        key = "tok_emb.weight" if kind == "tok_emb" else "pos_emb.weight" if kind == "pos_emb" \
            else f"blocks.{layer}.{kind}.weight"
        v = state[key]
        w = v.detach().cpu().double().numpy() if hasattr(v, "detach") else np.asarray(v)
        if kind == "wq":
            w = w / math.sqrt(head_dim)
        deq = q.w.astype(np.float64) * q.s[:, None] / (1 << SCALE_BITS)
        err = float(np.sqrt(((w - deq) ** 2).mean()) / max(1e-12, np.sqrt((w ** 2).mean())))
        report.setdefault(kind, []).append(err)
    return {k: max(v) for k, v in report.items()}
