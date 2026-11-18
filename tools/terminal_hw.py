#!/usr/bin/env python3
"""Drive the AI terminal on the C64 Ultimate over its REST API.

    python3 tools/terminal_hw.py [--prompt TEXT] [--scene F1] [--exact]

Starts terminal/build/dm64.prg with POST /v1/runners:run_prg, waits for the
terminal's state block ($C800, "DMT1"), types keys by writing the KERNAL keyboard
buffer ($0277/$C6) with PUT /v1/machine:writemem, waits for the answer, then
prints the output text and the screen. Compares exact-mode output with
python/reference_int.py. Host: ULT_HOST (default 192.168.10.148).
"""
import argparse
import os
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "python"), str(ROOT / "tests")]
KEYS = {"F1": 0x85, "F3": 0x86, "F5": 0x87, "F7": 0x88, "F2": 0x89, "RETURN": 0x0D}


class Ult:
    def __init__(self, host):
        self.base = f"http://{host}/v1"

    def call(self, method, path, data=None, timeout=10):
        req = urllib.request.Request(self.base + path, data=data, method=method)
        if data is not None:
            req.add_header("Content-Type", "application/octet-stream")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read()

    def read(self, addr, n):
        return self.call("GET", f"/machine:readmem?address={addr:04X}&length={n}")

    def write(self, addr, data):
        self.call("PUT", f"/machine:writemem?address={addr:04X}&data={bytes(data).hex()}")

    def run_prg(self, path):
        return self.call("POST", "/runners:run_prg", Path(path).read_bytes(), timeout=30)


def state(u):
    b = u.read(0xC800, 9)
    return {"sig": bytes(b[:4]), "phase": b[4], "status": b[5], "count": b[6], "mode": b[7], "model": b[8]}


def wait(u, cond, timeout, what):
    t0 = time.time()
    while time.time() - t0 < timeout:
        s = state(u)
        if cond(s):
            return s, time.time() - t0
        time.sleep(1)
    raise SystemExit(f"timeout waiting for {what}: {state(u)}")


def key(u, code):
    u.write(0x0277, [code])
    u.write(0x00C6, [1])
    t0 = time.time()
    while u.read(0x00C6, 1)[0] and time.time() - t0 < 10:
        time.sleep(0.1)


def pet(ch):
    if "a" <= ch <= "z":
        return ord(ch) - 0x20
    return ord(ch)


def screen(u):
    from terminal_harness import scr2chr
    raw = u.read(0x0400, 1000)
    return ["".join(scr2chr(c) for c in raw[r * 40:(r + 1) * 40]).rstrip() for r in range(25)]


def output(u):
    n = u.read(0xC700, 1)[0]
    raw = u.read(0xC701, n) if n else b""
    return "".join(chr(c + 32) if 0x41 <= c <= 0x5A else chr(c - 0x80) if 0xC1 <= c <= 0xDA
                   else chr(c) for c in raw)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default=os.environ.get("ULT_HOST", "192.168.10.148"))
    ap.add_argument("--prompt", default="describe an ancient dungeon")
    ap.add_argument("--scene", choices=["F1", "F3", "F5", "F7"])
    ap.add_argument("--exact", action="store_true", help="press F2 first (greedy, comparable)")
    args = ap.parse_args()
    u = Ult(args.host)
    print(f"run_prg terminal/build/dm64.prg -> {u.run_prg(ROOT / 'terminal/build/dm64.prg').decode().strip()}")
    s, dt = wait(u, lambda s: s["sig"] == b"DMT1" and s["phase"] in (1, 3), 120, "boot")
    print(f"boot: {s} after {dt:.1f} s")
    if s["phase"] != 1:
        print("\n".join(screen(u)))
        sys.exit(1)
    if args.exact:
        key(u, KEYS["F2"])
    before = state(u)["count"]
    t0 = time.time()
    if args.scene:
        key(u, KEYS[args.scene])
    else:
        for ch in args.prompt:
            key(u, pet(ch))
        key(u, KEYS["RETURN"])
    s, _ = wait(u, lambda s: s["count"] > before and s["phase"] == 1, 900, "answer")
    elapsed = time.time() - t0
    text = output(u)
    print(f"answer after {elapsed:.1f} s (host clock, includes typing): {text!r}  state {s}")
    print("\n".join(screen(u)))
    if args.exact and not args.scene:
        import d64ai
        import lexicon
        from reference_int import IntEngine
        ref = IntEngine(d64ai.read((ROOT / "models/exported/baseline_bpe72_v2.d64ai").read_bytes()))
        ids = ref.encode_prompt(["TASK:FREE"], args.prompt)
        want = lexicon.display(ref.decode(ref.generate(ids, max_chars=120)))
        print(f"reference: {want!r}\nmatch: {text == want}")
        sys.exit(0 if text == want else 1)


if __name__ == "__main__":
    main()
