"""Fact checks for narration: does the text agree with the game's context record?

The game owns the facts; the narrator must not contradict them. One rule set is
shared by:

  - tools/dataset_generator.py   drops training examples that break a rule
  - tools/fact_check.py          measures how often a model breaks a rule
  - tools/gen_game_tables.py     the game's own (smaller) check on the C64

A word "names" an entity when it equals one of the entity's words, or that word
plus "s" / "es" (so "rat" matches "rats" but not "rattling").

Rules (ctx = control-token names, e.g. ["TASK:MONSTER", "MON:SPIDER", ...]):

  wrong_monster   the text names a monster that is not MON (or any monster when
                  the record has none). Checked for every task except FREE.
  wrong_item      TASK:TREASURE names an item kind other than ITEM.
  missing_monster TASK:MONSTER does not name its MON.
  missing_item    TASK:TREASURE with OUT:FOUND does not name its ITEM.
  missing_lock    OUT:LOCKED does not say lock/locked.
"""
import re

# Words that name each monster. Generic words ("beast", "brute", "thing") name
# nothing: they can neither satisfy nor break a rule.
MONSTER_WORDS = {
    "SKELETON": ["skeleton"],
    "GOBLIN": ["goblin"],
    "ORC": ["orc"],
    "SPIDER": ["spider"],
    "ZOMBIE": ["zombie"],
    "TROLL": ["troll"],
    "DARK_MAGE": ["mage", "sorcerer", "warlock", "wizard"],
    "DRAGON": ["dragon", "wyrm"],
    "RAT": ["rat"],
    "BAT": ["bat"],
}

ITEM_WORDS = {
    "GOLD": ["coin", "gold"],
    "POTION": ["potion", "vial", "flask", "bottle", "draught"],
    "SWORD": ["sword", "longsword", "sabre", "saber"],
    "AXE": ["axe"],
    "MACE": ["mace"],
    "DAGGER": ["dagger", "knife"],
    "BOW": ["bow"],
    "SHIELD": ["shield"],
    "ARMOR": ["armor", "breastplate", "mail", "jerkin", "shirt", "plate", "hauberk"],
    "HELM": ["helm", "helmet"],
    "KEY": ["key"],
    "RING": ["ring"],
    "AMULET": ["amulet", "pendant", "talisman", "locket"],
    "SCROLL": ["scroll"],
    "WAND": ["wand"],
    "GEM": ["gem", "ruby", "sapphire", "emerald", "opal", "diamond", "jewel"],
    "MAP": ["map"],
}

# Words that may appear as a description of another item without naming it
# ("a gold ring", "a ring of keys" is not needed). Item -> words it may use.
ITEM_ALLOWS = {
    "RING": ["gold", "ruby", "sapphire", "emerald", "opal", "diamond", "gem", "jewel"],
    "AMULET": ["gold", "ruby", "sapphire", "emerald", "opal", "diamond", "gem", "jewel"],
    "SWORD": ["gem", "ruby", "jewel"],
    "DAGGER": ["gem", "ruby", "jewel"],
    "SHIELD": ["plate"],
    "HELM": ["plate", "mail"],
    "MAP": ["gold", "key"],
    "WAND": ["gem", "jewel", "ruby"],
    "ARMOR": ["ring"],
}

LOCK_WORDS = ["lock", "locked"]

WORD = re.compile(r"[a-z]+")


def words(text):
    return WORD.findall(text.lower())


def _names(ws, keys):
    forms = set()
    for k in keys:
        forms.update((k, k + "s", k + "es"))
    return any(w in forms for w in ws)


def named(ws, table):
    """Entities of `table` named in the word list `ws`."""
    return [name for name, keys in table.items() if _names(ws, keys)]


def parse_ctx(ctx):
    out = {}
    for token in ctx:
        group, _, value = token.partition(":")
        out.setdefault(group, value)
    return out


def check(ctx, text):
    """Return the list of broken rule names (empty = consistent)."""
    c = parse_ctx(ctx)
    task = c.get("TASK")
    if task == "FREE":
        return []
    ws = words(text)
    problems = []
    mons = named(ws, MONSTER_WORDS)
    if any(m != c.get("MON") for m in mons):
        problems.append("wrong_monster")
    if task == "MONSTER" and c.get("MON") not in mons:
        problems.append("missing_monster")
    if task == "TREASURE":
        item = c.get("ITEM")
        allowed = set(ITEM_ALLOWS.get(item, []))
        others = [i for i in named([w for w in ws if w.rstrip("s") not in allowed and w not in allowed],
                                   ITEM_WORDS) if i != item]
        if others:
            problems.append("wrong_item")
        if c.get("OUT") == "FOUND" and item and item not in named(ws, ITEM_WORDS):
            problems.append("missing_item")
    if c.get("OUT") == "LOCKED" and not _names(ws, LOCK_WORDS):
        problems.append("missing_lock")
    return problems
