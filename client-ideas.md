# Bluesky Client Design Ideas for Megapad-64

## Design Philosophy

The megapad is not a desktop or mobile device. It's a tile-oriented fantasy
computer with a Forth OS. The client should feel native to this environment:

- **Text-first** — posts are text; the tile display is character-based
- **Minimal by necessity** — 16 KB default buffers, 64-bit Forth, no floating point
- **Extend the SCROLL pattern** — build on top of the existing HTTP/HTTPS architecture
- **Interactive Forth** — commands at the `ok` prompt, not a GUI app

---

## Architecture Overview

```
┌──────────────────────────────────────────────┐
│                 User Interface               │
│   BSK-LOGIN  BSK-TL  BSK-POST  BSK-NOTIF    │
│   BSK-PROFILE  BSK-REPLY  BSK-LIKE          │
├──────────────────────────────────────────────┤
│              Session Manager                 │
│   BSK-AUTH  BSK-REFRESH  BSK-DID  BSK-JWT    │
├──────────────────────────────────────────────┤
│            HTTP Client Layer                 │
│   HTTPS-GET*  HTTPS-POST  HTTP-BUILD-*       │
├──────────────────────────────────────────────┤
│            JSON Parser (Minimal)             │
│   JSON-FIND-KEY  JSON-GET-STRING             │
│   JSON-GET-ARRAY  JSON-NEXT-ITEM             │
├──────────────────────────────────────────────┤
│            Utility Layer                     │
│   BASE64-ENCODE  URL-ENCODE  ISO-TIMESTAMP   │
│   NUM>STR  DIGIT-APPEND                      │
├──────────────────────────────────────────────┤
│         Existing KDOS / tools.f              │
│   TLS-*  TCP-*  DNS-RESOLVE  SCROLL-*        │
└──────────────────────────────────────────────┘
```

---

## Layer 1: Utility Words

### Base64 Encoding (for display/debug — tokens are opaque)

The JWT tokens from Bluesky don't need decoding. They're stored as opaque byte
strings and echoed back in `Authorization` headers. But we need to know their
length for `Content-Length` calculation.

```forth
\ Token storage — JWTs can be ~1200 bytes
2048 CONSTANT BSK-JWT-MAX
CREATE BSK-ACCESS-JWT  BSK-JWT-MAX ALLOT
VARIABLE BSK-ACCESS-LEN
CREATE BSK-REFRESH-JWT BSK-JWT-MAX ALLOT
VARIABLE BSK-REFRESH-LEN
```

### URL Encoding

Needed for query parameters (e.g., `actor=did%3Aplc%3Aabc123`).

```forth
\ Percent-encode a character if needed
: URL-ENCODE-CHAR ( char buf -- buf' )
  OVER DUP [CHAR] A [CHAR] Z 1+ WITHIN
  OVER [CHAR] a [CHAR] z 1+ WITHIN OR
  OVER [CHAR] 0 [CHAR] 9 1+ WITHIN OR
  OVER [CHAR] - = OR
  OVER [CHAR] _ = OR
  OVER [CHAR] . = OR
  OVER [CHAR] ~ = OR
  IF   ( char buf )  OVER SWAP C!  1+  NIP
  ELSE ( char buf )
    [CHAR] % OVER C!  1+
    SWAP DUP 4 RSHIFT HEX-DIGIT OVER C!  1+
    SWAP $F AND HEX-DIGIT OVER C!  1+
  THEN ;
```

### ISO 8601 Timestamp

```forth
\ Build "YYYY-MM-DDTHH:MM:SS.000Z" into buffer
\ Assumes KDOS has DATE and TIME words providing year/month/day/hour/min/sec
CREATE BSK-TIMESTAMP 32 ALLOT

: BSK-NOW ( -- addr len )
  BSK-TIMESTAMP 32 0 FILL
  BSK-TIMESTAMP
  \ This is pseudocode — actual DATE/TIME API depends on KDOS words
  YEAR @  4 NUM>PAD  [CHAR] - APPEND
  MONTH @ 2 NUM>PAD  [CHAR] - APPEND
  DAY @   2 NUM>PAD  [CHAR] T APPEND
  HOUR @  2 NUM>PAD  [CHAR] : APPEND
  MIN @   2 NUM>PAD  [CHAR] : APPEND
  SEC @   2 NUM>PAD
  S" .000Z" APPEND-STR
  BSK-TIMESTAMP OVER BSK-TIMESTAMP - ;
```

