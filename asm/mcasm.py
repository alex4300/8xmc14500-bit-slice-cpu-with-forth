#!/usr/bin/env python3
"""
mcasm.py — Microcode Assembler for the MC14500 Bit-Slice CPU

Translates human-readable assembly into 41-bit microwords (.mem files)
compatible with Icarus Verilog's $readmemh.

Usage:
    python3 mcasm.py input.asm                # → input.mem
    python3 mcasm.py input.asm -o output.mem  # → output.mem
    python3 mcasm.py input.asm --verbose       # show assembled listing

Syntax:
    label:                      ; define a label (resolves to ROM address)
    LD  [0x10]                  ; opcode with RAM address
    LD  [myvar]                 ; opcode with named RAM address
    LD  #0x41                   ; immediate: load literal value 0x41
    ADD #5                      ; immediate: add literal 5
    AND #0x0F                   ; immediate: mask lower nibble
    ADD [0x11], carry           ; use carry flag as carry_in
    STO [0x7FFF]                  ; store to I/O
    JMP label                   ; unconditional jump
    JZ  label                   ; jump if zero
    JC  label                   ; jump if carry
    CALL label                  ; push return addr, jump
    RET                         ; pop return addr
    HALT                        ; stop CPU
    NOP                         ; no operation

    .data myvar 0x10            ; name a RAM address
    .data UART_DATA 0xFF
    .print "hello\\r\\n"         ; emit code to print string via UART

Operand forms:
    [addr]  — RAM address (symbol or literal)
    #value  — Immediate: value encoded directly in instruction (sets imm bit)

Modifiers (comma-separated after operand):
    carry   — use carry flag as carry_in for bit 0
    store   — write result to RAM (auto-set for STO/STOC)

Macros:
    .print "text"   — Generates LD #char + STO [0xFF] pairs for each character.
                      Supports: \\n \\r \\t \\\\

Examples:
    LD  [operand_a]             ; load from named RAM location
    LD  #'A'                    ; load ASCII 'A' (immediate)
    ADD #1                      ; add 1 (immediate)
    ADD [operand_b], carry      ; add with carry from RAM
    STO [result]                ; store (write-enable auto-set)
    XOR #0x0D                   ; compare with CR (immediate)
    JZ  wait_loop               ; jump if zero flag set
    .print "ready.\\r\\n"        ; print string to UART
"""

import sys
import re
import argparse
from pathlib import Path

# ============================================================================
# Opcode table
# ============================================================================
OPCODES = {
    'NOP':  0x0,
    'LD':   0x1,
    'LDC':  0x2,
    'AND':  0x3,
    'ANDC': 0x4,
    'OR':   0x5,
    'ORC':  0x6,
    'XOR':  0x7,
    'ADD':  0x8,
    'SUB':  0x9,
    'INC':  0xA,
    'DEC':  0xB,
    'STO':  0xC,
    'STOC': 0xD,
    'SET':  0xE,
    'CLR':  0xF,
}

# Opcodes that auto-set write enable
AUTO_WE_OPS = {'STO', 'STOC'}

# Opcodes that need a RAM address operand
ADDR_OPS = {'LD', 'LDC', 'AND', 'ANDC', 'OR', 'ORC', 'XOR',
            'ADD', 'SUB', 'STO', 'STOC'}

# Opcodes that don't take any operand
NO_OPERAND_OPS = {'NOP', 'INC', 'DEC', 'SET', 'CLR'}

# Shift/rotate pseudo-ops (no operand, encoded via control bits)
SHIFT_OPS = {'SHL', 'SHR', 'ROL', 'ROR'}

# Stack pseudo-ops (no operand, encoded via sp_mode + sp_auto bits)
STACK_OPS = {'PUSH', 'POP'}

# Data-stack base address. Effective stack address = STACK_BASE + sp_data,
# so with SP-init 0xFB and STACK_BASE 0x7E00 the stack lives at 0x7E00..0x7EFB.
# Set to 0x0000 to put the stack on Page 0 (legacy layout, contended with
# user VARIABLEs). Page 0x7E was chosen to free Page 0 entirely for variables
# and (later) PAUSE/multi-task structs.
STACK_BASE = 0x7E00

# Branch/control pseudo-ops
BRANCH_OPS = {'JMP', 'JZ', 'JC', 'CALL', 'RET', 'HALT',
              'JMPI', 'JZI', 'JCI', 'CALLI'}


# ============================================================================
# .print macro support
# ============================================================================

ESCAPE_MAP = {
    'n': 0x0A,
    'r': 0x0D,
    't': 0x09,
    '\\': 0x5C,
    '"': 0x22,
    '0': 0x00,
}


def _unescape(s):
    """Process escape sequences in a .print string."""
    result = []
    i = 0
    while i < len(s):
        if s[i] == '\\' and i + 1 < len(s):
            ch = s[i + 1]
            if ch in ESCAPE_MAP:
                result.append(chr(ESCAPE_MAP[ch]))
                i += 2
                continue
            else:
                result.append(s[i + 1])
                i += 2
                continue
        result.append(s[i])
        i += 1
    return ''.join(result)


