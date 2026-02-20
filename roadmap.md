# Bluesky Client Roadmap — Staged Build Plan

## Guiding Principle

Each stage produces a **working, testable artifact**. No stage depends on
unbuilt code from a later stage. Every word can be tested at the `ok` prompt
immediately after implementation.

---

## Stage 0: Foundation Utilities
**Goal**: Build the small utility words that everything else depends on.
**Test**: Each word is testable in isolation at the prompt.

### 0.1 — String Builders
```
Estimated: ~80 lines of Forth
```
- `BSK-APPEND ( addr len -- )` — append to a working buffer with length tracking
- `BSK-RESET` — clear the working buffer
- `NUM>STR ( n -- addr len )` — unsigned integer to decimal string
- `NUM>PAD ( n width addr -- addr+width )` — zero-padded number into buffer
- `DIGIT-APPEND ( n buf -- buf' )` — single hex digit
- `STR-CONCAT` — join two strings into a third buffer

**Test**: `123 NUM>STR TYPE` → prints `123`

### 0.2 — JSON String Escaping
```
Estimated: ~40 lines
```
- `JSON-ESCAPE-CHAR ( char buf -- buf' )` — output `\\`, `\"`, or raw char
- `JSON-COPY-ESCAPED ( src-addr src-len dst-addr -- dst-len )` — copy string with escaping

**Test**: `S\" Hello \"world\"" JSON-BUF JSON-COPY-ESCAPED` → `Hello \"world\"`

### 0.3 — ISO 8601 Timestamp
```
Estimated: ~30 lines
```
- `BSK-NOW ( -- addr len )` — produce `YYYY-MM-DDTHH:MM:SS.000Z`
- Depends on: KDOS `TIME` / `DATE` words (verify availability)
- Fallback: hardcoded timestamp if no RTC, or user-supplied

**Test**: `BSK-NOW TYPE` → prints timestamp

### 0.4 — URL Encoding
```
Estimated: ~40 lines
```
- `URL-ENCODE ( src-addr src-len dst-addr -- dst-len )` — percent-encode unsafe chars
- Needed for query parameter values (DIDs contain `:`)

**Test**: `S" did:plc:abc" URL-BUF URL-ENCODE TYPE` → `did%3Aplc%3Aabc`

**Stage 0 Total**: ~190 lines, 0 network calls, fully unit-testable

---

## Stage 1: Minimal JSON Parser
**Goal**: Parse JSON enough to extract specific key values from API responses.
**Test**: Parse sample JSON strings at the prompt.

### 1.1 — Key Finder
```
Estimated: ~60 lines
```
- `JSON-SKIP-WS ( addr len -- addr' len' )`
- `JSON-FIND-KEY ( json-addr json-len key-addr key-len -- val-addr val-len | 0 0 )`
  - Scans for `"key":` pattern
  - Returns pointer to the value (right after the colon + whitespace)

**Test**:
```forth
S' {"name":"alice","age":30}' S" name" JSON-FIND-KEY
\ → points to "alice"
```

### 1.2 — Value Extractors
```
Estimated: ~80 lines
```
- `JSON-GET-STRING ( addr len -- str-addr str-len )` — extract string value (handles `\"` escapes)
- `JSON-GET-NUMBER ( addr len -- n )` — extract integer value
- `JSON-SKIP-VALUE ( addr len -- addr' len' )` — skip one JSON value (string, number, object, array, bool, null) — needed for scanning past unwanted keys

**Test**:
```forth
S' {"x":"hello","y":42}' S" x" JSON-FIND-KEY JSON-GET-STRING TYPE
\ → hello
S' {"x":"hello","y":42}' S" y" JSON-FIND-KEY JSON-GET-NUMBER .
\ → 42
```

### 1.3 — Array Iterator
```
Estimated: ~40 lines
```
- `JSON-GET-ARRAY ( addr len key-addr key-len -- arr-addr arr-len )` — find array value for key
- `JSON-NEXT-ITEM ( addr len -- addr' len' | 0 0 )` — advance to next array element
- `JSON-ARRAY-COUNT ( addr len -- n )` — count items (optional, nice to have)

**Test**:
```forth
S' {"items":[1,2,3]}' S" items" JSON-GET-ARRAY
JSON-NEXT-ITEM JSON-GET-NUMBER .  \ → 1
JSON-NEXT-ITEM JSON-GET-NUMBER .  \ → 2
```

