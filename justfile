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

# Initialize all git submodules at the recorded gitlink commits
bootstrap:
    git submodule update --init --recursive

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
    bash tests/test-doc-field-drift.sh
    ./scripts/check-doc-field-drift.sh

# Odysseus Fleet web application (Node >=22.12; all credentials stay in the backend)
web-install:
    npm --prefix web ci --cache "{{env_var('HOME')}}/.cache/homeric-fleet-npm"

web-lock:
    npm --prefix web install --package-lock-only --ignore-scripts --cache "{{env_var('HOME')}}/.cache/homeric-fleet-npm"

web-test:
    npm --prefix web test

web-build:
    npm --prefix web run build

web-start:
    npm --prefix web start

web-browser-test:
    npm --prefix web run test:browser

# Install the browser and its supported platform dependencies for fixture tests.
web-browser-install:
    npm --prefix web exec -- playwright install --with-deps chromium

# Run the same formatting, unit, build and browser gates locally and in CI.
web-ci: web-format-check web-test web-build web-browser-test

web-format:
    npm --prefix web run format

web-format-check:
    npm --prefix web run format:check

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

# Build root-supported CMake targets into build/<name>/.
# Component-specific recipes remain owned and executed by component CI.
build: _build-agamemnon _build-nestor _build-charybdis _build-keystone _build-myrmidon
    @echo "=== Build complete. Artifacts in {{BUILD_ROOT}}/ ==="

# One-command setup for a fresh clone (after pixi is installed at root)
setup: bootstrap build
    @echo "=== Setup complete ==="

# Install all server binaries and libraries to a prefix (default: /usr/local)
install PREFIX="/usr/local":
    cmake --install "{{BUILD_ROOT}}/Agamemnon" --prefix "{{PREFIX}}"
    cmake --install "{{BUILD_ROOT}}/Nestor" --prefix "{{PREFIX}}"
    cmake --install "{{BUILD_ROOT}}/Charybdis" --prefix "{{PREFIX}}"
    cmake --install "{{BUILD_ROOT}}/Keystone" --prefix "{{PREFIX}}"

# Build Agamemnon (C++/CMake + Conan, debug preset)
_build-agamemnon:
    @BASH_ENV= ENV= /bin/bash -p scripts/build-pinned-submodule.sh agamemnon

# Build Nestor (C++/CMake + Conan, debug preset)
# Nestor renamed its profiles debug/release -> nestor-debug/nestor-release in
# Nestor#96 (portable-profiles fix); the other C++ submodules still
# ship conan/profiles/debug.
_build-nestor:
    @BASH_ENV= ENV= /bin/bash -p scripts/build-pinned-submodule.sh nestor

# Build Charybdis (C++/CMake + Conan, debug preset)
_build-charybdis:
    @BASH_ENV= ENV= /bin/bash -p scripts/build-pinned-submodule.sh charybdis

# Build Keystone (C++/CMake + Conan, debug preset)
_build-keystone:
    @BASH_ENV= ENV= /bin/bash -p scripts/build-pinned-submodule.sh keystone

_build-myrmidon:
    # Produces {{BUILD_ROOT}}/Myrmidons/hello-world/hello_myrmidon — the first
    # path start_myrmidon_bg (e2e/lib/process.sh:115) searches. Plain
    # FetchContent (nats.c + nlohmann/json), no Conan toolchain needed.
    @BASH_ENV= ENV= /bin/bash -p scripts/build-pinned-submodule.sh myrmidon

# ===========================================================================
# Test
# ===========================================================================

# Run tests across all compilable submodules
test: _test-agamemnon _test-nestor _test-charybdis _test-keystone
    @echo "=== Tests complete ==="

_test-agamemnon:
    @echo "--- Testing control/Agamemnon ---"
    ctest --test-dir "{{BUILD_ROOT}}/Agamemnon" --output-on-failure --no-tests=error