def preprocess(source):
    """
    Expand .print macros into LD #imm + STO [0xFF] pairs.
    With immediate mode, no bit-constant init is needed.
    """
    lines = source.split('\n')
    output = []

    for line in lines:
        stripped = line.strip()
        m = re.match(r'\.print\s+"((?:[^"\\]|\\.)*)"', stripped)
        if not m:
            output.append(line)
            continue

        text = _unescape(m.group(1))
        safe_str = m.group(1)[:40]
        output.append(f"; --- .print \"{safe_str}\" ---")

        prev_val = None
        for ch in text:
            val = ord(ch)
            if val > 0x7F:
                raise ValueError(f"Character out of ASCII range: {ch!r} (0x{val:02X})")
            if 0x20 <= val <= 0x7E:
                comment = f"'{ch}'"
            else:
                comment = f"0x{val:02X}"

            if val == prev_val:
                output.append(f"    STO [0x7FFF]                  ; {comment} (repeat)")
            else:
                output.append(f"    LD  #0x{val:02X}                    ; {comment}")
                output.append(f"    STO [0x7FFF]")
                prev_val = val

    return '\n'.join(output)


class AsmError(Exception):
    def __init__(self, line_num, message):
        self.line_num = line_num
        self.message = message
        super().__init__(f"Line {line_num}: {message}")


def parse_number(s):
    """Parse a number literal: 0x1A, 0b1010, 42, 'A'"""
    s = s.strip()
    if s.startswith("0x") or s.startswith("0X"):
        return int(s, 16)
    if s.startswith("0b") or s.startswith("0B"):
        return int(s, 2)
    if s.startswith("'") and s.endswith("'") and len(s) == 3:
        return ord(s[1])
    return int(s)


