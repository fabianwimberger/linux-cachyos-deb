#!/usr/bin/env bash
# Runs on the benchmark target; copied there by scripts/bench.sh.
#
#   bench-remote.sh <runs>
#
# Prints one line per metric: <name> <median> <unit> <higher|lower>, with
# "# " lines for context. Each metric runs <runs> times and reports the median,
# so one noisy run cannot decide a comparison.
#
# Most metrics are kernel-bound (syscalls, scheduler, fork/exec, VM, pipes,
# sockets, page cache, block layer), where a kernel build can differ. The
# openssl and sysbench cpu lines are pure userspace: they should not move
# between kernels, and how much they do is the noise floor for the rest.
set -uo pipefail

RUNS=${1:-3}
WORK=$(mktemp -d -p /var/tmp bench.XXXXXX)
trap 'rm -rf "$WORK"; [ -n "${iperf_pid:-}" ] && kill "$iperf_pid" 2>/dev/null' EXIT

have() { command -v "$1" >/dev/null 2>&1; }
median() { sort -g | awk '{v[NR]=$1} END {if (NR) print (NR % 2 ? v[(NR+1)/2] : (v[NR/2] + v[NR/2+1]) / 2)}'; }

# metric <name> <unit> <higher|lower> <command printing one number>
metric() {
    local name=$1 unit=$2 dir=$3 cmd=$4 i v vals=''
    for i in $(seq 1 "$RUNS"); do
        v=$(bash -c "$cmd" 2>/dev/null | tail -1)
        [[ "$v" =~ ^[0-9.eE+-]+$ ]] && vals+="$v"$'\n'
    done
    [ -n "$vals" ] || { echo "# $name: no result"; return; }
    printf '%s %s %s %s\n' "$name" "$(median <<<"$vals")" "$unit" "$dir"
}

stressng() {
    # bogo ops per second (real time) for one stressor.
    local y="$WORK/sng.yaml"
    stress-ng "$@" --timeout 10s --quiet --metrics-brief --yaml "$y" >/dev/null 2>&1
    awk '/bogo-ops-per-second-real-time:/ {print $2; exit}' "$y"
}
export -f stressng
export WORK

fio_iops() {
    fio --output-format=json "$@" 2>/dev/null \
        | python3 -c 'import json,sys; j=json.load(sys.stdin)["jobs"][0]; print(j["read"]["iops"] + j["write"]["iops"])'
}
fio_bw() {
    fio --output-format=json "$@" 2>/dev/null \
        | python3 -c 'import json,sys; j=json.load(sys.stdin)["jobs"][0]; print((j["read"]["bw_bytes"] + j["write"]["bw_bytes"]) / 1048576)'
}
export -f fio_iops fio_bw

echo "# kernel $(uname -r)"
echo "# cpu $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
echo "# governor $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null) epp $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null) platform_profile $(cat /sys/firmware/acpi/platform_profile 2>/dev/null) ac $(cat /sys/class/power_supply/A*/online 2>/dev/null | head -1)"
echo "# runs $RUNS, median"

# Userspace control group.
if have openssl; then
    metric openssl_sha256 MB/s higher \
        "openssl speed -seconds 5 -bytes 16384 sha256 2>/dev/null | awk 'END {sub(/k\$/, \"\", \$NF); print \$NF / 1000}'"
fi
if have sysbench; then
    metric sysbench_cpu events/s higher \
        "sysbench cpu --threads=\$(nproc) --time=10 run | awk '/events per second/ {print \$4}'"
    metric sysbench_memory MiB/s higher \
        "sysbench memory --threads=8 --time=10 run | sed -n 's/.*(\([0-9.]*\) MiB\/sec).*/\1/p'"
    metric sysbench_threads events higher \
        "sysbench threads --threads=64 --time=10 run | awk '/total number of events/ {print \$5}'"
fi

# Scheduler, syscalls, IPC.
if have perf; then
    metric perf_syscall_basic usecs/op lower \
        "perf bench syscall basic 2>&1 | awk '/usecs\\/op/ {print \$1}'"
    metric perf_sched_pipe usecs/op lower \
        "perf bench sched pipe -l 500000 2>&1 | awk '/usecs\\/op/ {print \$1}'"
    metric perf_sched_messaging s lower \
        "perf bench sched messaging -g 20 -l 2000 2>&1 | awk '/Total time/ {print \$3}'"