_test-nestor:
    @echo "--- Testing control/Nestor ---"
    ctest --test-dir "{{BUILD_ROOT}}/Nestor" --output-on-failure --no-tests=error

_test-charybdis:
    @echo "--- Testing testing/Charybdis ---"
    ctest --test-dir "{{BUILD_ROOT}}/Charybdis" --output-on-failure --no-tests=error

_test-keystone:
    @echo "--- Testing provisioning/Keystone ---"
    ctest --test-dir "{{BUILD_ROOT}}/Keystone" --output-on-failure

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
        bash tests/test-shellcheck-contract.sh
        echo "--- root: running shellcheck on tracked shell scripts ---"
        # Limit scope to first-party shell scripts; ignore submodules.
        # Use awk to filter so empty result yields exit 0 (no need for `|| true`).
        shell_targets=()
        shell_inventory=""
        filtered_shell_inventory=""
        if ! shell_inventory="$(git ls-files -- '*.sh')"; then
            echo "ERROR: could not enumerate tracked shell scripts" >&2
            failed+=("root:shell-inventory-unavailable")
        elif ! filtered_shell_inventory="$(
            printf '%s\n' "$shell_inventory" \
                | awk '!/^(infrastructure|control|provisioning|ci-cd|research|shared|testing)\//'
        )"; then
            echo "ERROR: could not filter the tracked shell-script inventory" >&2
            failed+=("root:shell-inventory-invalid")
        else
            while IFS= read -r shell_target; do
                [[ -z "$shell_target" ]] && continue
                shell_targets+=("$shell_target")
            done <<< "$filtered_shell_inventory"
        fi
        if [ "${shell_targets[0]+present}" = "present" ]; then
            if ! shellcheck --severity=warning "${shell_targets[@]}"; then
                failed+=("root:shellcheck")
            fi
        elif [[ -n "$shell_inventory" && -z "$filtered_shell_inventory" ]]; then
            echo "--- root: no tracked shell scripts to check ---"
        fi
    else
        echo "ERROR: root lint requires shellcheck from the declared pixi environment" >&2
        failed+=("root:shellcheck-unavailable")
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

    expected_inventory_output=""
    expected_paths=""
    status_paths=""
    inventory_matches=1
    if ! expected_inventory_output="$(git config --file .gitmodules --get-regexp '^submodule\..*\.path$' 2>&1)"; then
        echo "ERROR: could not read the configured submodule inventory" >&2
        echo "$expected_inventory_output" >&2
        failed+=("submodule-config")
        inventory_matches=0
    else
        while read -r _ expected_path; do
            [[ -z "${expected_path:-}" ]] && continue
            expected_paths+="$expected_path"$'\n'
        done <<< "$expected_inventory_output"
        if [[ -z "$expected_paths" ]]; then
            echo "ERROR: configured submodule inventory is empty" >&2
            failed+=("submodule-config")
            inventory_matches=0
        fi
    fi

    submodule_status_output=""
    if ! submodule_status_output="$(git submodule status --recursive 2>&1)"; then
        echo "ERROR: could not read the pinned submodule inventory" >&2
        echo "$submodule_status_output" >&2
        failed+=("submodule-inventory")
        inventory_matches=0
    else
        while IFS= read -r status_line; do
            [[ -z "$status_line" ]] && continue
            status_prefix="${status_line:0:1}"
            status_record="${status_line:1}"
            status_path="${status_record#* }"
            status_path="${status_path%% (*}"
            if [[ -z "$status_path" || "$status_path" = "$status_record" ]]; then
                echo "ERROR: invalid submodule status record: $status_line" >&2
                failed+=("submodule-inventory")
                inventory_matches=0
                continue
            fi
            status_paths+="$status_path"$'\n'
            case "$status_prefix" in
                " ") ;;
                -)
                    echo "ERROR: pinned submodule is not initialized: $status_path" >&2
                    failed+=("$status_path:unavailable")
                    inventory_matches=0
                    ;;
                +)
                    echo "ERROR: submodule does not match its pinned commit: $status_path" >&2
                    failed+=("$status_path:pin-drift")
                    inventory_matches=0
                    ;;
                U)
                    echo "ERROR: submodule has a merge conflict: $status_path" >&2
                    failed+=("$status_path:conflict")
                    inventory_matches=0
                    ;;
                *)
                    echo "ERROR: unknown submodule status for $status_path" >&2
                    failed+=("$status_path:invalid-status")
                    inventory_matches=0
                    ;;
            esac
        done <<< "$submodule_status_output"
    fi

    while IFS= read -r expected_path; do
        [[ -z "$expected_path" ]] && continue
        if ! grep -Fxq "$expected_path" <<< "$status_paths"; then
            echo "ERROR: configured submodule is absent from the pinned inventory: $expected_path" >&2
            failed+=("$expected_path:pin-missing")
            inventory_matches=0
        fi
    done <<< "$expected_paths"

    while IFS= read -r status_path; do
        [[ -z "$status_path" ]] && continue
        if ! grep -Fxq "$status_path" <<< "$expected_paths"; then
            echo "ERROR: pinned submodule is absent from the configured inventory: $status_path" >&2
            failed+=("$status_path:config-missing")
            inventory_matches=0
        fi
    done <<< "$status_paths"

    if (( inventory_matches == 1 )); then
        echo "--- component lint is owned by each component repository CI ---"
    fi
    # Grafana credential hygiene + self-test (#179)
    pixi run python -I scripts/check_grafana_credentials.py --self-test || failed+=("grafana-gate-selftest")
    pixi run python -I scripts/check_grafana_credentials.py || failed+=("grafana-credential-hygiene")
    if [ "${failed[0]+present}" = "present" ]; then
        echo ""
        echo "ERROR: lint failed in: ${failed[*]}" >&2
        exit 1
    fi
    echo "--- lint complete ---"

