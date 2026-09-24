#!/usr/bin/env bash
# One-shot automation for refreshing the AutoFDO profile on a new release.
#
#   scripts/profile-release.sh <ssh-host> [total-seconds] [segment-seconds]
#
# Flow: start the load on the target and wait until its setup is done, record +
# convert + merge a profile of it (scripts/profile.sh), stop the load, check
# which phases ran and what share of the samples each produced, gate the result
# (scripts/profile-report.sh), and upload it to the private profiles repo CI
# reads. Same prerequisites as `make profile`: the target must be running the
# instrumented kernel from work/$FLAVOR/.
#
# The load is stopped on every exit path, including failures and Ctrl-C, so a
# failed run never leaves it churning on the target.
#
# AUTOFDO_NET_PEER=<host>[:<port>] points the load's NIC phase at an iperf3
# server. Unset, this host serves one itself on port 5203 if iperf3 is
# installed (the target reaches it at the address its ssh session came from);
# "none" skips the phase.
#
# AUTOFDO_PHASES, AUTOFDO_WG_PEER, AUTOFDO_SELENIUM_PY, AUTOFDO_GEMM_CPP and
# AUTOFDO_HSA_GFX_VERSION, when set here, are passed through to the load.
. "$(dirname "$0")/lib.sh"
require_flavor

TARGET=${1:-}
# An hour is two to three laps of the load, so every phase lands in the
# recording more than once.
TOTAL=${2:-3600}
SEGMENT=${3:-300}
[ -n "$TARGET" ] || die "usage: scripts/profile-release.sh <ssh-host> [total-seconds] [segment-seconds]"
[ "$TARGET" != local ] || die "profile-release needs a real remote target, not 'local'"
command -v gh >/dev/null || die "gh not installed (for the upload step)"

# Phases whose absence makes the profile unrepresentative; override with a
# space-separated list for a host that legitimately lacks one.
REQUIRED_PHASES=${AUTOFDO_REQUIRED_PHASES:-cpu vm ipc storage files containers db web mixed net_loopback}
# No single phase may make up more than this share (%) of the recorded
# samples: past it, the profile is mostly one workload.
MAX_PHASE_SHARE=${AUTOFDO_MAX_PHASE_SHARE:-40}
SETUP_TIMEOUT=${AUTOFDO_SETUP_TIMEOUT:-1800}
STATE=/var/tmp/profile-load
PROFILES_REPO=$AUTOFDO_PROFILES_REPO

# Host-key checking off, and never touching the real known_hosts: this
# target's key legitimately changes whenever its kernel or OS gets
# reinstalled, which is routine for this kind of target, not a MITM signal.
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ConnectionAttempts=5
          -o ServerAliveInterval=15 -o ServerAliveCountMax=6
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
rsh() { ssh "${SSH_OPTS[@]}" "$TARGET" "$1"; }

tmp=$(mktemp -d)
load_started='' load_stopped=''

stop_load() {
    [ -n "$load_started" ] && [ -z "$load_stopped" ] || return 0
    load_stopped=1
    say "stopping load on $TARGET"
    # The load finishes its current phase (two minutes at most) and tears its
    # containers and servers down itself; the group kill is the fallback.
    rsh "touch $STATE/stop
         p=\$(cat $STATE/pid 2>/dev/null) || exit 0
         for _ in \$(seq 1 60); do kill -0 \$p 2>/dev/null || exit 0; sleep 5; done
         kill -TERM -- -\$p 2>/dev/null; sleep 10; true" || say "warning: could not stop the load on $TARGET"
    scp "${SSH_OPTS[@]}" -q "$TARGET:/var/tmp/profile-load.log" "$ROOT/profiles/profile-load.log" 2>/dev/null
    scp "${SSH_OPTS[@]}" -q "$TARGET:$STATE/phases" "$ROOT/profiles/phases.log" 2>/dev/null
    true
}
cleanup() {
    stop_load
    [ -f "$tmp/iperf3.pid" ] && kill "$(cat "$tmp/iperf3.pid")" 2>/dev/null
    rm -rf "$tmp"
}
trap cleanup EXIT

say "target $TARGET; total ${TOTAL}s in ${SEGMENT}s segments; flavor $FLAVOR"
mkdir -p "$ROOT/profiles"
rm -f "$ROOT/profiles/profile-load.log" "$ROOT/profiles/phases.log" "$ROOT/profiles/samples.hist"

# The drift gate compares against the profile CI currently ships, so the
# reference comes from the profiles repo, not from whatever this checkout ran
# last. A repo without one yet leaves the local reference in place.
say "fetching the current profile's hotset and metadata from $PROFILES_REPO"
git clone --quiet --depth 1 "https://github.com/$PROFILES_REPO.git" "$tmp/profiles" \
    || die "could not clone $PROFILES_REPO"
[ -f "$tmp/profiles/hotset.txt" ] && cp "$tmp/profiles/hotset.txt" "$ROOT/profiles/hotset-reference.txt"
rm -f "$ROOT/profiles/previous.meta"
[ -f "$tmp/profiles/vmlinux.afdo.meta" ] && cp "$tmp/profiles/vmlinux.afdo.meta" "$ROOT/profiles/previous.meta"

peer=${AUTOFDO_NET_PEER:-}
if [ -z "$peer" ] && command -v iperf3 >/dev/null; then
    self=$(rsh 'echo $SSH_CONNECTION' | awk '{print $1}')
    if [ -n "$self" ] && iperf3 -s -D -p 5203 -I "$tmp/iperf3.pid" >/dev/null 2>&1; then
        peer="$self:5203"
        say "serving iperf3 for the NIC phase at $peer"
    fi
