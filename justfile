# ===========================================================================
# Variables
# ===========================================================================

AGAMEMNON_URL := env_var_or_default("AGAMEMNON_URL", "http://localhost:8080")

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

# Check whether any submodule pins are behind their upstream default branch
check-submodule-drift:
    bash scripts/check-submodule-drift.sh

# Guard first-party docs against deprecated workflow field names (issue #25)
check-doc-field-drift:
    ./scripts/check-doc-field-drift.sh

# ===========================================================================
# Ecosystem Health
# ===========================================================================

# Check health of all HomericIntelligence repos and print a status report
ecosystem-health:
    @bash scripts/ecosystem-health.sh

# Check health and write the report to docs/ecosystem-status.md
ecosystem-health-update:
    @bash scripts/ecosystem-health.sh --output docs/ecosystem-status.md

# Regenerate the 8-category Ecosystem CI Status board in the README from live check-runs
ecosystem-table:
    @bash scripts/gen-ecosystem-table.sh --inject README.md

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
    @if [ -d "{{BUILD_ROOT}}/ProjectAgamemnon" ]; then rm -rf "{{BUILD_ROOT}}/ProjectAgamemnon/CMakeCache.txt" "{{BUILD_ROOT}}/ProjectAgamemnon/CMakeFiles" "{{BUILD_ROOT}}/ProjectAgamemnon/_deps"; fi
    pixi run cmake -S control/ProjectAgamemnon -B "{{BUILD_ROOT}}/ProjectAgamemnon" \
        -DCMAKE_TOOLCHAIN_FILE="{{BUILD_ROOT}}/ProjectAgamemnon/conan_toolchain.cmake" \
        -DCMAKE_BUILD_TYPE=Debug \
        -G Ninja \
        -DProjectAgamemnon_BUILD_TESTING=ON \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    pixi run cmake --build "{{BUILD_ROOT}}/ProjectAgamemnon"

# Build ProjectNestor (C++/CMake + Conan, debug preset)
_build-nestor:
    @echo "--- Conan deps for control/ProjectNestor ---"
    cd control/ProjectNestor && pixi run conan install . \
        --output-folder="{{BUILD_ROOT}}/ProjectNestor" \
        --profile=conan/profiles/debug \
        --build=missing
    @echo "--- Building control/ProjectNestor ---"
    @if [ -d "{{BUILD_ROOT}}/ProjectNestor" ]; then rm -rf "{{BUILD_ROOT}}/ProjectNestor/CMakeCache.txt" "{{BUILD_ROOT}}/ProjectNestor/CMakeFiles" "{{BUILD_ROOT}}/ProjectNestor/_deps"; fi
    pixi run cmake -S control/ProjectNestor -B "{{BUILD_ROOT}}/ProjectNestor" \
        -DCMAKE_TOOLCHAIN_FILE="{{BUILD_ROOT}}/ProjectNestor/conan_toolchain.cmake" \
        -DCMAKE_BUILD_TYPE=Debug \
        -G Ninja \
        -DProjectNestor_BUILD_TESTING=ON \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    pixi run cmake --build "{{BUILD_ROOT}}/ProjectNestor"

# Build ProjectCharybdis (C++/CMake + Conan, debug preset)
_build-charybdis:
    @echo "--- Conan deps for testing/ProjectCharybdis ---"
    cd testing/ProjectCharybdis && pixi run conan install . \
        --output-folder="{{BUILD_ROOT}}/ProjectCharybdis" \
        --profile=conan/profiles/debug \
        --build=missing
    @echo "--- Building testing/ProjectCharybdis ---"
    @if [ -d "{{BUILD_ROOT}}/ProjectCharybdis" ]; then rm -rf "{{BUILD_ROOT}}/ProjectCharybdis/CMakeCache.txt" "{{BUILD_ROOT}}/ProjectCharybdis/CMakeFiles" "{{BUILD_ROOT}}/ProjectCharybdis/_deps"; fi
    pixi run cmake -S testing/ProjectCharybdis -B "{{BUILD_ROOT}}/ProjectCharybdis" \
        -DCMAKE_TOOLCHAIN_FILE="{{BUILD_ROOT}}/ProjectCharybdis/conan_toolchain.cmake" \
        -DCMAKE_BUILD_TYPE=Debug \
        -G Ninja \
        -DProjectCharybdis_BUILD_TESTING=ON \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    pixi run cmake --build "{{BUILD_ROOT}}/ProjectCharybdis"

