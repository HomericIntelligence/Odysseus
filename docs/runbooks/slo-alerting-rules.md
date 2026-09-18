# Runbook: SLO Alerting Rules

Argus owns alert-rule implementation, metric emission, Prometheus validation,
and deployment. This Odysseus runbook defines the cross-repository boundary;
it does not carry a duplicate rule file or authorize a live Prometheus reload.

[Proposed ADR-012](../adr/012-slo-sla-definitions.md) records candidate SLO
targets. It is not an accepted service commitment, and a checked-in rule is not
proof that its metric is emitted or that the rule is deployed.

## 1. Bind the Argus source

Read the exact Argus gitlink from the approved Odysseus revision. For a rule
change, fetch the current Argus remote head, record its immutable SHA, and
create an isolated Argus worktree from that SHA. Do not edit
`infrastructure/Argus` inside the Odysseus integration checkout.

The pinned Argus README, exporter source, metrics tests, Prometheus config, and
rule-validation entry point are the current authorities. If a command or path
named here is absent at that pin, stop and use the component-owned route rather
than inventing it.

## 2. Prove the metric exists independently of the rule

For every active alert expression, identify the exact exporter definition and
an observed/tested emission path. Search exporter and instrumentation source
only; never include `rules/` in the emitter search, because the rule text can
self-match and create false-green evidence.

Confirm the metric's type, labels, units, initialization behavior, and stale or
absent-series semantics. A name found in source is insufficient when the code
path never emits it. Keep a rule disabled until a focused test or controlled
scrape proves the series and label set used by its expression.

## 3. Author and validate in Argus

Add or update the rule in the isolated Argus worktree. Keep rules whose metrics
do not yet exist in a clearly non-active planning document, not as commented
production configuration that appears deployed.

Use the exact Argus-owned validation command. It must at minimum parse the
Prometheus rule file, reject unknown or incompatible metric/label assumptions,
and exercise representative firing and non-firing cases. A command that prints
`FAIL` but exits zero is not validation.

Run `$athena:pr-review` to terminal exact-head `GO` and pass every live required
Argus CI/CD check before merging the component PR.

## 4. Integrate deliberately

If Odysseus must move the Argus gitlink, obtain explicit integration approval
for the exact merged Argus commit and use a separate Odysseus integration PR.
Do not update other component pins opportunistically.

Rule deployment is a distinct production write. Bind the live Prometheus
instance, deployed config/rule digests, lifecycle setting, tenant, rollback
artifact, and operator-approved target before reloading or restarting it. Do
not assume `localhost:9090`, invoke `POST /-/reload`, or restart the embedded
Argus checkout as a generic procedure.

Use the deployment-owned service manager. After the change, query the exact
Prometheus API through its authorized endpoint and prove that the expected rule
group, expression, labels, and state match the reviewed artifact. Preserve the
actual response and exit status.

## 5. Completion and rollback

Completion requires:

- an exact source and deployment binding;
- independent evidence that each active metric is emitted with the required
  type and labels;
- parser and behavior tests for the rule;
- exact-head Athena review and Argus CI/CD success;
- an approved integration receipt when a gitlink moves;
- a live rule readback when deployment was authorized; and
- cleanup of any canary series or a truthful incomplete result.

Rollback restores the exact prior versioned rule/config artifact through the
same deployment manager and verifies the resulting live digest and rule state.
Never reconstruct rollback by editing the live file or assuming a previous Git
commit equals the deployed artifact.
