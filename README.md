[![checks](https://github.com/fabianwimberger/linux-cachyos-deb/actions/workflows/checks.yml/badge.svg)](https://github.com/fabianwimberger/linux-cachyos-deb/actions/workflows/checks.yml)
[![License: GPL-2.0](https://img.shields.io/badge/License-GPL--2.0-blue.svg)](LICENSE)

# linux-cachyos-deb

CachyOS kernels, packaged for Ubuntu.

CachyOS ships a tuned kernel — its own patch set, ThinLTO, `-O3`, AutoFDO,
full preemption, and x86-64-v3/v4/znver4 builds — but only for Arch. This makes
the same kernel installable on Ubuntu via `apt`, alongside the stock kernel,
without replacing or breaking it.

The config starts from Ubuntu's own generic kernel config and applies the
CachyOS profile on top. That keeps Ubuntu's assumptions intact: AppArmor,
snapd, BTF, initramfs-tools and the standard module set all still work. A
straight repackage of the Arch build wouldn't, because CachyOS's `CONFIG_LSM`
drops AppArmor.

## Install

```bash
# trust the repository key
curl -fsSL https://github.com/fabianwimberger/linux-cachyos-deb/releases/latest/download/linux-cachyos-deb-archive-keyring.gpg \
  | sudo tee /usr/share/keyrings/linux-cachyos-deb.gpg > /dev/null

# add the flat repo
echo "deb [signed-by=/usr/share/keyrings/linux-cachyos-deb.gpg] \
https://github.com/fabianwimberger/linux-cachyos-deb/releases/latest/download ./" \
  | sudo tee /etc/apt/sources.list.d/linux-cachyos-deb.list

sudo apt update
sudo apt install linux-cachyos-x64v4   # or -x64v3, or -znver4 on fresh AMD
```

Ubuntu's kernel stays installed — pick either one in GRUB. Try the new kernel
once with `sudo grub-reboot "<entry>" && sudo reboot`, then set it as the
default if it behaves. Read [docs/SAFETY.md](docs/SAFETY.md) before installing.

## Build it yourself

```bash
make image       # build container (ubuntu:26.04, clang from the archive)
make fetch       # download + GPG-verify the CachyOS source tarball
make config      # generate .config (x64v4 by default)
make build       # compile the kernel
make package     # .debs + CPU guard + metapackage
make everything  # all flavors from kernel.env, plus the apt repo
```

`make config FLAVOR=x64v3`, `make build JOBS=8` etc. override the defaults.

## What you get

- **Signed upstream source** — the CachyOS tarball is GPG-verified against pinned keys and a pinned SHA-256 before anything is built.
- **Ubuntu base config** — starts from Ubuntu's own config, so the whole delta is a few greppable fragment files in `config/fragments/`.
- **Coexists with Ubuntu's kernel** — nothing is replaced; upgrades flow through `apt` like any other package.
- **CPU guard** — the image refuses to install on hardware below its baseline (or on non-AMD for znver4) rather than producing an unbootable system.

## Benchmarks

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

## Updating

Following a new upstream release is a `kernel.env` edit and one build per flavor:

```bash
$EDITOR kernel.env          # new CACHY_TAG, clear CACHY_SHA256
make fetch                  # prints the hash to pin
$EDITOR kernel.env          # paste the hash back
rm -rf work/x64v3 work/x64v4 work/znver4
make everything
```

## Not this

- Not a tick-rate change — Ubuntu's 26.04 kernel is already 1000 Hz. The differences are codegen, the CachyOS patch set and its preemption and memory defaults; see [Benchmarks](#benchmarks).
- No ZFS — Ubuntu's ZFS modules aren't built here, so root-on-ZFS won't boot it.
- No own-signing-key chain — only Canonical can sign for the Ubuntu shim; Secure Boot needs a MOK you already have from DKMS.

## Configuration

`kernel.env` is the one file to edit.

| Variable | Default | Description |
|---|---|---|
| `CACHY_TAG` / `CACHY_SHA256` | `cachyos-7.2.7-1` | upstream release to build; hash pinned |
| `FLAVORS` | `x64v4 x64v3 znver4` | flavors built by `make everything` |
| `PKGREL` | `1` | Debian revision; bump when only the config changes |
| `LLVM_VERSION` | `distro` | `distro` = Ubuntu's clang, a number = apt.llvm.org release |
| `UBUNTU_SERIES` | `26.04` | Ubuntu the container/packages target |
| `MAINTAINER` | `linux-cachyos-deb <noreply@users.noreply.github.com>` | package Maintainer field |
| `AUTOFDO_PROFILE` | `profiles/vmlinux.afdo` | profile applied when present; absent = instrumented build |
| `AUTOFDO_PROFILE_SHA256` | pinned | profile release builds apply; `AUTOFDO_PROFILE_SHA256_<flavor>` overrides per flavor |
| `AUTOFDO_PROFILES_REPO` | this project's profiles repo | GitHub repo the profile is uploaded to and CI fetches from |
| `REPO_SIGN_KEY` | repo key fingerprint | gpg key `make sign` uses |

**AutoFDO:** release builds apply the pinned AutoFDO profile from the private profiles repo named in `AUTOFDO_PROFILES_REPO`, using the `AUTOFDO_DEPLOY_KEY` secret, and report in the job summary how much of it still matches the kernel. Without that secret (for example on a fork) the build simply skips the profile.

To refresh the profile, set up an AMD Zen 3+ machine as described in [docs/PROFILING.md](docs/PROFILING.md), install the flavor's kernel from `work/<flavor>` on it, and run:

```bash
make profile-release HOST=<ssh-host> SECS=3600
```

That runs a mixed kernel-heavy load on the host, records it, and stops if core load phases are missing, too few samples were recorded, or the hot functions drifted from the shipped profile. The run then prints each phase's share of the samples, uploads the profile, and prints the `AUTOFDO_PROFILE_SHA256` to pin.

## License

GPL-2.0. The packages derive from the Linux kernel, so the repo carries the kernel's license. Not affiliated with CachyOS or Canonical.

### Attribution

The build redistributes upstream CachyOS work under GPL-2.0:

- Kernel source and the `cachy`/`cachy-extras` config fragments — [CachyOS/linux](https://github.com/CachyOS/linux)
- `patches/0001-dkms-clang.patch` — Eric Naim <dnaim@cachyos.org>