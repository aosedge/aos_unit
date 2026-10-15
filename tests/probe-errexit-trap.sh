#!/usr/bin/env bash
# F-2 probe: runner's route-monitor shape (set -Eeuo pipefail, TERM trap that
# calls exit 0, EXIT trap that kills and waits for the ip-monitor coproc,
# blocking read on the coproc), signalled like KillMode=control-group.
# Prints the exit code distribution per variant.
# Usage: probe-errexit-trap.sh [runs]
runs="${1:-20}"
script="$(mktemp)"
cat >"$script" <<'EOF'
set -Eeuo pipefail
IPMON_PID=""
log() { printf 'probe: %s\n' "$*" >&2; }
die() { log "ERROR: $2"; exit "$1"; }
shutdown_runner() { exit 0; }
cleanup_route_monitor() {
    if [[ -n ${IPMON_PID} ]]; then
        log "Shutting down route monitor..."
        kill "${IPMON_PID}" 2>/dev/null || true
        wait "${IPMON_PID}" 2>/dev/null || true
    fi
}
trap shutdown_runner SIGTERM SIGINT
trap 'true' EXIT
coproc ipmon { exec sleep infinity; }
IPMON_PID="${ipmon_PID}"
case "$1" in
    nowait) trap 'true' EXIT ;;
    *) trap 'cleanup_route_monitor' EXIT ;;
esac
trap shutdown_runner INT TERM
while true; do
    if IFS= read -r -u "${ipmon[0]}" line; then
        :
    else
        if kill -0 "${IPMON_PID}" 2>/dev/null; then
            continue
        else
            die 1 "ip monitor stream ended unexpectedly."
        fi
    fi
done
EOF
bash --version | head -1
for mode in runner nowait; do
    for _ in $(seq "$runs"); do
        setsid bash "$script" "$mode" 2>/dev/null &
        pid=$!
        sleep 0.$((RANDOM % 5 + 3))
        kill -TERM -- "-$pid" 2>/dev/null
        wait "$pid"
        echo "${mode} rc=$?"
    done | sort | uniq -c
done
rm -f "$script"
