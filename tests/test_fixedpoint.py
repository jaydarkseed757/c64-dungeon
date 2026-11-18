import math
import random

import numpy as np
import pytest

from fixedpoint import (EXP_LIMIT, exp_neg, pack, rms_norm, round_div, round_div_np, round_shift,
                        xorshift32)


def test_round_div_ties_away_from_zero():
    assert round_div(5, 2) == 3 and round_div(-5, 2) == -3
    assert round_div(4, 3) == 1 and round_div(-4, 3) == -1
    assert round_div(0, 7) == 0
    with pytest.raises(ValueError):
        round_div(1, 0)


def test_round_div_np_matches_scalar():
    rng = random.Random(1)
    n = [rng.randint(-10**12, 10**12) for _ in range(500)] + [7, -7, 8, -8]
    for d in (1, 2, 3, 1024, 65536):
        assert list(round_div_np(np.array(n), d)) == [round_div(x, d) for x in n]


def test_round_shift_negative_is_left_shift():
    assert round_shift(3, -4) == 48
    assert round_shift(-24, 4) == -2      # -1.5 rounds away from zero


@pytest.mark.parametrize("bits", [7, 15])
def test_pack_bounds_and_error(bits):
    rng = random.Random(bits)
    for _ in range(200):
        v = [rng.randint(-2**30, 2**30) >> rng.randint(0, 30) for _ in range(16)]
        p, s = pack(v, bits)
        assert max(abs(x) for x in p) <= 2**bits - 1
        for orig, q in zip(v, p):
            assert abs(orig - (q << s)) <= (1 << s) // 2 if s else orig == q


def test_pack_zero_vector():
    assert pack([0, 0, 0], 15) == ([0, 0, 0], 0)


def test_exp_neg_accuracy_and_monotonic():
    prev = None
    for delta in range(0, EXP_LIMIT + 4096, 997):
        got = exp_neg(delta) / 2**24
        want = math.exp(-delta / 65536) if delta < EXP_LIMIT else 0.0
        assert abs(got - want) < (1 / 64) ** 2 / 8 + 1e-7   # linear-interpolation bound h^2/8
        if prev is not None:
            assert got <= prev
        prev = got
    assert exp_neg(0) == 2**24 - 1


def test_rms_norm_matches_float():
    rng = random.Random(3)
    x = [rng.randint(-3 * 65536, 3 * 65536) for _ in range(64)]
    g = [rng.randint(2048, 8192) for _ in range(64)]
    out = rms_norm(x, g, round(1e-5 * 2**32))
    xf = np.array(x) / 65536
    ref = xf / np.sqrt((xf ** 2).mean() + 1e-5) * (np.array(g) / 4096)
    assert np.abs(np.array(out) / 65536 - ref).max() < 1e-3


def test_xorshift32_reference_values():
    v, s = xorshift32(1)
    assert v == 270369 and s == 270369
    v, s = xorshift32(s)
    assert v == 67634689
