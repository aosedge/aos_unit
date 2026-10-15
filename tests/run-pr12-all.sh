#!/usr/bin/env bash
# Run PR #12 / issue #9 test matrix and write summary to /tmp/aos-pr12-test-summary.txt
set -uo pipefail

REPO="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
OUT="/tmp/aos-pr12-test-summary.txt"
MATRIX="/tmp/aos-unit-matrix-results.txt"
IMAGES="/var/tmp/aos-core-v6.1.2"

exec > >(tee "$OUT") 2>&1

echo "=== PR #12 test run $(date '+%Y-%m-%d %H:%M:%S') ==="
echo "Package: $(dpkg-query -W -f='${Version}' aos-unit 2>/dev/null || echo unknown)"
echo "Host: $(lsb_release -ds 2>/dev/null) $(uname -r) systemd $(systemctl --version | head -n1 | awk '{print $2}')"
echo "Images dir: $IMAGES"
echo

# Ensure no orphan static dnsmasq unit
rm -f /lib/systemd/system/aos-unit-dnsmasq.service
systemctl daemon-reload

run_block() {
    local title="$1"
    shift
    echo "========== ${title} =========="
    if "$@"; then
        echo "BLOCK_EXIT=0"
    else
        echo "BLOCK_EXIT=$?"
    fi
    echo
}

run_block "prove-l2-fix (issue #9 leftover dnsmasq)" \
    bash "${REPO}/tests/prove-l2-fix.sh"

run_block "helpers H1-H8" \
    bash "${REPO}/tests/die-shutdown-order-matrix.sh" --helpers-only

run_block "cluster matrix G/P/D/L/C/V/N/O on AosCore 6.1.2" \
    bash "${REPO}/tests/die-shutdown-order-matrix.sh" \
    --setup-images "$IMAGES" \
    --cases "G1 P1 P2 P3 D1 D2 D3 D4 L1 L2 C1 V1 V2 V3 V4 V5 N1 N2 N3 N4 O1"

if [[ -f $MATRIX ]]; then
    echo "========== MATRIX FILE =========="
    cat "$MATRIX"
fi

echo "=== DONE $(date '+%Y-%m-%d %H:%M:%S') ==="
