# ADR 025: Migrate Legacy Harness Credentials to an Exact Pod-Namespace Host Broker

**Status:** Proposed

> **Proposal status:** Merging this ADR neither accepts nor activates the
> design. Formal human acceptance would authorize a separate implementation
> change; it would not authorize protected-workflow edits, deployment, or live
> host mutation. Current provider, model, lane, role, and harness defaults stay
> unchanged.

**Related:** Proposed [ADR 020](020-mesh-distributed-hephaestus-loop.md) and
Proposed [ADR 022](022-layered-provider-neutral-agent-instructions.md)

---

## Context

Current `main` has no host-side provider broker. The single-repository legacy
harness bind-mounts the invoking user's `~/.claude/`, optional
`~/.claude.json`, and read-only `~/.config/gh/` into a `--userns=keep-id`
container on the shared mesh network. It also makes files beneath the Claude
configuration world-readable when necessary and bind-mounts a host-selected
standalone Claude executable from `~/.local/share/claude/versions/*` at
`/usr/local/bin/claude-host:ro`; its fallback selects the mutable latest local
version. The multi-repository harness mounts the same Claude and GitHub configuration, injects the host
`ANTHROPIC_API_KEY` environment value by name, uses `--userns=keep-id`, and
joins the shared mesh network. Both ask an in-container agent to perform Git
and GitHub remote effects. Those facts are current compatibility behavior, not
the containment design selected by this proposal.

If accepted and separately implemented, this ADR creates a host-only provider
broker and removes provider and forge credentials from the candidate container.
The broker opens the provider credential only on the host and exposes one
listener belonging to the candidate pod's otherwise disconnected network
namespace. Linux keeps a socket associated with the network namespace in which
it was created after its descriptor moves to a process in another namespace.
The host can therefore service provider requests while only processes in the
exact pod network namespace can reach the loopback listener. No reusable
bearer token is added to replace the removed provider credential; the exact
pod/session binding and the broker's bounded protocol are the authorization
boundary.

This boundary has sharp lifecycle requirements:

- a multithreaded host process must not call `setns(2)` and temporarily change
  its own namespace;
- a `--network none` pod starts without a usable loopback interface;
- `/proc/<pid>/ns/net` is a magic link, so an `O_PATH | O_NOFOLLOW` handle to
  the link itself is not a namespace handle suitable for `setns(2)`;
- rootless Podman UID and GID mappings cannot be inferred from equality with
  the host identity;
- a Podman service process may restart while the authoritative storage roots
  remain the same; and
- a crash between an external effect and its durable receipt must not leave an
  unowned listener, container, pod, credential path, or remote forge effect.

`--network none` also removes the candidate's current dependency-download,
Git, GitHub, NATS, and other egress paths. The migration must replace necessary
effects with manifest-bound host stages; it cannot silently restore bridge or
host networking to preserve compatibility.

The harnesses cannot be retired until the separate ADR-020 proof and real M4
mesh-only dogfood requirement pass. This proposal defines containment while
they remain live; it neither implements that containment nor weakens the
retirement gate.

## Decision

If this ADR is formally accepted, the legacy credential broker will use the
following exact design.

### 1. Support one fail-closed platform path

The isolated broker path is supported only on Linux with rootless Podman,
Linux network and user namespaces, PID file descriptors, Unix-domain
`SOCK_SEQPACKET`, and `SCM_RIGHTS` descriptor passing. The Podman API endpoint
must be an independently validated local Unix socket. A remote SSH or TCP
endpoint is not local merely because the client labels it remote.

If any required primitive, identity readback, namespace proof, UID/GID mapping,
or cleanup capability is unavailable, the harness fails closed before an agent
starts. There is no Docker fallback, remote-Podman fallback, bridge network,
published port, host network, host-gateway route, `0.0.0.0` listener, or
controller-, broker-, or multithreaded-process `setns(2)` and no fallback
namespace path. The sole namespace transition is the bound single-threaded
launcher described in section 3 using prevalidated namespace descriptors.
Unsupported platforms may run portable tests, but they cannot report the
isolation boundary as proven.

This proposal deliberately moves provider and forge credential authority from
the candidate container to bounded host processes. It does not change the
selected provider or model, task wire shape, role assignment, lane, retry
policy, resource bound, or default harness before a separately approved atomic
implementation cutover.

#### Migrate each harness atomically; never mix authority paths

ADR merge or formal acceptance does not migrate a credential or change a live
default. A later implementation must first prove an opt-in `isolated-broker`
path. A separate human-approved cutover drains every `legacy-direct` session,
proves no old container remains, and switches each harness version atomically.
One invocation is either `legacy-direct` or `isolated-broker`; no OCI spec,
process, mount, environment, generated file, or inherited descriptor may carry
both authorities.

Before enabling the isolated path, the operator binds the exact controller,
broker, launcher, gate, Podman/runtime, image, provider CLI, resolver, and forge
adapter digests and exercises the complete prefetch-to-delivery path. The
cutover then removes all Claude/provider and GitHub credential/config mounts,
API-key injection, credential-helper and SSH-agent sockets, inherited secret
descriptors, the host standalone-executable mount and mutable fallback,
world-readable permission mutation, bridge networking, and candidate-side
remote-effect prompts as one reviewed version change. The candidate/agent
executable must come from the digest-bound read-only image and match the
manifest/inspect/process readbacks; no host code path is overmounted into it.
Inspect and live `/proc` mount, environment, executable, FD, route, and process
readbacks must pass before the gate can release any candidate.

Any isolated-path failure is terminal for that invocation. It enters cleanup;
it never remounts credentials, injects a key, reopens mesh/bridge/host egress,
or delegates a remote effect to the candidate. A retained operator rollback is
whole-version only, after proving that no isolated invocation or effect remains,
and requires a separate recorded approval. It never inserts a credential into
a running candidate or reuses an interrupted workspace/session as new work.

### 2. Bind stable store authority and replaceable endpoint proof

Before creating an external effect, the invocation binds the stable rootless
Podman store authority as one indivisible tuple:

- the canonical `graphRoot`, opened component by component without following a
  caller-controlled symlink, plus its device and inode identity;
- the graph driver, `rootless=true`, complete UID/GID mappings, and
  `transientStore=false`; and
- the operation ID and collision-resistant labels used to find only effects
  from this invocation after a crash.

The local Podman API endpoint is separate, replaceable session evidence. The
session proof includes the canonical local Unix socket and opened device/inode,
kernel peer identity, `runRoot`, service host boot ID, service PID and process
start time, executable identity, and API identity. The harness revalidates the
endpoint session and the entire stable store tuple immediately before and after
every Podman read or mutation. Socket activation or service restart may replace
the endpoint session only while the stable tuple remains identical. Endpoint
rotation alone is not new store authority; any stable-tuple change, nonlocal
endpoint, peer mismatch, or before/after drift fails closed.

Every durable process identity is the host boot ID, numeric PID,
`/proc/<pid>/stat` start time, executable identity and digest, namespace
type/device/inode metadata, and namespace-owner relation. A pidfd, user- or
network-namespace descriptor, listener descriptor, accepted descriptor, or
control descriptor is a live-session capability only. No receipt serializes a
descriptor number or treats one of those handles as durable authority.

The harness creates one rootless Podman pod with an infra container,
`--network none`, and the one supported user-namespace mode
`--userns=auto:size=65536`. It publishes no port. Before pod creation, the
harness binds the exact Podman release and the complete subordinate UID/GID
ranges from which that fixed-size allocation may be drawn. Preflight requires
capacity for two disjoint 65,536-ID allocations so the same-token negative
oracle cannot share either user namespace or host-side IDs with the candidate.
Unset or ambient selection, `keep-id`, `host`, `auto` without the fixed size,
`nomap`, `container:`, `ns:`, and explicit/custom-map alternatives fail
preflight.
Podman's `host` mode means the caller's current user namespace; it is not a
claim about the kernel initial host user namespace. The implementation proves
the actual namespaces by opened NSFS identity and ancestry and also proves that
the selected pod user namespace is not the initial host user namespace.

Before a launcher or agent starts, the receipt records the exact pod and infra
container IDs, immutable image digests, store identity, durable infra-process
identity, selected subordinate ranges, complete allocated and observed UID/GID
maps, and resolved user- and network-namespace type/device/inode identities.
The allocated maps must be exactly 65,536 IDs, remain inside the bound
subordinate ranges, and contain neither the service host UID nor its GID in any
host-side extent. Every namespace descriptor is opened on the actual namespace
with `O_CLOEXEC`, then checked with NSFS. For
each target network namespace, `NS_GET_USERNS` must return an owner-userns
descriptor whose `fstat(2)` identity equals the selected bound pod user
namespace. The implementation binds that owner relation and repeats it before
and after listener creation and immediately before gate release. The
magic-link inode itself and a mode string are never namespace identity.

The new provider broker is a fixed host binary whose digest, operation ID,
provider endpoint, provider/model selection, versioned request and response
schemas, request/response limits, and credential-source identity are bound
before it opens a listener. It is not a raw HTTP, forwarding, or `CONNECT`
proxy. For each supported provider adapter, the manifest selects one closed
operation schema and one exact remote operation. The broker constructs
the fixed scheme, origin, port, HTTP method, path, query, API-version and
authentication headers; it never follows a redirect. It overwrites and then
verifies the exact manifest-bound provider and model. Candidate input can carry
only the bounded prompt/message content, approved client-tool definitions and
results, and fixed metadata fields required by that bound CLI operation.
Unknown fields; caller-selected URLs, paths, queries, headers, provider, or
model; credential-bearing fields; and unapproved provider-hosted or built-in
tools are rejected before any outbound connection. File, batch, fine-tune,
administration, model-discovery, and every adjacent provider operation are
outside the schema. The response is likewise decoded against a closed schema,
and request identity, bounded token usage, quota, and cost attribution are
recorded without request or response content.

The worker starts with a sealed environment and a digest-bound HTTPS client,
resolver configuration, CA trust store, TLS policy, SNI, and hostname-verification
policy for the one fixed origin. Ambient `HTTP_PROXY`, `HTTPS_PROXY`,
`ALL_PROXY`, `NO_PROXY`, netrc, provider-SDK base-URL/endpoint, custom-CA,
certificate, transport, and debug/logging overrides are absent and rejected if
introduced. Authentication is attached only after DNS and TLS identity checks
for the bound origin; redirects and proxy tunnels remain disabled. Transport
and provider errors map to fixed redacted enums so credentials, rejected/raw
request or error bodies, resolved secrets, and upstream headers never enter
logs or a candidate response. A successful response reaches the candidate only
as closed-schema validated, size-bounded content and events selected by the
bound operation; raw upstream bytes never cross that decoder.

The isolated cutover runs one exact digest-bound, image-baked Claude CLI. For
the single harness this deliberately replaces the current host-selected
`claude-host` bind mount and mutable fallback; for the multi harness it binds
the current image-provided `claude` behavior. Compatibility is demonstrated per
harness rather than assuming those two current executable paths are identical.
The immutable gate exposes a second, gate-owned loopback
HTTP endpoint with the exact provider-compatible request, server-sent-event,
tool-use/tool-result, usage, error, cancellation, and backpressure grammar that
this one CLI build requires. A sealed candidate environment fixes the CLI base
URL to that endpoint, disables telemetry and update/model discovery, and uses a
public constant local-auth placeholder that is neither secret nor accepted by
the host broker or provider. The gate consumes that placeholder; it never
forwards it. Only `POST /v1/messages` can cause the closed broker operation. If
the bound CLI requires token counting, the gate implements the exact
`POST /v1/messages/count_tokens` grammar locally with the digest-bound tokenizer
and no provider connection. Health is a fixed local gate operation. Every other
method, path, redirect, websocket, telemetry, update, discovery, file, batch,
or provider feature fails locally before broker contact.

Pre-cutover compatibility evidence binds the CLI binary/version and its complete
offline HTTP trace for new and resumed turns, then runs a real bounded canary
through the gate and closed host operation. The trace must contain only the two
named message/token-count paths and the fixed health operation; a new path,
header, streaming event, tool frame, or environment requirement blocks cutover
and requires a reviewed adapter revision. The gate converts a validated message
request into the fixed internal broker frame below, attaches the broker token
itself, validates every streamed response frame before translating it back, and
never exposes the broker listener or protocol to the CLI.

The broker opens only an allowlisted provider credential path component by
component with `O_NOFOLLOW | O_CLOEXEC`, verifies expected owner and owner-only
mode, and records only nonsecret identity metadata. Credential bytes, reusable
provider tokens, and provider-credential-derived hashes never enter a receipt,
environment, command line, container mount, workspace, log, or broker response.

The implementation deletes both harnesses' `~/.claude`, `~/.claude.json`, and
`~/.config/gh` mounts, the multi-harness `ANTHROPIC_API_KEY` injection, and the
single-harness world-readable permission mutation. Before cutover, a fixed
host helper walks every path and object in the complete historical mutation
surface (`~/.claude/**` plus `~/.claude.json`) component by component without
following links. It binds owner, type, mode, device/inode, and the exact set of
objects that the legacy `stat`/`chmod` loop could have widened. Every sensitive
regular file or directory in that set, including config, session, log, cache,
and non-credential state, receives its reviewed owner-only policy and a
before/after receipt. A symlink or previously followed target, unexpected
owner/type/mode, changing path, or object whose historical reachability cannot
be proved stops for an operator-reviewed disposition; migration never follows
the link or guesses a target. Cutover requires a second no-follow inventory
proving no classified sensitive object in the complete surface retains
group/other exposure. The candidate receives only generated, nonsecret
loopback endpoint and invocation metadata. Because a mode repair cannot revoke
bytes already exposed to a legacy container, the atomic cutover first drains
and proves absent every legacy session, then revokes or rotates every provider
and forge/GitHub credential, token, and session that was mounted, injected, or
reachable through that mutation surface. An unenumerable historical
symlink-follow target expands the presumed-exposed class and requires rotation;
it never permits a claim that chmod repaired disclosure. Independent negative
readback proves each old identity unusable before the broker or forge adapter
binds fresh credential identities that were never mounted, injected, or made
group/other accessible. A crash between revocation and fresh-identity arming
leaves isolated admission closed, and rollback never restores an exposed
identity. Container inspect and `/proc`
environment/mount readbacks must prove that no provider/GitHub credential,
config directory, reusable token, or host service socket is present.

