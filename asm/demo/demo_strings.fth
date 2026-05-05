( S" / TYPE / COUNT verification tests                              )
( Run: cat asm/demo/demo_strings.fth | make run PROGRAM=asm/forth.asm )

( --- Basic string literal inside a colon definition --- )
: HELLO S" Hello, World!" TYPE CR ;
." basic:          " HELLO

( --- Pass a string to a consumer --- )
: WITHGREET TYPE ;
." via TYPE:       " S" MC14500 " WITHGREET S" Forth" WITHGREET CR

( --- String length exposed via NIP NIP --- )
." length of MC14500: " S" MC14500" NIP NIP . CR

( --- Build a counted-string pointer, use COUNT to unpack it --- )
: CPTR S" COUNTED" DROP 1- ;
." COUNT round-trip: " CPTR COUNT TYPE CR

CR ." done." CR
