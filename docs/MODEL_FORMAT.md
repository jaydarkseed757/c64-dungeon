# `.d64ai` Model Format — Version 1.1

Status: implemented in Milestone 2, 2026-11-16 (`python/d64ai.py` writes and reads; `tools/format_validator.py` checks independently). Changes from the Milestone 1 proposal are marked **(M2)**. **Format 1.1 (Milestone 7, 2026-11-17)** stores every matrix except the position embedding as bitplane blocks (layout 2, §6b) for the faster engine; the engine and `d64ai.read` accept only 1.1, so 1.0 packages must be reconverted (`python/convert.py`, same weights). Any further layout change bumps the version.

## 1. Goals

- **Self-describing:** the engine reads the geometry from the header. Nothing is compiled into the engine, unlike Tiny21's hard-coded constants [SRC `network.s`].
- **Loadable as-is into the REU at address 0:** the same bytes work with the Ultimate menu "Load into REU", UCI `DOS_CMD_LOAD_REU`, and VICE `-reuimage`.
- **DMA-friendly:** tensors are 256-byte aligned. Matrix rows are grouped into tiles that a single DMA brings into the 8 KiB window.
- **Verifiable:** header CRC32, payload CRC32, source checkpoint SHA-256, vocabulary hash.
- **Strict:** the converter refuses anything the engine cannot run. It never truncates or reshapes silently.

## 2. File naming

- The canonical host-side artifact is `models/exported/<name>.d64ai`, plus `<name>.manifest.json` and `dm64_tokens.inc`.
- The distribution copy is the same bytes named `DM64AI.REU`. The Ultimate file browser offers "Load into REU" only for the `.REU` extension [AUTHOR, Tiny21 DOWNLOAD guide]. [OPEN] Confirm this on our firmware. If `.d64ai` files cannot be preloaded from the menu, the `.REU` name is the user-facing file and UCI loading accepts either name.

## 3. Conventions

- Little-endian throughout.
- Offsets are bytes from the start of the image. With the standard load at REU `$000000`, offsets equal REU addresses.
- CRC32 is IEEE 802.3 (poly `0xEDB88320`, init `0xFFFFFFFF`, final XOR), the same as Python `zlib.crc32`.
- Strings are PETSCII unless marked ASCII, and NUL-padded.

## 4. Header (256 bytes at offset 0)

| Off | Size | Field | v1.0 values / notes |
| ---: | ---: | --- | --- |
| 0 | 6 | `magic` | `"D64AI"` + `0x00` |
| 6 | 1 | `format_major` | 1. The engine rejects other majors. |
| 7 | 1 | `format_minor` | 0. Higher minors add only optional fields in reserved space. |
| 8 | 2 | `header_size` | 256 |
| 10 | 2 | `flags` | bit0 tied output head; bit1 learned absolute positions; bit2 control tokens present; **(M2)** bit3 attention scale 1/√head_dim folded into Wq. v1 requires bits 0, 1 and 3. |
| 12 | 1 | `arch_id` | 1 = DM64 decoder v1: pre-RMSNorm, multi-head attention (no GQA), ReLU FFN, residuals, final RMSNorm |
| 13 | 1 | `n_layers` | 1–8 |
| 14 | 1 | `n_heads` | 1–8 |
| 15 | 1 | `head_dim` | d_model / n_heads |
| 16 | 2 | `d_model` | ≤ 128 (engine v1 limit) |
| 18 | 2 | `d_ff` | ≤ 512 |
| 20 | 2 | `vocab_size` | ≤ 256 |
| 22 | 2 | `ctx_len` | ≤ 256 |
| 24 | 1 | `weight_format` | 1 = INT8 with one Q0.24 unsigned scale per row (3 bytes) |
| 25 | 1 | `activation_format` | 1 = INT16 dense inputs with a shared right shift; Q16.16 residual |
| 26 | 1 | `norm_format` | 1 = RMSNorm with int16 Q4.12 gains |
| 27 | 1 | `activation_fn` | 1 = ReLU |
| 28 | 1 | `kv_format` | **(M2)** 1 = INT8 per head with a power-of-two exponent per head (u8). Runtime-only; it defines the KV record `K[d] V[d] ke[H] ve[H]` (2d + 2H bytes). |
| 29 | 1 | `tile_rows` | rows per tile (for example 16); 1–64 |
| 30 | 1 | `tensor_count` | number of directory entries |
| 31 | 1 | `reserved0` | 0 |
| 32 | 4 | `dir_offset` | tensor directory |
| 36 | 4 | `tokenizer_offset` | |
| 40 | 4 | `tokenizer_length` | |
| 44 | 4 | `metadata_offset` | |
| 48 | 4 | `metadata_length` | |
| 52 | 4 | `image_length` | total bytes, including padding |
| 56 | 4 | `payload_crc32` | CRC of bytes `[256, image_length)` |
| 60 | 4 | `rms_eps_q32` | ε in Q0.32 (unsigned). 1e-5 is stored as 42950. |
| 64 | 4 | `inv_sqrt_head_q24` | 1/√head_dim, Q0.24. **(M2)** Informational only: the factor is already folded into Wq (flag bit 3). |
| 68 | 1 | `tok_pad` | special token ids |
| 69 | 1 | `tok_bos` | |
| 70 | 1 | `tok_eos` | |
| 71 | 1 | `tok_sep` | |
| 72 | 1 | `tok_unk` | |
| 73 | 1 | `first_control_id` | ids ≥ this are control tokens (never emitted as text) |
| 74 | 2 | `reserved1` | 0 |
| 76 | 4 | `vocab_hash` | CRC32 of the canonical tokenizer section; must equal the value compiled into the game |
| 80 | 16 | `model_version` | ASCII, for example `dm64-base-0001` |
| 96 | 32 | `model_name` | PETSCII display name |
| 128 | 32 | `source_sha256` | SHA-256 of the float checkpoint that was quantized |
| 160 | 92 | `reserved` | 0 |
| 252 | 4 | `header_crc32` | CRC of bytes `[0, 252)` |

