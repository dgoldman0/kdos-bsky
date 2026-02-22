#!/usr/bin/env python3
"""Test harness for bsky.f — boots KDOS in the emulator, loads bsky.f,
runs Forth test expressions, and checks UART output.

Usage:  cd bsky/ && emu/.venv/bin/python test_bsky.py
"""

import os
import sys
import traceback

# Add emulator directory to path
EMU_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "emu")
sys.path.insert(0, EMU_DIR)

from accel_wrapper import Megapad64, HaltError
from system import MegapadSystem
from devices import UART
from asm import assemble

# ---------------------------------------------------------------------------
#  Paths
# ---------------------------------------------------------------------------
BIOS_ASM = os.path.join(EMU_DIR, "bios.asm")
KDOS_F   = os.path.join(EMU_DIR, "kdos.f")
TOOLS_F  = os.path.join(EMU_DIR, "tools.f")
BSKY_F   = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bsky.f")

# ---------------------------------------------------------------------------
#  Helpers  (adapted from megapad-64/tests/test_system.py)
# ---------------------------------------------------------------------------

def make_system(ram_kib=1024, ext_mem_mib=16):
    return MegapadSystem(ram_size=ram_kib * 1024,
                         ext_mem_size=ext_mem_mib * (1 << 20))


def capture_uart(sys_obj):
    buf = []
    sys_obj.uart.on_tx = lambda b: buf.append(b)
    return buf


def uart_text(buf):
    return "".join(
        chr(b) if (0x20 <= b < 0x7F or b in (10, 13, 9)) else ""
        for b in buf
    )


def _next_line_chunk(data, pos):
    nl = data.find(b'\n', pos)
    if nl == -1:
        return data[pos:]
    return data[pos:nl + 1]


# ---------------------------------------------------------------------------
#  Snapshot cache — avoids re-interpreting KDOS+bsky.f for every test
# ---------------------------------------------------------------------------
_snapshot = None   # (mem_bytes, ext_mem_bytes, cpu_state)
_bios_code = None


def _save_cpu_state(cpu):
    return {
        'regs': list(cpu.regs),
        'psel': cpu.psel, 'xsel': cpu.xsel, 'spsel': cpu.spsel,
        'flag_z': cpu.flag_z, 'flag_c': cpu.flag_c,
        'flag_n': cpu.flag_n, 'flag_v': cpu.flag_v,
        'flag_p': cpu.flag_p, 'flag_g': cpu.flag_g,
        'flag_i': cpu.flag_i, 'flag_s': cpu.flag_s,
        'd_reg': cpu.d_reg, 'q_out': cpu.q_out, 't_reg': cpu.t_reg,
        'ivt_base': cpu.ivt_base, 'ivec_id': cpu.ivec_id,
        'trap_addr': cpu.trap_addr,
        'halted': cpu.halted, 'idle': cpu.idle,
        'cycle_count': cpu.cycle_count,
        '_ext_modifier': cpu._ext_modifier,
        'priv_level': getattr(cpu, 'priv_level', 0),
        'mpu_base': getattr(cpu, 'mpu_base', 0),
        'mpu_limit': getattr(cpu, 'mpu_limit', 0),
    }


def _restore_cpu_state(cpu, state):
    cpu.regs[:] = state['regs']
    for k in ('psel', 'xsel', 'spsel',
              'flag_z', 'flag_c', 'flag_n', 'flag_v',
              'flag_p', 'flag_g', 'flag_i', 'flag_s',
              'd_reg', 'q_out', 't_reg',
              'ivt_base', 'ivec_id', 'trap_addr',
              'halted', 'idle', 'cycle_count', '_ext_modifier',
              'priv_level', 'mpu_base', 'mpu_limit'):
        setattr(cpu, k, state.get(k, 0))


def build_snapshot():
    """Assemble BIOS → load KDOS → load bsky.f → take snapshot."""
    global _snapshot, _bios_code

    print("  Assembling BIOS …")
    with open(BIOS_ASM) as f:
        _bios_code = assemble(f.read())
    print(f"  BIOS: {len(_bios_code)} bytes")

    # Read KDOS lines (skip blanks & comments for speed)
    print("  Loading KDOS …")
    with open(KDOS_F) as f:
        kdos_lines = [line for line in f.read().splitlines()
                      if line.strip() and not line.strip().startswith('\\')]

    # Read tools.f lines (provides _HTTP-FIND-HEND, _HTTP-PARSE-CLEN, etc.)
    print("  Loading tools.f …")
    with open(TOOLS_F) as f:
        tools_lines = [line for line in f.read().splitlines()
                       if line.strip() and not line.strip().startswith('\\')]

    # Read bsky.f lines
    print("  Loading bsky.f …")
    with open(BSKY_F) as f:
        bsky_lines = [line for line in f.read().splitlines()
                      if line.strip() and not line.strip().startswith('\\')]

    # Test helper words: a separate string-builder buffer for constructing
    # test inputs (e.g. JSON with embedded quotes).
    #   TR       — reset test buffer
    #   TC (c--) — append a character
    #   TQ       — append a double-quote character (34)
    #   TS (a u--) — append a counted string
    #   TA (--a u) — return test buffer contents as addr u
    test_helpers = [
        'CREATE _TB 512 ALLOT  VARIABLE _TL',
        ': TR  0 _TL ! ;',
        ': TC  ( c -- ) _TB _TL @ + C!  1 _TL +! ;',
        ': TQ  34 TC ;',
        ': TS  ( addr u -- ) >R _TB _TL @ + R@ CMOVE  R> _TL +! ;',
        ': TA  ( -- addr u ) _TB _TL @ ;',
    ]

    sys_obj = make_system(ram_kib=1024, ext_mem_mib=16)
    buf = capture_uart(sys_obj)
    sys_obj.load_binary(0, _bios_code)
    sys_obj.boot()

    all_lines = kdos_lines + tools_lines + ['ENTER-USERLAND'] + bsky_lines + test_helpers
    payload = "\n".join(all_lines) + "\n"
    data = payload.encode()
    pos = 0
    max_steps = 400_000_000
    total = 0

    while total < max_steps:
        if sys_obj.cpu.halted:
            break
        if sys_obj.cpu.idle and not sys_obj.uart.has_rx_data:
            if pos < len(data):
                chunk = _next_line_chunk(data, pos)
                sys_obj.uart.inject_input(chunk)
                pos += len(chunk)
            else:
                break
            continue
        batch = sys_obj.run_batch(min(100_000, max_steps - total))
        total += max(batch, 1)

    boot_text = uart_text(buf)
    print(f"  Boot steps: {total:,}")

    # Check for errors during load
    if "?" in boot_text.split("\n")[-5:]:
        print("  WARNING: Possible error during KDOS/bsky.f load!")
        # Print last 10 lines of boot output for debugging
        for line in boot_text.strip().split("\n")[-10:]:
            print(f"    | {line}")

    _snapshot = (bytes(sys_obj.cpu.mem), bytes(sys_obj._ext_mem), _save_cpu_state(sys_obj.cpu))
    print("  Snapshot ready.\n")
    return boot_text


