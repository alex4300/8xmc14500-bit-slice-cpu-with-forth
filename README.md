# MC14500 Bit-Slice CPU with Forth

An 8-bit CPU built from eight 1-bit ALU slices, inspired by the Motorola MC14500 Industrial Control Unit. Microcode-driven with a 48-bit microword. Includes a complete Forth interpreter/compiler that runs on the CPU, runs on real hardware (Tang Primer 20K), and boots a block-based on-chip filesystem with a hex editor.

> **Acknowledgment:** This project was inspired by David Lovett's [Usagi Electric](https://www.youtube.com/@UsagiElectric) YouTube channel. His build of a vacuum-tube MC14500 CPU is what introduced me to bit-slice architectures in the first place — and made it feel approachable enough to try from scratch. Huge thanks to David for the generosity of sharing his work.

```
> VARIABLE Y
> : SIERP 16 0 BEGIN DUP 16 U< WHILE DUP Y ! 16 0 BEGIN DUP 16 U< WHILE
>   DUP Y @ AND 0= IF 42 EMIT ELSE 32 EMIT THEN 1+ REPEAT DROP DROP CR
>   1+ REPEAT DROP ;
> SIERP
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

*Sierpinski triangle fractal, computed and rendered by the Forth interpreter running on the custom CPU.*

## What's in the box

- **8-bit CPU** in Verilog — eight 1-bit slices with carry chain, 16 opcodes, 15-bit PC (8192-word ROM), 32KB RAM, 32-deep hardware call stack
- **15-bit index register** — unified memory addressing for the Forth compile buffer (~28KB)
- **Microcode assembler** in Python — two-pass, labels, macros, `.builtin`/`.forthword` directives, cold-reset RAM-backup emission
- **Forth interpreter/compiler** — ~112 words in ROM (61 builtins + 51 forthwords), plus ~115 more user-defined at boot from `blocks_core.fth`. Unified dictionary, token-threaded, interactive REPL, signed-decimal I/O, 16-bit double-cell math (`UM*`, `UM/MOD`, `UM16*`, `F*`, `M*`, `D+`, `D-`, `D.`, `DNEGATE`, `S>D`, `U>D`), strings (`S"`, `TYPE`, `COUNT`), reflection (`'`, `[']`, `EXECUTE`), full control flow (`DO/LOOP/+LOOP/LEAVE/I`, `CASE/OF/ENDOF/ENDCASE`, `BEGIN/WHILE/REPEAT/UNTIL`), `\` line comments, block storage, in-system line editor **and a full-screen hex editor** (HEDIT with ANSI cursor control, ASCII/HEX-mode toggle, INS/DEL/BS byte operations, page-forward/back block navigation with dirty-check, ESC-with-dirty asks `discard? y/n`). Modern error reporting: unknown words emit `<word> ?` and abort source mode cleanly.
- **FPGA target**: Tang Primer 20K (Gowin GW2A-18) — verified running at 27 MHz (Fmax ~59 MHz), RX FIFO + XON/XOFF flow control, **SD-card over SPI as the only block storage** (BSRAM emulator removed in Phase C, 2026-04-25), persistent SPI-flash boot, magic-header auto-boot reads SD sector 0 and sources the rest of the system on reset
- **Showcase demos** — RC4 cipher (bit-for-bit matches the Wikipedia test vector), Sierpinski triangle, factorial, Fibonacci, full hex editor (`HEDIT`), Mandelbrot fractal in 8.8 signed fixed-point with ROM-level signed multiply (~13 s @ 27 MHz for 64×24)
- **Testbenches** — 21 CPU tests, interactive emulator with UART + block-storage simulation

## System Block Diagram

