# ADR 024: One Homeric NATS Application Account with Per-Role Authorization

**Status:** Proposed

> **Proposal status:** This ADR does not change checked-in configuration,
> server versions, or deployed state. Acceptance authorizes a separate,
> operator-approved implementation; merge alone does not.

**If accepted, supersedes:** the conflicting transport-ownership and
all-inter-component-traffic clauses of Accepted
[ADR-006](006-decouple-from-ai-maestro.md), while preserving its migration away
from ai-maestro; and only the conflicting portions of Proposed
[ADR-009](009-nats-authentication.md) Decision 3 and Proposed
[ADR-010](010-nats-mtls-subject-scoped-auth.md) Decision 3, as bounded in
[Relationship to earlier proposals](#relationship-to-earlier-proposals).

---

## Context

Accepted [ADR-002](002-nats-event-bridge.md) requires one Hermes publication
to fan out to multiple services, with durable replay for an offline consumer.
Accepted [ADR-005](005-nats-subject-schema.md) fixes the `hi.agents.>` and
`hi.tasks.>` subject families, the `homeric-agents` and `homeric-tasks`
streams, and the `keystone-dag` durable consumer name.

Those accepted interfaces are not the whole current runtime inventory. The
exact gitlinks also contain a Hermes-owned durable dead-letter stream,
Agamemnon and Nestor streams for current myrmidon, research, pipeline, and log
traffic, Argus observability consumers, and named durable consumers owned by
the still-live legacy harnesses. Omitting any of them from migration authority
or recovery evidence could silently discard stored messages, delivery state,
or retry behavior.

The checked-in client listeners place Hermes, agents, Keystone, and Telemachy
in four isolated accounts on both hub and spoke. Identical application subjects
do not cross those account boundaries without an operator-authored
application-subject export and matching import, and JetStream state remains
account-owned.

The checked-in leaf configuration does not establish four matching end-to-end
account bindings. Its `account` field selects only the spoke-local account. The
hub leaf listener uses one user/password authorization block with no account
binding, so any connection accepted with that credential is registered in the
hub global account `$G`, not in the same-named hub account. After authentication
syntax is repaired, the present shape would therefore connect each isolated
spoke-local account to hub `$G` while leaving the hub's named application users
outside that subject space; it still would not form the accepted shared
application bus.

Before any connection can reach that asymmetric state, v2.10.22 rejects the
quoted scalar `token` field in every spoke remote as an unknown field. The
checked-in CI installs v2.10.22 but invokes `nats-server -t` only for
`server.conf`; the repository Python validator checks delimiters rather than
the NATS schema, so neither gate detects the broken `leaf.conf`. Other
executable test and launch surfaces include v2.10.24, a digest-pinned
`nats:2.10` image, mutable image tags, and ambient `nats-server` binaries.

Those old versions also predate later security fixes. CVE-2026-33222, in which
a user with narrowly scoped stream-restore permission could restore under other
stream names, was fixed in v2.11.15 and v2.12.6. For CVE-2026-58254, the
canonical NATS security note says that v2.12.11 and below are affected and
v2.12.12 is fixed, while the official GitHub advisory says v2.12.7 and below
are affected and v2.12.8 is fixed. Both name v2.14.3 as the v2.14 fix. This ADR
uses v2.12.12 only as the conservative historical regression floor; the
conflict itself requires a fresh advisory review rather than interpolation.
A single linear version comparison would also admit known-vulnerable v2.14.0
through v2.14.2.

## Decision

If this ADR is formally accepted, the HomericIntelligence NATS topology will
use one application account named `HOMERIC`, one separate system account named
`SYS`, and one hub-owned JetStream domain.

### 1. Require a branch-safe, immutable server pin first

Before changing accounts, granting snapshot or restore authority, or migrating
data, the selected exact NATS release must satisfy all of these conditions:

- it is a stable release in a minor series that the vendor supports at
  implementation time under the nats-server current-and-previous-minor policy;
- a fresh review covers every official NATS security advisory published at
  that time, including amended or conflicting records, and records that the
  exact release is not affected;
- a fresh review covers every upgrade note between the deployed release and
  the candidate, including JetStream snapshot/archive compatibility, leaf
  behavior, account behavior, and rollback constraints; and
- the exact binary or image digest, release signature, advisory-set digest,
  upgrade-review digest, and review date are bound in the migration manifest.

A prerelease, unsupported minor series, unreviewed exact patch, mutable tag, or
release with an unresolved advisory is rejected. At this ADR's 2026-09-18
inventory date, the v2.12 series is outside the supported window and cannot be
a migration candidate. The v2.12.12 record is only a conservative historical
security-floor test. Likewise, v2.14.3 is only the historical floor for the
v2.14 CVE-2026-58254 branch; it is not an evergreen approval for that exact
patch or minor series. If official records disagree, the implementation uses
the more conservative affected range and does not select the release until the
complete current review resolves the candidate.

Passing these conditions makes one exact release eligible, not selected for
all future time. The implementation binds one exact stable server build and
digest, then runs that identical build on every hub and spoke. Mixed-version
operation is not an accepted migration state.

Before the first production binary replacement, the operator quiesces each
JetStream store, stops every old server, and proves every client/server process,
writable store descriptor, mapping, and autonomous restart absent before
creating a pre-upgrade recovery point bound to the old and
candidate release digests, complete live state, canonical no-follow store
identity, and byte/tree digest. The implementation must then prove one of two
rollback authorities on a disposable exact copy: either the vendor-supported
on-disk transition is bidirectional and the old binary reopens candidate-touched
state with complete state equality, or an immutable pre-upgrade store backup is
restored to a separately allocated store and the old binary reproduces the
captured state. The backup follows section 6's confidentiality, integrity,
reader, capacity, retention, and verified-deletion controls. If neither exact
downgrade nor restore rehearsal passes, no production binary is replaced. A
candidate-touched production store is never called rollback-safe merely because
the old executable still starts.

The version upgrade is a separate all-node downtime transaction. Before
replacing any binary, the operator quiesces all affected application traffic,
captures live state and rendered configuration, approves the maintenance
window, disables the hub leaf listener and every spoke remote, stops every old
server, and proves zero server/client/leaf/route session and zero writable store
handle. It stages and verifies the same candidate digest for every node, then
starts the complete candidate set with leafs and routes still disabled. If any
node, store, parser, client, or restart check fails, the operator stops every
candidate node, proves their handles absent, restores every old store/config/
binary from the recovery point, and starts the complete old set. Mixed-version
or staggered service, and the former alternative that temporarily connected
same-named old accounts with ambiguous default JetStream domains, are forbidden.

No intermediate syntax repair may create a connection to an account-unbound
hub listener or `$G`. Only after the identical candidate build passes on every
node may the separately rendered target leaf configuration be evaluated under
the migration gates below. A syntax-only `token`-to-user/password repair is not
an accepted phase. No node may continue in an asymmetric, partially repaired,
or candidate-mutated-but-unverified state.

Only after this version phase proves restart, client, permitted leaf, and
JetStream compatibility may topology migration begin. Live readbacks must show
the selected patched build on every node and the selected intermediate mode's
account invariants. The implementation PR records the exact image or binary
digest and the signed review records. Version-gate tests reject the checked-in
v2.10.22 and v2.10.24 executables, every v2.12 candidate (including the
historical v2.12.12 floor), v2.14.0 through v2.14.2, prereleases, mutable tags,
unsupported series, and any exact release absent from the current signed
review manifest. Tests preserve v2.12.12 and v2.14.3 as branch-specific
historical floor cases without treating either as currently selectable.
Runtime readback must match the selected exact digest, not merely a semantic
version that passes a numeric comparison. NATS `INFO` does not attest executable
bytes. A privileged local verifier independently binds each live server ID,
boot/PID/start, `/proc/<pid>/exe` or immutable container-image/config digest,
binary hash, rendered-config hash, listening endpoint, and authenticated TLS
session. Migration helpers accept that server ID only while this attestation is
current; a self-reported version or image tag is insufficient.

The checked-in executable inventory at this binding is:

| Surface | Current executable selection | Migration disposition |
|---|---|---|
| `.github/workflows/ci.yml` | Downloads v2.10.22 but parses only `server.conf`; it does not expose the rejected scalar `token` in `leaf.conf` | Keep as a hub-parser and exact defect-version fixture only until a separately approved workflow change validates both rendered configs with the reviewed release. It cannot provide migration evidence. |
| `.github/workflows/e2e-reliability.yml` | Executable E2E downloads v2.10.24 | Replace through a separately approved workflow change; migration evidence must run the reviewed exact digest. |
| `e2e/single-container/Dockerfile` | Downloads v2.10.24 | Replace with the same reviewed exact build and verify its digest before execution. |
| `docker-compose.e2e.yml` | `nats:2.10` plus an exact image digest | Rebind tag and digest to the reviewed release; the old digest remains regression evidence only. |
| `e2e/docker-compose.cluster.yml` | Node one inherits the E2E image; nodes two and three use `nats:latest` | Remove the mutable tags and bind all three nodes to the same reviewed digest. |
| `justfile` `start-nats` | Launches mutable `nats:alpine` | Bind the recipe to the same reviewed digest before it can contribute runtime or migration evidence. |
| `e2e/start-hermes-hub.sh` | Fallback launches mutable `nats:alpine` | Remove or bind the fallback before it can contribute evidence. |
| `e2e/lib/process.sh` and `e2e/topologies/t2-tmux.sh` | Execute ambient `nats-server` from `PATH` | Resolve, hash, and compare the executable with the reviewed manifest before launch. |

An implementation-time hidden/tracked/loader/generator/test and organization
consumer search must repeat this inventory and classify every additional
server executable or image before the first upgrade. Documentation examples do
not select a release and cannot substitute for executable readback.

The same freeze applies to every NATS client, because API, inbox, reconnect,
drain, delivery, and ACK subjects are client-version behavior. The manifest
binds each application gitlink, built binary or image digest, client library
source/artifact digest, complete dependency lock, and rendered connection
configuration. At this inventory, Agamemnon's nats.c dependency is an immutable
commit; Nestor and Keystone use shallow mutable tags; the Loki bridge and
single-container path install unversioned nats-py; the host legacy harnesses use
ambient nats-py; and no tag, range, ambient install, or version-only package is
accepted evidence. Hermes' lock, Telemachy's hash-bound wheel, and Atlas's
Go module sum remain candidates only after their built artifacts are also
bound. Every nats.c tag is resolved to and built from an immutable commit.
Scylla, AchaeanFleet/Myrmidons workers, and any newly found consumer are included
or explicitly retired. Exact runtime traces and ACLs are frozen only from these
bound artifacts; changing one requires a new trace and manifest.

### 2. Preserve and classify the exact-pinned live inventory

`HOMERIC` is the single subject space for application traffic. It contains the
accepted `hi.agents.>` and `hi.tasks.>` subjects, the `homeric-agents` and
`homeric-tasks` streams, and the `keystone-dag` durable consumer. This decision
does not rename those interfaces or change their retention, delivery, replay,
or at-least-once semantics.

The exact-pinned Keystone source also contains two incompatible runtime paths
that are not additional accepted contracts. Its task listener defaults a
configuration field to `keystone-daemon`, while its transparent agent bridge
defaults another field to `keystone-bridge`; neither path copies that field into
the `jsSubOptions` passed to `js_Subscribe`. They therefore request
server-assigned consumers rather than either configured durable. The task
parser also accepts any subject with at least five tokens without verifying the
`hi.tasks` prefix or rejecting suffix tokens, so a foreign prefix or
`hi.tasks.team.task.completed.extra` can invoke the callback and be
acknowledged. It also treats `created`, `assigned`, and `started` as known task
verbs and acknowledges them even though Accepted ADR-005 permits only
`updated`, `completed`, and `failed`. The bridge also publishes
`hi.agents.<receiver_id>`, which does not by itself satisfy the
accepted `hi.agents.{host}.{name}.{verb}` lifecycle-event shape. More
fundamentally, Accepted ADR-002 reserves point-to-point agent messaging to AMP
and NATS to infrastructure event fan-out. Hermes publishes JSON lifecycle
envelopes on `hi.agents.>`, while the bridge interprets every matching payload
as a binary Cista `KeystoneMessage`; each format is poison to the other role.
The bridge's inbound loop then calls `MessageBus::routeMessage`; for a receiver
that is not local, that method invokes the same outbound NATS publisher.
Despite the in-source comment that this avoids re-publication, an off-host
delivery can therefore be re-ingested and published again, and multiple
wildcard bridges can amplify it. Finally, `attach()` registers the outbound
publisher before it proves the inbound subscription and thread, leaves that
publisher registered on failure, and the daemon continues after the reported
failure. These are cutover-blocking source and live-state reconciliation
defects, not authority to rename `keystone-dag`, silently register
`keystone-bridge`, or repurpose the accepted event stream for agent transport.

Other current or future application subjects may share `HOMERIC` only when
their own accepted contract or exact-pinned runtime authority permits them.
This ADR does not accept a Proposed mesh contract merely by placing its
subjects in an account.

`SYS` is designated by `system_account = SYS`. It carries server/system
monitoring, server-account events, and system management. JetStream advisories
are account-scoped and remain in `HOMERIC`; they are not reclassified as `SYS`
traffic. If those advisories are retained, one local least-privilege
`HOMERIC` observer may subscribe only to the exact selected-release JetStream
advisory subjects and publish no application or management request. Application
clients do not connect through `SYS`, and `SYS` is not a back door to `hi.>`
traffic. The target admits no anonymous or account-unbound application or leaf
session into `$G`; the current account-unbound hub leaf behavior is a defect,
not a target invariant.

The repository inventory for this decision is bound to Hermes
`c89b52ae41f69ce485d616927fd3ad32f78b8332`, Agamemnon
`bb17afd828a8c164930a30d5095e6b90241f8564`, Nestor
`6445688c1c27e3d984bde074cb7168a02856f6fa`, Argus
`59727bb5c86ae7340bc694a3ccd35c055c8df7f8`, Keystone
`7ad4d1ea163e0ae258ceef5220ebb3c91a6cdb29`, Telemachy
`4702a17f4be69b232ead7944b552f85fcc183b41`, and the Odysseus
`ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4` legacy harnesses. At those pins,
the migrate-or-retire disposition is:

Inventory keys are `(manifest node, canonical physical store identity, source
account, stream name)`, not stream name alone. Server ID, boot/PID/start, and
TLS connection identify one ephemeral session and are mapped to that stable
store key; a restart must not create a new logical object or authorize another
store. Current `HERMES` and `AGENTS` accounts can each contain independent
objects named `homeric-agents` or `homeric-tasks`; two same-named source objects
cannot both be raw-restored into one target name. Before RP0, every duplicate
instance receives an independently approved mapping: select one authoritative
owner instance and classify every record/consumer/effect in the other, or
perform a record-level deterministic merge with payload/envelope validation,
deduplication identity, source-sequence-to-target-sequence mapping, ordering and
consumer-floor/effect disposition. An incompatible or unclassifiable record
blocks migration. The target has exactly seven streams only after this mapping
proves that every source instance and record has one lossless or explicitly
reviewed terminal disposition. Each raw source RP0 remains immutable. A merge
also produces a separately approved canonical target-RP0 transform containing
the complete record/sequence/timestamp/deduplication and consumer/effect-state
mapping plus expected deltas. One-to-one restores require raw canonical
equality; merged target objects are compared to that transform, never falsely
to two independent source sequence spaces.

| Stream | Captured subjects | Exact-pinned roles and named durable consumers | Required disposition |
|---|---|---|---|
| `homeric-agents` | `hi.agents.>` | Hermes and Agamemnon currently provision or publish lifecycle events; Argus `atlas-agents` consumes; Keystone's transparent bridge puts incompatible point-to-point binary messages on the event family, consumes JSON events as if they were binary messages, can route an inbound nonlocal delivery back through its outbound publisher, and may remain outbound-active after attach failure | Migrate the stream and `atlas-agents`; reconcile and retire the Keystone bridge before cutover; any separately accepted replacement is a post-RP0 change on a distinct contract and stream; Hermes keeps semantic and manifest ownership under ADR-005 |
| `homeric-tasks` | `hi.tasks.>` | Hermes and Agamemnon currently provision or publish; Agamemnon and Telemachy subscribe; legacy harnesses publish; Accepted ADR-005 names Keystone `keystone-dag`, but the exact-pinned listener leaves its `keystone-daemon` configuration default unwired and requests a server-assigned consumer; Argus `atlas-tasks` consumes | Migrate the stream, canonical `keystone-dag`, and `atlas-tasks`; first refactor Keystone to bind `keystone-dag` explicitly and classify, drain, and retire every server-assigned listener consumer; Hermes keeps semantic and manifest ownership under ADR-005 |
| `homeric-deadletter` | `hi.deadletter.>` | Hermes provisions and publishes; no exact-pinned named durable | Migrate in full; Hermes keeps semantic and manifest ownership under the Hermes repository's Accepted dead-letter ADR-002 |
| `homeric-myrmidon` | `hi.myrmidon.>` | Agamemnon, Nestor, and both legacy harnesses currently provision or publish; Argus `atlas-myrmidon` and the legacy durable set below consume | Migrate the stream and every named durable unless the separate retirement gate below has passed; Agamemnon owns the retained manifest |
| `homeric-research` | `hi.research.>` | Agamemnon and Nestor currently provision or publish; Nestor has a core subscription; Argus `atlas-research` consumes | Migrate the full stream and `atlas-research`; Agamemnon owns the retained manifest |
| `homeric-pipeline` | `hi.pipeline.>` | Telemachy publishes epic registration; Agamemnon currently provisions and core-subscribes to that registration; Argus `atlas-pipeline` consumes | Migrate the full stream and `atlas-pipeline`; Agamemnon owns the retained manifest |
| `homeric-logs` | `hi.logs.>` | Agamemnon currently provisions and publishes; Nestor and both legacy harnesses publish; Argus `atlas-logs` consumes; Odysseus cross-host launch paths run a NATS-to-Loki consumer that creates durable `loki-bridge` | Migrate the full stream, `atlas-logs`, and `loki-bridge` unless the separate retirement gate below has passed; Agamemnon owns the retained manifest |

The source defaults are not migration authority. At these pins, Agamemnon
proposes Limits retention with 50 MiB and one-hour limits for six streams,
including the two whose accepted semantic owner is Hermes. Nestor instead
proposes WorkQueue retention for `homeric-research` and Limits retention for
`homeric-myrmidon`, without the same limits. The legacy harnesses also propose
their own limits. These reconcilers treat an existing stream as success without
proving configuration equality, so startup order can determine the live
configuration. RP0 must therefore capture the complete live objects. Hermes
owns the canonical manifests for `homeric-agents`, `homeric-tasks`, and
`homeric-deadletter`; Agamemnon owns the other four. An owner preserves the
captured object during this migration. A source default can change it only
through a separately reviewed decision.

Captured live configuration is state to reconcile, not authority to legitimize
drift. Before freeze, the helper compares every stream subject/source/mirror/
transform/republish field and every consumer filter, delivery, start, replay,
retention, and deletion field with the independently reviewed canonical owner
manifest. A live wildcard, republish, source, filter, or policy absent from that
manifest stops for an exact approved disposition; it is never restored merely
because RP0 observed it. Message bytes, sequence gaps, floors, and delivery
state are preserved or disposed separately from unexpected authority-bearing
configuration.

`homeric-research` needs an explicit pre-RP0 decision. Nestor's WorkQueue
default and an overlapping `atlas-research` consumer cannot coexist as a
fan-out observability contract: WorkQueue filters may not overlap and an Atlas
ACK can consume work. The owner must either prove the live canonical stream is
not WorkQueue, migrate to an independently approved fan-out retention manifest,
or retire/handoff the overlapping consumer with zero backlog or a complete
sequence/effect mapping. RP0 stops on a WorkQueue stream with overlapping
filters, a `DeliverAll` guess, or an unreviewed retention change.

For Accepted ADR-005 families, Hermes is the sole canonical producer and
envelope owner. Before RP0, Agamemnon and every other overlapping producer must
stop publishing `hi.agents.*` and `hi.tasks.*` unless a separate Accepted ADR
authorizes an exact producer/envelope transition. Historical Hermes lifecycle
envelopes and Agamemnon raw/wrapped task JSON are classified by source sequence;
duplicates and incompatible payloads receive an effect-aware merge, replay, or
reviewed terminal disposition. The target does not preserve two producer
schemas behind one wildcard ACL.

The single-repository legacy harness owns `claude-planner`, `claude-tester`,
`claude-implementer`, `claude-reviewer`, and `claude-shipper` on
`homeric-myrmidon`. The multi-repository harness owns
`claude-multi-planner`, `claude-multi-shipper-odysseus`, and each exact name
`claude-multi-{tester|impl|reviewer|shipper}-<slug>`, where `<slug>` is one of
`achaean-fleet`, `argus`, `hermes`, `agamemnon`, `nestor`, `telemachy`,
`keystone`, `myrmidons`, `proteus`, `odyssey`, `scylla`, `charybdis`,
`mnemosyne`, or `hephaestus`. These consumers remain migration-required while
the harnesses are live; the default source set is five single-harness and 58
multi-harness names, while `REPOS_FILTER` may reduce the instantiated multi set.
They may switch to a retirement disposition only after a separate
human-reviewed retirement change proves no active task, no pending or
unacknowledged message, archived terminal evidence, and live deletion of every
listed consumer before this migration's RP0.

At the bound Odysseus commit, `docker-compose.crosshost.yml` defines the
`nats-loki-bridge` service, `e2e/start-crosshost.sh` starts its image when the
image exists, and `e2e/nats-loki-bridge/bridge.py` creates the
`homeric-logs` durable `loki-bridge`. Its default disposition is therefore
migrate, not retire. It may switch to retire only after a separate
human-reviewed change does all of the following:

1. Quiesce the bridge, reconcile or archive its unique messages and delivery
   state, and delete the durable only after that evidence is recorded.
2. Remove or fail closed the Compose service, the cross-host launcher branch,
   the executable bridge consumer, and every packaging, loader, generator, and
   test path that can start or recreate it.
3. Run the retained or replacement cross-host start path with the bridge image
   present and prove that it creates no bridge container, process, connection,
   or durable. Repeat the proof after a restart so a later start cannot recreate
   `loki-bridge`.
4. Confirm by live readback immediately before RP0 that no bridge connection or
   `loki-bridge` durable exists.

If any retirement condition is absent, RP0 and the target must preserve the
complete `loki-bridge` configuration and state. Test-only
`ordering-test-consumer`, `nak-test-consumer`, and `large-payload-consumer` and
the future-only `agamemnon-epics` name are not migration objects. Finding any
of them live does not silently promote them; it triggers the unclassified-state
stop below.

#### Reconcile Keystone before RP0

RP0 begins only after a separate human-reviewed Keystone change and live
readback reconcile both exact-pinned paths. Source defaults alone do not prove
a durable exists. The preflight captures every consumer on `homeric-agents`
and `homeric-tasks`, including server-assigned names, durable names, filters,
delivery subjects, complete state, and the process and executable that can
recreate each one.

The task listener must explicitly bind the accepted `keystone-dag` durable in
its JetStream subscription and prove that restart reuses that exact consumer.
If current `keystone-dag` state exists, it is the canonical state to preserve.
The exact-pinned daemon's callback only prints the task identifiers, after
which the listener acknowledges the terminal event. Before the listener may
receive task authority, a reviewed Keystone change must instead commit an
observable, idempotent DAG transition and return a durable effect receipt
before acknowledgment. Failure before that receipt must not acknowledge the
event. The listener must accept only the exact five-token
`hi.tasks.{team_id}.{task_id}.{verb}` prefix and arity and only ADR-005's
`updated`, `completed`, and `failed` vocabulary. It rejects foreign prefixes,
suffix tokens, and any other verb before callback invocation unless a separate
Accepted ADR extends the vocabulary. If no such effect path is implemented,
the listener receives no task grant and RP0 stops. Retiring the accepted
`keystone-dag` contract instead requires a separate Accepted ADR that explicitly
supersedes ADR-005 and disposes of its complete consumer and effect state; this
migration proposal cannot retire it by omission.

An invalid prefix, arity, or verb follows one bounded terminal path. Before
terminating that delivery, Keystone commits an idempotent record to a durable
local invalid-task ledger keyed by stream, source sequence, and consumer. The
record contains the subject and payload digests, a fixed reason enum, delivery
count, and terminal-state transition, but no raw task payload. Only after that
receipt is durable may the listener issue `AckTerm` for the exact delivery and
read back that it is no longer pending. A crash after the receipt but before
`AckTerm` resumes the same terminal transition without invoking the callback; a
crash after `AckTerm` is reconciled from the consumer floor and receipt. If the
ledger commit or readback fails, the listener pauses and quiesces for operator
reconciliation instead of ACK-dropping or repeatedly NAKing the record. RP0
binds the ledger checkpoint and one terminal outcome for every invalid source
sequence.

The handoff first quiesces the listener and captures the stream sequence,
consumer delivered and acknowledgment floors, every pending or redelivering
message identity, and independently recorded DAG-effect and invalid-task
receipts. The reviewed mapping then either starts `keystone-dag` at the first
provably unprocessed stream sequence or replays a bound range through a proven
idempotent handler. It must account for every matching stream sequence as
already effected, terminally classified, pending, or bounded duplicate and
prove no gap before release. If current state cannot establish that mapping,
RP0 stops for operator reconciliation; an ambient `DeliverAll`, `DeliverNew`,
or guessed start position is forbidden.
Only after no-loss and bounded-duplicate evidence may a server-assigned
consumer be drained or archived under its exact state, deleted, and proven
absent after a restart. The string `keystone-daemon` is not migrated as a
durable merely because it is a source default.

The exact-pinned push-subscribe call with a null callback cannot create the
claimed consumer and returns an invalid-argument error. The reviewed replacement
has the fixed helper provision `keystone-dag`, then uses `js_PullSubscribe` with
explicit bind-only subscription options for the exact stream, durable, account,
domain, and filter; no callback is passed to that pull API. It never discovers,
updates, or creates a consumer. `updated` is an accepted ADR-005 verb
but currently has no DAG mutation; it therefore commits a durable idempotent
no-op disposition keyed by stream/consumer/sequence before ACK rather than
silently acknowledging without an effect.

The transparent bridge must be retired for this migration because its
point-to-point role and payload conflict with Accepted ADR-002 and the accepted
`homeric-agents` lifecycle stream. A future replacement may be deployed only
after RP0 through a separate Accepted ADR and a later frozen migration; it is
not an eighth retained object in this seven-stream cutover. That future ADR
must explicitly supersede the ADR-002 boundary and define a distinct subject
family and stream, payload schema, routing and host cardinality, per-host
filter and durable ownership, source-state handoff, poison-message and
dead-letter behavior, and no-loop semantics. Its implementation must use a
local-only inbound delivery entry
point that cannot invoke outbound publishing, give unknown or nonlocal
receivers one bounded terminal path, and make activation atomic: inbound
subscription, processing thread, outbound publisher, and health state either
become active together or roll back together. Any intentionally partial mode
requires its own explicit accepted authority and observable health contract;
the current attach-failure behavior is not such authority. The replacement
must not reuse `homeric-agents`, claim authorization from ADR-005 alone, use one
global wildcard durable, republish an inbound delivery, or negatively
acknowledge poison forever. Retirement first quiesces every bridge process and
captures every server-assigned bridge consumer's delivered and acknowledgment
floors, pending and redelivering identities, filter, and complete configuration.
It also classifies every incompatible binary bridge record already mixed into
`homeric-agents`. An operator must resolve or preserve each record and pending
delivery in the confidential source-local archive before deleting its exact
consumer. After independent resolution, a reviewed manifest deletes every
exact incompatible source-stream sequence before RP0 and records the resulting
sequence gaps or deletion tombstones in the canonical source state; none of
those payloads may enter the target snapshot. No unresolved point-to-point
message or unacknowledged delivery may be silently discarded or migrated into
the JSON lifecycle stream. Retirement then removes or fails closed both
inbound and outbound paths, deletes the classified consumers, and proves that
no process or restart can recreate their consumer or publisher. If a record
cannot be classified, independently resolved, or deleted without losing
required state, RP0 stops. Until that retirement disposition is proven, the
baseline target grants the bridge no authority and migration cannot advance
beyond preflight.

Argus also contains the older `argus-jetstream-consumer` durable on alternate
streams `hi_agents` and `hi_tasks`, which capture the same subjects as the
canonical `homeric-agents` and `homeric-tasks` streams and therefore cannot be
created alongside them in one account. Before this migration, a separate
reviewed retirement must quiesce that consumer, reconcile or archive any
unique messages and delivery state, verify the Atlas replacements, and delete
both alternate streams and consumers from live state. If either alternate
stream remains at RP0, migration stops.

#### Rebind every retained client and effect before RP0

Every retained JetStream client is changed and tested against its exact bound
artifact before RP0. It connects only to the manifest endpoint with explicit
account and `homeric-hub` domain/API prefix, disables discovery and automatic
reconnect for migration/readiness traces, and performs only manifest-name binds
to helper-provisioned streams and consumers. Subject-based stream lookup,
create-if-missing, update/add fallback, unqualified/default JetStream contexts,
ambient/default-server dials, and Core publish fallback are forbidden.
Agamemnon treats JetStream-context failure as startup failure and requires a
validated PubAck naming the expected stream and sequence; Telemachy's registrar
does the same rather than treating a Core publish as durable success. Hermes,
Nestor, Keystone, Argus, Loki, both legacy harnesses, and every worker use the
same explicit-domain rule. An uninterrupted connection/session generation binds
server ID, TLS peer, account, domain, client artifact, inbox prefix, and every
request/delivery/ACK/reply chunk; disconnect, reconnect, INFO/server-ID drift,
auth refresh, or lost response aborts that operation and starts a fresh process
and operation ID after reconciliation.

Accepted ADR-002's offline catch-up and at-least-once requirement applies to
retained infrastructure event consumers. In addition to `keystone-dag`, the six
`atlas-*` names, `loki-bridge`, and retained legacy names, the helper provisions
the exact durables `agamemnon-task-facts`,
`agamemnon-pipeline-registration`, `nestor-research-status`, and
`telemachy-task-events` when those roles remain. Those clients bind only; no
Core-only subscription is called durable. A role may instead be retired with
complete state/effect evidence, or a separate Accepted ADR may authorize named
at-most-once loss.

The Core-to-durable handoff happens on the source while ordinary producers are
denied and before RP0. Each old Core callback drains to zero and commits an
idempotent external-effect receipt keyed to the exact source stream sequence.
The helper then creates the named durable at the first sequence not proved
effected for that filter. If Core delivery did not expose a complete sequence
ledger, a reviewed replay scans the exact retained filter from a bound earliest
sequence and reconciles every record through the idempotent effect store before
choosing the durable start; `DeliverNew`, `DeliverAll`, current-last, wall-clock,
or a guessed floor is forbidden. The source durable's complete configuration
and state enter RP0. A duplicate-stream merge translates its source sequence
and floor through the approved source-to-target mapping; a one-to-one restore
preserves them directly. A missing effect receipt, unmapped sequence, or handler
without idempotent replay blocks migration.

Target admission is two-phase across the point of no return. Before the commit,
only non-consuming authorization/readiness probes and isolated effect-sink
canaries run; they cannot bind or ACK a production durable. After
`cutover_committed`, ordinary producer publication remains denied while the
exact ordinary consumer binaries and credentials bind every named durable,
validate effect sinks and floors, establish zero pull waiters/callback work,
and report ready. Only after all consumers are ready may the operator atomically
admit ordinary producers. Failure in this post-commit phase uses forward
recovery and never falls back to RP0.

Filters and payloads are closed contracts. Nestor consumes only
`hi.research.*`, not descendants. Agamemnon and Telemachy consume only the exact
ADR-005 arity and `updated`, `completed`, or `failed` filters; `started` is
denied absent separate accepted authority. Agamemnon's short
`hi.tasks.created` and state-derived subject variants, every stored malformed
record, broad research/task/log filter, and every noncanonical envelope receive
a reviewed sequence-level disposition before RP0. Each retained log role gets
an owner-manifest arity instead of a catch-all family. Ordinary role ACLs
enumerate these exact subject sets and verbs, not table shorthand `>`.

Argus binds all six Atlas consumers or remains NotReady; a single successful
attach is insufficient. Startup and every reconnect revalidate exact stream,
consumer, account, domain, filter, delivery/ACK subjects, and client/server
identity. Quiesce uses a non-deleting drain/stop path and proves all six durables
survive two restarts; the current create-on-missing and durable-deleting drain
behaviors are removed. Atlas's volatile internal bus is not an effect receipt:
each delivered sequence must reach a durable idempotent sink receipt before ACK,
or an exact reviewed bounded-loss disposition must name it.

The retained Loki bridge binds only `homeric-logs`/`loki-bridge` with its locked
nats-py artifact. It removes subject lookup and add-stream fallback. A Loki HTTP
success is not enough: an idempotent durable `(stream, consumer, sequence,
payload-digest, Loki-tenant/stream, external-object/readback)` receipt commits
before ACK, and restart reconciles it without duplicate external effect. Invalid
UTF-8/JSON/schema, over-limit, Loki rejection, timeout, crash, and unknown record
use the same bounded poison-ledger/AckTerm rule as Keystone rather than early
ACK, swallowed failure, or endless NAK.

Every retained legacy durable binds a durable task/SCM effect intent and
independent result receipt before ACK; an outer exception propagates failure and
cannot unconditionally ACK. Every AchaeanFleet/Myrmidons hello worker, Atlas
handler, and other poison path gets a finite terminal invalid ledger and cannot
NAK forever. The three active mutable hello-worker manifests and their launcher
are queried through the live reconciler and require operator-approved migrate or
hibernate/retire evidence before RP0; no restart may recreate a retired worker.
Scylla's optional `scylla-subscriber` is migrated with full state or its loader
is disabled and restart-tested. The Odysseus console's six broad Core
subscriptions and interview-answer publication receive an exact role,
credential, filters, effects, and non-deleting stop path or the loader/recipe is
retired. No unclassified consumer or effect path advances.

The pinned Myrmidons `hello-myrmidon` path is not grandfathered. Its direct
creation of `homeric-myrmidon`, `homeric-tasks`, and `homeric-logs` moves to the
owner helper; it bind-pulls only the existing `hello-myrmidon` durable and exact
`hi.myrmidon.hello.>` filter. It may publish an exact dispatch-result and log,
but not `hi.tasks.*.completed`; a reviewed Hermes ingress validates the result
and emits the canonical ADR-005 completion envelope. Before source ACK, the
worker commits a task-effect intent, requires PubAcks naming the expected result
and log streams and sequences, and observes an externally durable task-result
receipt. A lost PubAck or result receipt is reconciled by operation and message
identity without re-running the task; completion/log failure never falls through
to ACK. Invalid task input follows the bounded poison-ledger/AckTerm path. These
requirements replace the current unconditional ACK after ignored completion/log
publish failures; they do not widen worker producer authority.

The pinned optional Scylla path is likewise live inventory even when disabled by
default. Its `TASKS`/`scylla-subscriber`/`hi.tasks.>` create-or-bind and
`DeliverNew` defaults, permissive verb parsing, raw endpoint logging, swallowed
handler failures, and unconditional ACK are either replaced by an exact named
stream/filter/domain/TLS bind with effect-before-ACK and poison receipts or the
loader is removed and absence is proved across restart. Default-disabled is not
retirement evidence.

All ordinary clients replace close-only, swallowed-error shutdown with bounded
flush, non-deleting drain, callback/descendant completion, surfaced failure, and
zero active work or an exact reviewed loss receipt. This includes Agamemnon,
Nestor, Telemachy, Hermes, Keystone, Argus, Loki, and the legacy harnesses. Each
uses separate protected auth material; a credential-bearing URL is rejected.
Startup, reconnect, exceptions, audits, and readiness render only a canonical
secret-free endpoint. Exact sentinel tests cover every current raw-URL log site,
including Atlas `ConnectedUrl()`; source APIs must use a redacted form rather
than sanitizing only after logging.

The preflight live readback must reconcile this code inventory with every
stream, subject binding, consumer, account, and connected role actually
present. An additional or renamed object is unclassified state and stops the
migration until a reviewed migrate-or-retire disposition covers it. Including
the compatibility-retained myrmidon, research, pipeline, and log surfaces here
does not accept Proposed ADR-013 or expand its authority; it prevents current
state from being silently lost.

### 3. Use one hub-owned JetStream domain

This ADR chooses one exact storage topology:

- One standalone hub server role, `homeric-nats-hub`, is the only JetStream
  server. It owns the authoritative store and uses the domain
  `homeric-hub`.
- Standalone means the hub and spokes have no cluster stanza, cluster listener,
  route URL, route credential, or route session. The checked-in
  `0.0.0.0:6222` listener is a source defect to remove in the separately
  approved implementation. A future cluster requires its own accepted
  topology, authentication, TLS, store, and migration decision.
- `HOMERIC` is JetStream-enabled on the hub and is the only account that owns
  application streams. `SYS` owns no application stream.
- `homeric-agents`, `homeric-tasks`, `homeric-deadletter`,
  `homeric-myrmidon`, `homeric-research`, `homeric-pipeline`, and
  `homeric-logs` each have one replica on the hub. Their normalized live
  subject, retention, storage, duplicate-window, limit, and consumer
  configuration is preserved.
- Hermes remains the semantic and manifest owner of `homeric-agents`,
  `homeric-tasks`, and `homeric-deadletter`. Agamemnon is the semantic and
  manifest owner of `homeric-myrmidon`, `homeric-research`,
  `homeric-pipeline`, and `homeric-logs`. Each owner invokes the same fixed
  reconciler helper with its canonical checked-in manifests; neither service
  sends a raw stream or consumer mutation. Nestor, the legacy harnesses,
  Argus, and any retained NATS-to-Loki bridge retain only their required
  runtime publish, info, pull, delivery, or acknowledgment authority.
- Spokes are Core NATS leaf servers only. They have no `jetstream {}` storage,
  no local metadata leader, no local stream, mirror, or source, and no
  JetStream-enabled account.
- A replicated hub cluster, spoke-local storage, mirrors, and sources are
  outside this decision and require a later ADR and migration.

The manifest freezes the target node name, exact binary/image and rendered
configuration digests, TLS identity, endpoint, store identity, and activation
generation before first target start. A target server ID does not exist yet and
is never invented: the local verifier records the first observed ID with those
prebound facts in a signed activation receipt, and every target session must map
back to it. Restart produces a new session receipt and cannot switch stores or
configuration.

The target also preserves or deliberately narrows every source account/JWT and
stream resource limit. The manifest records per-account storage/memory,
connection, subscription, payload, consumer, and pending limits plus per-user
limits; capacity preflight proves the sum of seven streams, consumers,
replication overhead, canary margin, and restore scratch fits the hub without
borrowing from `SYS`. Noisy-neighbor tests exhaust one least-privilege role and
prove other roles, migration reserve, and system monitoring remain available.

The hub domain maps `$JS.homeric-hub.API.>` to its local `$JS.API.>` service.
Every steady-state application client, whether connected to the hub or a
spoke, selects the `homeric-hub` domain and therefore sends its authorized
management or consumer requests to `$JS.homeric-hub.API.>`. The domain prefix
is the only JetStream API prefix permitted to steady-state application users
and the target-side migration identity. Unqualified `$JS.API.>` service
interest may also propagate over the leaf, so those identities explicitly deny
the complete `$JS.API.>` subtree rather than treating absence of a spoke-local
JetStream process as an authorization control. Section 6 deliberately uses
source-local `$JS.API.>` endpoints through direct connections to each old
source account before the new leaf/domain topology exists; those short-lived
source identities cannot reach the target domain. Application data remains on
its unchanged `hi.>` subject families. Reply inboxes, consumer delivery
subjects, and `$JS.ACK.>` flow through the same `HOMERIC` leaf binding after
cutover.

Runtime inventory distinguishes operator-authored application or migration
exports/imports from the selected release's NATS-managed JetStream
system-account service export, per-JetStream-account service imports, and
domain mappings. Those managed objects are exact-release protocol plumbing:
the implementation inventories their subjects, direction, accounts, and
runtime identities, neither deletes nor denies them merely to satisfy this
ADR's application-boundary wording, and fails closed on any unexpected export,
import, or mapping.

The selected topology implies that a spoke-originated publish should be stored
once by the hub stream rather than locally and then mirrored. That is an
inference to prove, not an accepted runtime fact. Executable evidence must show
that exactly one matching hub sequence advances, no spoke-local store exists,
and the returned acknowledgement identifies that hub-owned stream and
sequence.

### 4. Authorize roles inside `HOMERIC`

Account membership provides the shared event bus; distinct credentials and
subject permissions provide least privilege. Hermes, Agamemnon, Nestor,
worker, Keystone, Telemachy, Argus, a retained NATS-to-Loki bridge, a retained
advisory observer, the reconciler helper, and every retained legacy-harness
identity are separate users in `HOMERIC`. Every role has explicit publish and
subscribe allow lists. A user without a permissions block is not an acceptable
implementation of this decision.

The implementation must start from these boundaries and narrow them when the
exact-pinned client inventory demonstrates that a capability is unnecessary:

| Role | Application publish | Application subscribe | JetStream authority |
|---|---|---|---|
| Hermes | Only the owner-manifest enumerations of `hi.agents.*.*.{created,updated,deleted}`, `hi.tasks.*.*.{updated,completed,failed}`, and the exact dead-letter grammar | Its unique inbox prefix | Exact info endpoints for its three owned streams; no mutation |
| Agamemnon | Only owner-manifest `hi.myrmidon.{domain}.{role}.task.{id}` and exact-arity Agamemnon log subjects; no `hi.agents` or `hi.tasks` publication | Named-durable task filters for `updated`, `completed`, and `failed`, the exact pipeline-registration filter, and its unique inbox prefix | Exact info, bind, pull/delivery, and ACK endpoints for its named consumers; no mutation or Core fallback |
| Nestor | Exact `hi.research.{id}`, `hi.myrmidon.research.chief-architect.task.{id}`, and owner-manifest exact-arity Nestor log subjects | Named-durable `hi.research.*` delivery plus its unique inbox prefix | Exact info, bind, pull/delivery, and ACK endpoints only for its named consumers; no mutation |
| Worker or retained legacy harness | Only its exact dispatch-result and log subjects; no direct `hi.tasks` or `hi.agents` publication | Only its listed delivery filters and own reply inboxes | Exact info, pull, and ack endpoints for only its listed durable on `homeric-myrmidon`; no mutation |
| Keystone task listener, after reconciliation | None | `keystone-dag` delivery and its own reply inboxes | Exact stream-info, consumer-info, pull, and ack endpoints for `keystone-dag` on `homeric-tasks` |
| Keystone transparent bridge | None; it is retired before RP0 | None; it is retired before RP0 | None; it is retired before RP0 |
| Telemachy | Only `hi.pipeline.epic.*.registered`, with the single-token epic key produced by the exact-pinned registrar and a validated PubAck | Named-durable exact bound-team task filters for the three ADR-005 verbs plus its unique inbox prefix | Exact info, bind, pull/delivery, and ACK endpoints for its named consumer; no mutation |
| Argus Atlas | None | Delivery subjects for the six `atlas-*` consumers and its own reply inboxes | Exact info, pull or delivery, and ack endpoints for its six named consumers only; no mutation |
| NATS-to-Loki bridge, when retained | None | `loki-bridge` delivery and its own reply inboxes | Exact stream-info, consumer-info, pull, and ack endpoints for `loki-bridge` on `homeric-logs`; no mutation |
| Local `HOMERIC` advisory observer, when retained | None | Only the exact account-scoped JetStream advisory subjects used by the selected release | No request or management authority |
| Fixed reconciler helper | None | Helper-owned reply inboxes only | The only steady-state stream/consumer mutation authority, limited to the seven owned manifests and retained consumers |
| System operator | None in `HOMERIC` | None in `HOMERIC` | System monitoring and management in local `SYS` only |

Every credential and process instance receives a unique, nonoverlapping inbox
prefix derived by the trusted provisioner; no role shares `_INBOX.>` or an
instance-neutral wildcard. Push-consumer delivery subjects use a separate
manifest-bound namespace and can never fall under a reply grant. Pull clients
receive no push-delivery grant. Reply, delivery, flow-control, and ACK subjects
are traced independently in both directions and expire with that exact
credential/instance.

No ordinary role receives an unrestricted `hi.>`, `$JS.API.>`, or
`$JS.homeric-hub.API.>` grant. Request/reply inbox, consumer-delivery,
acknowledgment, and management subjects are enumerated from an exact-pinned
client trace before implementation. The resulting allow lists are checked in
and exercised by positive and negative authorization tests.

An exact API request subject is not a sufficient mutation boundary. Stream
request bodies can select captured subjects, sources, mirrors, transforms, and
republish targets. Consumer bodies can select filters, delivery subjects,
delivery and replay policy, start position, and other authority-bearing state.
All create, update, delete, purge, message-delete, restore, and consumer
mutation calls therefore run through a fixed helper; no ordinary service or
runtime identity receives a mutating JetStream API grant.

For steady-state reconciliation, the caller supplies only an operation and the
identifier and digest of a canonical checked-in manifest owned by Hermes or
Agamemnon. The helper loads that manifest itself, validates the complete body
against the exact selected-release schema, rejects unknown fields and any
caller-supplied difference, binds every stream name, subject, source, mirror,
transform, republish target, consumer name, filter, delivery subject, start
position, and replay setting, and then constructs the canonical request. The
helper credential enumerates only the exact selected-release endpoint variants
for those seven streams and retained consumers. Destructive operations require
a separately reviewed manifest disposition; a manifest omission is not delete
authority. Request body, manifest digest, caller owner, operation, and result
are audited without credentials.

The helper authenticates its caller through a root-owned local
`SOCK_SEQPACKET` boundary and binds boot/PID/start, executable and image digest,
cgroup/workload identity, LSM label, repository owner, manifest, and generation;
UID or possession of a socket path alone is insufficient. Before any migration
credential can open, one external durable compare-and-swap lease keyed by
change, stable source/target store identities, account, stream, operation, and
generation becomes the sole writer. A retry or lost response first reads that
lease and the immutable operation receipt; concurrent/stale callers and a helper
restart cannot issue a second request. The lease is released only after the
connection, dynamic subjects, credential, partial artifacts, and operation are
terminally reconciled.

The steady-state helper's ephemeral request/reply identity is separate from
every temporary source or target migration identity in section 6. Only these
fixed helpers can hold stream or consumer mutation grants, and each migration
helper process is limited to one manifest-bound identity, operation, and
snapshot or restore window. The steady-state helper rejects an owner mismatch:
Hermes may reconcile only `homeric-agents`, `homeric-tasks`, and
`homeric-deadletter`; Agamemnon may reconcile only the other four streams.
Nestor and the legacy harnesses must stop reconciling shared streams, and the
retired Argus consumer must stop creating alternate streams. A retained
NATS-to-Loki bridge must replace its subject-based stream lookup and add-stream
fallback with exact `homeric-logs` stream-info access and fail closed if the
stream is absent. A denied management call or attempted configuration drift is
a failed migration, not a reason to widen a role or helper.

Certificate identities proposed by ADR-010 may remain the authentication
identities for these users. This ADR changes their account placement, not the
requirement for distinct role identity.

### 5. Bind one application leaf and keep `SYS` local

Each spoke has exactly one remote for this topology. Its static local account
is `HOMERIC`, and the hub's corresponding leaf user authenticates and binds the
incoming connection to hub account `HOMERIC`. The outgoing credential syntax
must be supported by the selected server pin and uses protected separate auth
material; userinfo, password, token, or credential material in a URL is
forbidden. An unsupported scalar `token` field is not permitted. Audit and
rendered endpoint records contain only canonical scheme/host/port identity and
never auth material.

Every credential-bearing end-client, leaf, migration-helper, reconciler, and
local administrative connection uses manifest-bound authenticated TLS with
exact CA/peer/SAN/policy and no skip-verification mode. Plaintext listeners and
connections are denied. Because several current clients expose only raw URL or
default-off TLS paths, their reviewed exact-binary changes and ordinary-identity
readiness are pre-RP0 requirements; embedding credentials in `tls://` URLs is
not a workaround. ADR-010 may later select certificate identities, but this
transport precondition does not depend on that Proposed ADR becoming accepted.

Leaf credentials identify the topology connection. They do not replace
end-client role credentials or subject authorization. A client on a spoke
still authenticates as its exact Hermes, Agamemnon, Nestor, worker, Keystone,
Telemachy, Argus, NATS-to-Loki, advisory-observer, reconciler-helper, or
retained legacy role in the local `HOMERIC` account, and the origin server
enforces that user's permissions. Distinct leaf credentials are issued per
spoke so one host can be revoked without rotating every host.

`SYS` is deliberately **not** extended over a leaf. The hub and every spoke
have separate local `SYS` credentials, no remote has `account: SYS`, and no
system-account interest crosses the application leaf. Operators inspect each
server's local system account through its protected administrative path. This
keeps a compromised spoke system identity from acquiring hub system authority.

Argus does not receive a remote or shared `SYS` identity. Each node runs one
fixed, non-forwarding local collector that authenticates only to that node's
`SYS` account, subscribes to the exact selected-release monitoring subjects,
and exposes a closed sanitized metric schema to Argus over host-local verified
mTLS. It has no system request, application, leaf, route, payload, or raw-URL
authority. Unauthenticated `/varz`, `/jsz`, `/connz`, and other monitoring HTTP
listeners are disabled; if the selected release requires HTTP collection, the
endpoint is loopback-only behind the same authenticated collector and cannot be
scraped directly. Node identity, metric field allowlist, cardinality bounds,
staleness, and secret-free output are executable acceptance gates.

### 6. Split source capture from target restore behind one validating helper

Snapshot and restore run only through the fixed
`homeric-nats-migration-helper` on the approved migration host. The frozen
manifest contains one row for every retained stream. Each row binds the exact
old source server ID and endpoint, old account name, source-local JetStream API
prefix, source identity ID, stream and consumer names, canonical no-follow
source store root and storage identity, the prebound target node name, endpoint,
TLS identity, rendered-config digest, activation generation, and signed
activation-receipt link slot, target `HOMERIC` account and `homeric-hub` domain,
canonical no-follow target store root and storage identity, selected server
release and digest, decoder/schema digest, and expected operation. The target
server ID is absent before first start; the local verifier records it only in
the linked activation receipt and every later audit binds that receipt. A
storage identity includes the exact volume or
device, filesystem and mount identities, root inode, ownership, and immutable
allocation record. A duplicate, missing, overlapping, aliased, ambiguous, or
live-mismatched source placement stops migration; the helper never guesses that
a target-domain subject maps to an old source account.

Before this manifest is frozen or any migration identity is armed, the operator
allocates the pristine target store, resolves and records all of its no-follow
storage identities, proves physical non-overlap with every source, and proves it
is empty. It remains unmounted from target processes, inaccessible to target
credentials, and unwritten until every source identity is revoked and every
source store is sealed below. Later phases may revalidate and activate that
exact target; they cannot substitute it or mutate the frozen manifest. An
allocation failure abandons the operation and starts a new manifest rather than
filling an identity placeholder.

The implementation creates one time-limited
`homeric-migration-source-<account>-<change-id>` identity for each old
non-`SYS` source account represented by the manifest, plus one separate
`homeric-migration-target-<change-id>` identity in target `HOMERIC`. A helper
process invocation accepts only an approved operation, one stream identifier,
and the frozen-manifest digest. It selects exactly one manifest-bound identity
and API plane, opens only that credential, verifies the connected server ID,
endpoint, account, domain presence or absence, release digest, stream,
consumers, and operation, performs one bounded operation, drains and closes the
connection, releases the credential, and exits. No process lifetime may load a
source and target credential together or retain one identity for the next
operation.

Each source identity connects directly to its manifest-bound old endpoint and
may use only the exact source-local `$JS.API.STREAM.SNAPSHOT.<stream>`,
`$JS.API.STREAM.INFO.<stream>`, and retained
`$JS.API.CONSUMER.INFO.<stream>.<consumer>` endpoints for streams in that
source account, plus its unique reply and snapshot-delivery subjects and the
exact selected-release snapshot transfer subjects observed in a checked-in
protocol trace. A source identity has no restore, target-domain, application,
other-account, `SYS`, leaf, route, general consumer-management, or wildcard
JetStream authority.

The target identity connects only to the manifest-bound new hub endpoint and
target `HOMERIC` account. It may use only the exact
`$JS.homeric-hub.API.STREAM.RESTORE.<stream>`,
`$JS.homeric-hub.API.STREAM.SNAPSHOT.<stream>`,
`$JS.homeric-hub.API.STREAM.INFO.<stream>`, and retained
`$JS.homeric-hub.API.CONSUMER.INFO.<stream>.<consumer>` endpoints, plus its
unique reply and snapshot-delivery subjects and the exact selected-release
restore or snapshot transfer subjects observed in the same protocol trace. It
has no source-local `$JS.API.>`, old-account, application, `SYS`, leaf, route,
general consumer-management, or wildcard JetStream authority. The migration
defines no operator-authored cross-account application-data or
migration-control export/import between an old application account and another
old account or target `HOMERIC`; source capture remains source-local and target
restore and verification remains target-local. This prohibition neither
removes nor widens the selected release's NATS-managed JetStream system-account
service export, per-JetStream-account service imports, or domain mappings.

The selected release's dynamic transfer subjects are not an evergreen grant.
The implementation records an executable protocol trace for that exact release
and enumerates only the required subject shapes, direction, operation, stream,
binding, and reply path. Snapshot delivery uses the caller-derived unique
change/operation subject below. Restore is a distinct protocol: the server
returns `$JS.SNAPSHOT.RESTORE.<stream>.<nuid>`, and the caller cannot choose its
suffix. The request-only target identity receives that subject on the same
authenticated server/account/session and validates the exact stream, selected-
release grammar, NUID, pending operation, deadline, and signed response. It
durably binds the returned subject to the one operation, closes the request
identity, and asks the fixed authorization provisioner for a second short-lived
transfer identity whose sole publish grant is that exact returned subject. The
transfer identity cannot issue another restore request. A caller-selected
restore subject, a response from another session, or a second response fails
closed. A release, endpoint, subject, or frame outside the signed trace requires
a newly reviewed manifest and permission set.

NATS stream snapshot requests contain a caller-selected `deliver_subject`, and
the server publishes chunks to it. Client publish permissions do not constrain
that server-mediated publication, so neither a short-lived identity nor an
exact request subject alone is a least-privilege boundary. The helper contains
that capability by:

1. deriving one unique
   `_MIGRATION.<change-id>.<operation-id>.snapshot.<stream>.<nonce>` delivery
   subject from the frozen row and accepting no caller-provided subject;
2. constructing the complete canonical snapshot or restore body internally,
   with consumers included and message checking enabled;
3. validating every body field, embedded stream name, configuration, source or
   mirror, transform, republish target, consumer filter, delivery subject, and
   transfer destination against the selected-release schema and frozen row;
4. rejecting unknown fields or any value not derived from the manifest before
   opening the credential or transport; and
5. appending the exact request-body bytes and hash, endpoint, server ID,
   account, domain/API plane, identity ID and class, operation, stream,
   consumer set, selected-release and schema/archive digests, timestamp, and
   result to the operator audit record. Credential material and snapshot
   payloads are not logged.

#### Protect snapshot artifacts

Raw source and target archives, retired source and target JetStream stores,
bridge-record archives, transfer chunks, decoded objects, scratch files,
complete RP0/RP1 manifests, immutable pre-upgrade backups, filesystem/storage
snapshots, copy-on-write descendants, and any backup containing them are
confidential migration data. Before a credential is
opened, the frozen manifest binds the approved encrypted storage root, a
distinct per-migration key identifier held outside that root, helper and
decoder service identities, named operator readers, backup/snapshot exclusion,
maximum artifact count, per-operation and total byte caps, minimum free-space
reserve, each recovery point's retention deadline, and the deletion mechanism.
No ordinary application role, CI runner, repository, log or chat channel,
generic shared temporary directory, or unapproved backup or object store may
receive an artifact.

The target generation selected for production has a separate storage and key
lifecycle. Before restore, the manifest binds its dedicated encrypted volume,
production key identifier, service owner, access controls, and approved backup
policy. Its key is not the expiring migration-artifact key. Before cutover, the
operator records and verifies a production-custody receipt for that exact
generation and key. Admission requires this receipt. A failed, unadmitted
target can enter the retired-store inventory only through the approved rollback
procedure. An admitted production generation, its key, and its production
backups never enter the migration-expiry deletion set. They remain confidential
and subject to normal production retention and retirement approval.

The helper uses a private `0700` workspace and exclusively created regular
`0600` files, or platform-equivalent controls. It opens every path component
without following links, rejects symlink, hardlink, and path escape, transports
only over the approved TLS session, and applies authenticated encryption before
durable write. Preflight capacity and manifest caps derive from quiesced source
bytes plus measured overhead for the selected release. Count, byte, and
free-space limits are enforced while streaming. Exhaustion, truncation, or a
cap breach closes files, destroys partial output, revokes the active identity,
and fails migration; a partial archive is never a recovery point.

Failed or incomplete-operation artifacts are removed during immediate failure
cleanup. Raw RP0 material survives only through the approved pre-point-of-no-
return rollback deadline; raw RP1 material survives only through its approved
forward-recovery deadline. A separately approved extension names the location,
readers, owner, and expiry. At expiry the operator reconciles the artifact
inventory with the production-custody receipt and rejects any deletion set
that contains the admitted generation or its keys or backups. The operator
stops readers and proves that no server, decoder, bridge, helper, canary,
backup, or snapshot process can access the retired stores and recovery copies
selected for deletion. The active production server need not stop. The operator
enumerates every retired store, archive, chunk, decoded, temporary,
copy-on-write, and backup copy in that deletion set, deletes those copies, and
destroys only their dedicated encryption keys—the required erasure
boundary for copy-on-write or SSD storage—verifies paths and key are
unavailable, and records an inventory/hash/location/key-ID/time/actor deletion
receipt. Storage whose backup or lifecycle cannot meet and attest that deadline
is ineligible. Non-payload hashes and audit metadata may remain under the
evidence-retention policy; payload-bearing artifacts may not.

On restart, the helper reconciles the manifest against partial files, open
operations, and expiry/deletion state before any migration credential can be
reissued.

The operator issues, audits, expires, disconnects, and revokes every source
identity independently. After the final source snapshot for one account, the
helper closes it, the operator removes or expires the identity and disconnects
its session, and a fresh connection proves authentication denial before any
target restore starts. Target restore and target verification snapshots use
only the target identity. The operator revokes and disconnects that identity
and all canary identities before RP1 permits ordinary producers to resume.
Every audit binds the helper binary digest, exact server and credential
identity, endpoint, account/domain/API plane, operation, stream/consumer set,
request and artifact hashes, issue/change ID, expiry, disconnect, reload when
required, revocation, and post-revocation denial.

Tests prove each positive source-local capture and target-domain restore or
verification binding. They also prove denial of neighboring old accounts,
`SYS`, a foreign stream or consumer, an unlisted endpoint, source use of the
target domain, target use of a source-local API, target authentication before
all source identities are revoked, any attempt to supply or load multiple
identities or operations in one invocation, and any request after expiry or
revocation.
Alternate `hi.>`, `$SYS.>`, foreign inbox, other-stream delivery subjects,
unknown body fields, and mismatched restore bodies fail before the transport
records a request. Ordinary roles cannot snapshot or restore; neither migration
identity class can directly publish application traffic. No identity on a
release rejected by section 1 may receive a transfer grant.

Bounded pre-commit checks use separate, short-lived
`homeric-cutover-<role>-<change-id>` identities and fixed canary executables.
They are not cloned ordinary identities and never bind, fetch, deliver, or ACK
a production durable. For a writable stream with proved non-evicting headroom,
the manifest may authorize one unique canary record and an isolated shadow
consumer whose sink is disposable and idempotent; the exact append, delivery,
effect, ACK, and deletion/tombstone delta enters the canary ledger. A sealed,
full, discard-old, or otherwise eviction-capable production stream receives
read-only configuration/authorization checks or a separately restored isolated
shadow store, never a mutating canary. No probe may evict, expire, reorder, or
change a real backlog.

Any role that could cause a GitHub/SCM, task-state, DAG, Loki, notification, or
other remote effect uses an isolated sandbox sink with no production credential
or durable intent. Where an exact sandbox is unavailable, the check is labeled
transport-only and cannot claim effect-path proof. The identity receives no
snapshot, restore, source-account, system, route, or leaf authority. It is
audited, drained, revoked, and disconnected before the final RP1 snapshot, with
zero pull waiters, callbacks, deliveries, and effects and `PushBound=false` for
every temporary push consumer. Exact ordinary binaries and credentials are
proved only in the post-commit consumer-first readiness phase; pre-commit
canaries cannot consume or delete their production state. Ordinary service
credentials remain in maintenance deny throughout pre-commit checks.

### 7. Quiesce through snapshot, restore, and verification

Acceptance of this ADR is not deployment approval. Before a configuration PR
or live change, its owner binds the exact server and component revisions,
inventories live accounts, users, connected leafs, streams, consumers,
message counts, sequence state, and client capabilities, reconciles them to the
dispositions in section 2, and obtains operator approval for the maintenance
and rollback window.

RP0 and RP1 are canonical manifests, not count summaries. Normalization may
only sort map keys and render durations and timestamps in one lossless unit. No
field inside `StreamConfig`, `StreamState`, `ConsumerConfig`, or
`ConsumerState` is excluded. The only permitted differences outside those four
objects are the explicitly chosen account name, domain/API prefix, server ID,
and leader/replica-health metadata of the new physical topology; each is
listed in the manifest rather than silently ignored.

Neither the JetStream INFO APIs nor a `FastState` summary is accepted as a
complete representation of this state. Public `ConsumerInfo` exposes aggregate
and floor fields, not the complete persisted pending/timestamp and per-message
redelivery maps. Before migration, the implementation provides two independent
decoders bound to the exact selected server release and snapshot/store schema:
one decodes the checked archive and one decodes a read-only copy of the fully
quiesced, stopped store. Their source revisions, executable digests, schema
digests, format fixtures, and unknown-field rejection results are recorded with
the migration manifest. Both decoders must agree byte-for-byte on every
persisted field. Authenticated INFO is corroboration only for fields it actually
exposes. Source and target servers are stopped with zero writable handles before
their store decode; a decoder disagreement, unsupported field, or attempt to
infer a hidden map from an aggregate blocks migration.

For every retained stream, the manifest records the complete `StreamConfig`
and `StreamState`, including all subjects, retention/storage/discard and limit
fields, replicas, placement, duplicate window, rollup/seal/deny flags, message
and byte counts, first/last sequences and timestamps, subject count and full
per-subject state, deleted count and exact deleted-sequence gaps, lost-data
detail, and consumer count. For every retained durable, it records the complete
`ConsumerConfig` and `ConsumerState`, including name/durable and delivery
subjects, deliver/ack/replay policies, start sequence/time, all filters,
`AckWait`, `MaxDeliver`, backoff, rate/sample/flow-control settings,
`MaxAckPending`, inactive threshold, replicas, delivered and acknowledgment
stream/consumer sequence pairs, every pending message identity and timestamp,
and every redelivery identity and count. Derived pending, pending-ack, and
redelivery counts are checked against those maps. If the implementation cannot
extract and compare any field from the selected release's snapshot and target
state, migration is blocked; equality is not inferred from aggregate counts.

Quiescence does not freeze clocks. The manifest binds independently attested
source, target, helper, and operator wall clocks, a maximum permitted skew, a
monotonic migration budget, and the selected release's `MaxAge` and consumer
`InactiveThreshold` behavior. At source freeze, snapshot, target start, RP1,
and point-of-no-return readback, every expiring message, consumer, credential,
certificate, and migration identity must retain more lifetime than the entire
remaining worst-case budget plus skew and cleanup margin. Near-expiry state
cannot be kept alive by an unrecorded heartbeat: the operator waits for its
source-side expiry and recaptures RP0, or applies a separately approved exact
sequence/config delta before RP0. Any expiry or inactive-consumer deletion is
recorded in the canonical transform; an unexpected timer delta blocks cutover.
Clock rollback/advance, skew excess, expired auth, or an elapsed monotonic
budget closes identities and restarts from a new recovery point.

The old source store and new target store are separately allocated physical
storage objects even when both server configurations name
`/var/lib/nats/jetstream`. They may not be the same volume, bind mount, device
range, root inode, hardlink/reflink tree, writable snapshot backing, or path
reached through a symlink. Before restore, every old server is stopped, all
writable file descriptors and mappings are absent, and the source store is
sealed read-only outside every target process and mount namespace. The manifest
binds complete no-follow identities and a source byte/tree digest. Target
process credentials and mount tables must prove they can open only the distinct
target store. The source remains sealed and byte-unchanged through the durable
cutover commit below.

The cutover then follows this order:

1. Stop task and research admission and every autonomous producer for all seven
   captured subject families. Each producer must flush and drain its exact NATS
   connection, finish every admitted publication, and close before a temporary
   server-side maintenance deny makes further ordinary publication impossible.
   Unknown or unclassified producer state aborts migration.
2. Let every retained durable drain in-flight work and require
   `num_ack_pending = 0`. Before stopping a core subscription, invoke its
   client-library drain, close its connection, wait for every callback and
   descendant handler to finish, and bind an idempotent durable effect receipt
   for every handled event plus a client drain-generation receipt. An exact
   handler that is intentionally at-most-once may proceed only under a separate
   reviewed loss disposition naming the bounded records and consequences; it is
   never inferred here. Stop all consumers only after those receipts are
   complete, then prove every stream last sequence and complete durable-consumer
   state remains unchanged across two bounded readbacks. Any core callback or
   external effect still in flight, missing/ambiguous receipt, nonempty pending
   or redelivery map, nonzero pending ack, advancing sequence, or unclassified
   client aborts migration. An undelivered durable backlog may remain only when
   represented exactly in state. RP0 binds every producer-drain, core-drain,
   effect, and reviewed-loss receipt.
3. Use one source identity and one helper process per operation to take final
   source-local snapshots of every retained stream, with consumer state
   included, only after quiescence. Stream every archive and decoded object
   only into the protected workspace and enforce its count, byte, capacity,
   reader, encryption, and retention bounds. Decode each exact-version archive,
   cross-check it against complete source live readbacks, canonicalize, and
   hash the complete objects above as recovery point **RP0**, plus the frozen
   inventory, decoder and schema hashes, request audit, snapshot hashes, exact
   source server, endpoint, account, API plane, release, identity, protected
   location, key ID, and rollback deadline. After the final capture from each
   old account, disconnect and revoke that account's source identity and prove
   it can no longer authenticate. Stop every old server, close and prove absent
   every writable handle or mapping to its store, seal the source storage
   read-only, and bind its complete no-follow identity and byte/tree digest.
   Do not issue or enable the target identity until every source denial and
   sealed-store check passes.
4. Keep the old rendered configuration, credentials, store, RP0 snapshots,
   and manifest immutable and access-controlled only until their manifest
   retention deadlines. Revalidate the previously allocated, manifest-bound
   pristine target store without changing any identity, prove the target process
   cannot resolve, mount, or open the source store, and issue the separate target
   `HOMERIC` identity. Restore the
   target streams and consumers on `homeric-nats-hub`. Take target snapshots
   with target-only helper processes into the same protected storage contract,
   decode them with the same bound decoder, and cross-check them against
   complete target live readbacks. Require byte-equivalent canonical source and
   target values for every non-topology RP0 field before any canary. Target
   writes and target-store cleanup must leave the sealed source identity and
   bytes unchanged. Source-code defaults never replace the actual live
   configurations recorded in RP0.
5. Keep autonomous producers quiesced and ordinary production credentials in
   maintenance deny. Run only the non-consuming or isolated-sink canaries from
   section 6. Prove sufficient non-evicting headroom before a permitted append;
   use read-only or isolated-shadow checks for sealed, full, or eviction-capable
   state. Reconcile every authorized stream, per-subject, shadow-consumer,
   effect, ACK, expiry, and deletion delta into the canary ledger. Drain every
   canary callback and pull waiter, require `PushBound=false` for every temporary
   push consumer, revoke and disconnect every canary identity, and prove no
   canary process, writable handle, or effect remains before final capture.
6. Keep ordinary publication and consumption denied. While the target server
   and target-only helper still run, take and finish the final target API
   snapshot, with consumer state included. Record its capture boundary and
   complete transfer before closing the helper. Stop the target server and
   all store writers, then prove zero writable target-store handles or mappings.
   Run the archive and stopped-store decoders. Require their complete persisted
   state to agree; an intervening timer change or any other mismatch requires
   a fresh capture within the approved budget, not an ignored field. Record
   permitted RP0-to-capture timer and canary deltas in the ledger. Restart only
   the same prebound
   target generation under ordinary-publication deny, and corroborate the
   exposed fields through authenticated INFO. Disconnect and revoke the target
   migration identity and complete all negative tests. Record recovery point
   **RP1** containing those artifacts, the complete normalized objects, signed
   activation receipt, and explicit canary/timer delta ledger. Every change
   from RP0 must be attributable to that ledger. RP1 binds its forward-recovery
   deadline and protected artifact inventory. Only after every source, target,
   and canary identity is denied may the operator commit `cutover_committed` in
   the independent ledger below. That commit is the point of no return. After
   its readback, ordinary publication remains denied while the exact ordinary
   consumer binaries and credentials bind named durables, validate effect sinks
   and floors, and report ready. The operator admits producers only after the
   complete consumer-ready set and production-custody receipt are durable.
   When each recovery window closes,
   the operator performs and receipts verified artifact, retired source/target-
   generation, credential-copy, store, backup, snapshot, and key deletion.
   The admitted production generation, its keys, and production backups are
   excluded as specified in section 6.

`cutover_committed` lives in an independent root-owned durable ledger outside
both NATS stores and every migration-artifact/key root; the helper-operation
lease is not this ledger. Its immutable key is `(change-id, manifest-digest,
activation-generation)`. The schema binds the prior state, monotonic fencing
token, RP0/RP1 and canonical-transform hashes, source/target store identities,
activation receipt and target server ID, canary/timer ledger, expected ordinary
consumer set, approval receipt, writer executable/LSM identity, and
timestamp. Only the fixed local cutover committer can compare-and-swap it from
`prepared` to `committed`, then to `consumers_ready`, and finally to
`producers_admitted` over an authenticated `SOCK_SEQPACKET` boundary. The first
transition is the point of no return; the latter transitions bind exact
consumer readiness and producer-admission readbacks. The
committer writes an authenticated checksummed record to two independently
allocated durable copies, synchronously flushes file and directory metadata,
and requires matching readback before success. A lost response first reads the
same key and fencing token; absence, divergence, corruption, foreign writer, or
generation mismatch stops with publication denied. The committed record is
retained beyond both recovery windows and is never removed with a NATS store.

Old application, leaf, local `SYS`, administrative, source-migration, and
helper credentials remain sealed and inaccessible during the pre-commit
rollback window. Once `cutover_committed` is durable, the fixed revocation plan
disconnects and revokes every old identity, rotates any shared trust root that
would still validate it, enumerates and erases every rendered file, secret-store
version, backup, process copy, and operator export, and proves fresh
authentication denial. Each identity and copy receives a deletion or retained-
for-legal-policy disposition and deadline; no old source credential survives to
the producer-admission transition. New target credentials are separate material
and are never derived from or restored with the old store.

Before the durable cutover commit, ordinary credentials remain denied and every
ordinary client remains stopped. Rollback first revokes and disconnects target
and canary identities, inhibits target/server/helper autonomous restart, stops
and reaps every target server, helper, canary, decoder, and backup process, and
proves zero connection, pull waiter, push binding, writable descriptor, or
mapping for the target store. Only then may it erase the exact manifest-bound
target store and target-only keys, with a deletion receipt. It proves those
writes and deletion did not alter the sealed source identity or bytes, remounts
only the verified source store for the old servers, restores the complete prior
topology at RP0, verifies RP0, and only then resumes old producers and consumers.
Canary records are intentionally absent from that rollback.

At and after the durable cutover commit, RP0 is no longer a safe rollback even
if no ordinary publish or acknowledgment has yet been observed. A crash, lost
response, delivery-side effect before ACK, or later failure triggers forward
recovery: quiesce again, capture a new recovery point from the target, and
repair or restore from that state. Dual writes to old and new accounts are
never permitted.

### 8. Make topology, replay, and denial executable acceptance gates

Hosted CI for the implementation runs the exact digest-pinned server build
with one hub and at least two spokes. It must prove all of the following:

- The version gate rejects v2.10.22, v2.10.24, every v2.12 release including
  the historical v2.12.12 floor, v2.14.0 through v2.14.2, prereleases,
  unsupported minor series, mutable tags, an unreviewed future branch, and any
  exact release missing from the signed current advisory and upgrade review.
  Tests retain v2.12.12 and v2.14.3 only as historical branch-specific
  security-floor cases. Live readback matches the one selected digest on every
  node, and the executable-inventory check covers every site listed in section
  1 plus any site found by the repeated implementation-time search.
- The all-node version-first transaction keeps every leaf listener, remote, and
  route disabled, stops every old server and writable handle before candidate
  start, and never activates repaired remote syntax against an account-unbound
  hub listener. Failure on one candidate stops all candidate nodes and restores
  all old nodes from the bound recovery point. Mixed versions, staggered
  service, temporary same-name-account leafing, `$G`, config parsing alone, and
  every asymmetric or partially repaired state fail closed.
- Before the candidate release touches a production store, a quiesced
  pre-upgrade recovery point binds its complete state and physical identity.
  Exact-copy tests prove either bidirectional old↔candidate on-disk compatibility
  with complete equality or immutable-backup restoration to a distinct store
  reopened by the old binary. Missing, partial, unprotected, or unrehearsed
  recovery evidence blocks replacement; a start-only downgrade is insufficient.
- An exact v2.10.22 regression fixture proves the checked-in scalar `token`
  rejects every spoke remote, and a current-shape fixture with syntactically
  valid user/password but no hub account binding proves that the spoke-local
  named account lands in hub `$G`, not a same-named hub account. The reviewed
  exact release then parses both complete rendered hub and spoke configs with
  secret-safe dummy credentials; parsing only the hub is insufficient.
- Desired static configuration has one local `HOMERIC` remote per spoke, a hub
  leaf user explicitly mapped to `HOMERIC`, no `SYS` remote, JetStream enabled
  only for hub `HOMERIC`, and domain `homeric-hub` only on the hub. Missing or
  incorrect credentials register no leaf. Runtime readbacks independently show
  the spoke's outbound local account and hub's accepted remote account are both
  `HOMERIC`, with no application or leaf session in `$G`. Separate checks prove
  `SYS` has no remote binding and cross-account access is denied.
- The frozen pre-start manifest binds target node/config/TLS/endpoint/store and
  activation generation, not a fabricated server ID. The first verified start
  writes the observed ID into the separately signed activation receipt; every
  target operation and restart binds that receipt and rejects a changed store,
  config, TLS identity, endpoint, or generation.
- The hub is standalone: rendered and live state have no cluster stanza,
  cluster listener, route URL, route credential, or route session. Every
  credential-bearing client, leaf, helper, reconciler, and administrative path
  proves authenticated TLS with the exact CA/peer/SAN policy. Plaintext,
  skip-verification, userinfo URL, expired/near-expiry certificate, wrong SAN,
  and raw credential-bearing log fixtures fail before application or management
  traffic; sentinel credentials never appear in logs or receipts.
- Per-account and per-user storage, memory, connection, subscription, payload,
  consumer, and pending limits match or narrow the source manifest. Capacity
  includes all seven streams, retained consumers, restore scratch, and canary
  margin. Exhausting one noisy role cannot consume migration reserve or prevent
  another role or local system collector from operating.
- Rendered config contains no operator-authored application-data or migration
  export/import. Runtime introspection contains only the exact selected-release
  NATS-managed JetStream service export/imports and domain mappings recorded in
  the signed manifest; an unexpected object fails closed. Those managed `$JS`
  objects do not permit `hi.>` application data to cross accounts.
- `$JS.homeric-hub.API.INFO` succeeds from an authorized spoke and resolves to
  the hub domain. The same identity is denied both `$JS.API.INFO` and the deep
  unqualified `$JS.API.STREAM.INFO.homeric-tasks` and
  `$JS.API.CONSUMER.INFO.homeric-tasks.keystone-dag` endpoints, even if the
  hub's unqualified service interest is visible.
- The inventory gate finds exactly the seven retained streams and every
  surviving named durable from section 2. It proves that `hi_agents`,
  `hi_tasks`, their `argus-jetstream-consumer` durables, test-only consumers,
  and any separately retired legacy durable are absent. It requires
  `loki-bridge` and its complete state when its disposition is migrate. It
  permits its absence only when the reviewed retirement evidence proves that
  every bound launch/runtime path is disabled and a cross-host start and
  restart with the image present cannot recreate it. Any other object fails
  closed as unclassified state.
- The Keystone gate proves that the task listener passes exact durable
  `keystone-dag` subscription configuration and that two restarts reuse the
  same consumer without creating a server-assigned consumer. A quiesced source
  sequence plus complete delivered/acknowledgment floors, pending deliveries,
  and effect receipts map the first canonical delivery boundary. Every matching
  sequence is accounted for with no loss and only bounded duplicates handled by
  a proven idempotent path before an old consumer is deleted. A terminal event
  is acknowledged only after an observable committed DAG effect receipt; the
  print-only callback receives no task authority. Exact-prefix and exact-arity
  positives pass for only `updated`, `completed`, and `failed`, while
  foreign-prefix, added-suffix, and out-of-contract verbs never invoke the
  callback and follow the bounded invalid-message disposition. The gate
  requires a durable invalid-task ledger receipt before `AckTerm`, binds each
  invalid source sequence to one reason and terminal outcome, and proves that
  restart completes an interrupted terminal transition without callback
  invocation, silent ACK loss, or infinite redelivery. Ledger or readback
  failure pauses and quiesces the listener for operator reconciliation. The gate
  inventories and reconciles every pre-existing unnamed or unexpected task
  consumer. The transparent bridge is absent and unrecreatable after restart;
  no replacement stream, consumer, publisher, or identity exists at RP0. The
  unwired strings
  `keystone-daemon` and `keystone-bridge` are never treated as live durable
  evidence. When the bridge is retired, every server-assigned bridge consumer
  and every incompatible binary record in `homeric-agents` has a reviewed
  source-local disposition; complete consumer state proves that no pending or
  unacknowledged delivery is silently deleted. A reviewed exact-sequence
  deletion manifest matches the source gaps or tombstones captured at RP0, the
  target contains no incompatible bridge payload, and restart proves bridge
  absence.
- Where the headroom/discard/seal precondition permits an append, a unique
  sandbox-sink publish originating on each spoke proves the topology inference:
  it returns a hub stream acknowledgement, advances exactly one sequence in
  only the correct hub stream and per-subject state, advances no spoke-local
  store, and reaches only the isolated shadow consumer. Sealed, full, or
  eviction-capable state uses a separately restored shadow store. No topology
  probe binds or ACKs a production durable or reaches GitHub, task, DAG, Loki,
  notification, or other production effect credentials.
- The Telemachy identity publishes a registrar-produced
  `hi.pipeline.epic.{epic_key}.registered` instance and Agamemnon receives it.
  It is denied every `hi.tasks.>` publish, a multi-token or empty epic key, and
  sibling `hi.pipeline.>` subjects; its subscription succeeds only for the
  exact bound-team `hi.tasks.{team_id}.*.*` filter and its own reply inboxes.
- Hermes is the only ordinary producer of the accepted `hi.agents` and
  `hi.tasks` envelopes. Agamemnon, workers, and legacy harnesses are denied
  direct publication. The repaired pinned `hello-myrmidon` binds the existing
  stream/`hello-myrmidon` durable, publishes only exact result and log records,
  obtains expected-stream/sequence PubAcks and an external task-result receipt,
  and ACKs source work only afterward; Hermes alone emits the canonical task
  completion. Completion/log failure, lost PubAck, crash, poison input, and
  restart reconcile without silent ACK, duplicate task execution, or infinite
  NAK. Its former three-stream creation path is denied.
- The exact-pinned optional Scylla loader either binds its reviewed stream,
  `scylla-subscriber` durable, exact filter/domain/TLS, poison ledger, and
  effect-before-ACK path, or is absent and unrecreatable after two restarts.
  `DeliverNew`, create-or-bind, broad `hi.tasks.>`, permissive verb parsing,
  raw endpoint logging, swallowed handler failure, and ACK-after-failure are
  negative fixtures even when the feature defaults off.
- Every retained stream and durable preserves its exact name, owner account,
  domain, complete normalized configuration, and pre-canary state. Each
  ordinary role succeeds only on its exact info, pull, delivery, or ack runtime
  endpoints and is denied every stream/consumer mutation. The reconciler helper
  accepts only the correct owner and canonical manifest digest; bodies that
  alter a subject, source, mirror, transform, republish target, filter,
  delivery subject, start position, replay policy, or unknown field fail before
  the transport records a request. Neighboring names and destructive
  operations without a reviewed disposition are also denied.
- With each retained durable offline in turn, a matching spoke-originated
  message remains stored. After reconnect, an unacknowledged delivery is
  redelivered with the recorded attempt count; after one ack, its stream and
  consumer acknowledgment floors advance exactly once and the message is not
  delivered again on a second reconnect. The former Core paths drain under
  producer deny, bind every source sequence to an idempotent effect receipt or
  exact replay disposition, and create the four exact named durables at the
  first provably uneffected sequence before RP0. Their configuration/state and
  any duplicate-stream sequence transform survive restore. Deliver-new/all,
  current-last, wall-clock, or guessed starts fail. After
  `cutover_committed`, exact ordinary consumers bind and prove their sinks and
  readiness while producer publication remains denied; only the durable
  `consumers_ready` transition permits producer admission. Crash, callback-in-
  flight, missing-effect, delayed publication, lost response, or missing
  sequence mapping enters forward recovery without dropping or duplicating an
  external effect.
- Severing and restoring a leaf connection does not create another stored copy
  in any retained stream. A post-reconnect publish is stored once at the next
  sequence. Unique canary IDs, per-subject state, deleted/lost state, and stream
  sequence reads distinguish expected unacknowledged redelivery from duplicate
  storage.
- No runtime leaf connection is registered for `SYS`, no hub system interest
  appears on a spoke, and no spoke system interest appears on the hub. An
  application identity cannot reach local or remote `SYS`; a local spoke
  `SYS` identity cannot reach hub `SYS` or `HOMERIC`; and publishing the same
  subject text in local `SYS` does not reach `HOMERIC`.
- Server and system monitoring is observed only through each server's local
  `SYS` path by the fixed node-local collector. Argus receives only its closed
  sanitized metric schema over host-local verified mTLS and has no `SYS`
  credential. Unauthenticated or remotely exposed `/varz`, `/jsz`, `/connz`,
  request authority, raw subject/payload fields, and unbounded labels fail the
  gate. If the local `HOMERIC` advisory observer is retained, it receives
  only the exact account-scoped JetStream advisory subjects for the selected
  release and is denied application publication, management requests, other
  account traffic, and all remote `SYS` traffic.
- Each source identity and target identity succeeds only through a separate
  helper process on its manifest-selected server, endpoint, account, API plane,
  stream, consumer set, operation, and exact-release transfer trace. The
  helper loads exactly one identity per process. Neighboring source accounts,
  `SYS`, foreign or unlisted endpoints, premature target authentication,
  source use of the target domain, target use of a source-local API, alternate
  application/system/foreign-inbox delivery subjects, other streams, and
  mismatched bodies fail before a NATS request is sent. The audit contains the
  exact allowed request bodies and matching hashes. Ordinary roles cannot
  snapshot or restore, no migration identity can directly publish `hi.>`, and
  each source, target, and cutover identity cannot authenticate after its own
  revocation. Ordinary producer credentials remain denied until RP1 is
  recorded.
- Snapshot chunks use only the manifest-derived delivery subject. Restore tests
  prove the request identity accepts only the exact server-returned
  `$JS.SNAPSHOT.RESTORE.<stream>.<nuid>` from its authenticated pending request,
  the provisioner grants a second identity only that one publish subject, and
  caller-selected, foreign-session, wrong-stream, replayed, concurrent, expired,
  or wildcard subjects never receive a transfer grant.
- The two independent exact-version, schema-hashed archive/stopped-store
  decoders reject unknown formats and fields and agree on every persisted byte.
  RP0 comparison uses decoded source and target snapshots plus read-only copies
  of fully stopped stores; authenticated INFO corroborates only its exposed
  fields. The comparison exercises every field in normalized
  `StreamConfig`, `StreamState`, `ConsumerConfig`, and `ConsumerState`, including
  per-subject state, deleted gaps, lost data, timestamps, filters, delivery and
  retry policies, pending identities/timestamps, and redelivery counts. RP1
  repeats the stopped-target decode and differs only by the exact canary/timer
  delta ledger. Public `ConsumerInfo`, INFO, or `FastState` summaries alone fail
  this gate and are never claimed to expose hidden pending/redelivery maps.
- Source and target JetStream stores have distinct canonical no-follow roots,
  volume/device, filesystem/mount, root-inode, and allocation identities with
  no bind, link, reflink, writable-snapshot, or device-range overlap. Before
  restore, every source writer and writable handle is absent and the source is
  sealed read-only outside target namespaces. Target write/delete fixtures and
  precommit cleanup leave the source identity, tree digest, and sampled bytes
  unchanged; same-path, alias, overlap, shared-backing, and target-open-source
  fixtures fail closed. Rollback first inhibits restart, revokes target/canary
  identities, stops and reaps every target writer/helper, proves zero sessions,
  push bindings, pull waiters, descriptors, and mappings, then removes only the
  exact target with a deletion receipt, reopens only the verified source, and
  reproduces RP0. Target substitution, post-freeze manifest
  mutation, a nonempty target, and crashes between allocation, freeze,
  source-seal, revalidation, and activation cannot acquire restore authority.
- Synthetic fixtures prove the protected artifact contract without exposing a
  production archive to CI: source/target stores, bridge archives, immutable
  backups, snapshots, copy-on-write descendants, named-reader denial, private
  workspace/file modes,
  no-follow creation, authenticated encryption and distinct key custody, no
  payload in output, preflight capacity, count/byte/free-space failure, crash
  cleanup, deadline enforcement, key destruction, path absence, and the exact
  deletion receipt. A backup or copy-on-write fixture that cannot prove key-
  based erasure fails closed.
- A synthetic cutover admits a production generation and appends post-cutover
  messages. Expiring RP0 and RP1 removes only recovery artifacts and retired
  generations. The admitted store, its production key, and its backups remain
  available; restarting that generation preserves those messages. A deletion
  manifest that includes any admitted object or production key fails closed.
- Final capture completes through the running target's authenticated snapshot
  API before server shutdown. Both decoders then agree on the complete stopped
  state. A timer change between capture and shutdown forces recapture or abort;
  it cannot produce RP1 by omitting the changed field. No step requests a live
  API operation from a stopped server.
- Restart, reconnect, credential rotation, RP0 rollback rehearsal, and all
  failure paths terminate cleanly without credentials in output. The independent
  two-copy ledger rejects foreign writers, stale fencing tokens, corruption,
  divergent copies, and generation mismatch; lost responses read the exact key
  without issuing a second commit. Crash injection around `committed`,
  `consumers_ready`, and `producers_admitted` proves producers never open before
  exact ordinary consumers and sinks are ready, an uncertain or confirmed
  point-of-no-return can never select RP0 rollback, and forward recovery starts
  even when no ordinary traffic was observed. Old application/leaf/SYS/admin/
  migration credentials and every enumerated copy are revoked, erased, and
  freshly denied before producer admission.
- Timer tests bind independently attested clocks, maximum skew, a monotonic
  budget, `MaxAge`, `InactiveThreshold`, and every credential/certificate
  expiry. Near-expiry state blocks or is deterministically expired and captured
  at a new RP0; unrecorded heartbeats and unexpected expiry/deletion fail.
  Rechecks at snapshot, target start, RP1, and point of no return prove the
  remaining lifetime margin and exact canary/timer ledger.

The implementation is complete only after operator-approved live readbacks
iterate the same frozen inventory and prove the same version, account binding,
domain, full stream/consumer state, fan-out, durable replay, authorization
denials, helper audit, sequence reconciliation, and revocation facts while
ordinary producers and consumers remain quiesced through RP1, then prove the
post-commit consumer-ready/producer-denied and producer-admission transitions.
CI evidence and live-state evidence are distinct and both are required.

## Relationship to earlier proposals

Until this ADR is accepted, ADR-009 and ADR-010 remain Proposed and this ADR
supersedes neither one.

If accepted:

- it supersedes ADR-006 only where that ADR names Keystone as the universal
  transport or requires every inter-component exchange to pass through a
  transparent Keystone path. ADR-002's narrower boundary remains: AMP owns
  point-to-point agent messages, while direct least-privilege NATS clients
  publish and durably consume infrastructure events under Hermes' transport
  contract. Keystone retains `keystone-dag` as an ADR-005 consumer, but its
  incompatible transparent NATS bridge is retired. ADR-006's ai-maestro
  removal, component ownership, and migration intent remain accepted;
- it supersedes ADR-009 Decision 3 only where that section permits a generic
  or unsupported leaf credential that cannot bind the connection to
  `HOMERIC`. ADR-009's fail-closed listener authentication, cluster
  authentication, secret-handling, and validation requirements remain
  compatible; and
- it supersedes ADR-010 Decision 3 only where that section splits application
  roles across the `HERMES`, `AGENTS`, `KEYSTONE`, and `TELEMACHY` accounts or
  grants blanket JetStream API access. ADR-010's mutual-TLS identity proposal,
  certificate naming convention, and future operator/NKey/JWT path remain
  compatible.

Accepted ADR-002 and ADR-005 are preserved without modification; the bounded
ADR-006 clauses above are explicitly superseded.

## Consequences

**Positive:**

- Hermes publications and authorized consumers share one subject space, so
  the accepted fan-out and durable replay design can work across leaf nodes.
- One hub-owned domain prevents ambiguous stream placement and eliminates
  spoke-local duplicate storage.
- Separate ordinary-role runtime permissions and a complete-body-validating
  reconciler retain least privilege without misusing tenant isolation; the
  exceptional server-mediated snapshot capability is contained in a separate
  audited helper rather than mischaracterized as an ACL guarantee.
- A currently supported exact release with a fresh complete advisory and
  upgrade review, plus the temporary migration helper, addresses known restore
  and leaf-authorization vulnerabilities before migration authority exists.
- The frozen seven-stream and named-consumer inventory prevents accepted
  dead-letter durability or current compatibility state from disappearing
  during an account-only migration.
- Quiescence, sequence reconciliation, recovery points, and a point of no
  return make data-loss boundaries explicit.

**Negative:**

- Existing account-owned streams and consumers require a coordinated,
  state-preserving migration; changing account names alone is destructive.
- The standalone hub is the sole persistence owner and availability boundary.
  Replication requires a later decision.
- Exact permission lists depend on current client behavior and require traces,
  denial tests, and maintenance as clients evolve.
- Confidential snapshots require bounded encrypted storage, separate key
  custody, capacity management, named readers, retention deadlines, and
  verifiable payload/key deletion after each recovery window.
- A compromised application-account server still shares one application
  subject space; role permissions and host isolation remain essential.

**Neutral:**

- This proposal does not itself change a server pin, NATS subjects, stream
  names, consumer names, component APIs, model/provider defaults, or mesh task
  schemas. It preserves accepted `keystone-dag`; the incompatible Keystone
  paths above must be repaired or retired through separately reviewed runtime
  work before migration.
- Verified authenticated TLS for every credential-bearing connection is a
  mandatory precondition of this decision. Certificate issuance, rotation,
  storage, identity format, and any future cluster-route authentication remain
  separate controls and may be specified by ADR-010 or a later accepted design.
- This topology defines no operator-authored cross-account application-data
  bridge. NATS-managed JetStream system-account exports/imports and domain
  mappings remain internal protocol plumbing inventoried at the selected exact
  release; they do not authorize `hi.>` across accounts. A future tenant bridge
  requires a separate decision with exact subjects, accounts, ownership,
  migration, and authorization evidence.

## References

- [Accepted ADR-002](002-nats-event-bridge.md) — event fan-out and durable
  replay
- [Accepted ADR-005](005-nats-subject-schema.md) — subjects, streams, and the
  `keystone-dag` consumer
- [Accepted ADR-006](006-decouple-from-ai-maestro.md) — clauses explicitly
  bounded and superseded above
- [Proposed ADR-009](009-nats-authentication.md) — fail-closed NATS
  authentication
- [Proposed ADR-010](010-nats-mtls-subject-scoped-auth.md) — mutual TLS and
  role identity proposal
- [Hermes exact-pin stream inventory](https://github.com/HomericIntelligence/Hermes/blob/c89b52ae41f69ce485d616927fd3ad32f78b8332/src/hermes/publisher.py#L239-L289)
- [Hermes Accepted dead-letter ADR](https://github.com/HomericIntelligence/Hermes/blob/c89b52ae41f69ce485d616927fd3ad32f78b8332/docs/adr/ADR-002-dead-letter-strategy.md#L25-L76)
- [Agamemnon exact-pin stream inventory](https://github.com/HomericIntelligence/Agamemnon/blob/bb17afd828a8c164930a30d5095e6b90241f8564/src/nats_client.cpp#L121-L169)
- [Agamemnon exact-pin dial, reconnect, JetStream fallback, and close paths](https://github.com/HomericIntelligence/Agamemnon/blob/bb17afd828a8c164930a30d5095e6b90241f8564/src/nats_client.cpp#L62-L118)
- [Agamemnon exact-pin JetStream/Core publish fallback](https://github.com/HomericIntelligence/Agamemnon/blob/bb17afd828a8c164930a30d5095e6b90241f8564/src/nats_client.cpp#L171-L230)
- [Agamemnon exact-pin Core subscription](https://github.com/HomericIntelligence/Agamemnon/blob/bb17afd828a8c164930a30d5095e6b90241f8564/src/nats_client.cpp#L288-L342)
- [Nestor exact-pin stream inventory](https://github.com/HomericIntelligence/Nestor/blob/6445688c1c27e3d984bde074cb7168a02856f6fa/src/nats_client.cpp#L365-L451)
- [Nestor exact-pin callbacks, reconnect, and connection generation](https://github.com/HomericIntelligence/Nestor/blob/6445688c1c27e3d984bde074cb7168a02856f6fa/src/nats_client.cpp#L24-L199)
- [Nestor exact-pin provision, close, and Core research subscription](https://github.com/HomericIntelligence/Nestor/blob/6445688c1c27e3d984bde074cb7168a02856f6fa/src/nats_client.cpp#L199-L451)
- [Nestor exact-pin JetStream and fire-and-forget Core publishing](https://github.com/HomericIntelligence/Nestor/blob/6445688c1c27e3d984bde074cb7168a02856f6fa/src/nats_client.cpp#L455-L513)
- [Argus exact-pin durable inventory](https://github.com/HomericIntelligence/Argus/blob/59727bb5c86ae7340bc694a3ccd35c055c8df7f8/dashboard/internal/nats/subscriber.go#L322-L330)
- [Argus exact-pin connection, raw URL log, and partial-ready attach](https://github.com/HomericIntelligence/Argus/blob/59727bb5c86ae7340bc694a3ccd35c055c8df7f8/dashboard/internal/nats/subscriber.go#L117-L231)
- [Argus exact-pin subscription, drain, volatile-bus effect, and ACK](https://github.com/HomericIntelligence/Argus/blob/59727bb5c86ae7340bc694a3ccd35c055c8df7f8/dashboard/internal/nats/subscriber.go#L233-L320)
- [Telemachy exact-pin epic-registration publisher](https://github.com/HomericIntelligence/Telemachy/blob/4702a17f4be69b232ead7944b552f85fcc183b41/src/telemachy/github_epic.py#L37-L47)
- [Telemachy exact-pin publish call](https://github.com/HomericIntelligence/Telemachy/blob/4702a17f4be69b232ead7944b552f85fcc183b41/src/telemachy/github_epic.py#L240-L247)
- [Telemachy exact-pin task subscription](https://github.com/HomericIntelligence/Telemachy/blob/4702a17f4be69b232ead7944b552f85fcc183b41/src/telemachy/nats_monitor.py#L87-L92)
- [Keystone exact-pin bridge defaults and subject contract](https://github.com/HomericIntelligence/Keystone/blob/7ad4d1ea163e0ae258ceef5220ebb3c91a6cdb29/include/transport/transparent_bridge.hpp#L44-L59)
- [Keystone exact-pin bridge publish and unwired subscription](https://github.com/HomericIntelligence/Keystone/blob/7ad4d1ea163e0ae258ceef5220ebb3c91a6cdb29/src/transport/transparent_bridge.cpp#L22-L84)
- [Keystone exact-pin outbound routing](https://github.com/HomericIntelligence/Keystone/blob/7ad4d1ea163e0ae258ceef5220ebb3c91a6cdb29/src/core/message_bus.cpp#L66-L115)
- [Keystone exact-pin bridge inbound loop](https://github.com/HomericIntelligence/Keystone/blob/7ad4d1ea163e0ae258ceef5220ebb3c91a6cdb29/src/transport/transparent_bridge.cpp#L139-L209)
- [Keystone exact-pin partial-active attach contract](https://github.com/HomericIntelligence/Keystone/blob/7ad4d1ea163e0ae258ceef5220ebb3c91a6cdb29/include/transport/transparent_bridge.hpp#L79-L91)
- [Keystone exact-pin partial-active regression test](https://github.com/HomericIntelligence/Keystone/blob/7ad4d1ea163e0ae258ceef5220ebb3c91a6cdb29/tests/unit/test_transparent_bridge.cpp#L202-L226)
- [Keystone exact-pin daemon bridge and placeholder DAG callback](https://github.com/HomericIntelligence/Keystone/blob/7ad4d1ea163e0ae258ceef5220ebb3c91a6cdb29/src/daemon/main.cpp#L72-L119)
- [Keystone exact-pin task-listener defaults](https://github.com/HomericIntelligence/Keystone/blob/7ad4d1ea163e0ae258ceef5220ebb3c91a6cdb29/src/daemon/main.cpp#L49-L84)
- [Keystone exact-pin unwired task-listener subscription](https://github.com/HomericIntelligence/Keystone/blob/7ad4d1ea163e0ae258ceef5220ebb3c91a6cdb29/src/network/nats_listener.cpp#L111-L133)
- [Keystone exact-pin terminal-event acknowledgment](https://github.com/HomericIntelligence/Keystone/blob/7ad4d1ea163e0ae258ceef5220ebb3c91a6cdb29/src/network/nats_listener.cpp#L276-L291)
- [Keystone exact-pin permissive task classification](https://github.com/HomericIntelligence/Keystone/blob/7ad4d1ea163e0ae258ceef5220ebb3c91a6cdb29/src/network/nats_listener.cpp#L52-L82)
- [Hermes exact-pin JSON lifecycle envelope](https://github.com/HomericIntelligence/Hermes/blob/c89b52ae41f69ce485d616927fd3ad32f78b8332/src/hermes/publisher.py#L383-L393)
- [Odysseus exact-pin single-harness durable inventory](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/e2e/claude-myrmidon.py#L795-L807)
- [Odysseus exact-pin single-harness processing and ACK loop](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/e2e/claude-myrmidon.py#L815-L852)
- [Odysseus exact-pin multi-harness durable inventory](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/e2e/claude-myrmidon-multi.py#L1096-L1128)
- [Odysseus exact-pin multi-harness processing and ACK loop](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/e2e/claude-myrmidon-multi.py#L1150-L1193)
- [Odysseus exact-pin NATS-to-Loki Compose service](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/docker-compose.crosshost.yml#L40-L53)
- [Odysseus exact-pin cross-host bridge launcher](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/e2e/start-crosshost.sh#L111-L123)
- [Odysseus exact-pin `loki-bridge` runtime consumer](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/e2e/nats-loki-bridge/bridge.py#L20-L79)
- [Odysseus exact-pin Loki ACK-before-HTTP and swallowed push failure](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/e2e/nats-loki-bridge/bridge.py#L91-L129)
- [Myrmidons exact-pin stream creation and `hello-myrmidon` binding](https://github.com/HomericIntelligence/Myrmidons/blob/16a7ed57bff18af737c0a07f50ddcfd9e163e4f4/hello-world/main.cpp#L122-L170)
- [Myrmidons exact-pin completion/log publication and unconditional ACK](https://github.com/HomericIntelligence/Myrmidons/blob/16a7ed57bff18af737c0a07f50ddcfd9e163e4f4/hello-world/main.cpp#L225-L273)
- [Scylla exact-pin optional defaults](https://github.com/HomericIntelligence/Scylla/blob/68427e6ec68ab9baf290db583039345ca18a0668/src/scylla/nats/config.py#L13-L40)
- [Scylla exact-pin create-or-bind, broad filter, ACK, and drain paths](https://github.com/HomericIntelligence/Scylla/blob/68427e6ec68ab9baf290db583039345ca18a0668/src/scylla/nats/subscriber.py#L71-L221)
- [Scylla exact-pin swallowed handler failures and effecting `created` route](https://github.com/HomericIntelligence/Scylla/blob/68427e6ec68ab9baf290db583039345ca18a0668/src/scylla/nats/handlers.py#L22-L76)
- [Scylla exact-pin orchestrator effect handlers](https://github.com/HomericIntelligence/Scylla/blob/68427e6ec68ab9baf290db583039345ca18a0668/src/scylla/nats/handlers.py#L121-L181)
- [Odysseus exact-pin console broad subscriptions](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/tools/odysseus-console.py#L48-L61)
- [Odysseus exact-pin console interview publish and Core subscribe lifecycle](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/tools/odysseus-console.py#L174-L240)
- [Odysseus exact-pin console connection, subscribe, and suppressed shutdown errors](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/tools/odysseus-console.py#L276-L385)
- [Odysseus exact-pin hub account configuration](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/configs/nats/server.conf#L27-L74)
- [Odysseus exact-pin spoke account and leaf configuration](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/configs/nats/leaf.conf#L25-L138)
- [Odysseus exact-pin CI NATS parser scope](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/.github/workflows/ci.yml#L68-L87)
- [Odysseus exact-pin binary-free NATS validator scope](https://github.com/HomericIntelligence/Odysseus/blob/ccce2ccb4fbd0e12562e96c564d43ca3395e6ce4/scripts/validate_nats_config.py#L4-L75)
- [NATS v2.10.22 leaf-remote parser](https://github.com/nats-io/nats-server/blob/v2.10.22/server/opts.go#L2491-L2623)
- [NATS v2.10.22 account-unbound leaf authentication](https://github.com/nats-io/nats-server/blob/v2.10.22/server/auth.go#L1307-L1342)
- [NATS v2.10.22 managed JetStream service export](https://github.com/nats-io/nats-server/blob/v2.10.22/server/jetstream.go#L533-L538)
- [NATS v2.10.22 managed JetStream imports and domains](https://github.com/nats-io/nats-server/blob/v2.10.22/server/jetstream.go#L651-L689)
- [NATS accounts and multitenancy](https://docs.nats.io/learn/security/accounts-and-multitenancy)
- [NATS subject authorization](https://docs.nats.io/learn/security/authorization)
- [NATS wildcard semantics](https://docs.nats.io/concepts/subjects)
- [NATS leaf nodes and JetStream domains](https://docs.nats.io/learn/topologies/leaf-nodes)
- [NATS JetStream domain configuration](https://docs.nats.io/reference/config/jetstream/domain)
- [NATS JetStream disaster recovery](https://docs.nats.io/running-a-nats-service/nats_admin/jetstream_admin/disaster_recovery)
- [NATS server support policy](https://github.com/nats-io/nats-server/blob/main/RELEASES.md)
- [NATS server release inventory](https://github.com/nats-io/nats-server/releases)
- [NATS Security Note 2026-12: CVE-2026-33222](https://advisories.nats.io/CVE/secnote-2026-12.txt)
- [NATS Security Note 2026-20: CVE-2026-58254](https://advisories.nats.io/CVE/secnote-2026-20.txt)
- [GitHub Advisory GHSA-p3j5-5hrq-p75h: CVE-2026-58254](https://github.com/advisories/GHSA-p3j5-5hrq-p75h)
- [Historical NATS server v2.12.12 release](https://github.com/nats-io/nats-server/releases/tag/v2.12.12)
