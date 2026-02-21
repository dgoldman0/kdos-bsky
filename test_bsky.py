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
_snapshot = None   # (mem_bytes, cpu_state)
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

    all_lines = kdos_lines + bsky_lines + test_helpers
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

    _snapshot = (bytes(sys_obj.cpu.mem), _save_cpu_state(sys_obj.cpu))
    print("  Snapshot ready.\n")
    return boot_text


def run_forth(lines, max_steps=50_000_000):
    """Restore from snapshot, evaluate Forth lines, return UART text."""
    mem_bytes, cpu_state = _snapshot

    sys_obj = make_system(ram_kib=1024, ext_mem_mib=16)
    buf = capture_uart(sys_obj)
    sys_obj.cpu.mem[:len(mem_bytes)] = mem_bytes
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
    print("=" * 60)
    print(f"  Results: {_pass} passed, {_fail} failed")
    if _errors:
        print(f"  Failures: {', '.join(_errors)}")
    print("=" * 60)

    return 0 if _fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
