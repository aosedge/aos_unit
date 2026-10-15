#!/usr/bin/env bash
# T3.4: VM restart-policy matrix (PR #14 review). Runs every failure
# shape against the INSTALLED package, once per Restart= policy. The policy is
# switched with a runtime drop-in, so one build covers both.
#
# Usage: phase3-restart-matrix.sh [on-failure] [on-abort]    (default: both)
# Env:   FAULT_NODE (default: second node in unit_config.yaml)

set -u

. "$(dirname "$(realpath "$0")")/lib-issue11.sh"
SUMMARY=/tmp/aos-phase3-matrix-summary.txt

readonly DROPIN_DIR=/run/systemd/system/aos-unit-node@.service.d
readonly DROPIN="${DROPIN_DIR}/zz-matrix-restart.conf"
: "${FAULT_NODE:=$(node_names | sed -n 2p)}"
readonly UNIT="aos-unit-node@${FAULT_NODE}.service"

declare -a ROWS=()

set_policy() {
    mkdir -p "$DROPIN_DIR"
    printf '[Service]\nRestart=%s\n' "$1" >"$DROPIN"
    systemctl daemon-reload
    check T3.4 "policy active: $1" "$1" "$(show "$UNIT" Restart)"
}

clear_policy() {
    rm -f "$DROPIN"
    rmdir "$DROPIN_DIR" 2>/dev/null
    systemctl daemon-reload
}

qmp() {
    printf '{"execute":"qmp_capabilities"}\n{"execute":"%s"}\n' "$1" |
        socat -t2 - "UNIX-CONNECT:${AOS_RUN}/${FAULT_NODE}.qmp" >/dev/null 2>&1
}

fresh_cluster() {
    systemctl stop aos-unit.service
    local n
    for n in $(node_names); do systemctl reset-failed "$(node_unit "$n")" 2>/dev/null; done
    systemctl start aos-unit.service
    wait_until 60 unit_is "$UNIT" active
    wait_guests_booted
}

onfailure_count() { journal_units "$1" | grep -c "VM unit FAILED.*${UNIT}"; }

# Wait until the unit stops changing: active with a PID that differs from the
# faulted one, or inactive/failed, and unchanged for 20s (RestartSec=5s).
settle() {
    local deadline=$((SECONDS + ${1:-120})) last="" cur stable=0
    while ((SECONDS < deadline)); do
        cur="$(show "$UNIT" ActiveState)/$(show "$UNIT" SubState)/$(show "$UNIT" MainPID)"
        if [[ $cur == "$last" ]]; then
            stable=$((stable + 1))
            ((stable >= 20)) && return 0
        else
            stable=0
            last="$cur"
        fi
        sleep 1
    done
}

observe() {
    local policy="$1" case_id="$2" desc="$3" since="$4" nr0="$5" pid0="$6"
    local nr1 state result onf pid1 restarted
    nr1="$(show "$UNIT" NRestarts)"
    state="$(show "$UNIT" ActiveState)"
    result="$(show "$UNIT" Result)"
    pid1="$(show "$UNIT" MainPID)"
    onf="$(onfailure_count "$since")"
    restarted=no
    if ((nr1 > nr0)); then restarted="yes(${nr1}-${nr0})"; fi
    ROWS+=("${policy}|${case_id}|${desc}|${restarted}|${onf}|${state}|${result}|${pid0}->${pid1}")
    info T3.4 "${policy} ${case_id} ${desc}" "restart=${restarted} onfailure=${onf} final=${state}/${result}"
}

case_m1() { # normal guest poweroff
    local p="$1" since nr0 pid0
    fresh_cluster
    since="$(now)"
    nr0="$(show "$UNIT" NRestarts)"
    pid0="$(show "$UNIT" MainPID)"
    qmp system_powerdown
    wait_until 90 bash -c "[[ \$(systemctl show -p MainPID --value $UNIT) != $pid0 ]]"
    settle
    observe "$p" M1 "guest poweroff (QEMU exit 0)" "$since" "$nr0" "$pid0"
}

M2_IMG=""
restore_image() {
    if [[ -n $M2_IMG && -f "${M2_IMG}.matrix" ]]; then
        mv -f "${M2_IMG}.matrix" "$M2_IMG"
    fi
    M2_IMG=""
}

case_m2() { # QEMU exits 1: image replaced by garbage, then instance restarted
    local p="$1" since nr0 pid0
    fresh_cluster
    M2_IMG="$(awk -F'"' '/^NODE_IMAGE=/ {print $2}' "${AOS_RUN}/nodes/${FAULT_NODE}.env")"
    since="$(now)"
    nr0="$(show "$UNIT" NRestarts)"
    pid0="$(show "$UNIT" MainPID)"
    mv "$M2_IMG" "${M2_IMG}.matrix"
    head -c 1M /dev/zero >"$M2_IMG"
    chown aos-unit:aos-unit "$M2_IMG"
    systemctl kill -s KILL --kill-whom=main "$UNIT"
    settle
    observe "$p" M2 "QEMU exit(1) after a crash-restart" "$since" "$nr0" "$pid0"
    restore_image
}

