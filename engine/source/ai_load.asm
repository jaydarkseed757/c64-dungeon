; ai_load.asm - admit a .d64ai model image that is already in the REU at $000000.
;
; load_model: header -> engine limits -> payload CRC32 -> directory -> tokenizer.
; Returns carry clear on success, or carry set with A = AI_ERR_*.
; Directory slots: 0 tok_emb, 1 pos_emb, 2 final_norm,
;                  8 + layer*8 + (kind-3) for attn_norm..w2 (kinds 3..10).

HDR = REU_TILE                  ; header is fetched into the tile window

!zone load_model
load_model:
        lda #0
        sta reu_adr
        sta reu_adr+1
        sta reu_adr+2
        sta reu_len
        lda #1
        sta reu_len+1           ; 256 bytes
        lda #<HDR
        sta reu_c64
        lda #>HDR
        sta reu_c64+1
        jsr reu_fetch
        bcc +
        lda #AI_ERR_IO
        rts
+       ; signature "D64AI\0"
        ldx #5
-       lda HDR,x
        cmp .magic,x
        beq .lb1
        jmp .bad_sig
.lb1:
        dex
        bpl -
        lda HDR+6
        cmp #1
        bne .badver
        lda HDR+7               ; 1.1+: bitplane matrices (1.0 packages need reconverting)
        bne .verok
.badver:
        lda #AI_ERR_VERSION
        sec
        rts
.verok:       ; header CRC over bytes 0..251
        jsr crc_begin
        lda #<HDR
        sta ptr0
        lda #>HDR
        sta ptr0+1
        lda #252
        sta tmp0
        lda #0
        sta tmp1
        jsr crc_mem
        jsr crc_end
        ldx #3
-       lda crc,x
        cmp HDR+252,x
        bne .bad_crc
        dex
        bpl -
        jsr .copy_fields
        bcs .ret
        ; payload CRC over [256, image_length)
        lda AI_PB_FLAGS
        and #1
        bne .skip_crc
        jsr crc_begin
        lda #0
        sta reu_adr
        sta reu_adr+2
        lda #1
        sta reu_adr+1
        sec
        lda m_len
        sbc #0
        sta crc_left
        lda m_len+1
        sbc #1
        sta crc_left+1
        lda m_len+2
        sbc #0
        sta crc_left+2
        lda m_len+3
        sbc #0
        sta crc_left+3
        jsr crc_reu
        bcs .io
        jsr crc_end
        ldx #3
-       lda crc,x
        cmp m_pcrc,x
        bne .bad_crc
        dex
        bpl -
.skip_crc:
        jsr load_directory
        bcs .ret
        jsr load_tokenizer
        bcs .ret
        jsr model_reset         ; empty context for the new model
        lda #2
        sta eng_state
        lda #AI_OK
        clc
.ret:   rts
.bad_sig:
        lda #AI_ERR_SIGNATURE
        sec
        rts
.bad_crc:
        lda #AI_ERR_CHECKSUM
        sec
        rts
.io:    lda #AI_ERR_IO
        sec
        rts
.magic: !text "D64AI"
        !byte 0

; ---- copy and check header fields against engine v1 limits ----
.copy_fields:
        lda HDR+10
        sta m_flags
        and #%00001011          ; tied, learned positions, attention scale folded
        cmp #%00001011
        beq .lb2
        jmp .arch
.lb2:
        lda HDR+11
        sta m_flags+1
        lda HDR+12              ; arch_id
        cmp #1
        beq .lb3
        jmp .arch
.lb3:
        ldx #24                 ; weight/activation/norm/activation_fn/kv formats all 1
-       lda HDR,x
        cmp #1
        beq .lb4
        jmp .arch
.lb4:
        inx
        cpx #29
        bne -
        lda HDR+13
        bne .lb5
        jmp .arch
.lb5:
        cmp #9
        bcc .lb6
        jmp .arch
.lb6:
        sta m_layers
        lda HDR+14
        bne .lb7
        jmp .arch
.lb7:
        cmp #9
        bcs .arch
        sta m_heads
        lda HDR+15
        sta m_hd
        lda HDR+17              ; d_model <= 128
        bne .arch
        lda HDR+16
        beq .arch
        cmp #129
        bcs .arch
        sta m_d
        ; d == heads * head_dim
        lda #0
        ldx m_heads
