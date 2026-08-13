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

## Hosts

| Host | Role | CPU | SIMD | Notes |
|------|------|-----|------|-------|
| **epimetheus** | Build / distribution hub | i5-6600K (Skylake) | AVX2 | Source-built Podman 5.8.1 already verified rootless. Firewalld zone fix applied 2026-04-06. |
| **apollo** | Training target | i7-8565U (Whiskey Lake) | AVX2+VNNI | HomelabOS host. Docker installed but coexisting Podman works. Python 3.7 is irrelevant — container has Python 3.12+. |
| **aeolus** | Training target | i7-3820 (Sandy Bridge-E) | **AVX only** | 2012 silicon. Mojo JIT may emit AVX2; script auto-strips via `--target-features -avx2`. |
| **hephaestus** | Training target | Unknown | Unknown | Run `just install-worker` first; verify SIMD via `/proc/cpuinfo`. |
| **hermes** | Training target | Intel Core Ultra 7 258V (Lunar Lake) | AVX2 | Modern 2024 silicon. Per the May-2026 cross-CPU survey, runs Mojo cleanly without `--target-features` strip. Preflight investigation flagged 2026-05-12; host offline since 2026-08-07 (see Per-Host Notes). |

## Prerequisites (per host)

Each target host must satisfy the rootless Podman prerequisite chain tested on
epimetheus and documented in `e2e/doctor.sh`. The canonical setup is:

```bash
# 1. Tailscale (already on all hosts per multi-repo-governance skill)
tailscale status | grep -E "$(hostname)"

# 2. User linger (required for rootless systemd services)
sudo loginctl enable-linger $USER

# 3. Install Podman if absent
sudo apt-get install -y podman podman-compose slirp4netns uidmap

# 4. Enable Podman socket (export XDG/DBUS env vars first — SSH sessions lack both)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
systemctl --user enable --now podman.socket

# 5. Firewalld zone fix (hosts running firewalld — Debian 11+, RHEL, Fedora)
sudo firewall-cmd --permanent --zone=trusted --add-interface=tailscale0
sudo firewall-cmd --reload

# 6. Full prerequisite verification (auto-installs missing deps with --install)
cd ~/Projects/Odysseus && just doctor --role worker --install
```

If podman was installed from source rather than apt, `doctor.sh` handles the missing
systemd unit files (searches `~/.local/src/podman-*/contrib/systemd/user/` and processes
the `podman.service.in` template with `sed "s|@@PODMAN@@|$(command -v podman)|g"`).

## Known Rootless Gotchas (All Mitigated by the Scripts)

| Issue | Reference | Mitigation |
|-------|-----------|-----------|
| `rootlessport` missing → `podman compose` hangs at `podman wait --condition=healthy` | `docs/e2e-walkthrough-report.md` | Scripts use `podman run --network=host`, never `podman compose` for the training container |
| Stale conmon holding libpod lock | `docs/e2e-walkthrough-report.md` | Killed by the doctor check; defensive container removal in `alexnet-train.sh` |
| UID mismatch on bind-mount (rootless) | `shared/Mnemosyne/skills/mesh-dispatch-pipeline-debugging.md` | All `podman run` invocations use `--userns=keep-id` |
| Firewalld blocks all Tailscale ports except SSH | `shared/Mnemosyne/skills/e2e-crosshost-doctor-prerequisite-checker.md` (verified on epimetheus 2026-04-06) | `firewall-cmd --permanent --zone=trusted --add-interface=tailscale0` in prerequisites |
| `systemctl --user` fails over SSH | `e2e/doctor.sh` step 8 | Export `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS`; ensure linger |

## Rollout Sequence

### Phase 1: Validate on epimetheus

Epimetheus is the most-prepared host (Podman 5.8.1 already verified, firewalld zone
fixed). Start here to validate the full pattern before pushing to other hosts.

```bash
# On epimetheus
cd ~/Projects/Odysseus
just doctor --role worker                 # Confirm podman, podman socket, tailscale

# Smoke test — 3 batches of synthetic data, ~60 seconds
just alexnet-smoke
```

**Smoke-test expectations — `podman logs` is the single source of truth.**
`alexnet-train.sh` launches the training container **detached** (`podman run -d`), so
`just alexnet-smoke` returns immediately. All training output — per-batch loss, epoch
progress, final metrics, and the completion marker — streams to the **container log
driver**. `training.log` under `~/alexnet-results/<host>/` holds **only the launch
header** (config summary); the run itself is never written there. Monitor and verify
via `podman logs`:

```bash
# Stream live output
podman logs -f alexnet-training

# Quick peek — prints the lines matching any of these markers
podman logs alexnet-training 2>/dev/null | grep -E "Batch \[1/3\]|Training complete!|Average Loss|Test Accuracy:"
# For a strict smoke PASS, verify EACH marker is present + container exited 0:
#  1. "Batch [1/3] - Loss: ..."   — first batch ran (smoke mode = 3 batches)
#  2. "Average Loss: ..."         — final loss printed
#  3. "Test Accuracy: ..."        — evaluation completed
#  4. "Training complete!"        — the terminal marker
#  5. container exited 0:
podman inspect alexnet-training --format '{{.State.Status}} exit={{.State.ExitCode}}'
#     exited exit=0
# (e2e/alexnet-fleet-wait.sh enforces all of the above as its gate)

# Full training run (after smoke validation passes)
podman rm -f alexnet-training             # Clean up smoke container
EPOCHS=100 BATCH_SIZE=128 bash e2e/alexnet-train.sh
```

### Phase 2: Launch fleet from epimetheus

After the epimetheus smoke test passes, deploy to the full fleet:

```bash
# On epimetheus
cd ~/Projects/Odysseus

# Dry-run first to verify the fleet list resolves correctly
DRY_RUN=1 bash e2e/alexnet-deploy-fleet.sh

# Full fleet smoke run (3 batches each)
EPOCHS=10 MAX_BATCHES=3 bash e2e/alexnet-deploy-fleet.sh
# Builds image, distributes to apollo/aeolus/hephaestus/hermes over Tailscale, launches
# 4 training jobs in parallel. ~90s for image transfer, then training runs concurrent.
#
# Fleet smoke expectations are per-host and identical to Phase 1: each host's
# container log is the single source of truth — check every host with
#   ssh <host> 'podman logs alexnet-training 2>/dev/null | grep -E "Training complete!|Average Loss|Test Accuracy:"'
# (the wait+gate wrapper, e2e/alexnet-fleet-wait.sh, automates this check)

# Full training run
EPOCHS=100 bash e2e/alexnet-deploy-fleet.sh
```

Image distribution uses `rsync -az /tmp/odyssey-dev.tar <host-100.x>:~/odyssey-dev.tar`
followed by `ssh <host> 'podman load -i ~/odyssey-dev.tar'`. This is the proven pattern
from the May-2026 cross-CPU survey (~90s for a 760MB image). The deploy script ALSO
distributes the three launch scripts to `~/alexnet-fleet-scripts/` on each remote host,
so the Phase 3 launch can ssh with a clean prefix-envvar pattern (no nested quoting).
On each remote: `~/alexnet-fleet-scripts/{alexnet-train,alexnet-collect-results,alexnet-deploy-fleet}.sh`.

### Phase 3: Per-host monitoring

While the fleet trains, monitor each host independently:

```bash
# Stream individual host logs
podman logs -f alexnet-training                             # epimetheus
for h in apollo aeolus hephaestus hermes; do
    ssh "$h" "podman logs -f alexnet-training"
done

# Check final loss summaries — markers live in each host's container log,
# not in training.log (which only carries the launch header)
for host in epimetheus apollo aeolus hephaestus hermes; do
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
bash e2e/alexnet-collect-results.sh
# Or with a custom central directory
CENTRAL_DIR=~/alexnet-fleet-results-$(date +%Y%m%d) bash e2e/alexnet-collect-results.sh
```

The collection script rsyncs each host's `~/alexnet-results/<hostname>/` over Tailscale
and prints a comparison summary (per-host status, weights count, log excerpts).

### Wait + gate (CI and scripted runs)

`e2e/alexnet-deploy-fleet.sh` launches training **detached** and returns immediately.
For scripted or CI runs that need to block until the fleet finishes and verify
completion, use the gate wrapper:

```bash
# Blocks until every host's alexnet-training container exits (150 min default),
# then verifies per-host completion evidence ("Training complete!" in podman
# logs + non-empty weights dir). Exits non-zero if any host fails.
bash e2e/alexnet-fleet-wait.sh

# Shorter deadline, or wait-only (skip the completion gate)
bash e2e/alexnet-fleet-wait.sh --timeout-minutes 90
bash e2e/alexnet-fleet-wait.sh --no-gate
```

## CI: AlexNet mesh smoke workflow

`.github/workflows/alexnet-mesh-smoke.yml` runs the full smoke pipeline from CI
as a **manual-dispatch-only, gated** workflow:

1. Checkout (submodules recursive) on a self-hosted runner
2. Preflight (podman, tailscale, jq, submodule)
3. `alexnet-deploy-fleet.sh` — build, distribute, launch
4. `alexnet-fleet-wait.sh` — block until all hosts exit, then **gate** on
   completion evidence; the job fails if any host lacks it
