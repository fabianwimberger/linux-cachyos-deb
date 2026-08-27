#!/usr/bin/env bash
# Report how well $AUTOFDO_PROFILE still matches the kernel being built.
#
#   scripts/profile-report.sh [min-weighted-percent]
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
PROFILE="$ROOT/${AUTOFDO_PROFILE:-profiles/vmlinux.afdo}"
VMLINUX="$OBJDIR/vmlinux"

[ -f "$PROFILE" ] || die "no profile at $PROFILE — run: make profile HOST=<host>"
[ -f "$VMLINUX" ] || die "no $VMLINUX — build the flavor first"

IMAGE=${IMAGE:-linux-cachyos-deb:$UBUNTU_SERIES}
docker image inspect "$IMAGE" >/dev/null 2>&1 || die "image $IMAGE missing — run: make image"

say "profile: ${AUTOFDO_PROFILE}"
say "kernel : work/$FLAVOR/vmlinux ($KRELEASE)"

tmp=$(mktemp -d) && trap 'rm -rf "$tmp"' EXIT

docker run --rm -v "$ROOT:/work" -v "$tmp:/out" -w /work --user "$(id -u):$(id -g)" "$IMAGE" \
    bash -c "llvm-profdata show --sample '/work/${AUTOFDO_PROFILE}' > /out/profile.txt 2>/dev/null
             llvm-nm --defined-only '/work/work/$FLAVOR/vmlinux' > /out/symbols.txt 2>/dev/null" \
    || die "could not read profile or symbols"

python3 - "$tmp/profile.txt" "$tmp/symbols.txt" "$MIN" <<'PY'
import re, sys

prof_path, sym_path, min_pct = sys.argv[1], sys.argv[2], float(sys.argv[3])

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
print(f"  ok    weighted match {wt_pct:.1f}% (threshold {min_pct:.0f}%)")
PY
