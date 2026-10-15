#!/usr/bin/env bash
# Same checks as .github/workflows/static-analysis.yml, on tracked files only,
# plus systemd-analyze verify for the unit files in the repo.
# Usage: tests/static-checks.sh [repo]

set -u

_repo="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
readonly REPO="${1:-$_repo}"
cd "$REPO" || exit 1

rc=0
mapfile -t scripts < <(git ls-files | while read -r f; do
    [[ -f $f ]] || continue
    head -1 "$f" | grep -qE '^#!.*\b(bash|sh)\b' && echo "$f"
    [[ $f == *.sh ]] && ! head -1 "$f" | grep -qE '^#!' && echo "$f"
done | sort -u)

echo "=== shellcheck -S warning (${#scripts[@]} files, checked together)"
shellcheck -S warning "${scripts[@]}" || rc=1

echo "=== shfmt -ln=bash -ci -i 4 -s -d"
shfmt -ln=bash -ci -i 4 -s -d "${scripts[@]}" || rc=1

echo "=== systemd-analyze verify"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for u in $(git ls-files '*.service' '*.slice'); do
    name="${u##*/}"
    [[ $name == *@.service ]] && name="${name/@./@verify.}"
    install -m 0644 "$u" "$tmp/$name"
done
out="$(cd "$tmp" && SYSTEMD_LOG_LEVEL=warning systemd-analyze verify --man=no ./*[!@].service ./*.slice 2>&1 |
    grep -vE 'Failed to load environment files|/run/aos-unit|Unit configuration has fatal error|aos-unit-vm-failed@' || true)"
if [[ -n $out ]]; then
    echo "$out"
    rc=1
fi

if ((rc == 0)); then echo "STATIC: PASS"; else echo "STATIC: FAIL"; fi
exit "$rc"
