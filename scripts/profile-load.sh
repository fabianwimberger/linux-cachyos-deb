#!/usr/bin/env bash
# Put a realistic mixed workload on the profiling host so the AutoFDO profile
# captures the drivers and userspace paths real users hit, not an idle kernel.
# Each phase is bounded and skipped if its tool is missing, so this runs on any
# instrumented host.
#
#   scripts/profile-load.sh <duration-seconds>
#
# Phases are dialled to roughly fill <duration> and, loosely, stand in for a
# real always-on container fleet (docker/postgres/valkey/mqtt/traefik/dns/
# wireguard/gitea-ci/paperless/immich/frigate-style workloads), plus CPU,
# memory, storage across several filesystem types, GPU (VAAPI + ROCm), audio
# codecs, desktop and browser. It is meant to be driven by scripts/profile.sh,
# which guarantees the instrumented kernel underneath.
#
# This profiles the *kernel*, not the applications, so a synthetic stand-in
# that drives the same ioctls/syscalls (docker+postgres instead of the real
# paperless-ngx stack, say) is enough — see scripts/profile-report.sh for why
# an untrained function is simply cold, never penalised. ROCm is the one
# exception worth naming: it runs the real rocBLAS library through HIP inside
# a containerised ROCm userspace (no host install), because the reference
# machine's Frigate container drives ROCm the same way, and a GEMM through
# rocBLAS submits to /dev/kfd the same way real inference does.
#
# Each phase is a single, longer pass rather than many short ones — a handful
# of long loops of the whole set beats many short ones for how representative
# the profile ends up, since short bursts are dominated by process/driver
# setup overhead rather than steady-state execution.
#
# The host needs the profile prerequisites (perf, kptr_restrict=0,
# perf_event_paranoid<=0) which profile.sh already checks.
#
# The desktop/video/audio/browser phases only run when a live graphical
# session is present (an Ubuntu Desktop target with someone logged in) — they
# exercise the compositor/display stack that the headless VAAPI phase's
# render-only encode never touches. Headless targets like a server install
# skip them.
#
# The multi-filesystem storage phase, the read-only internal-NVMe phase and
# the wireguard phase depend on one-time root setup that isn't part of this
# script (loopback fs images under /mnt/fsdiv-*, a read-only mount at
# /mnt/nvme-ro, a wg0/wg1 tunnel pair) and no-op if that setup hasn't been
# done on this host, so this still runs unmodified anywhere. The ROCm GEMM phase similarly needs
# a gemm.cpp (AUTOFDO_GEMM_CPP, default $HOME/autofdo-load/gemm.cpp — a small
# HIP/rocBLAS GEMM benchmark, not shipped here) to compile inside the ROCm
# container; without it, that phase keeps retrying the compile every lap and
# never runs the actual benchmark.
set -uo pipefail

TOTAL=${1:-600}
END=$(( $(date +%s) + TOTAL ))
run() { command -v "$1" >/dev/null 2>&1; }