The allocator is a separately installed, root-owned, non-networked service
manager with one fixed binary and a closed operation enum:
`PREPARE_LEASE`, `ACTIVATE_LEASE`, `START_ACTOR`, `STOP_ACTOR`, `POD_OP`, and
`RECONCILE_RELEASE`. Its
reviewed configuration preprovisions the finite UID/GID and subordinate-ID
ranges, LSM labels, cgroup, home, `runRoot`, and graph-root parents; it never
edits account databases or chooses an ID dynamically. The unprivileged
controller submits a fixed-size request over an owner-only
`SOCK_SEQPACKET` endpoint. The manager authenticates kernel peer credentials
plus the receipt-bound controller boot ID, PID/start, executable digest, cgroup,
and LSM identity at every request, then verifies the operation, controller and
allocator generations, commit ID, and full-binding digest. UID alone never
authorizes the socket. It accepts no command, executable, path,
environment, image, UID, policy, or free-form operation supplied by the caller.
`START_ACTOR` accepts only a fixed actor enum and a schema-fixed set of already
authenticated control/lifeline descriptors; the installed configuration maps
that enum to an exact UID/GID, executable digest, LSM/seccomp policy, sealed
environment, cgroup, and descriptor slots. It starts the pod-owner monitor,
broker worker, source prefetcher, dependency resolver, session-state service,
forge adapter, signer, and reconciler as distinct fixed actors.
The controller and session supervisor may share the unprivileged orchestrator
UID, but no credential-bearing actor shares it. There is no caller-selected
`setuid`, executable, argv, environment, unit name, path, or service primitive.
`STOP_ACTOR` requires a precommitted stop phase and exact lease, generation,
actor enum, manager-held process identity, and full-binding digest. It first
closes the actor's fixed authority, then permits only the installed graceful
stop and deadline-expired `SIGKILL` sequence; it accepts no caller PID, signal,
timeout, or cgroup. A pidfd held by an unprivileged different-UID caller is
observation evidence, never assumed signal authority.

Because the root manager is the actor's actual parent, installed policy treats
that relationship as privileged TCB rather than pretending UID separation is
sufficient. Before an actor can open a credential, the manager drops
`CAP_SYS_PTRACE` and every capability not required for fixed identity setup and
`STOP_ACTOR`, sets nondumpable/no-core state, and installs a read-back mandatory
LSM/seccomp boundary denying `ptrace`, `process_vm_*`, proc-mem/proc-FD opens,
`pidfd_getfd`, and arbitrary signal/process operations against every child.
Only the fixed manager-held actor pidfd plus precommitted `STOP_ACTOR` path may
send the installed graceful signal and deadline `SIGKILL`; the policy permits
that signal operation without permitting memory or FD inspection. An
installed filesystem allowlist permits only the immutable manager/policy/runtime
binaries, its allocation journal, fixed pool/cgroup roots, and the exact leased
Podman store objects required by a closed operation. It denies the primary
receipt, provider/forge/signing credentials, CLI session store, task/prompt
stores, user homes, and every unrelated path; archive bytes arrive only on the
operation's validated descriptor. The manager has no network namespace route or
network syscall. An unavailable policy, same-UID impostor, wrong
actor/generation, caller PID/signal, or attempted manager read of sentinel
worker memory/FDs or credential/session/signing paths fails before any actor can
arm.

The source prefetcher, dependency resolver, and session-state service are
one-operation, non-daemonizing actors under that same manager contract, not
ambient controller helpers. Each has a distinct non-login UID/GID, executable
digest, LSM/seccomp/network/filesystem policy, cgroup, controller and manager
lifelines, fixed ledger-control descriptor, and sealed operation manifest. The
prefetcher can open only the bound source origin and its fresh raw-object store;
the resolver can open only manifest-selected dependency origins and its fresh
resolver store; the session-state actor has no network and can open only the
bound encrypted session generation and operation-scoped key descriptor. Their
credentials or keys open only after their operation intent is durable, remain
locked and nondumpable, and close and zero before the result commit. Lifeline
loss, crash, ambiguous remote response, restart, replay, or store/key mismatch
enters the same request-identity reconciliation and `STOP_ACTOR`/cleanup path;
it never adopts another generation, retries an uncertain effect, or leaves a
credential or key usable by the controller.

`POD_OP` is an authenticated `SOCK_SEQPACKET` protocol whose entire enum is
`IMPORT_IMAGE`, `CREATE_POD`, `RUN_GATE`, `INSPECT`, `COPY_IN`, `COPY_OUT`, and
`STOP_REMOVE`. It accepts an operation/lease/generation/full-binding digest,
fixed object identifiers, and only the exact pre-opened regular-file descriptors
required by that operation; `RUN_GATE` additionally accepts exactly one
authenticated gate-control socket in its fixed descriptor slot. It rejects
every other descriptor plus caller paths, argv, environment, labels,
mounts, image names, and arbitrary Podman flags. The manager constructs one
fixed Podman/crun specification from installed policy and receipt-bound fields,
launches the one-operation helper as the leased pod owner, and returns only the
closed-schema result and canonical readbacks. The controller never receives a
Podman socket and cannot access the owner-only home, `runRoot`, graph root, or
container store. Before `CREATE_POD`, `IMPORT_IMAGE` streams a canonical,
digest-bound OCI archive through its pre-opened descriptor into the fresh store,
verifies the manifest, config, layer, image digest, ownership, store identity,
and zero unexpected images, and commits the imported-image identity. Every
later start uses that exact local digest with `--pull=never`; a fresh store is
never assumed to contain the image.

The primary receipt ledger is authoritative for lease intent and lifecycle; the
manager's durable ledger is only a fenced resource-allocation journal and never
independently authorizes an invocation. The controller first commits
`lease_prepared`, containing the operation, immutable pre-manifest, requested
fixed pool class, allocator generation, and no allocated identity. It then calls
`PREPARE_LEASE`; the manager compare-and-swap reserves one free entry and returns
a signed fixed lease tuple without creating a directory, process, cgroup, store,
or other pod effect. The controller commits `lease_bound` with that tuple, then
calls `ACTIVATE_LEASE` with the exact commit ID. Only activation may create the
fixed no-follow home/`runRoot`/graph-root descendants, labels, limits, and
cgroup. The controller records the activation readback before `armed` and before
any pod operation. On restart, a prepared reservation lacking `lease_bound` is
releasable only after zero-effect proof; an activated manager entry lacking the
matching primary commit is quarantined for operator review. Cleanup commits
`lease_release_armed`, obtains complete absence/store-erasure readback from
`RECONCILE_RELEASE`, commits `lease_released`, and only then may the manager
tombstone and reuse the pool entry. The operation ID, generations, commit IDs,
and both-ledger hashes make every retry idempotent; no heuristic cross-ledger
adoption is allowed.

Recovery proves every process, cgroup, Podman object, descriptor, image/store
object, and fixed actor for the exact lease absent or reconciles it under those
receipts before release. The manager never receives a provider, forge
credential, Git credential, task, prompt, or candidate-output byte and exposes
no shell, arbitrary file, signal, mount, namespace, process, or container
primitive. Hostile requests for another UID/path/binary/policy, replay,
concurrent lease, stale generation, manager restart, or partial cleanup fail
closed. The manager, installed policy, allocation journal, and operation helpers
are explicit privileged TCB, not authority inferred from candidate text.

Before any pod or authoritative descriptor exists, that fixed local allocator
leases one non-login pod-owner UID/GID from the reviewed pool, with a fresh
owner-only home, `runRoot`, and graph root. Only the exact digest-bound
pod-owner monitor, start helper, Podman, conmon, crun, and launcher may run under
that identity, and only in the bound service/cgroup. The controller,
session supervisor, broker worker, candidate, forge adapter, and unrelated
service processes use distinct identities. Before launch and at every
pre-secret topology checkpoint, the monitor proves that no unknown process,
session, executable, cgroup member, or open login exists for the pod-owner
identity. Reuse, overlap, or an unclassified same-EUID process fails closed.
The child user namespace is owned by this dedicated identity, never by the
general agent or broker-worker account.

The pod-owner processes have parent-namespace authority over the child user
namespace and are therefore explicit trusted-computing-base members; dumpability
alone is not claimed to isolate the gate from them. A mandatory, digest-bound
LSM profile plus syscall policy denies conmon, Podman after setup, crun after
handoff, and the launcher any `ptrace`, `process_vm_*`, `pidfd_getfd`, proc-mem,
or proc-FD reopening of the gate/candidate. The monitor may read only the
declared pre-secret process/namespace/FD metadata, never memory or descriptor
targets, and exits before FD3 `ARM`. The policy and exact peer labels are read
back from the kernel; an unavailable or permissive LSM path makes this design
unsupported rather than falling back to shared-EUID trust.

Every authority-bearing process sets `PR_SET_DUMPABLE=0`, sets and verifies
`RLIMIT_CORE=0`, and excludes itself from host crash collectors before it
receives a namespace, control, listener, accepted, credential, or secret
descriptor. The gate does the same at its first instruction, before FD3 is
validated; any credential transition or exec that can reset dumpability must
reapply and read it back first. Secret buffers are size-bounded dedicated
anonymous mappings, locked, marked `MADV_DONTDUMP`, and explicitly zeroed on
every success and failure path. A process that may later fork, especially the
gate, also applies and reads back `MADV_DONTFORK` before the first secret byte
enters the mapping. Its fixed parser reads secret fields directly into those
mappings and forbids copies in general heap, library-owned buffers, exceptions,
or long-lived stack objects; temporary register/stack slots are overwritten
before fork. The post-fork child verifies those mapping ranges are absent before
any allocation, credential transition, or error reporting. If a
required hardening, identity isolation, LSM policy, or readback is unavailable,
the process opens no authority or credential and the invocation fails closed.
Journal, crash-handler, core-pattern, and filesystem scans after injected
parser/client crashes must prove sentinel credentials, tokens, and signing
bytes absent.

The one per-invocation operation authorization value is a fresh non-provider
broker token bound to the operation, listener receipt, full-binding digest, and
deadline; it is never candidate-readable. Only after `listener_bound`, the
session supervisor obtains 256 random
bits from the kernel, sends the bytes once to the already authenticated broker
worker over its control socket in a fixed `BROKER_ARM` frame, and requires a
binding-digest `BROKER_ARMED` acknowledgment while admission remains disabled.
The same bytes then travel once inside the secret field of the authenticated
FD3 `ARM` frame below. The trusted gate creates one new no-follow gate-owned
`0600` file in container-private `/run/homeric`, writes exactly those bytes,
binds its inode/owner/mode/size and digest in `READY`, and never accepts token
material from an archive, argv, environment, path, or candidate output. The
candidate UID/GID cannot read, link, rename, or traverse to the file. Instead,
the gate serves the fixed CLI-facing loopback endpoint above, validates and
bounds each candidate request, connects to the transferred broker listener,
adds the token inside the internal frame, and strips authorization material
from the response. A direct candidate connection to the broker listener has no
token and is denied. Only the supervisor, exact broker worker, and gate can
observe the bytes; the supervisor zeroes its copy after both arms and the gate
retains a locked copy only until the final request or cleanup, then zeroes and
unlinks it. Only the digest is durable. The worker enables provider admission
only after durable `gate_bound` and a final `BROKER_ENABLE`/`BROKER_ENABLED`
exchange immediately before `RELEASE`. It rejects the token on another
listener, operation, binding, or deadline and invalidates it when this listener
closes. It is not a provider or forge credential and is not reusable by a later
invocation.

#### Couple the broker worker directly to controller and supervisor lifetime

The fixed broker worker is a single-threaded, non-daemonizing `START_ACTOR`
process whose actual parent is the root-owned service manager. It cannot fork,
clone, exec, or create descendants. Before asking the manager to start it, the
controller and session supervisor each create a separate
`SOCK_SEQPACKET | SOCK_CLOEXEC` death-lifeline/control pair and retain their sole
ends. The manager accepts only those two authenticated endpoint types in their
installed descriptor slots, gives the other ends to the worker, and closes its
transient copies after the worker's fixed startup acknowledgment. The worker
also receives one manager-lifetime endpoint. No caller can substitute a file,
listening socket, dual-ended pair, or endpoint with the wrong peer, operation,
generation, or LSM identity. After validating the launcher's transferred listener, the supervisor
sends one fixed `BROKER_LISTENER` frame with exactly that descriptor over this
authenticated pair using `SCM_RIGHTS`. The worker receives with
`MSG_CMSG_CLOEXEC` into fixed data/control buffers, rejects truncation, extra or
unknown ancillary data and every identity or binding mismatch, independently
validates the listener address, namespace cookie, operation, and full-binding
digest, and replies `BROKER_LISTENER_BOUND`. Only then does the supervisor close
its copy and read back `EBADF` for its descriptor number. It sends authenticated
`LISTENER_ACCEPTED` to the
launcher, which closes its original, completes the post-drop proof below, and
exits after an authenticated close/self-attestation. Only after that exit and
the worker's fresh authenticated listener-identity self-attestation does the
supervisor request the durable `listener_bound` commit. Sole ownership derives
from the one-transfer protocol, mandatory pre-authority nondumpability,
distinct identities/LSM policy, sender closure readbacks, and launcher exit—not
from a racy same-UID `/proc` snapshot. Failure at any step stops/kills the
worker, closes every installed copy, and leaves admission disabled. The worker
accepts directly from that listener; an accepted socket is never handed across
another process boundary.

