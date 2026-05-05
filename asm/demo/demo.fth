( MC14500 Forth Demo - Exercises most of the 64-word vocabulary )
( Run: make run PROGRAM=forth.asm < demo.fth                   )
( Note: output values are hexadecimal                          )

( --- Factorial: * SWAP OVER 1- BEGIN WHILE REPEAT NOT U< --- )
: FACT 1 SWAP BEGIN DUP 1 U< NOT WHILE SWAP OVER * SWAP 1- REPEAT DROP ;
5 FACT . 6 FACT . 7 FACT . CR

( --- Fibonacci: VARIABLE @ ! > + BEGIN WHILE REPEAT 1- --- )
VARIABLE A
VARIABLE B
: FIB 0 A ! 1 B ! BEGIN DUP 0 > WHILE 1- B @ DUP A @ + B ! A ! REPEAT DROP A @ ;
10 FIB . 13 FIB . CR

( --- MIN MAX ABS --- )
3 7 MIN . 3 7 MAX . 5 ABS . 200 ABS . CR

( --- CONSTANT --- )
42 CONSTANT LIFE
LIFE .
CR

( --- .S DEPTH --- )
1 2 3 .S CR

( --- WORDS: list all 64+ words --- )
WORDS
