# 8x MC14500 Forth — Reference Manual

A working reference for the Forth interpreter / compiler that runs on the 8-bit
slice CPU built from eight MC14500 1-bit ALUs. Covers what's in ROM, what's
loaded from SD at boot, the stack effects of every word, and the limitations
you need to keep in mind while writing code for this system.

**Status:** ROM 7030 / 8192 words used (1162 free) as of 2026-04-28. All
features below are live unless explicitly marked otherwise.

---

## 1. Quick start

After `make flash` and the SD onboarding sequence (see §10), the FPGA boots,
prints `.....` (one dot per major source section), shows the `MENU` banner,
and drops you at a prompt:

```
8x MC14500 SD-Forth
type WORDS for the dictionary, HELP for the command reference,
FILES for the files-FS commands.
ok
>
```

You can then type Forth at the prompt. Each line ending with a newline is
parsed left-to-right, word-by-word. Unknown words print `<name> ?` and the
prompt returns. Compile mode is entered with `:` and exited with `;`.

---

## 2. Architecture & limitations

### Cell size
- **Cells are 8 bits.** Every entry on the data stack is one byte.
- **Doubles are 2 cells** — a 16-bit value sits on the stack as `( hi lo )`
  with `lo` on top of stack.
- Memory addresses outside page 0 are also doubles: `( addr_hi addr_lo )`.

### Number range and parsing
- Single-cell literals: `0..255` (unsigned) or `-128..127` (signed).
- The number parser **errors out on overflow** (`256 ?`, `1000 ?`, hex `100 ?`)
  rather than silently truncating. This is intentional — silent mod-256 wrap
  was the previous behaviour and bit several scripts.
- For values that need to be larger than 255, push them as a double explicitly:
  `0 100` is `100` as a double, `1 0` is `256` as a double, `3 232` is `1000`
  as a double. Use `D.` to print, `D+` / `D-` / `UM*` etc. for arithmetic.
- Hex parsing is case-insensitive (everything is uppercased by `WORD`).

### Comparisons are signed by default
- `<`, `>`, `=` work on signed bytes (`-128..127`). `255 5 >` is **false**
  because 255 is signed -1.
- Use `U<` and `U>` for unsigned 0..255 comparisons.

### `+LOOP` semantics
- Forth-83 modular: cross-detection at the `(limit-1, limit)` boundary in
  either direction. Countdown loops over the full 0..255 range work.
- `0 0 DO ... LOOP` runs **256 iterations** (LOOP wraps from 255→0=limit).
  This idiom replaces the older `256 0 DO ... LOOP` pattern.

### Memory layout (RAM)
| Range            | Use                                             |
|------------------|-------------------------------------------------|
| `0x0000..0x001F` | scratch + interpreter variables (`tmp`, `state`, `here`, `ipsp`, `base`, …) |
| `0x0020..0x002D` | block-buffer + THRU state                       |
| `0x002E..0x00FF` | user `VARIABLE` allocation (grows up from `varp`) |
| `0x0100..0x017F` | `WORD` input buffer / `PARSE-NAME` target       |
| `0x0180..0x01FF` | IP return stack (also backs `>R` / `R>` / `R@`) |
| `0x0200..0x02FF` | `BLOCK_BUF` (256 bytes for `BLOCK` / `LOAD`)    |
| `0x0400..0x0FFF` | unified dictionary (builtins + forthwords + user defs) |
| `0x1000..0x7EFF` | compile buffer (~28 KB for user word bodies)    |
| `0x7F00..0x7FFB` | data stack (`SP` starts at `0x7FFB`, grows down) |
| `0x7FF0..0x7FFF` | memory-mapped I/O (SPI, GPIO, UART, IX, SP)     |

### Memory layout (storage)
- **No on-chip block storage.** Every `BLOCK` / `LOAD` / `THRU` call routes
  through SD-card-over-SPI (`sd_read_r_body`).
- Sectors `0:0..0:255` are reserved for direct use (boot block, raw uploads).
- The files-FS directory lives at sector `1:0`. Data sectors start at `1:1`.

### Stacks
- **Data stack:** 252 bytes max (`0x7F00..0x7FFB`), grows downward from
  `0x7FFB`. Overflow corrupts compile-buffer bytes silently — be careful with
  unbalanced loops.
