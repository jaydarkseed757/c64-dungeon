; bench.asm - Dungeon Master 64 benchmark (BENCH.PRG).
;
; Runs the on-device model for 5 minutes (cfg_secs) on a fixed list of game-style
; requests (bench_tables.asm, from tools/bench.py) with the game's settings:
; temperature 0.8, top-8, at most 48 tokens, seed = request number. Shows live
; statistics and a final summary; tools/bench.py reads the results block at $C800
; and checks the CRC of all generated tokens against python/reference_int.py.
;
; Timing:
;   wall clock   CIA1 time-of-day clock (tenths); falls back to the CIA2 cycle
;                counter (taken as 1 MHz) if the TOD clock does not run
;   steps        CIA2 timers A+B cascaded: a 32-bit count of CIA cycles (the CIA
;                stays at 1 MHz under the C64U turbo), converted to ms with the
;                CIA clock rate measured against the TOD clock
; Each AI_GENERATE_STEP call is one forward pass: a prompt token while the context
; position is below the prompt length, else a generated token. The final call of a
; request (end of text) runs no forward pass and is not timed.
;
; Build: make bench -> bench/build/bench.prg
; Memory: this code $0801-$1fff, engine $2000-, bench data after the engine,
; host RAM $c800-$caff.

!cpu 6510
!source "engine/include/memory.inc"
!source "engine/include/ai_api.inc"

SCREEN   = $0400
COLRAM   = $d800
GETIN    = $ffe4
STOP     = $ffe1
JIFFY    = $a0

C_TITLE  = 7
C_LABEL  = 15
C_VALUE  = 1
C_TEXT   = 13
C_CTX    = 3
C_ERR    = 10
C_STAT   = 12

ROW_TXT0 = 13               ; generated text rows 13-20
ROW_TXT1 = 20
ROW_MSG  = 22

; zero page (host range $50-$8f)
scr      = $50
colp     = $52
str      = $54
t0       = $56
t1       = $57
t2       = $58
t3       = $59

; ---------------------------------------------------------------- results block
RB       = $c800            ; see tools/bench.py
rb_phase = RB+4
rb_status = RB+5
rb_req   = RB+6             ; 2
rb_ptok  = RB+8             ; 4 prompt tokens
rb_pcyc  = RB+12            ; 4
rb_gtok  = RB+16            ; 4 generated tokens (forward passes)
rb_gcyc  = RB+20            ; 4
rb_min   = RB+24            ; 4
rb_max   = RB+28            ; 4
rb_last  = RB+32            ; 4
rb_chars = RB+36            ; 4
rb_crc   = RB+40            ; 4 (final value)
rb_tenths = RB+44           ; 2
rb_clock = RB+46            ; 1 TOD, 2 CIA
rb_turbo = RB+47
rb_cia   = RB+48            ; 4
rb_khz   = RB+52            ; 2
RB_END   = RB+64

; work variables ($c900-)
crc_run  = $c900            ; 4 CRC32 register over completed requests
crc_cur  = $c904            ; 4 CRC32 register including the current request
now      = $c908            ; 4 CIA cycles since the start
tbefore  = $c90c            ; 4
dt       = $c910            ; 4
num      = $c914            ; 4 number to format / dividend -> quotient
dvs      = $c918            ; 4 divisor
rem      = $c91c            ; 4 remainder
mtmp     = $c920            ; 4
limit    = $c924            ; 2 tenths at which the run ends
req_k    = $c926            ; 2 request number (seed)
req_i    = $c928            ; table index
plen     = $c929            ; prompt length of the current request
pos_b    = $c92a            ; context position before a step
cur_row  = $c92b
cur_col  = $c92c
shown    = $c92d            ; out_buf characters shown
dp       = $c92e            ; decimals for fmt
ended    = $c92f            ; 1 = time or RUN/STOP ended the run
tens_v   = $c930            ; 2 current tenths
turbo_ok = $c932            ; 1 = 64 MHz
khz_nom  = $c933            ; 2 nominal CIA clock (kHz) from the KERNAL PAL flag
numbuf   = $c940            ; 16 formatted number (screen codes)

* = $0801
        !word .bas_end, 10
        !byte $9e
        !text "2061"
        !byte 0
.bas_end: !word 0
* = $080d
        jmp start

model_path:
        !byte .path_end - .path
.path:  !text "/USB1/dist/dungeon-master/DM64AI.REU"
.path_end:

; configuration (tests patch these in RAM before running)
cfg_secs:    !word 300          ; run length in seconds
cfg_max_req: !word 0            ; stop after this many requests (0 = no limit)
cfg_max_tok: !byte 48           ; tokens per request (the game's limit)

start:
        sei
        lda #$36
        sta $01
        ldx #$ff
        txs
        cld
        ldx #RB_END-RB-1
        lda #0
-       sta RB,x
        dex
        bpl -
        lda #"D"
        sta RB
        lda #"M"
        sta RB+1
        lda #"B"
        sta RB+2
        lda #"1"
        sta RB+3
        lda #$ff
        sta $cc
        cli
        jsr init_screen

; ---------------------------------------------------------------- boot
        lda #<m_init
        ldx #>m_init
        jsr msg
        jsr AI_INIT
        bcc +
        jmp fail
+       jsr turbo_on
        lda #0
        rol                     ; carry clear = 64 MHz
        eor #1
        sta turbo_ok
        ldx #3
-       lda vocab_hash_bytes,x
        sta AI_PB_EXPECT_HASH,x
        dex
        bpl -
        lda #<m_check
        ldx #>m_check
        jsr msg
        jsr AI_LOAD_MODEL
        bcc .ok
        jsr uci_present         ; no usable model in the REU: load the USB file
        bcc +
        lda #AI_ERR_NO_MODEL
        jmp fail
+       lda #<m_file
        ldx #>m_file
        jsr msg
        ldx #<model_path
        ldy #>model_path
        jsr uci_load_model
        bcc +
        jmp fail
+       jsr AI_LOAD_MODEL
        bcc .ok
        jmp fail
.ok:    jsr draw_frame

; ---------------------------------------------------------------- run
run:
        ldx #RB_END-RB-5        ; clear the statistics (keep the signature)
        lda #0
-       sta RB+4,x
        dex
        bpl -
        lda turbo_ok
        sta rb_turbo
        lda #0
        sta req_k
        sta req_k+1
        sta req_i
        sta ended
        lda #$ff
        ldx #3
-       sta crc_run,x
        sta crc_cur,x
        sta rb_min,x
        dex
        bpl -
        ; limit = cfg_secs * 10
        lda cfg_secs
        sta limit
        lda cfg_secs+1
        sta limit+1
        asl limit
        rol limit+1             ; x2
        lda limit
        ldx limit+1
        asl limit
        rol limit+1
        asl limit
        rol limit+1             ; x8
        clc
        adc limit
        sta limit
        txa
        adc limit+1
        sta limit+1             ; x10
        jsr clock_start
        lda #1
        sta rb_phase
        lda #<m_running
        ldx #>m_running
        jsr status_line

next_request:
        lda cfg_max_req
        ora cfg_max_req+1
        beq +
        lda rb_req
        cmp cfg_max_req
        lda rb_req+1
        sbc cfg_max_req+1
        bcc +
        jmp finish
+       ldx req_i
        lda req_lo,x
        sta str
        lda req_hi,x
        sta str+1
        ldy #0
        lda (str),y
        sta plen
        lda cfg_max_tok
        sta AI_PB_MAX_CHARS
        lda #<320
        sta AI_PB_INV_TEMP
        lda #>320
        sta AI_PB_INV_TEMP+1
        lda #8
        sta AI_PB_TOP_K
        lda req_k
        sta AI_PB_SEED
        lda req_k+1
        sta AI_PB_SEED+1
        lda #$5a
        sta AI_PB_SEED+2
        lda #$a5
        sta AI_PB_SEED+3
        ldx str
        ldy str+1
        jsr AI_SET_PROMPT
        bcc +
        jmp fail
+       ldx #3
-       lda crc_run,x
        sta crc_cur,x
        dex
        bpl -
        jsr show_request

.step:  jsr tick                ; time, RUN/STOP, screen
        lda ended
        beq +
        jmp finish              ; the unfinished request is not counted
+       lda AI_PB_POS
        sta pos_b
        jsr cia_now
        ldx #3
-       lda now,x
        sta tbefore,x
        dex
        bpl -
        jsr AI_GENERATE_STEP
        bcc +
        jmp fail
+       pha
        jsr cia_now
        sec                     ; dt = now - tbefore
        lda now
        sbc tbefore
        sta dt
        lda now+1
        sbc tbefore+1
        sta dt+1
        lda now+2
        sbc tbefore+2
        sta dt+2
        lda now+3
        sbc tbefore+3
        sta dt+3
        lda pos_b
        cmp plen
        bcs .gen
        ; a prompt token
        pla
        inc rb_ptok
        bne +
        inc rb_ptok+1
+       ldx #rb_pcyc-RB
        jsr add_dt
        jmp .shown
.gen:   lda AI_PB_LAST_TOKEN    ; every sampled token enters the CRC
        jsr crc_byte
        pla
        cmp #AI_STEP_DONE
        beq .done               ; the final call runs no forward pass
        inc rb_gtok
        bne +
        inc rb_gtok+1
+       ldx #rb_gcyc-RB
        jsr add_dt
        ldx #3
-       lda dt,x
        sta rb_last,x
        dex
        bpl -
        ldx #rb_min-RB          ; min = dt if dt < min
        jsr cmp_dt
        bcs +
        ldx #3
-       lda dt,x
        sta rb_min,x
        dex
        bpl -
+       ldx #rb_max-RB          ; max = dt if dt >= max
        jsr cmp_dt
        bcc +
        ldx #3
-       lda dt,x
        sta rb_max,x
        dex
        bpl -
+
.shown: jsr stream
        jmp .step
.done:  jsr stream
        ldx #3
-       lda crc_cur,x
        sta crc_run,x
        eor #$ff
        sta rb_crc,x
        dex
        bpl -
        clc
        lda rb_chars
        adc out_buf
        sta rb_chars
        bcc +
        inc rb_chars+1
        bne +
        inc rb_chars+2
+       inc rb_req
        bne +
        inc rb_req+1
+       inc req_k
        bne +
        inc req_k+1
+       ldx req_i
        inx
        cpx #N_REQ
        bne +
        ldx #0
+       stx req_i
        jmp next_request

finish:
        jsr tick_stats
        jsr summary
        lda #2
        sta rb_phase
        lda #<m_done
        ldx #>m_done
        jsr status_line
bench_done:                     ; tests stop here
        jsr GETIN
        beq bench_done
        cmp #13
        bne +
        jsr clear_text
        jmp run
+       cmp #$8c                ; F8: quit (turbo back as found)
        bne bench_done
        jsr turbo_restore
        jmp ($fffc)

fail:                           ; A = AI_* error
        sta rb_status
        pha
        lda #3
        sta rb_phase
        lda #<m_fail
        ldx #>m_fail
        jsr status_line
        pla
        ldx #ROW_MSG
        jsr row_ptr
        jsr hex8_at30
-       jmp -

; ---------------------------------------------------------------- per step
; tick: wall clock, RUN/STOP, statistics on screen
tick:
        jsr tick_stats
        lda tens_v              ; time up?
        cmp limit
        lda tens_v+1
        sbc limit+1
        bcc +
        lda #1
        sta ended
+       jsr STOP
        bne +
        lda #1
        sta ended
+       rts

tick_stats:
        jsr clock_read          ; -> tens_v, now, rb_cia, rb_khz
        jsr draw_stats
        rts

add_dt:                         ; RB+X (4 bytes) += dt
        clc
        lda RB,x
        adc dt
        sta RB,x
        lda RB+1,x
        adc dt+1
        sta RB+1,x
        lda RB+2,x
        adc dt+2
        sta RB+2,x
        lda RB+3,x
        adc dt+3
        sta RB+3,x
        rts

cmp_dt:                         ; carry = dt >= RB+X (unsigned 32-bit)
        lda dt
        cmp RB,x
        lda dt+1
        sbc RB+1,x
        lda dt+2
        sbc RB+2,x
        lda dt+3
        sbc RB+3,x
        rts

crc_byte:                       ; crc_cur = CRC32 step over A (zlib polynomial)
        eor crc_cur
        sta crc_cur
        ldx #8
-       lsr crc_cur+3
        ror crc_cur+2
        ror crc_cur+1
        ror crc_cur
        bcc +
        lda crc_cur
        eor #$20
        sta crc_cur
        lda crc_cur+1
        eor #$83
        sta crc_cur+1
        lda crc_cur+2
        eor #$b8
        sta crc_cur+2
        lda crc_cur+3
        eor #$ed
        sta crc_cur+3
+       dex
        bne -
        rts

; ---------------------------------------------------------------- clocks
clock_start:
        lda #$7f                ; CIA2: no interrupts (no NMIs from the timers)
        sta $dd0d
        lda #0
        sta $dd0e
        sta $dd0f
        lda #$ff
        sta $dd04
        sta $dd05
        sta $dd06
        sta $dd07
        lda #%01010001          ; timer B: count timer A underflows, load, start
        sta $dd0f
        lda #%00010001          ; timer A: count CIA cycles, load, start
        sta $dd0e
        lda $dc0e               ; TOD input: 50 Hz on PAL machines, 60 Hz on NTSC
        and #$7f                ; (the KERNAL leaves 60 Hz, so PAL clocks ran slow)
        ldx $02a6               ; KERNAL: 1 = PAL
        beq +
        ora #$80
+       sta $dc0e
        lda #<985               ; nominal CIA clock: PAL 985 kHz, NTSC 1023 kHz
        ldx #>985
        ldy $02a6
        bne +
        lda #<1023
        ldx #>1023
+       sta khz_nom
        stx khz_nom+1
        lda $dc0f               ; CIA1 TOD: write the time, not the alarm
        and #$7f
        sta $dc0f
        lda #0
        sta $dc0b               ; hours (stops the clock until tenths are written)
        sta $dc0a
        sta $dc09
        sta $dc08               ; tenths: the clock runs from 0:00:00.0
        lda #1
        sta rb_clock
        rts

cia_now:                        ; now = CIA cycles since clock_start
-       lda $dd06
        sta now+2
        lda $dd07
        sta now+3
        lda $dd05
        sta now+1
        lda $dd04
        sta now
        lda $dd06
        cmp now+2
        bne -
        ldx #3
-       lda now,x
        eor #$ff
        sta now,x
        dex
        bpl -
        rts

; clock_read -> tens_v (tenths since start), rb_tenths, rb_cia, rb_khz
clock_read:
        jsr cia_now
        ldx #3
-       lda now,x
        sta rb_cia,x
        dex
        bpl -
        lda rb_clock
        cmp #1
        bne .cia
        lda $dc0b               ; latch, then minutes, seconds, tenths (unlatches)
        lda $dc0a
        sta t0
        lda $dc09
        sta t1
        lda $dc08
        sta t2
        ora t1
        ora t0
        bne .tod
        lda now+3               ; TOD still 0:00.0 after 3 million cycles: it
        bne .dead               ; does not run here, use the CIA count
        lda now+2
        cmp #$2e                ; $2e0000 = 3.0 million
        bcc .tod
.dead:  lda #2
        sta rb_clock
        jmp .cia
.tod:   lda t0                  ; tenths = (min*60 + sec)*10 + tenths (BCD)
        jsr bcd
        sta num
        lda #0
        sta num+1
        sta num+2
        sta num+3
        lda #60
        jsr mul_num8
        lda t1
        jsr bcd
        jsr add_num8
        lda #10
        jsr mul_num8
        lda t2
        and #$0f
        jsr add_num8
        jmp .store
.cia:   lda khz_nom             ; tenths = cycles / (nominal kHz * 100)
        sta num
        lda khz_nom+1
        sta num+1
        lda #0
        sta num+2
        sta num+3
        lda #100
        jsr mul_num8
        ldx #3
-       lda num,x
        sta dvs,x
        lda now,x
        sta num,x
        dex
        bpl -
        jsr div32
.store: lda num
        sta tens_v
        sta rb_tenths
        lda num+1
        sta tens_v+1
        sta rb_tenths+1
        ; kHz = cycles / (tenths * 100) once 5 s have passed on the TOD clock
        lda khz_nom
        sta rb_khz
        lda khz_nom+1
        sta rb_khz+1
        lda rb_clock
        cmp #1
        bne .nokhz
        lda tens_v+1
        bne .khz
        lda tens_v
        cmp #50
        bcc .nokhz
.khz:   lda tens_v
        sta num
        lda tens_v+1
        sta num+1
        lda #0
        sta num+2
        sta num+3
        lda #100
        jsr mul_num8
        ldx #3
-       lda num,x
        sta dvs,x
        lda now,x
        sta num,x
        dex
        bpl -
        jsr div32               ; num = measured kHz
        lda num+2
        ora num+3
        bne .bad
        lda num                 ; plausible: 900 <= kHz < 1100
        cmp #<900
        lda num+1
        sbc #>900
        bcc .bad
        lda num
        cmp #<1100
        lda num+1
        sbc #>1100
        bcs .bad
        lda num
        sta rb_khz
        lda num+1
        sta rb_khz+1
.nokhz: rts
.bad:   lda #2                  ; the TOD clock runs at the wrong rate: use the CIA
        sta rb_clock
        jmp clock_read

bcd:                            ; A (BCD) -> binary
        pha
        and #$0f
        sta t3
        pla
        lsr
        lsr
        lsr
        lsr
        tax
        lda t3
-       dex
        bmi +
        clc
        adc #10
        jmp -
+       rts

; ---------------------------------------------------------------- 32-bit math
add_num8:                       ; num += A
        clc
        adc num
        sta num
        bcc +
        inc num+1
        bne +
        inc num+2
        bne +
        inc num+3
+       rts

mul_num8:                       ; num *= A (low 32 bits)
        sta t3
        ldx #3
-       lda num,x
        sta mtmp,x
        lda #0
        sta num,x
        dex
        bpl -
.bit:   lsr t3
        bcc .skip
        clc
        lda num
        adc mtmp
        sta num
        lda num+1
        adc mtmp+1
        sta num+1
        lda num+2
        adc mtmp+2
        sta num+2
        lda num+3
        adc mtmp+3
        sta num+3
.skip:  asl mtmp
        rol mtmp+1
        rol mtmp+2
        rol mtmp+3
        lda t3
        bne .bit
        rts

div32:                          ; num = num / dvs, rem = num % dvs (dvs = 0: num = 0)
        lda dvs
        ora dvs+1
        ora dvs+2
        ora dvs+3
        bne +
        sta num
        sta num+1
        sta num+2
        sta num+3
        rts
+       lda #0
        sta rem
        sta rem+1
        sta rem+2
        sta rem+3
        ldx #32
.l:     asl num
        rol num+1
        rol num+2
        rol num+3
        rol rem
        rol rem+1
        rol rem+2
        rol rem+3
        sec
        lda rem
        sbc dvs
        sta mtmp
        lda rem+1
        sbc dvs+1
        sta mtmp+1
        lda rem+2
        sbc dvs+2
        sta mtmp+2
        lda rem+3
        sbc dvs+3
        bcc .no
        sta rem+3
        lda mtmp+2
        sta rem+2
        lda mtmp+1
        sta rem+1
        lda mtmp
        sta rem
        inc num
.no:    dex
        bne .l
        rts

; load helpers
num_rb:                         ; num = 4 bytes at RB+X
        lda RB,x
        sta num
        lda RB+1,x
        sta num+1
        lda RB+2,x
        sta num+2
        lda RB+3,x
        sta num+3
        rts
dvs_rb:                         ; dvs = 4 bytes at RB+X
        lda RB,x
        sta dvs
        lda RB+1,x
        sta dvs+1
        lda RB+2,x
        sta dvs+2
        lda RB+3,x
        sta dvs+3
        rts
dvs_khz:
        lda rb_khz
        sta dvs
        lda rb_khz+1
        sta dvs+1
        lda #0
        sta dvs+2
        sta dvs+3
        rts
dvs_tenths:
        lda tens_v
        sta dvs
        lda tens_v+1
        sta dvs+1
        lda #0
        sta dvs+2
        sta dvs+3
        rts

; ---------------------------------------------------------------- statistics screen
; Rows 3-10: label at column 1, value at column 12; second label 21, value 32.
draw_stats:
        ; time m:ss of m:ss
        ldx #3
        jsr row_ptr
        lda tens_v
        ldx tens_v+1
        ldy #12
        jsr put_mss
        lda #<s_of
        ldx #>s_of
        jsr put_str_at          ; continues at Y
        lda limit
        ldx limit+1
        jsr put_mss
        ; requests, characters
        ldx #4
        jsr row_ptr
        ldx #rb_req-RB
        jsr num_rb
        lda #0
        sta num+2
        sta num+3
        ldy #12
        jsr put_int
        ldx #rb_chars-RB
        jsr num_rb
        ldy #32
        jsr put_int
        ; prompt tokens, ms per prompt token
        ldx #5
        jsr row_ptr
        ldx #rb_ptok-RB
        jsr num_rb
        ldy #12
        jsr put_int
        ldx #rb_pcyc-RB
        ldy #rb_ptok-RB
        jsr ms_per
        ldy #32
        jsr put_int
        ; generated tokens, ms per generated token
        ldx #6
        jsr row_ptr
        ldx #rb_gtok-RB
        jsr num_rb
        ldy #12
        jsr put_int
        ldx #rb_gcyc-RB
        ldy #rb_gtok-RB
        jsr ms_per
        ldy #32
        jsr put_int
        ; min, max ms
        ldx #7
        jsr row_ptr
        lda rb_gtok
        ora rb_gtok+1
        beq +
        ldx #rb_min-RB
        jsr ms_of
        ldy #12
        jsr put_int
        ldx #rb_max-RB
        jsr ms_of
        ldy #32
        jsr put_int
        ; last ms, context position
        ldx #8
        jsr row_ptr
        ldx #rb_last-RB
        jsr ms_of
        ldy #12
        jsr put_int
+       ldx #8
        jsr row_ptr
        lda AI_PB_POS
        sta num
        lda #0
        sta num+1
        sta num+2
        sta num+3
        ldy #32
        jsr put_int
        ; tokens/s, characters/s (x100 = count * 1000 / tenths)
        ldx #9
        jsr row_ptr
        ldx #rb_gtok-RB
        jsr num_rb
        jsr per_sec
        ldy #12
        lda #2
        jsr put_dec
        ldx #rb_chars-RB
        jsr num_rb
        jsr per_sec
        ldy #32
        lda #2
        jsr put_dec
        ; CIA kHz, CRC
        ldx #10
        jsr row_ptr
        lda rb_khz
        sta num
        lda rb_khz+1
        sta num+1
        lda #0
        sta num+2
        sta num+3
        ldy #12
        jsr put_int
        ldy #32
        ldx #3
-       lda rb_crc,x
        jsr hex8_at
        dex
        bpl -
        rts

ms_per:                         ; num = (RB+X / RB+Y) / kHz; 0 when RB+Y = 0
        sty t2
        jsr num_rb
        ldx t2
        jsr dvs_rb
        jsr div32
        jsr dvs_khz
        jmp div32
ms_of:                          ; num = RB+X / kHz
        jsr num_rb
        jsr dvs_khz
        jmp div32
per_sec:                        ; num = num * 1000 / tenths
        lda #250
        jsr mul_num8
        lda #4
        jsr mul_num8
        jsr dvs_tenths
        jmp div32

; ---------------------------------------------------------------- summary
; The final screen: the request area becomes a short report.
summary:
        jsr clear_text
        ldx #12
        jsr row_ptr
        ldy #39
        lda #$20
-       sta (scr),y
        dey
        bpl -
        lda #<s_sum
        ldx #>s_sum
        ldy #1
        jsr put_str_at
        ldy #39
        lda #C_CTX
-       sta (colp),y
        dey
        bpl -
        ; "Ran m:ss, N requests, N characters."
        ldx #13
        jsr row_ptr
        lda #<s_ran
        ldx #>s_ran
        ldy #1
        jsr put_str_at
        lda tens_v
        ldx tens_v+1
        jsr put_mss
        lda #<s_comma
        ldx #>s_comma
        jsr put_str_at
        ldx #rb_req-RB
        jsr num_rb
        lda #0
        sta num+2
        sta num+3
        jsr put_num_y
        lda #<s_req
        ldx #>s_req
        jsr put_str_at
        ; "N characters, N tokens."
        ldx #14
        jsr row_ptr
        ldy #1
        ldx #rb_chars-RB
        jsr num_rb
        jsr put_num_y
        lda #<s_chs
        ldx #>s_chs
        jsr put_str_at
        ldx #rb_gtok-RB
        jsr num_rb
        jsr put_num_y
        lda #<s_toks
        ldx #>s_toks
        jsr put_str_at
        ; "x.xx tokens/s, x.xx characters/s"
        ldx #15
        jsr row_ptr
        ldy #1
        ldx #rb_gtok-RB
        jsr num_rb
        jsr per_sec
        lda #2
        jsr put_dec_y
        lda #<s_tps
        ldx #>s_tps
        jsr put_str_at
        ldx #rb_chars-RB
        jsr num_rb
        jsr per_sec
        lda #2
        jsr put_dec_y
        lda #<s_cps
        ldx #>s_cps
        jsr put_str_at
        ; "Prompt N ms, generated N ms per token"
        ldx #16
        jsr row_ptr
        lda #<s_pms
        ldx #>s_pms
        ldy #1
        jsr put_str_at
        sty t1
        ldx #rb_pcyc-RB
        ldy #rb_ptok-RB
        jsr ms_per
        ldy t1
        jsr put_num_y
        lda #<s_gms
        ldx #>s_gms
        jsr put_str_at
        sty t1
        ldx #rb_gcyc-RB
        ldy #rb_gtok-RB
        jsr ms_per
        ldy t1
        jsr put_num_y
        lda #<s_ms
        ldx #>s_ms
        jsr put_str_at
        ; clock line
        ldx #17
        jsr row_ptr
        lda #<s_tod
        ldx #>s_tod
        lda rb_clock
        cmp #1
        bne +
        lda #<s_tod
        ldx #>s_tod
        jmp ++
+       lda #<s_ciaclk
        ldx #>s_ciaclk
++      ldy #1
        jsr put_str_at
        ldx #rb_khz-RB          ; (2 bytes)
        lda rb_khz
        sta num
        lda rb_khz+1
        sta num+1
        lda #0
        sta num+2
        sta num+3
        jsr put_num_y
        lda #<s_khz
        ldx #>s_khz
        jsr put_str_at
        ; unfinished request
        lda ended
        beq +
        ldx #18
        jsr row_ptr
        lda #<s_unf
        ldx #>s_unf
        ldy #1
        jsr put_str_at
+       ldx #19
        jsr row_ptr
        lda #<s_crc
        ldx #>s_crc
        ldy #1
        jsr put_str_at
        ldx #3
-       lda rb_crc,x
        jsr hex8_at
        dex
        bpl -
        rts

put_num_y:                      ; num at column Y, Y advances (no clearing)
        lda #0
put_dec_y:                      ; A = decimals
        sta dp
        sty t3
        jsr fmt
        ldy t3
        ldx #0
-       lda numbuf,x
        beq +
        sta (scr),y
        iny
        inx
        bne -
+       rts

; ---------------------------------------------------------------- formatting
; put_int: num at column Y (row via scr), 8 columns cleared first
put_int:
        lda #0
put_dec:                        ; A = decimals (0-2)
        sta dp
        sty t3
        lda #$20                ; clear 8 columns
        ldx #8
-       sta (scr),y
        iny
        dex
        bne -
        jsr fmt
        ldy t3
        ldx #0
-       lda numbuf,x
        beq +
        sta (scr),y
        lda #C_VALUE
        sta (colp),y
        iny
        inx
        bne -
+       rts

fmt:                            ; num -> numbuf (screen codes, decimal point before dp digits)
        ldx #0                  ; digits in reverse order into numbuf+8..
.d:     stx t2
        lda #10
        sta dvs
        lda #0
        sta dvs+1
        sta dvs+2
        sta dvs+3
        jsr div32
        ldx t2
        lda rem
        ora #$30
        sta numbuf+8,x
        inx
        lda num
        ora num+1
        ora num+2
        ora num+3
        bne .d
        cpx dp                  ; at least dp + 1 digits
        beq .pad
        bcs .rev
.pad:   lda #$30
        sta numbuf+8,x
        inx
        cpx dp
        beq .pad
        bcc .pad
.rev:   ldy #0                  ; numbuf = reversed digits with the point
-       dex
        lda numbuf+8,x
        sta numbuf,y
        iny
        cpx dp
        bne +
        lda dp
        beq +
        lda #$2e
        sta numbuf,y
        iny
+       txa
        bne -
        lda #0
        sta numbuf,y
        rts

put_mss:                        ; A/X = tenths -> "m:ss" at column Y; Y advances
        sta num
        stx num+1
        lda #0
        sta num+2
        sta num+3
        sty t3
        lda #10
        sta dvs
        lda #0
        sta dvs+1
        sta dvs+2
        sta dvs+3
        jsr div32               ; seconds
        lda #60
        sta dvs
        jsr div32               ; minutes, rem = seconds
        lda rem
        pha
        lda #0
        sta dp
        jsr fmt
        ldy t3
        ldx #0
-       lda numbuf,x
        beq +
        sta (scr),y
        iny
        inx
        bne -
+       lda #$3a                ; ":"
        sta (scr),y
        iny
        pla
        ldx #$2f                ; tens digit
        sec
-       inx
        sbc #10
        bcs -
        adc #10
        pha
        txa
        sta (scr),y
        iny
        pla
        ora #$30
        sta (scr),y
        iny
        lda #$20
        sta (scr),y
        rts

hex8_at30:
        ldy #30
hex8_at:                        ; A -> two hex digits at column Y; Y += 2 (keeps X)
        pha
        lsr
        lsr
        lsr
        lsr
        jsr .nib
        pla
        and #$0f
.nib:   cmp #10
        bcc +
        sbc #9                  ; screen codes 1-6 = a-f
        jmp ++
+       ora #$30
++      sta (scr),y
        iny
        rts

; ---------------------------------------------------------------- screen
init_screen:
        lda #0
        sta $d020
        sta $d021
        lda #$17
        sta $d018
        lda #$1b
        sta $d011
        ldx #0
-       lda #$20
        sta SCREEN,x
        sta SCREEN+$100,x
        sta SCREEN+$200,x
        sta SCREEN+$2e8,x
        lda #C_LABEL
        sta COLRAM,x
        sta COLRAM+$100,x
        sta COLRAM+$200,x
        sta COLRAM+$2e8,x
        inx
        bne -
        ldx #0
        jsr row_ptr
        lda #<s_title
        ldx #>s_title
        ldy #1
        jsr put_str_at
        ldy #39
        lda #C_TITLE
-       sta (colp),y
        dey
        bpl -
        lda #3
        sta cur_row
        rts

msg:                            ; boot message on the next row (A/X)
        pha
        txa
        pha
        ldx cur_row
        inc cur_row
        jsr row_ptr
        pla
        tax
        pla
        ldy #1
        jmp put_str_at

draw_frame:                     ; labels, model line
        ldx #1
        jsr row_ptr
        ldy #1
        lda #<s_model
        ldx #>s_model
        jsr put_str_at
        lda turbo_ok
        beq +
        lda #<s_64
        ldx #>s_64
        jmp ++
+       lda #<s_1
        ldx #>s_1
++      jsr put_str_at
        ldx #3
-       stx t0
        jsr row_ptr
        ldy #39
        lda #$20
--      sta (scr),y
        dey
        bpl --
        ldx t0
        lda lab_a_lo-3,x
        pha
        lda lab_a_hi-3,x
        tax
        pla
        ldy #1
        jsr put_str_at
        ldx t0
        lda lab_b_lo-3,x
        pha
        lda lab_b_hi-3,x
        tax
        pla
        ldy #21
        jsr put_str_at
        ldx t0
        inx
        cpx #11
        bne -
        ldx #11
        jsr row_ptr
        ldy #39
        lda #$40                ; line
-       sta (scr),y
        dey
        bpl -
        rts

show_request:                   ; label of the current request, clear the text area
        jsr clear_text
        ldx #12
        jsr row_ptr
        ldy #39
        lda #$20
-       sta (scr),y
        dey
        bpl -
        ldx req_i
        lda lab_lo,x
        pha
        lda lab_hi,x
        tax
        pla
        ldy #1
        jsr put_str_at
        ldy #39
        lda #C_CTX
-       sta (colp),y
        dey
        bpl -
        lda #0
        sta shown
        lda #ROW_TXT0
        sta cur_row
        lda #1
        sta cur_col
        rts

clear_text:
        ldx #ROW_TXT0
-       stx t0
        jsr row_ptr
        ldy #39
--      lda #$20
        sta (scr),y
        lda #C_TEXT
        sta (colp),y
        dey
        bpl --
        ldx t0
        inx
        cpx #ROW_TXT1+1
        bne -
        rts

stream:                         ; print out_buf characters not yet shown
        lda shown
        cmp out_buf
        bcs .s_out
        tax
        lda out_buf+1,x
        jsr pet2scr
        pha
        ldx cur_row
        jsr row_ptr
        ldy cur_col
        pla
        sta (scr),y
        inc shown
        inc cur_col
        lda cur_col
        cmp #39
        bcc stream
        lda #1
        sta cur_col
        lda cur_row
        cmp #ROW_TXT1
        bcs stream              ; last row: keep overwriting it
        inc cur_row
        jmp stream
.s_out: rts

status_line:                    ; A/X = message on ROW_MSG
        pha
        txa
        pha
        ldx #ROW_MSG
        jsr row_ptr
        ldy #39
        lda #$20
-       sta (scr),y
        dey
        bpl -
        pla
        tax
        pla
        ldy #1
        jsr put_str_at
        ldy #39
        lda #C_STAT
-       sta (colp),y
        dey
        bpl -
        rts

row_ptr:                        ; X = row -> scr, colp
        lda row_lo,x
        sta scr
        sta colp
        lda row_hi,x
        sta scr+1
        clc
        adc #>(COLRAM - SCREEN)
        sta colp+1
        rts

put_str_at:                     ; A/X = string, Y = column; Y = column after it
        sta str
        stx str+1
        sty t3
        ldy #0
-       lda (str),y
        beq +
        sty t2
        ldy t3
        sta (scr),y
        inc t3
        ldy t2
        iny
        bne -
+       ldy t3
        rts

pet2scr:
        cmp #$20
        bcc .q
        cmp #$40
        bcc .same
        cmp #$60
        bcc .sub40
        cmp #$c1
        bcc .q
        cmp #$db
        bcs .q
        sec
        sbc #$80
        rts
.sub40: sec
        sbc #$40
.same:  rts
.q:     lda #$3f
        rts

row_lo: !for r, 0, 24 { !byte <(SCREEN + r * 40) }
row_hi: !for r, 0, 24 { !byte >(SCREEN + r * 40) }

end_part1:
!if end_part1 > $2000 { !error "bench code overlaps the engine at $2000" }

* = $2000
!source "engine/source/engine.asm"

; ---------------------------------------------------------------- data (after the engine)
!source "bench/source/generated/bench_tables.asm"

lab_a_lo: !byte <s_a3, <s_a4, <s_a5, <s_a6, <s_a7, <s_a8, <s_a9, <s_a10
lab_a_hi: !byte >s_a3, >s_a4, >s_a5, >s_a6, >s_a7, >s_a8, >s_a9, >s_a10
lab_b_lo: !byte <s_b3, <s_b4, <s_b5, <s_b6, <s_b7, <s_b8, <s_b9, <s_b10
lab_b_hi: !byte >s_b3, >s_b4, >s_b5, >s_b6, >s_b7, >s_b8, >s_b9, >s_b10
s_a3:  !scr "Time", 0
s_a4:  !scr "Requests", 0
s_a5:  !scr "Prompt tok", 0
s_a6:  !scr "Gen tokens", 0
s_a7:  !scr "Fastest ms", 0
s_a8:  !scr "Last ms", 0
s_a9:  !scr "Tokens/s", 0
s_a10: !scr "CIA kHz", 0
s_b3:  !scr "", 0
s_b4:  !scr "Characters", 0
s_b5:  !scr "ms/token", 0
s_b6:  !scr "ms/token", 0
s_b7:  !scr "Slowest ms", 0
s_b8:  !scr "Position", 0
s_b9:  !scr "Chars/s", 0
s_b10: !scr "CRC", 0

s_title:   !scr "Dungeon Master 64  -  Benchmark", 0
s_model:   !scr "model ok  ", 0
s_64:      !scr "64 MHz", 0
s_1:       !scr "1 MHz (turbo off)", 0
s_of:      !scr " of ", 0
m_init:    !scr "Starting the engine...", 0
m_check:   !scr "Checking the model in the REU...", 0
m_file:    !scr "Loading DM64AI.REU from USB...", 0
m_running: !scr "Running. RUN/STOP ends early.", 0
m_done:    !scr "Finished. RETURN: again  F8: quit", 0
m_fail:    !scr "Error, code (hex):", 0
s_sum:     !scr "[summary]", 0
s_ran:     !scr "Ran ", 0
s_comma:   !scr ", ", 0
s_req:     !scr " requests.", 0
s_chs:     !scr " characters, ", 0
s_toks:    !scr " tokens.", 0
s_tps:     !scr " tokens/s, ", 0
s_cps:     !scr " chars/s.", 0
s_pms:     !scr "Per token: prompt ", 0
s_gms:     !scr " ms, gen ", 0
s_ms:      !scr " ms", 0
s_tod:     !scr "Clock: TOD, CIA at ", 0
s_ciaclk:  !scr "Clock: CIA count, CIA at ", 0
s_khz:     !scr " kHz.", 0
s_unf:     !scr "Unfinished last request not counted.", 0
s_crc:     !scr "CRC for tools/bench.py: ", 0

end_data:
!if end_data > $6000 { !error "bench data overlaps engine buffers at $6000" }