### Number-to-String with Zero Padding

```forth
\ Convert number to N-digit zero-padded string at addr, return addr+N
: NUM>PAD ( n width addr -- addr+width )
  2DUP + >R            \ save end address
  SWAP 0 DO
    2DUP MOD [CHAR] 0 + OVER I - 1- + C!
    10 /
  LOOP
  2DROP R> ;
```

---

## Layer 2: JSON Parser (Minimal/Streaming)

We don't need a full JSON parser. We need to find specific keys in a JSON
object and extract their string values. Key insight: we can scan byte-by-byte
through the response without building a tree.

### Strategy: "Needle in Haystack" Key Search

```forth
\ Find "key": in JSON buffer, return address after the colon
\ Handles: "key":"value" and "key": "value" (with optional whitespace)
: JSON-FIND-KEY ( json-addr json-len key-addr key-len -- val-addr val-len | 0 0 )
  \ Search for "key": pattern
  \ Return pointer to start of value and remaining length
  \ Value could be: "string", number, true/false/null, {object}, [array]
  ...
;

\ Extract a JSON string value (assumes pointer is at opening quote)
: JSON-GET-STRING ( addr len -- str-addr str-len )
  \ Skip opening "
  \ Scan for closing " (handle \" escapes)
  \ Return inner string
  ...
;

\ Skip whitespace
: JSON-SKIP-WS ( addr len -- addr' len' )
  BEGIN DUP 0> WHILE
    OVER C@ DUP BL = SWAP 9 = OR  \ space or tab
    OVER C@ 13 = OR               \ CR
    OVER C@ 10 = OR               \ LF
  WHILE
    1 /STRING
  REPEAT THEN ;
```

### Practical JSON Scanning Example

To parse a `createSession` response and extract `accessJwt`:

```forth
: PARSE-SESSION ( buf len -- )
  S" accessJwt" JSON-FIND-KEY    ( val-addr val-len )
  DUP 0= IF 2DROP ." Auth failed" CR EXIT THEN
  JSON-GET-STRING                 ( str-addr str-len )
  DUP BSK-JWT-MAX > IF 2DROP ." Token too long" CR EXIT THEN
  BSK-ACCESS-JWT SWAP MOVE
  BSK-ACCESS-LEN !

  \ Repeat for refreshJwt, did, handle
  ...
;
```

### Array Iteration

For timeline parsing, we need to iterate through a JSON array:

```forth
\ Find start of array value for key, return addr after [
: JSON-GET-ARRAY ( json-addr json-len key-addr key-len -- arr-addr arr-len )
  JSON-FIND-KEY
  JSON-SKIP-WS
  OVER C@ [CHAR] [ <> IF 2DROP 0 0 EXIT THEN
  1 /STRING   \ skip [
;

\ Advance to next item in array (skip one JSON value)
\ Returns 0 0 when ] is reached
: JSON-NEXT-ITEM ( addr len -- addr' len' | 0 0 )
  JSON-SKIP-WS
  OVER C@ [CHAR] ] = IF 2DROP 0 0 EXIT THEN
  OVER C@ [CHAR] , = IF 1 /STRING THEN
  JSON-SKIP-WS
;
```

---

## Layer 3: HTTP Client Extensions

### HTTPS-POST (New — Does Not Exist in tools.f)

The big missing piece. Currently tools.f only builds GET requests. We need POST
with custom headers and a JSON body.

