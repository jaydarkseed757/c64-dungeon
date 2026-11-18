; DM64 engine memory map (engine v1). See docs/MEMORY_MAP.md.
; Every fixed address the engine uses is defined here and nowhere else.

; ------------------------------------------------------------ zero page $10-$4F
mA      = $10           ; 8  multiply operand A / dividend / shift operand
mB      = $18           ; 4  multiply operand B / divisor
mP      = $1c           ; 8  product
mR      = $24           ; 5  division remainder
mT      = $29           ; 4  scratch
mI      = $2d           ; 1  loop index
mJ      = $2e           ; 1  loop index
mLenA   = $2f           ; 1  multiply: bytes in A
mLenB   = $30           ; 1  multiply: bytes in B
mSign   = $31           ; 1  sign of current operation (bit 7)
m8lo    = $32           ; 1  8x8 product low byte
m8hi    = $33           ; 1  8x8 product high byte
ptr0    = $34           ; 2
ptr1    = $36           ; 2
ptr2    = $38           ; 2
acc     = $3a           ; 4  dot-product accumulator (signed 32-bit)
prod    = $3e           ; 3  partial product
psgn    = $41           ; 1  product sign
reu_c64 = $42           ; 2  REU request: C64 address
reu_adr = $44           ; 3  REU request: REU address
reu_len = $47           ; 2  REU request: length (0 = no-op)
cnt0    = $49           ; 1
cnt1    = $4a           ; 1
tmp0    = $4b           ; 1
tmp1    = $4c           ; 1
tmp2    = $4d           ; 1
tmp3    = $4e           ; 1
tmp4    = $4f           ; 1

; ------------------------------------------------------------ engine RAM
ENGINE_BASE = $2000     ; code + constant tables, $2000-$5fff

; Q16.16 vectors as four byte planes (plane b of vector V at V + b*stride).
VSTRIDE = 128           ; d_model vectors (engine limit d_model <= 128)
HSTRIDE = 256           ; d_ff and vocab vectors
vec_x   = $6000         ; residual
vec_n   = $6200         ; norm output
vec_q   = $6400
vec_k   = $6600
vec_v   = $6800
vec_a   = $6a00         ; attention output
vec_o   = $6c00         ; projection output
vec_h   = $7000         ; feed-forward hidden ($7000-$73ff)
vec_l   = $7400         ; logits ($7400-$77ff); also attention scores
; packed int16 dot-product input: magnitude planes + sign ($00 / $80)
pk_lo   = $6e00
pk_hi   = $6f00
pk_sg   = $7800
; attention
att_f0  = $7900         ; softmax weights Q0.24, 3 planes x 128 ($7900-$7a7f)
att_f1  = $7980
att_f2  = $7a00
att_c0  = $7a80         ; packed coefficients lo/hi ($7a80-$7b7f)
att_c1  = $7b00
att_ve  = $7b80         ; V exponent per position (128)
kv_rec  = $7c00         ; KV record being built: K8[d] V8[d] ke[H] ve[H] (<= 272)
tok_pool = $7d10        ; strings of multi-letter text tokens ($7d10-$7dff, 240 bytes)
TOK_POOL_SIZE = $f0
tok_len  = $7e00        ; display length per token (0 = none, 1 = tok_disp, >1 = pool)
tok_off  = $7f00        ; pool offset per multi-letter token

REU_TILE = $8000        ; DMA window, 8 KiB
REU_TILE_SIZE = $1c00   ; DMA users other than matvec stay below $9c00 (7 KiB)

; bitplane matvec (format 1.1) work areas inside the window, see ai_matvec.asm
BP_TILE  = $8000        ; masks of one block, <= 64 rows x 64 columns = 4096 bytes
BP_SCALE = $9000        ; row scales of the current row block (<= 192)
BP_ACC   = $9101        ; 24 plane accumulators (8 planes x 3 bytes) x 64 rows, signed 24-bit
BP_R3    = $9701        ; top byte of the combined 32-bit row sums (64)
BP_V0    = $9741        ; the 8 signed inputs of the current group, 3 byte planes
BP_V1    = $9749
BP_V2    = $9751
BP_SS0   = $9800        ; subset sums of the current group (256 x signed 24-bit)
BP_SS1   = $9900
BP_SS2   = $9a00
EMB_W    = $9b00        ; decoded embedding row (<= 128)
EMB_S    = $9b80        ; its row scale (3)
BP_CODE  = $9c00        ; generated row kernel (255 bytes), rebuilt by each matvec
BP_ZERO  = $9d00        ; generated accumulator-clearing kernel

; exp table: assembled into vector RAM (free until the first model step) and copied to
; the REU by engine_init; exp_neg fetches the two entries it needs by DMA.
EXP_DATA = $6000        ; 1025 x 3 bytes in the host PRG ($6000-$6c02)
REU_EXP  = $1f0000      ; REU copy (the engine requires >= 2 MB)

; RAM under BASIC ROM (requires $01 = $36)
sq1lo   = $a000         ; quarter squares floor(i^2/4), i = 0..511
sq1hi   = $a200
sq2lo   = $a400         ; floor((i-255)^2/4)
sq2hi   = $a600
crc_t0  = $a800         ; CRC32 table, four byte planes
crc_t1  = $a900
crc_t2  = $aa00
crc_t3  = $ab00
absval  = $ac00         ; |signed byte| table (256)
; $ad00-$bfff free (reserved for subset-sum optimization)

; engine tables and state ($c000-$c7ff); host owns $c800-$cfff
tok_emit = $c000        ; 1 if token may be emitted as text (or EOS), else 0
tok_disp = $c100        ; PETSCII display byte for text tokens
tok_in   = $c200        ; PETSCII keyboard code -> token id
dir_lo   = $c300        ; tensor REU offsets, index = slot (see ai_load.asm)
dir_mid  = $c380
dir_hi   = $c400
STATE    = $c480        ; engine variables ($c480-$c5ff), see ai_state.asm
prompt_buf = $c600      ; token ids of the current prompt (<= 255)
out_buf  = $c700        ; output: length byte + PETSCII text
