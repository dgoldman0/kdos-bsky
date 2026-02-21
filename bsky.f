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
        0= IF EXIT THEN            \ not whitespace — done
        1 /STRING
    REPEAT ;

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
    >R 0                             ( addr' len' 0=count -- R: start )
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
    DUP 0> 0= IF 2DROP 0 EXIT THEN
    OVER C@ 45 = IF
        -1 _JSON-NUM-NEG !
        1 /STRING
    THEN
    0                                ( addr len accum )
    BEGIN
        OVER 0> WHILE
        2 PICK C@ DUP 48 >= SWAP 57 <= AND
        0= IF NIP NIP                \ not a digit — done
            _JSON-NUM-NEG @ IF NEGATE THEN
            EXIT
        THEN
        10 *
        2 PICK C@ 48 - +
        >R 1 /STRING R>
    REPEAT
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
    DUP 0> 0= IF EXIT THEN
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
    DUP 0> 0= IF 2DROP 0 0 EXIT THEN
    OVER C@ 93 = IF 2DROP 0 0 EXIT THEN   \ ]
    OVER C@ 44 = IF 1 /STRING THEN        \ skip ,
    JSON-SKIP-WS
    DUP 0> 0= IF 2DROP 0 0 EXIT THEN
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

\ =====================================================================
\  §2  HTTP POST and Authenticated GET
\ =====================================================================
\
\  Extends tools.f's HTTP capabilities with POST, auth headers, and
\  a large HBW-backed receive buffer.  Reuses _HTTP-FIND-HEND and
\  _HTTP-PARSE-CLEN from tools.f for response parsing.
\
\  Depends on: §0+§1 (string builder, JSON), tools.f (HTTP parsing),
\              KDOS TLS 1.3 stack, HBW allocator.

\ ── §2.1  Memory Setup ────────────────────────────────────────────
\
\  Session-lifetime buffers for XRPC communication.
\
\  Large receive buffer lives in external RAM (XMEM), accessible from
\  both system and userland modes.  HBW is supervisor-only so cannot
\  be used by userland code.  Small fixed-size credential buffers
\  live in dictionary space (static CREATE+ALLOT).

65536 CONSTANT BSK-RECV-MAX          \ 64 KB receive buffer
VARIABLE BSK-RECV-BUF   0 BSK-RECV-BUF !   \ XMEM address (set by BSK-INIT)
VARIABLE BSK-RECV-LEN   0 BSK-RECV-LEN !   \ bytes received

\ Token storage — AT Protocol JWTs are typically ~900 bytes
2048 CONSTANT BSK-JWT-MAX
CREATE BSK-ACCESS-JWT BSK-JWT-MAX ALLOT
VARIABLE BSK-ACCESS-LEN   0 BSK-ACCESS-LEN !
CREATE BSK-REFRESH-JWT BSK-JWT-MAX ALLOT
VARIABLE BSK-REFRESH-LEN  0 BSK-REFRESH-LEN !

\ User identity
128 CONSTANT BSK-DID-MAX
CREATE BSK-DID BSK-DID-MAX ALLOT
VARIABLE BSK-DID-LEN      0 BSK-DID-LEN !

64 CONSTANT BSK-HANDLE-MAX
CREATE BSK-HANDLE BSK-HANDLE-MAX ALLOT
VARIABLE BSK-HANDLE-LEN   0 BSK-HANDLE-LEN !

\ Server state
VARIABLE BSK-SERVER-IP     0 BSK-SERVER-IP !
VARIABLE BSK-READY         0 BSK-READY !    \ -1 after successful BSK-INIT

\ BSK-INIT ( -- )  Allocate XMEM recv buffer, clear credential state
: BSK-INIT  ( -- )
    BSK-READY @ IF EXIT THEN        \ already initialised
    BSK-RECV-MAX XMEM-ALLOT BSK-RECV-BUF !
    0 BSK-RECV-LEN !
    BSK-ACCESS-JWT BSK-JWT-MAX 0 FILL   0 BSK-ACCESS-LEN !
    BSK-REFRESH-JWT BSK-JWT-MAX 0 FILL  0 BSK-REFRESH-LEN !
    BSK-DID BSK-DID-MAX 0 FILL          0 BSK-DID-LEN !
    BSK-HANDLE BSK-HANDLE-MAX 0 FILL    0 BSK-HANDLE-LEN !
    0 BSK-SERVER-IP !
    -1 BSK-READY !
    ." bsky: init ok" CR ;

\ BSK-CLEANUP ( -- )  Release HBW (bulk reset) and clear state
: BSK-CLEANUP  ( -- )
    BSK-READY @ 0= IF EXIT THEN
    HBW-RESET                        \ reclaim all HBW memory
    0 BSK-RECV-BUF !
    0 BSK-READY ! ;

\ ── §2.2  DNS + IP Caching ────────────────────────────────────────
\
\  Resolves bsky.social once, caches the IP.  Re-resolves only on
\  explicit call or connect failure.

CREATE BSK-HOST 16 ALLOT
11 CONSTANT BSK-HOST-LEN
: _BSK-HOST-INIT  ( -- )
    S" bsky.social" BSK-HOST SWAP CMOVE ;
_BSK-HOST-INIT

\ BSK-RESOLVE ( -- ior )  Resolve bsky.social, cache IP
: BSK-RESOLVE  ( -- ior )
    BSK-HOST BSK-HOST-LEN DNS-RESOLVE
    DUP 0= IF
        ." bsky: DNS failed" CR -1 EXIT
    THEN
    BSK-SERVER-IP !
    0 ;

\ _BSK-ENSURE-IP ( -- ior )  Resolve if not yet cached
: _BSK-ENSURE-IP  ( -- ior )
    BSK-SERVER-IP @ 0= IF BSK-RESOLVE EXIT THEN
    0 ;

\ ── §2.3  Request Builders ────────────────────────────────────────
\
\  Build HTTP/1.1 GET and POST requests into BSK-BUF (4 KB).
\  Both add Host, Connection: close, and optional Authorization.
\  POST also adds Content-Type and Content-Length.

\ _BSK-APPEND-CRLF ( -- )  Append \r\n to BSK-BUF
: _BSK-APPEND-CRLF  ( -- )  13 BSK-EMIT 10 BSK-EMIT ;

\ _BSK-APPEND-HOST ( -- )  Append "Host: bsky.social\r\n"
: _BSK-APPEND-HOST  ( -- )
    S" Host: " BSK-APPEND
    BSK-HOST BSK-HOST-LEN BSK-APPEND
    _BSK-APPEND-CRLF ;

