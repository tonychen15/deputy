# Codex review — ROUND 2 — deputy multi-agent phased workflow (2026-06-24)

_Second-round bar-raising review (reacting to round-1 feedback + Claude's opinion + the human-ownership decision). Via `codex exec -s read-only`._

**Round-2 Review**

The new direction is materially better, but it still needs tightening before it becomes a spec.

1. **Human ownership is sound, but it changes the CLI contract more than the doc admits.**

Yes: human-owned Requirements + System Design is the right model. It prevents fake “collaboration” where agents steer foundational decisions without accountability. Agents as peer reviewers is exactly the right use of LLMs here: challenge ambiguity, missing constraints, edge cases, risks, acceptance criteria.

But this implies the CLI must support **non-agent owners** as first-class state machine actors.

That means `owner` cannot just be an agent id. It needs something like:

```text
owner_type: human | agent
owner_id: user | claude | codex | ...
reviewers: [claude, codex]
required_reviews: all | one | quorum | configured
```

And human-owned phases need different transitions:

```text
DRAFT_BY_HUMAN
SUBMITTED_FOR_AGENT_REVIEW
REVIEWS_RETURNED
HUMAN_REVISING
HUMAN_ACCEPTED
READY_FOR_NEXT_PHASE
```

The CLI also needs a way for the human to submit/revise/waive without pretending to be an agent. Otherwise the “human owns requirements” decision becomes prompt convention rather than state-machine truth.

Concrete implication: add human verbs or explicit flags, for example:

```text
deputy phase submit --as-human requirements.md
deputy phase waive-review RC-3 --reason ...
deputy phase accept --as-human
deputy phase assign implementation-plan --owner claude --reviewer codex
deputy phase assign test-plan --owner codex --reviewer claude
```

The current thin-skill verb list is agent-centric. The spec needs a **human control surface** section.

2. **The planning owner split is conceptually good, but v1 must serialize it.**

Claude owning implementation plan and Codex owning test plan is a strong default. It creates useful independence: the test planner is not merely deriving tests from the implementer’s happy path.

But for rungs 1-2, do not run these in parallel. The doc now says sequential-first, but the worked example still implies parallel planning. That contradiction must be removed.

For v1:

```text
Requirements: human owner, agents review
System Design: human owner, agents review
Implementation Plan: Claude owner, Codex review
Test Plan: Codex owner, Claude review
```

The test plan should probably depend on the accepted implementation plan and system design, but not be allowed to weaken or simply mirror them. The review gate should require traceability back to requirements and explicit adversarial coverage.

Later, parallel plan drafting can return once the ledger supports multiple active phase artifacts.

3. **I agree with Claude: bounded review rounds → human escalation is the right v1 disagreement protocol.**

Do not add third-agent arbitration in v1.

Third-agent arbitration sounds elegant, but it adds a second unresolved authority problem: why is the third agent allowed to break the tie? If the answer is “because it is another model,” that is weak governance. You still need escalation, waiver, and final acceptance semantics.

The deputy workflow already has the right primitive: bounded disagreement, then surface to human. Use it.

A good v1 protocol:

```text
Review round 1: reviewer files blocking RCs
Owner resubmits with closure evidence or rejection rationale
Review round 2: reviewer approves or keeps RCs open
Review round 3 / limit reached: phase becomes BLOCKED_FOR_HUMAN
Human chooses: require owner changes, accept reviewer objection, waive with reason, reassign owner/reviewer
```

Third-agent arbitration can be a later optional input to the human, not an authority. For example: “request advisory review from Gemini before human decision.” But it should not advance state by itself.

4. **Sequential-first MVP is the correct scope.**

Yes. Rungs 1-2 only is the right call.

The actual hard problem is not multi-agent concurrency. It is making deputy’s conductor state real: typed phases, ownership, structured review artifacts, blocking closure, waivers, and phase advancement controlled by the CLI.

Parallel worktrees before that would multiply ambiguity. You would get more activity, not more reliability.

The MVP should prove:

```text
one active phase
one owner
one or more reviewers
structured review artifact
blocking required changes
resubmission with evidence
CLI-mediated advancement
human escalation on impasse
```

That is already enough surface area.

5. **New risk: “human owns Requirements/System Design” can become unreviewable unless artifact schemas are stricter.**

When an agent owns an artifact, the CLI can demand a structured submission. For a human-owned artifact, there is a temptation to let arbitrary prose through.

Do not allow that. Human-owned does not mean schema-free.

Requirements should have at least:

```text
goals
non_goals
users
functional_requirements
constraints
acceptance_criteria
open_questions
```

System design should have at least:

```text
architecture
interfaces
data_model
state_transitions
risks
alternatives_considered
test_strategy_implications
```

Agents can then review against stable fields instead of arguing with a blob of text.

6. **New risk: “human assigns Claude/Codex” conflicts with capability-based policy unless modeled as an override.**

The doc says affinity + availability fallback, but also says the human assigns Claude to implementation plan and Codex to test plan.

That is fine, but the state machine needs to distinguish:

```text
policy_default_assignment
human_explicit_assignment
fallback_assignment
```

If Claude is unavailable, does the CLI override the human’s assignment? Ask? Block? Fall back automatically?

For v1, I would make explicit human assignment sticky:

```text
If assigned owner unavailable, phase enters WAITING_FOR_OWNER unless human reassigns.
```

Do not silently fall back on foundational plan phases. Silent fallback undermines the point of human ownership.

7. **New risk: “resolved” language is still too strong.**

The doc says review gates, task decomposition, ledger shape, and thin-skill verbs are “resolved.” They are directionally resolved, not spec-resolved.

Before spec promotion, define the exact state transitions for at least:

```text
submit
review
needs_changes
resubmit
approve
waive
block_for_human
advance
```

Without that, implementers will recreate policy in prompts.

**Round-2 Verdict**

Yes, this is ready to become a spec scoped to rungs 1-2, but only if the spec is explicitly normative and trims the discussion-history contradictions.

Top 3 must-fix-first items:

1. Define human-owned phase semantics in the CLI/state machine: human submit, human accept, human waive, human assign, and `owner_type=human`.
2. Make v1 strictly sequential, including implementation-plan then test-plan; mark parallel planning and parallel implementation as later.
3. Specify the bounded disagreement protocol precisely: review-round limit, blocking RC closure, `BLOCKED_FOR_HUMAN`, waiver/reassignment outcomes, and no third-agent arbitration authority in v1.
