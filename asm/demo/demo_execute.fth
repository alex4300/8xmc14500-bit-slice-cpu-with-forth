( EXECUTE / '  verification tests                                  )
( Run: cat asm/demo/demo_execute.fth | make run PROGRAM=asm/forth.asm )

( --- ' on builtin, run via EXECUTE --- )
." 2 3 ' + EXECUTE .   exp 5: " 2 3 ' + EXECUTE . CR

( --- ' on user word --- )
: SQ DUP * ;
." 6 ' SQ EXECUTE .    exp 36: " 6 ' SQ EXECUTE . CR

( --- APPLY: take an xt as the word's "argument" --- )
: APPLY EXECUTE ;
." 8 ' SQ APPLY .      exp 64: " 8 ' SQ APPLY . CR

( --- ' on EMIT, prints char --- )
." 65 ' EMIT EXECUTE   exp A: " 65 ' EMIT EXECUTE CR

( --- ' inside a colon is RUNTIME-tick: reads next input word at execution.    )
( --- Useful at the REPL for "apply this xt to that arg" style.               )
( --- For compile-time xt embedding you'd want ['] (not implemented yet).      )

CR ." done." CR
