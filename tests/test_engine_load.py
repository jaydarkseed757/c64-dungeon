"""Engine REU detection and model admission (engine/source/hw_reu.asm, ai_load.asm) in VICE."""
import shutil
import struct
from pathlib import Path

import pytest

import d64ai

pytestmark = pytest.mark.skipif(not shutil.which("x64sc") or not shutil.which("acme"),
                                reason="needs VICE (x64sc) and ACME")
ROOT = Path(__file__).resolve().parents[1]
PKG = ROOT / "models/exported/bringup.d64ai"
OP_INIT, OP_LOAD = 7, 8
AI_PB = 0xC5E0
STATE = 0xC480


def labels():
    from engine_harness import assemble
    return assemble(ROOT / "engine/tests/test_host.asm", "test_host")[1]


def run_op(host, op):
    host.vm.write(0xC800, bytes([op]))
    host.run()
    a, carry = host.vm.read(0xC838, 0xC839)
    return a, carry & 1


def make_host(image_bytes, tmp_path, reu_kb=16384):
    from engine_harness import Host
    img = tmp_path / "reu.bin"
    img.write_bytes(image_bytes)
    h = Host.__new__(Host)
    from engine_harness import assemble
    from vice_harness import Vice
    h.prg, h.labels = assemble(ROOT / "engine/tests/test_host.asm", "test_host")
    h.vm = Vice(reu_image=img, reu_kb=reu_kb)
    h.vm.load_prg(h.prg)
    h.entry, h.done = h.labels["test_entry"], h.labels["test_done"]
    return h


@pytest.fixture(scope="module")
def image():
    if not PKG.exists():
        pytest.skip("run `make convert MODEL=bringup` first")
    return PKG.read_bytes()


def test_detect_and_load(image, tmp_path):
    h = make_host(image, tmp_path)
    try:
        a, c = run_op(h, OP_INIT)
        assert (a, c) == (0, 0)
        caps, mb = h.vm.read(AI_PB + 1, AI_PB + 2)
        assert mb == 16 and caps & 3 == 3
        # detection must not disturb REU contents: the header is still intact
        a, c = run_op(h, OP_LOAD)
        assert c == 0, f"load failed with error {a:#x}"
        pkg = d64ai.read(image)
        hdr = pkg.header
        lab = h.labels
        got = h.vm.read(lab["m_layers"], lab["m_ctx"])
        assert list(got) == [hdr["n_layers"], hdr["n_heads"], hdr["head_dim"], hdr["d_model"],
                             hdr["d_ff"] & 0xFF, hdr["vocab_size"] & 0xFF, hdr["ctx_len"]]
        # directory offsets
        lo, mid, hi = (h.vm.read(a, a + 127) for a in (0xC300, 0xC380, 0xC400))
        for e in pkg.directory:
            kind = d64ai.KIND[e["kind"]]
            slot = {1: 0, 2: 1, 11: 2}.get(kind, 8 + e["layer"] * 8 + kind - 3) if kind in (1, 2, 11) \
                else 8 + e["layer"] * 8 + kind - 3
            assert lo[slot] | mid[slot] << 8 | hi[slot] << 16 == e["offset"], e
        # tokenizer tables
        table, entries = d64ai.parse_tokenizer(pkg.tokenizer)
        assert list(h.vm.read(0xC200, 0xC2FF)) == table
        emit = h.vm.read(0xC000, 0xC000 + hdr["vocab_size"] - 1)
        disp = h.vm.read(0xC100, 0xC100 + hdr["vocab_size"] - 1)
        for i, (kind, data) in enumerate(entries):
            want = 1 if (kind == 1 and len(data) == 1) or i == hdr["tok_eos"] else 0
            assert emit[i] == want, i
            if kind == 1:
                assert disp[i] == data[0]
        print(f"\nload_model with CRC check: {h.cycles():,} cycles (VICE, 1 MHz PAL)")
    finally:
        h.close()


@pytest.mark.parametrize("damage,error", [
    (lambda b: b.__setitem__(0, 0x58), 0x05),          # signature
    (lambda b: b.__setitem__(6, 2), 0x06),             # major version
    (lambda b: b.__setitem__(5000, b[5000] ^ 1), 0x08),  # payload CRC
    (lambda b: b.__setitem__(100, b[100] ^ 1), 0x08),  # header CRC
])
def test_rejects_bad_images(image, tmp_path, damage, error):
    b = bytearray(image)
    damage(b)
    h = make_host(bytes(b), tmp_path)
    try:
        assert run_op(h, OP_INIT) == (0, 0)
        assert run_op(h, OP_LOAD) == (error, 1)
    finally:
        h.close()


def test_small_reu_rejected(image, tmp_path):
    h = make_host(image[:65536], tmp_path, reu_kb=512)
    try:
        a, c = run_op(h, OP_INIT)
        assert (a, c) == (0x02, 1)
        assert h.vm.read(AI_PB + 2, AI_PB + 2)[0] == 0      # 512 KB -> 0 MB
    finally:
        h.close()


def test_detection_preserves_reu(image, tmp_path):
    h = make_host(image, tmp_path)
    try:
        run_op(h, OP_INIT)
        run_op(h, OP_INIT)
        assert run_op(h, OP_LOAD) == (0, 0)                # header and payload still valid
    finally:
        h.close()
