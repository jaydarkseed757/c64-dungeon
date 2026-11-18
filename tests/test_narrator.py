"""Milestone 6: the game's Dungeon Master narrates with the engine (VICE)."""
import shutil
from pathlib import Path

import pytest

import d64ai
import lexicon
from reference_int import IntEngine

pytestmark = pytest.mark.skipif(not shutil.which("x64sc") or not shutil.which("acme"),
                                reason="needs VICE (x64sc) and ACME")
ROOT = Path(__file__).resolve().parents[1]
MODEL = ROOT / "models/exported/bringup_bpe72.d64ai"


def rd(g, name, n=1):
    a = g.labels[name]
    b = g.vm.read(a, a + n - 1)
    return b[0] if n == 1 else list(b)


@pytest.fixture
def game():
    from game_harness import Game
    if not MODEL.exists():
        pytest.skip("run `make convert MODEL=bringup_bpe72` first")
    g = Game(reu_image=MODEL)
    g.start("ana", 1)
    yield g
    g.close()


def test_model_found_narrator_off_without_turbo(game):
    assert rd(game, "ai_ok") == 1
    assert rd(game, "ai_turbo") == 0          # VICE has no $D031 turbo registers
    assert rd(game, "ai_on") == 0


def test_room_narration_matches_reference(game):
    game.feed([0x4E])                          # N: narrator on
    assert rd(game, "ai_on") == 1
    game.vm.write(game.labels["ai_temp"], bytes([0, 0]))     # greedy, reproducible
    if rd(game, "cur_room") == 255:
        pytest.skip("player not in a room")
    count = rd(game, "dm_count")
    game.feed([0x58], timeout=1200)            # X: look -> room event -> narration
    assert rd(game, "dm_count") == count + 1
    ctx = rd(game, "dm_ctx", 16)
    ctx = ctx[1:1 + ctx[0]]
    lex = lexicon.load(lexicon.DEFAULT)
    assert [lex.TOKENS[t] for t in ctx][0] == "TASK:ROOM"
    ref = IntEngine(d64ai.read(MODEL.read_bytes()))
    want = lexicon.display(ref.decode(ref.generate([lex.BOS] + ctx + [lex.SEP], max_chars=48)))
    n = game.vm.read(0xC700, 0xC700)[0]
    got = "".join(chr(c + 32) if 0x41 <= c <= 0x5A else chr(c - 0x80) if 0xC1 <= c <= 0xDA else chr(c)
                  for c in game.vm.read(0xC701, 0xC700 + n))
    assert got == want and got
    log = " ".join(line.strip() for line in game.screen()[17:24])
    assert want.split()[0] in log                # streamed into the Dungeon Master window
    assert "You enter" not in log.split("look")[-1] if "look" in log else True
    assert "WASD move" in game.screen()[24]      # help row restored after "thinking"


def test_silent_without_model():
    from game_harness import Game
    g = Game()                                 # empty REU: no model
    try:
        g.start("bo", 2)
        assert rd(g, "ai_ok") == 0 and rd(g, "ai_why") == 2
        g.feed([0x4E])
        assert "built-in text only" in " ".join(" ".join(g.screen()[17:24]).split())
        g.feed([0x58])                         # look still works with built-in text
        assert "You enter" in " ".join(g.screen()[17:24]) or rd(g, "cur_room") == 255
    finally:
        g.close()
