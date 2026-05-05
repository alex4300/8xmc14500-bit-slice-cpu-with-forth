# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

An 8-bit CPU built from eight 1-bit ALU slices in Verilog, inspired by the Motorola MC14500 Industrial Control Unit. Microcode-driven with a 48-bit microword. Includes microcode assembler (Python), interactive emulator, Forth interpreter/compiler with a full-screen hex editor (HEDIT), a tiny block-directory file system, and an FPGA target (Tang Primer 20K) with **SD-card over SPI as the only block storage**. The BSRAM emulator was eliminated (Phase C, 2026-04-25); ROM now carries the entire Forth kernel + builtins + SD primitives, and higher-level vocabulary (HEDIT, MENU, files-FS) lives on the SD card and is auto-loaded at reset via a magic-header bootblock.

## Build & Test Commands

Requires Icarus Verilog (`brew install icarus-verilog`) and Python 3.

```bash
make slice          # Single-slice ALU testbench (33 tests)
make cpu            # Full CPU testbench (21 tests) — uses test_cpu.asm
make all            # Run both testbenches
make run PROGRAM=forth.asm   # Assemble + run (piped input)
make repl PROGRAM=forth.asm  # Type input, Ctrl+D to execute
make bench          # Run benchmarks (raw assembly vs STC Forth)
make flash          # Build + flash bitstream to Tang Primer 20K
make clean          # Remove generated files
```

Assembler: `python3 mcasm.py prog.asm [-v] [-E] [-o output.mem]`

### Onboarding a fresh SD card (Phase D workflow)

After `make flash`, the FPGA boots a minimal Forth (kernel + builtins + RXBLK + HELP). Higher-level vocabulary comes from SD:

```bash
# 1. Build the boot block (auto-detects source size from blocks_core.fth)
python3 tools/sd_install.py
# 2. Upload bootblock + source with verify (catches UART/SD glitches with retry)
python3 tools/upload_blocks.py /dev/ttyUSB0 bootblock.bin --start 0 --raw --verify
python3 tools/upload_blocks.py /dev/ttyUSB0 asm/demo/blocks_core.fth --start 100 --strip --verify
```

Reset → ROM init → `try_autoboot` reads sector 0 → magic `\ 8xMC14500` matches → block sourced as Forth → `0 100 0 138 THRU MENU` → boot markers (`.....`) + MENU banner.

`sd_install.py` auto-detects block count from `asm/demo/blocks_core.fth` size, so the bootblock always matches the source. Passing `--count` overrides.

For per-program uploads (e.g. mandel.fth), use `--safe-split` (default chain mode) and call via `RUN <NAME>` after `REGISTER`-ing.

`tools/sd_install.py --sector` emits a 512-byte sector for `dd` if you ever do have an SD reader.

## Architecture

### CPU (mc14500_cpu.v)
- **48-bit microword**, 15-bit PC (8192 ROM words on FPGA; 32K addressable), 16-bit ram_addr field (eff_addr currently 15-bit / 32 KB)
- 8 slices via `generate`, carry chain `carry_chain[0..8]`
- **Registers**: RR (8-bit accumulator), IX (15-bit index, 0x7FFD=lo + 0x7FFB=hi), SP (stack pointer, 0x7FFC)
- **I/O**: 0x7FFF=UART data, 0x7FFE=UART status, 0x7FF4=GPIO LEDs, 0x7FF0-0x7FF2=SPI master (data/status/cs). 0x7FF8-0x7FFA stubs (write-ignored, read-zero) — were the BSRAM storage MMIO before Phase C.
- Hardware call stack: 32 deep (15-bit entries). Boot-time peak nesting hits ~7-9 levels (block_dispatch → sd_read_r_body → sd_init_body → sd_cmd → wait_r1 → spi_skip → spi_xfer).

### Microword Format (48 bits)

See `doc/MICROWORD.md` for the full reference.

### Slice (mc14500_slice.v)
- 16 opcodes: NOP LD LDC AND ANDC OR ORC XOR ADD SUB INC DEC STO STOC SET CLR
- Combinational ALU + sequential RR update. STO/STOC don't modify RR.

