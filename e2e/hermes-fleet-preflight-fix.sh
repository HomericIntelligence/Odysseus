#!/usr/bin/env bash
# hermes-fleet-preflight-fix.sh
# Resolves the 2026-05-12 hermes blocker (rootless podman on WSL2 Lunar Lake)
# so hermes can join the AlexNet mesh fleet. Run ON hermes (the WSL2 host),
# e.g.:  ssh hermes 'bash -s' < e2e/hermes-fleet-preflight-fix.sh
#
# Preflight blocker (docs/runbooks/alexnet-mesh-fleet.md "hermes" section):
#   - /proc/sys/kernel/unprivileged_userns_clone  -> (unreadable) / likely 0
#   - podman info                                 -> FAILED (cannot clone userns)
# Pattern confirmed live on apollo 2026-08-11:
#   unprivileged_userns_clone=0 -> "cannot clone: Operation not permitted"
set -euo pipefail

echo "=== [1/6] unprivileged_userns_clone probe ==="
if [[ -r /proc/sys/kernel/unprivileged_userns_clone ]]; then
    US="$(cat /proc/sys/kernel/unprivileged_userns_clone)"
    echo "kernel.unprivileged_userns_clone = $US"
else
    US="unreadable"
    echo "kernel.unprivileged_userns_clone = (unreadable as user — probe with sudo next)"
fi

echo
echo "=== [2/6] enable + persist unprivileged_userns_clone=1 ==="
if [[ "$US" != "1" ]]; then
    sudo sysctl -w kernel.unprivileged_userns_clone=1
    if [[ -d /etc/sysctl.d ]]; then
        echo "kernel.unprivileged_userns_clone=1" | sudo tee /etc/sysctl.d/99-tailnet.conf >/dev/null
        echo "persisted via /etc/sysctl.d/99-tailnet.conf"
    else
        echo "WARN: no /etc/sysctl.d — persistence skipped (WSL2: verify /etc/wsl.conf [boot] command)" >&2
    fi
    if [[ -r /proc/sys/kernel/unprivileged_userns_clone ]]; then
        echo "now: kernel.unprivileged_userns_clone = $(cat /proc/sys/kernel/unprivileged_userns_clone)"
    else
        echo "note: sysctl value still unreadable to this user (log out/in if unsure)" >&2
    fi
else
    echo "already 1 — nothing to do"
fi

echo
echo "=== [3/6] WSL2 rootless prerequisites (systemd + linger + socket) ==="
echo "WSL interop kernel: $(uname -r)"
if ! systemd_running="$(ps -p 1 -o comm= 2>/dev/null)"; then
    systemd_running=""
fi
echo "pid1: $systemd_running"
if [[ "$systemd_running" != "systemd" ]]; then
    echo "WARN: systemd not PID 1 (WSL2 legacy init). Rootless podman services need" >&2
    echo "      '[boot] systemd=true' in /etc/wsl.conf + 'wsl --shutdown' on Windows." >&2
fi
if command -v loginctl >/dev/null 2>&1; then
    if ! loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes'; then
        if ! sudo loginctl enable-linger "$USER"; then
            echo "WARN: could not enable linger (systemd may not be PID 1 on WSL2 legacy init) — continue" >&2
        else
            echo "linger enabled for $USER"
        fi
    else
        echo "linger already enabled"
    fi
else
    echo "WARN: loginctl unavailable" >&2
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
if [[ ! -d "$XDG_RUNTIME_DIR" ]]; then
    echo "WARN: $XDG_RUNTIME_DIR does not exist — attempting to create (root-owned on legacy-init WSL2; may fail)" >&2
    if mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null; then
        chmod 700 "$XDG_RUNTIME_DIR"
    else
        echo "WARN: cannot create $XDG_RUNTIME_DIR as user — podman.socket may fail below; this is the WSL2 systemd fix" >&2
    fi
fi
if ! systemctl --user enable --now podman.socket 2>&1 | tail -2; then
    echo "WARN: podman.socket enable/start reported failure (see output above)" >&2
fi

echo
echo "=== [4/6] podman info ==="
if ! podman version --format 'podman {{.Version}}' 2>&1; then
    echo "ERROR: podman not found or version query failed — install podman first (see runbook prerequisites)" >&2
    exit 1
fi
if podman info >/tmp/hermes-podman-info.log 2>&1; then
    echo "podman info: PASS"
    if ! grep -E 'os:|kernel:|cgroupManager|eventLogger|graphDriverName|rootless' /tmp/hermes-podman-info.log | head -8; then
        echo "  (info schema keys not matched — not an error; podman info already PASSED)"
    fi
else
    echo "podman info: FAILED — log tail:" >&2
    tail -8 /tmp/hermes-podman-info.log >&2
    exit 1
fi

echo
echo "=== [5/6] rootless run smoke test ==="
if podman run --rm --userns=keep-id docker.io/library/alpine:3.20 echo "hermes rootless podman OK" >/tmp/hermes-smoke.log 2>&1; then
    cat /tmp/hermes-smoke.log
    echo "rootless container run: PASS"
else
    echo "rootless container run: FAILED — log tail:" >&2
    tail -8 /tmp/hermes-smoke.log >&2
    exit 1
fi

echo
echo "=== [6/6] fleet deploy prerequisite (ssh from epimetheus) ==="
echo "Fleet deploy uses 'ssh <ip> <cmd>' (see e2e/alexnet-deploy-fleet.sh)."
echo "WSL2 hermes has NO ssh server configured (verified 2026-08-11: not in"
echo "epimetheus ~/.ssh/config or known_hosts). From epimetheus:"
echo "  ssh-copy-id hermes   # install openssh-server inside WSL, start sshd first"
echo "  ssh hermes 'podman --version'  # must return without password/prompt"

echo
echo "=== hermes preflight RESOLVED ==="
echo "Next, from epimetheus:"
echo "  just doctor --role worker --install   # on hermes"
echo "  FLEET='epimetheus apollo aeolus hephaestus hermes' bash e2e/alexnet-deploy-fleet.sh"
