# Profiling

How the AutoFDO profile that release builds apply is recorded, and how to set
up a machine to record it.

## How it fits together

Three machines take part:

- **Build host** — where this repo is checked out. It builds the kernel that
  gets profiled, drives the whole run over ssh, turns the recording into a
  profile, checks it, and uploads it. Needs Docker with the builder image
  (`make image`), `gh` logged in with push access to `AUTOFDO_PROFILES_REPO`,
  an ssh key the target accepts, and optionally `iperf3`.
- **Target** — the machine being profiled. It runs the kernel built on the
  build host, the training load (`scripts/profile-load.sh`) and `perf`. It
  needs an AMD Zen 3 CPU with BRS or any Zen 4 or newer, and Ubuntu 26.04
  Desktop. Nothing from this repo has to be installed there: each run copies
  the scripts it needs.
- **CI** — release builds fetch the profile pinned in `kernel.env` from the
  private profiles repo, using the read-only `AUTOFDO_DEPLOY_KEY` secret.

A run starts the load, waits until its setup is done, records the kernel in
segments, stops the load, and gates the result on which load phases ran, how
the samples are spread across them, how many were recorded, and how far the
hot functions moved from the shipped profile. Only a profile that passes is
uploaded.

## What the load covers

Only kernel samples are recorded, so the load is built from workloads that
spend their time in the kernel, standing in for a typical desktop, developer
workstation and self-hosted server. Pure userspace compute adds wall time and
next to no samples.

| Phase | Kernel paths |
|---|---|
| `cpu` | parallel C build: fork/exec, page cache, scheduler; thread churn |
| `vm` | page faults, mmap/munmap, brk, memfd, fork with mappings |
| `ipc` | pipes, futexes, context switches, epoll/poll, UNIX/TCP/UDP sockets, timerfd, eventfd, signals |
| `memory_pressure` | reclaim, zswap and swap in a memory-capped cgroup (every other lap) |
| `storage` | direct and buffered I/O through libaio, io_uring and psync; fsync, readahead, tmpfs |
| `files` | small-file trees: create, stat, cold read, git, copy, delete |
| `storage_multifs` | ext4, XFS, Btrfs with zstd compression, F2FS, ext4 on LUKS |
| `storage_nvme_readonly` | NVMe reads from the internal drive |
| `gpu_vaapi` | VAAPI H.264/AV1 encode and decode, with loopback TCP (IPv4/IPv6) and UDP running concurrently (`net_loopback`) |
| `net_nic` | TCP both ways and UDP through the real network driver |
| `gpu_rocm` | ROCm compute submission through KFD |
| `db` | PostgreSQL OLTP (WAL fsync) and Valkey over Docker's NAT |
| `web` | nginx under wrk: keep-alive, sendfile, per-request connections, IPv6 |
| `mixed` | database, web, buffered I/O and a build at the same time |
| `mqtt`, `dns` | broker pub/sub, resolver queries |
| `wireguard` | encrypted tunnel traffic |
| `containers` | container start/stop: namespaces, cgroups, overlayfs, veth, seccomp; an image build |
| `desktop` | OpenGL and Vulkan rendering with audio playing, window resizing |
| `audio`, `video` | playback through the sound server; hardware-decoded video to the compositor |
| `browser` | Firefox on real sites: page loads, WebGL, streaming video, a speed test |

Phases run in laps of roughly 20–25 minutes, and each lap starts at a
different phase, so wherever the recording stops, the cut falls on different
phases. After a run, `profiles/phase-share.txt` shows how much of the profile
each phase contributed; the run fails if any single phase is above
`AUTOFDO_MAX_PHASE_SHARE`.

## Target: base setup

Install Ubuntu 26.04 Desktop and log in once. Check the CPU can record branch
stacks; this must print `amd_lbr_v2` (Zen 4+) or `brs` (Zen 3):

```bash
grep -owm1 -e amd_lbr_v2 -e brs /proc/cpuinfo
```

Packages for the recorder and every load phase:

