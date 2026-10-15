# Manual test checklist — issue #9 / PR #12

Covers [issue #9](https://github.com/aosedge/aos_unit/issues/9) and review points on
[PR #12](https://github.com/aosedge/aos_unit/pull/12).

Run as **root** on Linux or WSL. Requires `aos-unit` installed from the PR branch,
qcow2 images in `/var/lib/aos-unit`, and systemd.

**Important:** remove any orphan static dnsmasq unit left from issue #11 testing:

```bash
sudo rm -f /lib/systemd/system/aos-unit-dnsmasq.service
sudo systemctl daemon-reload
```

**IDs.** Each row uses the same ID as the automated case in
[die-shutdown-order-matrix.sh](die-shutdown-order-matrix.sh), so a manual row and
a matrix row with the same ID are the same test. Families and requirements are
explained in [README.md](README.md#issue-9--pr-12-wait-for-leftover-transient-units).
`I` rows are manual-only inspections (code or host state) with no matrix case.

---

## Before you start

```bash
sudo systemctl stop aos-unit
sudo systemctl reset-failed aos-unit aos-unit-dnsmasq 2>/dev/null || true

# Reuse in every check
jcheck() {
  journalctl -u aos-unit -u 'aos-unit-node-*' -u aos-unit-dnsmasq \
    --since "$1" --no-pager -o cat | grep -iE \
    'already exists|already running|Failed to start AosEdge|Scheduled restart job' \
    && echo BAD || echo OK
}

state() {
  systemctl show -p ActiveState -p NRestarts -p LoadState -- aos-unit.service
  systemctl is-active aos-unit-dnsmasq.service 2>/dev/null || true
  systemctl list-units --all --plain 'aos-unit-node-*' 2>/dev/null | head
}
```

**Pass criteria for any start/restart (the "clean cycle"):**

- `ActiveState=active`
- `NRestarts` unchanged (unless on-failure restart is the scenario under test)
- `jcheck "$since"` prints `OK`
- Journal contains `Startup complete`
- After `stop`: no leftover bridge/taps (`ip link | grep -E 'aosbr|aostap'` empty)

---

## R9-1 — Issue #9 (core bug)

| ID | What | Commands | Pass |
|---|------|----------|------|
| L2 | Leftover dnsmasq at start | `sudo systemctl stop aos-unit`<br>`sudo systemd-run --unit=aos-unit-dnsmasq --collect -- /bin/sleep 120`<br>`since=$(date '+%F %T')`<br>`nr=$(systemctl show -p NRestarts --value aos-unit)`<br>`sudo systemctl start aos-unit`<br>`state; jcheck "$since"` | exit 0, `NRestarts` same, both units active, journal: `Waiting for transient unit to unload: aos-unit-dnsmasq` then `Startup complete`, no `already exists` |

P1 below (stop then start) also covers the stop/start an upgrade performs.

---

## R12-1 — Die / shutdown order

| ID | What | Commands | Pass |
|---|------|----------|------|
| P1 | Stop → start | `sudo systemctl stop aos-unit; sleep 2`<br>`since=$(date '+%F %T'); sudo systemctl start aos-unit; sleep 5`<br>`state; jcheck "$since"` | first start clean |
| P2 | Restart | `since=$(date '+%F %T'); sudo systemctl restart aos-unit; sleep 5`<br>`state; jcheck "$since"` | first restart clean |
| P3 | Two restarts | run P2 twice | both clean |
| D1 | Runner SIGTERM | `pid=$(systemctl show -p MainPID --value aos-unit)`<br>`since=$(date '+%F %T'); sudo kill -TERM "$pid"; sleep 3`<br>`sudo systemctl start aos-unit 2>/dev/null || true; sleep 5`<br>`state; jcheck "$since"` | recovers clean |
| D2 | Runner SIGKILL | `pid=$(systemctl show -p MainPID --value aos-unit)`<br>`since=$(date '+%F %T'); sudo kill -KILL "$pid"; sleep 15`<br>`state; jcheck "$since"` | on-failure restart clean |
| D3 | Kill one VM, restart | cluster up; `qpid=$(systemctl show -p MainPID --value aos-unit-node-main.service)`<br>`since=$(date '+%F %T'); sudo kill -KILL "$qpid"; sleep 1`<br>`sudo systemctl restart aos-unit; sleep 10`<br>`state; jcheck "$since"` | restart clean |
| D4 | Kill both VMs, restart | kill main + secondary QEMU PIDs, then `sudo systemctl restart aos-unit` | restart clean |
| L1 | Leftover node at start | `sudo systemctl stop aos-unit`<br>`sudo systemd-run --unit=aos-unit-node-main --collect -- /bin/sleep 120`<br>`since=$(date '+%F %T'); sudo systemctl start aos-unit; sleep 10`<br>`state; jcheck "$since"` | first start clean |
| L2 | Leftover dnsmasq at start | see R9-1 | see R9-1 |
| C1 | Failed node cleaned on stop | cluster up<br>`sudo systemd-run --unit=aos-unit-node-matrixghost -- /bin/false`<br>`sudo systemctl stop aos-unit`<br>`systemctl show -p LoadState --value aos-unit-node-matrixghost.service` | `not-found` |
| O1 | Stop order | cluster up; `since=$(date '+%F %T'); sudo systemctl stop aos-unit; sleep 5`<br>`journalctl -u aos-unit --since "$since" -o cat | grep 'Cleanup complete'` | line present; bridge/taps gone |

---

## R12-2 — VM failure shapes

| ID | What | Commands | Pass |
|---|------|----------|------|
| V1 | VM cannot start (corrupt image) | `img=$(ls /var/lib/aos-unit/aos-vm-main-*.qcow2 | head -1)`<br>`sudo cp -a "$img" "${img}.bak"; sudo systemctl stop aos-unit`<br>`sudo head -c 1M /dev/zero >"$img"`<br>`sudo systemctl start aos-unit; sleep 15; sudo systemctl stop aos-unit`<br>`sudo mv "${img}.bak" "$img"`<br>`since=$(date '+%F %T'); sudo systemctl start aos-unit; jcheck "$since"` | stop clean; second start clean |
| V2 | Guest exits (QMP quit) | cluster up<br>`printf '{"execute":"qmp_capabilities"}\n{"execute":"quit"}\n' | socat - UNIX-CONNECT:/run/aos-unit/main.qmp`<br>then P1 | stop/start clean |
| V3 | QEMU crash during auto-restart | `sudo kill -KILL $(systemctl show -p MainPID --value aos-unit-node-main.service)`<br>wait for `SubState=auto-restart`, then stop/start | clean |
| V4 | Node start limit | kill main QEMU 3× until OnFailure; `sudo systemctl restart aos-unit` | restart clean |
| V5 | QEMU hung (SIGSTOP) | `sudo kill -STOP $(systemctl show -p MainPID --value aos-unit-node-main.service)`<br>`time sudo systemctl restart aos-unit` | completes (~60s), clean |

---

## R12-3 — dnsmasq failure shapes

| ID | What | Commands | Pass |
|---|------|----------|------|
| N1 | dnsmasq SIGKILL | `sudo kill -KILL $(systemctl show -p MainPID --value aos-unit-dnsmasq.service)`<br>`sudo systemctl restart aos-unit` | clean |
| N2 | dnsmasq SIGSTOP | `sudo kill -STOP $(systemctl show -p MainPID --value aos-unit-dnsmasq.service)`<br>`sudo systemctl restart aos-unit` | clean |
| N3 | dnsmasq port taken | `sudo systemctl stop aos-unit`<br>`python3 -c 'import socket,time;s=socket.socket();s.bind(("0.0.0.0",5300));time.sleep(600)' &`<br>`sudo systemctl start aos-unit; sleep 10; sudo systemctl stop aos-unit`<br>`kill %1; since=$(date '+%F %T'); sudo systemctl start aos-unit; jcheck "$since"` | stop clean; start after port free clean |
| N4 | Failed dnsmasq at start | `sudo systemctl stop aos-unit`<br>`sudo systemd-run --unit=aos-unit-dnsmasq -- /bin/false`<br>`since=$(date '+%F %T'); sudo systemctl start aos-unit; jcheck "$since"` | first start clean |

---

## R12-4 — Bounded wait

| ID | What | How | Pass |
|---|------|-----|------|
| I1 | Wait has deadline | `grep -n 'deadline=\|did not unload within' /usr/libexec/aos-unit/log-helper` | both in `wait_for_transient_cleanup` |
| I2 | Per-unit timeouts | `grep DNSMASQ_UNLOAD_TIMEOUT_SEC /usr/libexec/aos-unit/log-helper` | 15s dnsmasq, 90s node |
| I3 | show errors ≠ success | `grep -A8 transient_unit_state /usr/libexec/aos-unit/log-helper` | returns 1 on failure; only `not-found` succeeds |
| H5 | Timeout smoke | plant unstoppable dummy unit; call wait with 3s timeout | error within ~3–15s, no hang |

---

## R12-5 — SIGTERM trap

| ID | What | How | Pass |
|---|------|-----|------|
| I4 | Helper sets no trap | `grep 'trap.*SIGTERM' /usr/libexec/aos-unit/log-helper` | none inside `wait_for_transient_cleanup` |
| H7, H8 | Caller trap preserved | compare runner trap before/after restart, or run `die-shutdown-order-matrix.sh --helpers-only` | unchanged / SIGTERM handled by caller |

---

## Host sanity

| ID | What | Command | Pass |
|---|------|---------|------|
| I5 | No static dnsmasq unit | `dpkg -S /lib/systemd/system/aos-unit-dnsmasq.service 2>&1` | no path found |
| G1 | Guest reachable (optional) | `ping -c1 -W2 10.0.0.100` after start | reply |
| I6 | Bridge gone after stop | `sudo systemctl stop aos-unit; ip link | grep aosbr` | empty |

---

## Optional automated run (same coverage)

From repo checkout on the test host:

```bash
sudo bash tests/prove-l2-fix.sh
sudo bash tests/die-shutdown-order-matrix.sh --helpers-only
sudo bash tests/die-shutdown-order-matrix.sh --setup-images /var/tmp/aos-core-v6.1.2
```

Expect `PROOF_OK` and `FAIL=0` in matrix output.

---

## Sign-off

| Requirement | Covers | Date | Result |
|------|--------|------|--------|
| R9-1 | Issue #9 | | |
| R12-1 | Die/shutdown order | | |
| R12-2 | VM failure shapes | | |
| R12-3 | dnsmasq failure shapes | | |
| R12-4 | Bounded wait | | |
| R12-5 | SIGTERM trap | | |
| Host | Host sanity | | |

**Notes**

- WSL: `ssh root@main.aos-unit` may fail; use IP or `resolvectl query main.aos-unit`.
- TCG-only hosts boot slower than KVM; allow extra time on D3–D4, L1 and V1–V5.
- CI `shfmt` failure on `network-helper` L83 is style-only; fix on `fix/wsl-drvfs-local-build` (`cb9fe2a`).
