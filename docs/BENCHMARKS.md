# Benchmarks

Bare metal, AMD Ryzen AI 9 365 (Zen 5, 20 threads) on Ubuntu 26.04: the stock
`7.0.0-34-generic` kernel against `7.2.7-cachyos-x64v4` from this repo with the
shipped AutoFDO profile. Both at the same clocks and power settings
(`amd-pstate-epp`, `balance_performance`, on AC); each value is the median of
five runs. Positive means the CachyOS kernel is better.

| Metric | Stock | CachyOS | Δ |
|---|---|---|---|
| openssl sha256 (userspace control) | 2445 MB/s | 2452 MB/s | +0.3% |
| sysbench cpu (userspace control) | 44142/s | 43225/s | −2.1% |
| sysbench memory | 12428 MiB/s | 12290 MiB/s | −1.1% |
| sysbench threads | 98655 | 122701 | **+24%** |
| perf bench syscall | 0.0410 µs | 0.0397 µs | +3% |
| perf bench sched pipe † | 1.60 µs | 1.54 µs | +4% |
| perf bench sched messaging | 1.65 s | 1.45 s | **+12%** |
| stress-ng pipe | 6.60 M/s | 12.46 M/s | **+89%** |
| stress-ng context switch | 5.44 M/s | 6.90 M/s | **+27%** |
| stress-ng sock | 9818/s | 12379/s | **+26%** |
| stress-ng brk | 1.44 M/s | 2.18 M/s | **+52%** |
| stress-ng page fault | 322765/s | 351579/s | +9% |
| stress-ng mmap | 1309/s | 1426/s | +9% |
| stress-ng open | 448530/s | 491373/s | +10% |
| stress-ng futex | 2.77 M/s | 1.69 M/s | **−39%** |
| stress-ng epoll † | 25741/s | 21960/s | **−15%** |
| stress-ng fork † | 31580/s | 27713/s | **−12%** |
| stress-ng exec † | 4195/s | 3881/s | −7% |
| fio tmpfs 4k randread | 5.96 M IOPS | 6.14 M IOPS | +3% |
| fio disk 4k randread, QD1 † | 9097 IOPS | 7454 IOPS | **−18%** |
| fio disk 4k randread, io_uring QD32 | 91089 IOPS | 91126 IOPS | 0% |
| iperf3 loopback, 1 stream † | 124 Gbit/s | 89 Gbit/s | **−28%** |
| iperf3 loopback, 4 streams † | 290 Gbit/s | 271 Gbit/s | −7% |
| parallel C build, 2000 files | 3.78 s | 3.60 s | +5% |

The userspace controls stay within 2%. Rows marked † are not reliable on
this CPU: it has two L3 domains of unequal cores (four Zen 5 at 5.1 GHz, six
Zen 5c at 3.3 GHz), so single- and few-threaded results depend on where the
scheduler happens to place the task, and a repeat run of the same kernel moved
them by 15–50%. The unmarked rows repeat within a few percent. The kernel is
also two upstream releases ahead (7.2 against 7.0), so part of any difference
is upstream rather than this build.

Switching the CachyOS scheduling choices back to Ubuntu's one at a time, at
runtime, on this kernel (five interleaved rounds) confirms none of them as
the cause of a clear loss:

- **Full preemption** (`PREEMPT`, Ubuntu `PREEMPT_LAZY`): lazy wins futex
  back by 13% but loses 6–7% on context switches and hackbench. A trade-off,
  not a fix.
- **Piece-Of-Cake idle selector** (`SCHED_POC_SELECTOR`) and **cache-aware
  balancing** (`SCHED_CACHE`): turning either off costs hackbench about 6%
  and changes nothing else beyond the noise.
- **Transparent huge pages always on** (Ubuntu `madvise`): no stable effect.

The broad gains (threads, pipe, sockets, page faults, the build) come with the
kernel as a whole: CachyOS's scheduler and preemption choices, ThinLTO,
`-O3`, x86-64-v4, AutoFDO, and ORC unwinding instead of frame pointers.

Reproduce on any machine you can reach over ssh, once per kernel:

```bash
make bench HOST=<user>@<host> LABEL=stock RUNS=5
make bench HOST=<user>@<host> LABEL=cachyos RUNS=5
make bench-compare A=profiles/bench-stock.txt B=profiles/bench-cachyos.txt
```
