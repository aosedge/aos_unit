#!/usr/bin/env bash
# Real package-upgrade acceptance (T3.6 for Phase 3, T2.3 for Phase 2).
#
# 1. install BASELINE deb, start it, confirm what is transient
# 2. install NEW deb on top of the running service, with no manual pre-wait
# 3. first start must succeed with static units and no leftover transients
# 4. planted leftover legacy transient node must be migrated on start
#
# Usage: upgrade-acceptance.sh <baseline.deb> <new.deb> <test-id>
# Env:   EXPECT_DNSMASQ_TRANSIENT=yes|no (after the upgrade; Phase 3: yes)
#        KNOWN_V112_SELF_HEAL=1  baseline is v1.1.2: its runtime network.conf
#          has no DHCP_START (required since main 2c17366), so the old
#          instance's cleanup aborts, the first new start hits "Bridge already
#          exists" and Restart=on-failure heals it. Pre-existing on main; those
#          lines become INFO, anything else still FAILs.

set -u

. "$(dirname "$(realpath "$0")")/lib-issue11.sh"

readonly BASE_DEB="$1" NEW_DEB="$2" ID="$3"
: "${EXPECT_DNSMASQ_TRANSIENT:=yes}"
# Baseline runs nodes as legacy transient units or as Phase 3 static instances
: "${BASELINE_NODES:=transient}"
# Sidecar unit after the upgrade (same name in every phase)
: "${NEW_DNS_UNIT:=${AOS_DNSMASQ}}"
: "${KNOWN_V112_SELF_HEAL:=0}"
: "${BASELINE_SETTLE_SEC:=90}"
SUMMARY="/tmp/aos-upgrade-${ID}-summary.txt"
readonly V112_SIGNATURE="DHCP_START missing|Bridge '[^']+' already exists|VM unit FAILED( \(during manager stop\))?: aos-unit-node-[A-Za-z0-9_-]+$"

manager_auto_restarts() { journal_units "$1" | grep -c 'aos-unit.service: Scheduled restart job'; }

check_upgrade_window() {
    local since="$1" restarts race unknown
    restarts="$(manager_auto_restarts "$since")"
    race="$(race_errors_since "$since")"
    if [[ $KNOWN_V112_SELF_HEAL == 1 ]]; then
        unknown="$(grep -vE "$V112_SIGNATURE" <<<"$race" | sed '/^$/d')"
        info "$ID" "manager auto-restarts (known v1.1.2 self-heal)" "$restarts"
        info "$ID" "journal lines matching the v1.1.2 signature" "$(grep -cE "$V112_SIGNATURE" <<<"$race")"
        if [[ -z $unknown ]]; then
            record "$ID" PASS "journal: nothing beyond the v1.1.2 signature" "none"
        else
            record "$ID" FAIL "journal: nothing beyond the v1.1.2 signature" "$(wc -l <<<"$unknown") line(s)"
            sed 's/^/        /' <<<"$unknown" | tail -15
        fi
        return
    fi
    check "$ID" "no automatic manager restart" 0 "$restarts"
    check_no_race "$ID" "$since"
}

settle_boundary() { sleep 1.1; }

legacy_loaded() { list_prefix aos-unit-node-; }
list_prefix() {
    systemctl list-units --all --type=service --no-legend --plain "${1}*" 2>/dev/null |
        grep -o "${1}[^[:space:]]*\.service" | tr '\n' ' '
}

all_nodes_active() {
    local name
    for name in $(node_names); do
        unit_is "$(node_unit "$name")" active || return 1
    done
}

assert_upgraded() {
    local label="$1" name unit
    check "$ID" "${label}: aos-unit active" active "$(show aos-unit.service ActiveState)"
    for name in $(node_names); do
        unit="$(node_unit "$name")"
        check "$ID" "${label}: ${name} static instance active" active "$(show "$unit" ActiveState)"
        check "$ID" "${label}: ${name} Transient" no "$(show "$unit" Transient)"
        check "$ID" "${label}: ${name} legacy unit gone" not-found "$(show "$(legacy_node_unit "$name")" LoadState)"
    done
    check "$ID" "${label}: no aos-unit-node-* units loaded" "" "$(legacy_loaded)"
    check "$ID" "${label}: ${NEW_DNS_UNIT} active" active "$(show "$NEW_DNS_UNIT" ActiveState)"
    check "$ID" "${label}: ${NEW_DNS_UNIT} Transient" "$EXPECT_DNSMASQ_TRANSIENT" "$(show "$NEW_DNS_UNIT" Transient)"
    if [[ $NEW_DNS_UNIT != "$AOS_LEGACY_DNSMASQ" ]]; then
        check "$ID" "${label}: legacy ${AOS_LEGACY_DNSMASQ} gone" not-found "$(show "$AOS_LEGACY_DNSMASQ" LoadState)"
    fi
    if [[ $EXPECT_DNSMASQ_TRANSIENT == no ]]; then
        local frag
        frag="$(show "$NEW_DNS_UNIT" FragmentPath)"
        check "$ID" "${label}: ${NEW_DNS_UNIT} FragmentPath packaged" yes \
            "$([[ $frag == /lib/systemd/system/* || $frag == /usr/lib/systemd/system/* ]] && echo yes || echo "no (${frag})")"
    fi
}

