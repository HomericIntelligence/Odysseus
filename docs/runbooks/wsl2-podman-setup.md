# Runbook: WSL2 Rootless Podman Setup

Use this runbook when the local Compose workflow needs Podman's rootless API
socket inside a WSL2 distribution. It separates read-only diagnosis from host
changes. None of the commands here prove or authorize a production deployment,
cross-host network access, or a change to another WSL distribution.

Microsoft documents the WSL configuration and restart behavior in
[Advanced settings configuration in WSL][wsl-config]. Podman documents the
rootless socket path and socket-activation model in
[`podman system service`][podman-service].

## Scope and authority

The read-only checks below are safe to run locally. Editing `/etc/wsl.conf`,
shutting down WSL, changing linger state, installing packages, and enabling a
user service are host mutations. Before each such change:

1. Confirm the exact WSL distribution and user account in scope.
2. Obtain approval from the host operator.
3. Record the current value and the rollback command.
4. Stop if another distribution, user, or managed host would be affected.

`wsl.exe --shutdown` stops every running WSL distribution, not just the current
one. Run it only from Windows after the operator confirms that blast radius.

## Read-only preflight

From the WSL distribution, inspect the current state:

```bash
uname -a
podman --version
podman compose version
ps -p 1 -o comm=
systemctl --user status
systemctl --user status podman.socket
loginctl show-user "$USER" -p Linger
printf 'XDG_RUNTIME_DIR=%s\n' "${XDG_RUNTIME_DIR:-unset}"
```

From Windows PowerShell, identify WSL and distribution state:

```powershell
wsl.exe --version
wsl.exe --list --verbose
```

Interpret these checks independently:

- A missing or broken `podman --version` is a package-installation problem.
- PID 1 not being `systemd` is a WSL initialization problem.
- A missing `podman.socket` unit is a Podman packaging/unit-installation
  problem; enabling systemd does not install that unit.
- A present but inactive socket is a user-service state problem.
- Linger controls whether a user manager can persist without an interactive
  login. It is not required merely to run Podman in a current session.

Resolve only the branch that matches the observed state.

## Enable systemd only when it is absent

If PID 1 is already `systemd`, skip this section.

After operator approval, inspect and back up the exact file before editing it:

```bash
sudo test -e /etc/wsl.conf && sudo cp -a /etc/wsl.conf /etc/wsl.conf.pre-systemd
sudoedit /etc/wsl.conf
```

Preserve every existing section and key. Ensure the resulting file contains one
`[boot]` section with this setting:

```ini
[boot]
systemd=true
```

Then, after confirming that all WSL distributions may be stopped, run this from
Windows PowerShell:

```powershell
wsl.exe --shutdown
```

Reopen the intended distribution and verify the result:

```bash
test "$(ps -p 1 -o comm= | tr -d '[:space:]')" = systemd
systemctl --user status
```

If verification fails, restore `/etc/wsl.conf.pre-systemd` (when it existed),
or remove only the newly added `systemd=true` key, then perform the same approved
WSL shutdown and verify the previous state.

## Start the rootless Podman socket

First prove the packaged user unit exists:

```bash
systemctl --user cat podman.socket
```

If the unit is missing, stop. Install Podman and its systemd user units through
the distribution's supported package process, or have the host operator review
an exact custom unit. Do not copy a guessed source-tree template into the user
configuration and call that installation complete.

For the current session only:

```bash
systemctl --user start podman.socket
```

If the operator explicitly wants the socket enabled for future user sessions:

```bash
systemctl --user enable --now podman.socket
```

Verify both unit state and the rootless socket owned by the current user:

```bash
systemctl --user is-active podman.socket
test -n "${XDG_RUNTIME_DIR:-}"
test -S "$XDG_RUNTIME_DIR/podman/podman.sock"
podman info
```

Rollback for a newly enabled socket is:

```bash
systemctl --user disable --now podman.socket
```

Use that rollback only if the socket was disabled before this procedure.

## Enable linger only for an approved persistence requirement

If the socket must activate without an interactive login and the operator
approves persistent user services, record the current value and enable linger:

```bash
loginctl show-user "$USER" -p Linger
sudo loginctl enable-linger "$USER"
loginctl show-user "$USER" -p Linger
```

If linger was disabled before this change, its rollback is:

```bash
sudo loginctl disable-linger "$USER"
```

Do not change linger merely to repair a missing Podman binary or unit.

## Repository verification

The repository doctor validates the selected local role. Local mode does not
run Tailscale or claim cross-host readiness:

```bash
just doctor --role worker
```

Then run the local stack through the repository entry point:

```bash
just e2e-up
```

If Compose fails, preserve the exact failing output and inspect only the current
user's state:

```bash
systemctl --user status podman.socket
podman info
podman ps --all
```

Do not switch the stack to host networking as a generic workaround. Network
mode changes isolation and port ownership; they require a separately reviewed,
topology-specific change.

## Completion

This procedure is complete only when:

- `podman --version` and `podman compose version` succeed;
- the intended WSL distribution is still the only distribution changed;
- the rootless socket is active at `$XDG_RUNTIME_DIR/podman/podman.sock`;
- any requested linger state matches the operator's decision;
- `just doctor --role worker` reports truthful local results; and
- `just e2e-up` either proves complete stack readiness or exits non-zero with
  the failed checks.

[wsl-config]: https://learn.microsoft.com/windows/wsl/wsl-config#systemd-support
[podman-service]: https://docs.podman.io/en/latest/markdown/podman-system-service.1.html
