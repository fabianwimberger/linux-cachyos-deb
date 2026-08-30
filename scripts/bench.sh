#!/usr/bin/env bash
# Run the benchmark suite against a target and write profiles/bench-<label>.txt.
#
#   scripts/bench.sh <ssh-host> [label]
#
# <label> defaults to the target's `uname -r`. Run this against the same host
# before and after a kernel switch to get a comparable pair of files.
#
# Metrics mirror the VM benchmark table in README.md (sysbench cpu/memory/
# threads, fio tmpfs, fio disk) plus the crypto/GPU/network checks this
# repo's profiling work already found useful. Real hardware has its own
# ceiling (SSD/NIC throughput) the kernel can't push past the way a VM's
# virtio-backed disk/network can't, so a flat metric here reads as
# "hardware-bound", not "no difference" -- see the README's own caveat about
# VM-relative vs absolute numbers, and don't expect the VM table's deltas to
# reproduce on real hardware.
. "$(dirname "$0")/lib.sh"

TARGET=${1:-}
[ -n "$TARGET" ] || die "usage: scripts/bench.sh <ssh-host> [label]"

# Host-key checking off, and never touching the real known_hosts: a
# profiling/benchmark target's key legitimately changes whenever its kernel
# or OS gets reinstalled, which is routine for this kind of target, not a
# MITM signal.
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=6
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
run() { ssh "${SSH_OPTS[@]}" "$TARGET" "$1"; }

KRELEASE_REMOTE=$(run 'uname -r') || die "could not reach $TARGET"
LABEL=${2:-$KRELEASE_REMOTE}
mkdir -p "$ROOT/profiles"
OUT="$ROOT/profiles/bench-$LABEL.txt"

say "benchmarking $TARGET ($KRELEASE_REMOTE) -> $OUT"

result=$(run '
have() { command -v "$1" >/dev/null 2>&1; }

echo "=== openssl sha256 ==="
have openssl && openssl speed -seconds 10 sha256 2>&1 | tail -2

echo "=== openssl aes-256-cbc ==="
have openssl && openssl speed -seconds 10 aes-256-cbc 2>&1 | tail -2

echo "=== sysbench cpu ==="
have sysbench && sysbench cpu --threads="$(nproc)" --time=20 run 2>&1 | tail -6

echo "=== sysbench memory ==="
have sysbench && sysbench memory --threads=8 --time=20 run 2>&1 | tail -8

echo "=== sysbench threads ==="
have sysbench && sysbench threads --threads=64 --time=20 run 2>&1 | tail -6

echo "=== fio tmpfs randread ==="
if have fio; then
    tmp=$(mktemp -d -p /dev/shm)
    (cd "$tmp" && fio --name=b --size=512m --bs=4k --rw=randread --ioengine=libaio --direct=0 --iodepth=32 --time_based --runtime=15 --group_reporting 2>&1 | grep -E "IOPS|bw =")
    echo "=== fio tmpfs randwrite ==="
    (cd "$tmp" && fio --name=b --size=512m --bs=4k --rw=randwrite --ioengine=libaio --direct=0 --iodepth=32 --time_based --runtime=15 --group_reporting 2>&1 | grep -E "IOPS|bw =")
    rm -rf "$tmp"
fi

echo "=== fio disk randread ==="
if have fio; then
    (cd "$HOME" && fio --name=b --size=1g --bs=4k --rw=randread --ioengine=libaio --direct=1 --iodepth=32 --time_based --runtime=20 --group_reporting 2>&1 | grep -E "IOPS|bw =")
    echo "=== fio disk seqread ==="
    (cd "$HOME" && fio --name=b --size=2g --bs=1m --rw=read --ioengine=libaio --direct=1 --time_based --runtime=20 --group_reporting 2>&1 | grep -E "IOPS|bw =")
    rm -f "$HOME"/b.*.0 2>/dev/null
fi

echo "=== ffmpeg vaapi h264 1080p encode ==="
if have ffmpeg && [ -e /dev/dri/renderD128 ]; then
    src=/tmp/bench-src.y4m
    ffmpeg -hide_banner -f lavfi -i testsrc2=size=1920x1080:rate=30:duration=10 -pix_fmt yuv420p "$src" >/dev/null 2>&1
    ffmpeg -hide_banner -vaapi_device /dev/dri/renderD128 -i "$src" -vf "format=nv12,hwupload" -c:v h264_vaapi -b:v 8M /tmp/bench-out.mp4 2>&1 | grep -oE "speed=[0-9.]+x" | tail -1
    rm -f "$src" /tmp/bench-out.mp4
fi

echo "=== iperf3 loopback (4 streams, 10s) ==="
if have iperf3; then
    iperf3 -s -D -p 5201 >/dev/null 2>&1
    sleep 1
    iperf3 -c 127.0.0.1 -p 5201 -t 10 -P 4 2>&1 | tail -4
    pkill -f "iperf3 -s" 2>/dev/null || true
fi
') || true

# The SSH session can drop for a beat right as the command finishes -- ssh
# then exits non-zero even though the full output already made it through.
# Trust the captured text over ssh's exit code, and
# only bail if it actually looks truncated. Check the last *header*, not
# iperf3's own output -- iperf3 may legitimately be absent on the target,
# in which case that section prints nothing but the header still runs.
case "$result" in
*"=== iperf3 loopback"*) ;;
*) die "remote output looks incomplete, not writing $OUT (retry the run)" ;;
esac

{
    printf 'Benchmark — %s (%s)\n' "$TARGET" "$KRELEASE_REMOTE"
    printf 'Collected: %s\n\n' "$(date -u +'%Y-%m-%d %H:%M UTC')"
    printf '%s\n' "$result"
} > "$OUT"

say "wrote $OUT"
