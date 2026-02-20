# Megapad-64 Platform Reference for App Development

## Overview

Megapad-64 is a tile-oriented fantasy computer built around a custom 64-bit CPU.
It runs a Forth BIOS and the KDOS operating system. The system includes a full
network stack (Ethernet through TLS 1.3), hardware-accelerated cryptography,
a filesystem, heap memory, and a tile-based graphics engine.

The development language is **Forth** — all user-space code is written as Forth
source (`.f` files) that KDOS can `EVALUATE`.

---

## System Architecture

| Component | Details |
|-----------|---------|
| CPU | Custom 64-bit, multi-core capable |
| RAM | 1 MiB Bank 0 (general) + 3 MiB HBW (math coprocessor) |
| BIOS | Subroutine-threaded Forth, 300+ dictionary words, ~26 KB binary |
| OS | KDOS v1.1 — 670+ colon definitions, 430+ variables/constants, 8,667 lines |
| Filesystem | MP64FS — 1 MiB images, 64 files max, 7 file types |
| Display | Tile engine (sprites, layers, scrolling) |
| Networking | Full TCP/IP + TLS 1.3 stack |
| Crypto | Hardware-accelerated AES-GCM, SHA-3, SHA-256, X25519, ML-KEM-512, TRNG |

---

## Boot Sequence

1. BIOS initializes hardware, sets up Forth interpreter
2. KDOS loads — defines OS words (filesystem, networking, crypto, etc.)
3. `autoexec.f` runs:
   - Configures networking (DHCP, falls back to static 10.64.0.2/24)
   - Switches to userland
   - Loads `tools.f` (SCROLL system — network clients)
   - Loads `graphics.f` (tile graphics helpers)

---

## Network Stack (KDOS §16)

The stack is layered, from hardware up to TLS:

```
  TLS 1.3
    ↑
   TCP          UDP
    ↑            ↑
   IPv4       DHCP / DNS
    ↑
   ARP
    ↑
  Ethernet (NIC hardware)
```

### Ethernet
- `ETH-SEND`, `ETH-RECV`, `ETH-BUILD` — raw frame I/O
- `NET-MAC@` — read NIC MAC address (BIOS word)
- `NET-SEND`, `NET-RECV`, `NET-STATUS` — BIOS NIC words

### ARP
- `ARP-RESOLVE ( ip -- mac )` — resolve IP to MAC
- Automatic ARP reply handling

### IPv4
- `IP-SEND`, `IP-RECV` — packet send/receive with header build/parse

### ICMP
- `PING ( ip -- )` — send ICMP echo request

### UDP
- `UDP-SEND ( dst-ip dst-port src-port buf len -- )` — send UDP datagram
- `UDP-RECV` — receive UDP datagram

### DNS
- `DNS-RESOLVE ( c-addr len -- ip )` — resolve hostname to IPv4 address
- Used by tools.f URL parser for hostname resolution

### DHCP
- `DHCP-START ( -- flag )` — obtain IP/gateway/DNS via DHCP

### TCP
- **4 TCB (Transmission Control Block) slots** — max 4 simultaneous connections
- `TCP-CONNECT ( ip port -- tcb )` — open connection (3-way handshake)
- `TCP-SEND ( tcb buf len -- )` — send data
- `TCP-RECV ( tcb buf maxlen -- len )` — receive data (0 = nothing yet)
- `TCP-CLOSE ( tcb -- )` — close connection
- `TCP-POLL` — process incoming TCP segments
- `TCP-STATUS ( tcb -- state )` — check connection state
- `TCPS-ESTABLISHED` — constant for connected state
- Implements sliding window, congestion control, retransmission

### TLS 1.3
- `TLS-CONNECT ( ip port -- tls )` — open TLS session
- `TLS-SEND ( tls buf len -- )` — send encrypted data
- `TLS-RECV ( tls buf maxlen -- len )` — receive and decrypt (-1 = decrypt error)
- `TLS-CLOSE ( tls -- )` — tear down session
- `TLS-SNI-HOST` — 64-byte buffer for Server Name Indication hostname
- `TLS-SNI-LEN` — length of SNI hostname

