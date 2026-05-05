; ============================================================================
; test_uart_simple.asm — minimal UART heartbeat, no wait_tx polling
; ============================================================================
; Fires 'U' (0x55) into UART_DATA every ~24 ms, fire-and-forget.
; The delay is so long that uart_tx is always idle when the next STO hits,
; so the bridge's "!tx_busy" gate never drops a byte.
;
; 'U' = 0x55 = 0b01010101. This alternating pattern is easy to diagnose:
;   - if a bit flips, the character changes dramatically (becomes 'T', 'Q',
;     '5', 'u', ...)
;   - if framing is off by one bit, the terminal sees garbage
;
; Purpose: isolate whether AND + JZ (the wait_tx poll in test_fpga.asm) is
; the bug on FPGA. This test avoids that entirely — only LD, STO, INC, JC.
; ============================================================================

.data UART_DATA   0x7FFF
.data DELAY_LO    0x10
.data DELAY_HI    0x11

    JMP start

start:
    LD  #0x55               ; 'U' — clear alternating pattern
    STO [UART_DATA]         ; fire-and-forget

    ; --- 16-bit delay counter: 65536 * ~5 instr ≈ 12 ms ---
    CLR                     ; RR = 0
    STO [DELAY_LO]
    STO [DELAY_HI]

delay:
    LD  [DELAY_LO]
    INC                     ; INC uses carry chain; carry_out on 0xFF→0x00
    STO [DELAY_LO]
    JC  inc_hi              ; wrap → bump high byte
    JMP delay

inc_hi:
    LD  [DELAY_HI]
    INC
    STO [DELAY_HI]
    JC  start               ; full 16-bit wrap → send next byte
    JMP delay