```forth
\ Larger request buffer for POST (GET uses 512-byte _HTTP-REQ)
4096 CONSTANT BSK-REQ-MAX
CREATE BSK-REQ-BUF BSK-REQ-MAX ALLOT
VARIABLE BSK-REQ-LEN

\ Build HTTP POST request into BSK-REQ-BUF
: BSK-BUILD-POST ( path-addr path-len body-addr body-len -- )
  BSK-REQ-BUF BSK-REQ-MAX 0 FILL
  0 BSK-REQ-LEN !

  \ Request line
  S" POST " BSK-APPEND
  ( path ) BSK-APPEND
  S"  HTTP/1.1\r\n" BSK-APPEND

  \ Host header
  S" Host: bsky.social\r\n" BSK-APPEND

  \ Content-Type
  S" Content-Type: application/json\r\n" BSK-APPEND

  \ Authorization (if logged in)
  BSK-ACCESS-LEN @ 0> IF
    S" Authorization: Bearer " BSK-APPEND
    BSK-ACCESS-JWT BSK-ACCESS-LEN @ BSK-APPEND
    S" \r\n" BSK-APPEND
  THEN

  \ Content-Length
  S" Content-Length: " BSK-APPEND
  ( body-len ) DUP NUM>STR BSK-APPEND
  S" \r\n" BSK-APPEND

  \ Connection close
  S" Connection: close\r\n" BSK-APPEND

  \ Blank line
  S" \r\n" BSK-APPEND

  \ Body
  ( body-addr body-len ) BSK-APPEND
;

\ Helper: append string to BSK-REQ-BUF
: BSK-APPEND ( addr len -- )
  BSK-REQ-BUF BSK-REQ-LEN @ +   \ destination
  SWAP DUP BSK-REQ-LEN +!        \ update length
  MOVE ;
```

### HTTPS-POST-XRPC (High-Level)

```forth
\ Send POST to bsky.social XRPC endpoint, receive response
: HTTPS-POST-XRPC ( path-addr path-len body-addr body-len -- resp-addr resp-len )
  BSK-BUILD-POST

  \ Resolve bsky.social (cache the IP to avoid repeated DNS)
  BSK-SERVER-IP @ 0= IF
    S" bsky.social" DNS-RESOLVE BSK-SERVER-IP !
  THEN

  \ Set SNI
  S" bsky.social" TLS-SNI-HOST SWAP MOVE
  14 TLS-SNI-LEN !   \ len of "bsky.social"

  \ Connect, send, receive
  BSK-SERVER-IP @ 443 TLS-CONNECT  ( tls )
  DUP BSK-REQ-BUF BSK-REQ-LEN @ TLS-SEND
  \ Receive loop into BSK-RECV-BUF
  BSK-RECV-LOOP
  TLS-CLOSE

  \ Parse HTTP response, extract body
  BSK-RECV-BUF BSK-RECV-LEN @ HTTP-PARSE-RESPONSE
;
```

### HTTPS-GET-XRPC (Authenticated GET)

```forth
\ Authenticated GET — extends tools.f pattern with auth header
: BSK-BUILD-GET ( path-addr path-len -- )
  BSK-REQ-BUF BSK-REQ-MAX 0 FILL
  0 BSK-REQ-LEN !

  S" GET " BSK-APPEND
  ( path ) BSK-APPEND
  S"  HTTP/1.1\r\n" BSK-APPEND
  S" Host: bsky.social\r\n" BSK-APPEND

  BSK-ACCESS-LEN @ 0> IF
    S" Authorization: Bearer " BSK-APPEND
    BSK-ACCESS-JWT BSK-ACCESS-LEN @ BSK-APPEND
    S" \r\n" BSK-APPEND
  THEN

  S" Connection: close\r\n" BSK-APPEND
  S" \r\n" BSK-APPEND
;
```

### Larger Receive Buffer

The 16 KB SCROLL-BUF won't hold timeline responses. Use heap:

```forth
65536 CONSTANT BSK-RECV-MAX   \ 64 KB receive buffer
VARIABLE BSK-RECV-BUF
VARIABLE BSK-RECV-LEN

: BSK-INIT ( -- )
  BSK-RECV-MAX ALLOCATE THROW BSK-RECV-BUF !
  0 BSK-RECV-LEN !
;

: BSK-CLEANUP ( -- )
  BSK-RECV-BUF @ FREE DROP
;
```

### Receive Loop with Larger Buffer

```forth
: BSK-RECV-LOOP ( tls -- )
  0 BSK-RECV-LEN !
  500 0 DO
    DUP BSK-RECV-BUF @ BSK-RECV-LEN @ +
    BSK-RECV-MAX BSK-RECV-LEN @ -
    TLS-RECV                        ( tls len )
    DUP -1 = IF DROP LEAVE THEN    \ decrypt error
    DUP 0= IF
      DROP 1+ DUP 10 > IF DROP LEAVE THEN  \ 10 empty reads = done
    ELSE
      BSK-RECV-LEN +!
      DROP 0                         \ reset empty counter
    THEN
  LOOP
  DROP   \ drop tls handle
;
```

---

## Layer 4: Session Management

### Login Flow

