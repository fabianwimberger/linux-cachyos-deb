#!/usr/bin/env bash
# Move the build inputs to another CachyOS release: pin the tarball SHA-256 in kernel.env, reset
# PKGREL, rewrite the version references in SOURCE-OFFER.md and run check-release.sh.
#   make bump TAG=cachyos-7.3.6-1
# Nothing is downloaded or built here; `make fetch` still verifies hash and signature.
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

new_tag=${1:-}
[[ $new_tag =~ ^cachyos-([0-9]+\.[0-9]+\.[0-9]+)-[0-9]+$ ]] || die "usage: make bump TAG=cachyos-<kernel version>-<n>"
new_version=${BASH_REMATCH[1]}
[[ $new_tag != "$CACHY_TAG" ]] || die "kernel.env is already at $new_tag"

old_tag=$CACHY_TAG old_version=$KERNEL_VERSION old_sha=$CACHY_SHA256
old_release=v$KERNEL_VERSION
[[ $PKGREL == 1 ]] || old_release=v$PKGVERSION

# GitHub publishes the SHA-256 of every release asset; stream the tarball only if it is missing.
repo=CachyOS/linux
sha=$(gh api "repos/$repo/releases/tags/$new_tag" \
    --jq ".assets[] | select(.name == \"$new_tag.tar.gz\") | .digest" 2>/dev/null | sed -n 's/^sha256://p') || true
if [[ ! $sha =~ ^[0-9a-f]{64}$ ]]; then
    say "no digest on the release, hashing the tarball while streaming it"
    sha=$(curl -fsSL "https://github.com/$repo/releases/download/$new_tag/$new_tag.tar.gz" | sha256sum | cut -d' ' -f1)
fi
[[ $sha =~ ^[0-9a-f]{64}$ ]] || die "could not get a SHA-256 for $new_tag"

sed -i \
    -e "s/^KERNEL_VERSION=.*/KERNEL_VERSION=$new_version/" \
    -e "s/^CACHY_TAG=.*/CACHY_TAG=$new_tag/" \
    -e "s/^CACHY_SHA256=.*/CACHY_SHA256=$sha/" \
    -e "s/^PKGREL=.*/PKGREL=1/" kernel.env

# The offer names the tag, version, hash and the repository tag a rebuild checks out.
new_release=v$new_version
OLD_TAG=$old_tag NEW_TAG=$new_tag OLD_V=$old_version NEW_V=$new_version OLD_REL=$old_release NEW_REL=$new_release \
OLD_SHA=$old_sha NEW_SHA=$sha \
    perl -pi -e '
        s/\Q$ENV{OLD_TAG}\E/$ENV{NEW_TAG}/g;
        s/\Q$ENV{OLD_SHA}\E/$ENV{NEW_SHA}/g;
        s/\Q$ENV{OLD_REL}\E(?![0-9.])/$ENV{NEW_REL}/g;
        s/CachyOS Linux \Q$ENV{OLD_V}\E/CachyOS Linux $ENV{NEW_V}/g;
        s/linux-image-\Q$ENV{OLD_V}\E-cachyos/linux-image-$ENV{NEW_V}-cachyos/g;
    ' SOURCE-OFFER.md

if bash scripts/check-release.sh >/dev/null; then
    echo "BUMP OK $old_tag -> $new_tag  sha256 ${sha:0:12}...  PKGREL=1  check-release passes; still to do: CHANGELOG entry, make fetch (signature), config refresh"
else
    echo "BUMP NOT OK $new_tag: kernel.env and SOURCE-OFFER.md were edited but check-release.sh fails; run it to see why"
    exit 1
fi