- **Hardware call stack:** 32 deep. Peak depth at boot is ~9 levels.
- **IP return stack:** 128 bytes at `0x0180+`, also used by `>R` / `R>` / `R@`.
  You must balance `>R` and `R>` within a single definition.

### What's *not* supported
- Floating point (apart from the 8.8 fixed-point helpers `F*` and `UM16*`).
- Multi-tasking, interrupts.
- File-based source (only block-based, on SD).
- 32-bit cells / triples.
- `SEE` (decompiler) — planned to live on SD when added; not in ROM.

---

## 3. Stack-effect notation

```
( before -- after )
```

- `n`, `m`     — single-cell signed (-128..127) or unsigned (0..255).
- `c`          — single-cell character.
- `flag`       — 0 = false, non-zero (typically 0xFF / -1) = true.
- `addr`       — page-0 address (single cell).
- `addr_hi addr_lo` or `hi lo` — 16-bit address (double, two cells).
- `xt`         — execution token = `( handler_hi handler_lo )` of a word.
- `d`, `ud`    — double = `( hi lo )` (signed / unsigned).
- `R:`         — describes effect on the IP return stack.

---

## 4. Word reference — by category

### 4.1 Stack manipulation

| Word    | Stack            | Description                                |
|---------|------------------|--------------------------------------------|
| `DUP`   | `( a -- a a )`   | Duplicate top                              |
| `DROP`  | `( a -- )`       | Discard top                                |
| `SWAP`  | `( a b -- b a )` | Exchange top two                           |
| `OVER`  | `( a b -- a b a )` | Copy second to top                       |
| `ROT`   | `( a b c -- b c a )` | Rotate third to top                    |
| `NIP`   | `( a b -- b )`   | Drop second                                |
| `TUCK`  | `( a b -- b a b )` | `SWAP OVER`                              |
| `?DUP`  | `( a -- a [a] )` | Duplicate only if non-zero                 |
| `2DUP`  | `( a b -- a b a b )` | Duplicate top pair                     |
| `2DROP` | `( a b -- )`     | Drop top pair                              |
| `2SWAP` | `( a b c d -- c d a b )` | Swap top two pairs                 |
| `DEPTH` | `( -- n )`       | Number of items on the stack               |
| `SP@`   | `( -- n )`       | Push current data-stack pointer            |

### 4.2 Arithmetic

| Word     | Stack             | Description                              |
|----------|-------------------|------------------------------------------|
| `+`      | `( a b -- a+b )`  | 8-bit add                                |
| `-`      | `( a b -- a-b )`  | 8-bit subtract                           |
| `*`      | `( a b -- a*b )`  | 8-bit multiply (low byte of product)     |
| `/`      | `( a b -- a/b )`  | Signed divide (quotient only)            |
| `MOD`    | `( a b -- a mod b )` | Signed modulo                         |
| `/MOD`   | `( a b -- rem quot )` | Signed divide with remainder         |
| `NEGATE` | `( n -- -n )`     | Two's-complement negate                  |
| `ABS`    | `( n -- \|n\| )`  | Absolute value (signed)                  |
| `MIN`    | `( a b -- min )`  | Signed minimum                           |
| `MAX`    | `( a b -- max )`  | Signed maximum                           |
| `1+`     | `( n -- n+1 )`    | Increment                                |
| `1-`     | `( n -- n-1 )`    | Decrement                                |
| `2*`     | `( n -- n*2 )`    | Logical shift left (= multiply by 2)     |
| `2/`     | `( n -- n/2 )`    | Logical shift right (= unsigned /2)      |

### 4.3 Double-cell arithmetic

| Word      | Stack                       | Description                          |
|-----------|-----------------------------|--------------------------------------|
| `D+`      | `( d1 d2 -- d )`            | 16-bit add via carry chain           |
| `D-`      | `( d1 d2 -- d )`            | 16-bit subtract                      |
| `D.`      | `( d -- )`                  | Print unsigned 16-bit decimal + space |
| `DNEGATE` | `( d -- -d )`               | Negate a double                      |
| `S>D`     | `( n -- d )`                | Sign-extend single to double         |
| `U>D`     | `( u -- ud )`               | Zero-extend unsigned single to double |
| `M*`      | `( n m -- d )`              | Signed 8x8→16 multiply               |
| `UM*`     | `( u1 u2 -- prod_lo prod_hi )` | Unsigned 8x8→16 multiply          |
| `UM16*`   | `( al ah bl bh -- p_lo p_hi )` | Unsigned 16x16→middle 16          |
| `F*`      | `( al ah bl bh -- r_lo r_hi )` | Signed 8.8 fixed-point multiply   |
| `UM/MOD`  | `( ud_lo ud_hi div -- rem quot )` | Unsigned 16/8 → 8/8 divide     |

