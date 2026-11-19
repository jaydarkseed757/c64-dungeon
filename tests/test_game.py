"""Dungeon game (game/build/dm64game.prg) in VICE: generator invariants and rules."""
import shutil
from collections import deque

import pytest

import lexicon
import vocab

pytestmark = pytest.mark.skipif(not shutil.which("x64sc") or not shutil.which("acme"),
                                reason="needs VICE (x64sc) and ACME")
WALL, FLOOR, DOOR, LOCKED, STAIRS, TRAP, TRAPV = range(7)
I_KEY, I_AMULET = 11, 15


@pytest.fixture
def game():
    from game_harness import Game
    g = Game()
    g.start("ana", 1)
    yield g
    g.close()


def rd(g, name, n=1):
    a = g.labels[name]
    b = g.vm.read(a, a + n - 1)
    return b[0] if n == 1 else list(b)


def wr(g, name, data):
    g.vm.write(g.labels[name], bytes(data if isinstance(data, (list, bytes)) else [data]))


def reach(grid, start, allow_locked):
    ok = {FLOOR, DOOR, STAIRS, TRAP, TRAPV} | ({LOCKED} if allow_locked else set())
    seen, q = {start}, deque([start])
    while q:
        x, y = q.popleft()
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < 64 and 0 <= ny < 32 and (nx, ny) not in seen and grid[ny][nx] & 31 in ok:
                seen.add((nx, ny))
                q.append((nx, ny))
    return seen


def floor_state(g):
    grid = g.map()
    items = [(t, x, y) for t, x, y in zip(rd(g, "i_type", 32), rd(g, "i_x", 32), rd(g, "i_y", 32)) if t]
    mons = [(t, x, y) for t, x, y in zip(rd(g, "m_type", 24), rd(g, "m_x", 24), rd(g, "m_y", 24)) if t != 255]
    return grid, items, mons, (rd(g, "p_x"), rd(g, "p_y"))


def check_floor(g, floor):
    grid, items, mons, start = floor_state(g)
    assert grid[start[1]][start[0]] & 31 == FLOOR
    open_all = reach(grid, start, allow_locked=True)
    locked_free = reach(grid, start, allow_locked=False)
    walkable = {(x, y) for y in range(32) for x in range(64) if grid[y][x] & 31 not in (WALL,)}
    assert walkable == open_all, "every non-wall tile is connected"
    for y in (0, 31):
        assert all(grid[y][x] & 31 == WALL for x in range(64))
    for t, x, y in items + mons:
        assert grid[y][x] & 31 in (FLOOR, TRAP, TRAPV), (t, x, y)
    assert len({(x, y) for _, x, y in mons}) == len(mons)
    goal = [(x, y) for y in range(32) for x in range(64) if grid[y][x] & 31 == STAIRS]
    if floor < 5:
        assert len(goal) == 1 and goal[0] in open_all
    else:
        assert not goal and any(t == I_AMULET for t, _, _ in items)
        assert any(t == 9 for t, _, _ in mons), "the dragon guards the amulet"
    locked = [(x, y) for y in range(32) for x in range(64) if grid[y][x] & 31 == LOCKED]
    if floor >= 2 and locked:
        keys = [(x, y) for t, x, y in items if t == I_KEY]
        assert keys and keys[0] in locked_free, "the key is reachable without passing a locked door"
    return grid, goal


def descend(g):
    grid, items, mons, start = floor_state(g)
    stairs = [(x, y) for y in range(32) for x in range(64) if grid[y][x] & 31 == STAIRS][0]
    wr(g, "p_x", stairs[0])
    wr(g, "p_y", stairs[1])
    g.feed([0x3E])                                      # ">"


def test_all_floors_are_sound(game):
    for floor in range(1, 6):
        assert game.gs()["floor"] == floor
        check_floor(game, floor)
        if floor < 5:
            descend(game)
    assert "level 5" in " ".join(game.screen()[17:24]).lower() or game.gs()["floor"] == 5


def test_same_seed_same_dungeon():
    from game_harness import Game
    maps = []
    for _ in range(2):
        g = Game()
        try:
            g.start("bo", 2)
            g.vm.write(g.labels["seed"], bytes([0x34, 0x12]))
            descend(g)                                  # floor 2 generated from the fixed seed
            maps.append((g.map(), floor_state(g)[1:]))
        finally:
            g.close()
    assert maps[0] == maps[1]