\ _BSK-APPEND-AUTH ( -- )  Append "Authorization: Bearer <jwt>\r\n"
\   Only appends if we have an access token.
: _BSK-APPEND-AUTH  ( -- )
    BSK-ACCESS-LEN @ 0= IF EXIT THEN
    S" Authorization: Bearer " BSK-APPEND
    BSK-ACCESS-JWT BSK-ACCESS-LEN @ BSK-APPEND
    _BSK-APPEND-CRLF ;

\ _BSK-APPEND-CLOSE ( -- )  Append "Connection: close\r\n"
: _BSK-APPEND-CLOSE  ( -- )
    S" Connection: close" BSK-APPEND  _BSK-APPEND-CRLF ;

\ _BSK-APPEND-JSON-CT ( -- )  Append JSON content-type header
: _BSK-APPEND-JSON-CT  ( -- )
    S" Content-Type: application/json" BSK-APPEND  _BSK-APPEND-CRLF ;

\ _BSK-APPEND-CLEN ( n -- )  Append "Content-Length: n\r\n"
: _BSK-APPEND-CLEN  ( n -- )
    S" Content-Length: " BSK-APPEND
    NUM>APPEND
    _BSK-APPEND-CRLF ;

\ BSK-BUILD-GET ( path-addr path-len -- )
\   Build authenticated GET request in BSK-BUF.
: BSK-BUILD-GET  ( path-addr path-len -- )
    BSK-RESET
    S" GET " BSK-APPEND
    BSK-APPEND                       \ path
    S"  HTTP/1.1" BSK-APPEND  _BSK-APPEND-CRLF
    _BSK-APPEND-HOST
    _BSK-APPEND-AUTH
    _BSK-APPEND-CLOSE
    _BSK-APPEND-CRLF ;              \ blank line = end of headers

\ BSK-BUILD-POST ( path-addr path-len body-addr body-len -- )
\   Build authenticated POST request in BSK-BUF.
\   Body content is appended after headers.
VARIABLE _BSK-BODY-ADDR
VARIABLE _BSK-BODY-LEN

: BSK-BUILD-POST  ( path-addr path-len body-addr body-len -- )
    _BSK-BODY-LEN ! _BSK-BODY-ADDR !
    BSK-RESET
    S" POST " BSK-APPEND
    BSK-APPEND                       \ path
    S"  HTTP/1.1" BSK-APPEND  _BSK-APPEND-CRLF
    _BSK-APPEND-HOST
    _BSK-APPEND-AUTH
    _BSK-APPEND-JSON-CT
    _BSK-BODY-LEN @ _BSK-APPEND-CLEN
    _BSK-APPEND-CLOSE
    _BSK-APPEND-CRLF                \ blank line
    _BSK-BODY-ADDR @ _BSK-BODY-LEN @ BSK-APPEND ;  \ body

\ ── §2.4  TLS Send/Receive Wrapper ────────────────────────────────
\
\  Connect to bsky.social:443, send the request built in BSK-BUF,
\  receive into HBW recv buffer.

VARIABLE _BSK-CTX                    \ current TLS context
VARIABLE _BSK-EMPTY                  \ consecutive empty recv counter
VARIABLE _BSK-RECV-STOP             \ flag: stop recv loop

\ _BSK-TLS-OPEN ( -- ctx | 0 )  TLS connect to cached server IP
: _BSK-TLS-OPEN  ( -- ctx | 0 )
    \ Set SNI hostname
    BSK-HOST-LEN 63 MIN DUP TLS-SNI-LEN !
    BSK-HOST TLS-SNI-HOST ROT CMOVE
    \ Random ephemeral port 49152-65535 to avoid collisions
    RANDOM32 16383 AND 49152 +
    BSK-SERVER-IP @ 443 ROT TLS-CONNECT ;

\ Recv-loop helpers — split to stay within KDOS compiler limits.
\ Each helper handles one TLS-RECV outcome with at most 1 IF.

: _BSK-RECV-ONE  ( -- n )
    _BSK-CTX @
    BSK-RECV-BUF @ BSK-RECV-LEN @ +
    BSK-RECV-MAX BSK-RECV-LEN @ -
    TLS-RECV ;

: _BSK-RECV-GOT  ( n -- )
    BSK-RECV-LEN +!   0 _BSK-EMPTY ! ;

: _BSK-RECV-ZERO  ( -- )
    BSK-RECV-LEN @ 0= IF EXIT THEN
    _BSK-EMPTY @ 1+ DUP _BSK-EMPTY !
    10 >= IF TRUE _BSK-RECV-STOP ! THEN ;

: _BSK-RECV-ERR  ( -- )
    TRUE _BSK-RECV-STOP ! ;

: _BSK-RECV-HANDLE  ( n -- )
    DUP 0> IF _BSK-RECV-GOT EXIT THEN
    DUP -1 = IF DROP _BSK-RECV-ERR EXIT THEN
    DROP _BSK-RECV-ZERO ;

\ _BSK-RECV-LOOP ( ctx -- )  Receive response into recv buffer
: _BSK-RECV-LOOP  ( ctx -- )
    _BSK-CTX !
    0 BSK-RECV-LEN !  0 _BSK-EMPTY !  FALSE _BSK-RECV-STOP !
    500 0 DO
        TCP-POLL NET-IDLE
        BSK-RECV-LEN @ BSK-RECV-MAX >= IF LEAVE THEN
        _BSK-RECV-STOP @ IF LEAVE THEN
        _BSK-RECV-ONE _BSK-RECV-HANDLE
    LOOP ;

\ BSK-XRPC-SEND ( -- ior )
\   Send BSK-BUF contents over TLS, receive response into HBW buffer.
: BSK-XRPC-SEND  ( -- ior )
    _BSK-ENSURE-IP IF -1 EXIT THEN
    _BSK-TLS-OPEN DUP 0= IF
        ." bsky: TLS connect failed" CR -1 EXIT
    THEN
    DUP >R
    BSK-BUF BSK-LEN @ ROT -ROT TLS-SEND DROP
    R@ _BSK-RECV-LOOP
    R> TLS-CLOSE
    BSK-RECV-LEN @ 0= IF -1 EXIT THEN
    0 ;

\ ── §2.5  Response Parser ─────────────────────────────────────────
\
\  Parse HTTP status and extract response body.
\  Reuses _HTTP-FIND-HEND and _HTTP-PARSE-CLEN from tools.f.

VARIABLE BSK-HTTP-STATUS             \ last HTTP status code (200, 401, etc.)

\ _BSK-PARSE-STATUS ( addr len -- status )
\   Extract 3-digit HTTP status from "HTTP/1.1 NNN ..." response line.
\   Expects addr to point at start of response.
: _BSK-PARSE-STATUS  ( addr len -- status )
    9 < IF DROP 0 EXIT THEN          \ too short — len consumed, addr remains
    9 +                              \ addr+9 = status digits
    \ 3 chars at offset 9: "2" "0" "0"
    DUP C@ 48 - 100 *
    OVER 1+ C@ 48 - 10 * +
    SWAP 2 + C@ 48 - + ;

