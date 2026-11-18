"""Helpers for running engine test hosts in VICE (see tools/vice_harness.py)."""
import re
import struct
import subprocess
from pathlib import Path

from vice_harness import Vice

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "engine/build"


def assemble(source, name):
    prg, lbl = BUILD / f"{name}.prg", BUILD / f"{name}.lbl"
    BUILD.mkdir(parents=True, exist_ok=True)
    subprocess.run(["python3", "tools/acme_longbranch.py", "acme", "-f", "cbm", "-o", str(prg), "-l", str(lbl), str(source)],
                   check=True, cwd=ROOT, capture_output=True, text=True)
    labels = {}
    for line in lbl.read_text().splitlines():
        m = re.match(r"\s*(\S+)\s*=\s*\$([0-9a-fA-F]+)", line)
        if m:
            labels[m.group(1)] = int(m.group(2), 16)
    return prg, labels


class Host:
    """One VICE session running a test host. call() runs one dispatcher command."""

    def __init__(self, source, name, reu_image=None):
        self.prg, self.labels = assemble(source, name)
        self.vm = Vice(reu_image=reu_image)
        self.vm.load_prg(self.prg)
        self.entry, self.done = self.labels["test_entry"], self.labels["test_done"]

    def run(self, timeout=600):
        self.vm.set_pc(self.entry)
        self.vm.run_until(self.done, timeout=timeout)

    def cycles(self):
        return struct.unpack("<I", self.vm.read(0xC840, 0xC843))[0]

    def close(self):
        self.vm.close()
