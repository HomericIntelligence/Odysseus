# ===========================================================================
# Variables
# ===========================================================================

AGAMEMNON_URL := env_var_or_default("AGAMEMNON_URL", "http://172.20.0.1:8080")

# Root build directory — all submodule build artifacts land here when
# building from Odysseus. Each submodule uses its own ./build/ when
# cloned and built independently.
BUILD_ROOT := justfile_directory() / "build"

# ===========================================================================
# Default
# ===========================================================================

default:
    @just --list

# ===========================================================================
# Submodule Management
# ===========================================================================

# Initialize and update all git submodules
bootstrap:
    git submodule update --init --recursive

# Pull latest commits for all submodules from their upstream remotes
update-submodules:
    git submodule update --remote

# ===========================================================================
# Cross-Repo Status
# ===========================================================================

# Show git status across all submodules
status:
    @echo "=== Odysseus root ==="
    @git status --short
    @echo ""
    @echo "=== Submodule status ==="
    @git submodule foreach --recursive 'echo "--- $name ---" && git status --short && echo ""'

# ===========================================================================
# Build
# ===========================================================================

# Build all compilable submodules into build/<name>/ (C++/CMake + Mojo)
build: _build-agamemnon _build-nestor _build-charybdis _build-keystone _build-odyssey
    @echo "=== Build complete. Artifacts in {{BUILD_ROOT}}/ ==="

# One-command setup for a fresh clone (after pixi is installed at root)
setup: bootstrap build
    @echo "=== Setup complete ==="

# Install all server binaries and libraries to a prefix (default: /usr/local)
install PREFIX="/usr/local":
    cmake --install "{{BUILD_ROOT}}/ProjectAgamemnon" --prefix "{{PREFIX}}"
    cmake --install "{{BUILD_ROOT}}/ProjectNestor" --prefix "{{PREFIX}}"
    cmake --install "{{BUILD_ROOT}}/ProjectCharybdis" --prefix "{{PREFIX}}"
    cmake --install "{{BUILD_ROOT}}/ProjectKeystone" --prefix "{{PREFIX}}"

# Build ProjectAgamemnon (C++/CMake + Conan, debug preset)
_build-agamemnon:
    @echo "--- Conan deps for control/ProjectAgamemnon ---"
    cd control/ProjectAgamemnon && pixi run conan install . \
        --output-folder="{{BUILD_ROOT}}/ProjectAgamemnon" \
        --profile=conan/profiles/debug \
        --build=missing
    @echo "--- Building control/ProjectAgamemnon ---"
    cmake -S control/ProjectAgamemnon -B "{{BUILD_ROOT}}/ProjectAgamemnon" \
        -DCMAKE_TOOLCHAIN_FILE="{{BUILD_ROOT}}/ProjectAgamemnon/conan_toolchain.cmake" \
        -DCMAKE_BUILD_TYPE=Debug \
        -G Ninja \
        -DProjectAgamemnon_BUILD_TESTING=ON \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    cmake --build "{{BUILD_ROOT}}/ProjectAgamemnon"

# Build ProjectNestor (C++/CMake + Conan, debug preset)
_build-nestor:
    @echo "--- Conan deps for control/ProjectNestor ---"
    cd control/ProjectNestor && pixi run conan install . \
        --output-folder="{{BUILD_ROOT}}/ProjectNestor" \
        --profile=conan/profiles/debug \
        --build=missing
    @echo "--- Building control/ProjectNestor ---"
    cmake -S control/ProjectNestor -B "{{BUILD_ROOT}}/ProjectNestor" \
        -DCMAKE_TOOLCHAIN_FILE="{{BUILD_ROOT}}/ProjectNestor/conan_toolchain.cmake" \
        -DCMAKE_BUILD_TYPE=Debug \
        -G Ninja \
        -DProjectNestor_BUILD_TESTING=ON \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    cmake --build "{{BUILD_ROOT}}/ProjectNestor"

# Build ProjectCharybdis (C++/CMake + Conan, debug preset)
_build-charybdis:
    @echo "--- Conan deps for testing/ProjectCharybdis ---"
    cd testing/ProjectCharybdis && pixi run conan install . \
        --output-folder="{{BUILD_ROOT}}/ProjectCharybdis" \
        --profile=conan/profiles/debug \
        --build=missing
    @echo "--- Building testing/ProjectCharybdis ---"
    cmake -S testing/ProjectCharybdis -B "{{BUILD_ROOT}}/ProjectCharybdis" \
        -DCMAKE_TOOLCHAIN_FILE="{{BUILD_ROOT}}/ProjectCharybdis/conan_toolchain.cmake" \
        -DCMAKE_BUILD_TYPE=Debug \
        -G Ninja \
        -DProjectCharybdis_BUILD_TESTING=ON \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    cmake --build "{{BUILD_ROOT}}/ProjectCharybdis"

