# ADR 024: One Homeric NATS Application Account with Per-Role Authorization

**Status:** Proposed

> **Proposal status:** This ADR does not change checked-in configuration,
> server versions, or deployed state. Acceptance authorizes a separate,
> operator-approved implementation; merge alone does not.

**If accepted, supersedes:** only the conflicting portions of Proposed
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

The current checked-in NATS configuration attempts to add least-privilege
authorization by placing Hermes, agents, Keystone, and Telemachy in four
different accounts. That topology conflicts with the accepted event contract.
A NATS account is an isolated subject space: identical subject names in two
accounts do not exchange messages. JetStream state is also account-owned.
Without explicit exports and imports, a message published by Hermes in its
account cannot reach a subscriber or durable consumer in another application
account.

Adding one leaf remote for each application account authenticates and binds
those leaf connections, but it does not repair that isolation. It creates four
separate subject spaces on every spoke and hub. The accepted use case is one
application event bus with multiple authorized roles, not four mutually
isolated tenants.

The leaf configuration also uses a scalar `token` field in remote entries that
the currently pinned NATS server does not accept. More importantly, that
v2.10.22 pin predates the fix for CVE-2026-33222, in which a user with narrowly
scoped stream-restore permission could restore under other stream names. NATS
fixed that vulnerability in v2.11.15 and v2.12.6. A later leaf authorization
vulnerability remained in v2.12.11 and v2.14.2 and was fixed separately in
v2.12.12 and v2.14.3. A single linear version comparison would therefore admit
known-vulnerable v2.14.0 through v2.14.2.

## Decision

If this ADR is formally accepted, the HomericIntelligence NATS topology will
use one application account named `HOMERIC`, one separate system account named
`SYS`, and one hub-owned JetStream domain.

### 1. Require a branch-safe, immutable server pin first

Before changing accounts, granting snapshot or restore authority, or migrating
data, the selected NATS release must satisfy this branch-aware predicate:

- a v2.12.x release must be v2.12.12 or later;
- a v2.14.x release must be v2.14.3 or later; and
- a later stable branch is eligible only when an implementation-time review of
  every current official NATS advisory records that the exact release is not
  affected and its upgrade notes are compatible with this topology.

Every branch older than v2.12, every unlisted intermediate branch, every
prerelease, and every release that does not satisfy its own branch minimum is
rejected. Passing this predicate makes a release eligible, not selected: the
implementation binds one exact stable server build and digest, then runs that
identical build on every hub and spoke. Mixed-version operation is not an
accepted migration state.

The version upgrade is a separate first phase that preserves the old account
topology and proves restart, client, leaf, and JetStream compatibility. The
topology migration begins only after live version readbacks show the selected
patched build on every node. The implementation PR records the exact image or
binary digest and the signed advisory-review record. Version-gate tests reject
v2.10.22, v2.11.15, v2.12.11, v2.14.0, v2.14.1, v2.14.2, prereleases, and an
unreviewed future branch; they accept v2.12.12 and v2.14.3 as their respective
boundary cases. Runtime readback must then match the selected exact digest,
not merely an eligible semantic version.

The existing v2.10.22 parser tests may describe the pre-migration defect, but
they cannot satisfy this ADR's implementation gate.

### 2. Preserve and classify the exact-pinned live inventory

`HOMERIC` is the single subject space for application traffic. It contains the
accepted `hi.agents.>` and `hi.tasks.>` subjects, the `homeric-agents` and
`homeric-tasks` streams, and the `keystone-dag` durable consumer. This decision
does not rename those interfaces or change their retention, delivery, replay,
or at-least-once semantics.

Other current or future application subjects may share `HOMERIC` only when
their own accepted contract or exact-pinned runtime authority permits them.
This ADR does not accept a Proposed mesh contract merely by placing its
subjects in an account.

