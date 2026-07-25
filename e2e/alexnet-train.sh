#!/usr/bin/env bash
# e2e/alexnet-train.sh — Per-host AlexNet training launcher
#
# Runs an AlexNet training job inside the Odyssey container on a single
# Tailscale mesh host. Each host runs independently (no cross-host gradient
# sync); results are collected centrally by e2e/alexnet-collect-results.sh.
#
# Usage:
#   bash e2e/alexnet-train.sh                     # full 100-epoch training
#   EPOCHS=10 BATCH_SIZE=64 bash e2e/alexnet-train.sh
#   MAX_BATCHES=3 bash e2e/alexnet-train.sh       # smoke test (synthetic data)
#   SMOKE=true bash e2e/alexnet-train.sh          # alias for MAX_BATCHES=3
#
# Required env:
#   WORKSPACE_DIR   — path to Odysseus checkout on this host (default: ~/Projects/Odysseus)
#
# Optional env:
#   EPOCHS          — training epochs (default: 100)
#   BATCH_SIZE      — mini-batch size (default: 128)
#   LEARNING_RATE   — SGD learning rate (default: 0.01)
#   PRECISION       — fp32 | fp16 (default: fp32)
#   MAX_BATCHES     — cap batches per epoch (0 = full dataset). Smoke test: 3.
#   MEM_LIMIT       — container memory limit (default: 14g)
#   CPU_LIMIT       — container CPU limit (default: 4.0)
#   IMAGE_NAME      — podman image tag (default: odyssey:dev)
#   RESULTS_DIR     — host results dir (default: ~/alexnet-results/<hostname>)
#
# The aeolus host (Sandy Bridge-E, AVX-only, no AVX2) gets --target-features -avx2
# automatically — verified by hostname match. Override with FORCE_AVX2=1 if your
# aeolus install has been upgraded with an AVX2-capable CPU.
#
# See docs/runbooks/alexnet-mesh-fleet.md for the full fleet deployment plan.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODYSSEUS_ROOT="$(dirname "$SCRIPT_DIR")"

# ── Configuration ──
HOST_NAME=$(hostname)
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/Projects/Odysseus}"
RESULTS_DIR="${RESULTS_DIR:-$HOME/alexnet-results/$HOST_NAME}"
EPOCHS="${EPOCHS:-100}"
BATCH_SIZE="${BATCH_SIZE:-128}"
LEARNING_RATE="${LEARNING_RATE:-0.01}"
PRECISION="${PRECISION:-fp32}"
# Smoke mode: if SMOKE=true and no explicit MAX_BATCHES set, cap to 3.
if [[ "${SMOKE:-}" == "true" && -z "${MAX_BATCHES:-}" ]]; then
    MAX_BATCHES=3
fi
MAX_BATCHES="${MAX_BATCHES:-0}"
MEM_LIMIT="${MEM_LIMIT:-14g}"
CPU_LIMIT="${CPU_LIMIT:-4.0}"
SHM_SIZE="${SHM_SIZE:-2g}"
IMAGE_NAME="${IMAGE_NAME:-odyssey:dev}"

# ── CPU-specific Mojo target flags ──
# aeolus: Sandy Bridge-E (2012) — AVX only, no AVX2. Mojo JIT may misdetect.
# Strip AVX2 + AVX-512 forcibly. Override with FORCE_AVX2=1 if hardware upgraded.
MOJO_TARGET_FLAGS=""
if [[ "$HOST_NAME" == "aeolus" && "${FORCE_AVX2:-}" != "1" ]]; then
    MOJO_TARGET_FLAGS="--target-features -avx2,-avx512f,-avx512vl,-avx512bw,-avx512dq,-avx512cd,-avx512vnni,-avx512vbmi,-avx512vbmi2,-avx512bitalg,-avx512vpopcntdq,-avx512bf16,-avx512ifma"
fi

# ── Pre-flight checks ──
if ! command -v podman >/dev/null 2>&1; then
    echo "ERROR: podman not found. Install with: sudo apt-get install -y podman podman-compose" >&2
    echo "  Or run: just install-worker (uses e2e/doctor.sh --install)" >&2
    exit 1
fi

# podman-compose build (and rootless podman save+load) tag the resulting image
# as `localhost/$IMAGE_NAME` rather than `$IMAGE_NAME`. Accept both forms so the
# preflight doesn't spuriously fail when the image was built here and rsynced
# to remotes (or vice-versa).
if ! podman images "$IMAGE_NAME" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -qE "^(localhost/)?${IMAGE_NAME}$"; then
    echo "ERROR: Image '$IMAGE_NAME' not loaded (tried '<NAME>' and 'localhost/<NAME>'). Build or distribute first:" >&2
    echo "  Build:   cd $WORKSPACE_DIR/research/Odyssey && \\" >&2
    echo "           podman compose build odyssey-dev" >&2
    echo "  Receive: rsync -avz <hub-host>:/tmp/odyssey-dev.tar ~/ && podman load -i ~/odyssey-dev.tar" >&2
    exit 1
fi

if [[ ! -d "$WORKSPACE_DIR/research/Odyssey" ]]; then
    echo "ERROR: Workspace $WORKSPACE_DIR/research/Odyssey not found." >&2
    echo "  Clone Odysseus + submodules, or set WORKSPACE_DIR." >&2
    exit 1
fi

