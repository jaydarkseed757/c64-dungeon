"""Read and write .d64ai model packages, format 1.1 (docs/MODEL_FORMAT.md).

A package is a byte image loaded unchanged into the REU at address 0.
"""
import struct
import zlib
from dataclasses import dataclass, field

import numpy as np

MAGIC = b"D64AI\x00"
FORMAT_MAJOR, FORMAT_MINOR = 1, 1
HEADER_SIZE = 256
DIR_ENTRY = 16
ALIGN = 256
TILE_WINDOW = 7168      # engine DMA window for row tiles ($8000-$9bff)

ARCH_DM64_V1 = 1
WEIGHT_INT8_ROWSCALE = 1
ACT_INT16_BLOCKSHIFT = 1
NORM_RMS_Q412 = 1
ACT_FN_RELU = 1
KV_INT8_HEAD_POW2 = 1

FLAG_TIED = 1 << 0
FLAG_LEARNED_POS = 1 << 1
FLAG_CONTROL_TOKENS = 1 << 2
FLAG_ATTN_SCALE_FOLDED = 1 << 3
REQUIRED_FLAGS = FLAG_TIED | FLAG_LEARNED_POS | FLAG_ATTN_SCALE_FOLDED

DTYPE_INT8_ROWS = 1
DTYPE_INT16_Q412 = 2
LAYOUT_ROW_TILES = 1
LAYOUT_BITPLANE8 = 2   # format 1.1: every matrix except pos_emb (section 6b)
BP_ROWS = BP_COLS = 64  # bitplane block: up to 64 rows x 64 columns
LAYOUT_VECTOR = 3
GLOBAL = 0xFF

KIND = {"tok_emb": 1, "pos_emb": 2, "attn_norm": 3, "wq": 4, "wk": 5, "wv": 6, "wo": 7,
        "ffn_norm": 8, "w1": 9, "w2": 10, "final_norm": 11, "lm_head": 12}
KIND_NAME = {v: k for k, v in KIND.items()}
LAYER_KINDS = ("attn_norm", "wq", "wk", "wv", "wo", "ffn_norm", "w1", "w2")
VECTOR_KINDS = {"attn_norm", "ffn_norm", "final_norm"}

# Header field layout: (name, struct code, offset). Everything little-endian.
HEADER_FIELDS = [
    ("magic", "6s", 0), ("format_major", "B", 6), ("format_minor", "B", 7),
    ("header_size", "H", 8), ("flags", "H", 10), ("arch_id", "B", 12), ("n_layers", "B", 13),
    ("n_heads", "B", 14), ("head_dim", "B", 15), ("d_model", "H", 16), ("d_ff", "H", 18),
    ("vocab_size", "H", 20), ("ctx_len", "H", 22), ("weight_format", "B", 24),
    ("activation_format", "B", 25), ("norm_format", "B", 26), ("activation_fn", "B", 27),
    ("kv_format", "B", 28), ("tile_rows", "B", 29), ("tensor_count", "B", 30),
    ("reserved0", "B", 31), ("dir_offset", "I", 32), ("tokenizer_offset", "I", 36),
    ("tokenizer_length", "I", 40), ("metadata_offset", "I", 44), ("metadata_length", "I", 48),
    ("image_length", "I", 52), ("payload_crc32", "I", 56), ("rms_eps_q32", "I", 60),
    ("inv_sqrt_head_q24", "I", 64), ("tok_pad", "B", 68), ("tok_bos", "B", 69),
    ("tok_eos", "B", 70), ("tok_sep", "B", 71), ("tok_unk", "B", 72),
    ("first_control_id", "B", 73), ("reserved1", "H", 74), ("vocab_hash", "I", 76),
    ("model_version", "16s", 80), ("model_name", "32s", 96), ("source_sha256", "32s", 128),
    ("header_crc32", "I", 252),
]


class FormatError(ValueError):
    pass


def crc32(data):
    return zlib.crc32(data) & 0xFFFFFFFF


def align(n, a=ALIGN):
    return (n + a - 1) // a * a


