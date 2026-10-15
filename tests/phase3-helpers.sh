#!/usr/bin/env bash
# T3.H: helper-only checks for wait_for_unit_unloaded / wait_for_unit_inactive.
# Uses throwaway units; does not touch aos-unit. Run as root.
# Usage: phase3-helpers.sh [path/to/log-helper]   (default: installed copy)

set -u

. "$(dirname "$(realpath "$0")")/lib-issue11.sh"
SUMMARY=/tmp/aos-phase3-helpers-summary.txt

HELPER="${1:-/usr/libexec/aos-unit/log-helper}"
LOG_TAG="helper-test"
# shellcheck disable=SC1090
. "$HELPER"

readonly T_TRANS=aoshelper-trans.service
readonly T_STUB=aoshelper-stubborn.service
readonly S_UNIT=aoshelper-static.service
readonly S_STUB=aoshelper-static-stubborn.service
readonly UDIR=/run/systemd/system

cleanup() {
    systemctl kill -s KILL "$T_TRANS" "$T_STUB" "$S_UNIT" "$S_STUB" >/dev/null 2>&1
    systemctl stop "$T_TRANS" "$T_STUB" "$S_UNIT" "$S_STUB" >/dev/null 2>&1
    systemctl reset-failed "$T_TRANS" "$T_STUB" "$S_UNIT" "$S_STUB" >/dev/null 2>&1
    rm -f "${UDIR}/${S_UNIT}" "${UDIR}/${S_STUB}"
    systemctl daemon-reload
}
trap cleanup EXIT

timed() {
    local t0=$SECONDS
    "$@"
    RC=$?
    DUR=$((SECONDS - t0))
}

main() {
    cleanup 2>/dev/null

    say "H1 transient unit unloads"
    systemd-run -q --collect --unit="$T_TRANS" sleep 600
    timed wait_for_unit_unloaded "$T_TRANS" 10
    check T3.H "H1 rc" 0 "$RC"
    check T3.H "H1 LoadState" not-found "$(show "$T_TRANS" LoadState)"

    say "H2 transient ignoring SIGTERM times out"
    systemd-run -q --collect --unit="$T_STUB" -p TimeoutStopSec=60 bash -c 'trap "" TERM; while :; do sleep 1; done'
    timed wait_for_unit_unloaded "$T_STUB" 3
    check T3.H "H2 rc (timeout)" 1 "$RC"
    check_cmd T3.H "H2 returned within ~timeout (<=4s)" test "$DUR" -le 4
    systemctl kill -s KILL "$T_STUB" >/dev/null 2>&1

    say "H3 static unit stops and stays loaded"
    printf '[Service]\nExecStart=/bin/sleep 600\n' >"${UDIR}/${S_UNIT}"
    printf '[Service]\nExecStart=/bin/bash -c "trap \\"\\" TERM; while :; do sleep 1; done"\nTimeoutStopSec=60\n' >"${UDIR}/${S_STUB}"
    systemctl daemon-reload
    systemctl start "$S_UNIT" "$S_STUB"
    timed wait_for_unit_inactive "$S_UNIT" 10
    check T3.H "H3 rc" 0 "$RC"
    check T3.H "H3 ActiveState" inactive "$(show "$S_UNIT" ActiveState)"
    check T3.H "H3 LoadState stays loaded" loaded "$(show "$S_UNIT" LoadState)"

    say "H4 static unit ignoring SIGTERM times out"
    timed wait_for_unit_inactive "$S_STUB" 3
    check T3.H "H4 rc (timeout)" 1 "$RC"
    check_cmd T3.H "H4 returned within ~timeout (<=4s)" test "$DUR" -le 4

    say "H5 caller trap is preserved"
    trap 'echo caller-trap' TERM
    local before after
    before="$(trap -p TERM)"
    wait_for_unit_inactive "$S_STUB" 1 2>/dev/null
    wait_for_unit_unloaded aoshelper-missing.service 1
    after="$(trap -p TERM)"
    check T3.H "H5 TERM trap unchanged" "$before" "$after"
    trap - TERM

    say "H6 missing unit counts as done for both helpers"
    timed wait_for_unit_inactive aoshelper-missing.service 3
    check T3.H "H6 inactive rc" 0 "$RC"
    timed wait_for_unit_unloaded aoshelper-missing.service 3
    check T3.H "H6 unloaded rc" 0 "$RC"

    say "H7 failed static unit counts as stopped"
    systemctl kill -s KILL "$S_STUB" >/dev/null 2>&1
    sleep 1
    printf '[Service]\nExecStart=/bin/false\n' >"${UDIR}/${S_UNIT}"
    systemctl daemon-reload
    systemctl start "$S_UNIT" 2>/dev/null
    sleep 1
    info T3.H "H7 state before wait" "$(show "$S_UNIT" ActiveState)"
    timed wait_for_unit_inactive "$S_UNIT" 3
    check T3.H "H7 rc" 0 "$RC"

    summary "Phase 3 helper checks (${HELPER})"
    return "$FAILS"
}

main "$@"
