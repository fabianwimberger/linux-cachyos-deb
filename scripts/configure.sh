#!/usr/bin/env bash
# Generate work/<flavor>/.config. Runs in the container.
# Base is Ubuntu's generic config; olddefconfig reconciles it with the 7.2 tree.
. "$(dirname "$0")/lib.sh"
require_flavor

[ -d "$SRCDIR" ] || die "no source tree — run: make fetch"

# Generated .cmd files record absolute toolchain include paths, so an objtree
# cannot be reused across a toolchain change: the build fails partway through
# tools/objtool looking for the old clang's headers.
STAMP="$OBJDIR/.toolchain"
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" != "$LLVM_VERSION" ]; then
    die "work/$FLAVOR was built with LLVM_VERSION=$(cat "$STAMP"), now $LLVM_VERSION — delete work/$FLAVOR and re-run"
fi

mkdir -p "$OBJDIR"
printf '%s\n' "$LLVM_VERSION" > "$STAMP"
MAKE=(make -C "$SRCDIR" O="$OBJDIR" LLVM="$LLVM_MAKE" LLVM_IAS=1 -j"$JOBS")
CONFIG="$SRCDIR/scripts/config --file $OBJDIR/.config"

say "base: $UBUNTU_BASE_CONFIG"
cp "$ROOT/$UBUNTU_BASE_CONFIG" "$OBJDIR/.config"
"${MAKE[@]}" olddefconfig >/dev/null

# The release string comes from LOCALVERSION on the make command line.
# shellcheck disable=SC2086
$CONFIG --set-str LOCALVERSION "" -d LOCALVERSION_AUTO
rm -f "$SRCDIR"/localversion* "$OBJDIR"/localversion*

for frag in cachy cachy-extras ubuntu-compat "$FLAVOR"; do
    say "applying config/fragments/$frag.conf"
    while read -r line; do
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac
        # eval preserves quoting for --set-str values.
        eval "$CONFIG $line"
    done < "$ROOT/config/fragments/$frag.conf"
done

"${MAKE[@]}" olddefconfig >/dev/null

say "config: $(grep -c '=y$' "$OBJDIR/.config") builtin, $(grep -c '=m$' "$OBJDIR/.config") modules"
exec "$ROOT/scripts/verify-config.sh"