```bash
sudo apt install openssh-server linux-tools-generic zstd build-essential sysbench stress-ng fio python3 python3-venv ffmpeg vainfo iperf3 bind9-dnsutils git docker.io mosquitto-clients redis-tools wrk pipewire-bin mesa-utils vulkan-tools vkmark wmctrl xdotool mpv wireguard-tools
```

On 26.04, `/usr/bin/perf` is a real binary and runs under any kernel, so the
custom kernel needs no matching `linux-tools` package.

Let `perf` read kernel samples and addresses as a normal user:

```bash
printf 'kernel.perf_event_paranoid = -1\nkernel.kptr_restrict = 0\n' | sudo tee /etc/sysctl.d/99-autofdo.conf
sudo sysctl --system
```

io_uring rings count against the locked-memory limit, and at Ubuntu's 8 MB
default the storage phases' io_uring jobs fail. Lift it for your user (takes
effect on the next login):

```bash
echo "$USER - memlock unlimited" | sudo tee /etc/security/limits.d/99-autofdo.conf
```

Docker and GPU access without sudo (log out and in afterwards):

```bash
sudo usermod -aG docker,video,render "$USER"
```

From the build host, install its ssh key. The scripts run ssh
non-interactively, so a key with a passphrase needs a running agent:

```bash
ssh-copy-id <user>@<target>
```

## Target: desktop session

The desktop, video, audio and browser phases need a live Wayland session, and
the run must not be interrupted by a lock screen or suspend. Log in
automatically, replacing `<user>`:

```bash
sudo sed -i -e 's/^#\? *AutomaticLoginEnable *=.*/AutomaticLoginEnable = true/' -e 's/^#\? *AutomaticLogin *=.*/AutomaticLogin = <user>/' /etc/gdm3/custom.conf
```

In that session:

```bash
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.desktop.screensaver lock-enabled false
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
```

Keep a laptop on AC power with the lid open for the whole run.

## Target: storage

The storage phase writes to `$HOME`. Its I/O goes through whatever that disk
is attached by: on an Ubuntu install on an external USB SSD, the profile
trains the USB storage stack (`uas`, `xhci`) instead of NVMe, which is what
most machines boot from. Prefer an install on internal NVMe; otherwise the
internal-NVMe phase below at least adds NVMe reads.

## Target: optional phases

Each of these skips cleanly when its setup is missing. None of them is in the
required set, but each adds kernel paths the others don't reach.

### ROCm

Runs a rocBLAS GEMM in a `rocm/rocm-terminal` container when `/dev/kfd`
exists; there is nothing to install on the host. The first run spends several
minutes installing rocBLAS and compiling `scripts/profile-gemm.cpp` inside the
container, before recording starts; the container is kept for later runs.
GPUs without precompiled rocBLAS kernels need `HSA_OVERRIDE_GFX_VERSION`:
gfx1150 (Strix Point) gets `11.0.0` automatically, others take
`AUTOFDO_HSA_GFX_VERSION` on the build host.

### Browser

Drives Firefox (the Ubuntu snap) through Selenium, from a venv at the default
path:

```bash
python3 -m venv ~/autofdo-load/.venv
~/autofdo-load/.venv/bin/pip install selenium
```

Selenium fetches a matching geckodriver on first use.

### Filesystems

One loopback image each of ext4, XFS, Btrfs and F2FS, mounted at
`/mnt/fsdiv-<fs>` and writable by you. Btrfs is mounted with zstd
compression, as distributions that default to Btrfs set it up. Run in bash:

```bash
sudo apt install xfsprogs btrfs-progs f2fs-tools cryptsetup
sudo mkdir -p /var/lib/prf-fs
for fs in ext4 xfs btrfs f2fs; do
  img=/var/lib/prf-fs/$fs.img
  opts=loop,nofail
  [ "$fs" = btrfs ] && opts=$opts,compress=zstd:1
  sudo truncate -s 2G "$img"
  if [ "$fs" = ext4 ]; then sudo mkfs.ext4 -q -F "$img"; else sudo mkfs.$fs -q "$img"; fi
  sudo mkdir -p /mnt/fsdiv-$fs
  echo "$img /mnt/fsdiv-$fs $fs $opts 0 0" | sudo tee -a /etc/fstab
done
sudo systemctl daemon-reload
sudo mount -a
for fs in ext4 xfs btrfs f2fs; do sudo chown "$USER:" /mnt/fsdiv-$fs; done
```

