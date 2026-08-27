#!/usr/bin/env bash
# Build the kernel and produce .debs. Runs in the container.
. "$(dirname "$0")/lib.sh"
require_flavor

[ -f "$OBJDIR/.config" ] || die "no config — run: make config"

export DEBEMAIL="${MAINTAINER#*<}"; DEBEMAIL="${DEBEMAIL%>}"
export DEBFULLNAME="${MAINTAINER%% <*}"
export KDEB_CHANGELOG_DIST="$UBUNTU_SERIES"

SOURCENAME=linux-cachyos
# The -dbg package is ~1.4 GB and costs an objcopy pass over every module.
# Debug info itself stays: DEBUG_INFO_BTF depends on !DEBUG_INFO_REDUCED, and
# vmlinux in work/ keeps its symbols.
export DEB_BUILD_PROFILES="pkg.$SOURCENAME.nokerneldbg"

MAKE=(make -C "$SRCDIR" O="$OBJDIR" LLVM="$LLVM_MAKE" LLVM_IAS=1 -j"$JOBS"
      LOCALVERSION="-cachyos-$FLAVOR"
      KDEB_PKGVERSION="$PKGVERSION"
      KDEB_SOURCENAME="$SOURCENAME")

# With CONFIG_AUTOFDO_CLANG=y and no profile, clang only adjusts debug info.
# Passing one turns on the optimisation. Absent is normal, not an error: it is
# how the kernel that a profile gets collected from is built.
if [ -n "${AUTOFDO_PROFILE:-}" ] && [ -f "$ROOT/$AUTOFDO_PROFILE" ]; then
    MAKE+=(CLANG_AUTOFDO_PROFILE="$ROOT/$AUTOFDO_PROFILE")
    say "autofdo profile: $AUTOFDO_PROFILE"
else
    say "autofdo profile: none (instrumented build, no optimisation applied)"
fi

mkdir -p "$OUTDIR"
say "building $KRELEASE on $JOBS threads"
"${MAKE[@]}" bindeb-pkg 2>&1 | tee "$OBJDIR/build.log" \
    | grep -E '^\s*(CC|LD|AR|BTF|LTO|GEN|DPKG|INSTALL)' \
    | awk 'NR%500==0 {print "   ... "$0}'

# bindeb-pkg writes into the objtree's parent for O= builds.
found=$(find "$ROOT/work" "$ROOT/src" -maxdepth 1 -name '*.deb' -newer "$OBJDIR/.config")
[ -n "$found" ] || die "no .debs produced — see $OBJDIR/build.log"

for deb in $found; do
    case "$(basename "$deb")" in
        # linux-libc-dev collides with Ubuntu's libc6-dev.
        linux-libc-dev_*|*-dbg_*) mv "$deb" "$OBJDIR/" ;;
        *) mv "$deb" "$OUTDIR/" ;;
    esac
done

say "packages:"
ls -1sh "$OUTDIR"
