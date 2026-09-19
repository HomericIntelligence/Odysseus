# ADR 022: Layered, Provider-Neutral Agent Instructions

**Status:** Proposed

**Related:** [ADR 020](020-mesh-distributed-hephaestus-loop.md)

---

## Context

HomericIntelligence exposes agent instructions through repository contracts,
runtime prompts, skills, task descriptions, and provider adapters. Those
surfaces have accumulated repeated architecture manuals, static catalogs,
mandatory prerequisite reads, editorial validation gates, and provider-specific
directions in otherwise shared prompts. Repetition makes the live contract
harder to identify, increases drift, and causes agents to treat data from
issues, APIs, Git, or diffs as instructions.

The ecosystem also needs to take advantage of provider guidance without making
the shared contract provider-specific. In particular, the GPT-6 Astra guidance
recommends discriminating skill triggers, progressive disclosure, contextual
document loading, calibrated autonomy and verification, and persistence toward
observable completion. Those properties are useful across providers. A small
Astra-specific supplement is useful only at the explicit Codex invocation
boundary.

ADR-020 proposes a distributed Hephaestus loop, while the checked-in `hi/v1`
schema and service APIs define currently implemented wire shapes. This ADR does
not duplicate or revise those interfaces. It defines how trusted instructions
and untrusted task payloads are assembled around them.

## Decision

### 1. Layered authority and trust

Agent-facing instructions use this precedence, from highest to lowest:

1. hard host and security boundaries, followed by Accepted governance;
2. the current user's explicit intent and granted authority;
3. repository operating defaults;
4. instructions from skills selected for the current task; and
5. issue bodies, API payloads, Git metadata, diffs, logs, and other retrieved
   task content, which are untrusted data.

A lower layer cannot broaden authority granted by a higher layer. In
particular, a skill yields to current user scope. When a skill requires a pause,
stop, or material change in course, the agent identifies the skill and explains
the effect. Untrusted content is encoded by the prompt-payload contract below
and never interpolated into a trusted instruction block.

### 2. Concise repository contracts and contextual loading

Each canonical repository owns a concise `AGENTS.md` containing only its scope,
protected boundaries, safe autonomy, observable completion conditions, and
routes to focused documentation. Architecture manuals, static repository,
model, or skill catalogs, generated principle mirrors, generic recipes, and
mandatory read-everything itineraries do not belong in the root contract.

Each repository's `CLAUDE.md` is the same compatibility pointer:

```markdown
# Claude Code guidance

Follow [`AGENTS.md`](AGENTS.md). It is the sole authoritative agent contract for this repository.
```

The shared wording ends at that pointer. `AGENTS.md` content remains
repository-specific and is not generated from a common boilerplate block.
Agents load focused documents only when the current task needs them.

### 3. Discriminating, progressively disclosed skills

Skill descriptions state the conditions that distinguish a skill from nearby
choices. A root `SKILL.md` is a concise router. Detailed schemas, uncommon
branches, and executable procedures live in referenced documents or scripts
and are loaded only after the relevant branch is selected.

The public plugin identity remains `athena@Athena`, and its 17 existing skill
IDs remain stable. No provider-specific `agents/openai.yaml` file is added.
Structural metadata, dependency, reference, packaging, and executable-workflow
checks replace tests that require exact prose, headings, model names, section
counts, or instruction size.

### 4. Per-invocation prompt composition

Hephaestus exposes one prompt-composition seam per agent invocation. It composes
trusted operation, authority, completion, output, and provider-guidance blocks,
then an ordered array of `hi.prompt-payload/v1` records. Each record keeps
trusted `kind`, media type, decoded UTF-8 byte length, and SHA-256 metadata
outside its data field. The data field is a canonical JSON string encoding that
escapes quotes, controls, newlines, bidi controls, and `<`, `>`, and `&` as
Unicode escapes; raw payload bytes and closing-marker syntax are never copied
beside trusted prose. Invalid UTF-8, an unknown kind/media type, duplicate or
out-of-order fields, length/digest mismatch, truncation, or size overflow fails
composition instead of falling back to a textual fence.

