#!/usr/bin/env python3
"""Generate the DM64 narration dataset from datasets/raw/phrasebank.yaml.

Each example pairs structured game context (control-token names) with a short
narration consistent with that context. Output (JSON lines):

    datasets/processed/dm64_v1_all.jsonl     every unique example (de-duplicated)
    datasets/training/train.jsonl            training split
    datasets/validation/val.jsonl            validation split
    datasets/processed/dm64_v1_stats.json    counts, lengths, coverage, hashes

--extra FILE merges more phrases onto the bank (lists are appended, act_* outcomes
extended, task_weights replaces the task mix). --tag v2 writes dm64_v2_*.jsonl,
train_v2.jsonl and val_v2.jsonl instead, so the v1 files stay untouched.

Deterministic for a given --seed and phrase bank(s).
"""
import argparse
import hashlib
import json
import random
import re
import sys
from collections import Counter
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))
import vocab  # noqa: E402

ALLOWED = set(vocab.TEXT_CHARS)
PLACEHOLDER = re.compile(r"\{([A-Za-z0-9_]+)\}")
G = vocab.CONTROL_GROUPS

# Context slot -> (rule prefix, context key holding the value).
BINDINGS = {
    "LOC": ("loc", "LOC"), "LOCNAME": ("locname", "LOC"), "MON": ("mon", "MON"),
    "MONSHORT": ("monshort", "MON"), "MST": ("mst", "MST"), "OBJ": ("obj", "OBJ"),
    "OBJ2": ("obj", "OBJ2"), "ITEM": ("item", "ITEM"), "ITEMFLAIR": ("itemflair", "ITEM"),
    "NPC": ("npc", "NPC"),
}
CONTAINERS = ["CHEST", "SARCOPHAGUS", "ALTAR", "BOOKSHELF", "BONES", "FOUNTAIN", "STATUE"]
OUTCOME_KEY = {"SUCCESS": "success", "FAIL": "fail", "LOCKED": "locked", "EMPTY": "empty",
               "TRAP": "trap", "FOUND": "found", "NOTHING": "nothing"}
NEEDS_OBJ = {"EXAMINE", "OPEN", "PUSH", "PULL", "USE"}
NEEDS_ITEM = {"TAKE", "USE"}


class Grammar:
    def __init__(self, bank, rng):
        self.bank = bank
        self.rng = rng
        self.acts = {}
        for key, value in bank.items():
            if key.startswith("act_"):
                merged = {}
                for entry in value:
                    merged.update(entry)
                self.acts[key[4:].upper()] = merged

    def expand(self, text, ctx, depth=0):
        if depth > 8:
            raise ValueError(f"rule recursion too deep near: {text}")

        def repl(match):
            name = match.group(1)
            if name in BINDINGS:
                prefix, key = BINDINGS[name]
                if key not in ctx:
                    raise KeyError(f"template needs {key}: {text}")
                rule = f"{prefix}_{ctx[key].lower()}"
            else:
                rule = name
            if rule not in self.bank:
                raise KeyError(f"unknown rule {rule}")
            return self.expand(self.rng.choice(self.bank[rule]), ctx, depth + 1)

        return PLACEHOLDER.sub(repl, text)

    def pick(self, rule, ctx):
        return self.expand(self.rng.choice(self.bank[rule]), ctx)


ARTICLE = re.compile(r"\ba (?=[aeiou])")


def fix_articles(text):
    """Grammar expansion can produce 'a old'; English wants 'an old'."""
    return ARTICLE.sub("an ", text)


def lint_bank(bank):
    """Catch YAML flow lists that split a sentence at a comma."""
    problems = []
    for key, value in bank.items():
        if isinstance(value, list) and value and all(isinstance(v, str) for v in value):
            ends = [v.endswith((".", "!", "?", '"')) for v in value]
            if any(ends) and not all(ends):
                problems.append(f"{key}: {value}")
    if problems:
        raise ValueError("phrase bank lists mix sentences and fragments "
                         "(quote items containing commas):\n" + "\n".join(problems))


