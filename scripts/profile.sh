#!/usr/bin/env bash
# Collect an AutoFDO profile from a machine running an instrumented kernel and
# convert it into $AUTOFDO_PROFILE.
#
#   scripts/profile.sh <host> [total-seconds] [segment-seconds]
#
# <host> is an ssh destination, or "local" to profile this machine. The kernel
# running there must be the one in work/$FLAVOR/, built with
# CONFIG_AUTOFDO_CLANG=y, because the profile is matched against its vmlinux.
#
# Recording is segmented and each segment is converted and discarded before the
# next starts, then the profiles are merged. A single long `perf record` with a
# branch stack produces a perf.data far larger than the profile derived from it
# — an hour can run to tens of GB — and segmenting bounds that to one segment at
# a time. Merging is the documented way to combine profiles, so a long run
# spanning several different workloads is preferable to one narrow one.
. "$(dirname "$0")/lib.sh"
require_flavor

TARGET=${1:-}
TOTAL=${2:-1800}
SEGMENT=${3:-300}
[ -n "$TARGET" ] || die "usage: scripts/profile.sh <ssh-host|local> [total-seconds] [segment-seconds]"
[ "$SEGMENT" -gt 0 ] && [ "$TOTAL" -ge "$SEGMENT" ] || die "total ($TOTAL) must be >= segment ($SEGMENT), and segment > 0"

VMLINUX="$OBJDIR/vmlinux"
[ -f "$VMLINUX" ] || die "no $VMLINUX — the profile is matched against the running kernel's vmlinux"

# llvm-profgen ships with LLVM and is already in the build image, so no second
# image and no build of autofdo's create_llvm_prof, which vendors all of
# llvm-project. The kernel documentation treats the two as equivalent and notes
# llvm-profgen need not match the compiler version, only be LLVM 19 or newer.
IMAGE=${IMAGE:-linux-cachyos-deb:$UBUNTU_SERIES}
docker image inspect "$IMAGE" >/dev/null 2>&1 || die "image $IMAGE missing — run: make image"

# AMD PMCx0C4, Retired Taken Branch Instructions, kernel side only. The kernel
# documentation names this RETIRED_TAKEN_BRANCH_INSTRUCTIONS and reaches it via
# --pfm-events, which Ubuntu's perf is not built with; the raw encoding needs no
# libpfm4. Intel's equivalent is BR_INST_RETIRED.NEAR_TAKEN, r20c4.
EVENT=${AUTOFDO_EVENT:-r0c4}
# One sample per this many taken branches. Lower is more detail and a much
# larger perf.data; the per-segment size is reported below so it can be tuned.
PERIOD=${AUTOFDO_PERIOD:-1000000}

# /var/tmp, not /tmp: /tmp is tmpfs on at least one target, and writing the
# recording into RAM competes with the workload being profiled.
# The host driving this may be on wifi, and a run spans an hour of transfers,
# so a momentary drop must not end the run. Host-key checking is off, and the
# real known_hosts is never touched: this target's key legitimately changes
# whenever its kernel or OS gets reinstalled, which is routine for this kind
# of target.
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ConnectionAttempts=5
          -o ServerAliveInterval=15 -o ServerAliveCountMax=6
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

retry() {
    local n=0
    until "$@"; do
        n=$((n + 1))
        [ "$n" -ge 5 ] && return 1
        say "retry $n/5 after failure: $1"
        sleep $((n * 10))
    done
}

run() { if [ "$TARGET" = local ]; then bash -c "$1"; else ssh "${SSH_OPTS[@]}" "$TARGET" "$1"; fi; }
fetch() {
    if [ "$TARGET" = local ]; then mv "$1" "$2"
    else retry scp "${SSH_OPTS[@]}" -q "$TARGET:$1" "$2" && run "rm -f $1"; fi
}

say "checking $TARGET"
run 'grep -qE "amd_lbr_v2| brs " /proc/cpuinfo || { echo "no AMD LBR/BRS: AutoFDO needs Zen 3 with BRS or Zen 4+ with amd_lbr_v2" >&2; exit 1; }
     command -v perf >/dev/null || { echo "perf not installed (apt install linux-tools-generic)" >&2; exit 1; }
     [ "$(sysctl -n kernel.perf_event_paranoid)" -le 0 ] || { echo "kernel.perf_event_paranoid must be <= 0; run: sudo sysctl -w kernel.perf_event_paranoid=-1" >&2; exit 1; }
     # With kptr_restrict set, /proc/kallsyms reads back as zeroes for a
     # non-root user, so perf cannot record the relocation reference symbol.
     # KASLR then leaves no way to map recorded runtime addresses onto
     # vmlinux, and the profile is silently worthless rather than wrong in any
     # visible way — perf only warns. Refuse instead.
     [ "$(sysctl -n kernel.kptr_restrict)" -eq 0 ] || { echo "kernel.kptr_restrict must be 0 so perf can record the KASLR relocation symbol; run: sudo sysctl -w kernel.kptr_restrict=0" >&2; exit 1; }
     grep -qE "^0+ " /proc/kallsyms && { echo "/proc/kallsyms reads as zeroes; kernel addresses are hidden and the profile cannot be mapped to vmlinux" >&2; exit 1; }
     true' \
    || die "target is not ready to profile"