### 4.4 Logic & comparison

| Word     | Stack             | Description                              |
|----------|-------------------|------------------------------------------|
| `AND`    | `( a b -- a&b )`  | Bitwise AND                              |
| `OR`     | `( a b -- a\|b )` | Bitwise OR (alias of `\|`)               |
| `\|`     | `( a b -- a\|b )` | Bitwise OR                               |
| `XOR`    | `( a b -- a^b )`  | Bitwise XOR                              |
| `INVERT` | `( n -- ~n )`     | Bitwise NOT (one's complement)           |
| `NOT`    | `( flag -- !flag )` | Logical NOT (alias of `0=`)            |
| `0=`     | `( n -- flag )`   | True if zero                             |
| `0<`     | `( n -- flag )`   | True if signed < 0                       |
| `=`      | `( a b -- flag )` | True if equal                            |
| `<`      | `( a b -- flag )` | Signed less-than                         |
| `>`      | `( a b -- flag )` | Signed greater-than                      |
| `U<`     | `( a b -- flag )` | Unsigned less-than                       |
| `U>`     | `( a b -- flag )` | Unsigned greater-than                    |
| `TRUE`   | `( -- -1 )`       | Push canonical true (0xFF)               |
| `FALSE`  | `( -- 0 )`        | Push canonical false                     |

### 4.5 Memory access

| Word    | Stack                        | Description                            |
|---------|------------------------------|----------------------------------------|
| `@`     | `( addr -- val )`            | Page-0 byte fetch (addr in 0..255)     |
| `!`     | `( val addr -- )`            | Page-0 byte store                      |
| `C@`    | `( hi lo -- val )`           | Byte fetch from any 16-bit address     |
| `C!`    | `( val hi lo -- )`           | Byte store to any 16-bit address       |
| `,`     | `( val -- )`                 | Append byte to compile buffer at HERE  |
| `HERE`  | `( -- hi lo )`               | Push current compile pointer (16-bit)  |
| `UNUSED`| `( -- d )`                   | Free space in compile buffer (double)  |

### 4.6 Numeric base

| Word      | Stack             | Description                            |
|-----------|-------------------|----------------------------------------|
| `BASE`    | `( -- addr )`     | Push address of base variable          |
| `HEX`     | `( -- )`          | Set base to 16                         |
| `DECIMAL` | `( -- )`          | Set base to 10                         |
| `.`       | `( n -- )`        | Print top-of-stack in current base     |

In hex mode, `.` always prints two zero-padded nibbles + space (`05`, `FF`).
In decimal, signed: `-128..127`. Hex literals accept digits `0-9 A-F`.

### 4.7 Character literals

| Word     | Stack             | Description                            |
|----------|-------------------|----------------------------------------|
| `CHAR`   | `( -- c )`        | Parse next word, push its first char (uppercased) |
| `[CHAR]` | `( -- )`          | Immediate. Compiles `do_lit + char`. Use inside `: ... ;` |
| `BL`     | `( -- 32 )`       | ASCII space character                  |

### 4.8 I/O

| Word      | Stack             | Description                            |
|-----------|-------------------|----------------------------------------|
| `EMIT`    | `( c -- )`        | Send byte to UART                      |
| `KEY`     | `( -- c )`        | Read one byte from UART (blocking, or from active source) |
| `KEY?`    | `( -- flag )`     | Non-blocking: true if input is waiting  |
| `CR`      | `( -- )`          | Print CR + LF                          |
| `SPACE`   | `( -- )`          | Print one space                        |
| `."`      | `( -- )`          | Immediate. `."` *string`"` compiles a printout. |
| `S"`      | `( -- )`          | Immediate. `S"` *string`"` compiles into `( hi lo len )`. |
| `TYPE`    | `( hi lo len -- )` | Print `len` bytes starting at 16-bit addr |
| `COUNT`   | `( hi lo -- hi' lo' len )` | Read length-prefixed string at addr |

### 4.9 Defining

| Word       | Stack                 | Description                          |
|------------|-----------------------|--------------------------------------|
| `:`        | `( -- )`              | Immediate. Start a new colon definition. |
| `;`        | `( -- )`              | Immediate. End a colon definition (compiles exit). |
| `VARIABLE` | `( -- )`              | Immediate. `VARIABLE NAME` allocates 1 byte at `varp`, NAME pushes its address. |
| `CONSTANT` | `( n -- )`            | Immediate. `n CONSTANT NAME` defines NAME to push n. |
| `FORGET`   | `( -- )`              | Immediate. `FORGET NAME` drops NAME and every newer entry. Refuses for builtins / pre-forthwords. |

### 4.10 Control flow (all immediate, used inside `: ... ;`)

| Word      | Description                                                |
|-----------|------------------------------------------------------------|
| `IF`      | If TOS is non-zero, run until matching `ELSE`/`THEN`.      |
| `ELSE`    | Alternate branch.                                          |
| `THEN`    | End of `IF` / `ELSE`.                                      |
| `BEGIN`   | Mark loop start.                                           |
| `UNTIL`   | Pop flag; if zero, jump back to `BEGIN`.                   |
| `WHILE`   | In `BEGIN ... WHILE ... REPEAT`, exit if flag is zero.     |
| `REPEAT`  | Jump back to matching `BEGIN`.                             |
| `DO`      | `( limit start -- )` Push pair to R-stack, start counted loop. |
| `LOOP`    | Increment index; exit when `index == limit`.               |
| `+LOOP`   | `( step -- )` Add step to index; exit when boundary `(limit-1, limit)` is crossed. |
| `LEAVE`   | Exit the innermost `DO` loop early.                        |
| `I`       | Push the current loop index (top of R-stack).              |
| `CASE`    | Begin `CASE` block.                                        |
| `OF`      | `( a -- )` If TOS equals `a`, run body until `ENDOF`.      |
| `ENDOF`   | Skip to matching `ENDCASE`.                                |
| `ENDCASE` | End `CASE` block (drops the selector).                     |

### 4.11 R-stack access (use inside `: ... ;`)

| Word | Stack                  | Description                              |
|------|------------------------|------------------------------------------|
| `>R` | `( n -- ) ( R: -- n )` | Push to R-stack                          |
| `R>` | `( -- n ) ( R: n -- )` | Pop from R-stack                         |
| `R@` | `( -- n ) ( R: n -- n )` | Copy top of R-stack                    |
| `I`  | `( -- n ) ( R: n -- n )` | Alias for `R@`. Loop index inside DO.  |

You **must** balance `>R` and `R>` within a single word. The R-stack also
holds the IP-return entries for compiled-word calls; corrupting it crashes.

### 4.12 Reflection

| Word       | Stack                 | Description                          |
|------------|-----------------------|--------------------------------------|
| `'`        | `( -- xt_hi xt_lo )`  | Parse next word, push its execution token. |
| `[']`      | `( -- )`              | Immediate version of `'`. Compiles a literal xt. |
| `EXECUTE`  | `( xt_hi xt_lo -- )`  | Call the word with the given xt.     |
| `WORDS`    | `( -- )`              | List every word in the dictionary.   |
| `.S`       | `( -- )`              | Print stack content (non-destructive). Format: `<n> top..bottom`. |
| `PARSE-NAME` | `( -- 1 0 len )`    | Parse next whitespace-delimited word. Pushes 16-bit address `( 1 0 )` of the word buffer at `0x0100` plus the length. |

### 4.13 Block storage (every block call goes to SD)

All block addresses are 16-bit doubles `( hi lo )`. Sector layout: `0:0..0:255`
is reserved (boot block + direct uploads), `1:0` is the files-FS directory,
data starts at `1:1`.

| Word     | Stack                    | Description                              |
|----------|--------------------------|------------------------------------------|
| `BLOCK`  | `( hi lo -- )`           | Read block to `BLOCK_BUF` (`0x0200`). No address pushed back — operate on `0x0200..0x02FF` via `B@`/`C@`/`C!` directly. |
| `B@`     | `( offset -- val )`      | Byte fetch from `BLOCK_BUF[offset]`.     |
| `LOAD`   | `( hi lo -- )`           | Read block, then interpret it as Forth source. Inside a `THRU`, `LOAD` syncs `thru_cur`. |
| `THRU`   | `( hi1 lo1 hi2 lo2 -- )` | LOAD blocks `hi1:lo1` through `hi2:lo2` sequentially. |
| `UPDATE` | `( -- )`                 | Mark current block dirty (will be written by `FLUSH`). |
| `FLUSH`  | `( -- )`                 | Write the current block back to SD if dirty. |
| `SD-INIT`| `( -- status )`          | Re-initialize the SD card. 0 = OK.       |
| `RXBLK`  | `( hi lo -- )`           | Receive 256 bytes from UART into block `hi:lo`, `UPDATE FLUSH`. |
| `LIST`   | `( hi lo -- )`           | (SD-loaded) Read block and print as 16x16-byte hex dump. |

### 4.14 System

| Word    | Stack    | Description                                       |
|---------|----------|---------------------------------------------------|
| `HELP`  | `( -- )` | Print built-in command reference.                 |
| `BYE`   | `( -- )` | Halt the CPU (only useful in sim — power-cycle to recover). |
| `ABORT` | `( i*x -- )` | Clear data and IP-return stacks, leave compile mode, kill source mode, return to prompt (silent). |
| `ABORT"`| `( flag -- )` | Immediate. `ABORT"` *message`"` — at runtime, if flag is non-zero, print message and ABORT; else skip the message. |

### 4.15 Comments

| Word | Description                                                  |
|------|--------------------------------------------------------------|
| `(`  | Block comment until matching `)`.                            |
| `\`  | Line comment until end-of-line.                              |

> **Gotcha:** `(` does **not** count nesting — it stops at the *first* `)`.
> A comment like `( foo (bar) baz )` closes after `bar` and the trailing
> ` baz )` is parsed as code, producing a `) ?` lookup error. Avoid inner
> parens or use `\` line comments instead.

### 4.16 Cooperative multi-tasking

Two-task cooperative round-robin scheduler. Both tasks share the dictionary,
data stack, compile buffer and block cache; each has its own SP, IP, IPSP,
a 16-byte IP-return-stack snapshot and a private `BASE`.

| Word    | Stack                         | Description                                                                       |
|---------|-------------------------------|-----------------------------------------------------------------------------------|
| `PAUSE` | `( -- )`                      | Yield to the other task if runnable; no-op if the other task is stopped.          |
| `TASK`  | `( xt_hi xt_lo -- )`          | Install xt as task1's initial IP, mark task1 runnable, reset its `BASE` to 10. The next `PAUSE` in task0 starts it. Also acts as **WAKE** — re-installing an XT into a stopped task1 fully resets its struct (SP, IP, IPSP, status, BASE) and the next PAUSE switches in. |
| `STOP`  | `( -- )`                      | Mark current task stopped. If the other task is runnable, tail-call into PAUSE (switch). If both are stopped now, reset to single-task baseline (`active_task=0`, task0 runnable, task1 stopped) and `ABORT` to the prompt.|

**Typical use:**
```forth
\ background heartbeat that ends when the foreground sets N=0
: T1 BEGIN 46 EMIT PAUSE  N @ 0 = UNTIL  STOP ;

