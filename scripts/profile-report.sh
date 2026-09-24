#!/usr/bin/env bash
# Report how well $AUTOFDO_PROFILE still matches the kernel being built.
#
#   scripts/profile-report.sh [min-weighted-percent]
#
# An AutoFDO profile is keyed by function name, so it survives source churn:
# functions that changed keep their entries, renamed or deleted ones stop
# matching, and new ones simply have no data. That degrades quietly — the build
# succeeds either way — so the question worth asking on every version bump is
# how much of the profile still lands. CI asks it on every release build.
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
#
# A name match cannot tell a real training run from idle noise, so a freshly
# recorded profile is also gated on how much it trained:
#   - absolute floors on total samples and distinct functions
#     (AUTOFDO_MIN_SAMPLES / AUTOFDO_MIN_FUNCTIONS)
#   - samples per recorded second against the profile CI currently ships
#     (profiles/previous.meta, AUTOFDO_MIN_RATE_RATIO)
#   - top-100 hot-function overlap against that same profile
#     (profiles/hotset-reference.txt)
# The last two only apply when those files exist; scripts/profile-release.sh
# fetches them from the profiles repo. This never moves the reference itself:
# it writes the current hotset to profiles/hotset.txt, and only an upload makes
# that the new reference.
. "$(dirname "$0")/lib.sh"
require_flavor

MIN=${1:-80}
# A healthy hour is ~1.4B samples / ~5k functions; these only
# catch a run that barely happened. The rate check below is the tight one.
MIN_SAMPLES=${AUTOFDO_MIN_SAMPLES:-50000000}
MIN_FUNCTIONS=${AUTOFDO_MIN_FUNCTIONS:-1500}
MIN_RATE_RATIO=${AUTOFDO_MIN_RATE_RATIO:-0.5}
# Set to 1 for the first run after a deliberate change to the training load,
# whose hot set is expected to move.
ACCEPT_DRIFT=${AUTOFDO_ACCEPT_HOTSET_DRIFT:-0}
PROFILE="$ROOT/${AUTOFDO_PROFILE:-profiles/vmlinux.afdo}"
VMLINUX="$OBJDIR/vmlinux"

[ -f "$PROFILE" ] || die "no profile at $PROFILE — run: make profile HOST=<host>"
[ -f "$VMLINUX" ] || die "no $VMLINUX — build the flavor first"

IMAGE=${IMAGE:-linux-cachyos-deb:$UBUNTU_SERIES}
docker image inspect "$IMAGE" >/dev/null 2>&1 || die "image $IMAGE missing — run: make image"

say "profile: ${AUTOFDO_PROFILE} (sha256 $(sha256sum "$PROFILE" | cut -c1-12))"
say "kernel : work/$FLAVOR/vmlinux ($KRELEASE)"
say "floors : >=$MIN_SAMPLES samples, >=$MIN_FUNCTIONS profiled functions"

tmp=$(mktemp -d) && trap 'rm -rf "$tmp"' EXIT

docker run --rm -v "$ROOT:/work" -v "$tmp:/out" -w /work --user "$(id -u):$(id -g)" "$IMAGE" \
    bash -c "set -e
             llvm-profdata show --sample '/work/${AUTOFDO_PROFILE}' > /out/profile.txt
             llvm-nm --defined-only '/work/work/$FLAVOR/vmlinux' > /out/symbols.txt" \
    || die "could not read profile or symbols"

python3 - "$tmp/profile.txt" "$tmp/symbols.txt" "$MIN" "$MIN_SAMPLES" "$MIN_FUNCTIONS" \
    "$MIN_RATE_RATIO" "$FLAVOR" "$PROFILE.meta" "$ROOT/profiles" "$ACCEPT_DRIFT" <<'PY'
import os, re, sys

prof_path, sym_path, min_pct = sys.argv[1], sys.argv[2], float(sys.argv[3])
min_samples, min_functions = int(sys.argv[4]), int(sys.argv[5])
min_rate_ratio, flavor, meta_path, profiles = float(sys.argv[6]), sys.argv[7], sys.argv[8], sys.argv[9]
accept_drift = sys.argv[10] == "1"
hotset_ref = os.path.join(profiles, "hotset-reference.txt")
prev_meta_path = os.path.join(profiles, "previous.meta")