`SYS` is designated by `system_account = SYS`. It carries NATS monitoring,
advisory, and management traffic. Application clients do not connect through
`SYS`, and `SYS` is not a back door to `hi.>` traffic. Anonymous fallback into
`$G` remains disabled.

The repository inventory for this decision is bound to Hermes
`c89b52ae41f69ce485d616927fd3ad32f78b8332`, Agamemnon
`bb17afd828a8c164930a30d5095e6b90241f8564`, Nestor
`6445688c1c27e3d984bde074cb7168a02856f6fa`, Argus
`59727bb5c86ae7340bc694a3ccd35c055c8df7f8`, Keystone
`7ad4d1ea163e0ae258ceef5220ebb3c91a6cdb29`, Telemachy
`4702a17f4be69b232ead7944b552f85fcc183b41`, and the Odysseus
`f8e211f118de4ae3bd5d8b3e24f46f63c258a2ba` legacy harnesses. At those pins,
the migrate-or-retire disposition is:

| Stream | Captured subjects | Exact-pinned roles and named durable consumers | Required disposition |
|---|---|---|---|
| `homeric-agents` | `hi.agents.>` | Hermes and Agamemnon provision or publish; Argus `atlas-agents` consumes | Migrate the full stream and `atlas-agents`; preserve ADR-005 |
| `homeric-tasks` | `hi.tasks.>` | Hermes and Agamemnon provision or publish; Agamemnon and Telemachy subscribe; legacy harnesses publish; Keystone `keystone-dag` and Argus `atlas-tasks` consume | Migrate the full stream and both named durables; preserve ADR-005 |
| `homeric-deadletter` | `hi.deadletter.>` | Hermes provisions and publishes; no exact-pinned named durable | Migrate in full; Hermes retains ownership under the Hermes repository's Accepted dead-letter ADR-002 |
| `homeric-myrmidon` | `hi.myrmidon.>` | Agamemnon, Nestor, and both legacy harnesses provision or publish; Argus `atlas-myrmidon` and the legacy durable set below consume | Migrate the stream and every named durable unless the separate retirement gate below has passed |
| `homeric-research` | `hi.research.>` | Agamemnon and Nestor provision or publish; Nestor has a core subscription; Argus `atlas-research` consumes | Migrate the full stream and `atlas-research` |
| `homeric-pipeline` | `hi.pipeline.>` | Agamemnon provisions and core-subscribes to pipeline registration; Argus `atlas-pipeline` consumes | Migrate the full stream and `atlas-pipeline` |
| `homeric-logs` | `hi.logs.>` | Agamemnon provisions and publishes; Nestor and both legacy harnesses publish; Argus `atlas-logs` consumes; Odysseus cross-host launch paths run a NATS-to-Loki consumer that creates durable `loki-bridge` | Migrate the full stream, `atlas-logs`, and `loki-bridge` unless the separate retirement gate below has passed |

The source defaults are not migration authority. At these pins, Agamemnon
proposes Limits retention with 50 MiB and one-hour limits for its six streams.
Nestor instead proposes WorkQueue retention for `homeric-research` and Limits
retention for `homeric-myrmidon`, without the same limits. The legacy harnesses
also propose their own limits. These reconcilers treat an existing stream as
success without proving configuration equality, so startup order can determine
the live configuration. RP0 must therefore capture the complete live objects.
The selected owner must preserve those objects during this migration; a source
default can change them only through a separately reviewed decision.

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

Argus also contains the older `argus-jetstream-consumer` durable on alternate
streams `hi_agents` and `hi_tasks`, which capture the same subjects as the
canonical `homeric-agents` and `homeric-tasks` streams and therefore cannot be
created alongside them in one account. Before this migration, a separate
reviewed retirement must quiesce that consumer, reconcile or archive any
unique messages and delivery state, verify the Atlas replacements, and delete
both alternate streams and consumers from live state. If either alternate
stream remains at RP0, migration stops.

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
- `HOMERIC` is JetStream-enabled on the hub and is the only account that owns
  application streams. `SYS` owns no application stream.
