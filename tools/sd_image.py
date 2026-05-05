#!/usr/bin/env python3
"""
sd_image.py — Pack a Forth source file into an SD card image (Phase D).

ROM only carries the Forth kernel + builtins + dict-init.  Higher-level
vocabulary (HEDIT, MENU, files-FS) lives on the SD card as Forth source
in 256-byte blocks; the user loads it on demand from the prompt.

This tool takes a `.fth` file (e.g. asm/demo/blocks_core.fth), strips the
old block markers and inter-block `LOAD` chains (no longer relevant — the
output is one contiguous source stream packed into consecutive blocks),
and emits a binary image you can write to the SD card with `dd seek=<N>`.

Each output block is one full SD sector (512 bytes): the lower 256 bytes
hold the source slice, the upper 256 bytes are 0xFF filler — same layout
as `sd_read_body` / `sd_write_body` in forth.asm.

Workflow:
    python3 tools/sd_image.py asm/demo/blocks_core.fth -o blocks.bin
    sudo dd if=blocks.bin of=/dev/sdX bs=512 seek=100 conv=notrunc

Then on the FPGA prompt:
    SD-INIT .            ( prints 0 = ready )
    0 100 0 110 THRU     ( load blocks 100..110 from SD )
    MENU                 ( banner appears )
"""
import argparse
import re
from pathlib import Path

BLOCK_MARKER_RE = re.compile(r"^\s*\(\s*---\s*block\s+\d+\s*---\s*\)\s*$")
LOAD_CHAIN_RE   = re.compile(r"^\s*0\s+\d+\s+LOAD\s*$")


def strip_boot_chain(src: str) -> str:
    out = []
    for line in src.splitlines():
        if BLOCK_MARKER_RE.match(line):
            continue
        if LOAD_CHAIN_RE.match(line):
            continue
        out.append(line)
    cleaned, blank = [], False
    for line in out:
        if line.strip() == "":
            if blank:
                continue
            blank = True
        else:
            blank = False
        cleaned.append(line)
    return "\n".join(cleaned).strip() + "\n"


def main():
    ap = argparse.ArgumentParser(
        description=__doc__.strip().split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("source", help=".fth source file")
    ap.add_argument("-o", "--output", default="blocks.bin",
                    help="binary image (default: blocks.bin)")
    ap.add_argument("--block-size", type=int, default=256,
                    help="bytes per Forth block (default 256)")
    ap.add_argument("--sector-size", type=int, default=512,
                    help="SD sector size (default 512)")
    args = ap.parse_args()

    src = Path(args.source).read_text()
    cleaned = strip_boot_chain(src)
    data = cleaned.encode("ascii", errors="strict")

    image = bytearray()
    n_blocks = 0
    for i in range(0, len(data), args.block_size):
        chunk = data[i:i + args.block_size]
        chunk = chunk.ljust(args.block_size, b"\x00")          # NUL-pad short tail
        sector = chunk + b"\xFF" * (args.sector_size - args.block_size)
        image += sector
        n_blocks += 1

    Path(args.output).write_bytes(image)
    print(f"Wrote {len(image)} bytes to {args.output}")
    print(f"  {n_blocks} Forth blocks ({len(data)} src bytes, "
          f"{n_blocks * args.block_size} packed)")
    print()
    print(f"Write to SD card (replace /dev/sdX with your device, "
          f"and 100 with whatever start sector you want):")
    print(f"  sudo dd if={args.output} of=/dev/sdX bs={args.sector_size} "
          f"seek=100 conv=notrunc")
    print()
    print(f"On the FPGA prompt after flashing:")
    print(f"  SD-INIT .                    ( prints 0 = ready )")
    print(f"  0 100 0 {100 + n_blocks - 1} THRU   ( compile blocks )")
    print(f"  MENU                         ( banner )")


if __name__ == "__main__":
    main()
