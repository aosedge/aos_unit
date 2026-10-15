#!/usr/bin/env bash
# Quick manual check: leftover transient node unit must not block aos-unit start.
set -euo pipefail

UNIT=aos-unit-node-main.service

echo "=== stop aos-unit ==="
systemctl stop aos-unit.service 2>/dev/null || true
systemctl reset-failed "$UNIT" 2>/dev/null || true

echo "=== plant leftover transient node (sleep 120) ==="
systemd-run --unit=aos-unit-node-main --collect -- /bin/sleep 120
systemctl show -p LoadState -p ActiveState -p Transient "$UNIT"

echo "=== start aos-unit (must succeed on first try) ==="
nrestarts_before="$(systemctl show -p NRestarts --value aos-unit.service)"
systemctl start aos-unit.service
nrestarts_after="$(systemctl show -p NRestarts --value aos-unit.service)"

echo "NRestarts before=${nrestarts_before} after=${nrestarts_after}"
systemctl is-active aos-unit.service
systemctl is-active "$UNIT" || true

echo "=== relevant journal ==="
journalctl -u aos-unit --since "2 min ago" --no-pager -o cat |
    grep -E 'Waiting for transient unit|already exists|Startup complete|Leftover unit|Launching via systemd' || true

echo OK