fi
if have stress-ng; then
    metric sng_fork ops/s higher "stressng --fork \$(nproc)"
    metric sng_exec ops/s higher "stressng --exec \$(nproc)"
    metric sng_switch ops/s higher "stressng --switch \$(nproc)"
    metric sng_pipe ops/s higher "stressng --pipe \$(nproc)"
    metric sng_futex ops/s higher "stressng --futex \$(nproc)"
    metric sng_epoll ops/s higher "stressng --epoll 4"
    metric sng_sock ops/s higher "stressng --sock 4"
    metric sng_mmap ops/s higher "stressng --mmap \$(nproc)"
    metric sng_fault ops/s higher "stressng --fault \$(nproc)"
    metric sng_brk ops/s higher "stressng --brk \$(nproc)"
    metric sng_open ops/s higher "stressng --open \$(nproc)"
    metric sng_dentry ops/s higher "stressng --dentry 4"
fi

# Page cache and block layer.
if have fio; then
    shm=$(mktemp -d -p /dev/shm bench.XXXXXX)
    metric fio_tmpfs_randread IOPS higher \
        "fio_iops --name=b --directory=$shm --size=512m --bs=4k --rw=randread --ioengine=psync --numjobs=4 --time_based --runtime=10 --group_reporting"
    metric fio_tmpfs_randwrite IOPS higher \
        "fio_iops --name=b --directory=$shm --size=512m --bs=4k --rw=randwrite --ioengine=psync --numjobs=4 --time_based --runtime=10 --group_reporting"
    rm -rf "$shm"
    metric fio_disk_randread_qd1 IOPS higher \
        "fio_iops --name=b --directory=$WORK --size=1g --bs=4k --rw=randread --ioengine=psync --direct=1 --time_based --runtime=10"
    metric fio_disk_randread_uring IOPS higher \
        "fio_iops --name=b --directory=$WORK --size=1g --bs=4k --rw=randread --ioengine=io_uring --direct=1 --iodepth=32 --time_based --runtime=10"
    metric fio_disk_seqread MiB/s higher \
        "fio_bw --name=b --directory=$WORK --size=2g --bs=1m --rw=read --ioengine=libaio --direct=1 --iodepth=8 --time_based --runtime=10"
    rm -f "$WORK"/b.*
fi

# Loopback networking.
if have iperf3; then
    iperf3 -s -p 5299 >/dev/null 2>&1 &
    iperf_pid=$!
    sleep 1
    metric iperf3_tcp_1stream Gbit/s higher \
        "iperf3 -c 127.0.0.1 -p 5299 -t 8 -J | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"end\"][\"sum_received\"][\"bits_per_second\"] / 1e9)'"
    metric iperf3_tcp_4stream Gbit/s higher \
        "iperf3 -c 127.0.0.1 -p 5299 -t 8 -P 4 -J | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"end\"][\"sum_received\"][\"bits_per_second\"] / 1e9)'"
    kill "$iperf_pid" 2>/dev/null
    iperf_pid=
fi

# A parallel C build: fork/exec, page cache and scheduler under a real tool.
if have cc && have make; then
    src=$WORK/cproj
    mkdir -p "$src"
    for i in $(seq 1 2000); do
        printf '#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\nint f%d(int x){char b[64];snprintf(b,sizeof b,"%%d",x);return (int)strlen(b)+x*%d;}\n' "$i" "$i" > "$src/f$i.c"
    done
    printf 'SRCS := $(wildcard *.c)\nOBJS := $(SRCS:.c=.o)\nall: $(OBJS)\n%%.o: %%.c\n\t$(CC) -O2 -c $< -o $@\nclean:\n\trm -f *.o\n' > "$src/Makefile"
    metric build_2000_files s lower \
        "make -C $src clean >/dev/null; sync; s=\$(date +%s.%N); make -s -C $src -j\$(nproc) >/dev/null; e=\$(date +%s.%N); awk -v s=\$s -v e=\$e 'BEGIN {print e - s}'"
fi
