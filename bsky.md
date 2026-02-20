# Bluesky & AT Protocol Reference for Megapad Client

## Overview

Bluesky is a social media application built on the **AT Protocol** (Authenticated
Transfer Protocol), a federated social networking protocol. Unlike centralized
platforms, AT Protocol distributes data across multiple servers, with users able
to move between providers while keeping their identity and data.

For a megapad client, we interact with the protocol through **XRPC** — a set of
HTTP API conventions using JSON request/response bodies.

---

## Architecture

```
  Client (megapad)
       |
       | HTTPS + JSON (XRPC)
       v
  PDS (Personal Data Server)  ←→  AppView  ←→  Relay
  e.g. bsky.social                api.bsky.app   bsky.network
```

- **PDS** — hosts user data (repositories), handles auth, proxies requests
- **AppView** — aggregates data from the network, serves feeds/profiles
- **Relay** — streams repo events across the network (firehose)

For a client, all requests go to the user's PDS. The PDS proxies to the
AppView automatically for `app.bsky.*` endpoints.

### Key Hostnames

| Service | Hostname | Purpose |
|---------|----------|---------|
| Entryway/PDS | `bsky.social` | Auth, repo writes, default PDS |
| Public AppView | `public.api.bsky.app` | Unauthenticated reads |
| AppView | `api.bsky.app` | Authenticated reads (via PDS proxy) |

---

## XRPC (HTTP API Conventions)

All API endpoints follow this pattern:

```
https://<host>/xrpc/<NSID>
```

**NSID** = Namespaced Identifier, e.g. `com.atproto.server.createSession`

### Request Types
- **Query** → `GET /xrpc/<NSID>?param=value` — read-only, cacheable
- **Procedure** → `POST /xrpc/<NSID>` with JSON body — mutations

### Common Headers
| Header | Value | When |
|--------|-------|------|
| `Content-Type` | `application/json` | POST requests with JSON body |
| `Authorization` | `Bearer <accessJwt>` | Authenticated requests |
| `Accept` | `application/json` | All requests (optional) |

### Error Responses
All errors return JSON:
```json
{
  "error": "InvalidRequest",
  "message": "Human-readable description"
}
```

### Pagination
- Responses include a `cursor` string field when more results exist
- Pass `cursor` as query parameter in next request
- Omit `cursor` for first request
- Stop when response has no `cursor`

---

## Authentication

### Session Creation

**Endpoint**: `POST /xrpc/com.atproto.server.createSession`

**Request body** (JSON):
```json
{
  "identifier": "handle.example.com",
  "password": "app-password-xxxx-xxxx-xxxx-xxxx"
}
```

**Response** (JSON):
```json
{
  "accessJwt": "<short-lived access token>",
  "refreshJwt": "<long-lived refresh token>",
  "handle": "user.bsky.social",
  "did": "did:plc:abc123...",
  "email": "user@example.com",
  "active": true
}
```

- `accessJwt` — used in `Authorization: Bearer <token>` header, expires in minutes
- `refreshJwt` — used only to get new access tokens
- `did` — the user's Decentralized Identifier (permanent account ID)
- `handle` — the user's human-readable name (can change)

### Token Refresh

**Endpoint**: `POST /xrpc/com.atproto.server.refreshSession`
- Use `refreshJwt` as the Bearer token (not `accessJwt`)
- Returns new `accessJwt` and `refreshJwt`

### App Passwords
- Generate in Bluesky settings → "App Passwords"
- Format: `xxxx-xxxx-xxxx-xxxx`
- Recommended for third-party clients (limited permissions)
- Used exactly like normal password in `createSession`

### Auth Summary for Megapad
```
1. POST createSession with identifier + app password
2. Store accessJwt and refreshJwt
3. Include "Authorization: Bearer <accessJwt>" on all subsequent requests
4. When accessJwt expires (HTTP 401), POST refreshSession with refreshJwt
5. Replace both tokens with new values
```

---

## Key API Endpoints

### Reading

#### Get Timeline
```
GET /xrpc/app.bsky.feed.getTimeline?limit=30&cursor=...
Authorization: Bearer <accessJwt>
```
Returns: `{ "feed": [...], "cursor": "..." }`

Each feed item contains a `post` object with author info, record (text,
createdAt, facets), embed info, and engagement counts.

#### Get Author Feed
```
GET /xrpc/app.bsky.feed.getAuthorFeed?actor=<did>&limit=30&filter=posts_with_replies
Authorization: Bearer <accessJwt>
```
Filters: `posts_with_replies`, `posts_no_replies`, `posts_with_media`, `posts_and_author_threads`

#### Get Profile
```
GET /xrpc/app.bsky.actor.getProfile?actor=<handle-or-did>
Authorization: Bearer <accessJwt>   (optional for public profiles)
```
Returns: display name, bio, avatar URL, follower/following counts, etc.

