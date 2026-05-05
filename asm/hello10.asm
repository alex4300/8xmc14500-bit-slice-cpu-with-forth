; ============================================================================
; hello10.asm — "10x Hello World" as STC Forth
; ============================================================================
;
; Shows what a Forth compiler would generate for:
;
;   : HELLO   ." Hello World!" CR ;
;   : MAIN    10 0 DO  HELLO  LOOP ;
;   MAIN
;
; Each Forth word compiles to a sequence of CALLs (Subroutine Threaded Code).
; The loop compiles to a counter + JZ/JMP.
;
; ============================================================================

.data UART_DATA    0x7FFF
.data tmp          0x00
.data tmp2         0x01
.data count        0x02

; ============================================================================
; Init
; ============================================================================

    LD  #0xFB
    STO [0x7FFC]                  ; SP = 0xFB

; ============================================================================
; MAIN — what ": MAIN 10 0 DO HELLO LOOP ;" compiles to
; ============================================================================

    LD  #10
    PUSH                        ; push loop count

main_loop:
    ; DO — check counter
    POP
    STO [count]
    LD  [count]
    JZ  main_done               ; 0 = done

    ; HELLO — what ": HELLO ." Hello World!" CR ;" compiles to
    CALL hello

    ; LOOP — decrement, push back, repeat
    LD  [count]
    SUB #1
    PUSH
    JMP main_loop

main_done:
    .print "Done.\r\n"
    HALT

; ============================================================================
; : HELLO   ." Hello World!" CR ;
; ============================================================================
; In STC Forth, this is a subroutine that calls primitives.

hello:
    ; ." Hello World!" — compiled as sequence of CALL f_emit_char
    CALL f_emit_H
    CALL f_emit_e
    CALL f_emit_l
    CALL f_emit_l
    CALL f_emit_o
    CALL f_emit_sp
    CALL f_emit_W
    CALL f_emit_o
    CALL f_emit_r
    CALL f_emit_l
    CALL f_emit_d
    CALL f_emit_ex

    ; CR
    CALL f_cr
    RET

; ============================================================================
; Character emit primitives — what ." compiles each char to
; ============================================================================
; In a real Forth these would be inline LD #imm + STO [UART],
; but showing them as CALLs demonstrates the STC pattern.
; A smarter compiler would inline these.

f_emit_H:   LD #0x48
            STO [UART_DATA]
            RET
f_emit_e:   LD #0x65
            STO [UART_DATA]
            RET
f_emit_l:   LD #0x6C
            STO [UART_DATA]
            RET
f_emit_o:   LD #0x6F
            STO [UART_DATA]
            RET
f_emit_sp:  LD #0x20
            STO [UART_DATA]
            RET
f_emit_W:   LD #0x57
            STO [UART_DATA]
            RET
f_emit_r:   LD #0x72
            STO [UART_DATA]
            RET
f_emit_d:   LD #0x64
            STO [UART_DATA]
            RET
f_emit_ex:  LD #0x21
            STO [UART_DATA]
            RET

f_cr:       LD #0x0D
            STO [UART_DATA]
            LD #0x0A
            STO [UART_DATA]
            RET