def tile_rows_for(max_cols):
    return max(1, min(64, TILE_WINDOW // (max_cols + 3)))


@dataclass
class Matrix:
    """int8 weights [rows, cols] and unsigned Q0.24 row scales [rows]."""
    w: np.ndarray
    s: np.ndarray

    def tiled_bytes(self, tile_rows):
        out = bytearray()
        for r0 in range(0, self.w.shape[0], tile_rows):
            out += self.w[r0:r0 + tile_rows].astype(np.int8).tobytes()
            for s in self.s[r0:r0 + tile_rows]:
                out += int(s).to_bytes(3, "little")
        return bytes(out)

    def bitplane_bytes(self):
        """Layout 2. For each block of up to 64 rows: for each block of up to 64 columns,
        for each group of 8 columns g, for each bit plane b (0..7, b7 = sign), one mask
        byte per row (bit j = bit b of w[row][8g+j]); then the block's row scales."""
        rows, cols = self.w.shape
        if cols % 8:
            raise FormatError("bitplane layout needs a multiple of 8 columns")
        u = self.w.astype(np.int8).view(np.uint8)
        out = bytearray()
        for r0 in range(0, rows, BP_ROWS):
            blk = u[r0:r0 + BP_ROWS]
            for c0 in range(0, cols, BP_COLS):
                for g in range(c0, min(cols, c0 + BP_COLS), 8):
                    grp = blk[:, g:g + 8].astype(np.int64)
                    for b in range(8):
                        masks = ((grp >> b) & 1) << np.arange(8)
                        out += masks.sum(axis=1).astype(np.uint8).tobytes()
            for s in self.s[r0:r0 + BP_ROWS]:
                out += int(s).to_bytes(3, "little")
        return bytes(out)

    @staticmethod
    def from_bitplanes(blob, rows, cols):
        u = np.zeros((rows, cols), dtype=np.int64)
        s = np.empty(rows, dtype=np.int64)
        cur = 0
        for r0 in range(0, rows, BP_ROWS):
            n = min(BP_ROWS, rows - r0)
            for c0 in range(0, cols, BP_COLS):
                for g in range(c0, min(cols, c0 + BP_COLS), 8):
                    for b in range(8):
                        masks = np.frombuffer(blob, dtype=np.uint8, count=n, offset=cur).astype(np.int64)
                        cur += n
                        bits = (masks[:, None] >> np.arange(8)) & 1
                        u[r0:r0 + n, g:g + 8] |= bits << b
            for j in range(n):
                s[r0 + j] = int.from_bytes(blob[cur:cur + 3], "little")
                cur += 3
        return Matrix(u.astype(np.uint8).view(np.int8).reshape(rows, cols), s)


@dataclass
class Package:
    header: dict
    tensors: dict                    # (kind name, layer or GLOBAL) -> Matrix | np.ndarray(int16)
    tokenizer: bytes
    metadata: str = ""
    directory: list = field(default_factory=list)

    def matrix(self, kind, layer=GLOBAL):
        return self.tensors[(kind, layer)]


def tokenizer_section(tokens, kinds, display, input_table):
    """tokens: names; kinds: 0 special/1 text/2 control; display: bytes per token."""
    out = bytearray(struct.pack("<H", len(tokens)))
    out += bytes(input_table)
    for kind, data in zip(kinds, display):
        if len(data) > 255:
            raise FormatError("token string too long")
        out += bytes([kind, len(data)]) + data
    return bytes(out)


def write(cfg, tensors, tokenizer, metadata, *, rms_eps_q32, inv_sqrt_head_q24, special,
          first_control_id, model_version, model_name, source_sha256):
    """Build a package image. cfg: dict with n_layers, n_heads, d_model, d_ff, vocab_size, ctx_len."""
    d, ff = cfg["d_model"], cfg["d_ff"]
    tile_rows = tile_rows_for(max(d, ff))
    order = [("tok_emb", GLOBAL), ("pos_emb", GLOBAL)]
    for layer in range(cfg["n_layers"]):
        order += [(k, layer) for k in LAYER_KINDS]
    order.append(("final_norm", GLOBAL))
    missing = [k for k in order if k not in tensors]
    if missing or len(tensors) != len(order):
        raise FormatError(f"tensor set mismatch: missing {missing}, have {len(tensors)}")

    blobs, entries = [], []
    cursor = align(HEADER_SIZE + DIR_ENTRY * len(order))
    for kind, layer in order:
        t = tensors[(kind, layer)]
        if kind in VECTOR_KINDS:
            blob = np.asarray(t, dtype="<i2").tobytes()
            rows, cols, dtype, layout = len(t), 1, DTYPE_INT16_Q412, LAYOUT_VECTOR
        elif kind == "pos_emb":
            blob = t.tiled_bytes(tile_rows)
            rows, cols = t.w.shape
            dtype, layout = DTYPE_INT8_ROWS, LAYOUT_ROW_TILES
        else:
            blob = t.bitplane_bytes()
            rows, cols = t.w.shape
            dtype, layout = DTYPE_INT8_ROWS, LAYOUT_BITPLANE8
        entries.append((KIND[kind], layer, dtype, layout, rows, cols, cursor, len(blob)))
        blobs.append((cursor, blob))
        cursor = align(cursor + len(blob))
    tok_off = cursor
    cursor = align(cursor + len(tokenizer))
    meta_bytes = metadata.encode("ascii")
    meta_off = cursor
    image_length = align(cursor + len(meta_bytes))

    image = bytearray(image_length)
    for off, blob in blobs:
        image[off:off + len(blob)] = blob
    image[tok_off:tok_off + len(tokenizer)] = tokenizer
    image[meta_off:meta_off + len(meta_bytes)] = meta_bytes
    for i, e in enumerate(entries):
        struct.pack_into("<BBBBHHII", image, HEADER_SIZE + DIR_ENTRY * i, *e)

    values = {
        "magic": MAGIC, "format_major": FORMAT_MAJOR, "format_minor": FORMAT_MINOR,
        "header_size": HEADER_SIZE, "flags": REQUIRED_FLAGS | FLAG_CONTROL_TOKENS,
        "arch_id": ARCH_DM64_V1, "n_layers": cfg["n_layers"], "n_heads": cfg["n_heads"],
        "head_dim": d // cfg["n_heads"], "d_model": d, "d_ff": ff, "vocab_size": cfg["vocab_size"],
        "ctx_len": cfg["ctx_len"], "weight_format": WEIGHT_INT8_ROWSCALE,
        "activation_format": ACT_INT16_BLOCKSHIFT, "norm_format": NORM_RMS_Q412,
        "activation_fn": ACT_FN_RELU, "kv_format": KV_INT8_HEAD_POW2, "tile_rows": tile_rows,
        "tensor_count": len(order), "reserved0": 0, "dir_offset": HEADER_SIZE,
        "tokenizer_offset": tok_off, "tokenizer_length": len(tokenizer),
        "metadata_offset": meta_off, "metadata_length": len(meta_bytes),
        "image_length": image_length, "payload_crc32": 0, "rms_eps_q32": rms_eps_q32,
        "inv_sqrt_head_q24": inv_sqrt_head_q24, "tok_pad": special["PAD"],
        "tok_bos": special["BOS"], "tok_eos": special["EOS"], "tok_sep": special["SEP"],
        "tok_unk": special["UNK"], "first_control_id": first_control_id, "reserved1": 0,
        "vocab_hash": crc32(tokenizer), "model_version": model_version.encode("ascii")[:16],
        "model_name": model_name[:32], "source_sha256": source_sha256, "header_crc32": 0,
    }
    for name, code, off in HEADER_FIELDS:
        struct.pack_into("<" + code, image, off, values[name])
    struct.pack_into("<I", image, 56, crc32(bytes(image[HEADER_SIZE:])))
    struct.pack_into("<I", image, 252, crc32(bytes(image[:252])))
    return bytes(image)


def read_header(image):
    if len(image) < HEADER_SIZE:
        raise FormatError("image shorter than header")
    return {name: struct.unpack_from("<" + code, image, off)[0] for name, code, off in HEADER_FIELDS}


def read(image):
    """Parse and fully validate a package. Raises FormatError on any problem."""
    h = read_header(image)
    if h["magic"] != MAGIC:
        raise FormatError("bad signature")
    if h["format_major"] != FORMAT_MAJOR:
        raise FormatError(f"unsupported format major {h['format_major']}")
    if crc32(image[:252]) != h["header_crc32"]:
        raise FormatError("header CRC mismatch")
    if h["image_length"] != len(image):
        raise FormatError(f"image_length {h['image_length']} != file size {len(image)}")
    if crc32(image[HEADER_SIZE:]) != h["payload_crc32"]:
        raise FormatError("payload CRC mismatch")
    checks = [
        (h["arch_id"] == ARCH_DM64_V1, "unsupported arch_id"),
        (h["flags"] & REQUIRED_FLAGS == REQUIRED_FLAGS, "required flags missing"),
        (h["weight_format"] == WEIGHT_INT8_ROWSCALE, "unsupported weight format"),
        (h["activation_format"] == ACT_INT16_BLOCKSHIFT, "unsupported activation format"),
        (h["norm_format"] == NORM_RMS_Q412, "unsupported norm format"),
        (h["activation_fn"] == ACT_FN_RELU, "unsupported activation function"),
        (h["kv_format"] == KV_INT8_HEAD_POW2, "unsupported kv format"),
        (1 <= h["n_layers"] <= 8 and 1 <= h["n_heads"] <= 8, "layer/head count out of range"),
        (h["d_model"] <= 128 and h["d_model"] == h["n_heads"] * h["head_dim"], "bad d_model/head_dim"),
        (h["format_minor"] >= 1, "format 1.0 (row-tile matrices) is no longer supported: reconvert"),
        (h["d_model"] % 8 == 0 and h["d_ff"] % 8 == 0, "d_model and d_ff must be multiples of 8"),
        (h["d_ff"] <= 512 and h["vocab_size"] <= 256 and h["ctx_len"] <= 256, "dimension over engine limit"),
        (h["tile_rows"] >= 1 and h["tile_rows"] * (max(h["d_model"], h["d_ff"]) + 3) <= TILE_WINDOW,
         "tile does not fit the 7 KiB row-tile window"),
    ]
    for ok, msg in checks:
        if not ok:
            raise FormatError(msg)

    d, ff, tr = h["d_model"], h["d_ff"], h["tile_rows"]
    expect = {("tok_emb", GLOBAL): (h["vocab_size"], d), ("pos_emb", GLOBAL): (h["ctx_len"], d),
              ("final_norm", GLOBAL): (d, 1)}
    for layer in range(h["n_layers"]):
        expect.update({("attn_norm", layer): (d, 1), ("wq", layer): (d, d), ("wk", layer): (d, d),
                       ("wv", layer): (d, d), ("wo", layer): (d, d), ("ffn_norm", layer): (d, 1),
                       ("w1", layer): (ff, d), ("w2", layer): (d, ff)})
    if h["tensor_count"] != len(expect):
        raise FormatError(f"tensor_count {h['tensor_count']} != expected {len(expect)}")

    tensors, directory = {}, []
    for i in range(h["tensor_count"]):
        kind, layer, dtype, layout, rows, cols, off, length = struct.unpack_from(
            "<BBBBHHII", image, h["dir_offset"] + DIR_ENTRY * i)
        name = KIND_NAME.get(kind)
        key = (name, layer)
        if key not in expect or key in tensors:
            raise FormatError(f"unexpected or duplicate tensor {key}")
        if (rows, cols) != expect[key]:
            raise FormatError(f"{key} shape {(rows, cols)} != {expect[key]}")
        if off % ALIGN or off + length > h["tokenizer_offset"]:
            raise FormatError(f"{key} offset/length out of bounds")
        blob = image[off:off + length]
        if name in VECTOR_KINDS:
            if (dtype, layout, length) != (DTYPE_INT16_Q412, LAYOUT_VECTOR, rows * 2):
                raise FormatError(f"{key} has wrong vector encoding")
            tensors[key] = np.frombuffer(blob, dtype="<i2").astype(np.int64)
        else:
            want = LAYOUT_ROW_TILES if name == "pos_emb" else LAYOUT_BITPLANE8
            if (dtype, layout, length) != (DTYPE_INT8_ROWS, want, rows * (cols + 3)):
                raise FormatError(f"{key} has wrong matrix encoding")
            if layout == LAYOUT_BITPLANE8:
                m = Matrix.from_bitplanes(blob, rows, cols)
                if (m.s == 0).any():
                    raise FormatError(f"{key} has a zero row scale")
                tensors[key] = m
                directory.append(dict(kind=name, layer=layer, rows=rows, cols=cols, offset=off, length=length))
                continue
            w = np.empty((rows, cols), dtype=np.int8)
            s = np.empty(rows, dtype=np.int64)
            cursor = 0
            for r0 in range(0, rows, tr):
                n = min(tr, rows - r0)
                w[r0:r0 + n] = np.frombuffer(blob, dtype=np.int8, count=n * cols,
                                             offset=cursor).reshape(n, cols)
                cursor += n * cols
                for j in range(n):
                    s[r0 + j] = int.from_bytes(blob[cursor:cursor + 3], "little")
                    cursor += 3
            if (s == 0).any():
                raise FormatError(f"{key} has a zero row scale")
            tensors[key] = Matrix(w, s)
        directory.append(dict(kind=name, layer=layer, rows=rows, cols=cols, offset=off, length=length))

    tok = image[h["tokenizer_offset"]:h["tokenizer_offset"] + h["tokenizer_length"]]
    if crc32(tok) != h["vocab_hash"]:
        raise FormatError("vocab_hash does not match tokenizer section")
    meta = image[h["metadata_offset"]:h["metadata_offset"] + h["metadata_length"]].decode("ascii")
    return Package(h, tensors, tok, meta, directory)


def parse_tokenizer(section):
    count = struct.unpack_from("<H", section, 0)[0]
    input_table = list(section[2:258])
    cursor, entries = 258, []
    for _ in range(count):
        kind, n = section[cursor], section[cursor + 1]
        entries.append((kind, bytes(section[cursor + 2:cursor + 2 + n])))
        cursor += 2 + n
    if cursor != len(section):
        raise FormatError("tokenizer section length mismatch")
    return input_table, entries