def run_forth(lines, max_steps=50_000_000):
    """Restore from snapshot, evaluate Forth lines, return UART text."""
    mem_bytes, ext_mem_bytes, cpu_state = _snapshot

    sys_obj = make_system(ram_kib=1024, ext_mem_mib=16)
    buf = capture_uart(sys_obj)
    sys_obj.cpu.mem[:len(mem_bytes)] = mem_bytes
    sys_obj._ext_mem[:len(ext_mem_bytes)] = ext_mem_bytes
    _restore_cpu_state(sys_obj.cpu, cpu_state)

    payload = "\n".join(lines) + "\nBYE\n"
    data = payload.encode()
    pos = 0
    steps = 0

    while steps < max_steps:
        if sys_obj.cpu.halted:
            break
        if sys_obj.cpu.idle and not sys_obj.uart.has_rx_data:
            if pos < len(data):
                chunk = _next_line_chunk(data, pos)
                sys_obj.uart.inject_input(chunk)
                pos += len(chunk)
            else:
                break
            continue
        batch = sys_obj.run_batch(min(100_000, max_steps - steps))
        steps += max(batch, 1)

    return uart_text(buf)


# ---------------------------------------------------------------------------
#  Test framework
# ---------------------------------------------------------------------------
_pass = 0
_fail = 0
_errors = []


def check(name, forth_lines, expected, check_fn=None):
    """Run a test case.

    forth_lines: list of Forth lines to evaluate
    expected: substring that must appear in the output
    check_fn: optional callable(output) -> bool for custom checks
    """
    global _pass, _fail
    try:
        output = run_forth(forth_lines)
        # Strip "ok" prompts and clean up for matching
        clean = output.strip()

        if check_fn:
            ok = check_fn(clean)
        else:
            ok = expected in clean

        if ok:
            _pass += 1
            print(f"  PASS  {name}")
        else:
            _fail += 1
            _errors.append(name)
            print(f"  FAIL  {name}")
            print(f"        expected: {expected!r}")
            print(f"        got:      {clean!r}")
    except Exception as e:
        _fail += 1
        _errors.append(name)
        print(f"  ERR   {name}: {e}")
        traceback.print_exc()


def jstr(s):
    """Return Forth lines that build string *s* in the test buffer
    using only TC calls (prompt-compatible, no S\" needed).

    Use ``TA`` inside a colon definition to retrieve (addr u).
    """
    # Build string at prompt using character codes
    parts = ['TR']
    for ch in s:
        parts.append(f'{ord(ch)} TC')
    # Split into multiple lines of ~70 chars to avoid TIB overflow
    lines = []
    cur = []
    cur_len = 0
    for p in parts:
        if cur_len + len(p) + 1 > 70 and cur:
            lines.append(' '.join(cur))
            cur = [p]
            cur_len = len(p)
        else:
            cur.append(p)
            cur_len += len(p) + 1
    if cur:
        lines.append(' '.join(cur))
    return lines


def jstr_inline(s):
    """Like jstr() but returns a single Forth line (for embedding in check calls)."""
    parts = ['TR']
    for ch in s:
        parts.append(f'{ord(ch)} TC')
    return ' '.join(parts)


# ---------------------------------------------------------------------------
#  Test cases
# ---------------------------------------------------------------------------

