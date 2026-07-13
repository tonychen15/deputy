# Codex review — deputy multi-agent phased workflow (2026-06-24)

_Bar-raising design review of [../2026-06-24-deputy-multi-agent-phased-workflow.md](../2026-06-24-deputy-multi-agent-phased-workflow.md), via `codex exec -s read-only`._

## Biggest risks / under-specified

The proposal is directionally strong, but it is still describing *coordination vibes* more than an enforceable workflow. The biggest gap is that “raises the bar” is not yet a protocol. If review is just a better-written critique, deputy cannot gate on it. If deputy cannot gate on it, the phase machine becomes ceremony around normal agent chat.

The conductor boundary is also under-specified. “CLI owns the phase state machine” must mean the CLI is the only authority that can:

- assign owner/reviewer
- accept submissions
- record review verdicts
- open required follow-up work
- decide whether a phase may advance
- mark degraded mode
- approve integration after parallel work

Agents should not be allowed to self-transition phases by prompt convention. They produce artifacts; deputy transitions state.

The equal-peer framing is good, but the design still leaks Claude/Codex affinity assumptions. Defaults are fine, but the durable model should be capability- and policy-driven:

```yaml
agents:
  claude:
    capabilities: [requirements, design, implementation, review]
  codex:
    capabilities: [implementation, test-design, review, refactor]
  gemini:
    capabilities: [review, design, large-context]

phase_policy:
  implementation_plan:
    owner: best_available(design, implementation)
    reviewer: different_agent(review)
```

Without this, “equal peers” becomes “Claude still leads, Codex sometimes reviews.”

The degraded mode is too permissive as currently written. Self-review for requirements or early design is acceptable if clearly flagged. Self-review for implementation, test implementation, merge, or release should not be allowed to complete the workflow without either human review or later peer review. `DEGRADED` should be a workflow-limiting state, not just metadata.

Parallel implementation is the riskiest part. “One task per agent, cross-reviewed” leaves unresolved who integrates the branches, runs the full test suite, handles semantic conflicts, and decides that the aggregate implementation phase is complete. This needs an explicit integration owner or integration phase.

Containment is correctly called out, but it should be treated as a product boundary, not an adapter detail. A runtime that cannot enforce the required safety properties should be ineligible for autonomous/headless modes. Otherwise the design creates a false sense of portability.

The duplicate portability preface should be removed before this becomes a spec. More importantly, the spec should separate background from normative requirements. Right now the doc mixes “what exists,” “what we want,” “what we decided,” and “what is still open.”

## Opinions on the open questions

### What should “raise the bar” concretely produce?

Reviewer output should be a structured artifact, not prose-only feedback. Minimum shape:

```yaml
review:
  phase_id: implementation_plan
  reviewer: codex
  author: claude
  verdict: changes_required | approved | rejected | degraded
  required_changes:
    - id: RC-001
      description: "Split migration work from runtime behavior change."
      blocking: true
  added_acceptance_criteria:
    - id: AC-007
      description: "Backlog claim recovery must be tested after stale lock expiry."
  added_tests:
    - id: T-004
      description: "Integration test for two agents claiming distinct tasks concurrently."
  risks:
    - "Parallel worktree merge can pass unit tests while breaking end-to-end ordering."
  evidence_required:
    - "Full test suite output"
    - "Ledger diff showing phase transition"
```

A review “raises the bar” only when it produces at least one of:

- blocking required changes
- added acceptance criteria
- added test cases
- explicitly documented risk acceptance
- evidence requirements for the next gate

An `APPROVE` with no additions should be allowed only if the reviewer explicitly states that the existing artifact already covers the relevant checklist. Otherwise agents will learn to rubber-stamp.

The gate should be:

1. Owner submits artifact.
2. Reviewer produces structured review.
3. If `changes_required`, deputy opens follow-up items against the same phase.
4. Owner resubmits with references to each required change.
5. Reviewer or deputy verifies closure.
6. Deputy advances phase only when all blocking review items are closed or explicitly waived by a human/deputy policy.

Do not let the owner simply “respond to feedback” in free text. Closure must be checkable.

### Who owns task decomposition and assignment?

The implementation-plan owner should produce the initial work breakdown. That is part of the implementation plan’s job.

The reviewer should validate the breakdown for independence, testability, conflict risk, and ordering constraints.

The CLI should assign tasks, because assignment affects locks, worktrees, ownership, and fairness. Agents can recommend; deputy decides.

Recommended model:

- Implementation plan owner defines tasks.
- Reviewer raises decomposition defects.
- Deputy validates task schema and dependency graph.
- Deputy assigns runnable tasks based on availability, capability, and conflict policy.
- Each task gets exactly one owner and one different reviewer.
- Integration is a separate task or phase, not implicit.

Task shape:

```yaml
task:
  id: IMP-003
  title: "Add phase claim command"
  owner: codex
  reviewer: claude
  status: claimed | submitted | changes_required | approved | integrated
  dependencies: [IMP-001]
  allowed_paths:
    - bin/deputy.sh
    - test/phase_claim.bats
  expected_artifacts:
    - code
    - tests
    - review
  conflict_group: phase-ledger
```

The CLI should not auto-fan-out a vague plan. It should only fan out well-formed tasks with path scopes, dependencies, and expected verification.

### Phase-ledger shape

Use a ledger that separates phases, artifacts, reviews, tasks, and transitions. Do not overload “waypoints” until they become an unparseable event log.

