\ MC14500x8 Mandelbrot, ported to durexforth (C64, 6502, 16-bit cells).
\ One cell holds one 8.8 signed fixed-point number:
\     1.0 =  256    2.0 =  512    -1.0 = -256    -2.0 = -512
\ Original values (cy_hi=255, cx_hi=254) map to -256 and -512 signed.

\ --- Signed 8.8 fixed-point multiply ---
\ |a|*|b| as unsigned 32-bit product, divide by 256 (take middle 16 bits),
\ re-apply sign. Uses only very basic words (UM*, UM/MOD, ABS, XOR, 0<).
: F* ( a b -- a*b/256 )
  2DUP XOR 0< >R                  \ R: true if result is negative
  ABS SWAP ABS UM*                \ ( d_lo d_hi ) unsigned double
  SWAP 0 256 UM/MOD NIP           \ ( d_hi  d_lo>>8 )
  SWAP 256 * +                    \ (d_hi<<8) + (d_lo>>8)
  R> IF NEGATE THEN ;

\ --- Parameters (edit to resize) ---
\ Rule: STEP-X = 768 / WIDTH,  STEP-Y = 512 / HEIGHT
32 CONSTANT WIDTH    24 CONSTANT STEP-X
16 CONSTANT HEIGHT   32 CONSTANT STEP-Y
15 CONSTANT MAXITER

\ --- Mandelbrot state ---
VARIABLE ZX   VARIABLE ZY
VARIABLE CX   VARIABLE CY
VARIABLE ZX2  VARIABLE ZY2
VARIABLE ESC  VARIABLE ITER

\ --- z_{n+1} = z_n^2 + c ---
\ Store zx^2 and zy^2 as side products (for ESC? to read after MSTEP).
: MSTEP
  ZX @ DUP F* ZX2 !               \ zx^2
  ZY @ DUP F* ZY2 !               \ zy^2
  ZX @ ZY @ F* 2* CY @ +          \ new_zy = 2*zx*zy + cy
  ZX2 @ ZY2 @ - CX @ +            \ new_zx = zx^2 - zy^2 + cx
  ZX ! ZY !                       \ store: top=new_zx, next=new_zy
;

\ |z|^2 > 4.0  ->  zx^2 + zy^2 > 1024 (= 4.0 in 8.8)
: ESC?  ZX2 @ ZY2 @ + 1023 > ;

\ Interior points (hit MAXITER) render as space; otherwise 33+iter.
: MCHAR  DUP MAXITER = IF DROP BL ELSE 33 + THEN ;

: MITER
  0 ESC ! 0 ITER ! 0 ZX ! 0 ZY !
  BEGIN ITER @ MAXITER < ESC @ 0= AND WHILE
    MSTEP  ESC? IF 1 ESC ! THEN
    ITER @ 1+ ITER !
  REPEAT
  ITER @
;

: MANDEL
  CR -256 CY !                    \ start cy = -1.0
  HEIGHT 0 DO
    -512 CX !                     \ start cx = -2.0 each row
    WIDTH 0 DO
      MITER MCHAR EMIT
      CX @ STEP-X + CX !
    LOOP
    CR
    CY @ STEP-Y + CY !
  LOOP
;

\ Type `MANDEL` to render.
\ On C64 @ 1 MHz, expect tens of seconds — compare against the 13 s
\ the MC14500x8 takes for 64x24 @ 27 MHz (or ~4 s for an equivalent 32x16).
