#!/usr/bin/env bash
# Die / shutdown order matrix for the transient-unit wait (PR #12 / issue #9).
# Run on a Linux host with systemd, as root:
#   sudo tests/die-shutdown-order-matrix.sh
#   sudo tests/die-shutdown-order-matrix.sh --helpers-only
#   sudo tests/die-shutdown-order-matrix.sh --setup-images /var/tmp/aos-core-v6.1.2
#
# Does not post to GitHub. Prints a PASS/FAIL matrix for the PR #12 review reply.
#
# Case families (see tests/README.md): H wait helper, G guests boot,
# P planned stop/restart, D runner or QEMU dies, L leftover unit at start,
# C failed unit cleaned on stop, V VM failure shapes, N dnsmasq failure
# shapes, O stop-order evidence.

set -Eeuo pipefail

LIBEXEC_DIR="${LIBEXEC_DIR:-/usr/libexec/aos-unit}"
readonly LIBEXEC_DIR
readonly LOG_TAG="aos-unit:matrix"
# shellcheck source=/usr/libexec/aos-unit/log-helper
. "${LIBEXEC_DIR}/log-helper"

readonly DUMMY_UNIT="aos-unit-matrix-dummy"
readonly MAIN_NODE_UNIT="aos-unit-node-main"
readonly SECONDARY_NODE_UNIT="aos-unit-node-secondary"
readonly DNSMASQ_UNIT="aos-unit-dnsmasq"
readonly STATE_DIR="/var/lib/aos-unit"
readonly CONFIG_DIR="/etc/aos-unit"
readonly BACKUP_DIR="/var/tmp/aos-unit-matrix-backup"
readonly RESULTS_FILE="/tmp/aos-unit-matrix-results.txt"

HELPERS_ONLY=0
CLUSTER_ONLY=0
SETUP_IMAGES=""
SKIP_GUEST_WAIT=0
CASES=""
MATRIX_PRINTED=0
PASS=0
FAIL=0
SKIP=0
declare -a ROWS=()

usage() {
    cat <<'EOF'
Usage:
  die-shutdown-order-matrix.sh [--helpers-only] [--cluster-only] [--setup-images DIR] [--skip-guest-wait]
                               [--cases "H5 V1 N3"]
EOF
    exit 2
}

ts() { date '+%Y-%m-%d %H:%M:%S'; }

row() {
    local status="$1" id="$2" title="$3" detail="${4:-}"
    ROWS+=("$(printf '%-6s %-6s %s%s' "$status" "$id" "$title" "${detail:+ — $detail}")")
    case "$status" in
        PASS) PASS=$((PASS + 1)) ;;
        FAIL) FAIL=$((FAIL + 1)) ;;
        SKIP) SKIP=$((SKIP + 1)) ;;
    esac
    log "${status}: ${id} ${title}${detail:+ (${detail})}"
}

require_root() {
    [[ $(id -u) -eq 0 ]] || die "${EXIT_CONFIG_ERROR}" "Run as root"
}

require_cmds() {
    local cmd
    for cmd in systemctl systemd-run journalctl qemu-img; do
        command -v "$cmd" >/dev/null 2>&1 || die "${EXIT_CONFIG_ERROR}" "Missing command: $cmd"
    done
    command -v ping >/dev/null 2>&1 || die "${EXIT_CONFIG_ERROR}" "Missing command: ping"
}

journal_since_has() {
    local since="$1" pattern="$2"
    journalctl -u aos-unit --since "$since" --no-pager -o cat 2>/dev/null | grep -E -q "$pattern"
}

assert_no_unit_collision() {
    local since="$1"
    if journal_since_has "$since" 'already exists|already loaded|already running'; then
        return 1
    fi
    return 0
}