def assemble(source, filename="<input>"):
    """
    Two-pass assembler.
    Pass 1: collect labels and .data definitions, determine addresses.
    Pass 2: resolve labels and emit microwords.

    `late_const_refs` records each `LD #INIT_*` use so the caller can patch the
    immediate byte after the dict layout is computed (at which point the actual
    HERE/LATEST/DICT_PTR values are known). Used to bake those values into the
    ROM directly, removing the dependency on the BSRAM cold-reset backup at
    0x1A-0x1F (which would otherwise be vulnerable to runtime corruption).
    """
    lines = source.split('\n')

    # Symbol tables
    labels = {}         # label → ROM address
    data_syms = {}      # name → RAM address
    instructions = []   # list of (line_num, original_text, parsed_fields)
    late_const_refs = []  # [(rom_addr, const_name)] for INIT_* constants

    # ====================================================================
    # Pass 1: Parse lines, collect labels, assign ROM addresses
    # ====================================================================
    rom_addr = 0
    in_forthword = False

    for line_num_0, raw_line in enumerate(lines):
        line_num = line_num_0 + 1
        # Strip comments (but not ; inside quoted strings)
        in_quote = False
        comment_pos = -1
        for ci, ch in enumerate(raw_line):
            if ch == '"' and (ci == 0 or raw_line[ci-1] != '\\'):
                in_quote = not in_quote
            elif ch == ';' and not in_quote:
                comment_pos = ci
                break
        line = (raw_line[:comment_pos] if comment_pos >= 0 else raw_line).strip()
        # .forthword body: check BEFORE blank-line skip so flag resets on blank lines
        if in_forthword:
            if not line or line.startswith('.') or ':' in line:
                in_forthword = False
                # Fall through to process this line normally (or skip if blank)
            else:
                continue  # skip body token line

        if not line:
            continue

        # .data directive
        if line.startswith('.data'):
            parts = line.split()
            if len(parts) != 3:
                raise AsmError(line_num, f".data requires name and address: .data NAME 0xNN")
            name = parts[1].upper()
            try:
                addr = parse_number(parts[2])
            except ValueError:
                raise AsmError(line_num, f"Invalid address: {parts[2]}")
            if addr < 0 or addr > 0x7FFF:
                raise AsmError(line_num, f"RAM address out of range (0x0000-0xFFFF): 0x{addr:04X}")
            data_syms[name] = addr
            continue

        # .builtin directive — processed after label resolution
        if line.startswith('.builtin'):
            continue

        # .forthword block — skip header, set flag for body
        if line.startswith('.forthword'):
            in_forthword = True
            continue

        # .org directive — set ROM address
        if line.startswith('.org'):
            parts = line.split()
            if len(parts) != 2:
                raise AsmError(line_num, ".org requires an address: .org 0x10")
            try:
                rom_addr = parse_number(parts[1])
            except ValueError:
                raise AsmError(line_num, f"Invalid address: {parts[1]}")
            continue

        # Label definition (can be on its own line or before an instruction)
        while ':' in line:
            colon_pos = line.index(':')
            label_name = line[:colon_pos].strip().upper()
            if not re.match(r'^[A-Z_][A-Z0-9_]*$', label_name):
                raise AsmError(line_num, f"Invalid label: {label_name}")
            if label_name in labels:
                raise AsmError(line_num, f"Duplicate label: {label_name}")
            labels[label_name] = rom_addr
            line = line[colon_pos + 1:].strip()

        if not line:
            continue

        # Parse instruction
        instructions.append((line_num, raw_line.rstrip(), line, rom_addr))
        rom_addr += 1

        if rom_addr > 8192:
            raise AsmError(line_num, "Program exceeds 8192 ROM words")

    # ====================================================================
    # Pass 2: Assemble instructions into microwords
    # ====================================================================
    rom = [0] * 8192
    listing = []

    for line_num, raw_line, line, addr in instructions:
        # Tokenize: split on whitespace, but keep [...] together
        # Examples: "LD [0x10]", "ADD [myvar], carry", "JMP loop", "HALT"
        tokens = re.split(r'\s+', line, maxsplit=1)
        mnemonic = tokens[0].upper()
        operand_str = tokens[1] if len(tokens) > 1 else ""

        # Parse modifiers (after closing bracket or after operand)
        # Handle ", x" inside brackets: [addr, x] → indexed mode
        # Handle ", carry" etc. outside brackets: ADD [addr], carry
        modifiers = set()
        bracket_end = operand_str.find(']')
        if bracket_end >= 0:
            # Check for ", x" inside brackets: [addr, x]
            inside = operand_str[1:bracket_end]  # content between [ and ]
            if ',' in inside:
                bracket_parts = inside.split(',')
                # Rebuild operand with just the address part
                operand_str = '[' + bracket_parts[0].strip() + ']' + operand_str[bracket_end+1:]
                for mod in bracket_parts[1:]:
                    modifiers.add(mod.strip().lower())
            # Check for modifiers after the bracket: [addr], carry
            after = operand_str[bracket_end+1:]
            if ',' in after:
                for mod in after.split(',')[1:]:
                    modifiers.add(mod.strip().lower())
                operand_str = operand_str[:bracket_end+1]
        elif ',' in operand_str:
            # No brackets — simple comma-separated modifiers: #value, carry
            parts = operand_str.split(',')
            operand_str = parts[0].strip()
            for mod in parts[1:]:
                modifiers.add(mod.strip().lower())

        # ---- Build microword fields ----
        opcode = 0
        we = 0
        use_carry = 0
        jmp_mode = 0
        is_call = 0
        is_ret = 0
        is_halt = 0
        imm = 0
        shift = 0
        shift_dir = 0   # bit [18]: shift direction OR sp_mode
        ix_mode = 0     # bit [17]: ix_mode OR sp_auto
        jmp_ind = 0     # bit [16]: indirect jump
        ram_addr = 0
        jmp_target = 0

        if mnemonic in OPCODES:
            opcode = OPCODES[mnemonic]

            # Auto write-enable for store ops
            if mnemonic in AUTO_WE_OPS:
                we = 1

            # Parse operand: #immediate or [ram_addr]
            if mnemonic in ADDR_OPS:
                if not operand_str:
                    raise AsmError(line_num, f"{mnemonic} requires an operand: {mnemonic} [addr] or {mnemonic} #value")

                # Immediate: #value or #label
                im = re.match(r'#(.+)', operand_str)
                if im:
                    imm = 1
                    imm_str = im.group(1).strip()
                    # Try as label first (for LD #label → load ROM address)
                    if imm_str.upper() in labels:
                        val = labels[imm_str.upper()]
                    elif imm_str.upper() in data_syms:
                        # .data symbols can be used as immediate constants too
                        # (useful for page-0 base addresses passed to IX-mode
                        # routines, e.g. `LD #TASK0_BASE; STO [0x7FFD]`).
                        val = data_syms[imm_str.upper()]
                    elif imm_str.upper().startswith('INIT_'):
                        # Late-bound constant: emit placeholder, patched after
                        # dict layout is computed in main().
                        val = 0
                        late_const_refs.append((addr, imm_str.upper()))
                    else:
                        try:
                            val = parse_number(imm_str)
                        except ValueError:
                            raise AsmError(line_num, f"Invalid immediate value: {imm_str}")
                    if val < 0 or val > 0xFF:
                        raise AsmError(line_num, f"Immediate out of range (0x00-0xFF): 0x{val:02X}")
                    ram_addr = val  # immediate value goes in ram_addr field
                else:
                    # RAM address: [addr] or [symbol]
                    m = re.match(r'\[(.+)\]', operand_str)
                    if not m:
                        raise AsmError(line_num, f"Expected [addr] or #value: {mnemonic} {operand_str}")
                    addr_str = m.group(1).strip().upper()
                    if addr_str in data_syms:
                        ram_addr = data_syms[addr_str]
                    else:
                        try:
                            ram_addr = parse_number(m.group(1).strip())
                        except ValueError:
                            raise AsmError(line_num, f"Unknown symbol or invalid address: {addr_str}")
                    if ram_addr < 0 or ram_addr > 0x7FFF:
                        raise AsmError(line_num, f"RAM address out of range: 0x{ram_addr:04X}")

            elif mnemonic in NO_OPERAND_OPS:
                if operand_str and not operand_str.startswith(','):
                    raise AsmError(line_num, f"{mnemonic} takes no operand")

            # Modifiers
            if 'carry' in modifiers:
                use_carry = 1
            if 'store' in modifiers or 'we' in modifiers:
                we = 1
            if 'x' in modifiers:
                ix_mode = 1
            if 's' in modifiers:
                shift_dir = 1   # bit [18] = sp_mode when shift=0
            if 's!' in modifiers:
                shift_dir = 1   # sp_mode
                ix_mode = 1     # sp_auto (bit [17])

        elif mnemonic in STACK_OPS:
            # PUSH: STO with sp_mode + sp_auto (SP--, store at RAM[SP])
            # POP:  LD  with sp_mode + sp_auto (load from RAM[SP], SP++)
            # Effective address = STACK_BASE + sp_data.
            shift_dir = 1   # sp_mode (bit [18])
            ix_mode = 1     # sp_auto (bit [17])
            ram_addr = STACK_BASE
            if mnemonic == 'PUSH':
                opcode = OPCODES['STO']
                we = 1
            else:  # POP
                opcode = OPCODES['LD']

        elif mnemonic in SHIFT_OPS:
            # SHL/SHR/ROL/ROR — shift bit [19], direction bit [18]
            # ROL/ROR = shift with carry (use_carry=1)
            shift = 1
            if mnemonic in ('SHR', 'ROR'):
                shift_dir = 1
            if mnemonic in ('ROL', 'ROR'):
                use_carry = 1

        elif mnemonic in ('JMP', 'JMPI'):
            opcode = 0
            jmp_mode = 0b01
            if mnemonic == 'JMPI':
                jmp_ind = 1
            else:
                jmp_target = _resolve_label(operand_str, labels, line_num)

        elif mnemonic in ('JZ', 'JZI'):
            opcode = 0
            jmp_mode = 0b10
            if mnemonic == 'JZI':
                jmp_ind = 1
            else:
                jmp_target = _resolve_label(operand_str, labels, line_num)

        elif mnemonic in ('JC', 'JCI'):
            opcode = 0
            jmp_mode = 0b11
            if mnemonic == 'JCI':
                jmp_ind = 1
            else:
                jmp_target = _resolve_label(operand_str, labels, line_num)

        elif mnemonic in ('CALL', 'CALLI'):
            opcode = 0
            jmp_mode = 0b01
            is_call = 1
            if mnemonic == 'CALLI':
                jmp_ind = 1
            else:
                jmp_target = _resolve_label(operand_str, labels, line_num)

        elif mnemonic == 'RET':
            opcode = 0
            is_ret = 1

        elif mnemonic == 'HALT':
            opcode = 0
            is_halt = 1

        else:
            raise AsmError(line_num, f"Unknown instruction: {mnemonic}")

        # ---- Encode 48-bit microword ----
        # Layout (see doc/MICROWORD.md):
        # [47:44] jmp_target[14:11]  [43] reserved (1)  [42:39] opcode (4)
        # [38] we  [37] use_carry  [36:35] jmp_mode (2)
        # [34] call  [33] ret  [32] halt  [31] imm
        # [30] shift  [29] shift_dir/sp_mode  [28] ix_mode/sp_auto  [27] jmp_ind
        # [26:11] ram_addr (16)  [10:0] jmp_target[10:0]
        word = (((jmp_target >> 11) & 0xF) << 44 |
                (opcode    & 0xF)    << 39 |
                (we        & 0x1)    << 38 |
                (use_carry & 0x1)    << 37 |
                (jmp_mode  & 0x3)    << 35 |
                (is_call   & 0x1)    << 34 |
                (is_ret    & 0x1)    << 33 |
                (is_halt   & 0x1)    << 32 |
                (imm       & 0x1)    << 31 |
                (shift     & 0x1)    << 30 |
                (shift_dir & 0x1)    << 29 |
                (ix_mode   & 0x1)    << 28 |
                (jmp_ind   & 0x1)    << 27 |
                (ram_addr  & 0xFFFF) << 11 |
                (jmp_target & 0x7FF))

        rom[addr] = word
        listing.append((addr, word, raw_line))

    # ====================================================================
    # Pass 3: Process .builtin directives (need resolved labels)
    # ====================================================================
    builtin_defs = []
    for line_num_0, raw_line in enumerate(lines):
        line_num = line_num_0 + 1
        # Strip comments respecting quoted strings
        in_q = False
        cp = -1
        for ci, ch in enumerate(raw_line):
            if ch == '"' and (ci == 0 or raw_line[ci-1] != '\\'):
                in_q = not in_q
            elif ch == ';' and not in_q:
                cp = ci
                break
        line = (raw_line[:cp] if cp >= 0 else raw_line).strip()
        if not line.startswith('.builtin'):
            continue
        # .builtin "NAME" handler [immediate]  (use \" for literal quote in name)
        m = re.match(r'\.builtin\s+"((?:[^"\\]|\\.)*)"\s+(\S+)(\s+immediate)?', line)
        if not m:
            raise AsmError(line_num, '.builtin requires: .builtin "NAME" handler [immediate]')
        name = m.group(1).replace('\\\\', '\\').replace('\\"', '"')
        handler_str = m.group(2).strip().upper()
        is_immediate = m.group(3) is not None
        if handler_str in labels:
            handler_addr = labels[handler_str]
        else:
            try:
                handler_addr = parse_number(m.group(2).strip())
            except ValueError:
                raise AsmError(line_num, f"Unknown handler label: {handler_str}")
        if handler_addr > 0xFF:
            raise AsmError(line_num, f"Handler address > 0xFF (needs trampoline): 0x{handler_addr:03X}")
        builtin_defs.append((name, handler_addr, is_immediate))

    # ====================================================================
    # Pass 4: Process .forthword directives — pre-compiled Forth in RAM
    # ====================================================================
    # Generates token sequences in compile buffer (0x0500+) and
    # dictionary entries in user dict (0x0400+).
    # Tokens after do_branch/do_zbranch/do_call_user are 2-byte addresses
    # tagged as ('addr16', value) tuples during collection.
    COMPILE_BASE = 0x1000
    forthword_defs = []   # list of (name, is_immediate, tokens[])
    compile_offset = 0    # tracks position in compile buffer (bytes)
    user_latest = 0xFFFF  # user dict chain head (full 15-bit address, 0xFFFF = empty)
    user_dict_ptr = 0x0400  # user dict allocation pointer (full 15-bit address)

    # Tokens that consume a 2-byte address argument
    addr16_tokens = set()
    for lbl in ['DO_BRANCH', 'DO_ZBRANCH', 'DO_CALL_USER']:
        if lbl in labels:
            addr16_tokens.add(labels[lbl])

    i = 0
    while i < len(lines):
        line = lines[i].split(';')[0].strip() if not any(c == '"' for c in lines[i][:20]) else lines[i].strip()
        # Better: use the quote-aware stripping
        raw = lines[i]
        in_q2 = False
        cp2 = -1
        for ci2, ch2 in enumerate(raw):
            if ch2 == '"' and (ci2 == 0 or raw[ci2-1] != '\\'):
                in_q2 = not in_q2
            elif ch2 == ';' and not in_q2:
                cp2 = ci2
                break
        line = (raw[:cp2] if cp2 >= 0 else raw).strip()

        if not line.startswith('.forthword'):
            i += 1
            continue

        # Parse header: .forthword "NAME" [immediate]
        m = re.match(r'\.forthword\s+"((?:[^"\\]|\\.)*)"\s*(immediate)?', line)
        if not m:
            raise AsmError(i + 1, '.forthword requires: .forthword "NAME" [immediate]')
        fw_name = m.group(1).replace('\\\\', '\\').replace('\\"', '"')
        fw_imm = m.group(2) is not None
        i += 1

        # Read token lines until next directive or end
        raw_tokens = []
        while i < len(lines):
            tline = lines[i].split(';')[0].strip()
            if not tline or tline.startswith('.'):
                break
            # Each line: label_or_number [argument]
            parts = tline.split()
            for part in parts:
                part_upper = part.upper()
                if part.startswith('@'):
                    # Word-relative offset: @N → absolute address in compile buffer
                    try:
                        rel = int(part[1:])
                    except ValueError:
                        raise AsmError(i + 1, f"Invalid relative offset: {part}")
                    raw_tokens.append(('addr16', COMPILE_BASE + compile_offset + rel))
                elif part_upper in labels:
                    raw_tokens.append(labels[part_upper])
                else:
                    try:
                        raw_tokens.append(parse_number(part))
                    except ValueError:
                        raise AsmError(i + 1, f"Unknown token: {part}")
            i += 1

        raw_tokens.append(0)  # exit token

        # Expand addr16 tags to 2 bytes (hi, lo) and count final size
        tokens = []
        for tok in raw_tokens:
            if isinstance(tok, tuple) and tok[0] == 'addr16':
                addr = tok[1]
                tokens.append((addr >> 8) & 0x7F)  # hi byte
                tokens.append(addr & 0xFF)          # lo byte
            else:
                tokens.append(tok)

        forthword_defs.append((fw_name, fw_imm, tokens, compile_offset))
        compile_offset += len(tokens)

    return rom, listing, labels, data_syms, builtin_defs, forthword_defs, compile_offset, late_const_refs


