#!/usr/bin/env bash
# Pre-build gates: toolchain, image, keys, disk.
. "$(dirname "$0")/lib.sh"

fail=0
check() { if eval "$2" >/dev/null 2>&1; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; fail=1; fi; }

check "docker present"            "command -v docker"
check "docker usable"             "docker info"
check "builder image built"       "docker image inspect linux-cachyos-deb:$UBUNTU_SERIES"
check "base config present"       "[ -f '$ROOT/$UBUNTU_BASE_CONFIG' ]"
check "upstream keys present"     "[ -s '$ROOT/keys/cachyos-upstream.asc' ]"
check "gpgv present"              "command -v gpgv"

# On btrfs, objtool writes vmlinux.o through mmap, and dirtying a COW'd or
# compressed page that way goes through the writeback fixup worker, which
# livelocks on 7.2 — the build then sits in uninterruptible sleep until the
# machine is rebooted. nodatacow keeps the objtree off that path, and skips
# compressing 16 GB of object files. New files inherit the flag.
if [ "$(stat -f -c %T "$ROOT")" = btrfs ]; then
    mkdir -p "$ROOT/work"
    if lsattr -d "$ROOT/work" 2>/dev/null | cut -d' ' -f1 | grep -q C; then
        printf '  ok   work/ is nodatacow\n'
    elif chattr +C "$ROOT/work" 2>/dev/null; then
        printf '  ok   work/ set to nodatacow\n'
    else
        printf '  FAIL work/ is on btrfs and not nodatacow: chattr +C work\n'; fail=1
    fi
fi

avail=$(df -BG --output=avail "$ROOT" | tail -1 | tr -dc '0-9')
if [ "${avail:-0}" -ge 60 ]; then
    printf '  ok   disk: %sG free\n' "$avail"
else
    printf '  FAIL disk: %sG free, want 60G+ per flavor\n' "$avail"; fail=1
fi

[ "$fail" = 0 ] || die "preflight failed"
say "preflight passed"
