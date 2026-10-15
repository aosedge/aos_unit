#!/usr/bin/env bash
# F-2: stop the manager N times, D seconds after start (guests not booted),
# and count how often runner exits 143.
# Usage: probe-early-stop.sh [runs] [delay_s]
AOS_DNSMASQ="${AOS_DNSMASQ:-aos-unit-dns.service}"
. "$(dirname "$(realpath "$0")")/lib-issue11.sh"
runs="${1:-8}" delay="${2:-5}"
for i in $(seq "$runs"); do
    clean_slate >/dev/null 2>&1
    systemctl start aos-unit.service
    sleep "$delay"
    systemctl stop aos-unit.service
    echo "run ${i}: Result=$(show aos-unit.service Result) ExecMainStatus=$(show aos-unit.service ExecMainStatus)"
done | tee /dev/stderr | sed 's/^run [0-9]*: //' | sort | uniq -c
systemctl reset-failed aos-unit.service 2>/dev/null || true
