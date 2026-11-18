#!/usr/bin/env python3
"""Print a human-readable summary of a .d64ai package.

    python tools/model_inspector.py models/exported/baseline.d64ai [--tokens]
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))
import d64ai  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package")
    parser.add_argument("--tokens", action="store_true", help="list every vocabulary entry")
    args = parser.parse_args()
    image = Path(args.package).read_bytes()
    pkg = d64ai.read(image)
    h = pkg.header
    print(f"{args.package}: {len(image):,} bytes (REU $000000-${len(image) - 1:06X})")
    print(f"format {h['format_major']}.{h['format_minor']}  arch {h['arch_id']}  "
          f"version {h['model_version'].rstrip(bytes(1)).decode()}  flags ${h['flags']:04X}")
    print(f"d_model {h['d_model']}  layers {h['n_layers']}  heads {h['n_heads']}x{h['head_dim']}  "
          f"d_ff {h['d_ff']}  vocab {h['vocab_size']}  ctx {h['ctx_len']}  tile_rows {h['tile_rows']}")
    print(f"rms_eps_q32 {h['rms_eps_q32']}  vocab_hash ${h['vocab_hash']:08X}  "
          f"payload_crc32 ${h['payload_crc32']:08X}  header_crc32 ${h['header_crc32']:08X}")
    print(f"source sha256 {h['source_sha256'].hex()}")
    print("\ntensor          layer  rows  cols   REU offset   bytes")
    for e in pkg.directory:
        layer = "G" if e["layer"] == d64ai.GLOBAL else e["layer"]
        print(f"{e['kind']:<15} {layer!s:>5} {e['rows']:5} {e['cols']:5}   ${e['offset']:06X}  {e['length']:7,}")
    table, entries = d64ai.parse_tokenizer(pkg.tokenizer)
    counts = {k: sum(1 for kind, _ in entries if kind == k) for k in (0, 1, 2)}
    print(f"\ntokenizer: {counts[1]} text, {counts[2]} control, {counts[0]} special/unused; "
          f"{sum(t != h['tok_unk'] for t in table)} mapped PETSCII input codes")
    if args.tokens:
        for i, (kind, data) in enumerate(entries):
            shown = f"${data[0]:02X}" if kind == 1 else data.decode("ascii")
            print(f"  {i:3} ${i:02X}  {'SXC'[kind] if kind < 3 else '?'}  {shown}")
    print("\nmetadata:")
    for line in pkg.metadata.splitlines():
        print("  " + (line if len(line) < 160 else line[:157] + "..."))


if __name__ == "__main__":
    main()
