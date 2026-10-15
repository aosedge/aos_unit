#!/usr/bin/env bash
# One-shot proof: leftover aos-unit-dnsmasq at ExecStartPre must start first try.
set -euo pipefail

sudo systemctl reset-failed aos-unit.service >/dev/null 2>&1 || true
sudo systemctl stop aos-unit
sudo systemctl stop aos-unit-dnsmasq.service >/dev/null 2>&1 || true
sudo systemctl reset-failed aos-unit-dnsmasq.service >/dev/null 2>&1 || true

sudo systemd-run --unit=aos-unit-dnsmasq --collect -- /bin/sleep 120
leftover_active="$(systemctl show -p ActiveState --value aos-unit-dnsmasq.service)"
leftover_load="$(systemctl show -p LoadState --value aos-unit-dnsmasq.service)"
printf 'PLANTED leftover ActiveState=%s LoadState=%s\n' "$leftover_active" "$leftover_load"
[[ $leftover_active == active ]]

nrestarts_before="$(systemctl show -p NRestarts --value aos-unit.service)"
since="$(date '+%Y-%m-%d %H:%M:%S')"
sleep 1

set +e
sudo systemctl start aos-unit
start_exit=$?
set -e

nrestarts_after="$(systemctl show -p NRestarts --value aos-unit.service)"
printf 'START_EXIT=%s NRestarts before=%s after=%s\n' "$start_exit" "$nrestarts_before" "$nrestarts_after"
printf 'aos-unit=%s dnsmasq=%s\n' "$(systemctl is-active aos-unit)" "$(systemctl is-active aos-unit-dnsmasq)"
echo "==== journal since ${since} ===="
sudo journalctl -u aos-unit --since "$since" --no-pager

[[ $start_exit -eq 0 ]]
[[ $nrestarts_after == "$nrestarts_before" ]]
systemctl is-active --quiet aos-unit
systemctl is-active --quiet aos-unit-dnsmasq.service
journal="$(sudo journalctl -u aos-unit --since "$since" --no-pager -o cat)"
grep -q 'Waiting for transient unit to unload: aos-unit-dnsmasq' <<<"$journal"
grep -q 'Starting dnsmasq as transient unit' <<<"$journal"
grep -q 'Startup complete' <<<"$journal"
! grep -Eq 'already running|already exists|Failed to start AosEdge|Scheduled restart job' <<<"$journal"
echo PROOF_OK
