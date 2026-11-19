#!/usr/bin/env python3
"""Measure how well a model's narration fits the game: facts, variety, real words.

    python tools/fact_check.py models/checkpoints/baseline_bpe72_v2/best.pt
    python tools/fact_check.py models/exported/baseline_bpe72_v2.d64ai --int -n 4

Builds the context records the game sends (docs/GAME_DESIGN.md section 7: rooms,
monsters seen, kills, treasure, locked and unlocked doors, traps; a fixed random
sample) and generates with the game's settings: temperature 0.8, top-8, at most
48 tokens. The float checkpoint is fast; --int runs the bit-exact integer
reference (what the C64 computes) on a .d64ai package and is much slower.

Reports, per record kind and overall:
  fact_ok     no python/facts.py rule broken
  distinct    different answers / answers
  new         answers not found verbatim in the training text
  nonword     answers with a word that never occurs in the training text
              (the last word is ignored when the answer was cut)
  cut         answers stopped by the 48-token limit instead of ending
Writes the full report as JSON with --out.
"""
import argparse
import json
import random
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "python")]
import facts  # noqa: E402
import lexicon  # noqa: E402
import vocab  # noqa: E402

G = vocab.CONTROL_GROUPS
TEMP, TOP_K, MAX_TOKENS = 0.8, 8, 48
INV_TEMP_Q8 = 320                      # the game's setting (256 / 0.8)


def game_records(rng, per_kind):
    """Context records shaped like the game's (rules.asm, GAME_DESIGN section 7)."""
    kinds = {
        "room": lambda: ["TASK:ROOM", f"LOC:{rng.choice(G['LOC'])}", f"ROOM:{rng.choice(G['ROOM'])}"]
        + ([f"MON:{rng.choice(G['MON'])}"] if rng.random() < 0.5 else []),
        "monster": lambda: ["TASK:MONSTER", f"LOC:{rng.choice(G['LOC'])}", f"MON:{rng.choice(G['MON'])}",
                            "MST:HEALTHY"],
        "kill": lambda: ["TASK:COMBAT", f"MON:{rng.choice(G['MON'])}", "MST:DEAD", "ACT:ATTACK",
                         "OUT:KILLED", f"HP:{rng.choice(G['HP'])}"],
        "treasure": lambda: ["TASK:TREASURE", f"ITEM:{rng.choice(G['ITEM'])}", "OUT:FOUND"],
        "locked": lambda: ["TASK:ACTION", "OBJ:DOOR", "ACT:OPEN", "OUT:LOCKED"],
        "unlock": lambda: ["TASK:ACTION", "OBJ:DOOR", "ITEM:KEY", "ACT:USE", "OUT:SUCCESS"],
        "trap": lambda: ["TASK:ACTION", "ACT:SEARCH", "OUT:TRAP"],
    }
    return [(kind, make()) for kind, make in kinds.items() for _ in range(per_kind)]


def training_text(paths):
    texts = set()
    for p in paths:
        with open(p) as f:
            texts.update(json.loads(line)["text"] for line in f)
    known = set()
    for t in texts:
        known.update(facts.words(t))
    return texts, known


def float_generator(path, seed):
    import torch
    from model import DM64Model, ModelConfig, generate
    ck = torch.load(path, map_location="cpu", weights_only=False)
    model = DM64Model(ModelConfig(**ck["model_config"]))
    model.load_state_dict(ck["model"])
    model.eval()
    lex = lexicon.load(ck.get("tokenizer", "char"))
    g = torch.Generator().manual_seed(seed)

    def run(ctx, i):
        p = lex.encode_prompt(ctx)
        out = generate(model, p, max_new=MAX_TOKENS, temperature=TEMP, top_k=TOP_K,
                       banned=lex.banned, eos_id=lex.EOS, generator=g)
        return lex.decode(out), out[-1:] != [lex.EOS]
    return run


def int_generator(path, seed):
    from reference_int import load
    engine = load(path)

    def run(ctx, i):
        ids = engine.encode_prompt(ctx)
        out = engine.generate(ids, max_chars=MAX_TOKENS, inv_temp_q8=INV_TEMP_Q8, top_k=TOP_K,
                              seed=(seed * 7919 + i) & 0xFFFFFFFF or 1)
        return engine.decode(out).lower(), out[-1:] != [engine.h["tok_eos"]]
    return run


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("model", help="checkpoint .pt (float) or .d64ai package (with --int)")
    ap.add_argument("--int", action="store_true", help="use the bit-exact integer reference")
    ap.add_argument("-n", type=int, default=40, help="records per kind (default 40)")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--train", nargs="+", default=["datasets/training/train_v2.jsonl"],
                    help="training text for the new/nonword counts")
    ap.add_argument("--out", type=Path)
    args = ap.parse_args()

    texts, known = training_text([ROOT / p for p in args.train])
    run = (int_generator if args.int else float_generator)(args.model, args.seed)
    records = game_records(random.Random(args.seed), args.n)
    per = defaultdict(lambda: {"n": 0, "fact_ok": 0, "new": 0, "nonword": 0, "cut": 0, "answers": set(),
                               "rules": Counter()})
    examples = defaultdict(list)
    for i, (kind, ctx) in enumerate(records):
        text, cut = run(ctx, i)
        broken = facts.check(ctx, text)
        r = per[kind]
        r["n"] += 1
        r["fact_ok"] += not broken
        r["rules"].update(broken)
        r["new"] += text not in texts
        ws = facts.words(text)[:-1] if cut else facts.words(text)
        r["nonword"] += any(w not in known for w in ws)
        r["cut"] += cut
        r["answers"].add(text)
        if broken and len(examples[kind]) < 3:
            examples[kind].append({"ctx": " ".join(ctx), "text": text, "broken": broken})

    total = Counter()
    report = {"model": args.model, "int": args.int, "per_kind": {}, "failures": dict(examples)}
    print(f"{'kind':9} {'fact_ok':>9} {'distinct':>9} {'new':>9} {'nonword':>9} {'cut':>9}  broken rules")
    for kind, r in per.items():
        row = {"n": r["n"], "fact_ok": r["fact_ok"], "distinct": len(r["answers"]), "new": r["new"],
               "nonword": r["nonword"], "cut": r["cut"], "rules": dict(r["rules"])}
        report["per_kind"][kind] = row
        total.update({k: row[k] for k in ("n", "fact_ok", "distinct", "new", "nonword", "cut")})
        n = r["n"]
        print(f"{kind:9} {r['fact_ok']:>4}/{n:<4} {len(r['answers']):>4}/{n:<4} {r['new']:>4}/{n:<4} "
              f"{r['nonword']:>4}/{n:<4} {r['cut']:>4}/{n:<4}  {dict(r['rules']) or ''}")
    n = total["n"]
    report["total"] = dict(total)
    print(f"{'all':9} {total['fact_ok']:>4}/{n:<4} {total['distinct']:>4}/{n:<4} {total['new']:>4}/{n:<4} "
          f"{total['nonword']:>4}/{n:<4} {total['cut']:>4}/{n:<4}")
    for kind, ex in examples.items():
        for e in ex:
            print(f"  [{kind}] {e['ctx']}\n      {e['text']!r} -> {e['broken']}")
    if args.out:
        args.out.write_text(json.dumps(report, indent=1) + "\n")


if __name__ == "__main__":
    main()