\ BSK-PARSE-RESPONSE ( -- body-addr body-len status )
\   Parse the raw HTTP response in BSK-RECV-BUF.
\   Returns body pointer (inside recv buffer), body length, and status code.
\   Handles chunked transfer encoding (dechunks in place).
\   Split into helpers to stay within KDOS compiler limits.
VARIABLE _BSK-HDR-OFF                   \ header-end offset (temp)
VARIABLE _PR-BADDR                      \ body address (result)
VARIABLE _PR-BLEN                       \ body length  (result)

\ ── Chunked transfer encoding decoder ──
\  (Must be defined before _BSK-MAYBE-DECHUNK — Forth requires
\   all called words to be defined before the caller.)

\ _BSK-HEX-VAL ( char -- n | -1 )
\   Convert one hex character to its value, or -1 if invalid.
: _BSK-HEX-VAL  ( char -- n | -1 )
    DUP 48 >= OVER 57 <= AND IF 48 - EXIT THEN   \ 0-9
    DUP 65 >= OVER 70 <= AND IF 55 - EXIT THEN   \ A-F
    DUP 97 >= OVER 102 <= AND IF 87 - EXIT THEN  \ a-f
    DROP -1 ;

\ _BSK-PARSE-CHUNK-SIZE ( addr len -- chunk-size hdr-len | -1 0 )
\   Parse hex chunk size at start of addr.  Returns the numeric size
\   and the number of bytes consumed (hex digits + \r\n).
\   Returns -1 0 on parse failure.
: _BSK-PARSE-CHUNK-SIZE  ( addr len -- chunk-size hdr-len | -1 0 )
    0 0                              ( addr len accum digits )
    BEGIN
        2 PICK 0>                    \ len > 0 ?
    WHILE
        3 PICK C@                    ( addr len accum digits char )
        DUP 13 = IF                  \ CR — end of hex digits
            DROP
            2 PICK 2 >= IF           \ need at least \r\n after len
                2SWAP 2DROP          ( accum digits )
                \ Skip \r\n (2 bytes) → hdr-len = digits + 2
                2 + EXIT
            ELSE
                2DROP 2DROP -1 0 EXIT
            THEN
        THEN
        _BSK-HEX-VAL DUP -1 = IF
            DROP 2DROP 2DROP -1 0 EXIT  \ invalid char
        THEN
        >R SWAP 16 * R> + SWAP 1+   ( addr len accum' digits' )
        >R >R 1 /STRING R> R>       ( addr' len' accum digits )
    REPEAT
    2DROP 2DROP -1 0 ;               \ ran out of data

\ _BSK-DECHUNK ( -- )
\   Remove chunked transfer encoding from body data (in place).
\   Reads body from _PR-BADDR / _PR-BLEN, compacts chunk payloads
\   by removing chunk headers and trailers, writes result back.
\   Split into small helpers to stay within KDOS compiler limits.
VARIABLE _DC-DST
VARIABLE _DC-TOTAL
VARIABLE _DC-DONE
VARIABLE _DC-CSIZ                      \ current chunk size
VARIABLE _DC-HLEN                      \ chunk header length

\ Store "parse failed" result — return accumulated data so far.
: _DC-ON-FAIL  ( -- )
    _DC-DST @ _PR-BADDR !
    _DC-TOTAL @ _PR-BLEN !
    TRUE _DC-DONE ! ;

\ Store "end of chunks" result — body start = dst - total.
: _DC-ON-END  ( -- )
    _DC-DST @ _DC-TOTAL @ - _PR-BADDR !
    _DC-TOTAL @ _PR-BLEN !
    TRUE _DC-DONE ! ;

\ Copy one chunk's payload to the compacted destination.
: _DC-COPY-ONE  ( addr len -- addr' len' )
    _DC-HLEN @ /STRING              \ skip chunk header
    _DC-CSIZ @ OVER MIN             \ copy-len = min(chunk, remain)
    >R
    OVER _DC-DST @ R@ CMOVE         \ compact chunk data
    R> DUP _DC-DST +!  DUP _DC-TOTAL +!
    /STRING                          \ skip past chunk data
    DUP 2 >= IF 2 /STRING THEN ;    \ skip trailing \r\n

\ Process one chunk: parse header, dispatch.
: _DC-STEP  ( addr len -- addr' len' )
    2DUP _BSK-PARSE-CHUNK-SIZE       ( addr len cs hl )
    _DC-HLEN !  _DC-CSIZ !           ( addr len )
    _DC-CSIZ @ -1 = IF  2DROP 0 0 _DC-ON-FAIL  EXIT  THEN
    _DC-CSIZ @  0= IF  2DROP 0 0 _DC-ON-END   EXIT  THEN
    _DC-COPY-ONE ;

\ Main dechunk loop — reads/writes _PR-BADDR, _PR-BLEN.
: _BSK-DECHUNK  ( -- )
    _PR-BADDR @ _DC-DST !
    0 _DC-TOTAL !   FALSE _DC-DONE !
    _PR-BADDR @ _PR-BLEN @           ( addr len )
    BEGIN  DUP 0> _DC-DONE @ 0= AND  WHILE
        _DC-STEP
    REPEAT
    2DROP
    _DC-DONE @ 0= IF _DC-ON-END THEN ;

\ ── Response parser helpers ──

: _BSK-CLAMP-CLEN  ( -- )
    _HTTP-CLEN @ -1 <> IF
        _PR-BLEN @ _HTTP-CLEN @ MIN _PR-BLEN !
    THEN ;

: _BSK-MAYBE-DECHUNK  ( -- )
    _HTTP-CLEN @ -1 <> IF EXIT THEN
    _PR-BLEN @ 1 < IF EXIT THEN
    _BSK-DECHUNK ;

: BSK-PARSE-RESPONSE  ( -- body-addr body-len status )
    BSK-RECV-BUF @ BSK-RECV-LEN @ _BSK-PARSE-STATUS
    BSK-HTTP-STATUS !
    BSK-RECV-BUF @ BSK-RECV-LEN @ _HTTP-FIND-HEND
    _HTTP-HEND @ 0= IF
        0 0 BSK-HTTP-STATUS @ EXIT
    THEN
    _HTTP-HEND @ BSK-RECV-BUF @ - _BSK-HDR-OFF !
    BSK-RECV-BUF @ _BSK-HDR-OFF @ _HTTP-PARSE-CLEN
    BSK-RECV-BUF @ _BSK-HDR-OFF @ + _PR-BADDR !
    BSK-RECV-LEN @ _BSK-HDR-OFF @ - _PR-BLEN !
    _BSK-CLAMP-CLEN
    _BSK-MAYBE-DECHUNK
    _PR-BADDR @ _PR-BLEN @ BSK-HTTP-STATUS @ ;

