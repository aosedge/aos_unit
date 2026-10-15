#!/usr/bin/env bash
# Issue #11 phase 3 acceptance test: VMs as static systemd template units.
#
# Installs the working-tree versions of the changed files over the packaged ones,
# then exercises start -> restart x2 -> stop, which is the exact sequence that
# used to fail with "Unit already exists" / "service is already running".
#
# Run as root from the repo checkout.

set -u

_repo="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
readonly REPO="${1:-$_repo}"
readonly LIBEXEC=/usr/libexec/aos-unit
readonly UNIT_DIR=/lib/systemd/system
readonly NODES=(main secondary)

fails=0

say() { printf '\n=== %s ===\n' "$*"; }

check() {
    local what="$1" expected="$2" actual="$3"
    if [[ $expected == "$actual" ]]; then
        printf 'PASS  %-46s %s\n' "$what" "$actual"
    else
        printf 'FAIL  %-46s expected=%s actual=%s\n' "$what" "$expected" "$actual"
        fails=$((fails + 1))
    fi
}

unit_of() { printf 'aos-unit-node@%s.service' "$1"; }

show() { systemctl show -p "$2" --value "$1" 2>/dev/null; }

cgroup_limits() {
    local unit="$1" cg
    cg="$(show "$unit" ControlGroup)"
    if [[ -z $cg || ! -d "/sys/fs/cgroup${cg}" ]]; then
        echo "no-cgroup no-cgroup"
        return
    fi
    printf '%s %s\n' "$(cat "/sys/fs/cgroup${cg}/memory.max")" "$(cat "/sys/fs/cgroup${cg}/cpu.max")"
}

install_working_tree() {
    say "Installing working-tree files over the packaged ones"
    local f
    for f in runner log-helper network-helper vm-launch; do
        install -m 0755 -o root -g root "${REPO}/${f}" "${LIBEXEC}/${f}" || exit 1
        echo "  ${LIBEXEC}/${f}"
    done
    install -m 0644 -o root -g root "${REPO}/aos-unit-node@.service" "${UNIT_DIR}/aos-unit-node@.service" || exit 1
    echo "  ${UNIT_DIR}/aos-unit-node@.service"
    systemctl daemon-reload
}

verify_units() {
    say "systemd-analyze verify"
    # Expected noise: the env files live in /run and only exist while running
    systemd-analyze verify "aos-unit-node@main.service" 2>&1 | sed 's/^/  /'
}

report_state() {
    local label="$1" node unit
    say "State after ${label}"
    for node in "${NODES[@]}"; do
        unit="$(unit_of "$node")"
        printf '  %-34s Load=%-8s Active=%-10s Sub=%-10s MainPID=%s\n' \
            "$unit" "$(show "$unit" LoadState)" "$(show "$unit" ActiveState)" \
            "$(show "$unit" SubState)" "$(show "$unit" MainPID)"
    done
    printf '  %-34s Active=%s\n' "aos-unit.service" "$(show aos-unit.service ActiveState)"
    printf '  taps: %s\n' "$(ip -o link show | awk -F': ' '/aostap/ {printf "%s ", $2}')"
    printf '  bridge: %s\n' "$(ip -o link show type bridge | awk -F': ' '/aosbr/ {printf "%s ", $2}')"
}

expect_running() {
    local label="$1" node unit
    say "Assertions after ${label}"
    for node in "${NODES[@]}"; do
        unit="$(unit_of "$node")"
        check "${node}: ActiveState" "active" "$(show "$unit" ActiveState)"
        check "${node}: LoadState stays loaded" "loaded" "$(show "$unit" LoadState)"
        # ps truncates comm at 15 chars, so read the exe link instead
        check "${node}: MainPID is qemu" "qemu-system-x86_64" \
            "$(basename "$(readlink -f "/proc/$(show "$unit" MainPID)/exe" 2>/dev/null)" 2>/dev/null)"
    done

    # unit_config.yaml: main = 4 cpu / 8G, secondary = 2 cpu / 4G
    check "main: memory.max cpu.max" "8589934592 400000 100000" "$(cgroup_limits "$(unit_of main)")"
    check "secondary: memory.max cpu.max" "4294967296 200000 100000" "$(cgroup_limits "$(unit_of secondary)")"
}

race_errors_since() {
    local since="$1"
    journalctl --no-pager --since "$since" -u aos-unit.service -u 'aos-unit-node@*' 2>/dev/null |
        grep -iE 'already exists|already running|already loaded|Failed to start unit|circular' || true
}

main() {
    local started_at
    started_at="$(date '+%Y-%m-%d %H:%M:%S')"

    say "Config in use"
    grep -E 'name|cpu|mem|uefi|ip' /etc/aos-unit/unit_config.yaml | grep -v '^\s*#' | sed 's/^/  /'

    install_working_tree
    verify_units

    say "Clean slate"
    systemctl stop aos-unit.service
    sleep 2
    report_state "stop (pre-test)"

    say "Start"
    time systemctl start aos-unit.service
    sleep 5
    report_state "start"
    expect_running "start"

    say "Letting guests boot for 45s so ACPI power-down is honoured"
    sleep 45

    local i
    for i in 1 2; do
        say "Restart #${i} (the scenario from issue #11)"
        time systemctl restart aos-unit.service
        sleep 5
        report_state "restart #${i}"
        expect_running "restart #${i}"
    done

    say "Stop"
    time systemctl stop aos-unit.service
    sleep 3
    report_state "stop"

    local node unit
    for node in "${NODES[@]}"; do
        unit="$(unit_of "$node")"
        # Cleanup clears the "failed" left by a SIGKILLed guest; the runtime
        # limit drop-ins are expected to survive (see network-helper cleanup)
        check "${node}: stopped and not left failed" "inactive" "$(show "$unit" ActiveState)"
    done
    check "taps removed" "" "$(ip -o link show | awk -F': ' '/aostap/ {printf "%s ", $2}')"
    check "bridge removed" "" "$(ip -o link show type bridge | awk -F': ' '/aosbr/ {printf "%s ", $2}')"

    say "Shutdown diagnostics (pre-existing ACPI behaviour, not phase 3)"
    journalctl --no-pager --since "$started_at" -u 'aos-unit-node@*' 2>/dev/null |
        grep -iE 'timed out|Killing|SIGKILL|power-down|has halted|QMP' |
        sed 's/^/  /' | tail -20

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