def test_stage0():
    """Test §0 Foundation Utilities."""
    print("── Stage 0: Foundation Utilities ──\n")

    # §0.1 String Builder
    check("BSK-RESET clears buffer",
          ['BSK-RESET BSK-LEN @ .'],
          "0 ")

    check("BSK-APPEND + BSK-TYPE",
          [': T BSK-RESET S" hello" BSK-APPEND BSK-TYPE ; T'],
          "hello")

    check("BSK-APPEND multiple",
          [': T BSK-RESET S" foo" BSK-APPEND S" bar" BSK-APPEND BSK-TYPE ; T'],
          "foobar")

    check("BSK-EMIT single char",
          ['BSK-RESET 65 BSK-EMIT BSK-TYPE'],
          "A")

    check("BSK-EMIT multiple chars",
          ['BSK-RESET 72 BSK-EMIT 105 BSK-EMIT BSK-TYPE'],
          "Hi")

    # §0.1 Number conversion
    check("NUM>STR zero",
          [': T 0 NUM>STR TYPE ; T'],
          "0")

    check("NUM>STR 42",
          [': T 42 NUM>STR TYPE ; T'],
          "42")

    check("NUM>STR 12345",
          [': T 12345 NUM>STR TYPE ; T'],
          "12345")

    check("NUM>STR 1",
          [': T 1 NUM>STR TYPE ; T'],
          "1")

    check("NUM>APPEND",
          [': T BSK-RESET S" count=" BSK-APPEND 99 NUM>APPEND BSK-TYPE ; T'],
          "count=99")

    # §0.2 JSON Escaping
    check("JSON-ESCAPE-CHAR normal",
          ['BSK-RESET 65 JSON-ESCAPE-CHAR BSK-TYPE'],
          "A")

    check("JSON-ESCAPE-CHAR quote",
          ['BSK-RESET 34 JSON-ESCAPE-CHAR BSK-TYPE'],
          None,
          # Should produce \" — backslash (92) then quote (34)
          lambda out: '\\"' in out)

    check("JSON-ESCAPE-CHAR backslash",
          ['BSK-RESET 92 JSON-ESCAPE-CHAR BSK-LEN @ .'],
          "2 ")  # Should emit two chars: \\ 

    check("JSON-COPY-ESCAPED plain",
          [': T BSK-RESET S" hello" JSON-COPY-ESCAPED BSK-TYPE ; T'],
          "hello")

    # §0.3 Timestamp
    check("BSK-NOW format",
          [': T BSK-NOW TYPE ; T'],
          None,
          lambda out: any(
              "Z" in line and len([c for c in line if c in "0123456789-T:.Z"]) >= 20
              for line in out.split("\n")
          ))

    check("BSK-NOW length",
          [': T BSK-NOW NIP . ; T'],
          "24 ")

    # §0.4 URL Encoding
    check("URL-ENCODE plain",
          [': T BSK-RESET S" hello" URL-ENCODE BSK-TYPE ; T'],
          "hello")

    # Build "a:b" using EMIT into a scratch buffer, then URL-ENCODE it
    check("URL-ENCODE special chars",
          ['CREATE _TURL 8 ALLOT',
           '97 _TURL C!  58 _TURL 1+ C!  98 _TURL 2 + C!',
           ': T BSK-RESET _TURL 3 URL-ENCODE BSK-TYPE ; T'],
          "a%3Ab")

    check("URL-ENCODE space",
          ['CREATE _TSPC 4 ALLOT  32 _TSPC C!',
           ': T BSK-RESET _TSPC 1 URL-ENCODE BSK-TYPE ; T'],
          "%20")

    check("URL-ENCODE safe chars preserved",
          [': T BSK-RESET S" hello-world_v1.0~test" URL-ENCODE BSK-TYPE ; T'],
          "hello-world_v1.0~test")

    # §0.5 Convenience
    check("BSK-CRLF",
          ['BSK-RESET BSK-CRLF BSK-LEN @ .'],
          "2 ")

    check("BSK-QUOTE",
          [': T BSK-RESET S" test" BSK-QUOTE BSK-TYPE ; T'],
          '"test"')

    check("BSK-KV",
          [': T BSK-RESET S" name" S" alice" BSK-KV BSK-TYPE ; T'],
          '"name":"alice"')

    check("BSK-KV,",
          [': T BSK-RESET S" age" S" 30" BSK-KV, BSK-TYPE ; T'],
          ',"age":"30"')


def test_stage1():
    """Test §1 Minimal JSON Parser."""
    print("── Stage 1: JSON Parser ──\n")

    # §1.1 Key finder
    check("JSON-FIND-KEY simple",
          jstr('{"name":"alice"}') +
          [': _T TA S" name" JSON-FIND-KEY JSON-GET-STRING TYPE ;', '_T'],
          "alice")

    check("JSON-FIND-KEY second key",
          jstr('{"x":1,"y":"bob"}') +
          [': _T TA S" y" JSON-FIND-KEY JSON-GET-STRING TYPE ;', '_T'],
          "bob")

    check("JSON-FIND-KEY missing",
          jstr('{"a":1}') +
          [': _T TA S" z" JSON-FIND-KEY NIP . ;', '_T'],
          "0 ")

    # §1.2 Value extractors
    check("JSON-GET-STRING basic",
          jstr('"hello"') +
          [': _T TA JSON-GET-STRING TYPE ;', '_T'],
          "hello")

    # "ab\"cd" — raw bytes: " a b \ " c d "
    check("JSON-GET-STRING with escape",
          jstr('"ab\\"cd"') +
          [': _T TA JSON-GET-STRING TYPE ;', '_T'],
          None,
          lambda out: 'ab' in out and 'cd' in out)

    check("JSON-GET-STRING empty",
          jstr('""') +
          [': _T TA JSON-GET-STRING NIP . ;', '_T'],
          "0 ")

    check("JSON-GET-NUMBER positive",
          jstr('{"val":42}') +
          [': _T TA S" val" JSON-FIND-KEY JSON-GET-NUMBER . ;', '_T'],
          "42 ")

    check("JSON-GET-NUMBER negative",
          jstr('{"val":-7}') +
          [': _T TA S" val" JSON-FIND-KEY JSON-GET-NUMBER . ;', '_T'],
          "-7 ")

    check("JSON-GET-NUMBER zero",
          jstr('{"n":0}') +
          [': _T TA S" n" JSON-FIND-KEY JSON-GET-NUMBER . ;', '_T'],
          "0 ")

    # §1.2 Skip value
    check("JSON-SKIP-STRING",
          jstr('"hello",rest') +
          [': _T TA JSON-SKIP-STRING TYPE ;', '_T'],
          ",rest")

    check("JSON-SKIP-VALUE number",
          jstr('42,next') +
          [': _T TA JSON-SKIP-VALUE TYPE ;', '_T'],
          ",next")

    check("JSON-SKIP-VALUE nested object",
          jstr('{"a":1},rest') +
          [': _T TA JSON-SKIP-VALUE TYPE ;', '_T'],
          ",rest")

    # §1.3 Array iterator
    check("JSON-GET-ARRAY",
          jstr('{"items":[1,2,3]}') +
          [': _T TA S" items" JSON-GET-ARRAY JSON-GET-NUMBER . ;', '_T'],
          "1 ")

    check("JSON-NEXT-ITEM",
          jstr('1,2,3]}') +
          [': _T TA JSON-SKIP-VALUE JSON-NEXT-ITEM JSON-GET-NUMBER . ;', '_T'],
          "2 ")

    # Combined: find key in nested JSON
    check("Nested key lookup",
          jstr('{"user":{"did":"plc:123","handle":"alice"},"ok":true}') +
          [': _T TA S" did" JSON-FIND-KEY JSON-GET-STRING TYPE ;', '_T'],
          "plc:123")

    # /STRING
    check("/STRING basic",
          [': _T S" abcdef" 2 /STRING TYPE ;', '_T'],
          "cdef")


