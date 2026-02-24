\ bsky.f — Bluesky / AT Protocol client for Megapad-64
\
\ Depends on: KDOS v1.1 (network stack, RTC, memory), tools.f (TUI)
\             Akashic libraries (json, http, atproto, datetime, string)
\
\ Prefix conventions:
\   BSK-    public API words
\   _BSK-   internal helpers
\
\ Load with:   REQUIRE bsky.f

PROVIDED bsky.f

\ ── Akashic library dependencies ──────────────────────────────
\ All akashic .f files live flat on the disk (build_disk.py puts them
\ in the root).  Bare filenames ensure the REQUIRE guard matches the
\ names used by the akashic libs' own internal REQUIREs.
REQUIRE string.f
REQUIRE json.f
REQUIRE datetime.f
REQUIRE url.f
REQUIRE headers.f
REQUIRE base64.f
REQUIRE http.f
REQUIRE uri.f
REQUIRE xrpc.f
REQUIRE session.f
REQUIRE aturi.f
REQUIRE repo.f

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

\ ── §0.2  Helpers that delegate to akashic ────────────────────────

\ NUM>APPEND ( n -- )  Append decimal number to BSK-BUF
\   Uses akashic string.f NUM>STR (signed).
: NUM>APPEND  ( n -- )
    NUM>STR BSK-APPEND ;

\ BSK-NOW ( -- addr len )  ISO 8601 timestamp via akashic datetime.f
CREATE _BSK-TS-BUF 32 ALLOT
: BSK-NOW  ( -- addr len )
    DT-NOW _BSK-TS-BUF 32 DT-ISO8601 _BSK-TS-BUF SWAP ;

\ ── §0.4  URL Encoding (no akashic equivalent) ────────────────────
\
\  Percent-encodes characters outside the unreserved set
\  (RFC 3986 §2.3).  Used for query parameters.

: _BSK-HEX-DIGIT  ( n -- char )
    DUP 10 < IF 48 + ELSE 10 - 65 + THEN ;

: _BSK-URL-SAFE?  ( char -- flag )
    DUP 65 >= OVER 90 <= AND IF DROP -1 EXIT THEN   \ A-Z
    DUP 97 >= OVER 122 <= AND IF DROP -1 EXIT THEN  \ a-z
    DUP 48 >= OVER 57 <= AND IF DROP -1 EXIT THEN   \ 0-9
    DUP 45 = IF DROP -1 EXIT THEN                   \ -
    DUP 46 = IF DROP -1 EXIT THEN                   \ .
    DUP 95 = IF DROP -1 EXIT THEN                   \ _
    DUP 126 = IF DROP -1 EXIT THEN                  \ ~
    DROP 0 ;

: URL-ENCODE  ( addr len -- )
    0 DO
        DUP I + C@
        DUP _BSK-URL-SAFE? IF
            BSK-EMIT
        ELSE
            37 BSK-EMIT
            DUP 4 RSHIFT _BSK-HEX-DIGIT BSK-EMIT
            15 AND _BSK-HEX-DIGIT BSK-EMIT
        THEN
    LOOP DROP ;

\ JSON-COPY-ESCAPED ( addr len -- )
\   Append string to BSK-BUF with JSON escaping for \, ", and
\   control characters (< 32).  Used by _BSK-QV-ESC in §5.
: JSON-COPY-ESCAPED  ( addr len -- )
    0 DO
        DUP I + C@
        DUP 34 = IF DROP 92 BSK-EMIT 34 BSK-EMIT        \ " → \"
        ELSE DUP 92 = IF DROP 92 BSK-EMIT 92 BSK-EMIT   \ \ → \\
        ELSE DUP 10 = IF DROP 92 BSK-EMIT 110 BSK-EMIT  \ LF → \n
        ELSE DUP 13 = IF DROP 92 BSK-EMIT 114 BSK-EMIT  \ CR → \r
        ELSE DUP  9 = IF DROP 92 BSK-EMIT 116 BSK-EMIT  \ TAB → \t
        ELSE DUP 32 < IF DROP 63 BSK-EMIT               \ other ctrl → ?
        ELSE BSK-EMIT
        THEN THEN THEN THEN THEN THEN
    LOOP DROP ;

\ =====================================================================
\  §0 — End of Foundation Utilities
\ =====================================================================

\ =====================================================================
\  §1  JSON Parser — REPLACED by akashic json.f
\ =====================================================================
\
\  The old hand-rolled flat-scan parser is deleted.  All JSON parsing
\  now uses akashic json.f (depth-aware, zero-copy, with builder).
\
\  Compatibility shims for callers not yet migrated to the akashic API:

\ JSON-FIND-KEY ( jaddr jlen kaddr klen -- vaddr vlen | 0 0 )
\   Compat shim: enter top-level object, then look up key.
\   Old code expected flat scanning; new code does depth-aware lookup.
: JSON-FIND-KEY  ( jaddr jlen kaddr klen -- vaddr vlen | 0 0 )
    2>R JSON-ENTER 2R> JSON-KEY?
    0= IF 2DROP 0 0 THEN ;

\ JSON-GET-ARRAY ( jaddr jlen kaddr klen -- aaddr alen )
\   Compat shim: find array value for key, enter it.
: JSON-GET-ARRAY  ( jaddr jlen kaddr klen -- aaddr alen )
    JSON-FIND-KEY DUP 0= IF EXIT THEN
    JSON-ENTER ;

\ JSON-NEXT-ITEM ( addr len -- addr' len' | 0 0 )
\   Compat shim: advance to next array element.
: JSON-NEXT-ITEM  ( addr len -- addr' len' | 0 0 )
    JSON-NEXT 0= IF 2DROP 0 0 THEN ;

\ =====================================================================
\  §1 — End of JSON Compat Shims
\ =====================================================================

