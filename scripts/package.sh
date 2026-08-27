#!/usr/bin/env bash
# Add the CPU guard to the image package and build the flavor metapackage.
. "$(dirname "$0")/lib.sh"
require_flavor

REQUIRED_VENDOR=
case "$FLAVOR" in
    x64v3) REQUIRED_FLAGS="avx2 bmi2 fma movbe abm f16c xsave"
           BASELINE="x86-64-v3" ;;
    x64v4) REQUIRED_FLAGS="avx2 bmi2 fma movbe abm f16c xsave avx512f avx512bw avx512cd avx512dq avx512vl"
           BASELINE="x86-64-v4" ;;
    # -march=znver4 also emits AVX-512 VNNI, BF16, VBMI2 and GFNI. Some Intel
    # parts have those too, but this build is scheduled for AMD and untested
    # anywhere else, so the vendor is part of the requirement.
    znver4) REQUIRED_FLAGS="avx2 bmi2 fma movbe abm f16c xsave avx512f avx512bw avx512cd avx512dq avx512vl avx512_vnni avx512_bf16 avx512_vbmi2 avx512vbmi gfni vaes vpclmulqdq"
            REQUIRED_VENDOR=AuthenticAMD
            BASELINE="AMD Zen 4" ;;
    *) die "no CPU requirement defined for flavor $FLAVOR" ;;
esac

image_deb=$(find "$OUTDIR" -maxdepth 1 -name "linux-image-${KRELEASE}_*.deb" | head -1)
[ -n "$image_deb" ] || die "no image package in $OUTDIR — run: make build"

## ---- CPU guard -----------------------------------------------------------
tmp=$(mktemp -d) && trap 'rm -rf "$tmp"' EXIT
dpkg-deb -R "$image_deb" "$tmp/pkg"

guard="$tmp/guard"
cat > "$guard" <<EOF
case "\$1" in
install|upgrade)
    if [ -n "$REQUIRED_VENDOR" ] && ! grep -q "^vendor_id.*$REQUIRED_VENDOR" /proc/cpuinfo; then
        echo "This CPU is not $REQUIRED_VENDOR." >&2
        echo "linux-image-$KRELEASE is compiled for $BASELINE and is not supported here." >&2
        exit 1
    fi
    missing=
    for f in $REQUIRED_FLAGS; do
        grep -qw "\$f" /proc/cpuinfo || missing="\$missing \$f"
    done
    if [ -n "\$missing" ]; then
        echo "This CPU is missing:\$missing" >&2
        echo "linux-image-$KRELEASE is compiled for $BASELINE and would not boot." >&2
        exit 1
    fi
    ;;
esac
EOF

if grep -q 'This CPU is missing' "$tmp/pkg/DEBIAN/preinst" 2>/dev/null; then
    guard_state="already present"
elif [ -f "$tmp/pkg/DEBIAN/preinst" ]; then
    { head -1 "$tmp/pkg/DEBIAN/preinst"; cat "$guard"; tail -n +2 "$tmp/pkg/DEBIAN/preinst"; } \
        > "$tmp/preinst.new"
    mv "$tmp/preinst.new" "$tmp/pkg/DEBIAN/preinst"
else
    { echo '#!/bin/sh'; echo 'set -e'; cat "$guard"; echo 'exit 0'; } > "$tmp/pkg/DEBIAN/preinst"
fi
chmod 755 "$tmp/pkg/DEBIAN/preinst"

