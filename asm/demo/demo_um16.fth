( UM16* sanity tests — expected values are hex )
( Stack: al ah bl bh  -- p_lo p_hi   = bits 8..23 of 32-bit product )

( 1.0 * 1.0 = 1.0  -> p_lo=0 p_hi=1 )
." 1x1: " 0 1 0 1 UM16* . . CR

( 2.0 * 2.0 = 4.0  -> 0 4 )
." 2x2: " 0 2 0 2 UM16* . . CR

( 1.5 * 2.0 = 3.0  -> 0 3 )
." 1.5x2: " 128 1 0 2 UM16* . . CR

( 0.5 * 0.5 = 0.25 -> 64 0 )
." 0.5x0.5: " 128 0 128 0 UM16* . . CR

( 3.0 * 3.0 = 9.0  -> 0 9 )
." 3x3: " 0 3 0 3 UM16* . . CR

( 0xFFFF * 0xFFFF = 0xFFFE0001 -> mid 16 = 0xFEFF -> p_lo=FF p_hi=FE )
." max^2: " 255 255 255 255 UM16* . . CR

( 100.0 * 100.0 = 10000.0  100*256=25600=0x6400  sq=0x27100000 mid16=0x2710 )
." 100x100: " 0 100 0 100 UM16* . . CR
BYE