\ ── §2.6  High-Level Wrappers ─────────────────────────────────────
\
\  Simple words that build a request, send it, and return the body.

\ BSK-GET ( path-addr path-len -- body-addr body-len )
\   Authenticated GET.  Returns body and length (0 0 on error).
: BSK-GET  ( path-addr path-len -- body-addr body-len )
    BSK-BUILD-GET
    BSK-XRPC-SEND IF 0 0 EXIT THEN
    BSK-PARSE-RESPONSE DROP ;        \ drop status, caller can check BSK-HTTP-STATUS

\ BSK-POST-JSON ( path-addr path-len json-addr json-len -- body-addr body-len )
\   Authenticated POST with JSON body.  Returns body and length.
: BSK-POST-JSON  ( path-addr path-len json-addr json-len -- body-addr body-len )
    BSK-BUILD-POST
    BSK-XRPC-SEND IF 0 0 EXIT THEN
    BSK-PARSE-RESPONSE DROP ;

\ =====================================================================
\  §2 — End of HTTP POST and Authenticated GET
\ =====================================================================

\ =====================================================================
\  §3  Authentication
\ =====================================================================
\
\  Login via com.atproto.server.createSession, store JWTs, refresh.
\  Uses BSK-POST-JSON / BSK-BUILD-POST + BSK-XRPC-SEND from Stage 2.
\
\  createSession request:  {"identifier":"handle","password":"pass"}
\  createSession response: {"accessJwt":"...","refreshJwt":"...",
\                           "did":"did:plc:...","handle":"..."}
\
\  refreshSession request: POST with empty body, Bearer = refreshJwt
\  refreshSession response: same as createSession

\ ── §3.1  Login JSON Builder ──────────────────────────────────────
\
\  Build the createSession JSON body in BSK-BUF (temporarily),
\  then copy it aside so BSK-BUILD-POST can reference it.

CREATE _BSK-LOGIN-BUF 512 ALLOT     \ temp buffer for login JSON body
VARIABLE _BSK-LOGIN-LEN   0 _BSK-LOGIN-LEN !

\ _BSK-BUILD-LOGIN-JSON ( handle-addr handle-len pass-addr pass-len -- )
\   Builds {"identifier":"<handle>","password":"<pass>"} into
\   _BSK-LOGIN-BUF.  Uses BSK-BUF as scratch then copies out.
: _BSK-BUILD-LOGIN-JSON  ( haddr hlen paddr plen -- )
    2>R 2>R                          \ save pass & handle on rstack
    BSK-RESET
    S" {" BSK-APPEND
    34 BSK-EMIT  S" identifier" BSK-APPEND  34 BSK-EMIT
    58 BSK-EMIT                      \ :
    34 BSK-EMIT  2R> JSON-COPY-ESCAPED  34 BSK-EMIT
    44 BSK-EMIT                      \ ,
    34 BSK-EMIT  S" password" BSK-APPEND  34 BSK-EMIT
    58 BSK-EMIT                      \ :
    34 BSK-EMIT  2R> JSON-COPY-ESCAPED  34 BSK-EMIT
    S" }" BSK-APPEND
    \ Copy to _BSK-LOGIN-BUF
    BSK-BUF _BSK-LOGIN-BUF BSK-LEN @ CMOVE
    BSK-LEN @ _BSK-LOGIN-LEN ! ;

\ ── §3.2  Session Response Parser ─────────────────────────────────
\
\  Extract accessJwt, refreshJwt, did, handle from createSession /
\  refreshSession response body and store in their buffers.

\ _BSK-EXTRACT-FIELD ( body-addr body-len key-addr key-len
\                      dst-addr dst-max dst-len-var -- ok? )
\   Find a JSON string field and copy it into a fixed buffer.
\   Returns -1 on success, 0 on failure (key not found or too long).
VARIABLE _EF-DST
VARIABLE _EF-DMAX
VARIABLE _EF-DVAR

: _BSK-EXTRACT-FIELD  ( baddr blen kaddr klen dst dmax dlen-var -- ok? )
    _EF-DVAR !  _EF-DMAX !  _EF-DST !
    JSON-FIND-KEY                    ( vaddr vlen | 0 0 )
    DUP 0= IF 2DROP 0 EXIT THEN
    JSON-GET-STRING                  ( str-addr str-len )
    DUP 0= IF 2DROP 0 EXIT THEN
    DUP _EF-DMAX @ > IF 2DROP 0 EXIT THEN
    \ Copy string to destination buffer
    DUP _EF-DVAR @ !                \ store length
    _EF-DST @ SWAP CMOVE            \ CMOVE ( str-addr dst str-len )
    -1 ;

\ _BSK-PARSE-SESSION ( body-addr body-len -- ok? )
\   Parse createSession / refreshSession response.
\   Stores tokens and identity.  Returns -1 on success, 0 on failure.
: _BSK-PARSE-SESSION  ( baddr blen -- ok? )
    \ Extract accessJwt
    2DUP S" accessJwt"
    BSK-ACCESS-JWT BSK-JWT-MAX BSK-ACCESS-LEN
    _BSK-EXTRACT-FIELD 0= IF 2DROP 0 EXIT THEN
    \ Extract refreshJwt
    2DUP S" refreshJwt"
    BSK-REFRESH-JWT BSK-JWT-MAX BSK-REFRESH-LEN
    _BSK-EXTRACT-FIELD 0= IF 2DROP 0 EXIT THEN
    \ Extract did
    2DUP S" did"
    BSK-DID BSK-DID-MAX BSK-DID-LEN
    _BSK-EXTRACT-FIELD 0= IF 2DROP 0 EXIT THEN
    \ Extract handle
    S" handle"
    BSK-HANDLE BSK-HANDLE-MAX BSK-HANDLE-LEN
    _BSK-EXTRACT-FIELD ;

\ ── §3.3  Login Command ───────────────────────────────────────────
\
\  BSK-LOGIN ( "handle" "password" -- )
\  User-facing word.  Reads handle and password from the input stream.
\
\  Usage:   BSK-LOGIN myname.bsky.social xxxx-xxxx-xxxx-xxxx

\ Temp parse buffers (used only during login)
CREATE _BSK-LOGIN-HANDLE 128 ALLOT
VARIABLE _BSK-LOGIN-HLEN   0 _BSK-LOGIN-HLEN !
CREATE _BSK-LOGIN-PASS 128 ALLOT
VARIABLE _BSK-LOGIN-PLEN   0 _BSK-LOGIN-PLEN !