\ foreground countdown that signals done by setting N=0
: T0 BEGIN N @ . CR  N @ 1 -  N !  PAUSE  N @ 0 = UNTIL  STOP ;

' T1 TASK     \ install task1 (does not start it yet)
T0            \ run task0; first PAUSE inside T0 switches in T1
```

**Per-task BASE** is preserved across switches:
```forth
: HEXTASK   HEX     BEGIN V @ . PAUSE 0 UNTIL ;
: DECTASK   DECIMAL BEGIN V @ . PAUSE 0 UNTIL ;
' HEXTASK TASK
DECTASK
\ Output alternates "<hex value>" and "<decimal value>" of V; setting HEX
\ in HEXTASK does not pollute DECTASK's printing.
```

**Tasks that can return.** A task installed via `TASK` must either:
1. Be an infinite loop (`BEGIN ... PAUSE 0 UNTIL ;`), or
2. Terminate via `STOP` (which never falls through to `;`).

A `;` exit from a TASK-installed task unwinds through `run_user`'s epilogue
with the wrong IPSP (the task1 struct's, not the original interp call's),
which corrupts the IP-return stack. The "main" task (task0, started normally
from interp) returns through its `;` cleanly.

**No `WAKE NAME` builtin.** `TASK` covers both initial-install and
resume-from-stopped. To resume a stopped task with the same XT:
```forth
' T1 TASK    \ re-installs T1 fresh
```
Stopped-task state (saved IP, IPSP, ip_save) is overwritten, so this is a
restart rather than a continue. Continuing a stopped task at its post-STOP
position is intentionally not exposed — the post-STOP IP usually points at
a `;` which would unwind incorrectly.

**Limits.**
- Two tasks total (task0 = main/interp thread, task1 = worker).
- IP nesting depth at PAUSE-time ≤ 8 frames (16 bytes of IP-stack snapshot).
- Shared data stack (page `0x7E00..0x7EFB`): each task should leave the stack
  balanced before `PAUSE` or its in-flight values will be overwritten by the
  other task.
- `STOP`-with-both-stopped leaks ~3 HW call-stack frames per cycle (same as
  any `ABORT`); the 16-deep HW stack survives a few of these before reset
  is needed.
- No pre-emption — purely cooperative. A task that never `PAUSE`s monopolises
  the CPU.

---

## 5. SD-loaded words (from `blocks_core.fth`)

These live on the SD card and are sourced at boot via the auto-magic-block
sequence. They're not in ROM and disappear if you `FORGET` the first one
loaded.

### 5.1 HEDIT — full-screen hex editor

`HEDIT ( -- )` opens an empty buffer. `hi lo HEDIT` opens block `hi:lo`.

ANSI cursor controls. `ESC` on a dirty buffer prompts `discard? y/n ` —
`y`/`Y` exits, anything else cancels.

Commands inside HEDIT:
- Arrow keys / hjkl: move cursor
- Hex digits / ASCII chars: type bytes
- `TAB`: toggle hex / ASCII mode
- `Ctrl+S`: `FLUSH`
- `Ctrl+R`: re-read block
- `ESC`: exit (with prompt if dirty)

Status line shows current block, cursor position, and `[HEX]` / `[ASCII]`.

### 5.2 MENU — boot banner

`MENU ( -- )` prints the welcome banner. Run automatically by the boot block.

### 5.3 LIST — print block as hex dump

`LIST ( hi lo -- )` reads block and prints a 16×16 hex+ASCII dump.

### 5.4 RXBLK / RXBLKS — UART block upload

- `RXBLK ( hi lo -- )` reads 256 bytes from UART into block `hi:lo`,
  `UPDATE FLUSH`. Used by `tools/upload_blocks.py`.
- `RXBLKS ( hi lo count -- )` chains `RXBLK` for `count` consecutive blocks.

### 5.5 ENDTHRU — early exit from sourced THRU

`ENDTHRU ( -- )` writes 0 to `thru_act` and forces `src=src_end`. The boot
block can specify a generously oversized `THRU` range; the source ends with
`ENDTHRU` to stop cleanly.

### 5.6 Files-FS (directory at SD `1:0`, data sectors `1:1+`)

A 16-slot directory stored as one block. Each slot is 16 bytes:
13 bytes name + start-hi + start-lo + count.

| Word      | Stack            | Description                                |
|-----------|------------------|--------------------------------------------|
| `DIR-INIT`| `( -- )`         | Wipe the directory (256 bytes of zero).    |
| `DIR`     | `( -- )`         | List all files.                            |
| `STATS`   | `( -- )`         | Print `files=N free=K blocks=M`.           |
| `REGISTER`| `( hi lo cnt -- )` then NAME | Add a file entry. Validates name, range, and overlap. BEL on error. |
| `RUN`     | `( -- )` then NAME | Source the file's blocks via `THRU`.     |
| `ERA`     | `( -- )` then NAME | Remove a file's directory entry (data blocks left intact). |
| `WIPE`    | `( -- )` then NAME | Zero every block listed in the file's entry. |
| `RESIZE`  | `( newcnt -- )` then NAME | Change a file's block count. `0 RESIZE NAME` is effectively `ERA`. |
| `?FREE`   | `( cnt -- hi lo )` | Find first free `cnt`-block range in `1:1..7:255`. BEL on miss. |
| `COPY`    | `( -- )` then SRC then DST | Duplicate SRC under DST, picks new range via `?FREE`. |
| `?FILE`   | `( -- hi lo cnt )` then NAME | Push file metadata. BEL on miss.     |
| `?HEDIT`  | `( -- )` then NAME | Open HEDIT directly on the file's first block. |
| `FILES`   | `( -- )`         | Print files-FS command reference.          |

---

## 6. Numeric examples

```forth
\ Single-cell math (signed -128..127 or unsigned 0..255):
5 3 + .                    \ 8
5 3 - .                    \ 2
13 5 /MOD . .              \ 3 2  (rem=3 quot=2)

