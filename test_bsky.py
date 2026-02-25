#!/usr/bin/env python3
"""Test harness for bsky.f — boots KDOS from a disk image, loads bsky.f
via autoexec, then runs Forth test expressions via UART.

Disk-image boot is orders of magnitude faster than the old UART-injection
approach because disk reads are instantaneous DMA copies.

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
from diskutil import MP64FS, FTYPE_FORTH
from pathlib import Path

# ---------------------------------------------------------------------------
#  Paths
# ---------------------------------------------------------------------------
BIOS_ASM = os.path.join(EMU_DIR, "bios.asm")
KDOS_F   = os.path.join(EMU_DIR, "kdos.f")
TOOLS_F  = os.path.join(EMU_DIR, "tools.f")
BSKY_F   = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bsky.f")
AKASHIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "akashic", "akashic")

# Akashic library files — (disk-path, host-path) pairs.
# Files are placed in subdirectories matching the akashic source tree
# so that internal REQUIRE ../utils/string.f paths resolve correctly.
AKASHIC_LIBS = [
    ("utils", os.path.join(AKASHIC_DIR, "utils", "string.f")),
    ("utils", os.path.join(AKASHIC_DIR, "utils", "json.f")),
    ("utils", os.path.join(AKASHIC_DIR, "utils", "datetime.f")),
    ("net",   os.path.join(AKASHIC_DIR, "net", "url.f")),
    ("net",   os.path.join(AKASHIC_DIR, "net", "headers.f")),
    ("net",   os.path.join(AKASHIC_DIR, "net", "base64.f")),
    ("net",   os.path.join(AKASHIC_DIR, "net", "http.f")),
    ("net",   os.path.join(AKASHIC_DIR, "net", "uri.f")),
    ("atproto", os.path.join(AKASHIC_DIR, "atproto", "xrpc.f")),
    ("atproto", os.path.join(AKASHIC_DIR, "atproto", "session.f")),
    ("atproto", os.path.join(AKASHIC_DIR, "atproto", "aturi.f")),
    ("atproto", os.path.join(AKASHIC_DIR, "atproto", "repo.f")),
]


# ---------------------------------------------------------------------------
#  Disk image builder — test variant
# ---------------------------------------------------------------------------

# Test autoexec.f — loads tools.f + bsky.f + test helpers, then returns
# to the KDOS prompt.  No networking, no login, no TUI.
_TEST_AUTOEXEC = """\
PROVIDED autoexec.f

\\ Switch to userland (ext mem) to conserve system dictionary
: _ENTER-UL  XMEM? IF ENTER-USERLAND THEN ;
_ENTER-UL

\\ Load modules from disk
REQUIRE tools.f
REQUIRE bsky.f

\\ Test helper words: separate buffer for building test inputs
CREATE _TB 512 ALLOT  VARIABLE _TL
: TR  0 _TL ! ;
: TC  ( c -- ) _TB _TL @ + C!  1 _TL +! ;
: TQ  34 TC ;
: TS  ( addr u -- ) >R _TB _TL @ + R@ CMOVE  R> _TL +! ;
: TA  ( -- addr u ) _TB _TL @ ;

