#!/usr/bin/env bash
# Build <ref> and print every maintainer-script line that names an aos-unit
# systemd unit (excluding the postinst help text that lists unit files).
# Usage: inspect-maintscripts.sh <ref> <base-version>
set -u
deb="$(bash "$(dirname "$(realpath "$0")")/build-deb.sh" "$1" "$2" | tail -1)"
[[ -f $deb ]] || {
    echo "BUILD FAILED"
    exit 1
}
echo "DEB=$deb"
ctl="$(mktemp -d)"
dpkg-deb -e "$deb" "$ctl"
grep -RnE "aos-unit[^ ']*\.(service|slice)" "$ctl" | grep -vE '/lib/systemd/system/[^ ]+ +- '
rm -rf "$ctl"