```forth
CREATE BSK-DID 128 ALLOT
VARIABLE BSK-DID-LEN
CREATE BSK-HANDLE 64 ALLOT
VARIABLE BSK-HANDLE-LEN
VARIABLE BSK-SERVER-IP

: BSK-LOGIN ( "handle" "password" -- )
  \ Parse handle and password from input stream
  BL WORD COUNT  ( handle-addr handle-len )
  BL WORD COUNT  ( handle-a handle-l pass-a pass-l )

  \ Build JSON body: {"identifier":"...","password":"..."}
  BSK-BUILD-LOGIN-JSON  ( body-addr body-len )

  \ POST to createSession
  S" /xrpc/com.atproto.server.createSession"
  2SWAP HTTPS-POST-XRPC

  \ Parse response — extract accessJwt, refreshJwt, did, handle
  PARSE-SESSION-RESPONSE
  ." Logged in as " BSK-HANDLE BSK-HANDLE-LEN @ TYPE CR
;

: BSK-BUILD-LOGIN-JSON ( handle-a handle-l pass-a pass-l -- json-a json-l )
  \ Build into a temp buffer:
  \ {"identifier":"<handle>","password":"<password>"}
  ...
;
```

### Token Refresh

```forth
: BSK-REFRESH ( -- )
  \ Use refresh token as the auth token for this one request
  BSK-REFRESH-JWT BSK-REFRESH-LEN @
  BSK-ACCESS-JWT BSK-ACCESS-LEN @   \ save current
  \ Temporarily swap refresh into access slot
  BSK-REFRESH-JWT BSK-ACCESS-JWT BSK-REFRESH-LEN @ MOVE
  BSK-REFRESH-LEN @ BSK-ACCESS-LEN !

  S" /xrpc/com.atproto.server.refreshSession"
  S" " HTTPS-POST-XRPC   \ empty body

  \ Parse like createSession — get new tokens
  PARSE-SESSION-RESPONSE

  \ Restore or update tokens
  ...
;
```

### Credential Persistence

```forth
\ Save session to filesystem for persistence across reboots
: BSK-SAVE-SESSION ( -- )
  S" bsk-sess" FILE-CREATE
  BSK-ACCESS-JWT BSK-ACCESS-LEN @ FILE-WRITE
  \ ... separator ...
  BSK-REFRESH-JWT BSK-REFRESH-LEN @ FILE-WRITE
  BSK-DID BSK-DID-LEN @ FILE-WRITE
  FILE-CLOSE
;

: BSK-LOAD-SESSION ( -- )
  S" bsk-sess" FILE-OPEN
  DUP 0= IF DROP ." No saved session" CR EXIT THEN
  \ Read tokens back...
  FILE-CLOSE
;
```

---

## Layer 5: User-Facing Commands

### Timeline Viewing

```forth
: BSK-TL ( -- )
  \ Fetch timeline, small batch
  S" /xrpc/app.bsky.feed.getTimeline?limit=5"
  HTTPS-GET-XRPC

  \ Parse and display each post
  S" feed" JSON-GET-ARRAY
  BEGIN DUP 0> WHILE
    BSK-DISPLAY-POST
    JSON-NEXT-ITEM
  REPEAT 2DROP
;

: BSK-DISPLAY-POST ( addr len -- addr' len' )
  \ Extract nested fields:
  \   post.author.handle
  \   post.record.text
  \   post.likeCount, post.repostCount
  2DUP S" handle" JSON-FIND-KEY JSON-GET-STRING
  ." @" TYPE ."  says:" CR

  2DUP S" text" JSON-FIND-KEY JSON-GET-STRING
  TYPE CR

  ." ---" CR
;
```

### Posting

```forth
: BSK-POST ( "text..." -- )
  \ Read rest of line as post text
  0 PARSE  ( addr len )

  \ Build createRecord JSON
  BSK-BUILD-POST-JSON  ( json-addr json-len )

  S" /xrpc/com.atproto.repo.createRecord"
  2SWAP HTTPS-POST-XRPC

  \ Check for success
  S" uri" JSON-FIND-KEY
  IF ." Posted!" CR ELSE ." Failed to post" CR THEN
  2DROP
;

: BSK-BUILD-POST-JSON ( text-addr text-len -- json-addr json-len )
  \ Build: {"repo":"<did>","collection":"app.bsky.feed.post",
  \         "record":{"$type":"app.bsky.feed.post",
  \                   "text":"<text>","createdAt":"<now>"}}
  ...
;
```

