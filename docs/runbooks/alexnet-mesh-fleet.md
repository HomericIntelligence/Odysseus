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
| **hermes** | Training target | Intel Core Ultra 7 258V (Lunar Lake) | AVX2 | Modern 2024 silicon. Per the May-2026 cross-CPU survey, runs Mojo cleanly without `--target-features` strip. Preflight investigation flagged 2026-05-12 (see Per-Host Notes). |

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

# Monitor
podman logs -f alexnet-training
tail -f ~/alexnet-results/epimetheus/training.log
# Expected: "Batch [1/3] - Loss: ..." then "Training complete!"

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

# Check final loss summaries
for host in epimetheus apollo aeolus hephaestus hermes; do
    echo "── $host ──"
    grep -E "Average Loss|Test Accuracy" ~/alexnet-results/$host/training.log | tail -5
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
(16 GB physical), 8 cores, 353 GB free disk.Podman 5.8.3 installed (epimetheus currently ships 5.8.1) but
preflight probes on 2026-05-12 raised two soft concerns that need operator
investigation before the first fleet smoke:

| Preflight check | Result | What to investigate |
|-----------------|--------|---------------------|
| `/proc/sys/kernel/unprivileged_userns_clone` (user-mode read) | `(unreadable)` | On some kernels the sysctl hides itself from unprivileged users when the value is `0`. Likely same kernel blocker as apollo. Verify with `sudo cat /proc/sys/kernel/unprivileged_userns_clone`. |
| `podman info` | **FAILED** | Could not verify cgroups / graph driver. Likely same root cause as the sysctl above (rootless user-namespace clone disabled). If confirmed at `0`, deploy Phase 2 (`podman load`) will fail with `cannot clone` — same failure pattern as apollo. |
| Podman version | 5.8.3 | OK. |
| Odyssey workspace (`research/Odyssey`) | Absent before 2026-05-12 onboarding | After meta-repo sync: `git submodule update --init --recursive`. |

**If `kernel.unprivileged_userns_clone=0`**, hermes has the same blocker as apollo
and the deploy will fail at image load. Two operator options:

1. **One-shot workaround**: `sudo sysctl -w kernel.unprivileged_userns_clone=1`
   (requires sudo + persistence across reboots via `/etc/sysctl.d/99-tailnet.conf`).
2. **Skip hermes in the active FLEET** for the smoke run: `FLEET="epimetheus apollo
   aeolus hephaestus" bash e2e/alexnet-deploy-fleet.sh`. Keep hermes in the default
   for documentation but explicitly exclude for the first run until preflight clears.

**If `kernel.unprivileged_userns_clone=1`**, hermes should work like epimetheus
with no preflight remediation needed. `e2e/alexnet-train.sh`'s per-host CPU-flag
block has only an `aeolus` exclusion; hermes (Lunar Lake) keeps the default empty
`MOJO_TARGET_FLAGS`.

## Verification Checklist

- [ ] **All hosts**: `just doctor --role worker` passes
- [ ] **All hosts**: `podman --version` reports a rootless-mode install
- [ ] **All hosts**: `~/alexnet-results/<hostname>/training.log` ends with "Training complete!"
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

After the fleet run completes, useful per-host comparisons from the training logs:

| Metric | Where to find it |
|--------|-----------------|
| Epoch time (s) | `grep "Epoch \[" training.log` (parse the wall-clock between epochs) |
| Final loss | `grep "Average Loss" training.log \| tail -1` |
| Final test accuracy | `grep "Test Accuracy:" training.log \| tail -1` |
| Container memory peak | `podman stats --no-stream alexnet-training` while running |
| Mojo version | `podman exec alexnet-training pixi run mojo --version` |
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
3. **Live result streaming** — training logs are written to disk and rsync'd at the
   end. A NATS-based streaming path (publish `hi.research.alexnet.<host>.progress`
   per batch) would enable real-time dashboards via Argus.
4. **Cross-host dataset sync** — CIFAR-10 (~170MB) is downloaded per host if absent.
   Pre-staging to a Tailscale-mounted NAS would skip the per-host download.

For any of these, file an issue against the `Odysseus` repo referencing this runbook.
