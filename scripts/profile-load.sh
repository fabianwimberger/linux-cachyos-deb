#!/usr/bin/env bash
# Put a realistic mixed workload on the profiling host so the AutoFDO profile
# captures the drivers and kernel paths real users hit, not an idle kernel.
# Each phase is bounded and skipped if its tool is missing, so this runs on any
# instrumented host.
#
#   scripts/profile-load.sh <max-seconds>
#
# Phases loosely stand in for a typical self-hosted container stack (docker,
# databases, a message broker, a web server, DNS, VPN, CI builds, GPU
# inference) and a desktop: scheduler, VM, IPC, storage across several
# filesystem types and I/O engines, NIC traffic, GPU (VAAPI + ROCm), audio,
# compositor and browser. It is meant to be driven by
# scripts/profile-release.sh, which guarantees the instrumented kernel
# underneath. Target setup is in docs/PROFILING.md.
#
# Only kernel samples are recorded, so a phase earns its time by how much of it
# is spent in the kernel. Pure userspace compute (compression, crypto
# benchmarks, OCR, image conversion) adds wall time and next to no samples, so
# the mix leans on workloads that live in syscalls, page faults, the block
# layer, the network stack and drivers instead. A synthetic stand-in that drives
# the same syscalls/ioctls (docker+postgres instead of a real document-archive
# stack, say) is enough — an untrained function simply has no profile data and
# is compiled as it would be without AutoFDO. ROCm is the one exception worth
# naming: it runs the real rocBLAS library through HIP inside a containerised
# ROCm userspace (no host install), because containerised inference drives
# ROCm the same way, and a GEMM through rocBLAS submits to /dev/kfd the same
# way real inference does.
#
# Each phase runs for a sustained window: a single short burst is dominated
# by process and driver setup rather than steady state.
#
# Phases run in laps. Each lap starts at a different phase, so wherever the
# recording happens to end, the cut-off falls on different phases rather than
# always shortchanging the ones at the end of the list. A lap with every phase
# available takes roughly 20-25 minutes. AUTOFDO_PHASES restricts the run to a
# space-separated subset, for tuning one phase at a time.
#
# Coordination with the recorder goes through $STATE (AUTOFDO_STATE_DIR):
#   pid      this script, so the recorder can fail if the load dies
#   ready    touched once setup (image pulls, rocBLAS install, pgbench init)
#            is done; recording starts only after it, so setup is not profiled
#   stop     created by the driver; the load finishes its current phase and
#            exits. <max-seconds> is only a backstop for a vanished driver.
#   phases   "<CLOCK_MONOTONIC> start|end <phase>", joined against perf's
#            per-second sample counts to show each phase's share
#
# STRICT=1 (passed by scripts/profile-release.sh) makes the run fail before
# setup when core training tools are absent, so a degraded mix on a freshly
# reinstalled host cannot produce an hour of near-idle noise. A final phase
# summary lists which phases actually ran and which skipped.
#
# The desktop/video/audio/browser phases only run when a live graphical
# session is present (an Ubuntu Desktop target with someone logged in) — they
# exercise the compositor, display and sound stack that the headless VAAPI
# phase's render-only encode never touches. Headless targets skip them.
#
# Some phases depend on one-time root setup that isn't part of this script and
# skip if it hasn't been done: loopback fs images under /mnt/fsdiv-*, a
# read-only mount at /mnt/nvme-ro, the prf-wg WireGuard namespace — all in
# docs/PROFILING.md. The ROCm phase compiles scripts/profile-gemm.cpp, which
# profile-release.sh copies next to this script (AUTOFDO_GEMM_CPP overrides).
# The NIC phase needs an iperf3 server on another machine,
# AUTOFDO_NET_PEER=<host>[:<port>], which profile-release.sh starts on the
# driving host.
set -uo pipefail

TOTAL=${1:-600}
END=$(( $(date +%s) + TOTAL ))
STATE=${AUTOFDO_STATE_DIR:-/var/tmp/profile-load}
PIDS="$STATE/pids"
run() { command -v "$1" >/dev/null 2>&1; }