# ===========================================================================
# Clean
# ===========================================================================

# Remove the root build directory
clean:
    rm -rf "{{BUILD_ROOT}}"

# ===========================================================================
# Quality
# ===========================================================================

# Validate YAML, NATS and Compose configs, and canonical Nomad HCL syntax and
# placeholder invariants. The locked pixi environment supplies the maintained
# HCL2 parser. NATS validation also requires a maintained nats-server parser;
# a missing parser fails closed.
validate-configs: test-milestone-registry
    #!/usr/bin/env bash
    set -euo pipefail
    grep -q '${NOMAD_SERVER_IP}' configs/nomad/client.hcl || { echo "client.hcl lost its placeholder"; exit 1; }
    # Anti-re-hardcoding guard (issue #320, regression from #181): server.hcl must
    # keep its ${NOMAD_ADVERTISE_ADDR} placeholder, never a literal Tailscale IP.
    grep -qF '${NOMAD_ADVERTISE_ADDR}' configs/nomad/server.hcl || {
        echo "configs/nomad/server.hcl lost its \${NOMAD_ADVERTISE_ADDR} placeholder (hardcoded IP re-introduced — see #181)"; exit 1;
    }
    pixi run yamllint -c .yamllint.yml .github/workflows/ configs/
    pixi run python scripts/validate_nomad_config.py
    pixi run bash tests/test-config-validators.sh
    pixi run bash tests/test-dispatch-envelope-schema.sh
    pixi run bash tests/test-lane-models.sh
    pixi run bash tests/test-push-signatures.sh
    bash tools/validate-nats-auth.sh
    bash tools/tests/test-validate-nats-auth.sh
    pixi run python scripts/validate_compose.py

# Validate all NATS configs with the required nats-server parser
validate-nats:
    python3 scripts/validate_nats_config.py

# Validate all docker-compose files (binary-free Python + PyYAML)
validate-compose:
    python3 scripts/validate_compose.py

# Run justfile recipe integrity + config-validator tests (build-free)
test-justfile-recipes:
    bash tests/test-justfile-recipes.sh
    bash tests/test-config-validators.sh
    bash tests/test-lane-models.sh

