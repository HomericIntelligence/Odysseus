# Runbook: AlexNet Training Across the Tailscale Mesh

## Objective

Run Project Odyssey's AlexNet CIFAR-10 training **independently on each host** of the
HomericIntelligence Tailscale mesh, sharing a single built container image distributed
via `rsync` over the WireGuard mesh. Each host performs its own training job inside a
rootless Podman container; results are rsync'd back to a central host for comparison.

This is **NOT distributed training** (no cross-host gradient sync). It is embarrassingly
parallel: one AlexNet fit per host, useful as a hyperparameter sweep and as a benchmark
of "the same workload on different hardware."

> **Why not actual distributed training?** Odyssey's Mojo training loop is a single
> process — there is no data-parallel gradient sync or allreduce in the codebase.
> Wiring that up over NATS would be new engineering. This runbook covers the much
> simpler "run the same training N times in parallel" case.

## Hosts (historical inventory)

The host names, hardware, versions, reachability observations, and dated results in
this runbook are historical evidence, not a live inventory or authorization to
operate on those hosts. Before a new fleet run, bind the exact intended host set and
immutable checkout revision, obtain live readback for every prerequisite on every target, and
get operator approval for that exact host set and planned mutation delta. A missing,
stale, or unreachable host blocks that host; do not infer its current state from the
observations below.

| Host | Role | CPU | SIMD | Notes |
|------|------|-----|------|-------|
| **epimetheus** | Build / distribution hub | i5-6600K (Skylake) | AVX2 | Historical observation: source-built Podman 5.8.1 verified rootless; firewalld zone changed 2026-04-06. |
| **apollo** | Training target | i7-8565U (Whiskey Lake) | AVX2+VNNI | Historical observation: HomelabOS with Docker and coexisting Podman. The recorded host Python version did not affect the container runtime. |
| **aeolus** | Training target | i7-3820 (Sandy Bridge-E) | **AVX only** | 2012 silicon. Mojo JIT may emit AVX2; script auto-strips via `--target-features -avx2`. |
| **hephaestus** | Training target | Unknown | Unknown | No hardware state was recorded; bind and verify it live before use. |
| **hermes** | Training target | Intel Core Ultra 7 258V (Lunar Lake) | AVX2 | Historical observation: the May-2026 survey ran Mojo without a `--target-features` strip; a preflight was recorded 2026-05-12 and offline state was observed 2026-08-07. |

## Prerequisites (per host)

Each target host must satisfy the rootless Podman prerequisite chain documented in
`e2e/doctor.sh`. Start with read-only topology verification after binding the exact
host. Installation and service-start effects require approval for the exact target
and delta. `--install` does **not** change firewall policy. Firewall changes use a
separate deployment-owned least-privilege procedure after current policy readback
and explicit approval.

```bash
# 1. Bind and verify one selected peer; repeat for every approved peer
cd ~/Projects/Odysseus
: "${TARGET_TAILSCALE_IP:?set one operator-verified literal peer IP}"
just doctor --role worker --cross-host --worker-ip "$TARGET_TAILSCALE_IP"

# 2. User linger (required for rootless systemd services)
sudo loginctl enable-linger $USER

# 3. Install Podman if absent
sudo apt-get install -y podman podman-compose slirp4netns uidmap

# 4. Enable Podman socket (export XDG/DBUS env vars first — SSH sessions lack both)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
systemctl --user enable --now podman.socket

# 5. Install other missing local prerequisites for the approved target and delta
just doctor --role worker --install
```

`just doctor --cross-host --capability-only` verifies only local Tailscale
capability; it is not topology proof. The doctor never applies broad
whole-interface firewall trust.

If the selected Podman package does not provide its user service units,
`doctor.sh` fails closed. Repair or replace that package through an
operator-approved package-management procedure, then rerun the read-only doctor;
the repository does not synthesize system service definitions from source trees.

## Known Rootless Gotchas (All Mitigated by the Scripts)

