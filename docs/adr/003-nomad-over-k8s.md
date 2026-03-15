# ADR 003: Use Nomad for Multi-Host Container Scheduling Instead of Kubernetes

**Status:** Accepted

---

## Context

The HomericIntelligence ecosystem needs to schedule container workloads (agent containers, supporting services) across multiple WSL2 hosts connected via Tailscale. ai-maestro handles agent discovery and peer registration via its `/host-sync` endpoint, but it does not schedule containers across hosts — it only knows which hosts exist.

The two primary candidates for multi-host container scheduling are Kubernetes (K8s) and HashiCorp Nomad.

Kubernetes is the industry-standard choice for large-scale container orchestration. However, for this use case it introduces significant complexity:
- Requires a multi-component control plane (kube-apiserver, etcd, controller-manager, scheduler, kubelet, kube-proxy).
- Needs either kubeadm, k3s, or a managed service — all of which add setup and maintenance burden.
- Resource overhead on WSL2 hosts is substantial (etcd alone is memory-hungry).
- CNI networking on WSL2 with Tailscale requires careful configuration to avoid conflicts.
- The learning curve and operational surface area are disproportionate to the scale of this mesh (tens of agents across a handful of hosts).

## Decision

We choose **Nomad** as the container scheduler for HomericIntelligence.

Key points:

- **Single binary:** Both the Nomad server and client are a single statically-linked binary. No control plane sprawl. Install one binary, start one process.
- **Right-sized for this scale:** Nomad handles thousands of jobs with a fraction of the resource overhead of Kubernetes. For a mesh of tens of agents across a handful of hosts, Nomad is far more appropriate.
- **Docker/Podman driver:** Nomad's Docker task driver works with Podman via the Docker socket shim (ADR 001). Agent containers defined in Nomad job specs use the same image names as AchaeanFleet.
- **ai-maestro integration:** ai-maestro handles host discovery via `/host-sync` and Tailscale for peer networking. Nomad schedules workloads onto those hosts. The two concerns are cleanly separated.
- **Simpler networking:** Nomad's network model on Tailscale is straightforward. No CNI plugins, no overlay networks — Tailscale provides the mesh network, Nomad uses it.
- **HCL job specs:** Nomad job specs are readable HCL, familiar to anyone who has used Terraform or the configs in this repo.

## Consequences

**Positive:**
- Dramatically simpler setup: one binary, one config file per host (`configs/nomad/client.hcl` or `server.hcl`).
- Low resource overhead on WSL2 hosts.
- Nomad server bootstraps with `bootstrap_expect=1` for single-server setups; scales out trivially.
- Myrmidons can submit Nomad jobs as part of its apply workflow.
- ai-maestro host-sync + Tailscale continues to handle peer discovery; Nomad uses the same host list.

**Negative:**
- Nomad is less widely known than Kubernetes. New team members may be less familiar with it.
- Nomad's service mesh (Consul Connect) is not used here; if service mesh features become necessary, this decision may be revisited.
- Nomad does not provide the rich ecosystem of K8s operators and Helm charts. Any Kubernetes-specific tooling must be adapted.

**Neutral:**
- ai-maestro is unaffected. It does not know or care about Nomad. Nomad schedules containers; ai-maestro manages agent state. They share the Tailscale network but operate independently.
- Nomad configs are canonical in `configs/nomad/` in this repo.