# ── Prepare host directories ──
mkdir -p "$RESULTS_DIR"

# Container clobber guard: refuse to silently destroy an in-flight training job.
# Training typically runs hours; clobbering it without confirmation is destructive.
if podman container exists alexnet-training 2>/dev/null; then
    existing_status=$(podman inspect alexnet-training --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
    if [[ "$existing_status" == "running" ]]; then
        echo "ERROR: 'alexnet-training' container is currently RUNNING on $HOST_NAME." >&2
        echo "  Inspect:  podman logs alexnet-training" >&2
        echo "  Force-stop and remove:  podman rm -f alexnet-training" >&2
        exit 1
    fi
    echo "Cleaning up previous alexnet-training container (status: $existing_status)..."
    podman rm -f alexnet-training >/dev/null
fi

# ── Pre-download CIFAR-10 if needed (skipped in smoke mode) ──
if [[ "$MAX_BATCHES" -eq 0 ]]; then
    if [[ ! -d "$WORKSPACE_DIR/research/Odyssey/datasets/cifar10" ]]; then
        echo "Downloading CIFAR-10 dataset..."
        podman run --rm --userns=keep-id \
            -v "$WORKSPACE_DIR/research/Odyssey:/workspace:Z" \
            -w /workspace \
            "$IMAGE_NAME" \
            pixi run python examples/alexnet_cifar10/download_cifar10.py
    fi
fi

# ── Write training invocation log header ──
LOG="$RESULTS_DIR/training.log"
{
    echo "=== AlexNet Training on $HOST_NAME ==="
    echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Image:   $IMAGE_NAME"
    echo "Epochs:  $EPOCHS / Batch: $BATCH_SIZE / LR: $LEARNING_RATE / Precision: $PRECISION"
    echo "Max batches per epoch: $MAX_BATCHES $([[ $MAX_BATCHES -gt 0 ]] && echo '(smoke mode)' || echo '(full dataset)')"
    echo "Memory limit: $MEM_LIMIT / CPU limit: $CPU_LIMIT / shm-size: $SHM_SIZE"
    echo "Mojo target flags: ${MOJO_TARGET_FLAGS:-none}"
    echo "Workspace: $WORKSPACE_DIR/research/Odyssey"
    echo "Results:   $RESULTS_DIR"
    if [[ -r /proc/cpuinfo ]]; then
        echo "CPU:      $(grep -m1 "model name" /proc/cpuinfo | sed 's/^model name\s*:\s*//')"
    fi
    echo ""
} | tee -a "$LOG"

# Single training entry point. Fleet ships run_train.mojo on every host.
# If you rename or replace this entry-point, update the inner `bash -c ...`
# block below — line `examples/alexnet_cifar10/run_train.mojo` — accordingly.

# ── Launch training container ──
# --network=host: avoids rootlessport binary missing (verified workaround)
# --userns=keep-id: maps host UID→container UID so bind-mount writes succeed
# -v workspace:Z: SELinux relabel for workspace bind-mount (Fedora/RHEL)
# -v results:Z: SELinux relabel for results bind-mount
echo "Launching training container..."
podman run -d \
    --name alexnet-training \
    --network=host \
    --userns=keep-id \
    --mem-limit="$MEM_LIMIT" \
    --cpus="$CPU_LIMIT" \
    --shm-size="$SHM_SIZE" \
    -v "$WORKSPACE_DIR/research/Odyssey:/workspace:Z" \
    -v "$RESULTS_DIR:/results:Z" \
    -w /workspace \
    -e HOST_NAME="$HOST_NAME" \
    -e EPOCHS="$EPOCHS" \
    -e BATCH_SIZE="$BATCH_SIZE" \
    -e LEARNING_RATE="$LEARNING_RATE" \
    -e PRECISION="$PRECISION" \
    -e MAX_BATCHES="$MAX_BATCHES" \
    -e MOJO_TARGET_FLAGS="$MOJO_TARGET_FLAGS" \
    "$IMAGE_NAME" \
    bash -c '
        set -euo pipefail
        echo "[$(date -u +%H:%M:%S)] Container started. Image: $(pixi run mojo --version 2>&1 | head -1)"

        # Smoke mode: when MAX_BATCHES > 0, pass --smoke and --max-batches
        # unconditionally. Hosts whose run_train.mojo lacks those flags will
        # surface the mismatch as a Mojo error at launch (not silently).
        EXTRA_ARGS=()
        if [[ "$MAX_BATCHES" -gt 0 ]]; then
            EXTRA_ARGS=(--smoke --max-batches "$MAX_BATCHES")
        fi

        pixi run mojo run $MOJO_TARGET_FLAGS -I . \
            examples/alexnet_cifar10/run_train.mojo \
            --epochs "$EPOCHS" \
            --batch-size "$BATCH_SIZE" \
            --lr "$LEARNING_RATE" \
            "${EXTRA_ARGS[@]}" \
            --weights-dir /results/alexnet_weights \
            2>&1
        echo "[$(date -u +%H:%M:%S)] Training run finished"
    '

echo ""
echo "Training launched on $HOST_NAME."
echo "Monitor with:"
echo "  podman logs -f alexnet-training"
echo "  tail -f $RESULTS_DIR/training.log"
echo ""
echo "To collect results centrally on epimetheus:"
echo "  bash $SCRIPT_DIR/alexnet-collect-results.sh"