# Exercise installer resource bounds without invoking a live compiler toolchain.
test-resource-bounds:
    bash tests/test-resource-bounds.sh

# Prove root C++ recipes consume exact gitlink snapshots (no live build).
test-pinned-build-inputs:
    bash tests/test-build-pinned-submodule.sh

# Compare repository hierarchy copies with the pinned Myrmidons source.
check-hierarchy-sync:
    bash scripts/check-hierarchy-sync.sh

# Print the current lane-model pins (issue #465; Proposed ADR-020 is design context).
# Validates the canonical pin file configs/lane-models.yaml first.
lane-models:
    pixi run python tools/lane_models.py

# Emit source-able `export HEPH_*_MODEL=...` lines for loop launch shells:
#   eval "$(just loop-env)"
loop-env:
    @pixi run python tools/lane_models.py --env

# Lint test scripts for corrupted / non-runnable artifacts (guards #374)
lint-test-scripts:
    bash scripts/lint-test-scripts.sh

# Validate required-check workflows and repository-owned ruleset preservation (#386)
test-merge-queue-readiness:
    bash tests/github/merge-queue-readiness-portability.test.sh
    bash tests/github/merge-queue-readiness.test.sh
    bash tests/github/apply-repo-rulesets.test.sh

# Run only the repository-ruleset reconciliation safety contract (#475)
test-repo-ruleset-apply:
    bash tests/github/apply-repo-rulesets.test.sh

# Validate the current M1-M6 epic registration contract (#468; Proposed ADR-020 context)
test-milestone-registry:
    pixi run python tests/github/test_register_milestone_epics.py
    pixi run python tools/github/register-milestone-epics.py --check >/dev/null

# Render Nomad config placeholders to one explicit, approved directory.
# Nomad agent HCL does NOT expand OS env vars, so render before `nomad agent -config`.
# Pre-create an empty, owner-bound mode-0700 OUT_DIR. Set its exact path in
# NOMAD_RENDER_APPROVED_DIR and its device:inode in NOMAD_RENDER_APPROVED_ID.
# A Nomad or hclfmt parser must be available.
render-nomad-configs OUT_DIR:
    #!/usr/bin/env bash
    set -euo pipefail
    requested_dir={{ quote(OUT_DIR) }}
    python3 scripts/render_nomad_configs.py \
      --source-dir configs/nomad --output-dir "$requested_dir"

# Run all CI checks locally
ci: lint validate-configs check-doc-field-drift test-merge-queue-readiness test-milestone-registry web-ci
    @echo "All selected local checks passed; CI/CD remains authoritative"

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
# Infrastructure Services
# ===========================================================================

# Explain why Argus activation is unavailable at the current gitlink pin
argus-start:
    #!/usr/bin/env bash
    printf '%s\n' \
      'Argus activation is unavailable at the current pin.' \
      'Its start recipe creates a different credential path than its Compose stack mounts.' \
      'Integrate the reviewed Argus fix before activation.' >&2
    exit 2

# ===========================================================================
# One-Command Install (per host role)
# ===========================================================================

# Install all prerequisites for a worker host (podman, NATS, observability)
install-worker:
    bash e2e/doctor.sh --role worker --install
    @echo "Installation completed. Select and verify an authorized deployment path in docs/deployment.md before starting services."

# Install all prerequisites + build C++ binaries for a control host
install-control:
    bash e2e/doctor.sh --role control --install
    just _build-agamemnon _build-nestor
    @echo "Installation and builds completed. Select and verify an authorized deployment path in docs/deployment.md before starting services."

# ===========================================================================
# E2E Pipeline Testing
# ===========================================================================

# Start Claude Code myrmidon — multi-stage pipeline worker (plan → test → implement → review → ship)
start-claude-myrmidon NATS_URL="nats://localhost:4222":
    HOMERIC_LEGACY_SERVICE_UID="${HOMERIC_LEGACY_SERVICE_UID:?set HOMERIC_LEGACY_SERVICE_UID to the effective decimal service UID}" NATS_URL={{ quote(NATS_URL) }} python3 e2e/claude-myrmidon.py

