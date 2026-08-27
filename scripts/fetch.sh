#!/usr/bin/env bash
# Download, verify and extract the CachyOS source tarball.
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

BASE_URL="https://github.com/CachyOS/linux/releases/download/$CACHY_TAG"
mkdir -p "$ROOT/src"

for f in "$CACHY_TAG.tar.gz" "$CACHY_TAG.tar.gz.asc"; do
    if [ -s "$ROOT/src/$f" ]; then
        say "have src/$f"
    else
        say "fetching $f"
        curl -fL --retry 3 --progress-bar -o "$ROOT/src/$f.part" "$BASE_URL/$f"
        mv "$ROOT/src/$f.part" "$ROOT/src/$f"
    fi
done

say "verifying signature"
keyring=$(mktemp) && trap 'rm -f "$keyring"' EXIT
gpg --dearmor < "$ROOT/keys/cachyos-upstream.asc" > "$keyring"
gpgv --keyring "$keyring" "$TARBALL.asc" "$TARBALL" || die "signature verification failed"

actual=$(sha256sum "$TARBALL" | cut -d' ' -f1)
if [ -z "${CACHY_SHA256:-}" ]; then
    say "no hash pinned; add to kernel.env:"
    printf '\n    CACHY_SHA256=%s\n\n' "$actual"
elif [ "$actual" != "$CACHY_SHA256" ]; then
    die "sha256 mismatch: expected $CACHY_SHA256, got $actual"
else
    say "sha256 matches pin"
fi

if [ -d "$SRCDIR" ]; then
    say "already extracted: src/$CACHY_TAG"
else
    say "extracting"
    tar -C "$ROOT/src" -xf "$TARBALL"
    [ -d "$SRCDIR" ] || die "tarball did not contain $CACHY_TAG/"
fi

# Patches are applied once, right after extraction.
if [ ! -f "$SRCDIR/.patched" ]; then
    for p in "$ROOT"/patches/*.patch; do
        [ -e "$p" ] || continue
        say "applying $(basename "$p")"
        patch -Np1 -d "$SRCDIR" < "$p" || die "patch failed: $p"
    done
    touch "$SRCDIR/.patched"
fi

say "source ready: $SRCDIR"
