# ===========================================================================
# Variables
# ===========================================================================

# DEPRECATED: Will be replaced by AGAMEMNON_URL per ADR-006 migration
MAESTRO_URL := env_var_or_default("MAESTRO_URL", "http://172.20.0.1:23000")

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
# Provisioning
# ===========================================================================

# Apply Myrmidons declarative YAML state to ai-maestro
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
# Research
# ===========================================================================

# Run ProjectScylla tests
scylla-test:
    cd research/ProjectScylla && just test
