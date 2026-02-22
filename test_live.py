#!/usr/bin/env python3
"""Live internet test for bsky.f via TAP interface.

Prerequisites (one-time host setup):
    sudo ip tuntap add dev mp64tap0 mode tap user $USER
    sudo ip link set mp64tap0 up
    sudo ip addr add 10.64.0.1/24 dev mp64tap0
    sudo sysctl net.ipv4.ip_forward=1
    sudo iptables -t nat -A POSTROUTING -s 10.64.0.0/24 -j MASQUERADE

Usage:
    cd bsky/ && emu/.venv/bin/python test_live.py
"""

import os
import sys
import struct
import time

EMU_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "emu")
sys.path.insert(0, EMU_DIR)

from accel_wrapper import Megapad64, HaltError
from system import MegapadSystem
from devices import UART
from asm import assemble
from nic_backends import TAPBackend

# ---------------------------------------------------------------------------
#  Paths
# ---------------------------------------------------------------------------
BIOS_ASM = os.path.join(EMU_DIR, "bios.asm")
KDOS_F   = os.path.join(EMU_DIR, "kdos.f")
TOOLS_F  = os.path.join(EMU_DIR, "tools.f")
BSKY_F   = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bsky.f")
CONFIG_F = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.f")

# ---------------------------------------------------------------------------
#  Packet logger
# ---------------------------------------------------------------------------
PKT_LOG = []  # list of (direction, summary_str)

def _fmt_ip(b, off):
    return f"{b[off]}.{b[off+1]}.{b[off+2]}.{b[off+3]}"

def _pkt_summary(data, direction):
    """Parse an Ethernet frame and return a one-line summary."""
    if len(data) < 14:
        return f"{direction} {len(data)}B (runt)"
    ethertype = struct.unpack("!H", data[12:14])[0]
    if ethertype == 0x0806:  # ARP
        return f"{direction} ARP {len(data)}B"
    if ethertype != 0x0800:
        return f"{direction} ether=0x{ethertype:04X} {len(data)}B"
    if len(data) < 34:
        return f"{direction} IPv4 (short) {len(data)}B"
    ip = data[14:]
    proto = ip[9]
    src = _fmt_ip(ip, 12)
    dst = _fmt_ip(ip, 16)
    if proto == 6 and len(ip) >= 24:  # TCP
        ihl = (ip[0] & 0xF) * 4
        sp = struct.unpack("!H", ip[ihl:ihl+2])[0]
        dp = struct.unpack("!H", ip[ihl+2:ihl+4])[0]
        flags = ip[ihl+13] if len(ip) > ihl+13 else 0
        flag_str = ""
        if flags & 0x02: flag_str += "S"
        if flags & 0x10: flag_str += "A"
        if flags & 0x08: flag_str += "P"
        if flags & 0x01: flag_str += "F"
        if flags & 0x04: flag_str += "R"
        tcp_hdr_len = ((ip[ihl+12] >> 4) * 4) if len(ip) > ihl+12 else 20
        payload = len(ip) - ihl - tcp_hdr_len
        return f"{direction} TCP {src}:{sp}->{dst}:{dp} [{flag_str}] {payload}B"
    if proto == 17:  # UDP
        sp = struct.unpack("!H", ip[20:22])[0]
        dp = struct.unpack("!H", ip[22:24])[0]
        return f"{direction} UDP {src}:{sp}->{dst}:{dp} {len(ip)-28}B"
    if proto == 1:  # ICMP
        return f"{direction} ICMP {src}->{dst} {len(ip)-20}B"
    return f"{direction} IP proto={proto} {src}->{dst} {len(ip)}B"

def install_pkt_logger(tap):
    """Monkey-patch the TAP backend to log packets."""
    orig_send = tap.send
    orig_on_rx = tap.on_rx_frame

    def logged_send(frame):
        PKT_LOG.append(("TX", _pkt_summary(frame, "TX")))
        return orig_send(frame)

    def logged_rx(frame):
        PKT_LOG.append(("RX", _pkt_summary(frame, "RX")))
        if orig_on_rx:
            return orig_on_rx(frame)

    tap.send = logged_send
    tap.on_rx_frame = logged_rx

# ---------------------------------------------------------------------------
#  Helpers
# ---------------------------------------------------------------------------

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


def feed_lines(sys_obj, buf, lines, max_steps=500_000_000):
    """Feed Forth lines into the UART and run until idle (no network wait)."""
    payload = "\n".join(lines) + "\n"
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
        batch = sys_obj.run_batch(min(200_000, max_steps - steps))
        steps += max(batch, 1)

    return steps


