\ Stage-2 STOP demo - both tasks terminate gracefully via STOP.
\ Compared to demo_pause: heartbeat is bounded - stops when N=0
\ - instead of running infinite. STOP marks the task stopped; when
\ the OTHER task is also stopped, STOP aborts cleanly back to interp.
\ Run in sim:  make run PROGRAM=forth.asm < asm/demo/demo_stop.fth

VARIABLE N
10 N !

\ background - heartbeat while countdown is running
: HEARTBEAT  BEGIN  46 EMIT  PAUSE  N @ 0 =  UNTIL  STOP ;

\ foreground - countdown 10..1, then signal done by setting N=0
: COUNTDOWN
  BEGIN
    N @ .  CR
    N @ 1 -  N !
    PAUSE
    N @ 0 =
  UNTIL  STOP ;

: BANNER  ." -- STOP demo: countdown 10..1 with bounded heartbeat --" CR ;
: REPORT  ." -- both tasks STOPped, system back at prompt --" CR ;

BANNER
' HEARTBEAT TASK
COUNTDOWN
REPORT
