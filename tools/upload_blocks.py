#!/usr/bin/env python3
"""
upload_blocks.py — Upload a file to MC14500x8 block storage via UART.

Phase D: only RXBLK is available in ROM, so we always send one RXBLK
command per block (one round-trip per block).  Slightly slower than the
old RXBLKS-batch path but works without pre-loading any vocabulary from
SD, which is the whole point of the Phase D bootstrap.

Usage:
    # Strip mode (recommended for blocks_core.fth and similar): drop
    # legacy `( --- block N --- )` markers + inter-block `0 N LOAD` chains,
    # then pack the cleaned source into 256-byte blocks.  Load on FPGA
    # afterwards with `SD-INIT . 0 <start> 0 <end> THRU`.
    python3 tools/upload_blocks.py /dev/ttyUSB0 asm/demo/blocks_core.fth --start 100 --strip

    # Default: split the file across blocks at newline boundaries and
    # auto-insert "N+1 LOAD" chains so a single "START LOAD" loads all.
    python3 tools/upload_blocks.py /dev/ttyUSB0 big.fth --start 50

    # Safe-split: like default, but refuses to split inside an open `:` ... `;`
    # definition (prevents chain-LOAD from being compiled into a def).
    python3 tools/upload_blocks.py /dev/ttyUSB0 big.fth --start 50 --safe-split

    # Raw mode: pad to 256-byte boundaries and upload bytes verbatim.
    # Use this for binary data or when you've embedded your own chain logic
    # (e.g. a single `N M THRU` at the start of block N).
    python3 tools/upload_blocks.py /dev/ttyUSB0 blocks.bin --start 0 --raw

The NUL byte is our parser's "end of source" sentinel, so chain commands
are always placed *before* any padding. Transfer rate on 27 MHz MC14500x8:
~500-1000 B/s (Forth-level KEY loop overhead). A 16 KB full-storage upload
takes ~20-30 seconds.
"""
import argparse
import re
import serial
import sys
import time
from pathlib import Path

BLOCK_SIZE = 256

BLOCK_MARKER_RE = re.compile(r"^\s*\(\s*---\s*block\s+\d+\s*---\s*\)\s*$")
LOAD_CHAIN_RE   = re.compile(r"^\s*0\s+\d+\s+LOAD\s*$")


def strip_boot_chain(src: bytes) -> bytes:
    """Drop legacy `( --- block N --- )` markers and inter-block `0 N LOAD`
    statements, collapsing runs of blank lines."""
    text = src.decode("ascii", errors="strict")
    out = []
    for line in text.splitlines():
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
    return ("\n".join(cleaned).strip() + "\n").encode("ascii")


def pad_to_block(data: bytes) -> bytes:
    pad_bytes = (BLOCK_SIZE - len(data) % BLOCK_SIZE) % BLOCK_SIZE
    return data + b'\x00' * pad_bytes


def find_safe_boundaries(data: bytes) -> list:
    """Return byte offsets (immediately after each \\n) where a split would
    not cut through an open ':' ... ';' definition.

    Respects Forth lexical structure: ( ... ) block comments, \\ ...\\n line
    comments, ." ..." and S" ..." strings. Tokens are whitespace-delimited.
    """
    boundaries = []
    in_def = False
    in_block_comment = False
    in_line_comment = False
    in_string = False
    WS = b' \t\r\n'

    i, n = 0, len(data)
    while i < n:
        c = data[i]

        if in_block_comment:
            if c == 0x29:  # )
                in_block_comment = False
            i += 1
            continue
        if in_line_comment:
            if c == 0x0A:  # \n
                in_line_comment = False
                if not in_def:
                    boundaries.append(i + 1)
            i += 1
            continue
        if in_string:
            if c == 0x22:  # "
                in_string = False
            i += 1
            continue

        if c == 0x0A:
            if not in_def:
                boundaries.append(i + 1)
            i += 1
            continue
        if c in WS:
            i += 1
            continue

        # Start of a whitespace-delimited token
        end = i
        while end < n and data[end] not in WS:
            end += 1
        token = data[i:end]

        if token == b'(':
            in_block_comment = True
        elif token == b'\\':
            in_line_comment = True
        elif token in (b'."', b'S"'):
            in_string = True
        elif token == b':':
            in_def = True
        elif token == b';':
            in_def = False
        i = end

    return boundaries


