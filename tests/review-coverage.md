# Review coverage

For PR reviews only. Maps each review requirement to the test that proves it.
To **run** tests, use [README.md](README.md); it is organised by feature and
does not need anything from this file.

Requirement IDs are `R<issue or PR>-<n>`. Test names are the selectors the
scripts take (`L2`, `T3.1`, ...); README.md describes each one.

## Leftover transient units: issue #9, PR #12

- Issue: [#9 Startup fails on first attempt after service update](https://github.com/aosedge/aos_unit/issues/9)
- PR: [#12 fix: Wait for transient node units on restart](https://github.com/aosedge/aos_unit/pull/12)
- Our answer to the review: [comment, 29 Sep](https://github.com/aosedge/aos_unit/pull/12#issuecomment-5894602628)
- README area: [Leftover transient units at start](README.md#leftover-transient-units-at-start)

| Req | Requirement | Source | Tests | Pass when |
|---|---|---|---|---|
| R9-1 | A stale `aos-unit-dnsmasq` from the previous run must not fail the first start | [Issue #9](https://github.com/aosedge/aos_unit/issues/9) | L2; also N4 | Clean cycle, and the journal shows `Waiting for transient unit to unload` |
| R12-1 | Every die/shutdown order ends in a clean stop and a first-try start | [Review, "all die / shutdown order scenarios"](https://github.com/aosedge/aos_unit/pull/12#issuecomment-5313837030) | P1-P3, D1-D4, L1-L2, C1; O1 as evidence | Clean cycle |
| R12-2 | A VM that cannot start, or dies before the stop, still leaves a clean stop and start | [Review, "VM(s) unable to start / dies before kill"](https://github.com/aosedge/aos_unit/pull/12#issuecomment-5370336594) | V1-V5 | Clean cycle; a frozen QEMU restart finishes within 150 s |
| R12-3 | Same failure shapes for dnsmasq | [same comment, "same applied to dnsmasq"](https://github.com/aosedge/aos_unit/pull/12#issuecomment-5370336594) | N1-N4 | Clean cycle |
| R12-4 | The wait has a deadline, and a failed `systemctl show` is never read as "unit gone" | [Review, "The wait is unbounded"](https://github.com/aosedge/aos_unit/pull/12#issuecomment-5370825791) | H1-H6 | H5 gives up at its 3 s deadline; H6 returns non-zero when `systemctl show` fails |
| R12-5 | The wait helper does not reset the caller's SIGTERM trap | [Review, "It destroys an existing SIGTERM trap"](https://github.com/aosedge/aos_unit/pull/12#issuecomment-5370842836) | H7, H8 | Trap text is identical before and after; SIGTERM mid-wait runs the caller's trap |

## VMs as template units: issue #11 Phase 3, PR #13

- Issue: [#11 Refactor aos-unit systemd architecture](https://github.com/aosedge/aos_unit/issues/11)
- PR: [#13 feat(systemd): Phase 3 — VM template units](https://github.com/aosedge/aos_unit/pull/13)
- Review: ["This shall be reworked to lay the groundwork for redesign"](https://github.com/aosedge/aos_unit/pull/13#issuecomment-5371128694), one bullet per requirement below
- README areas: [VMs as template units](README.md#vms-as-template-units), [Package upgrade](README.md#package-upgrade), [Package install and remove](README.md#package-install-and-remove)

| Req | Requirement | Source bullet | Tests | Pass when |
|---|---|---|---|---|
| R13-1 | Keep `BindsTo=aos-unit.service`: a VM cannot outlive the manager | "Keep BindsTo" | T3.1, T3.2 | Every node is inactive after the manager stops |
| R13-2 | Remove `After=aos-unit.service`, which let systemd start a node before its env file existed | "Remove After=aos-unit.service" | T3.1, T3.2 | No `Failed to load environment files` or `Result: resources` across 2 + 10 restarts |
| R13-3 | The runner opens the node-start gate before launching and closes it when shutdown begins | "Introduce the node-start gate" | T3.3 | The gate file is absent every time a node is seen stopping |
| R13-4 | Template uses `ConditionPathExists=` for the env file and gate, optional `EnvironmentFile=-`, and `ExecCondition=` | same bullet | T3.1, T3.3 | Nodes start normally with the gate open; teardown is clean |
| R13-5 | Leave transient dnsmasq as it is in this PR | "Keep current transient dnsmasq behavior" | review | `git diff origin/main fork/feat/11-phase3-vm-template-units -- network-helper` shows no dnsmasq start changes |
| R13-6 | QEMU launch in `vm-launch`, per-node env files, CPU/RAM limits via `systemctl set-property --runtime` | "Move VM-specific launch logic into vm-launch" | T3.1 | Each node's cgroup `memory.max` and `cpu.max` match `unit_config.yaml` |
| R13-7 | Static units are waited on by `ActiveState`; only legacy transient units by `LoadState=not-found` | "Make static-node cleanup use ActiveState" | wait helpers, T3.5 | Stopped static unit stays `loaded`; waits on it return inactive, never not-found |
| R13-8 | Migrate old transient `aos-unit-node-*` VMs to the new instances on upgrade | "Do not solve legacy transient migration unless required" | upgrade T3.6 | Every node runs as `aos-unit-node@<name>`, `Transient=no`; no `aos-unit-node-*` loaded |
| R13-9 | VM restart policy decided against real failure shapes (`Restart=on-failure` kept) | [PR #14 review comment](https://github.com/aosedge/aos_unit/pull/14#issuecomment-5371342364), asks to decide it here | restart policy matrix | Matrix completes; teardown identical under both policies |
| R0-1 | Every wait is bounded (carried over from PR #12) | [PR #12 comment](https://github.com/aosedge/aos_unit/pull/12#issuecomment-5370825791) | wait helpers | Each times out within 4 s of a 3 s limit |
| R0-2 | Wait helpers never touch the caller's traps (from PR #12) | [PR #12 comment](https://github.com/aosedge/aos_unit/pull/12#issuecomment-5370842836) | wait helpers | TERM trap text unchanged |
| R0-3 | Cleanup continues when the nft table is already gone | found while testing | T3.8 | `Cleanup complete` logged; bridge and taps removed |
| R13-P | Package scripts do not start or stop `aos-unit-node@` | implied by "BindsTo manager" ownership | package checks T3.7 | No maintainer-script action on `aos-unit-node@` or `aos-unit-vm-failed@` |

## dnsmasq as a static unit: issue #11 Phase 2, PR #14

- Issue: [#11 Refactor aos-unit systemd architecture](https://github.com/aosedge/aos_unit/issues/11)
- PR: [#14 feat(systemd): Phase 2 static dnsmasq unit](https://github.com/aosedge/aos_unit/pull/14), stacked on PR #13
- README areas: [dnsmasq as a static unit](README.md#dnsmasq-as-a-static-unit), [Package upgrade](README.md#package-upgrade), [Package install and remove](README.md#package-install-and-remove)

| Req | Requirement | Source | Tests | Pass when |
|---|---|---|---|---|
| R14-1 | No `PropagatesStopTo=`; `service-cleanup` is the only thing that stops dnsmasq | [Review, "PropagatesStopTo= violates the intended shutdown ordering"](https://github.com/aosedge/aos_unit/pull/14#issuecomment-5371230073) | T2.1, T2.2 | Each restart gives dnsmasq a new PID; stop is clean |
| R14-2 | Stop order is nodes, then dnsmasq, then the network: a running VM never loses DHCP | same comment | T2.2 | Last node stopped before dnsmasq stops, dnsmasq stopped before `Removing bridge`; with a frozen guest dnsmasq stays active until that guest is gone |
| R14-3 | Migrate the old transient dnsmasq: check `Transient=yes`, stop it, bounded wait for `not-found`, then start the static unit | [Review, "upgrade from transient dnsmasq to static dnsmasq is not handled"](https://github.com/aosedge/aos_unit/pull/14#issuecomment-5371287028) | upgrade T2.3, T2.3c | `preinst upgrade` stops `aos-unit.service` and waits, bounded, for the transient to unload before the unit file lands; a transient that will not unload fails `preinst` with `did not unload within` and keeps the old package |
| R14-4 | Real package upgrade: first start succeeds and the sidecar reports `Transient=no` | same comment | upgrade T2.3 | `aos-unit-dnsmasq.service` active, `Transient=no`, packaged `FragmentPath`, no automatic manager restart |
| R14-5 | Debian maintainer scripts manage only `aos-unit.service` | [Review, "Debian must not independently manage aos-unit-dnsmasq.service"](https://github.com/aosedge/aos_unit/pull/14#issuecomment-5371307431) | package checks T2.4 | The only unit named in the maintainer scripts is `'aos-unit.service'` |
| R14-6 | `dpkg-deb -e` plus grep finds no dnsmasq start/stop/restart | same comment | package checks T2.4 | No maintainer-script action on `aos-unit-dnsmasq`; every `systemctl` verb targets `aos-unit.service`; `dpkg -r` while running is clean |
| R14-7 | No VM lifecycle changes here: the gate and restart policy live in PR #13; the node template only gains `After=aos-unit-dnsmasq.service` | [Review, "Restart=on-abort and the node-start gate do not belong here"](https://github.com/aosedge/aos_unit/pull/14#issuecomment-5371342364) | review; VM template suite on the PR #14 package | `git diff fork/feat/11-phase3-vm-template-units fork/feat/11-phase2-dnsmasq-static-unit -- aos-unit-node@.service` adds only that `After=` |
| R14-8 | Remaining transient machinery removed; dnsmasq failures still end clean | [Issue #11](https://github.com/aosedge/aos_unit/issues/11), "Next PR" list in the [PR #13 comment](https://github.com/aosedge/aos_unit/pull/13#issuecomment-5371128694) | T2.5 | Each failure shape ends in a clean stop and a clean next start |

**Same-name migration.** The static unit keeps the name
`aos-unit-dnsmasq.service`. The review's steps run in `preinst upgrade`, not at
runtime: a `daemon-reload` while the transient is loaded keeps the name bound
to it until the next reload, which the `aos-unit` user cannot run. See
[README.md](README.md#issue-11--pr-14-dnsmasq-as-a-static-unit).

## Local builds on WSL: PR #15

- PR: [#15 fix(build): Support local builds on WSL drvfs](https://github.com/aosedge/aos_unit/pull/15). No review comments.

| Req | Requirement | Tests | Pass when |
|---|---|---|---|
| R15-1 | `./build_package.sh local <version>` works from a checkout on `/mnt/c` | [Local build on WSL](README.md#local-build-on-wsl) | The `.deb` is built under `~/.cache/aos-unit-build` and the build prints its path |
| R15-2 | `network-helper` passes the CI formatter (`shfmt -s`) | [Code style and unit files](README.md#code-style-and-unit-files) | `STATIC: PASS` |