#### Cipher suites
| ID | Name | Notes |
|----|------|-------|
| `0xFF01` | AES-256-GCM + SHA3-256 | Custom/experimental |
| `0x1301` | TLS_AES_128_GCM_SHA256 | Standard RFC 8446 |

- Full ClientHello/ServerHello/key exchange/Finished handshake
- Record-layer framing with reassembly buffers
- CCS (Change Cipher Spec) tolerance for middlebox compatibility
- SNI extension support (required for most real-world servers)

### Socket API (KDOS §17)
Higher-level abstraction over TCP/UDP:
- `SOCKET ( type -- sd )`, `BIND`, `LISTEN`, `ACCEPT`
- `CONNECT ( sd ip port -- )`, `SEND`, `RECV`, `CLOSE`

### Polling
- `NET-IDLE` — process all pending network events
- `POLL` — general polling word

---

## Cryptography (BIOS + KDOS)

### AES-GCM (Hardware-Accelerated)
- `AES-ENCRYPT ( key iv src dst len -- tag-addr )`
- `AES-DECRYPT ( key iv src dst len tag -- flag )`
- `AES-ENCRYPT-AEAD` — with additional authenticated data (used by TLS)
- Supports both AES-128 and AES-256

### SHA-3 / SHAKE (Hardware-Accelerated)
- `SHA3 ( addr len out -- )` — SHA3-256
- `SHA3-512 ( addr len out -- )`
- `SHAKE128 ( addr len out outlen -- )`
- `SHAKE256 ( addr len out outlen -- )`
- `SHAKE-STREAM` — streaming SHAKE output

### SHA-256
- `SHA256 ( addr len out -- )`
- `HMAC-SHA256 ( key klen msg mlen out -- )`
- `HKDF-SHA256-EXTRACT`, `HKDF-SHA256-EXPAND`

### Unified Crypto API
- `HASH ( addr len out -- )` — selected hash
- `HMAC ( key klen msg mlen out -- )`
- `ENCRYPT`, `DECRYPT` — symmetric operations
- `VERIFY` — constant-time comparison (anti-timing-attack)

### X25519 ECDH
- `X25519 ( scalar point result -- )` — raw curve operation
- `X25519-KEYGEN` — generate keypair
- `X25519-DH` — Diffie-Hellman key agreement

### HKDF
- `HKDF-EXTRACT ( salt slen ikm iklen out -- )` — SHA3-based
- `HKDF-EXPAND ( prk plen info ilen out olen -- )`

### TRNG (True Random Number Generator)
- `RANDOM ( -- u64 )` — 64-bit random
- `RANDOM8 ( -- u8 )`, `RANDOM16`, `RANDOM32`
- `RAND-RANGE ( max -- n )` — bounded random

### Post-Quantum (ML-KEM-512 / Kyber)
- `KYBER-KEYGEN`, `KYBER-ENCAPS`, `KYBER-DECAPS`
- `PQ-EXCHANGE-INIT`, `PQ-EXCHANGE-RESP`

---

## Filesystem (MP64FS)

| Property | Value |
|----------|-------|
| Image size | 1 MiB |
| Max files | 64 |
| File types | raw, text, forth, doc, data, tutorial, bundle (7 types) |
| Allocation | Sector-based with bitmap |

### Key Words
- `FILE-OPEN`, `FILE-CLOSE`, `FILE-READ`, `FILE-WRITE`
- `FILE-CREATE`, `FILE-DELETE`
- `FILE-SIZE`, `FILE-SEEK`
- `DIR` / `LS` — list files

---

## Memory Management

- `ALLOCATE ( size -- addr ior )` — heap allocate
- `FREE ( addr -- ior )` — free allocation
- `RESIZE ( addr size -- addr' ior )` — resize allocation
- Standard Forth memory words: `HERE`, `ALLOT`, `,` (comma), `C,`, `ALIGN`

---

## String Handling

