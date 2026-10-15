#!/usr/bin/env bash
# Wrapper: prove issue #9 L2 fix with planted leftover dnsmasq.
set -euo pipefail
_repo="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
REPO="${1:-$_repo}"
exec bash "${REPO}/tests/prove-l2-fix.sh"