5. `alexnet-collect-results.sh` — central collection + uploaded as an artifact
6. Tear down containers on all hosts (unless `teardown` is unchecked)

Dispatch inputs: `epochs` (default 10), `max_batches` (default 3), `fleet`
(default `epimetheus apollo aeolus hephaestus` — **hermes is opt-in** until its
preflight clears: `unprivileged_userns_clone=1` + SSH reachable from epimetheus,
see Per-Host Notes), `skip_build`, and `teardown`.

**Runner registration (one-time, on aeolus):** the workflow requires a
self-hosted runner with the `self-hosted,mesh` labels — GitHub-hosted runners
cannot reach the fleet. Register with:

```bash
# On aeolus (create a registration token via the repo Settings → Actions →
# Runners page, or `gh api repos/HomericIntelligence/Odysseus/actions/runners/registration-token`)
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -fsSL -o runner.tar.gz <latest-runner-linux-x64-url>
tar xzf runner.tar.gz
./config.sh --url https://github.com/HomericIntelligence/Odysseus \
    --token <registration-token> --labels self-hosted,mesh
./run.sh   # or install as a systemd user service (enable linger)
```

The runner account must satisfy the runbook prerequisites (rootless podman,
tailscale, `jq`). Aeolus confirmed 2026-08-11: podman 4.9.3, tailscale,
`jq`, `just`, podman.socket active — but **`loginctl enable-linger` must still
be run** (the user-level systemd service that keeps the runner alive after
logout requires it). The first fleet host registered a `mesh` runner on
epimetheus while aeolus was offline — **decommission `epimetheus-mesh` once the
aeolus runner is up** so job dispatch picks the intended host.

**Chaos suite (`alexnet-mesh-chaos.yml`):** `.github/workflows/alexnet-mesh-chaos.yml`
runs the crash-test suite `e2e/alexnet-mesh-chaos.sh` **manually via
`workflow_dispatch` only** — same policy as the mesh smoke: it never auto-gates
PRs or main. Dispatch it explicitly when a mesh change needs crash-testing.
Default runs use the fast mode (offline-host tolerance, missing-image
diagnostic, smoke-gate semantics, teardown idempotency — a minute or two, no
training). The live cases (C4 clobber guard + C5 kill-mid-run against a real
training container) are dispatched with `live: true`. Same `self-hosted,mesh`
runner requirement; the two mesh workflows share a concurrency group so they
never touch the `alexnet-training` container at the same time.

Locally, the same suite is available as `just alexnet-mesh-chaos` (default mode) and
`just alexnet-mesh-chaos-live` (live cases).

## Per-Host Notes

### aeolus (Sandy Bridge-E — most challenging)

The 2012-era silicon has **AVX only — no AVX2**. The Mojo JIT may detect a wider SIMD
baseline than the CPU supports and SIGILL. `e2e/alexnet-train.sh` detects this via
hostname and adds `--target-features -avx2,-avx512*` automatically.

If a future aeolus upgrade replaces the CPU with an AVX2-capable chip, override with:

```bash
FORCE_AVX2=1 EPOCHS=10 bash e2e/alexnet-train.sh
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

Apollo already runs Docker (HomelabOS). Podman and Docker can coexist on the same host
but their storage and network stacks are separate. The training script uses `podman`
commands exclusively and does not interact with the Docker daemon.

The host's Python 3.7 is irrelevant — the Odyssey container provides Python 3.12 via pixi.

### hephaestus (fresh host)

If hephaestus has never been configured:

```bash
ssh hephaestus
cd ~/Projects/Odysseus   # or clone: git clone --recurse-submodules https://github.com/HomericIntelligence/Odysseus
just doctor --role worker --install   # auto-installs podman, enables socket, fixes firewalld
```

Verify SIMD before launching:

```bash
grep -E "model name|flags" /proc/cpuinfo | head -5
# Check for avx, avx2, avx512f flags. If avx512 is absent but Mojo targets it,
# add MOJO_TARGET_FLAGS manually via container env (overrides the script).
```

### hermes (Lunar Lake — new fleet member as of 2026-05-12)

Intel Core Ultra 7 258V (Lunar Lake, late-2024 silicon), **15.4 GB** kernel-reported RAM
(16 GB physical), 8 cores, 353 GB free disk. Podman 5.8.3 installed (epimetheus currently
ships 5.8.1). Hermes is a **WSL2 host** (Linux 6.6.87.2-microsoft-standard-WSL2, per
`docs/e2e-walkthrough-report.md`), so it must satisfy both the rootless-Podman chain
**and** the WSL2 systemd chain (`[boot] systemd=true` in `/etc/wsl.conf` + linger).

**Status (checked 2026-08-11): hermes is OFFLINE on the tailnet** — last seen
2026-08-07, no ping/SSH response from epimetheus. The 2026-05-12 preflight probes
could not be re-run live. The pattern evidence below is from **apollo** (the documented
same-blocker host), confirmed live on 2026-08-11:

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

**Remediation (one-shot):** `e2e/hermes-fleet-preflight-fix.sh` — run **on hermes**
(once it is back online and SSH-reachable):

```bash
ssh hermes 'bash -s' < e2e/hermes-fleet-preflight-fix.sh
```

It probes and sets `kernel.unprivileged_userns_clone=1` (persisted via
`/etc/sysctl.d/99-tailnet.conf`), verifies the WSL2 systemd/linger/socket chain,
re-runs `podman info` (the preflight gate), runs a rootless `alpine` smoke container,
and prints the ssh prerequisite steps.

**If `kernel.unprivileged_userns_clone=0`**, hermes has the same blocker as apollo
and the deploy will fail at image load. Operator options:

1. **Run the remediation script above** — `sudo sysctl -w kernel.unprivileged_userns_clone=1`,
   persisted across reboots via `/etc/sysctl.d/99-tailnet.conf`.
2. **Skip hermes in the active FLEET** for the smoke run: `FLEET="epimetheus apollo
   aeolus hephaestus" bash e2e/alexnet-deploy-fleet.sh`. Keep hermes in the default
   for documentation but explicitly exclude until both blockers (sysctl + SSH) clear.

