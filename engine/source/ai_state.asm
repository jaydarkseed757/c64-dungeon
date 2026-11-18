; ai_state.asm - engine variables in the STATE area ($c480-$c5df). Equates only.
; AI_PB (the public parameter block) follows at $c5e0 (ai_api.inc).

isq_bit     = STATE + $00   ; 8  isqrt64 scratch
isq_t       = STATE + $08   ; 8
exp_frac    = STATE + $10   ; 2  exp_neg scratch
exp_left    = STATE + $12   ; 3
reu_present = STATE + $15   ; 1
reu_mb      = STATE + $16   ; 1
reu_probe0  = STATE + $17   ; 4  detection scratch
reu_probe1  = STATE + $1b   ; 4
reu_probe2  = STATE + $1f   ; 4
reu_probeB  = STATE + $23   ; 4
crc         = STATE + $27   ; 4  running CRC32
crc_left    = STATE + $2b   ; 4  bytes left (crc_reu)
eng_state   = STATE + $2f   ; 1  0 = cold, 1 = initialized, 2 = model loaded

; model header fields (copied by ai_load)
m_flags     = STATE + $30   ; 2
m_layers    = STATE + $32   ; 1
m_heads     = STATE + $33   ; 1
m_hd        = STATE + $34   ; 1  head_dim
m_d         = STATE + $35   ; 1  d_model (<= 128)
m_ff        = STATE + $36   ; 1  d_ff (1..256, 0 encodes 256)
m_vocab     = STATE + $37   ; 1  vocab (0 encodes 256)
m_ctx       = STATE + $38   ; 1  ctx_len (<= 128)
m_tile      = STATE + $39   ; 1  tile_rows
m_ntens     = STATE + $3a   ; 1
m_dir       = STATE + $3b   ; 4  dir_offset
m_tok       = STATE + $3f   ; 4  tokenizer_offset
m_tokl      = STATE + $43   ; 4  tokenizer_length
m_len       = STATE + $47   ; 4  image_length
m_pcrc      = STATE + $4b   ; 4  payload_crc32
m_eps       = STATE + $4f   ; 4  rms_eps_q32
m_eos       = STATE + $53   ; 1
m_bos       = STATE + $54   ; 1
m_sep       = STATE + $55   ; 1
m_unk       = STATE + $56   ; 1
m_pad       = STATE + $57   ; 1
m_first_ctl = STATE + $58   ; 1
m_vhash     = STATE + $59   ; 4  vocab_hash
m_kvrec     = STATE + $5d   ; 2  KV record bytes = 2d + 2H
dir_seen    = STATE + $5f   ; 9  bitmap of filled directory slots (72 slots)

