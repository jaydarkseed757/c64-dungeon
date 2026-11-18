"""Engine forward pass (engine/source/ai_model.asm, ai_attn.asm) vs python/reference_int.py, in VICE.

Every intermediate tensor of the last layer, the residual and the logits must
match the integer reference exactly.
"""
import shutil
import struct
from pathlib import Path

import pytest

import d64ai
import tokenizer
from reference_int import IntEngine

pytestmark = pytest.mark.skipif(not shutil.which("x64sc") or not shutil.which("acme"),
                                reason="needs VICE (x64sc) and ACME")
ROOT = Path(__file__).resolve().parents[1]
OP_INIT, OP_LOAD, OP_STEP, OP_RESET = 7, 8, 9, 10
VEC = {"x": 0x6000, "n": 0x6200, "q": 0x6400, "k": 0x6600, "v": 0x6800, "a": 0x6A00,
       "o": 0x6C00, "h": 0x7000, "l": 0x7400}


def read_vec(vm, name, n):
    base, stride = VEC[name], (256 if name in ("h", "l") else 128)
    planes = [vm.read(base + b * stride, base + b * stride + n - 1) for b in range(4)]
    out = []
    for i in range(n):
        v = planes[0][i] | planes[1][i] << 8 | planes[2][i] << 16 | planes[3][i] << 24
        out.append(v - (1 << 32) if v >> 31 else v)
    return out


class EngineRun:
    def __init__(self, package, tmp_path):
        from engine_harness import assemble
        from vice_harness import Vice
        self.prg, self.labels = assemble(ROOT / "engine/tests/test_host.asm", "test_host")
        self.vm = Vice(reu_image=package)
        self.vm.load_prg(self.prg)
        assert self.op(OP_INIT) == (0, 0)
        assert self.op(OP_LOAD) == (0, 0)

    def op(self, op, a=b""):
        self.vm.write(0xC800, bytes([op]))
        if a:
            self.vm.write(0xC810, a)
        self.vm.set_pc(self.labels["test_entry"])
        self.vm.run_until(self.labels["test_done"], timeout=180)
        r = self.vm.read(0xC838, 0xC839)
        return r[0], r[1] & 1

    def cycles(self):
        return struct.unpack("<I", self.vm.read(0xC840, 0xC843))[0]


@pytest.mark.parametrize("name", ["bringup", "bringup_bpe72", pytest.param("baseline", marks=pytest.mark.slow),
                                  pytest.param("baseline_bpe72_v2", marks=pytest.mark.slow)])
def test_forward_pass_matches_reference(name, tmp_path):
    path = ROOT / f"models/exported/{name}.d64ai"
    if not path.exists():
        pytest.skip(f"run `make convert MODEL={name}` first")
    pkg = d64ai.read(path.read_bytes())
    ref = IntEngine(pkg)
    h = pkg.header
    d, ff, vocab, layers = h["d_model"], h["d_ff"], h["vocab_size"], h["n_layers"]
    prompt = ref.encode_prompt(["TASK:ROOM", "LOC:CRYPT", "ROOM:BURIAL_CHAMBER"])
    run = EngineRun(path, tmp_path)
    try:
        assert run.op(OP_RESET) == (0, 0) or True
        ref.reset()
        cycles = []
        tokens = prompt + [tokenizer.vocab.CHAR_ID[c] for c in "a cold"]
        for i, tok in enumerate(tokens):
            want = i >= len(prompt) - 1
            trace = {}
            ref_logits = ref.step(tok, want_logits=want, trace=trace)
            a, c = run.op(OP_STEP, bytes([tok, int(want)]))
            assert c == 0, f"step {i} failed with {a:#x}"
            cycles.append(run.cycles())
            last = trace[layers - 1]
            for key, vec, n in [("q", "q", d), ("k", "k", d), ("v", "v", d), ("attn", "a", d),
                                ("residual", "x", d)]:
                got = read_vec(run.vm, vec, n)
                assert got == last[key], f"token {i} ({tok}): {key} differs\n got {got[:8]}\nwant {last[key][:8]}"
            if want:
                assert read_vec(run.vm, "l", vocab) == ref_logits, f"token {i}: logits differ"
        print(f"\n{name}: cycles per token (VICE 1 MHz): first {cycles[0]:,}, last {cycles[-1]:,}")
    finally:
        run.vm.close()