def _resolve_label(operand_str, labels, line_num):
    """Resolve a jump target label or numeric address."""
    target = operand_str.strip().upper()
    if not target:
        raise AsmError(line_num, "Jump/call requires a target label or address")
    if target in labels:
        return labels[target]
    try:
        addr = parse_number(operand_str.strip())
        if addr < 0 or addr > 0x7FFF:
            raise AsmError(line_num, f"Jump target out of range: 0x{addr:04X}")
        return addr
    except ValueError:
        raise AsmError(line_num, f"Unknown label: {target}")


def build_builtin_dict(builtin_defs, base_addr=0x0400):
    """Build unified linked-list dict entries in RAM for builtins.
    Same format as user-word entries so one walker handles both chains.
    Entry: [link_hi, link_lo, name_len|imm(1), name_chars(N), handler_hi, handler_lo]
    Builtins have handler_hi=0 (ROM address < 0x100); the runtime dispatches
    on that to emit a 1-byte token instead of `do_call_user` + 2-byte addr.
    Returns (ram_data dict, latest_full_addr, next_dict_ptr).
    """
    ram = {}
    dict_ptr = base_addr
    latest = 0xFFFF     # end-of-chain sentinel

    for name, handler_addr, is_immediate in builtin_defs:
        entry_start = dict_ptr
        # Link = 2 bytes (full addr of prev entry, or 0xFFFF for end)
        ram[dict_ptr] = (latest >> 8) & 0xFF
        dict_ptr += 1
        ram[dict_ptr] = latest & 0xFF
        dict_ptr += 1
        # name_len with immediate flag in bit 7
        name_len = len(name)
        if is_immediate:
            name_len |= 0x80
        ram[dict_ptr] = name_len
        dict_ptr += 1
        # Name characters
        for ch in name:
            ram[dict_ptr] = ord(ch) & 0xFF
            dict_ptr += 1
        # Handler = 2 bytes (hi=0 for builtins, lo = ROM addr)
        ram[dict_ptr] = (handler_addr >> 8) & 0xFF
        dict_ptr += 1
        ram[dict_ptr] = handler_addr & 0xFF
        dict_ptr += 1
        latest = entry_start

    return ram, latest, dict_ptr


