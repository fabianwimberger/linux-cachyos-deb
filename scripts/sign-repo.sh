#!/usr/bin/env bash
# Sign repo/Release with the repository key. Runs on the host.
# REPO_SIGN_KEY is a gpg key id or fingerprint. Unset leaves the repo unsigned,
# which apt accepts only with [trusted=yes].
. "$(dirname "$0")/lib.sh"

REPO="$ROOT/repo"
[ -f "$REPO/Release" ] || die "no repo/Release — run: make repo"

if [ -z "${REPO_SIGN_KEY:-}" ]; then
    say "REPO_SIGN_KEY unset — leaving repo unsigned"
    exit 0
fi

gpg --batch --yes --local-user "$REPO_SIGN_KEY" --clearsign -o "$REPO/InRelease" "$REPO/Release"
gpg --batch --yes --local-user "$REPO_SIGN_KEY" -abs -o "$REPO/Release.gpg" "$REPO/Release"
gpg --export "$REPO_SIGN_KEY" > "$REPO/linux-cachyos-deb-archive-keyring.gpg"

say "signed with $REPO_SIGN_KEY"
