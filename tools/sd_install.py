#!/usr/bin/env python3
"""
sd_install.py — Build the SD boot block (sector 0) so the FPGA auto-loads
blocks_core.fth (or any other Forth source) on every reset.

Layout of the boot block (256 bytes — the lower half of the 512-byte SD
sector; the upper half is filled with 0xFF by sd_write_body automatically):

    \\ 8xMC14500\\r\\n              ← magic, the leading "\\ " makes the rest
                                       a Forth line comment so it's harmless
                                       to interp regardless of what follows.
    HI LO HI2 LO2 THRU MENU\\r\\n   ← whatever Forth commands you want run
    \\0\\0...\\0                     ← NUL-padded; interp's NUL sentinel
                                       drops back to UART prompt once the
                                       payload is consumed.

ROM init reads sector 0:0, checks BLOCK_BUF[0..10] against "\\ 8xMC14500"
byte-for-byte, and only sources the block on a match.  Invalid magic / SD
missing / read failure → silent fallback to UART prompt.

Usage:

    # Default: 256-byte block ready for UART upload (no SD reader needed)
    python3 tools/sd_install.py
    python3 tools/upload_blocks.py /dev/ttyUSB0 bootblock.bin --start 0 --raw

    # Then upload the source itself once (UART, after the FPGA prompt is up)
    python3 tools/upload_blocks.py /dev/ttyUSB0 asm/demo/blocks_core.fth \\
        --start 100 --strip

    # If you have an SD reader, --sector emits the full 512-byte sector
    # so you can `dd` it directly:
    python3 tools/sd_install.py --sector
    sudo dd if=bootblock.bin of=/dev/sdX bs=512 conv=notrunc

    # Override target range and post-load command:
    python3 tools/sd_install.py --start 1000 --count 21 --after MENU
"""
import argparse
from pathlib import Path

MAGIC       = b"\\ 8xMC14500\r\n"
BLOCK_SIZE  = 256
SECTOR_SIZE = 512


def build_block(start: int, count: int, after: str) -> bytes:
    s_hi, s_lo = start >> 8, start & 0xFF
    e = start + count - 1
    e_hi, e_lo = e >> 8, e & 0xFF
    cmd = f"{s_hi} {s_lo} {e_hi} {e_lo} THRU {after}\r\n".encode("ascii")
    payload = MAGIC + cmd
    if len(payload) > BLOCK_SIZE:
        raise ValueError(
            f"boot payload is {len(payload)} bytes, exceeds block size "
            f"{BLOCK_SIZE}"
        )
    return payload + b"\x00" * (BLOCK_SIZE - len(payload))


def main():
    ap = argparse.ArgumentParser(
        description=__doc__.strip().split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("--start", type=int, default=100,
                    help="First sector of the boot source (default 100)")
    ap.add_argument("--count", type=int, default=None,
                    help="Number of source blocks (default: auto-detect "
                         "from --source, or 50 if no --source given)")
    ap.add_argument("--source", default="asm/demo/blocks_core.fth",
                    help="Source file to size against (default "
                         "asm/demo/blocks_core.fth). After --strip the "
                         "block count is computed; --count overrides.")
    ap.add_argument("--after", default="MENU",
                    help="Word(s) to run after THRU completes (default MENU)")
    ap.add_argument("-o", "--output", default="bootblock.bin",
                    help="Output file (default bootblock.bin)")
    ap.add_argument("--sector", action="store_true",
                    help="Emit a full 512-byte SD sector (lower 256 = block, "
                         "upper 256 = 0xFF) for `dd`. Default is the 256-byte "
                         "Forth block, ready for upload_blocks.py --raw.")
    args = ap.parse_args()

    if args.count is None:
        src_path = Path(args.source)
        if src_path.exists():
            import re as _re
            raw = src_path.read_text()
            kept = []
            for line in raw.split("\n"):
                s = line.strip()
                if s.startswith("( --- block ") or _re.match(r"^[0-9]+ [0-9]+ LOAD\s*$", s):
                    continue
                kept.append(line)
            data = ("\n".join(kept).rstrip() + "\n").encode("ascii")
            args.count = (len(data) + BLOCK_SIZE - 1) // BLOCK_SIZE
            print(f"Auto-detected {args.count} blocks from {src_path}")
        else:
            args.count = 50
            print(f"--source {args.source} not found; using --count 50")

    block = build_block(args.start, args.count, args.after)
    if args.sector:
        out = block + b"\xFF" * (SECTOR_SIZE - BLOCK_SIZE)
    else:
        out = block

    Path(args.output).write_bytes(out)

    s_hi, s_lo = args.start >> 8, args.start & 0xFF
    e = args.start + args.count - 1
    e_hi, e_lo = e >> 8, e & 0xFF
    src_bytes = block.rstrip(b"\x00")
    print(f"Wrote {len(out)} bytes to {args.output}")
    print(f"  Auto-load: blocks {s_hi}:{s_lo}..{e_hi}:{e_lo} THRU {args.after}")
    print(f"  Boot block source ({len(src_bytes)} bytes):")
    for line in src_bytes.decode("ascii").splitlines():
        print(f"      {line}")
    print()
    if args.sector:
        print(f"Write to SD card sector 0 (raw):")
        print(f"  sudo dd if={args.output} of=/dev/sdX bs=512 conv=notrunc")
    else:
        print(f"Upload via UART (no SD reader needed):")
        print(f"  python3 tools/upload_blocks.py /dev/ttyUSB0 "
              f"{args.output} --start 0 --raw")


if __name__ == "__main__":
    main()