The worker polls all three lifelines on every nonblocking provider-I/O iteration and
handles an observed EOF/POLLHUP before beginning another provider-I/O operation.
Controller-end EOF/POLLHUP therefore reaches the worker directly;
supervisor-end or manager-end EOF/POLLHUP does the same. Detection is bounded, not
instantaneous: death can occur after a poll and before or during a provider write. Once
observed, the event immediately stops admission and closes every accepted, provider, and
credential descriptor. Any request that might have crossed the provider boundary in that
race remains durably `provider_effect_uncertain`; the design does not claim that a userspace
lifeline can revoke an in-flight kernel or library operation synchronously.

At startup the worker sets `PR_SET_PDEATHSIG` to `SIGKILL`, re-reads and
validates its actual service-manager parent PID/start identity to close the
parent-death race, and installs a syscall policy that denies changing the death
signal, daemonizing, or signaling another process. Manager death therefore
causes kernel termination; controller or supervisor death is the direct
lifeline event above. For controlled cancellation, the supervisor sends one
authenticated, operation-bound `BROKER_STOP`; the worker first stops admission,
closes every accepted and provider socket and the credential descriptor, zeroes
secret memory, replies `BROKER_STOPPED`, and exits. The supervisor waits through
the already held broker pidfd. At the monotonic deadline, that pidfd remains
identity/wait evidence only: the supervisor requests a durable
`broker_stop_escalated` commit, then sends the authenticated commit ID to the
manager's exact `STOP_ACTOR` operation. The manager closes authority, applies
the fixed deadline kill, and returns an authenticated exit/absence readback;
the supervisor independently observes pidfd exit and descriptor absence. The
manager is not used for ordinary graceful cancellation and its mandatory policy
cannot inspect worker secret memory or credential FDs. The worker accepts each
connection directly; no other process ever holds that accepted socket, its
provider socket, or its credential descriptor.

Every provider request has a unique manifest-bound request identity and durable
monotonic states. The invocation manifest also binds finite aggregate request,
input-token, output-token, and cost ceilings plus per-request and concurrency
limits. Before the first outbound byte, one durable compare-and-swap atomically
reserves that request's maximum count/tokens/cost against the invocation
generation; a reservation that could exceed any ceiling is denied without a
provider connection. Concurrent workers cannot share an invocation, and a
duplicate or stale generation cannot reserve. `provider_request_armed` is
committed with that reservation; before attempting any provider write, the
state advances to `provider_request_issued`. An independently validated
response reconciles actual usage without making the reserved capacity available
to another request until the prior effect is terminally classified. A crash or
lost response after issue conservatively retains the reservation, and restart
reconciliation cannot double-spend or silently refund it. Only an independently validated
provider response or provider-side readback can advance it to
`provider_effect_observed`. Controller, supervisor, or broker death after
`provider_request_issued` but before that observation is
`provider_effect_uncertain`: an already issued remote request cannot be rolled
back and is never described as having had no effect. Cleanup first closes the
session broker and credential authority, then a separately bound host
reconciler uses the request identity and provider idempotency/readback support,
when available, to classify the effect. If it cannot do so, the terminal receipt
remains uncertain for operator action. Neither path silently retries or replays
the request, resumes the candidate, or reports completion.

#### Bind one durable receipt ledger before any effect

All lifecycle phases, request-budget reservations, provider/forge intents and
readbacks, terminal receipts, and permanent consumed-operation tombstones live
in one schema-versioned receipt ledger on a dedicated encrypted host volume.
The manifest binds the no-follow volume/filesystem/root-inode identity, ledger
schema and binary digest, owner-only service identity, journal mode, integrity
settings, and a distinct encrypted write-once backup target. The ledger is not
inside the workspace, Podman store, staging/quarantine tree, candidate mount, or
provider/forge credential store.

Exactly one controller may mount the primary writable. It acquires an
OS-enforced exclusive ledger lock and atomically increments a durable fencing
generation before issuing an operation ID. IDs contain 256 kernel-random bits
and are unique under a primary-key constraint; a used ID is never released.
Every state transition is a transaction binding the controller generation,
operation, full manifest digest, predecessor state, monotonic timestamp, and
hash-chain predecessor. The fixed controller binary and service identity are
the only writer. Before starting the supervisor it creates a separate
authenticated `SOCK_SEQPACKET | SOCK_CLOEXEC` ledger-control pair and retains
the sole writer-side endpoint. The supervisor sends fixed operation-, actor-,
phase-, predecessor-, and generation-bound commit requests over the other end
and waits for a fixed commit ID/readback acknowledgment. Gate phases reach the
controller only after their FD3 frames are validated by the supervisor; worker
reservation/issued/effect states travel over the authenticated broker-control
pair and are relayed by the supervisor without candidate-selected fields. A
forge or signer adapter gets its own one-operation authenticated ledger-control
pair from the controller. No actor performs its corresponding local or remote
effect until the controller's durable acknowledgment matches the request, and
controller/lifeline loss closes admission. Independently opened read-only
handles verify the committed row, journal, filesystem identity, and chain
before an external effect.
Concurrent controllers, a stale generation, missing lock, wrong volume, and a
lost commit response fail closed.

Before the first provider or forge effect and after every authority-bearing
transition, the primary transaction and journal are flushed and an atomic
consistent backup object plus digest is durably committed on the distinct
target. There is no automatic failover or fresh-ledger fallback. If the primary,
backup, lock, row, chain, or integrity check is unavailable, corrupt, divergent,
or ambiguous, new admission stops. Manual recovery compares the primary and
backup at the last common transaction, preserves any issued or uncertain remote
effect, restores to a newly bound primary, increments the fencing generation,
and requires operator approval before admission. It never rewinds a consumed ID
or reservation. Crash, torn-write, lost-response, backup/restore, host-loss,
concurrent-controller, stale-writer, corruption, and missing-ledger tests must
prove fail-closed recovery and zero duplicate local, provider, or forge effect.

### 3. Use one bounded, fixed-operation launcher

`START_ACTOR` starts one fixed pod-owner monitor under the leased owner. That
monitor is the actual parent of one fixed, allowlisted, single-threaded launcher;
neither accepts a shell command, caller executable/path/environment, an address
other than loopback, a port outside the configured high-port range, or an
arbitrary namespace path. Before launch, the controller and session supervisor
each create a direct authenticated lifeline/control endpoint for the launcher;
the service manager installs only their peer ends in fixed descriptor slots and
closes every transient copy. At startup the launcher sets `PR_SET_PDEATHSIG`,
re-reads the monitor's PID/start identity to close the actual-parent death race,
and re-arms and rechecks that setting after any credential transition that could
clear it. It polls both controller and supervisor lifelines before every state
transition. Monitor parent death or either lifeline EOF, a missed monotonic
deadline, or an identity mismatch enters cleanup. No claim depends on the
distinct-UID supervisor being able to fork or impersonate the pod owner.

The launcher installs a syscall barrier that denies fork, `vfork`, `clone`,
`clone3`, `execve`, and `execveat` before reporting readiness. It brings up
loopback using fixed in-process operations, not a child command. It then:

1. joins the exact bound rootless Podman user namespace and exact bound pod
   network namespace through already validated `O_CLOEXEC` descriptors;
2. rechecks its process identity, both namespace identities and the
   `NS_GET_USERNS` owner relation, Podman store, and complete UID/GID maps;
3. sends an authenticated readiness record and waits for one-use authorization
   only after `launcher_bound` is durable;
4. brings up only `lo`, creates one `SOCK_CLOEXEC` TCP listener bound to
   `127.0.0.1` on one configured high port, and calls `listen(2)`;
5. transfers that listener once over authenticated `AF_UNIX`
   `SOCK_SEQPACKET` control using exactly one `SCM_RIGHTS` descriptor; and
6. completes the post-drop barrier below and exits on the host's one-use exit
   acknowledgment.

Every descriptor is close-on-exec at creation or open: `O_CLOEXEC` for files
and namespaces, `SOCK_CLOEXEC` for sockets,
`accept4(..., SOCK_CLOEXEC)` for the accepted control connection, and the
kernel-guaranteed close-on-exec pidfd result. Every flag is verified with
`F_GETFD` before use. The host receives the transfer only with
`recvmsg(MSG_CMSG_CLOEXEC)` into a fixed maximum frame buffer and control
buffer of `CMSG_SPACE(sizeof(int))`. It requires the
exact protocol version, frame type, state, nonce, and payload length. It rejects
`MSG_TRUNC`, `MSG_CTRUNC`, an oversized frame, reordered or duplicate frames,
every unknown or duplicate ancillary item, a wrong level/type/length, and
anything other than exactly one `SOL_SOCKET`/`SCM_RIGHTS` listener descriptor.
Frames that do not transfer the listener permit no ancillary data. All received
descriptors, including descriptors installed from a rejected message, are
closed on every parsing, authentication, state, timeout, or cleanup failure.

The host creates the control endpoint in an owner-only directory and binds it
to one invocation. It authenticates the launcher through kernel peer
credentials, a live pidfd, full durable process identity, and a one-use session
nonce delivered over the already authenticated control session. An agent bearer
token is not a control credential.

Before acknowledging transfer, the host proves that the sole received
descriptor is a TCP listener at `127.0.0.1:<bound-high-port>`. The
implementation explicitly probes `SO_NETNS_COOKIE`. When supported, the option
is mandatory on both the launcher's listener and host's received listener, and
their authenticated values must match. Only a proven unsupported-kernel result
may omit it; any other `getsockopt(2)` failure is fatal. The cookie complements,
and never replaces, the network-namespace identity and `NS_GET_USERNS` proof.

After the host records the exact `BROKER_LISTENER_BOUND` acknowledgment and
sends `LISTENER_ACCEPTED`, the launcher closes its listener copy and every
namespace or extra descriptor.
The manager starts the pod-owner monitor and launcher with an already empty
supplementary-group vector and proves it before namespace entry. The launcher
then binds and reads the selected user namespace's `/proc/self/setgroups` mode.
If it is `allow`, the launcher calls `setgroups(0, NULL)` while it still has
group-changing authority and verifies empty groups. If it is `deny`, it makes no
impossible `setgroups(2)` call and instead requires the inherited group vector
to have remained empty across namespace entry; any group or another mode fails
closed. It then calls `setresgid` and `setresuid` to one exact manifest-bound
mapped subordinate launcher identity. That identity is distinct from the host
service, gate, and candidate identities and every host translation lies inside
the allocated range. It reads back real/effective/saved IDs both locally and
from the host and fails unless the service UID/GID and all supplementary groups
are absent.

Only then does it drop the capability bounding set before clearing
`CAP_SETPCAP`, clear ambient, permitted, effective, and inheritable sets, set
`no_new_privs`, and install a verified syscall/filesystem barrier that forbids
new opens, namespace or mount changes, process creation/exec, networking, and
access outside the retained authenticated control descriptor. The no-fork/no-
exec barrier remains enforced. It sends an authenticated, fixed-schema
post-drop self-attestation. Before the first secret, the dedicated pod-owner
monitor corroborates only the allowed process/namespace/FD metadata through its
live pidfd and verifies boot ID, PID/start, executable, namespaces, maps,
subordinate UID/GID, empty groups, one thread, no child or descendant, all
capability sets zero, `NoNewPrivs: 1`, and the syscall/LSM barriers. It never
opens the launcher's descriptor targets or memory. Host-service-UID and group-only
sentinels must be unreadable, unwritable, and unsignalable. Its FD table may
contain only the explicitly declared authenticated control FD and declared
standard streams, each bound to its expected pipe or null device; every
namespace, listener, and extra FD must be absent. Only then does the host send
the one-use exit acknowledgment and wait for exit on the live pidfd. The
listener phase becomes durable only after that exit.

The controller, supervisor, and broker worker never enter the pod network
namespace; only the exact bound single-threaded launcher enters it to create and
transfer the listener, then drops authority and exits. The worker accepts on the
transferred listener and routes requests through the bounded provider operation
only after the separately reviewed implementation and cutover. Provider
credential, provider DNS/TLS connection, request validation, concurrency and
response limits, and logs remain host-side. The gate alone uses one expiring,
per-invocation non-provider broker token whose digest is bound to the operation;
the candidate never receives it, it is invalid after that listener closes, and
it is never accepted by another invocation. Candidate traffic uses only the
gate-owned loopback endpoint inside the exact pod.

### 4. Pre-stage inputs and keep every remote effect host-side

Before any pod effect, the controller binds an immutable invocation manifest:
issue identity; an ordered, finite repository set; image and provider-CLI
digests; dependency lock/manifests; approved artifact origins and digests;
requested output shape; and the complete allowed-effect set. Each repository
entry binds its identity, canonical remote, base ref/commit/tree, expected
meta-repository gitlink when applicable, allowed paths and transition, output
branch/base, and separate comment/commit/push/PR authority. A single-repository
harness has one entry. A multi-repository harness has the Odysseus entry plus
every selected component entry; `REPOS_FILTER` may only select an ordered subset
already present in that manifest. A missing, extra, duplicated, uninitialized,
or drifted member stops the invocation. Component PR effects complete and are
independently read back before any separately enumerated meta-repository
gitlink/integration transition; that final transition requires its own exact
base/pin/head authority and fresh cross-repository readback. No generic
cross-repository or submodule-update capability is implied.

