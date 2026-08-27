# Safety

What to know before installing a third-party kernel on Ubuntu.

## Boot failure

Ubuntu's kernel is never removed or replaced — both stay in the GRUB menu. For
the first boot use `grub-reboot` for a one-shot boot, so a power cycle returns
to the old kernel with nothing to undo. Removal is `apt remove`.

## CPU baseline

An x86-64-v4 kernel on a CPU without AVX-512 resets at boot before anything can
log why. The image's `preinst` reads `/proc/cpuinfo` and refuses to install if
the required flags are missing.

## Secure Boot

The kernel is signed at install time with the machine's own MOK — the key
Ubuntu already generates for DKMS. Disable Secure Boot, or enrol that MOK with
`mokutil`. Only Canonical can sign for the Ubuntu shim, so there's no
shim-signed chain here.

## AppArmor

CachyOS's `CONFIG_LSM` has no AppArmor, which on Ubuntu would leave snapd and
every `/etc/apparmor.d` profile unenforced silently. Ubuntu's config here puts
it back — `verify-config.sh` fails the build if it's missing. Check
`aa-status` after the first boot; Ubuntu's AppArmor carries Canonical patches
that upstream may not, so some profiles might not load.

## DKMS modules

Out-of-tree modules (nvidia, VirtualBox, …) rebuild through DKMS on install,
which needs the matching `linux-headers` package — the metapackage pulls it in.
These kernels are built with ThinLTO, so modules must be compiled by clang.
Check `dkms status -k <release>` after installing; a failed build surfaces as
missing hardware, not an install error. With a non-distro `LLVM_VERSION`, the
unsuffixed `/usr/bin/clang` must match the kernel's clang (via `dpkg-divert`).

## ZFS

This kernel has no ZFS. Ubuntu's ZFS modules aren't built here, so a
root-on-ZFS system can't boot it and ZFS pools are inaccessible while it runs.

## Updates

Fixes arrive on upstream's 7.2.x point-release schedule, not Canonical's, and
there's no Livepatch. Rebuild against a new tag to get them.

## Source

The packages are derived from GPL-2.0 source. The exact tarball, its signature
and its hash are pinned in `kernel.env`, and every config difference lives in
`config/` — that's what the license requires.