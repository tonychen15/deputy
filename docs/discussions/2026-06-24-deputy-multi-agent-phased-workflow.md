
  What's already portable vs Claude-bound

  The asset: bin/deputy.sh (the runner) is provider-agnostic. It already knows Codex — probes codex login status, parses Codex quota/retry wording, routes Codex as a failover coder and as an xReview reviewer. deputy claim --agent, the spine verbs, states, BACKLOG — none of
  that is Claude-specific. So the queue + ledger + safety-gates-in-the-CLI layer ports for free.

  What's Claude-bound (all in the orchestrator layer, not the CLI):
  1. Invocation — the skill is ln -s skills/deputy → ~/.claude/skills/deputy, invoked as /deputy. Codex has no ~/.claude/skills; its analogs are ~/.codex/prompts/*.md (→ /deputy slash command), AGENTS.md, or the cross-platform superpowers skill loader.
  2. xReview routing — SKILL.md hardcodes author = claude. If Codex orchestrates, it becomes the author, so the reviewer must flip to Claude/Gemini (Codex can't review its own work). The routing logic already supports author-aware selection — it's a config flip, not new
  code.
  3. The guardrail — this is the crux. Claude's safety (no push/merge, protected paths, no out-of-worktree writes) is enforced by a PreToolUse hook (hooks/guardrail.sh). Codex has no PreToolUse hook — its containment is the sandbox + approval policy (--sandbox 
  workspace-write, approval modes). So a Codex orchestrator needs a different enforcement story.
  4. Human-session back-off reads ~/.claude/sessions/. Codex sessions live elsewhere with a different shape — the back-off gate would need a Codex reader (or stay Claude-only).
  5. Worker spawn — headless workers are claude -p. But for an interactive Codex orchestrator running steps inline (like today's V1 "Claude executes each step directly"), there's no spawn — Codex just does the work. The spawn only matters for the headless/cron path.


  What's already portable vs Claude-bound

  The asset: bin/deputy.sh (the runner) is provider-agnostic. It already knows Codex — probes codex login status, parses Codex quota/retry wording, routes Codex as a failover coder and as an xReview reviewer. deputy claim --agent, the spine verbs, states, BACKLOG — none of
  that is Claude-specific. So the queue + ledger + safety-gates-in-the-CLI layer ports for free.

  What's Claude-bound (all in the orchestrator layer, not the CLI):
  1. Invocation — the skill is ln -s skills/deputy → ~/.claude/skills/deputy, invoked as /deputy. Codex has no ~/.claude/skills; its analogs are ~/.codex/prompts/*.md (→ /deputy slash command), AGENTS.md, or the cross-platform superpowers skill loader.
  2. xReview routing — SKILL.md hardcodes author = claude. If Codex orchestrates, it becomes the author, so the reviewer must flip to Claude/Gemini (Codex can't review its own work). The routing logic already supports author-aware selection — it's a config flip, not new
  code.
  3. The guardrail — this is the crux. Claude's safety (no push/merge, protected paths, no out-of-worktree writes) is enforced by a PreToolUse hook (hooks/guardrail.sh). Codex has no PreToolUse hook — its containment is the sandbox + approval policy (--sandbox 
  workspace-write, approval modes). So a Codex orchestrator needs a different enforcement story.
  4. Human-session back-off reads ~/.claude/sessions/. Codex sessions live elsewhere with a different shape — the back-off gate would need a Codex reader (or stay Claude-only).
  5. Worker spawn — headless workers are claude -p. But for an interactive Codex orchestrator running steps inline (like today's V1 "Claude executes each step directly"), there's no spawn — Codex just does the work. The spawn only matters for the headless/cron path.

  The interactive Codex-orchestrator MVP is cheap (a Codex prompt + a Codex-flavored SKILL with the author flipped + lean on Codex's sandbox/approval as the guardrail). The headless/cron parity is expensive (needs a real guardrail-equivalent + Codex session detection +
  cross-provider worker spawn). Most of the cost lives in trying to match the autonomous safety model, not the orchestration itself.

---

# Converged design — multi-agent phased workflow (grill session, 2026-06-24)

## Vision (the goal)

Not "Codex as a fallback orchestrator" but **deputy as a multi-agent, phase-driven
SDD + TDD pipeline** in which all agents (Claude, Codex, Gemini, …) register as **equal
peers** of the deputy workflow. Quality, resilience, and efficiency come from **role
rotation with cross-review at every phase**: for each phase of application development one
agent OWNS the work and a *different* agent REVIEWS it and "raises the bar."

Worked example given by the user (note: the "in parallel" framing is the *aspirational*
shape — **v1 serializes the planning phases**, see Round-2 must-fix #2 below):
- Discuss the requirement of an application; figure out a system design (collaborative).
- One agent (e.g. Claude) writes the **implementation plan**; another (Codex) writes the
  **E2E / integration test plan** — *(v1: serialized — test plan depends on the accepted
  implementation plan + design, not drafted concurrently)*.
- With a detailed implementation plan, Claude and Codex **each implement tasks** and ask
  the other party to review.
- Claude implements the **test cases** from the test plan.
- General principle: **per phase, one agent works, another reviews and raises the bar.**

## Converged architecture

**deputy CLI = the conductor.** It owns the **phase state machine**, assigns each phase's
**owner** (lead/author) and **reviewer**, and transitions ownership as phases advance
(hybrid model: the CLI changes the phase owner; within a phase a single owner agent leads).
Agents are **peers**, each running *one identical, runtime-neutral skill*: "ask deputy for
my current phase + role → do the work → submit → deputy routes the bar-raising review to a
peer." The CLI stays the thin, **portable safety floor** (protected-path / surface-not-merge
/ no-push gates already live in `bin/deputy.sh`, agent-agnostic); each runtime adds only a
**containment adapter** (Claude PreToolUse hook / Codex sandbox+approval / Gemini).

This generalizes deputy's existing **author ≠ reviewer** invariant from *per-commit* to
*per-phase, across peer agents*, and generalizes the waypoint ledger from flat *steps* into
typed *phases*. Precursors already on the backlog: deferred **#1** (run waypoint + xReview on
Gemini/Codex) and **#2** (capped, conflict-aware parallel worktrees).

## Phase pipeline + concurrency

The **human is the OWNER** of the first two phases (Requirements, System design); the two
agents act as **peer reviewers**. The human then **assigns the planning-phase owners** —
**Claude owns the implementation plan, Codex owns the test plan** — each reviewed by the
other agent. From the implement phase onward, ownership is per-task (agents).

| Phase | Owner | Reviewer | Concurrency |
|---|---|---|---|
| Requirements | **human (user)** | both agents (peer review) | **single owner** (sequential) |
| System design | **human (user)** | both agents (peer review) | single owner |
| Implementation plan | Claude (user-assigned) | Codex | 1 owner + 1 reviewer |
| Test plan (E2E / integration) | Codex (user-assigned) | Claude | 1 owner + 1 reviewer |
| **Implement** | per-task agent | the other agent | **bounded-parallel — 1 task per agent, cross-reviewed** |
| **Test implementation** | per-task agent | the other agent | bounded-parallel — 1 task per agent |

Design/plan phases reuse today's single-slot locking as-is; only Implement/Test need
**bounded parallel worktrees** (deferred #2), capped at one task per agent.

## Decisions captured from the grill

- **Motivation:** all of resilience-when-Claude-down + cost/preference + redundancy —
  ultimately **all agents register as the deputy workflow's agent**, following Spec-Driven
  Design + TDD.
- **Scope:** Codex (and others) are an **equal agent** to Claude, not a fallback.
- **Invocation mechanism:** a **superpowers cross-platform skill** (loads natively in
  Claude / Codex / Gemini / Copilot) — one thin, runtime-neutral skill for every agent.
- **Conductor:** **hybrid** — the CLI orchestrates and changes the phase owner; within each
  phase one agent is the phase owner who leads the work.
- **Role policy:** **affinity + availability fallback** — default affinities by phase-type,
  fall back to whoever is available; if only one agent is up it self-authors with a flagged
  **DEGRADED** review (deputy's existing `self` degrade). Resilience falls out of the
  existing claim-TTL + circuit-breaker + availability routing.
- **Concurrency:** **phase-dependent.** Requirements / system design / test design /
  implementation plan → strictly **one owner + one reviewer** (sequential). Implement /
  test → **each agent can work on one task** (bounded parallel, cross-reviewed).
- **Guardrail:** **build a Codex-native enforcement** (full containment for Codex workers
  too), with the deputy-CLI gates as the portable floor and per-runtime adapters above it.
- **Human-owned early phases + human-assigned planning owners.** The **user owns**
  Requirements and System design (the agents are peer reviewers), then the **user assigns**
  the planning-phase owners: **Claude → implementation plan, Codex → test plan**, each
  cross-reviewed. (This also answers Codex's question about whether Requirements is truly
  "collaborative" — it has a single human owner with agent peer-review, not a leaderless
  free-for-all.)

## Open questions (still to resolve before a spec is complete)

1. **"Raise the bar" — the actual mechanism.** Currently a principle, not a gate. What
   concrete artifact does a reviewer produce so the bar-raise is checkable — stricter
   `APPROVE` with mandatory added acceptance-criteria, appended test cases, or a per-phase
   hardening checklist the owner must then satisfy?
2. **Task decomposition + assignment for the parallel phases.** Who splits the
   implementation plan into tasks and assigns one-per-agent — the impl-plan phase owner (so
   the plan *is* the work-breakdown), the CLI (auto-fan-out), or the plan's reviewer? How do
   the parallel worktrees reconcile + handle conflicts?
3. **Phase ledger shape.** Evolve the waypoint ledger from flat steps to typed *phases*
   each holding `{owner, reviewer, artifact, verdict}`, with Implement/Test fanning out into
   per-agent *tasks*.
4. **Thin-skill CLI contract.** The exact runtime-neutral verbs an agent calls — e.g.
   `deputy phase claim` (→ my phase+role+task), `deputy phase submit`, `deputy phase review`,
   `deputy agent register <name>`.
5. **Codex / Gemini containment adapters** (the "Codex-native enforcement"), with the
   CLI gates as the floor.

## Codex comments

- **Clean up the duplicated portability preface before promoting this to a spec.** The
  "What's already portable vs Claude-bound" block appears twice at the top. That is harmless
  in a discussion note, but the formal spec should either keep one copy as background or
  move it into an appendix so the normative design starts at the phase workflow.
- **Make "deputy CLI = conductor" explicit about authority boundaries.** The CLI should own
  phase state, locks, assignment, routing, and final acceptance transitions. Agents should
  own only artifact production and review text. This prevents a peer agent from silently
  deciding that its own phase is complete just because it has produced an artifact.
- **Treat reviewer output as a required follow-up workload, not just a verdict.** A useful
  bar-raise artifact should probably have three fields: `verdict`, `required_changes`, and
  `added_acceptance_criteria` or `added_tests`. The phase should not advance until the owner
  either satisfies the required changes or records a human-visible rejection/rationale.
- **Separate design-time degraded mode from implementation-time degraded mode.** Self-review
  may be acceptable for early requirements/design exploration if it is flagged, but it is
  much riskier for implementation and test phases. The spec should decide whether DEGRADED
  implementation can merge at all, or whether it only queues a human/peer review requirement.
- **Define the merge authority for bounded parallel worktrees.** Implement/Test phases need
  a single integrator role or CLI-mediated integration step after per-task reviews. Otherwise
  "one task per agent" leaves unanswered who rebases, resolves conflicts, runs the full suite,
  and marks the aggregate phase complete.
- **Keep affinity policy configurable rather than hardcoded.** The table's Claude/Codex
  affinities are reasonable defaults, but the durable model should be capability tags
  (`design`, `test-planning`, `implementation`, `review`, `cheap`, `available`) plus project
  config. That will make Gemini/Copilot or local models fit without another redesign.
- **Containment is a release gate, not an implementation detail.** The CLI's portable gates
  are necessary but insufficient for autonomous/headless workers. The spec should include
  a matrix of runtime guarantees and mark which workflow modes are allowed per runtime:
  interactive only, supervised headless, or autonomous cron.
- **Add artifact schema and storage locations early.** The phase ledger shape should name
  concrete files/records for requirements, system design, implementation plan, test plan,
  task artifacts, reviews, and final integration reports. This will make cross-agent handoff
  less dependent on prompt memory and easier to resume after crashes.
- **Clarify whether Requirements is truly collaborative.** The table says "collaborative"
  but also says "1 owner + 1 reviewer". If the intended behavior is a facilitated discussion,
  call that a distinct phase type with a facilitator and reviewer; if not, assign one owner
  like the other sequential phases.

---

# Cross-LLM review (Codex) + synthesis (2026-06-24)

Per the very methodology this design proposes, the converged design was handed to **Codex**
for a bar-raising review. Codex's points are captured in **## Codex comments** above; the
full review is at [multi-llm-workflow/codex-review-2026-06-24.md](multi-llm-workflow/codex-review-2026-06-24.md).
The fuller compiled critique below adds detail the summary omits (structured-review schema,
thin-skill verbs, phase-ledger shape, migration ladder), followed by Claude's opinion.

## Codex's critique (fuller compile)

1. **"Raise the bar" is not yet a protocol — this is make-or-break.** If review is just
   better-written prose, deputy cannot *gate* on it, and the whole phase machine becomes
   ceremony around normal agent chat. Review must be a **structured, blocking artifact**:
   `{verdict, required_changes[blocking], added_acceptance_criteria, added_tests, risks,
   evidence_required}`. A review counts as bar-raising only if it produces ≥1 of those; a
   bare `APPROVE` is allowed only if the reviewer explicitly asserts the checklist is
   already covered (else agents learn to rubber-stamp). Deputy enforces **closure** (owner
   resubmits referencing each `RC-id`; phase advances only when all blocking items are
   closed or human-waived). *Closure must be checkable, not free-text.*
2. **The conductor must own authority, not just routing.** The CLI must be the *only*
   authority that assigns owner/reviewer, accepts submissions, records verdicts, opens
   follow-ups, advances phases, marks degraded, and approves integration. **Agents must
   never self-transition phases by prompt convention** — "conduct agents without
   prompt-based trust."
3. **"Equal peers" still leaks affinity** — express agents + phase policy as **config**
   (capabilities per agent; owner/reviewer = best_available/different_agent), or it quietly
   becomes "Claude leads, Codex sometimes reviews."
4. **Degraded mode is too permissive.** Self-review is fine for requirements/early design,
   NOT for implement/test/merge/release without human or later peer review. `DEGRADED` must
   be a **workflow-limiting state**, not just metadata.
5. **Parallel implementation needs an explicit integration owner/phase** — someone merges
   branches, runs the full suite, resolves semantic conflicts, declares the phase done.
6. **Containment is a product boundary, not an adapter detail.** A runtime that cannot
   enforce the safety properties should be **ineligible for autonomous/headless** (Codex
   sandbox ≠ Claude PreToolUse). Spec needs a runtime × mode guarantee matrix.
7. **Task decomposition ownership:** impl-plan **owner** defines the work breakdown →
   **reviewer** validates (independence/testability/conflict/ordering) → **deputy**
   validates the schema+dependency graph and **assigns** tasks (one owner + one different
   reviewer each); the CLI never auto-fans-out a vague plan, only well-formed tasks with
   `allowed_paths`, `dependencies`, `expected_artifacts`.
8. **Phase-ledger shape:** append-only **events** + a **materialized current-state** file —
   don't overload "waypoints" into an unparseable event log.
9. **Thin-skill verbs:** `deputy agent register/heartbeat`, `phase status/claim/submit/review`,
   `task list/claim/submit/review`, `gate check/advance`. `gate advance` is policy-controlled;
   the skill never gets `approve`/`complete`/`merge` except mediated by gate checks.
10. **Still missing:** artifact taxonomy + schemas, per-phase entry/exit gate checklists, a
    **human-override model**, a **disagreement protocol** (owner rejects a required change ↔
    reviewer won't approve → second reviewer / human / documented waiver), a **test-authority
    model** (stop tests being weakened to pass the impl), **observability** commands, and
    **crash-recovery** as first-class ledger states (stale claims, partial submissions,
    interrupted reviews, abandoned worktrees).
11. **Migration ladder (Codex's recommended order):** (1) typed *sequential* phases, single
    owner/reviewer, no parallelism; (2) structured review artifacts + gates; (3)
    capability-based agent registration; (4) parallel task fan-out with worktrees; (5)
    runtime containment matrix + headless support. *Do not start with parallel multi-agent
    implementation; start with enforceable phase gates.*

## Claude's opinion (synthesis)

- **Codex is right about the crux, and it changes our framing.** I had been treating the
  multi-agent *collaboration* as the hard part; Codex correctly reframes the hard part as
  **state, authority, evidence, and gates**. The collaboration is easy once the conductor
  can *enforce* a structured review gate. Adopt the structured blocking-review artifact as
  the centerpiece — it directly resolves open-question #1, and it is exactly the
  generalization of deputy's existing `review-log` + `APPROVE/NEEDS_CHANGES` (which is
  already append-only and CLI-mediated), so it fits the codebase.
- **Adopt the task-decomposition answer as decided** (owner proposes → reviewer validates →
  deputy assigns → separate integration phase). This resolves open-question #2 and keeps the
  thin-runner philosophy (agents recommend, deputy decides).
- **Agree on sequential-first.** Our pipeline table over-reached by putting bounded-parallel
  in the MVP. Re-scope: **MVP = typed sequential phases + owner/reviewer rotation + the
  structured review gate**, proving the CLI conducts without prompt-based trust. Parallel
  worktrees (#2) move to a *later* rung, gated on the conductor being proven.
- **Agree `DEGRADED` must limit the workflow**, not just annotate it — and this is a small
  change to deputy's existing `self`-degrade path: tie it to phase-type (allowed for
  requirements/design, blocks completion for implement/test/merge without human or deferred
  peer review).
- **Agree containment is a product boundary.** Concretely: keep pushing enforcement into the
  CLI (the portable floor), and make *mode eligibility* (interactive / supervised-headless /
  autonomous) a function of which guarantees the runtime can prove — a runtime with no
  enforceable containment is interactive-only.
- **One place I'd push back / extend Codex:** the **disagreement protocol** should reuse
  deputy's existing escalation, not invent arbitration first. An owner↔reviewer standoff is
  the same shape as today's "3rd NEEDS_CHANGES → BLOCKED → surface to human." So the v1
  disagreement protocol is: **bounded review rounds → on impasse, `surface` to the human**
  (deputy already does this). Third-agent arbitration is a *later* enhancement, not MVP.
- **Net:** the design's spine is sound; the work is to make "raise the bar" a checkable,
  CLI-enforced gate and to narrow v1 to the sequential conductor. The next concrete step is
  a formal spec under `docs/superpowers/specs/` scoped to **rungs 1–2** of Codex's ladder
  (typed sequential phases + structured review gates), with rungs 3–5 as explicit "later".

## Revised open questions (post-review)

- **Directionally resolved** (converged in shape, but *not* yet spec-resolved — each still
  needs exact schemas + state transitions before promotion): "raise the bar" mechanism
  (structured blocking artifact); task decomposition ownership; phase-ledger shape (events +
  materialized state); thin-skill verb set.
- **Still open:** the exact **artifact schemas** (requirements/design/plan/test-plan/task/
  review/integration); the **human-override + waiver** model; whether the v1 **disagreement
  protocol** is surface-to-human only (Claude's position) vs third-agent arbitration
  (Codex's option); and the **containment guarantee matrix** per runtime.

## Codex follow-up comments

- **Update stale decisions before promotion.** The earlier role-policy decision still says
  a single available agent can self-author with flagged `DEGRADED` review. The later synthesis
  correctly narrows this: DEGRADED should be workflow-limiting for implementation, test,
  merge, and release phases unless a human or later peer review clears it. The formal spec
  should make the later rule normative so implementers do not inherit the permissive version.
- **Resolve the planning-phase concurrency contradiction.** The worked example has Claude
  writing the implementation plan while Codex writes the test plan in parallel, but the MVP
  recommendation is typed sequential phases first. A clean spec can keep parallel plan writing
  as a later target, but v1 should explicitly serialize these phases unless the conductor can
  already gate two simultaneous phase artifacts.
- **Downgrade "resolved" to "resolved directionally" for review gates.** The design has
  converged on structured blocking review artifacts, but the enforceable contract still
  depends on exact schemas, waiver rules, closure semantics, and state transitions. Until
  those are specified, the bar-raising mechanism is not fully resolved.
- **Collapse review material into one synthesis before spec work.** The document now carries
  the short Codex comments, a fuller compiled Codex critique, and Claude's synthesis. That is
  useful discussion history, but the spec should extract one coherent normative section and
  leave raw review material in the linked review file.
- **Remove the duplicated portability preface.** The repeated opening block should be cleaned
  up before this becomes the source for `docs/superpowers/specs/`; otherwise the spec starts
  with background noise instead of requirements and decisions.

---

# Round 2 — Codex review + adopted must-fixes

Codex's second-round review (full: [multi-llm-workflow/codex-review-2026-06-24-round2.md](multi-llm-workflow/codex-review-2026-06-24-round2.md))
reacted to the human-ownership decision + Claude's opinion. **Verdict: spec-ready for rungs
1–2, *if* the spec is explicitly normative and the discussion-history contradictions are
trimmed.** Codex agreed with human-owned early phases, with sequential-first, and with
Claude that v1 disagreement = bounded rounds → human escalation (no third-agent arbitration).
Its actionable output, **adopted as decisions**:

**Must-fix #1 — the human is a first-class state-machine actor.** `owner` is not just an
agent id; the ledger carries `owner_type: human | agent`, `owner_id`, `reviewers`,
`required_reviews`. Human-owned phases get their own transitions (`DRAFT_BY_HUMAN →
SUBMITTED_FOR_AGENT_REVIEW → REVIEWS_RETURNED → HUMAN_REVISING → HUMAN_ACCEPTED`) and a
**human control surface** of CLI verbs: `deputy phase submit --as-human`,
`accept --as-human`, `waive-review <RC> --reason`, `assign <phase> --owner <a> --reviewer <b>`.
Otherwise "human owns requirements" is prompt convention, not state-machine truth.

**Must-fix #2 — v1 is strictly sequential.** Requirements → System design → Implementation
plan (Claude) → Test plan (Codex), one active phase at a time, each owner+reviewer. The test
plan **depends on** the accepted implementation plan + design (traceable to requirements +
explicit adversarial coverage — it must not mirror the impl happy-path). Parallel plan
drafting *and* parallel implementation are explicitly **later** (rungs 4+).

**Must-fix #3 — precise bounded-disagreement protocol.** Round 1: reviewer files blocking
`RC`s → owner resubmits with closure evidence or rejection rationale → round 2 → at the round
limit the phase becomes `BLOCKED_FOR_HUMAN`; the human then requires owner changes, accepts
the reviewer objection, waives with a reason, or reassigns owner/reviewer. **No third-agent
arbitration authority in v1** (a peer may be requested as *advisory* input to the human, but
never advances state).

**Two new risks adopted as constraints:**
- **Human-owned ≠ schema-free.** Even human artifacts have required fields so agents review
  against stable structure: Requirements ≥ `{goals, non_goals, users, functional_requirements,
  constraints, acceptance_criteria, open_questions}`; System design ≥ `{architecture,
  interfaces, data_model, state_transitions, risks, alternatives_considered,
  test_strategy_implications}`.
- **Human assignment is sticky.** An explicit human owner assignment is not silently
  overridden by availability fallback: if the assigned owner is unavailable the phase enters
  `WAITING_FOR_OWNER` until the human reassigns. (Affinity + availability fallback applies
  only where there is *no* explicit human assignment.)

**Also folded in:** `DEGRADED` is **workflow-limiting** (blocks completion of
implement/test/merge/release without human or later peer review) — normative, superseding the
earlier permissive phrasing; and the exact state transitions
(`submit / review / needs_changes / resubmit / approve / waive / block_for_human / advance`)
must be specified before promotion. Claude concurs with all three must-fixes; #1 (human as a
first-class actor) is the load-bearing gap that was under-specified.

---

# Next step

SDD-correct: this discussion *is* the requirements + system-design phase of this very
workflow (deputy designing deputy). Per Codex's Round-2 verdict it is **ready to become a
formal spec** under `docs/superpowers/specs/`, **scoped to rungs 1–2 of the migration
ladder** (typed *sequential* phases + structured, CLI-enforced review gates), with rungs 3–5
(capability registration, parallel worktrees, containment matrix + headless) marked
explicitly "later." The spec must be **normative** and resolve the three Round-2 must-fixes
first: **(1)** human-owned phase semantics (`owner_type=human` + the human control-surface
verbs + human-phase transitions); **(2)** strictly sequential v1 (impl-plan then test-plan);
**(3)** the precise bounded-disagreement protocol (round limit → `BLOCKED_FOR_HUMAN` →
waiver/reassignment, no third-agent authority). It should also extract **one** normative
section and leave the raw review history in the linked review files, and drop the duplicated
portability preface. No backlog items or code until the spec settles.

