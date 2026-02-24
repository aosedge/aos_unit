#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage:
  build_package.sh local <version>
      [--clean]
      [--dist <dist>]
      [--subject <text>]
      Build local .deb for development/testing (unsigned).
      Local version is automatically suffixed to differ from PPA builds.

  build_package.sh ppa <version>
      --msg-from-tag <tag>
      [--clean]
      [--series "jammy noble"]
      [--ppa "ppa:TEAM/NAME"]
      [--upload]
      [--gpg-key <keyid>]
      Build signed source packages for Ubuntu PPA (one per series).

Message sources:
  local mode:    --subject; defaults to "Local build <version>"
  ppa mode:      --msg-from-tag is mandatory, and both tag subject and body must be non-empty
                 NOTE: this requires an *annotated* tag (lightweight tags have no message).
                 In CI, ensure tags are available (e.g. git fetch --tags) before running.

Environment:
  DEB_DIST       Local build distribution (default: try autodetect) [local mode]
  PPA_SERIES     Default series list for ppa mode (example: "jammy noble")
  PPA_TARGET     Default PPA target (example: "ppa:aosedge/aos-unit")
  GPG_KEY_ID     Signing key id (required for ppa mode unless --gpg-key used)
  SOURCE_DATE_EPOCH
                 If set (Unix epoch seconds), used for changelog timestamps to support
                 reproducible builds. If not set and Git is available, it is derived
                 from the commit time of HEAD.

Examples:
  ./build_package.sh local 0.0.9
  ./build_package.sh ppa 0.0.9 --msg-from-tag v0.0.9 --upload
EOF
    exit 2
}

die() {
    echo "ERROR: $*" >&2
    exit 2
}
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

require_cmd debuild
require_cmd git

[[ -f debian/control ]] || die "debian/control not found. Run from package root."
[[ -d debian ]] || die "debian/ directory not found."

MODE="${1:-}"
BASE_VERSION="${2:-}"
shift 2 || true

[[ -n $MODE && -n $BASE_VERSION ]] || usage
[[ $BASE_VERSION =~ ^[A-Za-z0-9.+:~\-]+$ ]] || die "Invalid Debian version: '$BASE_VERSION'"

PKG_NAME="$(awk -F': ' '/^Package:/ {print $2; exit}' debian/control)"
MAINTAINER_LINE="$(awk -F': ' '/^Maintainer:/ {print $2; exit}' debian/control)"
[[ -n $PKG_NAME ]] || die "Failed to parse Package from debian/control"
[[ -n $MAINTAINER_LINE ]] || die "Failed to parse Maintainer from debian/control"

SRC_NAME="$(awk -F': ' '/^Source:/ {print $2; exit}' debian/control)"
if [[ -z $SRC_NAME ]]; then
    SRC_NAME="$PKG_NAME"
fi

DEBFULLNAME="${MAINTAINER_LINE%% <*}"
DEBEMAIL="${MAINTAINER_LINE%>}"
DEBEMAIL="${DEBEMAIL##*<}"
export DEBFULLNAME DEBEMAIL

init_source_date_epoch() {
    # For reproducible builds: prefer user-provided SOURCE_DATE_EPOCH, otherwise
    # derive from HEAD commit time (Git). If neither works, leave unset.
    if [[ -n ${SOURCE_DATE_EPOCH:-} ]]; then
        [[ ${SOURCE_DATE_EPOCH} =~ ^[0-9]+$ ]] || die "SOURCE_DATE_EPOCH must be an integer epoch seconds"
        export SOURCE_DATE_EPOCH
        return 0
    fi

    local epoch
    epoch="$(git log -1 --format=%ct HEAD 2>/dev/null || true)"
    if [[ -n $epoch && $epoch =~ ^[0-9]+$ ]]; then
        export SOURCE_DATE_EPOCH="$epoch"
    fi
}

rfc2822_date() {
    # Use SOURCE_DATE_EPOCH if available; fall back to current time.
    if [[ -n ${SOURCE_DATE_EPOCH:-} && ${SOURCE_DATE_EPOCH} =~ ^[0-9]+$ ]]; then
        date -R -u -d "@${SOURCE_DATE_EPOCH}"
    else
        date -R
    fi
}