: BSK-LOGIN-WITH  ( handle-addr handle-len pass-addr pass-len -- )
    BSK-INIT
    _BSK-BUILD-LOGIN-JSON
    \ POST to createSession
    S" /xrpc/com.atproto.server.createSession"
    _BSK-LOGIN-BUF _BSK-LOGIN-LEN @
    BSK-BUILD-POST
    BSK-XRPC-SEND IF
        ." bsky: login network error" CR EXIT
    THEN
    \ Parse response
    BSK-PARSE-RESPONSE              ( body-addr body-len status )
    DUP 200 <> IF
        ." bsky: login failed (HTTP " . ." )" CR
        TYPE CR                      \ print error body
        EXIT
    THEN
    DROP                             \ drop status
    _BSK-PARSE-SESSION 0= IF
        ." bsky: login failed (parse error)" CR EXIT
    THEN
    ." Logged in as " BSK-HANDLE BSK-HANDLE-LEN @ TYPE CR ;

: BSK-LOGIN  ( "handle" "password" -- )
    \ Parse handle and password from input stream
    BL WORD COUNT                    ( addr len )
    DUP 0= IF 2DROP ." Usage: BSK-LOGIN handle password" CR EXIT THEN
    127 MIN DUP _BSK-LOGIN-HLEN !
    _BSK-LOGIN-HANDLE SWAP CMOVE
    BL WORD COUNT                    ( addr len )
    DUP 0= IF 2DROP ." Usage: BSK-LOGIN handle password" CR EXIT THEN
    127 MIN DUP _BSK-LOGIN-PLEN !
    _BSK-LOGIN-PASS SWAP CMOVE
    _BSK-LOGIN-HANDLE _BSK-LOGIN-HLEN @
    _BSK-LOGIN-PASS _BSK-LOGIN-PLEN @
    BSK-LOGIN-WITH
    \ Clear password from memory
    _BSK-LOGIN-PASS 128 0 FILL  0 _BSK-LOGIN-PLEN ! ;

\ ── §3.4  Token Refresh ───────────────────────────────────────────
\
\  BSK-REFRESH ( -- )
\  Refresh the access token using the stored refresh token.
\  The refresh endpoint uses the refreshJwt as Bearer auth
\  (not the accessJwt).

: BSK-REFRESH  ( -- )
    BSK-REFRESH-LEN @ 0= IF
        ." bsky: no refresh token — login first" CR EXIT
    THEN
    \ Build POST with empty body, but we need refreshJwt as auth.
    \ Temporarily swap refresh into access position:
    \ 1. Save current access token aside
    BSK-RESET
    S" POST /xrpc/com.atproto.server.refreshSession HTTP/1.1" BSK-APPEND
    _BSK-APPEND-CRLF
    _BSK-APPEND-HOST
    \ Manually append auth with refresh token
    S" Authorization: Bearer " BSK-APPEND
    BSK-REFRESH-JWT BSK-REFRESH-LEN @ BSK-APPEND
    _BSK-APPEND-CRLF
    S" Content-Length: 0" BSK-APPEND  _BSK-APPEND-CRLF
    _BSK-APPEND-CLOSE
    _BSK-APPEND-CRLF                \ blank line = end of headers
    \ Send
    BSK-XRPC-SEND IF
        ." bsky: refresh network error" CR EXIT
    THEN
    \ Parse response
    BSK-PARSE-RESPONSE              ( body-addr body-len status )
    DUP 200 <> IF
        ." bsky: refresh failed (HTTP " . ." )" CR
        TYPE CR EXIT
    THEN
    DROP
    _BSK-PARSE-SESSION 0= IF
        ." bsky: refresh failed (parse error)" CR EXIT
    THEN
    ." bsky: tokens refreshed" CR ;

\ ── §3.5  Session Info ────────────────────────────────────────────

\ BSK-WHO ( -- )  Display current session information
: BSK-WHO  ( -- )
    BSK-ACCESS-LEN @ 0= IF
        ." Not logged in" CR EXIT
    THEN
    ." Handle: " BSK-HANDLE BSK-HANDLE-LEN @ TYPE CR
    ." DID:    " BSK-DID BSK-DID-LEN @ TYPE CR
    ." Access: " BSK-ACCESS-LEN @ . ." bytes" CR
    ." Refresh: " BSK-REFRESH-LEN @ . ." bytes" CR ;

\ =====================================================================
\  §3 — End of Authentication
\ =====================================================================

\ =====================================================================
\  §4  Read-Only Features
\ =====================================================================
\
\  View timeline, profiles, and notifications.
\  All words require a valid session (BSK-LOGIN first).
\  Uses BSK-GET from Stage 2 and JSON parser from Stage 1.

\ ── §4.0  Display Helpers ─────────────────────────────────────────
\
\  Truncate and word-wrap text for 80-column display.

\ _BSK-TYPE-TRUNC ( addr len maxlen -- )
\   Print up to maxlen characters, add "..." if truncated.
: _BSK-TYPE-TRUNC  ( addr len maxlen -- )
    2DUP > IF
        NIP                         \ drop len; ( addr maxlen )
        3 - TYPE ." ..."
    ELSE
        DROP TYPE
    THEN ;

\ ── Path scratch buffer ──
\
\  BSK-BUF is shared with BSK-BUILD-GET/POST, so path builders must
\  copy their result into a separate buffer before calling BSK-GET.

512 CONSTANT _BSK-PATH-MAX
CREATE _BSK-PATH-BUF _BSK-PATH-MAX ALLOT
VARIABLE _BSK-PATH-LEN   0 _BSK-PATH-LEN !

\ _BSK-SAVE-PATH ( -- addr len )
\   Copy current BSK-BUF contents into _BSK-PATH-BUF and return
\   a pointer to the copy.  Call after building a path in BSK-BUF.
: _BSK-SAVE-PATH  ( -- addr len )
    BSK-LEN @ _BSK-PATH-MAX MIN DUP _BSK-PATH-LEN !
    BSK-BUF _BSK-PATH-BUF ROT CMOVE
    _BSK-PATH-BUF _BSK-PATH-LEN @ ;

\ ── §4.1  Timeline ────────────────────────────────────────────────
\
\  BSK-TL ( -- )  Fetch and display recent timeline posts (5 items).
\
\  Endpoint: GET /xrpc/app.bsky.feed.getTimeline?limit=5
\  Response: {"cursor":"...","feed":[{"post":{"author":{"handle":"...","displayName":"..."},"record":{"text":"..."},...},...},...]}
\
\  Each feed item has a deep "post" object.  We use JSON-FIND-KEY
\  to navigate into nested objects since it scans forward.

\ Cursor storage for pagination
CREATE BSK-TL-CURSOR 128 ALLOT
VARIABLE BSK-TL-CURSOR-LEN  0 BSK-TL-CURSOR-LEN !

