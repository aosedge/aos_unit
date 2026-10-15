#!/usr/bin/env bash
# Build a deb (git ref or WORKTREE), install it, run static checks, then run
# the given acceptance script. Output goes to tests/results/<label>-<date>.txt.
#
# Usage: run-step.sh <ref|WORKTREE> <base-version> <label> <script> [args...]
#   e.g. run-step.sh WORKTREE 1.2.0~p3s31 phase3-S3.1 phase3-acceptance.sh T3.8

set -uo pipefail

_repo="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
readonly REPO="$_repo"
readonly ref="$1" ver="$2" label="$3" script="$4"
shift 4

_ts="$(date +%Y%m%d-%H%M)"
readonly out="${REPO}/tests/results/${label}-${_ts}"
mkdir -p "${REPO}/tests/results"

{
    echo "### step ${label}  ref=${ref}  head=$(git -C "$REPO" rev-parse --short HEAD)  $(date '+%F %T')"
    git -C "$REPO" status --short -- . ':!tests' ':!.idea'

    deb="$(bash "${REPO}/tests/build-deb.sh" "$ref" "$ver" | tail -1)" || {
        echo "BUILD FAILED"
        exit 1
    }
    echo "### deb: ${deb}"
    dpkg -i "$deb" 2>&1 | tail -5
    echo "### installed: $(dpkg-query -W -f='${Version}' aos-unit)"

    echo "### static checks"
    bash "${REPO}/tests/static-checks.sh" "$REPO"

    echo "### ${script} $*"
    env ${ENV_EXTRA:-} bash "${REPO}/tests/${script}" "$@"
    echo "### exit: $?"
} >"$out" 2>&1

echo "$out"
grep -E '^(FAIL|RESULT|STATIC|BUILD|### (exit|installed))' "$out"
