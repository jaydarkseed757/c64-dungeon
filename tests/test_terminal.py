"""AI terminal (terminal/build/dm64.prg) end to end in VICE."""
import shutil
from pathlib import Path

import pytest

import d64ai
import lexicon
from reference_int import IntEngine

pytestmark = pytest.mark.skipif(not shutil.which("x64sc") or not shutil.which("acme"),
                                reason="needs VICE (x64sc) and ACME")
ROOT = Path(__file__).resolve().parents[1]
BRINGUP = ROOT / "models/exported/bringup_bpe72.d64ai"   # the terminal's lexicon (lexicon.DEFAULT)


@pytest.fixture
def term():
    from terminal_harness import Terminal
    if not BRINGUP.exists():
        pytest.skip("run `make convert MODEL=bringup_bpe72` first")
    t = Terminal(BRINGUP)
    yield t
    t.close()


def test_boot_finds_model(term):
    term.run_to("main_idle", 300)
    st = term.state()
    assert st["sig"] == b"DMT1" and st["phase"] == 1 and st["model"] == 1
    screen = "\n".join(term.screen())
    assert "Dungeon Master 64" in screen and "REU 16 MB" in screen
    assert "Model OK." in screen and "Ready." in screen
    assert "Turbo registers off" in screen          # VICE has no $D031 turbo registers


def test_typed_prompt_matches_reference(term):
    from terminal_harness import KEYS
    term.run_to("main_idle", 300)
    term.press([KEYS["F2"]])                         # exact (greedy) mode
    assert term.state()["mode"] == 1
    term.type("describe a dungeon")
    assert term.screen()[21].startswith("> describe a dungeon")
    term.press([KEYS["RETURN"]])
    st = term.state()
    assert st["count"] == 1 and st["status"] == 0 and st["phase"] == 1
    ref = IntEngine(d64ai.read(BRINGUP.read_bytes()))
    ids = ref.encode_prompt(["TASK:FREE"], "describe a dungeon")
    want = lexicon.display(ref.decode(ref.generate(ids, max_chars=120)))
    assert term.output() == want
    window = " ".join(line.strip() for line in term.screen()[3:20])
    assert "> describe a dungeon" in window
    assert want in window                           # word wrapping keeps every word intact
    assert f"({len(want)} characters," in window


def test_editing_and_unknown_keys(term):
    from terminal_harness import KEYS
    term.run_to("main_idle", 300)
    term.type("ab")
    term.press([0x5E])                               # up-arrow: not in the vocabulary, ignored
    term.press([KEYS["DEL"]])
    assert term.screen()[21].startswith("> a") and not term.screen()[21].startswith("> ab")
    assert term.vm.read(0xC8C0, 0xC8C0)[0] == 1     # in_len


def test_scene_key_generates(term):
    from terminal_harness import KEYS
    term.run_to("main_idle", 300)
    term.press([KEYS["F1"]])
    st = term.state()
    assert st["count"] == 1 and st["status"] == 0
    window = "\n".join(term.screen()[3:20])
    assert "[room: " in window and "]" in window
    assert len(term.output()) > 0


def test_no_model_explains(tmp_path):
    from terminal_harness import Terminal
    blank = tmp_path / "blank.bin"
    blank.write_bytes(bytes(4096))
    t = Terminal(blank)
    try:
        t.run_to("wait_retry", 300)
        t.vm.read(0xC800, 0xC800)
        screen = " ".join(line.strip() for line in t.screen()[3:20])
        assert "No model in the REU" in screen and "Load into REU" in screen
        assert t.state()["status"] == 0x05
    finally:
        t.close()