| Issue | Reference | Mitigation |
|-------|-----------|-----------|
| `rootlessport` missing → `podman compose` hangs at `podman wait --condition=healthy` | `docs/e2e-walkthrough-report.md` | Scripts use `podman run --network=host`, never `podman compose` for the training container |
| Stale conmon holding libpod lock | `docs/e2e-walkthrough-report.md` | Killed by the doctor check; defensive container removal in `alexnet-train.sh` |
| UID mismatch on bind-mount (rootless) | `shared/Mnemosyne/skills/mesh-dispatch-pipeline-debugging.md` | All `podman run` invocations use `--userns=keep-id` |
| Firewalld blocked Tailscale traffic in the 2026-04-06 epimetheus observation | `shared/Mnemosyne/skills/e2e-crosshost-doctor-prerequisite-checker.md` | Bind exact listeners and peers, then use an operator-owned least-privilege firewall procedure with rollback and post-state readback |
| `systemctl --user` fails over SSH | `e2e/doctor.sh` step 8 | Export `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS`; ensure linger |

## Rollout Sequence

### Phase 1: Validate on epimetheus

Epimetheus was the most-prepared host in the recorded observation (Podman 5.8.1 and
the then-current firewalld zone were verified). Rebind it live before choosing it as
the build or distribution hub.

```bash
# On epimetheus
cd ~/Projects/Odysseus
: "${TARGET_TAILSCALE_IP:?set one operator-verified literal peer IP}"
just doctor --role worker --cross-host --worker-ip "$TARGET_TAILSCALE_IP"

# Smoke test — 3 batches of synthetic data, ~60 seconds
just alexnet-smoke
```

**Smoke-test expectations — `podman logs` is the single source of truth.**
`alexnet-train.sh` launches the training container **detached** (`podman run -d`), so
`just alexnet-smoke` returns immediately. All training output — per-batch loss, epoch
progress, final metrics, and the completion marker — streams to the **container log
driver**. `training.log` under
`~/alexnet-results/runs/<run-id>/<host>/` holds **only the launch header**
(configuration summary). The run itself is never written there. The launcher
prints the run ID. Monitor and verify via `podman logs`:

```bash
# Stream live output
podman logs -f alexnet-training

# Quick peek — prints the lines matching any of these markers
podman logs alexnet-training 2>/dev/null | grep -E "Batch \[1/3\]|Training complete!|Average Loss|Test Accuracy:"
# For a detailed manual smoke review, verify each marker and the process exit:
#  1. "Batch [1/3] - Loss: ..."   — first batch ran (smoke mode = 3 batches)
#  2. "Average Loss: ..."         — final loss printed
#  3. "Test Accuracy: ..."        — evaluation completed
#  4. "Training complete!"        — the terminal marker
#  5. container exited 0:
podman inspect alexnet-training --format '{{.State.Status}} exit={{.State.ExitCode}}'
#     exited exit=0
# The fleet wait gate enforces the exact run ID, result mount, exit 0, and
# "Training complete!" marker. Full runs also require a current-run weight.
# It does not enforce the Batch, Average Loss, or Test Accuracy text.

# Full training run (use the exact run ID printed by the smoke launch)
FLEET=localhost ALEXNET_TEARDOWN_APPROVED_FLEET=localhost \
  ALEXNET_RUN_ID="paste-exact-smoke-run-id" \
  just alexnet-fleet-teardown
EPOCHS=100 BATCH_SIZE=128 just alexnet-train
```

### Phase 2: Launch fleet from epimetheus

After the epimetheus smoke test passes, deploy to the full fleet:

```bash
# On epimetheus
cd ~/Projects/Odysseus

# Bind one exact fleet, then run the live read-only preflight. A dry run still
# reads current Tailscale and remote-host state, but makes no target changes.
FLEET="epimetheus apollo aeolus hephaestus" \
  DRY_RUN=1 just alexnet-fleet-deploy

# Full fleet smoke run (3 batches each)
FLEET="epimetheus apollo aeolus hephaestus" \
  ALEXNET_DEPLOY_APPROVED_FLEET="epimetheus apollo aeolus hephaestus" \
  EPOCHS=10 MAX_BATCHES=3 just alexnet-fleet-deploy
# Builds the image, distributes it to apollo/aeolus/hephaestus over Tailscale,
# and launches 4 training jobs in parallel. Hermes is opt-in only after its
# exact live prerequisites and target approval are established.
#
# Fleet smoke expectations are per-host and identical to Phase 1: each host's
# container log is the single source of truth — check every host with
#   ssh <host> 'podman logs alexnet-training 2>/dev/null | grep -E "Training complete!|Average Loss|Test Accuracy:"'
# The wait gate automates the run identity, exit, terminal-marker, and weight
# checks. The loss and accuracy lines remain manual review data.

# Before starting full training, wait for every smoke container, collect its
# evidence, and remove only that exact approved smoke run. Stop if any step
# fails; do not bypass the launcher's existing-container check.
FLEET="epimetheus apollo aeolus hephaestus" \
  ALEXNET_RUN_ID="paste-exact-smoke-run-id" just alexnet-fleet-wait
FLEET="epimetheus apollo aeolus hephaestus" \
  ALEXNET_RUN_ID="paste-exact-smoke-run-id" just alexnet-fleet-collect
FLEET="epimetheus apollo aeolus hephaestus" \
  ALEXNET_TEARDOWN_APPROVED_FLEET="epimetheus apollo aeolus hephaestus" \
  ALEXNET_RUN_ID="paste-exact-smoke-run-id" just alexnet-fleet-teardown
# Require successful exact-run teardown before proceeding. Preserve collected
# smoke evidence; the next deployment allocates a fresh run ID.

# Full training run
FLEET="epimetheus apollo aeolus hephaestus" \
  ALEXNET_DEPLOY_APPROVED_FLEET="epimetheus apollo aeolus hephaestus" \
  EPOCHS=100 just alexnet-fleet-deploy
```

Image distribution uses an invocation-unique local archive and remote staging
directory under `~/.cache/odysseus-alexnet/<run-id>/`. Each transfer and image
load must produce the exact image identity from the initiating host. Deployment
retains remote invocation artifacts because a later pathname cleanup cannot
atomically prove object identity. The persistent remote tools are the verified
launcher and result-filesystem helper under `~/alexnet-fleet-scripts/`.
This retention also lets a later `SKIP_BUILD=1` run use the verified tools.
Collection and fleet orchestration remain on the initiating host. Each run
writes to `~/alexnet-results/runs/<run-id>/<host>/`. The initiating host records
the latest deployment run ID under `~/.cache/odysseus-alexnet/`. You can also
set `ALEXNET_RUN_ID` explicitly for the deploy, wait, and collect commands.

### Phase 3: Per-host monitoring

While the fleet trains, monitor each host independently:

```bash
# Stream individual host logs
podman logs -f alexnet-training                             # epimetheus
for h in apollo aeolus hephaestus; do
    ssh "$h" "podman logs -f alexnet-training"
done

# Check final loss summaries — markers live in each host's container log,
# not in training.log (which only carries the launch header)
for host in epimetheus apollo aeolus hephaestus; do
    echo "── $host ──"
    if [[ "$host" == "$(hostname)" ]]; then
        podman logs alexnet-training 2>/dev/null | grep -E "Average Loss|Test Accuracy" | tail -5
    else
        ssh "$host" "podman logs alexnet-training 2>/dev/null | grep -E 'Average Loss|Test Accuracy' | tail -5"
    fi
done
```

### Phase 4: Collect results centrally

Once all training jobs finish, aggregate:

```bash
# On epimetheus
just alexnet-fleet-collect
# Or with a custom central directory
CENTRAL_DIR=~/alexnet-fleet-results-$(date +%Y%m%d) just alexnet-fleet-collect
```

The collection script copies each host's exact
`~/alexnet-results/runs/<run-id>/<hostname>/` tree over Tailscale. It rejects
links and special nodes before publication and requires the launch header to
name that exact run ID. Its receipt reports the file count, bound launch-header
presence, and weight count. It does not claim training completion or print
container-log excerpts. Run the wait gate before collection for completion
evidence. If one current-run transfer fails, the script keeps only the verified
safe current-run trees for forensics and exits nonzero.

### Wait + gate (CI and scripted runs)

`e2e/alexnet-deploy-fleet.sh` launches training **detached** and returns immediately.
For scripted or CI runs that need to block until the fleet finishes and verify
completion, use the gate wrapper:

```bash
# Blocks until every host's alexnet-training container exits (150 min default),
# then binds and revalidates the immutable container ID, exact run label and
# result mount, exit 0, and "Training complete!" from that ID's Podman log.
# Full runs also need a weight created
# after the current launch header. Exits nonzero if any host fails.
just alexnet-fleet-wait

# Shorter deadline, or wait-only (skip the completion gate)
just alexnet-fleet-wait --timeout-minutes 90
just alexnet-fleet-wait --no-gate
```

