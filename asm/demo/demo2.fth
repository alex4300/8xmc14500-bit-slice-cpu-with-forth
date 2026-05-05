( ============================================== )
( MC14500 Forth Demo 2 - Fibonacci & Primes     )
( Exercises: VARIABLE @ ! > + MOD /MOD = NOT    )
( BEGIN WHILE REPEAT IF THEN DUP OVER SWAP U<   )
( ============================================== )

VARIABLE A
VARIABLE B

: FIB
  0 A ! 1 B !
  BEGIN DUP 0 > WHILE
    1- B @ DUP A @ + B ! A !
  REPEAT DROP A @
;

10 FIB .
13 FIB .

( --- Prime checker using trial division --- )

VARIABLE N
VARIABLE R

: P?
  N ! 1 R !
  N @ 2 U< IF 0 R ! THEN
  N @ 2 U< NOT N @ 2 = NOT AND IF
    N @ 2 / 1+ 2
    BEGIN OVER OVER SWAP U< WHILE
      N @ OVER MOD 0= IF 0 R ! THEN
      1+
    REPEAT DROP DROP
  THEN R @
;

: PS
  2 BEGIN OVER OVER SWAP U< WHILE
    DUP P? IF DUP . THEN
    1+
  REPEAT DROP DROP
;

30 PS

( --- Constant and min/max demo --- )
42 CONSTANT LIFE
LIFE .
3 7 MIN .
3 7 MAX .
5 ABS .
200 ABS .
