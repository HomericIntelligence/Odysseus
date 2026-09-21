# Runbook: Self-Hosted Runner Container Jobs (`statfs /var/run/docker.sock`)

Diagnose and fix the failure mode where every GitHub Actions job that declares a
job-level `container:` dies on the `aeolus` self-hosted runner within ~10 seconds,
before any workflow step runs.

## Symptom

The job fails during **Initialize containers** with exit code 125:

```text
##[command]/usr/bin/docker create --name ... -v "/var/run/docker.sock":"/var/run/docker.sock" ...
Error: statfs /var/run/docker.sock: no such file or directory
##[error]Exit code 125 returned from process: file name '/usr/bin/docker', arguments 'create ...'
```

The job never reaches checkout or any `run:` step, so the failure looks like an
opaque infrastructure error rather than a configuration one. Because the runner is
org-level (`aeolus-org-homericintelligence`, labels `self-hosted,self-hosted-aeolus`),
it can affect any repository that targets it — in practice this is `Odysseus`
(`build.yml` → `idempotent-build`, `e2e-reliability.yml` → `e2e-reliability-t1`).

## Root Cause

GitHub's `actions/runner` **unconditionally** bind-mounts the host path
`/var/run/docker.sock` into any job that sets `container:` — this is hardcoded runner
behavior, not repository configuration. `aeolus` runs **podman** (`podman-docker`
supplies `/usr/bin/docker` as a thin `exec /usr/bin/podman "$@"` shim); there is no
Docker daemon.

Two host facts combine to break the mount:

1. `/etc/tmpfiles.d/podman-docker.conf` repoints `/run/docker.sock` (and therefore
   `/var/run/docker.sock`, since `/var/run` is a symlink to `/run`) at
   `github_runner`'s **rootless** socket: `/run/user/1500/podman/podman.sock`.
2. That socket only exists once `github_runner`'s **user** `podman.socket` unit is
   enabled and started. Linger and `XDG_RUNTIME_DIR` are necessary but **not
   sufficient** — they create `/run/user/1500`, they do not start the socket.

If the user socket was never enabled, the symlink dangles. `podman` resolves the
symlink during `create` and `statfs` fails with `ENOENT`, which the runner reports as
`no such file or directory`.

Note the misleading detail: the **rootful** system `podman.socket`
(`/run/podman/podman.sock`, `SocketMode=0660`, `root:root`) may be `active` while
container jobs still fail — nothing points at it, and the unprivileged
`github_runner` account cannot access it anyway.

## Diagnosis

Run these on `aeolus`. The first three are unprivileged.

```bash
# 1. Where does the socket point, and does the target exist?
ls -l /var/run/docker.sock
readlink -f /var/run/docker.sock || echo 'DANGLING: target does not exist'

# 2. Is the rootless socket present at all?
sudo stat -c '%N' /run/user/1500/podman/podman.sock

# 3. Which runner user, and is there a live user manager to host the socket?
getent passwd 1500
loginctl show-user github_runner | grep -E 'Linger|State|RuntimePath'
systemctl is-active user@1500.service

# 4. Is the user socket unit actually enabled? (this is the usual culprit)
sudo -u github_runner XDG_RUNTIME_DIR=/run/user/1500 systemctl --user is-active podman.socket
```

Interpretation:

| Observation | Meaning |
| --- | --- |
| `readlink -f` fails / step 2 `ENOENT` | Dangling symlink — the user socket is not running |
| `user@1500.service` inactive | No user manager to host the socket (check `Linger=yes`) |
| step 4 `inactive`/`failed` | **The fix below has not been applied** |
| Rootful `podman.socket` active but jobs still fail | Expected; it is not the mount target |

Reading `readlink -f` as a normal login user may report a failure purely because
`/run/user/1500` is mode `0700` and owned by `github_runner`. Verify with `readlink -f`
as `github_runner`, or rely on the CI re-run instead.

## Fix

Enable and start the **user** `podman.socket` for the runner account. This is the
step that actually creates the socket file the symlink points at:

```bash
sudo -u github_runner XDG_RUNTIME_DIR=/run/user/1500 systemctl --user enable --now podman.socket
```

`enable` (not just `--now`) is required so the socket is recreated on every boot;
`Linger=yes` is already set for `github_runner`, so no interactive session is needed.

Verify:

```bash
sudo -u github_runner XDG_RUNTIME_DIR=/run/user/1500 systemctl --user is-active podman.socket
# Expected: active

sudo stat -c '%N %a' /run/user/1500/podman/podman.sock
# Expected: '/run/user/1500/podman/podman.sock' 660
```

Then re-run the affected CI job and confirm it progresses past **Initialize
containers** rather than failing in ~10 seconds:

```bash
gh api -X POST "/repos/HomericIntelligence/Odysseus/actions/runs/<run-id>/rerun-failed-jobs"
```

## Why Rootless, Not Rootful

Pointing `/run/docker.sock` at the rootful `/run/podman/podman.sock` would also
satisfy the `statfs` check, but it requires granting the unprivileged
`github_runner` account access to a root-owned socket (group membership or a wider
`SocketMode`) and would run CI containers as real root. The rootless socket keeps
the runner unprivileged, which is the intended posture for this host.

## Prevention

- Treat the user `podman.socket` as part of the runner's provisioning contract, not
  an optional extra. Linger + `XDG_RUNTIME_DIR` alone do **not** create the socket.
- Container jobs and the socket they depend on are coupled: any change to
  `/etc/tmpfiles.d/podman-docker.conf` or the runner unit's `Environment=` must be
  followed by an explicit check that `/var/run/docker.sock` resolves for
  `github_runner`.
- **A green build on a job that has never once passed is not evidence.** Every
  `build.yml` run failed for 6+ days (2026-09-11 → 2026-09-17) while the failure was
  a 10-second infrastructure abort. Alert on jobs that fail faster than any
  plausible step duration, or that fail repeatedly on a single host.

## Verification Checklist

- [ ] `systemctl --user is-active podman.socket` is `active` for `github_runner`
- [ ] `/run/user/1500/podman/podman.sock` exists with mode `660`
- [ ] `readlink -f /var/run/docker.sock` resolves (checked as `github_runner`)
- [ ] `idempotent-build` in `build.yml` progresses past **Initialize containers**
- [ ] `e2e-reliability-t1` in `e2e-reliability.yml` progresses past **Initialize containers**

## See Also

- `docs/runbooks/wsl2-podman-setup.md` — same socket-enablement idiom for developer workstations
- HomericIntelligence/Odysseus#432 — CI: move heaviest jobs to self-hosted runner
- HomericIntelligence/Odysseus#498 — the first PR blocked by this failure
- [actions/runner](https://github.com/actions/runner) — hardcoded `container:` socket bind-mount
