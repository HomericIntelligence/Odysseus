#!/usr/bin/env bash
# e2e/alexnet-fleet-wait.sh — Wait for AlexNet fleet training to finish, then gate
#
# e2e/alexnet-deploy-fleet.sh launches training detached on every fleet host and
# returns immediately. This script is the "gated" counterpart: it polls every
# host's `alexnet-training` container until all have exited (or a deadline
# passes), then — unless --no-gate — verifies completion evidence per host:
#   - `podman logs alexnet-training` contains "Training complete!"
#   - ~/alexnet-results/<host>/alexnet_weights/ is non-empty
# and exits non-zero if any host fails, so a CI job calling this fails the gate.
#
# Smoke runs (MAX_BATCHES>0) intentionally save NO weights (run_train.mojo
# #5551) — pass --smoke to relax the weights requirement to a non-fatal note;
# the completion marker remains the gate. Full 100-epoch runs stay strict.
#
# Usage:
#   bash e2e/alexnet-fleet-wait.sh                # wait 150 min, then gate (strict)
#   --timeout-minutes 90                          # shorter deadline
#   --no-gate                                     # wait only, no completion check
#   --smoke                                       # smoke run: marker-only gate
#   FLEET="epimetheus apollo" bash e2e/alexnet-fleet-wait.sh
#
# Optional env:
#   FLEET           — space-separated host list (default: same 5 as deploy-fleet)
#   RESULTS_DIR     — per-host results root for the weights check (default: alexnet-results)
#   POLL_INTERVAL   — seconds between polls (default: 60)
#
# Exit codes:
#   0 — all hosts exited AND (gate on) all hosts have completion evidence
#   1 — deadline passed with hosts still running, or gate evidence missing
#   2 — usage/environment error (bad flag, missing podman, unresolvable host)
#
# See docs/runbooks/alexnet-mesh-fleet.md for the full fleet deployment plan.

set -euo pipefail

# ── Configuration ──
FLEET="${FLEET:-epimetheus apollo aeolus hephaestus hermes}"
RESULTS_DIR="${RESULTS_DIR:-alexnet-results}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
TIMEOUT_MINUTES=150
GATE=1
# Weights are REQUIRED by default (full 100-epoch runs). Smoke runs
# (MAX_BATCHES>0) intentionally save NO weights (run_train.mojo #5551) — the
# completion marker is the correct smoke gate, so --smoke relaxes the weights
# requirement to a non-fatal note.
REQUIRE_WEIGHTS=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout-minutes)
            TIMEOUT_MINUTES="$2"
            shift 2
            ;;
        --no-gate)
            GATE=0
            shift
            ;;
        --smoke)
            REQUIRE_WEIGHTS=0
            shift
            ;;
        *)
            echo "ERROR: unknown flag '$1' (supported: --timeout-minutes N, --no-gate, --smoke)" >&2
            exit 2
            ;;
    esac
done

if ! command -v podman >/dev/null 2>&1; then
    echo "ERROR: podman not found on this host — this script must run on a fleet host." >&2
    exit 2
fi

LOCAL_HOST=$(hostname)

# Parse FLEET into a glob-safe array (same pattern as deploy/collect scripts —
# `for host in $FLEET` would pathname-expand if FLEET ever contained a glob).
IFS=' ' read -ra _hosts <<< "$FLEET"

# ── Resolve Tailscale IPs (same pattern as deploy/collect scripts) ──
declare -A HOST_IPS
for host in "${_hosts[@]}"; do
    if [[ "$host" == "$LOCAL_HOST" || "$host" == "localhost" ]]; then
        HOST_IPS[$host]="localhost"
    else
        HOST_IPS[$host]=$(tailscale status --json 2>/dev/null \
            | jq -r --arg h "$host" \
                '.Peer // {} | to_entries[] | .value | select(.HostName == $h) | .TailscaleIPs[0]' \
            2>/dev/null || echo "")
    fi
done

# ── Remote podman over rootless ssh: same env exports doctor.sh step 8 needs ──
# Single-quoted literal keeps `$(id -u)` unexpanded here; it is evaluated by
# the REMOTE shell after ssh (expanded variables are never re-scanned locally).
# shellcheck disable=SC2016
REMOTE_PODMAN_PREFIX='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus'

# SSH_CONNECT_OPTS guards every remote probe so a wedged remote host (e.g. a
# stuck podman) cannot hang the poll or gate step indefinitely.
SSH_BASE=(timeout 15 ssh -o ConnectTimeout=5 -o BatchMode=yes)

# ── Per-host helpers ──
# state <ip> → "exited <code>" | "running" | "created" | "missing" | "ssh-fail"
state() {
    local ip="$1"
    if [[ "$ip" == "localhost" ]]; then
        podman inspect alexnet-training --format '{{.State.Status}} {{.State.ExitCode}}' 2>/dev/null \
            || echo "missing"
    else
        "${SSH_BASE[@]}" "$ip" "
            $REMOTE_PODMAN_PREFIX
            podman inspect alexnet-training --format '{{.State.Status}} {{.State.ExitCode}}' 2>/dev/null || echo missing
        " 2>/dev/null || echo "ssh-fail"
    fi
}