\ Comparisons (note: < and > are SIGNED!):
255 5 > .                  \ 0   (255 = signed -1)
255 5 U> .                 \ -1  (true under unsigned)

\ Hex / decimal:
HEX FF .                   \ FF
A B + .                    \ 15  (= 10 + 11 = 21 decimal = 0x15)
DECIMAL 16 .               \ 16

\ Doubles via 2 cells (hi lo):
0 100 D.                   \ 100
1 0 D.                     \ 256
3 232 D.                   \ 1000

\ Number-overflow detection:
256 .                      \ 256 ?    (parser bails)
HEX 100 .                  \ 100 ?    (= 256 dec)

\ Char literals:
CHAR A .                   \ 65
: GREET [CHAR] H EMIT [CHAR] I EMIT ;
GREET                      \ HI

\ Loops (note +LOOP modular semantics):
: COUNT-UP   5 0 DO I . LOOP ;          \ → 0 1 2 3 4
: COUNT-DOWN 0 5 DO I . -1 +LOOP ;      \ → 5 4 3 2 1 0
: BIG-DOWN   0 200 DO I . -1 +LOOP ;    \ → 200 199 ... 1 0   (201 iters, no spurious exit at 128)
: POLL-256   0 0 DO KEY? IF LEAVE THEN LOOP ;  \ 256-iter polling via LOOP wrap