```
                         ┌──────────────────────────────────────────────────────────┐
                         │                     mc14500_top (FPGA)                    │
                         │                                                           │
     ┌────────┐   CR/LF  │  ┌──────────┐   rx_ready     ┌──────────────────────┐    │
     │  tio   │◄─────────┼──┤ uart_tx  │◄──────────┐   │                       │    │
     │ 115200 │          │  └──────────┘           │   │       MC14500 CPU     │    │
     │  baud  │          │  ┌──────────┐  io_status│   │    (8 × 1-bit slice,  │    │
     │        │─────────►│  │ uart_rx  ├───────┐   └──►│     48-bit microword, │    │
     └────────┘          │  └──────────┘       │       │     3-phase pipeline) │    │
                         │                     │       │                       │    │
                         │  ┌────────────────┐ │       │   ┌───────────────┐   │    │
                         │  │ 16-byte TX FIFO│◄┘◄──────┤◄──┤ slice[0..7]   │   │    │
                         │  │ 32-byte RX FIFO│  data   │   │  + carry chain│   │    │
                         │  │ + XON/XOFF     ├─────────┼──►└──────┬────────┘   │    │
                         │  └────────────────┘ tx_full │          │            │    │
                         │                             │          │            │    │
                         │  ┌──────────────────────┐   │   ┌──────┴────────┐   │    │
                         │  │   256-byte Storage   │   │   │    ROM        │   │    │
                         │  │   (block buffer)     │◄──┼───┤  2048×48 bit  │   │    │
                         │  │   auto-boot Block 0  │   │   │  (forth.asm)  │   │    │
                         │  └──────────────────────┘   │   └───────────────┘   │    │
                         │                             │          ▲            │    │
                         │  ┌──────────────────────┐   │          │ microword  │    │
                         │  │   32KB Data RAM      │◄──┼──────────┤            │    │
                         │  │   (BSRAM, 16 blocks) │   │          │            │    │
                         │  │   stack, dict, buf   │   │   ┌──────┴────────┐   │    │
                         │  └──────────────────────┘   │   │  PC, flags,   │   │    │
                         │                             │   │  RR, IX, SP   │   │    │
                         │                             │   └───────────────┘   │    │
                         │                             └───────────────────────┘    │
                         └──────────────────────────────────────────────────────────┘

  MMIO Map:
    0x7FFF  UART_DATA    (R/W)         0x7FFC  SP         (data stack pointer)
    0x7FFE  UART_STATUS  (R: rx_ready, tx_ready)
    0x7FFD  IX_LO        (index reg low)
    0x7FFB  IX_HI        (index reg high 7 bits)
    0x7FFA  STG_DATA     (R/W, auto-increments offset within block)
    0x7FF9  STG_BLK_HI   (W: block# high byte)
    0x7FF8  STG_BLK_LO   (W: block# low byte — triggers offset reset)
```

## Quick start

