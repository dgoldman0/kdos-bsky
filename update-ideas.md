# bsky.f Update Ideas — Akashic & Emulator Review

**Date:** 2026-02-23

Pulled fresh `megapad/` into `emu/` and `akashic/` into `akashic/`. Below
is a detailed analysis of what the new libraries offer and how they can
slim down and improve the Bluesky client.

---

## 1. Replace bsky.f §1 (JSON Parser) with akashic-json

**Current state:** bsky.f lines 238–458 (~220 lines) implement a minimal
JSON parser: `JSON-SKIP-WS`, `JSON-FIND-KEY`, `JSON-GET-STRING`,
`JSON-GET-NUMBER`, `JSON-SKIP-STRING`, `JSON-SKIP-VALUE`,
`JSON-GET-ARRAY`.  This is a flat scan-for-`"key":` approach — it doesn't
understand nesting, so `JSON-FIND-KEY` can accidentally match keys inside
nested objects.

**akashic-json provides:** 874 lines of battle-tested, depth-aware JSON.
Key wins:
- `JSON-KEY` — depth-aware key lookup (only matches top-level keys of the
  current object, not nested ones).  Eliminates the false-match risk.
- `JSON-ENTER` / `JSON-LEAVE` — enter/leave `{}` or `[]` contexts.
- `JSON-PATH` — dot-path access like `S" post.author.handle" JSON-PATH`
  in a single call.  This would hugely simplify `_BSK-TL-CACHE-ITEM`
  where we currently do nested `JSON-FIND-KEY` chains.
- `JSON-EACH` — callback-driven array iteration.  Replaces the manual
  BEGIN/WHILE array loops in `_BSK-TL-FETCH` and `_BSK-NF-FETCH`.
- `JSON-GET-BOOL`, `JSON-TYPE?` — type checking the bsky parser lacks.
- `JSON-UNESCAPE` — proper `\uXXXX` decoding.  bsky.f currently punts on
  this (our `JSON-GET-STRING` returns raw escaped content).
- **Builder** — `JSON-{`, `JSON-}`, `JSON-KV`, `JSON-ARR`, etc. with
  auto-comma.  Could replace the manual `BSK-KV` / `BSK-KV,` / string
  builder gymnastics in §3 (login JSON), §5.1 (post body builder), and
  all the other body construction code.

**Estimated savings:** ~200 lines removed from bsky.f.  The §1 JSON
parser section essentially disappears.  §0.2 (JSON string escaping) may
also be replaceable by the builder's auto-escaping.

**Migration path:**
1. `REQUIRE ../akashic/utils/json/json.f` at top of bsky.f.
2. Replace `JSON-FIND-KEY` calls → `JSON-ENTER S" key" JSON-KEY`.
3. Replace array iteration loops → `JSON-EACH`.
4. Replace JSON body building → `JSON-{` / `JSON-KV` / `JSON-}`.

---

## 2. Replace bsky.f §0.4 (URL Encoding) with akashic-url

**Current state:** bsky.f lines 172–207 (~35 lines) implement URL
percent-encoding: `_BSK-HEX-DIGIT`, `_BSK-URL-SAFE?`, `URL-ENCODE`.

**akashic-url provides:** 641 lines — full URL parsing (scheme, host,
port, path, query, fragment), percent encode/decode, query-string
building and parsing.  Key wins:
- `URL-ENCODE` / `URL-DECODE` — proper RFC 3986 with configurable buffers.
- `URL-PARSE` — decompose a full URL into components.
- `QS-ADD` / `QS-BUILD` — query-string builder.  Could simplify how we
  build XRPC query paths (e.g. `?actor=did%3Aplc%3A...&limit=10`).

**Estimated savings:** ~35 lines.  More importantly, we get URL-decode
for free (needed if we ever display URLs from API responses).

---

## 3. Replace bsky.f §2.3–§2.5 (HTTP Request/Response) with akashic-http

**Current state:** bsky.f lines 563–862 (~300 lines) implement HTTP
request building (manual header string construction), TLS send/receive
loop, HTTP response parsing (status extraction, header-end scanning,
content-length parsing, chunked transfer decoding).  This is the biggest
chunk of plumbing in the file.