**If `kernel.unprivileged_userns_clone=1`** (and SSH is reachable), hermes should work
like epimetheus with no further remediation. `e2e/alexnet-train.sh`'s per-host CPU-flag
block has only an `aeolus` exclusion; hermes (Lunar Lake) keeps the default empty
`MOJO_TARGET_FLAGS`.

## Verification Checklist

- [ ] **All hosts**: `just doctor --role worker` passes
- [ ] **All hosts**: `podman --version` reports a rootless-mode install
- [ ] **All hosts**: `podman logs alexnet-training` shows `Batch [1/3]`, `Average Loss`, `Test Accuracy:`, and ends with `Training complete!`; container `ExitCode=0` (ssh each remote host; `training.log` only carries the launch header — `podman logs` is the single source of truth)
- [ ] **epimetheus**: Image built via `podman compose build odyssey-dev` (or `podman build` fallback)
- [ ] **Apollo/aeolus/hephaestus**: Image received via `rsync` and `podman load -i` succeeded
- [ ] **Apollo/aeolus/hephaestus**: Scripts rsync'd via `~/alexnet-fleet-scripts/` (deployed by Phase 2 of `alexnet-fleet-deploy`)
- [ ] **Central collection**: `just alexnet-fleet-collect` prints a complete summary

## Teardown & Recovery

If `just alexnet-fleet-deploy` was interrupted mid-fleet (say aeolus SIGILL'd after
apollo already launched), you have orphaned `alexnet-training` containers consuming
RAM on the partial launches. Use the teardown recipe to clean up fleet-wide:

```bash
# On epimetheus (confirms interactively unless FORCE=1)
just alexnet-fleet-teardown

# Scripted teardown (no prompt, skip host checks)
FORCE=1 just alexnet-fleet-teardown

# Also remove the rsync'd helper scripts from each host (frees ~/alexnet-fleet-scripts/)
CLEAN_SCRIPTS=1 FORCE=1 just alexnet-fleet-teardown
```

What this script does:

| Step | Action |
|------|--------|
| 1 | Resolve `tailscale status --json` IP for each host in `FLEET` |
| 2 | For each host: `podman rm -f alexnet-training` (idempotent — missing container is OK) |
| 3 | Optional: `rm -rf ~/alexnet-fleet-scripts/` on each remote host (with `CLEAN_SCRIPTS=1`) |
| 4 | Preserve `~/alexnet-results/<hostname>/` for archival — the teardown script never touches it |

The script **does NOT delete** training results — delete those manually with
`rm -rf ~/alexnet-results/<hostname>` if you want a clean slate.

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
| Mojo version | `podman exec alexnet-training mojo --version` |
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
   container log driver (`podman logs alexnet-training`); only the weights and
   the launch-header `training.log` are rsync'd back at the end. A NATS-based
   streaming path (publish `hi.research.alexnet.<host>.progress` per batch)
   would enable real-time dashboards via Argus.
4. **Cross-host dataset sync** — CIFAR-10 (~170MB) is downloaded per host if absent.
   Pre-staging to a Tailscale-mounted NAS would skip the per-host download.

For any of these, file an issue against the `Odysseus` repo referencing this runbook.
