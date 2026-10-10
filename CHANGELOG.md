# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow the upstream kernel release, with a `-N` suffix when only the packaging changes.

## [v7.2.9] - 2026-10-03

CachyOS 7.2.9, rebuilt for Ubuntu 26.04 across the x64v4, x64v3 and znver4 flavors with the pinned AutoFDO profile.

## [v7.2.8] - 2026-09-26

CachyOS 7.2.8, rebuilt for Ubuntu 26.04 across the x64v4, x64v3 and znver4 flavors with the pinned AutoFDO profile.

## [v7.2.7-2] - 2026-09-24

Rebuilds CachyOS 7.2.7 with a new AutoFDO profile, recorded on bare-metal Zen 5 under a much broader training load.

### Features

- New AutoFDO profile covering storage across several filesystems and LUKS, networking, WireGuard, containers, databases, a web server, ROCm compute, desktop, audio, video and a browser.
- Release builds apply only the profile pinned by hash in `kernel.env` and report how well it fits the kernel in the build summary.
- `make bench` and `make bench-compare` measure kernel-bound paths and compare two kernels; the README shows bare-metal results against Ubuntu's kernel.
- Profiling runs record detached from the ssh session and reject profiles dominated by one workload or far from the shipped one.

### Fixes

- Incremental builds pick up a changed AutoFDO profile instead of keeping the old one.

## [v7.2.7] - 2026-09-24

CachyOS 7.2.7.

## [v7.2.6] - 2026-09-16

CachyOS 7.2.6.

## [v7.2.5] - 2026-09-14

CachyOS 7.2.5.

## [v7.2.4] - 2026-09-11

CachyOS 7.2.4.

## [v7.2.3-1] - 2026-09-05

CachyOS 7.2.3.

### Fixes

- Apply the AutoFDO profile only when it is meant to be used.
- Reset `PKGREL` to 1 when the kernel version changes.

## [v7.2.2-5] - 2026-08-30

Packaging refresh of CachyOS 7.2.2.

### Features

- Add hardware benchmarking and harden the profiling pipeline.

## [v7.2.2] - 2026-08-28

CachyOS 7.2.2.

## [v7.2.0-1] - 2026-08-28

First release: CachyOS 7.2.0 packaged for Ubuntu.
