#!/usr/bin/env python3
"""Evaluate a checkpoint and its .d64ai package.

    python python/evaluate.py models/checkpoints/baseline/best.pt models/exported/baseline.d64ai

Reports (and writes <package>.eval.json):
  - float validation loss over the full validation split
  - teacher-forced top-1 agreement between float and integer models, and the
    integer model's loss, over --examples validation examples
  - exact greedy-response agreement float vs. integer on --responses prompts
  - largest integer magnitudes seen (for choosing 6502 accumulator widths)
  - sample greedy and top-k responses from the integer model
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

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lexicon  # noqa: E402
from model import DM64Model, ModelConfig, generate  # noqa: E402
from reference_int import load  # noqa: E402
from train import evaluate as float_eval, tokenize_file  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
ALLOWED = []                       # set from the checkpoint's lexicon in main()


def masked_argmax(logits):
    return max(ALLOWED, key=lambda i: (logits[i], -i))


def log_softmax_at(logits, target):
    vals = np.array([logits[i] for i in ALLOWED], dtype=np.float64)
    m = vals.max()
    return float(logits[target] - m - math.log(np.exp(vals - m).sum()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkpoint")
    parser.add_argument("package")
    parser.add_argument("--examples", type=int, default=100)
    parser.add_argument("--responses", type=int, default=30)
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()

    ck = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    lex = lexicon.load(ck.get("tokenizer", "char"))
    ALLOWED[:] = lex.text_ids + [lex.EOS]
    mcfg = ModelConfig(**ck["model_config"])
    model = DM64Model(mcfg)
    model.load_state_dict(ck["model"])
    model.eval()
    engine = load(args.package)

    val_path = ROOT / ck["config"]["data"]["val"]
    val_ids, val_np = tokenize_file(val_path, mcfg.ctx_len, lex)
    float_val = float_eval(model, val_ids, val_np, "cpu")
    examples = [json.loads(line) for line in val_path.open()]
    rng = random.Random(args.seed)
    chosen = rng.sample(examples, min(args.examples, len(examples)))

    t0 = time.time()
    agree = total = 0
    nll_float = nll_int = 0.0
    int_tokens = 0
    text_chars = 0
    for ex in chosen:
        ids, n_prompt = lex.encode_example(ex)
        text_chars += len(ex["text"]) + 1          # narration characters + end of text
        with torch.no_grad():
            flog = model(torch.tensor([ids[:-1]]))[0].double().numpy()
        engine.reset()
        for pos, tok in enumerate(ids[:-1]):
            need = pos >= n_prompt - 1
            ilog = engine.step(tok, want_logits=need)
            int_tokens += 1
            if not need:
                continue
            target = ids[pos + 1]
            il = [v / 65536 for v in ilog]
            agree += masked_argmax(il) == masked_argmax(flog[pos])
            total += 1
            nll_int -= log_softmax_at(il, target)
            nll_float -= log_softmax_at(flog[pos], target)
    tf_seconds = time.time() - t0

    response_match = 0
    samples = []
    for ex in chosen[:args.responses]:
        prompt = lex.encode_prompt(ex["ctx"], ex.get("prompt"))
        f_out = generate(model, prompt, max_new=mcfg.ctx_len - len(prompt), banned=lex.banned,
                         eos_id=lex.EOS)
        i_out = engine.generate(prompt, max_chars=mcfg.ctx_len - len(prompt))
        response_match += f_out == i_out
        k_out = engine.generate(prompt, max_chars=mcfg.ctx_len - len(prompt), inv_temp_q8=320,
                                top_k=8, seed=rng.randrange(1, 2**32))
        samples.append({"ctx": ex["ctx"], "prompt": ex.get("prompt"), "data": ex["text"],
                        "int_greedy": lex.decode(i_out),
                        "float_greedy": lex.decode(f_out),
                        "int_topk8_t0.8": lex.decode(k_out),
                        "int_greedy_tokens": len(i_out)})

    report = {
        "checkpoint": args.checkpoint, "package": args.package, "params": model.param_count(),
        "tokenizer": lex.name,
        "nats_per_char": {"float": round(nll_float / text_chars, 4), "int": round(nll_int / text_chars, 4)},
        "greedy_chars_per_token": round(sum(len(s["int_greedy"]) + 1 for s in samples)
                                        / max(1, sum(s["int_greedy_tokens"] for s in samples)), 2),
        "float_val_loss_full_split": round(float_val, 4),
        "teacher_forced": {"examples": len(chosen), "positions": total,
                           "top1_agreement": round(agree / total, 4),
                           "float_loss": round(nll_float / total, 4),
                           "int_loss": round(nll_int / total, 4),
                           "int_tokens_per_second_python": round(int_tokens / tf_seconds, 1)},
        "greedy_response_exact_match": f"{response_match}/{min(args.responses, len(chosen))}",
        "int_max_abs": {k: int(v) for k, v in engine.max_abs.items()},
        "int_max_bits": {k: int(v).bit_length() + 1 for k, v in engine.max_abs.items()},
        "samples": samples,
    }
    out = Path(args.package).with_suffix(".eval.json")
    out.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k != "samples"}, indent=1))
    for s in samples[:10]:
        ctx = " ".join(s["ctx"]) + (f' "{s["prompt"]}"' if s["prompt"] else "")
        print(f"\n{ctx}\n  int greedy : {lexicon.display(s['int_greedy'])}"
              f"\n  int top-k  : {lexicon.display(s['int_topk8_t0.8'])}")


if __name__ == "__main__":
    main()
