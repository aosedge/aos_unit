#!/usr/bin/env bash
# Verify AosCore guest version and issue #9 first-start behavior.
set -euo pipefail

since="$(date '+%Y-%m-%d %H:%M:%S')"
echo "=== since ${since} ==="

systemctl reset-failed aos-unit.service >/dev/null 2>&1 || true
systemctl stop aos-unit >/dev/null 2>&1 || true
sleep 2

nrestarts_before="$(systemctl show -p NRestarts --value aos-unit.service)"
systemctl start aos-unit
sleep 3

echo "=== aos-unit after start ==="
systemctl show -p ActiveState -p NRestarts -p Result -- aos-unit.service
systemctl is-active aos-unit-dnsmasq.service || true

echo "=== ping main guest ==="
ping_ok=0
for i in $(seq 1 240); do
    if ping -c1 -W1 10.0.0.100 >/dev/null 2>&1; then
        echo "PING_OK after ${i}s"
        ping_ok=1
        break
    fi
    sleep 1
done
[[ $ping_ok -eq 1 ]] || echo "PING_FAIL after 240s"

echo "=== guest /etc/aos/version ==="
guest_ver=""
for i in $(seq 1 60); do
    if guest_ver="$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes -o ConnectTimeout=3 -o LogLevel=ERROR \
        root@10.0.0.100 cat /etc/aos/version 2>&1)"; then
        echo "$guest_ver"
        break
    fi
    sleep 3
done
[[ -n $guest_ver ]] || echo "SSH_FAIL: ${guest_ver:-no response}"

echo "=== journal (issue #9 strings) ==="
journal="$(journalctl -u aos-unit --since "$since" --no-pager -o cat)"
if grep -Eq 'already exists|already running|Failed to start AosEdge|Scheduled restart job' <<<"$journal"; then
    echo "ISSUE9_SYMPTOM_FOUND"
    grep -E 'already exists|already running|Failed to start AosEdge|Scheduled restart job' <<<"$journal" || true
else
    echo "ISSUE9_SYMPTOM_NONE"
fi
grep -E 'Startup complete|Waiting for transient unit to unload' <<<"$journal" || true

nrestarts_after="$(systemctl show -p NRestarts --value aos-unit.service)"
echo "NRestarts before=${nrestarts_before} after=${nrestarts_after}"