**Stage 1 Total**: ~180 lines, still no network calls, testable with string literals

---

## Stage 2: HTTP POST and Authenticated GET
**Goal**: Extend tools.f's HTTP capabilities with POST and auth headers.
**Test**: Make raw HTTPS requests and see responses.

### 2.1 — Memory Setup
```
Estimated: ~30 lines
```
- `BSK-INIT` — allocate 64 KB receive buffer, initialize variables
- `BSK-CLEANUP` — free receive buffer
- Define all static buffers:
  - `BSK-REQ-BUF` (4 KB) — request building
  - `BSK-ACCESS-JWT` / `BSK-REFRESH-JWT` (2 KB each) — token storage
  - `BSK-DID` (128 bytes), `BSK-HANDLE` (64 bytes)

### 2.2 — DNS + IP Caching
```
Estimated: ~15 lines
```
- `BSK-RESOLVE` — resolve `bsky.social`, cache in `BSK-SERVER-IP`
- Only re-resolve on failure

### 2.3 — Request Builders
```
Estimated: ~100 lines
```
- `BSK-BUILD-GET ( path-addr path-len -- )` — build authenticated GET request
- `BSK-BUILD-POST ( path-addr path-len body-addr body-len -- )` — build POST with JSON body + auth
- Both write into `BSK-REQ-BUF`, update `BSK-REQ-LEN`
- Include `Host:`, `Authorization: Bearer`, `Content-Type:`, `Content-Length:`, `Connection: close`

### 2.4 — TLS Send/Receive Wrapper
```
Estimated: ~40 lines
```
- `BSK-XRPC-SEND ( -- )` — TLS connect to cached IP:443, send `BSK-REQ-BUF`, receive into heap buffer, close
- `BSK-RECV-LOOP ( tls -- )` — receive loop adapted from SCROLL pattern, writing to heap buffer

### 2.5 — Response Parser
```
Estimated: ~30 lines
```
- `BSK-PARSE-RESPONSE ( -- body-addr body-len status )` — find header/body boundary, extract HTTP status code
- Reuse/adapt `_HTTP-FIND-HEND` from tools.f

### 2.6 — High-Level Wrappers
```
Estimated: ~20 lines
```
- `BSK-GET ( path-addr path-len -- body-addr body-len )` — build, send, parse GET
- `BSK-POST-JSON ( path-addr path-len json-addr json-len -- body-addr body-len )` — build, send, parse POST

**Test**:
```forth
BSK-INIT
S" /xrpc/com.atproto.server.describeServer" BSK-GET TYPE
\ → should print JSON response from bsky.social
```

**Stage 2 Total**: ~235 lines, first real network calls

---

## Stage 3: Authentication
**Goal**: Login, store tokens, refresh tokens.
**Test**: Successfully authenticate and see user info.

### 3.1 — Login JSON Builder
```
Estimated: ~30 lines
```
- `BSK-BUILD-LOGIN-JSON ( handle-addr handle-len pass-addr pass-len -- json-addr json-len )`
- Produces: `{"identifier":"...","password":"..."}`

### 3.2 — Session Response Parser
```
Estimated: ~40 lines
```
- `BSK-PARSE-SESSION ( body-addr body-len -- ok? )`
- Extract and store: `accessJwt`, `refreshJwt`, `did`, `handle`
- Store each in its dedicated buffer

### 3.3 — Login Command
```
Estimated: ~20 lines
```
- `BSK-LOGIN ( "handle" "password" -- )` — user-facing command
  1. Parse args from input stream
  2. Build login JSON
  3. POST to `createSession`
  4. Parse response, store tokens
  5. Print confirmation

### 3.4 — Token Refresh
```
Estimated: ~30 lines
```
- `BSK-REFRESH ( -- )` — called manually or on 401
  1. Swap refresh token into auth position
  2. POST to `refreshSession`
  3. Parse response, update both tokens

### 3.5 — Session Persistence (Optional)
```
Estimated: ~30 lines
```
- `BSK-SAVE-SESSION` — write tokens + DID to MP64FS file
- `BSK-LOAD-SESSION` — read them back
- Avoids re-login across reboots

**Test**:
```forth
BSK-LOGIN myhandle.bsky.social xxxx-xxxx-xxxx-xxxx
\ → "Logged in as myhandle.bsky.social"
BSK-ACCESS-LEN @ .  \ → ~900 (token length)
BSK-DID BSK-DID-LEN @ TYPE  \ → did:plc:abc123...
```