### Assembler (mcasm.py)
- Multi-pass with late-bind constants, labels, `.data`, `.org`, `.print "string"` macro
- Operand forms: `[addr]`, `#value`, `[addr, x]` (IX), `[addr, s]` (SP peek)
- Pseudo-ops: PUSH, POP, SHL, SHR, ROL, ROR, JMPI, JZI, JCI, CALLI
- Dictionary entry format: `[link(2), name_len|imm_flag(1), name_chars(N), handler_addr(2)]`
- `.builtin "NAME" handler [immediate]` — pre-populated dict entries.
- `.forthword "NAME" [immediate] / tokens...` — pre-compiled bodies (token-threaded), with `@N` for word-relative branch targets.
- **Late-bind constants** (`INIT_HERE_HI` / `INIT_HERE_LO` / `INIT_LATEST_HI` / `INIT_LATEST_LO` / `INIT_DICT_PTR_HI` / `INIT_DICT_PTR_LO`): immediates patched after dict layout is known.
- **`dict_init` post-pass** (NEW, Phase D): when `forth.asm` declares a `dict_init` label, mcasm fills its body with `LD #v; STO [addr]` pairs covering every non-zero byte of the static dict + compile bodies + cold-state pointers, then a trailing `RET`. **Required on the FPGA** because Gowin BSRAM init (both inline and `$readmemh`) drops data unreliably for the byte-wide cpu.ram — the only path that actually lands the dict in RAM is to drive the writes from ROM at boot.