- `homeric-agents`, `homeric-tasks`, `homeric-deadletter`,
  `homeric-myrmidon`, `homeric-research`, `homeric-pipeline`, and
  `homeric-logs` each have one replica on the hub. Their normalized live
  subject, retention, storage, duplicate-window, limit, and consumer
  configuration is preserved.
- Agamemnon is the configuration reconciler for `homeric-agents`,
  `homeric-tasks`, `homeric-myrmidon`, `homeric-research`,
  `homeric-pipeline`, and `homeric-logs`. Hermes remains the configuration and
  semantic owner of `homeric-deadletter`. Before cutover, Hermes stops
  reconciling agents/tasks. Nestor, the legacy harnesses, and any retained
  NATS-to-Loki bridge stop reconciling shared streams; they retain only their
  runtime publish or consume authority.
- Spokes are Core NATS leaf servers only. They have no `jetstream {}` storage,
  no local metadata leader, no local stream, mirror, or source, and no
  JetStream-enabled account.
- A replicated hub cluster, spoke-local storage, mirrors, and sources are
  outside this decision and require a later ADR and migration.

The hub domain maps `$JS.homeric-hub.API.>` to its local `$JS.API.>` service.
Every application client, whether connected to the hub or a spoke, selects the
`homeric-hub` domain and therefore sends management and consumer requests to
`$JS.homeric-hub.API.>`. The domain prefix is the only JetStream API prefix
permitted to application and migration users. Unqualified `$JS.API.>` service
interest may also propagate over the leaf, so every such user explicitly
denies the complete `$JS.API.>` subtree rather than treating absence of a
spoke-local JetStream process as an authorization control. Application data
remains on its unchanged `hi.>` subject families. Reply inboxes, consumer
delivery subjects, and `$JS.ACK.>` flow through the same `HOMERIC` leaf
binding.

A stream's interest on the hub propagates across the leaf. A spoke-originated
publish is therefore stored once by the hub stream; it is not stored locally
and then mirrored. A JetStream publish acknowledgement returned to a spoke
must identify the hub-owned stream and sequence.

### 4. Authorize roles inside `HOMERIC`

Account membership provides the shared event bus; distinct credentials and
subject permissions provide least privilege. Hermes, Agamemnon, Nestor,
worker, Keystone, Telemachy, Argus, a retained NATS-to-Loki bridge, and any
retained legacy-harness identities are separate users in `HOMERIC`. Every role
has explicit publish and subscribe allow lists. A user without a permissions
block is not an acceptable implementation of this decision.

The implementation must start from these boundaries and narrow them when the
exact-pinned client inventory demonstrates that a capability is unnecessary:

| Role | Application publish | Application subscribe | JetStream authority |
|---|---|---|---|
| Hermes | `hi.agents.>`, `hi.tasks.>`, `hi.deadletter.>` | Its own reply inboxes | Exact create, update, and info endpoints for `homeric-deadletter` only |
| Agamemnon | Its exact-pinned `hi.agents.>`, `hi.tasks.>`, `hi.myrmidon.>`, and `hi.logs.>` subjects | Exact task-state and pipeline-registration subjects plus its own reply inboxes | Exact create, update, and info endpoints for its six owned streams only |
| Nestor | Exact `hi.research.{id}`, `hi.myrmidon.research.chief-architect.task.{id}`, and `hi.logs.nestor.>` subjects | `hi.research.>` and its own reply inboxes | Stream info only for `homeric-research` and `homeric-myrmidon`; no create or update after migration |
| Worker or retained legacy harness | Only its exact dispatch-result, task-state, and log subjects | Only its listed delivery filters and own reply inboxes | Exact info, create/update, pull, and ack endpoints for only its listed durable on `homeric-myrmidon`; no stream administration |
| Keystone | None | `keystone-dag` delivery and its own reply inboxes | Exact stream-info, consumer-info, pull, and ack endpoints for `keystone-dag` on `homeric-tasks` |
| Telemachy | Exact-pinned task events that the workflow runner produces | `hi.tasks.{team_id}.*.*` and its own reply inboxes | None for its current core subscription; any future durable requires separate inventory and grants |
| Argus Atlas | None | Delivery subjects for the six `atlas-*` consumers and its own reply inboxes | Exact info, create/update, pull or delivery, and ack endpoints for `atlas-agents`, `atlas-tasks`, `atlas-myrmidon`, `atlas-research`, `atlas-pipeline`, and `atlas-logs` only |
| NATS-to-Loki bridge, when retained | None | `loki-bridge` delivery and its own reply inboxes | Exact stream-info, consumer-info, create/update, pull, and ack endpoints for `loki-bridge` on `homeric-logs`; no stream creation or update |
| System operator | None in `HOMERIC` | None in `HOMERIC` | System monitoring and management in local `SYS` only |