case_signal() { # M3 SIGSEGV, M5 SIGKILL
    local p="$1" id="$2" sig="$3" since nr0 pid0
    fresh_cluster
    since="$(now)"
    nr0="$(show "$UNIT" NRestarts)"
    pid0="$(show "$UNIT" MainPID)"
    kill -"$sig" "$pid0"
    settle
    observe "$p" "$id" "QEMU killed by SIG${sig}" "$since" "$nr0" "$pid0"
}

case_m4() { # OOM kill
    local p="$1" since nr0 pid0
    fresh_cluster
    since="$(now)"
    nr0="$(show "$UNIT" NRestarts)"
    pid0="$(show "$UNIT" MainPID)"
    systemctl set-property --runtime "$UNIT" MemoryMax=32M
    settle 150
    observe "$p" M4 "OOM kill (MemoryMax=32M)" "$since" "$nr0" "$pid0"
}

case_m6() { # ExecStartPre failure: tap name taken by a non-tap interface
    local p="$1" since nr0 pid0 tap
    fresh_cluster
    tap="$(awk -F'"' '/^NODE_TAP=/ {print $2}' "${AOS_RUN}/nodes/${FAULT_NODE}.env")"
    systemctl stop "$UNIT"
    ip link add "$tap" type dummy
    since="$(now)"
    nr0="$(show "$UNIT" NRestarts)"
    pid0=0
    systemctl start "$UNIT" 2>/dev/null
    settle
    observe "$p" M6 "ExecStartPre failure (add-vm)" "$since" "$nr0" "$pid0"
    ip link del "$tap"
}

case_m7() { # ACPI shutdown timeout during manager stop
    local p="$1" since nr0 pid0
    fresh_cluster
    nr0="$(show "$UNIT" NRestarts)"
    pid0="$(show "$UNIT" MainPID)"
    kill -STOP "$pid0"
    since="$(now)"
    systemctl stop aos-unit.service
    observe "$p" M7 "ACPI timeout on manager stop" "$since" "$nr0" "$pid0"
    check T3.4 "${p} M7 no instance started during teardown" 0 \
        "$(journal_units "$since" | grep -c 'Starting aos-unit-node@')"
    check T3.4 "${p} M7 network torn down" "" "$(bridges)"
    check T3.4 "${p} M7 failure tagged as during manager stop" 1 \
        "$(journal_units "$since" | grep -c "VM unit FAILED (during manager stop): ${UNIT}")"
}

case_m8() { # manager stop
    local p="$1" since nr0 pid0
    fresh_cluster
    since="$(now)"
    nr0="$(show "$UNIT" NRestarts)"
    pid0="$(show "$UNIT" MainPID)"
    systemctl stop aos-unit.service
    observe "$p" M8 "manager stop" "$since" "$nr0" "$pid0"
}

case_m9() { # manager restart
    local p="$1" since nr0 pid0
    fresh_cluster
    since="$(now)"
    nr0="$(show "$UNIT" NRestarts)"
    pid0="$(show "$UNIT" MainPID)"
    systemctl restart aos-unit.service
    wait_until 60 unit_is "$UNIT" active
    settle 60
    observe "$p" M9 "manager restart" "$since" "$nr0" "$pid0"
}

run_policy() {
    local p="$1"
    say "Policy Restart=${p} (fault node: ${FAULT_NODE})"
    set_policy "$p"
    case_m1 "$p"
    case_m2 "$p"
    case_signal "$p" M3 SEGV
    case_m4 "$p"
    case_signal "$p" M5 KILL
    case_m6 "$p"
    case_m7 "$p"
    case_m8 "$p"
    case_m9 "$p"
    clear_policy
}

main() {
    local -a policies=("$@")
    ((${#policies[@]})) || policies=(on-failure on-abort)
    trap 'restore_image; clear_policy' EXIT
    local p
    for p in "${policies[@]}"; do run_policy "$p"; done
    systemctl stop aos-unit.service
    for p in $(node_names); do systemctl reset-failed "$(node_unit "$p")" 2>/dev/null; done

    say "Matrix"
    printf '%-10s %-3s %-38s %-10s %-9s %-10s %-10s %s\n' policy id case restarted onfailure state result pids
    local row
    for row in "${ROWS[@]}"; do
        IFS='|' read -r a b c d e f g h <<<"$row"
        printf '%-10s %-3s %-38s %-10s %-9s %-10s %-10s %s\n' "$a" "$b" "$c" "$d" "$e" "$f" "$g" "$h"
    done
    summary "Phase 3 restart-policy matrix"
}

main "$@"
