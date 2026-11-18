#!/usr/bin/env python3
"""Rewrite out-of-range conditional branches reported by ACME as inverted branch + JMP.

    python3 tools/acme_longbranch.py <acme command...>
Runs ACME, and for each "Target out of range" error rewrites that source line
`bXX label` to `bYY + / jmp label / +`, then repeats until ACME succeeds.
"""
import re
import subprocess
import sys
from pathlib import Path

OPP = {"bne": "beq", "beq": "bne", "bcc": "bcs", "bcs": "bcc", "bpl": "bmi", "bmi": "bpl",
       "bvc": "bvs", "bvs": "bvc"}
ERR = re.compile(r"Error - File (\S+), line (\d+) .*Target out of range")

counter = [0]
for _ in range(20):
    r = subprocess.run(sys.argv[1:], capture_output=True, text=True)
    hits = {}
    for m in ERR.finditer(r.stdout + r.stderr):
        hits.setdefault(m.group(1), set()).add(int(m.group(2)))
    if not hits:
        sys.stdout.write(r.stdout)
        sys.stderr.write(r.stderr)
        sys.exit(r.returncode)
    for path, lines in hits.items():
        src = Path(path).read_text().split("\n")
        for n in sorted(lines, reverse=True):
            line = src[n - 1]
            m = re.match(r"^(\S*\s+)(b(?:ne|eq|cc|cs|pl|mi|vc|vs))\s+(\S+)(.*)$", line)
            if not m:
                sys.exit(f"cannot rewrite {path}:{n}: {line}")
            label_part, op, target, rest = m.groups()
            indent = " " * 8
            counter[0] += 1                 # unique label: an anonymous "+" could
            lab = f".lbx{counter[0]}_{n}"   # capture an earlier "bXX +" in the block
            new = [f"{label_part}{OPP[op]} {lab}{rest}", f"{indent}jmp {target}", f"{lab}:"]
            src[n - 1:n] = new
        Path(path).write_text("\n".join(src))
sys.exit("too many iterations")
