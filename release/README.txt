DUNGEON MASTER 64 - AI terminal for the C64 Ultimate
====================================================

DM64.PRG       The AI terminal. Run it from the Ultimate file browser.
DM64GAME.PRG   The dungeon game with the AI Dungeon Master. Narration needs
               the REU model and turbo registers; without them the game
               plays with built-in text.
DM64AI.REU     The storytelling model (format .d64ai 1.1, about 237 KB; writes
               whole letter groups like "the" in one step).
MANIFEST.JSON  Model description (size, SHA-256, tensor layout).

Everything runs on the C64 itself: the model is a 221,760-parameter transformer
and the 6502 code computes every character. No network, no PC.

ULTIMATE MENU SETTINGS (F2)
  C64 and Cartridge Settings
    RAM Expansion Unit = Enabled
    REU Size           = 16 MB
    Command Interface  = Enabled      (optional: lets DM64.PRG load the model
                                       from /USB1/dist/dungeon-master itself)
  U64 Specific Settings
    Turbo Control      = C64U Turbo Registers   (64 MHz; at 1 MHz an answer
                                                 takes over half an hour)

GETTING THE MODEL INTO THE REU (one of)
  - Select DM64AI.REU in the file browser and choose "Load into REU", or
  - enable the Command Interface: DM64.PRG then loads the file itself from
    /USB1/dist/dungeon-master/DM64AI.REU, or
  - set REU Preload to DM64AI.REU (loads at power-on only).
  The model stays in the REU through resets; DM64.PRG checks it (CRC32) on start.

USING THE TERMINAL
  Type a question and press RETURN, e.g. "describe an ancient dungeon".
  F1 random room, F3 monster, F5 treasure, F7 fight: the scene is shown in
  [brackets] and the model narrates it. Scenes give the best text.
  F2 switches creative (varied) / exact (always the same answer).
  RUN/STOP cancels an answer. F8 quits (restores the turbo setting).

SPEED (C64 Ultimate at 64 MHz)
  About 2.7 characters per second for a scene (one measured run; the
  previous engine managed 1.7-1.9). A step writes 1.7 letters on average.
  Each typed character also costs one step before the answer starts; scenes
  are short (6-8 steps).

The model reuses and recombines phrases from its training text, and typed
free-form questions work less well than the F-key scenes.

THE DUNGEON GAME (DM64GAME.PRG)
  Enter a name, pick a class, and find the Amulet of Dawn on level 5.
  WASD / cursor keys / joystick port 2: move and attack (bump into a foe)
  G get   I items (1-8 use or wield)   C character   X look   R rest
  > or .  descend stairs (on a ">" tile)   F1 help
  Locked doors (%) open when you walk into them carrying a key.
  N switches the AI narrator on/off; RUN/STOP skips the current narration.
  Narrated text is light blue; the game adds the numbers (XP, damage, gold).
  The narrator writes word by word and is checked by the game: if it starts
  to name a monster that is not there, it stops with "..." and the game's own
  line follows.
