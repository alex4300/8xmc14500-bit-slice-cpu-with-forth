( DO / LOOP / I verification tests                                )
( Run in sim:  cat asm/demo/demo_doloop.fth | make run PROGRAM=asm/forth.asm )

( --- Basic count 0..4 --- )
: T1 5 0 DO I . LOOP ;
." 5 0 DO I . LOOP  exp 0 1 2 3 4:  " T1 CR

( --- Sum 1+2+...+10 via I --- )
: SUM10 0 11 1 DO I + LOOP ;
." SUM10           exp 55:         " SUM10 . CR

( --- Nested body that uses stack --- )
: STARS 0 DO 42 EMIT LOOP CR ;
." 7 STARS         exp *******:    " 7 STARS

( --- Empty body still works --- )
: NOP10 10 0 DO LOOP ;
." 10 0 DO LOOP    exp (no print): " NOP10 ." done" CR

( --- Range with non-zero start --- )
: RANGE 20 15 DO I . LOOP ;
." 20 15 DO I .    exp 15 16 17 18 19:  " RANGE CR

( --- +LOOP forward step 2 --- )
: COUNT2 10 0 DO I . 2 +LOOP ;
." 10 0 DO 2 +LOOP exp 0 2 4 6 8:    " COUNT2 CR

( --- +LOOP backward step -2 --- )
: BACK 0 10 DO I . -2 +LOOP ;
." 0 10 DO -2 +LOOP exp 10 8 6 4 2 0:" BACK CR

( --- LEAVE: early exit at I=5 --- )
: LV1 10 0 DO I . I 5 = IF LEAVE THEN LOOP ;
." LEAVE at I=5    exp 0 1 2 3 4 5:  " LV1 CR

( --- Multiple LEAVEs in same loop (3 fires first) --- )
: LV2 10 0 DO I . I 7 = IF LEAVE THEN I 3 = IF LEAVE THEN LOOP ;
." 2x LEAVE        exp 0 1 2 3:      " LV2 CR

( --- LEAVE with +LOOP --- )
: LV3 10 0 DO I . I 4 = IF LEAVE THEN 1 +LOOP ;
." LEAVE + +LOOP   exp 0 1 2 3 4:    " LV3 CR

CR ." done." CR
