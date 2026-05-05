( Demo + verification tests for the new features:    )
( >R / R> / R@  builtins                             )
( 2SWAP  forthword                                   )
( INVERT forthword                                   )
( 3-level deep forthword nesting - HW stack >= 16    )
( Run in sim:   make rstack-demo                     )
( Run on FPGA:  flash, then type  5 LOAD             )

( --- Return-stack primitives --- )
." 5 >R R>       exp 5:       "  5 >R R> . CR
." 7 >R R@ R>    exp 7 7:     "  7 >R R@ . R> . CR
." R@ peek 3x    exp 2 2 2:   "  2 >R R@ . R@ . R> . CR

( Keep a value on the R stack while operating on data stack: )
." 10 3 -> 2*10+3  exp 23:    "  10 3 >R DUP + R> + . CR

( --- 2SWAP as a forthword --- )
." 1 2 3 4 2SWAP  exp 2 1 4 3:"  1 2 3 4 2SWAP . . . . CR

( --- INVERT as a forthword. do_dot prints signed decimal. --- )
." 0   INVERT    exp -1:      "  0   INVERT . CR
." 255 INVERT    exp 0:       "  255 INVERT . CR
." 42  INVERT    exp -43:     "  42  INVERT . CR

( --- Deep nesting: HI calls MI calls LI calls 1+ . )
( LI itself is a user word, 1+ is a forthword, so HI goes 4 deep )
( through user-word tokens. Fails on HW stack depth 8. )
: LI 1+ ;
: MI LI LI LI ;
: HI MI MI MI ;
." 5 HI = 5+9    exp 14:      "  5 HI . CR

( --- 2SWAP compiled into another user word --- )
: FROB 2SWAP + + + ;
." 1 2 3 4 FROB  exp 10:      "  1 2 3 4 FROB . CR

( --- Factorial, exercises BEGIN/WHILE/REPEAT + * --- )
: F 1 SWAP BEGIN DUP 1 U< NOT WHILE SWAP OVER * SWAP 1- REPEAT DROP ;
." 5! F          exp 120:     "  5 F . CR
." 4! F          exp 24:      "  4 F . CR

CR ." done." CR
