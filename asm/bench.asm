; ============================================================================
; bench.asm — Performance benchmarks for MC14500 Bit-Slice CPU
; ============================================================================
;
; Three benchmarks, results stored in RAM and printed as hex.
; Run: make run PROGRAM=bench.asm < /dev/null
;
; Benchmark 1: 8x8 Multiply (shift-and-add)
;   13 * 7 = 91 (0x5B)
;
; Benchmark 2: Fibonacci(10)
;   fib(0)=0, fib(1)=1, ..., fib(10)=55 (0x37)
;
; Benchmark 3: Memory fill 32 bytes
;   Fill RAM[0x40..0x5F] with pattern (index XOR 0xAA)
;   Verify first and last byte
;
; ============================================================================

.data UART_DATA    0x7FFF
.data tmp          0x00
.data tmp2         0x01

; Multiply variables
.data mul_a        0x10        ; multiplicand
.data mul_b        0x11        ; multiplier
.data mul_result   0x12        ; result

; Fibonacci variables
.data fib_prev     0x13        ; fib(n-2)
.data fib_curr     0x14        ; fib(n-1)
.data fib_count    0x15        ; counter
.data fib_tmp      0x16

; Memory fill
.data fill_count   0x17

; ============================================================================
; Init
; ============================================================================

    LD  #0xFB
    STO [0x7FFC]                  ; SP = 0xFB
    .print "Bench:\r\n"

; ============================================================================
; Benchmark 1: 8x8 Multiply — 13 * 7 = 91
; Shift-and-add algorithm:
;   result = 0
;   while b != 0:
;     if b & 1: result += a
;     a <<= 1
;     b >>= 1
; ============================================================================

    .print "MUL "

    LD  #13
    STO [mul_a]
    LD  #7
    STO [mul_b]
    CLR
    STO [mul_result]

mul_loop:
    LD  [mul_b]
    JZ  mul_done                ; b == 0? done
    AND #0x01                   ; test LSB of b
    JZ  mul_noadd
    LD  [mul_result]
    ADD [mul_a]
    STO [mul_result]            ; result += a
mul_noadd:
    LD  [mul_a]
    SHL                         ; a <<= 1
    STO [mul_a]
    LD  [mul_b]
    SHR                         ; b >>= 1
    STO [mul_b]
    JMP mul_loop

mul_done:
    ; Print result
    LD  [mul_result]
    CALL print_hex
    .print "\r\n"

; ============================================================================
; Benchmark 2: Fibonacci(10)
; Iterative: prev=0, curr=1, repeat 10 times: tmp=curr, curr+=prev, prev=tmp
; fib(10) = 55
; ============================================================================

    .print "FIB "

    CLR
    STO [fib_prev]             ; fib(0) = 0
    LD  #1
    STO [fib_curr]             ; fib(1) = 1
    LD  #9
    STO [fib_count]            ; 9 iterations: fib(1)→fib(10)

fib_loop:
    LD  [fib_count]
    JZ  fib_done
    ; tmp = curr
    LD  [fib_curr]
    STO [fib_tmp]
    ; curr = curr + prev
    ADD [fib_prev]
    STO [fib_curr]
    ; prev = tmp
    LD  [fib_tmp]
    STO [fib_prev]
    ; count--
    LD  [fib_count]
    SUB #1
    STO [fib_count]
    JMP fib_loop

fib_done:
    LD  [fib_curr]
    CALL print_hex
    .print "\r\n"

; ============================================================================
; Benchmark 3: Memory fill 32 bytes at RAM[0x40..0x5F]
; Pattern: RAM[0x40 + i] = i XOR 0xAA
; ============================================================================

    .print "FILL "

    CLR
    STO [0x7FFD]                  ; IX = 0
    LD  #32
    STO [fill_count]

fill_loop:
    LD  [fill_count]
    JZ  fill_done
    ; value = IX XOR 0xAA
    LD  [0x7FFD]                  ; load IX
    XOR #0xAA
    STO [0x40, x]              ; store at RAM[0x40 + IX]
    ; IX++
    LD  [0x7FFD]
    ADD #1
    STO [0x7FFD]
    ; count--
    LD  [fill_count]
    SUB #1
    STO [fill_count]
    JMP fill_loop

fill_done:
    ; Verify: RAM[0x40] should be 0x00 XOR 0xAA = 0xAA
    LD  [0x40]
    CALL print_hex
    ; RAM[0x5F] should be 0x1F XOR 0xAA = 0xB5
    LD  [0x5F]
    CALL print_hex
    .print "\r\n"

; ============================================================================
; Done
; ============================================================================

    .print "Done\r\n"
    HALT

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

; --- Single hex nibble (0-F) from RR ---
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
