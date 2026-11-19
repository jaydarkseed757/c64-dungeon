#!/usr/bin/env python3
"""Train a DM64 model.

    python python/train.py --config configs/baseline.yaml [--resume] [--steps N]

Config keys beyond model/data/train: tokenizer, device, init_from (start from
another checkpoint's weights, e.g. for quantization-aware fine-tuning with
model.qat: true).

Writes models/checkpoints/<name>/{latest.pt,best.pt,log.jsonl,samples.txt}.
Seeds Python, NumPy and torch. Bit-exact repeatability is only expected on CPU;
MPS kernels are not guaranteed deterministic.
"""
import argparse
import json
import math
import random
import sys
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lexicon  # noqa: E402
import vocab  # noqa: E402
from model import DM64Model, ModelConfig, generate  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
LEX = lexicon.load("char")          # replaced in main() by the config's tokenizer
BANNED = LEX.banned


def load_config(path):
    cfg = yaml.safe_load(Path(path).read_text())
    lex = lexicon.load(cfg.get("tokenizer", "char"))
    cfg["model"]["vocab_size"] = lex.VOCAB_SIZE
    return cfg


def tokenize_file(path, ctx_len, lex=None):
    """jsonl -> (ids uint8 [N, ctx_len], n_prompt uint8 [N]). Cached as .npz."""
    lex = lex or LEX
    path = Path(path)
    suffix = "" if lex.name == "char" else f".{lex.name}"
    cache = path.with_suffix(f"{suffix}.ctx{ctx_len}.npz")
    if cache.exists() and cache.stat().st_mtime > path.stat().st_mtime:
        data = np.load(cache)
        return data["ids"], data["n_prompt"]
    rows, prompts = [], []
    with path.open() as f:
        for line in f:
            ids, n_prompt = lex.encode_example(json.loads(line))
            if len(ids) > ctx_len:
                raise ValueError(f"example longer than ctx_len {ctx_len}: {line.strip()}")
            rows.append(ids + [lex.PAD] * (ctx_len - len(ids)))
            prompts.append(n_prompt)
    ids, n_prompt = np.array(rows, dtype=np.uint8), np.array(prompts, dtype=np.uint8)
    np.savez_compressed(cache, ids=ids, n_prompt=n_prompt)
    return ids, n_prompt


def batch_loss(model, ids, n_prompt):
    """Cross-entropy on continuation positions only (text + EOS after SEP)."""
    inputs, targets = ids[:, :-1], ids[:, 1:]
    logits = model(inputs)
    pos = torch.arange(targets.shape[1], device=ids.device)[None, :] + 1
    mask = (pos >= n_prompt[:, None]) & (targets != vocab.PAD)
    loss = F.cross_entropy(logits.reshape(-1, logits.shape[-1]).float(), targets.reshape(-1),
                           reduction="none").view_as(targets)
    return (loss * mask).sum() / mask.sum(), mask.sum()


@torch.no_grad()
def evaluate(model, ids, n_prompt, device, batch=256):
    model.eval()
    total, count = 0.0, 0
    for i in range(0, len(ids), batch):
        x = torch.from_numpy(ids[i:i + batch].astype(np.int64)).to(device)
        p = torch.from_numpy(n_prompt[i:i + batch].astype(np.int64)).to(device)
        loss, n = batch_loss(model, x, p)
        total += float(loss) * int(n)
        count += int(n)
    model.train()
    return total / count


def sample_report(model, examples, device):
    lines = []
    for ex in examples:
        prompt = LEX.encode_prompt(ex["ctx"], ex.get("prompt"))
        out = generate(model, prompt, max_new=128 - len(prompt), banned=LEX.banned, eos_id=LEX.EOS)
        ctx = " ".join(ex["ctx"]) + (f' "{ex["prompt"]}"' if "prompt" in ex else "")
        lines.append(f"{ctx}\n  model: {LEX.decode(out)}\n  data:  {ex['text']}")
    return "\n".join(lines)