def test_combat_records_and_rules(game):
    grid, items, mons, start = floor_state(game)
    # put a goblin next to the player, then attack it until something happens
    wr(game, "m_type", [3] + [255] * 23)                 # only this goblin
    wr(game, "m_x", start[0] + 1)
    wr(game, "m_y", start[1])
    wr(game, "m_hp", 7)
    wr(game, "mon_flags", 1)                              # already announced
    if grid[start[1]][start[0] + 1] & 31 == WALL:
        pytest.skip("start room too narrow")
    before = rd(game, "dm_count")
    game.feed([0x44])                                   # D: attack east
    assert rd(game, "dm_count") > before
    ctx = rd(game, "dm_ctx", 8)
    names = [lexicon.load(lexicon.DEFAULT).TOKENS[t] for t in ctx[1:1 + ctx[0]]]
    # the last record is either our attack or the goblin's answer
    assert names[0] == "TASK:COMBAT" and names[1] == "MON:GOBLIN"
    order = [vocab.CONTEXT_ORDER.index(n.split(":")[0]) for n in names]
    assert order == sorted(order), f"context tokens out of training order: {names}"
    log = " ".join(game.screen()[17:24])
    assert "goblin" in log


def test_locked_door_needs_key(game):
    _, goal = None, None
    descend(game)                                       # floor 2 has locked doors
    grid, items, mons, start = floor_state(game)
    locked = [(x, y) for y in range(32) for x in range(64) if grid[y][x] & 31 == LOCKED]
    assert locked
    lx, ly = locked[0]
    # stand on a walkable neighbour of the locked door
    for dx, dy, key in ((1, 0, 0x41), (-1, 0, 0x44), (0, 1, 0x57), (0, -1, 0x53)):
        nx, ny = lx + dx, ly + dy
        if grid[ny][nx] & 31 in (FLOOR, DOOR) and (nx, ny) not in [(x, y) for _, x, y in mons]:
            break
    wr(game, "p_x", nx)
    wr(game, "p_y", ny)
    wr(game, "p_inv", [0] * 8)
    game.feed([key])
    assert "locked" in " ".join(game.screen()[17:24]).lower()
    assert game.map()[ly][lx] & 31 == LOCKED
    wr(game, "p_inv", [I_KEY] + [0] * 7)
    game.feed([key])
    assert game.map()[ly][lx] & 31 == DOOR
    assert rd(game, "p_inv", 8) == [0] * 8              # key used up


def test_pickup_and_inventory(game):
    grid, items, mons, start = floor_state(game)
    # drop a sword where the player stands and take it
    wr(game, "i_type", [4] + list(rd(game, "i_type", 32))[1:])
    wr(game, "i_x", start[0])
    wr(game, "i_y", start[1])
    game.feed([0x47])                                   # G
    assert 4 in rd(game, "p_inv", 8)
    assert "sword" in " ".join(game.screen()[17:24]).lower()


def test_death_and_victory():
    from game_harness import Game
    g = Game()
    try:
        g.start("cy", 3)
        grid, items, mons, start = floor_state(g)
        wr(g, "p_hp", 1)
        wr(g, "m_type", [9] + [255] * 23)                         # only a dragon, next door
        wr(g, "mon_flags", 1)
        wr(g, "m_x", start[0] + 1)
        wr(g, "m_y", start[1])
        wr(g, "m_hp", 60)
        for _ in range(200):                                     # attack until the dragon wins
            if g.gs()["state"] == 2:
                break
            wr(g, "p_hp", 1)
            g.vm.write(0x0277, bytes([0x44]))
            g.vm.write(0x00C6, bytes([1]))
            while g.vm.read(0x00C6, 0x00C6)[0]:
                g.vm.run_until(0xFFE4, timeout=60)
            g.vm.run_until(0xFFE4, timeout=60)                    # key fully processed
        assert g.gs()["state"] == 2
        g.run_to("end_wait")
        assert "died" in " ".join(g.screen()[17:24]).lower()
    finally:
        g.close()
    g = Game()
    try:
        g.start("di", 1)
        grid, items, mons, start = floor_state(g)
        wr(g, "i_type", [I_AMULET] + list(rd(g, "i_type", 32))[1:])
        wr(g, "i_x", start[0])
        wr(g, "i_y", start[1])
        g.vm.write(0x0277, bytes([0x47]))
        g.vm.write(0x00C6, bytes([1]))
        g.run_to("end_wait")
        assert g.gs()["state"] == 3
        assert "victory" in " ".join(g.screen()[17:24]).lower()
    finally:
        g.close()


def _open_screen(game, key):
    """Press a key that opens a full-view screen and stop while it waits for a key."""
    game.vm.write(0x0277, bytes([key]))
    game.vm.write(0xC6, bytes([1]))
    while game.vm.read(0xC6, 0xC6)[0]:
        game._step()
    game._step()                      # the screen is drawn and polls GETIN again
    return game.screen()


@pytest.mark.parametrize("key,title", [(0x49, "Your pack"), (0x43, "")])
def test_item_and_character_screens_are_clean(game, key, title):
    """clear_view once filled the view with screen code 13 ("m"): only spaces and text."""
    rows = _open_screen(game, key)[1:16]
    view = game.vm.read(0x0400 + 40, 0x0400 + 16 * 40 - 1)
    assert 0x0D not in view, "\n".join(rows)
    assert all(len(r) <= 40 for r in rows)
    if title:
        assert rows[1].strip().startswith(title) and rows[1].rstrip().endswith("close)")