A fifth image carries ext4 on LUKS, unlocked at boot with a key file, so every
read and write passes through dm-crypt as on an encrypted install:

```bash
img=/var/lib/prf-fs/luks.img
sudo truncate -s 2G "$img"
head -c 64 /dev/urandom | sudo tee /etc/prf-fs-luks.key > /dev/null
sudo chmod 600 /etc/prf-fs-luks.key
sudo cryptsetup luksFormat --batch-mode "$img" /etc/prf-fs-luks.key
sudo cryptsetup open --key-file /etc/prf-fs-luks.key "$img" prf-luks
sudo mkfs.ext4 -q /dev/mapper/prf-luks
echo "prf-luks $img /etc/prf-fs-luks.key luks,nofail" | sudo tee -a /etc/crypttab
sudo mkdir -p /mnt/fsdiv-luks
echo "/dev/mapper/prf-luks /mnt/fsdiv-luks ext4 nofail 0 0" | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo mount /mnt/fsdiv-luks
sudo chown "$USER:" /mnt/fsdiv-luks
```

### Internal NVMe, read-only

Random reads from a large existing file on the internal NVMe (`nvme0n1`),
never writes: the job runs with fio's `--readonly`, and the mount is read-only
as well. Pick a partition with files over 200 MB on it, then add it with its
UUID and filesystem type from `lsblk -f`:

```bash
sudo mkdir -p /mnt/nvme-ro
echo 'UUID=<uuid> /mnt/nvme-ro <fstype> ro,noauto,nofail,x-systemd.automount 0 0' | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
```

For Btrfs, add `rescue=nologreplay` after `ro`; a read-only mount otherwise
still replays a dirty log.

### WireGuard

A real encrypted tunnel needs its far end in another network namespace; both
ends in one namespace would be routed over loopback. `scripts/profile-wg.sh`
builds that — `wg0` (10.99.0.1) here, `wg1` (10.99.0.2) in the `prf-wg`
namespace, joined by a veth pair — and the units below bring it up at boot
with an iperf3 server at the far end. Copy the script over from the build
host:

```bash
scp scripts/profile-wg.sh <user>@<target>:
```

Then on the target:

```bash
sudo install -m 755 ~/profile-wg.sh /usr/local/sbin/profile-wg.sh
printf '[Unit]\nDescription=Profiling WireGuard tunnel\nAfter=network.target\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/local/sbin/profile-wg.sh up\nExecStop=/usr/local/sbin/profile-wg.sh down\n\n[Install]\nWantedBy=multi-user.target\n' | sudo tee /etc/systemd/system/prf-wg.service
printf '[Unit]\nDescription=iperf3 at the far end of the profiling tunnel\nRequires=prf-wg.service\nAfter=prf-wg.service\nPartOf=prf-wg.service\n\n[Service]\nExecStart=/usr/sbin/ip netns exec prf-wg /usr/bin/iperf3 -s -B 10.99.0.2 -p 5202\nRestart=always\n\n[Install]\nWantedBy=multi-user.target\n' | sudo tee /etc/systemd/system/prf-wg-iperf3.service
sudo systemctl daemon-reload
sudo systemctl enable --now prf-wg.service prf-wg-iperf3.service
```

Check it with `iperf3 -c 10.99.0.2 -p 5202 -t 3`.

## The kernel under test

The recording is mapped onto the `vmlinux` in `work/<flavor>` on the build
host, so the target must run exactly that build — the run compares build IDs
and refuses anything else. Build and package it on the build host:

```bash
make all FLAVOR=x64v4
scp out/x64v4/linux-image-*.deb out/x64v4/linux-headers-*.deb <user>@<target>:
```

Install it on the target and boot it once:

```bash
sudo apt install ./linux-image-*.deb ./linux-headers-*.deb
sudo grub-reboot "Advanced options for Ubuntu>Ubuntu, with Linux 7.2.7-cachyos-x64v4"
sudo reboot
```

