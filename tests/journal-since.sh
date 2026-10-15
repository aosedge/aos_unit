#!/usr/bin/env bash
# Print aos-unit journal lines between two wall-clock times, optionally
# filtered by an extended regex.
# Usage: journal-since.sh "YYYY-MM-DD HH:MM:SS" "YYYY-MM-DD HH:MM:SS" [regex]
since="${1:?since}" until="${2:?until}" re="${3:-.}"
journalctl --no-pager -o short-precise --since "$since" --until "$until" \
    -u aos-unit.service -u 'aos-unit-node@*' -u 'aos-unit-node-*' \
    -u 'aos-unit-vm-failed@*' -u aos-unit-dnsmasq.service -u aos-unit-dns.service |
    grep -E "$re"
