# Nomad server configuration for single-node bootstrap in Tailscale mesh
datacenter = "hermes"
data_dir   = "/var/lib/nomad"

# Listen on all interfaces (0.0.0.0), including Tailscale VPN interface.
# Tailscale provides network-layer routing/encryption only; the acl stanza
# below adds workload-layer least privilege (issue #196). Both are required.
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

# ACL system (issue #196): API/RPC access now requires a token so individual
# jobs/namespaces get least-privilege policies instead of open access.
#
# REQUIRED one-time step after first server start — without it, all token-
# authenticated calls (including `nomad node status` and client registration)
# will fail with "ACL token not found":
#   nomad acl bootstrap            # prints the Secret ID — store it securely
#   export NOMAD_TOKEN=<secret-id> # then distribute scoped tokens to clients
#
# The management token is NEVER stored in this file — no `sensitive` attribute
# exists in Nomad HCL; secrets are provisioned at runtime via
# `nomad acl bootstrap` / `nomad acl token create`.
acl {
  enabled = true
}