def test_stage2():
    """Test §2 HTTP POST and Authenticated GET."""
    print("── Stage 2: HTTP POST and Authenticated GET ──\n")

    # §2.1 Memory Setup
    check("BSK-INIT sets READY",
          ['BSK-INIT BSK-READY @ .'],
          "-1 ")

    check("BSK-INIT idempotent",
          ['BSK-INIT BSK-RECV-BUF @ BSK-INIT BSK-RECV-BUF @ = .'],
          "-1 ")

    check("BSK-RECV-BUF non-zero after init",
          ['BSK-INIT BSK-RECV-BUF @ 0 > .'],
          "-1 ")

    check("BSK-RECV-LEN starts at 0",
          ['BSK-INIT BSK-RECV-LEN @ .'],
          "0 ")

    check("BSK-ACCESS-LEN starts at 0",
          ['BSK-INIT BSK-ACCESS-LEN @ .'],
          "0 ")

    check("BSK-DID-LEN starts at 0",
          ['BSK-INIT BSK-DID-LEN @ .'],
          "0 ")

    check("BSK-CLEANUP clears READY",
          ['BSK-INIT BSK-CLEANUP BSK-READY @ .'],
          "0 ")

    # §2.2 DNS — can't test actual DNS without a NIC, but test the
    # _BSK-ENSURE-IP logic (returns -1 when no NIC/DNS available)
    check("BSK-SERVER-IP starts at 0",
          ['BSK-INIT BSK-SERVER-IP @ .'],
          "0 ")

    # §2.3 Request Builders
    check("BSK-BUILD-GET basic",
          ['BSK-INIT',
           ': _T S" /xrpc/test" BSK-BUILD-GET BSK-TYPE ; _T'],
          None,
          lambda out: 'GET /xrpc/test HTTP/1.1' in out)

    check("BSK-BUILD-GET has Host header",
          ['BSK-INIT',
           ': _T S" /" BSK-BUILD-GET BSK-TYPE ; _T'],
          None,
          lambda out: 'Host: bsky.social' in out)

    check("BSK-BUILD-GET has Connection close",
          ['BSK-INIT',
           ': _T S" /" BSK-BUILD-GET BSK-TYPE ; _T'],
          None,
          lambda out: 'Connection: close' in out)

    check("BSK-BUILD-GET no auth when no token",
          ['BSK-INIT',
           ': _T S" /" BSK-BUILD-GET BSK-TYPE ; _T'],
          None,
          lambda out: 'Authorization' not in out)

    # Simulate a stored JWT and check auth header appears
    check("BSK-BUILD-GET with auth token",
          ['BSK-INIT',
           ': _T S" tok123" BSK-ACCESS-JWT SWAP CMOVE  6 BSK-ACCESS-LEN ! ;',
           '_T',
           ': _T2 S" /" BSK-BUILD-GET BSK-TYPE ; _T2'],
          None,
          lambda out: 'Authorization: Bearer tok123' in out)

    check("BSK-BUILD-POST basic",
          ['BSK-INIT',
           ': _T S" /xrpc/post" S" {}" BSK-BUILD-POST BSK-TYPE ; _T'],
          None,
          lambda out: 'POST /xrpc/post HTTP/1.1' in out)

    check("BSK-BUILD-POST has content-type",
          ['BSK-INIT',
           ': _T S" /p" S" {}" BSK-BUILD-POST BSK-TYPE ; _T'],
          None,
          lambda out: 'Content-Type: application/json' in out)

    check("BSK-BUILD-POST has content-length",
          ['BSK-INIT',
           ': _T S" /p" S" {}" BSK-BUILD-POST BSK-TYPE ; _T'],
          None,
          lambda out: 'Content-Length: 2' in out)

    check("BSK-BUILD-POST includes body",
          ['BSK-INIT',
           ': _T S" /p" S" {}" BSK-BUILD-POST BSK-TYPE ; _T'],
          None,
          lambda out: '{}' in out and 'Content-Length' in out)

    check("BSK-BUILD-POST larger body length",
          ['BSK-INIT'] +
          jstr('{"id":"x","pw":"y"}') +
          [': _T S" /a" TA BSK-BUILD-POST BSK-TYPE ; _T'],
          None,
          lambda out: 'Content-Length: 19' in out)

    # §2.5 Response Parser — test _BSK-PARSE-STATUS and BSK-PARSE-RESPONSE
    # by manually filling the recv buffer
    check("Parse HTTP 200 status",
          ['BSK-INIT'] +
          jstr('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}') +
          [': _T TA DUP >R BSK-RECV-BUF @ SWAP CMOVE R> BSK-RECV-LEN !',
           'BSK-PARSE-RESPONSE . TYPE ; _T'],
          None,
          lambda out: '200' in out and '{}' in out)

    check("Parse HTTP 401 status",
          ['BSK-INIT'] +
          jstr('HTTP/1.1 401 Unauthorized\r\nContent-Length: 5\r\n\r\nerror') +
          [': _T TA DUP >R BSK-RECV-BUF @ SWAP CMOVE R> BSK-RECV-LEN !',
           'BSK-PARSE-RESPONSE . TYPE ; _T'],
          None,
          lambda out: '401' in out and 'error' in out)

    check("BSK-HTTP-STATUS stored",
          ['BSK-INIT'] +
          jstr('HTTP/1.1 200 OK\r\n\r\nhi') +
          [': _T TA DUP >R BSK-RECV-BUF @ SWAP CMOVE R> BSK-RECV-LEN !',
           'BSK-PARSE-RESPONSE 2DROP DROP BSK-HTTP-STATUS @ . ; _T'],
          "200 ")

    # §2.6 — High-level wrappers can't be tested without network, but we
    # can verify they exist (no compilation errors) by checking their xt
    check("BSK-GET word exists",
          ["' BSK-GET 0> ."],
          "-1 ")

    check("BSK-POST-JSON word exists",
          ["' BSK-POST-JSON 0> ."],
          "-1 ")


