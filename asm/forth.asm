; ============================================================================
; forth.asm — Forth Interpreter + Compiler for MC14500 Bit-Slice CPU
; ============================================================================
;
; Features:
;   - Interactive interpreter (immediate mode)
;   - Compiler: : name ... ; defines new words in RAM
;   - Token-threaded execution for compiled words
;   - Control flow: IF THEN ELSE BEGIN UNTIL
;
; Built-in words:
;   Stack:   DUP DROP SWAP OVER
;   Math:    + - NEGATE | AND XOR INVERT 0=
;   Memory:  @ ! (page 0)
;   I/O:     . EMIT KEY CR ." WORDS
;   Define:  : ;
;   Control: IF ELSE THEN BEGIN UNTIL
;   Comment: ( ... )
;
; ============================================================================

.data UART_STATUS  0x7FFE
.data UART_DATA    0x7FFF
.data tmp          0x00
.data tmp2         0x01
.data wlen         0x02
.data nval         0x03
.data hash         0x04
.data eol          0x05
.data state        0x06        ; 0=interpret, 1=compile
.data ip_hi        0x07        ; instruction pointer high byte (15-bit)
.data ip_lo        0x08        ; instruction pointer low byte
.data here_hi      0x09        ; compile pointer high byte (15-bit)
.data here_lo      0x0A        ; compile pointer low byte
.data faddr        0x0B        ; found handler address (ROM, 8-bit)
.data ipsp         0x0C        ; ip return stack pointer (stack at RAM[0x0180+])
.data latest_lo    0x0D        ; low byte of latest user dict entry addr (15-bit)
.data dict_ptr_lo  0x0E        ; low byte of next free user dict byte
; 0x0F free (was b_latest — removed with unified dict)
.data fnd          0x10        ; found flag
.data faddr_hi     0x11        ; user word address high byte (during lookup: entry addr hi)
.data varp         0x12        ; next free user VARIABLE address (starts at 0x24)

.data src_lo       0x14        ; source pointer low (RAM addr) — 0 = use UART
.data src_hi       0x15        ; source pointer high
.data src_end_lo   0x16        ; source end pointer low
.data src_end_hi   0x17        ; source end pointer high
.data lvh          0x18        ; LEAVE chain head hi (compile-time, single-DO scope)
.data lvl          0x19        ; LEAVE chain head lo
.data sd_save_lo   0x1A        ; SD-READ-R/SD-WRITE-R: preserve block lo across re-init
.data sd_save_hi   0x1B        ; SD-READ-R/SD-WRITE-R: preserve block hi across re-init
.data base         0x1C        ; current numeric base (10=DECIMAL, 16=HEX). Default 10.
.data active_task  0x1D        ; PAUSE: 0 = task0 active, 1 = task1 active.
.data tb_save      0x1E        ; per-task BASE saves: tb_save+0 = task0, +1 = task1.
                               ; pause_body swaps the active slot with `base` on
                               ; every successful switch, so HEX in one task does
                               ; not leak into the other's number printing.
.data TASK0_BASE   0xC0        ; Task-0 struct base (21 bytes: 0xC0..0xD4)
.data TASK1_BASE   0xD5        ; Task-1 struct base (21 bytes: 0xD5..0xE9)
                               ; Struct layout per task (relative to base):
                               ;   +0   sp       (8-bit data-stack pointer)
                               ;   +1   ip_hi
                               ;   +2   ip_lo
                               ;   +3   ipsp     (IP-return-stack byte count)
                               ;   +4   status   (0=runnable, 1=stopped)
                               ;   +5   ip_save  (16 bytes — physical copy of
                               ;                  the IP-return-stack contents
                               ;                  while this task is paused)

.data IX_HI        0x7FFB      ; IX high byte register
.data STG_BLK_LO   0x7FF8      ; Storage: block# low (write only)
.data STG_BLK_HI   0x7FF9      ; Storage: block# high (write only)
.data STG_DATA     0x7FFA      ; Storage: data byte (R/W, auto-increments offset)
.data BLOCK_BUF    0x0200      ; Block buffer (256 bytes at 0x0200-0x02FF)
.data SPI_DATA     0x7FF0      ; SPI master: data (write=start TX, read=RX byte)
.data SPI_STAT     0x7FF1      ; SPI master: status (bit 0 = busy)
.data SPI_CS       0x7FF2      ; SPI master: chip-select (bit 0 drives sd_cs)

.data buf_blk      0x20        ; currently loaded block number LOW byte
.data buf_dirty    0x21        ; 1 if BLOCK_BUF has unsaved changes
.data buf_blk_hi   0x24        ; currently loaded block number HIGH byte (for 16-bit BLOCK16/LOAD16)
.data latest_hi    0x22        ; high byte of latest user dict entry addr
.data dict_ptr_hi  0x23        ; high byte of next free user dict byte

.data thru_act     0x25        ; 0=THRU inactive, non-zero=active
.data thru_cur_lo  0x26        ; currently-sourced block lo (during THRU)
.data thru_cur_hi  0x27        ; currently-sourced block hi
.data thru_end_lo  0x28        ; last block in THRU range, inclusive, lo
.data thru_end_hi  0x29        ; last block in THRU range, inclusive, hi

; --- Slot-1 metadata (2-slot block cache, repurposed from legacy SD-XT slots) ---
; The block cache keeps block data in two physical pages: page 0x02 (slot 0,
; user-visible — blocks_core.fth and HEDIT hardcode this) and page 0x03 (slot
; 1, cache-only).  Slot 0's metadata lives in buf_blk(_hi)/buf_dirty so user
; code that reads BLK@/DIRTY? sees the right state; slot 1's metadata sits
; here.  alt_blk_hi == 0xFF marks slot 1 as empty (real blocks have hi < 0x80
; via the 15-bit IX).
.data alt_blk      0x2A        ; slot 1 block# low byte
.data alt_blk_hi   0x2B        ; slot 1 block# high byte (0xFF = empty)
.data alt_dirty    0x2C        ; slot 1 dirty flag
; 0x2D free