#### Get Post Thread
```
GET /xrpc/app.bsky.feed.getPostThread?uri=at://did/app.bsky.feed.post/rkey&depth=6
Authorization: Bearer <accessJwt>
```
Returns: the post plus parent/reply tree.

#### Get Notifications
```
GET /xrpc/app.bsky.notification.listNotifications?limit=25
Authorization: Bearer <accessJwt>
```
Returns: likes, reposts, follows, mentions, replies, quotes.

#### Search Posts
```
GET /xrpc/app.bsky.feed.searchPosts?q=search+terms&limit=25
```

#### Get Follows / Followers
```
GET /xrpc/app.bsky.graph.getFollows?actor=<did>&limit=50
GET /xrpc/app.bsky.graph.getFollowers?actor=<did>&limit=50
```

### Writing (All POST, All Require Auth)

All write operations go through `com.atproto.repo.createRecord`:

#### Create Post
```
POST /xrpc/com.atproto.repo.createRecord
Authorization: Bearer <accessJwt>
Content-Type: application/json

{
  "repo": "<user-did>",
  "collection": "app.bsky.feed.post",
  "record": {
    "$type": "app.bsky.feed.post",
    "text": "Hello from Megapad!",
    "createdAt": "2024-01-15T12:00:00.000Z",
    "langs": ["en"]
  }
}
```

Response: `{ "uri": "at://did/app.bsky.feed.post/rkey", "cid": "bafy..." }`

#### Reply to Post
```json
{
  "repo": "<user-did>",
  "collection": "app.bsky.feed.post",
  "record": {
    "$type": "app.bsky.feed.post",
    "text": "Great post!",
    "createdAt": "2024-01-15T12:01:00.000Z",
    "reply": {
      "root": { "uri": "at://...", "cid": "bafy..." },
      "parent": { "uri": "at://...", "cid": "bafy..." }
    }
  }
}
```

#### Like a Post
```json
{
  "repo": "<user-did>",
  "collection": "app.bsky.feed.like",
  "record": {
    "$type": "app.bsky.feed.like",
    "subject": { "uri": "at://...", "cid": "bafy..." },
    "createdAt": "2024-01-15T12:02:00.000Z"
  }
}
```

#### Repost
```json
{
  "repo": "<user-did>",
  "collection": "app.bsky.feed.repost",
  "record": {
    "$type": "app.bsky.feed.repost",
    "subject": { "uri": "at://...", "cid": "bafy..." },
    "createdAt": "2024-01-15T12:03:00.000Z"
  }
}
```

#### Follow a User
```json
{
  "repo": "<user-did>",
  "collection": "app.bsky.graph.follow",
  "record": {
    "$type": "app.bsky.graph.follow",
    "subject": "did:plc:target-user-did",
    "createdAt": "2024-01-15T12:04:00.000Z"
  }
}
```

#### Delete Record (Unlike, Unfollow, Delete Post)
```
POST /xrpc/com.atproto.repo.deleteRecord
Authorization: Bearer <accessJwt>
Content-Type: application/json

{
  "repo": "<user-did>",
  "collection": "app.bsky.feed.like",
  "rkey": "<record-key>"
}
```

---

## Data Model

### Record Types (Collections)

| Collection | Purpose |
|------------|---------|
| `app.bsky.feed.post` | Posts (text, replies, quotes) |
| `app.bsky.feed.like` | Likes |
| `app.bsky.feed.repost` | Reposts |
| `app.bsky.graph.follow` | Follows |
| `app.bsky.graph.block` | Blocks |
| `app.bsky.graph.list` | Lists |
| `app.bsky.actor.profile` | User profile (self-describing) |

### AT URI Format
```
at://<did>/<collection>/<record-key>
```
Example: `at://did:plc:abc123/app.bsky.feed.post/3k43tv4rft22g`

### Strong References
A reference to a specific version of a record:
```json
{
  "uri": "at://did:plc:abc123/app.bsky.feed.post/3k43tv4rft22g",
  "cid": "bafyreig2fjxi3rptqdgylg7e5hmjl6mcke7rn2b6cugzlqq3i4zu6rq52q"
}
```
- `uri` — identifies the record
- `cid` — content hash, pins to a specific version

### Post Record Structure
```json
{
  "$type": "app.bsky.feed.post",
  "text": "Post text here (max 300 graphemes, ~3000 bytes)",
  "createdAt": "2024-01-15T12:00:00.000Z",
  "langs": ["en"],
  "facets": [
    {
      "index": { "byteStart": 5, "byteEnd": 22 },
      "features": [
        { "$type": "app.bsky.richtext.facet#mention", "did": "did:plc:..." }
      ]
    }
  ],
  "reply": { "root": { ... }, "parent": { ... } },
  "embed": { "$type": "app.bsky.embed.record", "record": { ... } }
}
```

