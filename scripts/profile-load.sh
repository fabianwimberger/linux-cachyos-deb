#!/usr/bin/env bash
# Put a realistic mixed workload on the profiling host so the AutoFDO profile
# captures the drivers and userspace paths real users hit, not an idle kernel.
# Each phase is bounded and skipped if its tool is missing, so this runs on any
# instrumented host.
#
#   scripts/profile-load.sh <duration-seconds>
#
# Runs CPU, memory, storage, GPU (VAAPI + ROCm) and network phases for the
# given total (dialled to roughly fill <duration>). It is meant to be driven by
# scripts/profile.sh, which guarantees the instrumented kernel underneath.
#
# The host needs the profile prerequisites (perf, kptr_restrict=0,
# perf_event_paranoid<=0) which make profile.sh already checks.
set -uo pipefail

TOTAL=${1:-600}
END=$(( $(date +%s) + TOTAL ))
run() { command -v "$1" >/dev/null 2>&1; }

say() { printf '>> [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

phase_cpu() {
    say "cpu: parallel compile + openssl"
    # A parallel kernel/module-style compile is a heavy CPU + syscall + scheduler load.
    if run "cc"; then
        tmp=$(mktemp -d)
        (timeout "${TOTAL}" bash -c "
            seq 1 \$(nproc) | xargs -P \$(nproc) -I{} sh -c 'cd $tmp && printf \"int f{}(){return {};}\" > f{}.c && cc -O2 -c f{}.c'
        ") 2>/dev/null || true
        rm -rf "$tmp"
    fi
    # OpenSSL is gzip of single-core crypto; quick burst.
    if run "openssl"; then
        timeout 30 openssl speed -seconds 8 sha256 >/dev/null 2>&1 || true
    fi
}

phase_memory() {
    say "memory: stream-like copy band"
    if run "python3"; then
        timeout 40 python3 - <<'PY' 2>/dev/null || true
n = 200_000_000  # ~1.6 GiB
a = bytearray(n)
for _ in range(8):
    a[:] = a[::-1]
PY
    fi
    # sysbench memory if present
    if run "sysbench"; then
        timeout 30 sysbench memory run --threads=8 --time=20 >/dev/null 2>&1 || true
    fi
}

phase_storage() {
    say "storage: fio on ext4 root"
    if run "fio" && [ -d /home ]; then
        (cd /home && timeout 50 fio --name=prf --size=1g --bs=4k \
            --rw=randread --ioengine=libaio --direct=1 --iodepth=32 \
            --time_based --runtime=20 --group_reporting >/dev/null 2>&1) || true
        (cd /home && timeout 50 fio --name=prf --size=1g --bs=1m \
            --rw=write --ioengine=libaio --direct=1 \
            --time_based --runtime=15 --group_reporting >/dev/null 2>&1) || true
        rm -rf /home/prf* 2>/dev/null
    fi
}

phase_gpu_vaapi() {
    say "gpu: VAAPI h264+av1 encode/decode on renderD128"
    if run "ffmpeg" && [ -e /dev/dri/renderD128 ]; then
        src=/tmp/prf-src.y4m
        # 4 seconds of moving test pattern
        timeout 20 ffmpeg -hide_banner -f lavfi -i testsrc2=size=1280x720:rate=30:duration=4 \
            -pix_fmt yuv420p "$src" >/dev/null 2>&1 || true
        for enc in h264_vaapi av1_vaapi; do
            timeout 30 ffmpeg -hide_banner -vaapi_device /dev/dri/renderD128 \
                -i "$src" -vf 'format=nv12,hwupload' -c:v "$enc" -b:v 8M \
                /tmp/prf-$enc.mp4 >/dev/null 2>&1 || true
        done
        rm -f "$src" /tmp/prf-*.mp4 2>/dev/null
    fi
}

phase_gpu_rocm() {
    say "gpu: ROCm GEMM"
    if run "rocblas-bench"; then
        timeout 40 rocblas-bench --sgemm --m 4096 --n 4096 --k 4096 \
             --alpha 1 --beta 0 --transposeA N --transposeB N >/dev/null 2>&1 || true
    fi
}

phase_network() {
    say "network: iperf3 over real NIC to gateway"
    if run "iperf3"; then
        # iperf3 needs a server; run it briefly against itself on loopback is
        # worthless for NIC drivers, so try a localhost server but keep it short.
        iperf3 -s -D -p 5201 >/dev/null 2>&1
        sleep 1
        timeout 20 iperf3 -c 127.0.0.1 -p 5201 -t 10 -P 4 >/dev/null 2>&1 || true
        pkill -f 'iperf3 -s' 2>/dev/null || true
    fi
}

while [ "$(date +%s)" -lt "$END" ]; do
    phase_cpu
    phase_memory
    phase_storage
    phase_gpu_vaapi
    phase_gpu_rocm
    phase_network
done
say "load complete"