Every issue, task, prior stage-result, PR, diff, and per-repository context value
is encoded as an ordered ADR-022 `hi.prompt-payload/v1` record with trusted kind,
media type, decoded byte length, and digest. The fixed host composer validates
those records and constructs the stage prompt without shell interpolation. The
candidate receives the prompt through one fixed inherited read-only input
descriptor or owner-scoped regular input file that is absent from argv,
environment, process listings, and logs; the gate verifies its identity and
closes it before descendant execution where the exact CLI does not require it.
Issue, task, forge, dependency, diff, and prior-result content remains untrusted
data after binding; none can add an effect or widen authority. Raw textual
fences and concatenated shell/CLI arguments are not compatible encodings.

The manifest also binds finite aggregate maxima, not only per-object limits:
repository/commit/tree/object/blob/file counts; encoded and decoded source
bytes; path-component length, full-path length, tree depth, and symlink-chain
depth; archive member count, per-member and aggregate encoded/expanded bytes,
and expansion ratio; dependency count and aggregate downloaded/expanded bytes;
stage-result/session-state counts and bytes; and separate plus combined capacity
for the raw-object store, resolver store, staging tmpfs, container tmpfs,
quarantine, session store, and cleanup scratch space. The fixed prefetcher,
resolver, gate decoder, and host decoder maintain streaming checked counters and
reject the next header/object before allocation, decompression, or write could
cross any bound. Filesystem/tmpfs quotas are defense in depth, not the parser's
limit. Integer overflow, deeply nested trees, aggregate-small-object floods,
overlong paths, decompression bombs, sparse-file tricks, and capacity exhaustion
fail closed and remove the exact partial quarantine/object-store generation.

The fixed host prefetcher creates a separate fresh owner-only raw-object store
for each manifest repository and fetches only that entry's canonical origin and
immutable commit through a digest-bound Git/HTTPS library. It independently
verifies each commit/tree closure and every declared meta-repository gitlink;
submodule recursion remains disabled and cannot substitute for the explicit
repository set. It uses the same sealed resolver, CA, TLS, SNI,
hostname, no-redirect, and no-proxy policy as the forge adapter below and
attaches a credential only after origin and peer verification. It accepts no
caller Git configuration or environment and disables/rejects includes,
alternates, replace/graft objects, hooks, attributes and clean/smudge/process
filters, textconv/diff/merge drivers, fsmonitor, LFS, submodules, credential
helpers, askpass, URL rewrites, `ext::`, arbitrary remote helpers, SSH, proxy,
and signer/editor overrides. It performs no checkout. A fixed object decoder
verifies the selected commit/tree closure and builds the source portion of the
canonical archive directly from raw blob/tree objects; duplicate, missing,
wrong-type, noncanonical, oversized, cross-store, or unexpected objects fail
closed. The detached input snapshot uses a fixed namespace for each repository,
and later stage/output schemas preserve those identities rather than flattening
colliding paths.

A separately authorized, bounded host resolver fetches only the dependency
artifacts selected by the bound lock/manifests from allowlisted origins,
verifies their content/provenance digests, and materializes them with the source
snapshot in an owner-only host staging tree. The resulting archive is a detached
normalized snapshot: it contains no `.git` directory or file, Git object
database, config, alternate, hook, signing key/config, remote, credential
helper, SSH config/agent, or forge transport. Container launch uses
the bound image digest with `--pull=never`. The candidate performs local work
only: no DNS, remote
clone/fetch/pull, package or tool download, registry access, NATS connection,
or provider/forge connection. It receives no proxy, `CONNECT` tunnel, resolver
socket, default route, bridge/host-gateway, SSH agent, credential helper, forge
credential, or container-engine socket. Provider name resolution, TLS
validation, and upstream requests occur only in the host broker.

If candidate work changes a dependency manifest or lock and additional
artifacts are required, the candidate emits a bounded checkpoint and stops.
The controller records the request as untrusted output. Only a separate
authorized resolver operation may build and verify a new artifact snapshot;
work then starts in a new pod, gate session, operation ID, and immutable
manifest. The existing candidate never gains transient egress or a new mount.
Missing input, failed resolution, or unavailable artifact is a truthful terminal
failure for that session.

The multi-repository harness currently relies on Claude CLI `--session-id` and
`--resume` state that persists through its host `~/.claude` mount. Removing that
mount must not silently turn a resumed turn into a new turn. The manifest binds
the exact CLI/image version, task, repository, stage, session ID, predecessor
turn, and a closed allowlist of CLI session-state paths and schemas. After a
successful turn and descendant reaping, the gate exports only those regular
files through a canonical archive; it rejects credentials, authentication and
provider configuration, update state, debug/log/cache content, links, special
files, unknown fields, size overflow, and any path outside the allowlist. A
separate host session-state service independently decodes that archive into an
encrypted, owner-only, no-follow store and compare-and-swap commits its digest
to the invocation receipt. That store is never mounted into a pod.

For a resumed turn, the controller copies the exact predecessor archive into
private tmpfs before release and the gate independently validates and
materializes it for the candidate UID. The CLI receives `--resume` only after
the session ID, predecessor, CLI/image, schema, file universe, and digest all
match. A crash before the export commit, missing/corrupt state, version drift,
or ambiguous predecessor blocks resume and records a truthful failure; it does
not silently start a fresh conversation. Retention, deletion, backup, and key
destruction are manifest-bound, and terminal cleanup proves no session archive
contains a broker token, provider/forge credential, or authentication config.
The single-repository harness remains explicitly new-turn-only, as it is today.

Candidate output is untrusted file data. A `.git` file, directory, or symlink at
any depth is rejected. `.gitattributes` and `.gitmodules` may be returned only
when allowed by the path manifest and are never executed or consulted during
archive extraction, diffing, hashing, commit construction, or delivery. After
candidate exit and descendant reaping, the trusted gate emits one canonical
complete state-transition manifest over the exact allowed-path universe bound
to the input tree. Every allowed path appears exactly once as `present` or
`deleted`. A present record binds type, mode, size, and content digest and must
have exactly one matching archive member; a deleted record carries no bytes and
is valid only for a path that existed in the bound input tree. A rename is an
explicit bound deletion plus a present destination. Missing, duplicate,
out-of-universe, state/type-conflicting, byte-less-present, or byte-bearing-
deleted records fail closed; absence from the archive never implies deletion.
The host copies the manifest and present bytes into a fresh owner-only
quarantine tree, opens every component with a dirfd/no-follow traversal,
rejects path escape, devices, FIFOs, sockets, and unexpected hardlinks, and
independently decodes and hashes every record, path, mode, size, and byte before
any forge effect. It resolves every symlink chain lexically against the complete
bound output tree without dereferencing the host filesystem. An absolute,
escaping, cyclic, dangling, ambiguous, or out-of-universe target fails, as does
any target or intermediate component in `.git`, a protected workflow/config/
governance namespace, or another path outside the exact allowed-path set. A
symlink is admitted only when its normalized target and every chain member are
explicit manifest entries authorized for that type.

Accepted ADR bodies and other immutable evidence are never valid output paths.
A regular-file transition under `.github/workflows/`, canonical NATS/Nomad
configuration, agent-governance policy, or another repository-declared
protected namespace is absent from the allowed universe unless an independently
authenticated human approval was created after the exact input head was known.
That approval binds repository, operation, base/head, exact path, prior and
proposed type/content digests, permitted effect, reviewer identity, and expiry;
it is fetched over the trusted forge path and never from issue/task/prompt/diff
or candidate output. Meta-repository gitlink transitions use the separately
enumerated integration approval above. Missing, stale, broader, path-only, or
content-drifted approval fails closed. Formal acceptance of this ADR is not such
an implementation or protected-file approval.

The legacy harness state machines also consume bounded Claude stdout as the
stage result; the filesystem archive does not replace that interface. Container
logging is disabled with the exact OCI `--log-driver=none` specification. Gate
PID 1 owns nonblocking stdout/stderr pipes for the candidate, applies separate
manifest byte/deadline limits, rejects invalid UTF-8 and truncation, and drains
both streams while reaping descendants. It emits stdout only as one typed
`stage-result` member in the quarantine archive, with stage, task, attempt,
content length/digest, and candidate-exit binding. Stderr is mapped to a bounded
fixed diagnostic enum and digest unless the manifest explicitly authorizes a
bounded diagnostic attachment. Neither stream enters OCI/conmon logs,
exceptions, security receipts, or terminal evidence.

The controller treats stage text as untrusted data. It validates the existing
stage-specific result/verdict schema, preserves the existing NATS/task result
field names, sizes, and state-machine meanings, and fences the exact bytes when
supplying them to a later prompt. Schema failure propagates as failure and never
becomes completion. A forge template may include bounded result text only via
the inert encoding contract below; candidate text cannot add a remote effect.
Portable and real-path tests cover plan, test, implementation, exact review
verdict, ship, resumed-turn, invalid UTF-8, over-limit, timeout, split writes,
stderr-only failure, and hostile instruction/closing-keyword content.

A fixed host forge/delivery adapter—not prompt text or a candidate command—may
perform only effects enumerated in the manifest: a bounded template-based issue
comment; an exact-ref fetch and drift check; a signed commit of the bound tree
and allowed paths; a non-force push of the bound head to one allowed
non-protected branch; and PR creation with the exact base/head. It then stops
before merge and exposes that immutable head for independent review. The
manifest binds repository/issue, canonical remote, base and head refs/SHAs,
branch, complete allowed-path transition, tree/diff digest, signing identity, fixed
comment/commit/PR templates, required checks, and the configured Athena
reviewer identity. Candidate-derived remote text is never inserted raw merely
because it is shell- or Markdown-escaped. Commit author, commit subject/body,
PR title/body, and issue-comment prose are fixed canonical templates containing
only manifest-selected identifiers, fixed vocabulary, and content digests.
Untrusted candidate prose remains in the quarantined content-addressed artifact
and is referenced by digest through an inert field. If an approved interface
must carry it, the manifest selects a canonical opaque encoding whose alphabet
cannot express mentions, issue-closing keywords, slash/chatops commands, links,
task directives, control characters, or bidirectional controls. Any permitted
secondary effect, including closure of one exact issue, is an explicit manifest
effect rather than a consequence of text parsing. The adapter inventories every
installed consumer of comment, commit, and PR events and rejects a field that
could trigger an unbound consumer.

Merge authority begins only after the adapter retrieves the complete forge
history and verifies an authentic delivered Athena terminal GO for that exact
head. It requires the expected reviewer actor, one strict versioned terminal
`COMMENT` carrier and publication-anchor proof, exact target/head/scope and
content digests and exact base-tip SHA, a valid ordered carrier and author-event
chain reduced to its terminal ledger, no pending authority event, zero open
review threads, and the exclusive `state:implementation-go` label with no NO-GO
label. A comment, label, approval, or locally constructed payload is never
sufficient by itself. Every required check name and expected app identity must
be successful for the same head.

The adapter then compare-and-swaps one immutable, single-use
`merge_authorized` receipt containing that complete validated snapshot,
carrier/event-chain hash, source head, and base tip. Mutable comments, labels,
and thread state are pre-admission evidence; the design does not falsely claim
they remain atomic predicates after the receipt is consumed. A later event for
the same review round cannot create another effect. If repository policy makes
post-admission metadata a revocation signal, admission is supported only behind
a trusted repository-enforced gate that can atomically block that signal;
otherwise the adapter stops for human merge. Source-head or base-tip movement
always invalidates the receipt.

Immediately before the merge effect, the adapter revalidates the unconsumed
receipt, PR head, base tip, mergeability, and exact-head checks. A head-only
GitHub merge request is insufficient because it has no atomic expected-base
predicate. The adapter may merge only through a repository-enforced queue or
merge-group primitive that atomically binds both the reviewed source head and
base tip, produces a specific merge result, and runs the required expected-app
checks on that result. Source-head, base-tip, merge-group, or check drift
cancels the entry and starts a new review exchange. If the repository lacks
that primitive, the adapter stops before merge for explicit human action and
records no completion. The baseline adapter does not leave ordinary auto-merge
enabled: GitHub does not guarantee disabling it after a new push by a
write-authorized actor. After merge, independent readback binds the admitted
source/base pair, merge-group result, merged commit, parents, tree, PR, and
terminal receipts before completion.

The adapter has no general shell or caller-selected URL/ref. It uses a separate
owner-only host repository and object/index/tree staging area created before
candidate output is admitted and never mounted into the pod. It refetches and
reads back the exact base object through a digest-pinned Git/HTTPS client,
imports only validated quarantine bytes, and constructs blobs, index, and tree
through a fixed library or bound plumbing that hashes raw bytes without a
checkout or attribute filter. The resulting tree, parent, allowed-path set, and
diff are independently recomputed, made immutable to the operation, and
compared with the manifest immediately before signing and again before push.

The adapter runs with a sealed allowlisted environment and digest-bound local
configuration. It uses an owner-only empty hooks directory and disables or
rejects config includes, alternates, submodules/LFS, clean/smudge/process
filters, external diff/textconv/merge drivers, fsmonitor, credential helpers,
URL rewrites, `ext::`, arbitrary remote helpers, SSH commands/agents, proxy
commands, and every protocol except the exact canonical HTTPS transport.
`HOME`, XDG, `GIT_*`, SSH, proxy, editor, askpass, and signing overrides from
candidate or ambient state are absent. Forge API, Git transport, and signing
binaries and helpers are absolute-path and digest-bound. Signing occurs in a
separate bounded host signer with the exact key identity and signature readback;
candidate author, message, and body strings never select remote semantics and
are represented only by the inert encoding and digest contract above.

