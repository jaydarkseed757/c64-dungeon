"""Integer arithmetic shared by the quantizer and the integer reference.

Every rounding rule here is part of the engine contract (docs/INFERENCE.md):
the 6502 implementation must produce identical integers.

Formats:
    Q16.16   residual stream, norm outputs, q/k/v, logits (signed 32-bit)
    Q0.24    matrix row scales (unsigned 24-bit), softmax weights
    Q4.12    RMSNorm gains (signed 16-bit)
    Q0.32    RMS epsilon
"""
import math

import numpy as np

Q16 = 16
SCALE_BITS = 24
GAIN_BITS = 12
EXP_STEPS = 64          # table resolution: exp(-i/64)
EXP_ENTRIES = 1025      # covers deltas 0 .. 16.0
# Capped at 2^24 - 1 so every entry fits three bytes (exp(0) = 1.0 would need 25 bits).
EXP_TABLE = tuple(min((1 << SCALE_BITS) - 1, round((1 << SCALE_BITS) * math.exp(-i / EXP_STEPS)))
                  for i in range(EXP_ENTRIES))
EXP_LIMIT = (EXP_ENTRIES - 1) * (1 << Q16) // EXP_STEPS     # 16.0 in Q16.16
EXP_FRAC_BITS = Q16 - 6                                     # 1/64 step = 2^10 in Q16.16


def round_div(n, d):
    """Integer n / positive d, rounded to nearest, ties away from zero."""
    if d <= 0:
        raise ValueError("divisor must be positive")
    q = (abs(n) + d // 2) // d
    return -q if n < 0 else q


def round_shift(n, s):
    """n / 2^s rounded (ties away from zero) for s > 0; n * 2^-s for s <= 0."""
    if s <= 0:
        return n << -s
    return round_div(n, 1 << s)


def round_div_np(n, d):
    """Vectorized round_div for int64 arrays (d may be a scalar or array > 0)."""
    n = np.asarray(n, dtype=np.int64)
    q = (np.abs(n) + np.asarray(d, dtype=np.int64) // 2) // d
    return np.where(n < 0, -q, q)


def round_shift_np(n, s):
    if s <= 0:
        return np.asarray(n, dtype=np.int64) << -s
    return round_div_np(n, 1 << s)


def pack(values, bits):
    """Block floating point: scale a vector to signed `bits`-bit magnitudes
    (<= 2^bits - 1) with one shared right shift. Returns (list, shift)."""
    values = [int(v) for v in values]
    peak = max((abs(v) for v in values), default=0)
    if peak == 0:
        return [0] * len(values), 0
    shift = max(0, peak.bit_length() - bits)
    if round_shift(peak, shift) > (1 << bits) - 1:
        shift += 1
    return [round_shift(v, shift) for v in values], shift


def exp_neg(delta):
    """exp(-delta) in Q0.24 for delta >= 0 in Q16.16, by table + linear interpolation."""
    if delta < 0:
        raise ValueError("exp_neg needs delta >= 0")
    if delta >= EXP_LIMIT:
        return 0
    index = delta >> EXP_FRAC_BITS
    frac = delta & ((1 << EXP_FRAC_BITS) - 1)
    left, right = EXP_TABLE[index], EXP_TABLE[index + 1]
    return left + round_div((right - left) * frac, 1 << EXP_FRAC_BITS)


def rms_norm(x, gains, eps_q32):
    """x: Q16.16 ints, gains: Q4.12 ints. Returns Q16.16 ints."""
    energy = sum(v * v for v in x)                      # Q32.32 units
    mean_sq = round_div(energy, len(x)) + eps_q32
    root = math.isqrt(mean_sq << 16)                    # rms in Q?.24 (8 guard bits)
    return [round_div((v * g) << (SCALE_BITS - GAIN_BITS), root) for v, g in zip(x, gains)]


def xorshift32(state):
    """One step of xorshift32 (13, 17, 5). Returns (value, new_state)."""
    x = state
    x ^= (x << 13) & 0xFFFFFFFF
    x ^= x >> 17
    x ^= (x << 5) & 0xFFFFFFFF
    return x, x
