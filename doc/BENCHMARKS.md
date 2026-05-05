# MC14500 Bit-Slice CPU — Performance Benchmarks

## Hardware

- 8-bit CPU from eight 1-bit ALU slices (Motorola MC14500-inspired)
- 48-bit microword, 11-bit PC (2048 ROM words), 15-bit RAM (32KB; ram_addr field is 16-bit, ready for 64KB upgrade)
- Single-cycle execution: 1 instruction per clock cycle
- Hardware call stack: 8 deep
- Simulated with Icarus Verilog

## Three Threading Models

| Model | Description | Use Case |
|-------|-------------|----------|
| **Raw Assembly** | Direct microcode, no abstraction | Maximum performance baseline |
| **STC Forth** | Subroutine-Threaded Code, CALL/RET per primitive | Compiled Forth (static) |
| **Token Forth** | Token-threaded interpreter, NEXT loop dispatches 8-bit tokens | Interactive Forth (dynamic) |

## Benchmark Programs

### MUL 13*7 — 8x8 Multiply (shift-and-add)

```forth
: mul ( a b -- a*b )
  0 32 ! BEGIN DUP 1 AND IF OVER 32 @ + 32 ! THEN
  SWAP 2* SWAP 2/ DUP 0= UNTIL DROP DROP 32 @ ;
13 7 mul .   ( → 5B = 91 decimal )
```

### FIB fib(10) — Iterative Fibonacci

```forth
: fib ( n -- fib_n )
  1 - 32 ! 0 1 BEGIN OVER OVER + ROT DROP
  32 @ 1 - DUP 32 ! 0= UNTIL SWAP DROP ;
10 fib .   ( → 37 = 55 decimal )
```

### FILL 32 bytes — Memory fill with XOR pattern

```forth
: fill ( -- )
  0 BEGIN DUP DUP 170 XOR SWAP 64 + ! 1 + DUP 32 XOR 0= UNTIL DROP ;
fill 64 @ .   ( → AA )  95 @ .   ( → B5 )
```

## Results

```
========================================================================
  MC14500 Bit-Slice CPU — Performance Benchmark (Final)
  48-bit microword | 11-bit PC | Compiler in RAM | Linked-List Dict
========================================================================

                        Raw ASM      STC    Token    T/R T/STC
  -------------------- -------- -------- --------  ----- -----
  MUL 13*7                 44cy    159cy   2496cy  56.7x 15.7x
  FIB fib(10)             110cy    272cy   3663cy  33.3x 13.5x
  FILL 32 bytes           386cy    386cy   8526cy  22.1x 22.1x
  -------------------- -------- -------- --------  ----- -----
  TOTAL                   540cy    817cy  14685cy  27.2x 18.0x

  Execution time @ 10 MHz:
    Raw ASM:        54.0 us
    STC Forth:      81.7 us
    Token Forth:  1468.5 us

  ROM usage: 1645/2048 words (403 free)
  Compile buffer: ~28KB unified memory (15-bit IX)
  Unified dictionary: 100 words (53 builtins + 47 forthwords), 825 bytes
========================================================================
```

## Analysis

### Threading Overhead

| Comparison | Factor | Explanation |
|------------|--------|-------------|
| STC / Raw | 1.5x | Each primitive adds CALL+RET (2 cycles) |
| Token / STC | 17.8x | NEXT loop: read token, CALLI dispatch, ip management |
| Token / Raw | 26.9x | Total interpreter overhead |

### Token Forth Overhead Breakdown

The token-threaded interpreter adds overhead per primitive call:
- NEXT loop: LD ip, STO IX, LD token, JZ check, STO faddr, ADD ip, STO ip, LD faddr, CALLI = **9 cycles**
- Plus the primitive itself (same as STC)
- Plus dictionary lookup for word invocation (linked-list name comparison)

### Comparison with Historical Systems

| System | Architecture | Forth Type | Typical Overhead |
|--------|-------------|------------|-----------------|
| **MC14500** | 8-bit bit-slice | Token-threaded | **27x** |
| Jupiter Ace (1982) | Z80 @ 3.25 MHz | Token-threaded | ~15-20x |
| Atari 8-bit | 6502 @ 1.79 MHz | STC/ITC | ~10-15x |
| eForth (modern) | ARM Cortex-M | Token-threaded | ~5-10x |