For both forge API and Git HTTPS, the manifest binds the exact scheme, origin,
port, operation-specific method/path/query, resolver configuration, CA trust
store, TLS policy, SNI, and hostname-verification policy. Redirects, proxy
tunnels, netrc, custom-CA, credential-helper, alternate endpoint, and ambient
system-trust overrides are disabled. The adapter verifies the final connected
origin and authenticated TLS peer before attaching a forge or Git credential;
an origin, certificate, name, path, or redirect mismatch sends no credential
byte and records only a fixed redacted error.

The adapter opens forge and signing credentials only on the host for one
manifest operation. Force pushes, deletes, protected/default-branch updates,
tags, arbitrary comments, foreign issues/repos/heads, and a stale base or head
fail closed. Before an effect it durably records intent, idempotency key,
expected remote state, and full binding; afterward it records the remote object
ID/SHA and an independent readback. A retry first reconciles that readback and
never duplicates an observed effect. Failure or cancellation closes
credentials, preserves partial-effect receipts, and performs no compensating
remote deletion without separate authority. The task cannot report completion
before every required effect reaches and is observed in its manifest-defined
terminal state.

### 5. Persist monotonic full-binding phases

One durable effect receipt owns the complete lifecycle. A transition is a
compare-and-swap over the expected prior phase and full-binding digest. Every
next binding contains every earlier immutable value and may add only the fields
allowed for that phase. It cannot rewrite authority, skip or reverse a phase,
or reuse another operation's effect. Live pidfds, namespace descriptors, and
listener/control descriptors are kept separately in process memory and never
serialized into that receipt.

`receipt_retired` retires live authority; it does not erase the replay barrier.
The complete terminal receipt remains immutable for at least the longest
provider, forge, review, rollback, and audit retention window. When that record
expires, one compare-and-swap atomically replaces it with a minimal append-only
terminal tombstone containing only the nonsecret operation ID, full-binding and
manifest digests, terminal outcome, remote effect IDs and readback digests, and
cleanup-proof digest. Operation IDs are globally nonreusable, and the tombstone
is retained permanently in the consumed-operation index. A missing, corrupt, or
ambiguous tombstone fails closed. The same operation after cleanup or restart
returns the recorded terminal classification or requires operator action; it
can never create a listener, pod, candidate, provider request, or forge effect.

Security receipts, generic logs, exceptions, and untyped artifacts never
persist raw frame, control, or ancillary buffers; nonce bytes or a
nonce-derived verifier; broker-token bytes; provider, forge, or signing
credential bytes or credential-derived hashes; signing material; raw upstream
provider request/response/error bodies;
secret-bearing URLs, headers, or environment; or raw OCI stdout/stderr. The only
durable candidate-content exceptions are the separately typed, size-bounded,
owner-protected `stage-result` and validated CLI session-state archives above.
Their bytes remain untrusted and are never review, completion, or security
evidence; the receipt holds only their type/length/digest and storage CAS
identity. Durable IPC evidence is only a canonical redacted
event list: protocol version, ordered frame types, declared and actual lengths,
monotonic offsets and deadline outcome, receiver namespace identity, durable
sender-process reference, nonsecret operation/full-binding/listener/artifact
digests, validation booleans, a digest of each canonical frame after every
secret field is replaced by its fixed redaction marker, and a fixed error enum.
An in-memory authenticated transcript digest may cover the nonce, but it is
zeroed after validation and is not persisted. Durable state records
`transcript_verified=true` and the digest of the redacted event list only.
Failure paths record field/type/error, never a raw buffer. The sole durable
secret-derived exception is the schema-fixed 256-bit broker-token digest needed
to bind the worker and gate to the same random per-invocation token; it is never
used as an authenticator, never accepted in place of the token, and is deleted
from live receipt state at cleanup while the permanent tombstone retains only a
nonsecret token-generation event ID. A nonce identity is likewise a nonsecret
random-generation event ID independent of nonce bytes, not a nonce hash or
verifier.

The creation phases are:

1. `lease_prepared` — operation, immutable pre-manifest, fixed pool class,
   controller and allocator generations, exact controller process identity, and
   zero-effect reservation intent are durable before `PREPARE_LEASE`;
2. `lease_bound` — the manager's reserved UID/GID/subordinate-map/LSM/cgroup/
   home/`runRoot`/graph-root tuple and allocation-journal CAS are durable while
   none of those objects exists;
3. `lease_activated` — the exact fixed objects have been created, labeled, and
   independently read back after `ACTIVATE_LEASE` and before another local
   effect;
4. `armed` — operation, labels, fixed privileged identity allocator,
   pod-owner identity/LSM policy, controller/session-supervisor, broker-worker,
   launcher, gate, Podman, conmon, crun, image, staging,
   resolver, forge, Git/HTTPS, and signer identities, immutable input/artifact
   manifest, output and remote-effect bounds, resource limits, stable store
   tuple, and service host boot ID are durable before a pod effect;
5. `image_import_armed` — the pre-opened canonical OCI archive identity, exact
   image/config/layer digests, empty fresh-store expectation, and closed
   `IMPORT_IMAGE` operation are durable before import;
6. `image_bound` — import result and an independent owner/store/image readback
   prove the one exact local digest available for `--pull=never`;
7. `pod_bound` — exact pod and infra IDs, durable infra-process and namespace
   identities, namespace-owner relation, and complete mapping metadata are
   durable; live pidfd and namespace handles remain session-local;
8. `launcher_bound` — durable launcher process metadata, redacted control-event
   evidence, namespace/map rechecks, deadlines, and one-use authorization state
   are recorded while the session supervisor holds the live pidfd;
9. `listener_bound` — address, port, namespace and owner identities, mandatory
   cookie result, redacted launcher and `BROKER_LISTENER` transfer evidence,
   exact `BROKER_LISTENER_BOUND` acknowledgment, post-drop verification,
   launcher exit, broker-worker PID/start/executable and live-pidfd identity,
   both lifeline endpoint identities, and the expected supervisor/worker FD
   topology are durable after the supervisor has closed its copy and the worker
   owns the sole live listener descriptor;
10. `agent_run_armed` — the complete immutable `podman run` specification,
   collision-resistant labels, image/input/output/tmpfs digests, exact local
   Podman/conmon/crun identities, restart policy `no`, gate/candidate argv and
   sealed environment, token digest, successful worker `BROKER_ARMED` binding,
   owner-only cidfile directory/path identity, FD3 socket identities, controller
   and session-supervisor process identities, receiver-relative credential
   expectations, protocol version, nonsecret nonce-generation event identity,
   and deadline are
   durable before the single run effect;
11. `gate_started` — the exact container ID, inspect digest, pod membership,
   tmpfs mounts, immutable gate PID 1, process/namespace identity, cgroup, and
   live pidfd/FD3 binding have been read back after `podman run`, while the
   candidate has not executed;
12. `fd_topology_bound` — the start helper, Podman, and transient runtime have
   exited; the persistent conmon PID/start/executable/pidfd and the pod-owner
   monitor's pre-secret process/FD metadata are bound; the session supervisor alone owns the host
   endpoint, the gate owns the gate endpoint, and only for the initial public
   `HELLO` may a manifest-declared exact-version conmon retain one duplicate
   gate endpoint; no process owns both and no unknown holder exists;
13. `inputs_staged` — the canonical input archive has been copied into
   container-private storage, independently verified by the waiting gate, and
   materialized with exact candidate ownership, while no candidate has executed
   and no archive contains broker-token material;
14. `secret_fd_topology_bound` — after validated public `HELLO`, any permitted
   conmon duplicate has closed; the monitor's final permitted enumeration and
   authenticated close/exit prove the supervisor and gate are the only socket
   holders, and that two-holder topology plus monitor absence is durable before
   the first secret-bearing `ARM` byte;
15. `gate_bound` — validated READY state, exact broker-token file metadata and
   digest, redacted protocol evidence, and the positive no-provider-effect
   listener-readiness proof are durable while the worker owns the live listener
   and the session supervisor owns the sole authoritative gate host endpoint;
   the candidate has neither executed nor sent a request, and broker admission
   remains disabled;
16. `candidate_stopped` — after one durable RELEASE/ACK, immutable gate PID 1
    retains FD3 and supervises exactly one hardened pre-exec admission child.
    That child has erased inherited secret state, has no FD3/token descriptor or
    gate state, has completed all identity/capability/seccomp transitions, and
    is synchronously stopped before it can exec the CLI, read a prompt, mutate a
    workspace, or issue a request;
17. `active` — the supervisor has validated the gate's authenticated
    `CANDIDATE_STOPPED` report, live pidfd, expected admission-shim executable,
    argv, namespaces, maps, pod, cgroup, empty authority/FD state, and target CLI
    digest, then durably committed the exact one-use activation. Only the
    corresponding gate-validated `ACTIVATE`/`ACTIVATE_ACK` may continue the
    child into the fixed CLI exec and dispatch work; and
18. `outputs_bound` — after candidate exit and descendant reaping, the trusted
    gate's complete present/deleted transition manifest, present-path archive,
    and typed `stage-result` have been copied to new owner-only quarantine
    objects and independently decoded, universe/state/path/schema-checked, and
    digest-checked against the bound input tree and stage contract. When the
    multi-harness stage is resumable, the closed-schema session-state archive is
    independently validated and compare-and-swap committed as the exact next
    session predecessor. The receipt binds all three artifact/CAS identities
    before any forge, next-stage, resume, or signing effect.

No fixed host object is created before `lease_bound`; no general invocation
effect follows activation before `lease_activated` and `armed`; no pod is
created before `image_bound`. The host does not arm the run until
`listener_bound` is durable and does not
invoke `podman run` until `agent_run_armed` is durable. It does not begin the
gate protocol until `fd_topology_bound` and `inputs_staged` are durable, and it
does not create the stopped admission child until `gate_bound` and listener
readiness are durable. It does not continue that child into the CLI until
`active` is durable. A crash after
the run effect but before `gate_started` may discover an object only through
the bound cidfile and exact operation labels, then validate its complete
immutable inspect against `agent_run_armed`, terminate it, and clean it. A
missing or malformed cidfile, multiple label matches, or any mismatch stops
automatic action for operator review; recovery never adopts, releases, or
resumes the candidate. Extra, missing, renamed, or mismatched state is never
adopted.

One non-daemonizing session supervisor is the direct child of the dedicated
controller parent and the sole authoritative gate host-end owner for the full
invocation. The broker worker is the sole listener owner after
`listener_bound`. The supervisor sets and rechecks `PR_SET_PDEATHSIG`, polls the
bound controller, broker-worker, conmon, gate, and candidate pidfds, and never
accepts or retains an accepted descriptor. Controller EOF/death or supervisor
parent drift is also observed through the broker's direct controller lifeline.
Broker-worker death, conmon death, gate death, or any identity/deadline failure
makes the supervisor close the gate host endpoint, stop and wait for the broker
as specified above, and enter cleanup. Supervisor death closes its control
descriptors; after bounded detection of authenticated supervisor-lifeline EOF,
the worker immediately closes authority and exits. A request that could have
crossed the provider boundary in the poll/write race remains
`provider_effect_uncertain`; no synchronous no-further-I/O guarantee is claimed. Manager
death separately kills its actual worker child through `PR_SET_PDEATHSIG`; worker
death closes the sole listener, and gate PID 1 observes EOF/POLLHUP, exits, and
causes the PID namespace to kill every remaining candidate descendant.

A controller, supervisor, or broker crash destroys the session's live
listener, accepted-socket, provider-socket, and credential capabilities. A
durable receipt cannot recreate them. A provider request that may already have
crossed the remote boundary is instead marked `provider_effect_uncertain` and
reconciled as specified above; process death is not rollback evidence. Recovery
never recreates the listener, releases or restarts the gate, resumes the
candidate, reruns it, or silently replays a request. It marks the invocation
interrupted, uses the receipt only to contain and terminate the exact bound
agent and pod and to reconcile exact remote request identities, records a
truthful terminal result, and retires the receipt only after terminal readback.

During one live session, every signal and wait uses an already held pidfd. After
a controller restart, recovery compares the recorded host boot ID first. If it
changed, every recorded process is extinct and recovery never signals a numeric
PID that may have been reused. If it matches, recovery reads the complete stored
PID/start/executable/namespace tuple, calls `pidfd_open(2)`, then re-reads and
compares the same tuple; only that freshly validated pidfd may authorize a
signal or wait. A missing, mismatched, or reused PID authorizes no signal. A
fresh namespace descriptor may be opened only after the same identity proof and
only for verification or cleanup, never to resume work. After a boot change,
Podman object cleanup is allowed only through a freshly validated endpoint
session and stable store plus exact object ID, digest, label, map, and namespace
readbacks.

Cleanup advances monotonically through `cleanup_armed`,
`gate_channel_closed`, `broker_closed`, `candidate_absent`, `gate_absent`,
`conmon_absent`, `launcher_absent`, `pod_absent`, `staging_reconciled`,
`host_authority_closed`, `remote_effects_reconciled`, and finally
`receipt_retired`. A cleanup transition records its terminal readbacks and the
prior binding digest. The final transition retains the immutable terminal
receipt and permanent consumed-operation tombstone described above; it removes
no last replay barrier. An unknown effect kind or phase issues no external
command and fails closed for operator review.