# Run Claude myrmidon in dry-run mode (no Claude CLI, validates NATS pipeline only)
e2e-dry-run NATS_URL="nats://localhost:4222":
    DRY_RUN=1 NO_GITHUB=1 NATS_URL={{ quote(NATS_URL) }} python3 e2e/claude-myrmidon.py

# Start Claude multi-repo myrmidon — parallel pipeline for multi-repo justfile tasks
start-claude-myrmidon-multi NATS_URL="nats://localhost:4222":
    HOMERIC_LEGACY_SERVICE_UID="${HOMERIC_LEGACY_SERVICE_UID:?set HOMERIC_LEGACY_SERVICE_UID to the effective decimal service UID}" NATS_URL={{ quote(NATS_URL) }} python3 e2e/claude-myrmidon-multi.py

# Run multi-repo myrmidon in dry-run mode (validates NATS fan-out/fan-in, no Claude API)
e2e-multi-dry-run NATS_URL="nats://localhost:4222":
    DRY_RUN=1 NO_GITHUB=1 NATS_URL={{ quote(NATS_URL) }} python3 e2e/claude-myrmidon-multi.py

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

# Compatibility alias for the CI-enforced justfile integrity entry point.
e2e-test-justfiles:
    just test-justfile-recipes

# Full validation suite (Docker E2E + Conan + pip)
e2e-full: e2e-test e2e-conan-validate e2e-pip-validate
    @echo "=== Full E2E validation complete ==="

# ===========================================================================
# AlexNet Mesh Fleet Deployment
# ===========================================================================
# Run Odyssey's AlexNet training independently on an explicitly approved fleet,
# one training job per host, with results collected centrally. Live fleet
# operations require current target readback and exact effect authorization;
# use CI's hermetic suites when this checkout has no approved mesh access.
#
# Per-host CPU-specific Mojo flags are auto-applied via alexnet-train.sh:
#   aeolus (Sandy Bridge-E) gets --target-features -avx2 because the
#   2012-era silicon has AVX only, no AVX2. The May-2026 cross-CPU survey
#   confirmed the Intel fleet runs Mojo cleanly without AVX-512, so no
#   AVX-512 stripping is needed for Skylake/Whiskey Lake/Lunar Lake hosts.
#
# Default hosts: epimetheus (build/distribution hub), apollo, aeolus, and
# hephaestus. This mirrors the protected manual workflow. Hermes remains an
# explicit opt-in only after exact live prerequisites and operator approval.
# See docs/runbooks/alexnet-mesh-fleet.md for the full deployment plan.

# Launch AlexNet training on the current host (per-host script).
# ALL parameters are passed as env vars, NOT positional args. Example:
#   EPOCHS=10 BATCH_SIZE=64 just alexnet-train
#   FORCE_AVX2=1 MAX_BATCHES=3 just alexnet-train
[script("/usr/bin/python3", "-I", "-E")]
alexnet-train:
    import runpy, sys
    sys.argv = ["e2e/alexnet-launch.py", "train"]
    runpy.run_path("e2e/alexnet-launch.py", run_name="__main__")

# Epimetheus/hub only — build the image, distribute to fleet, launch training.
# Pass optional config via env vars: EPOCHS, BATCH_SIZE, FLEET, DRY_RUN, etc.
[script("/usr/bin/python3", "-I", "-E")]
alexnet-fleet-deploy:
    import runpy, sys
    sys.argv = ["e2e/alexnet-launch.py", "deploy"]
    runpy.run_path("e2e/alexnet-launch.py", run_name="__main__")

# Wait for every selected training container, then verify completion evidence.
# Extra flags are forwarded to the gate (for example, --smoke or
# --timeout-minutes 90).
alexnet-fleet-wait *ARGS:
    bash e2e/alexnet-fleet-wait.sh {{ARGS}}