# Build ProjectKeystone (C++/CMake + Conan, debug preset)
_build-keystone:
    @echo "--- Conan deps for provisioning/ProjectKeystone ---"
    cd provisioning/ProjectKeystone && pixi run conan install . \
        --output-folder="{{BUILD_ROOT}}/ProjectKeystone" \
        --profile=conan/profiles/debug \
        --build=missing
    @echo "--- Building provisioning/ProjectKeystone ---"
    @if [ -d "{{BUILD_ROOT}}/ProjectKeystone" ]; then rm -rf "{{BUILD_ROOT}}/ProjectKeystone/CMakeCache.txt" "{{BUILD_ROOT}}/ProjectKeystone/CMakeFiles" "{{BUILD_ROOT}}/ProjectKeystone/_deps"; fi
    pixi run cmake -S provisioning/ProjectKeystone -B "{{BUILD_ROOT}}/ProjectKeystone" \
        -DCMAKE_TOOLCHAIN_FILE="{{BUILD_ROOT}}/ProjectKeystone/conan_toolchain.cmake" \
        -DCMAKE_BUILD_TYPE=Debug \
        -G Ninja \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    pixi run cmake --build "{{BUILD_ROOT}}/ProjectKeystone"

# Build ProjectOdyssey (Mojo — outputs to submodule build/ directory)
# Skipped when SKIP_ODYSSEY_BUILD=true or when podman is not available (e.g. CI).
_build-odyssey:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "${SKIP_ODYSSEY_BUILD:-}" = "true" ]; then
        echo "  SKIP: SKIP_ODYSSEY_BUILD=true"
        exit 0
    fi
    if ! podman info >/dev/null 2>&1; then
        echo "  SKIP: podman not available in this environment"
        exit 0
    fi
    cd research/ProjectOdyssey
    BUILD_ROOT="{{BUILD_ROOT}}/ProjectOdyssey" just build

# ===========================================================================
# Test
# ===========================================================================

# Run tests across all compilable submodules
test: _test-agamemnon _test-nestor _test-charybdis _test-keystone
    @echo "=== Tests complete ==="

_test-agamemnon:
    @echo "--- Testing control/ProjectAgamemnon ---"
    ctest --test-dir "{{BUILD_ROOT}}/ProjectAgamemnon" --output-on-failure --no-tests=error

_test-nestor:
    @echo "--- Testing control/ProjectNestor ---"
    ctest --test-dir "{{BUILD_ROOT}}/ProjectNestor" --output-on-failure --no-tests=error

_test-charybdis:
    @echo "--- Testing testing/ProjectCharybdis ---"
    ctest --test-dir "{{BUILD_ROOT}}/ProjectCharybdis" --output-on-failure --no-tests=error

_test-keystone:
    @echo "--- Testing provisioning/ProjectKeystone ---"
    ctest --test-dir "{{BUILD_ROOT}}/ProjectKeystone" --output-on-failure

# ===========================================================================
# Lint
# ===========================================================================

