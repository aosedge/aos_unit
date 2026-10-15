#!/usr/bin/env bash
# Probe: can per-node cgroup limits be applied to a STATIC systemd template
# instance the way `systemd-run --property=` applies them today?
# Throwaway experiment for issue #11 phase 3. Run as root.

set -u

readonly TEMPLATE=/etc/systemd/system/aosprobe@.service
readonly INSTANCE=aosprobe@main.service

cleanup() {
    systemctl stop "$INSTANCE" >/dev/null 2>&1
    systemctl revert --runtime "$INSTANCE" >/dev/null 2>&1
    rm -f "$TEMPLATE"
    systemctl daemon-reload
}
trap cleanup EXIT

cat >"$TEMPLATE" <<'EOF'
[Unit]
Description=aos-unit #11 probe for %i

[Service]
Type=simple
OOMPolicy=kill
ExecStart=/bin/sleep 300
EOF
systemctl daemon-reload

echo "=== 1. set-property on an INACTIVE template instance ==="
systemctl set-property --runtime "$INSTANCE" MemoryMax=64M CPUQuota=50%
echo "rc=$?"
systemctl show -p LoadState -p ActiveState -p MemoryMax -p CPUQuotaPerSecUSec "$INSTANCE"
echo "--- drop-in systemd wrote for us ---"
ls -l /run/systemd/system.control/"$INSTANCE".d/ 2>&1
cat /run/systemd/system.control/"$INSTANCE".d/*.conf 2>&1

echo
echo "=== 2. start, then read what the kernel actually enforces ==="
systemctl start "$INSTANCE"
sleep 1
cg="$(systemctl show -p ControlGroup --value "$INSTANCE")"
echo "ControlGroup=$cg"
echo "memory.max=$(cat "/sys/fs/cgroup${cg}/memory.max" 2>&1)"
echo "cpu.max=$(cat "/sys/fs/cgroup${cg}/cpu.max" 2>&1)"

echo
echo "=== 3. is starting an already-active instance a no-op? ==="
systemctl start "$INSTANCE"
echo "second start rc=$?"

echo
echo "=== 4. do limits survive a restart? ==="
systemctl restart "$INSTANCE"
sleep 1
cg="$(systemctl show -p ControlGroup --value "$INSTANCE")"
echo "memory.max=$(cat "/sys/fs/cgroup${cg}/memory.max" 2>&1)"
echo "cpu.max=$(cat "/sys/fs/cgroup${cg}/cpu.max" 2>&1)"

echo
echo "=== 5. can the unprivileged aos-unit user do the same over D-Bus? ==="
systemctl stop "$INSTANCE"
systemctl revert --runtime "$INSTANCE" >/dev/null 2>&1
runuser -u aos-unit -- systemctl set-property --runtime "$INSTANCE" MemoryMax=128M CPUQuota=75% 2>&1
echo "aos-unit set-property rc=$?"
systemctl show -p MemoryMax -p CPUQuotaPerSecUSec "$INSTANCE"
runuser -u aos-unit -- systemctl start "$INSTANCE" 2>&1
echo "aos-unit start rc=$?"
cg="$(systemctl show -p ControlGroup --value "$INSTANCE")"
echo "memory.max=$(cat "/sys/fs/cgroup${cg}/memory.max" 2>&1)"

echo
echo "=== 6. name is static: LoadState after stop (no --collect race) ==="
systemctl stop "$INSTANCE"
systemctl show -p LoadState -p ActiveState --value "$INSTANCE"
