datacenter = "hermes"
data_dir   = "/var/lib/nomad"

client {
  enabled = true

  # Nomad server addresses — Tailscale IP of the primary Nomad server
  # Set NOMAD_SERVER_IP environment variable to override the hardcoded IP below.
  # To find your Nomad server's Tailscale IP, run on that host: tailscale ip -4
  # Default below is epimetheus (100.92.173.32) — update for your network.
  servers = ["100.92.173.32:4647"]
}

# ACL enforcement on the client HTTP API (issue #196). Required so the client
# API is not an unauthenticated bypass of the server ACL. The agent needs a
# NOMAD_TOKEN (from `nomad acl bootstrap` on the server, or a node policy
# token) to register — see docs/runbooks/add-new-host.md step 6.
acl {
  enabled = true
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