Use the version the build printed. Do not rebuild `work/<flavor>` between
installing and recording. If the target uses Secure Boot, read
[SAFETY.md](SAFETY.md) first.

Profile the flavor most people install: CI applies one profile to every
flavor, and it fits the flavor it was recorded on best. A profile recorded on
another flavor's kernel can be pinned for that flavor alone with
`AUTOFDO_PROFILE_SHA256_<flavor>`.

If `profiles/vmlinux.afdo` exists, the kernel is built with it, and the new
profile is recorded from an already optimised kernel. That is how AutoFDO is
normally refreshed and needs no special handling.

## Running

On the build host:

```bash
make profile-release HOST=<user>@<target> SECS=3600 FLAVOR=x64v4
```

Load setup takes a few minutes before recording starts, longer on the first
run while images download. The run then records for `SECS` seconds (default
3600, two to three laps) in `SEG`-second segments (default 300), and
conversion takes a few more minutes. It stops before uploading if a required
phase did not run, if one phase dominates the samples, if the recording is
thin compared to the shipped profile, or if the hot functions moved far from
it. Everything it leaves is in `profiles/`:

| File | Content |
|---|---|
| `vmlinux.afdo`, `vmlinux.afdo.meta` | the profile and where it came from |
| `profile-load.log` | load output, ending in which phases ran and which skipped |
| `phase-share.txt` | each phase's share of the recorded kernel samples |
| `hotset.txt` | the profile's top 100 functions |

After the upload, paste the printed `AUTOFDO_PROFILE_SHA256` into
`kernel.env`; release builds use only the pinned profile.

Settings, all environment variables on the build host:

| Variable | Default | Description |
|---|---|---|
| `STRICT` | `1` | fail before setup if core load tools are missing on the target |
| `AUTOFDO_REQUIRED_PHASES` | `cpu vm ipc storage files containers db web mixed net_loopback` | phases that must have run |
| `AUTOFDO_MAX_PHASE_SHARE` | `40` | most of the recorded samples (%) any one phase may contribute |
| `AUTOFDO_PHASES` | all | run only these phases, space-separated; for tuning one phase at a time |
| `AUTOFDO_NET_PEER` | this host | iperf3 server for the NIC phase, `<host>[:<port>]`, or `none` |
| `AUTOFDO_SETUP_TIMEOUT` | `1800` | seconds to wait for load setup |
| `AUTOFDO_PERIOD` | `1000003` | taken branches per sample |
| `AUTOFDO_CONVERT_JOBS` | `2` | segments converted in parallel |
| `MIN` | `80` | minimum sample-weighted match against the kernel, % |
| `AUTOFDO_MIN_SAMPLES` / `AUTOFDO_MIN_FUNCTIONS` | `50000000` / `1500` | absolute floors |
| `AUTOFDO_MIN_RATE_RATIO` | `0.5` | minimum samples per second relative to the shipped profile |
| `AUTOFDO_ACCEPT_HOTSET_DRIFT` | `0` | `1` accepts a hot set far from the shipped one, for the first run after changing the load |
| `AUTOFDO_HSA_GFX_VERSION` | auto | ROCm GFX override for GPUs without rocBLAS kernels |
| `AUTOFDO_WG_PEER` | `10.99.0.2` | far end of the WireGuard tunnel |
| `AUTOFDO_SELENIUM_PY` | `~/autofdo-load/.venv/bin/python3` | Python with Selenium, on the target |

When the build host serves iperf3 for the NIC phase, port 5203 on it must be
reachable from the target, from whichever of its addresses routes to the
build host (a laptop on both Wi-Fi and Ethernet may use the one ssh did not).
With ufw on the build host:

```bash
sudo ufw allow from <target-ip> to any port 5203
```

## Forks

Create a private repo for profiles and set `AUTOFDO_PROFILES_REPO` to it. Add
a read-only deploy key to that repo and its private half to your fork's
secrets as `AUTOFDO_DEPLOY_KEY`. The first `make profile-release` uploads a
profile and prints the hash to pin. Without the secret, release builds skip
the profile.
