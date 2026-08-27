#!/usr/bin/env bash
# Run a build stage in the pinned Ubuntu container.
. "$(dirname "$0")/lib.sh"

IMAGE=${IMAGE:-linux-cachyos-deb:$UBUNTU_SERIES}
[ $# -ge 1 ] || die "usage: incontainer.sh <script> [args...]"

docker image inspect "$IMAGE" >/dev/null 2>&1 || die "image $IMAGE missing — run: make image"

args=()
# An empty SOURCE_DATE_EPOCH is rejected by rustc and by the kernel's fixdep.
[ -n "${SOURCE_DATE_EPOCH:-}" ] && args+=(-e "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH")

exec docker run --rm \
    -v "$ROOT:/work" \
    -w /work \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e FLAVOR="$FLAVOR" \
    -e JOBS="$JOBS" \
    "${args[@]}" \
    "$IMAGE" "$@"