\ FORGET to roll back user definitions:
: FOO 11 ;
: BAR 22 ;
FORGET BAR                 \ BAR and everything newer disappear; FOO stays
FOO .                      \ 11
BAR                        \ BAR ?

\ ABORT for clean error throws:
: SAFE-DIV ( n d -- n/d )  DUP 0= ABORT" division by zero" / ;
6 3 SAFE-DIV .             \ 2
6 0 SAFE-DIV               \ division by zero  (and prompt returns)
```

---

## 7. Common idioms

### 256-iteration loop without 16-bit literal
```forth
0 0 DO ... LOOP            \ runs 256 times — LOOP wraps from 255→0=limit and exits
```

### Read a 256-byte block and process every byte
```forth
hi lo BLOCK                \ reads block into BLOCK_BUF (0x0200..0x02FF)
0 0 DO  I B@  ...  LOOP    \ I = 0..255, B@ reads BLOCK_BUF[I]
```

### Multi-byte (16-bit) constant via `2CONSTANT`-style trick
```forth
\ No 2CONSTANT in ROM. Workaround: define a word that pushes the pair.
: BLK-MAIN  3 232 ;        \ pushes 1000 as ( hi=3 lo=232 )
BLK-MAIN D.                \ → 1000
```

### Numeric address into page 0
```forth
\ Read state variable at RAM[6]:
0 6 C@ .                   \ prints current state byte
```

### Writing safe definitions with ABORT"
```forth
: NEEDS-NONZERO  ( n -- )  DUP 0= ABORT" expected non-zero" . ;
```

### Recovering memory after experimenting
```forth
: MARK ;                   \ define a tag-word
: FOO ... ;
: BAR ... ;
\ ... try things, decide they're junk ...
FORGET MARK                \ rolls back to before MARK; FOO, BAR, MARK gone
```

---

## 8. Error messages — what they mean

| Message            | Cause                                                  |
|--------------------|--------------------------------------------------------|
| `WORD ?`           | `WORD` was neither a number nor a known word.          |
| `123 ?`            | The literal `123` was never resolved (e.g., parser overflowed at `256`). |
| `!`                | Compile / dict OOM. Source mode is aborted; prompt returns. |
| `BEL` (audible)    | Files-FS validation failure (slot overlap, name dup, etc.) |
| `discard? y/n `    | HEDIT exit prompt on a dirty buffer.                   |

When a name lookup fails inside a sourced block (`THRU` / `LOAD` / autoboot),
the error aborts the source: `state=0`, `thru_act=0`, `src=src_end`. Recovery
is automatic — the prompt returns. This prevents the cascade-error storm that
would otherwise dump hundreds of `?` lines.

---

## 9. Boot sequence

1. Bitstream loads. CPU jumps to `init`.
2. `init` clears scratch RAM, sets `varp = 0x2E`.
3. `init` calls `dict_init` — writes the entire ROM-resident dictionary
   (builtins + pre-forthwords + their bodies + `HERE`/`LATEST`/`DICT_PTR`)
   into RAM via ROM-encoded `LD #v; STO [a]` pairs. Required because Gowin
   BSRAM init drops bytes silently.
