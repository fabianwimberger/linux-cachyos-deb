#!/usr/bin/env bash
# One-shot automation for refreshing the AutoFDO profile on a new release.
#
#   scripts/profile-release.sh <ssh-host> [total-seconds]
#
# Flow: start the driver-mixing load in the background on the target, record +
# convert + merge a profile of it (make profile), stop the load, gate the result
# on how well it still matches the new kernel (make profile-report), and upload
# it to the private profiles repo CI reads. Same prerequisites as `make profile`:
# the target must be running the instrumented kernel from work/$FLAVOR/.
#
# Note the profile-keyed gate compares the collected profile against the kernel
# currently checked out, which is the release the profile is for. A profile that
# fails the gate here means the load is wrong or the source churned badly — stop
# and inspect, do not upload.
. "$(dirname "$0")/lib.sh"
require_flavor

TARGET=${1:-}
TOTAL=${2:-1800}
[ -n "$TARGET" ] || die "usage: scripts/profile-release.sh <ssh-host> [total-seconds]"
[ -n "$(command -v gh)" ] || die "gh not installed (for the upload step)"

# Host-key checking off, and never touching the real known_hosts: this
# target's key legitimately changes whenever its kernel or OS gets
# reinstalled, which is routine for this kind of target, not a MITM signal.
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=6
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
[ "$TARGET" != local ] || die "profile-release needs a real remote target, not 'local'"

say "target $TARGET; total ${TOTAL}s; flavor $FLAVOR"

# 1. load runs on the target in the background while we record.
# The script must land as a real file and be launched by path: a
# nohup'd `bash -s ... < /dev/null` run over a stdin-piped script never
# sees that script (its own </dev/null wins), and a backgrounded process
# started from an ssh command that's still attached to the closing ssh
# session can vanish with it even under nohup.
say "starting load on $TARGET (scripts/profile-load.sh $TOTAL)"
scp "${SSH_OPTS[@]}" -q "$ROOT/scripts/profile-load.sh" "$TARGET:/var/tmp/profile-load.sh" \
    || die "could not copy profile-load.sh to $TARGET"
ssh "${SSH_OPTS[@]}" "$TARGET" \
    "nohup bash /var/tmp/profile-load.sh $TOTAL < /dev/null > /var/tmp/profile-load.log 2>&1 & disown" \
    || die "could not start load on $TARGET"
ssh "${SSH_OPTS[@]}" "$TARGET" \
    "echo started; pgrep -f profile-load.sh >/dev/null && echo 'load running' || echo 'load FAILED to start'" \
    || die "could not verify load on $TARGET"

# 2. record + convert + merge while the load runs.
say "recording (make profile HOST=$TARGET SECS=$TOTAL)"
bash "$ROOT/scripts/profile.sh" "$TARGET" "$TOTAL" 300 || { echo "recording failed — stopping load"; die; }

# 3. stop the load.
ssh "${SSH_OPTS[@]}" "$TARGET" "pkill -f profile-load.sh 2>/dev/null; true" || true
say "load stopped"

# 4. gate the new profile on fit against the new kernel.
say "checking profile fit (make profile-report)"
bash "$ROOT/scripts/profile-report.sh" 80 || {
    die "profile fit below threshold — do not upload. Re-run with a better load or regenerate the source."
}

# 5. upload to the private repo CI reads.
say "profile fits — uploading"
bash "$ROOT/scripts/profile-upload.sh"

say "done. CI will pick up the new profile on its next build of $FLAVOR."
