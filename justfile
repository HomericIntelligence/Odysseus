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

# Build ProjectAgamemnon (C++/CMake, debug preset)
_build-agamemnon:
    @echo "--- Building control/ProjectAgamemnon ---"
    cmake -S control/ProjectAgamemnon -B "{{BUILD_ROOT}}/ProjectAgamemnon" \
        -DCMAKE_BUILD_TYPE=Debug \
        -G Ninja \
        -DProjectAgamemnon_BUILD_TESTING=ON \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    cmake --build "{{BUILD_ROOT}}/ProjectAgamemnon"

# Build ProjectNestor (C++/CMake, debug preset)
_build-nestor:
    @echo "--- Building control/ProjectNestor ---"
    cmake -S control/ProjectNestor -B "{{BUILD_ROOT}}/ProjectNestor" \
        -DCMAKE_BUILD_TYPE=Debug \
        -G Ninja \
        -DProjectNestor_BUILD_TESTING=ON \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    cmake --build "{{BUILD_ROOT}}/ProjectNestor"

# Build ProjectCharybdis (C++/CMake, debug preset)
_build-charybdis:
    @echo "--- Building testing/ProjectCharybdis ---"
    cmake -S testing/ProjectCharybdis -B "{{BUILD_ROOT}}/ProjectCharybdis" \
        -DCMAKE_BUILD_TYPE=Debug \
        -G Ninja \
        -DProjectCharybdis_BUILD_TESTING=ON \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    cmake --build "{{BUILD_ROOT}}/ProjectCharybdis"

# Build ProjectKeystone (C++/CMake via Makefile, respects BUILD_DIR)
_build-keystone:
    @echo "--- Building provisioning/ProjectKeystone ---"
    cmake -S provisioning/ProjectKeystone -B "{{BUILD_ROOT}}/ProjectKeystone" \
        -DCMAKE_BUILD_TYPE=Debug \
        -G Ninja \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    cmake --build "{{BUILD_ROOT}}/ProjectKeystone"

# Build ProjectOdyssey (Mojo — outputs to submodule build/ directory)
_build-odyssey:
    @echo "--- Building research/ProjectOdyssey (Mojo) ---"
    cd research/ProjectOdyssey && NATIVE=1 just build

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
