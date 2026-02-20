\ bsky.f — Bluesky / AT Protocol client for Megapad-64
\
\ Depends on: KDOS v1.1 (network stack, RTC, memory), tools.f (SCROLL)
\
\ Prefix conventions:
\   BSK-    public API words
\   _BSK-   internal helpers
\
\ Load with:   S" bsky.f" INCLUDED
\         or:  SCROLL-LOAD http://host/bsky.f

\ =====================================================================
\  §0  Foundation Utilities
\ =====================================================================
\
\  String builders, JSON escaping, ISO 8601 timestamps, URL encoding.
\  No network calls — every word is testable at the ok prompt.

\ ── §0.1  String Builder ───────────────────────────────────────────
\
\  A shared working buffer with a length counter.  Words append bytes
\  or strings into it; BSK-RESET clears it for reuse.
\
\  Pattern:  BSK-RESET  S" hello" BSK-APPEND  BSK-BUF BSK-LEN @ TYPE

4096 CONSTANT BSK-BUF-MAX
CREATE BSK-BUF BSK-BUF-MAX ALLOT
VARIABLE BSK-LEN   0 BSK-LEN !

\ BSK-RESET ( -- )  Clear the working buffer
: BSK-RESET  ( -- )
    0 BSK-LEN ! ;

\ BSK-APPEND ( addr len -- )  Append string to working buffer
: BSK-APPEND  ( addr len -- )
    DUP BSK-LEN @ + BSK-BUF-MAX > IF
        2DROP EXIT                       \ overflow guard
    THEN
    DUP >R                           \ save len for +! below
    BSK-BUF BSK-LEN @ + SWAP CMOVE
    R> BSK-LEN +! ;

\ BSK-EMIT ( char -- )  Append single character to working buffer
: BSK-EMIT  ( char -- )
    BSK-LEN @ BSK-BUF-MAX >= IF DROP EXIT THEN
    BSK-BUF BSK-LEN @ + C!
    1 BSK-LEN +! ;

\ BSK-TYPE ( -- )  Print current buffer contents
: BSK-TYPE  ( -- )
    BSK-BUF BSK-LEN @ TYPE ;

\ ── Number to string conversion ──

\ Scratch pad for number formatting (32 bytes is plenty for 64-bit decimal)
CREATE _BSK-NUMBUF 32 ALLOT
VARIABLE _BSK-NUMLEN

\ NUM>STR ( u -- addr len )  Unsigned integer to decimal string
\   Converts via divide-and-mod into _BSK-NUMBUF (right-to-left),
\   then returns pointer and length.
: NUM>STR  ( u -- addr len )
    DUP 0= IF
        DROP _BSK-NUMBUF 48 OVER C!  1  EXIT
    THEN
    0 _BSK-NUMLEN !
    BEGIN DUP 0> WHILE
        10 /MOD SWAP               ( quot rem )
        48 +                        ( quot ascii-digit )
        _BSK-NUMBUF 31 _BSK-NUMLEN @ - + C!
        1 _BSK-NUMLEN +!
    REPEAT
    DROP
    _BSK-NUMBUF 32 _BSK-NUMLEN @ - +
    _BSK-NUMLEN @ ;

\ _BSK-PAD2 ( n addr -- addr+2 )  Write 2-digit zero-padded number
: _BSK-PAD2  ( n addr -- addr+2 )
    OVER 10 / 48 + OVER C!          \ tens digit
    1+
    SWAP 10 MOD 48 + OVER C!        \ ones digit
    1+ ;

\ _BSK-PAD4 ( n addr -- addr+4 )  Write 4-digit zero-padded number
: _BSK-PAD4  ( n addr -- addr+4 )
    OVER 1000 / 48 + OVER C!  1+
    OVER 1000 MOD 100 / 48 + OVER C!  1+
    OVER 100 MOD 10 / 48 + OVER C!  1+
    SWAP 10 MOD 48 + OVER C!  1+ ;

