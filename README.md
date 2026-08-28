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

Measured on KVM VMs with CPU passthrough on Zen 4, comparing the stock Ubuntu
kernel against `7.2.0-cachyos-znver4` installed from this repo. Each metric is
the mean of three runs on the same VM. `cpu`/`mem`/`threads` are sysbench;
`tmpfs_*` and `disk_*` are fio; `loop` is iperf3 over loopback.

Ubuntu 24.04 (stock 6.8.0-138):

| metric | stock | cachyos | Δ |
|---|---|---|---|
| sysbench cpu | 23512/s | 23155/s | −1.5% |
| sysbench memory | 26644 MiB/s | 26234 MiB/s | −1.5% |
| sysbench threads | 5981/s | 8496/s | **+42%** |
| fio tmpfs 4k randread | 118923 IOPS | 184748 IOPS | **+55%** |
| fio tmpfs 4k randwrite | 92051 IOPS | 154443 IOPS | **+68%** |
| fio disk 4k randread | 119448 IOPS | 181815 IOPS | **+52%** |
| fio disk 1m seqread | 28349 MiB/s | 63146 MiB/s | **+123%** |
| iperf3 loopback | 209 Gbit/s | 278 Gbit/s | **+33%** |

Ubuntu 26.04 (stock 7.0.0-30):

| metric | stock | cachyos | Δ |
|---|---|---|---|
| sysbench cpu | 20830/s | 21001/s | +1% |
| sysbench memory | 26456 MiB/s | 26800 MiB/s | +1% |
| sysbench threads | 5684/s | 8387/s | **+48%** |
| fio tmpfs 4k randread | 523905 IOPS | 563873 IOPS | **+8%** |
| fio tmpfs 4k randwrite | 485729 IOPS | 530348 IOPS | **+9%** |
| fio disk 4k randread | 166946 IOPS | 195248 IOPS | **+17%** |
| fio disk 1m seqread | 27771 MiB/s | 59280 MiB/s | **+113%** |
| iperf3 loopback | 210 Gbit/s | 270 Gbit/s | **+29%** |

The consistent wins are threading, block I/O and loopback throughput; pure
CPU and memory are flat. What the table does not isolate: the cachyos kernel is
two upstream releases ahead of stock 24.04/26.04 (`7.2` vs `6.8`/`7.0`), so part
of the I/O gain is upstream 7.2, not this tuning. Treat these as VM-relative
indicators, not absolute figures.

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

- Not a tick-rate change — Ubuntu's 26.04 kernel is already 1000 Hz / `PREEMPT_LAZY`; the difference is codegen and the CachyOS patch set.
- No ZFS — Ubuntu's ZFS modules aren't built here, so root-on-ZFS won't boot it.
- No own-signing-key chain — only Canonical can sign for the Ubuntu shim; Secure Boot needs a MOK you already have from DKMS.

## Configuration

`kernel.env` is the one file to edit.

| Variable | Default | Description |
|---|---|---|
| `CACHY_TAG` / `CACHY_SHA256` | `cachyos-7.2.0-1` | upstream release to build; hash pinned |
| `FLAVORS` | `x64v4 x64v3 znver4` | flavors built by `make everything` |
| `PKGREL` | `4` | Debian revision; bump when only the config changes |
| `LLVM_VERSION` | `distro` | `distro` = Ubuntu's clang, a number = apt.llvm.org release |
| `UBUNTU_SERIES` | `26.04` | Ubuntu the container/packages target |
| `MAINTAINER` | — | package Maintainer field |

## License

GPL-2.0. The packages derive from the Linux kernel, so the repo carries the kernel's license. Not affiliated with CachyOS or Canonical.