( RC4 stream cipher on the MC14500                                  )
( Wikipedia test vector: Key="Key" encrypts "Plaintext" to           )
( BB F3 16 E8 D9 40 AF 0A D3                                         )
( Run: cat asm/demo/demo_rc4.fth | make run PROGRAM=asm/forth.asm    )

VARIABLE KLEN              ( key length )
VARIABLE KJ                ( KSA's j )
VARIABLE RI                ( PRGA's i )
VARIABLE RJ                ( PRGA's j )
VARIABLE TI                ( SSWAP temps )
VARIABLE TJ

( S[] lives at 0x0300-0x03FF — use full 16-bit C@ / C! )
: S@  3 SWAP C@ ;
: S!  3 SWAP C! ;

: SSWAP   ( i j -- )        ( swap S[i] and S[j] via temp vars )
  TJ ! TI !
  TI @ S@  TJ @ S@
  TI @ S!
  TJ @ S! ;

( Key lives at RAM[48..55] -- page 0, accessed via byte @ / ! )
( Avoid 0x24-0x2F where VARIABLEs sit — they'd clobber key bytes. )
: SETKEY3   ( b0 b1 b2 -- )     3 KLEN ! 50 ! 49 ! 48 ! ;

( Hex byte printer )
: HNIB  15 AND DUP 10 < IF 48 + ELSE 55 + THEN EMIT ;
: .HX   DUP 2/ 2/ 2/ 2/ HNIB  HNIB  SPACE ;

( Key Scheduling: S[i]=i; j=0; for i: j+=S[i]+key[i%klen]; swap S[i],S[j] )
: KSA
  0 BEGIN DUP DUP S! 1+ DUP 0= UNTIL DROP
  0 KJ !
  0 BEGIN
     DUP S@
     OVER KLEN @ MOD 48 + @
     + KJ @ +  KJ !
     DUP KJ @ SSWAP
     1+ DUP 0= UNTIL DROP
  0 RI !  0 RJ ! ;

( PRGA: i+=1; j+=S[i]; swap S[i],S[j]; output S[(S[i]+S[j])&0xFF] )
: RC4BYTE   ( -- k )
  RI @ 1+ RI !
  RI @ S@  RJ @ +  RJ !
  RI @ RJ @ SSWAP
  RI @ S@  RJ @ S@  +  S@ ;

: ENC   ( plain -- cipher )   RC4BYTE XOR ;

( --- Run the Wikipedia vector --- )
75 101 121 SETKEY3      ( Key = "Key" )
KSA

." Encrypt Plaintext: "
 80 ENC .HX  108 ENC .HX   97 ENC .HX  105 ENC .HX  110 ENC .HX
116 ENC .HX  101 ENC .HX  120 ENC .HX  116 ENC .HX
CR
." Expected:          BB F3 16 E8 D9 40 AF 0A D3 " CR

( --- Round-trip: re-keying and decrypting should give back plaintext --- )
75 101 121 SETKEY3 KSA
." Decrypt cipher:    "
187 ENC .HX  243 ENC .HX   22 ENC .HX  232 ENC .HX  217 ENC .HX
 64 ENC .HX  175 ENC .HX   10 ENC .HX  211 ENC .HX
CR
." Expected ASCII:    50 6C 61 69 6E 74 65 78 74 " CR
." (50 6C 61 69 6E 74 65 78 74 = P l a i n t e x t) " CR
