# Safety

What can go wrong installing a third-party kernel on Ubuntu, and what this
project does about it.

## Machine does not boot

Ubuntu's kernel is never removed or replaced. The packages carry a full version
in their name (`linux-image-7.2.0-cachyos-x64v4`), so they install alongside
`linux-image-generic` and both stay in the GRUB menu.

For the first boot use a `grub-reboot` one-shot entry rather than changing the
default. If the kernel panics or hangs, power-cycling returns to the previous
default. Nothing has to be undone from a rescue shell.

Removal is `apt remove linux-image-7.2.0-cachyos-x64vN`; the postrm hooks
regenerate GRUB and the initramfs.

## Wrong CPU baseline

An x86-64-v4 kernel on a CPU without AVX-512 produces an immediate reset at
boot, before anything can log why. The image package's `preinst` reads
`/proc/cpuinfo` and refuses to install if the required flags are absent.

## Secure Boot

These kernels are unsigned, so they will not boot with Secure Boot enabled.
Options:

1. Disable Secure Boot in firmware.
2. Sign the kernel and its modules with a local MOK (`sbsign`, `scripts/sign-file`
   from the headers package) and enrol it with `mokutil`. Has to be repeated
   after each kernel update.

There is no shim-signed chain here and there will not be one; only Canonical can
sign for the Ubuntu shim.

## AppArmor and snapd

CachyOS's `CONFIG_LSM` has no `apparmor` entry. Booting such a kernel on Ubuntu
leaves snapd, LXD and every profile in `/etc/apparmor.d` unenforced, silently.
`config/fragments/ubuntu-compat.conf` puts AppArmor back into the LSM list, and
`verify-config.sh` fails the build if it is missing from the generated config.

Ubuntu's own AppArmor carries Canonical patches that are not upstream. Profiles
that rely on those features may not load. Check `aa-status` after the first boot.

## DKMS modules

Out-of-tree modules (nvidia, virtualbox, it87, …) rebuild against the new
headers through `/etc/kernel/postinst.d/dkms`, which needs the matching
`linux-headers` package installed — the metapackage pulls it in.

Check `dkms status -k <release>` after installing: a DKMS failure surfaces as
missing hardware, not as an install error.

These kernels are built with ThinLTO, so modules must be compiled by clang, and
DKMS invokes bare `clang` — `/usr/bin/clang` on the target. When `LLVM_VERSION`
in `kernel.env` is a number, that binary is older than the one the kernel was
built with and DKMS fails on flags it does not recognise. dpkg also sanitises
PATH for maintainer scripts, so the unsuffixed tools in `/usr/bin` have to be the
matching version — via `dpkg-divert` — unless the kernel is built with
`LLVM_VERSION=distro`.

## ZFS

Ubuntu builds ZFS modules as part of its own kernel packages
(`linux-main-modules-zfs-*`). This kernel has no ZFS. A root-on-ZFS system
cannot boot it, and a system with ZFS data pools loses access to them while
running it.

## Security updates

Ubuntu backports CVE fixes into its kernel on Canonical's schedule and offers
livepatch. Neither applies here. Fixes arrive when upstream releases a 7.2.x
point release and this repository rebuilds against it. Track upstream stable, or
stay on Ubuntu's kernel.

## Source availability

The packages are derived from GPL-2.0 source. The exact tarball, its signature
and its hash are pinned in `kernel.env`, and every configuration difference is
in `config/`. That, plus the upstream URL, is what the license requires.