wait_active() {
    local unit="$1" timeout_s="${2:-180}"
    local i
    for ((i = 0; i < timeout_s; i++)); do
        if systemctl is-active --quiet "$unit"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

load_state() {
    systemctl show -p LoadState --value "${1}.service" 2>/dev/null || true
}

start_dummy_collect() {
    local unit="$1"
    shift
    systemd-run --unit="$unit" --collect --quiet --property=Type=simple -- "${@:-/bin/sleep 30}"
}

cleanup_dummy() {
    systemctl kill --signal=SIGKILL "${DUMMY_UNIT}.service" >/dev/null 2>&1 || true
    systemctl stop "${DUMMY_UNIT}.service" >/dev/null 2>&1 || true
    systemctl reset-failed "${DUMMY_UNIT}.service" >/dev/null 2>&1 || true
    wait_for_transient_cleanup "$DUMMY_UNIT" || true
}

# --- helper cases (no AosCore guests) ---

case_h1_wait_then_recreate() {
    cleanup_dummy
    start_dummy_collect "$DUMMY_UNIT" /bin/sleep 5
    wait_for_transient_cleanup "$DUMMY_UNIT"
    if start_dummy_collect "$DUMMY_UNIT" /bin/sleep 2; then
        cleanup_dummy
        row PASS H1 "Wait then recreate same --collect unit"
    else
        cleanup_dummy
        row FAIL H1 "Wait then recreate same --collect unit" "systemd-run still rejected the name"
    fi
}

case_h2_stop_running_via_wait() {
    cleanup_dummy
    start_dummy_collect "$DUMMY_UNIT" /bin/sleep 120
    wait_for_transient_cleanup "$DUMMY_UNIT"
    local state
    state="$(load_state "$DUMMY_UNIT")"
    if [[ $state == "not-found" || -z $state ]]; then
        row PASS H2 "Wait stops a still-running transient unit"
    else
        row FAIL H2 "Wait stops a still-running transient unit" "LoadState=${state}"
    fi
}

case_h3_failed_unit_reset() {
    cleanup_dummy
    systemd-run --unit="$DUMMY_UNIT" --collect --quiet -- /bin/false || true
    sleep 0.5
    wait_for_transient_cleanup "$DUMMY_UNIT"
    if start_dummy_collect "$DUMMY_UNIT" /bin/sleep 2; then
        cleanup_dummy
        row PASS H3 "Wait recovers a failed --collect unit"
    else
        cleanup_dummy
        row FAIL H3 "Wait recovers a failed --collect unit"
    fi
}

case_h4_not_found_is_noop() {
    cleanup_dummy
    if wait_for_transient_cleanup "$DUMMY_UNIT"; then
        row PASS H4 "Wait is a no-op when unit is already gone"
    else
        row FAIL H4 "Wait is a no-op when unit is already gone"
    fi
}

# Transient unit whose stop never completes on its own.
start_dummy_unstoppable() {
    systemd-run --unit="$DUMMY_UNIT" --collect --quiet \
        --property=Type=simple \
        --property="ExecStop=/bin/sleep 600" \
        --property=TimeoutStopSec=infinity \
        -- /bin/sleep 600
}

case_h5_wait_is_bounded() {
    cleanup_dummy
    start_dummy_unstoppable
    local t0=$SECONDS rc=0
    wait_for_transient_cleanup "$DUMMY_UNIT" 3 || rc=$?
    local elapsed=$((SECONDS - t0))
    cleanup_dummy
    if [[ $rc -ne 0 && $elapsed -ge 2 && $elapsed -le 6 ]]; then
        row PASS H5 "Wait gives up at its deadline" "rc=${rc} after ${elapsed}s"
    else
        row FAIL H5 "Wait gives up at its deadline" "rc=${rc} after ${elapsed}s"
    fi
}

case_h6_query_error_is_not_success() {
    cleanup_dummy
    local shim rc=0
    shim="$(mktemp -d)"
    cat >"${shim}/systemctl" <<EOF
#!/usr/bin/env bash
if [[ \${1:-} == show ]]; then
    echo "Failed to connect to bus: simulated" >&2
    exit 1
fi
exec $(command -v systemctl) "\$@"
EOF
    chmod +x "${shim}/systemctl"
    (PATH="${shim}:${PATH}" wait_for_transient_cleanup "$DUMMY_UNIT" 2) || rc=$?
    rm -rf "$shim"
    if [[ $rc -ne 0 ]]; then
        row PASS H6 "systemctl show failure is not treated as unloaded" "rc=${rc}"
    else
        row FAIL H6 "systemctl show failure is not treated as unloaded" "returned 0"
    fi
}

case_h7_caller_trap_preserved() {
    cleanup_dummy
    start_dummy_collect "$DUMMY_UNIT" /bin/sleep 30
    local result
    result="$(
        trap 'echo caller-trap' SIGTERM
        before="$(trap -p SIGTERM)"
        wait_for_transient_cleanup "$DUMMY_UNIT" 10 >/dev/null 2>&1 || true
        after="$(trap -p SIGTERM)"
        [[ $before == "$after" ]] && echo same || echo "changed: '${before}' -> '${after}'"
    )"
    cleanup_dummy
    if [[ $result == same ]]; then
        row PASS H7 "Caller SIGTERM trap is preserved"
    else
        row FAIL H7 "Caller SIGTERM trap is preserved" "$result"
    fi
}