\ _BSK-TL-PRINT-POST ( item-addr item-len -- )
\   Print one timeline post entry (feed item).
\   Expects addr/len to point at the start of a feed item object.
: _BSK-TL-PRINT-POST  ( addr len -- )
    \ Find post object first
    2DUP S" post" JSON-FIND-KEY     ( addr len post-val-addr post-val-len )
    DUP 0= IF 2DROP 2DROP EXIT THEN
    \ Now within "post" value, find author.handle
    2DUP S" handle" JSON-FIND-KEY   ( addr len pvaddr pvlen handle-val-addr handle-val-len )
    DUP 0> IF
        JSON-GET-STRING             ( addr len pvaddr pvlen handle-saddr handle-slen )
        ." @" 76 _BSK-TYPE-TRUNC
    THEN
    2DROP                           \ drop handle result
    \ Find displayName inside the post scope
    2DUP S" displayName" JSON-FIND-KEY
    DUP 0> IF
        JSON-GET-STRING
        DUP 0> IF
            ."  (" 60 _BSK-TYPE-TRUNC ." )"
        ELSE 2DROP THEN
    ELSE 2DROP THEN
    CR
    \ Find record.text within the post scope
    2DUP S" text" JSON-FIND-KEY
    DUP 0> IF
        JSON-GET-STRING
        DUP 0> IF
            ."   " 200 _BSK-TYPE-TRUNC CR
        ELSE 2DROP THEN
    ELSE 2DROP THEN
    2DROP                           \ drop remaining post scope
    ." ---" CR ;

\ _BSK-TL-PATH ( -- addr len )
\   Build the timeline request path with limit parameter.
\   If a cursor is stored, appends &cursor=<cursor>.
: _BSK-TL-PATH  ( -- addr len )
    BSK-RESET
    S" /xrpc/app.bsky.feed.getTimeline?limit=5" BSK-APPEND
    BSK-TL-CURSOR-LEN @ 0> IF
        S" &cursor=" BSK-APPEND
        BSK-TL-CURSOR BSK-TL-CURSOR-LEN @ URL-ENCODE
    THEN
    _BSK-SAVE-PATH ;

\ BSK-TL ( -- )   Display recent timeline posts
: BSK-TL  ( -- )
    BSK-ACCESS-LEN @ 0= IF ." bsky: login first" CR EXIT THEN
    _BSK-TL-PATH BSK-GET           ( body-addr body-len )
    DUP 0= IF 2DROP ." bsky: timeline fetch failed" CR EXIT THEN
    BSK-HTTP-STATUS @ 200 <> IF
        ." bsky: timeline error (HTTP " BSK-HTTP-STATUS @ . ." )" CR
        2DROP EXIT
    THEN
    \ Store cursor for pagination
    2DUP S" cursor" JSON-FIND-KEY
    DUP 0> IF
        JSON-GET-STRING
        DUP 128 <= IF
            DUP BSK-TL-CURSOR-LEN !
            BSK-TL-CURSOR SWAP CMOVE
        ELSE 2DROP THEN
    ELSE 2DROP THEN
    \ Iterate feed array
    2DUP S" feed" JSON-FIND-KEY     ( body blen feed-val-addr feed-val-len )
    DUP 0= IF 2DROP 2DROP ." bsky: no feed in response" CR EXIT THEN
    \ Skip into the array
    JSON-SKIP-WS
    OVER C@ 91 <> IF 2DROP 2DROP ." bsky: feed not array" CR EXIT THEN
    1 /STRING JSON-SKIP-WS          \ skip [ and whitespace
    \ Iterate items
    BEGIN
        DUP 0> IF
            OVER C@ 93 <>          \ not ]
        ELSE 0 THEN
    WHILE
        2DUP _BSK-TL-PRINT-POST
        JSON-SKIP-VALUE             \ skip past this item
        JSON-SKIP-WS
        DUP 0> IF
            OVER C@ 44 = IF 1 /STRING JSON-SKIP-WS THEN
        THEN
    REPEAT
    2DROP 2DROP ;

\ BSK-TL-NEXT ( -- )   Show next page of timeline
: BSK-TL-NEXT  ( -- )
    BSK-TL-CURSOR-LEN @ 0= IF
        ." bsky: no more posts (no cursor)" CR EXIT
    THEN
    BSK-TL ;

\ ── §4.2  Profile Viewer ─────────────────────────────────────────
\
\  BSK-PROFILE ( "handle" -- )  View a user's profile.
\
\  Endpoint: GET /xrpc/app.bsky.actor.getProfile?actor=<handle>
\  Response: {"did":"...","handle":"...","displayName":"...",
\             "description":"...","followersCount":N,
\             "followsCount":N,"postsCount":N,...}

\ _BSK-PROFILE-PATH ( actor-addr actor-len -- path-addr path-len )
\   Build profile request path with URL-encoded actor parameter.
: _BSK-PROFILE-PATH  ( addr len -- path-addr path-len )
    BSK-RESET
    S" /xrpc/app.bsky.actor.getProfile?actor=" BSK-APPEND
    URL-ENCODE
    _BSK-SAVE-PATH ;

: BSK-PROFILE  ( "handle" -- )
    BSK-ACCESS-LEN @ 0= IF ." bsky: login first" CR EXIT THEN
    BL WORD COUNT                   ( addr len )
    DUP 0= IF 2DROP ." Usage: BSK-PROFILE handle" CR EXIT THEN
    _BSK-PROFILE-PATH BSK-GET      ( body-addr body-len )
    DUP 0= IF 2DROP ." bsky: profile fetch failed" CR EXIT THEN
    BSK-HTTP-STATUS @ 200 <> IF
        ." bsky: profile error (HTTP " BSK-HTTP-STATUS @ . ." )" CR
        2DROP EXIT
    THEN
    \ Display profile info
    2DUP S" displayName" JSON-FIND-KEY
    DUP 0> IF JSON-GET-STRING DUP 0> IF 64 _BSK-TYPE-TRUNC ELSE 2DROP THEN
    ELSE 2DROP THEN
    CR
    2DUP S" handle" JSON-FIND-KEY
    DUP 0> IF JSON-GET-STRING DUP 0> IF ." @" 64 _BSK-TYPE-TRUNC ELSE 2DROP THEN
    ELSE 2DROP THEN
    CR
    2DUP S" description" JSON-FIND-KEY
    DUP 0> IF JSON-GET-STRING DUP 0> IF 200 _BSK-TYPE-TRUNC ELSE 2DROP THEN
    ELSE 2DROP THEN
    CR
    2DUP S" followersCount" JSON-FIND-KEY
    DUP 0> IF JSON-GET-NUMBER . ." followers  " ELSE 2DROP THEN
    2DUP S" followsCount" JSON-FIND-KEY
    DUP 0> IF JSON-GET-NUMBER . ." following  " ELSE 2DROP THEN
    2DUP S" postsCount" JSON-FIND-KEY
    DUP 0> IF JSON-GET-NUMBER . ." posts" ELSE 2DROP THEN
    CR
    2DROP ;