## Protected workflow-dispatch routes are currently unavailable

Do **not** dispatch `.github/workflows/alexnet-mesh-smoke.yml` or
`.github/workflows/alexnet-mesh-chaos.yml` in their current revisions. Both
protected callers predate the hardened script approval interfaces and cannot
provide valid operation authority:

- The smoke caller does not bind `ALEXNET_DEPLOY_APPROVED_FLEET` to its exact
  requested fleet and still invokes teardown through the retired broad
  `FORCE=1` path instead of providing `ALEXNET_TEARDOWN_APPROVED_FLEET` and the
  exact `ALEXNET_RUN_ID`.
- The chaos caller does not bind `ALEXNET_CHAOS_APPROVED_HOST` to the runner's
  exact hostname. It also cannot supply the separate exact approvals required
  by any enabled network or offline-host branch.

The scripts therefore fail closed when called by these workflow revisions; a
dispatched run is not fleet-validation evidence. The workflow files are
protected and remain unchanged pending a separately approved repair that
passes caller-interface fixtures and exact-head CI. Until that repair lands,
CI/CD coverage for this area is limited to the repository's hermetic mocked
behavior tests. It does not establish live topology, Tailscale reachability, or
fleet success.

Direct operator invocation remains a distinct path. It requires a freshly
bound literal host or fleet, live prerequisite readback on an authorized mesh
host, and the matching exact approval variables documented by each script.
Do not attempt that path on a host without Tailscale or the authorized fleet
context.

## Per-Host Notes

### aeolus (Sandy Bridge-E — most challenging)

The 2012-era silicon has **AVX only — no AVX2**. The Mojo JIT may detect a wider SIMD
baseline than the CPU supports and SIGILL. `e2e/alexnet-train.sh` detects this via
hostname and adds `--target-features -avx2,-avx512*` automatically.

If a future aeolus upgrade replaces the CPU with an AVX2-capable chip, override with:

```bash
FORCE_AVX2=1 EPOCHS=10 just alexnet-train
```

If the script fails with SIGILL on aeolus despite the auto-strip, run the diagnostic
listed in the May-2026 cross-CPU survey blog post:

```bash
# On aeolus
podman run --rm --userns=keep-id \
    -v "$HOME/Projects/Odysseus/research/Odyssey:/workspace:Z" \
    -w /workspace \
    odyssey:dev \
    pixi run mojo build --print-effective-target \
        -I src examples/alexnet_cifar10/model.mojo 2>&1 | grep target-features
```

If the output still shows `+avx2`, the workaround is not taking effect — escalate to
manual `--target-features` flags inside the container.

### apollo (Docker coexistence)

At the time of the recorded observation, Apollo ran Docker (HomelabOS). Recheck that
state before use. Podman and Docker can coexist, but their storage and network stacks
are separate. The training script uses `podman` commands exclusively and does not
interact with the Docker daemon.

The host's Python 3.7 is irrelevant — the Odyssey container provides Python 3.12 via pixi.

### hephaestus (fresh host)

If hephaestus has never been configured:

```bash
ssh hephaestus
cd ~/Projects/Odysseus   # or clone: git clone --recurse-submodules https://github.com/HomericIntelligence/Odysseus
just doctor --role worker --install  # approved local dependency/service effects only
```

Cross-host proof is performed separately against each exact peer IP. Firewall
policy remains an operator-owned, least-privilege deployment procedure.

Verify SIMD before launching:

```bash
grep -E "model name|flags" /proc/cpuinfo | head -5
# Check for avx, avx2, and avx512f flags. If the detected target is not safe,
# stop and change the reviewed launcher policy. The launcher owns
# MOJO_TARGET_FLAGS. FORCE_AVX2=1 disables the Aeolus strip only after a
# verified hardware upgrade.
```

### hermes (Lunar Lake — new fleet member as of 2026-05-12)