No ordinary role receives an unrestricted `hi.>`, `$JS.API.>`, or
`$JS.homeric-hub.API.>` grant. Request/reply inbox, consumer-delivery,
acknowledgment, and management subjects are enumerated from an exact-pinned
client trace before implementation. The resulting allow lists are checked in
and exercised by positive and negative authorization tests.

For a stream named `<stream>`, an owner grant expands to the individual
`$JS.homeric-hub.API.STREAM.CREATE.<stream>`,
`$JS.homeric-hub.API.STREAM.UPDATE.<stream>`, and
`$JS.homeric-hub.API.STREAM.INFO.<stream>` request subjects actually used by
the selected client. For a durable named `<consumer>`, a consumer grant expands
only to the exact selected-client variant among
`$JS.homeric-hub.API.CONSUMER.CREATE.<stream>.<consumer>`,
`$JS.homeric-hub.API.CONSUMER.CREATE.<stream>.<consumer>.<literal-filter>`, and
`$JS.homeric-hub.API.CONSUMER.DURABLE.CREATE.<stream>.<consumer>`, plus
`$JS.homeric-hub.API.CONSUMER.INFO.<stream>.<consumer>`. A pull consumer also
gets `$JS.homeric-hub.API.CONSUMER.MSG.NEXT.<stream>.<consumer>`. The matching
acknowledgment grant is the dynamic `$JS.ACK.<stream>.<consumer>.>` subtree.
These placeholders must be expanded to the static inventory above; they do not
authorize a wildcard stream or consumer name. Push delivery subjects and reply
inbox prefixes are unique per identity. If a client uses a different endpoint
variant, its exact trace replaces the listed endpoint rather than adding a
broad API subtree.

This ownership split requires implementation changes before cutover: Hermes
must stop reconciling agents/tasks, Nestor and the legacy harnesses must stop
reconciling shared streams, and the retired Argus consumer must stop creating
alternate streams. A retained NATS-to-Loki bridge must replace its
subject-based stream lookup and add-stream fallback with exact
`homeric-logs` stream-info access and fail closed if the stream is absent. A
denied management call or attempted configuration drift is a failed migration,
not a reason to widen the role.

Certificate identities proposed by ADR-010 may remain the authentication
identities for these users. This ADR changes their account placement, not the
requirement for distinct role identity.

### 5. Bind one application leaf and keep `SYS` local

Each spoke has exactly one remote for this topology. Its static local account
is `HOMERIC`, and the hub's corresponding leaf user authenticates and binds the
incoming connection to hub account `HOMERIC`. The outgoing credential syntax
must be supported by the selected server pin, such as credentials in the
complete remote URL or, if separately adopting operator mode, a supported
credentials file. An unsupported scalar `token` field is not permitted.

Leaf credentials identify the topology connection. They do not replace
end-client role credentials or subject authorization. A client on a spoke
still authenticates as its exact Hermes, Agamemnon, Nestor, worker, Keystone,
Telemachy, Argus, NATS-to-Loki, or retained legacy role in the local `HOMERIC`
account, and the origin server enforces that user's permissions. Distinct leaf
credentials are issued per spoke so one host can be revoked without rotating
every host.