### 6. Stage through container-private storage; use no host idmapped bind

The implementation supports and tests one Podman user-namespace design:
rootless `--userns=auto:size=65536`. It proves the complete allocated and
observed `/proc/<pid>/uid_map` and `gid_map` for the infra process, launcher,
gate, and candidate. Each must match the bound allocation and expected relation,
fit wholly within the service account's bound subordinate ranges, and exclude
the service host UID and GID. A map containing either service identity, even in
an extent not selected as the candidate user, fails closed. Numeric UID/GID
equality alone proves nothing.

The selected rootless path does not rely on an idmapped host bind or on an
ownership-shifting mount option whose support varies by filesystem, kernel, or
Podman release. The agent receives no host workspace, state, cache, credential,
Git, control, or output bind at all. The image root is read-only;
`/workspace`, `/state`, and `/run/homeric` are explicit size-bounded
container-private tmpfs mounts with `nosuid,nodev`, with `noexec` everywhere
except a manifest-authorized executable workspace when local tests require it.
Inspect and `/proc/self/mountinfo` must exactly match that specification and
must show no `idmap`, `:U`, broad home, Podman-socket, service-owned writable
bind, or host-root fallback.

Before pod launch, the host prefetcher creates an owner-only staging root by
component-wise no-follow opens. It pre-materializes a canonical regular-file
input archive and manifest, each `0600`, from the exact approved source and
dependency bytes. The candidate cannot traverse or receive that host tree. Once
the trusted gate is waiting, the controller uses the exact bound local Podman
copy operation to stream the archive into `/workspace`; command success is not
evidence because rootless copy implementations may ignore permission failures.
The gate performs a second fixed decode, rejects absolute or `..` paths,
devices, FIFOs, sockets, and disallowed hardlinks, applies the same complete
symlink-chain and protected/control-namespace policy as host output validation,
verifies every path, mode, size, and content digest, applies the exact candidate UID/GID
inside the container, and reports only redacted verification evidence. The
archive contains no broker-token file. The gate creates that file later only
from the authenticated FD3 `ARM` secret after the worker has acknowledged the
same operation/listener/binding token.

Gate PID 1 remains trusted for the session. After the candidate exits and all
descendants are reaped, the gate walks the complete manifest-allowed path
universe and creates the explicit present/deleted transition manifest plus a
canonical archive containing only present records in a separate tmpfs. It
derives each transition relative to the bound input tree; rename is delete+add,
never an inferred pathname. The host copies those artifacts into a new
owner-only quarantine tree and independently decodes and verifies them before
`outputs_bound`. A missing or duplicate record, missing or extra byte member,
out-of-universe path, special file, escaping link, state/type/digest mismatch,
or Podman-copy ambiguity fails closed. The candidate never supplies a host
pathname or causes a host checkout.

A disposable probe, running as the exact candidate user with the same tmpfs
mounts and no provider credential, writes only `/workspace` and `/state`, reads
only the staged nonsecret input and endpoint metadata allowed to it, is denied
read/link/rename/traversal access to the gate-owned token file, and cannot access the host staging
root, provider credential, Podman socket, or quarantine. `--privileged`,
Podman `--userns=keep-id`, `--userns=host`, kernel initial user namespace,
extra capabilities, service-identity mappings, any bind/idmap/`:U` workspace,
and ownership-dependent guesses fail preflight.

### 7. Release the immutable PID 1 gate only over exact FD3

The container's OCI entrypoint is a digest-bound trusted gate binary from its
read-only image. No shell, wrapper, writable bind, or environment override may
replace it, and restart policy is `no`. Inspect must exactly match the gate and
candidate argv/environment, mounts, user, resources, image digest, pod, and
`--network none`/`--userns=auto:size=65536` expectations.

Immediately before `agent_run_armed`, the session supervisor creates exactly one
`socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, sv)`, then enables and
verifies `SO_PASSCRED` on both socket ends before either peer sends a
frame. It retains the only host end. The supervisor transfers the gate end once
in the fixed `RUN_GATE` descriptor slot. The service manager receives it with
`MSG_CMSG_CLOEXEC`, validates the socket, peer identities, receipt commit, and
lease generation, then launches exactly one single-threaded start helper under
the dedicated pod-owner identity. The helper starts with a sealed environment
in which `LISTEN_PID`, `LISTEN_FDS`, and
`LISTEN_FDNAMES` and every ambient `GIT_*`, SSH, proxy, and credential variable
are absent. It closes every undeclared FD, maps only the gate end to child FD 3,
and clears close-on-exec only on that FD immediately before executing the exact
bound local Podman CLI. The only supported start is the bound Podman/crun path using
`podman run --detach --pull=never --preserve-fds=1 --cidfile <bound-path>` and
the fully bound OCI specification constructed by the manager. The cidfile parent is owner-only and opened
without symlink traversal; the file must not preexist. Remote Podman, the
service API, Docker, another OCI runtime,
`podman create` followed by `start`, and any other FD transport fail closed.
After the manager has the helper's authenticated startup acknowledgment, it
closes its transient gate-end copy and reports the exact helper PID/start. The
start helper exits at the Podman exec, Podman closes its copy after bound
conmon setup, and the transient runtime must exit before the protocol begins.
Each close/exit is confirmed by pidfd and FD-table readback rather than inferred
from an exec boundary.

This is the sole narrow close-on-exec exception: FD 3 may cross the fixed start
helper, Podman, OCI runtime, and gate exec chain. At its first instruction the
gate requires FD 3, verifies its bound socket identity and
`AF_UNIX`/`SOCK_SEQPACKET` type, and sets `FD_CLOEXEC`. Missing, swapped, stale,
path-based, TCP, FIFO, stdin, file, environment, or extra inherited control
channels are rejected. Before any secret frame, the pod-owner monitor binds the
live gate PID/start, pidfd, executable, user/network namespaces and owner
relation, maps, cgroup, and `/proc/<pid>/fd/3` socket identity using only its
LSM-allowed metadata reads. After the secret topology commit, later identity
proof uses authenticated gate self-attestation, kernel `SCM_CREDENTIALS`, and
pidfd liveness/exit; it does not claim a same-service `/proc` inspection.

The implementation binds exact Podman, conmon, and crun versions, binary
digests, process identities, parents, and FD behavior. Before any protocol
frame is accepted, the controller and pod-owner monitor combine authenticated
self-attestation with LSM-limited metadata enumeration for the session
supervisor, gate, start-helper, Podman, transient-runtime, conmon, and every
unexpected pod-owner/service process. For the initial public `HELLO` only, the allowed
topology is one supervisor host endpoint, one gate endpoint in gate PID 1, and,
only when declared and proved for the selected stack, one duplicate gate
endpoint in the exact bound conmon. No process may own both ends and no other
holder may exist. A frame from conmon is rejected; consumption of public
`HELLO` causes terminal timeout, and conmon death or FD drift closes the
session. After valid `HELLO`, conmon must close its duplicate. The pod-owner
monitor then enumerates every holder again and the supervisor commits
`secret_fd_topology_bound` only
when exactly its host endpoint and gate PID 1's endpoint remain. No nonce,
broker token, or other secret-bearing frame is sent before that commit. A stack
that retains a conmon duplicate, differs from either exact topology, or cannot
prove the close is unsupported. The monitor closes its control channel and
exits, its absence is verified, and only then may the supervisor send `ARM`.

The gate is immutable, non-dumpable PID 1 for the full container session. It
reaches a bounded waiting state without forking or executing the untrusted
candidate, verifies the staged input, and proves loopback-listener readiness
with a fixed health operation that cannot invoke the provider.

Every `SCM_CREDENTIALS` observation is interpreted relative to the receiving
process's PID and user namespaces and recorded with those namespace identities
and the expected map. On frames received by the host, the sender tuple must
equal the host-visible gate PID and mapped UID/GID derived from the durable gate
identity and live pidfd. On frames received by the gate, the supervisor's host
PID may translate to PID zero and its deliberately unmapped service UID/GID may
translate to the kernel overflow IDs. That exact receiver-relative tuple is a
consistency check only, never standalone identity or authorization, and raw
numeric tuples are never compared across receivers. An unexpected translation
or overflow value fails closed.

Release authority instead derives from the trusted session supervisor creating
the socketpair, retaining the only host endpoint, never transferring it, the
exact two-holder secret-phase topology, and the nonce/full-binding state
machine. The host rejects any frame whose kernel sender is not exact live gate
PID 1. The gate accepts host frames only on its inherited bound endpoint with
the exact expected receiver-relative tuple. The protocol uses fixed-size,
versioned `SOCK_SEQPACKET` frames and bounded monotonic deadlines in this order:

1. The gate sends `HELLO` containing only the protocol version and its bound
   gate-build identity. The supervisor validates kernel-supplied
   `SCM_CREDENTIALS` plus the pod-owner monitor's authenticated pre-secret
   process/FD-topology attestation. Any declared conmon duplicate then closes;
   the monitor performs the final permitted enumeration, closes and exits, and
   the supervisor durably commits `secret_fd_topology_bound`. Failure to prove
   exactly the supervisor and gate endpoints and monitor absence ends the
   session without sending a secret.
2. After the worker's exact `BROKER_ARMED` acknowledgment, the supervisor sends
   one `ARM` containing the precommitted random nonce, operation ID,
   full-binding digest, listener-receipt digest, deadline, and one fixed-length
   secret broker-token field. The nonce and token exist only in locked
   supervisor, worker, and gate memory while needed; `agent_run_armed` records
   the nonce-generation event ID and the one permitted broker-token digest, not
   nonce bytes, a nonce-derived verifier, or token bytes.
3. The gate consumes `ARM` once, atomically creates and verifies the exact
   owner-only broker-token file, zeroes its transient token copy, proves listener
   readiness, and sends `READY` echoing the nonsecret binding fields, token-file
   metadata and digest, plus an in-memory authenticated transcript digest.
4. The supervisor validates `READY`, zeroes its token copy, durably commits
   `gate_bound`, requires `BROKER_ENABLE`/`BROKER_ENABLED` for that same binding,
   and sends one `RELEASE` with the same binding and a release digest.
5. The gate consumes `RELEASE` once and sends one `ACK` bound to its digest. It
   The gate is a one-thread event loop for its entire lifetime: HTTP/SSE parsing,
   broker exchange, archive work, and control handling cannot create a helper thread.
   Immediately before the fork it reads the kernel task inventory and requires exactly
   its own thread; a second thread or an unavailable readback fails closed. It then forks
   exactly one pre-exec admission child. At its first post-fork
   instruction, before a credential transition or fallible allocation, the
   child closes FD 3, every broker-token-file FD, and every gate/control/secret
   descriptor; proves every secret `MADV_DONTFORK` mapping absent, rejects any
   unexpected inherited mapping, and zeroes remaining nonsecret control state;
   it then reasserts
   `PR_SET_DUMPABLE=0`, `RLIMIT_CORE=0`, and crash-collector exclusion. The gate
   has already bound the user namespace's `/proc/self/setgroups` mode and proved
   its own empty group vector. If the mode is `allow`, the child calls
   `setgroups(0, NULL)` while it still has group-changing authority; if it is
   `deny`, the child makes no forbidden call and proves the inherited vector is
   still empty. Any group or other mode fails closed. Only then does it change
   to the exact candidate GID and UID, reassert and verify nondumpable
   state after each transition that may reset it, empty all capability sets,
   set `no_new_privs`, and install the candidate seccomp policy. Every transition
   and readback is checked; in `allow` mode, losing `CAP_SETGID` before the
   empty-group proof is forbidden. The child raises an
   unblockable-by-candidate synchronous stop, and cannot yet exec the CLI, read
   the prompt, mutate the workspace, or connect to the gate. Gate PID 1 observes
   the exact stopped child with `waitid`, sends `CANDIDATE_STOPPED` metadata over
   FD 3, and awaits `ACTIVATE` while retaining FD 3 and polling supervisor
   liveness. Hostile pre-exec crashes and core/journal fixtures must prove no
   inherited token, nonce, transcript, provider, or control byte remains.
6. The supervisor validates that report and pidfd identity, commits
   `candidate_stopped` and then the one-use `active` activation, and sends
   `ACTIVATE` containing that commit ID. The gate accepts it only once for the
   stopped child, resumes the child, and sends `ACTIVATE_ACK`. The child then
   execs only the bound image CLI with the sealed invocation. It never receives
   the nonce, token, FD 3, or control authority. A crash, timeout, duplicate,
   wrong commit, early continuation, or exec failure enters cleanup and cannot
   dispatch work.
7. On normal candidate exit, the gate proves descendants absent, builds the
   canonical output archive, sends fixed `EXIT` metadata containing only status
   and nonsecret archive digests, and waits. After host copy, independent
   verification, and durable `outputs_bound`, the supervisor sends `EXIT_ACK`;
   the gate zeroes protocol state, closes FD 3, and exits.

Each receive uses a fixed data/control buffer. Both peers reject truncation,
ancillary data other than exactly one expected `SCM_CREDENTIALS`, every
`SCM_RIGHTS`, wrong receiver-relative credentials, version, operation,
binding/listener/artifact digest, nonce, deadline, type, order, replay,
duplicate, or trailing byte. Durable evidence contains only the redacted event
list and `transcript_verified=true`, never raw frames, nonce material, or the
in-memory transcript digest.