## 5. Tensor directory (16 bytes per entry, 256-aligned)

| Off | Size | Field | Notes |
| ---: | ---: | --- | --- |
| 0 | 1 | `kind` | see the table below |
| 1 | 1 | `layer` | 0..n_layers−1, or `0xFF` for global tensors |
| 2 | 1 | `dtype` | 1 = int8 rows + Q0.24 scales; 2 = int16 Q4.12 vector |
| 3 | 1 | `layout` | 1 = row tiles (§6, position embedding only); 2 = bitplane blocks (§6b, all other matrices); 3 = plain vector |
| 4 | 2 | `rows` | output features (or vector length) |
| 6 | 2 | `cols` | input features (1 for vectors) |
| 8 | 4 | `offset` | 256-byte aligned |
| 12 | 4 | `length` | bytes |

| kind | Tensor | Shape (rows × cols) |
| ---: | --- | --- |
| 1 | token embedding (also the output head when tied) | vocab × d |
| 2 | position embedding | ctx × d |
| 3 | attention RMSNorm gain | d |
| 4 / 5 / 6 | Wq / Wk / Wv | d × d |
| 7 | Wo | d × d |
| 8 | FFN RMSNorm gain | d |
| 9 | W1 (up) | d_ff × d |
| 10 | W2 (down) | d × d_ff |
| 11 | final RMSNorm gain | d |
| 12 | output head (only if not tied) | vocab × d |

The converter must emit exactly one entry per required (kind, layer) pair. The loader checks every shape against the header and rejects missing, duplicate or mis-shaped entries.

There are no biases in arch 1. Adding biases would be a new `arch_id`.

## 6. Row-tile layout (layout 1)

A matrix of `rows × cols` is split into ⌈rows / tile_rows⌉ tiles. The last tile may be short.

```text
tile t:  W[r0][0..cols-1] W[r0+1][0..cols-1] … W[r0+n-1][…]     (n·cols bytes, int8)
         S[r0] S[r0+1] … S[r0+n-1]                              (n·3 bytes, u24 Q0.24)
```

