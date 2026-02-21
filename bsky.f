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
\  Large receive buffer lives in HBW (3 MiB fast BRAM), avoiding
\  Bank 0 heap fragmentation.  Small fixed-size credential buffers
\  live in dictionary space (static CREATE+ALLOT).

65536 CONSTANT BSK-RECV-MAX          \ 64 KB receive buffer
VARIABLE BSK-RECV-BUF   0 BSK-RECV-BUF !   \ HBW address (set by BSK-INIT)
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

\ BSK-INIT ( -- )  Allocate HBW recv buffer, clear credential state
: BSK-INIT  ( -- )
    BSK-READY @ IF EXIT THEN        \ already initialised
    BSK-RECV-MAX HBW-ALLOT BSK-RECV-BUF !
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

\ _BSK-TLS-OPEN ( -- ctx | 0 )  TLS connect to cached server IP
: _BSK-TLS-OPEN  ( -- ctx | 0 )
    \ Set SNI hostname
    BSK-HOST-LEN 63 MIN DUP TLS-SNI-LEN !
    BSK-HOST TLS-SNI-HOST ROT CMOVE
    BSK-SERVER-IP @ 443 12345 TLS-CONNECT ;

\ _BSK-RECV-LOOP ( ctx -- )  Receive response into HBW recv buffer
: _BSK-RECV-LOOP  ( ctx -- )
    _BSK-CTX !
    0 BSK-RECV-LEN !  0 _BSK-EMPTY !
    500 0 DO
        TCP-POLL NET-IDLE
        BSK-RECV-LEN @ BSK-RECV-MAX >= IF LEAVE THEN
        _BSK-CTX @
        BSK-RECV-BUF @ BSK-RECV-LEN @ +
        BSK-RECV-MAX BSK-RECV-LEN @ -
        TLS-RECV
        DUP 0> IF
            BSK-RECV-LEN +!
            0 _BSK-EMPTY !
        ELSE DUP -1 = IF
            DROP ." bsky: TLS error" CR LEAVE
        ELSE
            DROP
            BSK-RECV-LEN @ 0> IF
                _BSK-EMPTY @ 1+ DUP _BSK-EMPTY !
                10 >= IF LEAVE THEN
            THEN
        THEN THEN
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
    9 < IF DROP 0 EXIT THEN          \ too short
    DUP 9 + SWAP 9 + DROP            \ skip "HTTP/1.x "
    \ addr now points at status digits (3 chars at offset 9)
    DUP C@ 48 - 100 *
    OVER 1+ C@ 48 - 10 * +
    SWAP 2 + C@ 48 - + ;

\ BSK-PARSE-RESPONSE ( -- body-addr body-len status )
\   Parse the raw HTTP response in BSK-RECV-BUF.
\   Returns body pointer (inside HBW buffer), body length, and status code.
: BSK-PARSE-RESPONSE  ( -- body-addr body-len status )
    BSK-RECV-BUF @ BSK-RECV-LEN @ _BSK-PARSE-STATUS
    BSK-HTTP-STATUS !
    \ Find header/body boundary
    BSK-RECV-BUF @ BSK-RECV-LEN @ _HTTP-FIND-HEND
    _HTTP-HEND @ 0= IF
        0 0 BSK-HTTP-STATUS @ EXIT   \ no headers found
    THEN
    \ _HTTP-HEND is absolute address — convert to offset
    _HTTP-HEND @ BSK-RECV-BUF @ - >R  \ R: hdr-end offset
    \ Parse Content-Length from headers
    BSK-RECV-BUF @ R@ _HTTP-PARSE-CLEN
    \ Body starts at hdr-end offset, length = total - offset
    BSK-RECV-BUF @ R@ +              ( body-addr )
    BSK-RECV-LEN @ R> -              ( body-addr body-len )
    _HTTP-CLEN @ -1 <> IF
        _HTTP-CLEN @ MIN
    THEN
    BSK-HTTP-STATUS @ ;

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
