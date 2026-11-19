"""Milestone 8: fact checks (python/facts.py) and the game's word check (narrator.asm)."""
import shutil

import pytest

import facts
import lexicon


def test_rules():
    assert facts.check(["TASK:MONSTER", "MON:SPIDER", "MST:HEALTHY"], "a hairy spider drops down.") == []
    assert facts.check(["TASK:MONSTER", "MON:SPIDER"], "a goblin grins.") == ["wrong_monster", "missing_monster"]
    assert facts.check(["TASK:ROOM", "ROOM:HALL"], "a skeleton rattles here.") == ["wrong_monster"]
    assert facts.check(["TASK:ROOM", "ROOM:HALL"], "rattling chains and a torch.") == []   # not rat, orc
    assert facts.check(["TASK:ROOM", "ROOM:LAIR", "MON:BAT"], "bats hang from the roof.") == []
    assert facts.check(["TASK:TREASURE", "ITEM:RING", "OUT:FOUND"], "a gold ring glints.") == []
    assert facts.check(["TASK:TREASURE", "ITEM:GEM", "OUT:FOUND"], "you find a flask.") == \
        ["wrong_item", "missing_item"]
    assert facts.check(["TASK:ACTION", "OBJ:DOOR", "ACT:OPEN", "OUT:LOCKED"], "the door will not budge.") == \
        ["missing_lock"]
    assert facts.check(["TASK:FREE"], "a goblin and a dragon.") == []


def test_v3_generator_filters(tmp_path):
    import random
    import sys
    from pathlib import Path
    import yaml
    root = Path(__file__).resolve().parents[1]
    sys.path.insert(0, str(root / "tools"))
    import dataset_generator as dg
    bank = yaml.safe_load((root / "datasets/raw/phrasebank.yaml").read_text())
    for extra in ("phrasebank_v2_additions.yaml", "phrasebank_v3_additions.yaml"):
        bank = dg.merge_bank(bank, yaml.safe_load((root / "datasets/raw" / extra).read_text()))
    dg.lint_bank(bank)
    lex = lexicon.load("bpe72")
    examples, rejected, _ = dg.generate(bank, 5, 3000, 128, fact_filter=True, max_game_tokens=44, lex=lex)
    assert len(examples) == 3000 and rejected["fact_check"] and rejected["game_length"]
    for e in examples:
        assert facts.check(e["ctx"], e["text"]) == []
        if e["task"] in dg.GAME_TASKS:
            assert len(lex.encode_text(e["text"])) + 1 <= 44
    typo = dg.add_typo("describe the room", random.Random(2))
    assert typo != "describe the room" and abs(len(typo) - len("describe the room")) <= 1


# ---------------------------------------------------------------- VICE: narrator.asm
needs_vice = pytest.mark.skipif(not shutil.which("x64sc") or not shutil.which("acme"),
                                reason="needs VICE (x64sc) and ACME")
STUB = 0x0340          # cassette buffer: jsr fact_setup / ldx #len / jsr fact_word / jmp *


def pet(word):
    """Engine output encoding: lowercase = $41-$5a, capitals = $c1-$da."""
    return bytes(ord(c.upper()) | (0x80 if c.isupper() else 0) for c in word)


@pytest.fixture(scope="module")
def game():
    from game_harness import Game
    g = Game()
    g.vm.run_until(g.labels["title"], timeout=120)
    yield g
    g.close()


def word_check(g, ctx, word):
    lex = lexicon.load(lexicon.DEFAULT)
    ids = [lex.ID[t] for t in ctx]
    L = g.labels
    g.vm.write(L["dm_ctx"], bytes([len(ids)] + ids))
    g.vm.write(L["out_buf"], bytes([len(word)]) + pet(word))
    g.vm.write(L["ai_shown"], bytes([0]))
    fs, fw = L["fact_setup"], L["fact_word"]
    stub = bytes([0x20, fs & 0xFF, fs >> 8, 0xA2, len(word), 0x20, fw & 0xFF, fw >> 8,
                  0x4C, (STUB + 8) & 0xFF, (STUB + 8) >> 8])
    g.vm.write(STUB, stub)
    g.vm.set_pc(STUB)
    g.vm.run_until(STUB + 8, timeout=30)
    seen = g.vm.read(L["f_seen"], L["f_seen"])[0]
    bad = g.vm.read(L["f_bad"], L["f_bad"])[0]
    return seen, bad


