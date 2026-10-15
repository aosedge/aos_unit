#!/usr/bin/env bash
# Build a local aos-unit .deb from a git ref or from the working tree.
# Builds in a native Linux temp dir because debuild misbehaves on WSL drvfs.
#
# Usage: build-deb.sh <git-ref|WORKTREE> <base-version> [outdir]
# Prints the path of the built .deb on the last line.

set -Eeuo pipefail

_repo="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
readonly REPO="${REPO:-$_repo}"
readonly ref="${1:?git ref or WORKTREE required}"
readonly ver="${2:?base version required}"
readonly out="${3:-/var/tmp/aos-debs}"

work="$(mktemp -d /tmp/aosbuild.XXXXXX)"
trap 'rm -rf "$work"' EXIT

# drvfs reports every file as executable, so WORKTREE goes through a dangling
# stash commit to keep git's file modes (stash create touches neither the
# worktree nor the stash list).
src="$ref"
if [[ $ref == WORKTREE ]]; then
    src="$(git -C "$REPO" stash create)"
    src="${src:-HEAD}"
fi
git -C "$REPO" archive "$src" | tar -xf - -C "$work"

cd "$work"
git init -q
git add -A
git -c user.name=build -c user.email=build@localhost commit -qm "build ${ref}"

if ! bash ./build_package.sh local "$ver" >build.log 2>&1; then
    tail -40 build.log >&2
    exit 1
fi

mkdir -p "$out"
deb="$(ls -1 build/*.deb | head -1)"
cp "$deb" "$out/"
echo "${out}/${deb##*/}"
