#!/usr/bin/env bash
# F-2: for every manager stop since a time, print how long after "Route
# monitor started" it came, whether bash logged "Terminated ... read", and
# the main-process exit status.
# Usage: probe-143-history.sh "YYYY-MM-DD HH:MM:SS"
journalctl --no-pager -o short-unix --since "${1:?since}" -u aos-unit.service |
    awk '
        /runner: Route monitor started/ { mon = $1 }
        /systemd\[1\]: Stopping aos-unit.service/ { stop = $1; term = "no" }
        /Terminated +IFS= read/ { term = "yes" }
        /aos-unit.service: (Main process exited|Deactivated successfully)/ && stop {
            st = "0"
            if ($0 ~ /status=/) { st = $0; sub(/.*status=/, "", st); sub(/\/.*/, "", st) }
            printf "stop %.3f  after-monitor %6.1fs  terminated-msg %-3s  status %s\n", stop, (mon ? stop - mon : -1), term, st
            stop = 0
        }' | sort -k6 | uniq -c -f5 | head -50
echo "--- stops with status 143 or a Terminated line"
journalctl --no-pager -o short-unix --since "$1" -u aos-unit.service |
    awk '
        /runner: Route monitor started/ { mon = $1 }
        /systemd\[1\]: Stopping aos-unit.service/ { stop = $1; term = "no" }
        /Terminated +IFS= read/ { term = "yes" }
        /aos-unit.service: (Main process exited|Deactivated successfully)/ && stop {
            st = "0"
            if ($0 ~ /status=/) { st = $0; sub(/.*status=/, "", st); sub(/\/.*/, "", st) }
            if (st != "0" || term == "yes")
                printf "after-monitor %6.1fs  terminated-msg %-3s  status %s\n", (mon ? stop - mon : -1), term, st
            stop = 0
        }'