\ _BSK-PROFILE-WITH ( actor-addr actor-len -- )
\   Stack-based profile viewer (no input stream parsing).
: _BSK-PROFILE-WITH  ( addr len -- )
    BSK-ACCESS-LEN @ 0= IF 2DROP ." bsky: login first" CR EXIT THEN
    _BSK-PROFILE-PATH BSK-GET      ( body-addr body-len )
    DUP 0= IF 2DROP ." bsky: profile fetch failed" CR EXIT THEN
    BSK-HTTP-STATUS @ 200 <> IF
        ." bsky: profile error (HTTP " BSK-HTTP-STATUS @ . ." )" CR
        2DROP EXIT
    THEN
    2DUP S" displayName" JSON-FIND-KEY
    DUP 0> IF JSON-GET-STRING DUP 0> IF 64 _BSK-TYPE-TRUNC ELSE 2DROP THEN
    ELSE 2DROP THEN
    CR
    2DUP S" handle" JSON-FIND-KEY
    DUP 0> IF JSON-GET-STRING DUP 0> IF ." @" 64 _BSK-TYPE-TRUNC ELSE 2DROP THEN
    ELSE 2DROP THEN
    CR
    2DUP S" description" JSON-FIND-KEY
    DUP 0> IF JSON-GET-STRING DUP 0> IF 200 _BSK-TYPE-TRUNC ELSE 2DROP THEN
    ELSE 2DROP THEN
    CR
    2DUP S" followersCount" JSON-FIND-KEY
    DUP 0> IF JSON-GET-NUMBER . ." followers  " ELSE 2DROP THEN
    2DUP S" followsCount" JSON-FIND-KEY
    DUP 0> IF JSON-GET-NUMBER . ." following  " ELSE 2DROP THEN
    2DUP S" postsCount" JSON-FIND-KEY
    DUP 0> IF JSON-GET-NUMBER . ." posts" ELSE 2DROP THEN
    CR
    2DROP ;

\ ── §4.3  Notifications ──────────────────────────────────────────
\
\  BSK-NOTIF ( -- )  List recent notifications (10 items).
\
\  Endpoint: GET /xrpc/app.bsky.notification.listNotifications?limit=10
\  Response: {"cursor":"...","notifications":[
\    {"reason":"like"|"reply"|"follow"|"mention"|"repost"|"quote",
\     "author":{"handle":"...","displayName":"..."},
\     ...},...]}

\ _BSK-NOTIF-PRINT ( item-addr item-len -- )
\   Print one notification entry.
: _BSK-NOTIF-PRINT  ( addr len -- )
    \ Extract reason
    2DUP S" reason" JSON-FIND-KEY
    DUP 0> IF
        JSON-GET-STRING             ( addr len reason-addr reason-len )
        DUP 0> IF
            20 _BSK-TYPE-TRUNC
        ELSE 2DROP THEN
    ELSE 2DROP THEN
    ."  from "
    \ Extract author.handle
    2DUP S" handle" JSON-FIND-KEY
    DUP 0> IF
        JSON-GET-STRING
        DUP 0> IF
            ." @" 40 _BSK-TYPE-TRUNC
        ELSE 2DROP THEN
    ELSE 2DROP THEN
    CR ;

: BSK-NOTIF  ( -- )
    BSK-ACCESS-LEN @ 0= IF ." bsky: login first" CR EXIT THEN
    BSK-RESET
    S" /xrpc/app.bsky.notification.listNotifications?limit=10" BSK-APPEND
    _BSK-SAVE-PATH BSK-GET         ( body-addr body-len )
    DUP 0= IF 2DROP ." bsky: notif fetch failed" CR EXIT THEN
    BSK-HTTP-STATUS @ 200 <> IF
        ." bsky: notif error (HTTP " BSK-HTTP-STATUS @ . ." )" CR
        2DROP EXIT
    THEN
    \ Iterate notifications array
    2DUP S" notifications" JSON-FIND-KEY
    DUP 0= IF 2DROP 2DROP ." bsky: no notifications in response" CR EXIT THEN
    JSON-SKIP-WS
    OVER C@ 91 <> IF 2DROP 2DROP ." bsky: notifications not array" CR EXIT THEN
    1 /STRING JSON-SKIP-WS          \ skip [ and whitespace
    BEGIN
        DUP 0> IF
            OVER C@ 93 <>          \ not ]
        ELSE 0 THEN
    WHILE
        2DUP _BSK-NOTIF-PRINT
        JSON-SKIP-VALUE
        JSON-SKIP-WS
        DUP 0> IF
            OVER C@ 44 = IF 1 /STRING JSON-SKIP-WS THEN
        THEN
    REPEAT
    2DROP 2DROP ;

\ =====================================================================
\  §4 — End of Read-Only Features
\ =====================================================================

\ =====================================================================
\  §5  Write Features
\ =====================================================================
\
\  BSK-POST   — post a new skeet
\  BSK-REPLY  — reply to a post
\  BSK-LIKE   — like a post
\  BSK-REPOST — repost
\
\  All four use POST /xrpc/com.atproto.repo.createRecord with
\  different collection and record schemas.

\ ── §5.1  JSON Body Builder ───────────────────────────────────────
\
\  Staging buffer: JSON body is built in BSK-BUF, then copied here
\  before BSK-BUILD-POST overwrites BSK-BUF with HTTP headers.

CREATE _BSK-POST-BUF 2048 ALLOT
VARIABLE _BSK-POST-LEN   0 _BSK-POST-LEN !

\ _BSK-STAGE-BODY ( -- )  Copy BSK-BUF → _BSK-POST-BUF
: _BSK-STAGE-BODY  ( -- )
    BSK-LEN @ 2048 MIN DUP _BSK-POST-LEN !
    BSK-BUF _BSK-POST-BUF ROT CMOVE ;

\ _BSK-QK ( addr len -- )  Append "key":  (quoted key + colon)
: _BSK-QK  ( addr len -- )
    34 BSK-EMIT  BSK-APPEND  34 BSK-EMIT  58 BSK-EMIT ;

\ _BSK-QV ( addr len -- )  Append "value" (quoted value)
: _BSK-QV  ( addr len -- )
    34 BSK-EMIT  BSK-APPEND  34 BSK-EMIT ;

\ _BSK-QV-ESC ( addr len -- )  Append "value" with JSON escaping
: _BSK-QV-ESC  ( addr len -- )
    34 BSK-EMIT  JSON-COPY-ESCAPED  34 BSK-EMIT ;