def run_net_command(sys_obj, buf, lines, timeout_sec=30, sentinel=None):
    """Feed lines then keep running with real-time sleeps for network I/O.

    Unlike feed_lines(), this continues running even when idle — the CPU
    goes idle waiting for network events (ARP replies, TCP segments, TLS
    records).  We use wall-clock time and poll the NIC backend in between.

    If sentinel is set, returns early when that string appears in UART output.
    """
    payload = "\n".join(lines) + "\n"
    data = payload.encode()
    pos = 0
    steps = 0
    start = time.time()
    all_fed = False
    max_steps = 5_000_000_000

    while steps < max_steps:
        elapsed = time.time() - start
        if elapsed > timeout_sec:
            break
        if sys_obj.cpu.halted:
            break

        # Check sentinel
        if sentinel and sentinel in uart_text(buf):
            # Run a bit more to let output finish
            for _ in range(50):
                sys_obj.run_batch(100_000)
                steps += 100_000
                time.sleep(0.001)
            break

        if sys_obj.cpu.idle and not sys_obj.uart.has_rx_data:
            if not all_fed and pos < len(data):
                chunk = _next_line_chunk(data, pos)
                sys_obj.uart.inject_input(chunk)
                pos += len(chunk)
            else:
                all_fed = True
                # CPU is idle waiting for network — sleep briefly to
                # let the TAP backend thread deliver frames, then
                # force-wake the CPU so NET-IDLE polling loops advance
                # even when no frame arrived (the loop is a timeout,
                # not a blocking wait)
                time.sleep(0.005)
                sys_obj.cpu.idle = False
                batch = sys_obj.run_batch(50_000)
                steps += max(batch, 1)
            continue

        batch = sys_obj.run_batch(min(500_000, max_steps - steps))
        steps += max(batch, 1)

    return steps


# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------

