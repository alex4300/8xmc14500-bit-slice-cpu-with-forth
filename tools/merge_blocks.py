#!/usr/bin/env python3
"""
merge_blocks.py — Generate asm/demo/blocks.fth from blocks_core.fth + sd.fth.

The ROM now routes BLOCK/LOAD/FLUSH/THRU natively by block range (hi=0 AND
lo<64 → BSRAM; else → SD via SD-READ-R / SD-WRITE-R XTs that sd.fth registers
with SDHOOK at boot). sdblock.fth is obsolete.

Inputs:
  asm/demo/blocks_core.fth  — boot entry, HEDIT, MENU, RXBLK (hand-edited)
  asm/demo/sd.fth           — SD-over-SPI layer + SDHOOK

Output:
  asm/demo/blocks.fth       — integrated file ready for blockc.py
"""
import sys
from pathlib import Path

ROOT = Path(__file__).parent.parent
CORE = ROOT / "asm/demo/blocks_core.fth"
SD_FTH = ROOT / "asm/demo/sd.fth"
OUT = ROOT / "asm/demo/blocks.fth"

BLOCK_SIZE = 256

# sd.fth goes into BSRAM blocks 1-9 and 30-39. Blocks 10-29, 40, 41 are core.
SD_BLOCKS = list(range(1, 10)) + list(range(30, 40)) + list(range(42, 64))


def split_to_blocks(content, block_pool, chain_to_after_last):
    """Pack content into blocks, ending each with " 0 N LOAD\\n" chaining to the
    next pool entry (or `chain_to_after_last` for the last block).

    All chains emit the 2-cell form (hi=0) so they match the ROM's unified
    2-arg BLOCK/LOAD ABI.
    """
    lines = content.splitlines(keepends=True)
    groups = []
    current_lines = []
    current_size = 0
    # " 0 NNN LOAD\n" is up to 13 bytes — leave a bit of slack.
    chain_budget = 14

    for line in lines:
        if current_size + len(line) + chain_budget > BLOCK_SIZE:
            if current_lines:
                groups.append(current_lines)
                current_lines = []
                current_size = 0
        current_lines.append(line)
        current_size += len(line)
    if current_lines:
        groups.append(current_lines)

    if len(groups) > len(block_pool):
        raise ValueError(
            f"content needs {len(groups)} blocks, "
            f"pool has only {len(block_pool)} available")

    nums = block_pool[:len(groups)]
    remaining = block_pool[len(groups):]
    result = []
    for i, (num, lines_of_block) in enumerate(zip(nums, groups)):
        text = "".join(lines_of_block)
        target = nums[i + 1] if i < len(nums) - 1 else chain_to_after_last
        chain = f" 0 {target} LOAD\n"
        result.append((num, text + chain))
    return result, remaining


def render_block(num, text):
    return f"( --- block {num} --- )\n{text}"


def main():
    if not CORE.exists() or not SD_FTH.exists():
        print(f"ERROR: blocks_core.fth or sd.fth missing")
        return 1

    core_src = CORE.read_text()
    sd_src = SD_FTH.read_text()

    # sd.fth blocks chain to each other, last one chains to 27 (HEDIT pickup).
    try:
        sd_blocks, _ = split_to_blocks(sd_src, SD_BLOCKS, chain_to_after_last=27)
    except ValueError as e:
        print(f"ERROR: {e}")
        return 1
    sd_first = sd_blocks[0][0]
    sd_last = sd_blocks[-1][0]

    sections = [render_block(num, text) for num, text in sd_blocks]
    sections.append(core_src)

    OUT.write_text("\n".join(sections))
    sd_nums = [n for n, _ in sd_blocks]
    print(f"Wrote {OUT}")
    print(f"  sd.fth → blocks {sd_nums} ({len(sd_blocks)} blocks)")
    print(f"  core appended.")
    print(f"  Chain: block 21 → {sd_first}, sd.fth last block {sd_last} → 27")
    return 0


if __name__ == "__main__":
    sys.exit(main())
