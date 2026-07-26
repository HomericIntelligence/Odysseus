#!/usr/bin/env bash
# e2e/alexnet-deploy-fleet.sh — Fleet orchestration for AlexNet training
#
# From the central host (epimetheus): build the Odyssey container, distribute
# it via rsync over Tailscale, load on each remote host, and launch AlexNet
# training in parallel across the fleet.
#
# Usage (run from epimetheus, the designated build/distribution host):
#   bash e2e/alexnet-deploy-fleet.sh                                     # full 100-epoch fleet run
#   EPOCHS=10 MAX_BATCHES=3 bash e2e/alexnet-deploy-fleet.sh             # smoke fleet run
#   FLEET="epimetheus apollo" bash e2e/alexnet-deploy-fleet.sh            # subset
#   SKIP_BUILD=1 bash e2e/alexnet-deploy-fleet.sh                        # use existing image
#
# Required env (FLEET is optional):
#   (none — defaults to FLEET="epimetheus apollo aeolus hephaestus")
#
# Optional env:
#   FLEET            — space-separated host list (default: epimetheus apollo aeolus hephaestus)
#   EPOCHS           — epochs per host (default: 100)
#   BATCH_SIZE       — batch size per host (default: 128)
#   SKIP_BUILD=1     — use existing odyssey:dev image, don't rebuild or redistribute
#   SKIP_DISTRIBUTE=1— don't rsync to remote hosts (image already loaded there)
#   SKIP_LAUNCH=1    — build/distribute only, don't launch training
#   IMAGE_NAME       — podman image tag (default: odyssey:dev)
#
# See docs/runbooks/alexnet-mesh-fleet.md for the full fleet deployment plan,
# including per-host SIMD flag handling and rootless Podman setup requirements.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODYSSEUS_ROOT="$(dirname "$SCRIPT_DIR")"
LOCAL_HOST=$(hostname)

# ── Configuration ──
FLEET="${FLEET:-epimetheus apollo aeolus hephaestus hermes}"
EPOCHS="${EPOCHS:-100}"
BATCH_SIZE="${BATCH_SIZE:-128}"
IMAGE_NAME="${IMAGE_NAME:-odyssey:dev}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_DISTRIBUTE="${SKIP_DISTRIBUTE:-0}"
SKIP_LAUNCH="${SKIP_LAUNCH:-0}"

# Parse FLEET into a bash array using IFS+here-string (glob-safe). Avoid
# `for host in $FLEET` which would perform pathname expansion if FLEET
# accidentally contained a glob like 'epimeth*'.
IFS=' ' read -ra _hosts <<< "$FLEET"

# ── Pre-flight: current host must be in the fleet (the build host) ──
# If the user is running from outside the fleet, refuse rather than build elsewhere
# silently — they'd then need to re-run and the image wouldn't be where they expect.
if ! printf '%s\n' "${_hosts[@]}" | grep -qx "$LOCAL_HOST"; then
    echo "WARNING: You are running from '$LOCAL_HOST' which is not in FLEET=$FLEET." >&2
    echo "  Build/distribution will happen here. Set LOCAL_AS_BUILD=1 to proceed," >&2
    echo "  or change FLEET to include $LOCAL_HOST." >&2
    if [[ "${LOCAL_AS_BUILD:-0}" != "1" ]]; then
        exit 1
    fi
fi

# ── Resolve remote host Tailscale IPs (skip the local build host) ──
declare -A REMOTE_HOSTS
REMOTE_LIST=""
if command -v tailscale >/dev/null 2>&1; then
    for host in "${_hosts[@]}"; do
        if [[ "$host" == "$LOCAL_HOST" ]]; then
            continue
        fi
        ip=$(tailscale status --json 2>/dev/null \
            | jq -r --arg h "$host" \
                '.Peer // {} | to_entries[] | .value | select(.HostName == $h) | .TailscaleIPs[0]' \
            2>/dev/null || echo "")
        if [[ -n "$ip" ]]; then
            REMOTE_HOSTS[$host]=$ip
            REMOTE_LIST="$REMOTE_LIST $host"
        else
            echo "WARNING: Could not resolve Tailscale IP for remote host '$host' — skipping distribution" >&2
        fi
    done
else
    echo "ERROR: tailscale CLI not found on build host. Required for fleet distribution." >&2
    exit 1
fi

echo "=== AlexNet Fleet Deployment ==="
echo "Build host:      $LOCAL_HOST"
echo "Fleet:           $FLEET"
echo "Remote targets:  ${REMOTE_LIST:-(none)}"
echo "Image:           $IMAGE_NAME"
echo "Epochs/Batch:    $EPOCHS / $BATCH_SIZE"
echo ""