def build_chained_blocks(data: bytes, start_block: int,
                         safe_split: bool = False) -> bytes:
    """Split `data` into 256-byte blocks, inserting " HI LO LOAD\\n" at the
    end of each block but the last.

    The ROM BLOCK/LOAD API is 2-cell ( hi lo ) throughout, so chain links
    carry both bytes explicitly — a block number > 255 still chains cleanly.

    Default (safe_split=False): split at the latest `\\n` that fits in the
    available budget.  Fast and simple, but can land inside an open `:` ... `;`
    definition — the injected chain-LOAD then gets compiled into the definition
    instead of being executed.

    safe_split=True: only split at newlines where we're not inside a colon
    definition.  Requires every `:` ... `;` pair (plus surrounding blank lines
    and comments up to the next safe point) to fit within one block.
    """
    out = bytearray()
    block_num = start_block
    pos = 0
    safe_bounds = find_safe_boundaries(data) if safe_split else None

    while pos < len(data):
        remaining = data[pos:]

        if len(remaining) <= BLOCK_SIZE:
            out.extend(remaining)
            out.extend(b'\x00' * (BLOCK_SIZE - len(remaining)))
            return bytes(out)

        nxt = block_num + 1
        chain = f' {nxt >> 8} {nxt & 0xFF} LOAD\n'.encode('ascii')
        budget = BLOCK_SIZE - len(chain)

        if safe_split:
            candidates = [b for b in safe_bounds if pos < b <= pos + budget]
            if not candidates:
                future = [b for b in safe_bounds if b > pos]
                next_safe = future[0] if future else len(data)
                span = data[pos:next_safe].decode('ascii', errors='replace')
                first_line = span.split('\n', 1)[0][:60]
                raise ValueError(
                    f"Block {block_num} at file offset {pos}: chunk starting "
                    f"'{first_line}...' spans {next_safe - pos} bytes to the "
                    f"next `;`, exceeds block budget of {budget}. "
                    f"Break the definition up, or drop --safe-split."
                )
            split = candidates[-1]
        else:
            nl = remaining[:budget].rfind(b'\n')
            if nl == -1:
                raise ValueError(
                    f"Block {block_num} at file offset {pos}: no newline in "
                    f"first {budget} bytes. Break up long lines or use --raw."
                )
            split = pos + nl + 1

        block_content = data[pos:split] + chain
        out.extend(block_content)
        out.extend(b'\x00' * (BLOCK_SIZE - len(block_content)))

        pos = split
        block_num += 1

    return bytes(out)


def wait_for(ser: serial.Serial, needle: bytes, timeout: float = 10.0,
             progress: bool = False, seed: bytes = b'') -> bytes:
    """Read from serial until `needle` appears or timeout. Return accumulated bytes.

    `seed` pre-seeds the buffer with bytes already collected elsewhere (e.g. from
    echo-based flow control during the send phase).

    When `progress` is set, prints a dot every ~256 newly received echo bytes and
    a tick every 5s so a slow SD FLUSH stays visibly alive.
    """
    deadline = time.time() + timeout
    buf = bytearray(seed)
    if needle in buf:
        return bytes(buf)
    last_dot = len(buf)
    last_tick = time.time()
    while time.time() < deadline:
        n = ser.in_waiting
        if n:
            buf.extend(ser.read(n))
            if needle in buf:
                if progress:
                    print()
                return bytes(buf)
            if progress and len(buf) - last_dot >= 256:
                sys.stdout.write('.'); sys.stdout.flush()
                last_dot = len(buf)
        else:
            time.sleep(0.02)
            if progress and time.time() - last_tick > 5.0:
                sys.stdout.write('t'); sys.stdout.flush()
                last_tick = time.time()
    if progress:
        print()
    return bytes(buf)