def lr_at(step, cfg):
    t = cfg["train"]
    if step < t["warmup"]:
        return t["lr"] * (step + 1) / t["warmup"]
    progress = (step - t["warmup"]) / max(1, t["steps"] - t["warmup"])
    return t["min_lr"] + 0.5 * (t["lr"] - t["min_lr"]) * (1 + math.cos(math.pi * min(1.0, progress)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--steps", type=int, help="override train.steps")
    parser.add_argument("--device", default=None)
    parser.add_argument("--out-dir", default=None, help="default models/checkpoints/<name>")
    args = parser.parse_args()

    global LEX, BANNED
    cfg = load_config(args.config)
    LEX = lexicon.load(cfg.get("tokenizer", "char"))
    BANNED = LEX.banned
    if args.steps:
        cfg["train"]["steps"] = args.steps
    t = cfg["train"]
    name = cfg["name"]
    out_dir = Path(args.out_dir) if args.out_dir else ROOT / "models/checkpoints" / name
    out_dir.mkdir(parents=True, exist_ok=True)

    seed = t["seed"]
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    device = args.device or cfg.get("device") or ("mps" if torch.backends.mps.is_available() else "cpu")

    mcfg = ModelConfig(**cfg["model"])
    model = DM64Model(mcfg).to(device)
    opt = torch.optim.AdamW(model.parameters(), lr=t["lr"], betas=(0.9, 0.95),
                            weight_decay=t["weight_decay"])

    train_ids, train_np = tokenize_file(ROOT / cfg["data"]["train"], mcfg.ctx_len)
    val_ids, val_np = tokenize_file(ROOT / cfg["data"]["val"], mcfg.ctx_len)
    with (ROOT / cfg["data"]["val"]).open() as f:
        val_examples = [json.loads(line) for line in f]
    sample_rng = random.Random(seed)
    samples = sample_rng.sample(val_examples, min(12, len(val_examples)))

    step, best = 0, float("inf")
    data_rng = np.random.default_rng(seed)
    if cfg.get("init_from") and not (args.resume and (out_dir / "latest.pt").exists()):
        # fine-tune (e.g. quantization-aware) from another checkpoint's weights
        init = torch.load(ROOT / cfg["init_from"], map_location=device, weights_only=False)
        model.load_state_dict(init["model"])
        print(f"initialized from {cfg['init_from']} (its val {init.get('val_loss', float('nan')):.4f})")
    if args.resume and (out_dir / "latest.pt").exists():
        ck = torch.load(out_dir / "latest.pt", map_location=device, weights_only=False)
        model.load_state_dict(ck["model"])
        opt.load_state_dict(ck["optimizer"])
        step, best = ck["step"], ck["best_val"]
        data_rng.bit_generator.state = ck["data_rng"]
        print(f"resumed at step {step}, best val {best:.4f}")

    print(f"{name}: {model.param_count():,} params, device {device}, "
          f"train {len(train_ids):,} / val {len(val_ids):,} sequences")
    log = (out_dir / "log.jsonl").open("a")

    def save(path, val_loss):
        torch.save({"model": model.state_dict(), "optimizer": opt.state_dict(), "step": step,
                    "best_val": best, "val_loss": val_loss, "config": cfg,
                    "model_config": mcfg.to_dict(), "vocab_size": LEX.VOCAB_SIZE,
                    "vocab": LEX.TOKENS, "tokenizer": LEX.name,
                    "data_rng": data_rng.bit_generator.state}, path)

    model.train()
    t0 = time.time()
    while step < t["steps"]:
        idx = data_rng.integers(0, len(train_ids), t["batch"])
        x = torch.from_numpy(train_ids[idx].astype(np.int64)).to(device)
        p = torch.from_numpy(train_np[idx].astype(np.int64)).to(device)
        for group in opt.param_groups:
            group["lr"] = lr_at(step, cfg)
        loss, _ = batch_loss(model, x, p)
        opt.zero_grad(set_to_none=True)
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), t["grad_clip"])
        opt.step()
        step += 1
        if step % t["log_every"] == 0:
            print(f"step {step:6d}  loss {loss.item():.4f}  lr {lr_at(step, cfg):.2e}  "
                  f"{(time.time() - t0) / t['log_every'] * 1000:.0f} ms/step", flush=True)
            t0 = time.time()
        if step % t["eval_every"] == 0 or step == t["steps"]:
            val_loss = evaluate(model, val_ids, val_np, device)
            improved = val_loss < best
            best = min(best, val_loss)
            print(f"step {step:6d}  val {val_loss:.4f}{'  *best*' if improved else ''}", flush=True)
            log.write(json.dumps({"step": step, "train_loss": loss.item(), "val_loss": val_loss,
                                  "lr": lr_at(step, cfg)}) + "\n")
            log.flush()
            save(out_dir / "latest.pt", val_loss)
            if improved:
                save(out_dir / "best.pt", val_loss)
            report = sample_report(model, samples, device)
            (out_dir / "samples.txt").write_text(f"step {step}, val {val_loss:.4f}\n\n{report}\n")
            model.train()
    print(f"done. best val {best:.4f}. checkpoints in {out_dir}")


if __name__ == "__main__":
    main()
