#!/usr/bin/env bash
# Issue #11 Phase 3 (PR #13) acceptance against the INSTALLED package.
# Run as root: tests/phase3-acceptance.sh [T3.1 T3.2 T3.3 T3.5 T3.8 ...]
#
# Env: EXPECT_GATE=0 for builds without the node-start gate, RESTARTS=N (T3.2).

set -u

. "$(dirname "$(realpath "$0")")/lib-issue11.sh"

: "${EXPECT_GATE:=1}"
: "${RESTARTS:=10}"
SUMMARY="${SUMMARY_OVERRIDE:-/tmp/aos-phase3-summary.txt}"

assert_running() {
    local id="$1" label="$2" name cpu mem unit
    check "$id" "${label}: aos-unit active" active "$(show aos-unit.service ActiveState)"
    while read -r name cpu mem; do
        unit="$(node_unit "$name")"
        check "$id" "${label}: ${name} active" active "$(show "$unit" ActiveState)"
        check "$id" "${label}: ${name} Transient" no "$(show "$unit" Transient)"
        check "$id" "${label}: ${name} MainPID is qemu" qemu-system-x86_64 "$(main_exe "$unit")"
        check "$id" "${label}: ${name} cgroup limits" "$(mem_to_bytes "$mem") $((cpu * 100000)) 100000" "$(cgroup_limits "$unit")"
    done < <(node_specs)
    if ((EXPECT_GATE)); then
        check "$id" "${label}: node-start gate present" present "$([[ -e $AOS_GATE ]] && echo present || echo absent)"
    fi
}

assert_stopped() {
    local id="$1" label="$2" name unit
    check "$id" "${label}: aos-unit inactive" inactive "$(show aos-unit.service ActiveState)"
    for name in $(node_names); do
        unit="$(node_unit "$name")"
        check "$id" "${label}: ${name} inactive (not failed)" inactive "$(show "$unit" ActiveState)"
        check "$id" "${label}: ${name} LoadState stays loaded" loaded "$(show "$unit" LoadState)"
    done
    check "$id" "${label}: taps removed" "" "$(taps)"
    check "$id" "${label}: bridge removed" "" "$(bridges)"
    check "$id" "${label}: no failed aos-unit units" "" "$(failed_aos_units)"
    check "$id" "${label}: runtime dir removed" absent "$([[ -e $AOS_RUN ]] && echo present || echo absent)"
}

ensure_running_booted() {
    if ! unit_is aos-unit.service active; then
        systemctl start aos-unit.service
    fi
    wait_guests_booted
}

t3_1() {
    say "T3.1 start -> restart x2 -> stop"
    clean_slate
    local since
    since="$(now)"
    systemctl start aos-unit.service
    sleep 3
    report_state
    assert_running T3.1 start
    wait_guests_booted
    local i
    for i in 1 2; do
        systemctl restart aos-unit.service
        sleep 3
        report_state
        assert_running T3.1 "restart#${i}"
        wait_guests_booted
    done
    systemctl stop aos-unit.service
    report_state
    assert_stopped T3.1 stop
    check_no_race T3.1 "$since"
}

t3_2() {
    say "T3.2 ${RESTARTS} restarts in a loop"
    ensure_running_booted
    local since failures_before i name unit
    since="$(now)"
    failures_before="$(failures_log_lines)"
    declare -A pid_before
    for ((i = 1; i <= RESTARTS; i++)); do
        for name in $(node_names); do
            pid_before[$name]="$(show "$(node_unit "$name")" MainPID)"
        done
        systemctl restart aos-unit.service
        sleep 3
        local ok=1
        for name in $(node_names); do
            unit="$(node_unit "$name")"
            if ! unit_is "$unit" active || [[ "$(show "$unit" MainPID)" == "${pid_before[$name]}" ]] ||
                [[ "$(show "$unit" NRestarts)" != 0 ]]; then
                ok=0
                echo "  iteration ${i}: ${name} Active=$(show "$unit" ActiveState) PID=$(show "$unit" MainPID) was=${pid_before[$name]} NRestarts=$(show "$unit" NRestarts)"
            fi
        done
        if ((ok)); then
            record T3.2 PASS "restart ${i}: every node active with a new MainPID" ok
        else
            record T3.2 FAIL "restart ${i}: every node active with a new MainPID" "see above"
        fi
        wait_guests_booted
    done
    check T3.2 "no new vm-failures.log entries" "$failures_before" "$(failures_log_lines)"
    check_no_race T3.2 "$since"
}

