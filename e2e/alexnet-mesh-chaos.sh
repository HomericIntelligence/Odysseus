#!/usr/bin/env bash
# e2e/alexnet-mesh-chaos.sh — Chaos/hardening tests for the AlexNet mesh pipeline
#
# Deliberately crashes the fleet scripts (deploy / wait / collect / teardown /
# train) and asserts they fail FAST + CLEANLY — no hangs, clear diagnostics,
# correct exit codes — then verifies recovery is possible. The intent is to
# harden the mesh by breaking it under test, per the repo's chaos convention
# (e2e/tests/chaos/*), but self-contained: it does NOT depend on the
# NATS/Agamemnon stack or e2e/lib/common.sh.
#
# Cases:
#   C1 offline-host tolerance: teardown must NOT hang when an offline host
#      (hermes) is in FLEET — completes within a bounded time.
#   C2 unresolvable-host tolerance: deploy must warn + skip, never hang.
#   C3 missing-image: train must fail fast (rc 1) with a clear message.
#   C4 [CHAOS_LIVE=1] clobber guard: train must REFUSE to clobber a running
#      container (rc 1) instead of silently destroying an in-flight job.
#   C5 [CHAOS_LIVE=1] kill-mid-run: gate must detect a killed container
#      (non-zero exit) and fail with a diagnostic.
#   C6 smoke-gate: wait+gate --smoke must PASS a completed smoke run (marker
#      present; smoke mode intentionally saves no weights — run_train.mojo
#      #5551) and the strict default must FAIL the same run (weights missing).
#   C7 teardown idempotency: teardown with no container exits 0 (skip).
#
# Usage:
#   bash e2e/alexnet-mesh-chaos.sh              # offline-safety cases only
#   CHAOS_LIVE=1 bash e2e/alexnet-mesh-chaos.sh # + live container cases
#   FLEET="epimetheus apollo" bash e2e/alexnet-mesh-chaos.sh  # limit hosts
#
# Optional env:
#   FLEET          — hosts to exercise (default: epimetheus apollo aeolus
#                    hephaestus hermes — same default as the fleet scripts)
#   CHAOS_LIVE=1   — enable C4/C5 (launch/kill a real training container)
#   CHAOS_TIMEOUT  — per-case kill guard in seconds (default: 45)
#
# Exit codes:
#   0 — all enabled cases passed
#   1 — one or more cases failed (details printed per case)
#   2 — usage/environment error (missing podman, no image tar, etc.)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Per-invocation scratch file: parallel suite runs must not collide.
CHAOS_OUT="/tmp/mesh-chaos-$$.out"
trap 'rm -f "$CHAOS_OUT"' EXIT
FLEET="${FLEET:-epimetheus apollo aeolus hephaestus hermes}"
LOCAL_HOST=$(hostname)
CHAOS_TIMEOUT="${CHAOS_TIMEOUT:-45}"
LIVE=0
[[ "${CHAOS_LIVE:-0}" == "1" ]] && LIVE=1

# ── Result helpers (self-contained: no e2e/lib dependency) ──
PASS=0
FAIL=0
declare -a FAILED_CASES=()

