[![build](https://github.com/fabianwimberger/linux-cachyos-deb/actions/workflows/build.yml/badge.svg)](https://github.com/fabianwimberger/linux-cachyos-deb/actions/workflows/build.yml)
[![License: GPL-2.0](https://img.shields.io/badge/License-GPL--2.0-blue.svg)](LICENSE)

# linux-cachyos-deb

CachyOS kernels as Ubuntu packages, built from the signed upstream source with Ubuntu's own config as the base.

## Background

CachyOS ships a tuned kernel — its own patch set, ThinLTO, `-O3`, AutoFDO, full preemption, the ORC unwinder, x86-64-v3/v4 and znver4 baselines — and packages it only for Arch. Ubuntu users who want the same profile get told to install XanMod or Liquorix, which are different patch sets with different maintainers and different defaults.

Repackaging the Arch build does not work: CachyOS's `CONFIG_LSM` omits AppArmor, which leaves snapd, LXD and every `/etc/apparmor.d` profile unconfined on Ubuntu without printing an error. So the config here starts from Ubuntu's generic config and applies the CachyOS profile as fragments, which keeps Ubuntu's userspace assumptions intact and makes every deviation greppable.

Packages install alongside Ubuntu's kernel and never replace it.

What this is not: a tick-rate change. Ubuntu 26.04's generic kernel already
runs at 1000 Hz and already uses `PREEMPT_LAZY`, so the difference is in code
generation and the CachyOS patch set, not the timer. Full preemption trades
some throughput for latency, deliberately. Treat any performance claim as
unproven until it is measured on the workload in question.

## Features

- **Signed upstream source** — the CachyOS pre-patched tarball is GPG-verified against pinned maintainer keys and a pinned SHA-256 before anything is built
- **Ubuntu config base** — starts from `linux-buildinfo-*-generic`, so AppArmor, BTF, initramfs-tools and the Ubuntu module set survive
- **Auditable deltas** — the entire difference from stock Ubuntu is four fragment files, one directive per line, covering both the options `linux-cachyos`'s PKGBUILD sets and the choices in the config it ships
- **Config assertions** — the build fails if `olddefconfig` silently dropped ThinLTO, `-O3`, the tick rate or the LSM list
- **CPU guard** — the image package refuses to install on a CPU below its baseline, or on a non-AMD machine for the `znver4` build, instead of producing an unbootable machine
- **Secure Boot** — the image is signed at install time with the machine's own MOK, the key Ubuntu already generates for DKMS, so no new key to trust and no extra enrolment
- **Containerised build** — `ubuntu:26.04` with the archive's clang and pahole; the same image runs locally and in CI, and the same clang DKMS calls on the target
- **Signed modules** — in-tree modules are signed with a key the build generates and discards, so loading them does not taint the kernel
- **Coexists with Ubuntu's kernel** — versioned package names, so `linux-image-generic` stays installed and selectable in GRUB

## Quick Start

Install from the package repository:

```bash
# trust the repository key
curl -fsSL https://github.com/fabianwimberger/linux-cachyos-deb/releases/latest/download/linux-cachyos-deb-archive-keyring.gpg \
  | sudo tee /usr/share/keyrings/linux-cachyos-deb.gpg > /dev/null

# add the flat repo
echo "deb [signed-by=/usr/share/keyrings/linux-cachyos-deb.gpg] \
https://github.com/fabianwimberger/linux-cachyos-deb/releases/latest/download ./" \
  | sudo tee /etc/apt/sources.list.d/linux-cachyos-deb.list

sudo apt update
sudo apt install linux-cachyos-x64v4   # or linux-cachyos-x64v3 on pre-AVX-512 hardware
                                       # or linux-cachyos-znver4 on AMD Zen 4/5
```

Ubuntu's kernel stays installed. Pick either entry in GRUB, or boot the new one
once with `sudo grub-reboot "<entry title>" && sudo reboot` before making it the default.

Build it yourself:

```bash
make image                  # ubuntu:26.04 build container
make preflight              # toolchain, disk and key checks
make fetch                  # download + GPG verify + extract the CachyOS tarball
make config                 # generate and assert work/x64v4/.config
make build package          # kernel, .debs, CPU guard, metapackage
make everything             # all flavors from kernel.env, plus the apt repo
```

Collect an AutoFDO profile, which needs a machine running a kernel built from
this tree and an AMD CPU with `amd_lbr_v2` (Zen 4+) or BRS (Zen 3):

```bash
make profile HOST=<ssh-host> SECS=3600 SEG=300   # record, convert, merge
make profile-report                             # how well it matches this kernel
make build package                        # rebuild against the profile
```

Put real load on the target for the whole run — an idle recording profiles an
idle kernel, and a long run spanning several different workloads beats a short
narrow one. Recording is segmented and each segment is converted and discarded
before the next starts, so disk use stays bounded no matter how long the run;
the segments are merged at the end. The profile is gitignored and not
published.

Serve the built repo over HTTP to install it on another machine the same way
users will:

```bash
make serve   # prints the apt source line to add on that machine
```

## How It Works

```
CachyOS signed tarball ─┐
                        ├─→ Ubuntu generic config ─→ + cachy.conf ─→ + ubuntu-compat.conf ─→ + x64vN.conf
kernel.env pins ────────┘                                                                         │
                                                                                                  ▼
                                                                             assert config (verify-config.sh)
                                                                                                  │
                                                                                                  ▼
                                                          clang + ThinLTO in ubuntu:26.04 → bindeb-pkg
                                                                                                  │
                                                                                                  ▼
                                                              CPU guard + metapackage → flat apt repo → GitHub release
```

## Configuration

`kernel.env` is the only file that needs editing to follow upstream.

| Variable | Default | Description |
|---|---|---|
| `KERNEL_VERSION` | `7.2.0` | Upstream kernel version the tarball contains |
| `CACHY_TAG` | `cachyos-7.2.0-1` | Release tag in `CachyOS/linux` to build from |
| `CACHY_SHA256` | pinned | SHA-256 of the tarball; a mismatch aborts the build |
| `PKGREL` | `3` | Debian revision; bump when only the config changes |
| `FLAVORS` | `x64v4 x64v3 znver4` | Flavors built by `make everything` |
| `LLVM_VERSION` | `distro` | `distro` for Ubuntu's clang, or a number for that apt.llvm.org release |
| `UBUNTU_SERIES` | `26.04` | Ubuntu release the container and packages target |
| `UBUNTU_BASE_CONFIG` | `config/base/…` | Base config the fragments are applied to |
| `MAINTAINER` | placeholder | `Maintainer:` field of the produced packages |
| `REPO_SIGN_KEY` | fingerprint | gpg key `make sign` signs the repository with |
| `AUTOFDO_PROFILE` | `profiles/…` | AutoFDO profile to build against; absent means an instrumented build with no profile applied |

Build-time overrides: `make build FLAVOR=x64v3`, `make build JOBS=8`, `REPO_SIGN_KEY=<keyid> make sign`.

## Updating

Following a new CachyOS release is a `kernel.env` edit and one build per
flavor. There is no patch queue to rebase, because upstream ships a pre-patched
tarball.

```bash
# 1. point at the new tag and clear the old hash
#    https://github.com/CachyOS/linux/releases
$EDITOR kernel.env          # CACHY_TAG=cachyos-<new>, CACHY_SHA256=, PKGREL=1

# 2. fetch; the build prints the hash to pin, then verifies against it
make fetch                  # prints CACHY_SHA256=... on first run
$EDITOR kernel.env          # paste the hash back in
make fetch                  # now verifies signature and hash

# 3. objtrees cannot span kernel versions
rm -rf work/x64v3 work/x64v4 work/znver4

# 4. refresh the generated driver deltas and read the diff
scripts/gen-cachy-extras.sh
git diff config/fragments/cachy-extras.conf

# 5. build all flavors, assemble and sign the repo
make everything

# 6. check the profile still fits the new source
make profile-report FLAVOR=znver4
```

`verify-config.sh` runs inside `make config` and fails the build if any asserted
symbol was dropped, so a silently changed dependency cannot ship.

Then test on real hardware before tagging: install over apt from `make serve`,
`grub-reboot` for a single boot, and check the release string, tick rate,
preemption, `CONFIG_CACHY`, baseline, AppArmor, BTF, DKMS rebuild and taint.

Three things the automation does **not** cover:

- **Config parity.** `gen-cachy-extras.sh` only adopts symbols missing from
  Ubuntu's config, never ones Ubuntu sets to `n` and CachyOS sets to `y`. Those
  live hand-written in `cachy.conf`, and nothing detects it when upstream
  changes one. Re-check against a CachyOS machine's `/proc/config.gz`, which is
  the shipped config rather than the one in their git tree — they differ, and
  AutoFDO is one of the differences.
- **The AutoFDO profile.** It carries across point releases, since it is keyed
  by function name and line offset: stale entries are ignored and new functions
  simply get no data. `make profile-report` measures how much still lands and
  fails below a threshold, so this one at least reports rather than rotting
  silently — regenerate when it drops. A few percent goes as soon as the
  profile is applied, because AutoFDO inlines the small hot functions it was
  told about and they stop being symbols; compare across kernel versions, not
  against the build the profile came from. Collecting a new profile cannot happen
  in CI, since VMs have no hardware performance counters.
- **The Ubuntu base config.** `UBUNTU_BASE_CONFIG` is pinned to one
  `linux-buildinfo` package. Refresh it when Ubuntu moves its own kernel, and
  replace it entirely for a new Ubuntu release.

## Toolchain

`LLVM_VERSION` in `kernel.env` decides which clang builds the kernel, and it is
not a free choice:

- `distro` — Ubuntu's clang, the one `/usr/bin/clang` points at on every target.
- a number, e.g. `22` — that release from apt.llvm.org.

`dkms` appends `LLVM=1` to every out-of-tree module build when the kernel was
compiled by clang, so nvidia, VirtualBox and friends are always built with the
unsuffixed `/usr/bin/clang`. If the kernel was built with a newer clang, those
builds fail on flags it does not know, and each user has to divert
`/usr/bin/clang` first. `distro` is therefore the default, and anything else is
for local experiments only.

## License

GPL-2.0. The packages are derived works of the Linux kernel, so the repository carries the kernel's license rather than a permissive one.

| Component | License | Source |
|---|---|---|
| Linux kernel | GPL-2.0 | [kernel.org](https://www.kernel.org) |
| CachyOS patch set | GPL-2.0 | [CachyOS/kernel-patches](https://github.com/CachyOS/kernel-patches) |
| CachyOS source tarballs | GPL-2.0 | [CachyOS/linux](https://github.com/CachyOS/linux) |
| Ubuntu base kernel config | GPL-2.0 | `linux-buildinfo-*-generic` |

Not affiliated with or endorsed by the CachyOS project or Canonical.
