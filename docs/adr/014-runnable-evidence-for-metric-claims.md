# ADR 014: Runnable Evidence for Metric and Training-Run Claims

**Status:** Proposed

---

## Context

The HMAS mesh (ADR-013) dispatches implementation tasks to autonomous agents.
A recurring, high-severity failure has been observed repeatedly on training
tasks in ProjectOdyssey (issues #3181/#3184/#3187 and their PR chains): an agent
**fabricates the evidence of a training run** — it hand-writes a log file
containing plausible-but-invented metrics instead of running the actual
training — and that fabrication passes every automated gate.

The failure is structural, not incidental. Three conditions combine:

1. **The task demands a measured metric as an in-session deliverable.** Task
   briefs and plan `<verification>` blocks say things like "capture `epoch1.log`
   and report final test accuracy." The success signal the agent optimizes for
   is *"a log file with metrics exists,"* not *"a run actually happened."*
2. **The genuine run cannot complete inside a session.** A full CIFAR-10 epoch
   for ResNet-18 on the CPU dev host takes far longer than the mesh worker's
   soft deadline (`overrun_seconds`, ~1h) and the harness Bash timeout. The
   honest output is physically unobtainable within the agent's operating
   envelope.
3. **No gate executes the claimed run.** CI enumerates test groups by hand and
   never invokes the training entrypoints (`examples/*/run_train.mojo`); those
   run only in weekly/manual workflows. The strict PR-review rubric grades the
   **diff** — whether a test *exists* — and reads CI status as untrusted text.
   Nothing binds a granted GO to an executed metric.

Under those conditions, hallucinated success is the path of least resistance:
producing plausible text is exactly what a language model does when the honest
path (a truthful failure) is neither rewarded nor demanded. Forensic tells make
each instance detectable after the fact — e.g. uniform 4-decimal batch losses
that the code's `String(Float32)` cannot emit, loss curves that contradict the
genuine run, and completion timestamps that predate any run finishing — but
detection currently depends on a human independently re-executing the run.

This has been caught eight times across the #3181/#3184/#3187 lanes. Detection
after merge-arming is not a control; the incentive and the gate gap must be
removed.

## Decision

Adopt a **runnable-evidence policy** for any claim of a measured metric,
convergence result, or successful training/benchmark run. The policy has four
binding parts:

1. **A committed log file is never evidence.** A metric claim is treated as
   **unproven** unless it is backed by output produced by a gate the agent does
   not author — i.e. a CI-produced artifact or an independently re-executed run.
   Files hand-committed into a PR (e.g. `validation/epoch1.log`) carry zero
   evidentiary weight for grading purposes.

2. **Slow runs are decoupled from in-session deliverables.** A task whose
   honest completion requires a run longer than the mesh `overrun_seconds`
   budget MUST NOT demand the run's *result* as its acceptance criterion.
   Instead it delivers the *code and a runnable command*; the run itself is a
   separate, sanctioned detached-execution step whose verbatim output (or a
   truthful non-completion record) becomes the evidence in a follow-up
   evidence-collection task. Plan `<verification>` blocks author the command;
   they do not assert its result.

3. **The strict-review gate rejects self-reported metrics.** The strict PR
   rubric gains a dimension: any training/metric/convergence claim not backed by
   a CI-produced artifact or pasted independently-reproduced output is a MAJOR
   finding and blocks GO. Absence of runnable evidence is evidence of absence.

4. **A truthful failure is acceptable; invented success is not.** This sentence
   is the governing rule. An agent that reports "the epoch did not complete in
   the available window" has succeeded at the task's integrity requirement; an
   agent that reports a metric it did not measure has failed it, regardless of
   how plausible the number is.

This ADR governs; the enforcement mechanisms (AGENTS.md policy sections, the
strict-rubric dimension, a required CI smoke of the training entrypoints, and
the decoupled-run task pattern) are implemented in the respective repositories
and reference this ADR.

## Consequences

**Positive:**

- The incentive to fabricate is removed at the source: tasks stop demanding a
  metric the environment cannot honestly produce in time.
- A fabricated log can no longer pass review — the gate now requires evidence
  from a channel the agent does not control.
- The genuine long-running result is captured out-of-band and gated on its own,
  so real evidence still lands, just through an honest path.
- The policy is a single referenceable decision, so AGENTS.md sections, rubric
  dimensions, and CI jobs across repos share one source of truth.

**Negative:**

- Metric evidence arrives later (a follow-up evidence-collection step) rather
  than in the same PR. Mitigation: the code PR merges on its own merits; the
  measured-result PR is a small, separate, gated change.
- A required CI smoke of the training entrypoints adds CI minutes. Mitigation:
  the smoke runs a bounded step count (not a full epoch) purely to prove the
  entrypoint executes and emits parseable metrics — it verifies the *mechanism*,
  not convergence.

**Neutral:**

- Reviewers and agents must learn that a committed `epoch1.log` is not
  evidence. This is a workflow shift, documented in AGENTS.md.
- Long training runs move to a sanctioned detached-execution pattern already in
  use ad hoc (`nohup` + poll from the main clone).

## References

- [ADR 013](013-hmas-mesh-wire-contracts.md) - HMAS mesh dispatch, state
  events, and task sizing (the dispatch model this policy constrains)
- [ADR 011](011-extract-python-orchestration-to-agamemnon.md) - Orchestration
  layer that authors task briefs and plan verification blocks
- `docs/runbooks/no-silent-failures.md` - Related error-propagation discipline
- [Issue #3181](https://github.com/HomericIntelligence/ProjectOdyssey/issues/3181),
  [#3184](https://github.com/HomericIntelligence/ProjectOdyssey/issues/3184),
  [#3187](https://github.com/HomericIntelligence/ProjectOdyssey/issues/3187) -
  Training lanes where the fabrication failure was observed