Our overhead is slightly higher than historical 8-bit systems, mainly due to:
1. No native indirect addressing (IX is 15-bit but requires 2-step STO [IX_HI] + STO [0x7FFD] setup)
2. Single-accumulator architecture (frequent STO/LD for temporaries)
3. Linked-list dictionary with full name comparison (vs hash table)

## Unified Memory Milestone (15-bit IX)

With the IX register upgrade from 8-bit to 15-bit, the compile buffer grew from
256 bytes to ~30KB. This makes it possible to define many complex words in a
single session — previously impossible due to compile buffer overflow.

### Combined Demo: Sierpinski + Factorial + Fibonacci

All three defined and executed in one session (was impossible with 256B buffer):

```
> : FACT 1 SWAP BEGIN DUP 1 U< NOT WHILE SWAP OVER * SWAP 1- REPEAT DROP ;
> VARIABLE A
> VARIABLE B
> : FIB 0 A ! 1 B ! BEGIN DUP 0 > WHILE 1- B @ DUP A @ + B ! A ! REPEAT DROP A @ ;
> VARIABLE Y
> : SIERP 16 0 BEGIN DUP 16 U< WHILE DUP Y ! 16 0 BEGIN DUP 16 U< WHILE
>   DUP Y @ AND 0= IF 42 EMIT ELSE 32 EMIT THEN 1+ REPEAT DROP DROP CR
>   1+ REPEAT DROP ;
> 5 FACT .                → 78 (120 decimal)
> 10 FIB .                → 37 (55 decimal)
> SIERP                   → 16x16 Sierpinski triangle fractal
```

```
****************
* * * * * * * * 
**  **  **  **  
*   *   *   *   
****    ****    
* *     * *     
**      **      
*       *       
********        
* * * *         
**  **          
*   *           
****            
* *             
**              
*               
```

### Resource Usage (as of 100-word milestone)

```
ROM:            1645/2048 words (403 free)
Compile buffer: ~28KB (0x1000-0x7EFF)
Unified dict:   100 words (53 builtins + 47 forthwords), 825 bytes at 0x0400-0x0738
Forthword tok:  325 bytes
User words:     append to the same chain as builtins (handler_hi distinguishes)
```

### RC4 stream cipher — a real-world cross-check

`demo_rc4.fth` implements RC4 in pure Forth and verifies it against the Wikipedia test vector
(Key="Key", Plaintext="Plaintext" → ciphertext `BB F3 16 E8 D9 40 AF 0A D3`). Observed
throughput on the MC14500 CPU (sim, post-KSA): ~900 cycles/byte token-threaded. At 9 MHz
effective (27 MHz ÷ 3-phase pipeline) that's ~10 KB/s — competitive with a Z80 running a
similar Forth at comparable clock, and an end-to-end demonstration that the system is
actually complete enough to run a canonical stream cipher bit-for-bit correctly.

## Running the Benchmarks

```bash
# Raw Assembly + STC Forth (cycle-counted)
make bench

# Token Forth (interactive, cycle count in emulator output)
echo ': mul ... ; : fib ... ; : fill ... ;
13 7 mul . 10 fib . fill 64 @ . CR' | make run PROGRAM=forth.asm

# Combined demo (requires 15-bit IX)
make run PROGRAM=forth.asm < demo.fth
make run PROGRAM=forth.asm < demo_sierpinski.fth
```

## Possible future optimizations

Tricks not yet implemented. None of them require RTL changes — they're purely
software/Forth-runtime work. Listed in order of expected ROI (Forth-execution
speed-up vs. implementation effort). Discussed 2026-05-02.

### 1. Cache top-of-stack (TOS) in `RR`

**Status:** not implemented. Estimated speed-up: **~30-40%** for
arithmetic-heavy code. Highest ROI of any single change available without
hardware modification.

**Idea.** Currently every arithmetic word treats the data stack uniformly.
A `+` does:

```
POP            ; 1st operand from stack
STO [tmp]
POP            ; 2nd operand
ADD [tmp]
PUSH           ; result back to stack
```

That's 5 memory cycles to add two numbers. With TOS cached in `RR` (or in a
fixed page-0 slot like `0x00`), `+` becomes:

```
LD  [next]     ; "next" = the new SOS = top of in-memory stack
ADD [tos]      ; tos held in fixed slot
STO [tos]      ; new TOS
SP++           ; logical pop
```

Net: 3-4 cycles instead of 5. Across all stack-touching primitives
(DUP, DROP, SWAP, OVER, +, -, AND, OR, …) the savings compound.