The historical inventory recorded an Intel Core Ultra 7 258V (Lunar Lake,
late-2024 silicon), **15.4 GB** kernel-reported RAM (16 GB physical), 8 cores,
353 GB free disk, Podman 5.8.3, and WSL2 Linux
6.6.87.2-microsoft-standard-WSL2. Rebind each fact live. If Hermes remains a WSL2
host, it must satisfy both the rootless-Podman chain and the WSL2 systemd chain
(`[boot] systemd=true` in `/etc/wsl.conf` plus linger).

**Historical status (checked 2026-08-11): hermes was offline on the tailnet** — it
was last seen 2026-08-07, with no ping/SSH response from epimetheus. That observation
does not establish current state. The 2026-05-12 preflight probes could not be re-run
then. The pattern evidence below is from **apollo** (the documented same-blocker
host), as observed on 2026-08-11:

```
$ cat /proc/sys/kernel/unprivileged_userns_clone
0
$ podman info
cannot clone: Operation not permitted
user namespaces are not enabled in /proc/sys/kernel/unprivileged_userns_clone
```

| Preflight check | Result (2026-05-12) | What to investigate |
|-----------------|---------------------|---------------------|
| `/proc/sys/kernel/unprivileged_userns_clone` (user-mode read) | `(unreadable)` | On some kernels the sysctl hides itself from unprivileged users when the value is `0`. Likely same kernel blocker as apollo (confirmed `0` above). Verify with `sudo cat /proc/sys/kernel/unprivileged_userns_clone`. |
| `podman info` | **FAILED** | Could not verify cgroups / graph driver. Same root cause as the sysctl above (rootless user-namespace clone disabled). If confirmed at `0`, deploy Phase 2 (`podman load`) will fail with `cannot clone` — identical to apollo. |
| SSH from epimetheus | **Not configured** (2026-08-11) | Hermes has **no SSH server in WSL2** — not in epimetheus `~/.ssh/config` or `known_hosts`. Fleet deploy uses `ssh <ip> <cmd>` for every remote host, so this is a **second, independent blocker**. Install `openssh-server` in WSL, start sshd, then `ssh-copy-id hermes` from epimetheus. |
| Podman version | 5.8.3 | OK. |
| Odyssey workspace (`research/Odyssey`) | Absent before 2026-05-12 onboarding | After meta-repo sync: `git submodule update --init --recursive`. |

**Remediation boundary:** changing Hermes user namespaces, WSL2 services, or SSH
state is not exposed as a generic fleet command. Bind the exact live host state.
Review an exact change delta and rollback with the host operator. Then use the
operator-owned host procedure. No repository script authorizes this host repair.

**If `kernel.unprivileged_userns_clone=0`**, hermes has the same blocker as apollo
and the deploy will fail at image load. Operator options:

1. **Use the reviewed operator-owned remediation** for the exact host, delta,
   rollback, and post-change readback.
2. **Keep Hermes out of the active fleet** (the default already excludes it) until
   both blockers are verified clear. If an exact subset is needed, run
   `FLEET="epimetheus apollo aeolus hephaestus" just alexnet-fleet-deploy`.

**If `kernel.unprivileged_userns_clone=1`** (and SSH is reachable), hermes should work
like epimetheus with no further remediation. `e2e/alexnet-train.sh`'s per-host CPU-flag
block has only an `aeolus` exclusion; hermes (Lunar Lake) keeps the default empty
`MOJO_TARGET_FLAGS`.

## Verification Checklist

- [ ] **All peer paths**: `just doctor --role worker --cross-host --worker-ip "$TARGET_TAILSCALE_IP"` passes for each freshly bound literal peer IP
- [ ] **All hosts**: `podman --version` reports a rootless-mode install
- [ ] **All hosts**: `podman logs alexnet-training` shows `Batch [1/3]`, `Average Loss`, `Test Accuracy:`, and ends with `Training complete!`; container `ExitCode=0` (ssh each remote host; `training.log` only carries the launch header — `podman logs` is the single source of truth)
- [ ] **epimetheus**: Image built via `podman compose build odyssey-dev` (or `podman build` fallback)
- [ ] **Apollo/aeolus/hephaestus**: Image received via `rsync` and `podman load -i` succeeded
- [ ] **Apollo/aeolus/hephaestus**: The verified launcher and result helper are installed under `~/alexnet-fleet-scripts/`; invocation staging is retained for a separate, reviewed cleanup
- [ ] **Central collection**: `just alexnet-fleet-collect` prints a complete summary