# ── Phase 1: Build the Odyssey container image on local ──
if [[ "$SKIP_BUILD" != "1" ]]; then
    echo "=== Phase 1: Build Odyssey container ==="
    WORKSPACE="$ODYSSEUS_ROOT/research/Odyssey"
    if [[ ! -d "$WORKSPACE" ]]; then
        echo "ERROR: Odyssey workspace not found at $WORKSPACE" >&2
        echo "  Is ODYSSEUS_ROOT correct? Override with:" >&2
        echo "  cd <repo-root> && bash $0" >&2
        exit 1
    fi

    cd "$WORKSPACE"
    export USER_ID=$(id -u) GROUP_ID=$(id -g) USER_NAME=${USER:-dev}

    # podman compose may hang on hosts missing rootlessport (epimetheus is
    # documented in e2e-walkthrough-report.md). Fall back to podman build
    # through a NETWORK=host precheck: if compose fails, fall through.
    echo "Building odyssey:dev..."
    if ! podman compose build odyssey-dev 2>/tmp/podman-compose-build.log; then
        echo "  podman compose build failed (likely rootlessport missing). Falling back to podman build..."
        cat /tmp/podman-compose-build.log | tail -20
        podman build -t "$IMAGE_NAME" \
            --build-arg USER_ID="$USER_ID" \
            --build-arg GROUP_ID="$GROUP_ID" \
            --build-arg USER_NAME="$USER_NAME" \
            .
    fi

    # Save image for distribution to remote hosts
    echo "Saving image to /tmp/${IMAGE_NAME//[:\/]/_}.tar..."
    podman save -o "/tmp/odyssey-dev.tar" "$IMAGE_NAME"
    ls -lh /tmp/odyssey-dev.tar
else
    echo "=== Phase 1: Skipped (SKIP_BUILD=1) ==="
    if [[ ! -f /tmp/odyssey-dev.tar ]]; then
        echo "ERROR: SKIP_BUILD=1 but /tmp/odyssey-dev.tar does not exist." >&2
        echo "  Run without SKIP_BUILD or create the tar manually." >&2
        exit 1
    fi
    ls -lh /tmp/odyssey-dev.tar
fi

# ── Phase 2: Distribute the image AND the launch scripts to remote hosts ──
if [[ "$SKIP_DISTRIBUTE" != "1" && -n "$REMOTE_LIST" ]]; then
    echo ""
    echo "=== Phase 2: Distribute image + scripts to remote hosts via Tailscale ==="

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "  DRY_RUN=1: would rsync image and scripts to each host:"
        for host in $REMOTE_LIST; do
            ip="${REMOTE_HOSTS[$host]}"
            echo "    rsync /tmp/odyssey-dev.tar ${ip}:~/odyssey-dev.tar"
            echo "    rsync $SCRIPT_DIR/{alexnet-train,alexnet-collect-results,alexnet-deploy-fleet}.sh ${ip}:~/alexnet-fleet-scripts/"
        done
    else
        # Distribute the container image
        for host in $REMOTE_LIST; do
            ip="${REMOTE_HOSTS[$host]}"
            echo "  → $host ($ip): rsync odyssey-dev.tar"
            rsync -az --info=progress2 /tmp/odyssey-dev.tar "${ip}:~/odyssey-dev.tar" &
        done
        wait
        echo "  image rsync complete."

        # Distribute the launch + collect scripts (needed because the remote
        # training launch is just `bash ~/alexnet-fleet-scripts/alexnet-train.sh`
        # with EPOCHS/BATCH_SIZE prefixed — no nested-quoting mess required).
        echo "  rsync launch scripts to ~/alexnet-fleet-scripts/ on each host"
        for host in $REMOTE_LIST; do
            ip="${REMOTE_HOSTS[$host]}"
            ssh "$ip" "mkdir -p ~/alexnet-fleet-scripts" &
        done
        wait
        # rsync doesn't support a host list as a dest; do per-host instead.
        for host in $REMOTE_LIST; do
            ip="${REMOTE_HOSTS[$host]}"
            rsync -az --info=progress2 \
                "$SCRIPT_DIR/alexnet-train.sh" \
                "$SCRIPT_DIR/alexnet-collect-results.sh" \
                "$SCRIPT_DIR/alexnet-deploy-fleet.sh" \
                "${ip}:~/alexnet-fleet-scripts/" &
        done
        wait
        for host in $REMOTE_LIST; do
            ip="${REMOTE_HOSTS[$host]}"
            ssh "$ip" "chmod +x ~/alexnet-fleet-scripts/*.sh && ls -la ~/alexnet-fleet-scripts/" &
        done
        wait
        echo "  script rsync + chmod complete."

        # Load image on remote hosts
        for host in $REMOTE_LIST; do
            ip="${REMOTE_HOSTS[$host]}"
            echo "  → $host: podman load"
            ssh "$ip" "podman load -i ~/odyssey-dev.tar && rm ~/odyssey-dev.tar && podman images $IMAGE_NAME --format '{{.Repository}}:{{.Tag}}'" &
        done
        wait
    fi