def build_forthword_ram(forthword_defs, compile_base=0x1000, dict_base=0x0400,
                        initial_latest=0xFFFF):
    """Build pre-compiled Forth words in RAM.
    Returns (ram_data, user_latest, user_dict_ptr, here_value).
    User dict entries: [link_hi, link_lo, name_len|imm, name_chars..., addr_hi, addr_lo]
    Links are full 15-bit RAM addresses (0xFFFF = end of chain).
    If initial_latest is provided, first forthword links to that entry (used when
    builtins precede user words in the same unified chain).
    """
    ram = {}
    user_latest = initial_latest    # chain head when this fn starts
    user_dict_ptr = dict_base  # full address of next free byte

    for name, is_imm, tokens, offset in forthword_defs:
        # Write tokens to compile buffer
        for j, tok in enumerate(tokens):
            ram[compile_base + offset + j] = tok & 0xFF

        # Write user dict entry at current dict_ptr
        entry_start = user_dict_ptr
        # link = 2 bytes (full 15-bit address of previous entry, or 0xFFFF)
        ram[user_dict_ptr] = (user_latest >> 8) & 0xFF
        user_dict_ptr += 1
        ram[user_dict_ptr] = user_latest & 0xFF
        user_dict_ptr += 1
        # name_len | immediate flag
        name_len = len(name)
        if is_imm:
            name_len |= 0x80
        ram[user_dict_ptr] = name_len
        user_dict_ptr += 1
        # name chars
        for ch in name:
            ram[user_dict_ptr] = ord(ch) & 0xFF
            user_dict_ptr += 1
        # compile address = 2 bytes (hi, lo)
        full_addr = compile_base + offset
        ram[user_dict_ptr] = (full_addr >> 8) & 0xFF
        user_dict_ptr += 1
        ram[user_dict_ptr] = full_addr & 0xFF
        user_dict_ptr += 1
        # update latest to this entry's start
        user_latest = entry_start

    here_value = compile_base + (forthword_defs[-1][3] + len(forthword_defs[-1][2]) if forthword_defs else 0)
    return ram, user_latest, user_dict_ptr, here_value


