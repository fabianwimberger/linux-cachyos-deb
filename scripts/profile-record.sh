#!/usr/bin/env bash
# Segmented AutoFDO recorder. Copied to the profiling target and run there,
# detached, by scripts/profile.sh — never invoked by hand.
#
#   profile-record.sh <outdir> <segments> <segment-seconds> <event> <period> [load-pidfile]
#
# Runs in its own session so a dropped ssh link cannot take a segment down
# with it; the driver only polls <outdir>/status. Each segment is decoded and
# compressed on the spot and the raw perf.data dropped, which bounds disk use
# to one segment.
#
# Per segment it leaves:
#   <i>.script.zst  perf script -F ip,brstack, the input llvm-profgen reads
#   <i>.hist        "<CLOCK_MONOTONIC second> <samples>", to attribute samples
#                   to load phases afterwards
#   <i>.log         perf's own stderr, kept for lost-sample warnings
set -euo pipefail

OUT=$1 SEGMENTS=$2 SEGMENT=$3 EVENT=$4 PERIOD=$5 LOAD_PIDFILE=${6:-}

echo $$ > "$OUT/record.pid"
echo running > "$OUT/status"
trap '[ "$(cat "$OUT/status")" = "done" ] || echo "failed: ${fail:-interrupted}" > "$OUT/status"' EXIT
trap 'exit 143' TERM INT HUP

load_alive() {
    [ -z "$LOAD_PIDFILE" ] && return 0
    [ -f "$LOAD_PIDFILE" ] && kill -0 "$(cat "$LOAD_PIDFILE")" 2>/dev/null
}

perf_data=/var/tmp/autofdo.perf
for i in $(seq 1 "$SEGMENTS"); do
    echo "segment $i/$SEGMENTS" > "$OUT/progress"
    load_alive || { fail="load exited before segment $i"; exit 1; }

    fail="perf record, segment $i"
    # -k monotonic: the only NMI-safe clock perf offers, and the one the load
    # stamps its phase markers with.
    perf record -e "${EVENT}:k" -a -N -b -c "$PERIOD" -k monotonic \
        -o "$perf_data" -- sleep "$SEGMENT" 2> "$OUT/$i.log"

    fail="perf script, segment $i"
    perf script -i "$perf_data" --show-mmap-events -F ip,brstack 2>> "$OUT/$i.log" \
        | zstd -3 -q -f -o "$OUT/$i.script.zst"
    perf script -i "$perf_data" -F time 2>> "$OUT/$i.log" \
        | awk '{ sub(":", "", $1); c[int($1)]++ } END { for (t in c) print t, c[t] }' \
        > "$OUT/$i.hist"
    rm -f "$perf_data"

    # A segment during which the load died recorded an idle kernel.
    load_alive || { fail="load exited during segment $i"; exit 1; }
done

fail=
echo "done" > "$OUT/status"
