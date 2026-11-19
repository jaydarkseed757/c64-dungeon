"""BENCH.PRG (bench/source/bench.asm) in VICE: statistics and the token CRC."""
import shutil
import struct
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import bench  # noqa: E402

pytestmark = pytest.mark.skipif(not shutil.which("x64sc") or not shutil.which("acme"),
                                reason="needs VICE (x64sc) and ACME")
MODEL = ROOT / "models/exported/bringup_bpe72.d64ai"


def run(requests, max_tokens, secs=0):
    import subprocess
    from vice_harness import Vice
    subprocess.run(["make", "bench"], cwd=ROOT, check=True, capture_output=True)
    labels = bench.labels_of(ROOT / "bench/build/bench.lbl")
    with Vice(reu_image=MODEL) as vm:
        vm.load_prg(bench.PRG)
        vm.write(labels["cfg_max_req"], struct.pack("<H", requests))
        vm.write(labels["cfg_max_tok"], bytes([max_tokens]))
        if secs:
            vm.write(labels["cfg_secs"], struct.pack("<H", secs))
        vm.run_until(labels["bench_done"], timeout=1800)
        return bench.parse(vm.read(bench.RESULTS, bench.RESULTS + 63))


def test_two_requests_match_reference():
    f = run(2, 6)
    crc, gen, pre, _ = bench.expected(MODEL, 2, 6)
    assert f["sig"] == b"DMB1" and f["phase"] == 2 and f["requests"] == 2
    assert f["crc"] == crc and f["gen_tokens"] == gen and f["prompt_tokens"] == pre
    assert f["clock"] == "TOD" and 950 <= f["khz"] <= 1020          # VICE PAL: 985 kHz
    assert f["min_step"] <= f["gen_cycles"] // f["gen_tokens"] <= f["max_step"]
    assert f["chars"] > 0 and f["tenths"] > 0


def test_time_limit_ends_mid_request():
    f = run(0, 6, secs=40)                   # request 0 finishes near 1:00, request 1 does not
    assert f["phase"] == 2 and f["tenths"] >= 400
    crc, _, _, _ = bench.expected(MODEL, f["requests"], 6)
    assert f["crc"] == crc