### Forth Interpreter (forth.asm)
- **~7101/8192 ROM words** (2026-05-04, after 2-slot ping-pong block-cache; Tier-S + FORGET + ABORT/ABORT" + parse-overflow-detect baseline)
- **Pre-populated dict**: 61 builtins + 51 forthwords ≈ 936 bytes at 0x0400-0x07A7; `init` calls `dict_init` to write all dict + body bytes into RAM.
- Single unified dictionary at 0x0400+. Walker dispatches by `handler_hi == 0` (builtin → 1-byte token) vs `>= 0x10` (user word → `do_call_user` + 2-byte addr).
- **Defensive dict-walk guard**: `fu_next` aborts to `?` if `link_hi < 0x04` (dict lives in 0x0400+); prevents the 0x0000 → 0x0000 → … infinite loop that used to wedge the prompt when the dict region was zeroed.
- Token-threaded compiler: `:` compiles tokens to RAM[HERE+], `;` writes exit token (0).
- `do_call_user` + `run_user` for calling compiled words from NEXT.
- Nested user-word calls use a separate ip return stack at RAM[0x0180+] (depth pointer `ipsp`).
- Compiler words (`:` `;` IF ELSE THEN BEGIN UNTIL WHILE REPEAT `(` `."`) use trampolines in first 256 addresses for CALLI dispatch.
- **Bounds-checked compile**: `compile_byte` refuses writes outside 0x10-0x7E pages (emits `!`); `write_dict_byte` refuses writes outside 0x0xxx page. Both OOM paths now also `CALL oom_abort_src` — drops compile mode (state=0), kills source mode (thru_act=0, src=src_end), and sets eol=1 so the next `word` returns wlen=0 and `main` prints a fresh prompt. Bounds the legacy "endless `!` cascade" to a few `!` chars per dispatch step. **`do_colon` sets `state=1` BEFORE calling `create`** so a wdb_oom abort inside `create` actually leaves the system in interpret mode (otherwise `do_colon`'s tail `state=1` would re-enter compile mode at the prompt).
- **Error reporting** (2026-04-27): `nfail` prints `<word> ?\r\n` (the offending name + question mark + newline) instead of bare `?`. When a source mode (THRU/LOAD/autoboot) is active at error time, `nfail` aborts source: `thru_act=0`, `src=src_end`, `state=0` (drop compile mode). Stops cascade-errors and gives a clean prompt to recover from. **`tick_fail` now `JMP nfail`** so `'` lookup misses get the same `<word> ?\r\n` + source-abort treatment.
- **Quiet source mode** (2026-04-27): `main` suppresses the `ok\r\n> ` prompt while `thru_act!=0` OR `src` has bytes remaining. Boot output is now just the markers + final banner — no `> ok` salad between every newline.

#### Word inventory (ROM)
- **Stack:** DUP DROP SWAP OVER ROT NIP TUCK ?DUP 2DUP 2DROP 2SWAP DEPTH SP@
- **Math:** + - * /MOD / MOD NEGATE ABS MIN MAX 1+ 1- 2* 2/
- **Numeric base:** `BASE` ( -- addr ), `HEX`, `DECIMAL`. Base defaults to 10. `HEX` flips parser + `.` to base 16; in HEX mode, hex literals (0-9, A-F) are accepted, and `.` prints two zero-padded nibbles + space. Multi-base only — arbitrary bases (e.g. octal) NOT supported by parser/print.
- **Character literals:** `CHAR x` ( -- c ) parses next word, pushes first char (already uppercased by `word`). `[CHAR] x` is the immediate compile-time variant: emits `do_lit + char` to the current body. Standard convention — use `CHAR` in interpret mode, `[CHAR]` inside `: ... ;`.
- **Dict roll-back:** `FORGET <name>` walks the chain, finds `<name>`, and rolls back `LATEST`/`DICT_PTR`/`HERE` so the named entry and every entry newer than it are dropped. Refuses (via `nfail`) when the target is a builtin (handler_hi == 0) or pre-populated forthword (handler_hi 0x04..0x0F) — only user-defined words (handler_hi >= 0x10, body in compile buffer) are eligible. Cures the HERE/dict_ptr accumulation when the same source file is re-LOAD-ed.
- **Aborts:** `ABORT` ( i*x -- ) clears the data + IP-return stacks, drops compile mode, kills source mode, returns to the prompt loop (silent — no message). `ABORT" message"` is immediate and compiles a runtime test that pops a flag — if the flag is non-zero at runtime it prints the inline message and tail-calls `abort_body`; if zero it skips the message and continues. Both share `abort_body`, modeled on `nfail`'s source-abort path plus stack resets.
- **Double:** UM* UM16* F* UM/MOD M* D+ D- D. DNEGATE S>D U>D
- **Logic:** | OR AND XOR INVERT 0= NOT = < > U< U> 0< TRUE FALSE   (`OR` is an alias for `|`, ANS-Forth standard)
- **Memory:** @ ! , C@ C! HERE B@
- **R-stack:** >R R> R@ I
- **I/O:** . EMIT KEY KEY? CR ." S" TYPE COUNT WORDS .S SPACE BL
- **Define:** : ; VARIABLE CONSTANT FORGET
- **Abort:** ABORT ABORT"
- **Reflection:** ' ['] EXECUTE
- **Control:** IF ELSE THEN BEGIN UNTIL WHILE REPEAT DO LOOP +LOOP LEAVE CASE OF ENDOF ENDCASE
- **Multi-tasking (Stage 1+2+2b, cooperative):** `PAUSE`, `TASK ( xt_hi xt_lo -- )`, `STOP`. Two tasks share dict/stack/cache; each has its own SP/IP/IPSP plus a 16-byte IP-return-stack snapshot **and a private BASE** (per-task numeric base, swapped via `tb_save[active_task]` on every PAUSE — HEX in one task does not bleed into the other). PAUSE switches if the other task is runnable, otherwise returns immediately. `TASK` installs an XT as task1's body, marks it runnable, and resets task1's BASE to 10 (DECIMAL). **`STOP`** marks the current task as stopped and either tail-calls PAUSE (if the other task is still runnable) or `abort_body` (if both are stopped, after resetting active_task=0 and the status fields to single-task baseline). With STOP available, tasks may terminate gracefully (`: T1 ... STOP ;`); without STOP, tasks installed via TASK must be infinite loops (`BEGIN ... PAUSE 0 UNTIL ;`) because a `;` exit unwinds through the wrong run_user epilogue. See `pause_body` / `stop_body` near line ~2290 in forth.asm.
- **Block storage (all 2-cell `( hi lo )`):** BLOCK LOAD THRU FLUSH UPDATE B@ — all routed through ROM SD primitives (`sd_read_r_body` / `sd_write_r_body`).
- **Parser:** `PARSE-NAME ( -- 1 0 len )` — used by `RUN`/`REGISTER`/`ERA`/`WIPE`.
- **SD I/O:** `SD-INIT ( -- status )` — direct ROM primitive.
- **UART upload:** `RXBLK ( hi lo -- )` receives 256 B from UART into block (hi:lo), `UPDATE FLUSH`.
- **Help:** `HELP` prints the built-in command reference.
- **Comment:** `( ... )` block, `\ ... ` line.
- **Debug/System:** DEPTH .S UNUSED BYE

#### Word inventory (SD-loaded from blocks_core.fth)
- **HEDIT** — full-screen hex editor, ANSI cursor control. ESC on dirty buffer prompts `discard? y/n ` (y/Y exits, anything else stays).
- **MENU** — welcome banner, prints SD-INIT/HEDIT/files-FS hints.
- **ENDTHRU** — stops the current THRU early. blocks_core.fth ends with `ENDTHRU` so the bootblock can specify a generously oversized THRU range (sd_install.py default is 50 blocks, source is currently 39) without sourcing trailing garbage.
- **Files-FS** at SD sector 1:0 (sectors 0:0..0:255 reserved for direct use — boot block, source upload, raw HEDIT, etc.): `DIR-INIT DIR STATS REGISTER RESIZE RUN ERA WIPE ?FILE ?HEDIT ?FREE COPY FILES`. Slot layout: 13-char name + (start-hi, start-lo) + cnt; 16 entries per directory block.
  - `WIPE <name>` zeros every block listed under the file's directory entry (data only — the dir slot itself is left intact; use `ERA` to remove the entry).
  - `REGISTER` safety: refuses BEL on stack-underflow, empty name, CNT=0, start=0:0 (boot block), start=1:0 (directory), name already registered, or block-range overlapping any existing file. Range checks use `U16<` and `SEND` helpers (16-bit unsigned compare + start+cnt = end with carry) defined in blocks_core.fth.
  - `?FREE ( cnt -- hi lo )` finds the first free CNT-block range starting from 1:1, capped at hi<8 (1:1..7:255). BEL on cnt=0 / exhausted.
  - `COPY SRC DST` parses two names, duplicates SRC under DST, picks new range via `?FREE`.
  - `STATS` prints `files=N free=K blocks=M` summary.
  - `RESIZE ( newcnt -- ) NAME` changes a file's CNT byte with overlap check against all *other* slots. `0 RESIZE NAME` is effectively `ERA` (slot becomes free, data sectors retained).
  - `?FILE NAME` ( -- HI LO CNT ) pushes file metadata; BEL on miss.
  - `?HEDIT NAME` ( -- ) opens HEDIT directly on the file's first block; BEL on miss.
  - `FILES` prints the files-FS command reference at the prompt (companion to ROM `HELP`).
- **Boot progress markers**: `46 EMIT` (= `.`) at the end of each major source section — editor utils, HEDIT, RXBLK, files-FS basics, extensions. `.....` printed during boot signals "all sections compiled".

### RAM Layout
```
0x0000-0x001F   Variables (tmp, wlen, hash, state, ip, here, varp, ipsp, lvh/lvl, etc.)
                0x1A-0x1B sd_save_lo/hi (SD retry preservation)
                0x1C base — numeric base, default 10 (set after dict_init).
                0x1D active_task — Stage-1 PAUSE: 0=task0, 1=task1.
                0x1E tb_save+0 — task0 BASE save (per-task BASE, Stage 2b).
                0x1F tb_save+1 — task1 BASE save.
0x0020-0x002D   buf_blk(20) buf_dirty(21) latest_hi(22) dict_ptr_hi(23) buf_blk_hi(24)
                thru_act(25) thru_cur_lo/hi(26-27) thru_end_lo/hi(28-29)
                alt_blk(2A) alt_blk_hi(2B) alt_dirty(2C)  [slot-1 cache metadata; was legacy SD-XT]
0x002E-0x00BF   user VARIABLE allocation (varp starts at 0x2E) — ~146 bytes free.
0x00C0-0x00D4   Task-0 struct (21 B: sp, ip_hi, ip_lo, ipsp, status, ip_save[16])
0x00D5-0x00E9   Task-1 struct (21 B, same layout)
0x00EA-0x00FF   Free reserve (22 B for future task fields / 3rd task slot)
0x0100-0x017F   Word input buffer (WORD routine + PARSE-NAME target)
0x0180-0x01FF   IP return stack (128 bytes, also backs >R/R>/R@)
0x0200-0x02FF   Slot 0 (BLOCK_BUF) — user-visible block buffer (HEDIT, BB!/BBC, RXBLK, B@)
0x0300-0x03FF   Slot 1 — block-cache only, ping-pong-swapped into slot 0 on hit
0x0400-0x0FFF   Unified dictionary: 60 builtins + 51 forthwords pre-populated by dict_init
0x1000-0x7DFF   Compile buffer (unified memory, ~27 KB via 15-bit IX)
0x7E00-0x7EFB   Data stack (SP grows down from 0xFB; eff = 0x7E00 + sp_data)
0x7EFC-0x7EFF   Reserved (top of stack page)
0x7F00-0x7FEF   Free RAM region (currently unused)
0x7FF0-0x7FF2   MMIO: SPI master (0x7FF0=DATA R/W, 0x7FF1=STATUS[0]=busy, 0x7FF2=CS bits)
0x7FF4-0x7FF5   MMIO: GPIO LEDs (out), GPIO in
0x7FF8-0x7FFA   Phase C stubs (write-ignored, read-zero)
0x7FFB          IX_HI register (15-bit IX = {ix_hi, ix})
0x7FFC-0x7FFF   Registers/IO (SP-write, IX_LO, UART_STATUS, UART_DATA)
```

**Data stack mechanism.**  SP register is 8-bit at MMIO 0x7FFC; PUSH/POP
encode `ram_addr = STACK_BASE = 0x7E00` in their microword
(`mcasm.py` `STACK_BASE` constant, applied by the STACK_OPS path), so
`eff = 0x7E00 + sp_data`.  Init sets SP=0xFB → first PUSH writes
RAM[0x7EFA].  PEEK syntax `LD [0x7E00, s]` / `LD [0x7E01, s]` reads
TOS / TOS-1 directly via the same sp_mode path.  Page 0 is consequently
free for user VARIABLEs and (planned) PAUSE multi-task structs.

Pre-2026-05-04 the stack lived at RAM[0..0xFB] (Page 0), contended with
user VARIABLEs.  See `feedback_data_stack_at_page_0.md` for the historical
constraint.  `.S` (do_dots) was patched to walk the new range with
`IX_HI = 0x7E`.

**Critical RAM notes:**
- 0x0F and 0x13 are **NOT free** — used as scratch by UM16*/F*/M* multiplication helpers and compile_byte.
- 0x18/0x19 are reused: `lvh/lvl` during compile (LEAVE/ENDOF chain head) AND `ddot_dlo/ddot_dhi` during D. — fine because compile-time and D.-runtime never overlap.
- 0x2A-0x2C are slot-1 cache metadata (alt_blk / alt_blk_hi / alt_dirty) since 2026-05-04; 0x2D is free (the legacy SD-XT slots that lived here were retired in Phase A).
- **Block cache** (2026-05-04): two-slot ping-pong cache. Slot 0 at page 0x02 is user-visible — HEDIT, BB!/BBC, RXBLK, B@ and STATUS/BLK@/DIRTY? all hardcode page 0x02 / page-0 mirrors (0x20/0x21/0x24), so this hasn't changed. Slot 1 at page 0x03 holds the previously-active block; on a `BLOCK X` hit there, `block_dispatch` does a 256-byte data swap + meta swap (~85 µs) instead of a fresh SD read (~10 ms, 100× faster). On a miss the current slot 0 contents are copied down to slot 1 first, preserving them in cache. `FLUSH` walks slot 1 (swap-write-swap-back) then slot 0. Implementation in `forth.asm` near `block_dispatch`/`save_buffers_body`; `blocks_core.fth` was *not* changed — the cache is fully transparent to user code.
- **Stage-1 cooperative multi-tasking** (2026-05-04 evening): `PAUSE` and `TASK` builtins. Two task structs at RAM[0xC0..0xE9] (21 B each: sp, ip_hi, ip_lo, ipsp, status, ip_save[16]). `active_task` flag at RAM[0x1D] selects which struct mirrors the live registers. `pause_body` saves the current task's full state into its struct, copies the IP-return-stack contents into the per-task `ip_save` buffer (max 16 bytes — covers ~8 frames of nesting, deep enough for the SD path), toggles `active_task`, restores the other task's state and copies its `ip_save` back into the IP-stack. If the other task's `status` is non-zero (stopped), PAUSE fast-RETs without switching. `TASK` (called as `xt TASK`, where xt comes from `'`) installs an XT as task1's initial IP and marks task1 runnable. The HW call stack is shared between tasks but `pause_body` is always called from the SAME nesting level (`next` loop's `CALLI`), so the post-RET path is well-defined regardless of which task is now active. Tasks must be infinite loops (the run_user epilogue uses the current task's ipsp on exit, which corrupts state if the wrong task's `;` is hit).

## Key Design Details

- Carry flag is **latched** — updated on arithmetic AND shift ops.
- SUB uses borrow semantics: carry=1 means borrow.
- Shift: CPU rewires slice data_in from neighbor RR bits. Opcode forced to LD.
- Reset timing: testbenches release `rst_n` with `#1` delay after clock edge.
- Boot: ROM address 0 contains `JMP init` (address 0 reserved as exit token for NEXT).
- NEXT token interpreter: token 0 = exit (do_exit/RET). Other tokens are ROM addresses called via CALLI.
- `.print` in assembler generates `LD #char` + `STO [0x7FFF]` pairs (2 ROM words per char).
- Interactive testbench reads from `.uart_input` file (not stdin). Makefile `run`/`repl` targets handle this.
- Testbench wind-down: 4M cycles after input exhaustion (complex Forth programs need this).
- Testbench MAX_CYCLES: 100M (per `sim/tb_interactive.v`).
- `rch` (read_char) in Forth does NOT echo CR/LF to avoid terminal cursor issues.
- **`<` and `>` are SIGNED** — `255 5 >` is false (255 treated as -1). For unsigned byte/offset comparisons use `U<` or `U>` (now in ROM, 2026-04-26).
- **`+LOOP` boundary detection** (rewritten 2026-04-27 evening): `plus_loop_rt_body` now uses Forth-83 modular semantics — for step>=0 cross iff `(limit-1-old) < step`, for step<0 cross iff `(old-limit) < |step|`. Replaces the buggy sign-XOR-of-(idx-limit) test that fired at the antipode of `limit` (e.g., 127↔128 when limit=0). Countdown loops over wide ranges (`0 200 DO ... -1 +LOOP` etc.) now iterate correctly.
- **`LOAD` syncs `thru_cur` when THRU is active** — so chain-LOADs inside sourced blocks don't trigger THRU's auto-advance to re-process blocks the chain already covered.
- **`compile_quoted_string` parks the length-byte address on the data stack** across the char-read loop. Originally it used `tmp2`/`hash` page-0 slots, which are trashed by `block_dispatch` → `sd_read_r_body` if a `."` string crosses an SD-block boundary. Symptom of regressing this: FILES help printed correctly until the first cross-boundary `."`, then garbage from the dict region. Don't refactor back to scratch slots without re-checking SD-side preservation.

### SD-Card over SPI
- **HW SPI-Master** in `rtl/spi_master.v` (~80 lines, Mode-0, 8-bit, CLK_DIV=64 → ~210 kHz SCK, safe for SD init).
- **MMIO interface** (CPU side): 0x7FF0 SPI_DATA (write=start TX, read=RX byte), 0x7FF1 SPI_STATUS (bit 0 = busy), 0x7FF2 SPI_CS (bit 0 drives sd_cs pin).
- **Tang Primer Dock 3713 pins** (Mic Array header J14): SCK=T6, CS=P6, MOSI=P8, MISO=T8. MISO has `PULL_MODE=UP` in constraints.
- **ROM SD primitives** (Phase A, in `forth.asm`): `spi_xfer`, `spi_skip`, `sd_on/off`, `sd_warmup`, `wait_r1`, `sd_cmd0/8/55/acmd41`, `sd_init_body`, `sd_read_body`, `sd_write_body`, `sd_read_r_body` (retry-with-init), `sd_write_r_body`. ~270 ROM words.
- **`block_dispatch`** (Phase C): unconditionally calls `sd_read_r_body` for any block. No more BSRAM range check, no XT lookup.
- **Auto-boot** (Phase D): `try_autoboot` reads SD sector 0:0 at boot, validates magic `\ 8xMC14500` byte-for-byte, and on match `set_src_block_buf` makes the block the initial source. SD missing / read fail / magic mismatch → silent fallback to UART prompt — no random-source execution.

### Tools
- `tools/sd_install.py` — builds the boot block (magic + auto-load command). Default auto-detects block count from `--source` (default `asm/demo/blocks_core.fth`); fall back is 50. `--sector` for full 512-byte `dd` use.
- `tools/upload_blocks.py` — uploads via UART using ROM's RXBLK. Modes: default chain (`0 N+1 LOAD\n` injected), `--safe-split` (refuses to split inside `:` ... `;`), `--strip` (drops legacy block markers / inter-block LOADs, packs linear), `--raw` (verbatim). `--verify` reads each block back through `BLOCK_BUF` after RXBLK and retries up to 3× on mismatch — catches UART FIFO drops + SD cache glitches; reports failed blocks at end.
- `tools/sd_image.py` — packs a `.fth` source into a binary image for `dd`-style direct SD writes (when an SD reader is available).
- `tools/build_boot_text.py` — earlier Phase B helper, kept for reference; superseded by the SD-only path.
- `tools/merge_blocks.py` — earlier Phase A helper that merged sd.fth + blocks_core.fth into blocks.fth (BSRAM era); superseded by `--strip` upload of blocks_core.fth directly.

#### Tool gotchas
- `wait_for(b'ok')` would false-positive on `"ok"` substring inside data (e.g., comments containing the literal word "ok"). Tool now uses `b'ok\r'` because Forth source is LF-only and only the prompt has CR. **Don't downgrade.**
- `--verify` reads BLOCK_BUF (= what RXBLK just wrote), not a fresh SD read-back. This catches UART transfer issues but won't catch SD-side persistence failures. For full SD round-trip verification, would need a separate `BLOCK <hi> <lo> <emit>` pass.

### Robustness model

- **Soft reset** (button): CPU registers cleared, RAM kept. ROM `init` re-runs `dict_init`, which overwrites the dict + bodies + HERE/LATEST/DICT_PTR with known values. Soft reset always returns a clean dict regardless of session corruption.
- **Power cycle / make flash**: bitstream re-loads, ROM init runs from scratch, dict_init repopulates RAM. Plus `try_autoboot` re-runs the SD boot block.
- **Compile-time guards**: `compile_byte` refuses writes outside 0x10-0x7E pages; `write_dict_byte` refuses outside 0x0xxx. Garbage compiles get a `!` instead of cascade.
- **Runtime guards**: dict-walk aborts on `link_hi < 0x04` (corrupted chain), preventing infinite loops.
- **Auto-boot guards**: SD-INIT failure / read failure / magic mismatch all silently fall through to a UART prompt; no random Forth source is executed from a card with garbage at sector 0.
- **No more BSRAM corruption surface**: with the BSRAM emulator gone (Phase C), there is no in-bitstream block storage for runaway code to corrupt. SD writes go through `sd_write_r_body` which is only triggered by explicit `UPDATE FLUSH`.

## Phase history (the milestones)

- **Phase A (2026-04-25)** — SD-over-SPI primitives ported from `sd.fth` to ROM. `block_dispatch` / `save_buffers_body` call them directly; the SDHOOK XT-registration dance is gone.
- **Phase B (2026-04-25)** — boot text moved out of BSRAM. First attempt: blocks_core.fth source in a dedicated `boot_text` BRAM mapped at 0x6000-0x77FF. Worked in sim, failed on FPGA due to Gowin/yosys BRAM init unreliability.
- **Phase C (2026-04-25)** — BSRAM emulator (`stg_ram` + storage MMIO) removed from `mc14500_top.v`. `block_dispatch` / `save_buffers_body` simplified to always go SD. Frees ~8 BSRAM blocks that the boot_text needed.
- **Phase D (2026-04-26)** — pure ROM+RAM+SD architecture. ROM keeps only the kernel; HEDIT/MENU/files-FS live on SD. Dict-init driven by ROM-encoded `LD #v; STO [a]` pairs (`populate_dict_init` post-pass in mcasm.py) because Gowin BSRAM init drops data. Auto-boot from SD sector 0:0 with magic header. RXBLK + HELP added to ROM. `U>` added (was missing — caused silent NAME=? breakage in files-FS). Defensive dict-walk guard. WIPE in files-FS for blanking a registered file's data blocks. LOAD-syncs-thru_cur to prevent chain/THRU re-execution.
- **Phase D evening (2026-04-26)** — files-FS hardening. REGISTER gained CNT>0, boot-block protection, name-dup, and range-overlap checks. New `RESIZE` word for changing file size with overlap check (skip-self). `?FILE NAME` pushes (HI LO CNT); `?HEDIT NAME` jumps the editor straight to the file. `compile_quoted_string` length-byte address parked on the data stack to survive `rch`-triggered THRU advances (was trashed by SD-side scratch).
- **2026-04-26 night** — Tier 1 helpers: `?FREE`/`COPY`/`STATS`. HEDIT ESC y/n confirm. ROM 6563 → 6618.
- **2026-04-27 marathon** — robustness + ergonomics:
  - **Files-FS layout** moved: dir at SD sector 1:0; sectors 0:0..0:255 reserved for direct (non-FS) use. `?FREE` searches from 1:1.
  - **`ENDTHRU`** Forth-word added to blocks_core.fth — bootblock can specify a generously oversized THRU range, source ends with `ENDTHRU` to stop cleanly. `sd_install.py` auto-detects block count.
  - **Boot progress markers** (`46 EMIT` between major sections) — visible boot progress.
  - **Quiet-source-prompt ROM patch** — `main` no longer prints `ok\r\n> ` while source mode active (THRU active OR src has bytes). Patch checks `thru_act` to handle the offset-255 newline edge case where `src` momentarily equals `src_end` between blocks.
  - **`nfail` improved** — prints `<word> ?\r\n` plus aborts source on error (sets `thru_act=0`, `src=src_end`, `state=0`). Cascade-error storm gone, errors localizable.
  - **`OR` builtin alias** for `|` — ANS-Forth-conformance fix. blocks_core.fth uses `OR` (was failing silently in REGISTER's validation logic before nfail-with-name made it visible).
  - **`upload_blocks.py --verify`** — read-back-and-retry per block. Plus the wait_for marker fix (`b'ok\r'` not `b'ok'`) so substrings like `"ok"` in source comments don't trip false-positive prompts.
  - **`sd_install.py` auto-detect** block count from `--source` (default blocks_core.fth).
  - ROM 6618 → 6677 words.
- **2026-04-27 evening (Tier-S quick wins)** — error-UX consistency + cascade containment:
  - **`tick_fail` → `JMP nfail`** — `'` (tick) on lookup miss now prints `<word> ?\r\n` + aborts source, matching nfail. Saves 5 ROM words too.
  - **`compile_byte` / `write_dict_byte` OOM aborts source** — both call shared `oom_abort_src` (state=0, thru_act=0, src=src_end, eol=1). Bounds the legacy endless-`!` cascade to ≤3 `!` per dispatch step, then a clean prompt. Removes the secondary-corruption risk where an OOM cascade could later trigger an UPDATE+FLUSH on garbage.
  - **`do_colon` orders state=1 before create** — so a `wdb_oom` inside `create` leaves the system in interpret mode. Otherwise the trailing `state=1` would re-enter compile mode at the post-abort prompt.
  - **`HEX` / `DECIMAL` / `BASE`** — `base` slot at RAM[0x1C], default 10.  Number parser is base-aware (accepts A-F in hex), `.` dispatches to a hex print path that emits 2 zero-padded nibbles + space.  Required dropping the first-char digit gate in `interp` (everything tries `try_num` now; it bails to `try_user` on miss) so words starting with A-F can also be hex literals.  `try_neg` similarly simplified — `-X...` always tries `try_num_skip`, which falls through if X isn't a digit.
  - **mcasm cold-reset backup removed** — the old code at `make_ram_init` stamped here/latest/dict_ptr backups into 0x1A-0x1F.  Late-bind constants superseded that path long ago, but the dead writes were silently clobbering anything new placed in 0x1C-0x1F.  `base` lives at 0x1C now and survived once the backup writes were removed.
  - **`CHAR` / `[CHAR]`** — `CHAR` parses next word and pushes its first char; `[CHAR]` (immediate) compiles `do_lit + char`. To free a slot in the < 0x100 trampoline pool, `do_2swap`'s 17-instruction inline body was moved above 0x100 as a `swap2_body` trampoline.
  - **`+LOOP` cross detection rewritten** — replaces the legacy sign-XOR test (which fired at `limit + 128` instead of at `limit`) with `(limit-1-old) < step` for step≥0 and `(old-limit) < |step|` for step<0. Countdown loops with limit=0 now correctly iterate to 0 instead of bailing at 128.
  - **`FORGET <name>`** — walk LATEST chain, match name, refuse if handler_hi < 0x10 (kernel-protected), else set HERE = handler_addr, DICT_PTR = entry_addr, LATEST = entry's link field. Failure paths (no name / not found / protected) all route through `nfail`.
  - **`ABORT` / `ABORT"`** — `ABORT` clears data + IP-return stacks, drops compile mode, kills source mode, returns to interp (silent).  `ABORT"` is immediate, compiles a `do_abrtstr` runtime token + length-prefixed string; the runtime pops a flag and either prints the message + tail-calls `abort_body` or skips the inline string and continues.
  - **Number-parser overflow detection** — JC-after-SHL/ADD checks in `ndig` / `ndig_x16` and digit-add. Overflow bails to `try_user` (not `nfail` directly) — that way a multi-char word like `DECIMAL` whose leading letters parse as hex digits still gets a dict lookup; only when try_user *also* fails do we land in `nfail` with `<word> ?`. First attempt 2026-04-27 was reverted because `blocks_core.fth` used `1000 0 DO ...` and `256 0 DO ...` as "many iterations via mod-256 wrap" idioms. **Source updated 2026-04-28** to use the explicit `0 0 DO ... LOOP` form (256 iterations via LOOP wrap-around) — same iteration count, no overflow. Re-applied with that fix in place.
  - ROM 6677 → 7030 words (+353 net, includes HEX/DECIMAL/CHAR/[CHAR]/+LOOP-fix/FORGET/ABORT/ABORT"/parse-overflow).

`doc/SD_ONLY_ROADMAP.md` is now historical — every phase is shipped.