### Facets (Rich Text)
Facets annotate byte ranges in post text:
- **Mention**: `app.bsky.richtext.facet#mention` — `{ "did": "did:plc:..." }`
- **Link**: `app.bsky.richtext.facet#link` — `{ "uri": "https://..." }`
- **Tag**: `app.bsky.richtext.facet#tag` — `{ "tag": "hashtag" }`

**Important**: Byte offsets, not character offsets. UTF-8 aware.

### Timestamp Format
ISO 8601: `YYYY-MM-DDTHH:MM:SS.sssZ`

Megapad will need to generate valid timestamps. The system has a timer but may
need manual formatting code.

---

## HTTP Details for Raw Implementation

### A Complete createSession Request (What Megapad Sends)

```
POST /xrpc/com.atproto.server.createSession HTTP/1.1\r\n
Host: bsky.social\r\n
Content-Type: application/json\r\n
Content-Length: 72\r\n
Connection: close\r\n
\r\n
{"identifier":"user.bsky.social","password":"xxxx-xxxx-xxxx-xxxx"}
```

### A Complete getTimeline Request

```
GET /xrpc/app.bsky.feed.getTimeline?limit=10 HTTP/1.1\r\n
Host: bsky.social\r\n
Authorization: Bearer eyJhbGci...\r\n
Connection: close\r\n
\r\n
```

### A Complete createRecord Request (New Post)

```
POST /xrpc/com.atproto.repo.createRecord HTTP/1.1\r\n
Host: bsky.social\r\n
Authorization: Bearer eyJhbGci...\r\n
Content-Type: application/json\r\n
Content-Length: 189\r\n
Connection: close\r\n
\r\n
{"repo":"did:plc:abc123","collection":"app.bsky.feed.post","record":{"$type":"app.bsky.feed.post","text":"Hello from Megapad!","createdAt":"2024-01-15T12:00:00.000Z"}}
```

### Response Parsing
Responses are HTTP/1.1 with JSON bodies:
```
HTTP/1.1 200 OK\r\n
Content-Type: application/json\r\n
Content-Length: 1234\r\n
\r\n
{"accessJwt":"eyJ...","refreshJwt":"eyJ...","handle":"user.bsky.social","did":"did:plc:abc123"}
```

Key parsing steps:
1. Find `\r\n\r\n` — header/body boundary (already done in tools.f)
2. Everything after is JSON
3. Parse only the fields we need (no full JSON DOM required)

---

## Constraints & Considerations for Megapad

### Response Sizes
- `createSession` response: ~500-1000 bytes ✓ fits in 16 KB
- `getTimeline` with 10 posts: **5-50 KB** — may exceed SCROLL-BUF
- `getProfile`: ~500-2000 bytes ✓
- `listNotifications`: varies, could be large

### JWT Token Sizes
- Access tokens are typically **~800-1200 bytes** of base64
- They don't need to be decoded — just stored and echoed back
- Total `Authorization: Bearer <token>` header: ~850-1250 bytes
- This fits in a 512-byte request buffer? **No — need larger buffer**

### JSON Complexity
- Timeline responses are deeply nested JSON
- Multiple levels: feed[] → post → author, record, embed
- A minimal parser that extracts specific keys will suffice
- No need for full JSON DOM/tree — streaming/scanning approach

### Timestamps
- Must generate ISO 8601 strings
- Megapad has `TIME` / `DATE` BIOS words (need to verify format)
- May need to construct `YYYY-MM-DDTHH:MM:SS.000Z` from components

### Character Encoding
- Post text is UTF-8
- Megapad uses ASCII internally (tile-based display)
- Non-ASCII characters will be stored/transmitted correctly but may not render
- Facet byte offsets assume UTF-8 encoding

---

## Minimal Viable API Surface

For a first working client, these endpoints suffice:

| Priority | Endpoint | Method | Purpose |
|----------|----------|--------|---------|
| 1 | `com.atproto.server.createSession` | POST | Login |
| 2 | `app.bsky.feed.getTimeline` | GET | Read timeline |
| 3 | `com.atproto.repo.createRecord` | POST | Create post |
| 4 | `app.bsky.actor.getProfile` | GET | View profile |
| 5 | `com.atproto.server.refreshSession` | POST | Refresh auth |
| 6 | `app.bsky.notification.listNotifications` | GET | Notifications |
| 7 | `com.atproto.repo.createRecord` | POST | Like/repost/follow |
| 8 | `com.atproto.repo.deleteRecord` | POST | Unlike/unfollow |

Everything is either GET (with query params + auth header) or POST (with JSON
body + auth header). All over HTTPS to `bsky.social`.