# Centrally collect training results from all fleet hosts (rsync over Tailscale).
# Pass CENTRAL_DIR=~/custom-path just alexnet-fleet-collect to override the dir.
[script("/usr/bin/python3", "-I", "-E")]
alexnet-fleet-collect:
    import runpy, sys
    sys.argv = ["e2e/alexnet-launch.py", "collect"]
    runpy.run_path("e2e/alexnet-launch.py", run_name="__main__")

# Remove only the exact alexnet-training container on every approved fleet host.
# Interactive runs require an exact typed target; non-interactive runs require
# ALEXNET_TEARDOWN_APPROVED_FLEET to match FLEET. Results and scripts are kept.
[script("/usr/bin/python3", "-I", "-E")]
alexnet-fleet-teardown:
    import runpy, sys
    sys.argv = ["e2e/alexnet-launch.py", "teardown"]
    runpy.run_path("e2e/alexnet-launch.py", run_name="__main__")

# Convenience: end-to-end smoke test on the current host (3 synthetic batches).
# Same as: MAX_BATCHES=3 just alexnet-train
[script("/usr/bin/python3", "-I", "-E")]
alexnet-smoke:
    import os, runpy, sys
    os.environ["MAX_BATCHES"] = "3"
    sys.argv = ["e2e/alexnet-launch.py", "train"]
    runpy.run_path("e2e/alexnet-launch.py", run_name="__main__")

# Run the hermetic mesh-script failure-oracle suite. It does not query Tailscale
# unless CHAOS_NETWORK=1 is separately authorized, but it can change the local
# training container and therefore requires ALEXNET_CHAOS_APPROVED_HOST to equal
# the current hostname. CHAOS_TIMEOUT=<s> overrides the case guard (default 45).
[script("/usr/bin/python3", "-I", "-E")]
alexnet-mesh-chaos:
    import runpy, sys
    sys.argv = ["e2e/alexnet-launch.py", "chaos"]
    runpy.run_path("e2e/alexnet-launch.py", run_name="__main__")

# Same suite plus explicitly authorized live cases: C4 verifies the clobber
# guard and C5 kills a real local training container. It requires the image,
# exact local-host approval, and an idle alexnet-training container namespace.
[script("/usr/bin/python3", "-I", "-E")]
alexnet-mesh-chaos-live:
    import os, runpy, sys
    os.environ["CHAOS_LIVE"] = "1"
    sys.argv = ["e2e/alexnet-launch.py", "chaos"]
    runpy.run_path("e2e/alexnet-launch.py", run_name="__main__")

# ===========================================================================
# Python Package Installation
# ===========================================================================

# Install all Python packages in editable mode
install-python:
    pip install -e shared/Hephaestus
    pip install -e infrastructure/Hermes
    pip install -e provisioning/Telemachy

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
# GitHub Org Ruleset Management
# ===========================================================================

# Regenerate all tracked repository-ruleset payloads from the sole policy source
repo-rulesets-render:
    python3 tools/github/render-fleet-ruleset.py --write

# Read-only exact-fleet evaluate preview
repo-rulesets-apply:
    ./tools/github/apply-repo-rulesets.sh --evaluate --all --dry-run

# Read-only exact active preview for a reviewed comma-separated pilot set
repo-rulesets-preview REPOS:
    ./tools/github/apply-repo-rulesets.sh --active --repos "{{REPOS}}" --dry-run

# Read-only preview for one reviewed repository-owned extras retirement
repo-rulesets-preview-approved-extra REPOS APPROVAL:
    ./tools/github/apply-repo-rulesets.sh --active --repos "{{REPOS}}" --dry-run --extra-ruleset-approval-file "{{APPROVAL}}"

# Pilot activation with fresh GitHub-verified proof and an operator-owned snapshot path
repo-rulesets-activate-repos REPOS EVIDENCE SNAPSHOT:
    RULESET_SNAPSHOT_DIR="{{SNAPSHOT}}" ./tools/github/apply-repo-rulesets.sh --active --repos "{{REPOS}}" --evidence-file "{{EVIDENCE}}"