\ =====================================================================
\  §2  HTTP + Session Infrastructure — REPLACED by akashic
\ =====================================================================
\
\  The old hand-rolled HTTP stack (DNS caching, TLS wrapper, request
\  builders, response parser, chunked decoder) is deleted.  All HTTP
\  is now handled by akashic http.f.
\
\  What remains:
\  - BSK-HANDLE (session.f doesn't store the handle)
\  - BSK-INIT / BSK-CLEANUP (XMEM allocation, HTTP buffer setup)
\  - Compat shims for BSK-GET, BSK-POST-JSON, BSK-HTTP-STATUS

\ ── §2.1  Handle Storage (session.f doesn't keep this) ────────────

64 CONSTANT BSK-HANDLE-MAX
CREATE BSK-HANDLE BSK-HANDLE-MAX ALLOT
VARIABLE BSK-HANDLE-LEN   0 BSK-HANDLE-LEN !

\ ── §2.2  Init / Cleanup ──────────────────────────────────────────

65536 CONSTANT BSK-RECV-MAX
VARIABLE BSK-RECV-BUF   0 BSK-RECV-BUF !
VARIABLE BSK-READY      0 BSK-READY !

: BSK-INIT  ( -- )
    BSK-READY @ IF EXIT THEN
    BSK-RECV-MAX XMEM-ALLOT BSK-RECV-BUF !
    BSK-RECV-BUF @ BSK-RECV-MAX HTTP-USE-STATIC
    S" KDOS/1.1 Megapad-64" HTTP-SET-UA
    BSK-HANDLE BSK-HANDLE-MAX 0 FILL  0 BSK-HANDLE-LEN !
    -1 BSK-READY !
    ." bsky: init ok" CR ;

: BSK-CLEANUP  ( -- )
    BSK-READY @ 0= IF EXIT THEN
    0 BSK-RECV-BUF !
    0 BSK-READY ! ;

\ ── §2.3  Session Helpers ─────────────────────────────────────────

\ BSK-LOGGED-IN? ( -- flag )  True if session is active
: BSK-LOGGED-IN?  ( -- flag )  SESS-ACTIVE? ;

\ Compat variables — §4-§6 still reference these directly.
\ BSK-ACCESS-LEN is used everywhere as `BSK-ACCESS-LEN @ 0=` to
\ test login state.  Set to 1 after login, 0 on logout/init.
\ BSK-DID/BSK-DID-LEN provide a local copy of the DID — the akashic
\ SESS-DID returns (addr len) from internal storage but the old
\ callers expect BSK-DID (address) + BSK-DID-LEN @ (length).
VARIABLE BSK-ACCESS-LEN   0 BSK-ACCESS-LEN !

128 CONSTANT BSK-DID-MAX
CREATE BSK-DID BSK-DID-MAX ALLOT
VARIABLE BSK-DID-LEN      0 BSK-DID-LEN !

\ ── §2.4  Compat Shims (removed in Stage 5+6) ────────────────────
\
\  BSK-GET and BSK-POST-JSON bridge old path-based callers to the
\  akashic HTTP stack.  These build full URLs from paths.

\ BSK-HTTP-STATUS — alias for akashic HTTP-STATUS
: BSK-HTTP-STATUS  ( -- addr )  HTTP-STATUS ;

\ _BSK-PATH-TO-URL ( path-a path-u -- )
\   Build "https://bsky.social<path>" into BSK-BUF.
: _BSK-PATH-TO-URL  ( path-a path-u -- )
    BSK-RESET
    S" https://bsky.social" BSK-APPEND
    BSK-APPEND ;

\ BSK-GET ( path-addr path-len -- body-addr body-len )
\   Compat shim: build URL, call HTTP-GET.
: BSK-GET  ( path-addr path-len -- body-addr body-len )
    _BSK-PATH-TO-URL
    BSK-BUF BSK-LEN @
    HTTP-GET ;

\ BSK-POST-JSON ( path-a path-u json-a json-u -- body-a body-u )
\   Compat shim: build URL, call HTTP-POST-JSON.
CREATE _BSK-URL-TMP 512 ALLOT
VARIABLE _BSK-URL-LEN

: BSK-POST-JSON  ( path-a path-u json-a json-u -- body-a body-u )
    2>R                              \ save json
    _BSK-PATH-TO-URL
    \ Copy URL to temp buf (BSK-BUF will be overwritten by HTTP)
    BSK-LEN @ _BSK-URL-LEN !
    BSK-BUF _BSK-URL-TMP BSK-LEN @ CMOVE
    _BSK-URL-TMP _BSK-URL-LEN @
    2R>                              \ restore json
    HTTP-POST-JSON ;

\ =====================================================================
\  §3  Authentication — REPLACED by akashic session.f
\ =====================================================================
\
\  Login/refresh/who via akashic session.f (SESS-LOGIN, SESS-REFRESH,
\  SESS-DID, SESS-ACTIVE?).
\
\  session.f stores accessJwt, refreshJwt, did internally and sets
\  HTTP-SET-BEARER on login.  We only keep BSK-HANDLE locally
\  (session.f doesn't store handle), plus compat variables
\  BSK-ACCESS-LEN / BSK-DID / BSK-DID-LEN for §4-§6 callers.

\ ── §3.1  Sync Compat After Login ─────────────────────────────────
\
\  After SESS-LOGIN or SESS-REFRESH succeeds, copy DID to local buf
\  and set BSK-ACCESS-LEN to 1 (compat flag for login-check guards).

: _BSK-SYNC-SESSION  ( -- )
    SESS-DID                         ( did-a did-u )
    DUP BSK-DID-MAX MIN             \ clamp
    DUP BSK-DID-LEN !
    BSK-DID SWAP CMOVE
    1 BSK-ACCESS-LEN ! ;

\ ── §3.2  Login ───────────────────────────────────────────────────

\ Temp parse buffers (used only during login)
CREATE _BSK-LOGIN-HANDLE 128 ALLOT
VARIABLE _BSK-LOGIN-HLEN   0 _BSK-LOGIN-HLEN !
CREATE _BSK-LOGIN-PASS 128 ALLOT
VARIABLE _BSK-LOGIN-PLEN   0 _BSK-LOGIN-PLEN !

\ BSK-LOGIN-WITH ( handle-a handle-u pass-a pass-u -- )
\   Programmatic login.  Saves handle locally, delegates to SESS-LOGIN.
: BSK-LOGIN-WITH  ( handle-a handle-u pass-a pass-u -- )
    BSK-INIT
    \ Save handle before SESS-LOGIN (it doesn't store it)
    2OVER BSK-HANDLE-MAX MIN         ( h-a h-u p-a p-u h-a h-u' )
    >R BSK-HANDLE R@ CMOVE
    R> BSK-HANDLE-LEN !
    SESS-LOGIN                       ( ior )
    DUP 0<> IF
        ." bsky: login failed (ior=" . ." )" CR
        0 BSK-ACCESS-LEN !
        EXIT
    THEN DROP
    _BSK-SYNC-SESSION
    ." Logged in as " BSK-HANDLE BSK-HANDLE-LEN @ TYPE CR ;

\ BSK-LOGIN ( "handle" "password" -- )
\   User-facing word.  Reads handle and password from input stream.
\   Usage:  BSK-LOGIN myname.bsky.social xxxx-xxxx-xxxx-xxxx
: BSK-LOGIN  ( "handle" "password" -- )
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

\ ── §3.3  Token Refresh ──────────────────────────────────────────

: BSK-REFRESH  ( -- )
    BSK-ACCESS-LEN @ 0= IF
        ." bsky: not logged in — login first" CR EXIT
    THEN
    SESS-REFRESH                     ( ior )
    DUP 0<> IF
        ." bsky: refresh failed (ior=" . ." )" CR EXIT
    THEN DROP
    _BSK-SYNC-SESSION
    ." bsky: tokens refreshed" CR ;

\ ── §3.4  Session Info ────────────────────────────────────────────

: BSK-WHO  ( -- )
    BSK-ACCESS-LEN @ 0= IF
        ." Not logged in" CR EXIT
    THEN
    ." Handle: " BSK-HANDLE BSK-HANDLE-LEN @ TYPE CR
    ." DID:    " BSK-DID BSK-DID-LEN @ TYPE CR
    ." Session active" CR ;

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
    S" post" JSON-FIND-KEY         ( post-addr post-len )
    DUP 0= IF 2DROP EXIT THEN
    \ Navigate post → author for handle + displayName
    2DUP S" author" JSON-FIND-KEY   ( post-a post-l auth-a auth-l )
    DUP 0> IF
        2DUP S" handle" JSON-FIND-KEY
        DUP 0> IF
            JSON-GET-STRING
            ." @" 76 _BSK-TYPE-TRUNC
        ELSE 2DROP THEN
        S" displayName" JSON-FIND-KEY
        DUP 0> IF
            JSON-GET-STRING
            DUP 0> IF
                ."  (" 60 _BSK-TYPE-TRUNC ." )"
            ELSE 2DROP THEN
        ELSE 2DROP THEN
    ELSE 2DROP THEN
    CR
    \ Navigate post → record → text
    S" record" JSON-FIND-KEY
    DUP 0> IF
        S" text" JSON-FIND-KEY
        DUP 0> IF
            JSON-GET-STRING
            DUP 0> IF
                ."   " 200 _BSK-TYPE-TRUNC CR
            ELSE 2DROP THEN
        ELSE 2DROP THEN
    ELSE 2DROP THEN
    ." ---" CR ;

\ _BSK-TL-PATH ( -- addr len )
\   Build the timeline request path with limit parameter.
\   If a cursor is stored, appends &cursor=<cursor>.
: _BSK-TL-PATH  ( -- addr len )
    BSK-RESET
    S" /xrpc/app.bsky.feed.getTimeline?limit=10" BSK-APPEND
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
    \ Extract reason — top-level key
    2DUP S" reason" JSON-FIND-KEY
    DUP 0> IF
        JSON-GET-STRING
        DUP 0> IF
            20 _BSK-TYPE-TRUNC
        ELSE 2DROP THEN
    ELSE 2DROP THEN
    ."  from "
    \ Navigate author → handle (handle is inside author object)
    S" author" JSON-FIND-KEY
    DUP 0> IF
        S" handle" JSON-FIND-KEY
        DUP 0> IF
            JSON-GET-STRING
            DUP 0> IF
                ." @" 40 _BSK-TYPE-TRUNC
            ELSE 2DROP THEN
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

\ ── §5.5  BSK-FOLLOW / BSK-UNFOLLOW ───────────────────────────────
\
\  BSK-FOLLOW ( did-addr did-len -- )
\  Follow a user by DID.

: BSK-FOLLOW  ( addr len -- )
    S" app.bsky.graph.follow" _BSK-CR-OPEN
    S" subject" _BSK-QK
    _BSK-QV
    _BSK-COMMA
    _BSK-CREATED-AT
    _BSK-CR-CLOSE
    _BSK-DO-CREATE IF
        ." Followed!" CR
    ELSE
        ." bsky: follow failed (HTTP " BSK-HTTP-STATUS @ . ." )" CR
    THEN ;

\ _BSK-DO-DELETE ( -- ok? )  Stage body, POST deleteRecord, check.
: _BSK-DO-DELETE  ( -- ok? )
    BSK-ACCESS-LEN @ 0= IF
        ." bsky: login first" CR 0 EXIT
    THEN
    _BSK-STAGE-BODY
    S" /xrpc/com.atproto.repo.deleteRecord"
    _BSK-POST-BUF _BSK-POST-LEN @
    BSK-POST-JSON
    DUP 0= IF 2DROP ." bsky: delete failed (network)" CR 0 EXIT THEN
    2DROP
    BSK-HTTP-STATUS @ 200 = ;

\ _BSK-DR-OPEN ( collection-addr collection-len rkey-addr rkey-len -- )
\   Build deleteRecord JSON: {"repo":"<DID>","collection":"...","rkey":"..."}
: _BSK-DR-OPEN  ( caddr clen rkaddr rklen -- )
    2>R
    BSK-RESET
    123 BSK-EMIT
    S" repo" _BSK-QK
    BSK-DID BSK-DID-LEN @ _BSK-QV  _BSK-COMMA
    S" collection" _BSK-QK
    _BSK-QV  _BSK-COMMA
    S" rkey" _BSK-QK
    2R> _BSK-QV
    125 BSK-EMIT ;

\ BSK-UNFOLLOW ( rkey-addr rkey-len -- )
\   Unfollow by rkey (the record key of the follow record).
: BSK-UNFOLLOW  ( addr len -- )
    S" app.bsky.graph.follow" 2SWAP
    _BSK-DR-OPEN
    _BSK-DO-DELETE IF
        ." Unfollowed!" CR
    ELSE
        ." bsky: unfollow failed (HTTP " BSK-HTTP-STATUS @ . ." )" CR
    THEN ;

\ ── §5.6  BSK-DELETE ──────────────────────────────────────────────
\
\  BSK-DELETE ( uri-addr uri-len -- )
\  Delete a record by AT URI.
\  AT URI format: at://did:plc:xxx/app.bsky.feed.post/3abc...
\  We extract the collection and rkey from the last two path segments.

\ _BSK-RFIND-SLASH ( addr len -- offset | -1 )
\   Find the last '/' in string.  Returns offset from addr.
: _BSK-RFIND-SLASH  ( addr len -- offset )
    1- BEGIN
        DUP 0< IF NIP EXIT THEN
        2DUP + C@ 47 = IF NIP EXIT THEN
        1-
    AGAIN ;

\ _BSK-URI-PARSE ( uri-addr uri-len -- col-a col-l rkey-a rkey-l ok? )
\   Extract collection and rkey from AT URI.
\   Returns addresses pointing into the original string.
VARIABLE _BUP-ADDR   VARIABLE _BUP-LEN
VARIABLE _BUP-S2     VARIABLE _BUP-S1

: _BSK-URI-PARSE  ( uaddr ulen -- ca cl ra rl flag )
    _BUP-LEN !  _BUP-ADDR !
    \ Find last slash (separates collection/rkey)
    _BUP-ADDR @  _BUP-LEN @  _BSK-RFIND-SLASH
    DUP 0< IF 0 0 0 0 0 EXIT THEN
    _BUP-S2 !
    \ Find second-to-last slash (separates repo/collection)
    _BUP-ADDR @  _BUP-S2 @  _BSK-RFIND-SLASH
    DUP 0< IF 0 0 0 0 0 EXIT THEN
    _BUP-S1 !
    \ collection = addr+s1+1, length = s2-s1-1
    _BUP-ADDR @ _BUP-S1 @ + 1+
    _BUP-S2 @ _BUP-S1 @ - 1-
    \ rkey = addr+s2+1, length = total-s2-1
    _BUP-ADDR @ _BUP-S2 @ + 1+
    _BUP-LEN @ _BUP-S2 @ - 1-
    -1 ;

\ BSK-DELETE ( uri-addr uri-len -- )
\   Delete any record by AT-URI.
: BSK-DELETE  ( uaddr ulen -- )
    _BSK-URI-PARSE 0= IF
        ." bsky: invalid AT-URI" CR EXIT
    THEN
    \ ( col-a col-l rkey-a rkey-l )
    _BSK-DR-OPEN
    _BSK-DO-DELETE IF
        ." Deleted!" CR
    ELSE
        ." bsky: delete failed (HTTP " BSK-HTTP-STATUS @ . ." )" CR
    THEN ;

\ =====================================================================
\  §5 — End of Write Features
\ =====================================================================

\ =====================================================================
\  §6  Interactive TUI (KDOS Screens Integration)
\ =====================================================================
\
\  Registers a Bluesky screen [9] with three subscreens:
\    [Timeline]  [Notifs]  [Profile]
\
\  The screen is selectable (flag=1) — n/p navigates posts/items,
\  Enter activates.  Per-screen key handler:
\    f = fetch/refresh   l = like   t = repost   d = delete
\    c = compose post    y = reply to selected post
\
\  Data is cached in fixed-size arrays to avoid re-fetching on each
\  screen redraw.  Press 'f' to fetch fresh data from the API.

\ ── §6.1  Cache Data Model ────────────────────────────────────────
\
\  Fixed-size slot arrays for timeline posts, notifications, and
\  profile data.  Separate length arrays track actual stored length
\  per slot.

10 CONSTANT _BSK-TL-MAX      \ max cached timeline posts
32 CONSTANT _BSK-HS          \ handle slot size (bytes)
600 CONSTANT _BSK-TS         \ text slot size (up to 300-char post + URLs)
100 CONSTANT _BSK-US         \ URI slot size
64 CONSTANT _BSK-CS          \ CID slot size

\ Timeline post cache arrays
CREATE _BSK-TL-H   _BSK-TL-MAX _BSK-HS * ALLOT    \ handles
CREATE _BSK-TL-HL  _BSK-TL-MAX CELLS ALLOT         \ handle lengths
CREATE _BSK-TL-T   _BSK-TL-MAX _BSK-TS * ALLOT    \ post texts
CREATE _BSK-TL-TL  _BSK-TL-MAX CELLS ALLOT         \ text lengths
CREATE _BSK-TL-U   _BSK-TL-MAX _BSK-US * ALLOT    \ AT URIs
CREATE _BSK-TL-UL  _BSK-TL-MAX CELLS ALLOT         \ URI lengths
CREATE _BSK-TL-C   _BSK-TL-MAX _BSK-CS * ALLOT    \ CIDs
CREATE _BSK-TL-CL  _BSK-TL-MAX CELLS ALLOT         \ CID lengths
VARIABLE _BSK-TL-N   0 _BSK-TL-N !                 \ cached count

\ Notification cache arrays
10 CONSTANT _BSK-NF-MAX
20 CONSTANT _BSK-RS           \ reason slot size

CREATE _BSK-NF-R   _BSK-NF-MAX _BSK-RS * ALLOT    \ reasons
CREATE _BSK-NF-RL  _BSK-NF-MAX CELLS ALLOT         \ reason lengths
CREATE _BSK-NF-H   _BSK-NF-MAX _BSK-HS * ALLOT    \ author handles
CREATE _BSK-NF-HL  _BSK-NF-MAX CELLS ALLOT         \ handle lengths
VARIABLE _BSK-NF-N   0 _BSK-NF-N !                 \ cached count

\ Profile cache
CREATE _BSK-PR-DN   64 ALLOT   VARIABLE _BSK-PR-DNL  0 _BSK-PR-DNL !
CREATE _BSK-PR-H    40 ALLOT   VARIABLE _BSK-PR-HL   0 _BSK-PR-HL !
CREATE _BSK-PR-D   200 ALLOT   VARIABLE _BSK-PR-DL   0 _BSK-PR-DL !
VARIABLE _BSK-PR-FC  0 _BSK-PR-FC !    \ followersCount
VARIABLE _BSK-PR-FG  0 _BSK-PR-FG !    \ followsCount
VARIABLE _BSK-PR-PC  0 _BSK-PR-PC !    \ postsCount
VARIABLE _BSK-PR-OK  0 _BSK-PR-OK !    \ profile loaded?

\ Compose buffer
CREATE _BSK-COMP-BUF 300 ALLOT

\ Status message for feedback
CREATE _BSK-STATUS 64 ALLOT
VARIABLE _BSK-STATUS-LEN  0 _BSK-STATUS-LEN !

\ ── §6.2  Cache Accessors ─────────────────────────────────────────
\
\  Store:  _BSK-TL-H!  ( addr len i -- )   copy string into slot i
\  Fetch:  _BSK-TL-HANDLE  ( i -- addr len )   return pointer+length

VARIABLE _BSK-CI   \ cache index temp

\ Timeline handle
: _BSK-TL-H!  ( addr len i -- )
    _BSK-CI !
    _BSK-HS MIN DUP _BSK-CI @ CELLS _BSK-TL-HL + !
    _BSK-CI @ _BSK-HS * _BSK-TL-H + SWAP CMOVE ;
: _BSK-TL-HANDLE  ( i -- addr len )
    DUP _BSK-HS * _BSK-TL-H +  SWAP CELLS _BSK-TL-HL + @ ;

\ Timeline text
: _BSK-TL-T!  ( addr len i -- )
    _BSK-CI !
    _BSK-TS MIN DUP _BSK-CI @ CELLS _BSK-TL-TL + !
    _BSK-CI @ _BSK-TS * _BSK-TL-T + SWAP CMOVE ;
: _BSK-TL-TEXT  ( i -- addr len )
    DUP _BSK-TS * _BSK-TL-T +  SWAP CELLS _BSK-TL-TL + @ ;

\ Timeline URI
: _BSK-TL-U!  ( addr len i -- )
    _BSK-CI !
    _BSK-US MIN DUP _BSK-CI @ CELLS _BSK-TL-UL + !
    _BSK-CI @ _BSK-US * _BSK-TL-U + SWAP CMOVE ;
: _BSK-TL-URI  ( i -- addr len )
    DUP _BSK-US * _BSK-TL-U +  SWAP CELLS _BSK-TL-UL + @ ;

\ Timeline CID
: _BSK-TL-C!  ( addr len i -- )
    _BSK-CI !
    _BSK-CS MIN DUP _BSK-CI @ CELLS _BSK-TL-CL + !
    _BSK-CI @ _BSK-CS * _BSK-TL-C + SWAP CMOVE ;
: _BSK-TL-CID  ( i -- addr len )
    DUP _BSK-CS * _BSK-TL-C +  SWAP CELLS _BSK-TL-CL + @ ;

\ Notification reason
: _BSK-NF-R!  ( addr len i -- )
    _BSK-CI !
    _BSK-RS MIN DUP _BSK-CI @ CELLS _BSK-NF-RL + !
    _BSK-CI @ _BSK-RS * _BSK-NF-R + SWAP CMOVE ;
: _BSK-NF-REASON  ( i -- addr len )
    DUP _BSK-RS * _BSK-NF-R +  SWAP CELLS _BSK-NF-RL + @ ;

\ Notification handle
: _BSK-NF-H!  ( addr len i -- )
    _BSK-CI !
    _BSK-HS MIN DUP _BSK-CI @ CELLS _BSK-NF-HL + !
    _BSK-CI @ _BSK-HS * _BSK-NF-H + SWAP CMOVE ;
: _BSK-NF-HANDLE  ( i -- addr len )
    DUP _BSK-HS * _BSK-NF-H +  SWAP CELLS _BSK-NF-HL + @ ;

\ Status message
: _BSK-SET-STATUS  ( addr len -- )
    64 MIN DUP _BSK-STATUS-LEN !
    _BSK-STATUS SWAP CMOVE ;
: _BSK-CLR-STATUS  ( -- )  0 _BSK-STATUS-LEN ! ;

\ ── §6.3  Fetch & Populate ────────────────────────────────────────
\
\  Fetch data from the API, parse JSON, fill cache arrays.

\ _BSK-TL-CACHE-ITEM ( item-addr item-len idx -- )
\   Parse one feed item JSON and cache handle, text, URI, CID.
VARIABLE _BSK-FI

: _BSK-TL-CACHE-ITEM  ( addr len idx -- )
    _BSK-FI !
    \ Navigate to "post" object within feed item
    2DUP S" post" JSON-FIND-KEY
    DUP 0= IF 2DROP 2DROP EXIT THEN
    \ Cache post.uri
    2DUP S" uri" JSON-FIND-KEY
    DUP 0> IF
        JSON-GET-STRING DUP 0> IF _BSK-FI @ _BSK-TL-U!
        ELSE 2DROP THEN
    ELSE 2DROP THEN
    \ Cache post.cid
    2DUP S" cid" JSON-FIND-KEY
    DUP 0> IF
        JSON-GET-STRING DUP 0> IF _BSK-FI @ _BSK-TL-C!
        ELSE 2DROP THEN
    ELSE 2DROP THEN
    \ Cache author.handle — navigate post → author → handle
    2DUP S" author" JSON-FIND-KEY
    DUP 0> IF
        S" handle" JSON-FIND-KEY
        DUP 0> IF
            JSON-GET-STRING DUP 0> IF _BSK-FI @ _BSK-TL-H!
            ELSE 2DROP THEN
        ELSE 2DROP THEN
    ELSE 2DROP THEN
    \ Cache record.text — navigate post → record → text
    2DUP S" record" JSON-FIND-KEY
    DUP 0> IF
        S" text" JSON-FIND-KEY
        DUP 0> IF
            JSON-GET-STRING DUP 0> IF _BSK-FI @ _BSK-TL-T!
            ELSE 2DROP THEN
        ELSE 2DROP THEN
    ELSE 2DROP THEN
    2DROP       \ drop post scope
    2DROP ;     \ drop item scope

\ _BSK-TL-FETCH ( -- )   Fetch timeline and populate cache.
: _BSK-TL-FETCH  ( -- )
    BSK-ACCESS-LEN @ 0= IF
        S" Not logged in" _BSK-SET-STATUS EXIT
    THEN
    _BSK-TL-PATH BSK-GET
    DUP 0= IF 2DROP
        S" Fetch failed" _BSK-SET-STATUS EXIT
    THEN
    BSK-HTTP-STATUS @ 200 <> IF 2DROP
        S" HTTP error" _BSK-SET-STATUS EXIT
    THEN
    \ Save cursor for pagination
    2DUP S" cursor" JSON-FIND-KEY
    DUP 0> IF
        JSON-GET-STRING DUP 128 <= IF
            DUP BSK-TL-CURSOR-LEN !
            BSK-TL-CURSOR SWAP CMOVE
        ELSE 2DROP THEN
    ELSE 2DROP THEN
    \ Reset cache
    0 _BSK-TL-N !
    \ Navigate to feed array
    2DUP S" feed" JSON-FIND-KEY
    DUP 0= IF 2DROP 2DROP
        S" No feed data" _BSK-SET-STATUS EXIT
    THEN
    JSON-SKIP-WS
    OVER C@ 91 <> IF 2DROP 2DROP EXIT THEN
    1 /STRING JSON-SKIP-WS
    \ Iterate items, cache up to _BSK-TL-MAX
    BEGIN
        DUP 0> IF OVER C@ 93 <> ELSE 0 THEN
        _BSK-TL-N @ _BSK-TL-MAX < AND
    WHILE
        2DUP _BSK-TL-N @ _BSK-TL-CACHE-ITEM
        1 _BSK-TL-N +!
        JSON-SKIP-VALUE
        JSON-SKIP-WS
        DUP 0> IF
            OVER C@ 44 = IF 1 /STRING JSON-SKIP-WS THEN
        THEN
    REPEAT
    2DROP 2DROP
    S" Timeline loaded" _BSK-SET-STATUS ;

\ _BSK-NF-CACHE-ITEM ( item-addr item-len idx -- )
\   Parse one notification and cache reason + handle.
: _BSK-NF-CACHE-ITEM  ( addr len idx -- )
    _BSK-FI !
    \ Cache reason
    2DUP S" reason" JSON-FIND-KEY
    DUP 0> IF
        JSON-GET-STRING DUP 0> IF _BSK-FI @ _BSK-NF-R!
        ELSE 2DROP THEN
    ELSE 2DROP THEN
    \ Cache author.handle — navigate author → handle
    S" author" JSON-FIND-KEY
    DUP 0> IF
        S" handle" JSON-FIND-KEY
        DUP 0> IF
            JSON-GET-STRING DUP 0> IF _BSK-FI @ _BSK-NF-H!
            ELSE 2DROP THEN
        ELSE 2DROP THEN
    ELSE 2DROP THEN ;

\ _BSK-NF-FETCH ( -- )   Fetch notifications and populate cache.
: _BSK-NF-FETCH  ( -- )
    BSK-ACCESS-LEN @ 0= IF
        S" Not logged in" _BSK-SET-STATUS EXIT
    THEN
    BSK-RESET
    S" /xrpc/app.bsky.notification.listNotifications?limit=10" BSK-APPEND
    _BSK-SAVE-PATH BSK-GET
    DUP 0= IF 2DROP
        S" Fetch failed" _BSK-SET-STATUS EXIT
    THEN
    BSK-HTTP-STATUS @ 200 <> IF 2DROP
        S" HTTP error" _BSK-SET-STATUS EXIT
    THEN
    0 _BSK-NF-N !
    2DUP S" notifications" JSON-FIND-KEY
    DUP 0= IF 2DROP 2DROP
        S" No notifications" _BSK-SET-STATUS EXIT
    THEN
    JSON-SKIP-WS
    OVER C@ 91 <> IF 2DROP 2DROP EXIT THEN
    1 /STRING JSON-SKIP-WS
    BEGIN
        DUP 0> IF OVER C@ 93 <> ELSE 0 THEN
        _BSK-NF-N @ _BSK-NF-MAX < AND
    WHILE
        2DUP _BSK-NF-N @ _BSK-NF-CACHE-ITEM
        1 _BSK-NF-N +!
        JSON-SKIP-VALUE
        JSON-SKIP-WS
        DUP 0> IF
            OVER C@ 44 = IF 1 /STRING JSON-SKIP-WS THEN
        THEN
    REPEAT
    2DROP 2DROP
    S" Notifications loaded" _BSK-SET-STATUS ;

\ _BSK-PR-FETCH ( -- )   Fetch own profile and populate cache.
: _BSK-PR-FETCH  ( -- )
    BSK-ACCESS-LEN @ 0= IF
        S" Not logged in" _BSK-SET-STATUS EXIT
    THEN
    BSK-DID BSK-DID-LEN @ _BSK-PROFILE-PATH BSK-GET
    DUP 0= IF 2DROP
        S" Fetch failed" _BSK-SET-STATUS EXIT
    THEN
    BSK-HTTP-STATUS @ 200 <> IF 2DROP
        S" HTTP error" _BSK-SET-STATUS EXIT
    THEN
    \ Cache displayName
    2DUP S" displayName" JSON-FIND-KEY
    DUP 0> IF
        JSON-GET-STRING DUP 0> IF
            64 MIN DUP _BSK-PR-DNL !
            _BSK-PR-DN SWAP CMOVE
        ELSE 2DROP THEN
    ELSE 2DROP THEN
    \ Cache handle
    2DUP S" handle" JSON-FIND-KEY
    DUP 0> IF
        JSON-GET-STRING DUP 0> IF
            40 MIN DUP _BSK-PR-HL !
            _BSK-PR-H SWAP CMOVE
        ELSE 2DROP THEN
    ELSE 2DROP THEN
    \ Cache description
    2DUP S" description" JSON-FIND-KEY
    DUP 0> IF
        JSON-GET-STRING DUP 0> IF
            200 MIN DUP _BSK-PR-DL !
            _BSK-PR-D SWAP CMOVE
        ELSE 2DROP THEN
    ELSE 2DROP THEN
    \ Cache numeric stats
    2DUP S" followersCount" JSON-FIND-KEY
    DUP 0> IF JSON-GET-NUMBER _BSK-PR-FC ! ELSE 2DROP THEN
    2DUP S" followsCount" JSON-FIND-KEY
    DUP 0> IF JSON-GET-NUMBER _BSK-PR-FG ! ELSE 2DROP THEN
    2DUP S" postsCount" JSON-FIND-KEY
    DUP 0> IF JSON-GET-NUMBER _BSK-PR-PC ! ELSE 2DROP THEN
    2DROP
    -1 _BSK-PR-OK !
    S" Profile loaded" _BSK-SET-STATUS ;

\ ── §6.4  Row Renderers ───────────────────────────────────────────
\
\  Called by W.LIST for each item.  Signature: ( i -- )

\ .BSK-TL-ROW ( i -- )   Print one timeline post row.
: .BSK-TL-ROW  ( i -- )
    DUP _BSK-TL-HANDLE
    DUP 0> IF
        ." @" 20 _BSK-TYPE-TRUNC
    ELSE 2DROP THEN
    ."  "
    _BSK-TL-TEXT
    DUP 0> IF
        50 _BSK-TYPE-TRUNC
    ELSE 2DROP THEN ;

\ .BSK-NF-ROW ( i -- )   Print one notification row.
: .BSK-NF-ROW  ( i -- )
    DUP _BSK-NF-REASON
    DUP 0> IF
        18 _BSK-TYPE-TRUNC
    ELSE 2DROP THEN
    ."  @"
    _BSK-NF-HANDLE
    DUP 0> IF
        40 _BSK-TYPE-TRUNC
    ELSE 2DROP THEN ;

\ .BSK-TL-DETAIL ( -- )   Show detail for selected timeline post.
: .BSK-TL-DETAIL  ( -- )
    SCR-SEL @
    DUP _BSK-TL-HANDLE
    DUP 0> IF
        BOLD ."   @" TYPE RESET-COLOR CR
    ELSE 2DROP THEN
    DUP _BSK-TL-TEXT
    DUP 0> IF
        CR ."   " TYPE CR
    ELSE 2DROP THEN
    CR
    _BSK-TL-URI
    DUP 0> IF
        DIM ."   " 78 _BSK-TYPE-TRUNC RESET-COLOR CR
    ELSE 2DROP THEN ;

\ ── §6.5  Screen Renderers ────────────────────────────────────────
\
\  Each subscreen is a word that calls W.xxx widgets.

\ Profile value printers (for W.KV-XT)
: .BSK-PR-DN  ( -- )  _BSK-PR-DN _BSK-PR-DNL @ TYPE ;
: .BSK-PR-HA  ( -- )  ." @" _BSK-PR-H _BSK-PR-HL @ TYPE ;

\ Show whose feed this is in the title
: .BSK-TL-TITLE  ( -- )
    _BSK-TL-N @ 0> IF
        ." @" BSK-HANDLE BSK-HANDLE-LEN @ TYPE ."  "
    THEN ;

\ Common hint bar for timeline subscreen
: .BSK-TL-HINTS  ( -- )
    _BSK-TL-N @ 0> IF
        S" [l]Like [t]Repost [y]Reply [d]Delete [c]Compose [f]Refresh  [Enter]Open" W.HINT
    THEN ;

\ SCR-BSKY-TL ( -- )   Timeline subscreen
: SCR-BSKY-TL  ( -- )
    _BSK-TL-N @ 0= IF
        S" Timeline" W.TITLE
        S" Press [f] to fetch your timeline" W.HINT
    ELSE
        _BSK-TL-N @ S" Timeline" W.TITLE-N
        W.GAP
        ['] .BSK-TL-TITLE W.CUSTOM
        _BSK-TL-N @ ['] .BSK-TL-ROW W.LIST
        _BSK-TL-N @ ['] .BSK-TL-DETAIL W.DETAIL
        W.GAP
        .BSK-TL-HINTS
    THEN
    _BSK-STATUS-LEN @ 0> IF
        W.GAP
        _BSK-STATUS _BSK-STATUS-LEN @ W.HINT
    THEN ;

\ SCR-BSKY-NF ( -- )   Notifications subscreen
: SCR-BSKY-NF  ( -- )
    _BSK-NF-N @ 0= IF
        S" Notifications" W.TITLE
        S" Press [f] to fetch notifications" W.HINT
    ELSE
        _BSK-NF-N @ S" Notifications" W.TITLE-N
        _BSK-NF-N @ ['] .BSK-NF-ROW W.LIST
        W.GAP
        S" [f]Refresh  [n/p]Navigate" W.HINT
    THEN
    _BSK-STATUS-LEN @ 0> IF
        W.GAP
        _BSK-STATUS _BSK-STATUS-LEN @ W.HINT
    THEN ;

\ SCR-BSKY-PR ( -- )   Profile subscreen
: SCR-BSKY-PR  ( -- )
    _BSK-PR-OK @ 0= IF
        S" Profile" W.TITLE
        S" Press [f] to fetch your profile" W.HINT
    ELSE
        S" Profile" W.TITLE
        ['] .BSK-PR-DN S" Name" W.KV-XT
        ['] .BSK-PR-HA S" Handle" W.KV-XT
        _BSK-PR-FC @ S" Followers" W.KV
        _BSK-PR-FG @ S" Following" W.KV
        _BSK-PR-PC @ S" Posts" W.KV
        W.GAP
        _BSK-PR-DL @ 0> IF
            S" Bio" W.SECTION
            _BSK-PR-D _BSK-PR-DL @ W.LINE
        THEN
        W.GAP
        S" [f]Refresh" W.HINT
    THEN
    _BSK-STATUS-LEN @ 0> IF
        W.GAP
        _BSK-STATUS _BSK-STATUS-LEN @ W.HINT
    THEN ;

\ SCR-BSKY-HELP ( -- )   Help / controls subscreen
: SCR-BSKY-HELP  ( -- )
    S" Bluesky Controls" W.TITLE
    W.GAP
    S" Navigation" W.SECTION
    S" [n/p] Select next / previous post" W.LINE
    S" [[/]] Switch subscreen ([ = prev, ] = next)" W.LINE
    S" Enter  Open selected post full-screen" W.LINE
    S" [0-9] Switch to another KDOS screen" W.LINE
    W.GAP
    S" Timeline Actions" W.SECTION
    S" [f]   Fetch / refresh current view" W.LINE
    S" [l]   Like selected post" W.LINE
    S" [t]   Repost selected post" W.LINE
    S" [y]   Reply to selected post (Esc to cancel)" W.LINE
    S" [d]   Delete selected post (yours only)" W.LINE
    W.GAP
    S" Compose" W.SECTION
    S" [c]   Write a new post (Enter to send, Esc to cancel)" W.LINE
    W.GAP
    S" System" W.SECTION
    S" [q]   Quit SCREENS, return to Forth prompt" W.LINE
    S" [r]   Force screen redraw" W.LINE
    S" [A]   Toggle auto-refresh" W.LINE ;

\ SCR-BSKY ( -- )   Main screen (fallback if no subscreens)
: SCR-BSKY  ( -- )
    SCR-BSKY-TL ;

\ ── §6.6  Key Handler & Actions ──────────────────────────────────
\
\  BSKY-KEYS ( c -- consumed )
\  Per-screen key handler.  Priority dispatch via CALL-SCREEN-KEY.

\ _BSK-SWITCH-SUB ( delta -- )
\   Move to adjacent subscreen (wrapping), reset selection state.
: _BSK-SWITCH-SUB  ( delta -- )
    SUBSCREEN-ID @ + DUP 0 < IF DROP SCREEN-SUBS 1- THEN
    DUP SCREEN-SUBS >= IF DROP 0 THEN
    SUBSCREEN-ID !
    0 SCR-SEL !  0 SCR-MAX !
    RENDER-SCREEN ;

\ _BSK-ACT-LIKE ( -- )   Like the selected post
: _BSK-ACT-LIKE  ( -- )
    SCR-SEL @ DUP -1 <> OVER _BSK-TL-N @ < AND IF
        DUP _BSK-TL-URI ROT _BSK-TL-CID
        BSK-LIKE
        S" Liked!" _BSK-SET-STATUS
    ELSE DROP THEN ;

\ _BSK-ACT-REPOST ( -- )   Repost the selected post
: _BSK-ACT-REPOST  ( -- )
    SCR-SEL @ DUP -1 <> OVER _BSK-TL-N @ < AND IF
        DUP _BSK-TL-URI ROT _BSK-TL-CID
        BSK-REPOST
        S" Reposted!" _BSK-SET-STATUS
    ELSE DROP THEN ;

\ _BSK-ACT-DELETE ( -- )   Delete the selected post
: _BSK-ACT-DELETE  ( -- )
    SCR-SEL @ DUP -1 <> OVER _BSK-TL-N @ < AND IF
        _BSK-TL-URI BSK-DELETE
        S" Deleted!" _BSK-SET-STATUS
    ELSE DROP THEN ;

\ _BSK-ACT-REPLY ( -- )   Reply to the selected post
: _BSK-ACT-REPLY  ( -- )
    SCR-SEL @ DUP -1 <> OVER _BSK-TL-N @ < AND IF
        DUP _BSK-TL-URI ROT _BSK-TL-CID
        _BSK-COMP-BUF 280 S" Reply> " W.INPUT
        DUP 0> IF
            _BSK-COMP-BUF SWAP BSK-REPLY
            S" Replied!" _BSK-SET-STATUS
        ELSE DROP 2DROP 2DROP THEN
    ELSE DROP THEN ;

\ _BSK-ACT-COMPOSE ( -- )   Compose a new post
: _BSK-ACT-COMPOSE  ( -- )
    _BSK-COMP-BUF 280 S" Post> " W.INPUT
    DUP 0> IF
        _BSK-COMP-BUF SWAP BSK-POST
        S" Posted!" _BSK-SET-STATUS
    ELSE DROP THEN ;

\ _BSK-TYPE-DECODED ( addr len -- )
\   TYPE a raw JSON string, decoding backslash escapes:
\   \n -> newline+indent   \t -> space   \\ -> \   \" -> "
: _BSK-TYPE-DECODED  ( addr len -- )
    BEGIN DUP 0> WHILE
        OVER C@ 92 = IF              \ backslash
            1 /STRING DUP 0> IF
                OVER C@
                DUP 110 = IF DROP CR ."   " ELSE  \ \n -> newline
                DUP 116 = IF DROP SPACE       ELSE  \ \t -> space
                DUP  92 = IF DROP 92 EMIT     ELSE  \ \\
                DUP  34 = IF DROP 34 EMIT     ELSE  \ \"
                              EMIT                   \ other: pass through
                THEN THEN THEN THEN
                1 /STRING
            THEN
        ELSE
            OVER C@ EMIT
            1 /STRING
        THEN
    REPEAT 2DROP ;

\ _BSK-VIEW-POST ( -- )   Show full text of selected post, full-screen.
: _BSK-VIEW-POST  ( -- )
    SUBSCREEN-ID @ 0 <> IF EXIT THEN      \ only on Timeline subscreen
    SCR-SEL @ DUP -1 = IF DROP EXIT THEN
    DUP _BSK-TL-N @ >= IF DROP EXIT THEN
    PAGE
    CR
    DUP _BSK-TL-HANDLE DUP 0> IF BOLD ."   @" TYPE RESET-COLOR ELSE 2DROP THEN
    CR CR
    ."   "
    _BSK-TL-TEXT DUP 0> IF
        _BSK-TYPE-DECODED CR
    ELSE 2DROP THEN
    CR
    SCR-SEL @ _BSK-TL-URI DUP 0> IF
        DIM ."   " TYPE RESET-COLOR CR
    ELSE 2DROP THEN
    CR HBAR CR
    DIM ."   [y] Reply    any other key returns" RESET-COLOR CR
    KEY DUP 121 = IF DROP _BSK-ACT-REPLY ELSE DROP THEN
    RENDER-SCREEN ;

\ BSKY-KEYS ( c -- consumed )
\   Key handler for the Bluesky screen.
: BSKY-KEYS  ( c -- consumed )
    \ '['  = previous subscreen (with state reset)
    DUP 91 = IF DROP -1 _BSK-SWITCH-SUB -1 EXIT THEN
    \ ']'  = next subscreen (with state reset)
    DUP 93 = IF DROP  1 _BSK-SWITCH-SUB -1 EXIT THEN
    \ 'f' = fetch/refresh (subscreen-dependent)
    DUP 102 = IF DROP
        _BSK-CLR-STATUS
        SUBSCREEN-ID @ 0 = IF
            0 BSK-TL-CURSOR-LEN !      \ reset cursor for fresh fetch
            _BSK-TL-FETCH
        THEN
        SUBSCREEN-ID @ 1 = IF _BSK-NF-FETCH THEN
        SUBSCREEN-ID @ 2 = IF _BSK-PR-FETCH THEN
        RENDER-SCREEN -1 EXIT
    THEN
    \ 'c' = compose (any subscreen)
    DUP 99 = IF DROP
        _BSK-ACT-COMPOSE
        RENDER-SCREEN -1 EXIT
    THEN
    \ Post actions (timeline subscreen only)
    SUBSCREEN-ID @ 0 <> IF DROP 0 EXIT THEN
    \ 'l' = like
    DUP 108 = IF DROP
        _BSK-ACT-LIKE RENDER-SCREEN -1 EXIT
    THEN
    \ 't' = repost
    DUP 116 = IF DROP
        _BSK-ACT-REPOST RENDER-SCREEN -1 EXIT
    THEN
    \ 'd' = delete
    DUP 100 = IF DROP
        _BSK-ACT-DELETE RENDER-SCREEN -1 EXIT
    THEN
    \ 'y' = reply
    DUP 121 = IF DROP
        _BSK-ACT-REPLY RENDER-SCREEN -1 EXIT
    THEN
    DROP 0 ;       \ not consumed

\ ── §6.7  Screen Registration ─────────────────────────────────────
\
\  Register Bluesky as screen [9] with three subscreens.

: LBL-BSKY     ." Bsky" ;
: LBL-BSKY-TL  ." Timeline" ;
: LBL-BSKY-NF  ." Notifs" ;
: LBL-BSKY-PR  ." Profile" ;
: LBL-BSKY-HLP ." Help" ;

VARIABLE _BSK-SCR-ID

' SCR-BSKY ' LBL-BSKY 1 REGISTER-SCREEN _BSK-SCR-ID !

' BSKY-KEYS      _BSK-SCR-ID @ SET-SCREEN-KEYS
' _BSK-VIEW-POST _BSK-SCR-ID @ SET-SCREEN-ACT

' SCR-BSKY-TL   ' LBL-BSKY-TL  _BSK-SCR-ID @ ADD-SUBSCREEN
' SCR-BSKY-NF   ' LBL-BSKY-NF  _BSK-SCR-ID @ ADD-SUBSCREEN
' SCR-BSKY-PR   ' LBL-BSKY-PR  _BSK-SCR-ID @ ADD-SUBSCREEN
' SCR-BSKY-HELP ' LBL-BSKY-HLP _BSK-SCR-ID @ ADD-SUBSCREEN

\ =====================================================================
\  §6 — End of Interactive TUI
\ =====================================================================
