#!/usr/bin/env bash
# Push a freshly generated AutoFDO profile to the private companion repo that CI
# clones at build time. Called after make profile. The deploy-key secret on the
# CI side stays unchanged — it only reads.
#
#   scripts/profile-upload.sh [profile-path]
#
# Defaults to $AUTOFDO_PROFILE. Pushes with the user's gh credentials (the host
# that generates the profile owns the repo); the CI side keeps read-only.
. "$(dirname "$0")/lib.sh"

PROFILE="${1:-$ROOT/${AUTOFDO_PROFILE:-profiles/vmlinux.afdo}}"
[ -f "$PROFILE" ] || die "no profile at $PROFILE — run: make profile HOST=<host> first"
[ -n "$(command -v gh)" ] || die "gh not installed"
REPO="fabianwimberger/linux-cachyos-deb-profiles"

say "uploading $(basename "$PROFILE") ($(du -h "$PROFILE" | cut -f1)) to $REPO"

tmp=$(mktemp -d) && trap 'rm -rf "$tmp"' EXIT
git clone --quiet "https://github.com/$REPO.git" "$tmp/profiles" || die "clone failed"
cp "$PROFILE" "$tmp/profiles/vmlinux.afdo"
sha_before=$(git -C "$tmp/profiles" rev-parse --short HEAD)
git -C "$tmp/profiles" add vmlinux.afdo
if git -C "$tmp/profiles" diff --cached --quiet; then
    say "profile unchanged since $sha_before — nothing to push"
    exit 0
fi
git -C "$tmp/profiles" -c user.name="linux-cachyos-deb" \
    -c user.email="noreply@users.noreply.github.com" commit -qm "autofdo profile $(date -u +%Y-%m-%dT%H:%M:%SZ)"
git -C "$tmp/profiles" push --quiet origin main || die "push failed"
say "pushed; CI will pick it up on the next build"