\ NUM>APPEND ( u -- )  Append unsigned decimal number to working buffer
: NUM>APPEND  ( u -- )
    NUM>STR BSK-APPEND ;

\ Note: STR-CONCAT is intentionally omitted.  Callers should use
\ BSK-RESET + BSK-APPEND + BSK-APPEND to concatenate strings through
\ the working buffer.  This avoids complex stack gymnastics.

\ ── §0.2  JSON String Escaping ────────────────────────────────────
\
\  When building JSON request bodies, string values must escape
\  backslash and double-quote characters.
\
\  Note: control chars (< 0x20) could also need \\uXXXX escaping,
\  but Bluesky post text is typically printable ASCII/UTF-8, so we
\  only handle \\ and \" for now.

\ JSON-ESCAPE-CHAR ( char -- )  Append char to BSK-BUF with escaping
: JSON-ESCAPE-CHAR  ( char -- )
    DUP 34 = IF                      \ double-quote
        DROP 92 BSK-EMIT 34 BSK-EMIT EXIT
    THEN
    DUP 92 = IF                      \ backslash
        DROP 92 BSK-EMIT 92 BSK-EMIT EXIT
    THEN
    BSK-EMIT ;                       \ all others: raw

\ JSON-COPY-ESCAPED ( src-addr src-len -- )
\   Append string to BSK-BUF with JSON escaping.
: JSON-COPY-ESCAPED  ( addr len -- )
    0 DO
        DUP I + C@ JSON-ESCAPE-CHAR
    LOOP
    DROP ;

\ ── §0.3  ISO 8601 Timestamp ──────────────────────────────────────
\
\  Builds "YYYY-MM-DDTHH:MM:SS.000Z" (24 chars) using RTC@.
\  RTC@ ( -- sec min hour day mon year dow )

CREATE _BSK-TS-BUF 32 ALLOT

\ Store RTC fields in variables for clean formatting.
VARIABLE _BSK-TS-SEC
VARIABLE _BSK-TS-MIN
VARIABLE _BSK-TS-HOUR
VARIABLE _BSK-TS-DAY
VARIABLE _BSK-TS-MON
VARIABLE _BSK-TS-YEAR

: BSK-NOW  ( -- addr len )
    RTC@                             ( sec min hour day mon year dow )
    DROP                             ( sec min hour day mon year )
    _BSK-TS-YEAR !
    _BSK-TS-MON !
    _BSK-TS-DAY !
    _BSK-TS-HOUR !
    _BSK-TS-MIN !
    _BSK-TS-SEC !
    _BSK-TS-BUF 32 0 FILL
    _BSK-TS-YEAR @ _BSK-TS-BUF _BSK-PAD4
    45 OVER C! 1+                    \ -
    _BSK-TS-MON  @ SWAP _BSK-PAD2
    45 OVER C! 1+                    \ -
    _BSK-TS-DAY  @ SWAP _BSK-PAD2
    84 OVER C! 1+                    \ T
    _BSK-TS-HOUR @ SWAP _BSK-PAD2
    58 OVER C! 1+                    \ :
    _BSK-TS-MIN  @ SWAP _BSK-PAD2
    58 OVER C! 1+                    \ :
    _BSK-TS-SEC  @ SWAP _BSK-PAD2
    \ Append ".000Z"
    46 OVER C! 1+                    \ .
    48 OVER C! 1+                    \ 0
    48 OVER C! 1+                    \ 0
    48 OVER C! 1+                    \ 0
    90 OVER C! 1+                    \ Z
    DROP
    _BSK-TS-BUF 24 ;

\ ── §0.4  URL Encoding ────────────────────────────────────────────
\
\  Percent-encodes characters outside the unreserved set
\  (RFC 3986 §2.3: ALPHA / DIGIT / "-" / "." / "_" / "~").
\  Result is appended to BSK-BUF.
\
\  Used for query parameters, e.g.  actor=did%3Aplc%3Aabc123

