#!/usr/bin/env bash
# Report how well $AUTOFDO_PROFILE still matches the kernel being built.
#
#   scripts/profile-report.sh [min-weighted-percent]
#
# A name-match % alone can't detect an empty training run, so this also
# gates on total samples and distinct functions (env floors
# AUTOFDO_MIN_SAMPLES / AUTOFDO_MIN_FUNCTIONS) and on top-100 hot-function
# drift against the previously accepted profile (profiles/hotset-reference.txt).
#
# An AutoFDO profile is keyed by function name, so it survives source churn:
# functions that changed keep their entries, renamed or deleted ones stop
# matching, and new ones simply have no data. That degrades quietly — the build
# succeeds either way — so the question worth asking on every version bump is
# how much of the profile still lands.
#
# Two numbers are reported. The share of profiled *functions* still present is
# the shallow one. The share weighted by sample count is what matters: a profile
# can lose a third of its functions and still be fine if they were cold, or lose
# five and be worthless if they were the hot paths.
#
# Expect a drop of a few percent as soon as the profile is applied, and do not
# read it as drift. Small hot functions are exactly what AutoFDO inlines, so
# they stop existing as standalone symbols in the optimised binary — the
# profile causing its own apparent mismatch is the optimisation working. The
# comparison worth watching is between successive kernel versions, not between
# a profiled build and the build it was collected from.
. "$(dirname "$0")/lib.sh"
require_flavor

MIN=${1:-80}
# Name-match proves freshness, not coverage — a run of idle noise records the
# same function names and passes an 80% gate regardless. Two extra floors
# (env-overridable) make "did we actually train" decidable: total samples and
# distinct sampled functions. Defaults are floors below the current healthy
# values (~1.6B samples / ~4.7k functions) with headroom.
MIN_SAMPLES=${AUTOFDO_MIN_SAMPLES:-50000000}
MIN_FUNCTIONS=${AUTOFDO_MIN_FUNCTIONS:-1500}
PROFILE="$ROOT/${AUTOFDO_PROFILE:-profiles/vmlinux.afdo}"
VMLINUX="$OBJDIR/vmlinux"

[ -f "$PROFILE" ] || die "no profile at $PROFILE — run: make profile HOST=<host>"
[ -f "$VMLINUX" ] || die "no $VMLINUX — build the flavor first"

IMAGE=${IMAGE:-linux-cachyos-deb:$UBUNTU_SERIES}
docker image inspect "$IMAGE" >/dev/null 2>&1 || die "image $IMAGE missing — run: make image"

say "profile: ${AUTOFDO_PROFILE}"
say "kernel : work/$FLAVOR/vmlinux ($KRELEASE)"
say "floors : >=$MIN_SAMPLES samples, >=$MIN_FUNCTIONS profiled functions"

tmp=$(mktemp -d) && trap 'rm -rf "$tmp"' EXIT

docker run --rm -v "$ROOT:/work" -v "$tmp:/out" -w /work --user "$(id -u):$(id -g)" "$IMAGE" \
    bash -c "llvm-profdata show --sample '/work/${AUTOFDO_PROFILE}' > /out/profile.txt 2>/dev/null
             llvm-nm --defined-only '/work/work/$FLAVOR/vmlinux' > /out/symbols.txt 2>/dev/null" \
    || die "could not read profile or symbols"

python3 - "$tmp/profile.txt" "$tmp/symbols.txt" "$MIN" "$MIN_SAMPLES" "$MIN_FUNCTIONS" "$ROOT/profiles/hotset-reference.txt" <<'PY'
import os, re, sys

prof_path, sym_path, min_pct = sys.argv[1], sys.argv[2], float(sys.argv[3])
min_samples, min_functions = int(sys.argv[4]), int(sys.argv[5])
hotset_path = sys.argv[6]

# Compiler suffixes differ between builds without the function differing.
suffix = re.compile(r'\.(llvm|cold|part|isra|constprop|localalias)\.?[0-9]*.*$')
def norm(n): return suffix.sub('', n)

# Top-level entries only: inlined callees are indented and already accounted
# for inside their caller's total.
profile = {}
for line in open(prof_path, errors='replace'):
    m = re.match(r'^Function: ([^:]+): (\d+),', line)
    if m:
        profile[norm(m.group(1))] = profile.get(norm(m.group(1)), 0) + int(m.group(2))

symbols = set()
for line in open(sym_path, errors='replace'):
    parts = line.split()
    if len(parts) >= 3 and parts[1] in ('t', 'T', 'w', 'W'):
        symbols.add(norm(parts[2]))

if not profile:
    print("  FAIL  profile contains no functions"); sys.exit(1)
if not symbols:
    print("  FAIL  no text symbols found in vmlinux"); sys.exit(1)

total_fn = len(profile)
total_wt = sum(profile.values())
matched = {f: c for f, c in profile.items() if f in symbols}
missing = sorted(((c, f) for f, c in profile.items() if f not in symbols), reverse=True)

fn_pct = 100.0 * len(matched) / total_fn
wt_pct = 100.0 * sum(matched.values()) / total_wt if total_wt else 0.0

print()
print(f"  functions in profile      {total_fn}")
print(f"  still present in kernel   {len(matched)}  ({fn_pct:.1f}%)")
print(f"  sample-weighted match     {wt_pct:.1f}%   <- the number that matters")
print()

if missing:
    print(f"  hottest profiled functions no longer in the kernel:")
    for c, f in missing[:15]:
        share = 100.0 * c / total_wt
        print(f"    {share:6.2f}%  {f}")
    if len(missing) > 15:
        print(f"    ... and {len(missing) - 15} more")
    print()

if wt_pct < min_pct:
    print(f"  FAIL  weighted match {wt_pct:.1f}% is below {min_pct:.0f}% — regenerate the profile")
    sys.exit(1)
if total_wt < min_samples:
    print(f"  FAIL  {total_wt} samples is below the {min_samples} floor — the training load was empty or barely ran")
    sys.exit(1)
if total_fn < min_functions:
    print(f"  FAIL  {total_fn} profiled functions is below the {min_functions} floor — the driver mix was narrower than expected")
    sys.exit(1)
print(f"  ok    {total_wt} samples / {total_fn} functions above floors")

# Hotset drift: a recording whose top-100 hot functions differs fundamentally
# from the previous profile trained on something else, even if weight/floors
# pass. The reference file turns over after each accepted profile.
if os.path.exists(hotset_path):
    prev = [l.strip() for l in open(hotset_path).readlines() if l.strip()]
    cur = dict.fromkeys(sorted(profile, key=profile.get, reverse=True)[:100])
    overlap = sum(1 for f in prev if f in cur)
    print()
    print(f"  hotset overlap vs previous {overlap}/{len(prev)} top-100")
    if len(prev) >= 20 and overlap < 0.6 * len(prev):
        print("  FAIL  hotset moved far — review the training load, do not upload")
        sys.exit(1)
try:
    with open(hotset_path, 'w') as fh:
        fh.write(''.join(f + '\n' for f in sorted(profile, key=profile.get, reverse=True)[:100]))
except OSError:
    pass
print(f"  ok    weighted match {wt_pct:.1f}% (threshold {min_pct:.0f}%)")
PY