EOF/POLLHUP, controller, supervisor, broker-worker, conmon, or gate death,
timeout, missing ACK/CANDIDATE_STOPPED/ACTIVATE_ACK/EXIT/EXIT_ACK, identity drift, or any bad frame makes gate
PID 1 exit and the kernel terminate every remaining process in its PID
namespace. The stopped admission child cannot inherit FD 3, token mappings, or
gate control state. Before committing `candidate_stopped` or `active`, the
supervisor validates the gate's authenticated fixed-schema report and binds a
live pidfd for the reported distinct PID/start, expected admission-shim and
target-CLI identities/argv, empty authority state, absent secret mappings and
FD 3, and synchronous stopped state while the gate retains its one bound
endpoint. Work begins only after the durable activation and matching
`ACTIVATE`/`ACTIVATE_ACK`. This post-secret proof uses
the authenticated gate, kernel credentials, and pidfd liveness rather than an
external same-service `/proc` read. Every endpoint reference must be absent
after normal or failed gate, container, and conmon exit.

### 8. Make namespace isolation an observable security property

The positive oracle releases the exact agent in the exact bound pod and proves
that it can reach only the gate's fixed request socket. The gate reaches the
transferred listener over that pod's loopback, presents the expiring
per-invocation non-provider token, and returns one bounded broker response with
no authorization material while provider DNS, TLS, and credential use remain
host-side. A candidate direct-to-listener request is denied.

The negative oracle is a separately bound, non-operational `isolation-probe`
invocation completed before any operational token or provider credential is
armed. Its broker exposes only the fixed health operation and cannot open a
provider connection. The probe starts the intended test pod and a second
`--network none` and `--userns=auto:size=65536` pod with separately allocated,
nonoverlapping subordinate maps and distinct user and network namespaces. The
second trusted gate brings `lo` up, reads back the interface flags, route table,
namespace identity, and `SO_NETNS_COOKIE` result, and first proves an ordinary
loopback self-connect against a test listener in that second namespace. Both
probe processes receive the same public synthetic probe nonce, invocation
metadata, address, and port. That nonce is destroyed with the probe receipt and
is never accepted by an operational listener; the later operational token is
delivered only to the trusted worker and gate through the control protocols
above and remains candidate-inaccessible.

A no-listener trial may observe connection refusal. A separate decoy-listener
trial deliberately binds the same numeric loopback address and port in the
second namespace and must self-connect to that decoy; it must not complete the
bound broker protocol or produce a provider effect. Thus TCP success or failure
alone is never the oracle. Success is the correlated host-broker record for the
exact listener, namespace, operation, token digest, and bounded request. Both
negative trials require unchanged probe-broker accept/request counters, no
provider capability or call, and no completion receipt for the foreign
namespace.

The test also proves that neither pod can reach a DNS resolver, provider or
forge origin, Git remote, registry/package origin, NATS, proxy, host, bridge,
published port, or gateway address. Separate positive tests prove that only the
bounded host broker, resolver, prefetcher, and forge adapter can perform their
manifest-selected effects. Token secrecy is defense in depth; exact namespace
membership is the broker reachability boundary.

### 9. Clean up exact effects and retire the receipt last

Every success, failure, timeout, cancellation, restart, and signal path enters
the same bounded cleanup state machine. Before and after each Podman operation,
cleanup revalidates the replaceable endpoint session and stable store tuple. It:

1. closes the supervisor-owned gate control, namespace, and other descriptors
   when present, invalidates the per-invocation broker token, sends the bounded
   `BROKER_STOP` when the worker is live, and otherwise durably commits the stop
   escalation and asks the manager to apply only the exact `STOP_ACTOR` operation;
   the supervisor-held pidfd remains identity/wait evidence and never becomes
   cross-UID signal authority. The worker closes its sole listener before acknowledging
   stop. Cleanup waits for and proves the broker worker and every descendant
   absent and proves its accepted, provider, credential, lifeline, and listener
   descriptors closed;
2. waits one bounded interval for gate PID 1 to process EOF/HUP and reap the
   candidate. If the gate or another container actor is wedged, cleanup commits
   the exact stop phase and uses only the fixed `STOP_REMOVE` pod-owner operation
   for the receipt-bound container/pod/cgroup. A wedged distinct-UID host actor
   uses only `STOP_ACTOR`; an unprivileged controller never treats pidfd possession
   as cross-UID signal authority. Held or same-boot freshly reacquired and fully
   revalidated pidfds authorize identity/wait readback; direct pidfd signaling is
   limited to an exact same-UID process for which ordinary `kill(2)` permission
   is independently proved;
3. only after those processes are absent, independently proves every FD3,
   listener, accepted, provider, credential, lifeline, and namespace descriptor
   closed in all bound and same-service process tables;
4. stops and removes only the exact bound container and pod/infra objects after
   full identity, inspect, pod, map, mount, label, store, and authority readback;
5. destroys container tmpfs state, reconciles and removes only the exact bound
   host staging and quarantine trees through no-follow ownership checks, and
   proves provider, broker-token, nonce, Git, and signing bytes are absent. A
   validated `stage-result` and, when authorized, session-state archive move to
   their bound content-addressed stores before quarantine removal and remain
   only for the manifest retention window; failed, partial, over-limit, stderr,
   decode, and temporary archive generations are erased. OCI/conmon logging is
   disabled and cleanup proves no raw stdout/stderr copy, spool, or rotated log
   exists;
6. keeps session provider authority closed, then uses only a separately bound
   host reconciler to classify every issued or uncertain provider request and
   every other manifest-bound remote effect by independent readback, without
   inventing, silently retrying, rolling back, or automatically deleting it; and
7. records terminal success or truthful failure, commits
   `lease_release_armed`, obtains complete fixed-manager reconciliation, commits
   `lease_released`, and obtains two bounded empty
   readbacks for every exact process, descriptor, container, pod, staging, and
   authority object before the manager tombstones the lease and the controller
   retires live authority while retaining the terminal
   receipt and permanent replay tombstone.

After a boot-ID change or identity mismatch, cleanup never signals a numeric
PID. A name alone, label without the receipt, changed store, reused PID, changed
digest/map/namespace, or transient store is insufficient removal authority.
Such a mismatch preserves the receipt and reports the blocker. Live authority is
the last removable state; the immutable terminal receipt or its atomic permanent
tombstone remains the replay barrier. A log or attempted command is never
terminal evidence.

### 10. Separate portable tests from authoritative Linux proof

Portable tests use controlled fake Podman and syscall boundaries to cover phase
compare-and-swap, full-binding preservation, descriptor and frame validation,
hostile inputs, timeouts, PID/boot decisions, map decisions, cleanup order,
unknown-kind denial, manifest/effect validation, adapter idempotency, and every
forbidden fallback. Exact-base fixtures first prove the current Claude/GitHub
mounts, host-selected standalone Claude executable mount/mutable fallback,
world-readable mutation, API-key injection, keep-id, bridge network, and
candidate-side Git/GitHub prompts, so removal tests cannot pass against an
invented broker baseline. Portable tests label unavailable Linux primitives as
skipped or unsupported, never successful isolation.

Authoritative exact-head CI runs on Linux with real rootless Podman. It proves:

- `lease_prepared`/`lease_bound`/`lease_activated` and release phases reconcile
  the authoritative receipt with the manager allocation journal across every
  crash edge. Same-UID impostors, stale/concurrent callers, wrong controller
  executable/cgroup/LSM identity, actor, lease, generation, commit, descriptor,
  path, argv, environment, UID, policy, PID, or signal are denied. The manager's
  LSM/capability/seccomp/network/filesystem readbacks prove it cannot inspect
  worker memory/FDs or open provider, forge, signing, session, prompt, or primary
  receipt stores while exact `STOP_ACTOR` remains functional;
- source prefetcher, dependency resolver, and session-state service run only as
  distinct one-operation fixed actors with exact parent/UID/GID/executable/
  LSM/seccomp/cgroup/lifeline/ledger bindings. Wrong origins or stores, a
  networked session-state actor, credential/key access before durable intent,
  death, ambiguous response, restart, replay, generation drift, and partial
  cleanup cannot duplicate an effect or leave a credential, key, process, or
  store handle live;
- every closed `POD_OP` is exercised with hostile extra/wrong descriptors and
  fields. `IMPORT_IMAGE` verifies a canonical digest-bound OCI archive into the
  otherwise empty fresh graph root before `CREATE_POD`; corrupt/config/layer/
  digest/store/ownership drift fails, and `RUN_GATE` can use only that local
  digest with `--pull=never`. The controller has no Podman socket or direct
  graph-root/`runRoot` access;
- the selected `auto:size=65536` mode, bound subordinate ranges, complete
  allocated/actual map equality, absence of the service host UID/GID, exact
  read-only image and size-bounded container-private tmpfs mounts, owner-only
  no-follow input/output staging, stable store identity, endpoint rotation with
  the same store, and rejection of a changed store, map, driver, rootless state,
  service-ID mapping, any host workspace/state bind or ownership-shifting mount,
  or transient store;
- real user/net namespace entry, NSFS identity, `NS_GET_USERNS` owner matching,
  loopback activation, and mandatory `SO_NETNS_COOKIE` matching when supported,
  including fatal non-unsupported option failures;
- `O_CLOEXEC`, `SOCK_CLOEXEC`, `accept4(SOCK_CLOEXEC)`, and
  `MSG_CMSG_CLOEXEC` on every descriptor path, plus bounded-frame rejection of
  truncation, oversize, duplicate/unknown ancillary data, multiple descriptors,
  and FD leaks on every failure;
- authenticated post-drop UID/GID, empty supplementary groups, capability,
  `no_new_privs`, thread, descendant, FD, parent-death, and deadline barriers;
  both `/proc/self/setgroups=allow` and `deny` branches prove the group vector is
  empty without requiring a forbidden syscall;
  the gate's fixed in-namespace status readback reports an empty `Groups:` field
  for the candidate and every descendant, including a hostile inherited-group fixture, and those
  processes cannot read, write, connect to, or signal group-authorized
  sentinels;
- the gate remains a one-thread event loop, a kernel task-count readback proves one
  thread immediately before fork, and a hostile parser/archive/library fixture that
  creates a background thread fails closed before a child exists or work begins;
- controller, supervisor, worker, gate, source prefetcher, dependency resolver,
  session-state service, reconciler, forge adapter, and signer
  dumpability/core-limit readbacks occur before secret receipt or credential
  open; locked `MADV_DONTDUMP|MADV_DONTFORK` mappings are zeroed, their ranges
  are absent in the admission child, and hostile allocator/stack/register plus
  injected-crash fixtures leave no sentinel byte in a core, journal,
  crash-handler artifact, receipt, or file;
- direct controller and supervisor broker lifelines, parent-race-safe
  `PR_SET_PDEATHSIG`, nonblocking provider I/O, controlled `BROKER_STOP`/
  `BROKER_STOPPED`, fixed-manager `STOP_ACTOR` deadline escalation with the
  supervisor pidfd used only for identity/wait evidence, immediate accepted/
  provider/credential FD closure after bounded death detection, durable
  `provider_effect_uncertain` classification for the death/poll/provider-I/O race,
  and independent worker/descendant/FD absence proof;
- direct hostile clients bypassing the provider CLI can reach only the one
  manifest-bound, versioned operation schema. Unknown fields, adjacent API
  methods and paths, alternate models/providers, caller URLs/query/headers,
  redirects, credential-bearing fields, file/batch/fine-tune/admin operations,
  and unapproved provider-hosted or built-in tools produce no provider
  connection. Positive requests prove fixed origin/method/path/auth construction,
  closed response decoding, and exact request/quota/cost attribution. Ambient
  proxy/netrc/SDK endpoint, custom-CA, resolver, TLS, SNI, hostname, and debug
  overrides are denied; wrong-origin/certificate fixtures send no credential,
  and transport failures expose only fixed redacted errors. Aggregate
  request/token/cost reservations reject a request that could exceed any
  ceiling; concurrent, crash, lost-response, restart, duplicate, and stale-
  generation fixtures prove reservations cannot be double-spent or silently
  refunded;
- atomic cutover with mutually exclusive direct and isolated specifications;
  negative inspect and live process/mount/environment/FD checks prove no
  provider/GitHub config, credential, API key, reusable token, SSH/credential
  socket, world-readable sensitive config/session/log/cache object, or
  bridge/host route remains. A complete no-follow inventory covers every legacy
  chmod path and type, including non-credential files and directories; symlink,
  owner/type/mode drift, and unenumerable historical targets stop for reviewed
  disposition. Every legacy-exposed provider and forge/GitHub identity is
  revoked or rotated before fresh identities are armed; copied/reused old-token
  attempts and a crash between revoke and fresh arming remain denied;
- host prefetch and bounded resolution produce canonical digest-bound archives,
  the waiting gate independently decodes them into private tmpfs, output crosses
  only through a separately verified canonical archive and owner-only quarantine,
  launch uses `--pull=never`, a lock change forces a new authorized resolver and
  session, and the candidate cannot reach DNS, provider, forge, Git,
  registry/package, NATS, proxy, bridge, gateway, or host endpoints. Aggregate
  object/file/member/dependency counts and encoded/expanded bytes, path and tree/
  symlink depths, expansion ratio, and per-store/combined capacities fail before
  allocation or write; small-object floods, deep trees, overlong paths, integer
  overflow, sparse files, and decompression bombs leave no partial generation;
- one- and multi-repository fixtures verify independent origin/commit/tree/
  gitlink closures, ordered `REPOS_FILTER` selection, namespaced paths, per-repo
  transitions and PR receipts, and separately authorized meta-repository
  integration. Missing/drifted/extra repos, colliding paths, reordered filters,
  cross-repo base/head/pin TOCTOU, partial fan-out, and premature fan-in stop
  without a broad submodule or integration effect;
