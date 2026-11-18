"""DM64 decoder v1 (arch_id 1) in PyTorch: the float reference model.

Matches docs/ARCHITECTURE.md and docs/MODEL_FORMAT.md:
  - learned token and absolute position embeddings
  - pre-RMSNorm blocks: multi-head causal attention, ReLU feed-forward
  - no biases anywhere
  - final RMSNorm; output head tied to the token embedding
"""
from dataclasses import dataclass, asdict

import torch
import torch.nn as nn
import torch.nn.functional as F

ARCH_ID = 1


@dataclass
class ModelConfig:
    vocab_size: int
    ctx_len: int = 128
    d_model: int = 64
    n_layers: int = 4
    n_heads: int = 4
    d_ff: int = 256
    rms_eps: float = 1e-5
    dropout: float = 0.0

    @property
    def head_dim(self):
        return self.d_model // self.n_heads

    def validate(self):
        """Limits of the v1 engine (docs/ARCHITECTURE.md section 3.4)."""
        problems = []
        if self.d_model % self.n_heads:
            problems.append("d_model must be divisible by n_heads")
        if not (1 <= self.n_layers <= 8):
            problems.append("n_layers must be 1..8")
        if not (1 <= self.n_heads <= 8):
            problems.append("n_heads must be 1..8")
        if self.d_model > 128:
            problems.append("d_model must be <= 128")
        if self.d_ff > 512:
            problems.append("d_ff must be <= 512")
        if self.vocab_size > 256:
            problems.append("vocab_size must be <= 256")
        if self.ctx_len > 256:
            problems.append("ctx_len must be <= 256")
        if problems:
            raise ValueError("; ".join(problems))
        return self

    def to_dict(self):
        return asdict(self)


class RMSNorm(nn.Module):
    def __init__(self, d, eps):
        super().__init__()
        self.eps = eps
        self.weight = nn.Parameter(torch.ones(d))

    def forward(self, x):
        return x * torch.rsqrt(x.pow(2).mean(-1, keepdim=True) + self.eps) * self.weight


class Block(nn.Module):
    def __init__(self, cfg):
        super().__init__()
        d = cfg.d_model
        self.cfg = cfg
        self.attn_norm = RMSNorm(d, cfg.rms_eps)
        self.wq = nn.Linear(d, d, bias=False)
        self.wk = nn.Linear(d, d, bias=False)
        self.wv = nn.Linear(d, d, bias=False)
        self.wo = nn.Linear(d, d, bias=False)
        self.ffn_norm = RMSNorm(d, cfg.rms_eps)
        self.w1 = nn.Linear(d, cfg.d_ff, bias=False)
        self.w2 = nn.Linear(cfg.d_ff, d, bias=False)
        self.drop = nn.Dropout(cfg.dropout)

    def forward(self, x):
        b, t, d = x.shape
        h, hd = self.cfg.n_heads, self.cfg.head_dim
        n = self.attn_norm(x)
        q = self.wq(n).view(b, t, h, hd).transpose(1, 2)
        k = self.wk(n).view(b, t, h, hd).transpose(1, 2)
        v = self.wv(n).view(b, t, h, hd).transpose(1, 2)
        a = F.scaled_dot_product_attention(q, k, v, is_causal=True,
                                           dropout_p=self.cfg.dropout if self.training else 0.0)
        x = x + self.drop(self.wo(a.transpose(1, 2).reshape(b, t, d)))
        x = x + self.drop(self.w2(F.relu(self.w1(self.ffn_norm(x)))))
        return x


class DM64Model(nn.Module):
    def __init__(self, cfg):
        super().__init__()
        self.cfg = cfg.validate()
        self.tok_emb = nn.Embedding(cfg.vocab_size, cfg.d_model)
        self.pos_emb = nn.Embedding(cfg.ctx_len, cfg.d_model)
        self.blocks = nn.ModuleList(Block(cfg) for _ in range(cfg.n_layers))
        self.final_norm = RMSNorm(cfg.d_model, cfg.rms_eps)
        self.apply(self._init)

    @staticmethod
    def _init(m):
        if isinstance(m, (nn.Linear, nn.Embedding)):
            nn.init.normal_(m.weight, mean=0.0, std=0.02)

    def forward(self, ids):
        t = ids.shape[1]
        if t > self.cfg.ctx_len:
            raise ValueError(f"sequence length {t} exceeds ctx_len {self.cfg.ctx_len}")
        x = self.tok_emb(ids) + self.pos_emb(torch.arange(t, device=ids.device))
        for block in self.blocks:
            x = block(x)
        return self.final_norm(x) @ self.tok_emb.weight.T

    def param_count(self):
        return sum(p.numel() for p in self.parameters())


@torch.no_grad()
def generate(model, prompt_ids, max_new=120, temperature=0.0, top_k=0, eos_id=2,
             banned=(), generator=None):
    """Float reference generation. Returns the new token ids (stops at EOS)."""
    model.eval()
    device = next(model.parameters()).device
    ids = list(prompt_ids)
    out = []
    while len(out) < max_new and len(ids) < model.cfg.ctx_len:
        logits = model(torch.tensor([ids], device=device))[0, -1].float()
        if banned:
            logits[list(banned)] = float("-inf")
        if temperature <= 0:
            nxt = int(torch.argmax(logits))
        else:
            logits = logits / temperature
            if top_k:
                kth = torch.topk(logits, top_k).values[-1]
                logits[logits < kth] = float("-inf")
            nxt = int(torch.multinomial(torch.softmax(logits, -1), 1, generator=generator))
        ids.append(nxt)
        out.append(nxt)
        if nxt == eos_id:
            break
    return out
