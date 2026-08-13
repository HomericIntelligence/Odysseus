#!/usr/bin/env bash
# e2e/alexnet-fleet-teardown.sh — Fleet-wide teardown for AlexNet training
#
# Stops and removes `alexnet-training` containers on all fleet hosts. Use this
# when:
#   - alexnet-fleet-deploy was interrupted mid-fleet (some hosts started,
#     others didn't — orphaned containers consume RAM on the partial launches)
#   - you want to clean up after a manual fleet run for re-launch with
#     different params
#   - you suspect stale container state on a host and want a clean restart
#
# Usage (run from epimetheus, the central host):
#   bash e2e/alexnet-fleet-teardown.sh                    # default fleet
#   FLEET="epimetheus apollo" bash e2e/alexnet-fleet-teardown.sh  # subset
#   FORCE=1 bash e2e/alexnet-fleet-teardown.sh           # skip the confirm prompt
#
# Required env (FLEET is optional):
#   (none — defaults to FLEET="epimetheus apollo aeolus hephaestus")
#
# Optional env:
#   FLEET    — space-separated host list
#   FORCE=1  — skip the interactive confirmation prompt (for scripted teardown)
#
# See docs/runbooks/alexnet-mesh-fleet.md for context. This script does NOT
# delete ~/alexnet-results/<hostname>/ — those are kept for archival. Delete
# manually with `rm -rf ~/alexnet-results/<hostname>` if you want a clean slate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET="${FLEET:-epimetheus apollo aeolus hephaestus hermes}"
LOCAL_HOST=$(hostname)

# Bounded ssh for every remote probe: an offline/unreachable host (e.g. hermes
# on the tailnet) must not hang teardown. `timeout` caps the whole ssh session
# and ConnectTimeout fails fast when the host does not answer SYN.
# Matches the guard used by e2e/alexnet-fleet-wait.sh (SSH_BASE).
SSH_BASE=(timeout 15 ssh -o ConnectTimeout=5 -o BatchMode=yes)

# Parse FLEET into a glob-safe bash array. Avoid `for host in $FLEET` which would
# pathname-expand if FLEET accidentally contained a pattern like 'epimeth*'.
IFS=' ' read -ra FLEET_ARR <<< "$FLEET"

if [[ "${FORCE:-0}" != "1" ]]; then
    echo "=== AlexNet Fleet Teardown ==="
    echo "This will: stop + remove 'alexnet-training' container on:"
    for host in "${FLEET_ARR[@]}"; do
        echo "  - $host"
    done
    echo "Results directories (~/alexnet-results/<host>/) are NOT deleted."
    echo ""
    # Guard the interactive prompt for non-TTY contexts (CI jobs, ssh-from-cron).
    # Without the guard, `read` under `set -e` exits silently with no message.
    if [[ -t 0 ]]; then
        read -r -p "Continue? [y/N] " reply
        case "$reply" in
            [yY]|[yY][eE][sS]) ;;
            *) echo "Aborted."; exit 1 ;;
        esac
    else
        echo "ERROR: non-TTY stdin detected. Re-run with FORCE=1 to skip the prompt." >&2
        echo "  FORCE=1 bash e2e/alexnet-fleet-teardown.sh" >&2
        exit 1
    fi
fi

# Resolve Tailscale IPs (or use localhost for the local host).
declare -A HOST_IPS
for host in "${FLEET_ARR[@]}"; do
    if [[ "$host" == "$LOCAL_HOST" || "$host" == "localhost" ]]; then
        HOST_IPS[$host]="localhost"
    else
        HOST_IPS[$host]=$(tailscale status --json 2>/dev/null \
            | jq -r --arg h "$host" \
                '.Peer // {} | to_entries[] | .value | select(.HostName == $h) | .TailscaleIPs[0]' \
            2>/dev/null || echo "")
    fi
    if [[ -z "${HOST_IPS[$host]:-}" ]]; then
        echo "WARNING: could not resolve Tailscale IP for '$host'" >&2
    fi
done

echo ""
echo "Tearing down alexnet-training containers..."
for host in "${FLEET_ARR[@]}"; do
    ip="${HOST_IPS[$host]:-}"
    if [[ -z "$ip" ]]; then
        echo "  ✗ $host (no Tailscale IP — skipping)"
        continue
    fi

    if [[ "$ip" == "localhost" ]]; then
        echo "  → $host (local)"
        if podman container exists alexnet-training 2>/dev/null; then
            podman rm -f alexnet-training
            echo "    [ok] removed"
        else
            echo "    [skip] no alexnet-training container"
        fi
    else
        echo "  → $host ($ip)"
        # Idempotent: podman rm -f on a missing container exits 1; tolerate that.
        # Bounded ssh: an unreachable host surfaces as a WARN here instead of a
        # hang (see SSH_BASE above).
        "${SSH_BASE[@]}" "$ip" "podman rm -f alexnet-training 2>/dev/null && echo '[ok] removed' || echo '[skip] no container'" &
    fi
done
wait

# Also clean up the distributed scripts (leftover from alexnet-fleet-deploy).
if [[ "${CLEAN_SCRIPTS:-0}" == "1" ]]; then
    echo ""
    echo "Removing distributed ~/alexnet-fleet-scripts/ from each remote host..."
    for host in "${FLEET_ARR[@]}"; do
        ip="${HOST_IPS[$host]:-}"
        [[ -z "$ip" || "$ip" == "localhost" ]] && continue
        "${SSH_BASE[@]}" "$ip" "rm -rf ~/alexnet-fleet-scripts && echo '[ok] $host: scripts removed'" &
    done
    wait
fi

echo ""
echo "=== Teardown complete ==="
echo ""
echo "To start a fresh fleet run:  bash $SCRIPT_DIR/alexnet-deploy-fleet.sh"
echo "To clean up old results:    rm -rf ~/alexnet-results/<hostname>/"
