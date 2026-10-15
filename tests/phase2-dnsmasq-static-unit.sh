#!/usr/bin/env bash
# Issue #11 whole-solution acceptance: Phase 1 + 2 + 3.
#
# Installs the working-tree versions over the packaged ones, then exercises
# start -> restart x2 -> stop. That is the sequence that used to fail with
# "Unit already exists" / "service is already running" on both dnsmasq and VMs.
#
# Not for the PR. Run as root from the repo checkout.

set -u

_repo="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
readonly REPO="${1:-$_repo}"
readonly LIBEXEC=/usr/libexec/aos-unit
readonly UNIT_DIR=/lib/systemd/system
readonly NODES=(main secondary)
readonly DNSMASQ=aos-unit-dnsmasq.service

fails=0

say() { printf '\n=== %s ===\n' "$*"; }

check() {
    local what="$1" expected="$2" actual="$3"
    if [[ $expected == "$actual" ]]; then
        printf 'PASS  %-50s %s\n' "$what" "$actual"
    else
        printf 'FAIL  %-50s expected=%s actual=%s\n' "$what" "$expected" "$actual"
        fails=$((fails + 1))
    fi
}

unit_of() { printf 'aos-unit-node@%s.service' "$1"; }

show() { systemctl show -p "$2" --value "$1" 2>/dev/null; }

install_working_tree() {
    say "Installing working-tree files over the packaged ones"
    local f
    for f in runner log-helper network-helper vm-launch vm-failed-handler; do
        install -m 0755 -o root -g root "${REPO}/${f}" "${LIBEXEC}/${f}" || exit 1
        echo "  ${LIBEXEC}/${f}"
    done
    install -m 0644 -o root -g root "${REPO}/aos-unit-node@.service" "${UNIT_DIR}/aos-unit-node@.service" || exit 1
    echo "  ${UNIT_DIR}/aos-unit-node@.service"
    install -m 0644 -o root -g root "${REPO}/aos-unit-dnsmasq.service" "${UNIT_DIR}/aos-unit-dnsmasq.service" || exit 1
    echo "  ${UNIT_DIR}/aos-unit-dnsmasq.service"
    install -m 0644 -o root -g root "${REPO}/aos-unit.service" "${UNIT_DIR}/aos-unit.service" || exit 1
    echo "  ${UNIT_DIR}/aos-unit.service"
    systemctl daemon-reload
}

report_state() {
    local label="$1" node unit
    say "State after ${label}"
    printf '  %-34s Active=%s\n' "aos-unit.service" "$(show aos-unit.service ActiveState)"
    printf '  %-34s Load=%-8s Active=%-10s Sub=%s\n' \
        "$DNSMASQ" "$(show "$DNSMASQ" LoadState)" "$(show "$DNSMASQ" ActiveState)" \
        "$(show "$DNSMASQ" SubState)"
    for node in "${NODES[@]}"; do
        unit="$(unit_of "$node")"
        printf '  %-34s Load=%-8s Active=%-10s Sub=%-10s MainPID=%s\n' \
            "$unit" "$(show "$unit" LoadState)" "$(show "$unit" ActiveState)" \
            "$(show "$unit" SubState)" "$(show "$unit" MainPID)"
    done
}

expect_running() {
    local label="$1" node unit
    say "Assertions after ${label}"
    check "aos-unit: ActiveState" "active" "$(show aos-unit.service ActiveState)"
    check "dnsmasq: ActiveState" "active" "$(show "$DNSMASQ" ActiveState)"
    check "dnsmasq: LoadState stays loaded" "loaded" "$(show "$DNSMASQ" LoadState)"
    check "dnsmasq: MainPID is dnsmasq" "dnsmasq" \
        "$(basename "$(readlink -f "/proc/$(show "$DNSMASQ" MainPID)/exe" 2>/dev/null)" 2>/dev/null)"
    check "dnsmasq.conf exists" "yes" \
        "$([[ -f /run/aos-unit/dnsmasq.conf ]] && echo yes || echo no)"
    for node in "${NODES[@]}"; do
        unit="$(unit_of "$node")"
        check "${node}: ActiveState" "active" "$(show "$unit" ActiveState)"
        check "${node}: LoadState stays loaded" "loaded" "$(show "$unit" LoadState)"
    done
}

race_errors_since() {
    local since="$1"
    journalctl --no-pager --since "$since" \
        -u aos-unit.service -u aos-unit-dnsmasq.service -u 'aos-unit-node@*' 2>/dev/null |
        grep -iE "already exists|already running|already loaded|Failed to start unit|circular|Result: resources|Failed to load environment files|Failed with result 'signal'|VM unit FAILED" || true
}

main() {
    local started_at
    started_at="$(date '+%Y-%m-%d %H:%M:%S')"

    install_working_tree

    say "Clean slate"
    systemctl stop aos-unit.service
    # After a --collect transient with the same name vanishes, systemd will not
    # pick up the packaged unit file until another reload.
    systemctl daemon-reload
    sleep 2
    report_state "stop (pre-test)"

    say "Start"
    time systemctl start aos-unit.service
    sleep 5
    report_state "start"
    expect_running "start"

    local i
    for i in 1 2; do
        say "Restart #${i} (issue #11 whole solution)"
        time systemctl restart aos-unit.service
        sleep 5
        report_state "restart #${i}"
        expect_running "restart #${i}"
    done

    say "Stop"
    time systemctl stop aos-unit.service
    sleep 3
    report_state "stop"

    check "aos-unit stopped" "inactive" "$(show aos-unit.service ActiveState)"
    check "dnsmasq stopped (not failed)" "inactive" "$(show "$DNSMASQ" ActiveState)"
    check "dnsmasq LoadState still loaded" "loaded" "$(show "$DNSMASQ" LoadState)"
    local node unit
    for node in "${NODES[@]}"; do
        unit="$(unit_of "$node")"
        check "${node}: stopped and not left failed" "inactive" "$(show "$unit" ActiveState)"
    done
    check "taps removed" "" "$(ip -o link show | awk -F': ' '/aostap/ {printf "%s ", $2}')"
    check "bridge removed" "" "$(ip -o link show type bridge | awk -F': ' '/aosbr/ {printf "%s ", $2}')"

    say "Race-condition strings in the journal for this run"
    local race
    race="$(race_errors_since "$started_at")"
    if [[ -z $race ]]; then
        echo "  none"
    else
        echo "$race" | sed 's/^/  /'
        fails=$((fails + 1))
    fi

    say "Result"
    if ((fails == 0)); then
        echo "ALL CHECKS PASSED"
    else
        echo "${fails} CHECK(S) FAILED"
    fi
    return "$fails"
}

main "$@"
