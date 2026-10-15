#!/usr/bin/env bash
# Probe: does a runner-shaped bash loop (coproc ip monitor + blocking read -u +
# trap 'exit 0' TERM) always exit 0 on systemctl stop? Stops at several delays
# and prints the main-process exit status each time.
set -u

payload=/tmp/probe-runner-payload.sh
cat >"$payload" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
coproc ipmon { exec /usr/sbin/ip monitor route; }
IPMON_PID="${ipmon_PID}"
gate=/tmp/probe-runner-gate
: >"$gate"
deny() { rm -f "$gate"; }
shutdown_runner() { deny; exit 0; }
cleanup() { echo "cleanup" >&2; kill "${IPMON_PID}" 2>/dev/null || true; wait "${IPMON_PID}" 2>/dev/null || true; }
trap 'deny; cleanup' EXIT
trap shutdown_runner INT TERM
while true; do
    if IFS= read -r -u "${ipmon[0]}" line; then
        :
    else
        if kill -0 "${IPMON_PID}" 2>/dev/null; then continue; fi
        echo "EOF path"
        exit 3
    fi
done
EOF
chmod +x "$payload"

for delay in ${DELAYS:-0.3 0.6 1 2 0.6 0.6 0.6 0.4 0.5 0.7 0.8 0.6 0.6 0.6 0.6 1 1 1 0.6 0.6}; do
    unit="probe-runner-$RANDOM"
    systemd-run --quiet --unit "$unit" -p KillMode=control-group "$payload"
    sleep "$delay"
    systemctl stop "$unit"
    printf 'delay=%-4s status=%s result=%s\n' "$delay" \
        "$(systemctl show -p ExecMainStatus --value "$unit")" \
        "$(systemctl show -p Result --value "$unit")"
    journalctl --no-pager -q -u "$unit" | grep -iE 'Terminated|EOF path' | sed 's/^/    /'
    systemctl reset-failed "$unit" 2>/dev/null
done
