#!/usr/bin/env python3
"""
blockc.py — Forth Block Compiler

Converts a Forth source file with block markers into a storage.hex file
suitable for $readmemh by the simulator's storage peripheral.

Usage:
    python3 blockc.py source.fth -o storage.hex

Source format:
    ( --- block N --- )
    <forth code>
    ( --- block M --- )
    <more code>

Each block is padded to 256 bytes (BLOCK_SIZE). Bytes are NUL-terminated:
the first 0x00 byte in a block tells the interpreter "end of source —
switch to UART input". Comments using ( ... ) are kept verbatim (the
Forth interpreter handles them at runtime).

Output: hex file in $readmemh format, one byte per line, addresses are
sequential (block 0 occupies 0x0000-0x00FF, block 1 occupies 0x0100-0x01FF, ...).
"""

import argparse
import re
import sys
from pathlib import Path

BLOCK_SIZE = 256
TOTAL_BLOCKS = 256          # 64KB total storage
BLOCK_RE = re.compile(r'^\s*\(\s*---\s*block\s+(\d+)\s*---\s*\)\s*$', re.IGNORECASE)


def parse_blocks(source_text):
    """Parse source text into {block_num: text} dict."""
    blocks = {}
    current = 0
    current_lines = []

    for line in source_text.splitlines():
        m = BLOCK_RE.match(line)
        if m:
            # Flush previous block
            if current_lines:
                blocks[current] = '\n'.join(current_lines) + '\n'
            current = int(m.group(1))
            current_lines = []
        else:
            current_lines.append(line)

    if current_lines:
        blocks[current] = '\n'.join(current_lines) + '\n'

    return blocks


def encode_blocks(blocks):
    """Build a flat 64KB byte array from block dict."""
    storage = bytearray(BLOCK_SIZE * TOTAL_BLOCKS)

    for blk_num, text in blocks.items():
        if blk_num >= TOTAL_BLOCKS:
            raise ValueError(f"Block {blk_num} exceeds storage capacity ({TOTAL_BLOCKS} blocks)")

        encoded = text.encode('ascii', errors='replace')
        if len(encoded) >= BLOCK_SIZE:
            raise ValueError(f"Block {blk_num} too large: {len(encoded)} bytes (max {BLOCK_SIZE - 1})")

        offset = blk_num * BLOCK_SIZE
        # Copy bytes; remaining stays 0x00 (interpreter sentinel)
        storage[offset:offset + len(encoded)] = encoded

    return storage


def emit_hex(storage):
    """Emit $readmemh-compatible hex output (one byte per line)."""
    return '\n'.join(f'{b:02X}' for b in storage) + '\n'


def emit_verilog_init(storage, max_bytes, array_name='stg_ram'):
    """Emit inline Verilog init — skips zero bytes, clamps to max_bytes."""
    lines = []
    for i, b in enumerate(storage[:max_bytes]):
        if b != 0:
            lines.append(f"    {array_name}[{i:5d}] = 8'h{b:02X};")
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description='Forth Block Compiler')
    parser.add_argument('source', type=Path, help='Forth source with ( --- block N --- ) markers')
    parser.add_argument('-o', '--output', type=Path, required=True, help='Output hex file')
    parser.add_argument('-v', '--verbose', action='store_true', help='Print block summary')
    parser.add_argument('--verilog-init', type=Path, default=None,
                        help='Also emit inline Verilog rom init for FPGA synthesis')
    parser.add_argument('--fpga-blocks', type=int, default=8,
                        help='Blocks to include in verilog init (default: 8)')
    args = parser.parse_args()

    source_text = args.source.read_text(encoding='utf-8')
    blocks = parse_blocks(source_text)

    if args.verbose:
        for blk_num in sorted(blocks):
            size = len(blocks[blk_num].encode('ascii', errors='replace'))
            print(f"  Block {blk_num}: {size} bytes")

    storage = encode_blocks(blocks)
    args.output.write_text(emit_hex(storage))
    print(f"Compiled {len(blocks)} block(s) → {args.output} ({len(storage)} bytes)")

    if args.verilog_init:
        max_bytes = args.fpga_blocks * BLOCK_SIZE
        args.verilog_init.write_text(emit_verilog_init(storage, max_bytes))
        print(f"  Verilog storage init ({args.fpga_blocks} blocks) → {args.verilog_init}")


if __name__ == '__main__':
    main()
