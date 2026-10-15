#!/usr/bin/env bash
# Phase 2 (PR #14) acceptance against the INSTALLED package.
#   T2.1  start -> restart x2 -> stop: static dnsmasq, Transient=no each time
#   T2.2  teardown order nodes -> dnsmasq -> bridge (+ SIGSTOPped guest)
#   T2.3  a transient aos-unit-dnsmasq cannot be created next to the unit file
#         (the migration itself is the package upgrade: upgrade-acceptance.sh,
#         phase2-preinst-stuck.sh)
#   T2.5  dnsmasq failure shapes end with a clean stop and a clean next start
#
# Usage: phase2-acceptance.sh [T2.1] [T2.2] [T2.3] [T2.5]    (default: all)

set -u

AOS_DNSMASQ="${AOS_DNSMASQ:-aos-unit-dnsmasq.service}"
. "$(dirname "$(realpath "$0")")/lib-issue11.sh"
SUMMARY=/tmp/aos-phase2-summary.txt

# Journal monotonic timestamp (us) of the first / last line matching $2 since $1.
# Unit timestamps from systemctl show are no use after a stop: an inactive,
# unreferenced unit is garbage-collected and reloads with zeroed timestamps.
journal_mono_us() {
    journal_units "$1" | grep -m1 -E "$2" | awk '{ gsub(/[][]/, "", $1); printf "%d\n", $1 * 1000000 }'
}
journal_mono_us_last() {
    journal_units "$1" | grep -E "$2" | tail -1 | awk '{ gsub(/[][]/, "", $1); printf "%d\n", $1 * 1000000 }'
}

all_nodes_active() {
    local name
    for name in $(node_names); do
        unit_is "$(node_unit "$name")" active || return 1
    done
}

assert_dnsmasq_static() {
    local id="$1" label="$2" frag
    check "$id" "${label}: dnsmasq active" active "$(show "$AOS_DNSMASQ" ActiveState)"
    check "$id" "${label}: dnsmasq Transient" no "$(show "$AOS_DNSMASQ" Transient)"
    frag="$(show "$AOS_DNSMASQ" FragmentPath)"
    check "$id" "${label}: dnsmasq FragmentPath packaged" yes \
        "$([[ $frag == /lib/systemd/system/* || $frag == /usr/lib/systemd/system/* ]] && echo yes || echo "no (${frag})")"
}

assert_clean_stop() {
    local id="$1" label="$2"
    check "$id" "${label}: aos-unit inactive" inactive "$(show aos-unit.service ActiveState)"
    check "$id" "${label}: dnsmasq inactive" inactive "$(show "$AOS_DNSMASQ" ActiveState)"
    check "$id" "${label}: dnsmasq stays loaded" loaded "$(show "$AOS_DNSMASQ" LoadState)"
    check "$id" "${label}: no failed aos-unit units" "" "$(failed_aos_units)"
    check "$id" "${label}: bridge removed" "" "$(bridges)"
    check "$id" "${label}: taps removed" "" "$(taps)"
}

assert_clean_start() {
    local id="$1" label="$2"
    check_cmd "$id" "${label}: all nodes active within 60s" wait_until 60 all_nodes_active
    check "$id" "${label}: aos-unit active" active "$(show aos-unit.service ActiveState)"
    assert_dnsmasq_static "$id" "$label"
}

t2_1() {
    say "T2.1 start -> restart x2 -> stop"
    clean_slate
    local since i pid_before
    since="$(now)"
    systemctl start aos-unit.service
    assert_clean_start T2.1 start
    for i in 1 2; do
        # A guest that has not booted ignores ACPI and is killed (F-3)
        wait_guests_booted
        pid_before="$(show "$AOS_DNSMASQ" MainPID)"
        systemctl restart aos-unit.service
        assert_clean_start T2.1 "restart#${i}"
        check T2.1 "restart#${i}: dnsmasq restarted (new MainPID)" yes \
            "$([[ $(show "$AOS_DNSMASQ" MainPID) != "$pid_before" ]] && echo yes || echo no)"
    done
    wait_guests_booted
    systemctl stop aos-unit.service
    assert_clean_stop T2.1 stop
    check T2.1 "no automatic manager restart" 0 \
        "$(journal_units "$since" | grep -c 'aos-unit.service: Scheduled restart job')"
    check_no_race T2.1 "$since"
}