\ _BSK-HEX-DIGIT ( n -- char )  0-15 to hex ASCII
: _BSK-HEX-DIGIT  ( n -- char )
    DUP 10 < IF 48 + ELSE 10 - 65 + THEN ;

\ _BSK-URL-SAFE? ( char -- flag )  True if char needs no encoding
: _BSK-URL-SAFE?  ( char -- flag )
    DUP 65 >= OVER 90 <= AND IF DROP -1 EXIT THEN   \ A-Z
    DUP 97 >= OVER 122 <= AND IF DROP -1 EXIT THEN  \ a-z
    DUP 48 >= OVER 57 <= AND IF DROP -1 EXIT THEN   \ 0-9
    DUP 45 = IF DROP -1 EXIT THEN                   \ -
    DUP 46 = IF DROP -1 EXIT THEN                   \ .
    DUP 95 = IF DROP -1 EXIT THEN                   \ _
    DUP 126 = IF DROP -1 EXIT THEN                  \ ~
    DROP 0 ;

\ URL-ENCODE ( src-addr src-len -- )
\   Append URL-encoded string to BSK-BUF.
: URL-ENCODE  ( addr len -- )
    0 DO
        DUP I + C@
        DUP _BSK-URL-SAFE? IF
            BSK-EMIT
        ELSE
            37 BSK-EMIT                  \ %
            DUP 4 RSHIFT _BSK-HEX-DIGIT BSK-EMIT
            15 AND _BSK-HEX-DIGIT BSK-EMIT
        THEN
    LOOP
    DROP ;

\ ── §0.5  Convenience Strings ─────────────────────────────────────
\
\  Common string fragments used in HTTP request building.

: BSK-CRLF  ( -- )  13 BSK-EMIT 10 BSK-EMIT ;

\ Append a quoted JSON string value to BSK-BUF: "value"
: BSK-QUOTE  ( addr len -- )
    34 BSK-EMIT               \ opening "
    JSON-COPY-ESCAPED          \ escaped content
    34 BSK-EMIT ;             \ closing "

\ Append "key":"value" pair to BSK-BUF
: BSK-KV  ( key-addr key-len val-addr val-len -- )
    2SWAP BSK-QUOTE            \ "key"
    58 BSK-EMIT                \ :
    BSK-QUOTE ;                \ "value"

\ Append ,"key":"value" (with leading comma) to BSK-BUF
: BSK-KV,  ( key-addr key-len val-addr val-len -- )
    44 BSK-EMIT                \ ,
    BSK-KV ;

\ =====================================================================
\  §0 — End of Foundation Utilities
\ =====================================================================

\ =====================================================================
\  §1  Minimal JSON Parser
\ =====================================================================
\
\  Extracts specific key values from JSON API responses.  Not a full
\  parser — scans for "key": patterns and extracts values.
\  No network calls; testable with string literals at the ok prompt.

\ ── Helpers ──

\ /STRING ( addr len n -- addr+n len-n )  Advance string pointer
\   Standard Forth word; defined here in case BIOS lacks it.
: /STRING  ( addr len n -- addr+n len-n )
    ROT OVER + -ROT - ;

\ ── §1.1  Whitespace and Key Finder ──────────────────────────────

\ JSON-SKIP-WS ( addr len -- addr' len' )  Skip JSON whitespace
: JSON-SKIP-WS  ( addr len -- addr' len' )
    BEGIN
        DUP 0> WHILE
        OVER C@ DUP 32 =          \ space
        OVER 9 = OR                \ tab
        OVER 10 = OR               \ LF
        SWAP 13 = OR               \ CR
    WHILE
        1 /STRING
    REPEAT THEN ;

\ _JSON-MATCH? ( addr len paddr plen -- flag )
\   True if the first plen bytes at addr match paddr.
VARIABLE _JM-PA
VARIABLE _JM-PL

: _JSON-MATCH?  ( addr len paddr plen -- flag )
    _JM-PL ! _JM-PA !               \ save pattern
    DUP _JM-PL @ < IF               \ buffer too short?
        2DROP 0 EXIT
    THEN
    DROP                             \ drop len; only addr remains
    _JM-PL @ _JM-PA @ _JM-PL @ COMPARE 0= ;

