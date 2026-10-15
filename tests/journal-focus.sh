#!/usr/bin/env bash
# Lifecycle-only view of the aos-unit journal between two wall-clock times:
# systemd job/result lines and aos-unit's own log lines, without the
# vm-failed-handler status dumps and per-VM registration noise.
# Usage: journal-focus.sh "YYYY-MM-DD HH:MM:SS" "YYYY-MM-DD HH:MM:SS"
journalctl --no-pager -o short-precise --since "${1:?since}" --until "${2:?until}" \
    -u aos-unit.service -u 'aos-unit-node@*' -u 'aos-unit-vm-failed@*' \
    -u aos-unit-dnsmasq.service -u aos-unit-dns.service |
    grep -E 'systemd\[1\]: (aos-unit|Start|Stop)|aos-unit\[|FAILED to start|exiting|VM unit FAILED' |
    grep -vE 'ERROR: {2}|add-vm|del-vm|egister|reservation|vm-failed@' |
    cut -c8-230