; Compile buffer at 0x1000+ (unified memory, ~28KB via 15-bit IX)
; Unified dictionary at 0x0400-0x0FFF (3KB, 2-byte full-address links).
; Builtins pre-populated first, user words appended as defined. One linked
; chain walked by one finder. Entry: [link_hi, link_lo, name_len|imm,
; chars..., handler_hi, handler_lo]. Builtins have handler_hi=0 (ROM<0x100)
; → 1-byte token compile; user words have handler_hi>=0x10 (compile buffer)
; → do_call_user + 2-byte addr compile.
; Word buffer at 0x0100
; IP return stack at 0x0180-0x01FF (128 bytes, shared between nested user-word
; returns (2-byte entries: ip_hi, ip_lo) and user >R/R>/R@ (1-byte entries).
; Must be paired within each colon definition. `ipsp` is a byte counter (0..128).
; HW call stack (STACK_DEPTH=16 in mc14500_cpu.v) is the real recursion ceiling:
; 3-level nested forthwords + do_lit's read_ip_byte = 8 slots, so the old 8-deep
; stack overflowed on things like `: L2 L1 ;` where L1 uses `1+`.

; ============================================================================
; Builtin registration — assembler generates RAM init file
; Entry format: [link(1), name_len|imm_flag(1), name_chars(N), handler(1)]
; Immediate flag = bit 7 of name_len byte
; ============================================================================

; --- Stack ---
.builtin "DUP"    do_dup
.builtin "DROP"   do_drop
.builtin "SWAP"   do_swap
.builtin "OVER"   do_over
.builtin "ROT"    do_rot

; --- Math ---
.builtin "+"      do_plus
.builtin "-"      do_minus
; NEGATE moved to a forthword to free builtin-dict space
.builtin "|"      do_or
.builtin "OR"     do_or             ; ANS-Forth standard alias for |
.builtin "AND"    do_and
.builtin "XOR"    do_xor
.builtin "0="     do_zequ
.builtin "2*"     do_shl
.builtin "2/"     do_shr
.builtin "*"      do_mul
.builtin "/MOD"   do_divmod
.builtin "U<"     do_ult

; --- Memory ---
.builtin "@"      do_fetch
.builtin "!"      do_store

; --- I/O ---
.builtin "."      do_dot
.builtin "EMIT"   do_emit
.builtin "KEY"    do_key
.builtin "CR"     do_cr
.builtin "WORDS"  do_words
.builtin ".S"     tramp_dots

; --- Compile helpers ---
.builtin ","      do_comma
.builtin "C!"     do_cbang
.builtin "C@"     do_cfetch
.builtin "HERE"   do_here
.builtin "SP@"    do_spfetch
.builtin ">R"     do_to_r
.builtin "R>"     do_from_r
.builtin "R@"     do_r_fetch
.builtin "I"      do_r_fetch          ; loop index — top of R-stack during DO...LOOP
.builtin "D+"     do_dplus
.builtin "D-"     do_dminus
.builtin "D."     tramp_ddot
.builtin "EXECUTE" do_execute
.builtin "'"      do_tick
.builtin "UM*"    do_um_mul
.builtin "UM16*"  do_um16_mul
.builtin "F*"     do_f_mul
.builtin "UM/MOD" do_um_div
.builtin "KEY?"   do_keyq
; PATCH (do_patch_br) and ,16 (do_comma16) used by compiler forthwords only —
; their tokens are embedded at compile time, no user-facing dict entry needed

; --- Internal tokens (used by compiler, not typed by user; not exposed in dict) ---

; --- Compiler words (immediate) ---
; : and ." remain in ROM (need WORD reading / complex I/O)
.builtin ":"        tramp_colon    immediate
.builtin ".\""      tramp_dotquote immediate
.builtin "S\""      tramp_strquote immediate
.builtin "VARIABLE" tramp_variable immediate
.builtin "CONSTANT" tramp_constant immediate
.builtin "TYPE"     do_type
.builtin "COUNT"    do_count
.builtin "BYE"      do_bye
.builtin "HELP"     do_help

; --- Numeric base ---
.builtin "BASE"     do_base       ; ( -- addr )  push address of base variable
.builtin "HEX"      do_hex        ; ( -- )       set base to 16
.builtin "DECIMAL"  do_decimal    ; ( -- )       set base to 10

; --- Character literals ---
.builtin "CHAR"     do_char       ; ( -- c )    parse next word, push first char
.builtin "[CHAR]"   do_bchar  immediate   ; compile do_lit + first char of next word

; --- Dict roll-back ---
.builtin "FORGET"   do_forget     ; FORGET <name> — drop entry + everything newer

; --- Aborts ---
.builtin "ABORT"    do_abort      ; ( i*x -- ) clear stacks, exit compile, prompt
.builtin "ABORT\""  do_abrtquote  immediate   ; ABORT" message" — runtime test+print

; --- Storage / block I/O (all 2-arg: hi lo) ---
.builtin "BLOCK"  do_block
.builtin "LOAD"   do_load
.builtin "THRU"   do_thru
.builtin "B@"     do_bfetch
.builtin "UPDATE" do_update
.builtin "FLUSH"  do_save_bufs
.builtin "PARSE-NAME" do_pname
.builtin "SD-INIT" do_sd_init
.builtin "SDW"     do_sdw            ; diagnostic: ( hi lo -- status ) direct write
.builtin "SDR"     do_sdr            ; diagnostic: ( hi lo -- status ) direct read

; --- Stage-1/2 cooperative multi-tasking ---
.builtin "PAUSE"   do_pause          ; cooperative round-robin switch
.builtin "TASK"    do_task           ; ( xt_hi xt_lo -- ) install xt as task1
.builtin "STOP"    do_stop           ; mark self stopped + switch/abort

; --- Compiler words defined as pre-compiled Forth in RAM ---
; These are .forthword entries: token sequences stored in compile buffer,
; executed via run_user. Saves ROM by expressing compiler logic as Forth.
; NOTE: Branch targets are now 2-byte absolute addresses (hi, lo).
; do_here pushes 2 values (here_hi, here_lo).
; do_patch_br patches a 2-byte branch target at address from stack.
; do_comma16 compiles 2 bytes (hi, lo) from stack.
; do_2swap swaps two pairs of 8-bit values.

.forthword ";" immediate
    do_lit 0
    do_comma                    ; compile exit token
    do_lit 0
    do_lit 6
    do_store                    ; state = 0

.forthword "IF" immediate
    do_lit do_zbranch
    do_comma                    ; compile zbranch token
    do_here                     ; ( -- dest_hi dest_lo ) save patch address
    do_lit 0
    do_comma                    ; placeholder hi
    do_lit 0
    do_comma                    ; placeholder lo

.forthword "THEN" immediate
    do_patch_br                 ; ( dest_hi dest_lo -- ) patch with HERE

.forthword "ELSE" immediate
    do_lit do_branch
    do_comma                    ; compile branch token
    do_here                     ; ( if_hi if_lo -- if_hi if_lo else_hi else_lo )
    do_lit 0
    do_comma                    ; placeholder hi
    do_lit 0
    do_comma                    ; placeholder lo
    do_2swap                    ; ( else_hi else_lo if_hi if_lo )
    do_patch_br                 ; ( else_hi else_lo ) patch IF's placeholder

.forthword "BEGIN" immediate
    do_here                     ; ( -- begin_hi begin_lo )

.forthword "UNTIL" immediate
    do_lit do_zbranch
    do_comma                    ; compile zbranch token
    do_comma16                  ; ( begin_hi begin_lo -- ) compile 2-byte target

.forthword "(" immediate
    do_key
    do_lit 41
    do_xor
    do_zequ
    do_zbranch @0               ; loop back to do_key (byte 0 of this word)

.forthword "\\" immediate
    do_key
    do_lit 10                   ; LF terminator
    do_xor
    do_zequ
    do_zbranch @0               ; loop back until newline

; --- Comparison & logic ---

.forthword "0<"
    do_lit 128
    do_and
    do_zequ
    do_zequ

.forthword "="
    do_xor
    do_zequ

.forthword "<"
    do_minus
    do_lit 128
    do_and
    do_zequ
    do_zequ

.forthword ">"
    do_swap
    do_minus
    do_lit 128
    do_and
    do_zequ
    do_zequ

.forthword "U>"
    do_swap
    do_ult

.forthword "TRUE"
    do_lit 255

.forthword "FALSE"
    do_lit 0

.forthword "2DUP"
    do_over
    do_over

.forthword "2DROP"
    do_drop
    do_drop

.forthword "2SWAP"                  ; ( a b c d -- c d a b )
    do_rot
    do_to_r
    do_rot
    do_from_r

.forthword "NEGATE"
    do_lit 0
    do_swap
    do_minus

.forthword "NOT"
    do_zequ

.forthword "INVERT"                 ; ( n -- ~n ) bitwise NOT
    do_lit 0xFF
    do_xor

; --- Stack extensions ---

.forthword "NIP"
    do_swap
    do_drop

.forthword "TUCK"
    do_swap
    do_over

.forthword "?DUP"
    do_dup
    do_zbranch @5               ; skip DUP if zero → jump to exit (byte 5)
    do_dup

; --- Arithmetic ---

.forthword "/"
    do_divmod
    do_swap
    do_drop

.forthword "MOD"
    do_divmod
    do_drop

.forthword "ABS"
    do_dup
    do_lit 128
    do_and
    do_zbranch @8               ; if positive, skip negate → exit (byte 8)
    do_negate

.forthword "MIN"                ; ( a b -- min )
    do_over                     ; 0
    do_over                     ; 1
    do_ult                      ; 2: flag=FF if a<b
    do_zbranch @10              ; 3,[4,5]: a>=b → swap,drop (byte 10)
    do_drop                     ; 6: a<b: drop b, keep a
    do_branch @12               ; 7,[8,9]: skip to exit (byte 12)
    do_swap                     ; 10: a>=b: swap then drop → keep b
    do_drop                     ; 11
                                ; 12: exit (auto-appended)

.forthword "MAX"                ; ( a b -- max )
    do_over                     ; 0
    do_over                     ; 1
    do_ult                      ; 2: flag=FF if a<b
    do_zbranch @11              ; 3,[4,5]: a>=b → drop (byte 11)
    do_swap                     ; 6: a<b: swap,drop → keep b
    do_drop                     ; 7
    do_branch @12               ; 8,[9,10]: skip to exit (byte 12)
    do_drop                     ; 11: a>=b: drop b, keep a

.forthword "1+"
    do_lit 1
    do_plus

.forthword "1-"
    do_lit 1
    do_minus

; --- Compiler extensions ---

.forthword "WHILE" immediate
    do_lit do_zbranch
    do_comma                    ; compile zbranch token
    do_here                     ; ( -- dest_hi dest_lo ) save patch address
    do_lit 0
    do_comma                    ; placeholder hi
    do_lit 0
    do_comma                    ; placeholder lo

.forthword "REPEAT" immediate
    do_lit do_branch
    do_comma
    do_2swap
    do_comma16
    do_patch_br

; DO/LOOP/+LOOP keep only the back-target on the data stack so IF/THEN can
; freely push/pop their own state on top. The LEAVE chain head lives in the
; lvh:lvl globals, managed by do_lv_init / do_lv_compile / do_lv_finish.
.forthword "DO" immediate
    do_lit do_do
    do_comma
    do_here                     ; ( -- back_hi back_lo )
    do_lv_init                  ; reset LEAVE chain for this loop

.forthword "LOOP" immediate
    do_lit do_loop
    do_comma
    do_comma16                  ; ( back -- ) compile branch-back target
    do_lv_finish                ; patch all pending LEAVEs to HERE

.forthword "+LOOP" immediate
    do_lit do_plus_loop
    do_comma
    do_comma16
    do_lv_finish

.forthword "LEAVE" immediate
    do_lit do_leave
    do_lv_emit                  ; compile do_leave + chain placeholder

; CASE / OF / ENDOF / ENDCASE — multi-way branch.
; Compiled body for `n CASE v1 OF b1 ENDOF v2 OF b2 ENDOF default ENDCASE`:
;   ( n on stack at runtime )
;   v1 OVER = ZBRANCH L1   DROP b1 BRANCH END
;   L1: v2 OVER = ZBRANCH L2   DROP b2 BRANCH END
;   L2: default
;   END: DROP
; OF leaves its ZBRANCH placeholder on dstack; ENDOF patches it after emitting
; the BRANCH (which gets chained via lvh:lvl). ENDCASE walks the chain to
; patch all those BRANCHes to its own DROP. CASE saves lvh:lvl so a CASE
; nested inside DO+LEAVE doesn't clobber the outer LEAVE chain.

.forthword "CASE" immediate
    do_lv_save                  ; ( -- saved_lvh saved_lvl )

.forthword "OF" immediate
    do_lit do_over
    do_comma                    ; OVER
    do_lit do_xor
    do_comma                    ; XOR
    do_lit do_zequ
    do_comma                    ; 0= → flag (FF if equal)
    do_lit do_zbranch
    do_comma                    ; ZBRANCH placeholder
    do_here                     ; ( -- of_patch_h of_patch_l )
    do_lit 0
    do_comma
    do_lit 0
    do_comma
    do_lit do_drop
    do_comma                    ; DROP case-val (only runs when matched)

.forthword "ENDOF" immediate
    do_lit do_branch
    do_lv_emit                  ; compile do_branch + chained placeholder
    do_patch_br                 ; patch OF's ZBRANCH to current HERE

.forthword "ENDCASE" immediate
    do_lit do_drop
    do_comma                    ; DROP the case-val (fall-through path)
    do_lv_finish                ; patch all chained BRANCHes to HERE
    do_lv_restore               ; pop saved lvh:lvl back from dstack

; --- Convenience ---

.forthword "DEPTH"
    do_spfetch
    do_lit 251
    do_swap
    do_minus

.forthword "SPACE"
    do_lit 32
    do_emit

.forthword "BL"
    do_lit 32

; UNUSED ( -- d_lo d_hi )  free bytes in compile buffer (0x7F00 - HERE)
.forthword "UNUSED"
    do_lit 0
    do_lit 127
    do_here
    do_swap
    do_dminus

; S>D ( n -- d_lo d_hi )  signed-extend single → double-cell
; hi = 0xFF if n was negative (sign bit set), else 0. d_lo stays = n.
.forthword "S>D"
    do_dup
    do_lit 128
    do_and
    do_zequ
    do_zequ

; U>D ( n -- d_lo d_hi )  unsigned-widen single → double-cell (just push 0 hi).
; Non-standard but handy when you know n is 0..255 unsigned.
.forthword "U>D"
    do_lit 0

; ['] ( -- xt_hi xt_lo at runtime )  — compile-time tick.
; At compile time: reads next word from source, looks up xt, compiles
; `do_lit hi do_lit lo` into the stream so the xt is baked into the
; colon definition. Unlike `'` (which reads input at runtime), `[']`
; works correctly inside `: ... ;`.
.forthword "[']" immediate
    do_tick
    do_swap
    do_lit do_lit
    do_comma
    do_comma
    do_lit do_lit
    do_comma
    do_comma

; DNEGATE ( d_lo d_hi -- -d_lo -d_hi )  two's-complement double-cell negate
.forthword "DNEGATE"
    do_lit 0
    do_lit 0
    do_2swap
    do_dminus

; M* ( n1 n2 -- d_lo d_hi )  signed 8×8 → 16 multiply
; Inlines 2DUP / ABS x2 / DNEGATE because .forthword can only reference
; ROM-level primitives (not other forthwords) in its token list.
.forthword "M*"
    do_over                     ; 0   2DUP: over over
    do_over                     ; 1
    do_xor                      ; 2
    do_lit 128                  ; 3-4
    do_and                      ; 5
    do_to_r                     ; 6     R: sign
    do_swap                     ; 7     ( b a )
    do_dup                      ; 8     ABS(a):
    do_lit 128                  ; 9-10
    do_and                      ; 11
    do_zbranch @19              ; 12-14
    do_lit 0                    ; 15-16   inlined NEGATE
    do_swap                     ; 17
    do_minus                    ; 18
    do_swap                     ; 19    ( a b )
    do_dup                      ; 20    ABS(b):
    do_lit 128                  ; 21-22
    do_and                      ; 23
    do_zbranch @31              ; 24-26
    do_lit 0                    ; 27-28
    do_swap                     ; 29
    do_minus                    ; 30
    do_um_mul                   ; 31    ( lo hi )
    do_from_r                   ; 32    ( lo hi sign )
    do_zbranch @42              ; 33-35   positive → skip DNEGATE
    do_lit 0                    ; 36-37   inlined DNEGATE
    do_lit 0                    ; 38-39
    do_2swap                    ; 40
    do_dminus                   ; 41

; RXBLK ( hi lo -- ) — receive 256 bytes from UART into block hi:lo, FLUSH.
; Mirror of the Forth definition that used to live in blocks_core.fth block 41.
; Hardcoded in ROM (Phase D) so tools/upload_blocks.py can drive an SD-only
; system without first having to load blocks_core.fth from somewhere.
.forthword "RXBLK"
    do_block                    ; 0     load block hi:lo into BLOCK_BUF
    do_lit 0                    ; 1-2   counter
    do_key                      ; 3     ← BEGIN target (@3)
    do_over                     ; 4
    do_lit 2                    ; 5-6   page hi for BLOCK_BUF
    do_swap                     ; 7
    do_cbang                    ; 8     BLOCK_BUF[counter] = c
    do_lit 1                    ; 9-10
    do_plus                     ; 11    counter += 1
    do_dup                      ; 12
    do_zequ                     ; 13    counter wrapped to 0?
    do_zbranch @3               ; 14-16 UNTIL (loop while not yet wrapped)
    do_drop                     ; 17    drop counter
    do_update                   ; 18
    do_save_bufs                ; 19    FLUSH

; ============================================================================
; Boot — CPU starts at address 0, jump to init code
; ============================================================================

    JMP init

; ============================================================================
; PRIMITIVES — must be in first 256 ROM addresses for 8-bit tokens
; All end with RET so they can be CALLed from both interp and NEXT.
; Address 0 is reserved (JMP init), primitives start at address 2.
; ============================================================================

do_dup:                         ; ( a -- a a )
    LD  [0x7E00, s]
    PUSH
    RET
do_drop:                        ; ( a -- )
    POP
    RET
do_swap:                        ; ( a b -- b a )
    POP
    STO [tmp]
    POP
    STO [tmp2]
    LD  [tmp]
    PUSH
    LD  [tmp2]
    PUSH
    RET
do_over:                        ; ( a b -- a b a )
    LD  [0x7E01, s]
    PUSH
    RET
do_plus:                        ; ( a b -- a+b )
    POP
    STO [tmp]
    POP
    ADD [tmp]
    PUSH
    RET
do_minus:                       ; ( a b -- a-b )
    POP
    STO [tmp]
    POP
    SUB [tmp]
    PUSH
    RET
do_and:                         ; ( a b -- a&b )
    POP
    STO [tmp]
    POP
    AND [tmp]
    PUSH
    RET
do_xor:                         ; ( a b -- a^b )
    POP
    STO [tmp]
    POP
    XOR [tmp]
    PUSH
    RET
do_fetch:                       ; ( addr -- val ) @ — page 0 only
    CLR
    STO [IX_HI]                 ; IX_HI = 0 (safety)
    POP
    STO [0x7FFD]
    LD  [0x0000, x]
    PUSH
    RET
do_store:                       ; ( val addr -- ) ! — page 0 only
    CLR
    STO [IX_HI]                 ; IX_HI = 0 (safety)
    POP
    STO [0x7FFD]
    POP
    STO [0x0000, x]
    RET
do_emit:                        ; ( c -- )
    POP
    STO [UART_DATA]
    RET
do_comma:                       ; ( value -- ) compile byte to RAM[here], here++
    POP
    CALL compile_byte
    RET
do_cbang:                       ; ( value addr_hi addr_lo -- ) store value at compile addr
    POP
    STO [0x7FFD]                ; IX_LO = addr_lo
    POP
    STO [IX_HI]                 ; IX_HI = addr_hi
    POP
    STO [0x0000, x]             ; RAM[addr] = value
    CLR
    STO [IX_HI]                 ; restore IX_HI=0 for safety
    RET
do_cfetch:                      ; C@ ( addr_hi addr_lo -- val ) — byte fetch from any addr
    POP
    STO [0x7FFD]                ; IX_LO = addr_lo
    POP
    STO [IX_HI]                 ; IX_HI = addr_hi
    LD  [0x0000, x]
    PUSH
    CLR
    STO [IX_HI]                 ; restore IX_HI=0
    RET
do_here:                        ; ( -- here_hi here_lo ) push 2-byte compile pointer
    LD  [here_hi]
    PUSH
    LD  [here_lo]
    PUSH
    RET
do_or:                          ; ( a b -- a|b )
    POP
    STO [tmp]
    POP
    OR  [tmp]
    PUSH
    RET
do_invert:                      ; ( a -- ~a ) NOT / INVERT
    POP
    XOR #0xFF
    PUSH
    RET
do_zequ:                        ; ( a -- flag ) 0= : true(-1) if zero, else false(0)
    POP
    JZ  zequ_true
    CLR
    PUSH
    RET
zequ_true:
    LD  #0xFF
    PUSH
    RET
do_negate:                      ; ( a -- -a )
    POP
    STO [tmp]
    CLR
    SUB [tmp]
    PUSH
    RET
do_shr:                         ; ( a -- a>>1 ) 2/
    POP
    SHR
    PUSH
    RET
do_shl:                         ; ( a -- a<<1 ) 2*
    POP
    SHL
    PUSH
    RET
do_rot:     JMP rot_body        ; ROT trampoline — body above 0x100
do_key:                         ; ( -- c ) read one char (from source buffer if active, else UART)
    CALL rch                    ; rch already handles source-mode redirection
    PUSH
    RET
do_words:                       ; ( -- ) list all dict words (unified chain)
    LD  [latest_hi]
    STO [faddr_hi]
    LD  [latest_lo]
    STO [faddr]
    CALL dw_list_0400
    LD  #0x0A
    STO [UART_DATA]             ; newline
    RET
do_dotstr:                      ; runtime: print inline string from compile buffer
    ; ip points to [len, char, char, ...] in unified memory
    CALL read_ip_byte           ; load string length → RR
    STO [tmp]                   ; len
    CALL inc_ip                 ; skip past length byte
    CLR
    STO [tmp2]                  ; index
ds_loop:
    LD  [tmp2]
    XOR [tmp]
    JZ  ds_done
    CALL read_ip_byte           ; load char from compile buf via ip
    STO [UART_DATA]             ; print it
    CALL inc_ip
    LD  [tmp2]
    ADD #1
    STO [tmp2]
    JMP ds_loop
ds_done:
    RET
do_cr:                          ; ( -- ) print newline
    LD  #0x0D                   ; CR for real terminals (tio doesn't auto-translate)
    STO [UART_DATA]
    LD  #0x0A
    STO [UART_DATA]
    RET
do_dot:  JMP dot_body            ; trampoline — body above 0x100
do_bye:  HALT

; --- Literal: next byte in token stream is a value to push ---
do_lit:
    CALL read_ip_byte           ; load literal value from compile buf
    PUSH
    CALL inc_ip                 ; advance ip past literal
    RET

; --- Branch: unconditional jump in compiled code (2-byte target) ---
do_branch:
    CALL read_ip_byte           ; target_hi
    STO [tmp]
    CALL inc_ip
    CALL read_ip_byte           ; target_lo
    STO [ip_lo]
    LD  [tmp]
    STO [ip_hi]
    RET

; --- Branch if zero: conditional branch (2-byte target) ---
do_zbranch:
    POP
    JZ  do_zbranch_take
    ; not zero — skip 2-byte branch target
    CALL inc_ip
    CALL inc_ip
    RET
do_zbranch_take:
    JMP do_branch               ; reuse branch logic

; --- Call user word from compiled code: 2-byte target address ---
do_call_user:
    CALL read_ip_byte           ; target_hi
    STO [tmp2]
    CALL inc_ip
    CALL read_ip_byte           ; target_lo
    STO [tmp]
    CALL inc_ip                 ; advance ip past target bytes
    JMP run_user                ; run_user reads from tmp2:tmp

; --- New primitives that need token-space (< 0x100) ---

do_2swap:   JMP swap2_body      ; ( a b c d -- c d a b ) trampoline — body above 0x100

do_dplus:     JMP dplus_body    ; trampoline — body above 0x100
do_dminus:    JMP dminus_body   ; trampoline — body above 0x100
tramp_ddot:   JMP ddot_body     ; trampoline — body above 0x100

do_patch_br:  JMP patch_br_body ; trampoline — body above 0x100
do_comma16:   JMP comma16_body  ; trampoline — body above 0x100

do_spfetch:                     ; SP@ ( -- n ) push stack pointer value
    LD  [0x7FFC]
    PUSH
    RET

; --- Return-stack words — trampolines; bodies above 0x100 ------------
do_to_r:      JMP to_r_body     ; >R  ( n -- R: -- n )
do_from_r:    JMP from_r_body   ; R>  ( -- n R: n -- )
do_r_fetch:   JMP r_fetch_body  ; R@  ( -- n R: n -- n )

do_ult:                         ; U< ( a b -- flag ) unsigned less-than via carry
    POP
    STO [tmp]                   ; b
    POP
    SUB [tmp]                   ; a - b, carry=1 means borrow (a < b)
    JC  ult_true
    CLR
    PUSH
    RET
ult_true:
    LD  #0xFF
    PUSH
    RET

; Trampolines for * and /MOD — body lives above 0x100 to save token-space
do_mul:     JMP mul_body
do_divmod:  JMP divmod_body

; --- Trampolines for ROM-based compiler words (need 8-bit address for CALLI) ---
tramp_colon:    JMP do_colon
tramp_dotquote: JMP do_dotquote
tramp_variable: JMP do_variable
tramp_constant: JMP do_constant
tramp_dots:     JMP do_dots
do_block:       JMP block_body
do_load:        JMP load_body
do_thru:        JMP thru_body
do_pname:       JMP pname_body
do_save_bufs:   JMP save_buffers_body
do_do:          JMP do_rt_body      ; DO runtime ( limit idx -- R: -- limit idx )
do_loop:        JMP loop_rt_body    ; LOOP runtime: idx++, compare, branch
do_plus_loop:   JMP plus_loop_rt_body ; +LOOP runtime: ( step -- ) idx+=step, cross-test
do_leave:       JMP leave_rt_body   ; LEAVE runtime: pop R-stack, branch to after-LOOP
do_lv_init:     JMP lv_init_body    ; reset LEAVE/CASE chain
do_lv_emit:     JMP lv_emit_body    ; ( tok -- ) emit tok + chain placeholder, update chain
do_lv_finish:   JMP lv_finish_body  ; walk + patch chain
do_lv_save:     JMP lv_save_body    ; ( -- old_h old_l ) save lvh:lvl on dstack, reset chain
do_lv_restore:  JMP lv_restore_body ; ( old_h old_l -- ) restore lvh:lvl from dstack
do_execute:     JMP execute_body    ; ( xt_hi xt_lo -- ) call word at xt
do_tick:        JMP tick_body       ; ( -- xt_hi xt_lo ) parse next input word, push xt
do_um_mul:      JMP um_mul_body     ; ( u1 u2 -- prod_lo prod_hi ) unsigned 8×8→16
do_um16_mul:    JMP um16_mul_body   ; ( al ah bl bh -- p_lo p_hi ) unsigned 16×16 mid-16
do_f_mul:       JMP f_mul_body      ; ( al ah bl bh -- r_lo r_hi ) signed 8.8 multiply
do_um_div:      JMP um_div_body     ; ( ud_lo ud_hi div -- rem quot ) unsigned 16/8
do_keyq:        JMP keyq_body       ; KEY? ( -- flag ) non-blocking input check
do_strlit:      JMP strlit_body     ; runtime: ( -- hi lo len ) from inline string
do_type:        JMP type_body       ; TYPE ( hi lo len -- ) emit string
do_count:       JMP count_body      ; COUNT ( hi lo -- hi' lo' len )
tramp_strquote: JMP do_strquote     ; S" compile-time (immediate)
do_bfetch:      JMP bfetch_body     ; B@ trampoline — body lives above 0x100
do_update:      JMP update_body     ; UPDATE trampoline
do_sd_init:     JMP sd_init_handler ; SD-INIT ( -- status ) — ROM SD primitive
do_sdw:         JMP sdw_handler     ; SDW ( hi lo -- status ) — direct write
do_sdr:         JMP sdr_handler     ; SDR ( hi lo -- status ) — direct read
do_help:        JMP help_body       ; HELP — print command reference
do_base:        JMP base_body       ; BASE ( -- addr )
do_hex:         JMP hex_body        ; HEX ( -- )
do_decimal:     JMP decimal_body    ; DECIMAL ( -- )
do_char:        JMP char_body       ; CHAR ( -- c )
do_bchar:       JMP bchar_body      ; [CHAR] ( -- ) — immediate, compiles do_lit + char
do_forget:      JMP forget_body     ; FORGET ( -- ) — drop named entry + newer
do_abort:       JMP abort_body      ; ABORT ( i*x -- ) — reset stacks, prompt
do_abrtquote:   JMP abrtquote_body  ; ABORT" — immediate: compile do_abrtstr + string
do_abrtstr:     JMP abrtstr_body    ; runtime: pop flag, conditional msg+abort or skip

; --- Stage-1/2 cooperative multi-tasking ---
do_pause:       JMP pause_body      ; PAUSE ( -- ) cooperative task switch
do_task:        JMP task_body       ; TASK ( xt_hi xt_lo -- ) install xt as task1
do_stop:        JMP stop_body       ; STOP ( -- ) mark self stopped, switch or abort

; ============================================================================
; NEXT — Token interpreter for compiled words
; ============================================================================
; Reads tokens (1 byte each) from unified memory via 15-bit ip.
; Each token is the ROM address of a primitive. Calls it, then loops.
; Token 0 = do_exit (end of word).

next:
    CALL read_ip_byte           ; load token from RAM[{ip_hi, ip_lo}]
    JZ  next_done               ; token 0 = exit
    STO [faddr]
    CALL inc_ip                 ; advance ip (16-bit)
    LD  [faddr]
    CALLI                       ; call primitive
    JMP next
next_done:
    RET                         ; return to whoever called the compiled word

; (exec_compiled removed — use run_user instead)

; ============================================================================
; Init
; ============================================================================

init:
    LD  #0xFB
    STO [0x7FFC]                ; SP
    CLR
    STO [eol]
    STO [state]                 ; interpret mode
    STO [ipsp]                  ; ip return stack empty
    STO [IX_HI]                 ; IX_HI = 0 (safety)
    STO [src_lo]                ; src disabled (src_lo = src_end_lo = 0)
    STO [src_hi]
    STO [src_end_lo]
    STO [src_end_hi]
    STO [buf_dirty]
    STO [alt_dirty]             ; slot 1 not dirty
    STO [thru_act]              ; THRU inactive on boot
    LD  #0xFF
    STO [buf_blk_hi]            ; slot 0 marked empty (real blocks have hi<0x80)
    STO [alt_blk_hi]            ; slot 1 marked empty
    CLR
    STO [buf_blk]               ; lo bytes — value irrelevant while hi=0xFF
    STO [alt_blk]
    LD  #0x2E
    STO [varp]                  ; user VARIABLE allocation start (0x20-0x2D reserved)
    ; Populate the dictionary + compile bodies + HERE/LATEST/DICT_PTR slots
    ; from ROM-encoded LD/STO pairs.  Yosys-Gowin doesn't reliably persist
    ; BRAM init across the bitstream, so the dict has to be driven into
    ; RAM at boot.  mcasm.py post-pass fills the body of the `dict_init`
    ; label below with the necessary microwords + RET.
    CALL dict_init
    LD  #10
    STO [base]                  ; numeric base = 10 (DECIMAL).  After
                                ; dict_init so it can't be clobbered.
    STO [tb_save]               ; task0 BASE save = 10
    STO [0x1F]                  ; task1 BASE save = 10 (= tb_save + 1)

    ; Stage-1/2 cooperative multi-tasking init.  task0 = currently-running
    ; main task (state will be saved on first PAUSE), task1 = stopped
    ; placeholder until `xt TASK` installs a real worker.
    CLR
    STO [active_task]           ; active = task0
    STO [IX_HI]
    LD  #TASK1_BASE
    ADD #4
    STO [0x7FFD]                ; IX_LO = task1.status
    LD  #1
    STO [0x0000, x]             ; task1.status = 1 (stopped)

    ; Phase D: try the SD boot block.  If sector 0:0 starts with the magic
    ; "\ 8xMC14500" the rest of the block is sourced as Forth (typical
    ; payload is `1 100 1 120 THRU MENU` or similar).  No magic, no SD,
    ; or read failure → silent fallback to UART prompt.
    CALL try_autoboot

main:
    ; Suppress "ok\r\n> " while sourcing.  Three cases skip the prompt:
    ;  (a) THRU is active (more blocks coming, src may briefly be at end if
    ;      a newline landed exactly at byte 255 of the current block).
    ;  (b) src_lo != src_end_lo (source buffer still has bytes).
    ;  (c) src_hi != src_end_hi (ditto, hi byte differs).
    LD  [thru_act]
    JZ  main_check_src_lo
    JMP interp
main_check_src_lo:
    LD  [src_lo]
    XOR [src_end_lo]
    JZ  main_check_src_hi
    JMP interp
main_check_src_hi:
    LD  [src_hi]
    XOR [src_end_hi]
    JZ  main_print_prompt
    JMP interp
main_print_prompt:
    LD  #0x6F
    STO [UART_DATA]             ; 'o'
    LD  #0x6B
    STO [UART_DATA]             ; 'k'
    LD  #0x0D
    STO [UART_DATA]             ; CR
    LD  #0x0A
    STO [UART_DATA]             ; LF
    LD  #0x3E
    STO [UART_DATA]             ; '>'
    LD  #0x20
    STO [UART_DATA]             ; ' '

; ============================================================================
; INTERPRET — read word, find, compile or execute
; ============================================================================

interp:
    CALL word
    LD  [wlen]
    JZ  main

    ; --- Clear sign flag ---
    CLR
    STO [hash]                  ; 0 = positive number; set to 1 for '-' prefix

    ; --- Leading '-' ? (only a sign if followed by digits) ---
    LD  [0x0100]
    XOR #0x2D
    JZ  try_neg

    ; Try number-parse first.  In DECIMAL mode the parser bails to try_user
    ; on any non-'0'..'9' char; in HEX mode it also accepts 'A'..'F', so a
    ; word starting with one of those letters could be a hex literal AND a
    ; defined word.  Having try_num bail to try_user on any miss keeps the
    ; old "letters → dict, digits → number" behaviour without adding a
    ; base-aware first-char gate to the interp hot path.
    JMP try_num

try_neg:
    LD  [wlen]
    XOR #1
    JZ  try_user                ; just '-' alone → look up as word
    ; Tentatively treat '-X...' as a negative literal; try_num bails to
    ; try_user if X turns out not to be a digit (or A-F in hex mode), at
    ; which point the original "-X..." string is looked up as a word.
    LD  #1
    STO [hash]                  ; mark as negative
    JMP try_num_skip

    ; --- Search user dictionary at 0x0400 (exact name match) ---
try_user:
    ; Check if chain is empty: latest_hi:latest_lo == 0xFFFF
    LD  [latest_hi]
    XOR #0xFF
    JZ  tu_check_lo
    JMP tu_start
tu_check_lo:
    LD  [latest_lo]
    XOR #0xFF
    JZ  nfail                   ; empty chain → not found
tu_start:
    ; faddr = latest (full 15-bit entry address)
    LD  [latest_hi]
    STO [faddr_hi]
    LD  [latest_lo]
    STO [faddr]

fu_loop:
    ; Read entry[2] = name_len | imm flag
    LD  #2
    CALL set_ix_faddr
    LD  [0x0000, x]
    STO [fnd]
    AND #0x7F
    XOR [wlen]
    JZ  fu_len_ok
    JMP fu_next
fu_len_ok:
    CLR
    STO [tmp]                   ; i = 0
fu_cmp:
    LD  [tmp]
    XOR [wlen]
    JZ  fu_found
    ; Read dict char at entry[3+i]
    LD  [tmp]
    ADD #3
    CALL set_ix_faddr
    LD  [0x0000, x]
    STO [tmp2]
    ; Read word-buffer char at 0x0100+i
    CLR
    STO [IX_HI]
    LD  [tmp]
    STO [0x7FFD]
    LD  [0x0100, x]
    XOR [tmp2]
    JZ  fu_cmp_next
    JMP fu_next
fu_cmp_next:
    LD  [tmp]
    ADD #1
    STO [tmp]
    JMP fu_cmp

fu_found:
    ; Read 2-byte handler: entry[3+wlen] = hi, entry[4+wlen] = lo.
    ; handler_hi = 0 → builtin (ROM addr in lo). Else user word (compile-buffer addr).
    LD  [wlen]
    ADD #3
    CALL set_ix_faddr
    LD  [0x0000, x]
    STO [hash]                  ; saved handler_hi
    LD  [wlen]
    ADD #4
    CALL set_ix_faddr
    LD  [0x0000, x]
    STO [faddr]                 ; handler_lo (ROM token or user addr_lo)
    LD  [hash]
    STO [faddr_hi]
    ; Check immediate flag
    LD  [fnd]
    AND #0x80
    JZ  fu_not_imm
    JMP fu_exec                 ; immediate → always execute
fu_not_imm:
    LD  [state]
    JZ  fu_exec
    ; Compile path: builtin → 1-byte token, user → do_call_user + hi + lo
    LD  [faddr_hi]
    JZ  fu_compile_builtin
    LD  #do_call_user
    CALL compile_byte
    LD  [faddr_hi]
    CALL compile_byte
    LD  [faddr]
    CALL compile_byte
    JMP interp
fu_compile_builtin:
    LD  [faddr]
    CALL compile_byte
    JMP interp
fu_exec:
    LD  [faddr_hi]
    JZ  fu_exec_builtin
    ; User word: run_user with tmp2:tmp = handler_hi:lo
    LD  [faddr_hi]
    STO [tmp2]
    LD  [faddr]
    STO [tmp]
    CALL run_user
    JMP interp
fu_exec_builtin:
    LD  [faddr]
    CALLI
    JMP interp

fu_next:
    ; Follow 2-byte link: entry[0] = link_hi, entry[1] = link_lo
    ; Read link_hi first — if 0xFF, check link_lo for end-of-chain sentinel
    LD  #0
    CALL set_ix_faddr
    LD  [0x0000, x]
    STO [hash]                  ; saved link_hi
    LD  #1
    CALL set_ix_faddr
    LD  [0x0000, x]
    STO [tmp]                   ; saved link_lo
    ; Sanity guard: dict lives in 0x0400+. link_hi < 0x04 means RAM init
    ; failure or page-zero corruption — bail to "?" rather than chase
    ; 0x0000 -> 0x0000 -> ... forever (used to wedge the prompt cold).
    LD  [hash]
    SUB #0x04
    JC  nfail
    ; Check if chain ended (link = 0xFFFF)
    LD  [hash]
    XOR #0xFF
    JZ  fu_next_check_lo
    JMP fu_next_follow
fu_next_check_lo:
    LD  [tmp]
    XOR #0xFF
    JZ  nfail                   ; end of chain → not found
fu_next_follow:
    LD  [hash]
    STO [faddr_hi]
    LD  [tmp]
    STO [faddr]
    JMP fu_loop

    ; --- Try number ---
try_num:
    CLR
    STO [0x7FFD]                ; IX=0 (read from first char)
    JMP try_num_init
try_num_skip:
    LD  #1
    STO [0x7FFD]                ; IX=1 (skip leading '-')
try_num_init:
    CLR
    STO [nval]
nl:
    LD  [0x7FFD]
    XOR [wlen]
    JZ  nok
    LD  [0x0100, x]
    SUB #0x30
    JC  try_user                ; < '0' → not a digit
    STO [tmp]                   ; tmp = char - '0'
    SUB #0x0A
    JC  ndig                    ; tmp < 10 → 0..9 (decimal digit value already in tmp)
    ; Past '9'.  In hex mode, also accept 'A'..'F'.
    LD  [base]
    SUB #0x10
    JZ  nl_hex_check
    JMP try_user                ; not hex base → not a digit
nl_hex_check:
    ; tmp holds char - '0'.  'A'-'0' = 17, 'F'-'0' = 22.
    LD  [tmp]
    SUB #0x11                   ; - 17
    JC  try_user                ; tmp < 17 → ':'..'@' (between '9' and 'A')
    STO [tmp]                   ; tmp = char - 'A'
    SUB #0x06
    JC  nl_hex_ok               ; tmp < 6 → A..F
    JMP try_user                ; >= 6 → past F
nl_hex_ok:
    LD  [tmp]
    ADD #0x0A                   ; digit value = (char - 'A') + 10
    STO [tmp]
ndig:
    ; Multiply nval by base, then add digit (in tmp).  Each SHL latches the
    ; shifted-out bit into carry; JC catches when the multiply or add would
    ; overflow the 8-bit cell.  Overflow → try_user (NOT directly nfail) so
    ; multi-char words whose leading letters parse as digits — e.g. `DECIMAL`
    ; in HEX mode (D-E-C valid hex) — still get a dict lookup.  A real
    ; >255 literal that isn't a word lands in nfail with `<word> ?`.
    ;
    ; Note: SD-loaded source (blocks_core.fth) was updated 2026-04-28 to
    ; replace the `1000 0 DO` / `256 0 DO` "many iterations via mod-256
    ; wrap" idiom with the explicit `0 0 DO ... LOOP` (= 256 iterations
    ; via LOOP wrap-around).  Both produce the same iteration count.
    LD  [base]
    SUB #0x10
    JZ  ndig_x16
    ; *10 = (n<<3) + (n<<1)
    LD  [nval]
    SHL
    JC  ndig_overflow
    STO [tmp2]                  ; n*2
    SHL
    JC  ndig_overflow
    SHL
    JC  ndig_overflow           ; n*8
    ADD [tmp2]                  ; n*10
    JC  ndig_overflow
    JMP ndig_add
ndig_x16:
    LD  [nval]
    SHL
    JC  ndig_overflow
    SHL
    JC  ndig_overflow
    SHL
    JC  ndig_overflow
    SHL
    JC  ndig_overflow           ; n*16
ndig_add:
    ADD [tmp]
    JC  ndig_overflow           ; digit-add overflow (rare but possible)
    STO [nval]
    LD  [0x7FFD]
    ADD #1
    STO [0x7FFD]
    JMP nl
ndig_overflow:
    JMP try_user
nok:
    LD  [wlen]
    JZ  nfail
    ; Apply sign (hash=1 means negate)
    LD  [hash]
    JZ  nok_signed
    CLR
    SUB [nval]
    STO [nval]
nok_signed:
    LD  [state]
    JZ  num_push
    ; Compile: emit LIT token + value via compile_byte
    LD  #do_lit
    CALL compile_byte
    LD  [nval]
    CALL compile_byte
    JMP interp
num_push:
    LD  [nval]
    PUSH
    JMP interp
nfail:
    ; Print the offending word from buffer 0x0100[0..wlen-1], then " ?\r\n".
    ; If source mode is active (THRU/LOAD), abort source to avoid running on
    ; broken state — the rest of the source (typically further definitions)
    ; would just produce more cascading errors otherwise.
    CLR
    STO [tmp]                       ; i = 0
nf_loop:
    LD  [tmp]
    XOR [wlen]
    JZ  nf_done_word
    CLR
    STO [IX_HI]
    LD  [tmp]
    STO [0x7FFD]
    LD  [0x0100, x]
    STO [UART_DATA]                 ; emit one char of the failed name
    LD  [tmp]
    ADD #1
    STO [tmp]
    JMP nf_loop
nf_done_word:
    LD  #0x20
    STO [UART_DATA]                 ; ' '
    LD  #0x3F
    STO [UART_DATA]                 ; '?'
    LD  #0x0D
    STO [UART_DATA]                 ; CR
    LD  #0x0A
    STO [UART_DATA]                 ; LF
    ; Abort source mode if active.  THRU active OR src has bytes → kill it.
    LD  [thru_act]
    JZ  nf_check_src_lo
    JMP nf_abort_source
nf_check_src_lo:
    LD  [src_lo]
    XOR [src_end_lo]
    JZ  nf_check_src_hi
    JMP nf_abort_source
nf_check_src_hi:
    LD  [src_hi]
    XOR [src_end_hi]
    JZ  nf_no_abort
    JMP nf_abort_source
nf_abort_source:
    CLR
    STO [thru_act]
    LD  [src_end_lo]
    STO [src_lo]
    LD  [src_end_hi]
    STO [src_hi]
    CLR
    STO [state]                     ; exit compile mode (in case `:` was open)
nf_no_abort:
    JMP interp

; ============================================================================
; WORD
; ============================================================================

; to_upper: ( char in RR -- uppercased char in RR )
; Converts ASCII 'a'-'z' (0x61-0x7A) to 'A'-'Z'. Other bytes unchanged.
; Uses hash as scratch (does not touch tmp).
to_upper:
    STO [hash]                  ; save original char
    SUB #0x61                   ; char - 'a'
    JC  tu_keep                 ; borrow: char < 'a' → not a letter
    SUB #0x1A                   ; (char - 'a') - 26
    JC  tu_do                   ; borrow: was 'a'..'z'
tu_keep:
    LD  [hash]
    RET
tu_do:
    LD  [hash]
    SUB #0x20                   ; lowercase → uppercase
    RET

word:
    CLR
    STO [IX_HI]                 ; IX_HI = 0 for word buffer access
    STO [wlen]
    LD  [eol]
    JZ  ws
    CLR
    STO [eol]
    RET
ws:
    CALL rch
    XOR #0x20
    JZ  ws
    LD  [tmp]
    XOR #0x08               ; BS before any char — ignore
    JZ  ws
    LD  [tmp]
    XOR #0x7F               ; DEL before any char — ignore
    JZ  ws
    LD  [tmp]
    XOR #0x0D
    JZ  weol
    LD  [tmp]
    XOR #0x0A
    JZ  weol
    LD  [tmp]
    CALL to_upper
    STO [0x0100]
    LD  #1
    STO [wlen]
wc:
    CALL rch
    XOR #0x20
    JZ  wd
    LD  [tmp]
    XOR #0x0D
    JZ  wdeol
    LD  [tmp]
    XOR #0x0A
    JZ  wdeol
    LD  [tmp]
    XOR #0x08               ; BS — erase last char
    JZ  wbs
    LD  [tmp]
    XOR #0x7F               ; DEL — erase last char
    JZ  wbs
    LD  [wlen]
    STO [0x7FFD]
    LD  [tmp]
    CALL to_upper
    STO [0x0100, x]
    LD  [wlen]
    ADD #1
    STO [wlen]
    JMP wc
wbs:
    ; Remove last char from buffer, erase on terminal with BS SPACE BS
    LD  [wlen]
    SUB #1
    STO [wlen]
    LD  #0x08
    STO [UART_DATA]
    LD  #0x20
    STO [UART_DATA]
    LD  #0x08
    STO [UART_DATA]
    LD  [wlen]
    JZ  ws                  ; buffer empty → back to whitespace-skip mode
    JMP wc
wdeol:
    LD  #1
    STO [eol]
wd:
    LD  [wlen]
    STO [0x7FFD]
    CLR
    STO [0x0100, x]
    RET
weol:
    LD  #1
    STO [eol]
    RET

rch:
    ; Check if source buffer is active: src_lo != src_end_lo OR src_hi != src_end_hi
    LD  [src_lo]
    XOR [src_end_lo]
    JZ  rch_check_hi
    JMP rch_from_src
rch_check_hi:
    LD  [src_hi]
    XOR [src_end_hi]
    JZ  rch_uart        ; both equal → source exhausted → UART
rch_from_src:
    ; Read byte from RAM[src_hi : src_lo]
    LD  [src_hi]
    STO [IX_HI]
    LD  [src_lo]
    STO [0x7FFD]
    LD  [0x0000, x]
    STO [tmp]
    ; Restore IX_HI=0 immediately so callers don't see leaked state
    CLR
    STO [IX_HI]
    ; Treat NUL byte as end-of-source: switch to UART
    LD  [tmp]
    JZ  rch_src_eof
    ; Increment src pointer (16-bit)
    LD  [src_lo]
    ADD #1
    STO [src_lo]
    JC  rch_src_carry
    LD  [tmp]
    RET
rch_src_carry:
    LD  [src_hi]
    ADD #1
    STO [src_hi]
    LD  [tmp]
    RET
rch_src_eof:
    ; Mark source as exhausted (src = src_end)
    LD  [src_end_lo]
    STO [src_lo]
    LD  [src_end_hi]
    STO [src_hi]
    JMP rch_uart                ; immediately fall through to UART
rch_uart:
    ; --- THRU auto-chain intercept ---
    ; When THRU is active and current block source is exhausted, advance to the
    ; next block and continue interpreting from it. Only falls through to the
    ; real UART when THRU is inactive or the range has been exhausted.
    LD  [thru_act]
    JZ  rch_uart_real
    ; Advance thru_cur by 1 (16-bit)
    LD  [thru_cur_lo]
    ADD #1
    STO [thru_cur_lo]
    JC  thru_bump_hi
    JMP thru_cmp
thru_bump_hi:
    LD  [thru_cur_hi]
    ADD #1
    STO [thru_cur_hi]
thru_cmp:
    ; Compare (thru_cur_hi, thru_cur_lo) with (thru_end_hi, thru_end_lo).
    ; If thru_cur > thru_end → done, deactivate + fall through to UART.
    LD  [thru_cur_hi]
    SUB [thru_end_hi]
    JC  thru_load_cur               ; cur_hi < end_hi (borrow) → continue
    JZ  thru_cmp_lo                 ; cur_hi == end_hi → check lo
    JMP thru_done                   ; cur_hi > end_hi → done
thru_cmp_lo:
    LD  [thru_cur_lo]
    SUB [thru_end_lo]
    JC  thru_load_cur               ; cur_lo < end_lo → continue
    JZ  thru_load_cur               ; cur_lo == end_lo → last block
    ; cur_lo > end_lo → fall through to done
thru_done:
    CLR
    STO [thru_act]
    JMP rch_uart_real
thru_load_cur:
    LD  [thru_cur_hi]
    STO [tmp2]
    LD  [thru_cur_lo]
    STO [tmp]
    CALL block_dispatch
    CALL set_src_block_buf
    JMP rch_from_src                ; read first byte of newly-loaded block
rch_uart_real:
    LD  [UART_STATUS]
    AND #0x02
    JZ  rch_uart_real
    LD  [UART_DATA]
    STO [tmp]
    XOR #0x0D                       ; CR → echo CR+LF (terminal newline)
    JZ  rch_echo_crlf
    LD  [tmp]
    XOR #0x0A                       ; LF → no echo (terminals usually send CR)
    JZ  rch_ret
    LD  [tmp]
    XOR #0x08                       ; BS — caller handles echo
    JZ  rch_ret
    LD  [tmp]
    XOR #0x7F                       ; DEL — caller handles echo
    JZ  rch_ret
    LD  [tmp]
    STO [UART_DATA]
rch_ret:
    LD  [tmp]
    RET
rch_echo_crlf:
    LD  #0x0D
    STO [UART_DATA]
    LD  #0x0A
    STO [UART_DATA]
    LD  [tmp]
    RET

; ============================================================================
; COMPILER WORDS (always immediate — execute even in compile mode)
; ============================================================================

; : (colon) — start compiling a new word
; Builds a linked-list dictionary entry at RAM[0x0400 + dict_ptr]:
;   [link(1)] [name_len(1)] [name_chars(N)] [compile_offset(1)]
; CREATE — shared dict entry builder for : VARIABLE CONSTANT
; Reads word name, writes link+name+offset to user dict, updates latest.
; After return: dict entry is complete, here = compile offset for the word body.
create:
    CALL word                   ; read the name into 0x0100, sets wlen
    ; --- Save entry-start address (current dict_ptr) ---
    LD  [dict_ptr_hi]
    STO [tmp2]                  ; entry_start_hi
    LD  [dict_ptr_lo]
    STO [hash]                  ; entry_start_lo
    ; --- Write 2-byte link = current latest ---
    LD  [latest_hi]
    CALL write_dict_byte
    LD  [latest_lo]
    CALL write_dict_byte
    ; --- Write name_len (already has imm flag if set by caller... wait, no — that's done elsewhere) ---
    LD  [wlen]
    CALL write_dict_byte
    ; --- Copy name chars from word buffer ---
    CLR
    STO [tmp]                   ; i = 0
dc_copy:
    LD  [tmp]
    XOR [wlen]
    JZ  dc_copy_done
    ; Load char from word buffer[i]
    CLR
    STO [IX_HI]
    LD  [tmp]
    STO [0x7FFD]
    LD  [0x0100, x]
    CALL write_dict_byte
    LD  [tmp]
    ADD #1
    STO [tmp]
    JMP dc_copy
dc_copy_done:
    ; --- Write 2-byte compile address (here_hi, here_lo) ---
    LD  [here_hi]
    CALL write_dict_byte
    LD  [here_lo]
    CALL write_dict_byte
    ; --- Update latest = saved entry_start ---
    LD  [tmp2]
    STO [latest_hi]
    LD  [hash]
    STO [latest_lo]
    RET

do_colon:
    ; Enter compile mode BEFORE create.  If `create`'s wdb_oom fires (dict
    ; full), oom_abort_src clears state to 0 — and we want that to stick.
    ; Setting state=1 afterwards would re-enter compile mode at the
    ; prompt, defeating the abort.  Order matters.
    LD  #1
    STO [state]
    CALL create
    JMP compiler_done

do_variable:
    CALL create
    ; Compile: do_lit <addr> exit → word pushes address when called
    LD  #do_lit
    CALL compile_byte
    LD  [varp]
    CALL compile_byte
    CLR
    CALL compile_byte           ; exit token
    ; Bump variable pointer
    LD  [varp]
    ADD #1
    STO [varp]
    JMP compiler_done

do_constant:
    CALL create
    ; Compile: do_lit <TOS> exit → word pushes constant value when called
    POP
    STO [tmp]
    LD  #do_lit
    CALL compile_byte
    LD  [tmp]
    CALL compile_byte
    CLR
    CALL compile_byte           ; exit token
    JMP compiler_done

; ." — compile inline string for printing at runtime
; Reads chars until closing " and compiles: do_dotstr + len + chars
do_dotquote:
    LD  #do_dotstr
    CALL compile_quoted_string
    JMP compiler_done

do_strquote:
    LD  #do_strlit
    CALL compile_quoted_string
    JMP compiler_done

; Shared: emit RR as runtime token, then read chars from input until "
; and compile them with length prefix.  Caller-supplied token + len-prefix +
; chars is the layout both ."  and S"  rely on.
;
; The length-byte address is parked on the *data stack* across the read
; loop because `rch` may trigger a THRU auto-advance, which calls
; block_dispatch / sd_read_r_body and trashes tmp/tmp2/hash/IX.  The data
; stack survives because no SD-side asm touches it.  Without this fix a
; `."`-string that crossed an SD-block boundary patched its length byte
; into a random RAM address, leaving the real length at 0; do_dotstr then
; printed nothing and the IP stepped over the string content as if those
; bytes were tokens — visible as garbage from `WORDS`-style dict scans.
compile_quoted_string:
    CALL compile_byte           ; emit runtime token
    LD  [here_hi]
    PUSH                        ; len_addr_hi on data stack
    LD  [here_lo]
    PUSH                        ; len_addr_lo on data stack
    CLR
    CALL compile_byte           ; placeholder length
    CLR
    STO [fnd]                   ; char count
cqs_loop:
    CALL rch
    LD  [tmp]
    XOR #0x22                   ; '"'
    JZ  cqs_done
    LD  [tmp]
    CALL compile_byte
    LD  [fnd]
    ADD #1
    STO [fnd]
    JMP cqs_loop
cqs_done:
    POP                         ; len_addr_lo
    STO [hash]                  ; reuse hash as scratch (no more rch from here)
    POP                         ; len_addr_hi
    STO [IX_HI]
    LD  [hash]
    STO [0x7FFD]
    LD  [fnd]
    STO [0x0000, x]             ; patch length
    CLR
    STO [IX_HI]                 ; restore IX_HI
    RET

; S" runtime — when this token fires, ip points at the length byte of an
; inline string. Push ( addr_hi addr_lo len ) and advance ip past the string.
strlit_body:
    CALL read_ip_byte           ; length
    STO [tmp]
    CALL inc_ip                 ; ip now at first char
    LD  [ip_hi]
    PUSH                        ; addr_hi
    LD  [ip_lo]
    PUSH                        ; addr_lo
    LD  [tmp]
    PUSH                        ; len
slb_adv:
    LD  [tmp]
    JZ  slb_done
    CALL inc_ip
    LD  [tmp]
    SUB #1
    STO [tmp]
    JMP slb_adv
slb_done:
    RET

; TYPE ( hi lo len -- )  emit len bytes starting at 16-bit addr hi:lo
type_body:
    POP
    STO [tmp]                   ; len
    POP
    STO [hash]                  ; addr_lo (working)
    POP
    STO [tmp2]                  ; addr_hi (working)
type_loop:
    LD  [tmp]
    JZ  type_done
    LD  [tmp2]
    STO [IX_HI]
    LD  [hash]
    STO [0x7FFD]
    LD  [0x0000, x]
    STO [UART_DATA]
    LD  [hash]
    ADD #1
    STO [hash]
    JC  type_carry
    JMP type_dec
type_carry:
    LD  [tmp2]
    ADD #1
    STO [tmp2]
type_dec:
    LD  [tmp]
    SUB #1
    STO [tmp]
    JMP type_loop
type_done:
    CLR
    STO [IX_HI]
    RET

; COUNT ( hi lo -- hi' lo' len )  c-addr → addr+1, length
count_body:
    POP
    STO [tmp]                   ; addr_lo
    POP
    STO [IX_HI]                 ; addr_hi (kept here for read)
    LD  [tmp]
    STO [0x7FFD]
    LD  [0x0000, x]             ; length byte
    STO [tmp2]                  ; save len
    ; compute addr+1
    LD  [tmp]
    ADD #1
    STO [tmp]                   ; lo+1
    JC  count_carry
    LD  [IX_HI]
    PUSH                        ; hi unchanged
    JMP count_emit_lo
count_carry:
    LD  [IX_HI]
    ADD #1
    PUSH                        ; hi+1
count_emit_lo:
    LD  [tmp]
    PUSH                        ; new lo
    LD  [tmp2]
    PUSH                        ; len
    CLR
    STO [IX_HI]
    RET

; B@ body — moved from token space to free up room for new trampolines
bfetch_body:
    LD  #0x02
    STO [IX_HI]
    POP
    STO [0x7FFD]
    LD  [0x0000, x]
    PUSH
    CLR
    STO [IX_HI]
    RET

update_body:
    LD  #0x01
    STO [buf_dirty]
    RET

rot_body:                           ; ( a b c -- b c a )
    POP
    STO [hash]
    POP
    STO [tmp]
    POP
    STO [tmp2]
    LD  [tmp]
    PUSH
    LD  [hash]
    PUSH
    LD  [tmp2]
    PUSH
    RET

; ============================================================================
; Relocated routines — moved out of first-256 to free token address space
; These are only reached via CALL/JMP, never used as 8-bit tokens.
; ============================================================================

; --- 15-bit IP/HERE helpers ---

read_ip_byte:
    LD  [ip_hi]
    STO [IX_HI]
    LD  [ip_lo]
    STO [0x7FFD]
    LD  [0x0000, x]
    RET

inc_ip:
    LD  [ip_lo]
    ADD #1
    STO [ip_lo]
    JC  inc_ip_carry
    RET
inc_ip_carry:
    LD  [ip_hi]
    ADD #1
    STO [ip_hi]
    RET

compile_byte:
    STO [0x13]                  ; save value (dedicated temp — not tmp, not eol!)
    ; Bounds check: refuse to write outside the compile buffer (0x10..0x7E
    ; pages).  Stops a runaway compile from clobbering the data stack at
    ; 0x7F00+ or the dictionary at 0x0400-0x0FFF.
    LD  [here_hi]
    SUB #0x10
    JC  cb_oom                  ; here_hi < 0x10 → outside compile region
    LD  [here_hi]
    SUB #0x7F
    JC  cb_ok                   ; here_hi < 0x7F → fine
    JMP cb_oom                  ; here_hi >= 0x7F → in or past data stack
cb_ok:
    LD  [here_hi]
    STO [IX_HI]
    LD  [here_lo]
    STO [0x7FFD]
    LD  [0x13]
    STO [0x0000, x]
    LD  [here_lo]
    ADD #1
    STO [here_lo]
    JC  cb_carry
    RET
cb_carry:
    LD  [here_hi]
    ADD #1
    STO [here_hi]
    RET
cb_oom:
    ; Out-of-memory: emit '!' and abort source mode.  Without source-abort
    ; a `:` definition pulled from THRU/LOAD would keep dispatching tokens,
    ; each hitting cb_oom and spamming `!`s — and historically that
    ; cascade was the trigger for downstream SD corruption.  Bound it to
    ; at most a handful of `!`s per dispatch step, then drop back to the
    ; UART prompt cleanly.
    LD  #0x21
    STO [UART_DATA]             ; '!'
    CALL oom_abort_src
    RET

; write_dict_byte — write RR at RAM[dict_ptr], dict_ptr++ (16-bit)
; Bounds-checked: refuses writes past 0x0FFF (start of compile buffer) so a
; runaway define can't corrupt compiled word bodies above.
write_dict_byte:
    STO [0x13]
    LD  [dict_ptr_hi]
    SUB #0x10
    JC  wdb_ok                  ; dict_ptr_hi < 0x10 → still in dict region
    LD  #0x21
    STO [UART_DATA]             ; '!'  — dict overflow
    CALL oom_abort_src
    RET
wdb_ok:
    LD  [dict_ptr_hi]
    STO [IX_HI]
    LD  [dict_ptr_lo]
    STO [0x7FFD]
    LD  [0x13]
    STO [0x0000, x]
    LD  [dict_ptr_lo]
    ADD #1
    STO [dict_ptr_lo]
    JC  wdb_carry
    RET
wdb_carry:
    LD  [dict_ptr_hi]
    ADD #1
    STO [dict_ptr_hi]
    RET

; Shared abort path for compile/dict OOM.  Drops compile mode, kills source
; mode, and sets eol so the next `word` call returns wlen=0 — which lands
; us at the `main` prompt cleanly.  Caller emits the user-facing `!` first.
oom_abort_src:
    CLR
    STO [state]                 ; exit compile mode
    STO [thru_act]              ; cancel THRU
    LD  [src_end_lo]
    STO [src_lo]
    LD  [src_end_hi]
    STO [src_hi]                ; src=src_end → no more sourced bytes
    LD  #1
    STO [eol]                   ; force word() to return wlen=0 → main prompts
    RET

; set_ix_faddr — set IX to faddr + RR (offset). Entry: RR = offset.
; After: IX = faddr_hi:faddr + offset, RR destroyed, faddr untouched
set_ix_faddr:
    ADD [faddr]
    STO [0x7FFD]                ; IX_LO = faddr_lo + offset
    JC  sif_carry
    LD  [faddr_hi]
    STO [IX_HI]
    RET
sif_carry:
    LD  [faddr_hi]
    ADD #1
    STO [IX_HI]
    RET

patch_br_body:
    POP
    STO [tmp]                   ; dest_lo
    POP
    STO [tmp2]                  ; dest_hi
    LD  [tmp2]
    STO [IX_HI]
    LD  [tmp]
    STO [0x7FFD]
    LD  [here_hi]
    STO [0x0000, x]
    LD  [tmp]
    ADD #1
    STO [tmp]
    JC  pb_carry
pb_resume:
    LD  [tmp2]
    STO [IX_HI]
    LD  [tmp]
    STO [0x7FFD]
    LD  [here_lo]
    STO [0x0000, x]
    RET
pb_carry:
    LD  [tmp2]
    ADD #1
    STO [tmp2]
    JMP pb_resume

comma16_body:
    POP
    STO [tmp]                   ; lo (safe — compile_byte uses eol, not tmp)
    POP
    CALL compile_byte           ; compile hi
    LD  [tmp]
    CALL compile_byte           ; compile lo
    RET

; --- Common: save ip, execute compiled word at [tmp2:tmp], restore ip ---
; Uses a separate ip return stack at RAM[0x0180+] (128 bytes). Each IP-save
; entry is 2 bytes (ip_hi, ip_lo). User >R/R>/R@ push 1-byte entries on the
; same stack; user must balance those before `;`.
run_user:
    ; Save current ip (2 bytes) to ip return stack
    CLR
    STO [IX_HI]                 ; IX_HI = 0 for page-0 access
    LD  [ipsp]
    STO [0x7FFD]                ; IX = ipsp
    LD  [ip_hi]
    STO [0x0180, x]             ; ip_stack[ipsp] = ip_hi
    LD  [ipsp]
    ADD #1
    STO [0x7FFD]
    LD  [ip_lo]
    STO [0x0180, x]             ; ip_stack[ipsp+1] = ip_lo
    LD  [ipsp]
    ADD #2
    STO [ipsp]                  ; ipsp += 2
    ; Set ip = target from tmp2:tmp
    LD  [tmp2]
    STO [ip_hi]
    LD  [tmp]
    STO [ip_lo]
    CALL next                   ; execute the word
    ; Restore ip from ip return stack
    CLR
    STO [IX_HI]
    LD  [ipsp]
    SUB #2
    STO [ipsp]                  ; ipsp -= 2
    STO [0x7FFD]                ; IX = ipsp
    LD  [0x0180, x]             ; ip_hi = ip_stack[ipsp]
    STO [ip_hi]
    LD  [ipsp]
    ADD #1
    STO [0x7FFD]
    LD  [0x0180, x]             ; ip_lo = ip_stack[ipsp+1]
    STO [ip_lo]
    RET

; --- Numeric base bodies ---
base_body:                          ; ( -- addr )
    LD  #0x1C
    PUSH                            ; push address of base variable
    RET
hex_body:                           ; ( -- )
    LD  #16
    STO [base]
    RET
decimal_body:                       ; ( -- )
    LD  #10
    STO [base]
    RET

; --- Character literals.  Both parse the next whitespace-delimited word from
; the input stream and grab its first byte (already uppercased by `word`).
; CHAR pushes it; [CHAR] is immediate and compiles do_lit + the byte.
char_body:                          ; CHAR ( -- c )
    CALL word                       ; reads next word into 0x0100, sets wlen
    CLR
    STO [IX_HI]                     ; word leaves IX_HI = 0 already, but be safe
    LD  [0x0100]
    PUSH
    RET
bchar_body:                         ; [CHAR] ( -- ) — immediate
    CALL word
    LD  #do_lit
    CALL compile_byte
    CLR
    STO [IX_HI]
    LD  [0x0100]
    CALL compile_byte
    RET

; --- FORGET ( -- ) — parse next word, find it in the unified dict chain,
; then roll back LATEST / DICT_PTR / HERE so the named entry and every entry
; newer than it disappear.  Refuses for builtins (handler_hi == 0) and the
; pre-populated forthwords (handler_hi 0x04..0x0F): their bodies live in ROM
; or in the fixed dict area, so rolling them back would leave dangling state.
; Only user-defined words (handler_hi >= 0x10, body in compile buffer) are
; eligible.  On any failure (no name / not found / protected) we route through
; nfail for the standard `<name> ?\r\n` + source-abort treatment.
forget_body:
    CALL word
    LD  [wlen]
    JZ  fg_fail
    ; faddr = LATEST
    LD  [latest_hi]
    STO [faddr_hi]
    LD  [latest_lo]
    STO [faddr]
fg_loop:
    ; End-of-chain check (latest = 0xFFFF means dict empty)
    LD  [faddr_hi]
    XOR #0xFF
    JZ  fg_check_end_lo
    JMP fg_compare
fg_check_end_lo:
    LD  [faddr]
    XOR #0xFF
    JZ  fg_fail
fg_compare:
    ; Read entry[2] = name_len | imm flag, mask flag, compare with wlen
    LD  #2
    CALL set_ix_faddr
    LD  [0x0000, x]
    AND #0x7F
    XOR [wlen]
    JZ  fg_len_ok
    JMP fg_next
fg_len_ok:
    CLR
    STO [tmp]                       ; i = 0
fg_cmp:
    LD  [tmp]
    XOR [wlen]
    JZ  fg_found
    LD  [tmp]
    ADD #3
    CALL set_ix_faddr
    LD  [0x0000, x]
    STO [tmp2]                      ; dict char
    CLR
    STO [IX_HI]
    LD  [tmp]
    STO [0x7FFD]
    LD  [0x0100, x]                 ; word-buf char
    XOR [tmp2]
    JZ  fg_cmp_next
    JMP fg_next
fg_cmp_next:
    LD  [tmp]
    ADD #1
    STO [tmp]
    JMP fg_cmp
fg_next:
    ; Follow link to previous entry
    LD  #0
    CALL set_ix_faddr
    LD  [0x0000, x]
    STO [hash]                      ; link_hi
    LD  #1
    CALL set_ix_faddr
    LD  [0x0000, x]
    STO [tmp]                       ; link_lo
    LD  [hash]
    STO [faddr_hi]
    LD  [tmp]
    STO [faddr]
    JMP fg_loop
fg_found:
    ; faddr points at the matching entry.  Read handler_hi at faddr[3+wlen]
    ; — if it's < 0x10, this is a kernel word (builtin or pre-forthword)
    ; and we refuse.
    LD  [wlen]
    ADD #3
    CALL set_ix_faddr
    LD  [0x0000, x]
    STO [hash]                      ; handler_hi
    SUB #0x10
    JC  fg_fail                     ; carry → handler_hi < 0x10 → protected
    ; Read handler_lo at faddr[4+wlen]
    LD  [wlen]
    ADD #4
    CALL set_ix_faddr
    LD  [0x0000, x]
    STO [tmp]                       ; handler_lo
    ; HERE = handler (= compile-buffer body addr)
    LD  [hash]
    STO [here_hi]
    LD  [tmp]
    STO [here_lo]
    ; DICT_PTR = faddr (the entry's address — its bytes are now reusable)
    LD  [faddr_hi]
    STO [dict_ptr_hi]
    LD  [faddr]
    STO [dict_ptr_lo]
    ; LATEST = link field of the forgotten entry (= previous entry in chain)
    LD  #0
    CALL set_ix_faddr
    LD  [0x0000, x]
    STO [latest_hi]
    LD  #1
    CALL set_ix_faddr
    LD  [0x0000, x]
    STO [latest_lo]
    RET
fg_fail:
    JMP nfail                       ; "<name> ?\r\n" + source-abort

; --- ABORT ( i*x -- ) — clear data stack + IP-return stack, exit compile
; mode, kill source mode, return to the prompt loop.  Modeled on nfail's
; source-abort path, plus stack resets that nfail leaves alone.
abort_body:
    LD  #0xFB
    STO [0x7FFC]                    ; data SP back to top
    CLR
    STO [ipsp]                      ; IP-return stack empty
    STO [state]                     ; exit compile mode
    STO [thru_act]                  ; cancel THRU
    LD  [src_end_lo]
    STO [src_lo]
    LD  [src_end_hi]
    STO [src_hi]                    ; src=src_end → no more sourced bytes
    JMP interp                      ; let interp drain remaining UART chars
                                    ; (eol on the line's CR will trigger main)

; --- ABORT" — immediate: compile `do_abrtstr` + length-prefixed string.
; Reuses the same compile_quoted_string helper as `."` and S".
abrtquote_body:
    LD  #do_abrtstr
    CALL compile_quoted_string
    JMP compiler_done

; --- Runtime body for ABORT".  IP points at [len, char, ...] in the
; compiled body.  Pop the flag from the data stack:
;   flag != 0 → print the message, then ABORT (stacks reset, prompt).
;   flag == 0 → skip past the message and continue.
abrtstr_body:
    POP                             ; flag
    JZ  abrt_skip                   ; flag == 0 → just skip the message
    ; flag != 0 — print the message then jump to abort_body.
    CALL read_ip_byte               ; len → RR
    STO [tmp]                       ; tmp = len
    CALL inc_ip                     ; advance past length byte
    CLR
    STO [tmp2]                      ; index = 0
abrt_print_loop:
    LD  [tmp2]
    XOR [tmp]
    JZ  abort_body                  ; tail-call: clears stacks + prompt
    CALL read_ip_byte
    STO [UART_DATA]
    CALL inc_ip
    LD  [tmp2]
    ADD #1
    STO [tmp2]
    JMP abrt_print_loop
abrt_skip:
    ; flag == 0 — just skip past the inline string (len + chars)
    CALL read_ip_byte               ; len
    STO [tmp]
    CALL inc_ip
    CLR
    STO [tmp2]
abrt_skip_loop:
    LD  [tmp2]
    XOR [tmp]
    JZ  abrt_skip_done
    CALL inc_ip
    LD  [tmp2]
    ADD #1
    STO [tmp2]
    JMP abrt_skip_loop
abrt_skip_done:
    RET

; ============================================================================
; Stage-1 cooperative multi-tasking — PAUSE / TASK
; ============================================================================
; Both tasks share the data stack (0x7E00..0x7EFB), the dictionary, the
; compile buffer, the block cache and BASE.  Each task has its own SP, IP,
; IPSP and a copy of the IP-return-stack contents (max 16 bytes — covers
; nesting up to 8 frames, which is deep enough for the ROM SD path).
;
; HW call stack contract: PAUSE may only be called as a top-level token in
; a compiled word (i.e., from inside `next`).  At that point the HW stack
; holds {interp's CALL run_user, run_user's CALL next, next's CALLI here}.
; Both tasks share that frame layout because they're driven by the same
; `next` loop, so RET from pause_body returns into the CORRECT next-loop
; iteration regardless of which task we just switched to.
;
; A task that exits its top-level word (token 0 → next_done → RET) will
; unwind through run_user's epilogue using the CURRENT task's IPSP, which
; corrupts state.  Therefore tasks installed via TASK must be infinite
; loops (`: T1 BEGIN ... PAUSE 0 UNTIL ;`).  The "main" task (task0) may
; return to interp normally — the saved state of task1 simply becomes
; dormant until the next PAUSE-equipped word is launched.
; ============================================================================

; --- PAUSE ( -- )  Cooperative round-robin task switch.
pause_body:
    ; Step 1: peek at OTHER task's status.  If stopped, fast-RET.
    LD  [active_task]
    XOR #1                          ; OTHER index = active XOR 1
    JZ  ps_other_t0
    LD  #TASK1_BASE
    JMP ps_check_other
ps_other_t0:
    LD  #TASK0_BASE
ps_check_other:
    STO [tmp2]                      ; tmp2 = OTHER's struct base
    ADD #4                          ; +4 = status
    STO [0x7FFD]
    CLR
    STO [IX_HI]
    LD  [0x0000, x]                 ; status
    JZ  ps_do_switch                ; runnable
    RET                             ; stopped → no switch

ps_do_switch:
    ; Step 2: save current task's state into its struct.
    LD  [active_task]
    JZ  ps_curr_t0
    LD  #TASK1_BASE
    JMP ps_save_state
ps_curr_t0:
    LD  #TASK0_BASE
ps_save_state:
    STO [tmp]                       ; tmp = current task's base

    ; +0 SP
    STO [0x7FFD]
    LD  [0x7FFC]
    STO [0x0000, x]
    ; +1 IP_HI
    LD  [tmp]
    ADD #1
    STO [0x7FFD]
    LD  [ip_hi]
    STO [0x0000, x]
    ; +2 IP_LO
    LD  [tmp]
    ADD #2
    STO [0x7FFD]
    LD  [ip_lo]
    STO [0x0000, x]
    ; +3 IPSP
    LD  [tmp]
    ADD #3
    STO [0x7FFD]
    LD  [ipsp]
    STO [0x0000, x]

    CALL save_ip_stack              ; +5..+5+ipsp ← RAM[0x180..0x180+ipsp]

    ; Save current BASE into tb_save[active_task] so each task sees its own
    ; HEX/DECIMAL state across switches.  IX_HI is still 0 from earlier.
    LD  [active_task]
    ADD #tb_save
    STO [0x7FFD]
    LD  [base]
    STO [0x0000, x]

    ; Step 3: toggle active_task.
    LD  [active_task]
    XOR #1
    STO [active_task]

    ; Step 4: restore OTHER task's state (tmp2 = OTHER base from step 1).
    LD  [tmp2]
    STO [tmp]                       ; tmp = base for restore_ip_stack

    STO [0x7FFD]
    CLR
    STO [IX_HI]
    LD  [0x0000, x]                 ; +0 SP
    STO [0x7FFC]
    ; +1 IP_HI
    LD  [tmp]
    ADD #1
    STO [0x7FFD]
    LD  [0x0000, x]
    STO [ip_hi]
    ; +2 IP_LO
    LD  [tmp]
    ADD #2
    STO [0x7FFD]
    LD  [0x0000, x]
    STO [ip_lo]
    ; +3 IPSP
    LD  [tmp]
    ADD #3
    STO [0x7FFD]
    LD  [0x0000, x]
    STO [ipsp]

    CALL restore_ip_stack           ; RAM[0x180..0x180+ipsp] ← +5..+5+ipsp

    ; Restore BASE from tb_save[active_task] (active_task is now the NEW one).
    LD  [active_task]
    ADD #tb_save
    STO [0x7FFD]
    LD  [0x0000, x]
    STO [base]

    CLR
    STO [IX_HI]                     ; restore IX_HI=0 for normal callers
    RET

; --- save_ip_stack: copy [0x0180..0x0180+ipsp] → RAM[tmp+5..tmp+5+ipsp].
;     Pre: tmp = task base, ipsp = byte count.
;     Trashes hash, eol, IX.  Leaves IX_HI=0.
save_ip_stack:
    CLR
    STO [hash]
sis_loop:
    LD  [hash]
    XOR [ipsp]
    JZ  sis_done
    ; src: RAM[0x0180 + counter]
    LD  #0x01
    STO [IX_HI]
    LD  [hash]
    ADD #0x80
    STO [0x7FFD]
    LD  [0x0000, x]
    STO [eol]
    ; dst: RAM[tmp + 5 + counter]
    CLR
    STO [IX_HI]
    LD  [tmp]
    ADD #5
    ADD [hash]
    STO [0x7FFD]
    LD  [eol]
    STO [0x0000, x]
    LD  [hash]
    ADD #1
    STO [hash]
    JMP sis_loop
sis_done:
    CLR
    STO [IX_HI]
    RET

; --- restore_ip_stack: copy RAM[tmp+5..tmp+5+ipsp] → [0x0180..0x0180+ipsp].
;     Pre: tmp = task base, ipsp = byte count.
;     Trashes hash, eol, IX.  Leaves IX_HI=0.
restore_ip_stack:
    CLR
    STO [hash]
ris_loop:
    LD  [hash]
    XOR [ipsp]
    JZ  ris_done
    ; src: RAM[tmp + 5 + counter]
    CLR
    STO [IX_HI]
    LD  [tmp]
    ADD #5
    ADD [hash]
    STO [0x7FFD]
    LD  [0x0000, x]
    STO [eol]
    ; dst: RAM[0x0180 + counter]
    LD  #0x01
    STO [IX_HI]
    LD  [hash]
    ADD #0x80
    STO [0x7FFD]
    LD  [eol]
    STO [0x0000, x]
    LD  [hash]
    ADD #1
    STO [hash]
    JMP ris_loop
ris_done:
    CLR
    STO [IX_HI]
    RET

; --- TASK ( xt_hi xt_lo -- ) install xt as task1's initial IP.
;     Sets task1.SP=0xFB, IPSP=0, STATUS=0 (runnable).  No switch — the
;     next PAUSE in task0 will round-robin into task1.
task_body:
    POP                             ; xt_lo
    STO [tmp]
    POP                             ; xt_hi
    STO [tmp2]

    CLR
    STO [IX_HI]
    LD  #TASK1_BASE
    STO [0x7FFD]                    ; +0 SP
    LD  #0xFB
    STO [0x0000, x]
    LD  #TASK1_BASE
    ADD #1
    STO [0x7FFD]                    ; +1 IP_HI
    LD  [tmp2]
    STO [0x0000, x]
    LD  #TASK1_BASE
    ADD #2
    STO [0x7FFD]                    ; +2 IP_LO
    LD  [tmp]
    STO [0x0000, x]
    LD  #TASK1_BASE
    ADD #3
    STO [0x7FFD]                    ; +3 IPSP
    CLR
    STO [0x0000, x]
    LD  #TASK1_BASE
    ADD #4
    STO [0x7FFD]                    ; +4 STATUS
    CLR
    STO [0x0000, x]                 ; runnable
    LD  #10
    STO [0x1F]                      ; reset task1 BASE save = 10 (DECIMAL)
    RET

; --- STOP ( -- ) mark current task as stopped, then either switch (if the
;     other task is runnable) or abort (if both are stopped now).
;
;     Allows a user task to terminate gracefully:  `: T1 ... STOP ; ' T1 TASK`.
;     Without STOP, a task1 hitting `;` would unwind through run_user with
;     ipsp=0 and corrupt the IP-stack.  STOP avoids that path entirely:
;       - other runnable → tail-call pause_body, switch as usual.  Resumed
;         caller pops `;` cleanly via its own ipsp.
;       - both stopped   → reset to single-task baseline (active=task0,
;         task0.status=0, task1.status=1) and JMP abort_body.  abort_body
;         resets the data + IP-return stacks and falls back to interp.
;
;     HW-stack: same constraint as PAUSE — must be invoked as a NEXT-loop
;     token (one CALLI frame above us).  The abort-body path leaks the
;     {interp, run_user, next} frames just like an `ABORT` does, so a few
;     STOP-with-both-stopped cycles are fine; many would eventually exhaust
;     the 16-deep HW call stack.
stop_body:
    ; Mark current task as stopped (struct[+4] = 1).
    LD  [active_task]
    JZ  st_curr_t0
    LD  #TASK1_BASE
    JMP st_mark
st_curr_t0:
    LD  #TASK0_BASE
st_mark:
    ADD #4
    STO [0x7FFD]
    CLR
    STO [IX_HI]
    LD  #1
    STO [0x0000, x]                 ; current.status = 1

    ; Inspect OTHER task's status.
    LD  [active_task]
    XOR #1
    JZ  st_other_t0
    LD  #TASK1_BASE
    JMP st_check_other
st_other_t0:
    LD  #TASK0_BASE
st_check_other:
    ADD #4
    STO [0x7FFD]
    LD  [0x0000, x]                 ; other.status
    JZ  st_switch                   ; runnable → tail-call PAUSE
    ; Both tasks stopped → reset to clean single-task state, then abort.
    CLR
    STO [active_task]               ; active = task0 (the interp thread)
    LD  #TASK0_BASE
    ADD #4
    STO [0x7FFD]
    CLR
    STO [0x0000, x]                 ; task0.status = 0 (runnable for next user
                                    ;                  invocation)
    LD  #TASK1_BASE
    ADD #4
    STO [0x7FFD]
    LD  #1
    STO [0x0000, x]                 ; task1.status = 1 (no auto-resume)
    JMP abort_body                  ; reset stacks, fall back to interp
st_switch:
    JMP pause_body                  ; tail-call: pause_body's RET goes back to
                                    ; next, which then runs the OTHER task's
                                    ; first post-PAUSE token.

; --- Hex nibble print helper (used by pnibble callers, not by do_dot anymore) ---
pnib:
    STO [tmp2]
    SUB #0x0A
    JC  pd
    ADD #0x41
    STO [UART_DATA]
    RET
pd:
    LD  [tmp2]
    ADD #0x30
    STO [UART_DATA]
    RET

; --- Print body for do_dot.  Decimal: signed -128..127, 1-4 chars + trailing
; space.  Hex: unsigned, always 2 nibbles + trailing space (padded so columns
; line up during memory inspection).  Dispatch on `base`.
dot_body:
    POP
    STO [tmp]                       ; n
    LD  [base]
    SUB #0x10
    JZ  dot_hex                     ; base=16 → hex print
    LD  [tmp]
    AND #0x80                       ; test sign bit
    JZ  dot_abs                     ; positive → straight to digits
    LD  #0x2D
    STO [UART_DATA]                 ; print '-'
    CLR
    SUB [tmp]
    STO [tmp]                       ; tmp = -tmp (abs value)
dot_abs:
    CLR
    STO [tmp2]                      ; hundreds counter
dot_hloop:
    LD  [tmp]
    SUB #100
    JC  dot_hdone                   ; borrow → n < 100 → stop
    STO [tmp]
    LD  [tmp2]
    ADD #1
    STO [tmp2]
    JMP dot_hloop
dot_hdone:
    LD  [tmp2]
    JZ  dot_tens_cond               ; hundreds == 0 → tens is conditional
    ADD #0x30
    STO [UART_DATA]                 ; print hundreds
    CLR
    STO [tmp2]
dot_tfloop:
    LD  [tmp]
    SUB #10
    JC  dot_tfdone
    STO [tmp]
    LD  [tmp2]
    ADD #1
    STO [tmp2]
    JMP dot_tfloop
dot_tfdone:
    LD  [tmp2]
    ADD #0x30
    STO [UART_DATA]                 ; forced tens (even if 0)
    JMP dot_units
dot_tens_cond:
    CLR
    STO [tmp2]
dot_tcloop:
    LD  [tmp]
    SUB #10
    JC  dot_tcdone
    STO [tmp]
    LD  [tmp2]
    ADD #1
    STO [tmp2]
    JMP dot_tcloop
dot_tcdone:
    LD  [tmp2]
    JZ  dot_units                   ; no tens → skip
    ADD #0x30
    STO [UART_DATA]                 ; conditional tens
dot_units:
    LD  [tmp]
    ADD #0x30
    STO [UART_DATA]                 ; units
    LD  #0x20
    STO [UART_DATA]                 ; trailing space
    RET

; --- 2SWAP body — moved above 0x100 to free a primitive trampoline slot.
swap2_body:                         ; ( a b c d -- c d a b )
    POP
    STO [tmp]                       ; d
    POP
    STO [tmp2]                      ; c
    POP
    STO [hash]                      ; b
    POP
    STO [fnd]                       ; a (reuse fnd as temp)
    LD  [tmp2]
    PUSH                            ; c
    LD  [tmp]
    PUSH                            ; d
    LD  [fnd]
    PUSH                            ; a
    LD  [hash]
    PUSH                            ; b
    RET

; --- Hex print path (8-bit, unsigned, padded to 2 chars + trailing space).
; Reached from dot_body when base==16.  tmp holds the value to print.
dot_hex:
    LD  [tmp]
    SHR
    SHR
    SHR
    SHR                             ; high nibble (logical shift, top bits zero)
    CALL pnib
    LD  [tmp]
    AND #0x0F                       ; low nibble
    CALL pnib
    LD  #0x20
    STO [UART_DATA]                 ; trailing space
    RET

; ============================================================================
; >R / R> / R@ bodies — operate on IP return stack at 0x0180+
; User must balance >R and R> within each definition so the underlying
; 2-byte IP-save entry (pushed by run_user) stays intact.
; ============================================================================
to_r_body:                          ; >R ( n -- R: -- n )
    POP
    STO [tmp]
    CLR
    STO [IX_HI]
    LD  [ipsp]
    STO [0x7FFD]                    ; IX = ipsp
    LD  [tmp]
    STO [0x0180, x]                 ; R[ipsp] = n
    LD  [ipsp]
    ADD #1
    STO [ipsp]                      ; ipsp += 1
    RET

from_r_body:                        ; R> ( -- n R: n -- )
    CLR
    STO [IX_HI]
    LD  [ipsp]
    SUB #1
    STO [ipsp]                      ; ipsp -= 1
    STO [0x7FFD]                    ; IX = new ipsp (points at popped entry)
    LD  [0x0180, x]
    PUSH
    RET

r_fetch_body:                       ; R@ ( -- n R: n -- n )
    CLR
    STO [IX_HI]
    LD  [ipsp]
    SUB #1
    STO [0x7FFD]                    ; IX = ipsp - 1 (peek without popping)
    LD  [0x0180, x]
    PUSH
    RET

; ============================================================================
; DO / LOOP runtime bodies
; ----------------------------------------------------------------------------
; Compiled layout:   do_do  <body tokens>  do_loop  <target_hi> <target_lo>
; Branch target points at first byte after do_do (start of body).
;
; R-stack during loop: ..., prev_ip_hi, prev_ip_lo, limit, index
;   → I (== R@) reads index = R[ipsp-1]; limit = R[ipsp-2].
; User >R/R> inside loop body is unsafe (clobbers index/limit).
; ============================================================================
do_rt_body:                         ; ( limit index -- R: -- limit index )
    POP
    STO [tmp]                       ; index
    POP
    STO [tmp2]                      ; limit
    CLR
    STO [IX_HI]
    LD  [ipsp]
    STO [0x7FFD]                    ; IX = ipsp
    LD  [tmp2]
    STO [0x0180, x]                 ; R[ipsp] = limit
    LD  [ipsp]
    ADD #1
    STO [0x7FFD]                    ; IX = ipsp + 1
    LD  [tmp]
    STO [0x0180, x]                 ; R[ipsp+1] = index
    LD  [ipsp]
    ADD #2
    STO [ipsp]                      ; ipsp += 2
    RET

loop_rt_body:                       ; increment index, compare limit, branch/pop
    CLR
    STO [IX_HI]
    LD  [ipsp]
    SUB #1
    STO [0x7FFD]                    ; IX = ipsp-1 (index slot)
    LD  [0x0180, x]
    ADD #1
    STO [0x0180, x]                 ; index++
    STO [tmp]                       ; tmp = new index
    LD  [ipsp]
    SUB #2
    STO [0x7FFD]                    ; IX = ipsp-2 (limit slot)
    LD  [0x0180, x]                 ; RR = limit
    SUB [tmp]
    JZ  loop_done                   ; index == limit → exit loop
    JMP do_branch                   ; else take the 2-byte branch target
loop_done:
    LD  [ipsp]
    SUB #2
    STO [ipsp]                      ; pop limit+index
    CALL inc_ip                     ; skip target_hi
    CALL inc_ip                     ; skip target_lo
    RET

; +LOOP ( step -- ) — adds step to index, exits when the (limit-1, limit)
; boundary is crossed.  Forth-83 modular semantics: works on the full 0..255
; circle, so countdown loops with limit=0 wrap correctly past 0/255.
;
; The previous sign-XOR-of-(idx-limit) test detected crossings of (limit+128),
; not of limit itself — fine for limit=0 step=+1 in 0..127, broken for any
; case that traversed the 127↔128 cell (notably `200 0 DO ... -1 +LOOP`
; bailed out at idx=128).
;
; Cross detection per step direction (all unsigned, mod 256):
;   step > 0: cross iff (limit - 1 - old) < step.
;             i.e., limit is in the half-open arc (old, old + step].
;   step < 0: cross iff (old - limit) < |step|.
;             i.e., limit is in the half-open arc (old, old - |step|].
plus_loop_rt_body:
    POP
    STO [tmp2]                      ; tmp2 = step
    CLR
    STO [IX_HI]
    LD  [ipsp]
    SUB #1
    STO [0x7FFD]                    ; IX = ipsp-1 (index slot)
    LD  [0x0180, x]
    STO [tmp]                       ; tmp = old index
    ADD [tmp2]
    STO [0x0180, x]                 ; R[top] = old + step (new index)
    LD  [ipsp]
    SUB #2
    STO [0x7FFD]                    ; IX = ipsp-2 (limit slot)
    LD  [0x0180, x]
    STO [fnd]                       ; fnd = limit
    LD  [tmp2]
    AND #0x80
    JZ  pl_pos                      ; step >= 0
    ; step < 0: cross iff (old - limit) < |step|
    CLR
    SUB [tmp2]                      ; RR = -step = |step|
    STO [tmp2]                      ; tmp2 = |step|
    LD  [tmp]
    SUB [fnd]                       ; RR = old - limit (mod 256)
    SUB [tmp2]                      ; - |step|
    JC  plus_loop_exit              ; borrow → (old-limit) < |step| → cross
    JMP plus_loop_back
pl_pos:
    ; step >= 0: cross iff (limit - 1 - old) < step
    LD  [fnd]
    SUB [tmp]                       ; limit - old (mod 256)
    SUB #1                          ; - 1
    SUB [tmp2]                      ; - step
    JC  plus_loop_exit              ; borrow → (limit-1-old) < step → cross
    JMP plus_loop_back
plus_loop_exit:
    LD  [ipsp]
    SUB #2
    STO [ipsp]                      ; pop limit+index
    CALL inc_ip
    CALL inc_ip
    RET
plus_loop_back:
    JMP do_branch

; LEAVE runtime: pop limit+index from R-stack, branch to addr after the LOOP.
; The 2-byte target is filled in by the LEAVE-chain patcher in LOOP/+LOOP.
leave_rt_body:
    LD  [ipsp]
    SUB #2
    STO [ipsp]
    JMP do_branch                   ; reuse: reads 2-byte target from IP stream

; LEAVE-chain support — uses globals lvh:lvl as the chain head so IF/THEN
; state on the data stack doesn't interfere. Single-DO-with-LEAVE scope only:
; nesting a DO+LEAVE inside another DO+LEAVE is not supported.

lv_init_body:                       ; reset chain to empty
    LD  #0xFF
    STO [lvh]
    STO [lvl]
    RET

lv_emit_body:                       ; ( tok -- ) compile tok + chained placeholder
    POP
    CALL compile_byte               ; emit caller-supplied token
    LD  [lvh]
    STO [tmp]                       ; saved old chain hi
    LD  [lvl]
    STO [tmp2]                      ; saved old chain lo
    LD  [here_hi]
    STO [lvh]                       ; new chain head = HERE (placeholder addr)
    LD  [here_lo]
    STO [lvl]
    LD  [tmp]
    CALL compile_byte               ; placeholder = old chain (next link)
    LD  [tmp2]
    CALL compile_byte
    RET

lv_save_body:                       ; ( -- old_h old_l ) save+reset
    LD  [lvh]
    PUSH
    LD  [lvl]
    PUSH
    LD  #0xFF
    STO [lvh]
    STO [lvl]
    RET

lv_restore_body:                    ; ( old_h old_l -- )
    POP
    STO [lvl]
    POP
    STO [lvh]
    RET

; EXECUTE ( xt_hi xt_lo -- ) — call word at xt.
; xt_hi == 0 → ROM builtin (CALLI handler_lo). Else user word (run_user).
execute_body:
    POP
    STO [tmp]                       ; xt_lo
    POP                             ; xt_hi in RR
    JZ  exec_builtin
    STO [tmp2]                      ; xt_hi (for run_user)
    CALL run_user
    RET
exec_builtin:
    LD  [tmp]
    CALLI                           ; tail-call ROM builtin
    RET

; ' ( -- xt_hi xt_lo ) — parse next input word, look up, push 2-byte xt.
; Walks the unified dictionary chain. Prints '?' and aborts to interp on miss.
tick_body:
    CALL word
    LD  [wlen]
    JZ  tick_fail
    LD  [latest_hi]
    STO [faddr_hi]
    LD  [latest_lo]
    STO [faddr]
    LD  [latest_hi]
    XOR #0xFF
    JZ  tk_chk_lo_start
    JMP tk_loop
tk_chk_lo_start:
    LD  [latest_lo]
    XOR #0xFF
    JZ  tick_fail
tk_loop:
    LD  #2
    CALL set_ix_faddr
    LD  [0x0000, x]
    AND #0x7F
    XOR [wlen]
    JZ  tk_len_ok
    JMP tk_next
tk_len_ok:
    CLR
    STO [tmp]
tk_cmp:
    LD  [tmp]
    XOR [wlen]
    JZ  tk_found
    LD  [tmp]
    ADD #3
    CALL set_ix_faddr
    LD  [0x0000, x]
    STO [tmp2]
    CLR
    STO [IX_HI]
    LD  [tmp]
    STO [0x7FFD]
    LD  [0x0100, x]
    XOR [tmp2]
    JZ  tk_cmp_next
    JMP tk_next
tk_cmp_next:
    LD  [tmp]
    ADD #1
    STO [tmp]
    JMP tk_cmp
tk_found:
    LD  [wlen]
    ADD #3
    CALL set_ix_faddr
    LD  [0x0000, x]
    PUSH                            ; handler_hi
    LD  [wlen]
    ADD #4
    CALL set_ix_faddr
    LD  [0x0000, x]
    PUSH                            ; handler_lo
    RET
tk_next:
    LD  #0
    CALL set_ix_faddr
    LD  [0x0000, x]
    STO [hash]                      ; link_hi
    LD  #1
    CALL set_ix_faddr
    LD  [0x0000, x]
    STO [tmp]                       ; link_lo
    LD  [hash]
    XOR #0xFF
    JZ  tk_chk_link_lo
    JMP tk_follow
tk_chk_link_lo:
    LD  [tmp]
    XOR #0xFF
    JZ  tick_fail
tk_follow:
    LD  [hash]
    STO [faddr_hi]
    LD  [tmp]
    STO [faddr]
    JMP tk_loop
tick_fail:
    ; Reuse nfail's "<word> ?\r\n" + source-abort behaviour. wlen and the
    ; word buffer are still set from `tick_body`'s preceding `CALL word`
    ; (or wlen=0 if user typed nothing — nfail handles that too).
    JMP nfail

lv_finish_body:                     ; LOOP/+LOOP compile-time: walk chain
    LD  [lvh]
    STO [faddr_hi]
    LD  [lvl]
    STO [faddr]
    LD  #0xFF
    STO [lvh]
    STO [lvl]                       ; defensive reset
lpp_loop:
    LD  [faddr_hi]
    XOR #0xFF
    JZ  lpp_check_lo
    JMP lpp_step
lpp_check_lo:
    LD  [faddr]
    XOR #0xFF
    JZ  lpp_done
lpp_step:
    ; Read next-link bytes BEFORE overwriting them
    LD  #0
    CALL set_ix_faddr
    LD  [0x0000, x]
    STO [tmp]                       ; saved next_hi
    LD  #1
    CALL set_ix_faddr
    LD  [0x0000, x]
    STO [tmp2]                      ; saved next_lo
    ; Patch placeholder with HERE
    LD  #0
    CALL set_ix_faddr
    LD  [here_hi]
    STO [0x0000, x]
    LD  #1
    CALL set_ix_faddr
    LD  [here_lo]
    STO [0x0000, x]
    ; Advance to next link
    LD  [tmp]
    STO [faddr_hi]
    LD  [tmp2]
    STO [faddr]
    JMP lpp_loop
lpp_done:
    CLR
    STO [IX_HI]
    RET

; ============================================================================
; D+ / D- bodies — 16-bit add/sub via ADC carry chain
; Stack convention: ... lo_hi (SOS=lo, TOS=hi) — two bytes per double-cell
; ============================================================================
dplus_body:                        ; ( lo1 hi1 lo2 hi2 -- lo hi )
    POP
    STO [tmp]                       ; hi2
    POP
    STO [tmp2]                      ; lo2
    POP
    STO [hash]                      ; hi1
    POP                              ; lo1 in RR
    ADD [tmp2]                      ; lo1 + lo2, carry latched
    PUSH                            ; lo_sum
    LD  [hash]
    ADD [tmp], carry                ; hi1 + hi2 + carry
    PUSH                            ; hi_sum
    RET

dminus_body:                        ; ( lo1 hi1 lo2 hi2 -- lo hi )
    POP
    STO [tmp]                       ; hi2
    POP
    STO [tmp2]                      ; lo2
    POP
    STO [hash]                      ; hi1
    POP                              ; lo1 in RR
    SUB [tmp2]                      ; lo1 - lo2, carry=1 if borrow
    PUSH                            ; lo_diff
    LD  [hash]
    SUB [tmp], carry                ; hi1 - hi2 - borrow
    PUSH                            ; hi_diff
    RET

; ============================================================================
; D. body — unsigned 16-bit decimal print (0..65535, 1-5 digits + space)
; ============================================================================
; Strategy: repeated 16-bit subtract of {10000, 1000, 100, 10}, then units.
; Each divisor pass uses a helper routine that subtracts the divisor while the
; 16-bit dividend is >=, counting iterations as the digit value.
;
; Layout: tmp=value_lo, tmp2=value_hi, hash=current digit count, fnd=printed-flag
;
; Uses RAM[0x18] and [0x19] as divisor_lo/hi scratch. (Formerly overlapped
; with IP return stack; since the IP stack moved to 0x0180+, this region is
; plain scratch and safe to use anywhere.)
; ============================================================================
.data ddot_dlo      0x18
.data ddot_dhi      0x19
ddot_body:
    POP
    STO [tmp2]                      ; value_hi
    POP
    STO [tmp]                       ; value_lo
    CLR
    STO [fnd]                       ; printed-flag (0 = haven't printed yet)

    ; --- 10000 (0x2710) ---
    LD  #0x10
    STO [ddot_dlo]
    LD  #0x27
    STO [ddot_dhi]
    CALL ddot_digit
    ; --- 1000 (0x03E8) ---
    LD  #0xE8
    STO [ddot_dlo]
    LD  #0x03
    STO [ddot_dhi]
    CALL ddot_digit
    ; --- 100 (0x0064) ---
    LD  #0x64
    STO [ddot_dlo]
    CLR
    STO [ddot_dhi]
    CALL ddot_digit
    ; --- 10 (0x000A) ---
    LD  #0x0A
    STO [ddot_dlo]
    CALL ddot_digit
    ; --- units (always) ---
    LD  [tmp]
    ADD #0x30
    STO [UART_DATA]
    LD  #0x20
    STO [UART_DATA]                 ; trailing space
    RET

; ddot_digit: repeatedly sub the 16-bit divisor (ddot_dhi:ddot_dlo) from the
; 16-bit value (tmp2:tmp) as long as it fits. Count iterations and emit the
; digit if nonzero OR if any earlier digit was already printed.
ddot_digit:
    CLR
    STO [hash]                      ; digit count = 0
ddot_loop:
    ; trial subtract: new_lo = tmp - ddot_dlo, new_hi = tmp2 - ddot_dhi - borrow
    LD  [tmp]
    SUB [ddot_dlo]
    STO [eol]                       ; provisional new_lo (reuse eol as scratch)
    LD  [tmp2]
    SUB [ddot_dhi], carry
    JC  ddot_done                   ; borrow out → value < divisor → stop
    STO [tmp2]                      ; commit new_hi
    LD  [eol]
    STO [tmp]                       ; commit new_lo
    LD  [hash]
    ADD #1
    STO [hash]
    JMP ddot_loop
ddot_done:
    LD  [hash]
    JZ  ddot_maybe_skip             ; digit is 0
    ADD #0x30
    STO [UART_DATA]
    LD  #1
    STO [fnd]                       ; force-print subsequent digits
    RET
ddot_maybe_skip:
    LD  [fnd]
    JZ  ddot_ret                    ; suppress leading zero
    LD  #0x30
    STO [UART_DATA]                 ; print '0' for middle zeros
ddot_ret:
    RET

; ============================================================================
; WORDS helpers — print word names from a dictionary page
; ============================================================================

; Print all words from user dict chain (faddr_hi:faddr = starting entry, or 0xFFFF for empty)
dw_list_0400:
    LD  [faddr_hi]
    XOR #0xFF
    JZ  dw4_check_lo_start
    JMP dw4_loop
dw4_check_lo_start:
    LD  [faddr]
    XOR #0xFF
    JZ  dw_ret
dw4_loop:
    ; Read name_len at entry[2]
    LD  #2
    CALL set_ix_faddr
    LD  [0x0000, x]
    AND #0x7F
    STO [tmp]                   ; length
    CLR
    STO [tmp2]                  ; i = 0
dw4_char:
    LD  [tmp2]
    XOR [tmp]
    JZ  dw4_done
    LD  [tmp2]
    ADD #3
    CALL set_ix_faddr
    LD  [0x0000, x]
    STO [UART_DATA]
    LD  [tmp2]
    ADD #1
    STO [tmp2]
    JMP dw4_char
dw4_done:
    LD  #0x20
    STO [UART_DATA]
    ; Follow 2-byte link: entry[0] = link_hi, entry[1] = link_lo
    LD  #0
    CALL set_ix_faddr
    LD  [0x0000, x]
    STO [hash]
    LD  #1
    CALL set_ix_faddr
    LD  [0x0000, x]
    STO [tmp2]
    ; Check for end-of-chain (0xFFFF)
    LD  [hash]
    XOR #0xFF
    JZ  dw4_check_lo_link
    JMP dw4_follow
dw4_check_lo_link:
    LD  [tmp2]
    XOR #0xFF
    JZ  dw_ret
dw4_follow:
    LD  [hash]
    STO [faddr_hi]
    LD  [tmp2]
    STO [faddr]
    JMP dw4_loop

dw_ret:
    RET

; --- .S body (relocated from token space) ---
; Prints stack contents without consuming them: <depth> bottom ... top
; Stack lives at 0x7E00 + SP..0x7EFA (SP=TOS, 0xFA=bottom).
; Uses IX-indexed reads: IX=0x7E:offs, LD [0x0000, x] reads RAM[0x7E:offs].
do_dots:
    LD  #0x7E
    STO [IX_HI]                 ; IX_HI = 0x7E for stack access (page 0x7E)
    ; Calculate depth = 0xFB - SP
    LD  [0x7FFC]
    STO [tmp]                   ; SP value
    LD  #0xFB
    SUB [tmp]                   ; depth = 0xFB - SP
    STO [tmp2]                  ; depth
    ; Print "<depth> "
    LD  #0x3C                   ; '<'
    STO [UART_DATA]
    LD  [tmp2]
    CALL pnib                   ; print depth as single hex digit
    LD  #0x3E                   ; '>'
    STO [UART_DATA]
    LD  #0x20                   ; ' '
    STO [UART_DATA]
    ; Print from bottom (SP+depth-1 = 0xFA) down to top (SP)
    LD  [tmp2]
    JZ  dots_done               ; empty stack
    ; Start at bottom: IX = SP + depth - 1
    LD  [tmp]
    ADD [tmp2]
    SUB #1
    STO [hash]                  ; current IX = bottom of stack
dots_loop:
    LD  [hash]
    STO [0x7FFD]                ; IX = current address
    LD  [0x0000, x]             ; read stack entry via IX
    STO [eol]                   ; save value (reuse eol temporarily)
    SHR
    SHR
    SHR
    SHR
    CALL pnib                   ; high nibble
    LD  [eol]
    AND #0x0F
    CALL pnib                   ; low nibble
    LD  #0x20                   ; ' '
    STO [UART_DATA]
    ; Move toward top of stack
    LD  [hash]
    XOR [tmp]                   ; compare IX with SP (TOS address)
    JZ  dots_done               ; reached TOS, we're done
    LD  [hash]
    SUB #1
    STO [hash]                  ; IX-- (move toward TOS)
    JMP dots_loop
dots_done:
    CLR
    STO [IX_HI]                 ; restore IX_HI=0 for normal callers
    RET

; --- Arithmetic bodies (relocated from token space) ---

mul_body:                       ; * ( a b -- a*b ) shift-and-add multiply
    POP
    STO [tmp]                   ; b (shifted right each iteration)
    POP
    STO [tmp2]                  ; a (shifted left each iteration)
    CLR
    STO [hash]                  ; result = 0
mul_loop:
    LD  [tmp]
    JZ  mul_done
    AND #0x01                   ; test low bit of b
    JZ  mul_skip
    LD  [hash]
    ADD [tmp2]
    STO [hash]                  ; result += a
mul_skip:
    LD  [tmp2]
    SHL
    STO [tmp2]                  ; a <<= 1
    LD  [tmp]
    SHR
    STO [tmp]                   ; b >>= 1
    JMP mul_loop
mul_done:
    LD  [hash]
    PUSH
    RET

divmod_body:                    ; /MOD ( a b -- rem quot ) unsigned division
    POP
    STO [tmp]                   ; divisor (b)
    JZ  divmod_zero             ; divide by zero
    POP
    STO [tmp2]                  ; dividend (a)
    CLR
    STO [hash]                  ; quotient = 0
divmod_loop:
    LD  [tmp2]
    SUB [tmp]                   ; dividend - divisor
    JC  divmod_done             ; borrow → dividend < divisor → done
    STO [tmp2]                  ; dividend -= divisor
    LD  [hash]
    ADD #1
    STO [hash]                  ; quotient++
    JMP divmod_loop
divmod_done:
    LD  [tmp2]                  ; remainder
    PUSH
    LD  [hash]                  ; quotient
    PUSH
    RET
divmod_zero:
    POP                         ; drop dividend
    CLR
    PUSH                        ; rem = 0
    PUSH                        ; quot = 0
    RET

; UM* ( u1 u2 -- prod_lo prod_hi ) unsigned 8×8 → 16-bit multiply
; Shift-and-add: for each bit of u1 (LSB first), if set add the
; shifting multiplicand b into the 16-bit accumulator r. Then shift b
; left (2×) and u1 right (÷2). 8 iterations.
; Temps: tmp=b_lo, tmp2=b_hi, hash=a (u1), fnd=r_lo, eol=r_hi, nval=count
um_mul_body:
    POP
    STO [tmp]                   ; b_lo = u2
    CLR
    STO [tmp2]                  ; b_hi = 0
    POP
    STO [hash]                  ; a = u1
    CLR
    STO [fnd]                   ; r_lo = 0
    STO [eol]                   ; r_hi = 0
    LD  #8
    STO [nval]                  ; counter
umm_loop:
    LD  [hash]
    AND #1
    JZ  umm_no_add
    LD  [fnd]
    ADD [tmp]
    STO [fnd]                   ; r_lo += b_lo, carry latched
    LD  [eol]
    ADD [tmp2], carry
    STO [eol]                   ; r_hi += b_hi + carry
umm_no_add:
    LD  [tmp]
    SHL
    STO [tmp]                   ; b_lo <<= 1, carry = old bit 7
    LD  [tmp2]
    ROL
    STO [tmp2]                  ; b_hi = b_hi<<1 | carry
    LD  [hash]
    SHR
    STO [hash]                  ; a >>= 1
    LD  [nval]
    SUB #1
    STO [nval]
    JZ  umm_done
    JMP umm_loop
umm_done:
    LD  [fnd]
    PUSH                        ; prod_lo
    LD  [eol]
    PUSH                        ; prod_hi
    RET

; UM16* ( al ah bl bh -- p_lo p_hi ) unsigned 16×16, middle 16 bits
; Returns bits 8..23 of the 32-bit product (shift-right-8 = 8.8 fixed-point
; multiply). Shift-and-add: 16 iters. Each iter tests bit 0 of a,
; conditionally adds 32-bit b to 32-bit accumulator r, shifts b left 1
; (across 4 bytes), shifts a right 1 (across 2 bytes).
;
; RAM scratch (safe during execution — these are all dead between calls):
;   tmp     = b byte 0 (LSB)        tmp2    = b byte 1
;   wlen    = b byte 2              [0x0F]  = b byte 3 (MSB)
;   hash    = a byte 0              [0x13]  = a byte 1
;   fnd     = r byte 0              eol     = r byte 1
;   faddr   = r byte 2              faddr_hi= r byte 3
;   nval    = loop counter
um16_mul_body:
    POP
    STO [tmp2]                  ; b1 = bh
    POP
    STO [tmp]                   ; b0 = bl
    CLR
    STO [wlen]                  ; b2 = 0
    STO [0x0F]                  ; b3 = 0
    POP
    STO [0x13]                  ; a_hi = ah
    POP
    STO [hash]                  ; a_lo = al
    CLR
    STO [fnd]                   ; r0 = 0
    STO [eol]                   ; r1 = 0
    STO [faddr]                 ; r2 = 0
    STO [faddr_hi]              ; r3 = 0
    LD  #16
    STO [nval]
um16_loop:
    LD  [hash]
    AND #1
    JZ  um16_no_add
    LD  [fnd]
    ADD [tmp]
    STO [fnd]                   ; r0 += b0
    LD  [eol]
    ADD [tmp2], carry
    STO [eol]                   ; r1 += b1 + c
    LD  [faddr]
    ADD [wlen], carry
    STO [faddr]                 ; r2 += b2 + c
    LD  [faddr_hi]
    ADD [0x0F], carry
    STO [faddr_hi]              ; r3 += b3 + c
um16_no_add:
    LD  [tmp]
    SHL
    STO [tmp]                   ; b0 <<= 1
    LD  [tmp2]
    ROL
    STO [tmp2]                  ; b1 = b1<<1|c
    LD  [wlen]
    ROL
    STO [wlen]                  ; b2
    LD  [0x0F]
    ROL
    STO [0x0F]                  ; b3
    LD  [0x13]
    SHR
    STO [0x13]                  ; a_hi >>= 1
    LD  [hash]
    ROR
    STO [hash]                  ; a_lo = a_lo>>1|c<<7
    LD  [nval]
    SUB #1
    STO [nval]
    JZ  um16_done
    JMP um16_loop
um16_done:
    LD  [eol]
    PUSH                        ; p_lo = r1
    LD  [faddr]
    PUSH                        ; p_hi = r2
    RET

; F* ( al ah bl bh -- r_lo r_hi ) signed 16×16 → signed 8.8 (mid-16)
; Wrapper around um16_mul_body: extract signs, abs-value the inputs,
; call UM16*, then negate the result if the product sign is negative.
; lvh (0x18) holds the sign accumulator — it survives the UM16* call
; because UM16* doesn't touch lvh/lvl (those are compile-time-only).
f_mul_body:
    POP
    STO [tmp]                   ; tmp  = bh (save all 4 in scratch)
    POP
    STO [tmp2]                  ; tmp2 = bl
    POP
    STO [wlen]                  ; wlen = ah
    POP
    STO [hash]                  ; hash = al
    CLR
    STO [lvh]                   ; sign flag = 0
    ; --- sign of b ---
    LD  [tmp]
    AND #0x80
    JZ  fm_b_pos
    LD  [lvh]
    XOR #1
    STO [lvh]                   ; toggle sign
    CLR
    SUB [tmp2]
    STO [tmp2]                  ; bl' = 0 - bl
    CLR
    SUB [tmp], carry
    STO [tmp]                   ; bh' = 0 - bh - borrow
fm_b_pos:
    ; --- sign of a ---
    LD  [wlen]
    AND #0x80
    JZ  fm_a_pos
    LD  [lvh]
    XOR #1
    STO [lvh]
    CLR
    SUB [hash]
    STO [hash]
    CLR
    SUB [wlen], carry
    STO [wlen]
fm_a_pos:
    ; Push abs(a), abs(b) back onto data stack for UM16*
    LD  [hash]
    PUSH                        ; al
    LD  [wlen]
    PUSH                        ; ah
    LD  [tmp2]
    PUSH                        ; bl
    LD  [tmp]
    PUSH                        ; bh
    CALL um16_mul_body          ; ( al ah bl bh -- r_lo r_hi )
    ; --- apply sign to result ---
    LD  [lvh]
    JZ  fm_done
    POP
    STO [tmp]                   ; tmp = r_hi
    POP
    STO [tmp2]                  ; tmp2 = r_lo
    CLR
    SUB [tmp2]
    PUSH                        ; new r_lo = 0 - r_lo
    CLR
    SUB [tmp], carry
    PUSH                        ; new r_hi = 0 - r_hi - borrow
fm_done:
    RET

; UM/MOD ( ud_lo ud_hi div -- rem quot ) unsigned 16/8 → 8+8
; 16-iter shift-and-subtract restoring division. Quotient overflow (>255)
; is truncated — caller responsible for ensuring result fits 8 bits.
; Temps: tmp=n_lo, tmp2=n_hi, hash=divisor, fnd=remainder, eol=quot, nval=count
um_div_body:
    POP
    STO [hash]                  ; divisor
    POP
    STO [tmp2]                  ; n_hi
    POP
    STO [tmp]                   ; n_lo
    CLR
    STO [fnd]                   ; r = 0
    STO [eol]                   ; q = 0
    LD  #16
    STO [nval]
umd_loop:
    LD  [tmp]
    SHL
    STO [tmp]                   ; n_lo <<= 1, carry = old bit 7
    LD  [tmp2]
    ROL
    STO [tmp2]                  ; n_hi <<= 1 with carry, carry = old bit 15
    LD  [fnd]
    ROL
    STO [fnd]                   ; r <<= 1 with carry
    JC  umd_sub_force           ; r overflowed 8 bits → must subtract
    SUB [hash]
    JC  umd_no_sub              ; borrow set → r < divisor
    STO [fnd]                   ; r -= divisor
    LD  [eol]
    SHL
    ADD #1
    STO [eol]                   ; q = (q<<1) | 1
    JMP umd_tail
umd_sub_force:
    LD  [fnd]
    SUB [hash]
    STO [fnd]
    LD  [eol]
    SHL
    ADD #1
    STO [eol]
    JMP umd_tail
umd_no_sub:
    LD  [eol]
    SHL
    STO [eol]                   ; q <<= 1
umd_tail:
    LD  [nval]
    SUB #1
    STO [nval]
    JZ  umd_done
    JMP umd_loop
umd_done:
    LD  [fnd]
    PUSH                        ; rem
    LD  [eol]
    PUSH                        ; quot (low 8 bits)
    RET

; KEY? ( -- flag )  non-blocking input check.
; TRUE (FF) if source buffer still has data OR UART RX FIFO has a byte.
; FALSE (00) otherwise. Use to probe for keystrokes without blocking.
keyq_body:
    LD  [src_lo]
    XOR [src_end_lo]
    JZ  keyq_check_hi
    JMP keyq_true               ; src_lo != src_end_lo → source has data
keyq_check_hi:
    LD  [src_hi]
    XOR [src_end_hi]
    JZ  keyq_check_uart
    JMP keyq_true
keyq_check_uart:
    LD  [UART_STATUS]
    AND #0x02                   ; bit 1 = rx_ready
    JZ  keyq_false
keyq_true:
    LD  #0xFF
    PUSH
    RET
keyq_false:
    CLR
    PUSH
    RET

; --- Storage / Block I/O bodies ---
; 2-slot ping-pong block-cache.  Slot 0 lives at page 0x02 (the page that
; HEDIT, BB!/BBC, RXBLK and B@ all hardcode), slot 1 at page 0x03 — cache-
; only.  When the user requests the block currently in slot 1 we swap the
; 256-byte data + metadata so it's visible at page 0x02; on a miss we move
; slot 0's contents down to slot 1 (preserving them in the cache) before
; reading the new block from SD.  No user-visible API change: BLOCK still
; takes ( hi lo -- ), buf_blk(_hi)/buf_dirty still mirror the page-0x02
; slot.  Slot 1 metadata (alt_blk(_hi)/alt_dirty) lives in 0x2A-0x2C.
; alt_blk_hi == 0xFF marks slot 1 as empty.

; swap_slot01 — exchange 256 bytes between page 0x02 and page 0x03.  Per
; iteration: PUSH slot0[i], PUSH slot1[i], POP/store to slot0, POP/store to
; slot1.  Uses the data stack as temp because tmp/tmp2 must survive across
; this call (block_dispatch's bd_miss relies on tmp/tmp2 holding the SD
; sector address for the subsequent sd_read_r_body).  Each iteration nets
; zero stack change.  IX_LO wraps from 0xFF → 0x00 to stop.  Leaves IX_HI = 0.
swap_slot01:
    CLR
    STO [0x7FFD]                ; offset i = 0
sw_loop:
    LD  #0x02
    STO [IX_HI]
    LD  [0x0000, x]             ; slot0[i]
    PUSH
    LD  #0x03
    STO [IX_HI]
    LD  [0x0000, x]             ; slot1[i]
    PUSH
    LD  #0x02
    STO [IX_HI]
    POP
    STO [0x0000, x]             ; slot0[i] = old slot1[i]
    LD  #0x03
    STO [IX_HI]
    POP
    STO [0x0000, x]             ; slot1[i] = old slot0[i]
    LD  [0x7FFD]
    ADD #1
    STO [0x7FFD]
    JZ  sw_done
    JMP sw_loop
sw_done:
    CLR
    STO [IX_HI]
    RET

; copy_s0_to_s1 — copy 256 bytes from page 0x02 (slot 0) to page 0x03
; (slot 1).  Used to preserve slot 0's contents into the cache before
; reading a fresh block over them.  Uses data stack (PUSH/POP) as temp so
; tmp/tmp2 survive — caller's bd_miss path needs tmp/tmp2 = SD sector
; address for the immediately-following sd_read_r_body.  Leaves IX_HI = 0.
copy_s0_to_s1:
    CLR
    STO [0x7FFD]
cp_loop:
    LD  #0x02
    STO [IX_HI]
    LD  [0x0000, x]
    PUSH
    LD  #0x03
    STO [IX_HI]
    POP
    STO [0x0000, x]
    LD  [0x7FFD]
    ADD #1
    STO [0x7FFD]
    JZ  cp_done
    JMP cp_loop
cp_done:
    CLR
    STO [IX_HI]
    RET

; swap_meta01 — exchange slot 0/1 metadata (blk, blk_hi, dirty).  Trashes
; tmp2.  Used after swap_slot01 so the page-0 mirrors track which block is
; physically at page 0x02.
swap_meta01:
    LD  [buf_blk]
    STO [tmp2]
    LD  [alt_blk]
    STO [buf_blk]
    LD  [tmp2]
    STO [alt_blk]
    LD  [buf_blk_hi]
    STO [tmp2]
    LD  [alt_blk_hi]
    STO [buf_blk_hi]
    LD  [tmp2]
    STO [alt_blk_hi]
    LD  [buf_dirty]
    STO [tmp2]
    LD  [alt_dirty]
    STO [buf_dirty]
    LD  [tmp2]
    STO [alt_dirty]
    RET

; flush_slot1 — if slot 1 is dirty, swap it into slot 0, write to SD, swap
; back.  After: slot 1 is clean.  No-op if slot 1 was already clean.
; Trashes tmp/tmp2/hash/IX.
flush_slot1:
    LD  [alt_dirty]
    JZ  fs1_done
    CALL swap_slot01
    CALL swap_meta01            ; meta now describes slot 1's block at page 0x02
    LD  [buf_blk_hi]
    STO [tmp2]
    LD  [buf_blk]
    STO [tmp]
    CALL sd_write_r_body
    CLR
    STO [buf_dirty]             ; just-written slot is clean
    CALL swap_slot01
    CALL swap_meta01            ; restore physical-vs-logical alignment
fs1_done:
    RET

; save_buffers_body (FLUSH) — write any dirty cached block back to SD.
; Walk slot 1 first (so its swap doesn't interfere with slot 0's flush).
save_buffers_body:
    CALL flush_slot1
    LD  [buf_dirty]
    JZ  sb_done
    LD  [buf_blk_hi]
    STO [tmp2]
    LD  [buf_blk]
    STO [tmp]
    CALL sd_write_r_body
    CLR
    STO [buf_dirty]
sb_done:
    RET

; block_dispatch — internal helper.  Input: tmp2=hi, tmp=lo.  After: the
; requested block is in slot 0 (page 0x02), buf_blk(_hi)/buf_dirty mirror
; it, and tmp/tmp2 are restored to the requested block# so callers like
; load_body can sync thru_cur.  Trashes hash/IX.
block_dispatch:
    LD  [tmp2]
    XOR [buf_blk_hi]
    JZ  bd_check_s0_lo
    JMP bd_check_s1
bd_check_s0_lo:
    LD  [tmp]
    XOR [buf_blk]
    JZ  bd_hit_s0
bd_check_s1:
    LD  [tmp2]
    XOR [alt_blk_hi]
    JZ  bd_check_s1_lo
    JMP bd_miss
bd_check_s1_lo:
    LD  [tmp]
    XOR [alt_blk]
    JZ  bd_hit_s1
bd_miss:
    ; Cache miss.  Preserve slot 0 into slot 1 (after flushing slot 1),
    ; then SD-read the requested block into slot 0.  flush_slot1 (when
    ; slot 1 is dirty) and the swap/copy helpers all clobber tmp2 via
    ; sd_write_r_body / swap_meta01, so park the request on the data
    ; stack until we're ready to call sd_read_r_body.
    LD  [tmp]
    PUSH                        ; save request_lo
    LD  [tmp2]
    PUSH                        ; save request_hi
    CALL flush_slot1
    CALL copy_s0_to_s1
    LD  [buf_blk]
    STO [alt_blk]
    LD  [buf_blk_hi]
    STO [alt_blk_hi]
    LD  [buf_dirty]
    STO [alt_dirty]
    POP                         ; restore request_hi
    STO [tmp2]
    POP                         ; restore request_lo
    STO [tmp]
    CALL sd_read_r_body
    LD  [sd_save_lo]
    STO [buf_blk]               ; sd_read_r_body parked the request in sd_save_*
    LD  [sd_save_hi]
    STO [buf_blk_hi]
    CLR
    STO [buf_dirty]
    JMP bd_recover_tmp
bd_hit_s1:
    CALL swap_slot01
    CALL swap_meta01
    JMP bd_recover_tmp
bd_hit_s0:
    RET                         ; tmp/tmp2 still hold the requested block#
bd_recover_tmp:
    LD  [buf_blk]
    STO [tmp]
    LD  [buf_blk_hi]
    STO [tmp2]
    RET

; set_src_block_buf — point src/src_end at slot 0 (page 0x02).  Always
; slot 0 because that's where block_dispatch leaves the just-loaded block.
set_src_block_buf:
    CLR
    STO [src_lo]
    LD  #0x02
    STO [src_hi]
    CLR
    STO [src_end_lo]
    LD  #0x03
    STO [src_end_hi]
    RET

; BLOCK ( hi lo -- ) — load block hi:lo into slot 0 (page 0x02).
block_body:
    POP
    STO [tmp]
    POP
    STO [tmp2]
    CALL block_dispatch
    RET

; LOAD ( hi lo -- ) — load + source from block hi:lo.  If THRU is active,
; sync thru_cur with this load so a chain-LOAD inside the sourced block
; doesn't trigger THRU's auto-advance to re-process blocks the chain
; already covered (the classic re-compile-loop trap).
load_body:
    POP
    STO [tmp]
    POP
    STO [tmp2]
    CALL block_dispatch
    CALL set_src_block_buf
    LD  [thru_act]
    JZ  load_done
    LD  [tmp]
    STO [thru_cur_lo]
    LD  [tmp2]
    STO [thru_cur_hi]
load_done:
    RET

; PARSE-NAME ( -- hi lo len ) — parse next whitespace-delimited word from the
; current input source into the word buffer at 0x0100, return ( 1 0 len ). On
; end-of-line len is 0. Lets user words consume their own arguments
; (e.g. `: RUN PARSE-NAME ... ;` invoked as `RUN MANDEL`).
pname_body:
    CALL word
    LD  #1
    PUSH                        ; addr_hi = 1 (word buffer at 0x0100)
    CLR
    PUSH                        ; addr_lo = 0
    LD  [wlen]
    PUSH                        ; len
    RET

; THRU ( hi1 lo1 hi2 lo2 -- ) — load blocks hi1:lo1 .. hi2:lo2 sequentially.
; Initialises THRU state, loads first block, sets src. rch_uart's intercept
; chains to the next block each time the current one is fully consumed (NUL
; or src == src_end) and clears thru_act after the last block.
thru_body:
    POP
    STO [thru_end_lo]
    POP
    STO [thru_end_hi]
    POP
    STO [thru_cur_lo]
    POP
    STO [thru_cur_hi]
    LD  #1
    STO [thru_act]
    LD  [thru_cur_hi]
    STO [tmp2]
    LD  [thru_cur_lo]
    STO [tmp]
    CALL block_dispatch
    CALL set_src_block_buf
    RET

; --- Shared epilogue for compiler words ---
; Just RETs to the CALLI caller in interp (which then JMPs to interp)
compiler_done:
    RET

; ============================================================================
; SD over SPI — ROM primitives (Phase A: ported from asm/demo/sd.fth)
; ============================================================================
; These routines drive the on-chip SPI master (0x7FF0..0x7FF2) to talk to an
; SD card in SPI mode. They are called directly by block_dispatch and
; save_buffers_body whenever a block address falls outside the BSRAM range,
; replacing the old SDHOOK XT-based dispatch.
;
; Conventions:
;   - Low-level helpers use RR for byte arg/return.
;   - sd_read_body/sd_write_body take ( hi=tmp2, lo=tmp ); return status in RR.
;   - tmp, tmp2, hash, IX_HI are scratch and clobbered.
;   - sd_save_lo/hi preserve the block address across sd_init re-entry.
; ----------------------------------------------------------------------------

; spi_xfer ( tx in RR -- rx in RR ) — full-duplex byte transfer.
spi_xfer:
    STO [SPI_DATA]              ; write triggers TX
sx_busy:
    LD  [SPI_STAT]
    AND #1
    JZ  sx_done
    JMP sx_busy
sx_done:
    LD  [SPI_DATA]              ; read latched RX byte
    RET

; spi_skip ( -- rx ) — TX 0xFF, return RX (tail-calls spi_xfer)
spi_skip:
    LD  #0xFF
    JMP spi_xfer

; sd_on / sd_off — drive CS line. SD_CS is active-low.
sd_on:
    CLR
    STO [SPI_CS]
    RET
sd_off:
    LD  #1
    STO [SPI_CS]
    RET

; sd_warmup — CS=high, send 10 dummy bytes to wake the card (~80 SCK cycles).
sd_warmup:
    CALL sd_off
    LD  #10
    STO [tmp]
sd_warmup_loop:
    CALL spi_skip
    LD  [tmp]
    SUB #1
    STO [tmp]
    JZ  sd_warmup_done
    JMP sd_warmup_loop
sd_warmup_done:
    RET

; wait_r1 ( -- r1 in RR ) — poll up to 16 reads for a byte with bit 7 = 0.
; On timeout returns 0xFF.
wait_r1:
    LD  #16
    STO [tmp]
wait_r1_loop:
    CALL spi_skip
    STO [tmp2]                  ; remember last RX
    AND #0x80
    JZ  wait_r1_got             ; bit7==0 → valid R1
    LD  [tmp]
    SUB #1
    STO [tmp]
    JZ  wait_r1_to
    JMP wait_r1_loop
wait_r1_to:
    LD  #0xFF
    RET
wait_r1_got:
    LD  [tmp2]
    RET

; sd_finish_cmd — common tail for CMD0/55/ACMD41: wait_r1, sd_off, return R1.
sd_finish_cmd:
    CALL wait_r1
    STO [tmp2]                  ; preserve R1 across sd_off
    CALL sd_off
    LD  [tmp2]
    RET

; sd_cmd0 ( -- r1 ) — GO_IDLE_STATE
sd_cmd0:
    CALL sd_on
    LD  #0x40                   ; 64 = CMD0 | 0x40
    CALL spi_xfer
    CLR
    CALL spi_xfer
    CLR
    CALL spi_xfer
    CLR
    CALL spi_xfer
    CLR
    CALL spi_xfer
    LD  #0x95                   ; 149 = CRC for CMD0(0)
    CALL spi_xfer
    JMP sd_finish_cmd

; sd_cmd8 ( -- r1 ) — SEND_IF_COND, plus 4 trailing bytes (returns R7 high)
sd_cmd8:
    CALL sd_on
    LD  #0x48                   ; 72
    CALL spi_xfer
    CLR
    CALL spi_xfer
    CLR
    CALL spi_xfer
    LD  #0x01
    CALL spi_xfer
    LD  #0xAA                   ; 170
    CALL spi_xfer
    LD  #0x87                   ; 135 = CRC for CMD8(0x1AA)
    CALL spi_xfer
    CALL wait_r1
    STO [tmp2]
    CALL spi_skip               ; 4 trailing dummy reads (R7 body, ignored)
    CALL spi_skip
    CALL spi_skip
    CALL spi_skip
    CALL sd_off
    LD  [tmp2]
    RET

; sd_cmd55 ( -- r1 ) — APP_CMD prefix
sd_cmd55:
    CALL sd_on
    LD  #0x77                   ; 119
    CALL spi_xfer
    CLR
    CALL spi_xfer
    CLR
    CALL spi_xfer
    CLR
    CALL spi_xfer
    CLR
    CALL spi_xfer
    LD  #0x01                   ; CRC stub
    CALL spi_xfer
    JMP sd_finish_cmd

; sd_acmd41 ( -- r1 ) — SD_SEND_OP_COND with HCS=1
sd_acmd41:
    CALL sd_on
    LD  #0x69                   ; 105
    CALL spi_xfer
    LD  #0x40                   ; HCS=1
    CALL spi_xfer
    CLR
    CALL spi_xfer
    CLR
    CALL spi_xfer
    CLR
    CALL spi_xfer
    LD  #0x01                   ; CRC stub
    CALL spi_xfer
    JMP sd_finish_cmd

; sd_init_body ( -- status ) — full SD init sequence.
;   0 = ready, 1 = CMD0 fail, 2 = CMD8 fail, 3 = ACMD41 timeout
sd_init_body:
    CALL sd_warmup
    CALL sd_cmd0
    SUB #1
    JZ  sd_init_cmd8
    LD  #1
    RET
sd_init_cmd8:
    CALL sd_cmd8
    SUB #1
    JZ  sd_init_acmd41
    LD  #2
    RET
sd_init_acmd41:
    LD  #100
    STO [tmp]                   ; retry counter
sd_init_acmd41_loop:
    CALL sd_cmd55               ; result ignored
    CALL sd_acmd41
    JZ  sd_init_ok              ; 0 = card ready
    LD  [tmp]
    SUB #1
    STO [tmp]
    JZ  sd_init_to
    JMP sd_init_acmd41_loop
sd_init_to:
    LD  #3
    RET
sd_init_ok:
    CLR
    RET

; sd_init_handler — Forth SD-INIT ( -- status ) builtin wrapper.
sd_init_handler:
    CALL sd_init_body
    PUSH
    RET

; sdw_handler — Forth SDW ( hi lo -- status ) — direct write of page 0x02
; (slot 0) to SD sector hi:lo, exposes sd_write_r_body status.  Diagnostic.
sdw_handler:
    POP
    STO [tmp]
    POP
    STO [tmp2]
    CALL sd_write_r_body
    PUSH
    RET

; sdr_handler — Forth SDR ( hi lo -- status ) — direct read from SD sector
; hi:lo into page 0x02 (slot 0), exposes sd_read_r_body status.  Diagnostic.
; Does NOT update slot meta — bypasses the cache.
sdr_handler:
    POP
    STO [tmp]
    POP
    STO [tmp2]
    CALL sd_read_r_body
    PUSH
    RET

; sd_read_body — read sector tmp2:tmp into BLOCK_BUF (lower 256B).
;   status: 0=OK, 128=token timeout, else SD R1 error byte
sd_read_body:
    CALL sd_on
    LD  #0x51                   ; 81 = CMD17
    CALL spi_xfer
    CLR
    CALL spi_xfer
    CLR
    CALL spi_xfer
    LD  [tmp2]                  ; arg byte 3 = sector hi
    CALL spi_xfer
    LD  [tmp]                   ; arg byte 4 = sector lo
    CALL spi_xfer
    LD  #0x01                   ; CRC stub
    CALL spi_xfer
    CALL wait_r1
    JZ  sdr_token               ; R1 == 0 → wait for data token
    STO [tmp2]                  ; preserve R1
    CALL sd_off
    CALL spi_skip               ; final dummy
    LD  [tmp2]
    RET
sdr_token:
    ; Wait up to 1024 polls (4 × 256) for 0xFE token
    LD  #4
    STO [tmp2]                  ; outer counter
sdr_tok_outer:
    CLR
    STO [tmp]                   ; inner counter (wraps after 256 iters)
sdr_tok_inner:
    CALL spi_skip
    XOR #0xFE
    JZ  sdr_tok_ok
    LD  [tmp]
    ADD #1
    STO [tmp]
    JZ  sdr_tok_outer_dec
    JMP sdr_tok_inner
sdr_tok_outer_dec:
    LD  [tmp2]
    SUB #1
    STO [tmp2]
    JZ  sdr_tok_to
    JMP sdr_tok_outer
sdr_tok_to:
    CALL sd_off
    CALL spi_skip
    LD  #0x80                   ; 128
    RET
sdr_tok_ok:
    ; Read 256 bytes into BLOCK_BUF[0..255]
    LD  #0x02
    STO [IX_HI]                 ; IX_HI = BLOCK_BUF page
    CLR
    STO [tmp]                   ; counter
sdr_rd_loop:
    CALL spi_skip
    STO [tmp2]                  ; preserve byte across IX setup
    LD  [tmp]
    STO [0x7FFD]                ; IX_LO = counter
    LD  [tmp2]
    STO [0x0000, x]             ; BLOCK_BUF[counter] = byte
    LD  [tmp]
    ADD #1
    STO [tmp]
    JZ  sdr_rd_done
    JMP sdr_rd_loop
sdr_rd_done:
    CLR
    STO [IX_HI]                 ; restore
    ; Skip upper 256 bytes (we don't expose 512-byte sectors to Forth)
    CLR
    STO [tmp]
sdr_skip_loop:
    CALL spi_skip
    LD  [tmp]
    ADD #1
    STO [tmp]
    JZ  sdr_skip_done
    JMP sdr_skip_loop
sdr_skip_done:
    CALL spi_skip               ; CRC byte 1
    CALL spi_skip               ; CRC byte 2
    CALL sd_off
    CALL spi_skip               ; final dummy (release SCK clocks)
    CLR
    RET

; sd_write_body — write BLOCK_BUF (lower 256) + 0xFF fill (upper 256) to
; sector tmp2:tmp. Returns status: 0=OK, 16=write-rejected, else R1 error.
sd_write_body:
    CALL sd_on
    LD  #0x58                   ; 88 = CMD24
    CALL spi_xfer
    CLR
    CALL spi_xfer
    CLR
    CALL spi_xfer
    LD  [tmp2]
    CALL spi_xfer
    LD  [tmp]
    CALL spi_xfer
    LD  #0x01                   ; CRC stub
    CALL spi_xfer
    CALL wait_r1
    JZ  sdw_data                ; R1 == 0 → send data
    STO [tmp2]
    CALL sd_off
    CALL spi_skip
    LD  [tmp2]
    RET
sdw_data:
    LD  #0xFE                   ; data start token
    CALL spi_xfer
    ; Write 256 bytes from BLOCK_BUF
    LD  #0x02
    STO [IX_HI]
    CLR
    STO [tmp]
sdw_buf_loop:
    LD  [tmp]
    STO [0x7FFD]                ; IX_LO = counter
    LD  [0x0000, x]             ; BLOCK_BUF[counter]
    CALL spi_xfer
    LD  [tmp]
    ADD #1
    STO [tmp]
    JZ  sdw_buf_done
    JMP sdw_buf_loop
sdw_buf_done:
    CLR
    STO [IX_HI]
    ; Write 256 bytes of 0xFF (fill upper half of SD sector)
    CLR
    STO [tmp]
sdw_fill_loop:
    LD  #0xFF
    CALL spi_xfer
    LD  [tmp]
    ADD #1
    STO [tmp]
    JZ  sdw_fill_done
    JMP sdw_fill_loop
sdw_fill_done:
    CALL spi_skip               ; dummy CRC 1
    CALL spi_skip               ; dummy CRC 2
    ; Read response token: lower 5 bits == 0b00101 (5) ⇒ accepted
    CALL spi_skip
    AND #0x1F
    SUB #5
    JZ  sdw_resp_ok
    LD  #0x10                   ; 16 = rejected
    STO [tmp2]
    JMP sdw_busy
sdw_resp_ok:
    CLR
    STO [tmp2]
sdw_busy:
    ; Wait up to 1024 polls for 0xFF (card no longer holding MISO low)
    LD  #4
    STO [tmp]                   ; outer counter
sdw_busy_outer:
    CLR
    STO [hash]                  ; inner counter
sdw_busy_inner:
    CALL spi_skip
    XOR #0xFF
    JZ  sdw_busy_done
    LD  [hash]
    ADD #1
    STO [hash]
    JZ  sdw_busy_outer_dec
    JMP sdw_busy_inner
sdw_busy_outer_dec:
    LD  [tmp]
    SUB #1
    STO [tmp]
    JZ  sdw_busy_done           ; timeout: continue with whatever status
    JMP sdw_busy_outer
sdw_busy_done:
    CALL sd_off
    CALL spi_skip
    LD  [tmp2]
    RET

; sd_read_r_body — sd_read_body with one retry-after-init on failure.
sd_read_r_body:
    LD  [tmp]
    STO [sd_save_lo]
    LD  [tmp2]
    STO [sd_save_hi]
    CALL sd_read_body
    JZ  sdr_r_done
    CALL sd_init_body           ; ignore status
    LD  [sd_save_lo]
    STO [tmp]
    LD  [sd_save_hi]
    STO [tmp2]
    CALL sd_read_body
sdr_r_done:
    RET

; sd_write_r_body — sd_write_body with one retry-after-init on failure.
sd_write_r_body:
    LD  [tmp]
    STO [sd_save_lo]
    LD  [tmp2]
    STO [sd_save_hi]
    CALL sd_write_body
    JZ  sdw_r_done
    CALL sd_init_body
    LD  [sd_save_lo]
    STO [tmp]
    LD  [sd_save_hi]
    STO [tmp2]
    CALL sd_write_body
sdw_r_done:
    RET

; ============================================================================
; Auto-boot from SD sector 0:0 — checks for magic header "\ 8xMC14500" and,
; if present, sources the block as Forth.  The leading "\" makes the magic
; itself a Forth line comment, so the very first byte of the block is read
; by the comment word and discarded; the user follows it with whatever boot
; commands they want (e.g. `1 100 1 120 THRU MENU`).
;
; Failure modes are all benign: SD missing → init returns nonzero → skip.
; Read fails → skip.  Magic mismatch → skip.  In every "skip" case the
; system falls through to a normal UART prompt, no random-source execution.
; ============================================================================
try_autoboot:
    CALL sd_init_body
    JZ  ab_have_sd
    RET                             ; SD not ready → no autoboot
ab_have_sd:
    CLR
    STO [tmp]                       ; sector lo = 0
    STO [tmp2]                      ; sector hi = 0
    CALL sd_read_r_body
    JZ  ab_have_data
    RET                             ; SD read failed → no autoboot
ab_have_data:
    ; Block 0:0 is now in slot 0 — sync the cache metadata so a later
    ; `0 0 BLOCK` is recognised as a hit instead of triggering another SD
    ; round-trip + a wasted slot-0-to-slot-1 copy.
    CLR
    STO [buf_blk]
    STO [buf_blk_hi]
    STO [buf_dirty]
    LD  #0x02
    STO [IX_HI]                     ; IX_HI = BLOCK_BUF page
    ; Compare BLOCK_BUF[0..10] against "\ 8xMC14500".  Any miss → no autoboot.
    LD  #0
    STO [0x7FFD]
    LD  [0x0000, x]
    XOR #0x5C                       ; '\\'
    JZ  ab_c1
    JMP ab_no
ab_c1:
    LD  #1
    STO [0x7FFD]
    LD  [0x0000, x]
    XOR #0x20                       ; ' '
    JZ  ab_c2
    JMP ab_no
ab_c2:
    LD  #2
    STO [0x7FFD]
    LD  [0x0000, x]
    XOR #0x38                       ; '8'
    JZ  ab_c3
    JMP ab_no
ab_c3:
    LD  #3
    STO [0x7FFD]
    LD  [0x0000, x]
    XOR #0x78                       ; 'x'
    JZ  ab_c4
    JMP ab_no
ab_c4:
    LD  #4
    STO [0x7FFD]
    LD  [0x0000, x]
    XOR #0x4D                       ; 'M'
    JZ  ab_c5
    JMP ab_no
ab_c5:
    LD  #5
    STO [0x7FFD]
    LD  [0x0000, x]
    XOR #0x43                       ; 'C'
    JZ  ab_c6
    JMP ab_no
ab_c6:
    LD  #6
    STO [0x7FFD]
    LD  [0x0000, x]
    XOR #0x31                       ; '1'
    JZ  ab_c7
    JMP ab_no
ab_c7:
    LD  #7
    STO [0x7FFD]
    LD  [0x0000, x]
    XOR #0x34                       ; '4'
    JZ  ab_c8
    JMP ab_no
ab_c8:
    LD  #8
    STO [0x7FFD]
    LD  [0x0000, x]
    XOR #0x35                       ; '5'
    JZ  ab_c9
    JMP ab_no
ab_c9:
    LD  #9
    STO [0x7FFD]
    LD  [0x0000, x]
    XOR #0x30                       ; '0'
    JZ  ab_c10
    JMP ab_no
ab_c10:
    LD  #10
    STO [0x7FFD]
    LD  [0x0000, x]
    XOR #0x30                       ; '0'
    JZ  ab_match
    JMP ab_no
ab_no:
    CLR
    STO [IX_HI]
    RET
ab_match:
    CLR
    STO [IX_HI]
    CALL set_src_block_buf          ; src = BLOCK_BUF → interp will source it
    RET

; ============================================================================
; Dictionary init — placeholder that mcasm.py replaces with `LD #v; STO [a]`
; pairs covering every non-zero byte of the static dict (0x0400+), the
; pre-compiled Forth bodies (0x1000+), and the cold-state pointers
; HERE/LATEST/DICT_PTR (page 0 + 0x1A-0x1F).  The trailing RET below is
; preserved so a build that omits the post-pass (e.g. very early bring-up
; without dict population) still returns cleanly — but on the FPGA the
; post-pass is mandatory, otherwise no Forth word can be looked up.
; Placed at a fixed address well past the regular ROM code so mcasm has
; ~3K microwords of headroom for the LD/STO sequence.
; ============================================================================
; HELP — print a short command reference via UART. Exposed as the HELP
; builtin; uses .print macros that expand to LD/STO[UART] pairs (cheap
; given the leftover ROM headroom).  Update freely as new words land.
; ============================================================================
help_body:
    .print "\r\n== MC14500x8 Forth ==\r\n\r\n"
    .print "Stack:   DUP DROP SWAP OVER ROT NIP TUCK ?DUP DEPTH SP@\r\n"
    .print "         2DUP 2DROP 2SWAP\r\n"
    .print "Math:    + - * /MOD / MOD NEGATE ABS MIN MAX 1+ 1- 2* 2/\r\n"
    .print "Logic:   AND OR | XOR INVERT NOT 0= = < > U< 0< TRUE FALSE\r\n"
    .print "Memory:  @ ! C@ C! B@ HERE ,\r\n"
    .print "R-stack: >R R> R@ I\r\n"
    .print "Double:  UM* UM16* F* UM/MOD M* D+ D- D. DNEGATE S>D U>D\r\n"
    .print "I/O:     . EMIT KEY KEY? CR .\" S\" TYPE COUNT WORDS .S SPACE BL\r\n"
    .print "Compile: : ; VARIABLE CONSTANT ' ['] EXECUTE\r\n"
    .print "Ctrl:    IF ELSE THEN BEGIN UNTIL WHILE REPEAT\r\n"
    .print "         DO LOOP +LOOP LEAVE I CASE OF ENDOF ENDCASE\r\n"
    .print "\r\n"
    .print "Block:   BLOCK ( hi lo -- )         load block into buffer\r\n"
    .print "         LOAD  ( hi lo -- )         interpret block as source\r\n"
    .print "         THRU  ( h1 l1 h2 l2 -- )   interpret block range\r\n"
    .print "         UPDATE FLUSH               mark dirty / write back\r\n"
    .print "\r\n"
    .print "SD card: SD-INIT ( -- status )      0=ready, 1/2/3=init err\r\n"
    .print "         RXBLK   ( hi lo -- )       256 chars from UART\r\n"
    .print "\r\n"
    .print "Bringup: SD-INIT . 0 100 0 129 THRU MENU  (then FILES for fs help)\r\n"
    .print "         ( upload first: tools/upload_blocks.py --strip )\r\n"
    .print "\r\n"
    .print "Multi:   PAUSE      ( -- ) yield to other task\r\n"
    .print "         TASK       ( xt_hi xt_lo -- ) install task1, also = WAKE\r\n"
    .print "         STOP       ( -- ) mark self stopped, switch or abort\r\n"
    .print "\r\n"
    .print "Misc:    BYE HELP WORDS UNUSED PARSE-NAME\r\n"
    .print "\r\n"
    RET

; Place dict_init high enough that help_body (which the assembler placed
; right after sdw_r_done with no .org of its own) can extend without
; getting overwritten by the post-pass LD/STO sequence.  ROM is 8 KW;
; main + help_body needs ~0x1000 words today, dict_init eats ~0x950 more.
.org 0x1200
dict_init:
    RET