say() { printf '>> [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

rm -rf "$STATE"
mkdir -p "$PIDS"
echo $$ > "$STATE/pid"

# perf stamps samples with CLOCK_MONOTONIC (the only NMI-safe clock it
# offers); date(1) cannot read that clock.
mono() {
    python3 -c 'import time; print(f"{time.clock_gettime(time.CLOCK_MONOTONIC):.1f}")' 2>/dev/null \
        || awk '{print $1}' /proc/uptime
}
stopping() { [ -e "$STATE/stop" ] || [ "$(date +%s)" -ge "$END" ]; }

# iperf3 -D daemonises into its own session, out of reach of a process-group
# kill; its pidfile is how teardown finds exactly the servers started here.
iperf3_server() {
    local name=$1; shift
    iperf3 -s -D -I "$PIDS/$name.pid" "$@" >/dev/null 2>&1
    sleep 1
}
iperf3_stop() {
    local f="$PIDS/$1.pid"
    [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null
    rm -f "$f"
}

# The interpreter with selenium installed, if any; a plain system python3
# almost never has it, so this is expected to miss on most hosts.
SELENIUM_PY=${AUTOFDO_SELENIUM_PY:-}
[ -n "$SELENIUM_PY" ] || SELENIUM_PY="$HOME/autofdo-load/.venv/bin/python3"
[ -x "$SELENIUM_PY" ] || SELENIUM_PY=python3

# Below phases need a live compositor to reach the display stack at all;
# without one (headless, or nobody logged in) they no-op rather than fail.
desktop_ready() {
    local rt xauth
    rt="/run/user/$(id -u)"
    [ -S "$rt/wayland-0" ] || return 1
    export XDG_RUNTIME_DIR="$rt" WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 MOZ_ENABLE_WAYLAND=1
    # X11(via Xwayland) clients need the cookie Mutter generated for this
    # session; without it every GLX app (glxgears) fails auth even though
    # DISPLAY is set correctly. Native-Wayland clients don't need this.
    xauth=$(ls "$rt"/.mutter-Xwaylandauth.* 2>/dev/null | head -1)
    [ -n "$xauth" ] && export XAUTHORITY="$xauth"
    return 0
}

# Long-lived containers standing in for the always-on postgres/valkey/mqtt/
# nginx instances a real container fleet runs, plus a containerised ROCm
# userspace for real rocBLAS calls. Started once and reused across the whole
# run — the fleet this mimics doesn't restart its databases every lap, and
# provisioning ROCm (installing rocblas, compiling the GEMM binary) is too
# slow to redo every lap.
CONTAINERS_NET=prf-net
PRF_CONTAINERS=(prf-pg prf-redis prf-mosquitto prf-nginx)
HSA_GFX=

container_up() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

setup_containers() {
    run "docker" || return 0
    # A prior run killed before teardown ran (e.g. SIGKILL) leaves
    # these stopped rather than absent; `docker run --name` then fails on the
    # name clash and the checks below silently treat that as "already up".
    docker ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null \
        | grep -E '^prf-(pg|redis|mosquitto|nginx)$' | xargs -r docker rm -f >/dev/null 2>&1 || true
    docker network inspect "$CONTAINERS_NET" >/dev/null 2>&1 \
        || docker network create "$CONTAINERS_NET" >/dev/null 2>&1 || true

    container_up prf-pg || \
        docker run -d --name prf-pg --network "$CONTAINERS_NET" \
            -e POSTGRES_PASSWORD=prf -e POSTGRES_HOST_AUTH_METHOD=trust \
            -p 15432:5432 postgres:18-alpine >/dev/null 2>&1 || true

    container_up prf-redis || \
        docker run -d --name prf-redis --network "$CONTAINERS_NET" \
            -p 16379:6379 valkey/valkey:9 >/dev/null 2>&1 || true

    container_up prf-mosquitto || \
        docker run -d --name prf-mosquitto --network "$CONTAINERS_NET" \
            -p 11883:1883 eclipse-mosquitto:latest sh -c \
            'printf "listener 1883 0.0.0.0\nallow_anonymous true\n" > /tmp/prf-mosq.conf && exec mosquitto -c /tmp/prf-mosq.conf' \
            >/dev/null 2>&1 || true

    # Host networking, so wrk reaches nginx's epoll loop over plain loopback
    # TCP rather than through docker-proxy, on IPv4 and IPv6. The 1 MiB file
    # takes the sendfile path; the index page the small-response path.
    container_up prf-nginx || \
        docker run -d --name prf-nginx --network host nginx:alpine sh -c \
            "printf 'server {\n    listen 18080;\n    listen [::]:18080;\n    root /usr/share/nginx/html;\n}\n' \
                 > /etc/nginx/conf.d/default.conf \
             && head -c 1048576 /dev/urandom > /usr/share/nginx/html/1m.bin \
             && exec nginx -g 'daemon off;'" >/dev/null 2>&1 || true

    docker pull -q alpine:latest >/dev/null 2>&1 || true

    if [ -e /dev/kfd ]; then
        local vid_gid render_gid gemm_src
        vid_gid=$(getent group video | cut -d: -f3)
        render_gid=$(getent group render | cut -d: -f3)
        docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx prf-rocm || \
            docker create --name prf-rocm --device=/dev/kfd --device=/dev/dri \
                ${vid_gid:+--group-add "$vid_gid"} ${render_gid:+--group-add "$render_gid"} \
                rocm/rocm-terminal:latest sleep infinity >/dev/null 2>&1 || true
        docker start prf-rocm >/dev/null 2>&1 || true
        if ! docker exec prf-rocm test -x /tmp/gemm >/dev/null 2>&1; then
            docker exec -u root prf-rocm bash -c 'apt-get update -qq \
                && { apt-get install -y -qq rocblas rocblas-dev || apt-get install -y -qq rocblas; }' \
                >/dev/null 2>&1 || true
            gemm_src=${AUTOFDO_GEMM_CPP:-/var/tmp/profile-gemm.cpp}
            [ -f "$gemm_src" ] && \
                docker cp "$gemm_src" prf-rocm:/tmp/gemm.cpp >/dev/null 2>&1
            docker exec prf-rocm bash -c 'hipcc -O2 /tmp/gemm.cpp -o /tmp/gemm -lrocblas' >/dev/null 2>&1 || true
        fi
        # Consumer APUs outside ROCm's support matrix have no precompiled
        # rocBLAS kernels. gfx1150 (Strix Point) runs the gfx1100 ones when
        # told to identify as that; AUTOFDO_HSA_GFX_VERSION sets it for any
        # other such GPU.
        ROCM_GFX=$(docker exec prf-rocm rocminfo 2>/dev/null | grep -om1 'gfx[0-9a-f]\+')
        HSA_GFX=${AUTOFDO_HSA_GFX_VERSION:-}
        [ -z "$HSA_GFX" ] && [ "$ROCM_GFX" = gfx1150 ] && HSA_GFX=11.0.0
    fi

    # pgbench tables, created once so the phase itself is steady-state OLTP.
    if container_up prf-pg; then
        local _
        for _ in $(seq 1 30); do
            docker exec prf-pg pg_isready -U postgres >/dev/null 2>&1 && break
            sleep 1
        done
        docker exec prf-pg pgbench -U postgres -i -q -s 20 postgres >/dev/null 2>&1 || true
    fi
}

# A C project of 400 translation units, each pulling in the usual libc
# headers: a real build reads headers through the page cache, runs the
# cc1/as/ld pipeline per file and writes objects with debug info, which a
# loop of one-line files does not.
CPROJ=/var/tmp/prf-cproj

setup_cproj() {
    run "python3" || return 0
    python3 - "$CPROJ" <<'PY'
import os, sys

root = sys.argv[1]
os.makedirs(os.path.join(root, "src"), exist_ok=True)
for n in range(400):
    with open(os.path.join(root, "src", f"u{n}.c"), "w") as fh:
        fh.write(f"""#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static double table[64];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

double unit_{n}(const char *s)
{{
    double acc = 0;
    pthread_mutex_lock(&lock);
    for (size_t i = 0; i < strlen(s); i++) {{
        table[i % 64] += sin((double)s[i] * {n + 1});
        acc += table[i % 64] / (1.0 + i);
    }}
    pthread_mutex_unlock(&lock);
    return acc;
}}
""")
with open(os.path.join(root, "src", "main.c"), "w") as fh:
    fh.write("int main(void) { return 0; }\n")
with open(os.path.join(root, "Makefile"), "w") as fh:
    fh.write("""OBJS := $(patsubst %.c,%.o,$(wildcard src/*.c))
prog: $(OBJS)
\t$(CC) -o $@ $^ -lm -lpthread
%.o: %.c
\t$(CC) -O2 -g -c -o $@ $<
clean:
\trm -f prog src/*.o
""")
PY
}

TONE=/var/tmp/prf-tone.wav

setup_media() {
    run "ffmpeg" || return 0
    timeout 20 ffmpeg -hide_banner -y -f lavfi -i "sine=frequency=440:duration=30" \
        -ar 48000 -ac 2 "$TONE" >/dev/null 2>&1 || true
}

teardown() {
    local f
    for f in "$PIDS"/*.pid; do
        [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null
    done
    rm -rf "$CPROJ" "$TONE"
    run "docker" || return 0
    # prf-rocm is not torn down: reinstalling rocblas and recompiling the
    # GEMM binary is slow, and it costs nothing idle between runs.
    docker rm -f "${PRF_CONTAINERS[@]}" >/dev/null 2>&1 || true
    docker network rm "$CONTAINERS_NET" >/dev/null 2>&1 || true
}

# Repeated clean builds of $CPROJ with <jobs> parallel jobs until <seconds>
# have passed.
build_loop() {
    local jobs=$1 end=$(( $(date +%s) + $2 ))
    while [ "$(date +%s)" -lt "$end" ]; do
        timeout 120 make -s -C "$CPROJ" -j"$jobs" >/dev/null 2>&1 || return 1
        make -s -C "$CPROJ" clean >/dev/null 2>&1
    done
}

audio_player() {
    if run "pw-play"; then echo pw-play
    elif run "paplay"; then echo paplay
    else return 1
    fi
}

phase_cpu() {
    say "cpu: parallel C build + thread churn"
    run "cc" && run "make" && [ -d "$CPROJ" ] || run "sysbench" || return 1

    # A parallel build is a heavy fork/exec + page cache + scheduler load;
    # repeated rounds for a sustained window instead of one burst that
    # finishes before the scheduler ever gets under real pressure.
    if run "cc" && run "make" && [ -d "$CPROJ" ]; then
        build_loop "$(nproc)" 80
    fi
    # Thread creation/teardown and mutex contention exercise the scheduler's
    # wakeup/preemption path directly, distinct from the compile loop above
    # (which is mostly independent processes, not shared-state threading).
    if run "sysbench"; then
        timeout 30 sysbench threads --threads=64 --time=20 run >/dev/null 2>&1 || true
    fi
}

phase_vm() {
    say "vm: page faults, mmap/munmap, brk, memfd, fork with mappings"
    run "stress-ng" || return 1
    # Every one of these is a kernel-side VM path that ordinary applications
    # hit constantly (allocator arenas and heap growth, JIT heaps, file
    # mappings, memfd buffers shared between Wayland clients and the
    # compositor) and that a userspace memory-bandwidth benchmark never
    # reaches after the first touch of each page. Not --madvise: it reads
    # /proc/self/smaps in its loop, so seq_printf formatting took over the
    # profile's hot set. Not --mremap, --mprotect or --vma either: each spends
    # half its time in one allocator or lock path.
    timeout 45 stress-ng --fault 2 --mmap 2 --brk 1 --memfd 1 --mmapfork 1 \
        --timeout 30s --quiet >/dev/null 2>&1 || true
}

phase_ipc() {
    say "ipc: pipes, futexes, switches, epoll/poll, sockets, timers, signals, fork/exec"
    run "stress-ng" || return 1
    # Event loops (timerfd, eventfd, poll) and signals are what every GUI
    # toolkit, runtime and service manager spends its idle-to-busy
    # transitions in, next to the classic pipe/futex/socket IPC.
    timeout 60 stress-ng --pipe 2 --futex 2 --switch 2 --epoll 1 --poll 1 \
        --sock 2 --sockpair 1 --udp 1 --timerfd 1 --eventfd 1 --signal 1 \
        --fork 2 --exec 2 \
        --timeout 45s --quiet >/dev/null 2>&1 || true
}

phase_memory_pressure() {
    say "memory: reclaim into swap inside a memory-capped cgroup"
    run "python3" && run "systemd-run" || return 1
    [ -n "$(swapon --noheadings 2>/dev/null)" ] || { say "memory: no swap configured, skipping"; return 1; }
    # A cgroup limit forces reclaim, zswap and swap-out just as global
    # pressure does, without the global OOM killer being able to pick the
    # perf recorder, a database container or the desktop session as its
    # victim. 3 GiB of compressible data into a 1 GiB cap pushes ~2 GiB out.
    timeout 120 systemd-run --user --scope --quiet \
        -p MemoryMax=1G -p MemorySwapMax=4G \
        python3 - <<'PY' >/dev/null 2>&1 || { say "memory: scoped run failed (no user systemd session, or too little swap), skipping"; return 1; }
import time

size = 3 << 30
buf = bytearray(size)
# Low-entropy 251-byte cycle: compressible, so zswap/zram spend on real data
# movement instead of an incompressible-noise benchmark that no real fleet runs.
chunk = bytes(i % 251 for i in range(1 << 20))
n = len(chunk)
for i in range(0, size, n):
    buf[i:i + n] = chunk
# Two more passes fault the swapped-out pages back in.
for _ in range(2):
    for i in range(0, size, 1 << 12):
        buf[i] ^= 1
time.sleep(2)
PY
}

phase_storage() {
    say "storage: direct/buffered, libaio/io_uring, fsync, tmpfs"
    run "fio" || return 1
    local tmp
    fio_run() { timeout $(( $1 + 30 )) fio --name=prf --time_based --runtime="$1" --group_reporting "${@:2}" >/dev/null 2>&1 || true; }

    # $HOME, not /home: /home itself is root:root 755, so writing there as a
    # regular user fails with EACCES before fio does any real I/O.
    if [ -d "$HOME" ]; then
        tmp=$(mktemp -d -p "$HOME" .prf-fio.XXXXXX)
        # Direct I/O through both submission engines: libaio is what older
        # databases use, io_uring what current ones and most runtimes do.
        fio_run 30 --directory="$tmp" --size=1g --bs=4k --rw=randread --direct=1 --iodepth=32 --ioengine=libaio
        fio_run 30 --directory="$tmp" --size=1g --bs=4k --rw=randread --direct=1 --iodepth=32 --ioengine=io_uring
        # Buffered writes with periodic fsync: page cache, dirty tracking,
        # writeback and journal commit, which almost every application that
        # saves anything goes through and direct I/O skips entirely.
        fio_run 30 --directory="$tmp" --size=1g --bs=16k --rw=randwrite --direct=0 --fsync=32 --ioengine=psync
        # Buffered sequential read after dropping the file's cached pages:
        # readahead and page-cache fill rather than a cache hit.
        fio_run 25 --directory="$tmp" --size=2g --bs=1m --rw=read --direct=0 --invalidate=1 --ioengine=psync
        fio_run 25 --directory="$tmp" --size=2g --bs=1m --rw=write --direct=1 --ioengine=libaio
        rm -rf "$tmp"
    fi
    # tmpfs is a distinct kernel path from the block-device fio above: pure
    # page cache + VFS, no block layer or storage driver at all.
    if [ -d /dev/shm ]; then
        tmp=$(mktemp -d -p /dev/shm)
        fio_run 20 --directory="$tmp" --size=512m --bs=4k --rw=randread --direct=0 --iodepth=32 --ioengine=libaio
        fio_run 20 --directory="$tmp" --size=512m --bs=4k --rw=randwrite --direct=0 --iodepth=32 --ioengine=io_uring
        rm -rf "$tmp"
    fi
}

phase_storage_multifs() {
    say "storage: fio across ext4/xfs/btrfs/f2fs/LUKS loopback images"
    run "fio" || return 1
    local fs mnt found=
    # "luks" is ext4 on dm-crypt: full-disk encryption is a common install
    # choice on laptops, and it puts the kernel's AES-XTS and dm paths under
    # every block read and write.
    for fs in ext4 xfs btrfs f2fs luks; do
        mnt="/mnt/fsdiv-$fs"
        # Set up once as root ahead of time; a host without it just has no
        # mountpoint here, so this quietly covers only what was prepared.
        mountpoint -q "$mnt" 2>/dev/null || continue
        found=1
        (cd "$mnt" && timeout 40 fio --name=prf --size=512m --bs=4k \
            --rw=randrw --rwmixread=70 --ioengine=libaio --direct=1 --iodepth=16 \
            --time_based --runtime=20 --group_reporting >/dev/null 2>&1) || true
        (cd "$mnt" && timeout 30 fio --name=prf --size=256m --bs=4k \
            --rw=randwrite --ioengine=psync --direct=0 --fsync=16 \
            --time_based --runtime=10 --group_reporting >/dev/null 2>&1) || true
        rm -f "$mnt"/prf* 2>/dev/null
    done
    [ -n "$found" ]
}

phase_storage_nvme_readonly() {
    say "storage: read-only fio against internal NVMe (never writes)"
    run "fio" || return 1
    local mnt target
    # The mount is x-systemd.automount (no root needed at runtime): it only
    # appears once something stats the mountpoint, which this triggers.
    [ -d /mnt/nvme-ro ] && stat /mnt/nvme-ro >/dev/null 2>&1
    mnt=$(mount | awk '/nvme0n1/ {print $3; exit}')
    [ -n "$mnt" ] || { say "storage: internal NVMe not mounted, skipping"; return 1; }
    target=$(find "$mnt" -maxdepth 4 -type f -size +200M -readable 2>/dev/null | head -1)
    [ -n "$target" ] || { say "storage: no suitable read target on internal NVMe, skipping"; return 1; }
    # --readonly is fio's own hard guard: the job refuses to run at all if its
    # rw mode could ever write, on top of --rw=randread already being read-only.
    timeout 60 fio --name=prf-nvme-ro --readonly --rw=randread --bs=4k \
        --ioengine=io_uring --direct=1 --iodepth=16 --filename="$target" \
        --size=200m --time_based --runtime=45 --group_reporting >/dev/null 2>&1 || true
}

phase_gpu_vaapi() {
    say "gpu: VAAPI h264+av1 encode, then decode the result back"
    run "ffmpeg" && [ -e /dev/dri/renderD128 ] || return 1
    # /var/tmp: the 1080p y4m is ~1.4 GB, which on a tmpfs /tmp would sit in
    # RAM for the length of the phase.
    local src=/var/tmp/prf-src.y4m enc out
    timeout 30 ffmpeg -hide_banner -y -f lavfi -i testsrc2=size=1920x1080:rate=30:duration=15 \
        -pix_fmt yuv420p "$src" >/dev/null 2>&1 || true
    for enc in h264_vaapi av1_vaapi; do
        out=/var/tmp/prf-$enc.mp4
        timeout 40 ffmpeg -hide_banner -y -vaapi_device /dev/dri/renderD128 \
            -i "$src" -vf 'format=nv12,hwupload' -c:v "$enc" -b:v 8M \
            "$out" >/dev/null 2>&1 || true
        # Decode target is a real hardware decoder, not the software
        # fallback: -hwaccel_output_format keeps frames on the GPU.
        [ -s "$out" ] && timeout 30 ffmpeg -hide_banner \
            -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 -hwaccel_output_format vaapi \
            -i "$out" -f null - >/dev/null 2>&1 || true
    done
    rm -f "$src" /var/tmp/prf-*_vaapi.mp4 2>/dev/null
}

phase_net_loopback() {
    say "network: iperf3 loopback, TCP over IPv4 and IPv6, UDP"
    run "iperf3" || return 1
    # Looping back is worthless for NIC drivers, but still exercises the TCP
    # and UDP stacks of both address families; phase_net_nic covers the NIC.
    iperf3_server loopback -p 5201
    local ok=
    timeout 35 iperf3 -c 127.0.0.1 -p 5201 -t 25 -P 4 >/dev/null 2>&1 && ok=1
    timeout 25 iperf3 -c ::1 -p 5201 -t 15 -P 2 >/dev/null 2>&1 && ok=1
    # Unthrottled small datagrams: the per-packet UDP path that QUIC, games
    # and voice calls live in, as opposed to TCP's large segments.
    timeout 20 iperf3 -c 127.0.0.1 -p 5201 -u -b 0 -l 1400 -t 10 >/dev/null 2>&1 && ok=1
    iperf3_stop loopback
    [ -n "$ok" ]
}

# The long loopback run goes concurrently with GPU work so the profile picks
# up softirq/IRQ paths overlapping a DRM submission, not only strictly serial
# driver activity. Its phase markers therefore cover both.
phase_gpu_and_loopback() {
    local netpid='' rc=1
    if run "iperf3"; then
        phase_net_loopback &
        netpid=$!
    fi
    phase_gpu_vaapi && rc=0
    if [ -n "$netpid" ] && wait "$netpid"; then
        PHASE_RAN[net_loopback]=1
    fi
    return "$rc"
}

phase_net_nic() {
    say "network: iperf3 over the NIC to ${AUTOFDO_NET_PEER:-<no peer>}"
    run "iperf3" || return 1
    [ -n "${AUTOFDO_NET_PEER:-}" ] || { say "network: AUTOFDO_NET_PEER unset, skipping"; return 1; }
    local host=${AUTOFDO_NET_PEER%:*} port=5203 ok=
    [ "$host" != "$AUTOFDO_NET_PEER" ] && port=${AUTOFDO_NET_PEER##*:}
    # Both directions: transmit (TSO, qdisc, driver TX ring) and receive
    # (IRQ, NAPI, GRO) are separate driver and stack paths, as is UDP.
    timeout 30 iperf3 -c "$host" -p "$port" -t 20 -P 2 >/dev/null 2>&1 && ok=1
    timeout 30 iperf3 -c "$host" -p "$port" -t 20 -P 2 -R >/dev/null 2>&1 && ok=1
    timeout 20 iperf3 -c "$host" -p "$port" -u -b 1G -l 1400 -t 10 >/dev/null 2>&1 && ok=1
    [ -n "$ok" ] || say "network: iperf3 server at $host:$port unreachable"
    [ -n "$ok" ]
}

phase_gpu_rocm() {
    say "gpu: ROCm GEMM (real rocBLAS via HIP, containerised)"
    run "docker" || return 1
    container_up prf-rocm || return 1
    docker exec prf-rocm test -x /tmp/gemm >/dev/null 2>&1 || return 1
    timeout 100 docker exec ${HSA_GFX:+-e HSA_OVERRIDE_GFX_VERSION="$HSA_GFX"} \
        prf-rocm /tmp/gemm 4096 90 >/dev/null 2>&1
}

phase_audio() {
    say "audio: playback through the sound server"
    desktop_ready || { say "audio: no live graphical session, skipping"; return 1; }
    local player
    player=$(audio_player) && [ -s "$TONE" ] || return 1
    # Encoding audio is pure userspace; playing it is what reaches the ALSA
    # and HDA/USB audio drivers, the part a kernel profile can use.
    timeout 40 "$player" "$TONE" >/dev/null 2>&1
}

phase_db() {
    say "db: pgbench OLTP + valkey churn"
    run "docker" || return 1
    local ok=

    if container_up prf-pg; then
        # TPC-B-like read/write transactions: WAL fsync, shared-buffer
        # contention and client/server socket round trips, the pattern a real
        # database spends its kernel time in.
        timeout 70 docker exec prf-pg pgbench -U postgres -c 8 -j 4 -T 45 postgres \
            >/dev/null 2>&1 && ok=1
    fi
    if run "redis-benchmark" && container_up prf-redis; then
        timeout 60 redis-benchmark -h 127.0.0.1 -p 16379 -q -n 150000 -c 30 >/dev/null 2>&1 && ok=1
    fi
    [ -n "$ok" ]
}

phase_web() {
    say "web: nginx epoll server under wrk (keep-alive, sendfile, connection churn, IPv6)"
    run "wrk" && container_up prf-nginx || return 1
    local url=http://127.0.0.1:18080 ok=
    timeout 25 wrk -t4 -c64 -d15s "$url/" >/dev/null 2>&1 && ok=1
    timeout 25 wrk -t4 -c32 -d15s "$url/1m.bin" >/dev/null 2>&1 && ok=1
    # A new TCP connection per request: accept, TIME_WAIT and port reuse.
    timeout 25 wrk -t4 -c64 -d15s -H 'Connection: close' "$url/" >/dev/null 2>&1 && ok=1
    timeout 25 wrk -t4 -c64 -d15s "http://[::1]:18080/" >/dev/null 2>&1 && ok=1
    [ -n "$ok" ]
}

phase_files() {
    say "files: small-file tree create, scan, cold read, git, copy, delete"
    run "python3" || return 1
    # 20k files of up to 16 KiB over 400 directories: the shape of a source
    # checkout or a document library, where path lookup, the dentry and inode
    # caches, inode allocation and directory operations dominate. Most
    # desktop and developer tools (IDEs, git, file managers, indexers, package
    # managers) spend their kernel time here rather than in bulk I/O. One
    # cycle takes seconds on fast storage, so cycles repeat for a fixed time.
    local end=$(( $(date +%s) + 75 )) ok=''
    while [ "$(date +%s)" -lt "$end" ]; do
        files_cycle && ok=1
    done
    [ -n "$ok" ]
}

files_cycle() {
    local tree
    tree=$(mktemp -d -p "$HOME" .prf-files.XXXXXX)
    timeout 60 python3 - "$tree" <<'PY' || { rm -rf "$tree"; return 1; }
import os, random, sys

root, rnd = sys.argv[1], random.Random()
blob = os.urandom(1 << 14)
for d in range(400):
    path = os.path.join(root, f"d{d // 20}", f"s{d}")
    os.makedirs(path, exist_ok=True)
    for f in range(50):
        with open(os.path.join(path, f"f{f}.txt"), "wb") as fh:
            fh.write(blob[:rnd.randrange(1 << 14)])
PY
    timeout 30 find "$tree" -type f -newer "$tree" >/dev/null 2>&1
    timeout 30 ls -lR "$tree" >/dev/null 2>&1
    timeout 30 grep -rq no-such-string "$tree" 2>/dev/null
    # Written back, then dropped from the page cache, so the second scan
    # reads cold through readahead instead of hitting cached pages.
    sync -f "$tree"
    timeout 30 python3 - "$tree" <<'PY'
import os, sys

for d, _, files in os.walk(sys.argv[1]):
    for f in files:
        fd = os.open(os.path.join(d, f), os.O_RDONLY)
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
        os.close(fd)
PY
    timeout 30 grep -rq no-such-string "$tree" 2>/dev/null
    if run "git"; then
        timeout 60 sh -c "cd '$tree' && git init -q && git add -A \\
            && git -c user.name=prf -c user.email=prf@localhost commit -qm tree \\
            && for i in 1 2 3 4 5; do git status --porcelain; done" >/dev/null 2>&1
    fi
    timeout 30 cp -a "$tree" "$tree.copy" 2>/dev/null
    mkdir -p "$tree.tar"
    timeout 30 sh -c "tar -cf - -C '$tree' . | tar -xf - -C '$tree.tar'" 2>/dev/null
    timeout 60 rm -rf "$tree" "$tree.copy" "$tree.tar"
}

phase_containers() {
    say "containers: run churn (namespaces, cgroups, overlayfs, veth, seccomp) + offline build"
    run "docker" || return 1
    local i ok='' ctx
    for i in $(seq 1 15); do
        timeout 20 docker run --rm --network none alpine:latest true >/dev/null 2>&1 && ok=1
    done
    # The default bridge adds a veth pair and NAT rules per container.
    for i in $(seq 1 10); do
        timeout 20 docker run --rm alpine:latest sh -c 'cat /proc/self/status /proc/net/dev' >/dev/null 2>&1 && ok=1
    done
    # A build with a context of hundreds of files and no network access:
    # context transfer, layer snapshots and overlayfs copy-up.
    if [ -d "$CPROJ/src" ]; then
        ctx=$(mktemp -d -p /var/tmp)
        cp -r "$CPROJ/src" "$ctx/src"
        printf 'FROM alpine:latest\nCOPY . /ctx\nRUN find /ctx -type f -exec cat {} + > /dev/null && tar -czf /tmp/ctx.tgz /ctx && cp -r /ctx /ctx2 && rm -rf /ctx2\n' \
            > "$ctx/Dockerfile"
        timeout 90 docker build -q --no-cache -t prf-build:latest "$ctx" >/dev/null 2>&1 && ok=1
        docker rmi prf-build:latest >/dev/null 2>&1
        rm -rf "$ctx"
    fi
    [ -n "$ok" ]
}

phase_mixed() {
    say "mixed: database, web, buffered I/O and a build at once"
    # Real machines run several workloads at once: lock contention, softirq
    # work landing in process context, preemption between unrelated tasks,
    # writeback competing with reads. Serial phases never produce that.
    local pids=() tmp=
    if run "docker" && container_up prf-pg; then
        timeout 60 docker exec prf-pg pgbench -U postgres -c 4 -j 2 -T 50 postgres >/dev/null 2>&1 &
        pids+=($!)
    fi
    if run "wrk" && container_up prf-nginx; then
        timeout 60 wrk -t2 -c32 -d50s http://127.0.0.1:18080/ >/dev/null 2>&1 &
        pids+=($!)
    fi
    if run "fio" && [ -d "$HOME" ]; then
        tmp=$(mktemp -d -p "$HOME" .prf-mixed.XXXXXX)
        timeout 70 fio --name=prf --directory="$tmp" --size=1g --bs=4k --rw=randrw --rwmixread=70 \
            --direct=0 --ioengine=psync --fsync=64 --time_based --runtime=50 >/dev/null 2>&1 &
        pids+=($!)
    fi
    if run "make" && [ -d "$CPROJ" ]; then
        build_loop "$(( $(nproc) / 2 + 1 ))" 50 &
        pids+=($!)
    fi
    [ "${#pids[@]}" -gt 0 ] && wait "${pids[@]}"
    [ -n "$tmp" ] && rm -rf "$tmp"
    [ "${#pids[@]}" -ge 2 ]
}

phase_mqtt() {
    say "mqtt: pub/sub burst"
    run "mosquitto_pub" && run "mosquitto_sub" || return 1
    container_up prf-mosquitto || return 1
    # A burst of 1000 short-lived publishers takes about two seconds, so bursts
    # repeat for a fixed time, like the files phase.
    local subpid i end=$(( $(date +%s) + 30 ))
    timeout 40 mosquitto_sub -h 127.0.0.1 -p 11883 -t 'prf/#' >/dev/null 2>&1 &
    subpid=$!
    while [ "$(date +%s)" -lt "$end" ]; do
        for i in $(seq 1 1000); do
            mosquitto_pub -h 127.0.0.1 -p 11883 -t "prf/sensor/$((i % 10))" -m "{\"v\":$i}" >/dev/null 2>&1 || true
        done
    done
    kill "$subpid" 2>/dev/null
    wait "$subpid" 2>/dev/null || true
}

phase_dns() {
    say "dns: resolver query burst"
    run "dig" || return 1
    # Mostly answered from the local resolver's cache, so 100 queries take
    # about a second; bursts repeat for a fixed time.
    local domains=(github.com wikipedia.org google.com cloudflare.com kernel.org) i end=$(( $(date +%s) + 20 ))
    while [ "$(date +%s)" -lt "$end" ]; do
        for i in $(seq 1 100); do
            dig +short +time=2 +tries=1 "${domains[$((i % ${#domains[@]}))]}" >/dev/null 2>&1 || true
        done
    done
}

phase_wireguard() {
    say "wireguard: encrypted tunnel traffic"
    ip link show wg0 >/dev/null 2>&1 || { say "wireguard: interface not present, skipping"; return 1; }
    run "iperf3" || return 1
    # The far end of the tunnel lives in the prf-wg namespace, with an iperf3
    # server kept running there (docs/PROFILING.md). Both ends in one
    # namespace would route over lo and never encrypt anything.
    local peer=${AUTOFDO_WG_PEER:-10.99.0.2}
    timeout 10 ping -c 20 -i 0.2 "$peer" >/dev/null 2>&1 || true
    timeout 50 iperf3 -c "$peer" -p 5202 -t 45 >/dev/null 2>&1
}

phase_desktop() {
    say "desktop: windowed GL/Vulkan render with audio + compositor churn"
    desktop_ready || { say "desktop: no live graphical session, skipping"; return 1; }
    local ok='' wid player audiopid=

    if run "glxgears"; then
        timeout 30 glxgears >/dev/null 2>&1; ok=1
    fi
    if run "vkcube"; then
        timeout 30 vkcube >/dev/null 2>&1; ok=1
    fi
    if run "vkmark"; then
        # A Vulkan benchmark suite: a different API and driver path from GL
        # and VAAPI. Not glmark2, which is unstable under Xwayland/GLX. Sound
        # plays alongside, as in a game: GPU submission and fence waits
        # interleaved with audio period interrupts and their wakeups.
        if player=$(audio_player) && [ -s "$TONE" ]; then
            (for _ in 1 2 3; do timeout 40 "$player" "$TONE"; done) >/dev/null 2>&1 &
            audiopid=$!
        fi
        timeout 75 vkmark >/dev/null 2>&1; ok=1
        [ -n "$audiopid" ] && { kill "$audiopid" 2>/dev/null; wait "$audiopid" 2>/dev/null; }
    fi
    if run "wmctrl" && run "xdotool"; then
        wid=$(xdotool getactivewindow 2>/dev/null) || wid=
        if [ -n "$wid" ]; then
            for _ in $(seq 1 15); do
                xdotool windowsize "$wid" 640 480 2>/dev/null
                sleep 0.3
                xdotool windowsize "$wid" 1280 800 2>/dev/null
                sleep 0.3
            done
            ok=1
        fi
    fi
    [ -n "$ok" ]
}

phase_video() {
    say "video: mpv hw-decoded local clip playback"
    desktop_ready || { say "video: no live graphical session, skipping"; return 1; }
    run "mpv" && run "ffmpeg" || return 1
    local src=/var/tmp/prf-video-src.mp4 rc=1
    timeout 40 ffmpeg -hide_banner -y -f lavfi -i testsrc2=size=1920x1080:rate=30:duration=45 \
        -f lavfi -i sine=frequency=440:duration=45 \
        -pix_fmt yuv420p -c:v libx264 -preset ultrafast -c:a aac \
        -shortest "$src" >/dev/null 2>&1 || true
    if [ -s "$src" ]; then
        # Real window, not --no-video: decode target is the display
        # compositor, not an offscreen surface.
        timeout 55 mpv --hwdec=vaapi --geometry=1280x720 \
            --really-quiet --no-terminal "$src" >/dev/null 2>&1
        rc=0
    fi
    rm -f "$src"
    return "$rc"
}

phase_browser() {
    say "browser: selenium multi-site load"
    desktop_ready || { say "browser: no live graphical session, skipping"; return 1; }
    "$SELENIUM_PY" -c 'import selenium' >/dev/null 2>&1 || { say "browser: no selenium interpreter, skipping"; return 1; }
    run "firefox" || return 1

    # A spread of real, stable, bot-tolerant sites: text-heavy, code, WebGL,
    # a live video stream, and a real speedtest, so the profile picks up
    # JS/layout/canvas/video-decode/sustained-network paths a single page
    # type would not. Each entry is "url:seconds"; a page needs more than a
    # couple of seconds to matter for a video/stream/test.
    local sites=(
        "https://en.wikipedia.org/wiki/Special:Random:15"
        "https://github.com/torvalds/linux:15"
        "https://news.ycombinator.com:15"
        "https://webglsamples.org/aquarium/aquarium.html:20"
        "https://www.twitch.tv:30"
        "https://fast.com:40"
    )
    local entry url dwell
    for entry in "${sites[@]}"; do
        stopping && break
        url=${entry%:*}
        dwell=${entry##*:}
        timeout "$((dwell + 15))" "$SELENIUM_PY" - "$url" "$dwell" <<'PY' >/dev/null 2>&1 || true
import os, sys, time
from selenium import webdriver
from selenium.webdriver.firefox.options import Options

opts = Options()
# Ubuntu's /usr/bin/firefox is a snap wrapper script; geckodriver refuses it
# as "not a Firefox executable", so point straight at the binary inside the
# snap mount instead.
snap_ff = "/snap/firefox/current/usr/lib/firefox/firefox"
if os.path.exists(snap_ff):
    opts.binary_location = snap_ff
opts.add_argument("-width=1280")
opts.add_argument("-height=800")

driver = webdriver.Firefox(options=opts)
try:
    url, dwell = sys.argv[1], float(sys.argv[2])
    driver.get(url)
    time.sleep(3)
    remaining = dwell - 3
    if remaining > 0:
        # A long dwell means "let a stream/test run", not "scroll a page".
        if dwell >= 15:
            time.sleep(remaining)
        else:
            steps = max(1, int(remaining / 0.5))
            for _ in range(steps):
                driver.execute_script("window.scrollBy(0, 400)")
                time.sleep(0.5)
finally:
    driver.quit()
PY
    done
}

# Ran/skipped tracking: phases return 0 when their workload ran, non-zero when
# it could not. The final summary names what the profile actually contains —
# and what it does not, since each phase silently (by design) no-ops without
# its tools. profile-release.sh gates on it.
declare -A PHASE_RAN
ALL_PHASES=(
    cpu vm ipc memory_pressure storage files storage_multifs
    storage_nvme_readonly gpu_vaapi net_nic gpu_rocm db web mixed mqtt dns
    wireguard containers desktop audio video browser
)
read -ra PLAN <<< "${AUTOFDO_PHASES:-${ALL_PHASES[*]}}"
for name in "${PLAN[@]}"; do
    declare -F "phase_$name" >/dev/null || { say "unknown phase '$name' in AUTOFDO_PHASES"; exit 1; }
done
# net_loopback runs inside the gpu_vaapi slot, concurrently with it.
PHASES=("${PLAN[@]}")
[[ " ${PLAN[*]} " == *" gpu_vaapi "* ]] && PHASES+=(net_loopback)

ph() {
    local name=$1 fn=phase_$1
    [ "$name" = gpu_vaapi ] && fn=phase_gpu_and_loopback
    stopping && return 0
    echo "$(mono) start $name" >> "$STATE/phases"
    if "$fn"; then
        PHASE_RAN[$name]=1
    fi
    echo "$(mono) end $name" >> "$STATE/phases"
}

phase_summary() {
    say "phase summary:"
    local name
    for name in "${PHASES[@]}"; do
        if [ -n "${PHASE_RAN[$name]:-}" ]; then
            echo "    ok   $name"
        else
            echo "    skip $name"
        fi
    done
}

# STRICT=1 fails fast when core training tools are absent; otherwise the run
# records an hour of near-idle load.
STRICT=${STRICT:-0}
strict_check() {
    local tools=(cc make sysbench stress-ng fio python3 systemd-run ffmpeg iperf3
                 dig git docker mosquitto_pub mosquitto_sub redis-benchmark wrk) t missing=()
    for t in "${tools[@]}"; do
        run "$t" || missing+=("$t")
    done
    if desktop_ready; then
        for t in glxgears vkcube vkmark wmctrl xdotool mpv firefox; do
            run "$t" || missing+=("$t")
        done
        run "pw-play" || run "paplay" || missing+=("pw-play|paplay")
    fi
    [ "${#missing[@]}" -eq 0 ] || { say "strict: missing tools: ${missing[*]}"; exit 1; }
    say "strict: all core training tools present"
}

# Before setup: a host missing tools should fail in seconds, not after
# minutes of image pulls and a rocBLAS install.
[ "$STRICT" = 1 ] && strict_check

trap teardown EXIT
trap 'exit 143' TERM INT HUP

say "setting up containers, build tree and media"
setup_containers
setup_cproj
setup_media
touch "$STATE/ready"
say "setup done, load running until $STATE/stop exists (max ${TOTAL}s)"

lap=0
while ! stopping; do
    lap=$((lap + 1))
    # Start each lap 7 phases further on, so a recording that ends mid-lap
    # cuts short different phases each time rather than always the last ones.
    offset=$(( (lap - 1) * 7 % ${#PLAN[@]} ))
    say "lap $lap, starting at ${PLAN[$offset]}"
    for i in $(seq 0 $(( ${#PLAN[@]} - 1 ))); do
        name=${PLAN[$(( (offset + i) % ${#PLAN[@]} ))]}
        # Every other lap only: every lap would let reclaim and swap churn
        # crowd the steady-state mix out of sample weight.
        [ "$name" = memory_pressure ] && [ "${#PLAN[@]}" -gt 1 ] && (( lap % 2 )) && continue
        ph "$name"
    done
done
phase_summary
say "load complete"