fi
[ "$peer" = none ] && peer=
[ -n "$peer" ] || say "no iperf3 peer — the NIC phase will skip"

# The script must land as a real file and be launched by path: a nohup'd
# `bash -s ... < /dev/null` run over a stdin-piped script never sees that
# script (its own </dev/null wins). setsid makes it a session and process
# group leader, so stop_load can take the whole tree down in one kill.
say "starting load on $TARGET"
scp "${SSH_OPTS[@]}" -q "$ROOT/scripts/profile-load.sh" "$ROOT/scripts/profile-gemm.cpp" "$TARGET:/var/tmp/" \
    || die "could not copy the load scripts to $TARGET"
passthrough=
for v in AUTOFDO_PHASES AUTOFDO_WG_PEER AUTOFDO_SELENIUM_PY AUTOFDO_GEMM_CPP AUTOFDO_HSA_GFX_VERSION; do
    [ -n "${!v:-}" ] && passthrough+=" $v=$(printf '%q' "${!v}")"
done
# The duration is a backstop only; the load normally runs until stop_load.
rsh "STRICT=${STRICT:-1} AUTOFDO_NET_PEER='$peer' AUTOFDO_STATE_DIR=$STATE$passthrough \
     setsid nohup bash /var/tmp/profile-load.sh $(( TOTAL * 2 + 3600 )) \
     < /dev/null > /var/tmp/profile-load.log 2>&1 &" \
    || die "could not start load on $TARGET"
load_started=1

say "waiting for load setup (up to ${SETUP_TIMEOUT}s)"
deadline=$(( $(date +%s) + SETUP_TIMEOUT ))
while :; do
    sleep 15
    state=$(rsh "[ -e $STATE/ready ] && echo ready && exit
                 p=\$(cat $STATE/pid 2>/dev/null) && kill -0 \$p 2>/dev/null && echo setup || echo dead") \
        || continue
    case "$state" in
        ready) break ;;
        dead)  rsh 'tail -20 /var/tmp/profile-load.log' >&2 || true
               die "load exited during setup" ;;
    esac
    [ "$(date +%s)" -lt "$deadline" ] || die "load setup did not finish within ${SETUP_TIMEOUT}s"
done
say "load running"

AUTOFDO_LOAD_PIDFILE=$STATE/pid bash "$ROOT/scripts/profile.sh" "$TARGET" "$TOTAL" "$SEGMENT" \
    || die "recording failed"

stop_load
[ -s "$ROOT/profiles/profile-load.log" ] || die "could not fetch the load log from $TARGET"
sed -n '/phase summary:/,$p' "$ROOT/profiles/profile-load.log"

missing=
for p in $REQUIRED_PHASES; do
    grep -qE "^ +ok +$p\$" "$ROOT/profiles/profile-load.log" || missing="$missing $p"
done
[ -z "$missing" ] || die "required phases did not run:$missing — see profiles/profile-load.log; do not upload"

# Per-phase share of kernel samples: which workloads the profile is actually
# made of. Wall time says little here, since a userspace-bound phase can run
# for minutes and contribute almost nothing, while one that lives in the
# kernel on every core can swamp the rest.
[ -s "$ROOT/profiles/phases.log" ] && [ -s "$ROOT/profiles/samples.hist" ] \
    || die "no phase markers or sample histogram — cannot tell what the profile is made of"
python3 - "$ROOT/profiles/phases.log" "$ROOT/profiles/samples.hist" "$MAX_PHASE_SHARE" \
    > "$ROOT/profiles/phase-share.txt" <<'PY' || share_fail=1
import sys
from collections import defaultdict

windows, open_ = [], {}
for line in open(sys.argv[1]):
    t, kind, name = line.split()
    if kind == "start":
        open_[name] = float(t)
    elif name in open_:
        windows.append((open_.pop(name), float(t), name))

hist = [tuple(map(int, l.split())) for l in open(sys.argv[2]) if l.strip()]
total = sum(c for _, c in hist)
share, secs = defaultdict(int), defaultdict(float)
for s, e, name in windows:
    secs[name] += e - s
for sec, count in hist:
    name = next((n for s, e, n in windows if s <= sec + 0.5 < e), "(between phases)")
    share[name] += count

max_share = float(sys.argv[3])
print(f"\nsample share by phase ({total} samples recorded):")
worst = (0.0, "")
for name, count in sorted(share.items(), key=lambda kv: -kv[1]):
    pct = 100.0 * count / total if total else 0.0
    print(f"  {pct:6.2f}%  {secs.get(name, 0.0):7.0f}s  {name}")
    if name != "(between phases)" and pct > worst[0]:
        worst = (pct, name)
if worst[0] > max_share:
    print(f"\n  FAIL  {worst[1]} is {worst[0]:.1f}% of all samples, above {max_share:.0f}% — shorten it or lengthen the others")
    sys.exit(1)
if worst[0] > max_share * 0.6:
    print(f"\n  note  {worst[1]} is {worst[0]:.1f}% of all samples; the profile leans on it")
PY
cat "$ROOT/profiles/phase-share.txt"
[ -z "${share_fail:-}" ] || die "one phase dominates the profile — do not upload; see profiles/phase-share.txt"

say "checking profile floors and hotset drift"
bash "$ROOT/scripts/profile-report.sh" "${MIN:-80}" \
    || die "profile failed its gates — do not upload. Review the load and re-run."

say "profile passes — uploading"
bash "$ROOT/scripts/profile-upload.sh"
