; ============================================================================
; echo.asm — Interactive echo terminal for MC14500 Bit-Slice CPU
; ============================================================================

; --- I/O Ports ---
.data UART_STATUS  0x7FFE        ; bit 0: TX ready, bit 1: RX available
.data UART_DATA    0x7FFF        ; read: RX byte, write: TX byte

; --- RAM variables ---
.data rx_char      0x80        ; received character

; ============================================================================
; Welcome message
; ============================================================================

    .print "multi-mp14k5 ready.\r\n"
    .print "> "

; ============================================================================
; Main loop: poll for input, echo it back
; ============================================================================

poll:
    LD  [UART_STATUS]           ; read status register
    AND #0x02                   ; mask bit 1 (RX available)
    JZ  poll                    ; loop until character ready

    LD  [UART_DATA]             ; read received character
    STO [rx_char]               ; save for comparison
    STO [UART_DATA]             ; echo it back

    ; Check if CR (0x0D) → also send LF
    LD  [rx_char]
    XOR #0x0D                   ; compare with CR
    JZ  send_lf

    JMP poll

send_lf:
    LD  #0x0A                   ; LF
    STO [UART_DATA]
    JMP poll