def main():
    print("=" * 60)
    print("  bsky.f Live Internet Test (TAP)")
    print("=" * 60)
    print()

    # Check TAP device exists
    if not os.path.exists("/sys/class/net/mp64tap0"):
        print("ERROR: TAP device mp64tap0 not found.")
        print("Create it with:")
        print("  sudo ip tuntap add dev mp64tap0 mode tap user $USER")
        print("  sudo ip link set mp64tap0 up")
        print("  sudo ip addr add 10.64.0.1/24 dev mp64tap0")
        return 1

    # 1. Assemble BIOS
    print("Assembling BIOS ...")
    with open(BIOS_ASM) as f:
        bios_code = assemble(f.read())
    print(f"  BIOS: {len(bios_code)} bytes")

    # 2. Read source files
    def read_forth(path, label):
        with open(path) as f:
            lines = [line for line in f.read().splitlines()
                     if line.strip() and not line.strip().startswith('\\')]
        print(f"  {label}: {len(lines)} lines")
        return lines

    kdos_lines = read_forth(KDOS_F, "KDOS")
    tools_lines = read_forth(TOOLS_F, "tools.f")
    bsky_lines = read_forth(BSKY_F, "bsky.f")

    # Network setup — replicates AUTOEXEC-NET static fallback
    autoexec_lines = [
        '10 64 0 2 IP-SET',
        '10 GW-IP C! 64 GW-IP 1+ C! 0 GW-IP 2 + C! 1 GW-IP 3 + C!',
        '255 NET-MASK C! 255 NET-MASK 1+ C! 255 NET-MASK 2 + C! 0 NET-MASK 3 + C!',
        '8 DNS-SERVER-IP C! 8 DNS-SERVER-IP 1+ C! 8 DNS-SERVER-IP 2 + C! 8 DNS-SERVER-IP 3 + C!',
    ]

    # Read config.f if it exists (credentials for login test)
    config_lines = []
    has_config = os.path.exists(CONFIG_F)
    if has_config:
        with open(CONFIG_F) as f:
            config_lines = [line for line in f.read().splitlines()
                           if line.strip() and not line.strip().startswith('\\')]
        print(f"  config.f: {len(config_lines)} lines")
    else:
        print("  config.f: not found (login test will be skipped)")

    # 3. Create system with TAP backend
    print("\nCreating system with TAP backend ...")
    tap = TAPBackend("mp64tap0")
    sys_obj = MegapadSystem(
        ram_size=1024 * 1024,
        ext_mem_size=16 * (1 << 20),
        nic_backend=tap,
    )
    install_pkt_logger(tap)
    buf = capture_uart(sys_obj)
    sys_obj.load_binary(0, bios_code)
    sys_obj.boot()

    # 4. Load KDOS + tools.f, enter userland, then bsky.f + config.f + network config
    print("Loading KDOS + tools.f + bsky.f (userland) ...")
    all_lines = kdos_lines + tools_lines + ['ENTER-USERLAND'] + bsky_lines + config_lines + autoexec_lines
    steps = feed_lines(sys_obj, buf, all_lines)
    boot_text = uart_text(buf)
    print(f"  Boot: {steps:,} steps")

    # Check for load errors related to our code
    if "_HTTP-FIND-HEND ?" in boot_text or "_HTTP-HEND ?" in boot_text:
        print("  ERROR: tools.f words not found — load order problem")
        tap.stop()
        return 1

    # Show network config
    buf.clear()
    feed_lines(sys_obj, buf, [
        '." IP: " MY-IP .IP CR',
        '." GW: " GW-IP .IP CR',
        '." Mask: " NET-MASK .IP CR',
        '." DNS: " DNS-SERVER-IP .IP CR',
    ])
    net_text = uart_text(buf)
    for line in net_text.strip().split("\n"):
        line = line.strip()
        if line and not line.startswith('>') and line != 'ok':
            print(f"    {line}")

    # 5. Connectivity check — ping gateway
    print("\n--- Ping gateway (10.64.0.1) ---")
    buf.clear()
    steps = run_net_command(sys_obj, buf, ['10 64 0 1 1 PING-IP'],
                           timeout_sec=15, sentinel="received")
    ping_text = uart_text(buf)
    for line in ping_text.strip().split("\n"):
        line = line.strip()
        if line and not line.startswith('>') and line != 'ok':
            print(f"    {line}")

    ping_ok = "1 received" in ping_text
    if not ping_ok:
        print("  WARNING: Ping failed — ARP or routing issue")
        print("  Continuing anyway...")

    # 6. DNS test — skipped (done implicitly by BSK-GET) 
    dns_ok = True

    # 7. BSK-GET describeServer — full XRPC round-trip
    print("\n--- BSK-GET describeServer ---")
    buf.clear()
    test_def = [
        'BSK-INIT',
        ': _LIVETEST',
        '  S" /xrpc/com.atproto.server.describeServer" BSK-GET',
        '  ." [BLEN] " DUP . CR',
        '  ." [BADDR] " OVER . CR',
        '  ." [STATUS] " BSK-HTTP-STATUS @ . CR',
        '  DUP 0> IF',
        '    DUP 200 MIN TYPE CR',
        '  ELSE',
        '    ." [EMPTY]" CR 2DROP',
        '  THEN',
        '  ." ##DONE##" CR ;',
    ]
    feed_lines(sys_obj, buf, test_def)
    buf.clear()
    print("  Calling describeServer via BSK-GET ...")
    steps = run_net_command(sys_obj, buf, ['_LIVETEST'],
                           timeout_sec=120, sentinel="##DONE")
    result_text = uart_text(buf)

    print(f"  Completed in {steps:,} steps")
    print()

    # Parse and display results
    for line in result_text.strip().split("\n"):
        line = line.strip()
        if not line or line == 'ok' or line.startswith('>'):
            continue
        if len(line) > 120:
            print(f"  {line[:120]}...")
        else:
            print(f"  {line}")

    # Check for success
    success = False
    if "[BLEN]" in result_text and "[STATUS] 200" in result_text:
        print("\n  *** SUCCESS: Got valid response from bsky.social! ***")
        success = True
    elif "[BLEN]" in result_text:
        print("\n  *** PARTIAL: Got response but unexpected status ***")
    elif "[FAIL]" in result_text:
        print("\n  *** FAILED: No response received ***")
    elif "TLS connect failed" in result_text:
        print("\n  *** FAILED: TLS handshake failed ***")
    elif "DNS failed" in result_text:
        print("\n  *** FAILED: DNS resolution failed ***")
    else:
        print("\n  *** UNKNOWN: Check output above ***")

    # 8. BSK-LOGIN — live authentication (only if config.f has real creds)
    login_success = None  # None = skipped
    if has_config:
        # Check if config.f still has placeholder values
        config_text = open(CONFIG_F).read()
        if "yourhandle" in config_text or "xxxx-xxxx" in config_text:
            print("\n--- BSK-LOGIN (skipped: config.f has placeholder values) ---")
            print("  Edit config.f with your handle and app password to enable")
        else:
            print("\n--- BSK-LOGIN ---")
            buf.clear()
            login_def = [
                ': _LOGINTEST',
                '  BSK-MY-HANDLE BSK-MY-PASS BSK-LOGIN-WITH',
                '  BSK-WHO',
                '  ." ##LOGIN-DONE##" CR ;',
            ]
            feed_lines(sys_obj, buf, login_def)
            buf.clear()
            print("  Logging in via BSK-LOGIN-WITH ...")
            steps = run_net_command(sys_obj, buf, ['_LOGINTEST'],
                                   timeout_sec=120, sentinel="##LOGIN-DONE")
            login_text = uart_text(buf)
            print(f"  Completed in {steps:,} steps")
            print()
            for line in login_text.strip().split("\n"):
                line = line.strip()
                if not line or line == 'ok' or line.startswith('>'):
                    continue
                if len(line) > 120:
                    print(f"  {line[:120]}...")
                else:
                    print(f"  {line}")

            if "Logged in as" in login_text:
                print("\n  *** SUCCESS: BSK-LOGIN authenticated! ***")
                login_success = True
            else:
                print("\n  *** FAILED: BSK-LOGIN did not authenticate ***")
                login_success = False
    else:
        print("\n--- BSK-LOGIN (skipped: no config.f) ---")

    # ── Stage 4 live tests (require login) ──────────────────────
    # Strategy: Use raw BSK-GET to fetch each endpoint, dump the raw
    # body to UART as hex so we can inspect the actual data in
    # live_results.txt.  Also test the high-level display words.

    stage4_results = {}  # name -> output text

    if login_success:
        # 9. BSK-GET — test all three authenticated endpoints in one word
        # (KDOS has limited TCP socket pool; consolidating minimizes
        #  connection count)
        print("\n--- Stage 4: Authenticated BSK-GET tests ---")
        buf.clear()
        feed_lines(sys_obj, buf, [
            ': _STAGE4-GET',
            '  S" /xrpc/app.bsky.feed.getTimeline?limit=3" BSK-GET',
            '  DUP 0> IF',
            '    ." [TL-OK] len=" DUP . ." status=" BSK-HTTP-STATUS @ . CR',
            '    2DROP',
            '  ELSE ." [TL-FAIL] " . CR THEN',
            '  S" /xrpc/app.bsky.notification.listNotifications?limit=3" BSK-GET',
            '  DUP 0> IF',
            '    ." [NOTIF-OK] len=" DUP . ." status=" BSK-HTTP-STATUS @ . CR',
            '    2DROP',
            '  ELSE ." [NOTIF-FAIL] " . CR THEN',
            '  ." ##S4GET-DONE##" CR ;',
        ])
        buf.clear()
        print("  Fetching notifications + timeline ...")
        steps = run_net_command(sys_obj, buf, ['_STAGE4-GET'],
                               timeout_sec=120, sentinel="##S4GET-DONE")
        s4_text = uart_text(buf)
        stage4_results['BSK-GET-tests'] = s4_text
        print(f"  Completed in {steps:,} steps")
        for line in s4_text.strip().split("\n"):
            line = line.strip()
            if not line or line == 'ok' or line.startswith('>'):
                continue
            print(f"  {line[:160]}")

        # 10. BSK-PROFILE display word
        print("\n--- BSK-PROFILE ---")
        buf.clear()
        feed_lines(sys_obj, buf, [
            ': _PROFTEST BSK-HANDLE BSK-HANDLE-LEN @ _BSK-PROFILE-WITH',
            '  ." ##PROF-DONE##" CR ;',
        ])
        buf.clear()
        print("  Running BSK-PROFILE ...")
        steps = run_net_command(sys_obj, buf, ['_PROFTEST'],
                               timeout_sec=120, sentinel="##PROF-DONE")
        prof_text = uart_text(buf)
        stage4_results['BSK-PROFILE'] = prof_text
        print(f"  Completed in {steps:,} steps")
        for line in prof_text.strip().split("\n"):
            line = line.strip()
            if not line or line == 'ok' or line.startswith('>'):
                continue
            print(f"  {line[:160]}")

        # ── Stage 5 live test: Post + Delete ─────────────────────────
        print("\n--- Stage 5: Post + Delete (round-trip test) ---")
        buf.clear()
        import datetime
        ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
        test_msg = f"megapad-64 test [{ts}] (auto-delete)"
        # Use low-level words so we can capture the URI from createRecord
        # response, then feed it to BSK-DELETE.
        feed_lines(sys_obj, buf, [
            'CREATE _CR-URI 256 ALLOT  VARIABLE _CR-ULEN',
            ': _POSTDEL-TEST',
            # Build the post JSON
            f'  S" app.bsky.feed.post" _BSK-CR-OPEN',
            f'  S" text" _BSK-QK',
            f'  S" {test_msg}" _BSK-QV-ESC',
            f'  _BSK-COMMA _BSK-CREATED-AT _BSK-CR-CLOSE',
            # Stage body and POST
            f'  _BSK-STAGE-BODY',
            f'  S" /xrpc/com.atproto.repo.createRecord"',
            f'  _BSK-POST-BUF _BSK-POST-LEN @',
            f'  BSK-POST-JSON',
            # Check response
            f'  DUP 0= IF 2DROP ." [POST-FAIL-NET]" CR ." ##PDONE##" CR EXIT THEN',
            f'  ." [POST-STATUS] " BSK-HTTP-STATUS @ . CR',
            f'  BSK-HTTP-STATUS @ 200 <> IF 2DROP ." [POST-FAIL-HTTP]" CR ." ##PDONE##" CR EXIT THEN',
            # Response body is on stack ( addr len ) — extract URI
            f'  2DUP S" uri" JSON-FIND-KEY',
            f'  DUP 0> IF',
            f'    JSON-GET-STRING DUP 0> IF',
            # ( str-addr str-len ) — save str-addr, compute clamped len
            f'      256 MIN DUP _CR-ULEN !',
            # ( str-addr clamped-len )
            f'      _CR-URI SWAP CMOVE',
            f'      ." [POST-URI] " _CR-URI _CR-ULEN @ TYPE CR',
            f'    ELSE 2DROP ." [GS-EMPTY]" CR THEN',
            f'  ELSE 2DROP ." [POST-NO-URI]" CR THEN',
            f'  2DROP',
            # Now delete the post using the captured URI
            f'  _CR-ULEN @ 0= IF ." [DEL-SKIP]" CR ." ##PDONE##" CR EXIT THEN',
            f'  ." Deleting..." CR',
            f'  _CR-URI _CR-ULEN @ BSK-DELETE',
            f'  ." [DEL-STATUS] " BSK-HTTP-STATUS @ . CR',
            f'  ." ##PDONE##" CR ;',
        ])
        buf.clear()
        print(f'  Posting: "{test_msg}"')
        print(f'  Then immediately deleting it...')
        steps = run_net_command(sys_obj, buf, ['_POSTDEL-TEST'],
                               timeout_sec=180, sentinel="##PDONE")
        pd_text = uart_text(buf)
        stage4_results['POST+DELETE'] = pd_text
        print(f"  Completed in {steps:,} steps")
        for line in pd_text.strip().split("\n"):
            line = line.strip()
            if not line or line == 'ok' or line.startswith('>'):
                continue
            print(f"  {line[:160]}")

        if "Deleted!" in pd_text:
            print("\n  *** SUCCESS: Post created and deleted! ***")
        elif "[POST-URI]" in pd_text:
            print("\n  *** PARTIAL: Posted but delete may have failed ***")
        else:
            print("\n  *** FAILED: Post+Delete did not succeed ***")

    else:
        print("\n--- Stage 4+5 live tests SKIPPED (login required) ---")

    # Write stage 4 results to file for manual inspection
    if stage4_results:
        results_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "live_results.txt")
        with open(results_path, 'w') as f:
            for name, text in stage4_results.items():
                f.write(f"{'=' * 60}\n")
                f.write(f"  {name}\n")
                f.write(f"{'=' * 60}\n")
                for line in text.strip().split("\n"):
                    line = line.strip()
                    if not line or line == 'ok' or line.startswith('>'):
                        continue
                    f.write(f"  {line}\n")
                f.write("\n")
        print(f"\n  Stage 4 results written to live_results.txt")

    # Dump packet log
    print("\n--- Packet Log (last 60) ---")
    for _, summary in PKT_LOG[-60:]:
        print(f"    {summary}")
    print(f"    Total: {len(PKT_LOG)} packets")

    tap.stop()
    # Fail if describeServer failed, or if login was attempted and failed
    if not success:
        return 1
    if login_success is False:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
