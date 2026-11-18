# Integer Inference Contract (engine v1, arch 1)

Status: Milestone 2, 2026-11-16. This is the normative arithmetic for the 6502 engine. `python/reference_int.py` and `python/fixedpoint.py` implement it, and the ACME engine must reproduce their integers **exactly**. If prose and code disagree, the code is authoritative, and the disagreement is a documentation bug to fix.

## 1. Number formats

| Name | Width | Meaning |
| --- | --- | --- |
| Q16.16 | signed 32-bit | residual stream, norm outputs, q/k/v, attention outputs, FFN values, logits |
| int16 packed | signed, magnitude ≤ 32767, plus a shared shift `s` | inputs to every dot product; value ≈ `p << s` in Q16.16 units |
| int8 packed | signed, magnitude ≤ 127, plus a per-head shift | K and V cache entries |
| Q0.24 | unsigned 24-bit | matrix row scales; softmax weights (≤ 2²⁴) |
| Q4.12 | signed 16-bit | RMSNorm gains |
| Q0.32 | unsigned 32-bit | RMS ε (`rms_eps_q32` header field) |

## 2. Rounding primitives

- `round_div(n, d)`, with d > 0: nearest integer, **ties away from zero**. That is `sign(n) · ⌊(|n| + ⌊d/2⌋) / d⌋`.
- `round_shift(n, s)`: `round_div(n, 2^s)` for s > 0. `n << −s` for s ≤ 0.
- `pack(v, bits)`:
  - peak = max |vᵢ|. A zero vector gives shift 0 and all zeros.
  - shift = max(0, bitlen(peak) − bits).
  - If `round_shift(peak, shift) > 2^bits − 1`, add 1 to the shift.
  - Each element is `round_shift(vᵢ, shift)`.

## 3. Operations

**Embedding row** (tensor T, row r, int8 weights w, scale S):

```
x[j] = round_shift(w[j] · S, 8)
```

The token and position rows are each computed this way, then added.

**RMSNorm** (x in Q16.16, gains g in Q4.12, length d):

```
energy = Σ x[j]²
ms     = round_div(energy, d) + rms_eps_q32
root   = isqrt(ms << 16)                 (floor square root; rms with 8 guard bits)
out[j] = round_div((x[j] · g[j]) << 12, root)
```

**Matvec** (int8 rows w, scales S, input x in Q16.16):

```
(p, s)  = pack(x, 15)
acc[r]  = Σ_j w[r][j] · p[j]             (must fit signed 32-bit; checked in the reference)
y[r]    = round_shift(acc[r] · S[r], 24 − s)
```

**KV append**, per head h, slice [h·hd, (h+1)·hd):

```
(K8, ke[h]) = pack(k_slice, 7)
(V8, ve[h]) = pack(v_slice, 7)
```

**Attention**, per head h, over cached positions t = 0..pos (Wq already includes 1/√hd):

```
(qp, qs) = pack(q, 15)                         (whole q vector, one shift)
dot[t]   = Σ_{j in head} qp[j] · K8[t][j]
score[t] = round_shift(dot[t], 16 − qs − ke[t][h])
m        = max score;   f[t] = exp_neg(m − score[t]);   F = Σ f[t]
c[t]     = f[t] << ve[t][h]
(cp, cs) = pack(c, 15)
acc[j]   = Σ_t cp[t] · V8[t][j]
out[j]   = round_div(acc[j] << cs, F)
```

**exp_neg(δ)**, δ ≥ 0 in Q16.16, giving Q0.24:

- Table: E[i] = min(2²⁴ − 1, round(2²⁴ · e^(−i/64))) for i = 0..1024 (3,075 bytes as 3-byte entries).
- The cap (Milestone 3) keeps E[0] in three bytes. It changed no reported metric at the precision shown.
- If δ ≥ 16.0 (1,048,576), the result is 0.
- Otherwise:

  ```
  i = δ >> 10
  frac = δ & 1023
  result = E[i] + round_div((E[i+1] − E[i]) · frac, 1024)
  ```

**ReLU:** `max(0, v)`.

**Block:**

```
n  = RMSNorm(x, attn_g)
q,k,v = matvec(Wq|Wk|Wv, n)
KV append
a  = attention(q)
x += matvec(Wo, a)
n2 = RMSNorm(x, ffn_g)
x += matvec(W2, ReLU(matvec(W1, n2)))
```

**Logits** (only for the last prompt token and for generated tokens):

```
matvec(tok_emb, RMSNorm(x, final_g))
```

## 4. Sampling

- **Emittable ids:** text tokens (tokenizer kind 1, id < `first_control_id`) and EOS. Every other id is masked.
- **Greedy:** the highest logit among emittable ids. Ties go to the lowest id.
- **Top-k with temperature:**
  - `inv_temp_q8` = round(256 / T), for example 320 for T = 0.8.
  - Candidates are the top k emittable ids by (logit descending, id ascending).
  - `w_i = exp_neg(round_shift((l_top − l_i) · inv_temp_q8, 8))`.
  - `r = xorshift32(state)` (shifts 13, 17, 5; the state must be non-zero).
  - `target = ((r >> 8) · Σw) >> 24`.
  - Return the first candidate whose cumulative weight is greater than `target`.
- Generation stops at EOS, at the character limit, or when the context is full.

## 5. Bounds observed on the baseline model

The evaluation tool records the largest integer magnitude at each accumulator. See `models/exported/<name>.eval.json`, key `int_max_bits`. These measurements decide the 6502 accumulator widths. All v1 dot-product accumulators fit signed 32 bits by construction:

- matvec: 512 × 127 × 32767 < 2³¹
- attention dot: head_dim ≤ 128, so 128 × 127 × 32767 < 2³¹
- attention value sum: 256 × 32767 × 127 < 2³¹

The reference raises an error if any is exceeded. Wider intermediate products (`acc · S`, up to 55 bits; `acc << cs`) are computed in multi-byte arithmetic on the 6502.

## 6. Differences from the float model

- int8 weights with per-row scales; int16 block-shifted activations; int8 power-of-two-scaled K/V per head; table exp.
- The measured effect on the bring-up and baseline models is reported in `docs/MODEL_PIPELINE.md`.
- Exact float-vs-integer response matches are not expected. One diverging character changes the rest of the sentence. The meaningful metrics are teacher-forced top-1 agreement and the integer model's loss.

## 7. Engine-relevant consequences

- Wq rows are pre-scaled by 1/√head_dim during conversion (header flag bit 3), so attention has no scale multiply.
- K/V use per-head power-of-two exponents, so a score costs one shift and no multiply by a stored peak. This differs from Tiny21, which stores a peak per vector.
- Prefill tokens skip the final norm and the logits matvec.
- The engine owns the exp table and the quarter-square tables. They are not stored in the model package.