def emit_ram(builtin_ram, forthword_ram, user_latest, user_dict_ptr,
             here_value,
             latest_lo_addr, latest_hi_addr,
             dict_ptr_lo_addr, dict_ptr_hi_addr,
             here_hi_addr, here_lo_addr):
    """Generate RAM init .mem file. Sparse format: @addr data.
    user_latest and user_dict_ptr are full 15-bit RAM addresses (16-bit encoded).
    The unified dict has builtins first, then forthwords — latest_hi/lo points
    to whichever entry was created last.
    """
    all_data = {}
    all_data.update(builtin_ram)
    all_data.update(forthword_ram)
    all_data[latest_lo_addr]   = user_latest & 0xFF
    all_data[latest_hi_addr]   = (user_latest >> 8) & 0xFF
    all_data[dict_ptr_lo_addr] = user_dict_ptr & 0xFF
    all_data[dict_ptr_hi_addr] = (user_dict_ptr >> 8) & 0xFF
    # here (compile buffer pointer, 2 bytes)
    if here_value > 0:
        all_data[here_hi_addr] = (here_value >> 8) & 0xFF
        all_data[here_lo_addr] = here_value & 0xFF
    # NOTE: an earlier revision wrote here/latest/dict_ptr backups to
    # 0x1A-0x1F so the init: routine could restore them on soft reset.  Late-
    # bind constants (INIT_HERE_HI etc.) supersede that path: dict_init now
    # patches the live slots directly via ROM-encoded LD/STO pairs, and
    # forth.asm's init: zeros the rest.  The slots 0x1A/0x1B are reused as
    # SD scratch (sd_save_lo/hi) and 0x1C onward holds runtime state like
    # `base` — leaving them alone here keeps those values intact.

    lines = []
    for addr in sorted(all_data.keys()):
        lines.append(f"@{addr:04X} {all_data[addr]:02X}")

    return '\n'.join(lines) + '\n', all_data


def emit_ram_verilog_init(ram_data, array_name='ram'):
    """Generate inline Verilog RAM init (bypass $readmemh for synthesis)."""
    lines = []
    for addr in sorted(ram_data.keys()):
        lines.append(f"    {array_name}[{addr:5d}] = 8'h{ram_data[addr]:02X};")
    return '\n'.join(lines) + '\n'


