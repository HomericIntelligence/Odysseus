datacenter = "hermes"
data_dir   = "/var/lib/nomad"

client {
  enabled = true

  # Nomad server addresses — set to your Nomad server's Tailscale IP
  # Example: epimetheus = 100.92.173.32
  servers = ["100.92.173.32:4647"]
}

# Nomad uses the Docker driver with the podman-docker shim (per ADR-001).
# The podman-docker shim exposes a Docker-compatible socket at
# /run/user/<UID>/podman/podman.sock or /run/podman/podman.sock.
# Nomad communicates with Podman exclusively through this shim;
# no Docker daemon is installed or required.
plugin "docker" {
  config {
    allow_privileged = false
  }
}