t3_3() {
    say "T3.3 node-start gate"
    ensure_running_booted
    systemctl stop --no-block aos-unit.service
    local deadline=$((SECONDS + 150)) samples=0 violations=0 name st
    while ((SECONDS < deadline)) && ! unit_is aos-unit.service inactive; do
        for name in $(node_names); do
            st="$(show "$(node_unit "$name")" ActiveState)"
            if [[ $st == deactivating ]]; then
                samples=$((samples + 1))
                [[ -e $AOS_GATE ]] && violations=$((violations + 1))
            fi
        done
        sleep 0.2
    done
    check T3.3 "gate absent whenever a node was deactivating" 0 "$violations"
    info T3.3 "deactivating samples observed" "$samples"
    assert_stopped T3.3 "after stop"

    say "T3.3b manual start of an instance while the manager is down"
    local first unit rc
    first="$(node_names | head -1)"
    unit="$(node_unit "$first")"
    timeout 90 systemctl start "$unit"
    rc=$?
    sleep 10
    info T3.3 "manual start exit code" "$rc"
    info T3.3 "after manual start: aos-unit" "$(show aos-unit.service ActiveState)"
    info T3.3 "after manual start: ${first}" "$(show "$unit" ActiveState) Result=$(show "$unit" Result)"
    systemctl stop aos-unit.service
    for name in $(node_names); do systemctl reset-failed "$(node_unit "$name")" 2>/dev/null || true; done
    assert_stopped T3.3 "after manual-start cleanup"
}

t3_5() {
    say "T3.5 teardown order and SIGSTOPped guest"
    clean_slate
    systemctl start aos-unit.service
    wait_guests_booted
    local since name
    since="$(now)"
    systemctl stop aos-unit.service
    local log cleanup_line unreg_last
    log="$(journal_units "$since")"
    cleanup_line="$(grep -n 'Cleanup complete' <<<"$log" | head -1 | cut -d: -f1)"
    for name in $(node_names); do
        unreg_last="$(grep -n "Unregister VM: .*host=${name}\b" <<<"$log" | tail -1 | cut -d: -f1)"
        check_cmd T3.5 "${name}: Unregister VM logged before Cleanup complete" \
            test -n "$unreg_last" -a -n "$cleanup_line" -a "${unreg_last:-0}" -lt "${cleanup_line:-0}"
    done
    assert_stopped T3.5 "normal stop"

    say "T3.5b guest frozen with SIGSTOP"
    systemctl start aos-unit.service
    wait_guests_booted
    local first unit t0 dur
    first="$(node_names | head -1)"
    unit="$(node_unit "$first")"
    kill -STOP "$(show "$unit" MainPID)"
    t0=$SECONDS
    timeout 200 systemctl stop aos-unit.service
    dur=$((SECONDS - t0))
    info T3.5 "stop duration with frozen ${first}" "${dur}s"
    check_cmd T3.5 "stop finished within TimeoutStopSec (<=120s)" test "$dur" -le 120
    assert_stopped T3.5 "frozen-guest stop"
}

t3_8() {
    say "T3.8 cleanup when the nft table is already gone"
    clean_slate
    systemctl start aos-unit.service
    sleep 5
    local since
    since="$(now)"
    nft delete table inet aos_unit
    systemctl stop aos-unit.service
    check_cmd T3.8 "journal: Cleanup complete" grep -q 'Cleanup complete' <(journal_units "$since")
    check T3.8 "bridge removed" "" "$(bridges)"
    check T3.8 "taps removed" "" "$(taps)"
}

main() {
    local -a tests=("$@")
    ((${#tests[@]})) || tests=(T3.1 T3.2 T3.3 T3.5 T3.8)
    local t
    for t in "${tests[@]}"; do
        case "$t" in
            T3.1) t3_1 ;;
            T3.2) t3_2 ;;
            T3.3) t3_3 ;;
            T3.5) t3_5 ;;
            T3.8) t3_8 ;;
            *) echo "unknown test: $t" >&2 ;;
        esac
    done
    summary "Phase 3 acceptance: ${tests[*]}"
    return "$FAILS"
}

main "$@"
