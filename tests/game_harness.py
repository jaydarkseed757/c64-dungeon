"""Drive game/build/dm64game.prg in VICE."""
import subprocess
from pathlib import Path

from terminal_harness import pet_key, scr2chr
from vice_harness import Vice

ROOT = Path(__file__).resolve().parents[1]
KBUF, NDX = 0x0277, 0xC6
GS = 0xC9B0
MAP = 0xAD00


def build():
    subprocess.run([".venv/bin/python", "tools/gen_game_tables.py"], cwd=ROOT, check=True, capture_output=True)
    subprocess.run(["python3", "tools/acme_longbranch.py", "acme", "-f", "cbm", "-o", "game/build/dm64game.prg",
                    "-l", "game/build/dm64game.lbl", "game/source/game.asm"], cwd=ROOT, check=True,
                   capture_output=True)
    labels = {}
    for line in (ROOT / "game/build/dm64game.lbl").read_text().splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] == "=":
            labels[parts[0]] = int(parts[2].lstrip("$"), 16)
    return ROOT / "game/build/dm64game.prg", labels


class Game:
    def __init__(self, reu_image=None):
        self.prg, self.labels = build()
        self.vm = Vice(reu_image=reu_image)
        self.vm.load_prg(self.prg)

    def run_to(self, label, timeout=300):
        self.vm.run_until(self.labels[label], timeout=timeout)

    def feed(self, codes, stop="main_idle", timeout=300):
        """Put keys into the KERNAL buffer one at a time and run until `stop` with it empty."""
        for code in codes:
            self.vm.write(KBUF, bytes([code]))
            self.vm.write(NDX, bytes([1]))
            while True:
                self.run_to(stop, timeout)
                if self.vm.read(NDX, NDX)[0] == 0:
                    break

    def start(self, name="ana", cls=1):
        """Title: type the name (keys consumed in the name loop), RETURN, class digit."""
        for c in name:
            self.vm.write(KBUF, bytes([pet_key(c)]))
            self.vm.write(NDX, bytes([1]))
            while self.vm.read(NDX, NDX)[0]:
                self.vm.run_until(self.labels["title"] + 0, timeout=60) if False else self._step()
        self.vm.write(KBUF, bytes([13, 0x30 + cls]))
        self.vm.write(NDX, bytes([2]))
        self.run_to("main_idle", 600)

    def _step(self):
        # run a little: until GETIN is called again (KERNAL $ffe4)
        self.vm.run_until(0xFFE4, timeout=60)

    def gs(self):
        b = self.vm.read(GS, GS + 7)
        return {"sig": bytes(b[:4]), "state": b[4], "floor": b[5], "turns": b[6], "hp": b[7]}

    def screen(self):
        raw = self.vm.read(0x0400, 0x07E7)
        return ["".join(scr2chr(c) for c in raw[r * 40:(r + 1) * 40]).rstrip() for r in range(25)]

    def map(self):
        raw = self.vm.read(MAP, MAP + 2047)
        return [list(raw[y * 64:(y + 1) * 64]) for y in range(32)]

    def close(self):
        self.vm.close()