make_orig_tarball() {
    local src="$1" ver="$2"
    mkdir -p build
    local out="build/${src}_${ver}.orig.tar.gz"
    git archive --format=tar --prefix="${src}-${ver}/" HEAD | gzip -c >"$out"
}

# Strict tag subject/body extraction
get_tag_subject() {
    local tag="$1"
    git tag -l --format='%(contents:subject)' "$tag" 2>/dev/null | sed 's/\r$//'
}

get_tag_body() {
    local tag="$1"
    git tag -l --format='%(contents:body)' "$tag" 2>/dev/null | sed 's/\r$//'
}

require_nonempty() {
    local what="$1"
    local val="$2"
    if [[ -z ${val//[[:space:]]/} ]]; then
        die "$what is empty; refusing to proceed"
    fi
}

apply_changelog_entry_fresh() {
    local target_dir="$1"
    local version="$2"
    local dist="$3"
    local urgency="$4"
    local subject="$5"
    local body="$6"

    local cl="${target_dir}/debian/changelog"
    rm -f "$cl"

    # Normalize CRLF in body; trim leading and trailing blank lines.
    body="$(printf "%s\n" "$body" |
        sed 's/\r$//' |
        awk 'NF{found=1} found' |
        awk '{buf[NR]=$0} END{for(i=NR;i>=1;i--) if(buf[i]~/[^[:space:]]/){last=i;break}; for(i=1;i<=last;i++) print buf[i]}')"

    # Formatting rules:
    #   Subject              — written as-is, no bullet prefix
    #   Body lines with '-'  — become [ Section Header ]
    #   Body regular lines   — prefixed with '* '
    #   Blank line between subject and body
    #   Lines are never wrapped
    {
        printf "%s (%s) %s; urgency=%s\n" "$PKG_NAME" "$version" "$dist" "$urgency"
        printf "\n"
        printf "  %s\n" "$subject"

        if [[ -n ${body//[[:space:]]/} ]]; then
            printf "\n"
            while IFS= read -r line; do
                if [[ -z ${line//[[:space:]]/} ]]; then
                    printf "\n"
                elif [[ $line == -* ]]; then
                    local section="${line#-}"
                    section="${section# }"
                    printf "  [ %s ]\n" "$section"
                else
                    printf "  * %s\n" "$line"
                fi
            done <<<"$body"
        fi

        printf "\n"
        printf " -- %s <%s>  %s\n" "$DEBFULLNAME" "$DEBEMAIL" "$(rfc2822_date)"
    } >"$cl"
}

init_source_date_epoch

UPLOAD="no"
LOCAL_DIST="${DEB_DIST:-}"
GPG_KEY_ID="${GPG_KEY_ID:-}"

SUBJECT=""
TAG_FOR_MSG=""
DO_CLEAN="no"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean)
            DO_CLEAN="yes"
            shift 1
            ;;
        --dist)
            LOCAL_DIST="${2:?--dist requires value}"
            shift 2
            ;;
        --series)
            PPA_SERIES="${2:?--series requires value}"
            shift 2
            ;;
        --ppa)
            PPA_TARGET="${2:?--ppa requires value}"
            shift 2
            ;;
        --upload)
            UPLOAD="yes"
            shift 1
            ;;
        --gpg-key)
            GPG_KEY_ID="${2:?--gpg-key requires value}"
            shift 2
            ;;
        --subject)
            SUBJECT="${2:?--subject requires value}"
            shift 2
            ;;
        --msg-from-tag)
            TAG_FOR_MSG="${2:?--msg-from-tag requires tag}"
            shift 2
            ;;
        -h | --help) usage ;;
        *) die "Unknown option: $1" ;;
    esac
done

make_local_version() {
    local ts sha
    ts="$(date -u +%Y%m%d%H%M%S)"
    sha="$(git rev-parse --short=12 HEAD 2>/dev/null || echo "nogit")"
    # Deterministic tag to distinguish from PPA:
    # e.g. 0.0.9+gitabcdef123456+20260220123000
    printf "%s+git%s+%s" "$BASE_VERSION" "$sha" "$ts"
}