def merge_bank(bank, extra):
    """Append the extra file's alternatives to the bank (returns a new dict)."""
    out = {k: (list(v) if isinstance(v, list) else v) for k, v in bank.items()}
    for key, value in extra.items():
        if key == "task_weights":
            out[key] = dict(value)
        elif key.startswith("act_"):
            outcomes = {}
            for entry in out.get(key, []) + value:
                for outcome, lines in entry.items():
                    outcomes.setdefault(outcome, []).extend(lines)
            out[key] = [outcomes]
        else:
            out[key] = out.get(key, []) + list(value)
    return out


def maybe(rng, p):
    return rng.random() < p


def gen_room(g, rng):
    ctx = {"LOC": rng.choice(G["LOC"]), "ROOM": rng.choice(G["ROOM"])}
    text = g.pick(f"room_{ctx['ROOM'].lower()}", ctx)
    extra = rng.random()
    if extra < 0.25:
        ctx["OBJ"] = rng.choice(G["OBJ"])
        if maybe(rng, 0.3):
            ctx["OBJ2"] = rng.choice([o for o in G["OBJ"] if o != ctx["OBJ"]])
            text += " " + g.pick("see_obj2", ctx)
        else:
            text += " " + g.pick("see_obj", ctx)
    elif extra < 0.45:
        ctx["MON"] = rng.choice(G["MON"])
        text += " " + g.pick("see_mon", ctx)
    elif extra < 0.6:
        ctx["ENV"] = rng.choice(G["ENV"])
        text += " " + g.pick(f"env_{ctx['ENV'].lower()}", ctx)
    return ctx, text


def gen_monster(g, rng):
    ctx = {"MON": rng.choice(G["MON"]), "MST": rng.choice(["HEALTHY", "HEALTHY", "WOUNDED", "DYING"])}
    if maybe(rng, 0.4):
        ctx["LOC"] = rng.choice(G["LOC"])
    text = g.pick(f"mondesc_{ctx['MON'].lower()}", ctx)
    if ctx["MST"] != "HEALTHY" or maybe(rng, 0.5):
        text += " " + g.pick(f"mst_{ctx['MST'].lower()}", ctx)
    return ctx, text


def gen_treasure(g, rng):
    ctx = {"ITEM": rng.choice(G["ITEM"])}
    out = rng.choice(["FOUND", "FOUND", "FOUND", "EMPTY", "TRAP"])
    if out != "FOUND" or maybe(rng, 0.6):
        ctx["OBJ"] = rng.choice(CONTAINERS)
    if out != "FOUND":
        del ctx["ITEM"]
    ctx["OUT"] = out
    if out == "FOUND":
        rule = "treasure_found" if "OBJ" in ctx else "treasure_found_noobj"
    else:
        rule = f"treasure_{out.lower()}"
    return ctx, g.pick(rule, ctx)


def gen_npc(g, rng):
    ctx = {"NPC": rng.choice(G["NPC"]), "MOOD": rng.choice(G["MOOD"])}
    if maybe(rng, 0.3):
        ctx["LOC"] = rng.choice(G["LOC"])
    return ctx, g.pick("npcintro", ctx) + " " + g.pick(f"npcsay_{ctx['MOOD'].lower()}", ctx)


def gen_quest(g, rng):
    ctx = {"NPC": rng.choice(G["NPC"]), "QUEST": rng.choice(G["QUEST"])}
    text = g.pick(f"quest_{ctx['QUEST'].lower()}", ctx)
    if maybe(rng, 0.4):
        ctx["MON"] = rng.choice(G["MON"])
        text += " " + g.pick("questmon", ctx)
    return ctx, text


def gen_event(g, rng):
    ctx = {"ENV": rng.choice(G["ENV"])}
    if maybe(rng, 0.5):
        ctx["LOC"] = rng.choice(G["LOC"])
    text = g.pick(f"env_{ctx['ENV'].lower()}", ctx)
    if maybe(rng, 0.3):
        text += " " + g.pick("sound", ctx) + "."
    return ctx, text