`SYS` is deliberately **not** extended over a leaf. The hub and every spoke
have separate local `SYS` credentials, no remote has `account: SYS`, and no
system-account interest crosses the application leaf. Operators inspect each
server's local system account through its protected administrative path. This
keeps a compromised spoke system identity from acquiring hub system authority.

### 6. Put temporary migration authority behind one validating helper

Snapshot and restore run only through a single-purpose
`homeric-nats-migration-helper` on the approved migration host. The helper is
the only process allowed to read the time-limited
`homeric-migration-<change-id>` credential. Its command interface accepts an
approved operation, the frozen migration manifest, and one stream name from
the seven-row retained inventory; it accepts no raw NATS subject or arbitrary
request body.

For each retained stream, the credential enumerates
`$JS.homeric-hub.API.STREAM.SNAPSHOT.<stream>`,
`$JS.homeric-hub.API.STREAM.RESTORE.<stream>`, and
`$JS.homeric-hub.API.STREAM.INFO.<stream>`. It also enumerates
`$JS.homeric-hub.API.CONSUMER.INFO.<stream>.<consumer>` for every retained
named durable on that stream. The selected release's dynamic
`$JS.SNAPSHOT.ACK.<stream>.>` and `$JS.SNAPSHOT.RESTORE.<stream>.>` subtrees,
plus unique helper-owned reply and snapshot-delivery prefixes, complete its
grant. It receives no direct `hi.>` publish grant and no stream create, update,
delete, purge, message-delete, general consumer-management, leaf, route,
system-account, or wildcard JetStream administration permission.

NATS stream snapshot requests contain a caller-selected `deliver_subject` and
the server publishes chunks to that subject. Client publish permissions do not
constrain that server-mediated publication, so the migration credential alone
is **not** a least-privilege boundary. The helper contains that capability by:

1. hardcoding `_MIGRATION.<change-id>.snapshot.<stream>.<nonce>` as the only
   snapshot delivery shape, with `<stream>` selected from the frozen manifest;
2. constructing the canonical request internally with consumers included and
   message checking enabled;
3. validating a restore request's embedded stream name and configuration
   against the same manifest before it opens a NATS request; and
4. appending the exact canonical request-body bytes, subject, operation,
   stream, timestamp, and body SHA-256 to the operator audit record before
   transmission. Credential material and snapshot payloads are not logged.

Unit and integration tests pass alternate `hi.>`, `$SYS.>`, foreign inbox, and
other-stream delivery subjects or restore bodies to the helper and prove they
are rejected before the transport records any NATS request. Broker-side tests
separately prove that the credential cannot directly publish application
traffic and that snapshot or restore requests for a stream outside the frozen
inventory are denied.

The credential expires no later than the maintenance-window deadline. If the
chosen static authentication mechanism cannot encode expiry, the operator
removes the identity, reloads the configuration, and terminates its connection
before leaving the window. The operator records credential issuance, helper
binary digest, connection identity, exact commands, audit hash, artifact
hashes, and revocation.

Before migration, every ordinary role in the table above must fail snapshot
and restore requests. After migration, the retired migration credential must
fail authentication and the ordinary roles must still fail those requests. No
credential on a release rejected by the branch-aware predicate may be granted
permission to publish to a restore endpoint.

Bounded canary checks use separate, short-lived
`homeric-cutover-<role>-<change-id>` identities. Each copies only the exact
application publish, subscribe, inbox, and domain API permissions of the role
being tested; it receives no snapshot, restore, system, route, or leaf
authority. These identities are audited and expire or are removed and
disconnected under the same rules as the migration identity. Ordinary service
credentials remain in maintenance deny throughout canary execution.

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

The cutover then follows this order:

1. Stop task and research admission and every autonomous producer for all seven
   captured subject families. Enforce a temporary server-side maintenance deny
   so ordinary producer credentials cannot publish during the window.
2. Let every retained durable drain in-flight work, require
   `num_ack_pending = 0`, stop all durable and core consumers, and prove that
   every stream last sequence and complete consumer state remains unchanged
   across two bounded readbacks. Any nonempty pending/redelivery map, nonzero
   pending ack, advancing sequence, or unclassified client aborts migration;
   an undelivered backlog may remain only when represented exactly in state.
3. Use the helper to take final snapshots of every retained stream, with
   consumer state included, only after quiescence. Extract, canonicalize, and
   hash the complete objects above as recovery point **RP0**, plus the frozen
   inventory, request audit, snapshot hashes, and source server/account/domain
   identity.
4. Keep the old rendered configuration, credentials, store, RP0 snapshots,
   and manifest immutable. Restore the target `HOMERIC` streams and consumers
   on `homeric-nats-hub`, then require byte-equivalent canonical values for
   every non-topology RP0 field before any canary. Source-code defaults never
   replace the actual live configurations recorded in RP0.
5. Keep autonomous producers quiesced and ordinary production credentials in
   maintenance deny. Use only the short-lived cutover identities for bounded,
   uniquely identified canaries covering every retained stream, subject family,
   role permission set, and durable-consumer configuration in the acceptance
   tests below. Reconcile the exact stream, per-subject, consumer-delivered,
   acknowledgment-floor, pending, and redelivery deltas caused by each canary.
6. Revoke the migration and cutover identities, complete their authentication
   and authorization negative tests, and record recovery point **RP1**
   containing the same complete normalized objects plus an explicit canary
   delta ledger. Every change from RP0 must be attributable to that ledger.
   Only then may the operator remove the maintenance deny and approve resuming
   ordinary producers and consumers.

The **point of no return** is the first ordinary production publish or consumer
acknowledgment accepted after that explicit approval. Before it, rollback
discards the target state, restores the previous topology at RP0, verifies
RP0, and then resumes the old producers and consumers. Canary records are
intentionally absent from that rollback.

After the point of no return, RP0 is no longer a safe rollback because it would
discard new publications or acknowledgments. A failure then triggers forward
recovery: quiesce again, capture a new recovery point from the target, and
repair or restore from that state. Dual writes to old and new accounts are
never permitted.

### 8. Make topology, replay, and denial executable acceptance gates

Hosted CI for the implementation runs the exact digest-pinned server build
with one hub and at least two spokes. It must prove all of the following:

- The version predicate rejects every listed lower boundary and an unreviewed
  future branch, accepts v2.12.12 and v2.14.3 as branch boundary examples, and
  live readback matches the one selected digest on every node.
- Static configuration has one local `HOMERIC` remote per spoke, a hub leaf
  user mapped to `HOMERIC`, no `SYS` remote, JetStream enabled only for hub
  `HOMERIC`, and domain `homeric-hub` only on the hub.
- Static parsing shows each spoke remote's selected local account is exactly
  `HOMERIC`. Missing credentials and syntactically valid but incorrect
  credentials are rejected and register no leaf. A static local-account check
  proves the spoke selects `HOMERIC`. With the dedicated valid leaf credential,
  runtime readbacks independently show the spoke's outbound local account and
  the hub's accepted remote account are both `HOMERIC`. Separate checks prove
  that `SYS` has no remote binding and that cross-account access is denied.
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
- A publish originating on each spoke for each of the seven captured subject
  families returns a hub stream acknowledgement, advances only the correct hub
  stream and per-subject state by exactly one sequence, and reaches an
  authorized subscriber on the other side.
- Every retained stream and durable preserves its exact name, owner account,
  domain, complete normalized configuration, and pre-canary state. Each
  ordinary role succeeds only on the individual API endpoints assigned in
  section 4 and receives a permission denial for the neighboring stream,
  consumer, and management operation.
