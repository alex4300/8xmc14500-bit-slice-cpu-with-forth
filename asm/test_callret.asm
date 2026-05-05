; test_callret.asm — test CALL/RET without wait_tx polling
; Sends 'U' via a subroutine. If this works, CALL/RET is fine and the
; wait_tx (AND+JZ) poll is the problematic path. If not, CALL/RET itself
; has a synth-specific bug.

.data UART_DATA 0x7FFF

    JMP start

start:
    CALL send_U             ; <-- uses hardware stack push/pop
    CLR
    STO [0x10]
    STO [0x11]
delay:
    LD  [0x10]
    INC
    STO [0x10]
    JC  dly_hi
    JMP delay
dly_hi:
    LD  [0x11]
    INC
    STO [0x11]
    JC  start
    JMP delay

send_U:
    LD  #0x55
    STO [UART_DATA]
    RET
