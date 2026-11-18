"""Drive terminal/build/dm64.prg in VICE: boot, type keys, read the screen."""
import subprocess
from pathlib import Path

from vice_harness import Vice

ROOT = Path(__file__).resolve().parents[1]
KBUF, NDX = 0x0277, 0xC6
TS = 0xC800
KEYS = {"F1": 0x85, "F3": 0x86, "F5": 0x87, "F7": 0x88, "F2": 0x89, "RETURN": 0x0D, "DEL": 0x14}


def build():
    subprocess.run([".venv/bin/python", "tools/gen_terminal_tables.py"], cwd=ROOT, check=True,
                   capture_output=True)
    subprocess.run(["python3", "tools/acme_longbranch.py", "acme", "-f", "cbm", "-o",
                    "terminal/build/dm64.prg", "-l", "terminal/build/dm64.lbl",
                    "terminal/source/terminal.asm"], cwd=ROOT, check=True, capture_output=True)
    labels = {}
    for line in (ROOT / "terminal/build/dm64.lbl").read_text().splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] == "=":
            labels[parts[0]] = int(parts[2].lstrip("$"), 16)
    return ROOT / "terminal/build/dm64.prg", labels


def scr2chr(c):
    c &= 0x7F
    if c == 0:
        return "@"
    if 1 <= c <= 26:
        return chr(c + 96)
    if 0x41 <= c <= 0x5A:
        return chr(c)
    if 0x20 <= c <= 0x3F:
        return chr(c)
    return {0x1B: "[", 0x1D: "]", 0x40: "-"}.get(c, "?")


def pet_key(ch):
    if "a" <= ch <= "z":
        return ord(ch) - ord("a") + 0x41
    if "A" <= ch <= "Z":
        return ord(ch) - ord("A") + 0xC1
    return ord(ch)


class Terminal:
    def __init__(self, reu_image, reu_kb=16384):
        self.prg, self.labels = build()
        self.vm = Vice(reu_image=reu_image, reu_kb=reu_kb)
        self.vm.load_prg(self.prg)

    def run_to(self, label, timeout=900):
        self.vm.run_until(self.labels[label], timeout=timeout)

    def state(self):
        b = self.vm.read(TS, TS + 8)
        return {"sig": bytes(b[:4]), "phase": b[4], "status": b[5], "count": b[6],
                "mode": b[7], "model": b[8]}

    def screen(self):
        raw = self.vm.read(0x0400, 0x07E7)
        return ["".join(scr2chr(c) for c in raw[r * 40:(r + 1) * 40]).rstrip() for r in range(25)]

    def press(self, codes, timeout=900):
        """Feed key codes through the KERNAL keyboard buffer, one per idle loop."""
        for code in codes:
            self.vm.write(KBUF, bytes([code]))
            self.vm.write(NDX, bytes([1]))
            self.run_to("main_idle", timeout)          # key taken; any work it started is done
            while self.vm.read(NDX, NDX)[0]:
                self.run_to("main_idle", timeout)

    def type(self, text):
        self.press([pet_key(c) for c in text])

    def output(self):
        n = self.vm.read(0xC700, 0xC700)[0]
        raw = self.vm.read(0xC701, 0xC700 + n) if n else b""
        return "".join(chr(c + 32) if 0x41 <= c <= 0x5A else chr(c - 0x80) if 0xC1 <= c <= 0xDA
                       else chr(c) for c in raw)

    def close(self):
        self.vm.close()