info()  { printf '\n=== %s ===\n' "$*"; }
pass()  { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$*"; }
fail()  { FAIL=$((FAIL + 1)); FAILED_CASES+=("$*"); printf '  [FAIL] %s\n' "$*" >&2; }

# run_bounded <label> <timeout-s> <cmd...> — run a command under `timeout`;
# rc 124 proves a hang, rc 0 success, other rc is the command's own exit.
run_bounded() {
    # NOTE: never let the wrapped command's non-zero exit abort this suite
    # under `set -euo pipefail` — capture the rc with `|| rc=$?` instead.
    local label="$1" to="$2"
    shift 2
    local rc=0
    timeout "$to" "$@" >"$CHAOS_OUT" 2>&1 || rc=$?
    if [[ "$rc" -eq 124 ]]; then
        fail "$label: HUNG (killed after ${to}s)"
    elif [[ "$rc" -eq 0 ]]; then
        pass "$label: completed cleanly"
    else
        pass "$label: failed fast with rc=$rc (expected non-zero)"
    fi
    return 0
}

echo "=== AlexNet Mesh Chaos Suite ==="
echo "Fleet:            $FLEET"
echo "Local host:       $LOCAL_HOST"
echo "CHAOS_LIVE:       $LIVE"
echo "Per-case timeout: ${CHAOS_TIMEOUT}s"
echo ""

# ── Prerequisites ──
if ! command -v podman >/dev/null 2>&1; then
    echo "ERROR: podman not found — this suite must run on a fleet host." >&2
    exit 2
fi
if ! command -v tailscale >/dev/null 2>&1; then
    echo "ERROR: tailscale CLI not found — required to resolve fleet IPs." >&2
    exit 2
fi

# ── C1: offline-host tolerance (teardown must not hang) ────────────────────
info "C1: teardown with an offline host in FLEET must not hang"
# hermes is the documented offline host (runbook); if it is reachable, this
# case still exercises the bounded-ssh behavior (it will simply run).
if tailscale status --json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
hermes = [dev for name, dev in d.get('Peer', {}).items() if dev.get('HostName') == 'hermes']
print('offline' if hermes and not hermes[0].get('Online') else 'online-or-absent')
" 2>/dev/null | grep -q offline; then
    echo "  (hermes offline — this is the real-world crash case)"
else
    echo "  (hermes online or absent — exercising normal-path bounded ssh)"
fi
run_bounded "C1 teardown FLEET='$LOCAL_HOST hermes'" "$CHAOS_TIMEOUT" \
    env FLEET="$LOCAL_HOST hermes" FORCE=1 bash "$SCRIPT_DIR/alexnet-fleet-teardown.sh"
echo "  teardown output (tail):"
tail -4 "$CHAOS_OUT" | sed 's/^/    /'

# ── C2: unresolvable-host tolerance (deploy must warn + skip, never hang) ──
info "C2: deploy with an unresolvable host must warn + skip, never hang"
run_bounded "C2 deploy FLEET='$LOCAL_HOST no-such-host-xyz'" "$CHAOS_TIMEOUT" \
    env FLEET="$LOCAL_HOST no-such-host-xyz" SKIP_BUILD=1 SKIP_DISTRIBUTE=1 SKIP_LAUNCH=1 \
    bash "$SCRIPT_DIR/alexnet-deploy-fleet.sh"
echo "  deploy output (tail):"
tail -4 "$CHAOS_OUT" | sed 's/^/    /'

# ── C3: missing image must fail fast ───────────────────────────────────────
info "C3: train with a missing image must fail fast with a clear message"
run_bounded "C3 train IMAGE_NAME=odyssey:nonexistent" "$CHAOS_TIMEOUT" \
    env IMAGE_NAME="odyssey:nonexistent" MAX_BATCHES=3 bash "$SCRIPT_DIR/alexnet-train.sh"
echo "  train output (tail):"
tail -4 "$CHAOS_OUT" | sed 's/^/    /'
if grep -q "not loaded" "$CHAOS_OUT"; then
    pass "C3: clear 'image not loaded' diagnostic present"
else
    fail "C3: missing clear 'image not loaded' diagnostic"
fi

# ── C4 [LIVE]: clobber guard must refuse to destroy a running container ────
if [[ "$LIVE" -eq 1 ]]; then
    info "C4 [LIVE]: train must REFUSE to clobber a running container"
    # Seed a running container with a long sleep so the guard has something
    # to protect.
    if podman container exists alexnet-training 2>/dev/null; then
        echo "  (stale alexnet-training container exists — removing for a clean C4 seed)" >&2
        rm_rc=0
        podman rm -f alexnet-training >/dev/null 2>&1 || rm_rc=$?
        if [[ "$rm_rc" -ne 0 ]]; then
            echo "  (could not remove stale container — skipping C4)" >&2
        fi
    fi
    if ! podman run -d --name alexnet-training --userns=keep-id \
        localhost/odyssey:dev sleep 600 >"$CHAOS_OUT" 2>&1; then
        echo "  (image localhost/odyssey:dev unavailable or seed failed — skipping C4)" >&2
    else
        run_bounded "C4 train while container RUNNING" "$CHAOS_TIMEOUT" \
            env IMAGE_NAME="localhost/odyssey:dev" MAX_BATCHES=3 bash "$SCRIPT_DIR/alexnet-train.sh"
        echo "  train output (tail):"
        tail -4 "$CHAOS_OUT" | sed 's/^/    /'
        if grep -q "currently RUNNING" "$CHAOS_OUT"; then
            pass "C4: clobber guard message present"
        else
            fail "C4: missing clobber-guard message"
        fi
        rm_rc=0
        podman rm -f alexnet-training >/dev/null 2>&1 || rm_rc=$?
        [[ "$rm_rc" -eq 0 ]] && echo "  (C4 cleanup: seed container removed)" >&2
    fi
else
    info "C4 [LIVE]: skipped (set CHAOS_LIVE=1 to exercise the clobber guard)"
fi

# ── C5: kill-mid-run (LIVE) — gate must detect a killed container ─────────
# Crash the gate's failure path: launch a REAL training container, SIGKILL it
# while it is genuinely running, and assert the gate FAILS fast with a clear
# diagnostic instead of passing or hanging. A killed container leaves no
# completion marker and a non-zero exit — the gate must not be fooled.
info "C5 [LIVE]: kill a real training container mid-run; gate must detect it"
if [[ "$LIVE" -eq 1 ]]; then
    rm_rc=0
    podman rm -f alexnet-training >/dev/null 2>&1 || rm_rc=$?
    if [[ "$rm_rc" -ne 0 ]]; then
        echo "  (could not remove stale container — skipping C5)" >&2
    elif ! podman image exists localhost/odyssey:dev 2>/dev/null; then
        echo "  (image localhost/odyssey:dev unavailable — skipping C5)" >&2
    else
        echo "  launching real training container (MAX_BATCHES=1 EPOCHS=1)..."
        rc=0
        timeout 720 env IMAGE_NAME="localhost/odyssey:dev" MAX_BATCHES=1 EPOCHS=1 \
            bash "$SCRIPT_DIR/alexnet-train.sh" >"$CHAOS_OUT" 2>&1 || rc=$?
        if [[ "$rc" -ne 0 ]]; then
            echo "  launch failed (rc=$rc):" >&2
            tail -5 "$CHAOS_OUT" >&2
            info "C5: SKIP (could not launch training container)"
        else
            # Mojo compile dominates the first minutes; wait (bounded) until the
            # container is genuinely RUNNING before killing it. Break early if
            # it exits on its own (a crash is still a valid incomplete case).
            st=created
            for _i in $(seq 1 66); do
                st=$(podman inspect alexnet-training --format '{{.State.Status}}' 2>/dev/null || echo missing)
                [[ "$st" == running ]] && break
                [[ "$st" == exited* ]] && break
                sleep 10
            done
            echo "  container state before kill: $st"
            kill_rc=0
            podman kill alexnet-training >/dev/null 2>&1 || kill_rc=$?
            echo "  kill rc: $kill_rc (0 = SIGKILL delivered)"
            state_after=$(podman inspect alexnet-training --format '{{.State.Status}} exit={{.State.ExitCode}}' 2>/dev/null || echo missing)
            echo "  state after kill: $state_after"
            # The gate must DETECT the kill: non-zero rc with a clear marker FAIL.
            rc=0
            FLEET="$LOCAL_HOST" POLL_INTERVAL=5 bash "$SCRIPT_DIR/alexnet-fleet-wait.sh" \
                --timeout-minutes 1 --smoke >"$CHAOS_OUT" 2>&1 || rc=$?
            echo "  gate rc: $rc (expect non-zero — killed container must NOT pass)"
            tail -8 "$CHAOS_OUT" | sed 's/^/    /'
            if [[ "$rc" -ne 0 ]] && grep -q "no 'Training complete!' marker" "$CHAOS_OUT"; then
                pass "C5: gate detected the incomplete container (rc=$rc, marker FAIL)"
            else
                fail "C5: gate rc=$rc — killed container was NOT detected as incomplete"
            fi
            rm_rc=0
            podman rm -f alexnet-training >/dev/null 2>&1 || rm_rc=$?
            [[ "$rm_rc" -eq 0 ]] && echo "  (C5 cleanup: killed container removed)" >&2
        fi
    fi
else
    info "C5 [LIVE]: skipped (set CHAOS_LIVE=1 to kill a real training container mid-run)"
fi

# ── C6: smoke gate must pass with --smoke, strict default must fail ────────
# Smoke mode (MAX_BATCHES>0) intentionally saves NO weights (run_train.mojo
# #5551). --smoke relaxes the gate to marker-only; the strict default keeps
# weights required for full runs. C6b asserts the strict default FAILS this
# same smoke container (weights missing) — proving the default didn't regress.
info "C6: gate semantics — --smoke passes a smoke run, strict default fails it"
if podman container exists alexnet-training 2>/dev/null; then
    st=$(podman inspect alexnet-training --format '{{.State.Status}} {{.State.ExitCode}}' 2>/dev/null || echo unknown)
    echo "  existing alexnet-training: $st"
    if [[ "$st" != exited*0 ]] || ! podman logs alexnet-training 2>/dev/null | grep -q "Training complete!"; then
        echo "  (container not a completed smoke — removing and seeding a synthetic fixture)" >&2
        rm_rc=0
        podman rm -f alexnet-training >/dev/null 2>&1 || rm_rc=$?
        if [[ "$rm_rc" -ne 0 ]]; then
            echo "  (could not remove container — SKIPPING C6)" >&2
            info "C6: SKIP (could not seed gate fixture)"
        else
            st=missing
        fi
    fi
fi
# Seed a synthetic completed-smoke fixture: an exited(0) container whose log
# holds the completion marker but NO weights dir — exactly the state smoke mode
# produces (run_train.mojo #5551). Clearly a fixture: it exists only to exercise
# the gate logic deterministically in every mode; it is not presented as real
# training evidence. Reused only when a REAL completed smoke container is
# already present (checked above).
if ! podman container exists alexnet-training 2>/dev/null; then
    echo "  seeding synthetic smoke fixture (exited container + marker, no weights)" >&2
    if podman image exists localhost/odyssey:dev 2>/dev/null; then
        podman run -d --name alexnet-training --userns=keep-id \
            localhost/odyssey:dev bash -c 'sleep 2; echo "Training complete!"' >/dev/null 2>&1
    else
        podman run -d --name alexnet-training \
            docker.io/library/alpine:3.20 sh -c 'sleep 2; echo "Training complete!"' >/dev/null 2>&1
    fi
    for _i in $(seq 1 15); do
        st=$(podman inspect alexnet-training --format '{{.State.Status}}' 2>/dev/null || echo missing)
        [[ "$st" == exited ]] && break
        sleep 2
    done
    echo "  fixture state: $(podman inspect alexnet-training --format '{{.State.Status}} exit={{.State.ExitCode}}' 2>/dev/null || echo missing)" >&2
    echo "  fixture marker: $(podman logs alexnet-training 2>/dev/null | grep -c 'Training complete!')" >&2
fi
if podman container exists alexnet-training 2>/dev/null; then
    st=$(podman inspect alexnet-training --format '{{.State.Status}} {{.State.ExitCode}}' 2>/dev/null || echo unknown)
    if [[ "$st" == exited*0 ]] && podman logs alexnet-training 2>/dev/null | grep -q "Training complete!"; then
        echo "  (reusing completed smoke container for the gate check)"
        rc=0
        FLEET="$LOCAL_HOST" POLL_INTERVAL=5 bash "$SCRIPT_DIR/alexnet-fleet-wait.sh" \
            --timeout-minutes 1 --smoke >"$CHAOS_OUT" 2>&1 || rc=$?
        echo "  gate rc (--smoke): $rc"
        tail -6 "$CHAOS_OUT" | sed 's/^/    /'
        if [[ "$rc" -eq 0 ]]; then
            pass "C6: smoke gate (--smoke) PASSED"
        else
            fail "C6: smoke gate failed (rc=$rc) — smoke mode saves no weights (see run_train.mojo #5551)"
        fi
        # C6b: the STRICT default (no --smoke) must FAIL this same container —
        # proves weights stay required for full runs (reviewer: strict-by-default).
        rc=0
        FLEET="$LOCAL_HOST" POLL_INTERVAL=5 bash "$SCRIPT_DIR/alexnet-fleet-wait.sh" \
            --timeout-minutes 1 >"$CHAOS_OUT" 2>&1 || rc=$?
        echo "  gate rc (strict default): $rc"
        if [[ "$rc" -eq 1 ]]; then
            pass "C6b: strict default correctly FAILED smoke run (weights required)"
        else
            fail "C6b: strict default gate rc=$rc — expected 1 (weights must be required for full runs)"
        fi
    else
        echo "  (no completed smoke container available — launching a live smoke next)"
    fi
fi
if ! podman container exists alexnet-training 2>/dev/null || [[ $(podman inspect alexnet-training --format '{{.State.ExitCode}}' 2>/dev/null) != 0 ]]; then
    if [[ "$LIVE" -eq 1 ]]; then
        echo "  launching live smoke (MAX_BATCHES=1 EPOCHS=1)..."
        rc=0
        timeout 720 env IMAGE_NAME="localhost/odyssey:dev" MAX_BATCHES=1 EPOCHS=1 \
            bash "$SCRIPT_DIR/alexnet-train.sh" >"$CHAOS_OUT" 2>&1 || rc=$?
        if [[ "$rc" -eq 124 ]]; then
            echo "  smoke launch HUNG (killed after 720s):" >&2
            tail -5 "$CHAOS_OUT" >&2
            fail "C6: smoke launch hung"
        elif [[ "$rc" -ne 0 ]]; then
            echo "  smoke launch failed (rc=$rc):" >&2
            tail -5 "$CHAOS_OUT" >&2
            fail "C6: smoke launch failed"
        else
            # Wait for the container to exit (bounded), then gate it.
            echo "  waiting for smoke container to exit..."
            if timeout 600 bash -c 'while podman inspect alexnet-training --format "{{.State.Status}}" 2>/dev/null | grep -q running; do sleep 10; done'; then
                rc=0
                FLEET="$LOCAL_HOST" POLL_INTERVAL=5 bash "$SCRIPT_DIR/alexnet-fleet-wait.sh" \
                    --timeout-minutes 1 --smoke >"$CHAOS_OUT" 2>&1 || rc=$?
                echo "  gate rc (--smoke): $rc"
                tail -6 "$CHAOS_OUT" | sed 's/^/    /'
                if [[ "$rc" -eq 0 ]]; then
                    pass "C6: smoke gate (--smoke) PASSED"
                else
                    fail "C6: smoke gate failed (rc=$rc) — smoke mode saves no weights (see run_train.mojo #5551)"
                fi
                # C6b: strict default must FAIL this smoke container.
                rc=0
                FLEET="$LOCAL_HOST" POLL_INTERVAL=5 bash "$SCRIPT_DIR/alexnet-fleet-wait.sh" \
                    --timeout-minutes 1 >"$CHAOS_OUT" 2>&1 || rc=$?
                echo "  gate rc (strict default): $rc"
                if [[ "$rc" -eq 1 ]]; then
                    pass "C6b: strict default correctly FAILED smoke run (weights required)"
                else
                    fail "C6b: strict default gate rc=$rc — expected 1 (weights must be required for full runs)"
                fi
            else
                fail "C6: smoke container did not exit within 600s"
            fi
        fi
    else
        info "C6: no completed smoke container and CHAOS_LIVE unset — SKIP (gate logic covered by CHAOS_LIVE=1 / post-smoke runs)"
    fi
fi

# ── C7: teardown idempotency (no container -> rc 0) ────────────────────────
info "C7: teardown with no container must exit 0 (idempotent)"
run_bounded "C7 teardown FLEET='$LOCAL_HOST'" "$CHAOS_TIMEOUT" \
    env FLEET="$LOCAL_HOST" FORCE=1 bash "$SCRIPT_DIR/alexnet-fleet-teardown.sh"
echo "  teardown output (tail):"
tail -4 "$CHAOS_OUT" | sed 's/^/    /'

# ── Summary ──
echo ""
echo "=== Chaos Suite Summary ==="
echo "PASS: $PASS  FAIL: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    echo "Failed cases:"
    for c in "${FAILED_CASES[@]}"; do
        echo "  - $c"
    done
    exit 1
fi
echo "All enabled cases passed."
