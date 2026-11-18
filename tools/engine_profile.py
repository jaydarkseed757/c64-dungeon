#!/usr/bin/env python3
"""Cycle profile of engine kernels for a model package, measured in VICE (cycle-exact, 1 MHz PAL).

    .venv/bin/python tools/engine_profile.py models/exported/baseline.d64ai
Reports cycles for embedding, one RMSNorm, one d x d matvec (pack included) and a
full token step at position 0, plus derived cycles per multiply-accumulate. These
are VICE 1 MHz cycle counts, not C64 Ultimate timings.
"""
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "tests"), str(ROOT / "python"), str(ROOT / "tools")]
import d64ai  # noqa: E402
from engine_harness import assemble  # noqa: E402
from vice_harness import Vice  # noqa: E402


def main(path):
    pkg = d64ai.read(Path(path).read_bytes())
    h = pkg.header
    d = h["d_model"]
    prg, labels = assemble(ROOT / "engine/tests/test_host.asm", "test_host")
    vm = Vice(reu_image=path)
    try:
        vm.load_prg(prg)

        def op(code, a=b"", timeout=600):
            vm.write(0xC800, bytes([code]))
            if a:
                vm.write(0xC810, a)
            vm.set_pc(labels["test_entry"])
            vm.run_until(labels["test_done"], timeout=timeout)
            res = vm.read(0xC838, 0xC839)
            if res[1] & 1 and code in (7, 8, 9, 10):   # kernels 11-13 return no status
                raise SystemExit(f"op {code} failed: {res[0]:#x}")
            return struct.unpack("<I", vm.read(0xC840, 0xC843))[0]

        op(7)
        load = op(8)
        rows = []
        rows.append(("load_model (header, payload CRC32, directory, tokenizer)", load, None))
        emb = op(11, bytes([1, 0]))
        rows.append(("embedding (token + position row)", emb, None))
        norm = op(12, bytes([8]))
        rows.append(("rmsnorm (d elements)", norm, None))
        mv = op(13, bytes([9]))
        rows.append((f"pack + matvec Wq ({d}x{d} = {d * d} MACs)", mv, d * d))
        op(10)
        step0 = op(9, bytes([1, 1]))
        L, ff, V = h["n_layers"], h["d_ff"], h["vocab_size"]
        macs = L * (4 * d * d + 2 * d * ff) + V * d + L * 2 * d
        rows.append((f"full token, position 0, with logits ({macs:,} MACs)", step0, macs))
    finally:
        vm.close()
    print(f"{path}: d={d} L={h['n_layers']} ff={h['d_ff']} V={h['vocab_size']} (VICE x64sc PAL, 1 MHz cycles)")
    for name, cyc, m in rows:
        extra = f"   {cyc / m:,.0f} cycles/MAC" if m else ""
        print(f"  {name:62} {cyc:>12,}{extra}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else str(ROOT / "models/exported/baseline_bpe72_v2.d64ai"))
