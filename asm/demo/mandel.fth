\ Mandelbrot, 8.8 signed fixed-point, uses ROM-builtin UM16* and F*.
\ Upload:  python3 tools/upload_blocks.py <port> asm/demo/mandel.fth --start 100 --safe-split
\ Run:     100 LOAD
\ Parameters: STEP-X = 768 / WIDTH,  STEP-Y = 512 / HEIGHT
64 CONSTANT WIDTH    12 CONSTANT STEP-X
32 CONSTANT HEIGHT   16 CONSTANT STEP-Y
15 CONSTANT MAXITER

VARIABLE ZX_LO VARIABLE ZX_HI
VARIABLE ZY_LO VARIABLE ZY_HI
VARIABLE CX_LO VARIABLE CX_HI
VARIABLE CY_LO VARIABLE CY_HI
VARIABLE ZX2_LO VARIABLE ZX2_HI
VARIABLE ZY2_LO VARIABLE ZY2_HI
VARIABLE ZXY_LO VARIABLE ZXY_HI
VARIABLE ESC VARIABLE ITER

: ZX@ ZX_LO @ ZX_HI @ ;   : ZY@ ZY_LO @ ZY_HI @ ;
: CX@ CX_LO @ CX_HI @ ;   : CY@ CY_LO @ CY_HI @ ;
: ZX! ZX_HI ! ZX_LO ! ;   : ZY! ZY_HI ! ZY_LO ! ;
: CX! CX_HI ! CX_LO ! ;   : CY! CY_HI ! CY_LO ! ;

\ z = z^2 + c  — split across three helpers so each fits in a block.
: MS1 ZX@ ZX@ F* ZX2_HI ! ZX2_LO ! ZY@ ZY@ F* ZY2_HI ! ZY2_LO ! ZX@ ZY@ F* ZXY_HI ! ZXY_LO ! ;
: MS2 ZX2_LO @ ZX2_HI @ ZY2_LO @ ZY2_HI @ D- CX@ D+ ZX! ;
: MS3 ZXY_LO @ ZXY_HI @ 2DUP D+ CY@ D+ ZY! ;
: MSTEP MS1 MS2 MS3 ;

\ Escape: |z|^2 >= 4  <=>  hi byte of (zx^2 + zy^2) >= 4
: ESC? ZX2_LO @ ZX2_HI @ ZY2_LO @ ZY2_HI @ D+ SWAP DROP 3 U< 0= ;
: MCHAR DUP MAXITER = IF DROP 32 ELSE 33 + THEN ;

: MITER 0 ESC ! 0 ITER ! 0 0 ZX! 0 0 ZY!
  BEGIN ITER @ MAXITER U< ESC @ 0= AND WHILE
    MSTEP ESC? IF 1 ESC ! THEN ITER @ 1+ ITER !
  REPEAT ITER @ ;

: NEXT-CX CX@ STEP-X 0 D+ CX! ;
: NEXT-CY CY@ STEP-Y 0 D+ CY! ;

: MANDEL CR 0 255 CY!
  HEIGHT 0 DO 0 254 CX!
    WIDTH 0 DO MITER MCHAR EMIT NEXT-CX LOOP
    CR NEXT-CY
  LOOP ;