# Build ProjectKeystone (C++/CMake + Conan, debug preset)
_build-keystone:
    @echo "--- Conan deps for provisioning/ProjectKeystone ---"
    cd provisioning/ProjectKeystone && pixi run conan install . \
        --output-folder="{{BUILD_ROOT}}/ProjectKeystone" \
        --profile=conan/profiles/debug \
        --build=missing
    @echo "--- Building provisioning/ProjectKeystone ---"
    cmake -S provisioning/ProjectKeystone -B "{{BUILD_ROOT}}/ProjectKeystone" \
        -DCMAKE_TOOLCHAIN_FILE="{{BUILD_ROOT}}/ProjectKeystone/conan_toolchain.cmake" \
        -DCMAKE_BUILD_TYPE=Debug \
        -G Ninja \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    cmake --build "{{BUILD_ROOT}}/ProjectKeystone"

# Build ProjectOdyssey (Mojo — outputs to submodule build/ directory)
_build-odyssey:
    @echo "--- Building research/ProjectOdyssey (Mojo) ---"
    cd research/ProjectOdyssey && BUILD_ROOT="{{BUILD_ROOT}}/ProjectOdyssey" just build

# ===========================================================================
# Test
# ===========================================================================

# Run tests across all compilable submodules
test: _test-agamemnon _test-nestor _test-charybdis _test-keystone
    @echo "=== Tests complete ==="

_test-agamemnon:
    @echo "--- Testing control/ProjectAgamemnon ---"
    ctest --test-dir "{{BUILD_ROOT}}/ProjectAgamemnon" --output-on-failure

_test-nestor:
    @echo "--- Testing control/ProjectNestor ---"
    ctest --test-dir "{{BUILD_ROOT}}/ProjectNestor" --output-on-failure

_test-charybdis:
    @echo "--- Testing testing/ProjectCharybdis ---"
    ctest --test-dir "{{BUILD_ROOT}}/ProjectCharybdis" --output-on-failure

_test-keystone:
    @echo "--- Testing provisioning/ProjectKeystone ---"
    ctest --test-dir "{{BUILD_ROOT}}/ProjectKeystone" --output-on-failure

# ===========================================================================
# Lint
# ===========================================================================

# Run linters across all submodules that have a lint recipe
lint:
    @git submodule foreach --recursive 'just lint 2>/dev/null && true || true'

# ===========================================================================
# Clean
# ===========================================================================

# Remove the root build directory
clean:
    rm -rf "{{BUILD_ROOT}}"

# ===========================================================================
# Provisioning
# ===========================================================================

# Apply Myrmidons declarative YAML state via the Agamemnon API
apply-all:
    cd provisioning/Myrmidons && just apply

# ===========================================================================
# Infrastructure Services
# ===========================================================================

# Start ProjectHermes NATS event bridge
hermes-start:
    cd infrastructure/ProjectHermes && just start

# Start ProjectArgus observability stack
argus-start:
    cd infrastructure/ProjectArgus && just start

# ===========================================================================
# Provisioning Services
# ===========================================================================

# Start ProjectKeystone DAG executor daemon
keystone-start:
    cd provisioning/ProjectKeystone && just start

# Print ProjectKeystone DAG status across all teams
keystone-status:
    cd provisioning/ProjectKeystone && just status

# ===========================================================================
# Workflows
# ===========================================================================

# Run a named workflow via ProjectTelemachy
telemachy-run WORKFLOW:
    cd provisioning/ProjectTelemachy && just run WORKFLOW={{ WORKFLOW }}

# ===========================================================================
# Research / Testing
# ===========================================================================

# Run ProjectScylla ablation benchmarks
scylla-test:
    cd research/ProjectScylla && just test

# ===========================================================================
# One-Command Install (per host role)
# ===========================================================================

# Install all prerequisites for a worker host (podman, NATS, observability)
install-worker:
    bash e2e/doctor.sh --role worker --install
    git submodule update --init --recursive
    @echo "=== Worker host ready. Run: just start-nats, just start-hermes, etc. ==="

