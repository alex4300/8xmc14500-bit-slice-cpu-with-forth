; ============================================================================
; test_cpu.asm — CPU test program (replaces hand-coded ROM in tb_cpu.v)
; ============================================================================
; Results are stored in RAM for verification by the testbench.
; All tests from the original tb_cpu.v are included.

; I/O addresses (16-bit)
.data UART_DATA    0x7FFF
.data IX_HI_REG    0x7FFB
.data IX_REG       0x7FFD
.data SP_REG       0x7FFC

; Scratch
.data tmp          0x00

; ============================================================
; Test 1-4: Original tests (ADD, INC overflow, branch, SUB)
; ============================================================

    ; Pre-loaded by testbench: RAM[0x10]=0x25, [0x11]=0x1A, [0x12]=0xFF
    ;                          [0x13]=0x50, [0x14]=0x1F, [0x15]=0x42

    LD  [0x10]                  ; load 0x25
    ADD [0x11]                  ; + 0x1A = 0x3F
    STO [0x20]                  ; → RAM[0x20] = 0x3F

    LD  [0x12]                  ; load 0xFF
    INC                         ; 0xFF + 1 = 0x00, carry=1
    STO [0x21]                  ; → RAM[0x21] = 0x00

    JC  branch_ok               ; carry set → jump
    SET                         ; (should be skipped)
    STO [0x22]                  ; (should be skipped)
branch_ok:
    LD  [0x15]                  ; load marker 0x42
    STO [0x22]                  ; → RAM[0x22] = 0x42

    LD  [0x13]                  ; load 0x50
    SUB [0x14]                  ; - 0x1F = 0x31
    STO [0x23]                  ; → RAM[0x23] = 0x31

; ============================================================
; Test 5-8: Immediate mode
; ============================================================

    LD  #0xAB
    STO [0x24]                  ; → 0xAB

    ADD #0x05                   ; 0xAB + 0x05 = 0xB0
    STO [0x25]                  ; → 0xB0

    AND #0x0F                   ; 0xB0 & 0x0F = 0x00
    STO [0x26]                  ; → 0x00

    XOR #0x00                   ; 0x00 ^ 0x00 = 0x00, Z=1
    JZ  imm_z_ok
    SET                         ; (skipped)
imm_z_ok:
    SUB #0x01                   ; 0x00 - 0x01 = 0xFF
    STO [0x27]                  ; → 0xFF

; ============================================================
; Test 9-12: Shift/Rotate
; ============================================================

    LD  #0xA5                   ; 10100101
    SHL                         ; 01001010, carry=1
    STO [0x28]                  ; → 0x4A

    SHR                         ; 00100101, carry=0
    STO [0x29]                  ; → 0x25

    ROL                         ; 01001010 (carry was 0), carry=0
    STO [0x2A]                  ; → 0x4A

    LD  #0x81                   ; 10000001
    SHR                         ; 01000000, carry=1
    ROR                         ; 10100000 (carry=1 rotates in), carry=0
    STO [0x2B]                  ; → 0xA0

; ============================================================
; Test 13-14: Index register
; ============================================================

    LD  #0x02
    STO [IX_REG]                ; IX = 2
    LD  [0x40, x]               ; RAM[0x40+2] = RAM[0x42] (pre-loaded 0x77)
    STO [0x2C]                  ; → 0x77

    LD  #0x55
    STO [0x43, x]               ; RAM[0x43+2] = RAM[0x45] = 0x55
    LD  [0x45]
    STO [0x2D]                  ; → 0x55

; ============================================================
; Test 15-16: 15-bit IX via IX_HI register
; ============================================================

    ; Test 15: Read via 15-bit IX
    LD  #0x01
    STO [IX_HI_REG]             ; IX_HI = 1
    CLR
    STO [IX_REG]                ; IX_LO = 0 → effective IX = 0x0100
    LD  [0x0000, x]             ; RAM[0 + 0x0100] = RAM[0x0100] (pre-loaded 0xCC)
    STO [0x33]                  ; → 0xCC

    ; Test 16: Write via 15-bit IX
    LD  #0xDD
    STO [0x0000, x]             ; RAM[0x0100] = 0xDD
    LD  [0x0100]                ; read back directly (no IX)
    STO [0x34]                  ; → 0xDD

    ; Reset IX_HI for remaining tests
    CLR
    STO [IX_HI_REG]

; ============================================================
; Test 17-21: Stack pointer + PUSH/POP + indirect jump
; ============================================================

    LD  #0x9F
    STO [SP_REG]                ; SP = 0x9F

    LD  #0xAA
    PUSH                        ; SP→0x9E, RAM[0x7E9E]=0xAA
    LD  #0xBB
    PUSH                        ; SP→0x9D, RAM[0x7E9D]=0xBB

    LD  [0x7E01, s]             ; peek second: RAM[0x7E01+0x9D] = RAM[0x7E9E] = 0xAA
    STO [0x2E]                  ; → 0xAA

    POP                         ; RR=0xBB, SP→0x9E
    STO [0x2F]                  ; → 0xBB

    POP                         ; RR=0xAA, SP→0x9F
    STO [0x30]                  ; → 0xAA

    LD  [SP_REG]                ; SP should be 0x9F again
    STO [0x31]                  ; → 0x9F

    ; Indirect jump
    LD  #jmpi_target
    JMPI                        ; jump to RR
    SET                         ; (should be skipped)
jmpi_target:
    LD  #0xEE
    STO [0x32]                  ; → 0xEE

    HALT