say() { printf '>> [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# The interpreter with selenium installed, if any; a plain system python3
# almost never has it, so this is expected to miss on most hosts.
SELENIUM_PY=${AUTOFDO_SELENIUM_PY:-}
[ -n "$SELENIUM_PY" ] || SELENIUM_PY="$HOME/autofdo-load/.venv/bin/python3"
[ -x "$SELENIUM_PY" ] || SELENIUM_PY=python3

# Below phases need a live compositor to reach the display stack at all;
# without one (headless, or nobody logged in) they no-op rather than fail.
desktop_ready() {
    local rt="/run/user/$(id -u)" xauth
    [ -S "$rt/wayland-0" ] || return 1
    export XDG_RUNTIME_DIR="$rt" WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 MOZ_ENABLE_WAYLAND=1
    # X11(via Xwayland) clients need the cookie Mutter generated for this
    # session; without it every GLX app (glxgears) fails auth even though
    # DISPLAY is set correctly. Native-Wayland clients don't need this.
    xauth=$(ls "$rt"/.mutter-Xwaylandauth.* 2>/dev/null | head -1)
    [ -n "$xauth" ] && export XAUTHORITY="$xauth"
    return 0
}

# Long-lived containers standing in for the always-on postgres/valkey/mqtt
# instances a real container fleet runs, plus a containerised ROCm userspace
# for real rocBLAS calls. Started once and reused across the whole run — the
# fleet this mimics doesn't restart its databases every lap, and provisioning
# ROCm (installing rocblas, compiling the GEMM binary) is too slow to redo
# every lap.
CONTAINERS_NET=prf-net

setup_containers() {
    run "docker" || return 0
    # A prior run killed before teardown_containers ran (e.g. SIGKILL) leaves
    # these stopped rather than absent; `docker run --name` then fails on the
    # name clash and the checks below silently treat that as "already up".
    # Only called once, before the load loop starts, so it's safe to always
    # clear stale exited containers here.
    docker ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null \
        | grep -E '^prf-(pg|redis|mosquitto)$' | xargs -r docker rm -f >/dev/null 2>&1 || true
    docker network inspect "$CONTAINERS_NET" >/dev/null 2>&1 \
        || docker network create "$CONTAINERS_NET" >/dev/null 2>&1 || true

    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx prf-pg || \
        docker run -d --name prf-pg --network "$CONTAINERS_NET" \
            -e POSTGRES_PASSWORD=prf -e POSTGRES_HOST_AUTH_METHOD=trust \
            -p 15432:5432 postgres:18-alpine >/dev/null 2>&1 || true

    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx prf-redis || \
        docker run -d --name prf-redis --network "$CONTAINERS_NET" \
            -p 16379:6379 valkey/valkey:9 >/dev/null 2>&1 || true

    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx prf-mosquitto || \
        docker run -d --name prf-mosquitto --network "$CONTAINERS_NET" \
            -p 11883:1883 eclipse-mosquitto:latest sh -c \
            'printf "listener 1883 0.0.0.0\nallow_anonymous true\n" > /tmp/prf-mosq.conf && exec mosquitto -c /tmp/prf-mosq.conf' \
            >/dev/null 2>&1 || true

    if run "docker" && [ -e /dev/kfd ]; then
        local vid_gid render_gid
        vid_gid=$(getent group video | cut -d: -f3)
        render_gid=$(getent group render | cut -d: -f3)
        docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx prf-rocm || \
            docker create --name prf-rocm --device=/dev/kfd --device=/dev/dri \
                ${vid_gid:+--group-add "$vid_gid"} ${render_gid:+--group-add "$render_gid"} \
                rocm/rocm-terminal:latest sleep infinity >/dev/null 2>&1 || true
        docker start prf-rocm >/dev/null 2>&1 || true
        # gfx1150 (Strix Point iGPUs) has no precompiled rocBLAS Tensile
        # kernels; HSA_OVERRIDE_GFX_VERSION makes it identify as the
        # closest supported RDNA3 target (gfx1100) at runtime, a standard
        # workaround for consumer APUs outside ROCm's official matrix.
        if ! docker exec prf-rocm test -x /tmp/gemm >/dev/null 2>&1; then
            docker exec -u root prf-rocm bash -c 'apt-get update -qq && apt-get install -y -qq rocblas' \
                >/dev/null 2>&1 || true
            gemm_src=${AUTOFDO_GEMM_CPP:-$HOME/autofdo-load/gemm.cpp}
            [ -f "$gemm_src" ] && \
                docker cp "$gemm_src" prf-rocm:/tmp/gemm.cpp >/dev/null 2>&1
            docker exec prf-rocm bash -c 'hipcc -O2 /tmp/gemm.cpp -o /tmp/gemm -lrocblas' >/dev/null 2>&1 || true
        fi
    fi

    sleep 5
}

teardown_containers() {
    run "docker" || return 0
    # prf-rocm is not torn down: reinstalling rocblas and recompiling the
    # GEMM binary is slow, and it costs nothing idle between runs.
    docker rm -f prf-pg prf-redis prf-mosquitto >/dev/null 2>&1 || true
    docker network rm "$CONTAINERS_NET" >/dev/null 2>&1 || true
}

phase_storage_nvme_readonly() {
    say "storage: read-only fio against internal NVMe (never writes)"
    run "fio" || return 0
    local mnt target
    # The mount is x-systemd.automount (no root needed at runtime): it only
    # appears once something stats the mountpoint, which this triggers.
    [ -d /mnt/nvme-ro ] && stat /mnt/nvme-ro >/dev/null 2>&1
    mnt=$(mount | awk '/nvme0n1/ {print $3; exit}')
    [ -n "$mnt" ] || { say "storage: internal NVMe not mounted, skipping"; return; }
    target=$(find "$mnt" -maxdepth 4 -type f -size +200M -readable 2>/dev/null | head -1)
    [ -n "$target" ] || { say "storage: no suitable read target on internal NVMe, skipping"; return; }
    # --readonly is fio's own hard guard: the job refuses to run at all if its
    # rw mode could ever write, on top of --rw=randread already being read-only.
    timeout 60 fio --name=prf-nvme-ro --readonly --rw=randread --bs=4k \
        --ioengine=libaio --direct=1 --iodepth=16 --filename="$target" \
        --size=200m --time_based --runtime=45 --group_reporting >/dev/null 2>&1 || true
}

phase_cpu() {
    say "cpu: parallel compile + openssl"
    # A parallel kernel/module-style compile is a heavy CPU + syscall +
    # scheduler load; repeated rounds for a sustained window instead of one
    # burst that finishes before the scheduler ever gets under real pressure.
    if run "cc"; then
        tmp=$(mktemp -d)
        (timeout 90 bash -c "
            end=\$(( \$(date +%s) + 85 ))
            while [ \$(date +%s) -lt \$end ]; do
                seq 1 \$(nproc) | xargs -P \$(nproc) -I{} sh -c 'cd $tmp && printf \"int f{}(){return {};}\" > f{}.c && cc -O2 -c f{}.c'
            done
        ") 2>/dev/null || true
        rm -rf "$tmp"
    fi
    if run "openssl"; then
        timeout 35 openssl speed -seconds 25 sha256 >/dev/null 2>&1 || true
    fi
    # Thread creation/teardown and mutex contention exercise the scheduler's
    # wakeup/preemption path directly, distinct from the compile loop above
    # (which is mostly independent processes, not shared-state threading).
    if run "sysbench"; then
        timeout 30 sysbench threads --threads=64 --time=20 run >/dev/null 2>&1 || true
    fi
}

phase_memory() {
    say "memory: stream-like copy band"
    if run "python3"; then
        timeout 90 python3 - <<'PY' 2>/dev/null || true
n = 200_000_000  # ~1.6 GiB
a = bytearray(n)
for _ in range(24):
    a[:] = a[::-1]
PY
    fi
    if run "sysbench"; then
        timeout 70 sysbench memory run --threads=8 --time=60 >/dev/null 2>&1 || true
    fi
}

phase_memory_pressure() {
    say "memory: fill RAM to force zram swap-out (zstd compress/decompress)"
    run "python3" || return 0
    swapon --show 2>/dev/null | grep -qi zram || { say "memory: no zram swap configured, skipping"; return; }
    # Total RAM plus a fixed overflow, not a fraction of it: with most of
    # physical RAM typically free, allocating even 90% of total RAM still
    # comfortably fits without swapping anything -- reclaim only kicks in
    # once demand actually exceeds physical RAM. The overflow amount is
    # what's actually forced into swap; kept well inside available swap
    # capacity (zram plus any disk swap) so this can't run the system out
    # of memory.
    timeout 90 python3 - <<'PY' 2>/dev/null || true
import os, time

total = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
overflow = 4 * (1 << 30)  # 4 GiB beyond physical RAM
target = total + overflow

buf = bytearray(target)
chunk = os.urandom(1 << 20)  # 1 MiB of real entropy, tiled to fill the buffer
n = len(chunk)
for i in range(0, len(buf), n):
    end = min(i + n, len(buf))
    buf[i:end] = chunk[: end - i]

time.sleep(8)  # held resident so the kernel has real pressure to react to
PY
}

phase_storage() {
    say "storage: fio on the home filesystem"
    # $HOME, not /home: /home itself is root:root 755, so writing there as a
    # regular user fails with EACCES before fio does any real I/O.
    if run "fio" && [ -d "$HOME" ]; then
        (cd "$HOME" && timeout 80 fio --name=prf --size=1g --bs=4k \
            --rw=randread --ioengine=libaio --direct=1 --iodepth=32 \
            --time_based --runtime=60 --group_reporting >/dev/null 2>&1) || true
        (cd "$HOME" && timeout 70 fio --name=prf --size=2g --bs=1m \
            --rw=write --ioengine=libaio --direct=1 \
            --time_based --runtime=45 --group_reporting >/dev/null 2>&1) || true
        rm -rf "$HOME"/prf* 2>/dev/null
    fi
    # tmpfs is a distinct kernel path from the direct-I/O block-device fio
    # above: pure page cache + VFS, no block layer or storage driver at all.
    if run "fio" && [ -d /dev/shm ]; then
        tmp=$(mktemp -d -p /dev/shm)
        (cd "$tmp" && timeout 50 fio --name=prf --size=512m --bs=4k \
            --rw=randread --ioengine=libaio --direct=0 --iodepth=32 \
            --time_based --runtime=20 --group_reporting >/dev/null 2>&1) || true
        (cd "$tmp" && timeout 50 fio --name=prf --size=512m --bs=4k \
            --rw=randwrite --ioengine=libaio --direct=0 --iodepth=32 \
            --time_based --runtime=20 --group_reporting >/dev/null 2>&1) || true
        rm -rf "$tmp"
    fi
}

phase_storage_multifs() {
    say "storage: fio across xfs/btrfs/f2fs loopback images (external disk only)"
    run "fio" || return 0
    local fs mnt
    for fs in xfs btrfs f2fs; do
        mnt="/mnt/fsdiv-$fs"
        # Set up once as root ahead of time; a host without it just has no
        # mountpoint here, so this quietly covers only what was prepared.
        mountpoint -q "$mnt" 2>/dev/null || continue
        (cd "$mnt" && timeout 60 fio --name=prf --size=512m --bs=4k \
            --rw=randrw --rwmixread=70 --ioengine=libaio --direct=1 --iodepth=16 \
            --time_based --runtime=40 --group_reporting >/dev/null 2>&1) || true
        rm -f "$mnt"/prf* 2>/dev/null
    done
}

phase_gpu_vaapi() {
    say "gpu: VAAPI h264+av1 encode, then decode the result back"
    if run "ffmpeg" && [ -e /dev/dri/renderD128 ]; then
        src=/tmp/prf-src.y4m
        timeout 30 ffmpeg -hide_banner -f lavfi -i testsrc2=size=1920x1080:rate=30:duration=15 \
            -pix_fmt yuv420p "$src" >/dev/null 2>&1 || true
        for enc in h264_vaapi av1_vaapi; do
            out=/tmp/prf-$enc.mp4
            timeout 40 ffmpeg -hide_banner -vaapi_device /dev/dri/renderD128 \
                -i "$src" -vf 'format=nv12,hwupload' -c:v "$enc" -b:v 8M \
                "$out" >/dev/null 2>&1 || true
            # Decode target is a real hardware decoder, not the software
            # fallback: -hwaccel_output_format keeps frames on the GPU.
            [ -s "$out" ] && timeout 30 ffmpeg -hide_banner \
                -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 -hwaccel_output_format vaapi \
                -i "$out" -f null - >/dev/null 2>&1 || true
        done
        rm -f "$src" /tmp/prf-*.mp4 2>/dev/null
    fi
}

phase_gpu_rocm() {
    say "gpu: ROCm GEMM (real rocBLAS via HIP, containerised — matches Frigate's ROCm path)"
    run "docker" || return 0
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx prf-rocm || return 0
    docker exec prf-rocm test -x /tmp/gemm >/dev/null 2>&1 || return 0
    timeout 100 docker exec -e HSA_OVERRIDE_GFX_VERSION=11.0.0 prf-rocm /tmp/gemm 4096 90 >/dev/null 2>&1 || true
}

phase_audio() {
    say "audio: opus + aac encode/decode"
    run "ffmpeg" || return 0
    tmp=$(mktemp -d)
    timeout 20 ffmpeg -hide_banner -f lavfi -i "sine=frequency=440:duration=30" \
        -f lavfi -i "sine=frequency=880:duration=30" -filter_complex amix=inputs=2 \
        -ar 48000 "$tmp/src.wav" >/dev/null 2>&1 || true
    if [ -s "$tmp/src.wav" ]; then
        timeout 20 ffmpeg -hide_banner -i "$tmp/src.wav" -c:a libopus -b:a 128k "$tmp/out.opus" >/dev/null 2>&1 || true
        timeout 20 ffmpeg -hide_banner -i "$tmp/src.wav" -c:a aac -b:a 192k "$tmp/out.aac" >/dev/null 2>&1 || true
        [ -s "$tmp/out.opus" ] && timeout 15 ffmpeg -hide_banner -i "$tmp/out.opus" -f null - >/dev/null 2>&1 || true
        [ -s "$tmp/out.aac" ] && timeout 15 ffmpeg -hide_banner -i "$tmp/out.aac" -f null - >/dev/null 2>&1 || true
    fi
    rm -rf "$tmp"
}

phase_db() {
    say "db: postgres + valkey query churn"
    if run "docker" && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx prf-pg; then
        for _ in 1 2 3; do
            timeout 30 docker exec prf-pg psql -U postgres -c \
                "CREATE TABLE IF NOT EXISTS t(i serial, v text);
                 INSERT INTO t(v) SELECT md5(random()::text) FROM generate_series(1,30000);
                 SELECT count(*) FROM t;
                 DELETE FROM t WHERE i < (SELECT COALESCE(max(i),0) - 30000 FROM t);" \
                >/dev/null 2>&1 || true
        done
    fi
    if run "redis-benchmark" && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx prf-redis; then
        timeout 60 redis-benchmark -h 127.0.0.1 -p 16379 -q -n 150000 -c 30 >/dev/null 2>&1 || true
    fi
}

phase_mqtt() {
    say "mqtt: pub/sub burst"
    run "mosquitto_pub" && run "mosquitto_sub" || return 0
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx prf-mosquitto || return 0
    timeout 60 mosquitto_sub -h 127.0.0.1 -p 11883 -t 'prf/#' -C 1000 >/dev/null 2>&1 &
    subpid=$!
    for i in $(seq 1 1000); do
        mosquitto_pub -h 127.0.0.1 -p 11883 -t "prf/sensor/$((i % 10))" -m "{\"v\":$i}" >/dev/null 2>&1 || true
    done
    wait "$subpid" 2>/dev/null || true
}

phase_proxy_tls() {
    say "proxy: TLS handshake + request churn"
    run "openssl" || return 0
    tmp=$(mktemp -d)
    openssl req -x509 -newkey rsa:2048 -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
        -days 1 -nodes -subj "/CN=prf" >/dev/null 2>&1 || { rm -rf "$tmp"; return; }
    openssl s_server -quiet -cert "$tmp/cert.pem" -key "$tmp/key.pem" -accept 18443 >/dev/null 2>&1 &
    spid=$!
    sleep 1
    for i in $(seq 1 150); do
        timeout 2 openssl s_client -quiet -connect 127.0.0.1:18443 </dev/null >/dev/null 2>&1 || true
    done
    kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
    rm -rf "$tmp"
}

phase_dns() {
    say "dns: resolver query burst"
    run "dig" || return 0
    local domains=(github.com wikipedia.org google.com cloudflare.com kernel.org) i
    for i in $(seq 1 100); do
        dig +short +time=2 +tries=1 "${domains[$((i % ${#domains[@]}))]}" >/dev/null 2>&1 || true
    done
}

phase_wireguard() {
    say "wireguard: encrypted tunnel traffic"
    ip link show wg0 >/dev/null 2>&1 || { say "wireguard: interface not present, skipping"; return; }
    # The peer address of a locally set-up wg0/wg1 loopback tunnel pair;
    # override for a different tunnel layout.
    local peer=${AUTOFDO_WG_PEER:-10.99.0.2}
    timeout 10 ping -c 20 -i 0.2 "$peer" >/dev/null 2>&1 || true
    if run "iperf3"; then
        iperf3 -s -D -B "$peer" -p 5202 >/dev/null 2>&1
        sleep 1
        timeout 50 iperf3 -c "$peer" -p 5202 -t 45 >/dev/null 2>&1 || true
        pkill -f "iperf3 -s -D -B $peer" 2>/dev/null || true
    fi
}

phase_ci_build() {
    say "ci: git clone + docker build"
    run "git" && run "docker" || return 0
    tmp=$(mktemp -d)
    timeout 30 git clone --quiet --depth 1 \
        https://github.com/fabianwimberger/linux-cachyos-deb.git "$tmp/repo" >/dev/null 2>&1 \
        || { rm -rf "$tmp"; return; }
    cat > "$tmp/repo/Dockerfile.prf" <<'EOF'
FROM alpine:latest
RUN apk add --no-cache bash
COPY . /src
RUN find /src -name '*.sh' | xargs -r wc -l
EOF
    timeout 60 docker build --quiet --no-cache -f "$tmp/repo/Dockerfile.prf" -t prf-ci-build:latest "$tmp/repo" \
        >/dev/null 2>&1 || true
    docker rmi prf-ci-build:latest >/dev/null 2>&1 || true
    rm -rf "$tmp"
}

phase_document() {
    say "document: pandoc convert + tesseract OCR"
    tmp=$(mktemp -d)
    for i in 1 2 3 4 5; do
        if run "pandoc"; then
            printf '# Report %s\n\nGenerated for AutoFDO load %s.\n\n- item one\n- item two\n' \
                "$i" "$(date)" > "$tmp/doc.md"
            # PDF output needs a LaTeX/wkhtmltopdf engine that isn't installed
            # by default; HTML exercises the same conversion path without that.
            timeout 15 pandoc "$tmp/doc.md" -o "$tmp/doc.html" --standalone >/dev/null 2>&1 || true
        fi
        if run "convert" && run "tesseract"; then
            convert -size 800x200 xc:white -pointsize 32 -fill black \
                -annotate +20+100 "AutoFDO load $(date +%s)-$i" "$tmp/text.png" >/dev/null 2>&1 || true
            [ -f "$tmp/text.png" ] && timeout 15 tesseract "$tmp/text.png" "$tmp/text-out" >/dev/null 2>&1 || true
        fi
    done
    rm -rf "$tmp"
}

phase_media_index() {
    say "media: synthetic photo-library indexing"
    run "ffmpeg" && run "convert" || return 0
    tmp=$(mktemp -d)
    timeout 60 ffmpeg -hide_banner -f lavfi -i "mandelbrot=size=1600x1200:rate=2" \
        -frames:v 60 "$tmp/img-%03d.jpg" >/dev/null 2>&1 || true
    for f in "$tmp"/img-*.jpg; do
        [ -f "$f" ] || continue
        convert "$f" -resize 200x200 -strip "${f%.jpg}-thumb.jpg" >/dev/null 2>&1 || true
        identify "$f" >/dev/null 2>&1 || true
    done
    rm -rf "$tmp"
}

phase_desktop() {
    say "desktop: windowed GL/Vulkan render + compositor churn"
    desktop_ready || { say "desktop: no live graphical session, skipping"; return; }

    if run "glxgears"; then
        timeout 60 glxgears >/dev/null 2>&1 || true
    fi
    if run "vkcube"; then
        timeout 45 vkcube >/dev/null 2>&1 || true
    fi
    if run "vkmark"; then
        # A real Vulkan benchmark suite, not just a spinning cube — a
        # different API/driver path from vkcube and VAAPI above. (glmark2
        # was dropped: unstable under Xwayland/GLX on some hosts.)
        timeout 90 vkmark >/dev/null 2>&1 || true
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
        fi
    fi
}

phase_video() {
    say "video: mpv hw-decoded local clip playback"
    desktop_ready || { say "video: no live graphical session, skipping"; return; }
    if run "mpv" && run "ffmpeg"; then
        src=/tmp/prf-video-src.mp4
        timeout 40 ffmpeg -hide_banner -f lavfi -i testsrc2=size=1920x1080:rate=30:duration=45 \
            -f lavfi -i sine=frequency=440:duration=45 \
            -pix_fmt yuv420p -c:v libx264 -preset ultrafast -c:a aac \
            -shortest "$src" >/dev/null 2>&1 || true
        if [ -s "$src" ]; then
            # Real window, not --no-video: decode target is the display
            # compositor, not an offscreen surface.
            timeout 55 mpv --hwdec=vaapi --geometry=1280x720 \
                --really-quiet --no-terminal "$src" >/dev/null 2>&1 || true
        fi
        rm -f "$src"
    fi
}

phase_browser() {
    say "browser: selenium multi-site load"
    desktop_ready || { say "browser: no live graphical session, skipping"; return; }
    "$SELENIUM_PY" -c 'import selenium' >/dev/null 2>&1 || { say "browser: no selenium interpreter, skipping"; return; }
    run "firefox" || return 0

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

phase_network() {
    say "network: iperf3 loopback"
    if run "iperf3"; then
        # iperf3 needs a server; looping back to itself over 127.0.0.1 is
        # worthless for NIC drivers, but still exercises the TCP/loopback
        # fast path, which is the part this phase can portably reach.
        iperf3 -s -D -p 5201 >/dev/null 2>&1
        sleep 1
        timeout 55 iperf3 -c 127.0.0.1 -p 5201 -t 45 -P 4 >/dev/null 2>&1 || true
        pkill -f 'iperf3 -s' 2>/dev/null || true
    fi
}

setup_containers
trap teardown_containers EXIT

while [ "$(date +%s)" -lt "$END" ]; do
    phase_cpu
    phase_memory
    phase_memory_pressure
    phase_storage
    phase_storage_multifs
    phase_storage_nvme_readonly
    phase_gpu_vaapi
    phase_gpu_rocm
    phase_audio
    phase_db
    phase_mqtt
    phase_proxy_tls
    phase_dns
    phase_wireguard
    phase_ci_build
    phase_document
    phase_media_index
    phase_desktop
    phase_video
    phase_browser
    phase_network
done
say "load complete"
