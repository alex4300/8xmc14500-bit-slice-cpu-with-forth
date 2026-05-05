# Roadmap: BSRAM-free / SD-only architecture — **SHIPPED 2026-04-26**

This file was the working plan for eliminating the BSRAM emulator and moving the entire boot path to ROM + SD. **All phases are now in.** See CLAUDE.md for the post-merge architecture; this document is kept as historical context.

## Final shape

- **ROM** — Forth kernel + ALU primitives + dict + compile bodies + SD-over-SPI primitives + auto-boot loader. 6563 / 8192 microwords.
- **cpu.ram** — runtime RAM. Pre-populated dictionary (60 builtins + 51 forthwords) is driven into RAM at every boot by ROM-encoded `LD #v; STO [a]` pairs (the `dict_init` post-pass in `asm/mcasm.py`).
- **SD card over SPI** — only persistent block storage. SD sector 0:0 holds the auto-boot magic `\ 8xMC14500` followed by whatever Forth commands the user wants to run at startup; the rest of the card is plain Forth source.
- **No BSRAM emulator.** `rtl/mc14500_top.v` no longer has `stg_ram`; the storage MMIO at 0x7FF8/9/A is read-zero / write-ignored stubs kept for ABI stability.

## Phase log

### Phase A — SD primitives in asm ✅ (2026-04-25)

`spi_xfer`, `spi_skip`, `sd_on/off`, `sd_warmup`, `wait_r1`, `sd_cmd0/8/55/acmd41`, `sd_init_body`, `sd_read_body`, `sd_write_body`, `sd_read_r_body`, `sd_write_r_body` ported into `asm/forth.asm` (~270 ROM words).

`block_dispatch` and `save_buffers_body` call them directly; the previous `SDHOOK` XT-registration mechanism in `sd.fth` is gone.

### Phase B — Boot text out of BSRAM ✅ (2026-04-25, then revised in Phase D)

First take: dedicated `boot_text` BRAM mapped at 0x6000-0x77FF holding `blocks_core.fth` source. Worked in sim, but Gowin/yosys silently dropped BRAM init data on the actual FPGA, so the dict / boot text never landed in RAM.

Phase D superseded this with ROM-driven `dict_init` (no reliance on BRAM init) and SD-resident higher-level vocabulary (no boot_text BRAM needed at all).

### Phase C — Eliminate BSRAM ✅ (2026-04-25)

`stg_ram[16384]` removed from `rtl/mc14500_top.v`. Storage MMIO degraded to wire stubs. `Makefile` no longer depends on `storage_init.vh` / `storage.hex` for the bitstream. `block_dispatch` simplified to always-SD. `load_block_to_buf` deleted.

Side-benefit: 8 BSRAM blocks freed, fits the boot_text experiments and later the dict_init growth.

### Phase D — Pure ROM+RAM+SD ✅ (2026-04-26)

- `boot_text` BRAM removed; `forth.asm init` no longer points `src` at any RAM region pre-loaded with source. Higher-level vocabulary lives on the SD card and is loaded on demand.
- `mcasm.py` post-pass `populate_dict_init` walks the sparse `ram_data` map and emits `LD #v; STO [addr]` pairs (plus a final `RET`) at the `dict_init` label. `forth.asm init` calls `dict_init` first thing, guaranteeing the dict is in RAM regardless of BRAM init quirks.
- `try_autoboot` reads SD sector 0:0, validates magic `\ 8xMC14500` byte-for-byte against BLOCK_BUF[0..10], and on match makes the sector the initial Forth source. SD missing / read fail / magic mismatch → silent UART prompt fallback.
- Tools: `tools/sd_install.py` builds the boot block; `tools/upload_blocks.py --strip` packs a stripped source for direct THRU; `tools/upload_blocks.py` (default chain mode) preserves chain LOADs for `RUN <NAME>` style files.
- ROM additions: `RXBLK` (UART → block, in ROM so upload tooling has zero pre-requisites), `HELP` (built-in command reference), `U>` (was missing — caused silent NAME=? breakage in files-FS).
- Files-FS gains `WIPE <name>` for blanking a registered file's data blocks without removing the directory entry.
- Robustness: dict-walk in `fu_next` aborts to `?` if `link_hi < 0x04` (catches corrupted RAM dict before it loops); `LOAD` syncs `thru_cur` so chain-LOADs inside THRU-ranged source don't trigger re-compile.

## Known follow-ons (not blockers)

- The `rch` / WORD path interactions with `eol` after PARSE-NAME have one funky case (RUN behavior with leading CR on the input line) — works but the UX would be cleaner if PARSE-NAME didn't propagate eol back to the outer interp loop. Worth a small refactor when ROM space pressure isn't an issue.
- Auto-boot is currently single-block (the magic block itself sources whatever it contains). A multi-block auto-boot would need either chain LOADs in the boot block or a length field. Not currently needed.
- File-system `REGISTER` doesn't track which sectors are free; collisions are user-managed (the directory just stores `(start, count)` per slot). A free-list could be added later if multi-file workflows get common.