case_h8_sigterm_during_wait() {
    cleanup_dummy
    start_dummy_unstoppable
    env LIBEXEC_DIR="$LIBEXEC_DIR" DUMMY_UNIT="$DUMMY_UNIT" bash -c '
        . "${LIBEXEC_DIR}/log-helper"
        trap "exit 0" SIGTERM
        wait_for_transient_cleanup "$DUMMY_UNIT" 60
        exit 3
    ' &
    local pid=$! rc=0
    sleep 1
    local t0=$SECONDS
    kill -TERM "$pid"
    wait "$pid" || rc=$?
    local elapsed=$((SECONDS - t0))
    cleanup_dummy
    if [[ $rc -eq 0 && $elapsed -le 2 ]]; then
        row PASS H8 "SIGTERM during wait runs the caller trap" "exit ${rc} after ${elapsed}s"
    else
        row FAIL H8 "SIGTERM during wait runs the caller trap" "exit ${rc} after ${elapsed}s"
    fi
}

# --- cluster helpers ---

install_images_from_dir() {
    local dir="$1"
    local archive="${dir}/aos-vm-image-qemux86-64-6.1.2.tar.xz"
    [[ -f $archive ]] || die "${EXIT_CONFIG_ERROR}" "Bootable image archive not found: $archive"

    mkdir -p "$BACKUP_DIR" "${dir}/extracted"
    if [[ ! -f ${dir}/extracted/aos-vm-main-qemux86-64.qcow2 ]]; then
        log "Extracting ${archive}"
        tar -xJf "$archive" -C "${dir}/extracted"
    fi

    local main_img secondary_img
    main_img="$(find "${dir}/extracted" -name 'aos-vm-main-qemux86-64.qcow2' | head -n1)"
    secondary_img="$(find "${dir}/extracted" -name 'aos-vm-secondary-qemux86-64.qcow2' | head -n1)"
    [[ -n $main_img && -n $secondary_img ]] ||
        die "${EXIT_CONFIG_ERROR}" "qcow2 files missing after extract of $archive"

    log "Backing up existing qcow2 files to ${BACKUP_DIR}"
    cp -a "${STATE_DIR}/aos-vm-main-qemux86-64.qcow2" "${BACKUP_DIR}/" 2>/dev/null || true
    cp -a "${STATE_DIR}/aos-vm-secondary-qemux86-64.qcow2" "${BACKUP_DIR}/" 2>/dev/null || true

    install -m 0644 -o aos-unit -g aos-unit "$main_img" "${STATE_DIR}/aos-vm-main-qemux86-64.qcow2"
    install -m 0644 -o aos-unit -g aos-unit "$secondary_img" "${STATE_DIR}/aos-vm-secondary-qemux86-64.qcow2"
    log "Installed main image virtual-size=$(qemu-img info --output=json "${STATE_DIR}/aos-vm-main-qemux86-64.qcow2" | grep -o '"virtual-size": [0-9]*' | head -n1)"
    log "Stopping aos-unit so QEMU releases previous disks"
    systemctl stop aos-unit || true
}

apply_test_unit_config() {
    mkdir -p "$BACKUP_DIR"
    cp -a "${CONFIG_DIR}/unit_config.yaml" "${BACKUP_DIR}/unit_config.yaml"
    cat >"${CONFIG_DIR}/unit_config.yaml" <<'EOF'
unit:
  node_configs:
    - name: main
      cpu: 2
      mem: 2G
      ip: 10.0.0.100
      uefi: true
    - name: secondary
      cpu: 2
      mem: 2G
      uefi: true
EOF
}

restore_unit_config() {
    if [[ -f ${BACKUP_DIR}/unit_config.yaml ]]; then
        cp -a "${BACKUP_DIR}/unit_config.yaml" "${CONFIG_DIR}/unit_config.yaml"
    fi
}

cluster_up() {
    systemctl reset-failed aos-unit.service >/dev/null 2>&1 || true
    if ! systemctl is-active --quiet aos-unit.service; then
        systemctl start aos-unit || true
    fi
    settle_cluster
}

settle_cluster() {
    wait_active aos-unit.service 180 || return 1
    wait_active "${MAIN_NODE_UNIT}.service" 60 || return 1
    wait_active "${SECONDARY_NODE_UNIT}.service" 60 || return 1
    wait_active "${DNSMASQ_UNIT}.service" 30 || return 1
}

assert_clean_start() {
    local since="$1"
    local allow_on_failure_restart="${2:-0}"
    settle_cluster || return 1
    assert_no_unit_collision "$since" || return 1
    if journal_since_has "$since" 'Failed to start transient|Unit .* already exists|already running|did not unload'; then
        return 1
    fi
    if [[ $allow_on_failure_restart -eq 0 ]]; then
        if journal_since_has "$since" 'Failed to start AosEdge Unit VM Manager'; then
            return 1
        fi
        if journal_since_has "$since" 'Scheduled restart job'; then
            return 1
        fi
    fi
    return 0
}

