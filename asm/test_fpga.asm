; test_fpga.asm — Minimal FPGA test: sends 'H' 'i' '!' CR in a loop
; Tests: ROM init + CPU execution + UART TX
; Polls UART_STATUS bit 0 (TX ready) before each write.

.data UART_STATUS 0x7FFE
.data UART_DATA   0x7FFF

    JMP start

start:
    LD  #0x48               ; 'H'
    CALL emit
    LD  #0x69               ; 'i'
    CALL emit
    LD  #0x21               ; '!'
    CALL emit
    LD  #0x0A               ; newline
    CALL emit
    JMP start

; emit: send byte in RR to UART, wait for TX ready first
emit:
    STO [0x00]              ; save char in RAM[0]
wait_tx:
    LD  [UART_STATUS]
    AND #0x01               ; bit 0 = TX ready
    JZ  wait_tx
    LD  [0x00]
    STO [UART_DATA]
    RET
