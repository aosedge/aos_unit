#!/usr/bin/env bash
# Probe: a transient unit is running when a package installs a fragment with
# the same name. What do LoadState/Transient/FragmentPath show before and
# after the transient one is stopped and collected?
set -u
u=probe-shadow.service
frag=/etc/systemd/system/$u
st() { printf '%-28s %s\n' "$1" "$(systemctl show -p LoadState -p ActiveState -p Transient -p FragmentPath "$u" | tr '\n' ' ')"; }

systemd-run -q --collect --unit="$u" sleep 600
st "transient running:"
printf '[Service]\nExecStart=/usr/bin/sleep 600\n' >"$frag"
systemctl daemon-reload
st "fragment installed+reload:"
systemctl stop --no-block "$u"
for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 0.2; done
st "after stop/collect:"
systemctl start "$u" && st "start after migration:"
systemctl stop "$u"
rm -f "$frag"
systemctl daemon-reload