else
    echo ""
    echo "=== Phase 2: Skipped ==="
    if [[ -n "$SKIP_DISTRIBUTE" && "$SKIP_DISTRIBUTE" == "1" ]]; then
        echo "  (SKIP_DISTRIBUTE=1)"
    else
        echo "  (no remote hosts in fleet)"
    fi
fi

# ── Phase 3: Launch AlexNet training on all hosts in parallel ──
if [[ "$SKIP_LAUNCH" != "1" ]]; then
    echo ""
    echo "=== Phase 3: Launch AlexNet training on fleet ==="

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "  DRY_RUN=1: would launch training on:"
        for host in "${_hosts[@]}"; do
            if [[ "$host" == "$LOCAL_HOST" ]]; then
                echo "    local:  EPOCHS='$EPOCHS' BATCH_SIZE='$BATCH_SIZE' bash $SCRIPT_DIR/alexnet-train.sh"
            else
                ip="${REMOTE_HOSTS[$host]:-<unresolved>}"
                echo "    ssh $ip:  EPOCHS='$EPOCHS' BATCH_SIZE='$BATCH_SIZE' bash ~/alexnet-fleet-scripts/alexnet-train.sh"
            fi
        done
    else
        # For-loop over FLEET — using prefix-envvar pattern (EPOCHS='…' BATCH_SIZE='…'
        # ssh "$ip" "command") instead of nested quoting, so the remote gets a clean
        # `EPOCHS=N BATCH_SIZE=M bash ~/alexnet-fleet-scripts/alexnet-train.sh` line.
        for host in "${_hosts[@]}"; do
            echo "  → $host"
            if [[ "$host" == "$LOCAL_HOST" ]]; then
                EPOCHS="$EPOCHS" BATCH_SIZE="$BATCH_SIZE" \
                    bash "$SCRIPT_DIR/alexnet-train.sh" &
            else
                ip="${REMOTE_HOSTS[$host]:-}"
                if [[ -z "$ip" ]]; then
                    echo "    SKIP: no Tailscale IP for $host"
                    continue
                fi
                # Prefix-envvar pattern: the outer assignment goes to ssh's
                # env (cleanly namespaced to that process), and the inner
                # double-quoted string interpolates EPOCHS/BATCH_SIZE into the
                # remote command's prefix. Net effect on remote: clean
                # `EPOCHS=N BATCH_SIZE=M bash ~/alexnet-fleet-scripts/...`.
                EPOCHS="$EPOCHS" BATCH_SIZE="$BATCH_SIZE" \
                    ssh "$ip" "EPOCHS='$EPOCHS' BATCH_SIZE='$BATCH_SIZE' bash ~/alexnet-fleet-scripts/alexnet-train.sh" &
            fi
        done
        wait
        echo ""
        echo "All training jobs launched. Monitor individually:"
        for host in "${_hosts[@]}"; do
            if [[ "$host" == "$LOCAL_HOST" ]]; then
                echo "  podman logs -f alexnet-training  (this host)"
            else
                ip="${REMOTE_HOSTS[$host]:-}"
                [[ -n "$ip" ]] && echo "  ssh $ip 'podman logs -f alexnet-training'"
            fi
        done
    fi
else
    echo ""
    echo "=== Phase 3: Skipped (SKIP_LAUNCH=1) ==="
fi

# ── Phase 4: Collect results hint ──
echo ""
echo "=== Fleet deployment complete ==="
echo ""
echo "When all training jobs finish, collect results centrally:"
echo "  bash $SCRIPT_DIR/alexnet-collect-results.sh"
echo ""
echo "Or with a custom central directory:"
echo "  CENTRAL_DIR=~/alexnet-fleet-results-$(date +%Y%m%d) \\"
echo "    bash $SCRIPT_DIR/alexnet-collect-results.sh"
echo ""
echo "To tear down training containers on the fleet (e.g. if a host crashed mid-epoch):"
echo "  for h in \$FLEET; do ssh \$h 'podman rm -f alexnet-training'; done"
echo "  (Or run e2e/alexnet-train.sh on each host with --recover if you support it.)"
