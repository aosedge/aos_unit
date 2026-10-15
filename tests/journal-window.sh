#!/usr/bin/env bash
# Print aos-unit journal lines between two monotonic timestamps (seconds).
# Usage: journal-window.sh FROM TO
from="${1:?from}" to="${2:?to}"
journalctl --no-pager -o short-monotonic \
    -u aos-unit.service -u 'aos-unit-node@*' -u 'aos-unit-node-*' \
    -u 'aos-unit-vm-failed@*' -u aos-unit-dnsmasq.service |
    awk -v f="$from" -v t="$to" '{ ts = substr($1, 2) + 0 } ts >= f && ts <= t'