**Cost.** Every stack-manipulating primitive in `forth.asm` has to be
rewritten to honour the TOS-in-`RR` (or TOS-in-fixed-slot) convention.
That's ~30 primitives. The PUSH / POP macros that the assembler emits
also need to be re-thought, since the data stack now holds *next* on
top, not the actual top. Any inline asm that reads the data stack
directly needs auditing.

**ROM impact.** Probably break-even or slightly *smaller* — most words
shrink (no STO / extra LD), but a few helpers grow.

**Risk.** High — it's a refactor of every hot path in the kernel. Wide
test surface needed. Best done as a single big patch with the full
21-test CPU regression run + a Forth integration test (Mandelbrot
end-to-end) before merging.

**Why classical Forths do this.** Almost every modern Forth (gforth,
SwiftForth, Mecrisp, FlashForth, …) caches TOS in a CPU register. The
speed-up is well-established. We're an outlier in *not* doing it, mainly
because the slice CPU has no obvious "free" register to use — `RR` is
the slices' shared accumulator and is touched by every operation. The
fix is to think of `tos` as a *page-0 RAM slot* rather than a hardware
register, and live with the small extra cost vs. a true register cache.

---

### 2. Subroutine-threaded code (STC) instead of token-threaded

**Status:** not implemented. Estimated speed-up: **~25-35%** on Forth
dispatch overhead. Trade-off: *doubles compile-buffer consumption*.

**Idea.** Currently a compiled body is a sequence of 1-byte tokens. The
NEXT loop runs:

```
read_ip_byte   ; fetch token
inc_ip
CALLI          ; dispatch
JMP next       ; back to top
```

That's ~6-8 cycles of dispatch overhead *between* every primitive. With
subroutine-threaded code, the compiled body is a sequence of `CALL primitive`
microwords directly. The CPU walks them by executing them — no NEXT loop,
no token fetch.

```
; Token-threaded body for ": SQ DUP * ;"
do_dup do_mul do_exit               ; 3 bytes

; STC body for the same:
CALL do_dup                          ; 6 bytes (CALL + 15-bit target)
CALL do_mul                          ; 6 bytes
RET                                  ; 6 bytes
```

The STC version skips the NEXT-loop overhead entirely; each primitive's
own RET returns control to the next CALL in the body.

**Cost.** Compile buffer per word **doubles** (1 byte → 2 bytes per token,
plus instruction-encoding overhead since each CALL is one full microword
in our 48-bit encoding). For a small kernel this might mean cutting the
practical user-word capacity in half.

**Why we'd want it anyway.** The MC14500 microword *already includes* a
CALL mode with embedded 15-bit target — STC fits the existing ISA
naturally. The compile-buffer pressure is real, but for performance-
critical user code (e.g., a hand-tuned Mandelbrot inner loop) it would
be a meaningful win.

**Why we'd skip it.** Our compile buffer is ~28 KB, but every doubling
means fewer demos and fewer files-FS user words fit at once. Most of
our existing speed bottlenecks are in 8-bit math (UM*, F*) which is
already hand-coded asm — STC wouldn't speed up the asm-coded primitives
themselves, only the Forth-level glue around them. So the practical
benefit is smaller than the table speed-up suggests for *our* workload.

**Realistic verdict.** Not worth the doubled compile-buffer pressure
unless we're also adopting smaller microwords (separate Tier-2 project).
If both happen together, STC becomes attractive; in isolation, leave
token-threading as-is.

---

### Other tricks discussed but not detailed here

Briefly noted for completeness — see conversation log 2026-05-02 for
detail:

- **Peephole optimization at compile time** (e.g., `1 +` → `1+` primitive).
  Some specialization already in place (`1+`, `1-`, `0=`).
- **Tail-call optimization** — convert `… CALL FOO ;` to `… JMP FOO`.
  Saves 1-2 cycles per chained call.
- **Constant folding** — evaluate `5 3 +` to `8` at compile time.
- **Hot-path inlining** — inline very small primitives instead of
  CALL-ing them.
- **Tighter NEXT loop** — keep IP in a fixed page-0 slot, exploit
  CPU's `JMPI` directly. ~10-15% dispatch speed-up.
- **Algorithmic tweaks** to `*`, `UM/MOD`, etc. (Booth encoding etc.).

None are blocked on hardware; all are pure software wins waiting for
someone to need the speed.
