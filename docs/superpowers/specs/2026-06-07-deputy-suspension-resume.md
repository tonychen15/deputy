# Deputy — Suspension & Resume subsystem (design)

**Status:** Design (V2). Captures decisions from the 2026-06-07 discussion. Several
existing backlog items fold into this (priority preemption, dependencies, parallel
worktrees, scheduled/due-dates, full Reflect, notifications).
**Prerequisite:** waypoint must be wired into execution (see Rule R1) — this whole
subsystem rests on waypoint forward-recovery. **STATUS: satisfied** — the checkpoint
spine shipped (`2026-06-07-deputy-waypoint-spine-design.md`, merged `cac089d`), so R1's
substrate now exists; the resumable family (preempted/interrupted/awaiting) can be built
on it.

## 1. Problem
A task is often neither `done` nor actively progressing. Today deputy only has
terminal states + `surfaced`; it has no first-class notion of *suspended-but-
resumable* work, and no dependency awareness. This subsystem defines the states,
the durable resume substrate, and the resume/unblock triggers.

## 2. Core rules
- **R1 — Always checkpoint before executing.** Every task execution (even a "simple"
  item) **first saves a waypoint checkpoint**, then works in steps that each commit a
  durable checkpoint on the item's `deputy/<slug>` branch. Consequence: any
  interruption/preemption is resumable from a known point. *(This changes today's V1
  simple path, which bypasses waypoint.)*
- **R2 — Dependency-aware scheduling (run prerequisites first).** If an item declares
  a dependency that is not yet `done`, deputy does **not** just skip/surface it — it
  **executes the prerequisite first to unblock it**, then returns to the dependent
  item. This is topological execution of the dependency graph; it may temporarily
  override priority (run a lower-priority prerequisite so a higher-priority item can
  proceed). Cycles must be detected → surface/fail rather than loop.
- **R3 — One human gate (`surfaced`) with a reason.** `surfaced` carries a reason:
  `answer` (needs a clarifying answer) or `approve` (needs authorization for a
  risky/irreversible action — rename, delete, force-push, merge-to-main, anything
  outside the repo). Risky ops MUST take the `approve` path, never headless. (The
  `jobflow→deputy` rename is the cautionary precedent.)
- **R4 — Don't churn gated items.** For gated states the scheduler checks the gate
  **cheaply** and skips if still closed; it never re-claims/re-spawns a worker on an
  item whose precondition is unmet.

## 3. The four families
Every non-`done` task falls into one of these; conflating them is where rules blur.

| Family | Meaning | Resume substrate | Resume / unblock trigger |
|---|---|---|---|
| **Resumable-suspended** | was in flight; continue forward from checkpoint | **waypoint** (R1) | varies (below) |
| **Gated-suspended** | can't proceed until a precondition is met | n/a (hasn't run, or paused at a gate) | the gate opens |
| **Time-gated** | a gate whose precondition is the clock | n/a | the time arrives |
| **Terminal** | never resumed | — | — |

## 4. States & cases
| # | Cause | State (reason) | Family | Resume / unblock trigger |
|---|---|---|---|---|
| 1 | **Preempted** by a higher-priority item | `preempted` | resumable | the preemptor reaches `done` → resume **immediately** |
| 2 | **Interrupted** (Claude stopped / machine down) | orphaned → reclaimed | resumable | next time deputy picks it → continue from last checkpoint |
| 3 | **Blocked on a human answer** | `surfaced` (`answer`) | gated | human answers via `deputy review` |
| 4 | **Blocked on human approval** for a risky/irreversible op | `surfaced` (`approve`) | gated | human authorizes |
| 5 | **Blocked by a dependency** (another item not `done`) | `blocked` (`depends-on:<ref>`) | gated | run the prerequisite first (R2); unblock when it's `done` |
| 6 | **Blocked on an external resource** (provider down/unauthed, missing secret, service unreachable) | `blocked` (`resource`) | gated | retry when available; escalate to `surfaced(approve)` if it needs a human (e.g. `codex login`) |
| 7 | **Deferred until a time** (due/scheduled, or session-limit reschedule) | `scheduled` (`at:<time>`) | time-gated | the clock passes the time |
| 8 | **Awaiting a long-running external job** (CI, deploy, remote task) | `awaiting` | resumable | the external signal/poll reports completion |
| — | **Terminal** | `done` / `failed` / `cancelled` / `duplicate` | terminal | — |

Existing terminal/active states (`waiting/triaging/running/surfaced/done/failed/
cancelled/duplicate`) stay; **new** states this introduces: `preempted`, `blocked`,
`scheduled`, `awaiting` (+ `surfaced` gains a reason, + items gain optional
`depends-on` / `at` metadata in `.deputy/<slug>.meta`).

## 5. Resume triggers, by case
- **preempted (1):** when the preemptor finishes, the runner immediately re-picks the
  `preempted` item (it outranks fresh work — it was already in progress) and resumes
  from its checkpoint.
- **interrupted (2):** `recover` reclaims orphaned in-flight items; on next pick the
  worker resumes from the last committed checkpoint (forward-recovery; re-runs only
  the uncommitted step).
- **surfaced (3,4):** stays gated until the human responds; `deputy review` shows the
  reason (`answer`/`approve`) and the drafted questions / proposed action.
- **blocked-dependency (5):** scheduler resolves the dependency first (R2).
- **blocked-resource (6):** scheduler retries on a backoff; if human-fixable, escalate.
- **scheduled (7):** runner skips until `now ≥ at`.
- **awaiting (8):** runner polls / waits for the external completion signal.

## 6. Dependencies this design has
- **waypoint wiring** (R1) is a hard prerequisite for the resumable family (1,2,8).
- **parallel worktrees** are needed for true preemption (the paused item and the
  preemptor coexist) — though a serial variant (checkpoint + kill + resume-later)
  works without concurrency.
- **`depends-on` / `at` metadata** (the "richer attributes" backlog item) is needed
  for cases 5 and 7.

## 7. How existing backlog items fold in
- "Priority preemption …" → case 1 (+ R1, parallel worktrees).
- "richer attributes: due dates, dependencies" → cases 5, 7 (`depends-on`, `at`).
- "Support parallel execution via multiple git worktrees" → enables true preemption.
- "Migrate/wire waypoint" → R1 substrate.
- "external notifications" → surface the `approve`/`answer` gates (3,4) to the human.
- "full Reflect" → periodically re-evaluate `blocked`/`scheduled`/`awaiting` items.

## 8. Open questions
- Serial vs concurrent preemption for V2-first (serial = checkpoint-kill-resume-later;
  concurrent = paused + preemptor run in parallel worktrees).
- Dependency reference format (`depends-on` by slug? by description? an explicit id?).
- Backoff policy for `blocked(resource)` and poll cadence for `awaiting`.
