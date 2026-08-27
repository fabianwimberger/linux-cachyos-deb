# shellcheck shell=bash
set -euo pipefail
# shellcheck disable=SC2034  # consumers of this library use these

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
# shellcheck disable=SC1091
. "$ROOT/kernel.env"

FLAVOR=${FLAVOR:-x64v4}
# LLVM=1 uses the unsuffixed binaries; LLVM=-<n> the suffixed ones.
[ "$LLVM_VERSION" = distro ] && LLVM_MAKE=1 || LLVM_MAKE="-$LLVM_VERSION"
JOBS=${JOBS:-$(nproc)}

TARBALL="$ROOT/src/$CACHY_TAG.tar.gz"
SRCDIR="$ROOT/src/$CACHY_TAG"
OBJDIR="$ROOT/work/$FLAVOR"
OUTDIR="$ROOT/out/$FLAVOR"

# uname -r of the resulting kernel
KRELEASE="$KERNEL_VERSION-cachyos-$FLAVOR"
# Debian version of the resulting packages
PKGVERSION="$KERNEL_VERSION-$PKGREL"

say() { printf '>> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

require_flavor() {
    [ -f "$ROOT/config/fragments/$FLAVOR.conf" ] \
        || die "unknown flavor '$FLAVOR' (no config/fragments/$FLAVOR.conf)"
}