# has_marker <ip> → 0 if container log contains "Training complete!", non-zero otherwise
# Retries: `podman logs` on an exited rootless container is flaky (observed
# missing the final lines ~1/10 reads in crash testing) — a single read could
# false-fail the gate. Retry up to 3x with a 2s pause before declaring absence.
has_marker() {
    local ip="$1" attempt=0
    while [[ "$attempt" -lt 3 ]]; do
        if [[ "$ip" == "localhost" ]]; then
            if podman logs alexnet-training 2>/dev/null | grep -q "Training complete!"; then
                return 0
            fi
        else
            if "${SSH_BASE[@]}" "$ip" "
                $REMOTE_PODMAN_PREFIX
                podman logs alexnet-training 2>/dev/null | grep -q 'Training complete!'
            " 2>/dev/null; then
                return 0
            fi
        fi
        attempt=$((attempt + 1))
        [[ "$attempt" -lt 3 ]] && sleep 2
    done
    return 1
}

# weights_count <ip> <host> → number of files in the host's weights dir
weights_count() {
    local ip="$1" host="$2"
    if [[ "$ip" == "localhost" ]]; then
        # Guard BEFORE find: with a missing weights dir (the normal smoke case),
        # `find missing-dir | wc -l` fails under pipefail and would abort the
        # whole gate via the set -e assignment. Report 0 instead.
        if [[ -d "$HOME/$RESULTS_DIR/$host/alexnet_weights" ]]; then
            find "$HOME/$RESULTS_DIR/$host/alexnet_weights" -type f 2>/dev/null | wc -l
        else
            echo 0
        fi
    else
        "${SSH_BASE[@]}" "$ip" "
            $REMOTE_PODMAN_PREFIX
            find ~/$RESULTS_DIR/$host/alexnet_weights -type f 2>/dev/null | wc -l
        " 2>/dev/null || echo 0
    fi
}

# ── Resolve once, fail fast on unresolvable hosts ──
echo "=== AlexNet fleet wait + gate ==="
echo "Fleet:       $FLEET"
echo "Timeout:     ${TIMEOUT_MINUTES} min (poll every ${POLL_INTERVAL}s)"
if [[ "$GATE" -eq 1 ]]; then
    echo "Gate:        on — require Training complete! $([[ $REQUIRE_WEIGHTS -eq 1 ]] && echo '+ weights' || echo '(weights relaxed for smoke: --smoke)')  [full run: strict | smoke: --smoke]"
else
    echo "Gate:        off — wait only"
fi
echo ""
RESOLVE_FAIL=0
for host in "${_hosts[@]}"; do
    if [[ -z "${HOST_IPS[$host]:-}" ]]; then
        echo "ERROR: cannot resolve Tailscale IP for '$host'" >&2
        RESOLVE_FAIL=1
    fi
done
if [[ "$RESOLVE_FAIL" -eq 1 ]]; then
    exit 2
fi

# ── Poll until all containers exit or deadline ──
deadline=$(( $(date +%s) + TIMEOUT_MINUTES * 60 ))
while :; do
    now=$(date +%s)
    remaining=$(( deadline - now ))
    all_done=1
    line="[$(date -u +%H:%M:%SZ)]"
    for host in "${_hosts[@]}"; do
        st=$(state "${HOST_IPS[$host]}")
        line="$line  $host=$st"
        if [[ "$st" != "exited"* ]]; then
            all_done=0
        fi
    done
    echo "$line"
    if [[ "$all_done" -eq 1 ]]; then
        echo ""
        echo "All fleet training containers exited."
        # Settle: a container that just exited may not have flushed its log to
        # the on-disk driver yet — probing `podman logs` immediately can miss
        # the final lines (observed in crash testing). Give the driver a moment
        # before the gate reads markers/weights.
        echo "Settling 5s for container log flush before gating..."
        sleep 5
        break
    fi
    if (( remaining <= 0 )); then
        echo "" >&2
        echo "ERROR: deadline (${TIMEOUT_MINUTES} min) passed with hosts still not exited:" >&2
        for host in "${_hosts[@]}"; do
            echo "  $host: $(state "${HOST_IPS[$host]}")" >&2
        done
        echo "  Inspect per host: podman logs alexnet-training" >&2
        exit 1
    fi
    sleep "$POLL_INTERVAL"
done

# ── Gate: per-host completion evidence ──
if [[ "$GATE" -eq 1 ]]; then
    echo ""
    echo "=== Gate: verifying completion evidence per host ==="
    FAILURES=0
    for host in "${_hosts[@]}"; do
        ip="${HOST_IPS[$host]}"
        echo "── $host ──"
        marker=0 weights=0
        if has_marker "$ip"; then
            marker=1
            echo "  [ok] Training complete! marker found (podman logs)"
        else
            echo "  [FAIL] no 'Training complete!' marker in podman logs"
        fi
        weights=$(weights_count "$ip" "$host")
        if [[ "$weights" -gt 0 ]]; then
            echo "  [ok] weights: $weights files"
        elif [[ "$REQUIRE_WEIGHTS" -eq 1 ]]; then
            echo "  [FAIL] weights dir empty or missing (required — add --smoke to relax)"
        else
            echo "  [note] no weights — expected for smoke mode (run_train.mojo #5551); marker above is the gate"
        fi
        if [[ "$marker" -ne 1 ]]; then
            FAILURES=$((FAILURES + 1))
        elif [[ "$REQUIRE_WEIGHTS" -eq 1 && "$weights" -eq 0 ]]; then
            FAILURES=$((FAILURES + 1))
        fi
    done
    echo ""
    if [[ "$FAILURES" -gt 0 ]]; then
        echo "GATE FAILED: $FAILURES host(s) missing completion evidence." >&2
        echo "  Full output per host: podman logs alexnet-training (ssh for remotes)" >&2
        exit 1
    fi
    if [[ "$REQUIRE_WEIGHTS" -eq 1 ]]; then
        echo "GATE PASSED: all hosts completed training with weights."
    else
        echo "GATE PASSED: all hosts completed training (smoke gate — marker only, --smoke)."
    fi
fi