# Order proof from journal anchors: last node stopped < dnsmasq stop begins;
# dnsmasq stopped < "Removing bridge". dnsmasq may log its SIGTERM before
# systemd logs "Stopping", so the stop anchor is whichever comes first.
check_teardown_order() {
    local id="$1" since="$2" last_node dns_stop dns_down bridge_rm
    last_node="$(journal_mono_us_last "$since" 'systemd\[1\]: (Stopped aos-unit-node@|aos-unit-node@[^:]+: Failed with result)')"
    dns_stop="$(journal_mono_us "$since" "systemd\[1\]: Stopping ${AOS_DNSMASQ}|dnsmasq\[[0-9]+\]: exiting on receipt of SIGTERM")"
    dns_down="$(journal_mono_us "$since" "systemd\[1\]: (Stopped ${AOS_DNSMASQ}|${AOS_DNSMASQ}: Failed with result)")"
    bridge_rm="$(journal_mono_us "$since" 'Removing bridge')"
    info "$id" "last node stopped / dns stop / dns stopped / bridge rm (us)" \
        "${last_node:-none} / ${dns_stop:-none} / ${dns_down:-none} / ${bridge_rm:-none}"
    check "$id" "nodes inactive before dnsmasq stops" yes \
        "$([[ -n $last_node && -n $dns_stop ]] && ((last_node < dns_stop)) && echo yes || echo no)"
    check "$id" "dnsmasq inactive before bridge removal" yes \
        "$([[ -n $dns_down && -n $bridge_rm ]] && ((dns_down < bridge_rm)) && echo yes || echo no)"
}

t2_2() {
    say "T2.2 teardown order"
    clean_slate
    systemctl start aos-unit.service
    wait_until 60 all_nodes_active
    wait_guests_booted
    local since
    since="$(now)"
    systemctl stop aos-unit.service
    check_teardown_order T2.2 "$since"
    assert_clean_stop T2.2 "stop"

    say "T2.2b teardown order with a SIGSTOPped guest"
    clean_slate
    systemctl start aos-unit.service
    wait_until 60 all_nodes_active
    wait_guests_booted
    local victim unit pid dns_alive=yes samples=0
    victim="$(node_names | sed -n 2p)"
    unit="$(node_unit "$victim")"
    pid="$(show "$unit" MainPID)"
    kill -STOP "$pid"
    since="$(now)"
    systemctl stop --no-block aos-unit.service
    # While the frozen guest is still being stopped, DHCP/DNS must stay up
    while [[ "$(show "$unit" ActiveState)" != inactive && "$(show "$unit" ActiveState)" != failed ]]; do
        samples=$((samples + 1))
        [[ "$(show "$AOS_DNSMASQ" ActiveState)" == active ]] || dns_alive=no
        sleep 1
        ((samples > 200)) && break
    done
    info T2.2 "samples while ${victim} was stopping" "$samples"
    check T2.2 "dnsmasq active for as long as ${victim} was alive" yes "$dns_alive"
    wait_until 150 unit_is aos-unit.service inactive
    check_teardown_order T2.2 "$since"
    assert_clean_stop T2.2 "SIGSTOP stop"
}

# The packaged sidecar reuses the transient name, so the only migration point
# is the package upgrade. At runtime, with the unit file installed, systemd
# must refuse a same-name transient, or it could shadow the file again.
t2_3() {
    local since out rc
    say "T2.3 same-name transient refused while the unit file is installed"
    clean_slate
    out="$(systemd-run --quiet --collect --unit="$AOS_DNSMASQ" sleep 600 2>&1)"
    rc=$?
    info T2.3 "systemd-run exit code / message" "${rc} / ${out}"
    check T2.3 "transient refused" yes "$( ((rc != 0)) && echo yes || echo no)"
    if ((rc == 0)); then
        systemctl stop "$AOS_DNSMASQ"
        systemctl daemon-reload
    fi
    check T2.3 "sidecar still loaded from its file" "loaded no" \
        "$(show "$AOS_DNSMASQ" LoadState) $(show "$AOS_DNSMASQ" Transient)"
    since="$(now)"
    systemctl start aos-unit.service
    assert_clean_start T2.3 "start after refusal"
    check T2.3 "no automatic manager restart" 0 \
        "$(journal_units "$since" | grep -c 'aos-unit.service: Scheduled restart job')"
    check_no_race T2.3 "$since"
    wait_guests_booted
    systemctl stop aos-unit.service
    assert_clean_stop T2.3 stop
}