- Dequantized weight = int8 × S / 2²⁴. The float row scale must be in (0, 1). The converter rejects rows that would need a larger scale, with an error rather than clamping.
- Requirement: `tile_rows × (max(d, d_ff) + 3) ≤ 7168`, so a tile fits the part of the window that row-tile users may fill (`$8000–$9BFF`; format 1.1 reserves `$9C00–$9FFF` for the generated matvec kernel).
- **(M2)** Tensors start on 256-byte boundaries. Tiles inside a tensor are contiguous: tile t starts at `offset + t · tile_rows · (cols + 3)`. One header-wide `tile_rows` = min(64, ⌊7168 / (max(d, d_ff) + 3)⌋) is used; it is 27 for the baseline (31 in format 1.0). The engine still splits DMAs at 512 KiB boundaries.
- The quantizer pre-multiplies Wq by 1/√head_dim before choosing row scales. Row scales are round(max|w| / 127 · 2²⁴). An all-zero row gets scale 1 with zero weights.

## 6b. Bitplane blocks (layout 2, format 1.1)

Used for tok_emb (also the output head), Wq, Wk, Wv, Wo, W1 and W2. `cols` must be a multiple of 8. The matrix is split into row blocks of up to 64 rows and, inside each, column blocks of up to 64 columns:

```text
row block (rows r0 … r0+n-1, n <= 64):
    column block (columns c0 … c0+k-1, k <= 64):
        for each group g of 8 columns, for each bit plane b = 0..7:
            n mask bytes, one per row: bit j = bit b of the int8 w[row][c0 + 8g + j]
    S[r0] … S[r0+n-1]                                    (n·3 bytes, u24 Q0.24)
```

- Length is still `rows × (cols + 3)`: the same bytes as layout 1, reordered.
- Plane 7 is the two's-complement sign bit, so `w = Σ_{b<7} 2^b·bit_b − 2^7·bit_7`.
- The engine computes `Σ_j w_j p_j` as `Σ_{b<7} 2^b Σ_groups SS[mask_b] − 2^7 Σ_groups SS[mask_7]`, where `SS[m]` is the sum of the group's 8 inputs selected by `m`. This is exact integer arithmetic: results are bit-identical to layout 1 (`docs/ENGINE.md` section 4).
- The idea follows Tiny21's subset-sum (`mask_row_group8`) approach [SRC]; the block layout and code are this project's own.

## 7. Tokenizer section

```text
u16 count                         = vocab_size
u8  petscii_to_id[256]            typed-character → token id (UNK if unmapped)
per token id 0..count-1:
    u8 kind                       0 special, 1 text, 2 control
    u8 len                        bytes that follow
    u8 bytes[len]                 text: PETSCII display string (normally 1 char)
                                  control/special: ASCII name, e.g. "ROOM:BURIAL_CHAMBER"
```

`vocab_hash` = CRC32 of this whole section. The game includes `dm64_tokens.inc` (generated: `TOK_ROOM_BURIAL_CHAMBER = $5A` …) and `DM64_VOCAB_HASH`. `AI_LOAD_MODEL` fails with `VOCAB_MISMATCH` if the hashes differ.

## 8. Metadata section

ASCII `key=value` lines, at most 2 KB. The engine ignores it. It is shown by `tools/model_inspector.py`.

Required keys: `created`, `trainer_commit`, `dataset_sha256`, `train_config`, `val_loss_float`, `val_loss_int`, `oracle_version`.

## 9. Converter obligations (`python/convert.py`, `python/package.py`)

1. Load the float checkpoint and verify every tensor shape against the config.
2. Reject NaN/Inf, scales outside (0, 1), and gains outside Q4.12 range (−8 … < 8).
3. Quantize rows to int8 (symmetric, max-abs per row). Report the per-tensor quantization error.
4. Run the **integer reference** (`python/reference_int.py`) on the validation prompts. Record the float vs. integer agreement (top-1 token match rate and loss).
5. Lay out tensors, directory, tokenizer and metadata. Compute the CRCs. Write the image, `manifest.json` (all fields, offsets, CRCs, SHA-256 of the image) and `dm64_tokens.inc`.
6. Re-read the image with an independent validator (`tools/format_validator.py`) that re-derives everything from the bytes.

## 10. Versioning rules

- **Major** bump: any change an older engine would misread. The engine rejects unknown majors with `BAD_VERSION`.
- **Minor** bump: new optional header fields carved from `reserved` (zero means absent), or new `layout`/`format` codes that the engine rejects individually with `UNSUPPORTED_ARCH`.
- Every released model records the format version, the oracle version and the engine build it was validated against.
