( Mandelbrot in 8.8 signed fixed-point )
( Run: cat asm/demo/demo_mandel.fth | make run PROGRAM=asm/forth.asm )

( --- 16x16 unsigned multiply with shift-right-8 --- )
( Input: ( al ah bl bh ) all unsigned bytes, representing a = ah:al, b = bh:bl )
( Output: middle 16 bits of 32-bit product, as ( r_lo r_hi ) )

VARIABLE AL VARIABLE AH VARIABLE BL VARIABLE BH
VARIABLE P1 VARIABLE P2 VARIABLE P3

( +C: 8-bit add with carry-out. ( a b -- carry sum )  sum on top )
: +C  0 SWAP 0 D+ SWAP ;

( ADD1: add n to byte P1, propagate carry to P2, P3 )
: ADD1  P1 @ +C P1 !
  P2 @ +C P2 !
  P3 @ + P3 ! ;

( ADD2: add n to byte P2, propagate carry to P3 )
: ADD2  P2 @ +C P2 !
  P3 @ + P3 ! ;

( ADD3: add n to byte P3, ignore further carry )
: ADD3  P3 @ + P3 ! ;

: UM16* ( al ah bl bh -- r_lo r_hi )
  BH ! BL ! AH ! AL !
  0 P1 !  0 P2 !  0 P3 !
  ( p0 = AL*BL -> bytes 0,1; we only keep byte 1 as initial P1 )
  AL @ BL @ UM*  ( p0_lo p0_hi )  NIP  P1 !
  ( p1 = AL*BH -> bytes 1,2 )
  AL @ BH @ UM*  ( p1_lo p1_hi )
  SWAP ADD1 ADD2
  ( p2 = AH*BL -> bytes 1,2 )
  AH @ BL @ UM*  ( p2_lo p2_hi )
  SWAP ADD1
  ADD2
  ( p3 = AH*BH -> bytes 2,3 )
  AH @ BH @ UM*  ( p3_lo p3_hi )
  SWAP ADD2
  ADD3
  ( result = (P1, P2) = middle 16 bits )
  P1 @ P2 @ ;

\ Signed 16x16 -> signed 16 with shift-right-8 (8.8 fixed-point multiply)
\ Input: ( a_lo a_hi b_lo b_hi ) signed 16-bit values
\ Output: ( r_lo r_hi ) signed 16-bit product/256
VARIABLE FSGN

\ Conditionally DNEGATE a 16-bit value if its hi byte has sign bit set.
\ Return abs value + toggles FSGN if negative.
: FABS-SGN  ( lo hi -- |lo| |hi| )
  DUP 128 AND IF
    FSGN @ INVERT FSGN !
    DNEGATE
  THEN ;

: F*  ( a_lo a_hi b_lo b_hi -- r_lo r_hi )
  0 FSGN !
  FABS-SGN               \ abs(b)
  2SWAP                  \ ( |b| a_lo a_hi )
  FABS-SGN               \ abs(a)
  2SWAP                  \ ( |a| |b| )
  UM16*                  \ unsigned 16x16 >> 8
  FSGN @ IF DNEGATE THEN
  ;

\ --- tests ---
." U1: 1.0*1.0 = 1 0: " 0 1 0 1 UM16* . . CR
." U2: 2.0*2.0 = 4 0: " 0 2 0 2 UM16* . . CR
." U3: 1.5*2.0 = 3 0: " 128 1 0 2 UM16* . . CR
." U4: 0.5*0.5 = 64 0: " 128 0 128 0 UM16* . . CR

." S1: 1*(-1)  = 0 -1 " 0 1 0 255 F* . . CR
." S2: (-1)*(-1) = 0 1 " 0 255 0 255 F* . . CR
." S3: (-2)*2  = 0 -4 " 0 254 0 2 F* . . CR
." S4: 1.5*(-2)=0 -3 " 128 1 0 254 F* . . CR

\ --- Mandelbrot parameters ---
\ Change these 4 values to resize the render:
\   WIDTH   = columns
\   HEIGHT  = rows
\   STEP-X  = 768 / WIDTH   (cx range 3.0 in 8.8 = 768)
\   STEP-Y  = 512 / HEIGHT  (cy range 2.0 in 8.8 = 512)
24 CONSTANT WIDTH   32 CONSTANT STEP-X
12 CONSTANT HEIGHT  43 CONSTANT STEP-Y
15 CONSTANT MAXITER

\ cx start = -2.0 = 8.8 hi 254 (signed -2) lo 0
\ cy start = -1.0 = 8.8 hi 255 lo 0

VARIABLE ZX_LO VARIABLE ZX_HI
VARIABLE ZY_LO VARIABLE ZY_HI
VARIABLE CX_LO VARIABLE CX_HI
VARIABLE CY_LO VARIABLE CY_HI
VARIABLE ZX2_LO VARIABLE ZX2_HI
VARIABLE ZY2_LO VARIABLE ZY2_HI
VARIABLE ZXY_LO VARIABLE ZXY_HI

: ZX@ ZX_LO @ ZX_HI @ ;   : ZY@ ZY_LO @ ZY_HI @ ;
: CX@ CX_LO @ CX_HI @ ;   : CY@ CY_LO @ CY_HI @ ;
: ZX! ZX_HI ! ZX_LO ! ;   : ZY! ZY_HI ! ZY_LO ! ;

\ One Mandelbrot step: z = z^2 + c (uses ZX/ZY/CX/CY vars)
: MSTEP
  ZX@ ZX@ F*  ZX2_HI ! ZX2_LO !      \ zx^2
  ZY@ ZY@ F*  ZY2_HI ! ZY2_LO !      \ zy^2
  ZX@ ZY@ F*  ZXY_HI ! ZXY_LO !      \ zx*zy
  \ new_zx = zx^2 - zy^2 + cx
  ZX2_LO @ ZX2_HI @  ZY2_LO @ ZY2_HI @  D-
  CX@  D+  ZX!
  \ new_zy = 2*(zx*zy) + cy
  ZXY_LO @ ZXY_HI @  2DUP D+
  CY@  D+  ZY! ;

\ Escape test: |z|^2 > 4.0 -> hi byte of (zx^2+zy^2) >= 4
: ESC?
  ZX2_LO @ ZX2_HI @  ZY2_LO @ ZY2_HI @  D+
  SWAP DROP  3 U<  0= ;

\ Map iteration count to a character. MAXITER = in-set (space), else varied.
: MCHAR  ( iter -- char )
  DUP MAXITER = IF DROP 32 ELSE 33 + THEN ;

VARIABLE ESC  VARIABLE ITER
: CX! CX_HI ! CX_LO ! ;
: CY! CY_HI ! CY_LO ! ;

\ Compute escape count for one point (cx,cy in variables)
: MITER  ( -- iter )
  0 ESC !  0 ITER !
  0 0 ZX!  0 0 ZY!
  BEGIN ITER @ MAXITER U<  ESC @ 0=  AND WHILE
    MSTEP
    ESC? IF 1 ESC ! THEN
    ITER @ 1+ ITER !
  REPEAT
  ITER @ ;

: NEXT-CX  CX@  STEP-X 0 D+  CX! ;
: NEXT-CY  CY@  STEP-Y 0 D+  CY! ;

: MANDEL
  CR
  0 255 CY!                       \ cy = -1.0
  HEIGHT 0 DO
    0 254 CX!                     \ cx = -2.0
    WIDTH 0 DO
      MITER MCHAR EMIT
      NEXT-CX
    LOOP
    CR
    NEXT-CY
  LOOP ;

." Running MANDEL..." CR
MANDEL
." Done." CR

BYE