running=$(retry run 'uname -r')
[ "$running" = "$KRELEASE" ] \
    || die "target runs $running but this is $FLAVOR ($KRELEASE) — profile and vmlinux must match"

grep -q '^CONFIG_AUTOFDO_CLANG=y' "$OBJDIR/.config" \
    || die "work/$FLAVOR/.config lacks CONFIG_AUTOFDO_CLANG=y — a profile from an uninstrumented kernel is not usable"

mkdir -p "$ROOT/profiles/parts"
rm -f "$ROOT/profiles/parts"/*.afdo

segments=$(( (TOTAL + SEGMENT - 1) / SEGMENT ))
say "recording ${TOTAL}s on $TARGET in $segments segment(s) of ${SEGMENT}s (event $EVENT, period $PERIOD)"
say "put real load on that machine — an idle recording profiles an idle kernel"

# Everything stays on the target until the run is over, then transfers once.
# Segmenting is only to bound perf.data: each segment is decoded and compressed
# on the spot and the raw recording dropped. Nothing crosses the network while
# recording, so a flaky link cannot cost a segment mid-run.
run "rm -rf /var/tmp/autofdo-run && mkdir -p /var/tmp/autofdo-run" || die "could not prepare target"

for i in $(seq 1 "$segments"); do
    say "segment $i/$segments: recording ${SEGMENT}s"
    run "perf record -e ${EVENT}:k -a -N -b -c $PERIOD -o /var/tmp/autofdo.perf -- sleep $SEGMENT \
         && perf script -i /var/tmp/autofdo.perf --show-mmap-events -F ip,brstack 2>/dev/null \
            | zstd -3 -q -o /var/tmp/autofdo-run/$i.script.zst -f \
         && rm -f /var/tmp/autofdo.perf" \
        || die "recording failed on segment $i"
done

say "recording complete, transferring"
run "cd /var/tmp/autofdo-run && tar -cf /var/tmp/autofdo-run.tar ." || die "could not pack traces"
fetch /var/tmp/autofdo-run.tar "$ROOT/profiles/autofdo-run.tar" || die "could not fetch traces"
run "rm -rf /var/tmp/autofdo-run"
say "transferred $(du -h "$ROOT/profiles/autofdo-run.tar" | cut -f1)"

rm -rf "$ROOT/profiles/traces"
mkdir -p "$ROOT/profiles/traces"
tar -xf "$ROOT/profiles/autofdo-run.tar" -C "$ROOT/profiles/traces"
rm -f "$ROOT/profiles/autofdo-run.tar"

for i in $(seq 1 "$segments"); do
    z="$ROOT/profiles/traces/$i.script.zst"
    [ -s "$z" ] || die "segment $i missing from the transferred traces"
    zstd -d -q -f "$z" -o "$ROOT/profiles/traces/$i.script" || die "could not decompress segment $i"
    say "converting segment $i/$segments"
    docker run --rm -v "$ROOT:/work" -w /work --user "$(id -u):$(id -g)" "$IMAGE" \
        llvm-profgen --kernel \
            --binary="/work/work/$FLAVOR/vmlinux" \
            --perfscript="/work/profiles/traces/$i.script" \
            -o "/work/profiles/parts/$i.afdo" \
        || die "llvm-profgen failed on segment $i"
    [ -s "$ROOT/profiles/parts/$i.afdo" ] || die "segment $i produced an empty profile"
    rm -f "$ROOT/profiles/traces/$i.script"
done
rm -rf "$ROOT/profiles/traces"

say "merging $segments profile(s)"
docker run --rm -v "$ROOT:/work" -w /work --user "$(id -u):$(id -g)" "$IMAGE" \
    bash -c "llvm-profdata merge --sample -o '/work/$AUTOFDO_PROFILE' /work/profiles/parts/*.afdo" \
    || die "llvm-profdata merge failed"

say "wrote $AUTOFDO_PROFILE ($(du -h "$ROOT/$AUTOFDO_PROFILE" | cut -f1))"
say "rebuild to apply it: make FLAVOR=$FLAVOR build package"