## ---- Secure Boot ---------------------------------------------------------
# Sign the image with the machine's own MOK, the key Ubuntu already generates
# for DKMS and that anyone running out-of-tree modules under Secure Boot has
# already enrolled. Nothing is signed by this project, so there is no private
# key to hold and no new enrolment to ask for. In-tree modules need no help:
# their signing key's certificate is built into the kernel's own keyring.
#
# Deliberately fail-soft. An unsigned image boots normally with Secure Boot
# off, so a missing key or tool is a notice, not a failed install.
sb="$tmp/secureboot"
cat > "$sb" <<EOF
mok=/var/lib/shim-signed/mok
img=/boot/vmlinuz-$KRELEASE
if [ -f "\$img" ] && command -v sbsign >/dev/null 2>&1 \\
   && command -v openssl >/dev/null 2>&1 \\
   && [ -f "\$mok/MOK.priv" ] && [ -f "\$mok/MOK.der" ]; then
    # shim stores the certificate DER-encoded, which is what kmodsign wants for
    # modules. sbsign takes PEM, so convert rather than hand it the DER and get
    # an opaque failure.
    pem=\$(mktemp) || pem=/tmp/mok.\$\$.pem
    if openssl x509 -inform DER -in "\$mok/MOK.der" -outform PEM -out "\$pem" 2>/dev/null; then
        if sbverify --cert "\$pem" "\$img" >/dev/null 2>&1; then
            echo "Secure Boot: \$img already signed with the machine MOK."
        elif err=\$(sbsign --key "\$mok/MOK.priv" --cert "\$pem" \\
                    --output "\$img.signed" "\$img" 2>&1); then
            mv "\$img.signed" "\$img"
            echo "Secure Boot: signed \$img with the machine MOK."
        else
            rm -f "\$img.signed"
            echo "Secure Boot: signing \$img failed; it will not boot with Secure Boot on." >&2
            echo "Secure Boot: \$err" >&2
        fi
    else
        echo "Secure Boot: could not read \$mok/MOK.der; \$img left unsigned." >&2
    fi
    rm -f "\$pem"
elif [ -d /sys/firmware/efi ] && [ "\$(mokutil --sb-state 2>/dev/null)" = "SecureBoot enabled" ]; then
    echo "Secure Boot is enabled but no machine MOK was found." >&2
    echo "Install sbsigntool and shim-signed, then reinstall this package, or" >&2
    echo "disable Secure Boot. Otherwise $KRELEASE will not boot." >&2
fi
EOF

# The generated postinst ends in `exit 0` and runs the kernel hooks before it,
# so the block goes in ahead of those: initramfs and grub then see the signed
# image rather than the one it replaced.
python3 - "$tmp/pkg/DEBIAN/postinst" "$sb" <<'PYEOF'
import pathlib, sys

BEGIN = "# >>> linux-cachyos-deb secure boot\n"
END = "# <<< linux-cachyos-deb secure boot\n"
post = pathlib.Path(sys.argv[1])
block = BEGIN + pathlib.Path(sys.argv[2]).read_text() + END

if not post.exists():
    post.write_text("#!/bin/sh\nset -e\n" + block + "exit 0\n")
    print("added")
else:
    text = post.read_text()
    # Drop any block from an earlier packaging run, so repackaging replaces it
    # rather than keeping the first version forever.
    verb = "added"
    if BEGIN in text and END in text:
        head, rest = text.split(BEGIN, 1)
        text = head + rest.split(END, 1)[1]
        verb = "replaced"
    # Packages built before the markers existed carry an unmarked block. Strip
    # it by shape, or repackaging stacks a second copy on top of the first.
    lines = text.splitlines(keepends=True)
    try:
        start = next(i for i, l in enumerate(lines)
                     if l.startswith("mok=/var/lib/shim-signed/mok"))
        end = next(i for i in range(start, len(lines)) if lines[i].rstrip() == "fi")
        del lines[start:end + 1]
        text = "".join(lines)
        verb = "replaced"
    except StopIteration:
        pass
    lines = text.splitlines(keepends=True)
    for i, l in enumerate(lines):
        if l.startswith("# run-parts will error out") or l.startswith("exit 0"):
            cut = i
            break
    else:
        cut = len(lines)
    post.write_text("".join(lines[:cut]) + block + "".join(lines[cut:]))
    print(verb)
PYEOF
chmod 755 "$tmp/pkg/DEBIAN/postinst"

# Recommends rather than Depends: the signing hook is a no-op without them and
# the kernel boots fine with Secure Boot off, but apt installs Recommends by
# default, so a Secure Boot machine gets what it needs without being told.
python3 - "$tmp/pkg/DEBIAN/control" <<'PYEOF'
import pathlib, sys

