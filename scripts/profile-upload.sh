#!/usr/bin/env bash
# Push a freshly generated AutoFDO profile to the private companion repo
# ($AUTOFDO_PROFILES_REPO) that CI clones at build time. Called by
# scripts/profile-release.sh after the profile passed its gates. The
# deploy-key secret on the CI side stays unchanged — it only reads.
#
#   scripts/profile-upload.sh
#
# Layout of the profiles repo:
#   afdo/<sha256>.afdo, .meta   every profile ever shipped, by content; CI
#                               applies the one kernel.env pins, so rebuilding
#                               an old tag rebuilds it with its own profile
#   vmlinux.afdo, .meta         the latest profile
#   hotset.txt                  its top-100 functions, the next run's drift
#                               reference
# Pushes with the user's gh credentials (the host that generates the profile
# owns the repo).
. "$(dirname "$0")/lib.sh"

PROFILE="$ROOT/$AUTOFDO_PROFILE"
[ -f "$PROFILE" ] || die "no profile at $PROFILE — run: make profile HOST=<host> first"
[ -f "$PROFILE.meta" ] && [ -f "$ROOT/profiles/hotset.txt" ] \
    || die "no metadata or hotset next to the profile — run: make profile-report first"
command -v gh >/dev/null || die "gh not installed"
REPO=$AUTOFDO_PROFILES_REPO
sha=$(sha256sum "$PROFILE" | cut -d' ' -f1)

say "uploading $(basename "$PROFILE") ($(du -h "$PROFILE" | cut -f1), sha256 $sha) to $REPO"

tmp=$(mktemp -d) && trap 'rm -rf "$tmp"' EXIT
git clone --quiet "https://github.com/$REPO.git" "$tmp/profiles" || die "clone failed"
mkdir -p "$tmp/profiles/afdo"
cp "$PROFILE" "$tmp/profiles/vmlinux.afdo"
cp "$PROFILE" "$tmp/profiles/afdo/$sha.afdo"
cp "$PROFILE.meta" "$tmp/profiles/vmlinux.afdo.meta"
cp "$PROFILE.meta" "$tmp/profiles/afdo/$sha.meta"
cp "$ROOT/profiles/hotset.txt" "$tmp/profiles/hotset.txt"
sha_before=$(git -C "$tmp/profiles" rev-parse --short HEAD)
git -C "$tmp/profiles" add -A
if git -C "$tmp/profiles" diff --cached --quiet; then
    say "profile unchanged since $sha_before — nothing to push"
else
    git -C "$tmp/profiles" -c user.name="linux-cachyos-deb" \
        -c user.email="noreply@users.noreply.github.com" commit -qm "autofdo profile $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    git -C "$tmp/profiles" push --quiet origin main || die "push failed"
    say "pushed"
fi

# What was just shipped is the reference the next run is compared against.
cp "$ROOT/profiles/hotset.txt" "$ROOT/profiles/hotset-reference.txt"
cp "$PROFILE.meta" "$ROOT/profiles/previous.meta"

if [ "${AUTOFDO_PROFILE_SHA256:-}" = "$sha" ]; then
    say "kernel.env already pins this profile"
else
    say "CI builds with the pinned profile only; pin this one in kernel.env:"
    printf '\n    AUTOFDO_PROFILE_SHA256=%s\n\n' "$sha"
fi
