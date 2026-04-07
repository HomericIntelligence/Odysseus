# Runbook: WSL2 Rootless Podman Setup

This runbook enables rootless podman on WSL2 (Ubuntu/Debian) so that `just e2e-up` and the full compose stack work correctly. Run these steps once per WSL2 instance.

## Prerequisites

- WSL2 with Ubuntu 22.04 or later (or Debian 12+)
- Windows 11 or Windows 10 Build 22000+ (required for WSL2 systemd support)
- podman installed (verified via `just doctor`)

---

## Steps

### 1. Enable WSL2 Systemd

Add the following to `/etc/wsl.conf` (create if it does not exist):

```ini
[boot]
systemd=true
```

Then restart WSL2 from a Windows PowerShell/CMD prompt:

```powershell
wsl --shutdown
wsl
```

Verify systemd is running after restart:

```bash
systemctl --user status
# Should show: State: running
```

### 2. Enable User Linger

Linger allows user services (like the podman socket) to start at boot without an active login session:

```bash
sudo loginctl enable-linger $USER
```

Verify:

```bash
loginctl show-user $USER | grep Linger
# Expected: Linger=yes
```

### 3. Enable and Start the Podman Socket

```bash
systemctl --user enable --now podman.socket
```

Verify the socket exists:

```bash
ls $XDG_RUNTIME_DIR/podman/podman.sock
# Expected: /run/user/1000/podman/podman.sock (or similar)
```

### 4. Verify with Doctor

```bash
just doctor --role worker
# Expected: ✓ podman compose, ✓ podman socket
```

---

## Troubleshooting

### Unit podman.socket could not be found (source-built podman)

If podman was installed from source rather than via `apt`, the systemd unit files may not be installed. Find and install them from the podman source tree:

```bash
# Find the source directory
find ~/.local/src /usr/local/src -name "podman.socket" 2>/dev/null

# Install unit files (substitute <version> with actual path found above)
cp ~/.local/src/podman-<version>/contrib/systemd/user/podman.socket ~/.config/systemd/user/
sed "s|@@PODMAN@@|$(which podman)|g" \
    ~/.local/src/podman-<version>/contrib/systemd/user/podman.service.in \
    > ~/.config/systemd/user/podman.service
systemctl --user daemon-reload
systemctl --user enable --now podman.socket
```

### rootlessport binary not found (compose stack hangs)

If `podman compose up` hangs at health checks and logs show `rootlessport binary not found`, bridge-network port binding is unavailable. Workaround: start containers individually with `--network=host` (see `e2e/start-stack.sh` comments).

The full fix is enabling WSL2 systemd (Step 1 above) which makes rootlessport available.

### /run/user/1000 does not exist

This directory is created by systemd when a user session is active. If it is missing, systemd is not running. Repeat Step 1 and ensure WSL2 was fully restarted (`wsl --shutdown` from Windows, not just closing the terminal).

---

## Verification Checklist

- [ ] WSL2 systemd is enabled (`systemctl --user status` shows "State: running")
- [ ] User linger is enabled (`loginctl show-user $USER | grep Linger=yes`)
- [ ] Podman socket is active (`ls $XDG_RUNTIME_DIR/podman/podman.sock` succeeds)
- [ ] `just doctor --role worker` shows podman compose and socket as passing
- [ ] `just e2e-up` starts the full stack without hanging

---

## See Also

- `just doctor --role worker --install` — auto-installs missing prerequisites
- `e2e/doctor.sh` — full prerequisite check implementation
- HomericIntelligence/Odysseus#107 — tracking issue for WSL2 podman setup
