#!/usr/bin/env bash
. "$(dirname "$0")/lib.sh"

expected="v$PKGVERSION"
if [[ $PKGREL == 1 ]]; then
    expected="v$KERNEL_VERSION"
fi
offer=SOURCE-OFFER.md
tag=${1:-$(sed -n 's/^git checkout //p' "$offer")}
if [[ $tag != "$expected" && $tag != "v$PKGVERSION" ]]; then
    die "tag $tag does not match kernel.env ($expected)"
fi
[[ $CACHY_TAG == "cachyos-$KERNEL_VERSION-"* ]] || die "CACHY_TAG does not match kernel $KERNEL_VERSION"
[[ $CACHY_SHA256 =~ ^[0-9a-f]{64}$ ]] || die "kernel.env must pin the tarball SHA-256"

repository="https://github.com/${GITHUB_REPOSITORY:-fabianwimberger/linux-cachyos-deb}"
tarball="https://github.com/CachyOS/linux/releases/download/$CACHY_TAG/$CACHY_TAG.tar.gz"
tag_tree="$repository/tree/$tag"

require_offer() {
    grep -Fq -- "$1" "$offer" || die "$offer must contain $1"
}

check_source_links() {
    local file=$1 url
    while IFS= read -r url; do
        case "$url" in
            "$tarball"|"$tarball.asc"|"$tag_tree"|"$tag_tree/"*|"$repository/blob/$tag/"*) ;;
            https://github.com/CachyOS/linux/releases/download/cachyos-*|"$repository/tree/v"*|"$repository/blob/v"*|\
            "$repository/blob/"*/SOURCE-OFFER.md|"$repository/blob/"*/kernel.env)
                die "$file points to a different source version: $url"
                ;;
        esac
    done < <(grep -Eo 'https://[^[:space:]()<>`|#]+' <<< "$2")
}

check_version_prefix() {
    local field=$1 text=$2 version='[0-9]+\.[0-9]+\.[0-9]+' end='([^[:alnum:].-]|[.]([[:space:]]|$)|$)'
    if [[ $text =~ ^[[:space:]]*(v$version(-[0-9]+)?)$end ]]; then
        [[ ${BASH_REMATCH[1]} == "$tag" ]] || die "$field must match tag $tag"
        text=${text#"${BASH_REMATCH[0]}"}
        text=${text#—}
        text=${text#-}
    fi
    if [[ $text =~ ^[[:space:]]*(Linux|CachyOS([[:space:]]+Linux)?)[[:space:]]+($version)(-[0-9]+)?$end ]]; then
        [[ ${BASH_REMATCH[3]} == "$KERNEL_VERSION" ]] || die "$field must match kernel $KERNEL_VERSION"
    fi
}

require_offer "CachyOS Linux $KERNEL_VERSION source tarball | $tarball |"
require_offer "\`$CACHY_TAG.tar.gz.asc\`"
require_offer "This repository at tag \`$tag\`:"
require_offer "$tag_tree |"
require_offer "\`$CACHY_SHA256\`"
require_offer "\`linux-image-$KERNEL_VERSION-cachyos-"
grep -Fxq "git checkout $tag" "$offer" || die "$offer must check out $tag"
check_source_links "$offer" "$(< "$offer")"

if [[ $# -gt 0 ]]; then
    ref="refs/tags/$tag"
    [[ $(git rev-parse --verify "$ref^{commit}") == "$(git rev-parse HEAD)" ]] \
        || die "$tag does not point to the checked-out commit"
    if [[ $(git cat-file -t "$ref") == tag ]]; then
        title=$(git for-each-ref --format='%(contents:subject)' "$ref")
        notes=$(git for-each-ref --format='%(contents:body)' "$ref")
        check_version_prefix 'Release title' "$title"
        check_version_prefix 'Release notes' "$(awk 'NF {print; exit}' <<< "$notes")"
        check_source_links 'Release notes' "$notes"
        [[ -z $notes ]] || printf '%s\n\n' "$notes"
    fi
fi

printf '## Kernel source and build files\n\n'
printf -- '- [CachyOS Linux %s source tarball](%s)\n' "$KERNEL_VERSION" "$tarball"
printf -- '- [Upstream tarball signature](%s.asc)\n' "$tarball"
printf -- '- [Packaging, patches, configs and build scripts at %s](%s)\n' "$tag" "$tag_tree"
printf -- '- [Corresponding source and rebuild instructions](%s/blob/%s/SOURCE-OFFER.md)\n' "$repository" "$tag"
printf -- '- [Pinned source version and SHA-256](%s/blob/%s/kernel.env)\n' "$repository" "$tag"
