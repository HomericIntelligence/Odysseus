#!/usr/bin/env bash
# e2e/alexnet-collect-results.sh — Central result collection for the AlexNet fleet
#
# rsyncs training outputs from all fleet hosts over Tailscale to a central
# directory (typically epimetheus) and prints a comparison summary.
#
# Usage:
#   bash e2e/alexnet-collect-results.sh                        # default: ~/alexnet-fleet-results
#   CENTRAL_DIR=~/<path> bash e2e/alexnet-collect-results.sh
#   FLEET="epimetheus apollo aeolus" bash e2e/alexnet-collect-results.sh  # subset
#
# Required env (FLEET is optional — defaults to all 5 hosts):
#   (none — defaults to FLEET="epimetheus apollo aeolus hephaestus hermes")
#
# Optional env:
#   FLEET           — space-separated host list (default: epimetheus apollo aeolus hephaestus hermes)
#   CENTRAL_DIR     — central results root (default: ~/alexnet-fleet-results)
#   REMOTE_RESULTS_DIR — host-side results subdir (default: ~/alexnet-results)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Configuration ──
FLEET="${FLEET:-epimetheus apollo aeolus hephaestus hermes}"
CENTRAL_DIR="${CENTRAL_DIR:-$HOME/alexnet-fleet-results}"
REMOTE_RESULTS_DIR="${REMOTE_RESULTS_DIR:-alexnet-results}"

mkdir -p "$CENTRAL_DIR"

