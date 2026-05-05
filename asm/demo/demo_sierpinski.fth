( MC14500 Forth Demo - Sierpinski Triangle Fractal )
( Run: make run PROGRAM=forth.asm < demo_sierpinski.fth )
( Uses: VARIABLE @ ! AND 0= IF ELSE THEN BEGIN WHILE REPEAT )
(       DUP U< EMIT CR 1+ DROP                              )

VARIABLE Y
: SIERP
  16 0 BEGIN DUP 16 U< WHILE
    DUP Y !
    16 0 BEGIN DUP 16 U< WHILE
      DUP Y @ AND 0= IF 42 EMIT ELSE 32 EMIT THEN
    1+ REPEAT DROP DROP
    CR
  1+ REPEAT DROP ;
SIERP