ctl = pathlib.Path(sys.argv[1])
lines = ctl.read_text().splitlines()
if not any(l.startswith('Recommends:') for l in lines):
    i = next(n for n, l in enumerate(lines) if l.startswith('Architecture:'))
    lines.insert(i + 1, 'Recommends: sbsigntool, shim-signed, mokutil')
    ctl.write_text('\n'.join(lines) + '\n')
PYEOF
say "Secure Boot signing hook installed"
# --root-owner-group: the container builds as the caller's uid, which would
# otherwise ship /boot and /lib/modules owned by that user.
dpkg-deb --root-owner-group -b "$tmp/pkg" "$image_deb" >/dev/null
say "CPU guard ${guard_state:-added}: $REQUIRED_FLAGS"

## ---- headers toolchain dependency ----------------------------------------
# A CONFIG_LTO_CLANG kernel can only have modules built against it by clang, so
# DKMS needs the toolchain present, at the version the kernel was built with.
if [ "$LLVM_VERSION" = distro ]; then
    TOOLCHAIN_DEP="clang, lld, llvm"
else
    TOOLCHAIN_DEP="clang-$LLVM_VERSION, lld-$LLVM_VERSION, llvm-$LLVM_VERSION"
fi
headers_deb=$(find "$OUTDIR" -maxdepth 1 -name "linux-headers-${KRELEASE}_*.deb" | head -1)
if [ -n "$headers_deb" ]; then
    dpkg-deb -R "$headers_deb" "$tmp/hdr"
    ctl="$tmp/hdr/DEBIAN/control"
    # Drop any toolchain entry from an earlier run before adding the current
    # one, so repackaging converges instead of keeping the first value.
    python3 - "$ctl" "$TOOLCHAIN_DEP" <<'PYEOF'
import re, sys

path, dep = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
out, seen = [], False
for line in lines:
    if line.startswith('Depends:'):
        seen = True
        kept = [t.strip() for t in line[len('Depends:'):].split(',') if t.strip()]
        kept = [t for t in kept if not re.match(r'^(clang|lld|llvm)(-\d+)?\b', t)]
        out.append('Depends: ' + ', '.join([dep] + kept))
    else:
        out.append(line)
if not seen:
    i = next(n for n, l in enumerate(out) if l.startswith('Architecture:'))
    out.insert(i + 1, 'Depends: ' + dep)
open(path, 'w').write('\n'.join(out) + '\n')
PYEOF
    # bindeb-pkg leaves .config out of the headers tree; Ubuntu, Debian and
    # XanMod all ship it. DKMS modules read it to decide which toolchain to
    # build with, and without it they see no CONFIG_CC_IS_CLANG and fall back
    # to gcc against an LTO/clang kernel.
    hdrdir="$tmp/hdr/usr/src/linux-headers-$KRELEASE"
    if [ -d "$hdrdir" ] && [ -f "$OBJDIR/.config" ]; then
        cp "$OBJDIR/.config" "$hdrdir/.config"
        say "headers: shipped .config"
    fi
    dpkg-deb --root-owner-group -b "$tmp/hdr" "$headers_deb" >/dev/null
    say "headers depend on: $TOOLCHAIN_DEP"
fi

## ---- metapackage ---------------------------------------------------------
meta="$tmp/meta"
mkdir -p "$meta/DEBIAN" "$meta/usr/share/doc/linux-cachyos-$FLAVOR"
cat > "$meta/DEBIAN/control" <<EOF
Package: linux-cachyos-$FLAVOR
Version: $PKGVERSION
Section: kernel
Priority: optional
Architecture: amd64
Maintainer: $MAINTAINER
Depends: linux-image-$KRELEASE (= $PKGVERSION), linux-headers-$KRELEASE (= $PKGVERSION)
Description: CachyOS kernel for Ubuntu ($BASELINE)
 Metapackage pulling in the current CachyOS-patched kernel image and headers
 built for $BASELINE. Ubuntu's own kernel is left installed and remains
 selectable in GRUB.
EOF
dpkg-deb --root-owner-group -b "$meta" "$OUTDIR/linux-cachyos-${FLAVOR}_${PKGVERSION}_amd64.deb" >/dev/null

say "packages in out/$FLAVOR:"
ls -1sh "$OUTDIR"
