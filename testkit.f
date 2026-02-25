\ testkit.f -- test kit for bsky.f and its dependencies
\
\ Loaded by autoexec.f via REQUIRE testkit.f
\ Defines test words that can be called individually after boot.

PROVIDED testkit.f

\ ---- Test framework ----
VARIABLE #PASS  VARIABLE #FAIL

: T-OK     1 #PASS +! ;
: T-FAIL   1 #FAIL +!  ." FAIL: " ;
: T-EXPECT= ( got expected -- )
    2DUP = IF 2DROP T-OK ELSE
        T-FAIL ." expected " . ." got " . CR
    THEN ;

\ ---- T1: Forth sanity ----
: T-FORTH
    0 #PASS !  0 #FAIL !
    ." [T1] Forth basics" CR
    3 4 + 7 T-EXPECT=
    10 3 - 7 T-EXPECT=
    6 7 * 42 T-EXPECT=
    1 0= IF T-FAIL ." 1 0= should be false" CR ELSE T-OK THEN
    0 0= IF T-OK ELSE T-FAIL ." 0 0= should be true" CR THEN
    #PASS @ . ." passed, " #FAIL @ . ." failed" CR ;

\ ---- T2: PROVIDED guard ----
: T-REQUIRE
    0 #PASS !  0 #FAIL !
    ." [T2] PROVIDED guard" CR
    \ If we are running, REQUIRE testkit.f worked
    T-OK
    #PASS @ . ." passed, " #FAIL @ . ." failed" CR ;

\ ---- T3: Memory ops ----
CREATE _TM-BUF 16 ALLOT
: T-MEMORY
    0 #PASS !  0 #FAIL !
    ." [T3] Memory ops" CR
    _TM-BUF 16 0 FILL
    _TM-BUF C@ 0 T-EXPECT=
    65 _TM-BUF C!
    _TM-BUF C@ 65 T-EXPECT=
    S" Hi" _TM-BUF 2 CMOVE
    _TM-BUF C@ 72 T-EXPECT=
    _TM-BUF 1+ C@ 105 T-EXPECT=
    #PASS @ . ." passed, " #FAIL @ . ." failed" CR ;

\ ---- T4: Stack ops ----
: T-STACK
    0 #PASS !  0 #FAIL !
    ." [T4] Stack ops" CR
    1 2 SWAP 1 T-EXPECT=  DROP
    5 DUP + 10 T-EXPECT=
    1 2 3 ROT 1 T-EXPECT=  2DROP
    7 8 OVER 7 T-EXPECT=  2DROP
    #PASS @ . ." passed, " #FAIL @ . ." failed" CR ;

\ ---- T5: String basics ----
: T-STRING
    0 #PASS !  0 #FAIL !
    ." [T5] String basics" CR
    S" hello" NIP 5 T-EXPECT=
    S" " NIP 0 T-EXPECT=
    S" abc" DROP C@ 97 T-EXPECT=
    #PASS @ . ." passed, " #FAIL @ . ." failed" CR ;

\ ---- Run all ----
: T-ALL
    T-FORTH T-REQUIRE T-MEMORY T-STACK T-STRING
    CR ." All test groups done." CR ;

." testkit.f loaded" CR