**akashic-http provides:** 445 lines — full HTTP/1.1 client with:
- `HTTP-GET` / `HTTP-POST-JSON` — one-call request execution (URL →
  connect → send → recv → parse → body).  Currently bsky.f manually
  chains BSK-BUILD-GET → BSK-XRPC-SEND → BSK-PARSE-RESPONSE.
- `HTTP-CONNECT` / `HTTP-DISCONNECT` — TCP/TLS dispatch with automatic
  SNI hostname setting.  Replaces `_BSK-TLS-OPEN`.
- `HTTP-RECV-LOOP` — receive loop with timeout/empty detection.
  Replaces `_BSK-RECV-LOOP` and its helper chain.
- `HTTP-PARSE` / `HTTP-DECHUNK` — response parsing + chunked transfer
  decoding.  Replaces the entire §2.5 including `_BSK-DECHUNK`.
- `HTTP-SET-BEARER` — session bearer token management.  Replaces the
  manual `_BSK-APPEND-AUTH` plumbing.
- `HTTP-DNS-LOOKUP` — 8-slot DNS cache.  Replaces `BSK-RESOLVE` /
  `_BSK-ENSURE-IP` / `BSK-SERVER-IP`.
- `HTTP-HEADER` — response header lookup by name.  Could be used to
  check `content-type`, `x-ratelimit-*`, etc.
- Built-in redirect following (`HTTP-FOLLOW?`).

**akashic-headers provides:** 285 lines — reusable header builder with:
- `HDR-GET` / `HDR-POST` — method line builder.
- `HDR-ADD` — arbitrary header.
- `HDR-AUTH-BEARER` — bearer token header.
- `HDR-CONTENT-JSON` — JSON content-type shorthand.
- `HDR-CONTENT-LENGTH` — numeric content-length.
- `HDR-FIND` — parse response headers by name.

**Estimated savings:** ~250+ lines removed.  The entire §2.3 (request
builders), §2.4 (TLS wrapper), §2.5 (response parser), and §2.6
(high-level wrappers) collapse into thin wrappers around `HTTP-GET` and
`HTTP-POST-JSON`.  The §2.2 DNS caching section disappears entirely.

**Migration path for BSK-GET:**
```forth
\ OLD (bsky.f — ~100 lines of plumbing)
: BSK-GET  ( path -- body len )
    BSK-BUILD-GET BSK-XRPC-SEND IF 0 0 EXIT THEN
    BSK-PARSE-RESPONSE DROP ;

\ NEW (akashic-http — ~5 lines)
: BSK-GET  ( path-a path-u -- body-a body-u )
    BSK-RESET
    S" https://bsky.social" BSK-APPEND  BSK-APPEND
    BSK-BUF BSK-LEN @ HTTP-GET ;
```

Or even simpler — build the full URL in a buffer and call `HTTP-GET`
directly.  The session bearer token is set once via `HTTP-SET-BEARER`.

---

## 4. Replace bsky.f §0.5 + §0.2 with akashic-json Builder

**Current state:** bsky.f §0.5 (lines 210–232) defines `BSK-CRLF`,
`BSK-QUOTE`, `BSK-KV`, `BSK-KV,` for building JSON key-value pairs.
§0.2 (lines 100–125) defines `JSON-ESCAPE-CHAR` and `JSON-COPY-ESCAPED`
for escaping strings within JSON values.

**akashic-json builder provides:**
- `JSON-{` / `JSON-}` / `JSON-[` / `JSON-]` — structure delimiters with
  auto-comma insertion between values.
- `JSON-KV` — `S" key" S" value" JSON-KV` emits `"key":"value"` with
  proper escaping and automatic leading commas.
- `JSON-KV-NUM` — numeric values without quotes.
- Vectored output via `JSON-EMIT` / `JSON-TYPE` — can redirect to any
  buffer.

**Estimated savings:** ~50 lines.  All the manual comma/quote/escape
juggling in §3.1 (login JSON), §5.1 (post body builder), §5.3 (reply
body), §5.4 (like body), §5.5 (repost/follow bodies) gets dramatically
cleaner.

---

## 5. Base64 — New Capability

**akashic/utils/net/base64.f** provides RFC 4648 Base64 encode/decode,
including URL-safe variant.  bsky.f doesn't currently use Base64, but
AT Protocol uses it in:
- JWT token decoding (inspecting token claims without server round-trip)
- Image upload payloads (`com.atproto.repo.uploadBlob`)
- CBOR/DAG-CBOR content addressing

