"""Bit-exact tests of engine/source/ai_math.asm against python/fixedpoint.py, in VICE."""
import math
import random
import shutil
import struct

import pytest

from fixedpoint import exp_neg, round_div, round_shift

pytestmark = pytest.mark.skipif(not shutil.which("x64sc") or not shutil.which("acme"),
                                reason="needs VICE (x64sc) and ACME")

OP_UMUL, OP_UDIV, OP_RDIV, OP_RSHIFT, OP_ISQRT, OP_EXP = 1, 2, 3, 4, 5, 6
M64 = (1 << 64) - 1


@pytest.fixture(scope="module")
def host():
    from engine_harness import ROOT, Host
    h = Host(ROOT / "engine/tests/test_host.asm", "test_host")
    yield h
    h.close()


def call(host, op, a=0, b=0, len_a=8, len_b=4, s=0):
    vm = host.vm
    vm.write(0xC800, bytes([op, len_a, len_b, s & 0xFF]))
    vm.write(0xC810, (a & M64).to_bytes(8, "little") + (b & 0xFFFFFFFF).to_bytes(4, "little"))
    host.run()
    out = vm.read(0xC820, 0xC834)
    return (int.from_bytes(out[0:8], "little"), int.from_bytes(out[8:16], "little"),
            int.from_bytes(out[16:21], "little"))


def signed64(v):
    return v - (1 << 64) if v >> 63 else v


def test_umul(host):
    rng = random.Random(1)
    cases = [(0, 0, 4, 4), (255, 255, 1, 1), (2**32 - 1, 2**32 - 1, 4, 4), (2**24 - 1, 2**32 - 1, 3, 4)]
    cases += [(rng.getrandbits(8 * la), rng.getrandbits(8 * lb), la, lb)
              for la, lb in [(4, 4), (4, 3), (3, 2), (2, 2), (1, 4)] for _ in range(6)]
    for a, b, la, lb in cases:
        _, p, _ = call(host, OP_UMUL, a, b, la, lb)
        assert p == a * b, (a, b)


def test_udiv(host):
    rng = random.Random(2)
    cases = [(0, 1), (1, 1), (M64, 1), (M64, 0xFFFFFFFF), (12345, 7)]
    cases += [(rng.getrandbits(rng.choice([16, 40, 56, 64])), rng.getrandbits(32) | 1) for _ in range(30)]
    for n, d in cases:
        q, _, r = call(host, OP_UDIV, n, d)
        assert (q, r) == (n // d, n % d), (n, d)


def test_round_div(host):
    rng = random.Random(3)
    cases = [(5, 2), (-5, 2), (4, 3), (-4, 3), (0, 9), (-(2**50), 3)]
    cases += [(rng.randint(-2**55, 2**55), rng.randint(1, 2**31)) for _ in range(30)]
    for n, d in cases:
        q, _, _ = call(host, OP_RDIV, n, d)
        assert signed64(q) == round_div(n, d), (n, d)


def test_round_shift(host):
    rng = random.Random(4)
    cases = [(3, -4), (-24, 4), (24, 4), (-1, 1), (1, 1), (2**40 + 7, 24), (-(2**40) - 7, 24)]
    cases += [(rng.randint(-2**55, 2**55), rng.randint(1, 40)) for _ in range(30)]
    cases += [(rng.randint(-2**30, 2**30), rng.randint(-6, 0)) for _ in range(5)]
    for n, s in cases:
        q, _, _ = call(host, OP_RSHIFT, n, s=s)
        assert signed64(q) == round_shift(n, s), (n, s)


def test_isqrt(host):
    rng = random.Random(5)
    cases = [0, 1, 2, 3, 4, 15, 16, 2**62, 2**64 - 1, (2**32 - 1) ** 2]
    cases += [rng.getrandbits(rng.choice([20, 40, 58, 64])) for _ in range(30)]
    for n in cases:
        _, p, _ = call(host, OP_ISQRT, n)
        assert (p & 0xFFFFFFFF) == math.isqrt(n), n


def test_exp_neg(host):
    rng = random.Random(6)
    cases = [0, 1, 1023, 1024, 65536, 2**20 - 1, 2**20, 2**31]
    cases += [rng.randint(0, 2**20 + 5000) for _ in range(40)]
    for d in cases:
        _, p, _ = call(host, OP_EXP, d, len_a=4)
        assert (p & 0xFFFFFF) == exp_neg(d), d


def test_cycle_counter_reports(host):
    call(host, OP_UMUL, 2**32 - 1, 2**32 - 1, 4, 4)
    assert 200 < host.cycles() < 5000
