#!/usr/bin/env bash
# Sign repo/Release with the repository key. Runs on the host.
# REPO_SIGN_KEY is a gpg key id or fingerprint. Empty, or naming a key this
# keyring has no secret half of (a fork building with the default from
# kernel.env), leaves the repo unsigned, which apt accepts only with
# [trusted=yes]. The release workflow checks for InRelease itself.
. "$(dirname "$0")/lib.sh"

REPO="$ROOT/repo"
[ -f "$REPO/Release" ] || die "no repo/Release — run: make repo"

if [ -z "${REPO_SIGN_KEY:-}" ]; then
    say "REPO_SIGN_KEY empty — leaving repo unsigned"
    exit 0
fi
if ! gpg --batch --list-secret-keys "$REPO_SIGN_KEY" >/dev/null 2>&1; then
    say "no secret key for $REPO_SIGN_KEY here — leaving repo unsigned"
    exit 0
fi

gpg --batch --yes --local-user "$REPO_SIGN_KEY" --clearsign -o "$REPO/InRelease" "$REPO/Release"
gpg --batch --yes --local-user "$REPO_SIGN_KEY" -abs -o "$REPO/Release.gpg" "$REPO/Release"
gpg --export "$REPO_SIGN_KEY" > "$REPO/linux-cachyos-deb-archive-keyring.gpg"

say "signed with $REPO_SIGN_KEY"