# Every start counts against aos-unit StartLimitBurst=5/60s; reset it so the
# matrix itself does not trip the rate limit.
svc_start() {
    systemctl reset-failed aos-unit.service >/dev/null 2>&1 || true
    systemctl start aos-unit || true
}

svc_restart() {
    systemctl reset-failed aos-unit.service >/dev/null 2>&1 || true
    systemctl restart aos-unit || true
}

svc_stop() {
    systemctl stop aos-unit || true
    systemctl reset-failed aos-unit.service >/dev/null 2>&1 || true
}

LEFTOVER=""

assert_no_leftovers() {
    local unit
    LEFTOVER=""
    for unit in "$DNSMASQ_UNIT" "$MAIN_NODE_UNIT" "$SECONDARY_NODE_UNIT"; do
        if [[ $(load_state "$unit") != "not-found" ]]; then
            LEFTOVER="${unit} still loaded"
            return 1
        fi
    done
    if ip -o link show type bridge 2>/dev/null | grep -q ': aosbr'; then
        LEFTOVER="aosbr bridge left"
        return 1
    fi
    if nft list table inet aos_unit >/dev/null 2>&1; then
        LEFTOVER="nft table inet aos_unit left"
        return 1
    fi
}

main_pid() {
    systemctl show -p MainPID --value "${1}.service" 2>/dev/null || echo 0
}

wait_substate() {
    local unit="$1" want="$2" tries="${3:-50}" i
    for ((i = 0; i < tries; i++)); do
        [[ $(systemctl show -p SubState --value "${unit}.service" 2>/dev/null) == "$want" ]] && return 0
        sleep 0.1
    done
    return 1
}

wait_unloaded() {
    local unit="$1" timeout_s="${2:-30}" i
    for ((i = 0; i < timeout_s * 5; i++)); do
        [[ $(load_state "$unit") == "not-found" ]] && return 0
        sleep 0.2
    done
    return 1
}

# Stop, check host teardown, start, check first-attempt start.
check_stop_start() {
    local id="$1" title="$2" since
    svc_stop
    if ! assert_no_leftovers; then
        row FAIL "$id" "$title" "after stop: ${LEFTOVER}"
        cluster_up || true
        return
    fi
    since="$(ts)"
    svc_start
    if assert_clean_start "$since"; then
        row PASS "$id" "$title"
    else
        row FAIL "$id" "$title" "start after stop was not first-attempt clean"
    fi
}