def gen_combat(g, rng):
    ctx = {"MON": rng.choice(G["MON"]), "HP": rng.choice(G["HP"])}
    if maybe(rng, 0.8):
        ctx["ACT"] = "ATTACK"
        out = rng.choice(["HIT", "HIT", "CRIT", "MISS", "KILLED", "HURT"])
        ctx["OUT"] = out
        if out in ("HIT", "CRIT"):
            ctx["MST"] = rng.choice(["HEALTHY", "WOUNDED", "DYING"])
        elif out == "KILLED":
            ctx["MST"] = "DEAD"
        rule = f"combat_hurt_{ctx['HP'].lower()}" if out == "HURT" else f"combat_{out.lower()}"
    else:
        ctx["ACT"] = "FLEE"
        ctx["OUT"] = rng.choice(["SUCCESS", "FAIL"])
        rule = f"combat_flee_{ctx['OUT'].lower()}"
    return ctx, g.pick(rule, ctx)


def gen_action(g, rng):
    act = rng.choice(sorted(g.acts))
    outcomes = g.acts[act]
    out = rng.choice(sorted(OUTCOME_KEY, key=str))
    while OUTCOME_KEY[out] not in outcomes:
        out = rng.choice(list(OUTCOME_KEY))
    ctx = {"ACT": act, "OUT": out}
    if act in NEEDS_OBJ:
        ctx["OBJ"] = rng.choice(G["OBJ"])
    if act in NEEDS_ITEM or (act == "SEARCH" and out == "FOUND"):
        ctx["ITEM"] = rng.choice(G["ITEM"])
    template = rng.choice(outcomes[OUTCOME_KEY[out]])
    return ctx, g.expand(template, ctx)


def gen_free(g, rng):
    kind = rng.choice(["room", "room", "monster", "treasure", "event"])
    inner = {"room": gen_room, "monster": gen_monster, "treasure": gen_treasure,
             "event": gen_event}[kind]
    hidden, text = inner(g, rng)
    if kind == "room":
        hidden.setdefault("LOC", rng.choice(G["LOC"]))
    if kind == "treasure" and "ITEM" not in hidden:
        return None
    prompt = g.pick(f"free_{kind}_prompt", hidden)
    return {"_prompt": prompt}, text


TASKS = {"ROOM": (gen_room, 0.22), "MONSTER": (gen_monster, 0.10), "TREASURE": (gen_treasure, 0.10),
         "NPC": (gen_npc, 0.08), "QUEST": (gen_quest, 0.06), "EVENT": (gen_event, 0.06),
         "COMBAT": (gen_combat, 0.14), "ACTION": (gen_action, 0.16), "FREE": (gen_free, 0.08)}


def to_example(task, ctx, text, rng):
    prompt = ctx.pop("_prompt", None)
    if task in ("ROOM", "MONSTER") and maybe(rng, 0.3):
        ctx["HP"] = rng.choice(G["HP"])
    if task in ("ROOM", "MONSTER", "COMBAT") and maybe(rng, 0.3):
        ctx["LVL"] = rng.choice(G["LVL"])
    tokens = [f"TASK:{task}"]
    for group in vocab.CONTEXT_ORDER[1:]:
        for key in (group, group + "2"):
            if key in ctx:
                tokens.append(f"{group}:{ctx[key]}")
    example = {"task": task, "ctx": tokens, "text": fix_articles(text)}
    if prompt is not None:
        example["prompt"] = fix_articles(prompt)
    return example


def validate(example, ctx_len):
    for name in example["ctx"]:
        if name not in vocab.ID:
            raise ValueError(f"unknown control token {name}")
    for field in ("text", "prompt"):
        s = example.get(field, "")
        bad = set(s) - ALLOWED
        if bad:
            raise ValueError(f"illegal characters {bad!r} in {field}: {s!r}")
        if "  " in s or s != s.strip():
            raise ValueError(f"bad spacing in {field}: {s!r}")
    n = 1 + len(example["ctx"]) + len(example.get("prompt", "")) + 1 + len(example["text"]) + 1
    return n <= ctx_len


