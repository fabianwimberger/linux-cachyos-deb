# Benchmarks

Bare metal, AMD Ryzen AI 9 365 (Zen 5, 20 threads) on Ubuntu 26.04: the stock
`7.0.0-38-generic` kernel against `7.3.0-cachyos-znver4` from this repo with the
AutoFDO profile this release applies. Both at the same clocks and power settings
(`amd-pstate-epp`, `balance_performance`, on AC); each value is the median of
five runs. Positive means the CachyOS kernel is better.

| Metric | Stock | CachyOS | Δ |
|---|---|---|---|
| openssl sha256 (userspace control) | 2443 MB/s | 2453 MB/s | +0.4% |
| sysbench cpu (userspace control) | 43717/s | 43788/s | +0.2% |
| sysbench memory | 12290 MiB/s | 12407 MiB/s | +1.0% |
| sysbench threads | 96843 | 114870 | **+19%** |
| perf bench syscall | 0.0398 µs | 0.0415 µs | −4.3% |
| perf bench sched pipe † | 1.59 µs | 1.70 µs | −6.6% |
| perf bench sched messaging | 1.66 s | 1.33 s | **+20%** |
| stress-ng pipe | 7.01 M/s | 16.61 M/s | **+137%** |
| stress-ng context switch | 5.48 M/s | 5.77 M/s | +5.4% |
| stress-ng sock | 10302/s | 12071/s | **+17%** |
| stress-ng brk | 1.44 M/s | 2.35 M/s | **+63%** |
| stress-ng page fault | 329619/s | 352235/s | +6.9% |
| stress-ng mmap | 1345/s | 1370/s | +1.9% |
| stress-ng open | 476110/s | 481259/s | +1.1% |
| stress-ng futex | 2.81 M/s | 1.85 M/s | **−34%** |
| stress-ng epoll † | 14637/s | 18044/s | **+23%** |
| stress-ng fork † | 28222/s | 33919/s | **+20%** |
| stress-ng exec † | 3837/s | 4499/s | **+17%** |
| fio tmpfs 4k randread | 5.95 M IOPS | 5.98 M IOPS | +0.4% |
| fio disk 4k randread, QD1 † | 9329 IOPS | 8929 IOPS | −4.3% |
| fio disk 4k randread, io_uring QD32 | 90365 IOPS | 91283 IOPS | +1.0% |
| iperf3 loopback, 1 stream † | 125 Gbit/s | 118 Gbit/s | −5.7% |
| iperf3 loopback, 4 streams † | 292 Gbit/s | 249 Gbit/s | **−15%** |
| parallel C build, 2000 files | 3.79 s | 3.62 s | +4.5% |

The userspace controls stay within 2%. Rows marked † are not reliable on
this CPU: it has two L3 domains of unequal cores (four Zen 5 at 5.1 GHz, six
Zen 5c at 3.3 GHz), so single- and few-threaded results depend on where the
scheduler happens to place the task, and a repeat run of the same kernel moved
them by 15–50%. The unmarked rows repeat within a few percent. The kernel is
also three upstream releases ahead (7.3 against 7.0), so part of any difference
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