-       clc
        adc m_hd
        bcs .arch
        dex
        bne -
        cmp m_d
        bne .arch
        ; d_ff 1..256 (256 stored as 0)
        lda HDR+19
        beq .ff_small
        cmp #1
        bne .arch
        lda HDR+18
        bne .arch
        beq .ff_ok
.ff_small:
        lda HDR+18
        beq .arch
.ff_ok: sta m_ff
        ; vocab 1..256
        lda HDR+21
        beq .v_small
        cmp #1
        bne .arch
        lda HDR+20
        bne .arch
        beq .v_ok
.v_small:
        lda HDR+20
        beq .arch
.v_ok:  sta m_vocab
        ; ctx 1..128 (engine v1 limit; keeps softmax sums below 2^31)
        lda HDR+23
        bne .arch
        lda HDR+22
        beq .arch
        cmp #129
        bcs .arch
        sta m_ctx
        lda HDR+29
        beq .arch
        sta m_tile
        lda HDR+30
        sta m_ntens
        jmp .more
.arch:  lda #AI_ERR_ARCH
        sec
        rts
.more:
        ldx #3
-       lda HDR+32,x
        sta m_dir,x
        lda HDR+36,x
        sta m_tok,x
        lda HDR+40,x
        sta m_tokl,x
        lda HDR+52,x
        sta m_len,x
        lda HDR+56,x
        sta m_pcrc,x
        lda HDR+60,x
        sta m_eps,x
        lda HDR+76,x
        sta m_vhash,x
        dex
        bpl -
        lda HDR+68
        sta m_pad
        lda HDR+69
        sta m_bos
        lda HDR+70
        sta m_eos
        lda HDR+71
        sta m_sep
        lda HDR+72
        sta m_unk
        lda HDR+73
        sta m_first_ctl
        ; image must lie inside the model region: 256 < length <= $100000
        lda m_len+3
        bne .arch
        lda m_len+2
        cmp #$10
        bcc +
        bne .arch
        lda m_len+1
        ora m_len
        bne .arch
+       ; tokenizer section must fit the tile window
        lda m_tokl+3
        ora m_tokl+2
        bne .arch
        lda m_tokl+1
        cmp #>REU_TILE_SIZE
        bcs .arch
        ; tile must fit the window: tile_rows * (max(d, ff) + 3) <= 8192
        lda m_ff
        beq .big                ; 256
        cmp m_d
        bcs +
        lda m_d
+       clc
        adc #3
        sta mA
        lda #0
        adc #0
        sta mA+1
        jmp +
.big:   lda #3
        sta mA
        lda #1
        sta mA+1
+       lda m_tile
        sta mB
        lda #2
        sta mLenA
        lda #1
        sta mLenB
        jsr umul
        lda mP+2
        bne .arch2
        lda mP+1
        cmp #$20
        bcc +
        bne .arch2
        lda mP
        bne .arch2
+       ; expected vocab hash (host may require a specific vocabulary)
        lda AI_PB_EXPECT_HASH
        ora AI_PB_EXPECT_HASH+1
        ora AI_PB_EXPECT_HASH+2
        ora AI_PB_EXPECT_HASH+3
        beq +
        ldx #3
-       lda AI_PB_EXPECT_HASH,x
        cmp m_vhash,x
        bne .vocab
        dex
        bpl -
+       ; KV record = 2d + 2H
        lda m_d
        clc
        adc m_heads
        sta m_kvrec
        lda #0
        adc #0
        sta m_kvrec+1
        asl m_kvrec
        rol m_kvrec+1
        clc
        rts
.arch2: lda #AI_ERR_ARCH
        sec
        rts
.vocab: lda #AI_ERR_VOCAB
        sec
        rts

; ---------------------------------------------------------------- directory
!zone load_directory
load_directory:
        ldx #8
        lda #0
-       sta dir_seen,x
        dex
        bpl -
        ; fetch tensor_count * 16 bytes from dir_offset
        lda m_dir
        sta reu_adr
        lda m_dir+1
        sta reu_adr+1
        lda m_dir+2
        sta reu_adr+2
        lda m_ntens
        sta reu_len
        lda #0
        sta reu_len+1
        ldx #4