def generate(bank, seed, count, ctx_len):
    rng = random.Random(seed)
    g = Grammar(bank, rng)
    names = list(TASKS)
    mix = bank.get("task_weights", {})
    weights = [mix.get(n, TASKS[n][1]) for n in names]
    seen, examples, rejected = set(), [], Counter()
    attempts = 0
    while len(examples) < count and attempts < count * 20:
        attempts += 1
        task = rng.choices(names, weights)[0]
        result = TASKS[task][0](g, rng)
        if result is None:
            rejected["unusable"] += 1
            continue
        example = to_example(task, *result, rng)
        if not validate(example, ctx_len):
            rejected["too_long"] += 1
            continue
        key = json.dumps(example, sort_keys=True)
        if key in seen:
            rejected["repeat_kept"] += 1
        seen.add(key)
        examples.append(example)
    return examples, rejected, attempts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bank", type=Path, default=ROOT / "datasets/raw/phrasebank.yaml")
    parser.add_argument("--seed", type=int, default=64)
    parser.add_argument("--count", type=int, default=200000)
    parser.add_argument("--ctx", type=int, default=128)
    parser.add_argument("--val-fraction", type=float, default=0.05)
    parser.add_argument("--extra", type=Path, action="append", default=[],
                        help="phrase file merged onto the bank (repeatable)")
    parser.add_argument("--tag", default="", help="dataset tag, e.g. v2 (default: the v1 file names)")
    args = parser.parse_args()

    bank_bytes = args.bank.read_bytes()
    bank = yaml.safe_load(bank_bytes)
    for extra in args.extra:
        extra_bytes = extra.read_bytes()
        bank_bytes += extra_bytes
        bank = merge_bank(bank, yaml.safe_load(extra_bytes))
    lint_bank(bank)
    tag = args.tag or "v1"
    sfx = f"_{args.tag}" if args.tag else ""
    examples, rejected, attempts = generate(bank, args.seed, args.count, args.ctx)
    # Split by a hash of the whole example so an identical example never lands
    # in both splits. Training keeps repeats (natural task frequencies);
    # validation is de-duplicated.
    def in_val(e):
        digest = hashlib.sha256(json.dumps(e, sort_keys=True).encode()).digest()
        return int.from_bytes(digest[:4], "little") / 2**32 < args.val_fraction
    train = [e for e in examples if not in_val(e)]
    val = list({json.dumps(e, sort_keys=True): e for e in examples if in_val(e)}.values())
    unique = list({json.dumps(e, sort_keys=True): e for e in examples}.values())

    def write(path, rows):
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w") as f:
            for row in rows:
                f.write(json.dumps(row) + "\n")
        return hashlib.sha256(path.read_bytes()).hexdigest()

    hashes = {
        "all": write(ROOT / f"datasets/processed/dm64_{tag}_all.jsonl", unique),
        "train": write(ROOT / f"datasets/training/train{sfx}.jsonl", train),
        "val": write(ROOT / f"datasets/validation/val{sfx}.jsonl", val),
    }
    lengths = [1 + len(e["ctx"]) + len(e.get("prompt", "")) + 2 + len(e["text"]) for e in examples]
    train_texts = {e["text"] for e in train}
    stats = {
        "seed": args.seed, "requested": args.count, "attempts": attempts,
        "examples": len(examples), "unique": len(unique), "train": len(train), "val": len(val),
        "rejected": dict(rejected),
        "tasks": dict(Counter(e["task"] for e in examples)),
        "token_coverage": dict(sorted(Counter(t for e in examples for t in e["ctx"]).items())),
        "seq_len": {"min": min(lengths), "max": max(lengths), "mean": round(sum(lengths) / len(lengths), 1)},
        "text_chars_total": sum(len(e["text"]) for e in examples),
        "val_text_seen_in_train": round(sum(e["text"] in train_texts for e in val) / max(1, len(val)), 3),
        "phrasebank_sha256": hashlib.sha256(bank_bytes).hexdigest(),
        "extra_files": [str(e.relative_to(ROOT)) if e.is_absolute() else str(e) for e in args.extra],
        "sha256": hashes,
    }
    missing = [t for t in vocab.TOKENS[vocab.FIRST_CONTROL_ID:] if t not in stats["token_coverage"]]
    stats["control_tokens_unused"] = missing
    out = ROOT / f"datasets/processed/dm64_{tag}_stats.json"
    out.write_text(json.dumps(stats, indent=2) + "\n")
    print(json.dumps({k: stats[k] for k in ("examples", "unique", "train", "val", "rejected", "tasks", "seq_len",
                                            "val_text_seen_in_train", "control_tokens_unused")}, indent=1))


if __name__ == "__main__":
    main()
