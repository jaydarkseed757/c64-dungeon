#!/usr/bin/env python3
"""Independent .d64ai validator.

Re-derives every structural property from the raw bytes using only the
standard library. It deliberately does not import python/d64ai.py, so a bug in
the writer and reader cannot hide itself.

    python3 tools/format_validator.py models/exported/baseline.d64ai
Exit status 0 = valid, 1 = invalid.
"""
import struct
import sys
import zlib

ENGINE = dict(max_layers=8, max_heads=8, max_d=128, max_ff=512, max_vocab=256, max_ctx=256, window=7168)
KINDS = {1: "tok_emb", 2: "pos_emb", 3: "attn_norm", 4: "wq", 5: "wk", 6: "wv", 7: "wo",
         8: "ffn_norm", 9: "w1", 10: "w2", 11: "final_norm", 12: "lm_head"}
REU_BANK = 512 * 1024


def u(fmt, b, off):
    return struct.unpack_from("<" + fmt, b, off)[0]


def validate(b):
    errors, notes = [], []

    def need(cond, msg):
        if not cond:
            errors.append(msg)
        return cond

    if not need(len(b) >= 256, "file shorter than 256-byte header"):
        return errors, notes
    need(b[0:6] == b"D64AI\x00", "magic is not 'D64AI\\0'")
    need(b[6] == 1, f"format_major {b[6]} unsupported")
    need(u("H", b, 8) == 256, "header_size must be 256")
    need((zlib.crc32(b[:252]) & 0xFFFFFFFF) == u("I", b, 252), "header CRC32 mismatch")
    image_len = u("I", b, 52)
    need(image_len == len(b), f"image_length {image_len} != file size {len(b)}")
    need((zlib.crc32(b[256:]) & 0xFFFFFFFF) == u("I", b, 56), "payload CRC32 mismatch")
    flags = u("H", b, 10)
    need(flags & 0b1011 == 0b1011, "flags must include tied(0), learned_pos(1), attn_scale_folded(3)")
    need(b[12] == 1, f"arch_id {b[12]} unsupported")
    need(b[6] == 1 and b[7] >= 1, f"format {b[6]}.{b[7]}: engine needs 1.1+ (bitplane matrices)")
    L, H, hd = b[13], b[14], b[15]
    d, ff, V, C = u("H", b, 16), u("H", b, 18), u("H", b, 20), u("H", b, 22)
    need(1 <= L <= ENGINE["max_layers"] and 1 <= H <= ENGINE["max_heads"], "layers/heads out of range")
    need(d == H * hd and d <= ENGINE["max_d"], "d_model != n_heads * head_dim or > 128")
    need(ff <= ENGINE["max_ff"] and V <= ENGINE["max_vocab"] and C <= ENGINE["max_ctx"], "dims over engine limits")
    need(tuple(b[24:29]) == (1, 1, 1, 1, 1), f"format codes {tuple(b[24:29])} != (1,1,1,1,1)")
    tile_rows = b[29]
    need(tile_rows >= 1 and tile_rows * (max(d, ff) + 3) <= ENGINE["window"], "tile exceeds the 7 KiB row-tile window")
    count, dir_off = b[30], u("I", b, 32)
    tok_off, tok_len = u("I", b, 36), u("I", b, 40)
    meta_off, meta_len = u("I", b, 44), u("I", b, 48)
    pad, bos, eos, sep, unk, first_ctl = b[68:74]
    need(len({pad, bos, eos, sep, unk}) == 5 and max(pad, bos, eos, sep, unk) < first_ctl <= V,
         "special token ids invalid")

    expected = {(1, 255): (V, d), (2, 255): (C, d), (11, 255): (d, 1)}
    for layer in range(L):
        expected.update({(3, layer): (d, 1), (4, layer): (d, d), (5, layer): (d, d), (6, layer): (d, d),
                         (7, layer): (d, d), (8, layer): (d, 1), (9, layer): (ff, d), (10, layer): (d, ff)})
    need(count == len(expected), f"tensor_count {count} != {len(expected)}")
    spans, seen = [], set()
    for i in range(count):
        e = dir_off + 16 * i
        kind, layer, dtype, layout, rows, cols, off, length = struct.unpack_from("<BBBBHHII", b, e)
        key = (kind, layer)
        name = f"{KINDS.get(kind, kind)}[{'G' if layer == 255 else layer}]"
        if not need(key in expected and key not in seen, f"{name}: unexpected or duplicate"):
            continue
        seen.add(key)
        need((rows, cols) == expected[key], f"{name}: shape {(rows, cols)} != {expected[key]}")
        need(off % 256 == 0, f"{name}: offset not 256-aligned")
        if cols == 1:
            need((dtype, layout, length) == (2, 3, rows * 2), f"{name}: bad vector encoding")
        elif kind != 2:
            # format 1.1 bitplane blocks (64 rows x 64 cols): masks then the block's row scales
            need((dtype, layout, length) == (1, 2, rows * (cols + 3)), f"{name}: bad bitplane matrix encoding")
            need(cols % 8 == 0, f"{name}: columns not a multiple of 8")
            cursor = off
            for r0 in range(0, rows, 64):
                n = min(64, rows - r0)
                cursor += n * cols
                for _ in range(n):
                    need(int.from_bytes(b[cursor:cursor + 3], "little") > 0, f"{name}: zero row scale")
                    cursor += 3
        else:
            need((dtype, layout, length) == (1, 1, rows * (cols + 3)), f"{name}: bad matrix encoding")
            cursor = off
            for r0 in range(0, rows, tile_rows):
                n = min(tile_rows, rows - r0)
                cursor += n * cols
                for _ in range(n):
                    need(int.from_bytes(b[cursor:cursor + 3], "little") > 0, f"{name}: zero row scale")
                    cursor += 3
                if n * (cols + 3) and (cursor - n * (cols + 3)) // REU_BANK != (cursor - 1) // REU_BANK:
                    notes.append(f"{name}: a tile crosses a 512 KiB REU boundary (driver must split)")
        spans.append((off, off + length, name))
    spans += [(tok_off, tok_off + tok_len, "tokenizer"), (meta_off, meta_off + meta_len, "metadata")]
    spans.sort()
    need(spans[0][0] >= dir_off + 16 * count, "data overlaps header/directory")
    for (a0, a1, an), (b0, _, bn) in zip(spans, spans[1:]):
        need(a1 <= b0, f"{an} overlaps {bn}")
    need(spans[-1][1] <= len(b), "section runs past end of image")

    tok = b[tok_off:tok_off + tok_len]
    need((zlib.crc32(tok) & 0xFFFFFFFF) == u("I", b, 76), "vocab_hash != CRC32(tokenizer section)")
    if need(len(tok) >= 258 and u("H", tok, 0) == V, "tokenizer count != vocab_size"):
        need(all(t < V for t in tok[2:258]), "input table maps to an id >= vocab_size")
        cursor = 258
        for i in range(V):
            kind, n = tok[cursor], tok[cursor + 1]
            need(kind in (0, 1, 2), f"token {i}: bad kind {kind}")
            need((kind == 2) == (i >= first_ctl), f"token {i}: kind {kind} inconsistent with first_control_id")
            cursor += 2 + n
        need(cursor == len(tok), "tokenizer section length mismatch")
    try:
        b[meta_off:meta_off + meta_len].decode("ascii")
    except UnicodeDecodeError:
        errors.append("metadata is not ASCII")
    notes.append(f"{len(b):,} bytes; REU span $000000-${len(b) - 1:06X}; d={d} L={L} H={H} ff={ff} "
                 f"V={V} ctx={C} tile_rows={tile_rows}")
    return errors, notes


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    errors, notes = validate(open(sys.argv[1], "rb").read())
    for n in notes:
        print("note:", n)
    for e in errors:
        print("ERROR:", e)
    print("VALID" if not errors else f"INVALID ({len(errors)} errors)")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