\ Build the search pattern "key": in a scratch buffer.
CREATE _JSON-KPAT 128 ALLOT
VARIABLE _JSON-KPAT-LEN
VARIABLE _JK-AD
VARIABLE _JK-LN

: _JSON-BUILD-KPAT  ( kaddr klen -- )
    _JK-LN ! _JK-AD !
    34 _JSON-KPAT C!                             \ opening "
    _JK-AD @ _JSON-KPAT 1+ _JK-LN @ CMOVE      \ copy key text
    34 _JSON-KPAT 1+ _JK-LN @ + C!              \ closing "
    58 _JSON-KPAT 2 + _JK-LN @ + C!             \ colon :
    _JK-LN @ 3 + _JSON-KPAT-LEN ! ;             \ total = klen + 3

\ JSON-FIND-KEY ( json-addr json-len key-addr key-len -- val-addr val-len | 0 0 )
\   Scan json for "key": pattern.  Returns pointer to the value
\   (after the colon + whitespace), and remaining buffer length.
: JSON-FIND-KEY  ( jaddr jlen kaddr klen -- vaddr vlen | 0 0 )
    _JSON-BUILD-KPAT                 \ build "key": in _JSON-KPAT
    BEGIN
        DUP 0>
    WHILE
        2DUP _JSON-KPAT _JSON-KPAT-LEN @ _JSON-MATCH? IF
            _JSON-KPAT-LEN @ /STRING
            JSON-SKIP-WS
            EXIT
        THEN
        1 /STRING
    REPEAT
    2DROP 0 0 ;

\ ── §1.2  Value Extractors ────────────────────────────────────────

\ JSON-GET-STRING ( addr len -- str-addr str-len )
\   Extract string value.  addr must point at the opening " quote.
\   Returns the inner string (without quotes).  Does NOT unescape.
: JSON-GET-STRING  ( addr len -- str-addr str-len )
    OVER C@ 34 <> IF 2DROP 0 0 EXIT THEN
    1 /STRING                        \ skip opening "
    OVER                             ( addr' len' start )
    >R 0                             ( addr' len' 0=count ) R: start
    BEGIN
        OVER 0>
    WHILE
        2 PICK C@ 92 = IF           \ backslash: skip escape pair
            OVER 2 < IF             \ not enough bytes — malformed
                2DROP DROP R> DROP 0 0 EXIT
            THEN
            >R 2 /STRING R>
            2 +                      \ count += 2
        ELSE
            2 PICK C@ 34 = IF       \ closing "
                NIP NIP R> SWAP EXIT \ ( start count )
            THEN
            >R 1 /STRING R>
            1+
        THEN
    REPEAT
    2DROP DROP R> DROP 0 0 ;         \ unterminated string

\ JSON-GET-NUMBER ( addr len -- n )
\   Extract integer value.  Handles optional minus sign.
VARIABLE _JSON-NUM-NEG
: JSON-GET-NUMBER  ( addr len -- n )
    0 _JSON-NUM-NEG !
    JSON-SKIP-WS
    DUP 0<= IF 2DROP 0 EXIT THEN
    OVER C@ 45 = IF
        -1 _JSON-NUM-NEG !
        1 /STRING
    THEN
    0                                ( addr len accum )
    BEGIN
        OVER 0> WHILE
        2 PICK C@ DUP 48 >= SWAP 57 <= AND
    WHILE
        10 *
        2 PICK C@ 48 - +
        >R 1 /STRING R>
    REPEAT THEN
    NIP NIP
    _JSON-NUM-NEG @ IF NEGATE THEN ;