def read_meta(path):
    meta = {}
    if os.path.exists(path):
        for line in open(path):
            k, _, v = line.strip().partition("=")
            if k:
                meta[k] = v.strip('"')
    return meta

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

meta = read_meta(meta_path)
total_fn = len(profile)
total_wt = sum(profile.values())
matched = {f: c for f, c in profile.items() if f in symbols}
missing = sorted(((c, f) for f, c in profile.items() if f not in symbols), reverse=True)
hotset = sorted(profile, key=profile.get, reverse=True)[:100]

fn_pct = 100.0 * len(matched) / total_fn
wt_pct = 100.0 * sum(matched.values()) / total_wt if total_wt else 0.0

print()
if meta:
    print(f"  recorded from             {meta.get('KRELEASE', '?')} on {meta.get('DATE', '?')}")
    # Flow-sensitive discriminators come from machine basic blocks, which
    # differ with -march; a profile from another flavor applies less precisely.
    if meta.get('FLAVOR') and meta['FLAVOR'] != flavor:
        print(f"  note: recorded on {meta['FLAVOR']}, applied to {flavor}")
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

# Properties of the profile file itself, so rewriting them is idempotent; the
# upload carries them into the profiles repo for the next run's rate check.
os.makedirs(profiles, exist_ok=True)
with open(os.path.join(profiles, "hotset.txt"), "w") as fh:
    fh.write("".join(f + "\n" for f in hotset))
if meta:
    meta["SAMPLES"], meta["FUNCTIONS"] = str(total_wt), str(total_fn)
    with open(meta_path, "w") as fh:
        fh.write("".join(f'{k}="{v}"\n' if " " in v else f"{k}={v}\n" for k, v in meta.items()))

fail = False
if wt_pct < min_pct:
    print(f"  FAIL  weighted match {wt_pct:.1f}% is below {min_pct:.0f}% — regenerate the profile")
    fail = True
if total_wt < min_samples:
    print(f"  FAIL  {total_wt} samples is below the {min_samples} floor — the training load was empty or barely ran")
    fail = True
if total_fn < min_functions:
    print(f"  FAIL  {total_fn} profiled functions is below the {min_functions} floor — the driver mix was narrower than expected")
    fail = True

prev = read_meta(prev_meta_path)
secs = int(meta.get("RECORDED_SECONDS", 0) or 0)
prev_secs, prev_samples = int(prev.get("RECORDED_SECONDS", 0) or 0), int(prev.get("SAMPLES", 0) or 0)
if secs and prev_secs and prev_samples:
    rate, prev_rate = total_wt / secs, prev_samples / prev_secs
    print(f"  sample rate               {rate:,.0f}/s vs {prev_rate:,.0f}/s shipped ({rate / prev_rate:.2f}x)")
    if rate < min_rate_ratio * prev_rate:
        print(f"  FAIL  sample rate is below {min_rate_ratio}x the shipped profile's — the load ran thinner than last time")
        fail = True

# Hotset drift: a recording whose top-100 hot functions differ fundamentally
# from the shipped profile trained on something else, even if the floors pass.
if os.path.exists(hotset_ref):
    ref = [l.strip() for l in open(hotset_ref) if l.strip()]
    cur = set(hotset)
    overlap = sum(1 for f in ref if f in cur)
    print(f"  hotset overlap vs shipped {overlap}/{len(ref)} top-100")
    if len(ref) >= 20 and overlap < 0.6 * len(ref):
        if accept_drift:
            print("  note  hotset moved far; accepted (AUTOFDO_ACCEPT_HOTSET_DRIFT=1)")
        else:
            print("  FAIL  hotset moved far — review the training load, do not upload")
            fail = True

print()
if fail:
    sys.exit(1)
print(f"  ok    {total_wt} samples / {total_fn} functions, weighted match {wt_pct:.1f}% (threshold {min_pct:.0f}%)")
PY
