#!/usr/bin/env bash
# HomericIntelligence Doctor — E2E Pipeline Prerequisite Checker
#
# Verifies that all dependencies required by the cross-host E2E evaluation
# pipeline are installed and configured correctly. Checks follow the component
# hierarchy from docs/architecture.md.
#
# Usage:
#   just doctor                    # Check-only mode
#   just doctor --install          # Check + install missing dependencies
#   just doctor --role worker      # Only check worker-host dependencies
#   just doctor --role control     # Only check control-host dependencies
#   just doctor --check-services --worker-ip IP --control-ip IP
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed
set -uo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ─── Counters ────────────────────────────────────────────────────────────────
_PASS=0; _FAIL=0; _WARN=0; _SKIP=0

check_pass()  { _PASS=$((_PASS + 1));  echo -e "  ${GREEN}✓${NC} $1"; }
check_fail()  { _FAIL=$((_FAIL + 1));  echo -e "  ${RED}✗${NC} $1"; }
check_warn()  { _WARN=$((_WARN + 1));  echo -e "  ${YELLOW}⚠${NC} $1"; }
check_skip()  { _SKIP=$((_SKIP + 1));  echo -e "  ${DIM}–${NC} $1 ${DIM}(skipped)${NC}"; }
section()     { echo -e "\n${BOLD}${CYAN}$1${NC}"; }

# ─── Argument Parsing ────────────────────────────────────────────────────────
INSTALL=false
ROLE="all"              # all | worker | control
CHECK_SERVICES=false
WORKER_IP=""
CONTROL_IP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install)         INSTALL=true; shift ;;
        --role)            ROLE="$2"; shift 2 ;;
        --check-services)  CHECK_SERVICES=true; shift ;;
        --worker-ip)       WORKER_IP="$2"; shift 2 ;;
        --control-ip)      CONTROL_IP="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: bash e2e/doctor.sh [--install] [--role worker|control] [--check-services --worker-ip IP --control-ip IP]"
            exit 0
            ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# ─── Helpers ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODYSSEUS_ROOT="$(dirname "$SCRIPT_DIR")"

# Check if a command exists
has_cmd() { command -v "$1" &>/dev/null; }

# Get version string from a command (first line, extract version number)
get_version() { "$@" 2>&1 | head -1 | grep -oP '\d+\.\d+[\.\d]*' | head -1; }

# Install a package via apt (requires --install flag)
apt_install() {
    local pkg="$1"
    if $INSTALL; then
        echo -e "    ${BLUE}→${NC} Installing $pkg..."
        sudo apt-get install -y "$pkg" >/dev/null 2>&1
        return $?
    fi
    return 1
}

# Compare version: returns 0 if $1 >= $2
version_gte() {
    printf '%s\n%s\n' "$2" "$1" | sort -V | head -1 | grep -qF "$2"
}

should_check_worker()  { [[ "$ROLE" == "all" || "$ROLE" == "worker" ]]; }
should_check_control() { [[ "$ROLE" == "all" || "$ROLE" == "control" ]]; }

# ─── Banner ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}HomericIntelligence Doctor — E2E Pipeline Prerequisites${NC}"
echo "═══════════════════════════════════════════════════════"
echo -e "  Role: ${CYAN}${ROLE}${NC}    Install: ${CYAN}${INSTALL}${NC}"

# ═════════════════════════════════════════════════════════════════════════════
# Section 1: Core Tooling (all hosts)
# Required by: Odysseus meta-repo, E2E scripts, Myrmidons provisioning
# ═════════════════════════════════════════════════════════════════════════════
section "Core Tooling"

# git
if has_cmd git; then
    check_pass "git $(get_version git --version)"
else
    check_fail "git — NOT FOUND"
    apt_install git && check_pass "git installed" || true
fi

# just
if has_cmd just; then
    check_pass "just $(get_version just --version)"
