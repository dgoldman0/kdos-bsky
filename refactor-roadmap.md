# bsky.f Refactor Roadmap

Replace hand-rolled infrastructure in bsky.f with akashic libraries.
Work in stages — each stage produces a file that **loads and runs**.
Backup: `bsky-old.f` (2293 lines, original)

## Progress

| Stage | Status | Lines removed | Notes |
|-------|--------|---------------|-------|
| 0 | ✅ Done | — | Backup + 12 REQUIRE statements |
| 1 | ✅ Done | ~150 | §0 dead code removed, NUM>APPEND + BSK-NOW added |
| 2 | ✅ Done | ~220 | §1 JSON parser deleted, 3 compat shims added |
| 3+4 | ✅ Done | ~350 | §2 HTTP stack + §3 auth replaced together |
| 5 | ✅ Skip | 0 | §4 works via compat shims, no changes needed |
| 6 | ✅ Skip | 0 | §5 works via compat shims, no changes needed |
| 7 | ✅ Skip | 0 | §6 works via compat shims, no changes needed |
| 8 | 🔲 | — | Optional deep migration (XRPC-QUERY, repo.f, JSON builder) |

**Result: 2293 → 1577 lines (−716, −31%)**

Stages 5-7 were skippable because the compat shims in §1-§2 bridge
the old calling convention seamlessly. §4-§6 code compiles and works
unchanged. A future optimization pass (Stage 8) can migrate callers
to use akashic APIs directly for even more reduction.

---

## Dependency load order

bsky.f must REQUIRE akashic files in this order (each has a PROVIDED
guard so duplicates are harmless):

```forth
REQUIRE akashic/akashic/utils/string.f      \ /STRING, STR-INDEX, NUM>STR
REQUIRE akashic/akashic/utils/json.f        \ JSON parser + builder
REQUIRE akashic/akashic/utils/datetime.f    \ DT-NOW, DT-ISO8601
REQUIRE akashic/akashic/net/url.f           \ URL-PARSE (needed by http.f)
REQUIRE akashic/akashic/net/headers.f       \ HDR-* (needed by http.f)
REQUIRE akashic/akashic/net/http.f          \ HTTP-GET, HTTP-POST-JSON, etc.
REQUIRE akashic/akashic/net/uri.f           \ URI-PARSE (needed by aturi.f)
REQUIRE akashic/akashic/atproto/xrpc.f      \ XRPC-QUERY, XRPC-PROCEDURE
REQUIRE akashic/akashic/atproto/session.f   \ SESS-LOGIN, SESS-REFRESH
REQUIRE akashic/akashic/atproto/aturi.f     \ ATURI-PARSE
REQUIRE akashic/akashic/atproto/repo.f      \ REPO-CREATE, REPO-DELETE
```

Note: xrpc.f internally says `REQUIRE http.f` etc. — if KDOS resolves
REQUIRE by PROVIDED guard words (checking if `akashic-http` etc. exists),
this is fine since we loaded them first. If KDOS resolves by filename,
the internal REQUIREs will try relative paths from their own directory
and may also work. Either way the PROVIDED guards prevent double-loading.

---

## Key design decisions

1. **BSK-BUF stays** — still useful for building query param strings and
   TUI display. No longer used for HTTP headers or JSON bodies (akashic
   handles those internally).

2. **Handle stored locally** — `session.f` doesn't store the handle.
   bsky.f keeps BSK-HANDLE / BSK-HANDLE-LEN and saves before calling
   SESS-LOGIN.

3. **HTTP receive buffer** — akashic http.f has its own recv buffer
   (HTTP-RECV-BUF / HTTP-RECV-MAX). bsky.f's BSK-INIT allocates XMEM
   and calls `HTTP-USE-STATIC` so the HTTP stack uses our large buffer.

4. **JSON parsing switches from flat-scan to depth-aware** — old
   `JSON-FIND-KEY` scanned forward blindly. New code uses
   `JSON-ENTER` + `JSON-KEY?` for proper nesting.

5. **Cursor management** — XRPC has a single global cursor. Timeline
   uses it; other fetches clear it first. We also keep a local
   BSK-TL-CURSOR copy for persistence across subscreen switches.

6. **Chunked encoding** — skipped for now. Bluesky PDS sends
   Content-Length with Connection: close. Can add HTTP-DECHUNK later.

7. **§6 TUI is mostly untouched** — cache arrays, accessors, row
   renderers, screen renderers, key handler, and screen registration
   stay the same. Only the fetch functions and action dispatch change.

---