# ── Parse FLEET into a glob-safe array (must happen BEFORE any iteration) ──
# Avoid `for host in $FLEET` — that would pathname-expand if FLEET accidentally
# contained a glob like 'epimeth*'. Empty FLEET silently skips every host.
IFS=' ' read -ra _hosts <<< "$FLEET"
TOTAL_HOSTS=${#_hosts[@]}

# ── Resolve Tailscale IPs (resilient to Tailscale restarts) ──
declare -A HOST_IPS
if command -v tailscale >/dev/null 2>&1; then
    for host in "${_hosts[@]}"; do
        if [[ "$host" == "$(hostname)" || "$host" == "localhost" ]]; then
            HOST_IPS[$host]="localhost"
        else
            # tailscale status --json returns an object keyed by Peer.<id>; iterate
            HOST_IPS[$host]=$(tailscale status --json 2>/dev/null \
                | jq -r --arg h "$host" \
                '.Peer // {} | to_entries[] | .value | select(.HostName == $h) | .TailscaleIPs[0]' \
                2>/dev/null || echo "")
            if [[ -z "${HOST_IPS[$host]}" ]]; then
                echo "WARNING: Could not resolve Tailscale IP for '$host'" >&2
            fi
        fi
    done
else
    echo "ERROR: tailscale CLI not found. This script requires Tailscale on the central host." >&2
    exit 1
fi

# ── Collect from each host ──
echo "=== Collecting AlexNet training results from fleet ==="
echo "Fleet:       $FLEET"
echo "Central to:  $CENTRAL_DIR"
echo ""

# Count hosts from the FLEET string. TOTAL_HOSTS is set above (parse-block hoisted
# before any iteration).

COLLECTED=0
MISSING=()
for host in "${_hosts[@]}"; do
    ip="${HOST_IPS[$host]:-}"

    # Skip unresolvable hosts (they were warned about above; don't fail the whole run)
    if [[ -z "$ip" ]]; then
        echo "  ✗ $host (no Tailscale IP — skipping)"
        MISSING+=("$host")
        continue
    fi

    dest="$CENTRAL_DIR/$host"
    mkdir -p "$dest"

    echo "  → $host ($ip)"
    if [[ "$ip" == "localhost" ]]; then
        # Local copy
        src="$HOME/$REMOTE_RESULTS_DIR/$host"
        if [[ -d "$src" ]]; then
            cp -r "$src"/. "$dest"/ 2>/dev/null
            COLLECTED=$((COLLECTED + 1))
            echo "    [ok] collected from $src"
        else
            echo "    [skip] $src does not exist"
            MISSING+=("$host (no local results)")
        fi
    else
        # Remote rsync over Tailscale
        remote_src="${ip}:~/${REMOTE_RESULTS_DIR}/${host}/"
        # rsync exits non-zero if some files couldn't be transferred; treat any output
        # as informational and check whether destination is non-empty.
        set +e
        rsync_out=$(rsync -az --info=stats2 "$remote_src" "$dest/" 2>&1)
        rsync_status=$?
        set -e
        if [[ -d "$dest" ]] && ls "$dest"/* >/dev/null 2>&1; then
            COLLECTED=$((COLLECTED + 1))
            echo "    [ok] collected (rsync exit=$rsync_status)"
        else
            echo "    [skip] no results on $host (rsync exit=$rsync_status)"
            MISSING+=("$host (rsync failed or empty)")
        fi
    fi
done

# ── Summary ──
echo ""
echo "=== Fleet Results Summary ==="
echo "Central directory: $CENTRAL_DIR"
echo "Collected: $COLLECTED / $TOTAL_HOSTS hosts"
if (( ${#MISSING[@]} > 0 )); then
    echo "Missing:"
    for m in "${MISSING[@]}"; do
        echo "  - $m"
    done
fi
echo ""
# ── Pull final training markers from a host's container log ──
# Full training output streams to the container log driver (podman logs), NOT
# to training.log (which carries only the launch header). Best-effort: the
# training container may already have been torn down, and rootless podman over
# a non-interactive ssh may not resolve its runtime dir.
# Rootless podman over a non-interactive ssh needs the user runtime dir — same
# preamble as e2e/alexnet-fleet-wait.sh. Single-quoted so `$(id -u)` stays
# literal here and is evaluated by the REMOTE shell.
# shellcheck disable=SC2016
REMOTE_PODMAN_PREFIX='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus'

extract_podman_markers() {
    # No `|| true` here (repo no-silent-failures rule): "no markers found" or an
    # unreachable host is an explicit non-zero exit the caller handles in an
    # `if` condition. See docs/runbooks/no-silent-failures.md Bucket D.
    local ip="$1"
    local pat="Training complete|Average Loss|Test Accuracy"
    if [[ "$ip" == "localhost" ]]; then
        podman logs alexnet-training 2>/dev/null | grep -E "$pat" | tail -3
    else
        timeout 10 ssh -o ConnectTimeout=5 "$ip" \
            "$REMOTE_PODMAN_PREFIX; podman logs alexnet-training 2>/dev/null | grep -E '$pat' | tail -3" \
            2>/dev/null
    fi
}

for host_dir in "$CENTRAL_DIR"/*/; do
    [[ -d "$host_dir" ]] || continue
    host=$(basename "$host_dir")
    log="$host_dir/training.log"

    echo "── $host ──"
    if [[ -f "$log" ]]; then
        # Launch-header markers (rare; some configs also log the header summary).
        # Explicit if-guard per no-silent-failures.md Bucket D: a grep with no
        # matches exits 1, which is the intended "no markers" branch, not a
        # swallowed failure.
        if status=$(grep -E "Training complete!|Average Loss:|Test Accuracy:|Completed:" "$log" | tail -3); then
            echo "$status" | sed 's/^/  /'
        else
            # training.log holds only the launch header — real markers live in
            # the container's log driver on the host. Pull them best-effort.
            if markers=$(extract_podman_markers "$ip"); then
                echo "$markers" | sed 's/^/  /'
            elif [[ -d "$host_dir/alexnet_weights" ]]; then
                echo "  (weights present — run completed; container log no longer available)"
            else
                echo "  (no completion markers — training incomplete or container torn down)"
                tail -3 "$log" | sed 's/^/  /'
            fi
        fi
        if [[ -d "$host_dir/alexnet_weights" ]]; then
            n=$(ls "$host_dir/alexnet_weights" 2>/dev/null | wc -l)
            echo "  weights: $n files"
        fi
    else
        echo "  (no training.log found)"
    fi
    echo ""
done

echo "Per-host results inspection:"
echo "  ls -la $CENTRAL_DIR/<hostname>/"
echo "  cat $CENTRAL_DIR/<hostname>/training.log   # launch header / config only"
echo "  podman logs alexnet-training               # full training output (on each host)"
