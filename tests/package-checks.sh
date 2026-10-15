#!/usr/bin/env bash
# T3.7 / T2.4: maintainer scripts must not start/stop/restart/enable the
# aos-unit-node@ template or the dnsmasq sidecar; only aos-unit.service is
# managed by debhelper. Optionally checks remove-while-running.
#
# Usage: package-checks.sh <deb> <test-id> [--remove]

set -u

. "$(dirname "$(realpath "$0")")/lib-issue11.sh"
readonly DNS_UNIT="$AOS_DNSMASQ"

readonly DEB="$1" ID="$2" DO_REMOVE="${3:-}"
SUMMARY="/tmp/aos-package-${ID}-summary.txt"

ctl="$(mktemp -d)"
trap 'rm -rf "$ctl"' EXIT
dpkg-deb -e "$DEB" "$ctl"

say "${ID}: maintainer scripts of $(basename "$DEB")"
actions() {
    grep -RnE "(deb-systemd-invoke|deb-systemd-helper|systemctl).*$1" "$ctl" 2>/dev/null || true
}
for unit in 'aos-unit-node@' 'aos-unit-dnsmasq' 'aos-unit-vm-failed@'; do
    hits="$(actions "$unit")"
    check "$ID" "no maintscript action on ${unit}" "" "$hits"
    [[ -z $hits ]] || sed 's/^/        /' <<<"$hits"
done
# The review's literal check. preinst may name the sidecar, but only to read
# its state; every systemctl verb it runs must target aos-unit.service.
mentions="$(grep -Rn 'aos-unit-dnsmasq' "$ctl" 2>/dev/null || true)"
info "$ID" "grep -R aos-unit-dnsmasq (lines)" "$(sed '/^$/d' <<<"$mentions" | wc -l)"
[[ -z $mentions ]] || sed 's/^/        /' <<<"$mentions"
verbs="$(grep -RhoE '(systemctl|deb-systemd-invoke)( -[-a-z]+)* (start|stop|restart|try-restart|reload-or-restart|kill|enable|disable|mask) [^;|&]*' "$ctl" 2>/dev/null |
    grep -v "aos-unit.service" || true)"
check "$ID" "systemctl verbs only on aos-unit.service" "" "$verbs"
[[ -z $verbs ]] || sed 's/^/        /' <<<"$verbs"
check "$ID" "maintscripts manage aos-unit.service" yes \
    "$([[ -n $(actions "'aos-unit.service'") ]] && echo yes || echo no)"
named="$(grep -RhoE "'aos-unit[^']*'" "$ctl" | sort -u | tr '\n' ' ')"
if [[ $ID == T2.* ]]; then
    # Phase 2 (R14-5): debhelper may name nothing but the manager, not even the slice
    check "$ID" "units named in maintscripts" "'aos-unit.service' " "$named"
else
    info "$ID" "units named in maintscripts" "$named"
fi

if [[ $DO_REMOVE == --remove ]]; then
    say "${ID}: dpkg -r while running"
    dpkg -i "$DEB" >/dev/null 2>&1
    systemctl start aos-unit.service
    wait_until 60 unit_is "$(node_unit "$(node_names | head -1)")" active
    wait_guests_booted
    since="$(now)"
    dpkg -r aos-unit >/tmp/aos-remove.log 2>&1
    check "$ID" "dpkg -r exit code" 0 "$?"
    check "$ID" "after remove: aos-unit inactive" inactive "$(show aos-unit.service ActiveState)"
    check "$ID" "after remove: dnsmasq not active" no \
        "$([[ $(show "$DNS_UNIT" ActiveState) == active ]] && echo yes || echo no)"
    check "$ID" "after remove: bridge removed" "" "$(bridges)"
    check "$ID" "after remove: taps removed" "" "$(taps)"
    check "$ID" "after remove: no failed aos-unit units" "" "$(failed_aos_units)"
    check_no_race "$ID" "$since"
    dpkg -i "$DEB" >/dev/null 2>&1
    systemctl stop aos-unit.service
    info "$ID" "reinstalled" "$(dpkg-query -W -f='${Version}' aos-unit)"
fi

summary "Package ${ID}: $(basename "$DEB")"
exit "$FAILS"