Requires [Icarus Verilog](http://iverilog.icarus.com/) and Python 3.

```bash
# macOS
brew install icarus-verilog

# Run CPU tests (21 tests)
make cpu

# Launch Forth REPL
make forth

# Run the Sierpinski demo
make sierpinski

# Run math demo (factorial, fibonacci, comparisons)
make demo
```

## Forth

The Forth system is a complete token-threaded interpreter with ~112 words in one unified dictionary (61 ROM builtins + 51 ROM forthwords; user-source adds another ~115 from blocks_core.fth at boot):

| Category | Words |
|----------|-------|
| **Stack** | `DUP DROP SWAP OVER ROT NIP TUCK ?DUP 2DUP 2DROP 2SWAP >R R> R@` |
| **Math** | `+ - * /MOD / MOD NEGATE ABS MIN MAX 1+ 1- 2* 2/ UM* UM/MOD UM16* F* M* D+ D- DNEGATE S>D U>D` |
| **Logic** | `\| OR AND XOR INVERT 0= NOT = < > U< U> 0< TRUE FALSE`  (`OR` is an alias for `\|`, ANS-Forth standard) |
| **Memory** | `@ ! , C@ C! HERE SP@ B@` |
| **I/O** | `. D. EMIT KEY KEY? CR ." S" TYPE COUNT WORDS .S SPACE BL` |
| **Define** | `: ; VARIABLE CONSTANT` |
| **Reflection** | `' ['] EXECUTE` |
| **Control** | `IF ELSE THEN BEGIN UNTIL WHILE REPEAT DO LOOP +LOOP LEAVE I CASE OF ENDOF ENDCASE` |
| **Block storage** | `BLOCK LOAD THRU UPDATE FLUSH SD-INIT RXBLK` |
| **Parser** | `PARSE-NAME` |
| **Comments** | `( ... )` block, `\ ...` line (to newline) |
| **Debug/Help** | `DEPTH .S UNUSED HELP BYE` |

**Error reporting**: unknown words emit `<word> ?\r\n` and abort source mode (THRU/LOAD/autoboot) cleanly — no cascade-error storm. Bare `?` is FIG-style; we're modern.

### Example session

```
> 5 3 * .
15 ok
> : FACT 1 SWAP BEGIN DUP 1 U< NOT WHILE SWAP OVER * SWAP 1- REPEAT DROP ;
ok
> 5 FACT .
120 ok
> : UP 10 0 DO I . LOOP ;
ok
> UP
0 1 2 3 4 5 6 7 8 9 ok
> 200 100 UM* D.
20000 ok
> : HELLO S" Hi from MC14500" TYPE CR ;
ok
> HELLO
Hi from MC14500
ok
> VARIABLE X  42 X !  X @ .
42 ok
> 1 2 3 .S
<3> 01 02 03 ok
```

`.` and `D.` print signed decimal; `.S` shows the stack in hex. Input numbers are decimal (prefix `-` for negative).

### Demos

```bash
# Forth math demo (factorial, Fibonacci, comparisons, CASE, strings)
make demo

# Sierpinski triangle computed in Forth
make sierpinski

# Return-stack + nesting verification
make rstack-demo

# RC4 cipher verification (matches Wikipedia's "Plaintext" test vector)
cat asm/demo/demo_rc4.fth | make run PROGRAM=asm/forth.asm

# DO/LOOP/+LOOP/LEAVE edge cases
cat asm/demo/demo_doloop.fth | make run PROGRAM=asm/forth.asm
```

### Host-side block upload (Phase D — SD-only)

After `make flash`, ROM contains the kernel + builtins + `RXBLK`. Higher-level vocabulary (HEDIT, MENU, files-FS) lives on the SD card and is auto-loaded at boot. One-time onboarding:

```bash
# 1. Build the SD boot block (auto-detects source size from blocks_core.fth)
python3 tools/sd_install.py
# 2. Upload the boot block via UART (--verify reads back + retries on mismatch)
python3 tools/upload_blocks.py /dev/ttyUSB0 bootblock.bin --start 0 --raw --verify
# 3. Upload blocks_core.fth (HEDIT/MENU/files-FS source) starting at sector 0:100
python3 tools/upload_blocks.py /dev/ttyUSB0 asm/demo/blocks_core.fth \
    --start 100 --strip --verify
```

Reset → ROM init → `try_autoboot` reads SD sector 0:0 → magic `\ 8xMC14500` matches → block sourced as Forth → `0 100 0 138 THRU MENU` → boot markers (`.....`) + MENU banner. The boot output is quiet (no `> ok` salad between every newline) — only the `.` markers + final banner show.

`upload_blocks.py` modes:
- **default (chain)** — injects `0 N+1 LOAD\n` at each block boundary; one-shot with `RUN <NAME>` after `REGISTER`-ing.
- **`--safe-split`** — like default, but refuses to split inside an open `:` ... `;`.
- **`--strip`** — drops legacy block markers / inter-block LOAD chains, packs the cleaned source linearly. For sources you'll source via `THRU` (e.g. blocks_core.fth from the boot block).
- **`--raw`** — verbatim 256-byte blocks (binary data or hand-chained sources).
- **`--verify`** (recommended) — reads each block back through `BLOCK_BUF` after RXBLK, retries up to 3× on mismatch. Catches UART FIFO drops + SD cache glitches.

Transfer rate is ~500-1000 B/s, `--verify` roughly halves it but flags any failures explicitly. `tools/sd_install.py --sector` also emits a 512-byte sector for direct `dd` if you do have an SD reader.

### On-FPGA workflow

After auto-boot completes you're at the Forth prompt with HEDIT/MENU/files-FS available. Files-FS is the level-2 directory at SD sector 1:0 (sectors 0:0..0:255 are reserved for direct use — boot block, source upload, raw HEDIT):

```
MENU                          \ re-show the banner
HELP                          \ built-in command reference (in ROM)
FILES                         \ files-FS command reference (from blocks_core.fth)
DIR                           \ list registered files

\ Register a new file at SD blocks 1:100..1:107 (8 blocks)
1 100 8 REGISTER MANDEL
\   refuses (BEL) on overlap, name dup, boot-block range, CNT=0, depth<3, empty name

\ Upload the source via UART (chain mode preserves the in-source 0 N+1 LOAD chains)
\   python3 tools/upload_blocks.py /dev/ttyUSB0 asm/demo/mandel.fth --start 356 --safe-split

\ Then on the prompt:
RUN MANDEL                    \ load + compile (single LOAD, chain takes care of the rest)
MANDEL                        \ render

\ Or jump straight into the editor on the first block of a registered file:
?HEDIT MANDEL                 \ HEDIT opens at SD 1:100

\ Get file metadata onto the stack
?FILE MANDEL .S               \ ( 1 100 8 ) — hi lo cnt

\ Resize a file (overlap-checked against all other slots, not against itself)
12 RESIZE MANDEL              \ grow MANDEL to 12 blocks (refuses if it'd hit another file)
0  RESIZE MANDEL              \ effectively the same as ERA — slot freed, data preserved

\ Free a file's data without removing the dir entry
WIPE MANDEL
\ Or remove the directory entry (data sectors stay)
ERA MANDEL

0 200 HEDIT                   \ open SD sector 0:200 in the hex editor (no name lookup)
```

### Hex editor (HEDIT)

`HEDIT` is a full-screen hex/ASCII editor written entirely in Forth (blocks 15-26, ~1.6 KB of source). It renders 16×16 bytes of the current block buffer side-by-side in hex and ASCII, with live cursor tracking via ANSI escape sequences.

```
TAB=mode  BS=del<  ^X=del  ^N=ins  ESC=quit
00: 28 20 46 72 61 63 74 61 6C 20 64 65 6D 6F 20 3F  ( Fractal demo ?
01: 20 6C 6F 61 64 20 77 69 74 68 3A 20 32 20 4C 4F   load with: 2 LO
02: 41 44 20 74 68 65 6E 20 72 75 6E 20 53 49 45 52  AD then run SIER
...
                                                    [ASCII]
```

Keys: **arrow keys** move cursor; **Tab** toggles ASCII ↔ HEX input mode; **Enter** writes 0x0A (newline, shown as `↵`); **BS/DEL** delete the byte left of cursor; **^X** deletes the byte at cursor; **^N** inserts a NUL at cursor (bell on overflow); **^O** save (FLUSH); **^R** revert (reload block, discard edits); **^F / ^B** load next / previous block (bell-refused if there are unflushed edits — use ^O or ^R first); **ESC** save-and-exit; **^C** discard-and-exit. Also: `N HEDIT` opens block N directly (e.g. `5 HEDIT` to edit block 5). Status line shows current mode, block number, and a `*` when edits are unflushed.

## Architecture

```
         ┌─────────────────────────────────────────┐
         │              48-bit Microword            │
         │  opcode(4) we(1) carry(1) jmp(2) call(1)│
         │  ret(1) halt(1) imm(1) shift(2) ix(2)   │
         │  ram_addr(16) jmp_target(11) reserved(5) │
         └────────────────┬─────────────────────────┘
                          │
    ┌─────────────────────▼─────────────────────────┐
    │                  MC14500 CPU                   │
    │                                                │
    │  ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐
    │  │Bit 7│Bit 6│Bit 5│Bit 4│Bit 3│Bit 2│Bit 1│Bit 0│
    │  │Slice│Slice│Slice│Slice│Slice│Slice│Slice│Slice│
    │  └──┬──┴──┬──┴──┬──┴──┬──┴──┬──┴──┬──┴──┬──┴──┬──┘
    │     └─carry─┘   └─carry─┘   └─carry─┘   └─carry─┘
    │                                                │
    │  RR: 8-bit accumulator     SP: 8-bit stack ptr │
    │  IX: 15-bit index register (unified memory)    │
    │  PC: 15-bit (8192 ROM words)                   │
    │  Hardware call stack: 32 deep                  │
    └────────────────────────────────────────────────┘
```

### Slice opcodes (16)

`NOP LD LDC AND ANDC OR ORC XOR ADD SUB INC DEC STO STOC SET CLR`

Each slice is a 1-bit ALU. Eight slices are chained via carry to form the 8-bit datapath.

### Memory map

| Address | Content |
|---------|---------|
| `0x0000-0x001F` | Variables (tmp, ip, here, latest, …, lvh/lvl LEAVE chain) |
| `0x0020-0x00FF` | User variables (`VARIABLE` allocates from 0x24 up) |
| `0x0100-0x017F` | Word input buffer |
| `0x0180-0x01FF` | IP return stack (128 bytes — also backs `>R / R>`) |
| `0x0200-0x02FF` | Block buffer (`BLOCK` / `LOAD`) |
| `0x0400-0x07FF` | Unified dictionary (54 builtins + 48 forthwords, ~845 bytes) |
| `0x1000-0x7EFF` | Compile buffer (~28KB, unified memory via 15-bit IX) |
| `0x7F00-0x7FFB` | Data stack (grows down) |
| `0x7FFC-0x7FFF` | I/O registers (SP, IX lo/hi, UART) |

## Block storage

The Forth system includes a classic block-oriented "disk" — 64 KB organized as 256 blocks of 256 bytes, holding Forth source code that can be loaded at runtime. Block 0 boots automatically. See [doc/BLOCKS.md](doc/BLOCKS.md) for the full reference (`BLOCK`, `LOAD`, `THRU` and the `.fth` file format).

For the microword bit-level format see [doc/MICROWORD.md](doc/MICROWORD.md).

```bash
make run PROGRAM=asm/forth.asm STORAGE=build/storage.hex
```

## Performance

Benchmarked three threading models on the same algorithms:

```
                    Raw ASM      STC    Token    Token/Raw
  MUL 13x7             44cy    159cy   2496cy      56.7x
  FIB fib(10)         110cy    272cy   3663cy      33.3x
  FILL 32 bytes       386cy    386cy   8526cy      22.1x
  TOTAL               540cy    817cy  14685cy      27.2x
```

The 27x token-threading overhead is typical for 8-bit systems (Jupiter Ace: ~15-20x, eForth on ARM: ~5-10x). The single-accumulator architecture accounts for the higher end — no register file means frequent memory temporaries.

## Architectural trade-offs: Harvard earns its keep

Running the same Mandelbrot fractal in Forth on two very different systems makes the tradeoff visible:

|                                                  | MANDEL 32×16, MAXITER=15 |
|--------------------------------------------------|--------------------------|
| **C64 + durexforth** (6502 @ 1 MHz, von Neumann) | 63 s                    |
| **MC14500×8 + Forth** (27 MHz, Harvard)          | 4.8 s                   |

The ~13× wall-clock lead might look like raw clock speed winning. But *per clock cycle* the 6502 is actually more instruction-efficient — its 16-bit indexed addressing modes and zero-page tricks encode more work per instruction than this system's 8-bit accumulator with no register file.

What compensates is the Harvard split. Consider one memory load:

|                  | 6502 `LDA $1234`                               | MC14500×8 `LD [0x1234]`          |
|------------------|------------------------------------------------|----------------------------------|
| Memory accesses  | **4 sequential** (opcode, addr-lo, addr-hi, data) | **2 parallel** (microword + data) |
| Bus              | shared 8-bit (code + data)                     | 48-bit code ROM + 8-bit data RAM |

The 6502 pulls its instruction byte by byte from the *same* bus it needs for data. The bit-slice design pulls the complete instruction — opcode, 16-bit RAM address, all control bits — in one 48-bit microword from a dedicated code bus, *while reading data on a separate bus in parallel*. Effectively 2× the memory bandwidth per cycle.

Factorised vs the 6502:

| Effect                                          | Relative to 6502                             |
|-------------------------------------------------|----------------------------------------------|
| Thin 8-bit ISA (no register file, no indexing)  | ~2.7× slower (more instructions per task)    |
| Harvard: parallel instruction + data fetch      | ~2× faster (more memory bandwidth)           |
| Clock rate (27 MHz vs 1 MHz)                    | ~27× faster                                  |
| **Net**                                         | **~13× wall-clock speedup**                  |

Without the Harvard split, the design would fall below C64 level. With it, the per-clock performance is competitive with what an 8× discrete-MC14500B build at ~4 MHz could theoretically reach.

The principle — separate instruction and data paths to double memory bandwidth — is exactly what modern RISC CPUs still use internally, but only at the L1 cache level: below L1, code and data are unified in a single DRAM ("modified Harvard"). This design goes one step further: **pure Harvard all the way to main memory** — because below the on-chip SRAM there simply is no further layer to unify. An old idea that microcomputers of the 70s mostly skipped because the extra bus wiring wasn't worth it for a single-chip design. In a bit-slice + microcode architecture, it falls out naturally from the structure.

A durexforth port of the Mandelbrot benchmark is included in [`asm/demo/mandel_c64.fth`](asm/demo/mandel_c64.fth) for direct comparison.

## Project structure

```
├── rtl/                    Verilog source
│   ├── mc14500_cpu.v         Full 8-bit CPU (8 slices, carry chain)
│   ├── mc14500_slice.v       Single 1-bit ALU slice
│   └── mc14500_cpu_synth.v   Synthesis wrapper
├── asm/                    Assembly source + tooling
│   ├── mcasm.py              Microcode assembler (Python)
│   ├── forth.asm             Forth interpreter/compiler (~6677 ROM words, 112 ROM words + ~115 user-defined from blocks_core.fth)
│   ├── test_cpu.asm          CPU test program (21 tests)
│   ├── bench.asm             Raw assembly benchmarks
│   ├── bench_forth.asm       STC Forth benchmarks
│   ├── blockc.py             Block-storage compiler (.fth → .hex)
│   └── demo/                 Forth demo programs
│       ├── demo.fth            Math demo (factorial, fibonacci, CASE, etc.)
│       ├── demo_sierpinski.fth Sierpinski triangle fractal
│       ├── demo_doloop.fth     DO/LOOP/+LOOP/LEAVE edge cases
│       ├── demo_case.fth       CASE/OF/ENDOF/ENDCASE dispatch
│       ├── demo_execute.fth    Reflection: ' ['] EXECUTE
│       ├── demo_strings.fth    S" / TYPE / COUNT
│       ├── demo_rc4.fth        RC4 stream cipher (Wikipedia test vector)
│       ├── demo_rstack.fth     >R / R> / R@ verification
│       ├── demo_mandel.fth     Mandelbrot 8.8 fixed-point (standalone dev copy)
│       └── blocks.fth          On-FPGA block storage (40 blocks, HEDIT + MANDEL + demos, auto-boot)
├── sim/                    Testbenches
│   ├── tb_cpu.v              CPU testbench (automated, 21 checks)
│   ├── tb_interactive.v      Interactive emulator with UART
│   ├── tb_slice.v            Single-slice testbench
│   └── tb_bench.v            Benchmark harness
├── doc/                    Documentation
│   ├── BENCHMARKS.md         Performance analysis
│   ├── BLOCKS.md             Block-storage reference
│   ├── FPGA_BRINGUP.md       Tang Primer 20K flash + terminal setup
│   ├── MICROWORD.md          48-bit microword bit-layout reference
│   └── mc14500-bitslice-cpu.md  Design notes
├── schematic/              Generated circuit schematics (SVG)
├── Makefile                Build system
└── CLAUDE.md               Architecture reference (detailed)
```

## Make targets

| Target | Description |
|--------|-------------|
| `make cpu` | Run CPU testbench (21 tests) |
| `make slice` | Run single-slice ALU testbench |
| `make forth` | Launch Forth REPL (type commands, Ctrl+D to run) |
| `make run PROGRAM=asm/foo.asm` | Assemble and run any program |
| `make demo` | Run Forth math demo |
| `make sierpinski` | Run Sierpinski triangle demo |
| `make rstack-demo` | Return-stack + deep-nesting verification |
| `make bench` | Run performance benchmarks |
| `make bitstream` | Synthesize FPGA bitstream (Tang Primer 20K) |
| `make flash` | Load bitstream to FPGA SRAM (volatile) |
| `make flash-bit` | Load bitstream to on-board SPI flash (persistent) |
| `make clean` | Remove build artifacts |

## Design goals

This project explores what a minimal but complete computing system looks like when built from the ground up:

1. **Bit-slice architecture** — understanding how 8-bit CPUs are built from 1-bit building blocks
2. **Microcode control** — each instruction is a 48-bit word controlling all datapath signals directly
3. **Forth as a proof of completeness** — if you can run an interactive language with a compiler, the CPU is "real"
4. **Targeting real hardware** — the design is intended for implementation on a CPLD or FPGA

## License

MIT
