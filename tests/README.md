# aos-unit acceptance tests

These scripts check the installed `aos-unit` package on a real Linux host with
systemd and AosCore guests. They are kept in git for developers and QA and are
not shipped in the `.deb` (`debian/install` does not list `tests/`).

Each requirement below links to the GitHub issue, the pull request, and the
review comment it comes from, then names the test that proves it, the script
to run, and what a pass looks like.

## Contents

- [Before you run](#before-you-run)
- [Selecting tests](#selecting-tests)
- [Background in two minutes](#background-in-two-minutes)
- [Issue #9 / PR #12: wait for leftover transient units](#issue-9--pr-12-wait-for-leftover-transient-units)
- [Issue #11 / PR #13: VMs as static template units](#issue-11--pr-13-vms-as-static-template-units)
- [Issue #11 / PR #14: dnsmasq as a static unit](#issue-11--pr-14-dnsmasq-as-a-static-unit)
- [PR #15: local builds on WSL](#pr-15-local-builds-on-wsl)
- [Regression: what to rerun](#regression-what-to-rerun)
- [Known journal noise (out of PR scope)](#known-journal-noise-out-of-pr-scope)
- [Scripts](#scripts)

## Before you run

| Need | Details |
|---|---|
| Host | Linux or WSL2 with systemd. Run every script as root (`sudo`). |
| KVM | Optional. Without `/dev/kvm` (or with `ENABLE_KVM="false"` in `runtime.conf`) guests run under software emulation and boot much slower: run the scripts with `GUEST_BOOT_MAX_SEC=600`. Matrix case G1 (ping within 180 s) may still fail on such a host. Recorded results so far are from a KVM host. |
| Shell | bash. Not PowerShell: `$(...)`, quotes and `date '+%F'` break there. |
| Guest images | One `aos-vm-<node>-qemux86-64.qcow2` per node in `/var/lib/aos-unit/`. |
| Nodes | `/etc/aos-unit/unit_config.yaml` with at least `main` and `secondary`. The results so far used `main`, `secondary`, `secondary-1`. |
| Package | The `.deb` built from the PR under test, installed with `dpkg -i`. Each section says which one. |

Build and install a package from any git ref (branch, tag, commit). The build
runs in a temp dir on the Linux filesystem, so it works from `/mnt/c` too:

```bash
cd /path/to/aos_unit
git fetch fork                           # PR branches live on the fork
mkdir -p ~/aos-debs
bash tests/build-deb.sh <ref> <version> ~/aos-debs   # prints the .deb path last
sudo dpkg -i ~/aos-debs/aos-unit_<version>+*.deb
dpkg-query -W aos-unit                   # confirm the installed version
```

| Package | `<ref>` | `<version>` |
|---|---|---|
| Released baseline (for upgrade tests) | `v1.1.2` | `1.1.2` |
| PR #12 | `fork/fix/9-transient-unit-restart-race` | `1.2.0~pr12` |
| PR #13 | `fork/feat/11-phase3-vm-template-units` | `1.2.0~pr13` |
| PR #14 (includes PR #13) | `fork/feat/11-phase2-dnsmasq-static-unit` | `1.2.0~pr14` |

**How to read results.** Every check prints one line starting with `PASS`,
`FAIL`, or `INFO`. `INFO` is a measurement and never fails a run. A run passed
when it ends with:

- `RESULT: ALL CHECKS PASSED` for the `phase*`, `upgrade-*` and `package-*` scripts
- `PASS=<n> FAIL=0` for `die-shutdown-order-matrix.sh`
- `STATIC: PASS` for `static-checks.sh`

## Selecting tests

Each script takes test IDs differently. **Subcases** (`T2.3a`, `T2.5c`) are labels
inside a run — you cannot pass them on the CLI; run `T2.3` or `T2.5` instead.

| Script | How to pick tests | Example |
|---|---|---|
| `die-shutdown-order-matrix.sh` | `--cases "ID …"` or mode flags | `sudo bash tests/die-shutdown-order-matrix.sh --cases "L1 L2"` |
| | `--helpers-only` = H1–H8, no guests | `sudo bash tests/die-shutdown-order-matrix.sh --helpers-only` |
| | *(no args)* = full matrix | `sudo bash tests/die-shutdown-order-matrix.sh` |
| `phase3-acceptance.sh` | positional `T3.x` (default: all runtime tests) | `sudo bash tests/phase3-acceptance.sh T3.1 T3.3` |
| `phase3-helpers.sh` | no IDs — always T3.H | `sudo bash tests/phase3-helpers.sh` |
| `phase2-acceptance.sh` | positional `T2.x` (default: T2.1 T2.2 T2.3 T2.5) | `sudo bash tests/phase2-acceptance.sh T2.5` |
| `upgrade-acceptance.sh` | one ID: `T3.6` or `T2.3` | `sudo bash tests/upgrade-acceptance.sh old.deb new.deb T3.6` |
| `package-checks.sh` | one ID: `T3.7` or `T2.4` | `sudo bash tests/package-checks.sh pkg.deb T2.4 --remove` |
| `phase3-restart-matrix.sh` | policy: `on-failure` / `on-abort` | `sudo bash tests/phase3-restart-matrix.sh on-failure` |

**Why two styles?** PR #12 has many case IDs plus flags (`--setup-images`, …), so
cases use `--cases`. Phase 2/3 only expose a few top-level IDs and use plain
arguments.

**Inside a run:** `T2.5` prints blocks `T2.5a` … `T2.5d`; `T2.3` runs `T2.3a`
then `T2.3b`. The traceability ledger may cite subcases (e.g. “2 FAIL in T2.5c”).

## Background in two minutes

- `aos-unit.service` is the manager and the only service an operator starts or
  stops. On start it builds the bridge, NAT and dnsmasq (DHCP/DNS for the
  guests), then `runner` starts one QEMU VM per node. On stop,
  `service-cleanup` tears it all down.
- A **transient unit** is created at runtime by `systemd-run --collect`. When
  it stops, systemd forgets the name in the background. Reusing the name too
  early fails with `Unit ... already exists`. That is issue #9.
- A **static unit** is a `.service` file shipped in the package. Its name never
  disappears, so a restart cannot clash with a leftover. Moving to static units
  is issue #11.
- A test plants a **leftover** with `systemd-run --unit=<name> --collect -- sleep 120`.
  The `sleep` only keeps the name taken. The fix stops it at once and waits a
  bounded time for the name to be released; it never waits the 120 s.

## Issue #9 / PR #12: wait for leftover transient units

- Issue: [#9 Startup fails on first attempt after service update](https://github.com/aosedge/aos_unit/issues/9)
- PR: [#12 fix: Wait for transient node units on restart](https://github.com/aosedge/aos_unit/pull/12)
- Our answer to the review: [comment, 29 Sep](https://github.com/aosedge/aos_unit/pull/12#issuecomment-5894602628)
- Package: PR #12. Script: [die-shutdown-order-matrix.sh](die-shutdown-order-matrix.sh)

**How the IDs work.** Requirements are `R<issue or PR>-<n>`. Tests are a
family letter plus a number: the letter says what the test disturbs, the
number is only the order inside the family. No test family uses `R`, so a
test ID never looks like a requirement.

| Family | What the test disturbs | Cases | Proves |
|---|---|---|---|
| H | The wait helper alone, no guests | H1–H8 | R12-4, R12-5 |
| G | Nothing: guests must boot first | G1 | precondition for every case below |
| P | Planned operator stop / restart | P1–P3 | R12-1 |
| D | Unplanned die: runner or QEMU killed | D1–D4 | R12-1 |
| L | Leftover transient unit at start | L1–L2 | R12-1; L2 also R9-1 |
| C | Failed unit left over, cleaned on stop | C1 | R12-1 |
| V | VM failure shapes | V1–V5 | R12-2 |
| N | dnsmasq failure shapes (the V list applied to dnsmasq) | N1–N4 | R12-3; N4 also R9-1 |
| O | Nothing: records the stop order as evidence | O1 | R12-1 |

**Clean cycle**, the pass bar shared by every P, D, L, C, V and N case: the
stop leaves no `aos-unit` units, bridge or taps; the journal shows
`Cleanup complete`; the next start succeeds on the first attempt with no
`already exists` / `already running` and no `Scheduled restart job`.

| Req | Requirement | Source | Tests | Pass when |
|---|---|---|---|---|
| R9-1 | A stale `aos-unit-dnsmasq` from the previous run must not fail the first start | [Issue #9](https://github.com/aosedge/aos_unit/issues/9) | L2; also N4 | Clean cycle, and the journal shows `Waiting for transient unit to unload` |
| R12-1 | Every die/shutdown order ends in a clean stop and a first-try start | [Review, "all die / shutdown order scenarios"](https://github.com/aosedge/aos_unit/pull/12#issuecomment-5313837030) | P1–P3, D1–D4, L1–L2, C1; O1 as evidence | Clean cycle |
| R12-2 | A VM that cannot start, or dies before the stop, still leaves a clean stop and start | [Review, "VM(s) unable to start / dies before kill"](https://github.com/aosedge/aos_unit/pull/12#issuecomment-5370336594) | V1–V5 | Clean cycle; a frozen QEMU restart finishes within 150 s |
| R12-3 | Same failure shapes for dnsmasq | [same comment, "same applied to dnsmasq"](https://github.com/aosedge/aos_unit/pull/12#issuecomment-5370336594) | N1–N4 | Clean cycle |
| R12-4 | The wait has a deadline, and a failed `systemctl show` is never read as "unit gone" | [Review, "The wait is unbounded"](https://github.com/aosedge/aos_unit/pull/12#issuecomment-5370825791) | H1–H6 | H5 gives up at its 3 s deadline; H6 returns non-zero when `systemctl show` fails |
| R12-5 | The wait helper does not reset the caller's SIGTERM trap | [Review, "It destroys an existing SIGTERM trap"](https://github.com/aosedge/aos_unit/pull/12#issuecomment-5370842836) | H7, H8 | Trap text is identical before and after; SIGTERM mid-wait runs the caller's trap |

These H1–H8 are the PR #12 helper cases. The Phase 3 helper suite has its own
numbering and is always cited as `T3.H (Hn)`.

What each test does:

| ID | Scenario |
|---|---|
| H1 | Wait for a `--collect` unit, then create the same name again |
| H2 | Wait stops a still-running transient unit |
| H3 | Wait clears a failed `--collect` unit |
| H4 | Wait returns at once when the unit is already gone |
| H5 | Wait on a unit that never stops: gives up at the deadline |
| H6 | `systemctl show` fails: the wait reports failure, not success |
| H7 | Caller's SIGTERM trap is unchanged after the wait |
| H8 | SIGTERM arrives during the wait: the caller's trap runs |
| G1 | Guests boot and answer ping (precondition for the cluster cases) |
| P1 / P2 / P3 | Stop then start / one restart / two restarts back to back |
| D1 / D2 | Runner gets SIGTERM / SIGKILL, then the service comes back |
| D3 / D4 | One / both QEMU processes killed, then the service restarts |
| L1 / L2 | Leftover `aos-unit-node-main` / `aos-unit-dnsmasq` at start |
| C1 | A failed leftover node unit is unloaded by cleanup on stop |
| V1 | Corrupt main image: VM cannot start; restore it, next start is clean |
| V2 | Guest quits by itself (QMP `quit`) before the stop |
| V3 | QEMU killed, manager stopped while the node is in auto-restart |
| V4 | Node hits its start limit (OnFailure fires), then manager restart |
| V5 | QEMU frozen with SIGSTOP: restart waits for the node SIGKILL |
| N1 / N2 | dnsmasq killed with SIGKILL / frozen with SIGSTOP, then restart |
| N3 | DNS port already taken: dnsmasq cannot start; free it, next start is clean |
| N4 | A failed `aos-unit-dnsmasq` left over at start |
| O1 | Records the stop order to `/tmp/aos-unit-matrix-stop-order.log` |

Run:

```bash
sudo bash tests/die-shutdown-order-matrix.sh --helpers-only   # H1-H8, ~1 min, no guests needed
sudo bash tests/die-shutdown-order-matrix.sh --cases "L1 L2"  # the issue #9 cases, ~3 min
sudo bash tests/die-shutdown-order-matrix.sh                  # everything, ~30-40 min
```

The matrix is also written to `/tmp/aos-unit-matrix-results.txt`.

## Issue #11 / PR #13: VMs as static template units

- Issue: [#11 Refactor aos-unit systemd architecture](https://github.com/aosedge/aos_unit/issues/11) (Phase 3)
- PR: [#13 feat(systemd): Phase 3 — VM template units](https://github.com/aosedge/aos_unit/pull/13)
- Review: ["This shall be reworked to lay the groundwork for redesign"](https://github.com/aosedge/aos_unit/pull/13#issuecomment-5371128694) (one comment, one bullet per requirement below)
- Package: PR #13, or PR #14 for the regression run.
  Scripts: [phase3-acceptance.sh](phase3-acceptance.sh), [phase3-helpers.sh](phase3-helpers.sh), [upgrade-acceptance.sh](upgrade-acceptance.sh), [package-checks.sh](package-checks.sh)

| Req | Requirement | Source bullet | Tests | Pass when |
|---|---|---|---|---|
| R13-1 | Keep `BindsTo=aos-unit.service`: a VM cannot outlive the manager | "Keep BindsTo" | T3.1, T3.2 | Every node is inactive after the manager stops |
| R13-2 | Remove `After=aos-unit.service`, which let systemd start a node before its env file existed | "Remove After=aos-unit.service" | T3.1, T3.2 | No `Failed to load environment files` or `Result: resources` in the journal across 2 + 10 restarts |
| R13-3 | The runner opens the node-start gate before launching and closes it when shutdown begins | "Introduce the node-start gate" | T3.3 | The gate file is absent every time a node is seen stopping |
| R13-4 | Template uses `ConditionPathExists=` for the env file and gate, optional `EnvironmentFile=-`, and `ExecCondition=` | same bullet | T3.1, T3.3 | Nodes start normally with the gate open; teardown is clean |
| R13-5 | Leave transient dnsmasq as it is in this PR | "Keep current transient dnsmasq behavior" | review | `git diff origin/main fork/feat/11-phase3-vm-template-units -- network-helper` shows no dnsmasq start changes |
| R13-6 | QEMU launch in `vm-launch`, per-node env files, CPU/RAM limits via `systemctl set-property --runtime` | "Move VM-specific launch logic into vm-launch" | T3.1 | Each node's cgroup `memory.max` and `cpu.max` match `unit_config.yaml` |
| R13-7 | Static units are waited on by `ActiveState`; only legacy transient units by `LoadState=not-found` | "Make static-node cleanup use ActiveState" | T3.H (H3, H4, H6, H7), T3.5 | Stopped static unit stays `loaded`; waits on it return inactive, never not-found |
| R13-8 | Migrate old transient `aos-unit-node-*` VMs to the new instances on upgrade | "Do not solve legacy transient migration unless required" | T3.6 | After `dpkg -i` over a running old package every node runs as `aos-unit-node@<name>`, `Transient=no`; no `aos-unit-node-*` loaded |
| R13-9 | VM restart policy decided against real failure shapes (`Restart=on-failure` kept) | [PR #14 review comment](https://github.com/aosedge/aos_unit/pull/14#issuecomment-5371342364), asks to decide it here | T3.4 (optional) | Matrix completes; teardown identical under both policies |
| R0-1 | Every wait is bounded (carried over from PR #12) | [PR #12 comment](https://github.com/aosedge/aos_unit/pull/12#issuecomment-5370825791) | T3.H (H2, H4) | Each times out within 4 s of a 3 s limit |
| R0-2 | Wait helpers never touch the caller's traps (from PR #12) | [PR #12 comment](https://github.com/aosedge/aos_unit/pull/12#issuecomment-5370842836) | T3.H (H5) | TERM trap text unchanged |
| R0-3 | Cleanup continues when the nft table is already gone | found while testing | T3.8 | `Cleanup complete` logged; bridge and taps removed |
| R13-P | Package scripts do not start or stop `aos-unit-node@` | implied by "BindsTo manager" ownership | T3.7 | No maintainer-script action on `aos-unit-node@` or `aos-unit-vm-failed@` |

What each test does:

| ID | Scenario |
|---|---|
| T3.1 | Start, restart twice, stop. Checks node state, `Transient=no`, QEMU as main process, cgroup limits, gate present while running, clean stop |
| T3.2 | 10 restarts in a row; every node comes back with a new PID and no restart counter |
| T3.3 | Stop without waiting and sample the gate while nodes stop. T3.3b starts one node by hand with the manager down and prints the outcome (`INFO` only) |
| T3.5 | Every node logs `Unregister VM` before `Cleanup complete`; with one guest frozen the stop still ends within 120 s |
| T3.8 | Delete the nft table, then stop: cleanup still completes |
| T3.H | Helper-only: transient and static throwaway units, timeouts, missing and failed units, trap preserved |
| T3.6 | Real upgrade from a running older package, then a planted `aos-unit-node-ghost` leftover |
| T3.7 | Extract the `.deb` maintainer scripts and grep them; optionally `dpkg -r` while running |
| T3.4 | Every VM failure shape (poweroff, exit 1, SIGSEGV, OOM, SIGKILL, ExecStartPre failure, ACPI timeout, manager stop, manager restart) under both restart policies |

Run (PR #13 installed):

```bash
sudo bash tests/phase3-helpers.sh                         # T3.H, ~1 min
sudo bash tests/phase3-acceptance.sh                      # T3.1 T3.2 T3.3 T3.5 T3.8, ~30 min
sudo bash tests/phase3-acceptance.sh T3.3                 # or one test
sudo bash tests/package-checks.sh ~/aos-debs/aos-unit_1.2.0~pr13+*.deb T3.7 --remove

# T3.6: upgrade from the release and from main
sudo KNOWN_V112_SELF_HEAL=1 bash tests/upgrade-acceptance.sh \
    ~/aos-debs/aos-unit_1.1.2+*.deb ~/aos-debs/aos-unit_1.2.0~pr13+*.deb T3.6

sudo bash tests/phase3-restart-matrix.sh on-failure       # T3.4, optional, ~1 h
```

## Issue #11 / PR #14: dnsmasq as a static unit

- Issue: [#11 Refactor aos-unit systemd architecture](https://github.com/aosedge/aos_unit/issues/11) (Phase 2)
- PR: [#14 feat(systemd): Phase 2 static dnsmasq unit](https://github.com/aosedge/aos_unit/pull/14), stacked on PR #13
- Package: PR #14. The static unit keeps the transient's name, `aos-unit-dnsmasq.service` (see "Same-name migration").
  Scripts: [phase2-acceptance.sh](phase2-acceptance.sh), [upgrade-acceptance.sh](upgrade-acceptance.sh), [phase2-preinst-stuck.sh](phase2-preinst-stuck.sh), [package-checks.sh](package-checks.sh), runner [run-14-dnsmasq-name-verify.sh](run-14-dnsmasq-name-verify.sh)

| Req | Requirement | Source | Tests | Pass when |
|---|---|---|---|---|
| R14-1 | No `PropagatesStopTo=`; `service-cleanup` is the only thing that stops dnsmasq | [Review, "PropagatesStopTo= violates the intended shutdown ordering"](https://github.com/aosedge/aos_unit/pull/14#issuecomment-5371230073) | T2.1, T2.2 | Each restart gives dnsmasq a new PID; stop is clean |
| R14-2 | Stop order is nodes, then dnsmasq, then the network: a running VM never loses DHCP | same comment | T2.2 | Journal: last node stopped before dnsmasq stops, dnsmasq stopped before `Removing bridge`; with a frozen guest dnsmasq stays active until that guest is gone |
| R14-3 | Migrate the old transient dnsmasq: check `Transient=yes`, stop it, bounded wait for `not-found`, then start the static unit | [Review, "upgrade from transient dnsmasq to static dnsmasq is not handled"](https://github.com/aosedge/aos_unit/pull/14#issuecomment-5371287028) | T2.3 (upgrade), T2.3c | `preinst` reports stopping the manager for the sidecar and no unload timeout. T2.3c: a transient that will not unload fails `preinst` with `did not unload within`, leaves the old package installed, and the retry succeeds |
| R14-4 | Real package upgrade: first start succeeds and the sidecar reports `Transient=no` | same comment | T2.3 (upgrade) | After `dpkg -i` over a running older package: `aos-unit-dnsmasq.service` active, `Transient=no`, packaged `FragmentPath`, no automatic manager restart |
| R14-5 | Debian maintainer scripts manage only `aos-unit.service` | [Review, "Debian must not independently manage aos-unit-dnsmasq.service"](https://github.com/aosedge/aos_unit/pull/14#issuecomment-5371307431) | T2.4 | The only unit named in the maintainer scripts is `'aos-unit.service'` |
| R14-6 | `dpkg-deb -e` plus grep finds no dnsmasq start/stop/restart | same comment | T2.4 | No maintainer-script action on `aos-unit-dnsmasq`; every `systemctl` verb targets `aos-unit.service` (`preinst` names the sidecar only to read its state); `dpkg -r` while running is clean |
| R14-7 | No VM lifecycle changes here: the gate and restart policy live in PR #13; the node template only gains `After=aos-unit-dnsmasq.service` | [Review, "Restart=on-abort and the node-start gate do not belong here"](https://github.com/aosedge/aos_unit/pull/14#issuecomment-5371342364) | review, T3.* on PR #14 | `git diff fork/feat/11-phase3-vm-template-units fork/feat/11-phase2-dnsmasq-static-unit -- aos-unit-node@.service` adds only that `After=`; PR #13 suite passes on the PR #14 package |
| R14-8 | Remaining transient machinery removed; dnsmasq failures still end clean | [Issue #11](https://github.com/aosedge/aos_unit/issues/11), "Next PR" list in the [PR #13 comment](https://github.com/aosedge/aos_unit/pull/13#issuecomment-5371128694) | T2.5 | Each failure shape ends in a clean stop and a clean next start |

**Same-name migration.** If `daemon-reload` runs while the transient
`aos-unit-dnsmasq` is loaded, the name stays bound to it; once it is collected
the name is `not-found` until the next `daemon-reload`, which the `aos-unit`
user cannot run ([probe-transient-shadow.sh](probe-transient-shadow.sh)). So
the review's steps run in `preinst upgrade`, before the unit file is unpacked:
if the sidecar is `Transient=yes`, stop `aos-unit.service` (the old release
tears down its own sidecar in its own order), then wait, bounded, for
`LoadState=not-found`. debhelper's `postinst` then reloads and restarts the
manager, which starts the packaged unit. No maintainer script starts, stops or
restarts the sidecar itself.

What each test does:

| ID | Scenario |
|---|---|
| T2.1 | Start, restart twice, stop. dnsmasq active, `Transient=no`, packaged file, new PID per restart, no automatic manager restart |
| T2.2 | Stop order from journal timestamps. T2.2b repeats with one guest frozen (SIGSTOP) |
| T2.3 | With the unit file installed, `systemd-run --unit=aos-unit-dnsmasq` is refused and the next start is clean. As an upgrade (`upgrade-acceptance.sh`): from a running v1.1.2, main or PR #13 package |
| T2.3c | `phase2-preinst-stuck.sh`: a transient `aos-unit-dnsmasq` that nothing stops makes `preinst` fail within its timeout; after it is gone the upgrade succeeds |
| T2.4 | Extract the `.deb` maintainer scripts and grep them; `dpkg -r` while running |
| T2.5 | dnsmasq SIGKILL (a), SIGSTOP at stop (b), DNS port taken (c), failed dnsmasq left over at start (d) |

Run (PR #14 installed):

```bash
sudo bash tests/phase2-acceptance.sh                      # T2.1 T2.2 T2.3 T2.5, ~30 min
sudo bash tests/phase2-acceptance.sh T2.5                 # one test (runs T2.5a–d)
sudo bash tests/package-checks.sh ~/aos-debs/aos-unit_1.2.0~pr14+*.deb T2.4 --remove

# T2.3 as a real upgrade, from the release and from PR #13
DNS="NEW_DNS_UNIT=aos-unit-dnsmasq.service EXPECT_DNSMASQ_TRANSIENT=no"
sudo env $DNS bash tests/upgrade-acceptance.sh \
    ~/aos-debs/aos-unit_1.1.2+*.deb ~/aos-debs/aos-unit_1.2.0~pr14+*.deb T2.3
sudo env $DNS BASELINE_NODES=static bash tests/upgrade-acceptance.sh \
    ~/aos-debs/aos-unit_1.2.0~pr13+*.deb ~/aos-debs/aos-unit_1.2.0~pr14+*.deb T2.3
sudo bash tests/phase2-preinst-stuck.sh \
    ~/aos-debs/aos-unit_1.1.2+*.deb ~/aos-debs/aos-unit_1.2.0~pr14+*.deb

# Everything above for one git ref, one result file per step
sudo bash tests/run-14-dnsmasq-name-verify.sh <ref>
```

## PR #15: local builds on WSL

- PR: [#15 fix(build): Support local builds on WSL drvfs](https://github.com/aosedge/aos_unit/pull/15). No review comments.

| Req | Requirement | Tests | Pass when |
|---|---|---|---|
| R15-1 | `./build_package.sh local <version>` works from a checkout on `/mnt/c` | manual | The `.deb` is built under `~/.cache/aos-unit-build` and the build prints its path |
| R15-2 | `network-helper` passes the CI formatter (`shfmt -s`) | S1 | `STATIC: PASS` |

## Regression: what to rerun

Run against the package of the PR being changed. A PR that builds on another
must also pass the earlier suite.

| Package | Must pass |
|---|---|
| Any PR | S1 [static-checks.sh](static-checks.sh), with that branch checked out (it checks tracked files): `bash tests/static-checks.sh "$PWD"` |
| PR #12 | `die-shutdown-order-matrix.sh` (all cases) |
| PR #13 | T3.H, T3.1–T3.3, T3.5, T3.8, T3.7, T3.6 |
| PR #14 | Everything for PR #13 **plus** T2.1–T2.5, T2.3 upgrades and T2.3c |

PR #12 is a separate line of work on the old transient design: its matrix does
not apply to the PR #13/#14 packages, and their suites do not apply to PR #12.

## Known journal noise (out of PR scope)

Real bugs on `main`, expected behaviour, or uninvestigated log lines — not
R12/R13/R14 failures. Full ledger: [issue11-traceability.md](issue11-traceability.md).

| ID | You may see | Disposition | Why |
|---|---|---|---|
| F-1 | Upgrade from v1.1.2: first new start fails `Bridge ... already exists`, systemd restarts once and it works | fix-later | Pre-existing on `main`: old `network.conf` lacks `DHCP_START`, cleanup aborts. Set `KNOWN_V112_SELF_HEAL=1`; those lines become `INFO` |
| F-2 | Rarely, `aos-unit.service` ends `failed` with runner exit 143 after a complete teardown, mostly in T2.5c (port taken) | fix-later | Pre-existing on `main`: SIGTERM during route-monitor `read`. Teardown is correct; rerun the case |
| F-3 | Stopping before guests have booted: nodes hit their 60 s stop timeout and log `VM unit FAILED (during manager stop)` | expected | By design. Scripts wait for guests to boot before stopping |
| F-4 | DNS port taken: manager stays active while dnsmasq crash-loops | fix-later | Pre-existing on `main`; stop still tears down cleanly |
| F-5 | dnsmasq `duplicate dhcp-host` during teardown | uninvestigated | Not classified |

## Scripts

| Script | Used for |
|---|---|
| [die-shutdown-order-matrix.sh](die-shutdown-order-matrix.sh) | PR #12: H1–H8, G/P/D/L/C/V/N/O cases |
| [phase3-acceptance.sh](phase3-acceptance.sh) | PR #13: T3.1, T3.2, T3.3, T3.5, T3.8 |
| [phase3-helpers.sh](phase3-helpers.sh) | PR #13/#14: T3.H |
| [phase3-restart-matrix.sh](phase3-restart-matrix.sh) | PR #13: T3.4 (optional) |
| [phase2-acceptance.sh](phase2-acceptance.sh) | PR #14: T2.1, T2.2, T2.3, T2.5 |
| [phase2-preinst-stuck.sh](phase2-preinst-stuck.sh) | PR #14: T2.3c preinst timeout on stuck transient |
| [run-14-dnsmasq-name-verify.sh](run-14-dnsmasq-name-verify.sh) | PR #14: sequential runner (upgrades, T2.3c, phase2/3) |
| [run-f1-upgrade-verify.sh](run-f1-upgrade-verify.sh) | PR #17: T3.6 upgrade from v1.1.2 without self-heal env |
| [upgrade-acceptance.sh](upgrade-acceptance.sh) | T3.6, T2.3 real package upgrades |
| [package-checks.sh](package-checks.sh) | T3.7, T2.4 maintainer scripts and `dpkg -r` |
| [static-checks.sh](static-checks.sh) | S1: shellcheck, shfmt, `systemd-analyze verify` |
| [build-deb.sh](build-deb.sh) | Build a `.deb` from any git ref |
| [lib-issue11.sh](lib-issue11.sh) | Shared helpers for the scripts above; not run directly |
