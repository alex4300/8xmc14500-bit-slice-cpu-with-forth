#!/usr/bin/env python3
"""
build_boot_text.py — Embed blocks_core.fth as RAM boot source for Phase B.

After Phase A the SD primitives live in ROM (no sd.fth needed at boot). After
Phase B the boot chain itself doesn't depend on BSRAM either: the source text
of blocks_core.fth is dropped into RAM at BOOT_TEXT_BASE via $readmemh, and
forth.asm `init` points the source pointer there. The runtime Forth compiler
processes it on first cold boot, populating the dict at 0x0400+ and bodies at
0x1000+ exactly as the BSRAM-driven boot did before.

Strips:
  - `( --- block N --- )` markers
  - inter-block `0 N LOAD` chain statements (no longer relevant — we have one
    contiguous source, not a block chain)

Output (sparse hex, $readmemh-compatible):
  @addr value
  @addr value
  ...

The output ends with a NUL byte so the Forth interpreter's existing
end-of-source detection switches to UART once the boot text is consumed.
"""
import argparse
import re
from pathlib import Path

ROOT = Path(__file__).parent.parent
DEFAULT_SRC = ROOT / "asm/demo/blocks_core.fth"
DEFAULT_OUT = ROOT / "build/boot_text.hex"
DEFAULT_BASE = 0x6000
DEFAULT_LIMIT = 0x7800  # exclusive upper bound; ~6 KB for boot text


BLOCK_MARKER_RE = re.compile(r"^\s*\(\s*---\s*block\s+\d+\s*---\s*\)\s*$")
LOAD_CHAIN_RE = re.compile(r"^\s*0\s+\d+\s+LOAD\s*$")


def strip_boot_chain(src: str) -> str:
    """Remove block markers and inter-block LOAD chains. Keep everything else."""
    out = []
    for line in src.splitlines():
        if BLOCK_MARKER_RE.match(line):
            continue
        if LOAD_CHAIN_RE.match(line):
            continue
        out.append(line)
    # Collapse runs of blank lines so the boot text stays compact.
    cleaned = []
    blank = False
    for line in out:
        if line.strip() == "":
            if blank:
                continue
            blank = True
        else:
            blank = False
        cleaned.append(line)
    return "\n".join(cleaned).strip() + "\n"


def emit_hex(text: str, base: int, limit: int) -> str:
    data = text.encode("ascii", errors="strict") + b"\x00"
    if base + len(data) > limit:
        raise ValueError(
            f"boot text is {len(data)} bytes, exceeds budget "
            f"[{base:#06x}..{limit:#06x}) of {limit - base} bytes"
        )
    lines = [f"@{base + i:04X} {b:02X}" for i, b in enumerate(data)]
    return "\n".join(lines) + "\n"


def emit_rom_hex(text: str, capacity: int) -> str:
    """Hex file for the dedicated boot_text BRAM (addresses start at 0)."""
    data = text.encode("ascii", errors="strict") + b"\x00"
    if len(data) > capacity:
        raise ValueError(
            f"boot text is {len(data)} bytes, exceeds boot_text BRAM "
            f"capacity {capacity}"
        )
    lines = [f"@{i:04X} {b:02X}" for i, b in enumerate(data)]
    return "\n".join(lines) + "\n"


def emit_vh(text: str, base: int) -> str:
    """Inline `ram[N] = 8'hVV;` lines for FPGA synthesis."""
    data = text.encode("ascii", errors="strict") + b"\x00"
    return "".join(
        f"    ram[{base + i:5d}] = 8'h{b:02X};\n" for i, b in enumerate(data)
    )


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("source", nargs="?", default=str(DEFAULT_SRC),
                    help="Forth source file (default: blocks_core.fth)")
    ap.add_argument("-o", "--output", default=str(DEFAULT_OUT),
                    help="Sparse hex output file")
    ap.add_argument("--base", type=lambda s: int(s, 0), default=DEFAULT_BASE,
                    help="RAM base address (default 0x6000)")
    ap.add_argument("--limit", type=lambda s: int(s, 0), default=DEFAULT_LIMIT,
                    help="Exclusive upper bound (default 0x7400)")
    args = ap.parse_args()

    src = Path(args.source).read_text()
    cleaned = strip_boot_chain(src)
    hex_text = emit_hex(cleaned, args.base, args.limit)
    vh_text = emit_vh(cleaned, args.base)
    rom_hex_text = emit_rom_hex(cleaned, capacity=6144)

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(hex_text)
    vh_path = out_path.with_suffix(".vh")
    vh_path.write_text(vh_text)
    rom_hex_path = out_path.parent / "boot_text_rom.hex"
    rom_hex_path.write_text(rom_hex_text)

    nbytes = len(cleaned.encode()) + 1  # + NUL
    print(f"Boot text: {nbytes} bytes at "
          f"{args.base:#06x}..{args.base + nbytes - 1:#06x}")
    print(f"  hex → {out_path}")
    print(f"  vh  → {vh_path}")
    print(f"  rom → {rom_hex_path} (offset 0, for boot_text BRAM)")


if __name__ == "__main__":
    main()