; runtime
ctx_pos     = STATE + $68   ; 1  tokens in the KV cache
cur_layer   = STATE + $69   ; 1
cur_token   = STATE + $6a   ; 1
want_logits = STATE + $6b   ; 1
gen_phase   = STATE + $6c   ; 1  0 idle, 1 prefill, 2 generate, 3 done
prompt_len  = STATE + $6d   ; 1
prompt_idx  = STATE + $6e   ; 1
pack_shift  = STATE + $6f   ; 1  shift chosen by the last pack
mv_rows     = STATE + $70   ; 2  matvec: rows (16-bit to allow 256)
mv_cols     = STATE + $72   ; 2  matvec: cols
mv_src      = STATE + $74   ; 2  matvec: output vector base
mv_dst      = STATE + $76   ; 2
mv_stride   = STATE + $78   ; 2  output plane stride
mv_slot     = STATE + $7a   ; 1  directory slot
mv_row      = STATE + $7b   ; 2  current row
mv_tile_n   = STATE + $7d   ; 1  rows in current tile
mv_tile_i   = STATE + $7e   ; 1  row within tile
mv_scale    = STATE + $7f   ; 2  address of current row scale in the tile
vec_len     = STATE + $81   ; 2  generic vector length (16-bit)
vsrc        = STATE + $83   ; 2  generic vector source base
vdst        = STATE + $85   ; 2
vstr_s      = STATE + $87   ; 2  source plane stride
vstr_d      = STATE + $89   ; 2  destination plane stride
peak        = STATE + $8b   ; 4
pk_bits     = STATE + $8f   ; 1  15 or 7
rms_root    = STATE + $90   ; 4
gain_ptr    = STATE + $94   ; 2
att_head    = STATE + $96   ; 1
att_t       = STATE + $97   ; 1
att_qs      = STATE + $98   ; 1  q pack shift
att_max     = STATE + $99   ; 4
att_F       = STATE + $9d   ; 4  sum of softmax weights
att_cs      = STATE + $a1   ; 1  coefficient pack shift
att_chunk   = STATE + $a2   ; 1  records in current chunk
att_t0      = STATE + $a3   ; 1  first position in chunk
att_rec     = STATE + $a4   ; 2  pointer to record in tile
kv_base     = STATE + $a6   ; 3  REU address of this layer's KV slice
gen_count   = STATE + $a9   ; 1  characters generated
rng         = STATE + $aa   ; 4
best_tok    = STATE + $ae   ; 1
best_val    = STATE + $af   ; 4
cand_tok    = STATE + $b3   ; 8  top-k candidates
cand_w      = STATE + $bb   ; 32 top-k weights (4 bytes each)
cand_n      = STATE + $db   ; 1
cap_next    = STATE + $dc   ; 1  capitalize next letter
pk_tmp      = STATE + $dd   ; 8
crc_n       = STATE + $e5   ; 2  crc_reu chunk length (reu_xfer clobbers tmp0-tmp4)
pl_lo       = STATE + $e7   ; 4  plane addresses computed by planes_of
pl_hi       = STATE + $eb   ; 4
tile_adr    = STATE + $ef   ; 3  REU address of the current tile
tile_step   = STATE + $f2   ; 3  tile_rows * (cols + 3)
mv_left     = STATE + $f5   ; 2  rows not yet processed
energy      = STATE + $f7   ; 8  rmsnorm sum of squares
vel_sign    = STATE + $ff   ; 1
kv_left     = STATE + $100  ; 1  attention: positions not yet processed
kv_adr      = STATE + $101  ; 3  attention: REU address of next chunk
att_per     = STATE + $104  ; 1  records per chunk
att_cpk     = STATE + $105  ; 8  scratch
head_lo     = STATE + $10d  ; 1  first element of the current head
att_t_end   = STATE + $10e  ; 1  positions in the cache (ctx_pos + 1)
cand_wq0    = STATE + $10f  ; 8  top-k softmax weights, byte planes
cand_wq1    = STATE + $117  ; 8
cand_wq2    = STATE + $11f  ; 8
lp1         = STATE + $127  ; 1  loop counter (sampler)
pool_used   = STATE + $128  ; 1  bytes used in tok_pool
bp_n        = STATE + $129  ; 1  matvec: rows in the current row block
bp_k        = STATE + $12a  ; 1  columns in the current column block
bp_c0       = STATE + $12b  ; 1  first column of the block
bp_col      = STATE + $12c  ; 1  first column of the current group
bp_cleft    = STATE + $12d  ; 2  columns not yet processed
bp_r0       = STATE + $12f  ; 1  first row of the block
bp_i        = STATE + $130  ; 1  row being finished
bp_nz       = STATE + $131  ; 1  group has a nonzero input
bp_mptr     = STATE + $132  ; 2  next mask array - 1
bp_sptr     = STATE + $134  ; 2  scale of the row being finished
bp_len      = STATE + $136  ; 2  DMA length
exp_buf     = STATE + $138  ; 6  E[i], E[i+1] fetched from REU_EXP
STATE_END   = STATE + $13e
!if STATE_END > $c5e0 { !error "engine STATE overflows into AI_PB" }
