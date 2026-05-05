; ============================================================================
; bench_forth.asm — Same benchmarks as bench.asm, but STC Forth style
; ============================================================================
;
; Each operation uses CALL to Forth primitive subroutines.
; Compare cycle counts with bench.asm (raw assembly) to measure
; the overhead of subroutine threading.
;
; ============================================================================

.data UART_DATA    0x7FFF
.data tmp          0x00
.data tmp2         0x01
.data mul_tmp      0x10
.data fib_tmp      0x11
.data count        0x12

; ============================================================================
; Init
; ============================================================================

    LD  #0xFB
    STO [0x7FFC]                  ; SP = 0xFB
    .print "Forth Bench:\r\n"

; ============================================================================
; Benchmark 1: MUL 13*7 using Forth stack primitives
; ============================================================================
;
; Algorithm (stack-based):
;   Push 0 (result), 13 (a), 7 (b) — manage on stack + RAM
;   Loop: if b==0 done; if b&1: result+=a; a<<=1; b>>=1
;
; We keep result in RAM, a and b on stack: ( a b )

    .print "MUL "

    CLR
    STO [mul_tmp]               ; result = 0
    LD  #13
    PUSH                        ; ( 13 )
    LD  #7
    PUSH                        ; ( 13 7 )

mul_f_loop:
    ; Check b (TOS)
    CALL f_dup                  ; ( a b b )
    POP                         ; RR = b
    JZ  mul_f_done

    ; Test LSB of b: b AND 1
    CALL f_dup                  ; ( a b b )
    LD  #0x01
    PUSH                        ; ( a b b 1 )
    CALL f_and                  ; ( a b b&1 )
    POP                         ; RR = b&1
    JZ  mul_f_noadd

    ; result += a — need to peek a (second on stack)
    LD  [0x7E01, s]             ; peek a (under b)
    ADD [mul_tmp]
    STO [mul_tmp]               ; result += a

mul_f_noadd:
    ; b >>= 1
    POP                         ; RR = b
    SHR
    PUSH                        ; ( a b>>1 )

    ; a <<= 1
    CALL f_swap                 ; ( b>>1 a )
    POP                         ; RR = a
    SHL
    PUSH                        ; ( b>>1 a<<1 )
    CALL f_swap                 ; ( a<<1 b>>1 )

    JMP mul_f_loop

mul_f_done:
    CALL f_drop                 ; drop b
    CALL f_drop                 ; drop a
    LD  [mul_tmp]
    CALL print_hex
    .print "\r\n"

; ============================================================================
; Benchmark 2: FIB(10) using Forth stack primitives
; ============================================================================
;
; Stack: ( prev curr ), counter in RAM
; Loop body: save curr, CALL f_plus (consumes both, pushes sum),
;            push saved curr, CALL f_swap → ( new_prev new_curr )

    .print "FIB "

    CLR
    PUSH                        ; ( 0 ) = prev
    LD  #1
    PUSH                        ; ( 0 1 ) = prev curr
    LD  #10
    STO [count]

fib_f_loop:
    LD  [count]
    JZ  fib_f_done

    ; Save curr for later (becomes new prev)
    LD  [0x7E00, s]             ; peek curr (TOS)
    STO [fib_tmp]

    ; curr + prev → new_curr (consumes both stack values)
    CALL f_plus                 ; ( prev+curr )

    ; Push old curr as new prev
    LD  [fib_tmp]
    PUSH                        ; ( new_curr old_curr )
    CALL f_swap                 ; ( old_curr new_curr ) = ( new_prev new_curr )

    ; count--
    LD  [count]
    SUB #1
    STO [count]
    JMP fib_f_loop

fib_f_done:
    POP                         ; RR = fib(10)
    CALL f_drop                 ; drop prev
    CALL print_hex
    .print "\r\n"

; ============================================================================
; Benchmark 3: FILL 32 bytes using Forth-style indexed write
; ============================================================================
;
; Same as raw version — IX-indexed loop doesn't benefit from
; stack threading, so this measures the "floor" overhead.

    .print "FILL "

    CLR
    STO [0x7FFD]                  ; IX = 0
    LD  #32
    STO [count]

fill_f_loop:
    LD  [count]
    JZ  fill_f_done
    LD  [0x7FFD]
    XOR #0xAA
    STO [0x40, x]
    LD  [0x7FFD]
    ADD #1
    STO [0x7FFD]
    LD  [count]
    SUB #1
    STO [count]
    JMP fill_f_loop

fill_f_done:
    LD  [0x40]
    CALL print_hex
    LD  [0x5F]
    CALL print_hex
    .print "\r\n"

; ============================================================================
; Done
; ============================================================================

    .print "Done\r\n"
    HALT

; ============================================================================
; Forth Primitives (CALLable subroutines)
; ============================================================================

f_dup:                          ; ( a -- a a )
    LD  [0x7E00, s]
    PUSH
    RET

f_drop:                         ; ( a -- )
    POP
    RET

f_swap:                         ; ( a b -- b a )
    POP
    STO [tmp]
    POP
    STO [tmp2]
    LD  [tmp]
    PUSH
    LD  [tmp2]
    PUSH
    RET

f_over:                         ; ( a b -- a b a )
    LD  [0x7E01, s]
    PUSH
    RET

f_plus:                         ; ( a b -- a+b )
    POP
    STO [tmp]
    POP
    ADD [tmp]
    PUSH
    RET

f_minus:                        ; ( a b -- a-b )
    POP
    STO [tmp]
    POP
    SUB [tmp]
    PUSH
    RET

f_and:                          ; ( a b -- a&b )
    POP
    STO [tmp]
    POP
    AND [tmp]
    PUSH
    RET

; ============================================================================
; print_hex — Print RR as 2 hex digits (subroutine)
; ============================================================================
print_hex:
    STO [tmp]
    SHR
    SHR
    SHR
    SHR
    CALL print_nib
    LD  [tmp]
    AND #0x0F
    CALL print_nib
    LD  #0x20
    STO [UART_DATA]
    RET

print_nib:
    STO [tmp2]
    SUB #0x0A
    JC  pn_dec
    ADD #0x41
    STO [UART_DATA]
    RET
pn_dec:
    LD  [tmp2]
    ADD #0x30
    STO [UART_DATA]
    RET
