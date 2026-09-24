#!/usr/bin/env bash
# Benchmark the kernel a target is running, or compare two such runs.
#
#   scripts/bench.sh <ssh-host> [label] [runs]   -> profiles/bench-<label>.txt
#   scripts/bench.sh compare <a.txt> <b.txt>     -> b relative to a
#
# <label> defaults to the target's `uname -r`, <runs> to 3 (each metric reports
# its median). Run it on the same host under each kernel, then compare. The
# metrics are in scripts/bench-remote.sh; they are mostly kernel-bound, plus a
# pure-userspace control group that should not move between kernels and so
# shows the noise floor. Real hardware has its own ceilings (SSD, NIC), so a
# flat disk metric reads as hardware-bound rather than as no difference.
. "$(dirname "$0")/lib.sh"

if [ "${1:-}" = compare ]; then
    [ -f "${2:-}" ] && [ -f "${3:-}" ] || die "usage: scripts/bench.sh compare <a.txt> <b.txt>"
    python3 - "$2" "$3" <<'PY'
import sys

def load(path):
    meta, rows = [], {}
    for line in open(path):
        line = line.rstrip("\n")
        if line.startswith("# "):
            meta.append(line[2:])
        elif line.strip():
            name, value, unit, direction = line.split()
            rows[name] = (float(value), unit, direction)
    return meta, rows

(ma, a), (mb, b) = load(sys.argv[1]), load(sys.argv[2])
ka = next((m.split(" ", 1)[1] for m in ma if m.startswith("kernel ")), "a")
kb = next((m.split(" ", 1)[1] for m in mb if m.startswith("kernel ")), "b")
for m in ma:
    if m.startswith(("governor", "cpu ")):
        print(f"{ka}: {m}")
for m in mb:
    if m.startswith("governor"):
        print(f"{kb}: {m}")
print()
w = max(len(n) for n in a) + 2
print(f"{'metric':<{w}}{ka:>22}{kb:>22}   change (+ is better)")
for name, (va, unit, direction) in a.items():
    if name not in b:
        continue
    vb = b[name][0]
    better = (vb - va) / va * 100 if direction == "higher" else (va - vb) / va * 100
    print(f"{name:<{w}}{va:>22.6g}{vb:>22.6g}   {better:+6.1f}%  {unit}")
PY
    exit
fi

TARGET=${1:-}
[ -n "$TARGET" ] || die "usage: scripts/bench.sh <ssh-host> [label] [runs]"
RUNS=${3:-3}

# Host-key checking off, and never touching the real known_hosts: a
# benchmark target's key legitimately changes whenever its kernel or OS gets
# reinstalled, which is routine for this kind of target, not a MITM signal.
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=6
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
run() { ssh "${SSH_OPTS[@]}" "$TARGET" "$1"; }

KRELEASE_REMOTE=$(run 'uname -r') || die "could not reach $TARGET"
LABEL=${2:-$KRELEASE_REMOTE}
mkdir -p "$ROOT/profiles"
OUT="$ROOT/profiles/bench-$LABEL.txt"

say "benchmarking $TARGET ($KRELEASE_REMOTE), $RUNS runs per metric -> $OUT"
scp "${SSH_OPTS[@]}" -q "$ROOT/scripts/bench-remote.sh" "$TARGET:/var/tmp/bench-remote.sh" \
    || die "could not copy the benchmark to $TARGET"
run "bash /var/tmp/bench-remote.sh $RUNS; rm -f /var/tmp/bench-remote.sh" > "$OUT.tmp" \
    || die "benchmark failed on $TARGET"
grep -q '^build_' "$OUT.tmp" || die "benchmark output looks incomplete: $OUT.tmp"
mv "$OUT.tmp" "$OUT"
say "wrote $OUT"