t2_5_case() {
    local label="$1"
    systemctl stop aos-unit.service
    assert_clean_stop T2.5 "${label}: stop"
    systemctl start aos-unit.service
    assert_clean_start T2.5 "${label}: next start"
    wait_guests_booted
    systemctl stop aos-unit.service
}

t2_5() {
    say "T2.5a dnsmasq killed with SIGKILL while running"
    clean_slate
    systemctl start aos-unit.service
    wait_until 60 all_nodes_active
    local pid
    pid="$(show "$AOS_DNSMASQ" MainPID)"
    kill -KILL "$pid"
    check_cmd T2.5 "SIGKILL: dnsmasq back with a new PID within 10s" \
        wait_until 10 bash -c "[[ \$(systemctl show -p ActiveState --value $AOS_DNSMASQ) == active && \$(systemctl show -p MainPID --value $AOS_DNSMASQ) != $pid ]]"
    wait_guests_booted
    t2_5_case SIGKILL

    say "T2.5b dnsmasq frozen with SIGSTOP at manager stop"
    clean_slate
    systemctl start aos-unit.service
    wait_until 60 all_nodes_active
    wait_guests_booted
    kill -STOP "$(show "$AOS_DNSMASQ" MainPID)"
    t2_5_case SIGSTOP

    say "T2.5c DNS port already taken"
    clean_slate
    local port holder
    port="$(awk -F= '/^DNS_ALT_PORT=/ {gsub(/"/, "", $2); print $2}' /etc/aos-unit/runtime.conf)"
    port="${port:-5300}"
    python3 -c "
import socket, time
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.bind(('0.0.0.0', ${port}))
t = socket.socket(socket.AF_INET, socket.SOCK_STREAM); t.bind(('0.0.0.0', ${port})); t.listen()
time.sleep(600)" &
    holder=$!
    sleep 1
    local rc
    systemctl start aos-unit.service
    rc=$?
    sleep 5
    info T2.5 "port taken: start exit code" "$rc"
    info T2.5 "port taken: aos-unit / dnsmasq" "$(show aos-unit.service ActiveState) / $(show "$AOS_DNSMASQ" ActiveState)"
    kill "$holder" 2>/dev/null
    wait "$holder" 2>/dev/null
    systemctl reset-failed aos-unit.service 2>/dev/null
    t2_5_case "port taken"

    say "T2.5d failed dnsmasq left over at start"
    clean_slate
    mkdir -p "$AOS_RUN"
    printf 'this-is-not-an-option\n' >"${AOS_RUN}/dnsmasq.conf"
    touch "${AOS_RUN}/network.conf"
    systemctl start "$AOS_DNSMASQ" 2>/dev/null
    wait_until 20 unit_is "$AOS_DNSMASQ" failed
    check T2.5 "leftover: dnsmasq failed before manager start" failed "$(show "$AOS_DNSMASQ" ActiveState)"
    rm -rf "$AOS_RUN"
    systemctl start aos-unit.service
    assert_clean_start T2.5 "leftover failed: first start"
    wait_guests_booted
    t2_5_case "leftover failed"
}

main() {
    local -a tests=("$@")
    ((${#tests[@]})) || tests=(T2.1 T2.2 T2.3 T2.5)
    local t
    for t in "${tests[@]}"; do
        case "$t" in
            T2.1) t2_1 ;;
            T2.2) t2_2 ;;
            T2.3) t2_3 ;;
            T2.5) t2_5 ;;
            *) echo "unknown test $t" ;;
        esac
    done
    summary "Phase 2 acceptance"
    return "$FAILS"
}

main "$@"