\ _BSK-COMMA ( -- )  Append comma
: _BSK-COMMA  ( -- )  44 BSK-EMIT ;

\ _BSK-CR-OPEN ( collection-addr collection-len -- )
\   Begin a createRecord JSON body with common fields.
\   Emits: {"repo":"<DID>","collection":"<col>","record":{"$type":"<col>",
: _BSK-CR-OPEN  ( caddr clen -- )
    BSK-RESET
    123 BSK-EMIT                      \ {
    S" repo" _BSK-QK
    BSK-DID BSK-DID-LEN @ _BSK-QV
    _BSK-COMMA
    S" collection" _BSK-QK
    2DUP _BSK-QV
    _BSK-COMMA
    S" record" _BSK-QK
    123 BSK-EMIT                      \ {
    S" $type" _BSK-QK
    _BSK-QV
    _BSK-COMMA ;

\ _BSK-CREATED-AT ( -- )  Append "createdAt":"<ISO8601>"
: _BSK-CREATED-AT  ( -- )
    S" createdAt" _BSK-QK
    BSK-NOW _BSK-QV ;

\ _BSK-CR-CLOSE ( -- )  Close record and outer braces: }}
: _BSK-CR-CLOSE  ( -- )
    125 BSK-EMIT  125 BSK-EMIT ;  \ }}

\ _BSK-SUBJECT ( uri-addr uri-len cid-addr cid-len -- )
\   Append "subject":{"uri":"...","cid":"..."}
: _BSK-SUBJECT  ( uaddr ulen caddr clen -- )
    2>R
    S" subject" _BSK-QK
    123 BSK-EMIT
    S" uri" _BSK-QK  _BSK-QV  _BSK-COMMA
    S" cid" _BSK-QK  2R> _BSK-QV
    125 BSK-EMIT ;

\ _BSK-DO-CREATE ( -- ok? )  Stage body, POST, check response.
: _BSK-DO-CREATE  ( -- ok? )
    BSK-ACCESS-LEN @ 0= IF
        ." bsky: login first" CR 0 EXIT
    THEN
    _BSK-STAGE-BODY
    S" /xrpc/com.atproto.repo.createRecord"
    _BSK-POST-BUF _BSK-POST-LEN @
    BSK-POST-JSON
    DUP 0= IF 2DROP ." bsky: create failed (network)" CR 0 EXIT THEN
    2DROP
    BSK-HTTP-STATUS @ 200 = ;

\ ── §5.2  BSK-POST ────────────────────────────────────────────────
\
\  BSK-POST ( text-addr text-len -- )
\  Post a new skeet.

: BSK-POST  ( addr len -- )
    S" app.bsky.feed.post" _BSK-CR-OPEN
    S" text" _BSK-QK
    _BSK-QV-ESC
    _BSK-COMMA
    _BSK-CREATED-AT
    _BSK-CR-CLOSE
    _BSK-DO-CREATE IF
        ." Posted!" CR
    ELSE
        ." bsky: post failed (HTTP " BSK-HTTP-STATUS @ . ." )" CR
    THEN ;

\ ── §5.3  BSK-REPLY ───────────────────────────────────────────────
\
\  BSK-REPLY ( uri-addr uri-len cid-addr cid-len text-addr text-len -- )
\  Reply to a post.  For simplicity, root = parent (no deep threading).

VARIABLE _BSK-REPLY-UADDR   VARIABLE _BSK-REPLY-ULEN
VARIABLE _BSK-REPLY-CADDR   VARIABLE _BSK-REPLY-CLEN

: BSK-REPLY  ( uaddr ulen caddr clen taddr tlen -- )
    \ Save reply target
    2>R 2>R
    _BSK-REPLY-ULEN !  _BSK-REPLY-UADDR !
    2R> _BSK-REPLY-CLEN !  _BSK-REPLY-CADDR !
    2R>                               ( text-addr text-len )
    S" app.bsky.feed.post" _BSK-CR-OPEN
    S" text" _BSK-QK
    _BSK-QV-ESC
    _BSK-COMMA
    \ Build reply object (root = parent for simplicity)
    S" reply" _BSK-QK
    123 BSK-EMIT                      \ {
    \ root
    S" root" _BSK-QK
    123 BSK-EMIT
    S" uri" _BSK-QK
    _BSK-REPLY-UADDR @ _BSK-REPLY-ULEN @ _BSK-QV  _BSK-COMMA
    S" cid" _BSK-QK
    _BSK-REPLY-CADDR @ _BSK-REPLY-CLEN @ _BSK-QV
    125 BSK-EMIT  _BSK-COMMA         \ },
    \ parent = root
    S" parent" _BSK-QK
    123 BSK-EMIT
    S" uri" _BSK-QK
    _BSK-REPLY-UADDR @ _BSK-REPLY-ULEN @ _BSK-QV  _BSK-COMMA
    S" cid" _BSK-QK
    _BSK-REPLY-CADDR @ _BSK-REPLY-CLEN @ _BSK-QV
    125 BSK-EMIT                      \ }
    125 BSK-EMIT  _BSK-COMMA         \ },  (close reply)
    _BSK-CREATED-AT
    _BSK-CR-CLOSE
    _BSK-DO-CREATE IF
        ." Replied!" CR
    ELSE
        ." bsky: reply failed (HTTP " BSK-HTTP-STATUS @ . ." )" CR
    THEN ;

\ ── §5.4  BSK-LIKE ────────────────────────────────────────────────
\
\  BSK-LIKE ( uri-addr uri-len cid-addr cid-len -- )
\  Like a post.

: BSK-LIKE  ( uaddr ulen caddr clen -- )
    S" app.bsky.feed.like" _BSK-CR-OPEN
    _BSK-SUBJECT
    _BSK-COMMA
    _BSK-CREATED-AT
    _BSK-CR-CLOSE
    _BSK-DO-CREATE IF
        ." Liked!" CR
    ELSE
        ." bsky: like failed (HTTP " BSK-HTTP-STATUS @ . ." )" CR
    THEN ;

\ ── §5.5  BSK-REPOST ─────────────────────────────────────────────
\
\  BSK-REPOST ( uri-addr uri-len cid-addr cid-len -- )
\  Repost (reshare).

: BSK-REPOST  ( uaddr ulen caddr clen -- )
    S" app.bsky.feed.repost" _BSK-CR-OPEN
    _BSK-SUBJECT
    _BSK-COMMA
    _BSK-CREATED-AT
    _BSK-CR-CLOSE
    _BSK-DO-CREATE IF
        ." Reposted!" CR
    ELSE
        ." bsky: repost failed (HTTP " BSK-HTTP-STATUS @ . ." )" CR
    THEN ;

\ =====================================================================
\  §5 — End of Write Features
\ =====================================================================
