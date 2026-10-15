#!/usr/bin/env bash
# Shared helpers for the issue #11 acceptance scripts. Source it, do not run it.

readonly AOS_CONFIG=/etc/aos-unit/unit_config.yaml
readonly AOS_RUN=/run/aos-unit
readonly AOS_GATE="${AOS_RUN}/allow-node-start"
# Sidecar under test: transient up to Phase 3, packaged from Phase 2 on, both
# named aos-unit-dnsmasq
readonly AOS_LEGACY_DNSMASQ=aos-unit-dnsmasq.service
: "${AOS_DNSMASQ:=${AOS_LEGACY_DNSMASQ}}"
readonly AOS_DNSMASQ
readonly AOS_FAILURES_LOG=/var/log/aos-unit/vm-failures.log

: "${GUEST_BOOT_MAX_SEC:=180}"
: "${SUMMARY:=/tmp/aos-issue11-summary.txt}"

FAILS=0
declare -a RESULTS=()

say() { printf '\n=== %s ===\n' "$*"; }
now() { date '+%Y-%m-%d %H:%M:%S'; }
show() { systemctl show -p "$2" --value "$1" 2>/dev/null; }

record() {
    local id="$1" status="$2" what="$3" detail="$4"
    RESULTS+=("${id}|${status}|${what}|${detail}")
    printf '%-4s  %-6s %-58s %s\n' "$status" "$id" "$what" "$detail"
    if [[ $status == FAIL ]]; then
        FAILS=$((FAILS + 1))
    fi
}

check() {
    local id="$1" what="$2" expected="$3" actual="$4"
    if [[ $expected == "$actual" ]]; then
        record "$id" PASS "$what" "$actual"
    else
        record "$id" FAIL "$what" "expected=[${expected}] actual=[${actual}]"
    fi
}

check_cmd() {
    local id="$1" what="$2"
    shift 2
    if "$@"; then
        record "$id" PASS "$what" "ok"
    else
        record "$id" FAIL "$what" "condition false"
    fi
}

info() { record "$1" INFO "$2" "$3"; }

# "name cpu mem" for every node in unit_config.yaml
node_specs() {
    awk '$1 == "-" && $2 == "name:" { if (n != "") print n, c, m; n = $3; c = ""; m = "" }
         $1 == "cpu:" { c = $2 }
         $1 == "mem:" { m = $2 }
         END { if (n != "") print n, c, m }' "$AOS_CONFIG"
}

node_names() { node_specs | awk '{print $1}'; }
node_unit() { printf 'aos-unit-node@%s.service' "$1"; }
legacy_node_unit() { printf 'aos-unit-node-%s.service' "$1"; }

mem_to_bytes() {
    local m="$1"
    case "$m" in
        *G) echo $((${m%G} * 1024 * 1024 * 1024)) ;;
        *M) echo $((${m%M} * 1024 * 1024)) ;;
        *) echo $((m * 1024 * 1024)) ;;
    esac
}

cgroup_limits() {
    local cg
    cg="$(show "$1" ControlGroup)"
    if [[ -z $cg || ! -d "/sys/fs/cgroup${cg}" ]]; then
        echo "no-cgroup"
        return
    fi
    printf '%s %s\n' "$(cat "/sys/fs/cgroup${cg}/memory.max")" "$(cat "/sys/fs/cgroup${cg}/cpu.max")"
}

main_exe() {
    local pid
    pid="$(show "$1" MainPID)"
    [[ -n $pid && $pid != 0 ]] || return 0
    basename "$(readlink -f "/proc/${pid}/exe" 2>/dev/null)" 2>/dev/null || true
}

taps() { ip -o link show | awk -F': ' '/aostap/ {printf "%s ", $2}'; }
bridges() { ip -o link show type bridge | awk -F': ' '/aosbr/ {printf "%s ", $2}'; }
failed_aos_units() { systemctl list-units --failed --plain --no-legend 'aos-unit*' 2>/dev/null | grep -o 'aos-unit[^[:space:]]*' | tr '\n' ' '; }
failures_log_lines() { if [[ -f $AOS_FAILURES_LOG ]]; then wc -l <"$AOS_FAILURES_LOG"; else echo 0; fi; }

journal_units() {
    journalctl --no-pager --since "$1" -o short-monotonic \
        -u aos-unit.service -u "$AOS_LEGACY_DNSMASQ" \
        -u 'aos-unit-node@*' -u 'aos-unit-node-*' \
        -u 'aos-unit-vm-failed@*' 2>/dev/null
}