def _encode_ld_imm(value):
    """Microword for `LD #value` (imm bit set, value in ram_addr[7:0])."""
    return ((OPCODES['LD'] & 0xF) << 39) | (1 << 31) | ((value & 0xFF) << 11)


def _encode_sto_addr(addr):
    """Microword for `STO [addr]` (we bit set, full ram_addr)."""
    return ((OPCODES['STO'] & 0xF) << 39) | (1 << 38) | ((addr & 0xFFFF) << 11)


def _encode_ret():
    """Microword for `RET` (just the ret bit)."""
    return (1 << 33)


def populate_dict_init(rom, listing, ram_data, start_addr, rom_size):
    """Fill rom[start_addr:] with `LD #v; STO [addr]` pairs that bring up the
    runtime dictionary at boot, then a final RET. Used because Gowin/yosys
    doesn't reliably persist BRAM init across the bitstream — driving the dict
    via ROM-encoded init code is the only path that actually lands the bytes
    in RAM on the FPGA. Returns the number of microwords written."""
    addr = start_addr
    for ram_addr in sorted(ram_data.keys()):
        value = ram_data[ram_addr]
        if value == 0:
            continue                 # RAM is zero-initialized already
        if addr + 1 >= rom_size:
            raise AsmError(0, f"dict-init code overflows ROM (need >= {addr+2}, have {rom_size})")
        rom[addr]     = _encode_ld_imm(value)
        rom[addr + 1] = _encode_sto_addr(ram_addr)
        listing.append((addr,     rom[addr],     f"LD  #0x{value:02X}     ; dict-init"))
        listing.append((addr + 1, rom[addr + 1], f"STO [0x{ram_addr:04X}]  ; dict-init"))
        addr += 2
    if addr >= rom_size:
        raise AsmError(0, "dict-init has no room for trailing RET")
    rom[addr] = _encode_ret()
    listing.append((addr, rom[addr], "RET             ; dict-init done"))
    return addr - start_addr + 1


def emit_mem(rom, listing):
    """Generate .mem file content compatible with $readmemh."""
    lines = []
    # Find last non-zero word
    last_used = 0
    for i in range(len(rom) - 1, -1, -1):
        if rom[i] != 0:
            last_used = i
            break

    # Emit with comments from listing
    listing_map = {addr: (word, raw) for addr, word, raw in listing}

    for i in range(last_used + 1):
        hex_word = f"{rom[i]:012X}"
        if i in listing_map:
            _, raw = listing_map[i]
            comment = raw.strip()
            if len(comment) > 55:
                comment = comment[:52] + "..."
            lines.append(f"{hex_word}  // {i:03X}: {comment}")
        else:
            lines.append(hex_word)

    return '\n'.join(lines) + '\n'


def emit_verilog_init(rom, listing, array_name='rom'):
    """Generate inline Verilog ROM init (bypass $readmemh for synthesis)."""
    listing_map = {addr: raw for addr, _word, raw in listing}
    lines = []
    for i, word in enumerate(rom):
        if word == 0:
            continue
        comment = listing_map.get(i, '').strip()
        hex_word = f"48'h{word:012X}"
        stmt = f"    {array_name}[{i:4d}] = {hex_word};"
        if comment:
            if len(comment) > 55:
                comment = comment[:52] + '...'
            stmt += f"  // {comment}"
        lines.append(stmt)
    return '\n'.join(lines) + '\n'


def print_listing(listing, labels, data_syms):
    """Print a human-readable listing."""
    print()
    print("Addr   Microword           Source")
    print("-----  ------------        " + "-" * 50)
    for addr, word, raw in listing:
        print(f"0x{addr:03X}  {word:012X}    {raw.rstrip()}")

    if labels:
        print()
        print("Labels:")
        for name, addr in sorted(labels.items(), key=lambda x: x[1]):
            print(f"  {name:20s} = 0x{addr:03X}")

    if data_syms:
        print()
        print("Data symbols:")
        for name, addr in sorted(data_syms.items(), key=lambda x: x[1]):
            print(f"  {name:20s} = RAM[0x{addr:02X}]")

    print()