Having Base64 available opens the door to:
- **Token introspection** — decode JWT payload to check expiry time,
  avoiding unnecessary refresh calls.
- **Image posting** — a future `BSK-UPLOAD-IMAGE` that Base64-encodes
  binary data for the upload blob endpoint.

---

## 6. DOM + HTML + CSS — Future Rich Content Rendering

These are heavier libraries (dom.f = 1091 lines, css.f = 1677 lines,
html.f = 629 lines, core.f = 882 lines) but open up possibilities:

- **Rendering post facets** — Bluesky posts can contain rich text facets
  (links, mentions, hashtags).  An HTML DOM could render these in the TUI
  with ANSI color/underline for links.
- **Link preview rendering** — fetch a URL's `<meta>` tags to show
  embedded link card previews.
- **AT Protocol Lexicon XML** — the AT Protocol lexicon schemas are
  defined in JSON, but some related specs use XML.  xml.f gives us a
  parser if needed.

These aren't immediate priorities for slimming down bsky.f, but they're
available if we want richer post display later.

---

## 7. Emulator Updates Relevant to bsky.f

### 7a. XMEM replaces HBW for user buffers ✓

The emulator now has proper external memory (`--extmem`, default 16 MiB)
and userland memory isolation.  bsky.f already uses `XMEM-ALLOT` for its
64 KB recv buffer (§2.1), which is correct.  HBW is supervisor-only.

### 7b. RTC device

A hardware RTC device exists at MMIO 0x0B00.  bsky.f uses `RTC@` for
timestamps (§0.3).  This should continue working.

### 7c. SHA-256 + HMAC-SHA256

New SHA-256 hardware accelerator.  The KDOS `HMAC-SHA256` word could be
used for AT Protocol HMAC operations if Bluesky ever requires signed
requests (some atproto endpoints may move to signatures).

### 7d. Headless mode

`--headless` flag starts a TCP terminal server on port 6464.  This
enables running the bsky client remotely — SSH into the host, connect
to port 6464, and interact with the TUI.  Could be useful for a
Bluesky bot scenario.

### 7e. Multicore (informational)

The emulator now supports 4 full cores + 3 micro-core clusters

This isn't directly relevant to bsky.f yet, but opens the door to
background timeline refresh on a separate core while the TUI remains
responsive.

---

## 8. Summary: Realistic Refactoring Plan

### Phase 1 — JSON (biggest win)
- Replace §1 with `REQUIRE akashic-json`.
- Replace §0.2 + §0.5 JSON helpers with akashic-json builder.
- Rewrite `_BSK-TL-CACHE-ITEM` using `JSON-PATH` / `JSON-KEY`.
- Rewrite all fetch loops using `JSON-EACH`.
- Rewrite all body builders using `JSON-{` / `JSON-KV` / `JSON-}`.
- **Expected: −250 lines, +1 REQUIRE**

### Phase 2 — HTTP + URL (second biggest win)
- Replace §0.4, §2.2, §2.3, §2.4, §2.5, §2.6 with akashic-http + url.
- `BSK-GET` and `BSK-POST-JSON` become thin wrappers around
  `HTTP-GET` / `HTTP-POST-JSON`.
- Token stored via `HTTP-SET-BEARER` instead of manual header injection.
- DNS caching handled by `HTTP-DNS-LOOKUP`.
- Chunked decoding handled by `HTTP-DECHUNK`.
- **Expected: −250 lines, +1 REQUIRE**

### Phase 3 — §0.1 String Builder audit
- With akashic-json builder handling JSON output and akashic-headers
  handling HTTP headers, the BSK-BUF string builder (§0.1) may be
  significantly less used.  Audit remaining uses — some may be
  replaceable with `HDR-*` or `JSON-*` builder calls.
- `NUM>STR` / `NUM>APPEND` may still be needed for non-JSON contexts.
- **Expected: −30 lines**

### Phase 4 — Base64 for JWT introspection (optional)
- Decode access token payload to check `exp` claim.
- Skip refresh if token hasn't expired yet.
- **Expected: +20 lines, but smarter token handling**

