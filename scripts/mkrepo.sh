#!/usr/bin/env bash
# Assemble a flat apt repository from out/. Runs in the container.
# Flat layout: GitHub release assets have no directory structure.
# Signing happens on the host, in scripts/sign-repo.sh.
. "$(dirname "$0")/lib.sh"

REPO="$ROOT/repo"
rm -rf "$REPO"
mkdir -p "$REPO"

found=0
for f in $FLAVORS; do
    if compgen -G "$ROOT/out/$f/*.deb" >/dev/null; then
        cp "$ROOT/out/$f"/*.deb "$REPO/"
        found=1
    fi
done
[ "$found" = 1 ] || die "no packages in out/ — run: make build package"

cd "$REPO" || exit 1
dpkg-scanpackages --multiversion . /dev/null > Packages 2>/dev/null
# Flat repos resolve Filename against the repo URL; drop the leading ./
sed -i 's|^Filename: \./|Filename: |' Packages
gzip -9kf Packages

apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=linux-cachyos-deb \
    -o APT::FTPArchive::Release::Label=linux-cachyos-deb \
    -o APT::FTPArchive::Release::Suite=stable \
    -o APT::FTPArchive::Release::Architectures=amd64 \
    release . > Release

say "repo/ contains $(grep -c '^Package:' Packages) packages"