def test_stage3():
    """Stage 3: Authentication — login JSON builder, session parser, commands."""
    print("Stage 3: Authentication")
    print("-" * 40)

    # §3.1 — Login JSON builder
    check("Login JSON basic structure",
          ['BSK-INIT',
           ': _T S" alice.bsky.social" S" pass123"',
           '  _BSK-BUILD-LOGIN-JSON',
           '  _BSK-LOGIN-BUF _BSK-LOGIN-LEN @ TYPE ; _T'],
          None,
          lambda out: '"identifier":"alice.bsky.social"' in out
                      and '"password":"pass123"' in out)

    check("Login JSON is valid shape",
          ['BSK-INIT',
           ': _T S" user" S" pw"',
           '  _BSK-BUILD-LOGIN-JSON',
           '  _BSK-LOGIN-BUF _BSK-LOGIN-LEN @ TYPE ; _T'],
          '{"identifier":"user","password":"pw"}')

    check("Login JSON with special chars",
          ['BSK-INIT'] +
          jstr('test"user') +
          [': _T TA S" pw"',
           '  _BSK-BUILD-LOGIN-JSON',
           '  _BSK-LOGIN-BUF _BSK-LOGIN-LEN @ TYPE ; _T'],
          None,
          lambda out: r'test\"user' in out)

    # §3.2 — Session parser
    # Build a fake createSession response JSON and parse it
    check("Parse session extracts accessJwt",
          ['BSK-INIT'] +
          jstr('{"accessJwt":"atok","refreshJwt":"rtok","did":"did:plc:abc","handle":"me.bsky.social"}') +
          [': _T TA _BSK-PARSE-SESSION . ; _T'],
          "-1 ")  # -1 = success

    check("Parse session stores access token",
          ['BSK-INIT'] +
          jstr('{"accessJwt":"myaccess","refreshJwt":"myrefresh","did":"did:plc:x","handle":"h.bsky.social"}') +
          [': _T TA _BSK-PARSE-SESSION DROP',
           '  BSK-ACCESS-JWT BSK-ACCESS-LEN @ TYPE ; _T'],
          "myaccess")

    check("Parse session stores refresh token",
          ['BSK-INIT'] +
          jstr('{"accessJwt":"a","refreshJwt":"myrefresh","did":"did:plc:x","handle":"h.bsky.social"}') +
          [': _T TA _BSK-PARSE-SESSION DROP',
           '  BSK-REFRESH-JWT BSK-REFRESH-LEN @ TYPE ; _T'],
          "myrefresh")

    check("Parse session stores DID",
          ['BSK-INIT'] +
          jstr('{"accessJwt":"a","refreshJwt":"r","did":"did:plc:abc123","handle":"h.bsky.social"}') +
          [': _T TA _BSK-PARSE-SESSION DROP',
           '  BSK-DID BSK-DID-LEN @ TYPE ; _T'],
          "did:plc:abc123")

    check("Parse session stores handle",
          ['BSK-INIT'] +
          jstr('{"accessJwt":"a","refreshJwt":"r","did":"did:plc:x","handle":"alice.bsky.social"}') +
          [': _T TA _BSK-PARSE-SESSION DROP',
           '  BSK-HANDLE BSK-HANDLE-LEN @ TYPE ; _T'],
          "alice.bsky.social")

    check("Parse session fails on missing key",
          ['BSK-INIT'] +
          jstr('{"accessJwt":"a","did":"did:plc:x","handle":"h"}') +
          [': _T TA _BSK-PARSE-SESSION . ; _T'],
          "0 ")  # 0 = failure (missing refreshJwt)

    check("Parse session access token length",
          ['BSK-INIT'] +
          jstr('{"accessJwt":"shortjwt","refreshJwt":"r","did":"did:plc:x","handle":"h"}') +
          [': _T TA _BSK-PARSE-SESSION DROP',
           '  BSK-ACCESS-LEN @ . ; _T'],
          "8 ")  # len("shortjwt") = 8

    # §3.3 — BSK-LOGIN word exists (can't test without network)
    check("BSK-LOGIN word exists",
          ["' BSK-LOGIN 0> ."],
          "-1 ")

    # §3.4 — BSK-REFRESH word exists
    check("BSK-REFRESH word exists",
          ["' BSK-REFRESH 0> ."],
          "-1 ")

    # §3.5 — BSK-WHO
    check("BSK-WHO no session",
          ['BSK-INIT',
           ': _T BSK-WHO ; _T'],
          "Not logged in")

    check("BSK-WHO with session",
          ['BSK-INIT'] +
          jstr('{"accessJwt":"atok","refreshJwt":"rtok","did":"did:plc:test","handle":"me.bsky.social"}') +
          [': _T TA _BSK-PARSE-SESSION DROP BSK-WHO ; _T'],
          None,
          lambda out: 'me.bsky.social' in out and 'did:plc:test' in out)