-       asl reu_len
        rol reu_len+1
        dex
        bne -
        lda #<REU_TILE
        sta reu_c64
        sta ptr1
        lda #>REU_TILE
        sta reu_c64+1
        sta ptr1+1
        jsr reu_fetch
        bcc +
        lda #AI_ERR_IO
        rts
+       lda m_ntens
        sta cnt1
        bne .lbx5_369
        jmp .check_all
.lbx5_369:
.entry:
        ldy #0
        lda (ptr1),y            ; kind
        sta tmp2
        iny
        lda (ptr1),y            ; layer
        sta tmp3
        jsr .slot_and_shape     ; -> X = slot, mA/mA+1 rows, mA+2/mA+3 cols expected
        bcc .lb8
        jmp .bad
.lb8:
        ldy #4
        lda (ptr1),y
        cmp mA
        beq .lbx4_384
        jmp .bad
.lbx4_384:
        iny
        lda (ptr1),y
        cmp mA+1
        beq .lbx3_388
        jmp .bad
.lbx3_388:
        iny
        lda (ptr1),y
        cmp mA+2
        beq .lbx2_392
        jmp .bad
.lbx2_392:
        iny
        lda (ptr1),y
        cmp mA+3
        beq .lbx1_396
        jmp .bad
.lbx1_396:
        ; layout: 3 for vectors (cols = 1), 1 for pos_emb (slot 1), 2 for all other matrices
        ldy #3
        lda mA+2
        cmp #1
        bne +
        lda mA+3
        bne +
        lda #3
        bne .lay
+       lda #2
        cpx #1
        bne .lay
        lda #1
.lay:   cmp (ptr1),y
        bne .bad
        ; mark slot, reject duplicates
        txa
        lsr
        lsr
        lsr
        tay
        txa
        and #7
        sta tmp4
        stx tmp2
        ldx tmp4
        lda bit_tab,x
        and dir_seen,y
        bne .bad
        lda bit_tab,x
        ora dir_seen,y
        sta dir_seen,y
        ldx tmp2
        ; store REU offset (must be < $100000)
        ldy #11
        lda (ptr1),y
        bne .bad
        dey
        lda (ptr1),y
        cmp #$10
        bcs .bad
        sta dir_hi,x
        dey
        lda (ptr1),y
        sta dir_mid,x
        dey
        lda (ptr1),y
        sta dir_lo,x
        clc
        lda ptr1
        adc #16
        sta ptr1
        bcc +
        inc ptr1+1
+       dec cnt1
        beq .check_all
        jmp .entry
.check_all:
        ; every required slot present: 0,1,2 and 8 + l*8 + 0..7 for each layer
        lda dir_seen
        and #7
        cmp #7
        bne .bad
        ldx m_layers
        ldy #1
-       lda dir_seen,y
        cmp #$ff
        bne .bad
        iny
        dex
        bne -
        clc
        rts
.bad:   lda #AI_ERR_ARCH
        sec
        rts

; tmp2 = kind, tmp3 = layer -> X = slot; expected rows in mA (16-bit), cols in mA+2.
.slot_and_shape:
        lda tmp2
        cmp #1
        bne +
        ldx #0
        lda m_vocab
        jsr .rows_a
        jmp .cols_d
+       cmp #2
        bne +
        ldx #1
        lda m_ctx
        jsr .rows_a
        jmp .cols_d
+       cmp #11
        bne +
        ldx #2
        jmp .vector
+       cmp #3
        bcc .no
        cmp #11
        bcs .no
        lda tmp3
        cmp m_layers
        bcs .no
        asl
        asl
        asl
        clc
        adc tmp2
        adc #8-3
        tax
        lda tmp2
        cmp #3
        beq .vector
        cmp #8
        beq .vector
        cmp #9
        beq .w1
        cmp #10
        beq .w2
        lda m_d                 ; wq, wk, wv, wo: d x d
        jsr .rows_a
        jmp .cols_d
.w1:    lda m_ff
        jsr .rows_a
        jmp .cols_d
