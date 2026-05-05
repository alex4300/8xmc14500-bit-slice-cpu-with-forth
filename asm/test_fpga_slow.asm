; test_fpga_slow.asm — send "Hi!\n" once every ~50 ms (instead of max rate)
; Uses wait_tx polling like test_fpga.asm but adds a delay between messages
; so CH340/terminal doesn't get overrun.

.data UART_STATUS 0x7FFE
.data UART_DATA   0x7FFF
.data DELAY_LO    0x10
.data DELAY_HI    0x11

    JMP start

start:
    LD  #0x48
    CALL emit
    LD  #0x69
    CALL emit
    LD  #0x21
    CALL emit
    LD  #0x0A
    CALL emit

    ; Delay loop between messages (~50 ms)
    CLR
    STO [DELAY_LO]
    STO [DELAY_HI]
delay:
    LD  [DELAY_LO]
    INC
    STO [DELAY_LO]
    JC  dly_hi
    JMP delay
dly_hi:
    LD  [DELAY_HI]
    INC
    STO [DELAY_HI]
    JC  start
    JMP delay

; emit: send byte in RR to UART, wait for TX ready first
emit:
    STO [0x00]
wait_tx:
    LD  [UART_STATUS]
    AND #0x01
    JZ  wait_tx
    LD  [0x00]
    STO [UART_DATA]
    RET