def test_stage4():
    """Stage 4: Read-Only Features — timeline, profile, notifications."""
    print("Stage 4: Read-Only Features")
    print("-" * 40)

    # §4.0 — Display helpers
    check("Type-trunc short string",
          [': _T S" hello" 10 _BSK-TYPE-TRUNC ; _T'],
          "hello")

    check("Type-trunc at limit",
          [': _T S" hello" 5 _BSK-TYPE-TRUNC ; _T'],
          "hello")

    check("Type-trunc over limit",
          [': _T S" hello world" 8 _BSK-TYPE-TRUNC ; _T'],
          "hello...")

    # §4.1 — Timeline path builder
    check("TL path without cursor",
          ['BSK-INIT',
           ': _T _BSK-TL-PATH TYPE ; _T'],
          "/xrpc/app.bsky.feed.getTimeline?limit=5")

    check("TL path with cursor",
          ['BSK-INIT'] +
          jstr('abc123') +
          [': _T TA BSK-TL-CURSOR SWAP DUP BSK-TL-CURSOR-LEN ! CMOVE',
           '  _BSK-TL-PATH TYPE ; _T'],
          "/xrpc/app.bsky.feed.getTimeline?limit=5&cursor=abc123")

    # §4.1 — Timeline post printer
    # Simulate a single feed item with nested post/author/record
    check("TL print post extracts handle",
          ['BSK-INIT'] +
          jstr('{"post":{"author":{"handle":"alice.bsky.social","displayName":"Alice"},"record":{"text":"Hello world"}}}') +
          [': _T TA _BSK-TL-PRINT-POST ; _T'],
          None,
          lambda out: '@alice.bsky.social' in out)

    check("TL print post extracts displayName",
          ['BSK-INIT'] +
          jstr('{"post":{"author":{"handle":"alice.bsky.social","displayName":"Alice"},"record":{"text":"Hello world"}}}') +
          [': _T TA _BSK-TL-PRINT-POST ; _T'],
          None,
          lambda out: '(Alice)' in out)

    check("TL print post extracts text",
          ['BSK-INIT'] +
          jstr('{"post":{"author":{"handle":"bob.bsky.social","displayName":"Bob"},"record":{"text":"Testing 123"}}}') +
          [': _T TA _BSK-TL-PRINT-POST ; _T'],
          "Testing 123")

    check("TL print post shows separator",
          ['BSK-INIT'] +
          jstr('{"post":{"author":{"handle":"x.bsky.social","displayName":"X"},"record":{"text":"hi"}}}') +
          [': _T TA _BSK-TL-PRINT-POST ; _T'],
          "---")

    # §4.2 — Profile path builder
    check("Profile path simple handle",
          ['BSK-INIT',
           ': _T S" alice.bsky.social" _BSK-PROFILE-PATH TYPE ; _T'],
          "/xrpc/app.bsky.actor.getProfile?actor=alice.bsky.social")

    check("Profile path DID encoding",
          ['BSK-INIT',
           ': _T S" did:plc:abc" _BSK-PROFILE-PATH TYPE ; _T'],
          "/xrpc/app.bsky.actor.getProfile?actor=did%3Aplc%3Aabc")

    # §4.2 — Word existence checks for network-dependent words
    check("BSK-PROFILE word exists",
          ["' BSK-PROFILE 0> ."],
          "-1 ")

    check("BSK-TL word exists",
          ["' BSK-TL 0> ."],
          "-1 ")

    check("BSK-TL-NEXT word exists",
          ["' BSK-TL-NEXT 0> ."],
          "-1 ")

    # §4.3 — Notification printer
    check("Notif print extracts reason",
          ['BSK-INIT'] +
          jstr('{"reason":"like","author":{"handle":"carol.bsky.social","displayName":"Carol"}}') +
          [': _T TA _BSK-NOTIF-PRINT ; _T'],
          "like")

    check("Notif print extracts author handle",
          ['BSK-INIT'] +
          jstr('{"reason":"follow","author":{"handle":"dan.bsky.social","displayName":"Dan"}}') +
          [': _T TA _BSK-NOTIF-PRINT ; _T'],
          "@dan.bsky.social")

    check("Notif print shows from",
          ['BSK-INIT'] +
          jstr('{"reason":"reply","author":{"handle":"eve.bsky.social"}}') +
          [': _T TA _BSK-NOTIF-PRINT ; _T'],
          " from ")

    check("BSK-NOTIF word exists",
          ["' BSK-NOTIF 0> ."],
          "-1 ")

    check("BSK-TL requires login",
          ['BSK-INIT',
           ': _T BSK-TL ; _T'],
          "login first")

    check("BSK-NOTIF requires login",
          ['BSK-INIT',
           ': _T BSK-NOTIF ; _T'],
          "login first")

    # §2.5 — Chunked transfer encoding decoder
    check("Dechunk single chunk",
          ['BSK-INIT'] +
          jstr('5\r\nhello\r\n0\r\n\r\n') +
          [': _T TA _PR-BLEN ! _PR-BADDR ! _BSK-DECHUNK',
           '  _PR-BADDR @ _PR-BLEN @ TYPE ; _T'],
          "hello")

    check("Dechunk chunk size",
          ['BSK-INIT'] +
          jstr('3\r\nabc\r\n0\r\n\r\n') +
          [': _T TA _PR-BLEN ! _PR-BADDR ! _BSK-DECHUNK',
           '  _PR-BLEN @ . ; _T'],
          "3 ")

    check("Dechunk hex chunk size",
          ['BSK-INIT'] +
          jstr('a\r\n0123456789\r\n0\r\n\r\n') +
          [': _T TA _PR-BLEN ! _PR-BADDR ! _BSK-DECHUNK',
           '  _PR-BADDR @ _PR-BLEN @ TYPE ; _T'],
          "0123456789")

    check("Parse chunk size basic",
          ['BSK-INIT'] +
          jstr('ddb\r\ndata') +
          [': _T TA _BSK-PARSE-CHUNK-SIZE . . ; _T'],
          None,
          lambda out: '5 3547' in out or '5 3547 ' in out)