.w2:    lda m_d
        jsr .rows_a
        lda m_ff
        jmp .cols_a
.vector:
        lda m_d
        jsr .rows_a
        lda #1
        sta mA+2
        lda #0
        sta mA+3
        clc
        rts
.cols_d:
        lda m_d
.cols_a:                        ; A = cols (0 means 256)
        sta mA+2
        lda #0
        sta mA+3
        lda mA+2
        bne +
        inc mA+3
+       clc
        rts
.rows_a:                        ; A = rows (0 means 256)
        sta mA
        lda #0
        sta mA+1
        lda mA
        bne +
        inc mA+1
+       rts
.no:    sec
        rts

; ---------------------------------------------------------------- tokenizer
!zone load_tokenizer
load_tokenizer:
        lda m_tok
        sta reu_adr
        lda m_tok+1
        sta reu_adr+1
        lda m_tok+2
        sta reu_adr+2
        lda m_tokl
        sta reu_len
        lda m_tokl+1
        sta reu_len+1
        lda #<REU_TILE
        sta reu_c64
        lda #>REU_TILE
        sta reu_c64+1
        jsr reu_fetch           ; clobbers tmp0-tmp4: set up the CRC afterwards
        bcc +
        lda #AI_ERR_IO
        rts
+       lda m_tokl
        sta tmp0
        lda m_tokl+1
        sta tmp1
        lda #<REU_TILE
        sta ptr0
        lda #>REU_TILE
        sta ptr0+1
        jsr crc_begin
        jsr crc_mem
        jsr crc_end
        ldx #3
-       lda crc,x
        cmp m_vhash,x
        beq .lbx5_573
        jmp .bad
.lbx5_573:
        dex
        bpl -
        ; count must equal vocab
        lda REU_TILE
        cmp m_vocab
        beq .lbx4_579
        jmp .bad
.lbx4_579:
        lda REU_TILE+1
        beq +
        cmp #1
        beq .lbx3_583
        jmp .bad
.lbx3_583:
        lda m_vocab             ; 256 is stored as 0
        beq .lbx2_585
        jmp .bad
.lbx2_585:
+       ; input table
        ldx #0
-       lda REU_TILE+2,x
        sta tok_in,x
        inx
        bne -
        ; entries
        lda #0
        sta pool_used
        lda #<(REU_TILE+258)
        sta ptr0
        lda #>(REU_TILE+258)
        sta ptr0+1
        ldx #0                  ; token id
.tok:   ldy #0
        lda (ptr0),y            ; kind
        sta tmp2
        iny
        lda (ptr0),y            ; len
        sta tmp3
        lda #0
        sta tok_emit,x
        sta tok_disp,x
        sta tok_len,x
        lda tmp2
        cmp #1
        bne .not_text
        lda tmp3
        beq .not_text
        cmp #1
        bne .multi
        iny
        lda (ptr0),y
        sta tok_disp,x
        lda #1
        sta tok_len,x
        sta tok_emit,x
        jmp .not_text
.multi: ; letter group: copy its PETSCII string into the pool
        clc
        adc pool_used
        bcs .pool_full
        cmp #TOK_POOL_SIZE+1
        bcs .pool_full
        lda pool_used
        sta tok_off,x
        lda tmp3
        sta tok_len,x
        lda #1
        sta tok_emit,x
        stx tmp4
        ldy #2
-       lda (ptr0),y
        ldx pool_used
        sta tok_pool,x
        inc pool_used
        iny
        tya
        sec
        sbc #2
        cmp tmp3
        bne -
        ldx tmp4
.not_text:
        cpx m_eos
        bne +
        lda #1
        sta tok_emit,x
+       ; advance by 2 + len
        lda tmp3
        clc
        adc #2
        adc ptr0
        sta ptr0
        bcc +
        inc ptr0+1
+       inx
        cpx m_vocab
        beq .lbx1_664
        jmp .tok
.lbx1_664:
        clc
        rts
.bad:   lda #AI_ERR_VOCAB
        sec
        rts
.pool_full:                     ; letter groups exceed the engine's 240-byte pool
        lda #AI_ERR_ARCH
        sec
        rts