- every legacy stage, including resumed turns, receives only validated ordered
  `hi.prompt-payload/v1` records over the fixed non-shell prompt input. Hostile
  closing markers, nesting, controls, bidi text, invalid UTF-8, length/digest
  mismatch, truncation, argv/environment/log injection, and prior-stage output
  remain inert and cannot widen authority;
- manifest-bound host forge effects succeed only for the exact repository,
  issue, base/head, allowed branch/path transition, signed commit, PR, and required
  review/CI state. Hostile fixtures cover nested `.git`, config includes,
  alternates, hooks, attributes filters, textconv/diff/merge drivers,
  `.gitmodules`, LFS/submodules, remote helpers and `ext::`, URL rewrites,
  credential helpers, askpass, `core.sshCommand`, SSH/proxy/Git environment, and
  signer overrides. Candidate titles, bodies, author fields, and messages with
  closing keywords, mentions, slash/chatops commands, task directives, links,
  controls, or bidi characters remain inert and cause no bot, workflow,
  notification, or issue-state effect unless that exact secondary effect is
  manifest-bound and read back. Wrong/stale/foreign/protected refs,
  candidate-requested effects, force/delete operations, duplicate retries, and
  premature completion are denied and truthfully receipted. Protected-path
  fixtures reject missing, prompt-supplied, spoofed-actor, broad, stale-head,
  expired, wrong-path/type, and prior/proposed-content-drift approvals; accepted
  ADR bodies remain immutable and meta gitlinks require the separate integration
  authority. Wrong forge/Git
  origin, method/path, redirect, resolver, CA, TLS peer, SNI, or hostname
  fixtures prove no credential byte is sent;
- output-transition tests require exactly one present/deleted record for every
  bound allowed path and reconstruct the exact result from the immutable input
  tree. Deletion succeeds only through an explicit tombstone; rename succeeds
  only as a bound delete+add. Omission, duplicate/conflicting state, unknown
  path, missing/extra present bytes, bytes for a deleted record, type/mode/digest
  drift, and truncated archive fail before commit construction;
- merge authority tests reject a spoofed, malformed, stale, foreign, or
  wrong-actor carrier; a carrier without its publication anchor; an invalid or
  forked carrier/author-event chain; any pending authority event or open review
  thread; a stale or conflicting GO/NO-GO label; and a required check from the
  wrong app or head. Admission atomically creates one immutable, single-use
  `merge_authorized` receipt from that complete pre-admission snapshot. Reuse or
  a second authority event is denied. A head mutation after review or queue
  admission—including a write-authorized push that can leave ordinary
  auto-merge enabled—cancels authority and starts a new review exchange; a base
  advance is equally fatal. Mutable metadata is not claimed as an atomic
  post-admission predicate; a policy requiring later-event revocation needs a
  repository-enforced trusted gate or stops for human merge. The positive path
  revalidates the receipt, source head, base tip, and expected-app checks before
  admitting that exact pair to a queue or merge group; required checks run on
  the bound merge result. A repository with no atomic source-and-base primitive
  stops for human action. Independent post-merge readback must match the
  admitted pair, merge result, expected commit, parents, tree, PR, and receipts;
- exact local Podman/crun `podman run --preserve-fds=1` passes only the socketpair
  gate end as FD 3. A separate authenticated `BROKER_LISTENER`/SCM_RIGHTS/
  `BROKER_LISTENER_BOUND` test proves exactly one validated listener transfers
  from launcher through supervisor to the worker, every rejected/extra FD
  closes, and the worker is sole holder before admission. Exact-version start-
  helper, Podman, transient-runtime, conmon, gate, worker, and supervisor
  FD-table tests prove the declared intermediary closes,
  the optional conmon duplicate exists only for public `HELLO`, and exactly the
  supervisor and gate endpoints remain before `ARM`. Remote/API/Docker/
  create-start paths, a conmon duplicate at secret phase, and missing, swapped,
  extra, dual-ended, or unknown-holder FDs fail closed;
- HELLO/ARM/READY/RELEASE/ACK/CANDIDATE_STOPPED/ACTIVATE/ACTIVATE_ACK/EXIT/
  EXIT_ACK tests reject wrong or translated
  receiver-relative kernel credentials, unexpected overflow IDs, wrong version,
  operation, full-binding/listener/artifact digest, nonce, deadline, order,
  replay, duplicate, truncation, ancillary data, `SCM_RIGHTS`, EOF, and
  controller/supervisor/broker-worker/conmon/gate death. FD 3 and control state
  are absent from the candidate, while the trusted gate retains its declared end;
- token-provisioning tests prove kernel generation occurs only after the exact
  listener binding; `BROKER_ARM` and FD3 `ARM` carry the same secret once over
  their authenticated channels; `secret_fd_topology_bound` proves conmon cannot
  observe FD3 `ARM`; the gate alone creates the no-follow owner-only file; broker
  admission stays disabled until `gate_bound`; the candidate is denied read,
  link, rename, and traversal access to the file and can use only the bounded
  gate HTTP endpoint. Wrong listener/operation/binding/deadline, duplicate or replayed
  arm/enable frames, archive/env/argv injection, retained conmon FD, peer crash,
  and later-invocation reuse fail closed and leave no token bytes after cleanup;
- durable receipt/log/generic-artifact tests prove the absence of raw frames, ancillary
  buffers, nonce or verifier material, broker tokens, provider credentials and
  raw upstream request/response/error bodies, signing material,
  secret-bearing environment, and raw OCI stdout/stderr. Separate tests prove
  that only closed, bounded `stage-result` and session-state artifacts may retain
  validated-but-untrusted content, and that receipts retain only their
  type/length/digest/CAS identities plus the specified redacted event-list
  digest. Retention/CAS and terminal erasure tests prove failed/partial/tmp
  archives, stderr and OCI/conmon logs are absent while only the authorized
  validated stage/session generations survive for their bound window;
- the candidate cannot exec the CLI, read its prompt, mutate the workspace, or
  request before `candidate_stopped`, the one durable `active` commit, and the
  exact matching activation exchange. Early continue, wrong commit, duplicate
  activation, pre-exec crash, and exec failure produce no work or provider
  effect. A separate non-operational `isolation-probe` gives two probe pods the
  same public synthetic health-only nonce; the second pod proves loopback is up and
  self-connects to its own listener at the same numeric address/port, but both
  its no-listener and decoy trials leave probe-broker counters unchanged and
  have no provider capability. The synthetic nonce is destroyed before the
  operational token is generated, and the latter remains observable only to
  the supervisor, worker, and gate;
- controller, session-supervisor, broker-worker, conmon, and gate crash/death
  injection at every phase proves listener and broker-authority closure,
  PID-namespace descendant termination, and no listener recreation, gate
  release, candidate resume, restart, or rerun. A pre-issue death proves no
  provider request; a death after issue but before independent observation
  yields `provider_effect_uncertain`, is reconciled without automatic replay,
  and cannot produce a completion claim;
- same-boot PID reuse rejection and safe pidfd reacquisition, boot-ID change
  with no numeric-PID signal, exact cleanup, and receipt-last authority
  retirement. Same-operation replay after cleanup or restart resolves only to
  the immutable terminal receipt or permanent consumed-operation tombstone and
  creates no new local or remote effect; missing/corrupt barrier state fails
  closed.

CI does not require Tailscale because the design has no routable listener.
Tailscale unavailability on a local host is neither success nor failure evidence
for this boundary. Formal acceptance still is not implementation completion:
implementation requires its own reviewed change, green exact-head Linux CI, and
truthful runtime evidence for every applicable boundary above.

### 11. Keep a sidecar outside the selected design

A digest-pinned broker sidecar is not the default selected here. If the fixed
launcher path proves infeasible, a later proposal may choose a sidecar only
with separate exact image, secret, network, process, storage, restart, crash,
cleanup, and receipt authority for the sidecar's full lifecycle. It may not be
introduced as an unreviewed fallback from a launcher failure.

## Consequences

**Positive:**

- Provider and forge credentials move out of the candidate and remain host-side
  after the separately reviewed cutover, while the broker listener is
  reachable only from the exact agent pod network namespace.
- The candidate cannot copy the gate-owned per-invocation broker token; a
  public probe value or fabricated token in another pod cannot reach the broker.
- Immutable prefetch plus bounded host delivery preserves required repository,
  dependency, and forge effects without giving the candidate general egress.
- Durable, monotonic authority makes crash recovery and exact cleanup
  reviewable rather than relying on names or best-effort teardown.
- The selected design adds no routable listener and needs no Tailscale or
  bridge-network exception.

**Negative:**

- The path is Linux/rootless-Podman specific and requires careful namespace,
  descriptor-passing, UID/GID-map, and crash-recovery implementation.
- Real security proof requires a Linux CI runner capable of rootless Podman;
  portable local tests alone cannot satisfy it.
- Each additional lifecycle phase expands the reconciliation and failure-test
  matrix while the legacy harnesses remain supported.
- Owner-only archive staging, quarantine, a trusted PID 1 gate, explicit conmon
  accounting, and an isolated forge/signing path add local storage and process
  lifecycle complexity.

**Neutral:**

- This governance change does not implement the new broker, move a live
  credential, alter current runtime/provider/model/lane/role defaults, change
  agent task or result schemas, or retire either legacy harness.
- If formally accepted, the design requires a new bounded host provider broker,
  host resolver, and forge/delivery adapter plus a separately approved atomic
  cutover; none exists merely because this ADR is merged.
- A digest-pinned sidecar remains a possible future decision, not an automatic
  fallback.

## References

- [Proposed ADR 020](020-mesh-distributed-hephaestus-loop.md) — mesh proof and
  legacy-harness retirement boundary
- [Proposed ADR 022](022-layered-provider-neutral-agent-instructions.md) —
  authority, completion, and protected-boundary contract
- [Current single-harness credential, network, and mount path](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/e2e/claude-myrmidon.py#L225-L273)
- [Current single-harness `claude-host` argv and stdout result path](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/e2e/claude-myrmidon.py#L276-L315)
- [Current multi-harness credential, network, and mount path](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/e2e/claude-myrmidon-multi.py#L248-L317)
- [Current multi-harness session/resume argv and stdout result path](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/e2e/claude-myrmidon-multi.py#L331-L388)
- [Current multi-harness repository inventory and ordered `REPOS_FILTER`](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/e2e/claude-myrmidon-multi.py#L104-L188)
- [Current multi-harness repository fan-out](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/e2e/claude-myrmidon-multi.py#L541-L595)
- [Current multi-harness fan-in and meta-repository ship path](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/e2e/claude-myrmidon-multi.py#L962-L1015)
- [Current single-harness candidate-side ship effects](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/e2e/claude-myrmidon.py#L710-L740)
- [Current multi-harness candidate-side ship effects](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/e2e/claude-myrmidon-multi.py#L920-L949)
- [`network_namespaces(7)`](https://man7.org/linux/man-pages/man7/network_namespaces.7.html)
- [`setns(2)`](https://man7.org/linux/man-pages/man2/setns.2.html)
- [`ioctl_ns(2)` and `NS_GET_USERNS`](https://man7.org/linux/man-pages/man2/ioctl_nsfs.2.html)
- [`pidfd_open(2)`](https://man7.org/linux/man-pages/man2/pidfd_open.2.html)
- [`pidfd_send_signal(2)`](https://man7.org/linux/man-pages/man2/pidfd_send_signal.2.html)
- [`proc_pid_stat(5)` start time](https://man7.org/linux/man-pages/man5/proc_pid_stat.5.html)
- [`prctl(2)`](https://man7.org/linux/man-pages/man2/prctl.2.html)
- [`PR_SET_PDEATHSIG(2const)`](https://man7.org/linux/man-pages/man2/PR_SET_PDEATHSIG.2const.html)
- [`capabilities(7)`](https://man7.org/linux/man-pages/man7/capabilities.7.html)
- [`setgroups(2)`](https://man7.org/linux/man-pages/man2/setgroups.2.html)
- [`proc_pid_status(5)`](https://man7.org/linux/man-pages/man5/proc_pid_status.5.html)
- [`seccomp(2)`](https://man7.org/linux/man-pages/man2/seccomp.2.html)
- [`unix(7)`](https://man7.org/linux/man-pages/man7/unix.7.html)
- [`cmsg(3)`](https://man7.org/linux/man-pages/man3/cmsg.3.html)
- [`recvmsg(2)`](https://man7.org/linux/man-pages/man2/recvmsg.2.html)
- [Podman pod networking](https://docs.podman.io/en/latest/markdown/podman-pod-create.1.html)
- [Podman run `--preserve-fds`](https://docs.podman.io/en/latest/markdown/podman-run.1.html#--preserve-fds-n)
- [Podman run user namespaces, mounts, and tmpfs](https://docs.podman.io/en/latest/markdown/podman-run.1.html)
- [Podman copy](https://docs.podman.io/en/latest/markdown/podman-cp.1.html)
- [`user_namespaces(7)`](https://man7.org/linux/man-pages/man7/user_namespaces.7.html)
- [Git attributes, filters, and text conversion](https://git-scm.com/docs/gitattributes)
- [Git hooks](https://git-scm.com/docs/githooks)
- [Git configuration and includes](https://git-scm.com/docs/git-config)
- [Git credential helpers](https://git-scm.com/docs/gitcredentials)
- [Git remote helpers and `ext::`](https://git-scm.com/docs/gitremote-helpers)
- [GitHub automatic merge behavior](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/automatically-merging-a-pull-request)
- [GitHub pull-request merge API and expected head SHA](https://docs.github.com/en/rest/pulls/pulls#merge-a-pull-request)
