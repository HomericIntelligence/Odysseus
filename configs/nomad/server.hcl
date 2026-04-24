# Nomad server configuration for single-node bootstrap in Tailscale mesh
datacenter = "hermes"
data_dir   = "/var/lib/nomad"

# Listen on all interfaces (0.0.0.0), including Tailscale VPN interface.
# Tailscale will provide the actual routing and encryption.
bind_addr = "0.0.0.0"

# Advertise the Tailscale IP address so clients and peers discover this server
# via the Tailscale mesh. Set NOMAD_ADVERTISE_ADDR before starting Nomad:
#   export NOMAD_ADVERTISE_ADDR=$(tailscale ip -4)
advertise {
  http = "${NOMAD_ADVERTISE_ADDR}"
  rpc  = "${NOMAD_ADVERTISE_ADDR}"
  serf = "${NOMAD_ADVERTISE_ADDR}:4648"
}

# Bootstrap mode: single Nomad server that self-elects as leader.
# For multi-node clusters, increase bootstrap_expect and remove this comment.
server {
  enabled          = true
  bootstrap_expect = 1
}