I would use append-only events plus a materialized current-state file.

Example current state:

```yaml
workflow_id: deputy-sdd-tdd-001
status: in_progress
current_phase: implementation_plan

phases:
  implementation_plan:
    status: changes_required
    owner: claude
    reviewer: codex
    artifact: docs/superpowers/specs/deputy-multi-agent/implementation-plan.md
    review: docs/superpowers/specs/deputy-multi-agent/reviews/implementation-plan.codex.yaml
    required_changes_open: 3
    verdict: changes_required

  implement:
    status: pending
    tasks:
      - id: IMP-001
        owner: codex
        reviewer: claude
        status: pending
```

Append-only event examples:

```yaml
- event: phase_claimed
  phase: implementation_plan
  agent: claude
  timestamp: "2026-06-24T..."
- event: artifact_submitted
  phase: implementation_plan
  artifact: docs/...
- event: review_submitted
  phase: implementation_plan
  reviewer: codex
  verdict: changes_required
- event: phase_advanced
  from: implementation_plan
  to: implement
```

The append-only log is for auditability. The current-state file is for simple CLI operation. Keep both.

### Thin-skill CLI verbs

The skill should stay dumb. It should ask deputy what to do, perform work, and submit artifacts. It should not encode workflow policy.

Minimum verbs:

```bash
deputy agent register --name codex --capabilities implementation,review,test-design
deputy agent heartbeat --name codex

deputy phase status
deputy phase claim --agent codex
deputy phase submit --phase implementation_plan --artifact path/to/file
deputy phase review --phase implementation_plan --review path/to/review.yaml

deputy task list --agent codex
deputy task claim --agent codex
deputy task submit --task IMP-003 --artifact path/to/report.yaml
deputy task review --task IMP-003 --review path/to/review.yaml

deputy gate check
deputy gate advance --phase implementation_plan
```

Important: `gate advance` should be policy-controlled. In normal operation an agent can request advancement, but deputy must enforce whether advancement is legal.

I would avoid giving the skill verbs like `approve`, `complete`, or `merge` unless they are explicitly mediated by gate checks.

### Containment adapters

Define a runtime guarantee matrix before implementation.

Example:

| Runtime | Interactive | Supervised headless | Autonomous cron | Required adapter |
|---|---:|---:|---:|---|
| Claude | yes | yes | maybe | PreToolUse guardrail + CLI gates |
| Codex | yes | maybe | no until proven | sandbox + approval policy + CLI gates |
| Gemini | unknown | no | no | TBD |

Containment should specify enforceable properties:

- cannot write outside allowed workspace
- cannot modify protected paths
- cannot push, merge, tag, or publish
- cannot bypass deputy state transitions
- cannot claim multiple tasks beyond policy
- cannot overwrite another agent’s ledger entries
- cannot access secrets outside allowed environment
- cannot run destructive commands without approval
- produces auditable command/session logs

For Codex specifically, “sandbox + approval” may be enough for interactive use, but it is not automatically equivalent to Claude’s PreToolUse hook. The spec needs to say which guarantees are enforced by Codex runtime, which by deputy CLI, and which remain unsupported.

## What's missing

A formal artifact taxonomy is missing. Name the files and schemas now:

- requirements artifact
- system design artifact
- implementation plan
- test plan
- task definition
- task submission report
- review artifact
- integration report
- gate decision
- degraded-mode record

A gate checklist per phase is missing. Each phase needs explicit entry and exit criteria. For example, implementation should not start until requirements, design, implementation plan, and test plan are approved or explicitly waived.

A human override model is missing. You need to define who can waive review findings, approve degraded output, resolve agent disagreement, or force phase advancement.

A disagreement protocol is missing. What happens if owner says a required change is invalid and reviewer refuses to approve? Options: second reviewer, human arbitration, or documented waiver. Pick one.

An integration phase is missing. Parallel work requires a convergence point:

```text
Implement tasks -> Review tasks -> Integrate -> Full verification -> Integration review -> Advance
```

A test authority model is missing. If the implementation owner also writes or edits tests, who protects against tests being weakened to pass the implementation? The test plan should be reviewed before implementation, and test changes during implementation should be separately visible.

A migration path is missing. The spec should identify the smallest useful version:

1. Typed phases, single owner/reviewer, no parallelism.
2. Structured review artifacts and gates.
3. Capability-based agent registration.
4. Parallel task fan-out with worktrees.
5. Runtime containment matrix and headless support.

Do not start with parallel multi-agent implementation. Start with enforceable phase gates.

Observability is missing. Deputy should have commands like:

```bash
deputy workflow status
deputy workflow graph
deputy ledger audit
deputy reviews open
deputy degraded list
```

Crash recovery is missing. The design mentions resumability implicitly, but the phase ledger needs stale claims, partial submissions, interrupted reviews, and abandoned worktrees as first-class states.

## Bottom line

This is a good architectural direction, but it is not yet a spec. The core idea should survive: deputy should be the conductor, agents should be peers, and quality should come from cross-agent phase ownership plus structured review.

The bar-raising mechanism is the make-or-break piece. Make review a structured, blocking artifact that produces required changes, added acceptance criteria, added tests, risks, and evidence requirements. Then make deputy enforce closure before phase advancement.

I would narrow the first implementation to typed sequential phases with owner/reviewer rotation and structured review gates. Prove that the CLI can conduct agents without prompt-based trust. Only after that should you add bounded parallel worktrees, integration phases, and autonomous containment adapters.