**Stage 3 Total**: ~150 lines, first authenticated interaction

---

## Stage 4: Read-Only Features
**Goal**: View timeline, profiles, and notifications without writing data.
**Test**: See real Bluesky content on the megapad display.

### 4.1 — Timeline
```
Estimated: ~60 lines
```
- `BSK-TL ( -- )` — fetch and display recent timeline posts
  1. GET `/xrpc/app.bsky.feed.getTimeline?limit=5`
  2. Parse `feed` array
  3. For each post, extract and print `author.handle` and `record.text`
- `BSK-TL-NEXT ( -- )` — fetch next page using stored cursor

### 4.2 — Profile Viewer
```
Estimated: ~40 lines
```
- `BSK-PROFILE ( "handle" -- )` — view a user's profile
  1. GET `/xrpc/app.bsky.actor.getProfile?actor=<handle>`
  2. Display: displayName, description, followersCount, followsCount, postsCount

### 4.3 — Notifications
```
Estimated: ~50 lines
```
- `BSK-NOTIF ( -- )` — list recent notifications
  1. GET `/xrpc/app.bsky.notification.listNotifications?limit=10`
  2. Parse `notifications` array
  3. Display: reason (like/reply/follow/mention) + author handle

### 4.4 — Post Thread Viewer (Stretch)
```
Estimated: ~60 lines
```
- `BSK-THREAD ( "at-uri" -- )` — view a post and its replies
  1. GET `/xrpc/app.bsky.feed.getPostThread?uri=<uri>&depth=3`
  2. Display parent chain + replies with indentation

**Test**:
```forth
BSK-TL
\ @alice.bsky.social says:
\ Just posted from the command line!
\ ---
BSK-PROFILE alice.bsky.social
\ Alice | 42 followers | 128 following
BSK-NOTIF
\ like from @bob.bsky.social
\ reply from @charlie.bsky.social
```

**Stage 4 Total**: ~210 lines, passive/read-only usage working

---

## Stage 5: Write Features
**Goal**: Post, reply, like, repost, follow/unfollow.
**Test**: Actions appear on the real Bluesky network.

### 5.1 — Create Post
```
Estimated: ~40 lines
```
- `BSK-POST ( "text..." -- )` — post text (rest of input line)
  1. Build `createRecord` JSON for `app.bsky.feed.post`
  2. POST to `/xrpc/com.atproto.repo.createRecord`
  3. Display resulting `uri`

### 5.2 — Reply
```
Estimated: ~50 lines
```
- `BSK-REPLY ( "at-uri" "text..." -- )` — reply to a post
  1. First fetch the target post to get its CID and root URI
  2. Build `createRecord` with `reply.root` and `reply.parent`
  3. POST

### 5.3 — Like
```
Estimated: ~40 lines
```
- `BSK-LIKE ( "at-uri" -- )`
  1. Fetch post to get CID
  2. Build `createRecord` for `app.bsky.feed.like`
  3. POST

### 5.4 — Repost
```
Estimated: ~30 lines
```
- `BSK-REPOST ( "at-uri" -- )` — same pattern as like, different collection

### 5.5 — Follow / Unfollow
```
Estimated: ~40 lines
```
- `BSK-FOLLOW ( "handle-or-did" -- )` — follow a user
- `BSK-UNFOLLOW ( "handle-or-did" -- )` — requires finding the follow record's rkey first

### 5.6 — Delete Post
```
Estimated: ~20 lines
```
- `BSK-DELETE ( "at-uri" -- )` — parse rkey from URI, POST `deleteRecord`

**Stage 5 Total**: ~220 lines, full interactive client

---

## Stage 6: Robustness & Quality of Life
**Goal**: Handle errors gracefully, improve usability.

### 6.1 — Error Handling
```
Estimated: ~40 lines
```
- Check HTTP status codes (401 → auto-refresh, 400/500 → display error message)
- Parse JSON `error` and `message` fields on failure
- Retry logic (1 retry on network error)

### 6.2 — Auto-Refresh
```
Estimated: ~20 lines
```
- Wrap every command with "if 401, call BSK-REFRESH and retry once"

### 6.3 — Display Formatting
```
Estimated: ~60 lines
```
- Word-wrap post text to tile display width
- Truncate extremely long posts with `[...]`
- Color/attribute coding if tile engine supports it (e.g., handles in different color)
- Post numbering in timeline for easy reference (`BSK-LIKE 3` instead of pasting URI)

