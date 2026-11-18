"""DM64 vocabulary v1: the single source of truth for token ids.

Layout (one-byte ids, vocab <= 256):
    0..4     specials        PAD BOS EOS SEP UNK
    5..63    text symbols    single characters, generated one per token
    64..     control tokens  structured game context, never emitted as text

Changing anything here changes the vocabulary hash. A model package and a game
build must then be regenerated together (see docs/MODEL_FORMAT.md).
"""

SPECIALS = ["PAD", "BOS", "EOS", "SEP", "UNK"]
PAD, BOS, EOS, SEP, UNK = range(5)

# Text is trained single-case (lowercase). The output module capitalizes.
TEXT_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789 .,!?'\"-:;"
FIRST_TEXT_ID = 5
FIRST_CONTROL_ID = 64

# Control-token groups. Order is significant: ids are assigned in this order.
CONTROL_GROUPS = {
    "TASK": ["ROOM", "MONSTER", "TREASURE", "NPC", "QUEST", "EVENT", "COMBAT", "ACTION", "FREE"],
    "LOC": ["CRYPT", "CAVERN", "KEEP", "SEWER", "TEMPLE", "MINE", "TOWER", "LABYRINTH"],
    "ROOM": ["CORRIDOR", "BURIAL_CHAMBER", "TREASURE_ROOM", "LAIR", "LIBRARY", "ARMORY",
             "SECRET_CHAMBER", "TRAP_ROOM", "BOSS_ROOM", "MAGIC_CHAMBER", "SHRINE", "PRISON",
             "STAIRS", "HALL"],
    "MON": ["SKELETON", "GOBLIN", "ORC", "SPIDER", "ZOMBIE", "TROLL", "DARK_MAGE", "DRAGON",
            "RAT", "BAT"],
    "MST": ["HEALTHY", "WOUNDED", "DYING", "DEAD"],
    "OBJ": ["DOOR", "CHEST", "SARCOPHAGUS", "ALTAR", "STATUE", "LEVER", "FOUNTAIN", "BOOKSHELF",
            "BONES", "TORCH", "WEAPON_RACK", "PIT", "GATE", "MIRROR", "BRAZIER", "THRONE"],
    "ITEM": ["GOLD", "POTION", "SWORD", "AXE", "MACE", "DAGGER", "BOW", "SHIELD", "ARMOR",
             "HELM", "KEY", "RING", "AMULET", "SCROLL", "WAND", "GEM", "MAP"],
    "ACT": ["LOOK", "EXAMINE", "OPEN", "TAKE", "ATTACK", "TALK", "USE", "SEARCH", "PUSH",
            "PULL", "READ", "DRINK", "FLEE", "REST", "ENTER"],
    "OUT": ["SUCCESS", "FAIL", "LOCKED", "EMPTY", "TRAP", "HIT", "MISS", "CRIT", "KILLED",
            "HURT", "FOUND", "NOTHING"],
    "HP": ["HIGH", "MID", "LOW"],
    "LVL": ["LOW", "MID", "HIGH"],
    "NPC": ["HERMIT", "PRISONER", "GHOST", "MERCHANT", "PRIEST", "DWARF"],
    "MOOD": ["FRIENDLY", "AFRAID", "HOSTILE"],
    "QUEST": ["FIND_RELIC", "SLAY_BEAST", "RESCUE", "ESCAPE", "LIFT_CURSE"],
    "ENV": ["DRIP", "WIND", "RUMBLE", "SCREAM", "CHANT", "SMELL", "LIGHT", "COLD"],
}

# Order in which context tokens appear in a prompt (canonical, so the model sees
# a stable structure). TASK is always first.
CONTEXT_ORDER = ["TASK", "LOC", "ROOM", "NPC", "MOOD", "QUEST", "MON", "MST", "OBJ", "ITEM",
                 "ACT", "OUT", "ENV", "HP", "LVL"]


def build():
    names = list(SPECIALS)
    names += [f"<pad{i}>" for i in range(len(SPECIALS), FIRST_TEXT_ID)]
    names += list(TEXT_CHARS)
    if len(names) > FIRST_CONTROL_ID:
        raise ValueError("too many text symbols")
    names += [f"<unused{i}>" for i in range(len(names), FIRST_CONTROL_ID)]
    for group, values in CONTROL_GROUPS.items():
        names += [f"{group}:{v}" for v in values]
    if len(names) > 256:
        raise ValueError(f"vocabulary has {len(names)} entries; limit is 256")
    return names


TOKENS = build()
VOCAB_SIZE = len(TOKENS)
ID = {name: i for i, name in enumerate(TOKENS)}
CHAR_ID = {c: FIRST_TEXT_ID + i for i, c in enumerate(TEXT_CHARS)}
