( Cooperative-multitasking demo - Stage-1 PAUSE/TASK.             )
( task0 = foreground COUNTDOWN that prints every step.            )
( task1 = background HEARTBEAT that emits one '.' per slot.       )
( Both share VAR N for shutdown signalling.  task1 is an          )
( infinite loop - when task0 reaches 0 it returns to interp,      )
( task1 stays dormant - PAUSE no-op once nobody else calls it.    )
( Run in sim:  make run PROGRAM=forth.asm < asm/demo/demo_pause.fth )

VARIABLE N
10 N !

( background - fires one '.' between every COUNTDOWN line forever )
: HEARTBEAT  BEGIN  46 EMIT  PAUSE  0 UNTIL ;

( foreground - prints N decrements PAUSEs to give task1 a slot    )
: COUNTDOWN
  BEGIN
    N @ .            ( print current count )
    CR
    N @ 1 -  N !     ( decrement N )
    PAUSE            ( yield to task1 )
    N @  0 =
  UNTIL ;

: BANNER  ." -- PAUSE demo: countdown 10..1 with heartbeat --" CR ;
: REPORT  ." -- done.  N=" N @ . ."  task1 still dormant. --" CR ;

BANNER
' HEARTBEAT TASK
COUNTDOWN
REPORT