# Run linters across all submodules that have a lint recipe.
# A submodule without a `lint` recipe is treated as a pass (skipped); any other
# non-zero exit (linter found violations, broken justfile, etc.) propagates and
# fails the aggregate.
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    failed=()

    # Lint our own shell scripts with shellcheck (issue #195). shellcheck
    # is declared in pixi.toml but was previously not invoked anywhere, so
    # the `eval "$cmd"` pattern and other shell issues in e2e/lib/ slipped
    # through. Treat shellcheck failures as a lint failure for the root.
    if command -v shellcheck >/dev/null 2>&1; then
        echo "--- root: running shellcheck on tracked shell scripts ---"
        # Limit scope to first-party shell scripts; ignore submodules.
        # Use awk to filter so empty result yields exit 0 (no need for `|| true`).
        mapfile -t shell_targets < <(
            git ls-files -- '*.sh' \
                | awk '!/^(infrastructure|control|provisioning|ci-cd|research|shared|testing)\//'
        )
        if (( ${#shell_targets[@]} > 0 )); then
            if ! shellcheck --severity=warning "${shell_targets[@]}"; then
                failed+=("root:shellcheck")
            fi
        else
            echo "--- root: no tracked shell scripts to check ---"
        fi
    else
        echo "--- root: shellcheck not on PATH, skipping (declared in pixi.toml) ---"
    fi

    # e2e test coverage matrix drift check (issue #199). The matrix in
    # e2e/tests/README.md is generated from each test's header; fail lint if
    # the header contract is violated or the README is stale.
    echo "--- root: checking e2e test coverage matrix ---"
    if ! python3 e2e/tools/gen_test_matrix.py --validate; then
        failed+=("root:e2e-matrix-contract")
    elif ! python3 e2e/tools/gen_test_matrix.py --check; then
        failed+=("root:e2e-matrix-drift")
    fi

    while IFS= read -r submodule_path; do
        [[ -z "$submodule_path" ]] && continue
        if [[ ! -f "$submodule_path/justfile" && ! -f "$submodule_path/Justfile" ]]; then
            echo "--- $submodule_path: no justfile, skipping ---"
            continue
        fi
        if ! ( cd "$submodule_path" && just --justfile justfile --summary 2>/dev/null | tr ' ' '\n' | grep -qx lint ); then
            echo "--- $submodule_path: no 'lint' recipe, skipping ---"
            continue
        fi
        echo "--- $submodule_path: running lint ---"
        if ! ( cd "$submodule_path" && just lint ); then
            failed+=("$submodule_path")
        fi
    done < <(git submodule --quiet foreach --recursive 'echo "$displaypath"')
    # Grafana credential hygiene + self-test (#179)
    python3 scripts/check_grafana_credentials.py --self-test || failed+=("grafana-gate-selftest")
    python3 scripts/check_grafana_credentials.py || failed+=("grafana-credential-hygiene")
    if (( ${#failed[@]} > 0 )); then
        echo ""
        echo "ERROR: lint failed in: ${failed[*]}" >&2
        exit 1
    fi

# ===========================================================================
# Clean
# ===========================================================================

# Remove the root build directory
clean:
    rm -rf "{{BUILD_ROOT}}"

# ===========================================================================
# Quality
# ===========================================================================

# Validate HCL (Nomad), YAML (configs/), NATS config structure, and
# docker-compose structure. NATS/compose use binary-free Python validators so
# they run even where nats-server/podman are absent (CI). HCL still needs nomad
# locally; absence skips only the HCL leg, not the whole recipe.
validate-configs:
    #!/usr/bin/env bash
    set -euo pipefail
    grep -q '${NOMAD_SERVER_IP}' configs/nomad/client.hcl || { echo "client.hcl lost its placeholder"; exit 1; }
    if command -v nomad >/dev/null 2>&1; then
        nomad fmt -check configs/nomad/client.hcl configs/nomad/server.hcl
    else
        echo "Note: install nomad to validate HCL syntax (skipping HCL check)"
    fi
    # Anti-re-hardcoding guard (issue #320, regression from #181): server.hcl must
    # keep its ${NOMAD_ADVERTISE_ADDR} placeholder, never a literal Tailscale IP.
    grep -qF '${NOMAD_ADVERTISE_ADDR}' configs/nomad/server.hcl || {
        echo "configs/nomad/server.hcl lost its \${NOMAD_ADVERTISE_ADDR} placeholder (hardcoded IP re-introduced — see #181)"; exit 1;
    }
    pixi run yamllint -c .yamllint.yml .github/workflows/ configs/
    bash tools/validate-nats-auth.sh
    bash tools/tests/test-validate-nats-auth.sh
    python3 scripts/validate_nats_config.py
    python3 scripts/validate_compose.py

# Validate NATS server config structure (binary-free Python)
validate-nats:
    python3 scripts/validate_nats_config.py

# Validate all docker-compose files (binary-free Python + PyYAML)
validate-compose:
    python3 scripts/validate_compose.py

# Run justfile recipe integrity + config-validator tests (build-free)
test-justfile-recipes:
    bash tests/test-justfile-recipes.sh
    bash tests/test-config-validators.sh

# Lint test scripts for corrupted / non-runnable artifacts (guards #374)
lint-test-scripts:
    bash scripts/lint-test-scripts.sh

# Render Nomad config placeholders to a deploy-local dir (default /etc/nomad.d).
# Nomad agent HCL does NOT expand OS env vars, so render before `nomad agent -config`.
# Requires NOMAD_SERVER_IP and NOMAD_ADVERTISE_ADDR (e.g. export NOMAD_SERVER_IP=$(tailscale ip -4)).
render-nomad-configs OUT_DIR="/etc/nomad.d":
    #!/usr/bin/env bash
    set -euo pipefail
    : "${NOMAD_SERVER_IP:?set NOMAD_SERVER_IP (e.g. export NOMAD_SERVER_IP=$(tailscale ip -4))}"
    : "${NOMAD_ADVERTISE_ADDR:?set NOMAD_ADVERTISE_ADDR (e.g. export NOMAD_ADVERTISE_ADDR=$(tailscale ip -4))}"
    mkdir -p "{{ OUT_DIR }}"
    for f in client server; do
      envsubst '${NOMAD_SERVER_IP} ${NOMAD_ADVERTISE_ADDR}' \
        < "configs/nomad/${f}.hcl" > "{{ OUT_DIR }}/${f}.hcl"
      echo "rendered {{ OUT_DIR }}/${f}.hcl"
    done
    if command -v nomad >/dev/null 2>&1; then nomad fmt -check "{{ OUT_DIR }}"/*.hcl; fi

# Run all CI checks locally
ci: lint validate-configs check-doc-field-drift
    @echo "All checks passed"

# Cut a release: validate tag↔pixi.toml↔CHANGELOG, create tag, push (triggers release.yml)
# Prerequisites: bump version in pixi.toml, add dated CHANGELOG section, rewrite footer
# base from <root-sha> to v{{VERSION}}, then run: just release VERSION
release VERSION:
	@python3 scripts/check_version_consistency.py --expect {{VERSION}}
	@bash tests/release/release.test.sh
	@grep -qE "^## \[{{VERSION}}\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" CHANGELOG.md \
	  || (echo "CHANGELOG missing dated section for {{VERSION}}" && exit 1)
	@if git config --get user.signingkey >/dev/null 2>&1; then \
	    git tag -s -a v{{VERSION}} -m "Release v{{VERSION}}"; \
	  else \
	    echo "No signing key configured; creating annotated (unsigned) tag"; \
	    git tag -a v{{VERSION}} -m "Release v{{VERSION}}"; \
	  fi
	git push origin v{{VERSION}}
	@echo "Pushed v{{VERSION}} — release.yml will validate and publish."

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

# Start Agamemnon using submodule-local pixi build (control/ProjectAgamemnon/build/debug/)
start-agamemnon-native NATS_URL="nats://localhost:4222":
    NATS_URL={{ NATS_URL }} control/ProjectAgamemnon/build/debug/ProjectAgamemnon_server

# Start Nestor using submodule-local pixi build (control/ProjectNestor/build/debug/)
start-nestor-native NATS_URL="nats://localhost:4222":
    NATS_URL={{ NATS_URL }} control/ProjectNestor/build/debug/ProjectNestor_server

# Start ProjectHermes webhook-to-NATS bridge (Python/FastAPI)
start-hermes NATS_URL="nats://localhost:4222":
    cd infrastructure/ProjectHermes && NATS_URL={{ NATS_URL }} just start

# Start hello-myrmidon worker (Python, pulls from hi.myrmidon.hello.>)
start-myrmidon NATS_URL="nats://localhost:4222" AGAMEMNON_URL="http://localhost:8080":
    NATS_URL={{ NATS_URL }} AGAMEMNON_URL={{ AGAMEMNON_URL }} \
      python3 provisioning/Myrmidons/hello-world/main.py

# Start ProjectArgus observability stack (Prometheus + Loki + Grafana)
start-argus:
    cd infrastructure/ProjectArgus && just start

# Start Odysseus console — real-time NATS event viewer
start-console NATS_URL="nats://localhost:4222":
    NATS_URL={{ NATS_URL }} python3 tools/odysseus-console.py

# ===========================================================================
# Fleet Management (AchaeanFleet)
# ===========================================================================

# Build a single vessel image (e.g. just fleet-build-vessel odysseus-console)
fleet-build-vessel NAME:
    cd infrastructure/AchaeanFleet && just build-vessel {{ NAME }}

# Build all base + vessel images
fleet-build-all:
    cd infrastructure/AchaeanFleet && just build-all

# Verify built images (Trivy scan, smoke test)
fleet-verify:
    cd infrastructure/AchaeanFleet && just verify

# Run fleet integration tests
fleet-test:
    cd infrastructure/AchaeanFleet && just test

# Push images to registry
fleet-push:
    cd infrastructure/AchaeanFleet && just push

# Clean all built images
fleet-clean:
    cd infrastructure/AchaeanFleet && just clean

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

# Dispatch a pipeline to a host via Dagger
proteus-dispatch HOST:
    cd ci-cd/ProjectProteus && just dispatch-apply {{ HOST }}

# Run lint + validate quality check
proteus-check:
    cd ci-cd/ProjectProteus && just check

# ===========================================================================
# Skills Marketplace (Mnemosyne)
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
# Shared Utilities (Hephaestus)
# ===========================================================================

# Run Hephaestus unit + integration tests
hephaestus-test:
    cd shared/Hephaestus && just test

# Run Hephaestus linter
hephaestus-lint:
    cd shared/Hephaestus && just lint

# Run Hephaestus formatter
hephaestus-format:
    cd shared/Hephaestus && just format

# Run Hephaestus type checker
hephaestus-typecheck:
    cd shared/Hephaestus && just typecheck

# Run lint + format-check + typecheck quality gate
hephaestus-check:
    cd shared/Hephaestus && just check

# Run pip-audit dependency vulnerability scan
hephaestus-audit:
    cd shared/Hephaestus && just audit

# ===========================================================================
# E2E Pipeline Testing
# ===========================================================================

# Start Claude Code myrmidon — multi-stage pipeline worker (plan → test → implement → review → ship)
start-claude-myrmidon NATS_URL="nats://localhost:4222":
    NATS_URL={{ NATS_URL }} python3 e2e/claude-myrmidon.py

# Run Claude myrmidon in dry-run mode (no Claude CLI, validates NATS pipeline only)
e2e-dry-run NATS_URL="nats://localhost:4222":
    DRY_RUN=1 NO_GITHUB=1 NATS_URL={{ NATS_URL }} python3 e2e/claude-myrmidon.py

# Start Claude multi-repo myrmidon — parallel pipeline for multi-repo justfile tasks
start-claude-myrmidon-multi NATS_URL="nats://localhost:4222":
    NATS_URL={{ NATS_URL }} python3 e2e/claude-myrmidon-multi.py

# Run multi-repo myrmidon in dry-run mode (validates NATS fan-out/fan-in, no Claude API)
e2e-multi-dry-run NATS_URL="nats://localhost:4222":
    DRY_RUN=1 NO_GITHUB=1 NATS_URL={{ NATS_URL }} python3 e2e/claude-myrmidon-multi.py

# Run the issue-number resolver regression test (issue #187, no stack needed)
e2e-test-myrmidon-issue-number:
    bash e2e/test-myrmidon-issue-number.sh

# Build E2E container images
e2e-build:
    podman compose -f docker-compose.e2e.yml build

# Start the full E2E stack (handles podman DNS workaround)
e2e-up:
    bash e2e/start-stack.sh

# Run the E2E hello-world test (validates entire pipeline end-to-end)
e2e-test:
    bash e2e/start-stack.sh
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

# Phase 6 justfile delegation tests were removed as corrupted artifacts (#374).
# The referenced e2e/test-justfile-*.sh scripts were failed-agent-output garbage
# (each contained only "ERROR: Claude returned empty output"), never real tests.
# For actual justfile-recipe integrity coverage, see `just test-justfile-recipes`
# (tests/test-justfile-recipes.sh), which IS a valid, CI-enforced test.
e2e-test-justfiles:
    @echo "Phase 6 justfile delegation tests were removed as corrupted artifacts (ref #374)."
    @echo "Run 'just test-justfile-recipes' for valid justfile-recipe integrity checks."

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
    pip install -e shared/Hephaestus
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

# ===========================================================================
# Hermes-Hub Topology (hermes = full stack, epimetheus = remote myrmidon)
# ===========================================================================
# Validates cross-host myrmidon dispatch: Agamemnon (hermes) → NATS → Tailscale
# → hello-myrmidon (epimetheus) → NATS → Agamemnon → task=completed.
# Requires ssh aliases: "hermes" → 100.73.61.56, "epimetheus" → 100.92.173.32

# Build stack on hermes + launch myrmidon on epimetheus
hermes-hub-up:
    bash e2e/start-hermes-hub.sh

# Run 8-phase E2E validation for the hermes-hub topology
hermes-hub-test:
    bash e2e/run-hermes-hub-e2e.sh

# Tear down: stop compose stack on hermes + kill myrmidon on epimetheus
hermes-hub-down:
    ssh hermes "cd Odysseus && podman compose -f docker-compose.e2e.yml -f e2e/docker-compose.hermes-hub.yml down -v 2>&1 | tail -10"
    ssh epimetheus "pkill -f 'provisioning/Myrmidons/hello-world/main.py' && echo 'Myrmidon stopped' || echo 'Myrmidon was not running'"

# Stream logs from hermes compose stack (optional: pass service name, e.g. just hermes-hub-logs agamemnon)
hermes-hub-logs SERVICE="":
    ssh hermes "cd Odysseus && podman compose -f docker-compose.e2e.yml -f e2e/docker-compose.hermes-hub.yml logs --tail=100 {{ SERVICE }}"

# ===========================================================================
# GitHub Org Ruleset Management
# ===========================================================================

# Snapshot all 15 repos' current classic branch protection to a timestamped backup file
ruleset-backup:
    mkdir -p configs/github/backups
    ./tools/github/snapshot-protection.sh > "configs/github/backups/rulesets-$(date +%Y%m%d-%H%M%S).json"
    @echo "Backup written."

# Snapshot all 15 repos' classic branch protection to the canonical pre-ruleset backup file
protection-snapshot:
    mkdir -p configs/github/backups
    ./tools/github/snapshot-protection.sh > configs/github/backups/branch-protection-pre-ruleset.json
    @echo "Snapshot written to configs/github/backups/branch-protection-pre-ruleset.json"

# Create or update the org-level ruleset (default: evaluate mode JSON)
ruleset-apply FILE="configs/github/org-ruleset.json":
    ./tools/github/apply-org-ruleset.sh "{{FILE}}"

# Create or update the per-repo branch ruleset on all 15 repos (evaluate mode)
repo-rulesets-apply:
    ./tools/github/apply-repo-rulesets.sh

# Create or update the per-repo branch ruleset on all 15 repos (active/enforcing mode)
repo-rulesets-activate:
    ./tools/github/apply-repo-rulesets.sh --active

# Validate the live org ruleset against the canonical JSON and print current enforcement + checks
ruleset-validate:
    #!/usr/bin/env bash
    set -euo pipefail
    ORG=HomericIntelligence
    NAME=homeric-main-baseline
    live=$(gh api "orgs/$ORG/rulesets" --paginate --jq ".[] | select(.name == \"$NAME\")" 2>/dev/null || echo "null")
    if [[ "$live" == "null" ]]; then
      echo "ERROR: Ruleset '$NAME' not found in org." >&2
      exit 1
    fi
    echo "Live ruleset enforcement: $(echo "$live" | jq -r '.enforcement')"
    echo "Live required checks:"
    echo "$live" | jq -r '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' 2>/dev/null || echo "  (none)"
    echo "Canonical required checks (from file):"
    jq -r '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' configs/github/org-ruleset.json

# Assert each on-disk ruleset config keeps its intended enforcement value (offline check).
#
# SYNC OBLIGATION — the file→value map below is intentionally duplicated verbatim in
# .github/workflows/_required.yml ("Assert each ruleset config holds its intended
# enforcement value" step, lines ~316-321) because the schema-validation job does not
# have `just` available.  The two copies MUST stay identical:
#   • Adding a new ruleset variant → update BOTH this recipe AND the CI step.
#   • Removing a variant          → update BOTH places.
# If `just` is ever added to the schema-validation job, remove the inline bash there
# and replace it with `just ruleset-enforcement-check` so this recipe becomes the
# single source of truth.
ruleset-enforcement-check:
    #!/usr/bin/env bash
    set -euo pipefail
    declare -A expected=(
      [configs/github/repo-ruleset.json]=evaluate
      [configs/github/repo-ruleset-active.json]=active
      [configs/github/org-ruleset.json]=evaluate
      [configs/github/org-ruleset-active.json]=active
    )
    fail=0
    for f in "${!expected[@]}"; do
      got=$(jq -r '.enforcement' "$f")
      if [ "$got" != "${expected[$f]}" ]; then
        echo "REGRESSION: $f enforcement=\"$got\" (expected \"${expected[$f]}\")" >&2
        fail=1
      else
        echo "PASSED: $f enforcement=\"$got\""
      fi
    done
    [ "$fail" -eq 0 ] || { echo "FAILED: ruleset enforcement drift detected" >&2; exit 1; }
    echo "PASSED: all 4 ruleset configs hold their intended enforcement"

# Remove classic branch protection from ALL 15 repos (requires confirmation; run after ruleset is active)
protection-remove-all:
    ./tools/github/remove-classic-protection.sh --all

# ===========================================================================
# Atlas review wave
# ===========================================================================

# Dispatch 6-dimension review wave for an Atlas milestone PR via Agamemnon
atlas-review-dispatch MILESTONE PR AGAMEMNON_URL="http://localhost:8080":
    infrastructure/ProjectArgus/dashboard/scripts/atlas-review-dispatch.sh {{MILESTONE}} {{PR}} {{AGAMEMNON_URL}}

# Aggregate review wave results — exits 0 when 6/6 dimensions approved
atlas-review-aggregate MILESTONE TEAM AGAMEMNON_URL="http://localhost:8080":
    infrastructure/ProjectArgus/dashboard/scripts/atlas-review-aggregate.sh {{MILESTONE}} {{TEAM}} {{AGAMEMNON_URL}}

# Post GitHub commit status for the review wave outcome
atlas-review-status MILESTONE TEAM SHA AGAMEMNON_URL="http://localhost:8080":
    #!/usr/bin/env bash
    set -euo pipefail
    if just atlas-review-aggregate {{MILESTONE}} {{TEAM}} {{AGAMEMNON_URL}}; then
      gh api repos/HomericIntelligence/Odysseus/statuses/{{SHA}} \
        -f state=success \
        -f context="atlas / review-wave ({{MILESTONE}})" \
        -f description="6/6 dimensions approved"
    else
      gh api repos/HomericIntelligence/Odysseus/statuses/{{SHA}} \
        -f state=failure \
        -f context="atlas / review-wave ({{MILESTONE}})" \
        -f description="Review wave incomplete — see team {{TEAM}} in Agamemnon"
    fi

# ===========================================================================
# Ecosystem Install
# ===========================================================================

# Install the full HomericIntelligence ecosystem (production)
ecosystem-install role="all":
    bash install.sh --install --role {{role}}

# Install development tooling (linters, test frameworks, debug builds)
ecosystem-install-dev role="all":
    bash install_dev.sh --install --role {{role}}

# Check what's missing without installing
ecosystem-install-check role="all":
    bash install.sh --check --role {{role}}

# Run container-based install tests
test-install os="all" role="worker":
    bash tests/install/run_install_tests.sh {{os}} {{role}}

# ─── Athena (agent-host plugins/skills surface) ────────────────
# Carved out of Hephaestus per ADR-016. Library half stays in
# shared/Hephaestus; plugin/skill half lives here.

athena-start:
    cd agentic/Athena && just start

athena-lint:
    cd agentic/Athena && just lint

athena-test:
    cd agentic/Athena && just test

athena-bootstrap:
    @echo "Athena plugin manifest: agentic/Athena/.claude-plugin/plugin.json"
    @echo "Enable in Claude Code: 'athena@Athena: true' in ~/.claude/settings.json"