4. `init` sets `BASE = 10`.
5. `init` calls `try_autoboot` — reads SD sector `0:0`. If the first 11 bytes
   match `\ 8xMC14500` (the boot magic), the rest of that block is sourced
   as Forth. Otherwise (no SD / read failure / wrong magic), `try_autoboot`
   returns silently.
6. Control falls into `main`, which prints the prompt unless source mode is
   active.

The standard boot-block payload is `0 100 0 138 THRU MENU` — sources blocks
`0:100..0:138` (which contain `blocks_core.fth`), then runs `MENU`. The
final `ENDTHRU` in `blocks_core.fth` allows specifying a generously oversized
range without sourcing trailing garbage.

---

## 10. SD onboarding

After `make flash`:

```bash
# 1. Build the boot block (auto-detects block count from blocks_core.fth size)
python3 tools/sd_install.py

# 2. Upload boot block and source with verify
python3 tools/upload_blocks.py /dev/ttyUSB0 bootblock.bin --start 0 --raw --verify
python3 tools/upload_blocks.py /dev/ttyUSB0 asm/demo/blocks_core.fth --start 100 --strip --verify
```

Hit reset → boot markers (`.....`) → MENU banner → prompt.

---

## 11. Limitations summary (one-liner each)

- 8-bit cells everywhere; 16-bit values live on the stack as pairs `( hi lo )`.
- `<` / `>` / `=` are signed; use `U<` / `U>` for unsigned ranges.
- Number parser bails on overflow (`256 ?`); use double-cell idioms for >255.
- `+LOOP` is Forth-83 modular: countdown loops over the full 0..255 work.
- Hardware call stack is 32 deep; nested compiled-word calls plus error
  recovery rarely exceed 12. Don't go nuts.