def test_stage5():
    """Stage 5: Write Features — post, reply, like, repost."""
    print("Stage 5: Write Features")
    print("-" * 40)

    # Fake DID for testing: did:plc:test123
    did_setup = (
        jstr('did:plc:test123') +
        [': _DID-SET TA BSK-DID SWAP DUP BSK-DID-LEN ! CMOVE ;',
         '_DID-SET']
    )

    # §5.1 — JSON builder helpers
    check("_BSK-QK quoted key",
          ['BSK-RESET',
           ': _T S" name" _BSK-QK BSK-TYPE ; _T'],
          '"name":')

    check("_BSK-QV quoted value",
          ['BSK-RESET',
           ': _T S" hello" _BSK-QV BSK-TYPE ; _T'],
          '"hello"')

    check("_BSK-QV-ESC escapes quotes",
          ['BSK-RESET'] +
          jstr('say "hi"') +
          [': _T TA _BSK-QV-ESC BSK-TYPE ; _T'],
          r'"say \"hi\""')

    check("_BSK-CR-OPEN builds record prefix",
          did_setup +
          [': _T S" app.bsky.feed.post" _BSK-CR-OPEN BSK-TYPE ; _T'],
          None,
          lambda out: '"repo":"did:plc:test123"' in out
                      and '"collection":"app.bsky.feed.post"' in out
                      and '"$type":"app.bsky.feed.post"' in out)

    check("_BSK-CREATED-AT appends timestamp key",
          ['BSK-RESET',
           ': _T _BSK-CREATED-AT BSK-TYPE ; _T'],
          '"createdAt":"')

    check("_BSK-SUBJECT builds subject JSON",
          ['BSK-RESET',
           'CREATE _U 256 ALLOT  VARIABLE _UL',
           'CREATE _C 256 ALLOT  VARIABLE _CL'] +
          jstr('at://did:plc:x/app.bsky.feed.post/abc') +
          ['TA DUP _UL !  _U SWAP CMOVE'] +
          jstr('bafydef') +
          ['TA DUP _CL !  _C SWAP CMOVE',
           ': _T _U _UL @ _C _CL @ _BSK-SUBJECT BSK-TYPE ; _T'],
          None,
          lambda out: '"subject":{' in out
                      and '"uri":"at://did:plc:x/app.bsky.feed.post/abc"' in out
                      and '"cid":"bafydef"' in out)

    # §5.2 — BSK-POST JSON body
    check("BSK-POST builds correct JSON",
          did_setup +
          [': _T S" app.bsky.feed.post" _BSK-CR-OPEN',
           '  S" text" _BSK-QK',
           '  S" Hello from Megapad!" _BSK-QV-ESC',
           '  _BSK-COMMA _BSK-CREATED-AT _BSK-CR-CLOSE',
           '  BSK-TYPE ; _T'],
          None,
          lambda out: ('"repo":"did:plc:test123"' in out
                      and '"text":"Hello from Megapad!"' in out
                      and '"createdAt":"' in out
                      and '}}' in out))

    # §5.4 — BSK-LIKE JSON body
    check("BSK-LIKE builds correct JSON",
          did_setup +
          ['CREATE _U2 256 ALLOT  VARIABLE _U2L',
           'CREATE _C2 256 ALLOT  VARIABLE _C2L'] +
          jstr('at://did:plc:x/app.bsky.feed.post/abc') +
          ['TA DUP _U2L !  _U2 SWAP CMOVE'] +
          jstr('bafylike') +
          ['TA DUP _C2L !  _C2 SWAP CMOVE',
           ': _T',
           '  S" app.bsky.feed.like" _BSK-CR-OPEN',
           '  _U2 _U2L @ _C2 _C2L @ _BSK-SUBJECT',
           '  _BSK-COMMA _BSK-CREATED-AT _BSK-CR-CLOSE',
           '  BSK-TYPE ; _T'],
          None,
          lambda out: ('"collection":"app.bsky.feed.like"' in out
                      and '"uri":"at://did:plc:x/app.bsky.feed.post/abc"' in out
                      and '"cid":"bafylike"' in out))

    # §5.5 — BSK-REPOST JSON body
    check("BSK-REPOST builds correct JSON",
          did_setup +
          ['CREATE _U3 256 ALLOT  VARIABLE _U3L',
           'CREATE _C3 256 ALLOT  VARIABLE _C3L'] +
          jstr('at://did:plc:y/app.bsky.feed.post/xyz') +
          ['TA DUP _U3L !  _U3 SWAP CMOVE'] +
          jstr('bafyrepost') +
          ['TA DUP _C3L !  _C3 SWAP CMOVE',
           ': _T',
           '  S" app.bsky.feed.repost" _BSK-CR-OPEN',
           '  _U3 _U3L @ _C3 _C3L @ _BSK-SUBJECT',
           '  _BSK-COMMA _BSK-CREATED-AT _BSK-CR-CLOSE',
           '  BSK-TYPE ; _T'],
          None,
          lambda out: ('"collection":"app.bsky.feed.repost"' in out
                      and '"uri":"at://did:plc:y/app.bsky.feed.post/xyz"' in out))

    # §5 — Word existence checks
    check("BSK-POST word exists",
          ["' BSK-POST 0> ."],
          "-1 ")

    check("BSK-REPLY word exists",
          ["' BSK-REPLY 0> ."],
          "-1 ")

    check("BSK-LIKE word exists",
          ["' BSK-LIKE 0> ."],
          "-1 ")

    check("BSK-REPOST word exists",
          ["' BSK-REPOST 0> ."],
          "-1 ")

    # §5.2 — BSK-POST requires login
    check("BSK-POST requires login",
          ['BSK-INIT',
           ': _T S" test" BSK-POST ; _T'],
          "login first")

    # §5 — _BSK-STAGE-BODY copies buffer
    check("_BSK-STAGE-BODY copies BSK-BUF",
          ['BSK-RESET S" hello" BSK-APPEND',
           ': _T _BSK-STAGE-BODY _BSK-POST-BUF _BSK-POST-LEN @ TYPE ; _T'],
          "hello")

    # §5.5 — BSK-FOLLOW JSON body
    check("BSK-FOLLOW builds correct JSON",
          did_setup +
          [': _T S" app.bsky.graph.follow" _BSK-CR-OPEN',
           '  S" subject" _BSK-QK',
           '  S" did:plc:target123" _BSK-QV',
           '  _BSK-COMMA _BSK-CREATED-AT _BSK-CR-CLOSE',
           '  BSK-TYPE ; _T'],
          None,
          lambda out: ('"collection":"app.bsky.graph.follow"' in out
                      and '"subject":"did:plc:target123"' in out
                      and '"createdAt":"' in out))

    check("BSK-FOLLOW word exists",
          [': _T S" test" BSK-FOLLOW ; '],
          None,
          lambda out: "login first" in out or "?" not in out)

    check("BSK-UNFOLLOW word exists",
          [': _T S" abc123" BSK-UNFOLLOW ; '],
          None,
          lambda out: "login first" in out or "?" not in out)

    # §5.5 — _BSK-DR-OPEN (deleteRecord JSON builder)
    check("_BSK-DR-OPEN builds deleteRecord JSON",
          did_setup +
          [': _T S" app.bsky.feed.post" S" 3abc123" _BSK-DR-OPEN',
           '  BSK-TYPE ; _T'],
          None,
          lambda out: ('"repo":"did:plc:test123"' in out
                      and '"collection":"app.bsky.feed.post"' in out
                      and '"rkey":"3abc123"' in out))

    # §5.6 — URI parser
    check("_BSK-URI-PARSE basic AT-URI",
          jstr('at://did:plc:abc/app.bsky.feed.post/3xyz') +
          [': _T TA _BSK-URI-PARSE IF',
           '  ." rkey=" TYPE CR ." col=" TYPE CR',
           '  ELSE ." FAIL" THEN ; _T'],
          None,
          lambda out: 'rkey=3xyz' in out and 'col=app.bsky.feed.post' in out)

    check("_BSK-URI-PARSE no slashes fails",
          [': _T S" noslashes" _BSK-URI-PARSE IF',
           '  ." OK" ELSE ." FAIL" THEN ; _T'],
          "FAIL")

    check("_BSK-RFIND-SLASH finds last slash",
          [': _T S" a/b/c" _BSK-RFIND-SLASH . ; _T'],
          "3")

    check("_BSK-RFIND-SLASH no slash returns -1",
          [': _T S" abc" _BSK-RFIND-SLASH . ; _T'],
          "-1")

    check("BSK-DELETE word exists",
          [': _T S" at://x/y/z" BSK-DELETE ; '],
          None,
          lambda out: "login first" in out or "?" not in out)

    # §5.6 — BSK-DELETE end-to-end JSON (via _BSK-URI-PARSE + _BSK-DR-OPEN)
    check("BSK-DELETE parses URI and builds deleteRecord JSON",
          did_setup +
          jstr('at://did:plc:abc/app.bsky.feed.post/3xyz789') +
          [': _T TA _BSK-URI-PARSE IF',
           '  _BSK-DR-OPEN BSK-TYPE',
           '  ELSE ." PARSE-FAIL" THEN ; _T'],
          None,
          lambda out: ('"repo":"did:plc:test123"' in out
                      and '"collection":"app.bsky.feed.post"' in out
                      and '"rkey":"3xyz789"' in out))


# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------

def main():
    global _pass, _fail, _errors

    print("=" * 60)
    print("  bsky.f Test Suite")
    print("=" * 60)
    print()

    print("Building snapshot (BIOS → KDOS → bsky.f) …")
    boot_text = build_snapshot()

    # Show last few lines of boot output
    boot_lines = boot_text.strip().split("\n")
    print("  Last 5 boot lines:")
    for line in boot_lines[-5:]:
        print(f"    | {line}")
    print()

    # Check for errors during bsky.f load
    error_lines = [l for l in boot_lines if "?" in l and "ok" not in l.lower()]
    if error_lines:
        print("  *** ERRORS during load: ***")
        for el in error_lines:
            print(f"    | {el}")
        print()

    test_stage0()
    print()
    test_stage1()
    print()
    test_stage2()
    print()
    test_stage3()
    print()
    test_stage4()
    print()
    test_stage5()

    print()
    print("=" * 60)
    print(f"  Results: {_pass} passed, {_fail} failed")
    if _errors:
        print(f"  Failures: {', '.join(_errors)}")
    print("=" * 60)

    return 0 if _fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
