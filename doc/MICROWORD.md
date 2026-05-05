# Microword Format Reference

The CPU executes one **48-bit microword** per clock cycle. The microword directly drives all datapath signals — there is no instruction decode stage in the traditional sense, just bit-field extraction.

## Layout

```
Bit position   Width   Field                       Description
────────────   ─────   ─────────────────────────   ─────────────────────────────────────
[47:44]        4       jmp_target[14:11]           High bits of jump/call target (with [10:0])
[43]           1       reserved                    Future use
[42:39]        4       opcode                      ALU opcode (see Slice opcodes)
[38]           1       we                          Write enable (1 = STO/STOC class)
[37]           1       use_carry                   Use latched carry as carry-in
[36:35]        2       jmp_mode                    00=none, 01=uncond, 10=JZ, 11=JC
[34]           1       call                        CALL: push return addr, then jump
[33]           1       ret                         RET: pop return address from stack
[32]           1       halt                        HALT the CPU
[31]           1       imm                         ram_addr[7:0] is literal value, not address
[30]           1       shift                       Shift mode (rewires slice carry chain)
[29]           1       shift_dir / sp_mode         Context-dependent (see modes below)
[28]           1       ix_mode / sp_auto           Context-dependent (see modes below)
[27]           1       jmp_ind                     Jump target from RR instead of jmp_target
[26:11]        16      ram_addr                    RAM address / immediate value
[10:0]         11      jmp_target[10:0]            Low bits of jump/call target
```

**Total used:** 47 bits. **Reserve:** 1 bit.
Jump target is 15-bit ({`[47:44]`, `[10:0]`}) → 32K microwords addressable.

## Addressing modes (bits [30:28])

| [30] shift | [29] | [28] | Mode | Effective address |
|---|---|---|---|---|
| 0 | 0 | 0 | Normal | `ram_addr` |
| 0 | 0 | 1 | IX-indexed | `ram_addr + {ix_hi, ix}` |
| 0 | 1 | 0 | SP-indexed peek | `ram_addr + sp_data` |
| 0 | 1 | 1 | SP auto | PUSH (we=1, pre-decrement SP) / POP (we=0, post-increment SP) |
| 1 | 0 | * | Shift left | (rewires slice carry-in from neighbor RR bits) |
| 1 | 1 | * | Shift right | (same, opposite direction) |

## Special details

- **`imm` (bit [31])**: When set, `ram_addr[7:0]` is treated as a literal data value rather than an address. The 16-bit `ram_addr` field holds an 8-bit immediate in its low bits.
- **`jmp_ind` (bit [27])**: When set, the jump target is `{3'b000, RR}` (the 8-bit accumulator zero-extended to 11 bits). This is how CALLI implements token dispatch — RR holds a token (ROM address < 256), CALLI calls the corresponding primitive.
- **`ram_addr[15]`**: Currently ignored by the CPU. The effective address (`eff_addr`) is 15 bits, addressing 32 KB of RAM. The 16th bit is reserved in the microword format for future activation of 64 KB RAM.

## Reserve plan (bits [47:43])

These 5 bits are documented for foreseeable extensions but are currently always 0:

| Bit | Planned function |
|-----|------------------|
| [43] | Return-stack-mode flag (`>R` / `R>` hardware support) |
| [44] | Interrupt-enable / interrupt-mask |
| [45] | STC-write mode (writable microcode memory) |
| [46] | Second index register (IY) or extended condition codes |
| [47] | Free |

When any of these is needed, the CPU's Verilog gets the new logic and the assembler gets a new directive to emit the bit. Existing code keeps working because all reserve bits default to 0.

## Slice opcodes (bits [42:39])

```
0x0  NOP
0x1  LD     RR ← M
0x2  LDC    RR ← !M
0x3  AND    RR ← RR & M
0x4  ANDC   RR ← RR & !M
0x5  OR     RR ← RR | M
0x6  ORC    RR ← RR | !M
0x7  XOR    RR ← RR ^ M
0x8  ADD    RR ← RR + M (sets carry)
0x9  SUB    RR ← RR - M (borrow → carry)
0xA  INC    RR ← RR + 1 (sets carry on overflow)
0xB  DEC    RR ← RR - 1 (borrow → carry)
0xC  STO    M ← RR (does NOT modify RR)
0xD  STOC   M ← !RR
0xE  SET    RR ← 0xFF
0xF  CLR    RR ← 0x00
```

## Hex output

Each microword is emitted by the assembler as **12 hex digits** (48 bits) in `.mem` files:

```
064003FFF800  // 039: STO [UART_DATA]
```

Format: `{:012X}`. Leading zeros are kept for visual alignment.

## Discrete hardware mapping

48 bits = 6 bytes. On a discrete build, the microcode ROM/SRAM is 6 parallel 8-bit chips, each delivering one byte. For writable-microcode (STC upgrade), each compiled instruction is 6 byte-writes over MMIO — clean alignment, no awkward bit packing.

On FPGA (Lattice ECP5, Gowin GW2A): the 48-bit width fits neatly in standard BRAM slices (typically 36-bit + parity, or 18×3 = 54 bits). No waste.