@needs_vice
@pytest.mark.parametrize("ctx,word,seen,bad", [
    (["TASK:MONSTER", "MON:SPIDER", "MST:HEALTHY"], "spider", 1, 0),
    (["TASK:MONSTER", "MON:SPIDER", "MST:HEALTHY"], "Spiders", 1, 0),
    (["TASK:MONSTER", "MON:SPIDER", "MST:HEALTHY"], "goblin", 0, 1),
    (["TASK:MONSTER", "MON:DARK_MAGE", "MST:HEALTHY"], "sorcerer", 1, 0),
    (["TASK:ROOM", "LOC:CRYPT", "ROOM:HALL"], "rats", 0, 1),
    (["TASK:ROOM", "LOC:CRYPT", "ROOM:HALL"], "rattling", 0, 0),
    (["TASK:ROOM", "LOC:CRYPT", "ROOM:HALL"], "torch", 0, 0),
    (["TASK:ROOM", "LOC:CRYPT", "ROOM:HALL", "MON:ORC"], "orcs", 0, 0),
    (["TASK:ROOM", "LOC:CRYPT", "ROOM:HALL", "MON:ORC"], "Troll", 0, 1),
    (["TASK:TREASURE", "ITEM:GEM", "OUT:FOUND"], "gems", 1, 0),
    (["TASK:TREASURE", "ITEM:GEM", "OUT:FOUND"], "flask", 0, 0),
    (["TASK:ACTION", "OBJ:DOOR", "ACT:OPEN", "OUT:LOCKED"], "locked", 1, 0),
    (["TASK:ACTION", "OBJ:DOOR", "ACT:OPEN", "OUT:LOCKED"], "lockes", 1, 0),
])
def test_game_word_check(game, ctx, word, seen, bad):
    assert word_check(game, ctx, word) == (seen, bad)


@needs_vice
def test_game_word_check_agrees_with_facts(game):
    """Every word in the list, in both cases and plurals, as in python/facts.py."""
    for mon, words in facts.MONSTER_WORDS.items():
        for w in words:
            ctx = ["TASK:MONSTER", f"MON:{mon}", "MST:HEALTHY"]
            assert word_check(game, ctx, w) == (1, 0), w
            assert word_check(game, ctx, w.capitalize() + "s") == (1, 0), w
            other = next(m for m in facts.MONSTER_WORDS if m != mon)
            assert word_check(game, ["TASK:ROOM", "ROOM:HALL", f"MON:{other}"], w)[1] == 1, w


@needs_vice
def test_narration_stops_before_a_wrong_monster():
    """bringup_bpe72, greedy, an armory with no monster: the model writes
    "you find an old armory, skething spiders." The game must never show
    "spiders", must end the text with "...", and must ask for its built-in line."""
    from pathlib import Path
    from game_harness import Game
    model = Path(__file__).resolve().parents[1] / "models/exported/bringup_bpe72.d64ai"
    if not model.exists():
        pytest.skip("run `make convert MODEL=bringup_bpe72` first")
    lex = lexicon.load(lexicon.DEFAULT)
    g = Game(reu_image=model)
    try:
        g.start("ana", 1)
        L = g.labels
        ids = [lex.ID[t] for t in ["TASK:ROOM", "LOC:KEEP", "ROOM:ARMORY"]]
        g.vm.write(L["ai_on"], bytes([1]))
        g.vm.write(L["ai_temp"], bytes([0, 0]))
        g.vm.write(L["dm_kind"], bytes([L["EV_ROOM"]]))
        g.vm.write(L["dm_ctx"], bytes([len(ids)] + ids))
        nar = L["narrate"]
        res = STUB + 16
        stub = bytes([0x20, nar & 0xFF, nar >> 8, 0x08, 0x68, 0x8D, res & 0xFF, res >> 8,
                      0x4C, (STUB + 8) & 0xFF, (STUB + 8) >> 8])
        g.vm.write(STUB, stub)
        g.vm.set_pc(STUB)
        g.vm.run_until(STUB + 8, timeout=1200)
        carry = g.vm.read(res, res)[0] & 1
        n = g.vm.read(L["out_buf"], L["out_buf"])[0]
        produced = bytes(g.vm.read(L["out_buf"] + 1, L["out_buf"] + n)).decode("latin-1").lower()
        log = " ".join(line.strip() for line in g.screen()[17:24]).lower()
        assert "spider" in produced                # the model did write it ...
        assert "spider" not in log                 # ... but the player never saw it
        assert log.endswith("you find an old armory, skething ...")
        assert carry == 0                          # the caller prints its built-in text
    finally:
        g.close()
