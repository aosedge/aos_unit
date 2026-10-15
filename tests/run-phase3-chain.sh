#!/usr/bin/env bash
# Run the Phase 3 per-commit test chain sequentially (host is shared).
# Usage: run-phase3-chain.sh <step...>   steps: s31 s33 s33r s34 s35 s36

set -u

_t="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
readonly T="$_t"
readonly DEBS=/var/tmp/aos-debs

for step in "$@"; do
    case "$step" in
        s31) ENV_EXTRA="EXPECT_GATE=0" bash "$T/run-step.sh" 676603b 1.2.0~p3s31 phase3-S3.1 phase3-acceptance.sh T3.8 ;;
        s33) ENV_EXTRA="RESTARTS=10" bash "$T/run-step.sh" 21fc40b 1.2.0~p3s33 phase3-S3.3 phase3-acceptance.sh T3.1 T3.2 T3.3 ;;
        s34) bash "$T/run-step.sh" 32c4494 1.2.0~p3s34 phase3-S3.4 phase3-acceptance.sh T3.5 T3.1 ;;
        s35)
            new="$(bash "$T/build-deb.sh" 8f0739c 1.2.0~p3s35 | tail -1)"
            base112="$(ls -1 "$DEBS"/aos-unit_1.1.2+*.deb | head -1)"
            basemain="$(ls -1 "$DEBS"/aos-unit_1.1.3~main+*.deb | head -1)"
            ENV_EXTRA="KNOWN_V112_SELF_HEAL=1" bash "$T/run-step.sh" 8f0739c 1.2.0~p3s35 phase3-S3.5-from-v1.1.2 upgrade-acceptance.sh "$base112" "$new" T3.6
            bash "$T/run-step.sh" 8f0739c 1.2.0~p3s35 phase3-S3.5-from-main upgrade-acceptance.sh "$basemain" "$new" T3.6
            ;;
        s33r) bash "$T/run-step.sh" 21fc40b 1.2.0~p3s33 phase3-S3.3-rerun phase3-acceptance.sh T3.1 ;;
        s36) bash "$T/run-step.sh" 57f2627 1.2.0~p3s36 phase3-S3.6-matrix phase3-restart-matrix.sh ;;
        s38)
            ref="${REF:-e0051aa}"
            new="$(bash "$T/build-deb.sh" "$ref" 1.2.0~p3s38 | tail -1)"
            base112="$(ls -1 "$DEBS"/aos-unit_1.1.2+*.deb | head -1)"
            basemain="$(ls -1 "$DEBS"/aos-unit_1.1.3~main+*.deb | head -1)"
            ENV_EXTRA="RESTARTS=10" bash "$T/run-step.sh" "$ref" 1.2.0~p3s38 phase3-S3.8-regression phase3-acceptance.sh T3.1 T3.2 T3.3 T3.5 T3.8
            bash "$T/run-step.sh" "$ref" 1.2.0~p3s38 phase3-S3.8-helpers phase3-helpers.sh /usr/libexec/aos-unit/log-helper
            bash "$T/run-step.sh" "$ref" 1.2.0~p3s38 phase3-S3.8-package package-checks.sh "$new" T3.7 --remove
            ENV_EXTRA="KNOWN_V112_SELF_HEAL=1" bash "$T/run-step.sh" "$ref" 1.2.0~p3s38 phase3-S3.8-from-v1.1.2 upgrade-acceptance.sh "$base112" "$new" T3.6
            bash "$T/run-step.sh" "$ref" 1.2.0~p3s38 phase3-S3.8-from-main upgrade-acceptance.sh "$basemain" "$new" T3.6
            ;;
        s38v)
            ref="${REF:-e0051aa}"
            new="$(bash "$T/build-deb.sh" "$ref" 1.2.0~p3s38 | tail -1)"
            base112="$(ls -1 "$DEBS"/aos-unit_1.1.2+*.deb | head -1)"
            ENV_EXTRA="KNOWN_V112_SELF_HEAL=1" bash "$T/run-step.sh" "$ref" 1.2.0~p3s38 phase3-S3.8-from-v1.1.2-rerun upgrade-acceptance.sh "$base112" "$new" T3.6
            ;;
        *) echo "unknown step $step" ;;
    esac
done
echo "CHAIN DONE"