def main():
    parser = argparse.ArgumentParser(
        description="MC14500 Bit-Slice CPU — Microcode Assembler")
    parser.add_argument('input', help='Assembly source file (.asm)')
    parser.add_argument('-o', '--output', help='Output .mem file (default: input with .mem extension)')
    parser.add_argument('-v', '--verbose', action='store_true', help='Print assembled listing')
    parser.add_argument('-E', '--expand', action='store_true', help='Print expanded source (after macro expansion)')
    parser.add_argument('--verilog-init', action='store_true',
                        help="Also emit <output>.vh with inline rom[i] = 48'h...; "
                             "statements for synthesis tools that fail to honor $readmemh")
    args = parser.parse_args()

    input_path = Path(args.input)
    if not input_path.exists():
        print(f"Error: file not found: {input_path}", file=sys.stderr)
        sys.exit(1)

    output_path = Path(args.output) if args.output else input_path.with_suffix('.mem')

    source = input_path.read_text()

    # Expand macros (.print etc.) before assembling
    source = preprocess(source)

    if args.expand:
        print(source)
        return

    try:
        rom, listing, labels, data_syms, builtin_defs, forthword_defs, fw_here, late_const_refs = \
            assemble(source, str(input_path))
    except AsmError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    # Write ROM output (provisional — re-emitted below if dict-init / late
    # constants need patching).
    output_path.write_text(emit_mem(rom, listing))

    if args.verilog_init and not (builtin_defs or forthword_defs):
        # No dict to populate — emit the Verilog ROM init right away.
        vh_path = output_path.with_suffix('.vh')
        vh_path.write_text(emit_verilog_init(rom, listing))
        print(f"  Verilog ROM init → {vh_path}")

    # Write RAM init file if builtins or forthwords are defined
    if builtin_defs or forthword_defs:
        ram_path = output_path.with_suffix('.ram')
        builtin_ram, b_latest, b_dict_ptr = build_builtin_dict(builtin_defs)

        # Forthwords chain onto the end of the builtin chain in the same dict.
        fw_ram, u_latest, u_dict_ptr, here_val = build_forthword_ram(
            forthword_defs, dict_base=b_dict_ptr, initial_latest=b_latest)

        latest_lo_addr   = data_syms.get('LATEST_LO', 0x0D)
        latest_hi_addr   = data_syms.get('LATEST_HI', 0x22)
        dict_ptr_lo_addr = data_syms.get('DICT_PTR_LO', 0x0E)
        dict_ptr_hi_addr = data_syms.get('DICT_PTR_HI', 0x23)
        here_hi_addr     = data_syms.get('HERE_HI', 0x09)
        here_lo_addr     = data_syms.get('HERE_LO', 0x0A)

        ram_content, ram_data = emit_ram(builtin_ram, fw_ram, u_latest, u_dict_ptr,
                              here_val,
                              latest_lo_addr, latest_hi_addr,
                              dict_ptr_lo_addr, dict_ptr_hi_addr,
                              here_hi_addr, here_lo_addr)
        ram_path.write_text(ram_content)

        # Patch late-bound INIT_* constants in ROM.  Init code uses these as
        # immediate operands so reset always restores HERE/LATEST/DICT_PTR
        # from compile-time values, regardless of any BSRAM corruption.
        const_values = {
            'INIT_HERE_HI':     (here_val      >> 8) & 0xFF,
            'INIT_HERE_LO':      here_val             & 0xFF,
            'INIT_LATEST_HI':   (u_latest      >> 8) & 0xFF,
            'INIT_LATEST_LO':    u_latest             & 0xFF,
            'INIT_DICT_PTR_HI': (u_dict_ptr    >> 8) & 0xFF,
            'INIT_DICT_PTR_LO':  u_dict_ptr           & 0xFF,
        }
        for rom_a, name in late_const_refs:
            if name not in const_values:
                print(f"  WARN: unknown late-const {name}", file=sys.stderr)
                continue
            new_val = const_values[name]
            # ram_addr is bits [26:11] of the microword; for an immediate
            # operand only the lower 8 bits ([18:11]) are read by the CPU.
            rom[rom_a] &= ~(0xFF << 11)
            rom[rom_a] |= (new_val & 0xFF) << 11

        # If forth.asm declares a `dict_init` label, fill its body with
        # `LD #v; STO [addr]` pairs covering the entire ram_data sparse map
        # and a trailing RET.  Required on the FPGA because Gowin BSRAM
        # init (both inline and $readmemh) is unreliable for the byte-wide
        # cpu.ram — running dict-init from ROM at boot is the only path
        # that actually puts the bytes in place.  See doc/SD_ONLY_ROADMAP.md.
        if 'DICT_INIT' in labels:
            n = populate_dict_init(rom, listing, ram_data,
                                   start_addr=labels['DICT_INIT'],
                                   rom_size=len(rom))
            print(f"  Dict-init code: {n} ROM words at "
                  f"0x{labels['DICT_INIT']:04X}-0x{labels['DICT_INIT']+n-1:04X}")
        # Re-emit .mem after late-const patching and dict-init expansion.
        output_path.write_text(emit_mem(rom, listing))
        if args.verilog_init:
            vh_path = output_path.with_suffix('.vh')
            vh_path.write_text(emit_verilog_init(rom, listing))
            print(f"  Verilog ROM init → {vh_path}")
            ram_vh_path = output_path.with_name(output_path.stem + '_ram.vh')
            ram_vh_path.write_text(emit_ram_verilog_init(ram_data))
            print(f"  Verilog RAM init → {ram_vh_path}")
        print(f"  Unified dictionary: {len(builtin_defs)} builtins + {len(forthword_defs)} forthwords, "
              f"{u_dict_ptr - 0x0400} bytes at 0x0400-0x{u_dict_ptr-1:04X}")
        if forthword_defs:
            print(f"  Forth word tokens: {fw_here} bytes (HERE starts at 0x{here_val:04X})")
        print(f"  → {ram_path}")

    # Stats
    used = sum(1 for w in rom if w != 0)
    print(f"Assembled {len(listing)} instructions → {output_path} ({used} ROM words used)")

    if args.verbose:
        print_listing(listing, labels, data_syms)


if __name__ == '__main__':
    main()