## Teardown & Recovery

If `just alexnet-fleet-deploy` was interrupted mid-fleet (say aeolus SIGILL'd after
apollo already launched), you have orphaned `alexnet-training` containers consuming
RAM on the partial launches. Use the teardown recipe to clean up fleet-wide:

```bash
# On epimetheus (then type the displayed exact fleet interactively)
ALEXNET_RUN_ID="paste-exact-run-id" just alexnet-fleet-teardown

# Non-interactive teardown binds approval to the exact run and requested fleet
FLEET="epimetheus apollo aeolus hephaestus" \
  ALEXNET_TEARDOWN_APPROVED_FLEET="epimetheus apollo aeolus hephaestus" \
  ALEXNET_RUN_ID="paste-exact-run-id" \
  just alexnet-fleet-teardown
```

What this script does:

| Step | Action |
|------|--------|
| 1 | Validate the exact run and fleet approval, then resolve every target before mutation |
| 2 | Bind `alexnet-training` to the approved run label, result mount, and immutable container ID; revalidate it, remove by ID, then verify both the ID and name are absent |
| 3 | Emit a terminal `removed` or `absent` receipt for every requested host; any resolution, transport, Podman, or postcondition failure fails the operation |
| 4 | Preserve the installed launcher and all `~/alexnet-results/runs/<run-id>/<hostname>/` trees |

The recipe **does not delete** training results or the installed launcher. Their
retention or removal requires a separate procedure with an exact target,
reviewed path set, rollback or recovery plan, and operator approval.

## Comparison Metrics to Capture

After the fleet run completes, useful per-host comparisons. Training output is
captured by each host's container log driver, so the metric commands read
`podman logs` (run the `ssh "$host" "..."` form for remote hosts):

| Metric | Where to find it |
|--------|-----------------|
| Epoch time (s) | `podman logs alexnet-training \| grep "Epoch \["` (parse the wall-clock between epochs) |
| Final loss | `podman logs alexnet-training \| grep "Average Loss" \| tail -1` |
| Final test accuracy | `podman logs alexnet-training \| grep "Test Accuracy:" \| tail -1` |
| Container memory peak | `podman stats --no-stream alexnet-training` while running |
| Mojo version | First `podman logs alexnet-training` line emitted at container start |
| CPU utilization | `grep "model name" /proc/cpuinfo` + `nproc` |

## Related Skills

- `shared/Mnemosyne/skills/homeric-crosshost-deployment-and-mesh-topology.md` — cross-host
  NATS/Agamemnon deployment (the mesh plumbing this runbook depends on)
- `shared/Mnemosyne/skills/e2e-crosshost-doctor-prerequisite-checker.md` — the doctor
  checker this runbook calls; documents the firewalld `tailscale0` zone fix
- `shared/Mnemosyne/skills/multi-repo-governance-and-ecosystem-setup.md` — the
  Tailnet fan-out pattern used for `rsync` distribution
- `notes/blog/05-12-2026/README.md` — the cross-CPU survey proving the Intel fleet
  runs the Mojo-built binary without SIGILL (this runbook's safety case)

## Limitations & Future Work

This runbook does NOT cover:

1. **Distributed training** — implementing Mojo allreduce / data-parallel gradient sync
   over NATS would enable a true multi-host training speedup. Significant engineering:
   new code in `research/Odyssey`, plus a coordinator process.
2. **GPU acceleration** — all training is CPU-only. Adding CUDA/Metal would require
   image build changes plus per-host driver setup (Tailscale works fine for GPU
   hosts; the constraint is container → device passthrough).
3. **Live result streaming** — training output is captured by each host's
   container log driver (`podman logs alexnet-training`). Collection copies the
   safe regular files in the exact current-run result tree, including weights
   and the launch-header `training.log`, but not the container log stream. A
   NATS-based streaming path (publish
   `hi.research.alexnet.<host>.progress` per batch) would enable real-time
   dashboards via Argus.
4. **Cross-host dataset sync** — CIFAR-10 (~170MB) is downloaded per host if absent.
   Pre-staging to a Tailscale-mounted NAS would skip the per-host download.

For any of these, file an issue against the `Odysseus` repo referencing this runbook.
