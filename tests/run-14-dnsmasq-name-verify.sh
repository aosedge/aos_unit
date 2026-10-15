#!/usr/bin/env bash
# Verify PR #14 with the packaged sidecar under the transient's name,
# aos-unit-dnsmasq.service, migrated by preinst. Runs sequentially (shared host).
#
# Usage: sudo bash tests/run-14-dnsmasq-name-verify.sh <git-ref> [step...]
#   steps: static package phase2 phase3 upgrades stuck   (default: all)
# Writes tests/results/p14-dnsmasq-name-<step>-<timestamp>.txt per step.

set -uo pipefail

_t="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
readonly T="$_t" REPO="${_t%/tests}"
readonly REF="${1:?git ref required}"
shift
readonly DEBS=/var/tmp/aos-debs VER=1.2.0~p14name
readonly DNS_ENV=(AOS_DNSMASQ=aos-unit-dnsmasq.service NEW_DNS_UNIT=aos-unit-dnsmasq.service
    EXPECT_DNSMASQ_TRANSIENT=no KNOWN_V112_SELF_HEAL=0)
TS="$(date +%Y%m%d-%H%M)"
readonly TS

base_deb() { ls -1 "$DEBS"/aos-unit_"$1"+*.deb | head -1; }

install_new() {
    systemctl stop aos-unit.service 2>/dev/null
    dpkg -i "$NEW" >/dev/null 2>&1
    echo "### installed: $(dpkg-query -W -f='${Version}' aos-unit)"
}

step_static() {
    local src rc
    src="$(mktemp -d)"
    git -C "$REPO" archive "$REF" | tar -xf - -C "$src"
    (cd "$src" && git init -q && git add -A)
    bash "$T/static-checks.sh" "$src"
    rc=$?
    rm -rf "$src"
    return "$rc"
}

step_package() { env "${DNS_ENV[@]}" bash "$T/package-checks.sh" "$NEW" T2.4 --remove; }

step_phase2() {
    install_new
    env "${DNS_ENV[@]}" bash "$T/phase2-acceptance.sh" T2.1 T2.2 T2.3 T2.5
}

step_phase3() {
    install_new
    env "${DNS_ENV[@]}" RESTARTS=10 bash "$T/phase3-acceptance.sh" T3.1 T3.2 T3.3 T3.5 T3.8
}

step_upgrades() {
    local rc=0
    env "${DNS_ENV[@]}" bash "$T/upgrade-acceptance.sh" "$(base_deb 1.1.2)" "$NEW" T2.3 || rc=1
    env "${DNS_ENV[@]}" bash "$T/upgrade-acceptance.sh" "$(base_deb '1.1.3~main')" "$NEW" T2.3 || rc=1
    env "${DNS_ENV[@]}" BASELINE_NODES=static bash "$T/upgrade-acceptance.sh" "$(base_deb '1.2.0~p3s38')" "$NEW" T2.3 || rc=1
    return "$rc"
}

step_stuck() { bash "$T/phase2-preinst-stuck.sh" "$(base_deb 1.1.2)" "$NEW"; }

run() {
    local step="$1" out rc
    out="${REPO}/tests/results/p14-dnsmasq-name-${step}-${TS}.txt"
    {
        echo "### ${step}  ref=${REF} ($(git -C "$REPO" rev-parse --short "$REF"))  $(date '+%F %T')"
        echo "### deb: ${NEW}"
        "step_${step}"
        rc=$?
        echo "### exit: ${rc}"
    } >"$out" 2>&1
    echo "$out"
    grep -E '^(FAIL|RESULT|STATIC|### exit)' "$out"
}

NEW="$(bash "$T/build-deb.sh" "$REF" "$VER" | tail -1)" || {
    echo "BUILD FAILED"
    exit 1
}
readonly NEW

steps=("$@")
((${#steps[@]})) || steps=(static package phase2 phase3 upgrades stuck)
for s in "${steps[@]}"; do
    run "$s"
done
echo "VERIFY DONE"