# Install all prerequisites + build C++ binaries for a control host
install-control:
    bash e2e/doctor.sh --role control --install
    git submodule update --init --recursive
    just _build-agamemnon _build-nestor
    @echo "=== Control host ready. Run: just start-agamemnon, just start-nestor, etc. ==="

# ===========================================================================
# Per-Component Launchers (cross-host capable)
# ===========================================================================
# Each component can run independently on any Tailscale host.
# Point NATS_URL at the NATS server (default: nats://localhost:4222).

# Start NATS JetStream server (standalone container)
start-nats:
    podman run -d --replace --name hi-nats \
      -p 4222:4222 -p 8222:8222 \
      nats:alpine -js -m 8222
    @echo "NATS running at nats://$(hostname -I | awk '{print $1}'):4222"

# Start ProjectAgamemnon (C++ binary, connects to NATS)
start-agamemnon NATS_URL="nats://localhost:4222":
    NATS_URL={{ NATS_URL }} "{{BUILD_ROOT}}/ProjectAgamemnon/ProjectAgamemnon_server"

# Start ProjectNestor (C++ binary, connects to NATS)
start-nestor NATS_URL="nats://localhost:4222":
    NATS_URL={{ NATS_URL }} "{{BUILD_ROOT}}/ProjectNestor/ProjectNestor_server"

# Start ProjectHermes webhook-to-NATS bridge (Python/FastAPI)
start-hermes NATS_URL="nats://localhost:4222":
    cd infrastructure/ProjectHermes && NATS_URL={{ NATS_URL }} just start

# Start hello-myrmidon worker (Python, pulls from hi.myrmidon.hello.>)
start-myrmidon NATS_URL="nats://localhost:4222" AGAMEMNON_URL="http://localhost:8080":
    NATS_URL={{ NATS_URL }} AGAMEMNON_URL={{ AGAMEMNON_URL }} \
      python3 provisioning/Myrmidons/hello-world/worker.py

# Start ProjectArgus observability stack (Prometheus + Loki + Grafana)
start-argus:
    cd infrastructure/ProjectArgus && just start

# Start Odysseus console — real-time NATS event viewer
start-console NATS_URL="nats://localhost:4222":
    NATS_URL={{ NATS_URL }} python3 tools/odysseus-console.py

# ===========================================================================
# CI/CD Pipelines (ProjectProteus)
# ===========================================================================

# Build an OCI image via Dagger pipeline (e.g. just proteus-build myapp)
proteus-build NAME:
    cd ci-cd/ProjectProteus && just build {{ NAME }}

# Run tests for a repo via Dagger
proteus-test NAME:
    cd ci-cd/ProjectProteus && just test {{ NAME }}

# Full pipeline: build → test → promote → dispatch
proteus-pipeline NAME:
    cd ci-cd/ProjectProteus && just pipeline {{ NAME }}

# Lint via Dagger
proteus-lint:
    cd ci-cd/ProjectProteus && just lint

# Validate all pipeline configs
proteus-validate:
    cd ci-cd/ProjectProteus && just validate

# Run lint + validate quality check
proteus-check:
    cd ci-cd/ProjectProteus && just check

# ===========================================================================
# Skills Marketplace (ProjectMnemosyne)
# ===========================================================================

# Validate all skill files in ProjectMnemosyne
mnemosyne-validate:
    cd shared/ProjectMnemosyne && just validate

# Regenerate marketplace.json index from skill files
mnemosyne-generate-marketplace:
    cd shared/ProjectMnemosyne && just generate-marketplace

# Run ProjectMnemosyne tests
mnemosyne-test:
    cd shared/ProjectMnemosyne && just test

# Run validate + test quality check
mnemosyne-check:
    cd shared/ProjectMnemosyne && just check

# ===========================================================================
# Shared Utilities (ProjectHephaestus)
# ===========================================================================

# Run ProjectHephaestus unit + integration tests
hephaestus-test:
    cd shared/ProjectHephaestus && just test

# Run ProjectHephaestus linter
hephaestus-lint:
    cd shared/ProjectHephaestus && just lint

# Run ProjectHephaestus formatter
hephaestus-format:
    cd shared/ProjectHephaestus && just format

# Run ProjectHephaestus type checker
hephaestus-typecheck:
    cd shared/ProjectHephaestus && just typecheck

# Run lint + format-check + typecheck quality gate
hephaestus-check:
    cd shared/ProjectHephaestus && just check

# Run pip-audit dependency vulnerability scan
hephaestus-audit:
    cd shared/ProjectHephaestus && just audit