def send_one_block(ser: serial.Serial, block_num: int, data: bytes,
                   verbose: bool = False) -> None:
    """Send one 256-byte block via a single RXBLK invocation.

    Echo-based flow control: RXBLK echoes every non-LF byte. We bound the
    in-flight count below the FPGA's RX FIFO depth so it never has to drop
    or wait.
    """
    hi = block_num >> 8
    lo = block_num & 0xFF
    cmd = f'{hi} {lo} RXBLK\r'.encode()
    if verbose:
        print(f"  block {block_num}: {cmd!r}")
    ser.write(cmd)
    ser.flush()
    time.sleep(0.15)
    ser.reset_input_buffer()

    IN_FLIGHT_MAX = 20
    sent = 0
    lf_sent = 0
    echo_buf = bytearray()

    while sent < len(data):
        n = ser.in_waiting
        if n:
            echo_buf.extend(ser.read(n))

        consumed = len(echo_buf) + lf_sent
        in_flight = sent - consumed
        headroom = IN_FLIGHT_MAX - in_flight
        if headroom <= 0:
            time.sleep(0.002)
            continue

        chunk = data[sent:sent + headroom]
        ser.write(chunk)
        ser.flush()
        lf_sent += chunk.count(b'\n')
        sent += len(chunk)

    pre_tail = bytes(echo_buf)
    tail = wait_for(ser, b'ok\r', timeout=10.0, progress=False, seed=pre_tail)
    if b'ok' not in tail:
        print(f"WARNING: block {block_num}: no 'ok' received. "
              f"Last bytes: {tail[-80:]}", file=sys.stderr)


_vblk_defined = False


def verify_block(ser: serial.Serial, block_num: int, expected: bytes) -> int:
    """Verify a block by reading BLOCK_BUF (which RXBLK just populated)
    back through UART. We skip a fresh `BLOCK` call because it would
    re-read from SD, possibly returning stale/cached data while the
    write is still committing — and BLOCK_BUF already holds exactly
    the bytes RXBLK wrote, so reading it tells us if the UART
    transfer was clean.

    DO/LOOP only works inside a colon-def, so we define a one-shot
    helper word VBLK on the first call. NB: `256` parses to 0 in the
    8-bit number parser; `0 0 DO ... LOOP` happens to iterate 256
    times because the index wraps from 255 to 0 == limit. Fragile but
    works today.
    """
    global _vblk_defined
    if not _vblk_defined:
        ser.reset_input_buffer()
        ser.write(b": VBLK 0 0 DO 2 I C@ . LOOP ;\r")
        ser.flush()
        _ = wait_for(ser, b'ok\r', timeout=5.0)
        _vblk_defined = True

    snippet = b"VBLK\r"
    ser.reset_input_buffer()
    ser.write(snippet)
    ser.flush()
    tail = wait_for(ser, b'ok\r', timeout=20.0, progress=False)
    text = tail.decode('ascii', errors='replace')
    # `.` prints SIGNED 8-bit (so 200 → -56). Convert back to unsigned.
    nums = []
    for tok in text.split():
        try:
            n = int(tok)
            if -128 <= n <= 255:
                nums.append(n & 0xFF)
        except ValueError:
            pass
    # Echo includes hi, lo (e.g., "0 0 BLOCK VBLK"). Last 256 numbers are
    # the BLOCK_BUF contents.
    if len(nums) < 256:
        # Debug dump for parse-error diagnosis. Save raw output for inspection.
        try:
            with open('/tmp/upload_verify_fail.log', 'a') as f:
                f.write(f"\n=== block {block_num} parse-error: got {len(nums)} nums, "
                        f"raw output {len(tail)} bytes ===\n")
                f.write(repr(tail))
                f.write("\n")
        except Exception:
            pass
        return -1
    got = bytes(nums[-256:])
    return sum(1 for a, b in zip(got, expected) if a != b)