### Total estimated impact
- **Current bsky.f:** 2,293 lines
- **After Phase 1+2+3:** ~1,760 lines (~530 lines removed, ~23% smaller)
- The removed code is replaced by well-tested, documented library code
  with better error handling and edge-case coverage.

---

## 9. Risks / Things to Watch

- **PROVIDED guards:** Each akashic lib uses `PROVIDED` to prevent
  double-loading.  bsky.f should `REQUIRE` them, not `INCLUDE`.  Already
  uses `PROVIDED bsky.f` so this pattern is established.

- **VARIABLE name collisions:** bsky.f and akashic both define
  `/STRING`, `JSON-SKIP-WS`, etc.  The akashic versions are guarded by
  `PROVIDED` so redefinition is safe, but the bsky.f local copies should
  be removed to avoid confusion.

- **Buffer sizing:** akashic-http uses its own `HTTP-RECV-BUF` (XMEM
  allocated).  bsky.f's `BSK-RECV-BUF` / `BSK-RECV-MAX` would be
  replaced.  Need to ensure the akashic buffer is large enough (check
  `HTTP-RECV-MAX` or set it before first request).

- **Error model:** akashic libs use configurable abort-on-error vs
  soft-fail.  bsky.f currently uses ad-hoc error checking.  Should set
  `JSON-ABORT-ON-ERROR` to 0 (soft-fail) and check `JSON-OK?` after
  operations, matching the current resilient pattern.

- **tools.f overlap:** The emulator's `tools.f` (990 lines) already has
  HTTP/HTTPS/FTP clients.  bsky.f currently depends on tools.f for
  `_HTTP-FIND-HEND` and `_HTTP-PARSE-CLEN`.  After migrating to
  akashic-http, this dependency goes away — bsky.f would depend on
  akashic libs instead.  Cleaner separation.

---

## 10. Application Ideas for Proposed New Libraries

The following new libraries have been formally requested in
`change-request.md`.  Here's how each would apply to the bsky.f build:

- **atproto/xrpc + session (CR-1):** §3 auth (~200 lines) collapses to
  `ATP-LOGIN` / `ATP-REFRESH` calls.  All XRPC path-building in §4–§5
  replaced by `XRPC-QUERY` / `XRPC-PROCEDURE`.  §5 record CRUD
  (`_BSK-CR-OPEN` etc., ~100 lines) replaced by `ATP-CREATE-RECORD` /
  `ATP-DELETE-BY-URI`.  AT-URI parsing (`_BSK-URI-PARSE`, ~40 lines)
  replaced by `AT-URI-PARSE`.  **Combined: −340 lines.**

- **websocket (CR-2):** Enables live timeline/notification streaming
  via the firehose (`com.atproto.sync.subscribeRepos`), replacing the
  current poll-on-keypress model.  New feature, not a line reduction —
  but makes the client feel real-time.

- **string utils (CR-4):** `_BSK-RFIND-SLASH` replaced by `STR-RINDEX`.
  `NUM>STR` shared instead of locally defined.  Minor savings (~10
  lines) but cleaner dependency graph.

- **datetime (CR-5):** §0.3 ISO 8601 formatter (~50 lines) replaced by
  `ISO8601-FORMAT`.  New `TIME-AGO` enables "5m ago" display in the
  timeline TUI — significant UX win.  `ISO8601-PARSE` + `UNIX-TIME`
  enables JWT expiry checking to skip unnecessary refresh calls.

- **table/slot-array (CR-6):** §6.1–6.2 cache arrays (~120 lines of
  boilerplate `CREATE`/accessor pairs) replaced by ~10 lines of
  `TABLE-NEW` calls.  **−110 lines.**

- **pagination (CR-7):** Cursor management in timeline + notifications
  (~20 lines each, duplicated) replaced by shared `PAGE-*` helpers.
  **−30 lines.**

### Extended impact estimate

With all proposed libraries (Phase 1–3 from §8 + the above):
- **Phase 1–3 (existing libs):** 2,293 → ~1,760 lines (−530)
- **Phase 5 — atproto libs:** −340 lines
- **Phase 6 — table + datetime + pagination:** −190 lines
- **Projected total:** ~1,230 lines (~46% reduction)
- Under 1,000 lines of pure application logic (the rest is TUI rendering).
