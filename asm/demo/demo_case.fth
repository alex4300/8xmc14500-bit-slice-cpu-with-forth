( CASE / OF / ENDOF / ENDCASE verification tests                  )
( Run: cat asm/demo/demo_case.fth | make run PROGRAM=asm/forth.asm )

( --- Basic dispatch --- )
: T1 CASE 1 OF 11 . ENDOF 2 OF 22 . ENDOF 99 . ENDCASE ;
." 1 T1 exp 11:    " 1 T1 CR
." 2 T1 exp 22:    " 2 T1 CR
." 5 T1 exp 99:    " 5 T1 CR

( --- Default uses case-val (still on stack via DUP) --- )
: T2 CASE 65 OF ." A " ENDOF 66 OF ." B " ENDOF DUP . ." ?" ENDCASE ;
." 65→A 66→B 77→77?:  " 65 T2 66 T2 77 T2 CR

( --- Nested CASE --- )
: INNER CASE 10 OF ." X " ENDOF 20 OF ." Y " ENDOF ." z " ENDCASE ;
: OUTER CASE 1 OF 10 INNER ENDOF 2 OF 20 INNER ENDOF ." ?" ENDCASE ;
." OUTER 1=X 2=Y 9=?:  " 1 OUTER 2 OUTER 9 OUTER CR

( --- CASE inside DO+LEAVE: confirms lvh save/restore --- )
: T4 10 0 DO I . I 5 = IF LEAVE THEN I CASE 2 OF ." [2] " ENDOF 4 OF ." [4] " ENDOF ENDCASE LOOP ;
." DO+LEAVE+CASE  exp 0 1 2 [2] 3 4 [4] 5: " T4 CR

CR ." done." CR
