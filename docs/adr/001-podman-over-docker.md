# ADR 001: Use Podman as Primary Container Runtime

**Status:** Accepted

---

## Context

The HomericIntelligence ecosystem runs on WSL2 hosts and needs a container
runtime for building and running agent container images. The two primary
candidates are Docker (via Docker Desktop or the Docker daemon) and Podman.

Docker on WSL2 requires either Docker Desktop (licensed for commercial use,
adds overhead) or running the Docker daemon (`dockerd`) inside WSL2. The daemon
approach introduces a persistent background process, requires root privileges
for the daemon, and has historically had reliability issues with WSL2 (daemon
crashes on WSL2 restart, socket permission problems, slow startup).

ai-maestro exposes a `/docker/create` endpoint that speaks the Docker API via a
mounted socket. This socket must be provided by some container runtime on the
host.

## Decision

We choose **Podman** as the primary container runtime across all
HomericIntelligence hosts.

Key points of the decision:

- **Daemonless:** Podman spawns containers as child processes. There is no
  background daemon to crash, hang, or require root.
- **Rootless by default:** Podman can run fully unprivileged. This is the
  preferred mode on WSL2 and aligns with the principle of least privilege.
- **OCI-compatible:** All container images built with Podman are standard OCI
  images. AchaeanFleet images built with Podman run anywhere.
- **Docker CLI compatibility via `podman-docker`:** Installing the
  `podman-docker` package provides a `docker` binary that is a thin shim to
  `podman`. ai-maestro sees a Docker-compatible socket and API without
  modification.
- **Avoids WSL2 Docker daemon issues:** No daemon means no daemon-specific
  WSL2 instability. Podman containers survive WSL2 restarts cleanly.
- **Compatible with ai-maestro's `/docker/create` endpoint:** The Podman socket
  (via `podman.socket` systemd unit or `podman system service`) exposes a
  Docker-compatible REST API. ai-maestro is pointed at this socket.

## Consequences

**Positive:**
- Simpler host setup: install `podman` and `podman-docker`, enable
  `podman.socket`, done.
- No licensing concerns.
- Rootless operation reduces attack surface.
- WSL2 stability is significantly improved.

**Negative:**
- Some Docker Compose features require `podman-compose` or Podman's native
  compose support, which has minor compatibility gaps. Mitigation:
  HomericIntelligence uses Nomad for multi-container scheduling, not Compose,
  so this is a non-issue for production workloads.
- Team members already familiar with Docker need to learn minor Podman
  differences (e.g., `podman pod` commands). Mitigation: the `docker` shim
  means day-to-day commands are identical.

**Neutral:**
- ai-maestro's `/docker/create` endpoint continues to work unchanged. It calls
  the socket; the socket is served by Podman instead of Docker. No ai-maestro
  modification required.
