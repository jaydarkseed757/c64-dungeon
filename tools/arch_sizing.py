#!/usr/bin/env python3
"""Count parameters, multiply-accumulates (MACs), and REU traffic for candidate
decoder-only transformer geometries.

This is arithmetic on the architecture definition only. It does not measure or
predict wall-clock speed. Run: python3 tools/arch_sizing.py
"""
from dataclasses import dataclass


@dataclass
class Arch:
    name: str
    d: int        # model width
    layers: int
    heads: int
    ff: int       # feed-forward hidden width
    vocab: int
    ctx: int
    gated: bool = False   # SwiGLU-style FFN (3 matrices) vs ReLU (2)
    tied: bool = True     # output head shares token embedding
    learned_pos: bool = True
    kv_heads: int = 0     # 0 = same as heads

    def params(self):
        kv = (self.kv_heads or self.heads) * (self.d // self.heads)
        attn = self.d * self.d * 2 + self.d * kv * 2       # q,o + k,v
        ffn = self.d * self.ff * (3 if self.gated else 2)
        norms = 2 * self.d
        per_layer = attn + ffn + norms
        emb = self.vocab * self.d
        pos = self.ctx * self.d if self.learned_pos else 0
        head = 0 if self.tied else self.vocab * self.d
        return dict(per_layer=per_layer, layers=per_layer * self.layers,
                    emb=emb, pos=pos, head=head,
                    total=per_layer * self.layers + emb + pos + head + self.d)

    def macs(self, position):
        """MACs for one token at 0-based position (attention grows with it)."""
        kv = (self.kv_heads or self.heads) * (self.d // self.heads)
        dense = self.d * self.d * 2 + self.d * kv * 2 + self.d * self.ff * (3 if self.gated else 2)
        attn = 2 * (position + 1) * self.d     # q.k scores + weighted v sum, all heads
        body = (dense + attn) * self.layers
        return body, self.vocab * self.d       # (layers, output head)

    def weight_bytes_int8(self):
        p = self.params()
        rows = self.layers * (2 * self.d + 2 * ((self.kv_heads or self.heads) * (self.d // self.heads))
                              + self.ff * (2 if self.gated else 1) + self.d) + self.vocab + (self.ctx if self.learned_pos else 0)
        return p["total"] + rows * 3        # int8 weights + 3-byte row scale (Q0.24)

    def kv_bytes_int8(self):
        kv = (self.kv_heads or self.heads) * (self.d // self.heads)
        heads = self.kv_heads or self.heads
        return self.layers * self.ctx * (2 * kv + 2 * heads)   # int8 K and V + 1-byte exponent per head each


CANDIDATES = [
    Arch("bringup D32 L2 H2 F64 V96 C64", 32, 2, 2, 64, 96, 64),
    Arch("small D48 L3 H3 F128 V160 C128", 48, 3, 3, 128, 160, 128),
    Arch("BASELINE D64 L4 H4 F256 V192 C128", 64, 4, 4, 256, 192, 128),
    Arch("D64 L4 H4 F192 V192 C128", 64, 4, 4, 192, 192, 128),
    Arch("BPE512 D64 L4 H4 F256 V512 C128", 64, 4, 4, 256, 512, 128),
    Arch("Tiny21-geometry D96 L4 H4 F256 V97 C128", 96, 4, 4, 256, 97, 128),
    Arch("D128 L4 H4 F384 V192 C128", 128, 4, 4, 384, 192, 128),
    Arch("stories260K D64 L5 H8 KV4 F172 V512 C512 SwiGLU", 64, 5, 8, 172, 512, 512,
         gated=True, learned_pos=False, kv_heads=4),
]

if __name__ == "__main__":
    hdr = f"{'architecture':52} {'params':>8} {'int8 B':>8} {'f32 B':>9} {'KV B':>7} {'MAC/tok@p0':>11} {'MAC/tok@p127':>12} {'head MAC':>9}"
    print(hdr)
    print("-" * len(hdr))
    for a in CANDIDATES:
        p = a.params()
        b0, h = a.macs(0)
        b127, _ = a.macs(min(127, a.ctx - 1))
        print(f"{a.name:52} {p['total']:8,} {a.weight_bytes_int8():8,} {p['total']*4:9,} "
              f"{a.kv_bytes_int8():7,} {b0 + h:11,} {b127 + h:12,} {h:9,}")
