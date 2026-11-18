#!/usr/bin/env python3
"""Bit-exact integer reference for the DM64 6502 engine.

It reads a .d64ai package and runs inference using only the integer operations
the assembly engine will use (fixedpoint.py, docs/INFERENCE.md). Assembly
output must match this module's logits and tokens exactly.

    python python/reference_int.py models/exported/baseline.d64ai \
        --ctx TASK:ROOM LOC:CRYPT ROOM:BURIAL_CHAMBER
"""
import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import d64ai  # noqa: E402
from fixedpoint import (Q16, SCALE_BITS, exp_neg, pack, rms_norm, round_div,  # noqa: E402
                        round_shift, round_shift_np, xorshift32)

ACC_LIMIT = 1 << 62


class ContextFull(Exception):
    pass


class IntEngine:
    def __init__(self, package):
        self.pkg = package
        h = package.header
        self.h = h
        self.d, self.n_heads, self.hd = h["d_model"], h["n_heads"], h["head_dim"]
        self.n_layers, self.ctx_len, self.vocab = h["n_layers"], h["ctx_len"], h["vocab_size"]
        self.eps = h["rms_eps_q32"]
        self.mats = {k: (v.w.astype(np.int64), v.s.astype(np.int64))
                     for k, v in package.tensors.items() if isinstance(v, d64ai.Matrix)}
        self.gains = {k: [int(x) for x in v] for k, v in package.tensors.items()
                      if not isinstance(v, d64ai.Matrix)}
        _, self.token_entries = d64ai.parse_tokenizer(package.tokenizer)
        self.allowed = [i for i in range(self.vocab) if self._is_emittable(i)]
        self.max_abs = {}
        self.reset()

    def _is_emittable(self, i):
        h = self.h
        if i == h["tok_eos"]:
            return True
        return i < h["first_control_id"] and self.token_entries[i][0] == 1

    # ---- token strings straight from the package (works for any lexicon)
    def token_text(self, i):
        kind, data = self.token_entries[i]
        if kind != 1:
            return f"\u2039{data.decode('ascii')}\u203a"
        return "".join(chr(c + 32) if 0x41 <= c <= 0x5A else chr(c) for c in data)

    def decode(self, ids):
        out = []
        for i in ids:
            if i == self.h["tok_eos"]:
                break
            out.append(self.token_text(i))
        return "".join(out)

    def encode_prompt(self, ctx, prompt=None):
        names = {data.decode("ascii"): i for i, (kind, data) in enumerate(self.token_entries) if kind == 2}
        table, _ = d64ai.parse_tokenizer(self.pkg.tokenizer)
        ids = [self.h["tok_bos"]] + [names[n] for n in ctx]
        for c in prompt or "":
            code = ord(c) - 0x20 if "a" <= c <= "z" else ord(c)
            ids.append(table[code])
        return ids + [self.h["tok_sep"]]

    def reset(self):
        self.pos = 0
        self.kv = [[] for _ in range(self.n_layers)]   # per layer: list of (K8, ke[], V8, ve[])

    # ---- primitive operations (each mirrors one engine routine) ----
    def _track(self, name, values):
        m = max((abs(int(v)) for v in values), default=0)
        self.max_abs[name] = max(self.max_abs.get(name, 0), m)

    def row(self, kind, index, layer=d64ai.GLOBAL):
        """Dequantize one matrix row to Q16.16."""
        w, s = self.mats[(kind, layer)]
        return [round_shift(int(x) * int(s[index]), SCALE_BITS - Q16) for x in w[index]]

    def matvec(self, kind, x, layer=d64ai.GLOBAL):
        """int8 rows x int16 block-shifted input -> Q16.16 outputs."""
        packed, shift = pack(x, 15)
        w, s = self.mats[(kind, layer)]
        acc = w @ np.array(packed, dtype=np.int64)
        self._track("matvec_acc", acc)
        if np.abs(acc).max(initial=0) >= 1 << 31:
            raise OverflowError(f"{kind}: accumulator exceeds 32 bits")
        prod = acc * s
        if np.abs(prod).max(initial=0) >= ACC_LIMIT:
            raise OverflowError(f"{kind}: scaled product too wide")
        return [int(v) for v in round_shift_np(prod, SCALE_BITS - shift)]

    def norm(self, kind, x, layer=d64ai.GLOBAL):
        return rms_norm(x, self.gains[(kind, layer)], self.eps)

    def attention(self, layer, q):
        qp, qs = pack(q, 15)
        cache = self.kv[layer]
        out = []
        for h in range(self.n_heads):
            lo, hi = h * self.hd, (h + 1) * self.hd
            scores = []
            for k8, ke, _, _ in cache:
                dot = sum(a * b for a, b in zip(qp[lo:hi], k8[lo:hi]))
                scores.append(round_shift(dot, Q16 - qs - ke[h]))
            self._track("attn_score", scores)
            top = max(scores)
            weights = [exp_neg(top - s) for s in scores]
            total = sum(weights)
            coeff = [f << ve[h] for f, (_, _, _, ve) in zip(weights, cache)]
            cp, cs = pack(coeff, 15)
            for j in range(lo, hi):
                acc = sum(c * v8[j] for c, (_, _, v8, _) in zip(cp, cache))
                self._track("attn_acc", [acc])
                out.append(round_div(acc << cs, total))
        return out

    def kv_entry(self, k, v):
        k8, ke, v8, ve = [], [], [], []
        for h in range(self.n_heads):
            lo, hi = h * self.hd, (h + 1) * self.hd
            a, sa = pack(k[lo:hi], 7)
            b, sb = pack(v[lo:hi], 7)
            k8 += a
            v8 += b
            ke.append(sa)
            ve.append(sb)
        return k8, ke, v8, ve

    # ---- one token ----
    def step(self, token, want_logits=True, trace=None):
        if self.pos >= self.ctx_len:
            raise ContextFull()
        if not 0 <= token < self.vocab:
            raise ValueError(f"token {token} outside vocabulary")
        x = [a + b for a, b in zip(self.row("tok_emb", token), self.row("pos_emb", self.pos))]
        for layer in range(self.n_layers):
            n = self.norm("attn_norm", x, layer)
            q = self.matvec("wq", n, layer)
            k = self.matvec("wk", n, layer)
            v = self.matvec("wv", n, layer)
            self.kv[layer].append(self.kv_entry(k, v))
            a = self.attention(layer, q)
            o = self.matvec("wo", a, layer)
            x = [p + r for p, r in zip(x, o)]
            n2 = self.norm("ffn_norm", x, layer)
            hdn = [max(0, z) for z in self.matvec("w1", n2, layer)]
            f = self.matvec("w2", hdn, layer)
            x = [p + r for p, r in zip(x, f)]
            self._track("residual", x)
            if trace is not None:
                trace[layer] = dict(norm1=n, q=q, k=k, v=v, attn=a, o=o, norm2=n2, hidden=hdn,
                                    ffn=f, residual=list(x))
        self.pos += 1
        if not want_logits:
            return None
        logits = self.matvec("tok_emb", self.norm("final_norm", x))
        if trace is not None:
            trace["logits"] = logits
        return logits

    # ---- sampling ----
    def pick(self, logits, inv_temp_q8=0, top_k=1, rng_state=1):
        """Greedy when inv_temp_q8 == 0 or top_k <= 1. Returns (token, rng_state)."""
        ranked = sorted(self.allowed, key=lambda i: (-logits[i], i))
        if inv_temp_q8 == 0 or top_k <= 1:
            return ranked[0], rng_state
        cand = ranked[:top_k]
        top = logits[cand[0]]
        weights = [exp_neg(round_shift((top - logits[i]) * inv_temp_q8, 8)) for i in cand]
        value, rng_state = xorshift32(rng_state)
        target = ((value >> 8) * sum(weights)) >> 24
        cumulative = 0
        for i, w in zip(cand, weights):
            cumulative += w
            if cumulative > target:
                return i, rng_state
        return cand[-1], rng_state

    def generate(self, prompt_ids, max_chars=120, inv_temp_q8=0, top_k=1, seed=1):
        """Prefill (no logits except the last prompt token), then sample."""
        self.reset()
        logits = None
        for i, tok in enumerate(prompt_ids):
            logits = self.step(tok, want_logits=(i == len(prompt_ids) - 1))
        out, rng = [], seed or 1
        while len(out) < max_chars:
            tok, rng = self.pick(logits, inv_temp_q8, top_k, rng)
            out.append(tok)
            if tok == self.h["tok_eos"] or self.pos >= self.ctx_len:
                break
            logits = self.step(tok)
        return out