- `S" ..."` — compile-time string literal (compile-only)
- `BL WORD ( -- c-addr )` — parse word from input
- `COMPARE ( addr1 len1 addr2 len2 -- n )` — string comparison
- `EVALUATE ( addr len -- )` — interpret string as Forth
- `FIND` — dictionary lookup
- `TYPE ( addr len -- )` — output string
- `EMIT ( char -- )` — output character
- `COUNT ( c-addr -- addr len )` — counted string to addr+len
- `MOVE ( src dst len -- )` — memory copy
- `FILL ( addr len char -- )` — memory fill
- `CMOVE`, `CMOVE>` — byte-wise copy

**Constraint**: Forth has no built-in JSON parser, no floating-point strings,
no regex. All string processing must be hand-coded.

---

## tools.f — The SCROLL System (~990 lines)

This is the existing multi-protocol network client, and the **primary model**
for building any new network application.

### Data Structures

| Name | Size | Purpose |
|------|------|---------|
| `SCROLL-BUF` | 16,384 bytes | Receive buffer |
| `SCROLL-LEN` | variable | Bytes received |
| `_SC-HOST` | 64 bytes | Parsed hostname |
| `_SC-PATH` | 256 bytes | Parsed path |
| `_SC-HOST-LEN` | variable | Hostname length |
| `_SC-PATH-LEN` | variable | Path length |
| `_SC-PORT` | variable | Port number |
| `_SC-PROTO` | variable | Protocol enum |
| `_SC-IP` | variable | Resolved IP |
| `_HTTP-REQ` | 512 bytes | HTTP request build buffer |

### Protocol Constants
```forth
0 CONSTANT PROTO-HTTP
1 CONSTANT PROTO-TFTP
2 CONSTANT PROTO-GOPHER
3 CONSTANT PROTO-HTTPS
4 CONSTANT PROTO-FTP
5 CONSTANT PROTO-FTPS
```

### URL Parsing: `URL-PARSE ( c-addr len -- )`
1. Detects protocol prefix (`http://`, `https://`, `ftp://`, etc.)
2. Sets `_SC-PROTO` and default `_SC-PORT` (80/443/69/70/21/990)
3. Parses hostname → `_SC-HOST`
4. Parses optional `:port`
5. Parses path → `_SC-PATH`

### DNS Resolution: `_SC-RESOLVE`
- Tries dotted-quad parse first
- Falls back to `DNS-RESOLVE`
- Result → `_SC-IP`

### Fetch Dispatch: `_SC-FETCH`
```forth
: _SC-FETCH
  _SC-PROTO @ CASE
    PROTO-HTTP   OF HTTP-GET   ENDOF
    PROTO-HTTPS  OF HTTPS-GET  ENDOF
    PROTO-TFTP   OF TFTP-GET   ENDOF
    PROTO-GOPHER OF GOPHER-GET ENDOF
    PROTO-FTP    OF FTP-GET    ENDOF
    PROTO-FTPS   OF FTP-GET    ENDOF  \ FTP-GET handles TLS upgrade
  ENDCASE ;
```

### HTTP-GET Flow
```
TCP-CONNECT ( ip port -- tcb )
  ↓
Poll up to 200x for TCPS-ESTABLISHED
  ↓
_HTTP-BUILD-REQ → build "GET /path HTTP/1.1\r\nHost: host\r\nConnection: close\r\n\r\n"
  ↓
TCP-SEND ( tcb req-buf req-len -- )
  ↓
Loop 500x: TCP-RECV into SCROLL-BUF (bail after 10 consecutive zero-length reads)
  ↓
TCP-CLOSE
  ↓
_HTTP-FIND-HEND — find "\r\n\r\n" header boundary
  ↓
Extract body, apply Content-Length if present
```

### HTTPS-GET Flow
```
Set TLS-SNI-HOST / TLS-SNI-LEN from _SC-HOST
  ↓
TLS-CONNECT ( ip port -- tls )
  ↓
TLS-SEND ( tls req-buf req-len -- )      ← same HTTP request as HTTP-GET
  ↓
Loop 500x: TLS-RECV into SCROLL-BUF (handle -1 = decrypt error)
  ↓
TLS-CLOSE
  ↓
Same header parsing as HTTP-GET
```

