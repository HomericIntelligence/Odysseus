<!-- GENERATED FILE — DO NOT EDIT.
     Source: e2e/tests/<category>/*.sh headers (lines 2-3).
     Regenerate: python3 e2e/tools/gen_test_matrix.py -->

# E2E Test Coverage Matrix

Maps each scenario test in `e2e/tests/` to the scenario IDs and the system properties it verifies. Tests marked **T4** are partial on the default topology and fully exercised only under the T4 (multi-container) topology — i.e. intentionally deferred on single-node runs.

**Totals:** 38 tests, 65 unique scenario IDs covered, 7 T4-only (deferred on the default topology).

## Chaos

| Test file | Title | Scenario IDs | Verifies | Topology |
| --- | --- | --- | --- | --- |
| `concurrent-faults.sh` | Concurrent Faults | E08, E09, E13 | fault injection during task processing, cascading faults | Any |
| `fault-injection-api.sh` | Fault Injection API | E01, E02, E03, E04 | Agamemnon /v1/chaos/* CRUD lifecycle | Any |
| `network-latency.sh` | Network Latency Injection | E10 | tasks complete even with 500ms artificial delay | T4 |
| `random-restart.sh` | Random Service Restart | E11 | system recovers after Agamemnon restart mid-fan-out | Any |
| `split-brain.sh` | Split-Brain NATS Cluster | E12 | one partition survives in clustered NATS | T4 |

## Fault

| Test file | Title | Scenario IDs | Verifies | Topology |
| --- | --- | --- | --- | --- |
| `agamemnon-crash.sh` | Agamemnon Crash | A03, A04 | tasks in NATS survive crash, new tasks flow after restart | Any |
| `backlog-drain.sh` | Backlog Drain | A18 | tasks queue in NATS when myrmidon is down, drain when it comes back | Any |
| `connection-timeout-graceful.sh` | Graceful Degradation on NATS Outage | A11 | Agamemnon REST API works even when NATS is unreachable | Any |
| `connection-timeout.sh` | Connection Timeout | A11 | Agamemnon starts gracefully with unreachable NATS | Any |
| `hermes-reconnect.sh` | Hermes NATS Reconnect | A17 | Hermes survives NATS disruption and resumes publishing | Any |
| `jetstream-disk-full.sh` | JetStream Disk Full | A09 | system behavior when JetStream storage exhausted | T4 |
| `message-ordering.sh` | Out-of-Order Message Arrival | A16 | FIFO delivery via JetStream even under rapid publishing | Any |
| `myrmidon-crash.sh` | Myrmidon Crash | A05, A06 | task stays pending when myrmidon down, new tasks process after restart | Any |
| `nats-crash-reconnect.sh` | NATS Crash and Reconnection | A01, A02 | Agamemnon survives NATS crash, clients reconnect after restart | Any |
| `network-partition.sh` | Network Partition | A07, A08 | iptables-based partition, message flow resumes after heal | T4 |
| `partial-delivery.sh` | Partial Message Delivery | A15 | no partial messages in NATS stream after mid-publish kill | T4 |
| `signal-handling.sh` | Signal Handling | A13, A14 | SIGKILL vs SIGTERM behavior differences | Any |
| `slow-consumer.sh` | Slow Consumer | A10 | NATS handles slow consumer without dropping other messages | Any |
| `stale-subscription.sh` | Stale Subscription Recovery | A12 | unsubscribe → send tasks → resubscribe → new tasks arrive | Any |

## Perf

| Test file | Title | Scenario IDs | Verifies | Topology |
| --- | --- | --- | --- | --- |
| `backpressure.sh` | Backpressure | B09, B10 | queue depth grows when consumer slow, then drains | Any |
| `connection-pool.sh` | Connection Pool Scaling | B12 | 5 myrmidon replicas consuming from same subject | T4 |
| `fan-out.sh` | Concurrent Task Fan-Out | B06, B07, B08 | N simultaneous tasks all complete within timeout | Any |
| `large-payload.sh` | Large Payload | B11 | 1MB NATS message — no truncation | Any |
| `latency.sh` | Latency Measurement | B04, B05 | task round-trip P50/P95/P99, Hermes webhook latency | Any |
| `memory-usage.sh` | Memory Usage | B13, B14 | Agamemnon RSS after bulk operations, NATS JetStream memory | Any |
| `throughput.sh` | Message Throughput | B01, B02, B03 | msgs/sec at various payload sizes, saturating rate | Any |

## Protocol

| Test file | Title | Scenario IDs | Verifies | Topology |
| --- | --- | --- | --- | --- |
| `dead-letter.sh` | Dead Letter Handling | C08 | publishing to non-existent subjects doesn't cause panics | Any |
| `exactly-once.sh` | Exactly-Once and Ack/Nak | C02, C03 | JetStream dedup window, redelivery on nak | Any |
| `message-ordering.sh` | Message Ordering | C01 | FIFO guarantee via JetStream sequence numbers | Any |
| `stream-durability.sh` | JetStream Durability | C06, C07 | messages survive NATS restart, consumer replay | Any |
| `subject-routing.sh` | Subject Routing | C04, C05, C11, C12 | NATS subject construction and wildcard matching | Any |
| `task-state.sh` | Task State Transitions | C09, C15, C16 | pending → completed, correct NATS subjects, subscription matching | Any |

## Security

| Test file | Title | Scenario IDs | Verifies | Topology |
| --- | --- | --- | --- | --- |
| `connection-flood.sh` | Connection Flooding | D07 | NATS survives 100 rapid connections | Any |
| `container-isolation.sh` | Container Isolation | D08, D09 | PID namespace isolation, network boundary enforcement | T4 |
| `malformed-nats.sh` | Malformed NATS Messages | D11, D12 | services ignore garbage NATS messages gracefully | Any |
| `malformed-rest.sh` | Malformed REST API Payloads | D01, D02, D03, D06 | server gracefully rejects bad input | Any |
| `resource-exhaustion.sh` | Resource Exhaustion | D10 | 10000 rapid tasks — Agamemnon doesn't OOM | Any |
| `test-apikey-not-on-cmdline.sh` | API Key Not On Command Line | — | the ANTHROPIC_API_KEY value never appears on the container command line | Any |
