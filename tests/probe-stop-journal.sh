#!/usr/bin/env bash
# Print the journal lines a manager stop produces for nodes, the sidecar and
# the bridge, to pick stable anchors for the teardown-order check.
set -u
AOS_DNSMASQ="${AOS_DNSMASQ:-aos-unit-dns.service}"
. "$(dirname "$(realpath "$0")")/lib-issue11.sh"

clean_slate
systemctl start aos-unit.service
wait_until 60 unit_is "$(node_unit "$(node_names | head -1)")" active
wait_guests_booted
since="$(now)"
systemctl stop aos-unit.service
journal_units "$since" | grep -E 'Stopping|Stopped|Deactivated|Failed with result|Removing bridge|dnsmasq|aos-unit-dns'
echo "--- show after stop"
for u in $(for n in $(node_names); do node_unit "$n"; done) "$AOS_DNSMASQ"; do
    echo "$u $(show "$u" InactiveEnterTimestampMonotonic) $(show "$u" ActiveExitTimestampMonotonic)"
done