## Stages

### Stage 0 — Backup + REQUIRE preamble
- `cp bsky.f bsky-old.f`
- Replace the old file header and PROVIDED line
- Add the REQUIRE block (see above)
- Delete nothing else yet
- **Test**: file loads without errors (PROVIDED guards prevent conflicts
  with old §1 JSON words because the akashic versions will already be
  defined and the old definitions just shadow them — acceptable for now)

### Stage 1 — Kill §0 dead code, keep BSK-BUF
What to **delete** from §0:
- `NUM>STR` (replaced by akashic string.f `NUM>STR`)
- `_BSK-PAD2`, `_BSK-PAD4` (only used by BSK-NOW)
- `JSON-ESCAPE-CHAR`, `JSON-COPY-ESCAPED` (replaced by JSON-ESTR)
- `BSK-NOW` + all `_BSK-TS-*` variables (replaced by DT-NOW + DT-ISO8601)
- `URL-ENCODE` + `_BSK-HEX-DIGIT` + `_BSK-URL-SAFE?` (not needed — actor
  params don't need encoding, cursor handled by XRPC layer)
- `BSK-CRLF`, `BSK-QUOTE`, `BSK-KV`, `BSK-KV,` (only used by old HTTP
  header builder and old JSON body builder, both replaced)

What to **keep** from §0:
- `BSK-BUF-MAX`, `BSK-BUF`, `BSK-LEN`, `BSK-RESET`, `BSK-APPEND`,
  `BSK-EMIT`, `BSK-TYPE` — still used for param building + TUI display

Add a small helper:
```forth
\ NUM>APPEND ( n -- )  Append decimal number to BSK-BUF
: NUM>APPEND  ( n -- )  NUM>STR BSK-APPEND ;
```

Add a timestamp helper:
```forth
CREATE _BSK-TS-BUF 32 ALLOT
: BSK-NOW  ( -- addr len )
    DT-NOW _BSK-TS-BUF 32 DT-ISO8601 _BSK-TS-BUF SWAP ;
```

**Test**: file still loads; `BSK-RESET S" hello" BSK-APPEND BSK-TYPE`
prints "hello"; `BSK-NOW TYPE` prints ISO timestamp.

### Stage 2 — Kill §1 (old JSON parser) entirely
Delete everything from `§1 Minimal JSON Parser` to `§1 — End`:
- `/STRING` (provided by akashic string.f)
- `JSON-SKIP-WS` (provided by akashic json.f)  
- `JSON-FIND-KEY` + `_JSON-MATCH?` + `_JSON-BUILD-KPAT` + all scratch
- `JSON-GET-STRING` (provided by akashic json.f — same name, different impl)
- `JSON-GET-NUMBER` (provided by akashic json.f)
- `JSON-SKIP-STRING` (provided by akashic json.f)
- `JSON-SKIP-VALUE` (provided by akashic json.f)
- `JSON-GET-ARRAY`, `JSON-NEXT-ITEM`

This is pure deletion — no replacement code needed since akashic provides
all these words. The rest of bsky.f still compiles because the word names
are the same (except `JSON-FIND-KEY` and `JSON-GET-ARRAY` / `JSON-NEXT-ITEM`
which are used downstream — those callers get fixed in later stages).

**Problem**: §3–§6 call `JSON-FIND-KEY` (akashic has `JSON-KEY?` instead)
and `JSON-GET-ARRAY` / `JSON-NEXT-ITEM` (akashic has `JSON-ENTER` +
`JSON-NEXT`). These callers will break.

**Fix**: add thin compatibility shims at the end of Stage 2:
```forth
\ Compat shims — replaced in later stages
: JSON-FIND-KEY  ( jaddr jlen kaddr klen -- vaddr vlen | 0 0 )
    2>R JSON-ENTER 2R> JSON-KEY?
    0= IF 2DROP 0 0 THEN ;
: JSON-GET-ARRAY  ( jaddr jlen kaddr klen -- aaddr alen )
    JSON-FIND-KEY DUP 0= IF EXIT THEN
    JSON-ENTER ;
: JSON-NEXT-ITEM  ( addr len -- addr' len' | 0 0 )
    JSON-NEXT 0= IF 2DROP 0 0 THEN ;
```

**Test**: file loads; old §3/§4/§5/§6 code still works through shims.

### Stage 3 — Kill §2 (HTTP stack), replace with akashic http.f
Delete from §2:
- `BSK-RECV-MAX`, `BSK-RECV-BUF`, `BSK-RECV-LEN` → use HTTP-RECV-BUF etc.
- All JWT storage (`BSK-ACCESS-JWT`, `BSK-REFRESH-JWT`, etc.) → session.f
- `BSK-DID`, `BSK-HANDLE` → keep handle; DID from SESS-DID
- `BSK-SERVER-IP`, DNS caching → http.f has DNS cache
- `BSK-BUILD-GET`, `BSK-BUILD-POST` → http.f builds requests
- `_BSK-TLS-OPEN`, `_BSK-RECV-LOOP`, `BSK-XRPC-SEND` → http.f
- `BSK-PARSE-RESPONSE`, `_BSK-DECHUNK`, all helpers → http.f
- `BSK-GET`, `BSK-POST-JSON` → replaced by XRPC-QUERY / XRPC-PROCEDURE

Keep / rewrite:
- `BSK-HANDLE`, `BSK-HANDLE-LEN` — session.f doesn't store handle
- `BSK-INIT` — allocate XMEM, call HTTP-USE-STATIC, set UA
- `BSK-CLEANUP` — HTTP state teardown

Add compat shims for callers not yet migrated:
```forth
: BSK-GET  ( path-a path-u -- body-a body-u )
    ... build full URL, call HTTP-GET ... ;
: BSK-POST-JSON  ( path-a path-u json-a json-u -- body-a body-u )
    ... build full URL, call HTTP-POST-JSON ... ;
```
(These shims exist only until §4/§5 are migrated in stages 4–5.)

**Test**: `BSK-INIT` succeeds; compat `BSK-GET` / `BSK-POST-JSON` work
with the rest of the unchanged code.

### Stage 4 — Kill §3 (auth), replace with session.f
Delete from §3:
- `_BSK-BUILD-LOGIN-JSON`, `_BSK-LOGIN-BUF` → session.f builds JSON
- `_BSK-EXTRACT-FIELD`, `_BSK-PARSE-SESSION` → session.f parses
- Manual HTTP header construction for refresh

Rewrite:
- `BSK-LOGIN-WITH` — save handle locally, call SESS-LOGIN
- `BSK-LOGIN` — parse input, call BSK-LOGIN-WITH
- `BSK-REFRESH` — call SESS-REFRESH
- `BSK-WHO` — use SESS-DID, SESS-ACTIVE?, local handle

Remove compat shim variables:
- `BSK-ACCESS-LEN` → `SESS-ACTIVE?` everywhere
- `BSK-DID` / `BSK-DID-LEN` → `SESS-DID`
- `BSK-HTTP-STATUS` → `HTTP-STATUS @`

But `SESS-ACTIVE?` checks and `SESS-DID` have different stack signatures
than the old `BSK-ACCESS-LEN @ 0=` pattern, so all guard checks in §4/§5/§6
need updating too. Do this with a shim:
```forth
: BSK-LOGGED-IN?  ( -- flag )  SESS-ACTIVE? ;
```
Then search-replace `BSK-ACCESS-LEN @ 0=` with `BSK-LOGGED-IN? 0=`.

**Test**: `BSK-LOGIN handle pass` works; `BSK-WHO` displays info;
`BSK-REFRESH` refreshes tokens.

### Stage 5 — Migrate §4 (read-only) to XRPC-QUERY + akashic JSON
Replace `BSK-GET` calls with `XRPC-QUERY`:
- `BSK-TL` → `S" app.bsky.feed.getTimeline" S" limit=10" XRPC-QUERY`
- `BSK-PROFILE` → `S" app.bsky.actor.getProfile" params XRPC-QUERY`
- `BSK-NOTIF` → `S" app.bsky.notification.listNotifications" ...`

Replace JSON-FIND-KEY chains with JSON-ENTER + JSON-KEY? chains.
Replace JSON-GET-ARRAY iteration with JSON-ENTER + JSON-NEXT loops.

Cursor: call `XRPC-EXTRACT-CURSOR` after timeline fetch.
Handle `BSK-TL-NEXT` → set XRPC cursor from local copy, fetch again.

Remove compat shims for `BSK-GET`, `JSON-FIND-KEY`, `JSON-GET-ARRAY`,
`JSON-NEXT-ITEM` once all callers are migrated.

**Test**: `BSK-TL` displays timeline; `BSK-PROFILE handle` works;
`BSK-NOTIF` lists notifications.

### Stage 6 — Migrate §5 (write features) to repo.f + JSON builder
Replace manual JSON body construction with akashic JSON builder:
- `BSK-POST` → build record JSON with `JSON-SET-OUTPUT` + `JSON-{` +
  `JSON-KV-ESTR` etc., then `REPO-CREATE`
- `BSK-REPLY` → same pattern with nested reply object
- `BSK-LIKE`, `BSK-REPOST` → record JSON + `REPO-CREATE`
- `BSK-FOLLOW` → record JSON + `REPO-CREATE`
- `BSK-DELETE` → `REPO-DELETE` (handles URI parse + JSON internally)
- `BSK-UNFOLLOW` → `REPO-DELETE`

Delete:
- `_BSK-POST-BUF`, `_BSK-STAGE-BODY`, `_BSK-QK`, `_BSK-QV`,
  `_BSK-QV-ESC`, `_BSK-COMMA`
- `_BSK-CR-OPEN`, `_BSK-CR-CLOSE`, `_BSK-CREATED-AT`, `_BSK-SUBJECT`
- `_BSK-DO-CREATE`, `_BSK-DO-DELETE`, `_BSK-DR-OPEN`
- `_BSK-URI-PARSE`, `_BSK-RFIND-SLASH`

**Test**: `BSK-POST`, `BSK-LIKE`, `BSK-DELETE` work from the prompt.

### Stage 7 — Migrate §6 TUI fetch/action functions
The §6 cache arrays, accessors, row renderers, screen renderers,
key handler, and screen registration are **unchanged**.

Only update:
- `_BSK-TL-FETCH` — use XRPC-QUERY + akashic JSON to populate cache
- `_BSK-TL-CACHE-ITEM` — use JSON-ENTER + JSON-KEY? for nested parsing
- `_BSK-NF-FETCH` + `_BSK-NF-CACHE-ITEM` — same pattern
- `_BSK-PR-FETCH` — same pattern
- `_BSK-ACT-LIKE` / `_BSK-ACT-REPOST` / `_BSK-ACT-DELETE` /
  `_BSK-ACT-REPLY` / `_BSK-ACT-COMPOSE` — call updated §5 words
- Guard checks: `BSK-ACCESS-LEN @ 0=` → `BSK-LOGGED-IN? 0=`

Also remove `_BSK-SAVE-PATH` / `_BSK-PATH-BUF` (no longer needed).

**Test**: full TUI works — fetch, navigate, like, reply, compose, delete.

### Stage 8 — Cleanup
- Remove any remaining compat shims
- Remove dead variables and buffers
- Remove `BSK-HTTP-STATUS` if no longer referenced
- Final count: target ~1200–1400 lines (down from 2293)
- Verify: `REQUIRE bsky.f` from clean state, full TUI test

---

## What stays completely unchanged

- §6.1 Cache data model (arrays, slot sizes, counts)
- §6.2 Cache accessors (store/fetch per slot)
- §6.4 Row renderers (.BSK-TL-ROW, .BSK-NF-ROW, .BSK-TL-DETAIL)
- §6.5 Screen renderers (SCR-BSKY-TL/NF/PR/HELP, SCR-BSKY)
- §6.6 Key handler (BSKY-KEYS) — routing is unchanged, just calls
  updated action words
- §6.7 Screen registration
- _BSK-TYPE-TRUNC
- _BSK-TYPE-DECODED
- _BSK-VIEW-POST
- _BSK-SWITCH-SUB
- Status message helpers (_BSK-SET-STATUS, _BSK-CLR-STATUS)

## Summary of what each akashic lib replaces

| Old bsky.f code | Akashic replacement |
|---|---|
| §0 NUM>STR, _BSK-PAD2/4 | string.f NUM>STR |
| §0 BSK-NOW (RTC@) | datetime.f DT-NOW + DT-ISO8601 |
| §0 JSON-ESCAPE-CHAR, JSON-COPY-ESCAPED | json.f JSON-ESTR |
| §0 URL-ENCODE | kept (no akashic equivalent, still used by §4) |
| §0 BSK-QUOTE, BSK-KV, BSK-KV, | json.f JSON-KV-STR, JSON-KV-ESTR |
| §0 JSON-COPY-ESCAPED | kept (still used by §5 _BSK-QV-ESC) |
| §1 entire JSON parser | json.f (same names, better impl) |
| §2 HTTP stack (800 lines) | http.f (~445 lines, shared) |
| §3 auth (~220 lines) | session.f (~143 lines) |
| §5 URI parsing | aturi.f ATURI-PARSE |
| §5 createRecord body builder | repo.f REPO-CREATE + json.f builder |
| §5 deleteRecord body builder | repo.f REPO-DELETE |
