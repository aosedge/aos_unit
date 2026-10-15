#!/usr/bin/env bash
# Probe: which command actually removes the drop-ins that
# `systemctl set-property --runtime` writes into /run/systemd/system.control?
# Throwaway experiment for issue #11 phase 3. Run as root.

set -u

readonly TEMPLATE=/etc/systemd/system/aosprobe@.service
readonly INSTANCE=aosprobe@main.service
readonly CONTROL_DIR="/run/systemd/system.control/${INSTANCE}.d"

cleanup() {
    systemctl stop "$INSTANCE" >/dev/null 2>&1
    rm -rf "$CONTROL_DIR"
    rm -f "$TEMPLATE"
    systemctl daemon-reload
}
trap cleanup EXIT

cat >"$TEMPLATE" <<'EOF'
[Unit]
Description=aos-unit #11 revert probe for %i

[Service]
Type=simple
ExecStart=/bin/sleep 300
EOF
systemctl daemon-reload

state() {
    printf '    control dir: %s | MemoryMax=%s\n' \
        "$(ls "$CONTROL_DIR" 2>/dev/null | tr '\n' ' ' || echo empty)" \
        "$(systemctl show -p MemoryMax --value "$INSTANCE")"
}

arm() {
    systemctl set-property --runtime "$INSTANCE" MemoryMax=64M CPUQuota=50%
}

echo "=== baseline: after set-property --runtime ==="
arm
state

echo
echo "=== candidate 1: systemctl revert --runtime UNIT ==="
systemctl revert --runtime "$INSTANCE"
echo "    rc=$?"
state

echo
echo "=== candidate 2: systemctl revert UNIT ==="
arm
systemctl revert "$INSTANCE"
echo "    rc=$?"
state

echo
echo "=== candidate 3: set-property with empty values ==="
arm
systemctl set-property --runtime "$INSTANCE" MemoryMax= CPUQuota=
echo "    rc=$?"
state

echo
echo "=== candidate 4: same, while the unit is running ==="
arm
systemctl start "$INSTANCE"
systemctl set-property --runtime "$INSTANCE" MemoryMax= CPUQuota=
echo "    rc=$?"
state
cg="$(systemctl show -p ControlGroup --value "$INSTANCE")"
echo "    memory.max=$(cat "/sys/fs/cgroup${cg}/memory.max" 2>&1)"
