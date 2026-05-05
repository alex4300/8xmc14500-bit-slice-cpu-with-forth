; test_and_jz.asm — test AND + JZ path (polling pattern)
; Counts down a known-value register with AND + JZ instead of INC + JC.
; If this produces U's, AND + JZ works. If not, that's the bug.

.data UART_DATA 0x7FFF

    JMP start

start:
    LD  #0x55
    STO [UART_DATA]

    ; Setup a 16-bit counter we'll AND-test
    LD  #0xFF
    STO [0x10]
    STO [0x11]

delay:
    ; Use AND to mask then test with JZ
    LD  [0x10]
    AND #0x01           ; isolate bit 0 → Z=1 iff bit 0 was 0
    JZ  bit0_zero       ; not really the purpose — this just exercises AND+JZ
    JMP advance_lo

bit0_zero:
advance_lo:
    LD  [0x10]
    DEC
    STO [0x10]
    JZ  dec_hi          ; when [0x10] hits 0, decrement high
    JMP delay

dec_hi:
    LD  [0x11]
    DEC
    STO [0x11]
    JZ  start           ; when [0x11] also hits 0, one full pass done
    LD  #0xFF
    STO [0x10]
    JMP delay
