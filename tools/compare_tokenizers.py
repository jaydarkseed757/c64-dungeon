#!/usr/bin/env python3
"""Compare the char and bpe72 baseline models: quality per character and C64 cost per character.

    .venv/bin/python tools/compare_tokenizers.py

For each model: python/evaluate.py (nats per narration character, float vs int
agreement, samples), then the same greedy prompts through the real engine in VICE
(tests/test_engine_api.generate_on_c64) to count 1 MHz cycles per output character
(prompt prefill included). Writes models/exported/tokenizer_comparison.json.
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "python"), str(ROOT / "tests"), str(ROOT / "tools")]
import d64ai  # noqa: E402
import lexicon  # noqa: E402
from reference_int import IntEngine  # noqa: E402

MODELS = {"char": "baseline", "bpe72": "baseline_bpe72"}
PROMPTS = [["TASK:ACTION", "OBJ:DOOR", "ACT:OPEN", "OUT:LOCKED"],
           ["TASK:ROOM", "LOC:CRYPT", "ROOM:BURIAL_CHAMBER"],
           ["TASK:MONSTER", "LOC:CAVERN", "MON:ORC", "MST:WOUNDED"],
           ["TASK:TREASURE", "OBJ:CHEST", "ITEM:SWORD", "OUT:FOUND"]]


MIN_CYCLES_PER_TOKEN = 20_000_000     # far below any baseline forward pass (VICE profile: ~45M)


def unwrap(cycles, tokens):
    """The CIA2 cascade counts 32 bits and wraps every 4.29G cycles; long runs exceed that.
    A forward pass costs well over MIN_CYCLES_PER_TOKEN, so the number of wraps is unambiguous."""
    while cycles < tokens * MIN_CYCLES_PER_TOKEN:
        cycles += 1 << 32
    return cycles


def main():
    from test_engine_api import generate_on_c64
    report = {}
    for lex_name, name in MODELS.items():
        ckpt = ROOT / f"models/checkpoints/{name}/best.pt"
        pkg = ROOT / f"models/exported/{name}.d64ai"
        subprocess.run([sys.executable, str(ROOT / "python/evaluate.py"), str(ckpt), str(pkg),
                        "--examples", "100", "--responses", "30"], check=True, capture_output=True)
        ev = json.loads(pkg.with_suffix(".eval.json").read_text())
        lex = lexicon.load(lex_name)
        ref = IntEngine(d64ai.read(pkg.read_bytes()))
        runs = []
        for ctx in PROMPTS:
            ids = lex.encode_prompt(ctx)
            want = lexicon.display(ref.decode(ref.generate(ids, max_chars=120)))
            out_ids = ref.generate(ids, max_chars=120)
            status, text, cycles = generate_on_c64(pkg, ids, max_chars=120, skip_crc=1)
            cycles = unwrap(cycles, len(ids) + len(out_ids))
            runs.append({"ctx": ctx, "text": text, "matches_reference": text == want,
                         "status": status, "cycles": cycles, "chars": len(text),
                         "cycles_per_char": round(cycles / max(1, len(text)))})
            print(f"{lex_name:6} {' '.join(ctx)}: {text!r} {cycles:,} cycles", flush=True)
        total_cycles = sum(r["cycles"] for r in runs)
        total_chars = sum(r["chars"] for r in runs)
        report[lex_name] = {
            "model": name, "package_bytes": pkg.stat().st_size, "params": ev["params"],
            "nats_per_char": ev["nats_per_char"],
            "teacher_forced": ev["teacher_forced"],
            "greedy_response_exact_match": ev["greedy_response_exact_match"],
            "greedy_chars_per_token": ev["greedy_chars_per_token"],
            "vice": {"runs": runs, "cycles_per_char": round(total_cycles / max(1, total_chars))},
            "samples": [{k: s[k] for k in ("ctx", "int_greedy", "int_topk8_t0.8")} for s in ev["samples"][:8]],
        }
    out = ROOT / "models/exported/tokenizer_comparison.json"
    out.write_text(json.dumps(report, indent=2) + "\n")
    for k, v in report.items():
        print(f"{k:6} nats/char float {v['nats_per_char']['float']} int {v['nats_per_char']['int']}  "
              f"top1 {v['teacher_forced']['top1_agreement']}  chars/token {v['greedy_chars_per_token']}  "
              f"VICE cycles/char {v['vice']['cycles_per_char']:,}")


if __name__ == "__main__":
    main()
