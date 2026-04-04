#!/usr/bin/env bash
# HomericIntelligence Conan Install Validation
# Validates that C++ packages can be exported, consumed, and installed via Conan.
# Separate from the Docker-based E2E (run-hello-world.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODYSSEUS_ROOT="$(dirname "$SCRIPT_DIR")"
STAGING_PREFIX="$(mktemp -d)"
CONSUMER_DIR="$SCRIPT_DIR/conan-consumer"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
pass() { echo -e "  ${GREEN}✓ PASS${NC}: $1"; }
fail() { echo -e "  ${RED}✗ FAIL${NC}: $1"; exit 1; }
info() { echo -e "\n${BLUE}══${NC} ${YELLOW}$1${NC}"; }

cleanup() {
    rm -rf "$STAGING_PREFIX"
}
trap cleanup EXIT

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  HomericIntelligence Conan Install Validation            ║"
echo "╚══════════════════════════════════════════════════════════╝"

# ─── Phase 1: Export packages to local Conan cache ─────────────────────
info "Phase 1: Export C++ packages to local Conan cache"

for pkg_dir in \
    "$ODYSSEUS_ROOT/control/ProjectAgamemnon" \
    "$ODYSSEUS_ROOT/control/ProjectNestor" \
    "$ODYSSEUS_ROOT/testing/ProjectCharybdis" \
    "$ODYSSEUS_ROOT/provisioning/ProjectKeystone"; do
    pkg_name="$(basename "$pkg_dir")"
    if [ -f "$pkg_dir/conanfile.py" ]; then
        conan export "$pkg_dir" && pass "Exported $pkg_name" \
            || fail "Failed to export $pkg_name"
    else
        echo -e "  ${YELLOW}⊘ SKIP${NC}: $pkg_name (no conanfile.py)"
    fi
done

# ─── Phase 2: Build consumer project ──────────────────────────────────
info "Phase 2: Build Conan consumer project"

CONSUMER_BUILD="$(mktemp -d)"

conan install "$CONSUMER_DIR" \
    --output-folder="$CONSUMER_BUILD" \
    --build=missing \
    && pass "Consumer Conan install succeeded" \
    || fail "Consumer Conan install failed"

cmake -S "$CONSUMER_DIR" -B "$CONSUMER_BUILD" \
    -DCMAKE_TOOLCHAIN_FILE="$CONSUMER_BUILD/conan_toolchain.cmake" \
    -DCMAKE_BUILD_TYPE=Debug \
    -G Ninja \
    && pass "Consumer CMake configure succeeded" \
    || fail "Consumer CMake configure failed"

cmake --build "$CONSUMER_BUILD" \
    && pass "Consumer build succeeded (headers resolve, libraries link)" \
    || fail "Consumer build failed"

# Run the consumer binary
"$CONSUMER_BUILD/validate_install" \
    && pass "Consumer binary ran successfully" \
    || fail "Consumer binary failed"

rm -rf "$CONSUMER_BUILD"

# ─── Phase 3: CMake install validation ─────────────────────────────────
info "Phase 3: CMake install to staging prefix"

BUILD_ROOT="$ODYSSEUS_ROOT/build"

for pkg in ProjectAgamemnon ProjectNestor ProjectCharybdis ProjectKeystone; do
    build_dir="$BUILD_ROOT/$pkg"
    if [ -d "$build_dir" ]; then
        cmake --install "$build_dir" --prefix "$STAGING_PREFIX" 2>/dev/null \
            && pass "Installed $pkg to staging prefix" \
            || fail "Failed to install $pkg"
    else
        echo -e "  ${YELLOW}⊘ SKIP${NC}: $pkg (not built — run 'just build' first)"
    fi
done

# Verify expected files exist
info "Phase 4: Verify installed artifacts"

for binary in ProjectAgamemnon_server ProjectNestor_server; do
    if [ -f "$STAGING_PREFIX/bin/$binary" ]; then
        pass "Binary exists: bin/$binary"
    else
        echo -e "  ${YELLOW}⊘ SKIP${NC}: bin/$binary (not built)"
    fi
done

for lib_pattern in libkeystone_core libkeystone_concurrency libkeystone_agents; do
    found=$(find "$STAGING_PREFIX/lib" -name "${lib_pattern}*" 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        pass "Library exists: $(basename "$found")"
    else
        echo -e "  ${YELLOW}⊘ SKIP${NC}: $lib_pattern (not built)"
    fi
done

if [ -d "$STAGING_PREFIX/include/keystone" ]; then
    header_count=$(find "$STAGING_PREFIX/include/keystone" -name '*.hpp' | wc -l)
    pass "Keystone headers installed: $header_count .hpp files"
fi

echo ""
echo -e "${GREEN}Conan install validation complete.${NC}"
echo ""
