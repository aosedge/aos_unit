#!/usr/bin/env bash
# Run the Phase 2 per-commit test chain sequentially (host is shared).
# Usage: run-phase2-chain.sh <step...>   steps: s23 s24 s25 s27
#   s27 is the final Plan 1 + Plan 2 regression at REF (default 7bf97eb).

set -u

_t="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
readonly T="$_t"
readonly DEBS=/var/tmp/aos-debs
readonly DNS_ENV="AOS_DNSMASQ=aos-unit-dns.service NEW_DNS_UNIT=aos-unit-dns.service EXPECT_DNSMASQ_TRANSIENT=no"

base_deb() { ls -1 "$DEBS"/aos-unit_"$1"+*.deb | head -1; }

# upgrades <ref> <ver> <label-prefix> <new-deb> <id> <baseline...>
#   baseline: v112 | main | phase3
upgrades() {
    local ref="$1" ver="$2" prefix="$3" new="$4" id="$5" b
    shift 5
    for b in "$@"; do
        case "$b" in
            v112) ENV_EXTRA="${DNS_ENV} KNOWN_V112_SELF_HEAL=1" bash "$T/run-step.sh" "$ref" "$ver" "${prefix}-from-v1.1.2" \
                upgrade-acceptance.sh "$(base_deb 1.1.2)" "$new" "$id" ;;
            main) ENV_EXTRA="$DNS_ENV" bash "$T/run-step.sh" "$ref" "$ver" "${prefix}-from-main" \
                upgrade-acceptance.sh "$(base_deb '1.1.3~main')" "$new" "$id" ;;
            phase3) ENV_EXTRA="${DNS_ENV} BASELINE_NODES=static" bash "$T/run-step.sh" "$ref" "$ver" "${prefix}-from-phase3" \
                upgrade-acceptance.sh "$(base_deb '1.2.0~p3s38')" "$new" "$id" ;;
        esac
    done
}

for step in "$@"; do
    case "$step" in
        s23)
            new="$(bash "$T/build-deb.sh" 4d06c73 1.2.0~p2s23 | tail -1)"
            upgrades 4d06c73 1.2.0~p2s23 phase2-S2.3 "$new" T2.3 v112 phase3
            ;;
        s24)
            new="$(bash "$T/build-deb.sh" 370e4cf 1.2.0~p2s24 | tail -1)"
            bash "$T/run-step.sh" 370e4cf 1.2.0~p2s24 phase2-S2.4-package package-checks.sh "$new" T2.4 --remove
            ;;
        s25) ENV_EXTRA="$DNS_ENV" bash "$T/run-step.sh" 79990ec 1.2.0~p2s25 phase2-S2.5 phase2-acceptance.sh T2.1 T2.2 T2.5 ;;
        s27)
            ref="${REF:-7bf97eb}"
            new="$(bash "$T/build-deb.sh" "$ref" 1.2.0~p2s27 | tail -1)"
            ENV_EXTRA="$DNS_ENV" bash "$T/run-step.sh" "$ref" 1.2.0~p2s27 phase2-S2.7-phase2 phase2-acceptance.sh T2.1 T2.2 T2.3 T2.5
            ENV_EXTRA="${DNS_ENV} RESTARTS=10" bash "$T/run-step.sh" "$ref" 1.2.0~p2s27 phase2-S2.7-phase3 \
                phase3-acceptance.sh T3.1 T3.2 T3.3 T3.5 T3.8
            bash "$T/run-step.sh" "$ref" 1.2.0~p2s27 phase2-S2.7-helpers phase3-helpers.sh /usr/libexec/aos-unit/log-helper
            bash "$T/run-step.sh" "$ref" 1.2.0~p2s27 phase2-S2.7-package package-checks.sh "$new" T2.4 --remove
            upgrades "$ref" 1.2.0~p2s27 phase2-S2.7 "$new" T2.3 v112 main phase3
            ;;
        *) echo "unknown step $step" ;;
    esac
done
echo "CHAIN DONE"