else
    check_fail "just — NOT FOUND"
    if $INSTALL; then
        echo -e "    ${BLUE}→${NC} Installing just..."
        if has_cmd cargo; then
            cargo install just >/dev/null 2>&1 && check_pass "just installed via cargo"
        else
            # Try prebuilt binary
            curl -sSf https://just.systems/install.sh | bash -s -- --to /usr/local/bin >/dev/null 2>&1 \
                && check_pass "just installed via prebuilt binary" \
                || check_fail "just — could not install (try: cargo install just)"
        fi
    fi
fi

# python3
if has_cmd python3; then
    check_pass "python3 $(get_version python3 --version)"
else
    check_fail "python3 — NOT FOUND"
    apt_install python3 && check_pass "python3 installed" || true
fi

# pip3
if has_cmd pip3; then
    check_pass "pip3 $(get_version pip3 --version)"
else
    check_fail "pip3 — NOT FOUND"
    apt_install python3-pip && check_pass "pip3 installed" || true
fi

# curl
if has_cmd curl; then
    check_pass "curl $(get_version curl --version)"
else
    check_fail "curl — NOT FOUND"
    apt_install curl && check_pass "curl installed" || true
fi

# jq
if has_cmd jq; then
    check_pass "jq $(get_version jq --version)"
else
    check_fail "jq — NOT FOUND"
    apt_install jq && check_pass "jq installed" || true
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 2: Tailscale (Network Topology — all hosts)
# Required by: Cross-host NATS, Agamemnon/Nestor communication over mesh
# ═════════════════════════════════════════════════════════════════════════════
section "Tailscale (Network Topology)"

if has_cmd tailscale; then
    check_pass "tailscale $(get_version tailscale --version)"