wait_guest_ping() {
    local timeout_s="${1:-180}"
    local i
    [[ $SKIP_GUEST_WAIT -eq 1 ]] && return 1
    for ((i = 0; i < timeout_s; i++)); do
        if ping -c1 -W1 10.0.0.100 >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

GUESTS_BOOTED=0

case_g1_guests_boot() {
    local since
    since="$(ts)"
    if ! cluster_up; then
        row FAIL G1 "Real AosCore guests become reachable" "aos-unit failed to start"
        return
    fi
    if wait_guest_ping 180; then
        GUESTS_BOOTED=1
        row PASS G1 "Real AosCore guests become reachable" "ping 10.0.0.100 ok"
    else
        GUESTS_BOOTED=0
        row FAIL G1 "Real AosCore guests become reachable" "no ping within 180s (ACPI path is weaker)"
    fi
    assert_clean_start "$since" || true
}

case_p1_stop_then_start() {
    local since
    cluster_up || {
        row SKIP P1 "stop then start" "cluster not up"
        return
    }
    since="$(ts)"
    systemctl stop aos-unit || true
    systemctl start aos-unit || true
    if assert_clean_start "$since"; then
        row PASS P1 "stop then start — first attempt, no leftover units"
    else
        row FAIL P1 "stop then start — first attempt, no leftover units"
    fi
}

case_p2_restart() {
    local since
    cluster_up || {
        row SKIP P2 "systemctl restart" "cluster not up"
        return
    }
    since="$(ts)"
    systemctl restart aos-unit || true
    if assert_clean_start "$since"; then
        row PASS P2 "systemctl restart — first attempt, no leftover units"
    else
        row FAIL P2 "systemctl restart — first attempt, no leftover units"
    fi
}

case_p3_double_restart() {
    local since
    cluster_up || {
        row SKIP P3 "two restarts back to back" "cluster not up"
        return
    }
    systemctl restart aos-unit || true
    settle_cluster || true
    since="$(ts)"
    systemctl restart aos-unit || true
    if assert_clean_start "$since"; then
        row PASS P3 "two restarts back to back"
    else
        row FAIL P3 "two restarts back to back"
    fi
}

case_d1_runner_sigterm() {
    local since pid
    cluster_up || {
        row SKIP D1 "runner SIGTERM then systemd restart" "cluster not up"
        return
    }
    pid="$(systemctl show -p MainPID --value aos-unit.service)"
    if [[ -z $pid || $pid == 0 ]]; then
        row SKIP D1 "runner SIGTERM (die/trap) then start — no leftover units" "no MainPID"
        return
    fi
    since="$(ts)"
    kill -TERM "$pid" || true
    # Restart=on-failure does not apply to clean exit 0; start again if it stayed dead.
    sleep 2
    if ! systemctl is-active --quiet aos-unit.service; then
        systemctl start aos-unit || true
    fi
    if assert_clean_start "$since"; then
        row PASS D1 "runner SIGTERM (die/trap) then start — no leftover units"
    else
        row FAIL D1 "runner SIGTERM (die/trap) then start — no leftover units"
    fi
}

case_d2_runner_sigkill() {
    local since pid
    cluster_up || {
        row SKIP D2 "runner SIGKILL then on-failure restart" "cluster not up"
        return
    }
    pid="$(systemctl show -p MainPID --value aos-unit.service)"
    if [[ -z $pid || $pid == 0 ]]; then
        row SKIP D2 "runner SIGKILL — systemd on-failure restart is first-try clean" "no MainPID"
        return
    fi
    since="$(ts)"
    kill -KILL "$pid" || true
    # RestartSec=10s after ExecStopPost; on-failure restart itself is expected.
    if assert_clean_start "$since" 1; then
        row PASS D2 "runner SIGKILL — systemd on-failure restart is first-try clean"
    else
        row FAIL D2 "runner SIGKILL — systemd on-failure restart is first-try clean"
    fi
}

case_d3_kill_one_node_then_restart() {
    local since qpid
    cluster_up || {
        row SKIP D3 "kill one QEMU then restart aos-unit" "cluster not up"
        return
    }
    qpid="$(systemctl show -p MainPID --value "${MAIN_NODE_UNIT}.service")"
    if [[ -z $qpid || $qpid == 0 ]]; then
        row SKIP D3 "kill one QEMU (node die) overlapping service restart" "no QEMU pid"
        return
    fi
    since="$(ts)"
    kill -KILL "$qpid" || true
    sleep 1
    systemctl restart aos-unit || true
    if assert_clean_start "$since"; then
        row PASS D3 "kill one QEMU (node die) overlapping service restart"
    else
        row FAIL D3 "kill one QEMU (node die) overlapping service restart"
    fi
}

case_d4_kill_both_nodes_then_restart() {
    local since p1 p2
    cluster_up || {
        row SKIP D4 "kill both QEMU then restart aos-unit" "cluster not up"
        return
    }
    p1="$(systemctl show -p MainPID --value "${MAIN_NODE_UNIT}.service")"
    p2="$(systemctl show -p MainPID --value "${SECONDARY_NODE_UNIT}.service")"
    if [[ -z $p1 || $p1 == 0 || -z $p2 || $p2 == 0 ]]; then
        row SKIP D4 "kill both QEMU then restart aos-unit" "missing QEMU pid"
        return
    fi
    since="$(ts)"
    kill -KILL "$p1" "$p2" || true
    sleep 1
    systemctl restart aos-unit || true
    if assert_clean_start "$since"; then
        row PASS D4 "kill both QEMU then restart aos-unit"
    else
        row FAIL D4 "kill both QEMU then restart aos-unit"
    fi
}

case_l1_leftover_node_at_start() {
    local since
    systemctl stop aos-unit || true
    systemd-run --unit="$MAIN_NODE_UNIT" --collect --quiet -- /bin/sleep 120 || true
    since="$(ts)"
    systemctl start aos-unit || true
    if assert_clean_start "$since"; then
        row PASS L1 "leftover node unit at start — runner wait clears it"
    else
        row FAIL L1 "leftover node unit at start — runner wait clears it"
    fi
}

case_l2_leftover_dnsmasq_at_start() {
    local since
    systemctl stop aos-unit || true
    systemd-run --unit="$DNSMASQ_UNIT" --collect --quiet -- /bin/sleep 120 || true
    since="$(ts)"
    systemctl start aos-unit || true
    if assert_clean_start "$since"; then
        row PASS L2 "leftover dnsmasq at start — startup wait clears it"
    else
        row FAIL L2 "leftover dnsmasq at start — startup wait clears it"
        cluster_up || true
    fi
}

case_o1_stop_order() {
    cluster_up || {
        row SKIP O1 "record stop order (runner / nodes / dnsmasq / cleanup)" "cluster not up"
        return
    }
    local since
    since="$(ts)"
    systemctl stop aos-unit || true
    local journal
    journal="$(journalctl -u aos-unit -u "${MAIN_NODE_UNIT}" -u "${SECONDARY_NODE_UNIT}" -u "${DNSMASQ_UNIT}" --since "$since" --no-pager -o short-precise)"
    printf '%s\n' "$journal" >"/tmp/aos-unit-matrix-stop-order.log"
    if grep -q 'Cleanup complete' <<<"$journal"; then
        row PASS O1 "record stop order (runner / nodes / dnsmasq / cleanup)" \
            "see /tmp/aos-unit-matrix-stop-order.log"
    else
        row FAIL O1 "record stop order (runner / nodes / dnsmasq / cleanup)" "no Cleanup complete"
    fi
}

# --- cleanup parsing ---

case_c1_failed_leftover_node_cleaned_on_stop() {
    local -r ghost="aos-unit-node-matrixghost"
    cluster_up || {
        row SKIP C1 "failed leftover node unit is unloaded by cleanup" "cluster not up"
        return
    }
    # No --collect: a failed unit stays loaded and list-units prefixes it with a glyph.
    systemd-run --unit="$ghost" --quiet -- /bin/false || true
    sleep 0.5
    local before
    before="$(systemctl show -p ActiveState --value "${ghost}.service" 2>/dev/null || true)"
    svc_stop
    if [[ $(load_state "$ghost") == "not-found" ]]; then
        row PASS C1 "failed leftover node unit is unloaded by cleanup" "was ${before}"
    else
        row FAIL C1 "failed leftover node unit is unloaded by cleanup" "was ${before}, still loaded"
        systemctl reset-failed "${ghost}.service" >/dev/null 2>&1 || true
    fi
}

# --- VM cannot start / VM dies before stop ---

MAIN_IMAGE=""
MAIN_IMAGE_BACKUP=""

restore_main_image() {
    if [[ -n $MAIN_IMAGE_BACKUP && -f $MAIN_IMAGE_BACKUP ]]; then
        mv -f "$MAIN_IMAGE_BACKUP" "$MAIN_IMAGE"
        MAIN_IMAGE_BACKUP=""
    fi
}

vm_failures_count() {
    wc -l 2>/dev/null <"/var/log/aos-unit/vm-failures.log" || echo 0
}

case_v1_vm_unable_to_start() {
    local -r title="VM unable to start (corrupt image) — stop is clean, next start first-try"
    MAIN_IMAGE="$(find "$STATE_DIR" -maxdepth 1 -name 'aos-vm-main-*.qcow2' | head -n1)"
    if [[ -z $MAIN_IMAGE ]]; then
        row SKIP V1 "$title" "no aos-vm-main-*.qcow2 in ${STATE_DIR}"
        return
    fi
    svc_stop
    MAIN_IMAGE_BACKUP="${MAIN_IMAGE}.matrix-bak"
    mv "$MAIN_IMAGE" "$MAIN_IMAGE_BACKUP"
    head -c 1048576 /dev/zero >"$MAIN_IMAGE"
    chown aos-unit:aos-unit "$MAIN_IMAGE"

    local failures_before i detail
    failures_before="$(vm_failures_count)"
    svc_start
    for ((i = 0; i < 60; i++)); do
        (($(vm_failures_count) > failures_before)) && break
        sleep 1
    done
    detail="aos-unit=$(systemctl is-active aos-unit.service 2>/dev/null || true)"
    detail+=" OnFailure=$(($(vm_failures_count) > failures_before ? 1 : 0))"

    svc_stop
    restore_main_image
    if ! assert_no_leftovers; then
        row FAIL V1 "$title" "${detail}; after stop: ${LEFTOVER}"
        cluster_up || true
        return
    fi
    local since
    since="$(ts)"
    svc_start
    if assert_clean_start "$since"; then
        row PASS V1 "$title" "$detail"
    else
        row FAIL V1 "$title" "${detail}; restart with good image not clean"
    fi
}

case_v2_guest_exits_before_stop() {
    local -r title="VM exits by itself (QMP quit) before stop"
    cluster_up || {
        row SKIP V2 "$title" "cluster not up"
        return
    }
    printf '{"execute":"qmp_capabilities"}\n{"execute":"quit"}\n' |
        socat - "UNIX-CONNECT:/run/aos-unit/main.qmp" >/dev/null 2>&1 || true
    if ! wait_unloaded "$MAIN_NODE_UNIT" 30; then
        row FAIL V2 "$title" "node unit did not unload after QEMU quit"
        return
    fi
    check_stop_start V2 "$title"
}

case_v3_crash_during_auto_restart() {
    local -r title="QEMU crash, aos-unit stop during node auto-restart"
    cluster_up || {
        row SKIP V3 "$title" "cluster not up"
        return
    }
    kill -KILL "$(main_pid "$MAIN_NODE_UNIT")" || true
    if ! wait_substate "$MAIN_NODE_UNIT" auto-restart 50; then
        row FAIL V3 "$title" "node never reached auto-restart"
        return
    fi
    check_stop_start V3 "$title"
}

case_v4_node_start_limit_hit() {
    local -r title="node hits start limit (OnFailure) then aos-unit restart"
    cluster_up || {
        row SKIP V4 "$title" "cluster not up"
        return
    }
    local attempt pid new_pid i failures_before
    failures_before="$(vm_failures_count)"
    for attempt in 1 2 3; do
        pid="$(main_pid "$MAIN_NODE_UNIT")"
        [[ $pid != 0 ]] || break
        kill -KILL "$pid" || true
        ((attempt < 3)) || break
        for ((i = 0; i < 100; i++)); do
            new_pid="$(main_pid "$MAIN_NODE_UNIT")"
            [[ $new_pid != 0 && $new_pid != "$pid" ]] && break
            sleep 0.2
        done
    done
    for ((i = 0; i < 30; i++)); do
        (($(vm_failures_count) > failures_before)) && break
        sleep 1
    done
    local since
    since="$(ts)"
    svc_restart
    if assert_clean_start "$since"; then
        row PASS V4 "$title" "OnFailure=$(($(vm_failures_count) > failures_before ? 1 : 0))"
    else
        row FAIL V4 "$title"
    fi
}

case_v5_qemu_hangs() {
    local -r title="QEMU hung (SIGSTOP) — restart waits for node SIGKILL"
    cluster_up || {
        row SKIP V5 "$title" "cluster not up"
        return
    }
    kill -STOP "$(main_pid "$MAIN_NODE_UNIT")" || true
    local since t0 elapsed
    since="$(ts)"
    t0=$SECONDS
    svc_restart
    elapsed=$((SECONDS - t0))
    if assert_clean_start "$since" && ((elapsed <= 150)); then
        row PASS V5 "$title" "restart took ${elapsed}s"
    else
        row FAIL V5 "$title" "restart took ${elapsed}s"
    fi
}

# --- same scenarios for dnsmasq ---

case_n1_dnsmasq_killed() {
    local -r title="dnsmasq SIGKILL, restart inside its RestartSec window"
    cluster_up || {
        row SKIP N1 "$title" "cluster not up"
        return
    }
    kill -KILL "$(main_pid "$DNSMASQ_UNIT")" || true
    sleep 0.3
    local since
    since="$(ts)"
    svc_restart
    if assert_clean_start "$since"; then
        row PASS N1 "$title"
    else
        row FAIL N1 "$title"
    fi
}

case_n2_dnsmasq_hung() {
    local -r title="dnsmasq SIGSTOP, restart"
    cluster_up || {
        row SKIP N2 "$title" "cluster not up"
        return
    }
    kill -STOP "$(main_pid "$DNSMASQ_UNIT")" || true
    local since
    since="$(ts)"
    svc_restart
    if assert_clean_start "$since"; then
        row PASS N2 "$title"
    else
        row FAIL N2 "$title"
    fi
}

case_n3_dnsmasq_unable_to_start() {
    local -r title="dnsmasq unable to start (DNS port taken) — stop clean, next start first-try"
    local -r port="${DNS_ALT_PORT:-5300}"
    command -v python3 >/dev/null 2>&1 || {
        row SKIP N3 "$title" "python3 missing"
        return
    }
    svc_stop
    python3 - "$port" <<'EOF' &
import socket, sys, time
port = int(sys.argv[1])
socks = []
for kind in (socket.SOCK_DGRAM, socket.SOCK_STREAM):
    s = socket.socket(socket.AF_INET, kind)
    s.bind(("0.0.0.0", port))
    if kind == socket.SOCK_STREAM:
        s.listen()
    socks.append(s)
time.sleep(600)
EOF
    local blocker=$! i detail
    sleep 1
    svc_start
    for ((i = 0; i < 15; i++)); do
        systemctl is-active --quiet "${DNSMASQ_UNIT}.service" || break
        sleep 1
    done
    detail="aos-unit=$(systemctl is-active aos-unit.service 2>/dev/null || true)"
    detail+=" dnsmasq=$(systemctl is-active "${DNSMASQ_UNIT}.service" 2>/dev/null || true)"

    svc_stop
    kill "$blocker" 2>/dev/null || true
    wait "$blocker" 2>/dev/null || true
    if ! assert_no_leftovers; then
        row FAIL N3 "$title" "${detail}; after stop: ${LEFTOVER}"
        cluster_up || true
        return
    fi
    local since
    since="$(ts)"
    svc_start
    if assert_clean_start "$since"; then
        row PASS N3 "$title" "$detail"
    else
        row FAIL N3 "$title" "${detail}; start after freeing port not clean"
    fi
}

case_n4_leftover_failed_dnsmasq_at_start() {
    local -r title="leftover FAILED dnsmasq at start — startup wait clears it"
    svc_stop
    systemd-run --unit="$DNSMASQ_UNIT" --quiet -- /bin/false || true
    sleep 0.5
    local state since
    state="$(systemctl show -p ActiveState --value "${DNSMASQ_UNIT}.service" 2>/dev/null || true)"
    since="$(ts)"
    svc_start
    if assert_clean_start "$since"; then
        row PASS N4 "$title" "leftover was ${state}"
    else
        row FAIL N4 "$title" "leftover was ${state}"
        systemctl reset-failed "${DNSMASQ_UNIT}.service" >/dev/null 2>&1 || true
        cluster_up || true
    fi
}

print_matrix() {
    [[ ${MATRIX_PRINTED} -eq 1 ]] && return 0
    MATRIX_PRINTED=1
    {
        echo
        echo "Die / shutdown order matrix $(ts)"
        echo "Guests booted: ${GUESTS_BOOTED}"
        echo "----------------------------------------"
        local r
        for r in "${ROWS[@]}"; do
            echo "$r"
        done
        echo "----------------------------------------"
        echo "PASS=${PASS} FAIL=${FAIL} SKIP=${SKIP}"
    } | tee "$RESULTS_FILE"
    log "Results written to ${RESULTS_FILE}"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --helpers-only) HELPERS_ONLY=1 ;;
            --cluster-only) CLUSTER_ONLY=1 ;;
            --skip-guest-wait) SKIP_GUEST_WAIT=1 ;;
            --cases)
                CASES="${2:-}"
                [[ -n $CASES ]] || usage
                shift
                ;;
            --setup-images)
                SETUP_IMAGES="${2:-}"
                [[ -n $SETUP_IMAGES ]] || usage
                shift
                ;;
            -h | --help) usage ;;
            *) usage ;;
        esac
        shift
    done
}