- Data stack is 252 bytes; overflow corrupts the compile buffer silently.
- `BLOCK` / `LOAD` always go to SD — no on-chip block storage. SD I/O is the
  bottleneck; cache the block buffer in `0x0200` and avoid repeated reads.
- No floats (8.8 fixed-point only via `F*` and `UM16*`).
- No `SEE` decompiler in ROM (planned to live on SD).
- Soft reset reloads the dict via `dict_init` but keeps user-allocated RAM
  beyond `varp`. Use `FORGET <name>` to roll back specific definitions.
- Compile-buffer overflow emits `!` and aborts source — definitions defined
  past that point are corrupt; `FORGET` to clean up.
- Cooperative multi-tasking is two-task only and shares the data stack. Tasks
  must `PAUSE` voluntarily; a task without `PAUSE` monopolises the CPU. Tasks
  installed via `TASK` must end with `STOP` or be infinite loops — falling
  through `;` corrupts the IP-return stack. See section 4.16.

---

## 12. Where to go next

- `CLAUDE.md` — architectural notes, design history, current ROM size.
- `doc/MICROWORD.md` — 48-bit microword field layout (CPU level).
- `doc/BLOCKS.md` — SD block storage layout and conventions.
- `asm/demo/blocks_core.fth` — the SD-loaded word source. Read this for HEDIT
  internals, files-FS implementation, and idiom examples.
- `asm/demo/*.fth` — example demos:
  - `mandel.fth`, `demo_rc4.fth`, `demo_strings.fth`, `demo_um16.fth` —
    arithmetic / string / RC4 demos.
  - `demo_pause.fth` — Stage-1 cooperative MT (infinite-loop heartbeat).
  - `demo_stop.fth` — Stage-2 cooperative MT (both tasks `STOP` gracefully).

Bugs, surprises, or missing words — flag them; this manual lives in-tree and
is meant to evolve.
