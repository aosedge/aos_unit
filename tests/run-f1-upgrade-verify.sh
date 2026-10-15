#!/usr/bin/env bash
# Verify F-1 fix: upgrade from v1.1.2 without KNOWN_V112_SELF_HEAL.
# Usage: sudo bash tests/run-f1-upgrade-verify.sh [T3.6|T2.3]
#   T3.6 = Phase 3 package (default)
#   T2.3 = Phase 2 package (sets dns sidecar env)
# REPO must be the product tree with the network-helper fix (default: repo root).
# Writes tests/results/f1-dhcp-cleanup-<id>-<timestamp>.txt

set -uo pipefail

id="${1:-T3.6}"
TESTS="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
REPO="${REPO:-$TESTS}"

case "$id" in
    T3.6) extra= ;;
    T2.3)
        extra='AOS_DNSMASQ=aos-unit-dnsmasq.service NEW_DNS_UNIT=aos-unit-dnsmasq.service EXPECT_DNSMASQ_TRANSIENT=no'
        ;;
    *) echo "unknown test id: $id (use T3.6 or T2.3)"; exit 2 ;;
esac

TS="$(date +%Y%m%d-%H%M)"
OUT="${TESTS}/tests/results/f1-dhcp-cleanup-${id}-${TS}.txt"
BASE="$(ls -1 /var/tmp/aos-debs/aos-unit_1.1.2+*.deb 2>/dev/null | head -1)"

if [[ -z $BASE ]]; then
    echo "missing baseline deb under /var/tmp/aos-debs/aos-unit_1.1.2+*.deb"
    exit 1
fi

if [[ ! -f "${TESTS}/tests/upgrade-acceptance.sh" ]]; then
    echo "missing ${TESTS}/tests/upgrade-acceptance.sh"
    exit 1
fi

mkdir -p "${TESTS}/tests/results"

{
    echo "### F-1 fix verification (${id})"
    echo "### $(date -Is)"
    echo "### product REPO: ${REPO}"
    echo "### network-helper diff:"
    git -C "$REPO" diff -- network-helper | sed 's/^/    /'
    echo "### build package (WORKTREE)"
    NEW="$(REPO="$REPO" bash "${TESTS}/tests/build-deb.sh" WORKTREE "1.2.0~f1-${id}")"
    echo "### new deb: ${NEW}"
    echo "### baseline deb: ${BASE}"
    echo "### static checks"
    bash "${TESTS}/tests/static-checks.sh" "$REPO"
    echo "### upgrade-acceptance ${id} (KNOWN_V112_SELF_HEAL=0)"
    env ${extra} KNOWN_V112_SELF_HEAL=0 bash "${TESTS}/tests/upgrade-acceptance.sh" "$BASE" "$NEW" "$id"
    rc=$?
    echo "### exit: ${rc}"
    exit "$rc"
} 2>&1 | tee "$OUT"

echo "RESULT_FILE=${OUT}"
grep -E '^(PASS|FAIL|INFO|RESULT|STATIC|===|### exit)' "$OUT" | tail -80
exit "${PIPESTATUS[0]}"
