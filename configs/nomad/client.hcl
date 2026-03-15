datacenter = "hermes"
data_dir   = "/var/lib/nomad"

client {
  enabled = true

  # Nomad server addresses — update with your Nomad server's Tailscale IP
  servers = ["172.20.0.1:4647"]
}

plugin "docker" {
  config {
    allow_privileged = false
  }
}
