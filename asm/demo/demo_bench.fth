( Micro-benchmarks — read total cycle count from the emulator's  )
( "Input exhausted after N cycles" message at the end.            )
( Each defines a 10000-iter nested DO loop, then runs ONE of them.)
ADD16
: EMPTY-LOOP 255 0 DO 255 0 DO LOOP LOOP ." empty-done " ;
: MUL8       100 0 DO 100 0 DO I I *   DROP  LOOP LOOP ." mul8-done "  ;
: MUL16      100 0 DO 100 0 DO I I UM* 2DROP LOOP LOOP ." mul16-done " ;
: ADD16      100 0 DO 100 0 DO 1 0 3 0 D+ 2DROP LOOP LOOP ." add16-done " ;
ADD16
( Pick one to run )
ADD16
ADD16