"""


def build_test_disk() -> MP64FS:
    """Build an in-memory disk image for testing."""
    fs = MP64FS()
    fs.format()

    # 1. kdos.f — MUST be first file (BIOS auto-boots this)
    fs.inject_file("kdos.f", Path(KDOS_F).read_bytes(),
                   ftype=FTYPE_FORTH, flags=0x02)

    # 2. tools.f
    fs.inject_file("tools.f", Path(TOOLS_F).read_bytes(),
                   ftype=FTYPE_FORTH)

    # 3. Akashic libraries — in subdirectories matching source tree
    _created_dirs = set()
    for disk_dir, lib_path in AKASHIC_LIBS:
        p = Path(lib_path)
        if not p.exists():
            print(f"  WARNING: missing akashic lib: {p}")
            continue
        if disk_dir not in _created_dirs:
            fs.mkdir(disk_dir)
            _created_dirs.add(disk_dir)
        fs.inject_file(p.name, p.read_bytes(), ftype=FTYPE_FORTH,
                       path=f"/{disk_dir}")

    # 4. bsky.f
    fs.inject_file("bsky.f", Path(BSKY_F).read_bytes(),
                   ftype=FTYPE_FORTH)

    # 5. Test autoexec (no login/TUI — just load modules + helpers)
    fs.inject_file("autoexec.f", _TEST_AUTOEXEC.encode("ascii"),
                   ftype=FTYPE_FORTH)

    return fs


# ---------------------------------------------------------------------------
#  Helpers  (adapted from megapad-64/tests/test_system.py)
# ---------------------------------------------------------------------------

def make_system(ram_kib=1024, ext_mem_mib=16, disk_image=None):
    """Create a MegapadSystem, optionally attaching a disk image."""
    sys_obj = MegapadSystem(ram_size=ram_kib * 1024,
                            ext_mem_size=ext_mem_mib * (1 << 20))
    if disk_image is not None:
        # Attach disk image directly to the storage device
        sys_obj.storage._image_data = bytearray(disk_image)
        sys_obj.storage.status = 0x80  # present
    return sys_obj


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
_snapshot = None   # (mem_bytes, ext_mem_bytes, cpu_state, disk_bytes)
_bios_code = None


def _save_cpu_state(cpu):
    return {
        'regs': list(cpu.regs),
        'pc': cpu.pc,
        'acc': list(cpu.acc),
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
        'icache_enabled': getattr(cpu, 'icache_enabled', 0),
        'ef_flags': getattr(cpu, 'ef_flags', 0),
    }


def _restore_cpu_state(cpu, state):
    cpu.regs[:] = state['regs']
    cpu.pc = state.get('pc', 0)
    acc = state.get('acc', [0, 0, 0, 0])
    for i, v in enumerate(acc):
        cpu.acc[i] = v
    for k in ('psel', 'xsel', 'spsel',
              'flag_z', 'flag_c', 'flag_n', 'flag_v',
              'flag_p', 'flag_g', 'flag_i', 'flag_s',
              'd_reg', 'q_out', 't_reg',
              'ivt_base', 'ivec_id', 'trap_addr',
              'halted', 'idle', 'cycle_count', '_ext_modifier',
              'priv_level', 'mpu_base', 'mpu_limit',
              'icache_enabled', 'ef_flags'):
        setattr(cpu, k, state.get(k, 0))


def build_snapshot():
    """Build disk image -> boot KDOS -> autoexec loads bsky.f -> snapshot."""
    global _snapshot, _bios_code

    print("  Assembling BIOS ...")
    with open(BIOS_ASM) as f:
        _bios_code = assemble(f.read())
    print(f"  BIOS: {len(_bios_code)} bytes")

    # Build in-memory disk image
    print("  Building disk image ...")
    fs = build_test_disk()
    files = fs.list_files()
    total_bytes = sum(e.used_bytes for e in files)
    print(f"    {len(files)} files, {total_bytes:,} bytes on disk")
    disk_bytes = bytes(fs.img)

    # Boot with disk attached
    sys_obj = make_system(ram_kib=1024, ext_mem_mib=16, disk_image=disk_bytes)
    buf = capture_uart(sys_obj)
    sys_obj.load_binary(0, _bios_code)
    sys_obj.boot()

    # Run until KDOS reaches the interactive prompt (idle + no pending UART).
    # Full boot (KDOS + akashic libs + bsky.f) takes ~4-5 billion steps.
    max_steps = 10_000_000_000
    total = 0
    while total < max_steps:
        if sys_obj.cpu.halted:
            break
        if sys_obj.cpu.idle and not sys_obj.uart.has_rx_data:
            break
        batch = sys_obj.run_batch(min(5_000_000, max_steps - total))
        total += max(batch, 1)

    boot_text = uart_text(buf)
    print(f"  Boot steps: {total:,}")

    # Check for errors during load
    for line in boot_text.strip().split("\n")[-10:]:
        if "?" in line and "ok" not in line.lower():
            print(f"  WARNING: {line.strip()}")

    _snapshot = (bytes(sys_obj.cpu.mem), bytes(sys_obj._ext_mem),
                 _save_cpu_state(sys_obj.cpu), disk_bytes)
    print("  Snapshot ready.\n")
    return boot_text


def run_forth(lines, max_steps=50_000_000):
    """Restore from snapshot, evaluate Forth lines via UART, return output."""
    mem_bytes, ext_mem_bytes, cpu_state, disk_bytes = _snapshot

    sys_obj = make_system(ram_kib=1024, ext_mem_mib=16, disk_image=disk_bytes)
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
    using only TC calls (prompt-compatible, no S\\" needed).

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
    """Like jstr() but returns a single Forth line (for embedding)."""
    parts = ['TR']
    for ch in s:
        parts.append(f'{ord(ch)} TC')
    return ' '.join(parts)


# ---------------------------------------------------------------------------
#  Test cases
# ---------------------------------------------------------------------------

def test_stage0():
    """Test S0 Foundation Utilities."""
    print("-- Stage 0: Foundation Utilities --\n")

    # S0.1 String Builder
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

    # S0.1 Number conversion
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

    # S0.2 JSON Escaping -- JSON-COPY-ESCAPED (inline escaper)
    check("JSON-COPY-ESCAPED plain",
          [': T BSK-RESET S" hello" JSON-COPY-ESCAPED BSK-TYPE ; T'],
          "hello")

    check("JSON-COPY-ESCAPED with quote",
          ['BSK-RESET',
           'CREATE _JCE1 8 ALLOT',
           '104 _JCE1 C!  105 _JCE1 1+ C!  34 _JCE1 2 + C!  33 _JCE1 3 + C!',
           ': T _JCE1 4 JSON-COPY-ESCAPED BSK-TYPE ; T'],
          None,
          lambda out: 'hi\\"!' in out)

    # S0.3 Timestamp
    check("BSK-NOW format",
          [': T BSK-NOW TYPE ; T'],
          None,
          lambda out: any(
              "Z" in line and len([c for c in line if c in "0123456789-T:.Z"]) >= 20
              for line in out.split("\n")
          ))

    check("BSK-NOW length",
          [': T BSK-NOW NIP . ; T'],
          "20 ")

    # S0.4 URL Encoding
    check("URL-ENCODE plain",
          [': T BSK-RESET S" hello" URL-ENCODE BSK-TYPE ; T'],
          "hello")

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


def test_stage1():
    """Test S1 Minimal JSON Parser (akashic compat shims)."""
    print("-- Stage 1: JSON Parser --\n")

    # S1.1 Key finder
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

    # S1.2 Value extractors
    check("JSON-GET-STRING basic",
          jstr('"hello"') +
          [': _T TA JSON-GET-STRING TYPE ;', '_T'],
          "hello")

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

    # S1.2 Skip value
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

    # S1.3 Array iterator
    check("JSON-GET-ARRAY",
          jstr('{"items":[1,2,3]}') +
          [': _T TA S" items" JSON-GET-ARRAY JSON-GET-NUMBER . ;', '_T'],
          "1 ")

    check("JSON-NEXT-ITEM",
          jstr('1,2,3]}') +
          [': _T TA JSON-SKIP-VALUE JSON-NEXT-ITEM JSON-GET-NUMBER . ;', '_T'],
          "2 ")

    # Combined: find key in nested JSON (depth-aware: must navigate user → did)
    check("Nested key lookup",
          jstr('{"user":{"did":"plc:123","handle":"alice"},"ok":true}') +
          [': _T TA S" user" JSON-FIND-KEY S" did" JSON-FIND-KEY JSON-GET-STRING TYPE ;', '_T'],
          "plc:123")

    # /STRING
    check("/STRING basic",
          [': _T S" abcdef" 2 /STRING TYPE ;', '_T'],
          "cdef")


def test_stage2():
    """Test S2 HTTP Infrastructure (akashic compat shims)."""
    print("-- Stage 2: HTTP Infrastructure --\n")

    # S2.1 Memory Setup
    check("BSK-INIT sets READY",
          ['BSK-INIT BSK-READY @ .'],
          "-1 ")

    check("BSK-INIT idempotent",
          ['BSK-INIT BSK-RECV-BUF @ BSK-INIT BSK-RECV-BUF @ = .'],
          "-1 ")

    check("BSK-RECV-BUF non-zero after init",
          ['BSK-INIT BSK-RECV-BUF @ 0 > .'],
          "-1 ")

    check("BSK-ACCESS-LEN starts at 0",
          ['BSK-INIT BSK-ACCESS-LEN @ .'],
          "0 ")

    check("BSK-DID-LEN starts at 0",
          ['BSK-INIT BSK-DID-LEN @ .'],
          "0 ")

    check("BSK-CLEANUP clears READY",
          ['BSK-INIT BSK-CLEANUP BSK-READY @ .'],
          "0 ")

    # S2.2 -- High-level wrappers exist (compilation check)
    check("BSK-GET word exists",
          ["' BSK-GET 0> ."],
          "-1 ")

    check("BSK-POST-JSON word exists",
          ["' BSK-POST-JSON 0> ."],
          "-1 ")

    check("BSK-HTTP-STATUS word exists",
          ["' BSK-HTTP-STATUS 0> ."],
          "-1 ")

    check("BSK-LOGGED-IN? word exists",
          ["' BSK-LOGGED-IN? 0> ."],
          "-1 ")


def test_stage3():
    """Stage 3: Authentication (akashic session.f wrappers)."""
    print("Stage 3: Authentication")
    print("-" * 40)

    # S3.1 -- BSK-LOGIN / BSK-REFRESH words exist
    check("BSK-LOGIN word exists",
          ["' BSK-LOGIN 0> ."],
          "-1 ")

    check("BSK-REFRESH word exists",
          ["' BSK-REFRESH 0> ."],
          "-1 ")

    check("BSK-LOGIN-WITH word exists",
          ["' BSK-LOGIN-WITH 0> ."],
          "-1 ")

    # S3.2 -- BSK-WHO with no session
    check("BSK-WHO no session",
          ['BSK-INIT',
           ': _T BSK-WHO ; _T'],
          "Not logged in")


def test_stage4():
    """Stage 4: Read-Only Features -- timeline, profile, notifications."""
    print("Stage 4: Read-Only Features")
    print("-" * 40)

    # S4.0 -- Display helpers
    check("Type-trunc short string",
          [': _T S" hello" 10 _BSK-TYPE-TRUNC ; _T'],
          "hello")

    check("Type-trunc at limit",
          [': _T S" hello" 5 _BSK-TYPE-TRUNC ; _T'],
          "hello")

    check("Type-trunc over limit",
          [': _T S" hello world" 8 _BSK-TYPE-TRUNC ; _T'],
          "hello...")

    # S4.1 -- Timeline path builder
    check("TL path without cursor",
          ['BSK-INIT',
           ': _T _BSK-TL-PATH TYPE ; _T'],
          "/xrpc/app.bsky.feed.getTimeline?limit=10")

    check("TL path with cursor",
          ['BSK-INIT'] +
          jstr('abc123') +
          [': _T TA BSK-TL-CURSOR SWAP DUP BSK-TL-CURSOR-LEN ! CMOVE',
           '  _BSK-TL-PATH TYPE ; _T'],
          "/xrpc/app.bsky.feed.getTimeline?limit=10&cursor=abc123")

    # S4.1 -- Timeline post printer
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

    # S4.2 -- Profile path builder
    check("Profile path simple handle",
          ['BSK-INIT',
           ': _T S" alice.bsky.social" _BSK-PROFILE-PATH TYPE ; _T'],
          "/xrpc/app.bsky.actor.getProfile?actor=alice.bsky.social")

    check("Profile path DID encoding",
          ['BSK-INIT',
           ': _T S" did:plc:abc" _BSK-PROFILE-PATH TYPE ; _T'],
          "/xrpc/app.bsky.actor.getProfile?actor=did%3Aplc%3Aabc")

    # S4.2 -- Word existence checks
    check("BSK-PROFILE word exists",
          ["' BSK-PROFILE 0> ."],
          "-1 ")

    check("BSK-TL word exists",
          ["' BSK-TL 0> ."],
          "-1 ")

    check("BSK-TL-NEXT word exists",
          ["' BSK-TL-NEXT 0> ."],
          "-1 ")

    # S4.3 -- Notification printer
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


def test_stage5():
    """Stage 5: Write Features -- post, reply, like, repost."""
    print("Stage 5: Write Features")
    print("-" * 40)

    # Fake DID for testing: did:plc:test123
    did_setup = (
        jstr('did:plc:test123') +
        [': _DID-SET TA BSK-DID SWAP DUP BSK-DID-LEN ! CMOVE ;',
         '_DID-SET']
    )

    # S5.1 -- JSON builder helpers
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

    # S5.2 -- BSK-POST JSON body
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

    # S5.4 -- BSK-LIKE JSON body
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

    # S5.5 -- BSK-REPOST JSON body
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

    # S5 -- Word existence checks
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

    # S5.2 -- BSK-POST requires login
    check("BSK-POST requires login",
          ['BSK-INIT',
           ': _T S" test" BSK-POST ; _T'],
          "login first")

    # S5 -- _BSK-STAGE-BODY copies buffer
    check("_BSK-STAGE-BODY copies BSK-BUF",
          ['BSK-RESET S" hello" BSK-APPEND',
           ': _T _BSK-STAGE-BODY _BSK-POST-BUF _BSK-POST-LEN @ TYPE ; _T'],
          "hello")

    # S5.5 -- BSK-FOLLOW JSON body
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

    # S5.5 -- _BSK-DR-OPEN (deleteRecord JSON builder)
    check("_BSK-DR-OPEN builds deleteRecord JSON",
          did_setup +
          [': _T S" app.bsky.feed.post" S" 3abc123" _BSK-DR-OPEN',
           '  BSK-TYPE ; _T'],
          None,
          lambda out: ('"repo":"did:plc:test123"' in out
                      and '"collection":"app.bsky.feed.post"' in out
                      and '"rkey":"3abc123"' in out))

    # S5.6 -- URI parser
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

    # S5.6 -- BSK-DELETE end-to-end JSON
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


def test_stage6():
    """Test S6 Interactive TUI (cache data model, accessors, renderers)."""
    print("-- Stage 6: Interactive TUI --\n")

    # -- S6.1 Cache data model --

    check("TL cache init zero",
          ['_BSK-TL-N @ .'],
          "0 ")

    check("NF cache init zero",
          ['_BSK-NF-N @ .'],
          "0 ")

    check("PR cache init zero",
          ['_BSK-PR-OK @ .'],
          "0 ")

    check("Screen registered (10 total)",
          ['NSCREENS @ .'],
          "10 ")

    # -- S6.2 Cache accessors: roundtrip store/fetch --

    check("TL handle store/fetch",
          ['TR', '65 TC 108 TC 105 TC 99 TC 101 TC',
           'TA 0 _BSK-TL-H!',
           '0 _BSK-TL-HANDLE TYPE'],
          "Alice")

    check("TL text store/fetch",
          ['TR', '72 TC 101 TC 108 TC 108 TC 111 TC',
           'TA 1 _BSK-TL-T!',
           '1 _BSK-TL-TEXT TYPE'],
          "Hello")

    check("TL URI store/fetch",
          ['TR',
           '97 TC 116 TC 58 TC 47 TC 47 TC',
           '100 TC 105 TC 100 TC',
           'TA 2 _BSK-TL-U!',
           '2 _BSK-TL-URI TYPE'],
          "at://did")

    check("TL CID store/fetch",
          ['TR',
           '98 TC 97 TC 102 TC 121 TC',
           'TA 0 _BSK-TL-C!',
           '0 _BSK-TL-CID TYPE'],
          "bafy")

    check("NF reason store/fetch",
          ['TR', '108 TC 105 TC 107 TC 101 TC',
           'TA 0 _BSK-NF-R!',
           '0 _BSK-NF-REASON TYPE'],
          "like")

    check("NF handle store/fetch",
          ['TR', '98 TC 111 TC 98 TC',
           'TA 3 _BSK-NF-H!',
           '3 _BSK-NF-HANDLE TYPE'],
          "bob")

    check("TL slot isolation",
          ['TR 65 TC TA 0 _BSK-TL-H!',
           'TR 66 TC TA 1 _BSK-TL-H!',
           'TR 67 TC TA 2 _BSK-TL-H!',
           ': _TISO 0 _BSK-TL-HANDLE TYPE ." |" 1 _BSK-TL-HANDLE TYPE ." |" 2 _BSK-TL-HANDLE TYPE ; _TISO'],
          "A|B|C")

    check("TL handle truncation",
          ['TR',
           '65 TC 66 TC 67 TC 68 TC 69 TC 70 TC 71 TC 72 TC',
           '65 TC 66 TC 67 TC 68 TC 69 TC 70 TC 71 TC 72 TC',
           '65 TC 66 TC 67 TC 68 TC 69 TC 70 TC 71 TC 72 TC',
           '65 TC 66 TC 67 TC 68 TC 69 TC 70 TC 71 TC 72 TC',
           '65 TC 66 TC 67 TC 68 TC',
           'TA 4 _BSK-TL-H!',
           '4 _BSK-TL-HANDLE DUP .'],
          "32 ")

    # -- S6.2 Status message --

    check("Set/get status",
          ['TR 79 TC 75 TC',
           'TA _BSK-SET-STATUS',
           '_BSK-STATUS _BSK-STATUS-LEN @ TYPE'],
          "OK")

    check("Clear status",
          ['TR 79 TC 75 TC TA _BSK-SET-STATUS',
           '_BSK-CLR-STATUS',
           '_BSK-STATUS-LEN @ .'],
          "0 ")

    # -- S6.3 Cache item parser --

    check("TL cache item parse",
          jstr('{"post":{"uri":"at://did:plc:test/app.bsky.feed.post/abc","cid":"bafytest","author":{"handle":"alice.test"},"record":{"text":"Hello world"}}}') +
          ['TA 0 _BSK-TL-CACHE-ITEM',
           ': _TCIP 0 _BSK-TL-HANDLE TYPE ." |" 0 _BSK-TL-TEXT TYPE ." |" 0 _BSK-TL-URI TYPE ." |" 0 _BSK-TL-CID TYPE ; _TCIP'],
          None,
          lambda out: 'alice.test|Hello world|at://did:plc:test/app.bsky.feed.post/abc|bafytest' in out)

    check("NF cache item parse",
          jstr('{"reason":"follow","author":{"handle":"bob.bsky.social"}}') +
          ['TA 0 _BSK-NF-CACHE-ITEM',
           ': _TNIP 0 _BSK-NF-REASON TYPE ." |" 0 _BSK-NF-HANDLE TYPE ; _TNIP'],
          None,
          lambda out: 'follow|bob.bsky.social' in out)

    # -- S6.4 Row renderers --

    check("TL row renderer",
          jstr('{"post":{"uri":"at://x","cid":"c","author":{"handle":"alice.test"},"record":{"text":"My first post"}}}') +
          ['TA 0 _BSK-TL-CACHE-ITEM',
           '1 _BSK-TL-N !',
           '0 .BSK-TL-ROW'],
          None,
          lambda out: '@alice.test' in out and 'My first post' in out)

    check("NF row renderer",
          jstr('{"reason":"like","author":{"handle":"charlie.bsky.social"}}') +
          ['TA 0 _BSK-NF-CACHE-ITEM',
           '1 _BSK-NF-N !',
           '0 .BSK-NF-ROW'],
          None,
          lambda out: 'like' in out and '@charlie.bsky.social' in out)

    # -- S6.5 Screen renderers --

    check("TL screen empty",
          ['0 _BSK-TL-N !',
           'SCR-BSKY-TL'],
          None,
          lambda out: 'Timeline' in out and 'fetch' in out.lower())

    check("TL screen with data",
          jstr('{"post":{"uri":"at://x","cid":"c","author":{"handle":"alice.test"},"record":{"text":"Test post"}}}') +
          ['TA 0 _BSK-TL-CACHE-ITEM',
           '1 _BSK-TL-N !',
           '0 SCR-SEL !',
           'SCR-BSKY-TL'],
          None,
          lambda out: 'Timeline' in out and '@alice.test' in out)

    check("NF screen empty",
          ['0 _BSK-NF-N !',
           'SCR-BSKY-NF'],
          None,
          lambda out: 'Notifications' in out and 'fetch' in out.lower())

    check("PR screen empty",
          ['0 _BSK-PR-OK !',
           'SCR-BSKY-PR'],
          None,
          lambda out: 'Profile' in out and 'fetch' in out.lower())

    # -- S6.6 Key handler --

    check("Unknown key not consumed",
          ['0 SUBSCREEN-ID !',
           ': TKX  120 BSKY-KEYS . ; TKX'],
          "0 ")

    check("Key l not consumed on notifs sub",
          ['1 SUBSCREEN-ID !',
           ': TKL2  108 BSKY-KEYS . ; TKL2'],
          "0 ")

    # -- S6.7 Registration --

    check("Bsky screen selectable",
          ['_BSK-SCR-ID @ CELLS SCR-FLAGS + @ .'],
          "1 ")

    check("Bsky has 4 subscreens",
          ['_BSK-SCR-ID @ CELLS SUB-COUNTS + @ .'],
          "4 ")


# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------

def main():
    global _pass, _fail, _errors

    print("=" * 60)
    print("  bsky.f Test Suite")
    print("=" * 60)
    print()

    print("Building snapshot (disk image -> KDOS -> bsky.f) ...")
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
    test_stage6()

    print()
    print("=" * 60)
    print(f"  Results: {_pass} passed, {_fail} failed")
    if _errors:
        print(f"  Failures: {', '.join(_errors)}")
    print("=" * 60)

    return 0 if _fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