race_errors_since() {
    journal_units "$1" |
        grep -iE "already exists|already running|already loaded|result 'resources'|Result: resources|Failed to load environment files|Failed to start unit|circular|VM unit FAILED" || true
}

check_no_race() {
    local id="$1" since="$2" race
    race="$(race_errors_since "$since")"
    if [[ -z $race ]]; then
        record "$id" PASS "journal: no race/failure strings" "none"
    else
        record "$id" FAIL "journal: no race/failure strings" "$(wc -l <<<"$race") line(s)"
        sed 's/^/        /' <<<"$race" | tail -15
    fi
}

wait_until() {
    local timeout="$1"
    shift
    local deadline=$((SECONDS + timeout))
    while ((SECONDS < deadline)); do
        if "$@"; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

unit_is() { [[ "$(show "$1" ActiveState)" == "$2" ]]; }

# A guest only honours the ACPI power-down once its OS is up. "Up" means a
# DHCP lease, or answering ping for nodes configured with a static IP (the
# AosCore main image does not use DHCP).
guest_has_lease() {
    local node="$1" env="${AOS_RUN}/nodes/${1}.env" mac ip
    mac="$(awk -F'"' '/^NODE_MAC=/ {print $2}' "$env" 2>/dev/null)"
    ip="$(awk -F'"' '/^NODE_IP=/ {print $2}' "$env" 2>/dev/null)"
    [[ -n $mac ]] || return 1
    if [[ -n $ip ]]; then
        ping -c1 -W1 "$ip" >/dev/null 2>&1
    else
        grep -qi "$mac" "${AOS_RUN}/dnsmasq.leases" 2>/dev/null
    fi
}

wait_guests_booted() {
    local node
    for node in $(node_names); do
        if ! wait_until "$GUEST_BOOT_MAX_SEC" guest_has_lease "$node"; then
            echo "  WARN: ${node} has no DHCP lease after ${GUEST_BOOT_MAX_SEC}s"
        fi
    done
    # logind needs a few more seconds after networking to handle the button
    sleep 10
}

report_state() {
    local node unit
    printf '  %-36s Active=%s NRestarts=%s\n' aos-unit.service "$(show aos-unit.service ActiveState)" "$(show aos-unit.service NRestarts)"
    printf '  %-36s Load=%s Active=%s Transient=%s\n' "$AOS_DNSMASQ" "$(show "$AOS_DNSMASQ" LoadState)" \
        "$(show "$AOS_DNSMASQ" ActiveState)" "$(show "$AOS_DNSMASQ" Transient)"
    for node in $(node_names); do
        unit="$(node_unit "$node")"
        printf '  %-36s Load=%s Active=%s Sub=%s PID=%s\n' "$unit" "$(show "$unit" LoadState)" \
            "$(show "$unit" ActiveState)" "$(show "$unit" SubState)" "$(show "$unit" MainPID)"
    done
    printf '  gate=%s taps=[%s] bridge=[%s] failed=[%s]\n' \
        "$([[ -e $AOS_GATE ]] && echo present || echo absent)" "$(taps)" "$(bridges)" "$(failed_aos_units)"
}

clean_slate() {
    systemctl stop aos-unit.service 2>/dev/null || true
    local node
    for node in $(node_names); do
        systemctl reset-failed "$(node_unit "$node")" 2>/dev/null || true
    done
    systemctl reset-failed aos-unit.service "$AOS_DNSMASQ" "$AOS_LEGACY_DNSMASQ" 2>/dev/null || true
    # journalctl --since has 1s resolution: keep the teardown out of the next window
    sleep 1.1
}

summary() {
    local title="$1" line
    {
        echo "=== ${title} $(now) ==="
        echo "package: $(dpkg-query -W -f='${Version}' aos-unit 2>/dev/null)"
        for line in "${RESULTS[@]}"; do
            IFS='|' read -r id status what detail <<<"$line"
            printf '%-4s  %-6s %-58s %s\n' "$status" "$id" "$what" "$detail"
        done
        if ((FAILS == 0)); then
            echo "RESULT: ALL CHECKS PASSED"
        else
            echo "RESULT: ${FAILS} CHECK(S) FAILED"
        fi
    } | tee "$SUMMARY"
}