run_case() {
    local id="$1" fn="$2"
    if [[ -n $CASES && " ${CASES//,/ } " != *" ${id} "* ]]; then
        return 0
    fi
    "$fn"
}

on_exit() {
    restore_main_image
    print_matrix
    [[ -z $SETUP_IMAGES ]] || restore_unit_config
}

main() {
    parse_args "$@"
    require_root
    require_cmds

    trap on_exit EXIT

    if [[ -n $SETUP_IMAGES ]]; then
        install_images_from_dir "$SETUP_IMAGES"
        apply_test_unit_config
    fi

    if [[ $CLUSTER_ONLY -eq 0 ]]; then
        run_case H1 case_h1_wait_then_recreate
        run_case H2 case_h2_stop_running_via_wait
        run_case H3 case_h3_failed_unit_reset
        run_case H4 case_h4_not_found_is_noop
        run_case H5 case_h5_wait_is_bounded
        run_case H6 case_h6_query_error_is_not_success
        run_case H7 case_h7_caller_trap_preserved
        run_case H8 case_h8_sigterm_during_wait
    fi

    if [[ $HELPERS_ONLY -eq 1 ]]; then
        print_matrix
        return 0
    fi

    run_case G1 case_g1_guests_boot
    run_case P1 case_p1_stop_then_start
    run_case P2 case_p2_restart
    run_case P3 case_p3_double_restart
    run_case D1 case_d1_runner_sigterm
    run_case D2 case_d2_runner_sigkill
    run_case D3 case_d3_kill_one_node_then_restart
    run_case D4 case_d4_kill_both_nodes_then_restart
    run_case L1 case_l1_leftover_node_at_start
    run_case L2 case_l2_leftover_dnsmasq_at_start
    run_case C1 case_c1_failed_leftover_node_cleaned_on_stop
    run_case V1 case_v1_vm_unable_to_start
    run_case V2 case_v2_guest_exits_before_stop
    run_case V3 case_v3_crash_during_auto_restart
    run_case V4 case_v4_node_start_limit_hit
    run_case V5 case_v5_qemu_hangs
    run_case N1 case_n1_dnsmasq_killed
    run_case N2 case_n2_dnsmasq_hung
    run_case N3 case_n3_dnsmasq_unable_to_start
    run_case N4 case_n4_leftover_failed_dnsmasq_at_start
    run_case O1 case_o1_stop_order

    print_matrix
    [[ $FAIL -eq 0 ]]
}

main "$@"