### Profile Viewing

```forth
: BSK-PROFILE ( "handle-or-did" -- )
  BL WORD COUNT  ( actor-addr actor-len )
  \ Build path: /xrpc/app.bsky.actor.getProfile?actor=<handle>
  S" /xrpc/app.bsky.actor.getProfile?actor=" ...CONCAT...
  HTTPS-GET-XRPC

  \ Extract and display fields
  S" displayName" JSON-FIND-KEY JSON-GET-STRING TYPE CR
  S" description" JSON-FIND-KEY JSON-GET-STRING TYPE CR
  S" followersCount" JSON-FIND-KEY JSON-GET-NUMBER . ." followers" CR
  S" followsCount" JSON-FIND-KEY JSON-GET-NUMBER . ." following" CR
;
```

### Notifications

```forth
: BSK-NOTIF ( -- )
  S" /xrpc/app.bsky.notification.listNotifications?limit=10"
  HTTPS-GET-XRPC

  S" notifications" JSON-GET-ARRAY
  BEGIN DUP 0> WHILE
    2DUP S" reason" JSON-FIND-KEY JSON-GET-STRING
    \ Display: "like from @handle", "reply from @handle", etc.
    BSK-DISPLAY-NOTIF
    JSON-NEXT-ITEM
  REPEAT 2DROP
;
```

### Liking a Post

```forth
: BSK-LIKE ( "at-uri" -- )
  BL WORD COUNT  ( uri-addr uri-len )
  \ We need the CID too — could fetch the post first, or
  \ require user to provide it. Simpler: fetch post, get CID.
  ...
  BSK-BUILD-LIKE-JSON
  S" /xrpc/com.atproto.repo.createRecord"
  2SWAP HTTPS-POST-XRPC
  ." Liked!" CR
;
```

---

## Usage Model (At the `ok` Prompt)

```
ok BSK-LOGIN myhandle.bsky.social xxxx-xxxx-xxxx-xxxx
Logged in as myhandle.bsky.social
ok BSK-TL
@alice.bsky.social says:
Just discovered this amazing Forth computer!
---
@bob.bsky.social says:
TLS 1.3 in Forth. What a time to be alive.
---
ok BSK-POST Hello world from Megapad-64!
Posted!
ok BSK-PROFILE alice.bsky.social
Alice
Software developer, Forth enthusiast
42 followers
128 following
ok BSK-NOTIF
like from @charlie.bsky.social
reply from @alice.bsky.social
ok
```

---

## Key Design Decisions

### 1. Forth CLI, Not GUI
The tile engine could render a visual interface, but a CLI/REPL is simpler,
more natural to Forth, and sufficient for a first version. Each feature is a
single Forth word.

### 2. Single Server Target
Hardcode `bsky.social` as the PDS. Don't implement PDS discovery or DID
resolution. Users with custom PDS can change a variable.

### 3. Minimal JSON Parser
Don't build a JSON DOM. Scan for keys with known names, extract string values.
This is fragile to JSON formatting changes but vastly simpler. Can be hardened
later.

### 4. One Connection Per Request
Follow the existing SCROLL pattern: connect → send → receive → close. No
persistent connections. This is slightly slower but much simpler.

### 5. Opaque JWT Handling
Don't decode JWTs. Store them as raw byte strings. Echo them back in headers.
Only check their presence/absence.

### 6. Dynamic Buffers
Use `ALLOCATE` for the receive buffer (64 KB) to handle large responses.
Static buffers for request building (4 KB) and token storage (2 KB × 2).

### 7. Incremental Feature Growth
Start with login + read timeline + post. Add features one at a time. Each
feature is an independent Forth word that can be developed and tested in
isolation.

---

## Risk Areas

| Risk | Mitigation |
|------|------------|
| Response too large for buffer | `ALLOCATE` 64 KB; request small `limit` values |
| JWT token too long for headers | Request buffer is 4 KB — should be sufficient |
| JSON parsing edge cases | Start with minimal extraction; harden iteratively |
| TLS handshake failures | KDOS TLS is tested against real servers; bsky.social should work |
| Token expiration mid-session | Check for 401 response, auto-refresh |
| No real-time clock | May need user to provide timestamp or use a fallback |
| Special characters in post text | Escape `"` and `\` in JSON string builder |
| DNS caching | Cache resolved IP in `BSK-SERVER-IP` |