- With each retained durable offline in turn, a matching spoke-originated
  message remains stored. After reconnect, an unacknowledged delivery is
  redelivered with the recorded attempt count; after one ack, its stream and
  consumer acknowledgment floors advance exactly once and the message is not
  delivered again on a second reconnect. Core-only subscriptions are tested
  separately and are not mislabeled durable.
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
- The migration helper snapshots and restores each retained stream and no
  other. Alternate application, system, foreign-inbox, other-stream delivery
  subjects, and mismatched restore bodies fail before a NATS request is sent;
  the audit contains the exact allowed request bodies and matching hashes.
  Ordinary roles cannot snapshot or restore, the credential cannot directly
  publish `hi.>`, and the migration credential cannot authenticate after
  revocation. Cutover identities cannot snapshot or restore and cannot
  authenticate after revocation; ordinary producer credentials remain denied
  until RP1 is recorded.
- RP0 source-to-target comparison exercises every field in normalized
  `StreamConfig`, `StreamState`, `ConsumerConfig`, and `ConsumerState`, including
  per-subject state, deleted gaps, lost data, timestamps, filters, delivery and
  retry policies, pending identities/timestamps, and redelivery counts. RP1
  differs only by the exact canary delta ledger.
- Restart, reconnect, credential rotation, RP0 rollback rehearsal, and all
  failure paths terminate cleanly without credentials in output.

The implementation is complete only after operator-approved live readbacks
iterate the same frozen inventory and prove the same version, account binding,
domain, full stream/consumer state, fan-out, durable replay, authorization
denials, helper audit, sequence reconciliation, and revocation facts while
ordinary producers and consumers remain quiesced. CI evidence and live-state
evidence are distinct and both are required.

## Relationship to earlier proposals

Until this ADR is accepted, ADR-009 and ADR-010 remain Proposed and this ADR
supersedes neither one.

If accepted:

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

Accepted ADR-002 and ADR-005 are preserved without modification.

## Consequences

**Positive:**

- Hermes publications and authorized consumers share one subject space, so
  the accepted fan-out and durable replay design can work across leaf nodes.
- One hub-owned domain prevents ambiguous stream placement and eliminates
  spoke-local duplicate storage.
- Separate ordinary-role credentials and exact endpoint permissions retain
  least-privilege authorization without misusing tenant isolation; the
  exceptional server-mediated snapshot capability is contained in one audited
  helper rather than mischaracterized as an ACL guarantee.
- A branch-aware patched-version predicate and temporary migration helper
  address known restore and leaf-authorization vulnerabilities before
  migration authority exists.
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
- A compromised application-account server still shares one application
  subject space; role permissions and host isolation remain essential.

**Neutral:**

- This proposal does not itself change a server pin, NATS subjects, stream
  names, consumer names, component APIs, model/provider defaults, or mesh task
  schemas.
- TLS, certificate lifecycle, secret storage, and cluster-route authentication
  remain separate controls.
- Cross-account exports/imports remain available for a future true tenant
  boundary, but are unnecessary for the current shared event bus.

## References

- [Accepted ADR-002](002-nats-event-bridge.md) — event fan-out and durable
  replay
- [Accepted ADR-005](005-nats-subject-schema.md) — subjects, streams, and the
  `keystone-dag` consumer
- [Proposed ADR-009](009-nats-authentication.md) — fail-closed NATS
  authentication
- [Proposed ADR-010](010-nats-mtls-subject-scoped-auth.md) — mutual TLS and
  role identity proposal