\ JSON-SKIP-STRING ( addr len -- addr' len' )
\   Skip past a JSON string value (addr points at opening ").
: JSON-SKIP-STRING  ( addr len -- addr' len' )
    OVER C@ 34 <> IF EXIT THEN
    1 /STRING                        \ skip opening "
    BEGIN
        DUP 0>
    WHILE
        OVER C@ 92 = IF             \ backslash escape
            DUP 2 >= IF
                2 /STRING
            ELSE
                1 /STRING            \ malformed — skip what we can
            THEN
        ELSE
            OVER C@ 34 = IF         \ closing "
                1 /STRING EXIT
            THEN
            1 /STRING
        THEN
    REPEAT ;

\ JSON-SKIP-VALUE ( addr len -- addr' len' )
\   Skip one complete JSON value (string, number, object, array,
\   boolean, null).
VARIABLE _JSON-DEPTH
: JSON-SKIP-VALUE  ( addr len -- addr' len' )
    JSON-SKIP-WS
    DUP 0<= IF EXIT THEN
    OVER C@
    DUP 34 = IF                      \ " → string
        DROP JSON-SKIP-STRING EXIT
    THEN
    DUP 123 = OVER 91 = OR IF       \ { or [ → nested structure
        DROP
        1 _JSON-DEPTH !
        1 /STRING                    \ skip opening brace/bracket
        BEGIN
            DUP 0> _JSON-DEPTH @ 0> AND
        WHILE
            OVER C@
            DUP 34 = IF              \ " inside structure — skip string
                DROP JSON-SKIP-STRING
            ELSE DUP 123 = OVER 91 = OR IF
                DROP 1 _JSON-DEPTH +!
                1 /STRING
            ELSE DUP 125 = OVER 93 = OR IF
                DROP -1 _JSON-DEPTH +!
                1 /STRING
            ELSE
                DROP 1 /STRING
            THEN THEN THEN
        REPEAT
        EXIT
    THEN
    DROP
    \ number, true, false, null — scan to delimiter
    BEGIN
        DUP 0>
    WHILE
        OVER C@ DUP 44 =            \ ,
        OVER 125 = OR               \ }
        OVER 93 = OR                \ ]
        OVER 32 = OR                \ space
        OVER 10 = OR                \ LF
        SWAP 13 = OR                \ CR
        IF EXIT THEN
        1 /STRING
    REPEAT ;

\ ── §1.3  Array Iterator ─────────────────────────────────────────

\ JSON-GET-ARRAY ( jaddr jlen key-addr key-len -- arr-addr arr-len )
\   Find the array value for key.  Returns pointer inside [ ].
: JSON-GET-ARRAY  ( jaddr jlen kaddr klen -- aaddr alen )
    JSON-FIND-KEY
    DUP 0= IF EXIT THEN
    JSON-SKIP-WS
    OVER C@ 91 <> IF 2DROP 0 0 EXIT THEN
    1 /STRING
    JSON-SKIP-WS ;

\ JSON-NEXT-ITEM ( addr len -- addr' len' | 0 0 )
\   Advance to next array element.  Returns 0 0 at end of array.
: JSON-NEXT-ITEM  ( addr len -- addr' len' | 0 0 )
    JSON-SKIP-WS
    DUP 0<= IF 2DROP 0 0 EXIT THEN
    OVER C@ 93 = IF 2DROP 0 0 EXIT THEN   \ ]
    OVER C@ 44 = IF 1 /STRING THEN        \ skip ,
    JSON-SKIP-WS
    DUP 0<= IF 2DROP 0 0 EXIT THEN
    OVER C@ 93 = IF 2DROP 0 0 EXIT THEN ;

\ =====================================================================
\  §1 — End of JSON Parser
\ =====================================================================
\
\  Test at the ok prompt:
\
\  : TEST-JSON1
\    S\" {\"name\":\"alice\",\"age\":30}"
\    S" name" JSON-FIND-KEY JSON-GET-STRING TYPE ;
\  TEST-JSON1                        → alice
\
\  : TEST-JSON2
\    S\" {\"x\":\"hello\",\"y\":42}"
\    S" y" JSON-FIND-KEY JSON-GET-NUMBER . ;
\  TEST-JSON2                        → 42
