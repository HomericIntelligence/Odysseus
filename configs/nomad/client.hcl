datacenter = "hermes"
data_dir   = "/var/lib/nomad"

client {
  enabled = true

  # Nomad server addresses — update with your Nomad server's Tailscale IP
  servers = ["172.20.0.1:4647"]
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
