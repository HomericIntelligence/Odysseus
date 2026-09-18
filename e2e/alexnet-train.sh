#!/usr/bin/env bash
# e2e/alexnet-train.sh — Per-host AlexNet training launcher
#
# Runs an AlexNet training job inside the Odyssey container on a single
# Tailscale mesh host. Each host runs independently (no cross-host gradient
# sync); results are collected centrally by e2e/alexnet-collect-results.sh.
#
# Usage:
#   just alexnet-train                            # full 100-epoch training
#   EPOCHS=10 BATCH_SIZE=64 just alexnet-train
#   MAX_BATCHES=3 just alexnet-train              # synthetic-data smoke
#   SMOKE=true just alexnet-train                 # alias for MAX_BATCHES=3
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
#   RESULTS_DIR     — result root (default: ~/alexnet-results)
#   ALEXNET_RUN_ID  — optional safe run ID; generated when absent
#
# The aeolus host (Sandy Bridge-E, AVX-only, no AVX2) gets --target-features -avx2
# automatically — verified by hostname match. Override with FORCE_AVX2=1 if your
# aeolus install has been upgraded with an AVX2-capable CPU.
#
# See docs/runbooks/alexnet-mesh-fleet.md for the full fleet deployment plan.

set -euo pipefail

# ── Configuration ──
# Fleet deployment executes a descriptor-bound launcher. In that mode Bash has
# no source pathname, so the verified support directory is explicit.
if [[ -n "${ALEXNET_SUPPORT_DIR:-}" ]]; then
    if [[ "$ALEXNET_SUPPORT_DIR" != /* || "$ALEXNET_SUPPORT_DIR" == / \
            || "$ALEXNET_SUPPORT_DIR" == *:* \
            || "$ALEXNET_SUPPORT_DIR" =~ [[:cntrl:]] \
            || ! -d "$ALEXNET_SUPPORT_DIR" \
            || -L "$ALEXNET_SUPPORT_DIR" ]]; then
        echo "ERROR: ALEXNET_SUPPORT_DIR must be a safe absolute directory." >&2
        exit 2
    fi
    SCRIPT_DIR=$ALEXNET_SUPPORT_DIR
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
SAFE_FS="$SCRIPT_DIR/alexnet-collect-fs.py"
HOST_NAME=$(hostname)
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/Projects/Odysseus}"
RESULTS_ROOT="${RESULTS_DIR:-$HOME/alexnet-results}"
EPOCHS="${EPOCHS:-100}"
BATCH_SIZE="${BATCH_SIZE:-128}"
LEARNING_RATE="${LEARNING_RATE:-0.01}"
PRECISION="${PRECISION:-fp32}"
SMOKE_MODE="${SMOKE:-false}"
FORCE_AVX2_MODE="${FORCE_AVX2:-0}"
if [[ "$SMOKE_MODE" != "true" && "$SMOKE_MODE" != "false" ]]; then
    echo "ERROR: SMOKE must be 'true' or 'false'." >&2
    exit 2
fi
# Smoke mode: if SMOKE=true and no explicit MAX_BATCHES set, cap to 3.
if [[ "$SMOKE_MODE" == "true" && -z "${MAX_BATCHES:-}" ]]; then
    MAX_BATCHES=3
fi
MAX_BATCHES="${MAX_BATCHES:-0}"
MEM_LIMIT="${MEM_LIMIT:-14g}"
CPU_LIMIT="${CPU_LIMIT:-4.0}"
SHM_SIZE="${SHM_SIZE:-2g}"
IMAGE_NAME="${IMAGE_NAME:-odyssey:dev}"

# Validate direct-launch input before arithmetic, file changes, or Podman.
if [[ ! "$EPOCHS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: EPOCHS must be a positive integer." >&2
    exit 2
fi
if [[ ! "$BATCH_SIZE" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: BATCH_SIZE must be a positive integer." >&2
    exit 2
fi
if [[ ! "$LEARNING_RATE" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$ ]]; then
    echo "ERROR: LEARNING_RATE must be a non-negative decimal number." >&2
    exit 2
fi
if [[ "$PRECISION" != "fp32" && "$PRECISION" != "fp16" ]]; then
    echo "ERROR: PRECISION must be 'fp32' or 'fp16'." >&2
    exit 2
fi
if [[ ! "$MAX_BATCHES" =~ ^(0|[1-9][0-9]*)$ ]]; then
    echo "ERROR: MAX_BATCHES must be a non-negative integer." >&2
    exit 2
fi
if [[ "$FORCE_AVX2_MODE" != "0" && "$FORCE_AVX2_MODE" != "1" ]]; then
    echo "ERROR: FORCE_AVX2 must be '0' or '1'." >&2
    exit 2
fi
if [[ ! "$MEM_LIMIT" =~ ^[1-9][0-9]*[bBkKmMgG]?$ ]]; then
    echo "ERROR: MEM_LIMIT must be a positive integer with an optional b, k, m, or g unit." >&2
    exit 2
fi
if [[ ! "$CPU_LIMIT" =~ ^[0-9]+([.][0-9]+)?$ || ! "$CPU_LIMIT" =~ [1-9] ]]; then
    echo "ERROR: CPU_LIMIT must be a positive decimal number." >&2
    exit 2
fi
if [[ ! "$SHM_SIZE" =~ ^[1-9][0-9]*[bBkKmMgG]?$ ]]; then
    echo "ERROR: SHM_SIZE must be a positive integer with an optional b, k, m, or g unit." >&2
    exit 2
fi
if [[ ! "$IMAGE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@+-]*$ ]]; then
    echo "ERROR: IMAGE_NAME contains unsupported image-reference characters." >&2
    exit 2
fi
if [[ "$WORKSPACE_DIR" != /* || "$WORKSPACE_DIR" == / \
        || "$WORKSPACE_DIR" == *:* || "$WORKSPACE_DIR" =~ [[:cntrl:]] ]]; then
    echo "ERROR: WORKSPACE_DIR must be an absolute bind-safe directory." >&2
    exit 2
fi
if [[ "$RESULTS_ROOT" != /* || "$RESULTS_ROOT" == / \
        || "$RESULTS_ROOT" == *:* || "$RESULTS_ROOT" =~ [[:cntrl:]] ]]; then
    echo "ERROR: RESULTS_DIR must be an absolute bind-safe result root." >&2
    exit 2
fi
if [[ ! "$HOST_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
    echo "ERROR: hostname contains unsupported result-path characters: '$HOST_NAME'." >&2
    exit 2
fi
if [[ ${ALEXNET_RUN_ID:-} != "" ]]; then
    if [[ ! "$ALEXNET_RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
        echo "ERROR: ALEXNET_RUN_ID must be a safe identifier of at most 128 characters." >&2
        exit 2
    fi
else
    if ! run_stamp=$(date -u +%Y%m%dT%H%M%SZ); then
        echo "ERROR: could not create a run timestamp." >&2
        exit 2
    fi
    ALEXNET_RUN_ID="alexnet-$run_stamp-$$"
fi
RESULTS_DIR="${RESULTS_ROOT%/}/runs/$ALEXNET_RUN_ID/$HOST_NAME"

result_filesystem() {
    "$PYTHON_BIN" -I -E -c '
import hashlib
import os
import stat
import sys

descriptor = int(sys.argv[1])
expected_digest = sys.argv[2]
before = os.fstat(descriptor)
if not stat.S_ISREG(before.st_mode):
    raise SystemExit("bound result helper is not a regular file")
parts = []
offset = 0
while offset < before.st_size:
    part = os.pread(descriptor, min(65536, before.st_size - offset), offset)
    if not part:
        raise SystemExit("bound result helper became unreadable")
    parts.append(part)
    offset += len(part)
after = os.fstat(descriptor)
if (
    (before.st_dev, before.st_ino, before.st_size)
    != (after.st_dev, after.st_ino, after.st_size)
):
    raise SystemExit("bound result helper changed while reading")
source = b"".join(parts)
if hashlib.sha256(source).hexdigest() != expected_digest:
    raise SystemExit("bound result helper content digest changed")
display_name = f"<bound-result-helper:{before.st_dev}:{before.st_ino}>"
sys.argv = [display_name, *sys.argv[3:]]
scope = {"__name__": "__main__", "__file__": display_name}
exec(compile(source, display_name, "exec"), scope, scope)
' "$SAFE_FS_FD" "$SAFE_FS_DIGEST" "$@"
}

# ── CPU-specific Mojo target flags ──
# aeolus: Sandy Bridge-E (2012) — AVX only, no AVX2. Mojo JIT may misdetect.
# Strip AVX2 + AVX-512 forcibly. Override with FORCE_AVX2=1 if hardware upgraded.
MOJO_TARGET_FLAGS=""
if [[ "$HOST_NAME" == "aeolus" && "$FORCE_AVX2_MODE" != "1" ]]; then
    MOJO_TARGET_FLAGS="--target-features -avx2,-avx512f,-avx512vl,-avx512bw,-avx512dq,-avx512cd,-avx512vnni,-avx512vbmi,-avx512vbmi2,-avx512bitalg,-avx512vpopcntdq,-avx512bf16,-avx512ifma"
fi

# ── Pre-flight checks ──
if ! command -v podman >/dev/null 2>&1; then
    echo "ERROR: podman not found. Install with: sudo apt-get install -y podman podman-compose" >&2
    echo "  Or run: just install-worker (uses e2e/doctor.sh --install)" >&2
    exit 1
fi
if ! PYTHON_BIN=$(command -v python3); then
    echo "ERROR: python3 is required for safe result publication." >&2
    exit 1
fi
if [[ ! -f "$SAFE_FS" || -L "$SAFE_FS" ]]; then
    echo "ERROR: the safe result filesystem helper is unavailable." >&2
    exit 1
fi
if [[ -n "${ALEXNET_RESULT_HELPER_FD:-}" ]]; then
    if [[ ! "$ALEXNET_RESULT_HELPER_FD" =~ ^[0-9]+$ ]] \
            || ((10#$ALEXNET_RESULT_HELPER_FD < 3 \
                || 10#$ALEXNET_RESULT_HELPER_FD > 255)); then
        echo "ERROR: ALEXNET_RESULT_HELPER_FD is invalid." >&2
        exit 1
    fi
    SAFE_FS_FD=$((10#$ALEXNET_RESULT_HELPER_FD))
else
    if ! exec 10< "$SAFE_FS"; then
        echo "ERROR: the safe result filesystem helper could not be bound." >&2
        exit 1
    fi
    SAFE_FS_FD=10
fi
if ! bound_helper_digest=$("$PYTHON_BIN" -I -E -c '
import hashlib
import os
import stat
import sys

descriptor = int(sys.argv[1])
opened = os.fstat(descriptor)
named = os.lstat(sys.argv[2])
if (
    not stat.S_ISREG(opened.st_mode)
    or not stat.S_ISREG(named.st_mode)
    or (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino)
):
    raise SystemExit(1)
parts = []
offset = 0
while offset < opened.st_size:
    part = os.pread(descriptor, min(65536, opened.st_size - offset), offset)
    if not part:
        raise SystemExit(1)
    parts.append(part)
    offset += len(part)
after = os.fstat(descriptor)
if (
    (opened.st_dev, opened.st_ino, opened.st_size)
    != (after.st_dev, after.st_ino, after.st_size)
):
    raise SystemExit(1)
print(hashlib.sha256(b"".join(parts)).hexdigest())
' "$SAFE_FS_FD" "$SAFE_FS"); then
    echo "ERROR: the safe result filesystem helper changed while binding." >&2
    exit 1
fi
if [[ ! "$bound_helper_digest" =~ ^[0-9a-f]{64}$ ]]; then
    echo "ERROR: the safe result filesystem helper digest is invalid." >&2
    exit 1
fi
if [[ -n "${ALEXNET_RESULT_HELPER_SHA256:-}" ]]; then
    if [[ ! "$ALEXNET_RESULT_HELPER_SHA256" =~ ^[0-9a-f]{64}$ \
            || "$bound_helper_digest" != "$ALEXNET_RESULT_HELPER_SHA256" ]]; then
        echo "ERROR: the safe result filesystem helper does not match the deployment binding." >&2
        exit 1
    fi
    SAFE_FS_DIGEST=$ALEXNET_RESULT_HELPER_SHA256
else
    SAFE_FS_DIGEST=$bound_helper_digest
fi

# ── cgroup CPU controller availability ──
# Rootless podman only applies --cpus when the cpu controller is delegated to
# the user slice (cgroup v2). On hosts where systemd delegates only memory+pids
# (e.g. default Debian user@.service), --cpus makes crun fail with
# "controller `cpu` is not available under .../cgroup.controllers".
# Detect delegation and drop the CPU limit if the controller is missing.
CPU_CTRL_AVAILABLE=1
USER_CGROUP_CONTROLLERS=/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers
if [[ -f "$USER_CGROUP_CONTROLLERS" ]] && ! grep -qw "cpu" "$USER_CGROUP_CONTROLLERS" 2>/dev/null; then
    echo "NOTE: cpu controller not delegated to user slice — skipping --cpus limit" >&2
    CPU_CTRL_AVAILABLE=0
fi

# Podman can add a `localhost/` prefix to a loaded local image. Compare each
# returned identity as literal data; image names can contain regular-expression
# metacharacters.
image_found=0
while IFS= read -r image_identity; do
    if [[ "$image_identity" == "$IMAGE_NAME" \
            || "$image_identity" == "localhost/$IMAGE_NAME" ]]; then
        image_found=1
        break
    fi
done < <(podman images "$IMAGE_NAME" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)
if [[ "$image_found" != 1 ]]; then
    echo "ERROR: Image '$IMAGE_NAME' not loaded (tried '<NAME>' and 'localhost/<NAME>'). Build or distribute first:" >&2
    echo "  Fleet: ALEXNET_DEPLOY_APPROVED_FLEET='<exact fleet>' just alexnet-fleet-deploy" >&2
    echo "  Local: cd $WORKSPACE_DIR/research/Odyssey && podman compose build odyssey-dev" >&2
    exit 1
fi
if ! IMAGE_ID=$(podman image inspect "$IMAGE_NAME" \
        --format '{{.Id}}' 2>/dev/null) \
        || [[ ! "$IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "ERROR: Image '$IMAGE_NAME' has no valid immutable local identity." >&2
    exit 1
fi

if [[ ! -d "$WORKSPACE_DIR/research/Odyssey" ]]; then
    echo "ERROR: Workspace $WORKSPACE_DIR/research/Odyssey not found." >&2
    echo "  Clone Odysseus + submodules, or set WORKSPACE_DIR." >&2
    exit 1
fi

# Refuse a reused run identity before changing any retained container. An old
# terminal container can still carry logs needed to interpret its result tree.
if [[ -e "$RESULTS_DIR" || -L "$RESULTS_DIR" ]]; then
    echo "ERROR: result directory already exists for run '$ALEXNET_RUN_ID': $RESULTS_DIR" >&2
    exit 1
fi

# Container clobber guard: retain every existing container. Its logs can be the
# only terminal evidence for a prior run.
if podman container exists alexnet-training 2>/dev/null; then
    if ! existing_status=$(podman inspect alexnet-training \
        --format '{{.State.Status}}' 2>/dev/null); then
        echo "ERROR: cannot safely replace 'alexnet-training': its state probe failed." >&2
    else
        echo "ERROR: cannot safely replace 'alexnet-training': verified status '$existing_status'." >&2
    fi
    echo "  Inspect it with: podman logs alexnet-training" >&2
    echo "  Complete a separately authorized cleanup before a new launch." >&2
    exit 1
else
    exists_rc=$?
    if [[ "$exists_rc" != 1 ]]; then
        echo "ERROR: cannot safely replace 'alexnet-training': its existence probe failed (exit $exists_rc)." >&2
        exit 1
    fi
fi

# Each run owns a new result directory. Do not reuse or delete an older run.
if ! result_identity=$(result_filesystem train-create "$RESULTS_DIR"); then
    echo "ERROR: could not create the result directory for run '$ALEXNET_RUN_ID'." >&2
    exit 1
fi
if ! exec 9< "$RESULTS_DIR" \
        || ! result_filesystem train-verify-directory \
            "$RESULTS_DIR" "$result_identity" 9; then
    echo "ERROR: result directory binding changed after creation." >&2
    exit 1
fi

# ── Pre-download CIFAR-10 if needed (skipped in smoke mode) ──
if [[ "$MAX_BATCHES" -eq 0 ]]; then
    if [[ ! -d "$WORKSPACE_DIR/research/Odyssey/datasets/cifar10" ]]; then
        echo "Downloading CIFAR-10 dataset..."
        podman run --rm --userns=keep-id \
            -v "$WORKSPACE_DIR/research/Odyssey:/workspace:Z" \
            -w /workspace \
            "$IMAGE_ID" \
            python examples/alexnet_cifar10/download_cifar10.py
    fi
fi

# ── Write training invocation log header ──
header_payload=$(
    echo "=== AlexNet Training on $HOST_NAME ==="
    echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Run ID:   $ALEXNET_RUN_ID"
    echo "Image:   $IMAGE_NAME"
    echo "Image ID: $IMAGE_ID"
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
    echo "NOTE: Full training output streams to the container log driver."
    echo "      View it with:  podman logs -f alexnet-training"
    echo "      This file holds only the launch header (config) above."
    echo ""
)
if ! header_identity=$(result_filesystem train-publish-header \
        "$result_identity" 9 "$header_payload"); then
    echo "ERROR: could not safely publish the training launch header." >&2
    exit 1
fi
printf '%s\n' "$header_payload"
if ! result_filesystem train-verify-header \
        "$RESULTS_DIR" "$result_identity" 9 "$header_identity"; then
    echo "ERROR: result directory binding changed during launch-header publication." >&2
    exit 1
fi

# Single training entry point. Fleet ships run_train.mojo on every host.
# If you rename or replace this entry-point, update the inner `bash -c ...`
# block below — line `examples/alexnet_cifar10/run_train.mojo` — accordingly.

# ── Launch training container ──
# --network=host: avoids rootlessport binary missing (verified workaround)
# --userns=keep-id: maps host UID→container UID so bind-mount writes succeed
# -v workspace:Z: SELinux relabel for workspace bind-mount (Fedora/RHEL)
# -v results:Z: SELinux relabel for results bind-mount
echo "Launching training container..."
# --cpus is only passed when the cpu cgroup controller is delegated (see above)
CPUS_ARGS=()
if [[ "$CPU_CTRL_AVAILABLE" == "1" ]]; then
    CPUS_ARGS=(--cpus "$CPU_LIMIT")
fi
if [[ -d /proc/self/fd ]]; then
    RESULTS_MOUNT_SOURCE="/proc/$$/fd/9"
elif [[ -e /dev/fd/9 ]]; then
    RESULTS_MOUNT_SOURCE=/dev/fd/9
else
    echo "ERROR: the bound result descriptor is unavailable for the container mount." >&2
    exit 1
fi
if ! result_filesystem train-verify-header \
        "$RESULTS_DIR" "$result_identity" 9 "$header_identity"; then
    echo "ERROR: result directory binding changed before container launch." >&2
    exit 1
fi
container_id=""
if ! container_id=$(podman run -d \
    --name alexnet-training \
    --label "io.homeric.alexnet.run-id=$ALEXNET_RUN_ID" \
    --network=host \
    --userns=keep-id \
    --memory="$MEM_LIMIT" \
    "${CPUS_ARGS[@]}" \
    --shm-size="$SHM_SIZE" \
    -v "$WORKSPACE_DIR/research/Odyssey:/workspace:Z" \
    -v "$RESULTS_MOUNT_SOURCE:/results:Z" \
    -w /workspace \
    -e HOST_NAME="$HOST_NAME" \
    -e EPOCHS="$EPOCHS" \
    -e BATCH_SIZE="$BATCH_SIZE" \
    -e LEARNING_RATE="$LEARNING_RATE" \
    -e PRECISION="$PRECISION" \
    -e MAX_BATCHES="$MAX_BATCHES" \
    -e MOJO_TARGET_FLAGS="$MOJO_TARGET_FLAGS" \
    "$IMAGE_ID" \
    bash -c '
        set -euo pipefail
        echo "[$(date -u +%H:%M:%S)] Container started. Image: $(mojo --version 2>&1 | head -1)"

        # Smoke mode: when MAX_BATCHES > 0, pass --smoke and --max-batches
        # unconditionally. Hosts whose run_train.mojo lacks those flags will
        # surface the mismatch as a Mojo error at launch (not silently).
        EXTRA_ARGS=()
        if [[ "$MAX_BATCHES" -gt 0 ]]; then
            EXTRA_ARGS=(--smoke --max-batches "$MAX_BATCHES")
        fi

        # odyssey package lives under src/ (CI convention: -I src -I .)
        mojo run $MOJO_TARGET_FLAGS -I src -I . \
            examples/alexnet_cifar10/run_train.mojo \
            --epochs "$EPOCHS" \
            --batch-size "$BATCH_SIZE" \
            --lr "$LEARNING_RATE" \
            "${EXTRA_ARGS[@]}" \
            --weights-dir /results/alexnet_weights \
            2>&1
        echo "[$(date -u +%H:%M:%S)] Training run finished"
    '); then
    echo "ERROR: podman did not create the training container." >&2
    exit 1
fi
if [[ ! "$container_id" =~ ^[0-9a-f]{64}$ ]]; then
    echo "ERROR: podman returned an invalid training container ID receipt." >&2
    exit 1
fi
if ! container_binding=$(podman inspect "$container_id" \
        --format '{{.Id}}|{{.Name}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}|{{.Image}}|{{range .Mounts}}{{if eq .Destination "/results"}}{{.Source}}{{end}}{{end}}' \
        2>/dev/null); then
    echo "ERROR: the exact created training container is unavailable." >&2
    exit 1
fi
IFS='|' read -r actual_id actual_name actual_run actual_image actual_results extra \
    <<< "$container_binding"
if [[ "$container_binding" == *$'\n'* || -n "${extra:-}" \
        || "$actual_id" != "$container_id" \
        || ( "$actual_name" != alexnet-training \
            && "$actual_name" != /alexnet-training ) \
        || "$actual_run" != "$ALEXNET_RUN_ID" \
        || "$actual_image" != "$IMAGE_ID" \
        || "$actual_results" != "$RESULTS_DIR" ]]; then
    echo "ERROR: the exact created training container failed its identity postcondition." >&2
    echo "ERROR: expected id=$container_id run=$ALEXNET_RUN_ID image=$IMAGE_ID results=$RESULTS_DIR; got id=$actual_id name=$actual_name run=$actual_run image=$actual_image results=$actual_results." >&2
    exit 1
fi
if [[ ${ALEXNET_CONTAINER_ID_FD:-} != "" ]]; then
    if [[ ! "$ALEXNET_CONTAINER_ID_FD" =~ ^[0-9]+$ \
            || "$ALEXNET_CONTAINER_ID_FD" -lt 3 ]]; then
        echo "ERROR: ALEXNET_CONTAINER_ID_FD must name an open descriptor." >&2
        exit 1
    fi
    if ! printf '%s\n' "$container_id" >&"$ALEXNET_CONTAINER_ID_FD"; then
        echo "ERROR: could not publish the exact training container ID receipt." >&2
        exit 1
    fi
fi
if ! result_filesystem train-verify-header \
        "$RESULTS_DIR" "$result_identity" 9 "$header_identity"; then
    echo "ERROR: result directory binding changed during container launch." >&2
    exit 1
fi

echo ""
echo "Training launched on $HOST_NAME."
echo "Run ID: $ALEXNET_RUN_ID"
echo "Container ID: $container_id"
echo "Monitor with (full output — loss, accuracy, 'Training complete!'):"
echo "  podman logs -f alexnet-training"
echo ""
echo "  $RESULTS_DIR/training.log holds only the launch header (config);"
echo "  the training run itself is NOT written there — it streams to podman logs."
echo ""
if [[ "$RESULTS_ROOT" == "$HOME/alexnet-results" ]]; then
    echo "To collect this exact default-root run centrally:"
    echo "  FLEET='$HOST_NAME' ALEXNET_RUN_ID='$ALEXNET_RUN_ID' just alexnet-fleet-collect"
else
    echo "Collection requires REMOTE_RESULTS_DIR to match this custom result root:"
    echo "  $RESULTS_ROOT"
fi
