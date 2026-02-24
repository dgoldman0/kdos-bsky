#!/usr/bin/env bash
# boot.sh — Boot KDOS with Bluesky TUI disk image
#
# Prerequisites:
#   1. TAP device for networking (run once as root):
#        sudo ip tuntap add dev mp64tap0 mode tap user $USER
#        sudo ip link set mp64tap0 up
#        sudo ip addr add 10.64.0.1/24 dev mp64tap0
#        sudo sysctl -w net.ipv4.ip_forward=1
#        sudo iptables -t nat -A POSTROUTING -s 10.64.0.1/24 ! -o mp64tap0 -j MASQUERADE
#
#   2. Build the disk image:
#        python local_testing/build_disk.py
#
# Usage:
#   ./boot.sh              # interactive console
#   ./boot.sh --headless   # headless TCP server (connect via nc localhost 6464)

set -e
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR/emu"

# The C++ accelerator is built for Python 3.13 — use it directly.
# (The project .venv is 3.12 and can't load the .so)
PYTHON="${PYTHON:-python3.13}"

# Build disk image if it doesn't exist
if [ ! -f bsky-disk.img ]; then
    echo "Building disk image..."
    $PYTHON "$PROJECT_DIR/local_testing/build_disk.py"
fi

echo "=========================================="
echo "  Megapad-64 / KDOS + Bluesky TUI"
echo "=========================================="
echo ""
echo "Boot sequence:"
echo "  1. BIOS loads kdos.f from disk (first file)"
echo "  2. KDOS runs autoexec.f → tools.f → bsky.f → config.f"
echo "  3. BSK-LOGIN → SCREENS TUI"
echo ""
echo "Topology: 1 full core + 1 micro-core cluster (4 MCUs)"
echo ""
echo "Controls:"
echo "  [f]     → fetch / refresh"
echo "  [n/p]   → next / prev item"
echo "  []/[]   → next / prev subscreen"
echo "  [l]     → like    [t] → repost"
echo "  [y]     → reply   [c] → compose"
echo "  [d]     → delete  [q] → quit"
echo "  Ctrl+]  → drop to debug monitor"
echo "  Ctrl+C  → exit"
echo ""

exec $PYTHON cli.py \
    --bios bios.asm \
    --storage bsky-disk.img \
    --nic-tap mp64tap0 \
    --cores 1 \
    --clusters 1 \
    "$@"