# Pilot activation that retires one exact reviewed repository-owned extras ruleset
repo-rulesets-activate-approved-extra REPOS EVIDENCE SNAPSHOT APPROVAL:
    RULESET_SNAPSHOT_DIR="{{SNAPSHOT}}" ./tools/github/apply-repo-rulesets.sh --active --repos "{{REPOS}}" --evidence-file "{{EVIDENCE}}" --extra-ruleset-approval-file "{{APPROVAL}}"

# Explicit exact-fleet activation after PR/merge-group/main gate proof
repo-rulesets-activate EVIDENCE:
    ./tools/github/apply-repo-rulesets.sh --active --all --evidence-file "{{EVIDENCE}}"

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
      [configs/github/repo-ruleset.json]=active
      [configs/github/repo-ruleset-active.json]=active
      [configs/github/repo-ruleset-evaluate.json]=evaluate
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
    echo "PASSED: all ruleset configs hold their intended enforcement"

# ===========================================================================
# Repository security-setting discovery
# ===========================================================================
# These recipes make no remote changes. Interpret readbacks with current
# official documentation and docs/runbooks/disable-code-quality.md.

# Discover the canonical gitlink inventory plus Odysseus
[script("/usr/bin/env", "-u", "BASH_ENV", "-u", "ENV", "/bin/bash", "--noprofile", "--norc", "-p")]
code-quality-audit:
    /bin/bash --noprofile --norc -p tools/probe-code-quality.sh

# Discover a separately scoped live organization inventory
[script("/usr/bin/env", "-u", "BASH_ENV", "-u", "ENV", "/bin/bash", "--noprofile", "--norc", "-p")]
code-quality-audit-all:
    /bin/bash --noprofile --norc -p tools/probe-code-quality.sh --all

# Write current discovery readbacks to a fresh owner-private artifact
[script("/usr/bin/env", "-u", "BASH_ENV", "-u", "ENV", "/bin/bash", "--noprofile", "--norc", "-p")]
code-quality-update:
    report_dir=$(/usr/bin/mktemp -d /tmp/odysseus-code-quality.XXXXXXXX) && \
      /bin/chmod 0700 "$report_dir" && \
      report_path="$report_dir/ecosystem-code-quality-status.md" && \
      /bin/bash --noprofile --norc -p tools/probe-code-quality.sh --output "$report_path" && \
      /usr/bin/printf 'Code Quality report: %s\n' "$report_path"

# Print the contextual runbook path
code-quality-runbook:
    @echo "Open docs/runbooks/disable-code-quality.md for current documentation and readback requirements."

# ===========================================================================
# Atlas review wave (compatibility surface pending the Wave-4 Argus migration)
# ===========================================================================

# Dispatch the pinned Atlas milestone review wave via Agamemnon
atlas-review-dispatch MILESTONE PR AGAMEMNON_URL="http://localhost:8080":
    infrastructure/Argus/dashboard/scripts/atlas-review-dispatch.sh {{MILESTONE}} {{PR}} {{AGAMEMNON_URL}}

# Aggregate the pinned Atlas review wave results
atlas-review-aggregate MILESTONE TEAM AGAMEMNON_URL="http://localhost:8080":
    infrastructure/Argus/dashboard/scripts/atlas-review-aggregate.sh {{MILESTONE}} {{TEAM}} {{AGAMEMNON_URL}}

# Post GitHub commit status for the pinned review wave outcome
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

# ===========================================================================
# Claude Code Tooling (settings.json reconciliation)
# ===========================================================================

# Reconcile ~/.claude/settings.json: register the Athena marketplace + plugin
# (and drop pre-ADR-016 / non-canonical legacy plugin keys). Default is
# check-only; pass install="true" to apply changes.
claude-setup install="false":
    INSTALL={{ install }} bash scripts/install/60-claude-tooling.sh