def upload(port: str, file_path: str, start_block: int,
           baud: int = 115200, verbose: bool = False,
           raw: bool = False, safe_split: bool = False,
           strip: bool = False, verify: bool = False) -> None:
    raw_data = Path(file_path).read_bytes()
    if strip:
        raw_data = strip_boot_chain(raw_data)
        data = pad_to_block(raw_data)
        mode = "stripped"
    elif raw:
        data = pad_to_block(raw_data)
        mode = "raw"
    else:
        try:
            data = build_chained_blocks(raw_data, start_block, safe_split)
        except ValueError as e:
            print(f"ERROR: {e}", file=sys.stderr)
            print("(Tip: use --raw or --strip to skip chain insertion)",
                  file=sys.stderr)
            sys.exit(1)
        mode = "chained"
    num_blocks = len(data) // BLOCK_SIZE

    print(f"Uploading {file_path} "
          f"({len(data)} bytes = {num_blocks} block(s), {mode}) "
          f"to block {start_block}..{start_block + num_blocks - 1}")

    ser = serial.Serial(port, baud, timeout=1, xonxoff=False, rtscts=False)
    time.sleep(0.2)
    ser.reset_input_buffer()

    # Nudge the REPL with a CR so we know it's alive
    ser.write(b'\r')
    ser.flush()
    _ = wait_for(ser, b'> ', timeout=2.0)

    t0 = time.time()
    failed_blocks = []
    for i in range(num_blocks):
        block_num = start_block + i
        chunk = data[i * BLOCK_SIZE : (i + 1) * BLOCK_SIZE]
        ok = False
        for attempt in range(3):
            send_one_block(ser, block_num, chunk, verbose=verbose)
            if not verify:
                ok = True
                break
            mismatches = verify_block(ser, block_num, chunk)
            if mismatches == 0:
                ok = True
                break
            print(f"\n  block {block_num}: verify FAILED "
                  f"({mismatches if mismatches >= 0 else 'parse-error'} "
                  f"bytes mismatched), retry {attempt + 1}/3",
                  file=sys.stderr)
        if not ok:
            print(f"\n  block {block_num}: gave up after 3 attempts",
                  file=sys.stderr)
            failed_blocks.append(block_num)
        if not verbose:
            sys.stdout.write('.' if not verify else ('v' if ok else 'F'))
            sys.stdout.flush()
    if not verbose:
        print()
    if failed_blocks:
        print(f"\n*** {len(failed_blocks)} block(s) FAILED verify: "
              f"{failed_blocks} ***", file=sys.stderr)
    elapsed = time.time() - t0
    rate = len(data) / elapsed if elapsed > 0 else 0
    print(f"Sent {len(data)} bytes in {elapsed:.1f}s ({rate:.0f} B/s)")
    print("Upload complete.")

    if mode == "stripped":
        last = start_block + num_blocks - 1
        s_hi, s_lo = start_block >> 8, start_block & 0xFF
        e_hi, e_lo = last        >> 8, last        & 0xFF
        print()
        print(f"On the FPGA prompt (manual one-shot):")
        print(f"  SD-INIT . {s_hi} {s_lo} {e_hi} {e_lo} THRU MENU")
        print()
        print(f"For autoboot, regenerate the boot block to match this range:")
        print(f"  python3 tools/sd_install.py --start {start_block} "
              f"--count {num_blocks}")
        print(f"  python3 tools/upload_blocks.py {port} bootblock.bin "
              f"--start 0 --raw")

    ser.close()


def main() -> int:
    p = argparse.ArgumentParser(
        description="Upload a file to MC14500x8 block storage via UART")
    p.add_argument('port', help='Serial device (e.g. /dev/ttyUSB0)')
    p.add_argument('file', help='File to upload (padded to 256-byte blocks)')
    p.add_argument('--start', type=int, default=0,
                   help='Starting block number (default: 0)')
    p.add_argument('--baud', type=int, default=115200,
                   help='Baud rate (default: 115200)')
    p.add_argument('--raw', action='store_true',
                   help='Skip chain insertion; upload file bytes verbatim '
                        '(useful for binary data or hand-chained sources)')
    p.add_argument('--safe-split', action='store_true',
                   help="Only split blocks at newlines outside of `:` ... `;` "
                        "definitions. Prevents the injected chain-LOAD from "
                        "landing inside a definition. Errors out if any single "
                        "definition exceeds one block.")
    p.add_argument('--strip', action='store_true',
                   help="Strip legacy `( --- block N --- )` markers and old "
                        "inter-block `0 N LOAD` chains before packing into "
                        "256-byte blocks.  Use this when the source already "
                        "has block boundaries that should be discarded — "
                        "e.g. asm/demo/blocks_core.fth.  Load on FPGA via "
                        "`SD-INIT . 0 <start> 0 <end> THRU`.")
    p.add_argument('--verbose', '-v', action='store_true')
    p.add_argument('--verify', action='store_true',
                   help="Read each block back after upload and retry up to "
                        "3× on mismatch. Slower (≈2× the upload time) but "
                        "catches silent SD-cache or UART-FIFO drops.")
    args = p.parse_args()
    upload(args.port, args.file, args.start, args.baud,
           args.verbose, args.raw, args.safe_split, args.strip,
           args.verify)
    return 0


if __name__ == '__main__':
    sys.exit(main())