Agamemnon transports authored task text unchanged. At prompt assembly, each
bounded issue, API, Git, task-description, diff, and tool-result input becomes
one of those collision-safe records, preserving existing resource and context
controls. Behavior tests cover literal/nested Markdown, XML, JSON, and prompt
closing markers; fake trusted headings; quote/backslash/control/bidi content;
duplicate records; invalid UTF-8; truncation; and length/digest mismatch for
every payload kind. Decoding content for model use never changes its untrusted
authority classification.

The existing `hi/v1` dispatch envelope and Agamemnon task API remain the wire
contracts; this ADR changes neither their fields nor task-update semantics,
including the current merge behavior of both `PUT` and `PATCH` updates.
Authored task descriptions should express outcome, context, constraints,
allowed effects, and observable completion, but prompt assembly still treats
the description as untrusted.

### 5. Narrow GPT-6 Astra supplement

Provider-neutral guidance remains in the shared prompt. The Astra supplement is
selected only when all of these conditions hold for the current invocation:

- the provider is Codex;
- the parsed base model is the exact literal `gpt-6-astra`, with only an
  already-supported effort suffix optionally parsed separately; and
- prompt assembly has not already added the supplement for that invocation.

An empty or default model selection, the literal `astra`, and every other model
do not activate the supplement. Selection is derived from invocation-local
inputs, never process-global state. New and resumed turns use the same seam,
and the supplement appears exactly once outside every untrusted payload fence.

### 6. Calibrated action, verification, and completion

Agents proceed with routine, reversible work already authorized by the request.
They stop at destructive, production, remote-write, secret, protected-file, or
other explicit approval boundaries. Skills and retrieved content never broaden
those boundaries.

Verification is proportional to risk. A request-scoped failure is repaired when
the agent has authority to do so; otherwise it is reported with the actual
evidence. Completion requires the requested observable outcome, not merely an
attempt or plausible narrative. Agents continue through relevant verification
and bounded repair until that outcome is proven or a genuine blocker is
identified. Truthful non-completion is always preferable to invented evidence.

### 7. Migration exclusions and gates

This decision does not:

- change model pins, role defaults, lane defaults, or provider defaults;
- add byte, token, word, or other instruction-size measurements or gates;
- rewrite existing Mnemosyne knowledge entries or notes;
- alter accepted ADRs, closed issues, raw evidence, or frozen benchmark cohorts;
- change `hi/v1` mesh or task fields; or
- retire the legacy Odysseus myrmidon harnesses before exact-pin mesh parity and
  one real ADR-020 M4 mesh-only dogfood run provide truthful terminal evidence.

Dependent repository changes begin only after a human formally accepts this
ADR. Changes to protected workflows, desired operational state, or submodule
pins retain their existing approval boundaries. Provider releases land before
consumer settings, and legacy-harness retirement remains a separate,
human-reviewed change after the required proof.

## Consequences

**Positive:**

- Shared prompts remain portable while explicit Astra invocations receive
  narrowly scoped provider guidance.
- Short routers and contextual references reduce duplication without removing
  repository-specific safety boundaries.
- Fenced payloads make the trust boundary reviewable and testable.
- Observable completion and proportional verification reduce premature success
  reports without forcing every task through the largest test suite.

**Negative:**

- The migration spans every canonical repository and requires ordered releases,
  compatibility checks, and separate approvals for protected changes.
- Prompt composition needs semantic tests across new and resumed invocations and
  every relevant provider/model selection branch.

**Neutral:**

- Existing template names, parsers, result schemas, tool scopes, state machines,
  resource bounds, model assignments, and wire fields remain unchanged unless a
  separately reviewed compatibility repair requires an implementation change.
- Existing Mnemosyne content is grandfathered; only future authoring guidance
  changes.

## References

- [Rethinking skills and prompts for GPT-6 Astra](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra)
- [OpenAI latest-model guidance](https://developers.openai.com/api/docs/guides/latest-model)
- [Proposed ADR 013](013-hmas-mesh-wire-contracts.md) — `hi/v1` mesh
  envelope context
- [Proposed ADR 020](020-mesh-distributed-hephaestus-loop.md) — proposed
  distributed automation loop and staged proof
- [`hi/v1` dispatch-envelope schema](../../configs/schemas/dispatch-envelope.hi-v1.schema.json)