do_local() {
    local ver subject target_dir
    if [[ -z $LOCAL_DIST ]]; then
        require_cmd lsb_release
        LOCAL_DIST="$(lsb_release -cs 2>/dev/null)"
        [[ -n $LOCAL_DIST ]] || die "Could not detect local distribution; use --dist or DEB_DIST"
    fi
    ver="$(make_local_version)"
    subject="${SUBJECT:-Local build ${BASE_VERSION}}"
    target_dir="build/src_local"

    echo "Package: ${PKG_NAME}"
    echo "Source: ${SRC_NAME}"
    echo "Maintainer: ${DEBFULLNAME} <${DEBEMAIL}>"
    echo "Mode: local"
    echo "Base version: ${BASE_VERSION}"
    echo "Local version: ${ver}"
    echo "Distribution: ${LOCAL_DIST}"

    # Isolate the source
    mkdir -p "$target_dir"
    git archive --format=tar HEAD | tar -xf - -C "$target_dir"

    # Modify the changelog, subject only, no body
    apply_changelog_entry_fresh "$target_dir" "$ver" "$LOCAL_DIST" "low" "$subject" ""

    # Run debuild explicitly inside the target directory
    env -C "$target_dir" debuild -us -uc -b -jauto

    echo "Local build complete."
    ls -lh build/"${PKG_NAME}"_"${ver}"_*.deb 2>/dev/null || true
}

do_ppa() {
    require_cmd dput
    require_cmd gpg

    [[ -n ${PPA_SERIES:-} ]] || die "PPA_SERIES is not set (use --series or env var)"
    [[ -n ${PPA_TARGET:-} ]] || die "PPA_TARGET is not set (use --ppa or env var)"
    [[ -n ${GPG_KEY_ID:-} ]] || die "GPG key id required for ppa mode (set GPG_KEY_ID or use --gpg-key)"
    [[ -n ${TAG_FOR_MSG:-} ]] || die "ppa mode requires --msg-from-tag <tag> (strict subject+body)"

    local subj body urgency

    git rev-parse -q --verify "refs/tags/${TAG_FOR_MSG}" >/dev/null 2>&1 || die "Tag not found: ${TAG_FOR_MSG}"

    subj="$(get_tag_subject "$TAG_FOR_MSG")"
    body="$(get_tag_body "$TAG_FOR_MSG")"

    require_nonempty "Tag subject (release title) for ${TAG_FOR_MSG}" "$subj"
    require_nonempty "Tag body (release description) for ${TAG_FOR_MSG}" "$body"

    if [[ $subj == CRITICAL:\ * ]]; then
        urgency="critical"
    else
        urgency="medium"
    fi

    echo "Package: ${PKG_NAME}"
    echo "Source: ${SRC_NAME}"
    echo "Maintainer: ${DEBFULLNAME} <${DEBEMAIL}>"
    echo "Mode: ppa"
    echo "Base version: ${BASE_VERSION}"
    echo "Series: ${PPA_SERIES}"
    echo "Upload: ${UPLOAD}"
    echo "PPA target: ${PPA_TARGET}"
    echo "Signing key: ${GPG_KEY_ID}"
    echo "Tag for msg: ${TAG_FOR_MSG}"
    echo "Urgency: ${urgency}"

    mkdir -p build

    local series series_arr target_dir
    read -ra series_arr <<<"$PPA_SERIES"
    for series in "${series_arr[@]}"; do
        local series_version="${BASE_VERSION}~${series}"
        target_dir="build/src_${series}"

        echo
        echo "Building source for ${series} (version ${series_version})"

        make_orig_tarball "$SRC_NAME" "$series_version"

        # Isolate the source for this series
        rm -rf "$target_dir"
        mkdir -p "$target_dir"
        git archive --format=tar HEAD | tar -xf - -C "$target_dir"

        # Modify changelog and build cleanly
        apply_changelog_entry_fresh "$target_dir" "$series_version" "$series" "$urgency" "$subj" "$body"
        env -C "$target_dir" debuild -S -sa -k"$GPG_KEY_ID"

        local changes="build/${SRC_NAME}_${series_version}_source.changes"
        [[ -f $changes ]] || die "Expected changes file not found: $changes"

        if [[ $UPLOAD == "yes" ]]; then
            dput "$PPA_TARGET" "$changes"
        else
            echo "Built: $changes"
        fi
    done

    echo
    echo "PPA build complete."
}

if [[ $DO_CLEAN == "yes" ]]; then
    echo "Cleaning build directory..."
    rm -rf ./build
fi

case "$MODE" in
    local) do_local ;;
    ppa) do_ppa ;;
    *) usage ;;
esac