### HTTP Request Builder: `_HTTP-BUILD-REQ`
Constructs into `_HTTP-REQ` (512-byte buffer):
```
GET /path HTTP/1.1\r\n
Host: hostname\r\n
Connection: close\r\n
\r\n
```

### Public API
- `SCROLL-GET ( "url" -- )` — fetch URL contents into `SCROLL-BUF`
- `SCROLL-SAVE ( "url" "file" -- )` — fetch and save to MP64FS
- `SCROLL-LOAD ( "url" -- )` — fetch and `EVALUATE` as Forth source

### Line Editor: `ED`
- Simple line editor for creating/editing text files
- Located in tools.f alongside SCROLL

---

## Key Constraints for App Development

### Buffer Sizes
- `SCROLL-BUF`: 16 KB — **not enough for large JSON responses**
- `_HTTP-REQ`: 512 bytes — must fit entire HTTP request
- `_SC-HOST`: 64 bytes — hostname limit
- `_SC-PATH`: 256 bytes — path limit
- `TLS-SNI-HOST`: 64 bytes — SNI hostname

### Connection Limits
- **4 TCP connections max** (4 TCB slots)
- One TLS session at a time (implied by shared TLS state)

### Missing Capabilities (Needed for a Bluesky Client)
1. **No HTTP POST** — only GET is implemented in tools.f
2. **No JSON parser** — must be built from scratch
3. **No Base64 encoder/decoder** — needed for JWT auth headers
4. **No HTTP headers control** — can't set `Authorization`, `Content-Type`
5. **No chunked transfer encoding** — only `Content-Length` + `Connection: close`
6. **No persistent connections** — each request opens/closes a connection
7. **No URL-encoding** — needed for query parameters
8. **Large response handling** — 16 KB buffer may not fit timeline JSON

### Available Building Blocks
- Full HTTPS via TLS 1.3 — the hardest part is already done
- DNS resolution — hostnames work
- SHA-256 / HMAC — for any needed hashing
- TRNG — for request nonces
- Heap allocator — dynamic memory for larger buffers
- Filesystem — credential/state persistence
- String operations — `COMPARE`, `MOVE`, `FILL`, `TYPE`, `EMIT`
- Number ↔ string — `.` (print), `S>D`, standard numeric parsing
- EVALUATE — dynamic code execution
- Full Forth compiler available at runtime

### RTC / System Clock (7 words)

| # | Word | Stack Effect | Imm | Description |
|---|------|-------------|-----|-------------|
| 347 | `MS@` | `( -- ms )` | | Read 64-bit monotonic uptime in ms (reads UPTIME +0x0B00, byte 0 latches) |
| 348 | `EPOCH@` | `( -- ms )` | | Read 64-bit epoch ms since Unix epoch (reads EPOCH +0x0B08, byte 0 latches) |
| 349 | `RTC@` | `( -- sec min hour day mon year dow )` | | Read all seven calendar fields onto the stack |
| 350 | `RTC!` | `( sec min hour day mon year -- )` | | Set calendar (writes SEC–YEAR_HI at +0x10–+0x16) |
| 351 | `RTC-CTRL!` | `( ctrl -- )` | | Write RTC CTRL byte (bit0=run, bit1=alarm IRQ enable) at +0x18 |
| 352 | `RTC-ALARM!` | `( sec min hour -- )` | | Set alarm time (writes ALARM_S/M/H at +0x1A–+0x1C) |
| 353 | `RTC-ACK` | `( -- )` | | Clear alarm flag (write 0x01 to STATUS at +0x19) |

---

## Summary: What Can Be Built On This Platform

The megapad already fetches content over HTTPS from real-world servers. The
SCROLL system in tools.f is the architectural template. Building a Bluesky
client means extending this pattern with:

1. HTTP POST support (new request builder)
2. Custom headers (`Authorization: Bearer ...`, `Content-Type: application/json`)
3. JSON parsing (minimal, targeted)
4. Base64 encoding (for auth token handling)
5. Larger receive buffers (via ALLOCATE)
6. Session state management (token storage/refresh)

The TLS 1.3 stack, DNS, TCP — all the hard networking primitives — are ready.
The challenge is purely in the application-layer HTTP/JSON machinery.
