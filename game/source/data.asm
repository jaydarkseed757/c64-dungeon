; data.asm - game rules data (docs/GAME_DESIGN.md section 4) and fallback texts.

;                rat bat skel gob zomb spid orc troll mage dragon
!zone mon_hp
mon_hp:   !byte   3,  4,   8,  7,  12,   9,  14,  24,  14,  60
!zone mon_atk
mon_atk:  !byte   1,  2,   3,  3,   2,   4,   5,   6,   7,   9
!zone mon_def
mon_def:  !byte   0,  1,   2,  1,   1,   2,   3,   4,   2,   6
!zone mon_dmin
mon_dmin: !byte   1,  1,   1,  1,   2,   2,   2,   3,   3,   4
!zone mon_dmax
mon_dmax: !byte   2,  2,   4,  4,   4,   4,   6,   8,   7,  12
!zone mon_xp
mon_xp:   !byte   2,  3,   6,  5,   8,   9,  14,  25,  22, 100

; four monster kinds per floor (floors 1..5)
!zone floor_mon
floor_mon:
        !byte M_RAT, M_BAT, M_SKELETON, M_GOBLIN
        !byte M_BAT, M_SKELETON, M_ZOMBIE, M_SPIDER
        !byte M_GOBLIN, M_ZOMBIE, M_SPIDER, M_ORC
        !byte M_SPIDER, M_ORC, M_TROLL, M_MAGE
        !byte M_ORC, M_TROLL, M_MAGE, M_ORC

; weapons by item id (0 = fists .. 6 = mace)
!zone wpn_min
wpn_min: !byte 1, 0, 0, 1, 2, 2, 3
!zone wpn_max
wpn_max: !byte 2, 0, 0, 4, 6, 8, 7

; XP needed for levels 2..8
!zone lvl_xp_lo
lvl_xp_lo: !byte <20, <50, <100, <180, <300, <450, <650, $ff
!zone lvl_xp_hi
lvl_xp_hi: !byte >20, >50, >100, >180, >300, >450, >650, $ff

!zone cls_name_lo
cls_name_lo: !byte <s_warrior, <s_rogue, <s_cleric
!zone cls_name_hi
cls_name_hi: !byte >s_warrior, >s_rogue, >s_cleric
!zone s_warrior
s_warrior: !scr "warrior", 0
!zone s_rogue
s_rogue:   !scr "rogue", 0
!zone s_cleric
s_cleric:  !scr "cleric", 0

; one fallback sentence per room type (order of roomt_* / R_* ids)
!zone room_text_lo
room_text_lo: !byte <rt0, <rt1, <rt2, <rt3, <rt4, <rt5, <rt6, <rt7, <rt8, <rt9, <rt10, <rt11, <rt12
!zone room_text_hi
room_text_hi: !byte >rt0, >rt1, >rt2, >rt3, >rt4, >rt5, >rt6, >rt7, >rt8, >rt9, >rt10, >rt11, >rt12
!zone rt0
rt0:  !scr "Broken tables lie overturned.", 0
!zone rt1
rt1:  !scr "Stone coffins line the walls.", 0
!zone rt2
rt2:  !scr "Old coins glint in the dust.", 0
!zone rt3
rt3:  !scr "Gnawed bones cover the floor.", 0
!zone rt4
rt4:  !scr "Rotting books fill the shelves.", 0
!zone rt5
rt5:  !scr "Rusted weapons hang on the walls.", 0
!zone rt6
rt6:  !scr "Dust lies undisturbed here.", 0
!zone rt7
rt7:  !scr "Odd tiles cover the floor.", 0
!zone rt8
rt8:  !scr "Runes glow faintly underfoot.", 0
!zone rt9
rt9:  !scr "Faded offerings lie before an idol.", 0
!zone rt10
rt10: !scr "Rusted cells line the walls.", 0
!zone rt11
rt11: !scr "Worn steps lead down into the dark.", 0
!zone rt12
rt12: !scr "Great pillars rise into darkness.", 0

; environment events on arrival at a floor (ENV:DRIP .. ENV:COLD order)
!zone env_tok
env_tok: !byte TOK_ENV_DRIP, TOK_ENV_WIND, TOK_ENV_RUMBLE, TOK_ENV_SCREAM, TOK_ENV_CHANT, TOK_ENV_SMELL, TOK_ENV_LIGHT, TOK_ENV_COLD
!zone env_text_lo
env_text_lo: !byte <et0, <et1, <et2, <et3, <et4, <et5, <et6, <et7
!zone env_text_hi
env_text_hi: !byte >et0, >et1, >et2, >et3, >et4, >et5, >et6, >et7
!zone et0
et0: !scr "Water drips somewhere in the dark.", 0
!zone et1
et1: !scr "A cold wind moans through the passage.", 0
!zone et2
et2: !scr "The ground trembles. Dust falls.", 0
!zone et3
et3: !scr "A distant scream echoes, then stops.", 0
!zone et4
et4: !scr "Faint chanting drifts from below.", 0
!zone et5
et5: !scr "The stench of decay hangs here.", 0
!zone et6
et6: !scr "A pale glow pulses in the distance.", 0
!zone et7
et7: !scr "Your breath steams in the chill.", 0