### 6.4 — Timeline Post Index
```
Estimated: ~40 lines
```
- Store URIs/CIDs of displayed posts in an array
- Allow `BSK-LIKE 2`, `BSK-REPLY 3 "great post!"` by index
- Much more usable than typing full AT URIs

### 6.5 — Help System
```
Estimated: ~20 lines
```
- `BSK-HELP` — list all commands with one-line descriptions

**Stage 6 Total**: ~180 lines

---

## Stage 7: Extended Features (Optional/Future)

### 7.1 — Search
- `BSK-SEARCH ( "query" -- )` — search posts

### 7.2 — Author Feed
- `BSK-FEED ( "handle" -- )` — view a specific user's posts

### 7.3 — Mute/Block
- `BSK-MUTE`, `BSK-BLOCK`, `BSK-UNMUTE`, `BSK-UNBLOCK`

### 7.4 — Bookmarks
- `BSK-BOOKMARK`, `BSK-BOOKMARKS` — save/list bookmarked posts

### 7.5 — Custom Feed Viewer
- `BSK-CF ( "feed-uri" -- )` — view a custom/algorithm feed

### 7.6 — Rich Text Output
- Parse facets in posts, render mentions/links differently
- On tile display: underline links, highlight mentions

### 7.7 — Offline Queue
- Queue posts/likes when network is unavailable
- Send when connectivity returns

---

## Summary Table

| Stage | Lines (est.) | Dependencies | Deliverable |
|-------|-------------|--------------|-------------|
| 0 — Utilities | ~190 | None | String/number/timestamp helpers |
| 1 — JSON Parser | ~180 | Stage 0 | Parse JSON responses |
| 2 — HTTP POST/Auth GET | ~235 | Stage 0 | Make XRPC calls over HTTPS |
| 3 — Authentication | ~150 | Stages 1, 2 | Login, tokens, session |
| 4 — Read Features | ~210 | Stage 3 | Timeline, profile, notifications |
| 5 — Write Features | ~220 | Stages 3, 4 | Post, reply, like, follow |
| 6 — Robustness | ~180 | Stage 5 | Error handling, UX polish |
| 7 — Extended | Variable | Stage 6 | Search, feeds, bookmarks, etc. |
| **Total (1-6)** | **~1,365** | | **Full interactive client** |

For context, tools.f is ~990 lines and implements six protocols. A complete
Bluesky client in ~1,365 lines of Forth is realistic.

---

## Testing Strategy

Each stage has a clear test:

| Stage | Test |
|-------|------|
| 0 | Print formatted numbers, timestamps, encoded URLs at prompt |
| 1 | Parse hardcoded JSON strings, print extracted values |
| 2 | Fetch `describeServer` from bsky.social, see JSON output |
| 3 | Login with app password, print DID and handle |
| 4 | Read and display real timeline posts |
| 5 | Create a post, verify it appears on bsky.app |
| 6 | Trigger a 401, observe automatic refresh and retry |

---

## File Structure

```
bsky.f          — main client file, loaded via EVALUATE or included in autoexec.f
  ├── Utilities (Stage 0)
  ├── JSON parser (Stage 1)
  ├── HTTP client extensions (Stage 2)
  ├── Session management (Stage 3)
  ├── Read commands (Stage 4)
  ├── Write commands (Stage 5)
  └── Error handling / UX (Stage 6)
```

Single file, loaded with:
```forth
S" bsky.f" INCLUDED
```
or via SCROLL:
```forth
SCROLL-LOAD https://example.com/bsky.f
```

---

## What's Already Done (From KDOS/tools.f)

These do NOT need to be built — they're available from the platform:

- [x] TLS 1.3 client (connect, send, recv, close)
- [x] TCP client (connect, send, recv, close)
- [x] DNS resolution (hostname → IP)
- [x] DHCP (automatic network setup)
- [x] HTTP GET with header parsing
- [x] URL parsing
- [x] SHA-256, HMAC, HKDF
- [x] AES-GCM encryption/decryption
- [x] TRNG (random numbers)
- [x] Heap allocator (ALLOCATE/FREE/RESIZE)
- [x] Filesystem (read/write files)
- [x] String comparison (COMPARE)
- [x] Memory ops (MOVE, FILL)
- [x] Forth compiler (dynamic word definition)
