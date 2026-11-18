#!/usr/bin/env python3
"""Run the engine hardware check (engine/tests/hw_check.asm) and decode its result.

    python3 tools/hw_check.py --vice      in VICE with the baseline model as REU image
    python3 tools/hw_check.py --ultimate  on the C64 Ultimate over its REST API
                                          (the model must already be in the REU)

Ultimate access: ULT_HOST (default 192.168.10.148). Uses only documented REST
calls (POST /v1/runners:run_prg with the PRG as raw body, GET /v1/machine:readmem),
the same way ../c64-tyrian/tools/ultimate.py does. run_prg resets the C64; REU
contents survive a reset.
"""
import argparse
import json
import os
import random
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "python"), str(ROOT / "tools")]
import lexicon  # noqa: E402

RES = 0xC800
PROMPT_CTX = ["TASK:ACTION", "OBJ:DOOR", "ACT:OPEN", "OUT:LOCKED"]
ERRORS = {0: "OK", 1: "NO_REU", 2: "REU_SMALL", 3: "NO_FILE", 4: "IO", 5: "SIGNATURE (no model in REU)",
          6: "VERSION", 7: "ARCH", 8: "CHECKSUM", 9: "VOCAB", 10: "NOT_INIT", 11: "NO_MODEL",
          12: "BAD_TOKEN", 13: "CONTEXT", 14: "CANCELLED", 16: "STATE"}


def build(nonce, uci=False, damage=False):
    subprocess.run(["python3", "tools/acme_longbranch.py", "acme", "-f", "cbm", "-o", "engine/build/hw_check.prg", "-l",
                    "engine/build/hw_check.lbl", "engine/tests/hw_check.asm"], cwd=ROOT, check=True)
    labels = {}
    for line in (ROOT / "engine/build/hw_check.lbl").read_text().splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] == "=":
            labels[parts[0]] = int(parts[2].lstrip("$"), 16)
    data = bytearray((ROOT / "engine/build/hw_check.prg").read_bytes())
    load = data[0] | data[1] << 8
    ids = lexicon.load(lexicon.DEFAULT).encode_prompt(PROMPT_CTX)
    off = labels["prompt"] - load + 2
    data[off:off + 1 + len(ids)] = bytes([len(ids)] + ids)
    off = labels["nonce_src"] - load + 2
    data[off:off + 2] = nonce.to_bytes(2, "little")
    off = labels["mode"] - load + 2
    data[off] = (1 if uci else 0) | (2 if damage else 0)
    out = ROOT / "engine/build/hw_check_run.prg"
    out.write_bytes(data)
    return out


def decode(block, nonce):
    if block[0:4] != b"DM64" or int.from_bytes(block[4:6], "little") != nonce:
        return None
    r = {"status": {0: "RUNNING", 1: "DONE", 2: "FAILED"}.get(block[6], block[6]),
         "step": block[7],
         "init": ERRORS.get(block[8], block[8]) if block[9] & 1 else "OK",
         "reu_mb": block[10], "caps": block[11],
         "d031_before": f"${block[12]:02X}", "d031_after_set": f"${block[28]:02X}",
         "load": ERRORS.get(block[13], block[13]) if block[14] & 1 else "OK",
         "load_cia_ticks": int.from_bytes(block[15:19], "little"),
         "generated": bool(block[19])}
    if block[102:106] != bytes(4):      # the UCI step ran (it records its time)
        n = block[108]
        r["uci_load"] = ERRORS.get(block[100], block[100]) if block[101] & 1 else "OK"
        r["uci_cia_ticks"] = int.from_bytes(block[102:106], "little")
        r["uci_status_text"] = bytes(block[109:109 + min(n, 23)]).decode("ascii", "replace")
        r["reu_header_damaged_first"] = bool(block[106])
    if block[19]:
        r["generation"] = ERRORS.get(block[21], block[21]) if block[22] & 1 else "OK"
        r["gen_cia_ticks"] = int.from_bytes(block[23:27], "little")
        n = block[32]
        text = []
        for c in block[33:33 + n]:
            text.append(chr(c + 32) if 0x41 <= c <= 0x5A else chr(c - 0x80) if 0xC1 <= c <= 0xDA else chr(c))
        r["output"] = "".join(text)
        r["chars"] = n
    return r


def run_vice(prg):
    from vice_harness import Vice
    labels = {}
    for line in (ROOT / "engine/build/hw_check.lbl").read_text().splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] == "=":
            labels[parts[0]] = int(parts[2].lstrip("$"), 16)
    with Vice(reu_image=ROOT / "models/exported/baseline_bpe72_v2.d64ai") as vm:
        vm.load_prg(prg)
        vm.run_until(labels["show"], timeout=600)
        return vm.read(RES, RES + 159)


def run_ultimate(prg, host, timeout):
    base = f"http://{host}"
    req = urllib.request.Request(f"{base}/v1/runners:run_prg", data=prg.read_bytes(), method="POST")
    req.add_header("Content-Type", "application/octet-stream")
    print(f">> POST {base}/v1/runners:run_prg ({prg.stat().st_size} bytes)", file=sys.stderr)
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = resp.read().decode(errors="replace")
        print(f"<< {resp.status} {body.strip()[:200]}", file=sys.stderr)
    t0 = time.time()
    last = None
    while time.time() - t0 < timeout:
        time.sleep(2)
        url = f"{base}/v1/machine:readmem?address={RES:04X}&length=160"
        with urllib.request.urlopen(url, timeout=10) as resp:
            block = resp.read()
        if block[6:8] != last:
            last = block[6:8]
            print(f"   t={time.time() - t0:5.1f}s status={block[6]} step={block[7]}", file=sys.stderr)
        if block[6] in (1, 2) and block[0:4] == b"DM64":
            return block
    return block


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    where = ap.add_mutually_exclusive_group(required=True)
    where.add_argument("--vice", action="store_true")
    where.add_argument("--ultimate", action="store_true")
    ap.add_argument("--host", default=os.environ.get("ULT_HOST", "192.168.10.148"))
    ap.add_argument("--timeout", type=float, default=600)
    ap.add_argument("--damage", action="store_true",
                    help="with --uci: overwrite REU byte 0 first, so only a real file load can pass")
    ap.add_argument("--uci", action="store_true",
                    help="first load DM64AI.REU from USB through the Command Interface")
    args = ap.parse_args()
    nonce = random.randrange(1, 65536)
    prg = build(nonce, args.uci, args.damage)
    block = run_vice(prg) if args.vice else run_ultimate(prg, args.host, args.timeout)
    result = decode(block, nonce)
    if result is None:
        sys.exit(f"no result block for this run (nonce {nonce}); first bytes {block[:8].hex()}")
    result["where"] = "VICE x64sc" if args.vice else f"C64 Ultimate {args.host}"
    result["step"] = block[7]
    print(json.dumps(result, indent=2))
    sys.exit(0 if result["status"] == "DONE" else 1)


if __name__ == "__main__":
    main()