# ===========================================================================
# E2E Pipeline Testing
# ===========================================================================

# Start Claude Code myrmidon — multi-stage pipeline worker (plan → test → implement → review → ship)
start-claude-myrmidon NATS_URL="nats://localhost:4222":
    NATS_URL={{ NATS_URL }} python3 e2e/claude-myrmidon.py

# Run Claude myrmidon in dry-run mode (no Claude CLI, validates NATS pipeline only)
e2e-dry-run NATS_URL="nats://localhost:4222":
    DRY_RUN=1 NO_GITHUB=1 NATS_URL={{ NATS_URL }} python3 e2e/claude-myrmidon.py

# Build E2E container images
e2e-build:
    podman compose -f docker-compose.e2e.yml build

# Start the full E2E stack (handles podman DNS workaround)
e2e-up:
    bash e2e/start-stack.sh

# Run the E2E hello-world test (validates entire pipeline end-to-end)
e2e-test:
    bash e2e/run-hello-world.sh

# Tear down the E2E stack and remove volumes
e2e-down:
    bash e2e/teardown.sh

# Stream logs from E2E stack (optional: pass service name, e.g. just e2e-logs agamemnon)
e2e-logs SERVICE="":
    podman compose -f docker-compose.e2e.yml logs -f {{ SERVICE }}

# Show status of E2E stack containers
e2e-status:
    podman compose -f docker-compose.e2e.yml ps

# Check all E2E pipeline prerequisites (use --install to fix missing deps)
doctor *ARGS:
    bash e2e/doctor.sh {{ ARGS }}

# Validate Conan package installation (C++ packages export, consume, install)
e2e-conan-validate:
    bash e2e/validate-conan-install.sh

# Validate pip package installation (Python packages in clean venvs)
e2e-pip-validate:
    bash e2e/validate-pip-install.sh

# Full validation suite (Docker E2E + Conan + pip)
e2e-full: e2e-test e2e-conan-validate e2e-pip-validate
    @echo "=== Full E2E validation complete ==="

# ===========================================================================
# Cross-Host Deployment (two Tailscale-connected hosts)
# ===========================================================================

# Start cross-host stack on worker host (requires CONTROL_HOST_IP)
crosshost-up CONTROL_HOST_IP:
    CONTROL_HOST_IP={{ CONTROL_HOST_IP }} bash e2e/start-crosshost.sh

# Run cross-host E2E validation from control host (requires WORKER_HOST_IP)
crosshost-test WORKER_HOST_IP:
    WORKER_HOST_IP={{ WORKER_HOST_IP }} bash e2e/run-crosshost-e2e.sh

# Start the Odysseus console (NATS event viewer)
odysseus-console NATS_URL="nats://localhost:4222":
    NATS_URL={{ NATS_URL }} python3 tools/odysseus-console.py

# ===========================================================================
# Python Package Installation
# ===========================================================================

# Install all Python packages in editable mode
install-python:
    pip install -e shared/ProjectHephaestus
    pip install -e infrastructure/ProjectHermes
    pip install -e provisioning/ProjectTelemachy

# ===========================================================================
# IPC E2E Tests (75 test cases × 4 topologies)
# ===========================================================================

# Run IPC tests by category on compose topology (T4, requires e2e-up)
e2e-test-fault:
    bash e2e/run-ipc-tests.sh --topology t4 --category fault

e2e-test-perf:
    bash e2e/run-ipc-tests.sh --topology t4 --category perf

e2e-test-protocol:
    bash e2e/run-ipc-tests.sh --topology t4 --category protocol

e2e-test-security:
    bash e2e/run-ipc-tests.sh --topology t4 --category security

e2e-test-chaos:
    bash e2e/run-ipc-tests.sh --topology t4 --category chaos

e2e-test-all-categories:
    bash e2e/run-ipc-tests.sh --topology t4 --category all

# Run IPC tests on local topology (T1, no containers — fastest feedback)
e2e-test-local:
    bash e2e/run-ipc-tests.sh --topology t1 --category all

# Run IPC tests in single container (T3)
e2e-test-single-container:
    bash e2e/run-ipc-tests.sh --topology t3 --category all

# Multi-shell topology (T2, requires tmux)
e2e-test-tmux-setup:
    bash e2e/topologies/t2-tmux.sh setup

e2e-test-tmux-run:
    bash e2e/run-ipc-tests.sh --topology t2 --category all

e2e-test-tmux-teardown:
    bash e2e/topologies/t2-tmux.sh teardown
