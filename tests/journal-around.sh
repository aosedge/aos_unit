#!/usr/bin/env bash
# Print the lifecycle journal (journal-focus.sh filter, minus dnsmasq's own
# crash-loop lines) from N seconds before to M seconds after each line that
# matches a regex, since a wall-clock time.
# Usage: journal-around.sh "YYYY-MM-DD HH:MM:SS" REGEX [before_s] [after_s]
since="${1:?since}" re="${2:?regex}" before="${3:-8}" after="${4:-2}"
units=(-u aos-unit.service -u 'aos-unit-node@*' -u aos-unit-dns.service)
journalctl --no-pager -o short-unix --since "$since" "${units[@]}" | grep -E "$re" | while read -r ts _; do
    from="$(awk -v t="$ts" -v b="$before" 'BEGIN { printf "%.6f", t - b }')"
    to="$(awk -v t="$ts" -v a="$after" 'BEGIN { printf "%.6f", t + a }')"
    echo "=== around ${ts}"
    journalctl --no-pager -o short-precise --since "@${from}" --until "@${to}" "${units[@]}" |
        grep -vE 'dnsmasq(-dhcp)?\[|aos-unit-dns.service: (Main process|Failed with|Scheduled)|Started aos-unit-dns|vm-failed-handler|runner:  ' |
        cut -c8-200
done