def load(path):
    return IntEngine(d64ai.read(Path(path).read_bytes()))


def main():
    import lexicon
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package")
    parser.add_argument("--ctx", nargs="+", default=["TASK:ROOM", "LOC:CRYPT", "ROOM:BURIAL_CHAMBER"])
    parser.add_argument("--prompt", default=None, help="typed text (use with TASK:FREE)")
    parser.add_argument("--temp", type=float, default=0.0)
    parser.add_argument("--top-k", type=int, default=8)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("-n", type=int, default=3, help="samples (when temp > 0)")
    parser.add_argument("--trace", type=Path, help="write per-token intermediate tensors (JSON) "
                        "for the greedy run: test vectors for the assembly engine")
    args = parser.parse_args()
    engine = load(args.package)
    ids = engine.encode_prompt(args.ctx, args.prompt)
    if args.trace:
        import json
        out = engine.generate(ids)
        engine.reset()
        steps = []
        for i, tok in enumerate(ids + out[:-1]):
            trace = {}
            engine.step(tok, want_logits=i >= len(ids) - 1, trace=trace)
            steps.append({"pos": i, "token": tok,
                          "layers": [trace[l] for l in range(engine.n_layers)],
                          "logits": trace.get("logits"),
                          "kv": [{"k8": e[0], "ke": e[1], "v8": e[2], "ve": e[3]}
                                 for e in (engine.kv[l][-1] for l in range(engine.n_layers))]})
        args.trace.write_text(json.dumps({"package": args.package, "prompt_ids": ids,
                                          "output_ids": out, "steps": steps}))
        print(f"trace of {len(steps)} tokens written to {args.trace}")
    inv = round(256 / args.temp) if args.temp > 0 else 0
    for i in range(args.n if inv else 1):
        out = engine.generate(ids, inv_temp_q8=inv, top_k=args.top_k, seed=args.seed + i)
        print(lexicon.display(engine.decode(out)))


if __name__ == "__main__":
    main()