- [Hermes exact-pin stream inventory](https://github.com/HomericIntelligence/Hermes/blob/c89b52ae41f69ce485d616927fd3ad32f78b8332/src/hermes/publisher.py#L239-L289)
- [Hermes Accepted dead-letter ADR](https://github.com/HomericIntelligence/Hermes/blob/c89b52ae41f69ce485d616927fd3ad32f78b8332/docs/adr/ADR-002-dead-letter-strategy.md#L25-L76)
- [Agamemnon exact-pin stream inventory](https://github.com/HomericIntelligence/Agamemnon/blob/bb17afd828a8c164930a30d5095e6b90241f8564/src/nats_client.cpp#L121-L169)
- [Nestor exact-pin stream inventory](https://github.com/HomericIntelligence/Nestor/blob/6445688c1c27e3d984bde074cb7168a02856f6fa/src/nats_client.cpp#L365-L451)
- [Argus exact-pin durable inventory](https://github.com/HomericIntelligence/Argus/blob/59727bb5c86ae7340bc694a3ccd35c055c8df7f8/dashboard/internal/nats/subscriber.go#L322-L330)
- [Odysseus single-harness durable inventory](../../e2e/claude-myrmidon.py#L5849-L5874)
- [Odysseus multi-harness durable inventory](../../e2e/claude-myrmidon-multi.py#L8040-L8082)
- [Odysseus exact-pin NATS-to-Loki Compose service](https://github.com/HomericIntelligence/Odysseus/blob/f8e211f118de4ae3bd5d8b3e24f46f63c258a2ba/docker-compose.crosshost.yml#L40-L53)
- [Odysseus exact-pin cross-host bridge launcher](https://github.com/HomericIntelligence/Odysseus/blob/f8e211f118de4ae3bd5d8b3e24f46f63c258a2ba/e2e/start-crosshost.sh#L111-L123)
- [Odysseus exact-pin `loki-bridge` runtime consumer](https://github.com/HomericIntelligence/Odysseus/blob/f8e211f118de4ae3bd5d8b3e24f46f63c258a2ba/e2e/nats-loki-bridge/bridge.py#L20-L79)
- [NATS accounts and multitenancy](https://docs.nats.io/learn/security/accounts-and-multitenancy)
- [NATS subject authorization](https://docs.nats.io/learn/security/authorization)
- [NATS wildcard semantics](https://docs.nats.io/concepts/subjects)
- [NATS leaf nodes and JetStream domains](https://docs.nats.io/learn/topologies/leaf-nodes)
- [NATS JetStream domain configuration](https://docs.nats.io/reference/config/jetstream/domain)
- [NATS JetStream disaster recovery](https://docs.nats.io/running-a-nats-service/nats_admin/jetstream_admin/disaster_recovery)
- [NATS Security Note 2026-12: CVE-2026-33222](https://advisories.nats.io/CVE/secnote-2026-12.txt)
- [NATS Security Note 2026-20: leaf trace authorization](https://advisories.nats.io/CVE/secnote-2026-20.txt)
- [NATS server v2.12.12 release](https://github.com/nats-io/nats-server/releases/tag/v2.12.12)
- [NATS server v2.12.12 JetStream API and domain mappings](https://github.com/nats-io/nats-server/blob/v2.12.12/server/jetstream_api.go)
- [NATS server v2.12.12 snapshot request definition](https://github.com/nats-io/nats-server/blob/v2.12.12/server/jetstream_api.go#L561-L565)
- [NATS server v2.12.12 snapshot validation and delivery path](https://github.com/nats-io/nats-server/blob/v2.12.12/server/jetstream_api.go#L4418-L4589)
- [NATS server v2.12.12 stream and consumer state definitions](https://github.com/nats-io/nats-server/blob/v2.12.12/server/store.go#L164-L179)
- [NATS server v2.12.12 consumer pending and redelivery state](https://github.com/nats-io/nats-server/blob/v2.12.12/server/store.go#L385-L396)
- [NATS server v2.12.12 leaf implementation](https://github.com/nats-io/nats-server/blob/v2.12.12/server/leafnode.go)
- [NATS server v2.12.12 JetStream-over-leaf tests](https://github.com/nats-io/nats-server/blob/v2.12.12/server/jetstream_leafnode_test.go)
