#!/usr/bin/env bash
# T2.3c: preinst's bounded wait for the transient aos-unit-dnsmasq to unload.
#
# 1. install BASELINE (transient sidecar), keep the manager stopped
# 2. plant a transient aos-unit-dnsmasq that nothing stops (no BindsTo=)
# 3. dpkg -i NEW must fail in preinst within its timeout, report it, keep the
#    baseline installed and leave the planted unit alone
# 4. once the planted unit is gone, dpkg -i NEW succeeds and the first start
#    runs the packaged sidecar
#
# Usage: phase2-preinst-stuck.sh <baseline.deb> <new.deb>

set -u

. "$(dirname "$(realpath "$0")")/lib-issue11.sh"

readonly BASE_DEB="$1" NEW_DEB="$2" ID=T2.3c
SUMMARY="/tmp/aos-upgrade-${ID}-summary.txt"
readonly LOG=/tmp/aos-preinst-stuck-dpkg.log

pkg_state() { dpkg-query -W -f='${Status} ${Version}' aos-unit 2>/dev/null; }

main() {
    local base_ver rc t0 frag
    say "${ID}: baseline $(basename "$BASE_DEB"), manager stopped"
    systemctl stop aos-unit.service 2>/dev/null
    dpkg -i "$BASE_DEB" >/dev/null 2>&1 || {
        record "$ID" FAIL "install baseline" "dpkg -i failed"
        summary "Upgrade ${ID}"
        return 1
    }
    systemctl stop aos-unit.service
    systemctl reset-failed 'aos-unit*' 2>/dev/null
    base_ver="$(dpkg-query -W -f='${Version}' aos-unit)"
    info "$ID" "baseline version" "$base_ver"

    systemd-run --quiet --collect --unit="$AOS_LEGACY_DNSMASQ" sleep 600
    check "$ID" "orphan transient planted" "active yes" \
        "$(show "$AOS_LEGACY_DNSMASQ" ActiveState) $(show "$AOS_LEGACY_DNSMASQ" Transient)"

    say "${ID}: upgrade while the transient does not unload"
    t0="$(date +%s)"
    dpkg -i "$NEW_DEB" >"$LOG" 2>&1
    rc=$?
    info "$ID" "dpkg -i exit code / seconds" "${rc} / $(($(date +%s) - t0))"
    sed 's/^/        /' "$LOG" | grep -iE 'preinst|error|aos-unit' | head -10
    check "$ID" "dpkg -i fails" yes "$( ((rc != 0)) && echo yes || echo no)"
    check "$ID" "preinst reports the unload timeout" 1 "$(grep -c 'did not unload within' "$LOG")"
    check "$ID" "baseline still installed" "install ok installed ${base_ver}" "$(pkg_state)"
    check "$ID" "unit file not installed" no \
        "$([[ -e /lib/systemd/system/${AOS_LEGACY_DNSMASQ} || -e /usr/lib/systemd/system/${AOS_LEGACY_DNSMASQ} ]] && echo yes || echo no)"
    check "$ID" "planted transient left running" "active yes" \
        "$(show "$AOS_LEGACY_DNSMASQ" ActiveState) $(show "$AOS_LEGACY_DNSMASQ" Transient)"

    say "${ID}: retry after the transient is gone"
    # abort-upgrade restarts the baseline manager, which cannot start its own
    # sidecar next to the planted one
    systemctl stop aos-unit.service 2>/dev/null
    systemctl stop "$AOS_LEGACY_DNSMASQ"
    check_cmd "$ID" "planted transient unloaded" wait_until 15 \
        bash -c "[[ \$(systemctl show -p LoadState --value $AOS_LEGACY_DNSMASQ) == not-found ]]"
    systemctl reset-failed 'aos-unit*' 2>/dev/null
    dpkg -i "$NEW_DEB" >"$LOG" 2>&1
    check "$ID" "dpkg -i exit code" 0 "$?"
    systemctl start aos-unit.service
    check "$ID" "aos-unit active" active "$(show aos-unit.service ActiveState)"
    check "$ID" "sidecar active, from its file" "active no" \
        "$(show "$AOS_LEGACY_DNSMASQ" ActiveState) $(show "$AOS_LEGACY_DNSMASQ" Transient)"
    frag="$(show "$AOS_LEGACY_DNSMASQ" FragmentPath)"
    check "$ID" "sidecar FragmentPath packaged" yes \
        "$([[ $frag == /lib/systemd/system/* || $frag == /usr/lib/systemd/system/* ]] && echo yes || echo "no (${frag})")"
    wait_guests_booted
    systemctl stop aos-unit.service
    check "$ID" "stop: bridge removed" "" "$(bridges)"
    check "$ID" "stop: no failed aos-unit units" "" "$(failed_aos_units)"

    summary "Upgrade ${ID}: $(basename "$BASE_DEB") -> $(basename "$NEW_DEB")"
    return "$FAILS"
}

main "$@"