else
    check_fail "tailscale — NOT FOUND"
    if $INSTALL; then
        echo -e "    ${BLUE}→${NC} Installing tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1 \
            && check_pass "tailscale installed" \
            || check_fail "tailscale — install failed (see https://tailscale.com/download)"
    fi
fi

# Check if tailscaled is running
if has_cmd tailscale; then
    if tailscale status >/dev/null 2>&1; then
        check_pass "tailscaled running"
    else
        check_fail "tailscaled not running"
        if $INSTALL; then
            sudo systemctl start tailscaled 2>/dev/null \
                && check_pass "tailscaled started" \
                || check_warn "tailscaled — could not start (run: sudo tailscale up)"
        fi
    fi
fi

# Check firewalld tailscale0 zone (worker hosts only)
if should_check_worker && has_cmd firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
    ZONE=$(firewall-cmd --get-zone-of-interface=tailscale0 2>/dev/null || echo "")
    if [ "$ZONE" = "trusted" ]; then
        check_pass "firewalld tailscale0 zone: trusted"
    else
        check_fail "firewalld tailscale0 not in trusted zone (zone: ${ZONE:-unknown})"
        if [ "$INSTALL" = "true" ]; then
            sudo firewall-cmd --permanent --zone=trusted --add-interface=tailscale0 \
                && sudo firewall-cmd --reload \
                && check_pass "firewalld tailscale0 added to trusted zone" || true
        fi
    fi
fi

# Check peer reachability (if IPs provided)
if [[ -n "$WORKER_IP" ]]; then
    if ping -c1 -W3 "$WORKER_IP" >/dev/null 2>&1; then
        check_pass "Worker host ($WORKER_IP) reachable"
    else
        check_fail "Worker host ($WORKER_IP) NOT reachable"
    fi
fi
if [[ -n "$CONTROL_IP" ]]; then
    if ping -c1 -W3 "$CONTROL_IP" >/dev/null 2>&1; then
        check_pass "Control host ($CONTROL_IP) reachable"
    else
        check_fail "Control host ($CONTROL_IP) NOT reachable"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 3: Container Runtime (Worker host — AchaeanFleet / compose stack)
# Required by: docker-compose.e2e.yml, docker-compose.crosshost.yml
# ═════════════════════════════════════════════════════════════════════════════
if should_check_worker; then
    section "Container Runtime (AchaeanFleet)"

    # podman
    if has_cmd podman; then
        check_pass "podman $(get_version podman --version)"
    else
        check_fail "podman — NOT FOUND"
        apt_install podman && check_pass "podman installed" || true
    fi

    # podman compose
    if has_cmd podman && podman compose version >/dev/null 2>&1; then
        COMPOSE_VER=$(podman compose version 2>&1 | grep -oP '\d+\.\d+[\.\d]*' | head -1)
        check_pass "podman compose ${COMPOSE_VER}"
    else
        check_fail "podman compose — NOT FOUND"
        apt_install podman-compose && check_pass "podman-compose installed" || true
    fi

    # podman socket
    PODMAN_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
    if [[ -S "$PODMAN_SOCK" ]]; then
        check_pass "podman socket active ($PODMAN_SOCK)"
    else
        check_fail "podman socket not found"
        if $INSTALL; then
            # Ensure XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS are set —
            # SSH sessions and sudo strip these, breaking systemctl --user.
            export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
            export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

            # If the unit file doesn't exist (podman built from source), install it first.
            if ! systemctl --user cat podman.socket &>/dev/null; then
                PODMAN_SRC_UNIT=$(ls ~/.local/src/podman-*/contrib/systemd/user/podman.socket \
                                     /usr/local/src/podman-*/contrib/systemd/user/podman.socket \
                                     2>/dev/null | head -1)
                PODMAN_SRC_SERVICE=$(ls ~/.local/src/podman-*/contrib/systemd/user/podman.service.in \
                                        /usr/local/src/podman-*/contrib/systemd/user/podman.service.in \
                                        2>/dev/null | head -1)
                if [[ -n "$PODMAN_SRC_UNIT" ]]; then
                    mkdir -p ~/.config/systemd/user
                    cp "$PODMAN_SRC_UNIT" ~/.config/systemd/user/podman.socket
                    if [[ -n "$PODMAN_SRC_SERVICE" ]]; then
                        PODMAN_BIN=$(command -v podman)
                        sed "s|@@PODMAN@@|${PODMAN_BIN}|g" "$PODMAN_SRC_SERVICE" \
                            > ~/.config/systemd/user/podman.service
                    fi
                    systemctl --user daemon-reload
                else
                    check_warn "podman socket — unit files not found (podman built from source?)"
                    echo -e "    ${DIM}Install unit files manually from your podman source tree:${NC}"
                    echo -e "    ${DIM}  cp <src>/contrib/systemd/user/podman.socket ~/.config/systemd/user/${NC}"
                    echo -e "    ${DIM}  systemctl --user daemon-reload${NC}"
                fi
            fi

            if systemctl --user enable --now podman.socket 2>/dev/null; then
                check_pass "podman socket enabled"
            else
                check_warn "podman socket — could not enable via systemctl --user"
                echo -e "    ${DIM}This usually means no systemd user session is running (common over SSH).${NC}"
                echo -e "    ${DIM}Fix: run 'sudo loginctl enable-linger $USER' then reconnect,${NC}"
                echo -e "    ${DIM}or run 'systemctl --user enable --now podman.socket' from a desktop session.${NC}"
            fi
        fi
    fi

    # aardvark-dns stale check (WSL2 specific)
    AARDVARK_PID_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/networks/aardvark-dns"
    if [[ -f "$AARDVARK_PID_DIR/aardvark.pid" ]]; then
        AARDVARK_PID=$(cat "$AARDVARK_PID_DIR/aardvark.pid" 2>/dev/null || echo "")
        if [[ -n "$AARDVARK_PID" ]] && ! kill -0 "$AARDVARK_PID" 2>/dev/null; then
            check_warn "aardvark-dns PID stale (PID $AARDVARK_PID not running)"
            if $INSTALL; then
                rm -f "$AARDVARK_PID_DIR/aardvark.pid" 2>/dev/null \
                    && check_pass "stale aardvark-dns PID cleared" \
                    || true
            fi
        else
            check_pass "aardvark-dns OK"
        fi
    else
        check_pass "aardvark-dns no stale PID"
    fi
else
    section "Container Runtime (AchaeanFleet)"
    check_skip "Container runtime checks (role=$ROLE)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 4: C++ Build Chain (Control host — builds Nestor, Charybdis)
# Required by: just _build-nestor, just _build-agamemnon, just _build-charybdis
# ═════════════════════════════════════════════════════════════════════════════
if should_check_control; then
    section "C++ Build Chain"

    # cmake >= 3.20
    if has_cmd cmake; then
        CMAKE_VER=$(get_version cmake --version)
        if version_gte "$CMAKE_VER" "3.20"; then
            check_pass "cmake $CMAKE_VER (>= 3.20)"
        else
            check_fail "cmake $CMAKE_VER — need >= 3.20"
        fi
    else
        check_fail "cmake — NOT FOUND"
        apt_install cmake && check_pass "cmake installed" || true
    fi

    # ninja
    if has_cmd ninja; then
        check_pass "ninja $(get_version ninja --version)"
    else
        check_fail "ninja — NOT FOUND"
        apt_install ninja-build && check_pass "ninja installed" || true
    fi

    # g++ >= 11
    if has_cmd g++; then
        GPP_VER=$(get_version g++ --version)
        if version_gte "$GPP_VER" "11"; then
            check_pass "g++ $GPP_VER (>= 11)"
        else
            check_fail "g++ $GPP_VER — need >= 11 for C++20"
        fi
    else
        check_fail "g++ — NOT FOUND"
        apt_install g++ && check_pass "g++ installed" || true
    fi

    # libssl-dev
    if dpkg -l libssl-dev >/dev/null 2>&1; then
        LIBSSL_VER=$(dpkg -l libssl-dev 2>/dev/null | awk '/^ii/{print $3}' | head -1)
        check_pass "libssl-dev $LIBSSL_VER"
    else
        check_fail "libssl-dev — NOT FOUND (required by nats.c TLS)"
        apt_install libssl-dev && check_pass "libssl-dev installed" || true
    fi

    # make (needed for gtest CMake recipe)
    if has_cmd make; then
        check_pass "make $(get_version make --version)"
    else
        check_fail "make — NOT FOUND (required by gtest CMake recipe)"
        apt_install make && check_pass "make installed" || true
    fi

    # conan >= 2.0
    if has_cmd conan; then
        CONAN_VER=$(get_version conan --version)
        if version_gte "$CONAN_VER" "2.0"; then
            check_pass "conan $CONAN_VER (>= 2.0)"
        else
            check_fail "conan $CONAN_VER — need >= 2.0"
        fi
    else
        check_fail "conan — NOT FOUND"
        if $INSTALL; then
            echo -e "    ${BLUE}→${NC} Installing conan..."
            pip3 install --break-system-packages conan >/dev/null 2>&1 \
                && check_pass "conan installed" \
                || check_fail "conan — install failed (try: pip3 install conan)"
        fi
    fi

    # Conan default profile
    if has_cmd conan; then
        if conan profile show >/dev/null 2>&1; then
            check_pass "Conan default profile exists"
        else
            check_fail "Conan default profile missing"
            if $INSTALL; then
                conan profile detect --force >/dev/null 2>&1 \
                    && check_pass "Conan default profile created" \
                    || check_fail "Conan profile detect failed"
            fi
        fi
    fi

    # pixi
    if has_cmd pixi; then
        check_pass "pixi $(get_version pixi --version)"
    else
        check_fail "pixi — NOT FOUND"
        if $INSTALL; then
            echo -e "    ${BLUE}→${NC} Installing pixi..."
            curl -fsSL https://pixi.sh/install.sh | bash >/dev/null 2>&1 \
                && check_pass "pixi installed" \
                || check_fail "pixi — install failed (see https://pixi.sh)"
        fi
    fi
else
    section "C++ Build Chain"
    check_skip "C++ build chain checks (role=$ROLE)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 5: Python Dependencies (Console + observability)
# Required by: tools/odysseus-console.py, e2e/nats-loki-bridge/
# ═════════════════════════════════════════════════════════════════════════════
section "Python Dependencies"

# nats-py (required by odysseus-console.py)
if python3 -c "import nats" 2>/dev/null; then
    NATS_PY_VER=$(python3 -c "import importlib.metadata; print(importlib.metadata.version('nats-py'))" 2>/dev/null || echo "installed")
    check_pass "nats-py $NATS_PY_VER"
else
    check_fail "nats-py — NOT FOUND (required by tools/odysseus-console.py)"
    if $INSTALL; then
        echo -e "    ${BLUE}→${NC} Installing nats-py..."
        pip3 install --break-system-packages nats-py >/dev/null 2>&1 \
            && check_pass "nats-py installed" \
            || check_fail "nats-py — install failed (try: pip3 install nats-py)"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 6: Submodule Health (Odysseus meta-repo)
# Required by: All submodule builds, Myrmidons provisioning
# ═════════════════════════════════════════════════════════════════════════════
section "Submodule Health"

# Check if we're in the Odysseus repo
if [[ -f "$ODYSSEUS_ROOT/.gitmodules" ]]; then
    # Check submodules initialized
    UNINIT_COUNT=$(cd "$ODYSSEUS_ROOT" && git submodule status 2>/dev/null | grep -c '^-' || true)
    TOTAL_SUBS=$(cd "$ODYSSEUS_ROOT" && git submodule status 2>/dev/null | wc -l)
    if [[ "$UNINIT_COUNT" -eq 0 ]]; then
        check_pass "All $TOTAL_SUBS submodules initialized"
    else
        check_fail "$UNINIT_COUNT / $TOTAL_SUBS submodules NOT initialized"
        if $INSTALL; then
            echo -e "    ${BLUE}→${NC} Initializing submodules..."
            (cd "$ODYSSEUS_ROOT" && git submodule update --init --recursive >/dev/null 2>&1) \
                && check_pass "Submodules initialized" \
                || check_fail "Submodule init failed"
        fi
    fi

    # Check Myrmidons not targeting ai-maestro (#77)
    MYRMIDONS_DIR="$ODYSSEUS_ROOT/provisioning/Myrmidons"
    if [[ -d "$MYRMIDONS_DIR/scripts" ]]; then
        STALE_REFS=$(grep -r "aim_" "$MYRMIDONS_DIR/scripts/" 2>/dev/null | wc -l || true)
        if [[ "$STALE_REFS" -eq 0 ]]; then
            check_pass "Myrmidons targets Agamemnon (not ai-maestro)"
        else
            check_fail "Myrmidons has $STALE_REFS stale ai-maestro references (aim_*)"
            if $INSTALL; then
                echo -e "    ${BLUE}→${NC} Updating Myrmidons to main..."
                (cd "$MYRMIDONS_DIR" && git checkout main && git pull) >/dev/null 2>&1 \
                    && check_pass "Myrmidons updated" \
                    || check_fail "Myrmidons update failed"
            fi
        fi
    else
        check_warn "Myrmidons scripts directory not found — submodule may not be initialized"
    fi

    # Check symlinks resolve
    BROKEN_LINKS=0
    while IFS= read -r line; do
        subpath=$(echo "$line" | awk '{print $2}')
        resolved=$(readlink -f "$ODYSSEUS_ROOT/$subpath" 2>/dev/null || echo "")
        if [[ -z "$resolved" || ! -d "$resolved" ]]; then
            BROKEN_LINKS=$((BROKEN_LINKS + 1))
            check_warn "Symlink does not resolve: $subpath"
        fi
    done < <(cd "$ODYSSEUS_ROOT" && git submodule status 2>/dev/null)
    if [[ "$BROKEN_LINKS" -eq 0 ]]; then
        check_pass "All submodule paths resolve"
    fi
else
    check_warn "Not in Odysseus repo — skipping submodule checks"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 7: Network Connectivity (cross-host service health)
# Only checked with --check-services --worker-ip IP --control-ip IP
# ═════════════════════════════════════════════════════════════════════════════
if $CHECK_SERVICES; then
    section "Service Health (Cross-Host)"

    if [[ -n "$WORKER_IP" ]]; then
        # NATS
        if curl -sf "http://${WORKER_IP}:8222/healthz" >/dev/null 2>&1; then
            check_pass "NATS @ ${WORKER_IP}:8222"
        else
            check_fail "NATS @ ${WORKER_IP}:8222 — NOT REACHABLE"
        fi

        # Agamemnon
        if curl -sf "http://${WORKER_IP}:8080/v1/health" >/dev/null 2>&1; then
            check_pass "Agamemnon @ ${WORKER_IP}:8080"
        else
            check_fail "Agamemnon @ ${WORKER_IP}:8080 — NOT REACHABLE"
        fi

        # Hermes
        if curl -sf "http://${WORKER_IP}:8085/health" >/dev/null 2>&1; then
            check_pass "Hermes @ ${WORKER_IP}:8085"
        else
            check_fail "Hermes @ ${WORKER_IP}:8085 — NOT REACHABLE"
        fi

        # Grafana
        if curl -sf "http://${WORKER_IP}:3001/api/health" >/dev/null 2>&1; then
            check_pass "Grafana @ ${WORKER_IP}:3001"
        else
            check_fail "Grafana @ ${WORKER_IP}:3001 — NOT REACHABLE"
        fi

        # Prometheus
        if curl -sf "http://${WORKER_IP}:9090/-/healthy" >/dev/null 2>&1; then
            check_pass "Prometheus @ ${WORKER_IP}:9090"
        else
            check_fail "Prometheus @ ${WORKER_IP}:9090 — NOT REACHABLE"
        fi

        # Argus Exporter
        if curl -sf "http://${WORKER_IP}:9100/metrics" >/dev/null 2>&1; then
            check_pass "Argus Exporter @ ${WORKER_IP}:9100"
        else
            check_fail "Argus Exporter @ ${WORKER_IP}:9100 — NOT REACHABLE"
        fi
    else
        check_warn "No --worker-ip provided — skipping worker service checks"
    fi

    if [[ -n "$CONTROL_IP" ]]; then
        # Nestor
        if curl -sf "http://${CONTROL_IP}:8081/v1/health" >/dev/null 2>&1; then
            check_pass "Nestor @ ${CONTROL_IP}:8081"
        else
            check_fail "Nestor @ ${CONTROL_IP}:8081 — NOT REACHABLE"
        fi
    else
        check_warn "No --control-ip provided — skipping control service checks"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════"
TOTAL=$((_PASS + _FAIL + _WARN))
if [[ "$_FAIL" -eq 0 && "$_WARN" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All $TOTAL checks passed.${NC}"
elif [[ "$_FAIL" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}$_PASS passed${NC}, ${YELLOW}$_WARN warnings${NC}"
else
    echo -e "${RED}${BOLD}$_FAIL failed${NC}, ${GREEN}$_PASS passed${NC}, ${YELLOW}$_WARN warnings${NC}"
    if ! $INSTALL; then
        echo -e "Run ${CYAN}just doctor --install${NC} to fix installable issues."
    fi
fi
echo ""

# Exit with failure if any checks failed
[[ "$_FAIL" -eq 0 ]]