main() {
    say "${ID}: baseline $(basename "$BASE_DEB")"
    systemctl stop aos-unit.service 2>/dev/null
    dpkg -i "$BASE_DEB" >/dev/null 2>&1 || {
        record "$ID" FAIL "install baseline" "dpkg -i failed"
        summary "Upgrade ${ID}"
        return 1
    }
    systemctl reset-failed 'aos-unit*' 2>/dev/null
    systemctl restart aos-unit.service
    # Pre-Phase-3 packages write no nodes/*.env, so wait_guests_booted cannot probe
    sleep "$BASELINE_SETTLE_SEC"
    report_state
    info "$ID" "baseline version" "$(dpkg-query -W -f='${Version}' aos-unit)"
    local name
    for name in $(node_names); do
        if [[ $BASELINE_NODES == static ]]; then
            check "$ID" "baseline: ${name} runs as static instance" "active no" \
                "$(show "$(node_unit "$name")" ActiveState) $(show "$(node_unit "$name")" Transient)"
        else
            check "$ID" "baseline: ${name} runs as legacy transient" "active yes" \
                "$(show "$(legacy_node_unit "$name")" ActiveState) $(show "$(legacy_node_unit "$name")" Transient)"
        fi
    done
    check "$ID" "baseline: dnsmasq transient" yes "$(show "$AOS_LEGACY_DNSMASQ" Transient)"

    say "${ID}: upgrade to $(basename "$NEW_DEB") while running"
    local since rc
    since="$(now)"
    dpkg -i "$NEW_DEB" >/tmp/aos-upgrade-dpkg.log 2>&1
    rc=$?
    check "$ID" "dpkg -i new package exit code" 0 "$rc"
    check_cmd "$ID" "all static instances active within 120s" wait_until 120 all_nodes_active
    sleep 3
    report_state
    info "$ID" "new version" "$(dpkg-query -W -f='${Version}' aos-unit)"
    assert_upgraded "after upgrade"
    check_upgrade_window "$since"
    info "$ID" "migration logged" "$(journal_units "$since" | grep -c 'Migrating legacy transient VM units')"
    if [[ $EXPECT_DNSMASQ_TRANSIENT == no && $NEW_DNS_UNIT == "$AOS_LEGACY_DNSMASQ" ]]; then
        check "$ID" "preinst stopped the manager for the sidecar" 1 \
            "$(grep -c "Stopping aos-unit.service to replace the transient ${AOS_LEGACY_DNSMASQ}" /tmp/aos-upgrade-dpkg.log)"
        check "$ID" "dpkg log: no preinst unload timeout" 0 "$(grep -c 'did not unload' /tmp/aos-upgrade-dpkg.log)"
    fi

    say "${ID}: planted leftover legacy transient node"
    wait_guests_booted
    systemctl stop aos-unit.service
    systemctl reset-failed 'aos-unit*' 2>/dev/null
    systemd-run -q --collect --unit=aos-unit-node-ghost sleep 600
    check "$ID" "ghost planted" "active yes" "$(show aos-unit-node-ghost.service ActiveState) $(show aos-unit-node-ghost.service Transient)"
    settle_boundary
    since="$(now)"
    systemctl start aos-unit.service
    check_cmd "$ID" "all static instances active within 120s" wait_until 120 all_nodes_active
    check "$ID" "ghost migrated (unloaded)" not-found "$(show aos-unit-node-ghost.service LoadState)"
    assert_upgraded "after ghost"
    check "$ID" "no automatic manager restart" 0 "$(manager_auto_restarts "$since")"
    check_no_race "$ID" "$since"

    say "${ID}: stop"
    wait_guests_booted
    systemctl stop aos-unit.service
    check "$ID" "stop: bridge removed" "" "$(bridges)"
    check "$ID" "stop: taps removed" "" "$(taps)"
    check "$ID" "stop: no failed aos-unit units" "" "$(failed_aos_units)"

    summary "Upgrade ${ID}: $(basename "$BASE_DEB") -> $(basename "$NEW_DEB")"
    return "$FAILS"
}

main "$@"
