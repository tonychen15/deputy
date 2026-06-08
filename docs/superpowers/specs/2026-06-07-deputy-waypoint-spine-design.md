# Deputy — Waypoint Checkpoint Spine (design)

**Status:** Design (approved in brainstorm 2026-06-07). Feeds an implementation plan.
**One-liner:** Absorb waypoint's forward-recovery checkpoint mechanism *into* deputy
as a pure-bash spine, so every item executes as resumable, checkpointed steps — no
external waypoint, no Python.

## 1. Decision summary (the brainstorm outcomes)
- **Absorb, don't delegate.** deputy becomes one skill that does waypoint's work; the
  external `waypoint` (a Python package) is no longer a dependency.
- **Reimplement the spine in bash.** Port waypoint's *model*, not its Python.
- **Uniform spine.** Every item runs through the spine with **1..N steps** (triage
  decides depth: simple = 1 step, complex = N). Everything is checkpointed/resumable
  (rule R1: always checkpoint before executing).
- **Internal verbs.** waypoint's verbs become internal deputy subcommands
  (`start/plan/set-step/commit/steps/resume/check/done`), driven by the orchestrator,
  not shown in `deputy help`.
- **Storage:** `.deputy/waypoints/<task_id>/` (slim schema — §3), reusing deputy's lock.
- **Claude-first**, with a single `_run_step_worker` seam for later provider routing.
- **xReview gates design, plan, and implementation** (§6).

## 2. Division of labor
- **deputy queue/scheduler** (existing): pick → triage → claim → `.deputy/wt` worktree
  → run loop (with session-limit stop + reschedule).
- **deputy spine** (new, internal bash): step ledger, `set-step`/`commit`/`resume`/
  `steps`/`done`, per-step git commits on `deputy/<slug>`, forward-recovery.
- **orchestrator (SKILL)**: decompose item → steps; drive the spine; run xReview gates.
- **worker**: claude-first behind `_run_step_worker`.

## 3. Storage — slim schema, waypoint-structure-compatible
Layout mirrors waypoint's, relocated under deputy's state dir; the **`.locks/`** dir is
dropped (reuse `.deputy/lock`), and the JSON schema is **slimmed** (Option 3):
```
.deputy/waypoints/
├── <task_id>/
│   ├── waypoint.json   # slim source of truth (JSON, via jq)
│   └── STATUS.md       # derived human render, regenerated on every save
└── archive/<task_id>/  # archive-not-delete (honors the no-delete rule)
```
**Slim `waypoint.json`** (kept vs dropped vs waypoint's original):
- **Task:** `task_id, goal, status (in_progress|completed|abandoned), created_at,
  updated_at, note?, current_step{…}, steps[]`.
  - *Dropped:* `heartbeat` (deputy's `<pid>.claim` covers liveness), `owner_session`/
    `session_history` (deputy is headless), `scope` (per-branch worktree isolates).
- **Step (`steps[]` / `current_step`):** `id, purpose, expected_result?, status
  (in_progress|succeeded), completed_at, actual_result{summary, artifacts[]{path,
  step_commit}}`.
  - *Dropped:* `context`, `target`, `inputs[]`, and the artifact **fingerprint** fields
    (`exists/git_blob/mtime/size`) — redundant once each step is a real git commit;
    these are the hardest to do in bash and buy nothing given branch commits.
- **Dependency:** **`jq`** (read/write the JSON). `install.sh` preflights it (it is far
  lighter than the Python alternative). Writes are atomic (tmp + `mv`), matching
  waypoint's tmp+`os.replace`.

## 4. Spine verbs (internal; lock-serialized; atomic)
| Verb | Effect |
|---|---|
| `deputy start <id> "<goal>"` | create the slim task json (idempotent) |
| `deputy plan <id> --step <sid> --purpose "<p>"` | append a `pending` step |
| `deputy set-step <id> --step <sid> [--expected "<e>"]` | set `current_step` (active marker) |
| `deputy commit <id> --summary "<s>" [--artifact <path> ...]` | `git -C .deputy/wt add -A && git commit` — **stage ALL** worktree changes (don't rely on the worker to declare each file; undeclared edits would otherwise bleed into the next step or be lost on resume). Record SHA, move `current_step`→`steps[]` as `succeeded`, regenerate `STATUS.md`. `--artifact` is *optional ledger metadata* (notable paths), **not** the staging selector. |
| `deputy steps <id>` | print steps + states |
| `deputy resume <id>` | print the first uncommitted step (where to continue) |
| `deputy done <id>` | mark task `completed` |
| `deputy check <id>` | (light) sanity of last step's commit; optional |

All read/write `waypoint.json` via `jq`, under `.deputy/lock`, written atomically.

## 5. Execution flow
cmd_run claims the item → creates `.deputy/wt` → spawns the orchestrator, which:
1. If `.deputy/waypoints/<slug>/` exists → **resume** (§7); else `deputy start <slug> "<item>"`.
2. **Decompose** → `deputy plan` per step (1 if simple, N if complex). → **plan xReview** (§6).
3. For each pending step: `deputy set-step` → `_run_step_worker` does the work in
   `.deputy/wt` → **implementation xReview** (gemini) on the staged diff → `deputy commit`
   (git commit on `deputy/<slug>` + ledger flip). Failure → retry ≤ `max_retries` (2).
   **The retry budget bounds review-rejection cycles too** — repeated Gemini
   `NEEDS_CHANGES` counts against `max_retries` (then escalate/surface), so a
   reviewer↔author standoff can't loop forever.
4. `deputy done <slug>` → `deputy set "<item>" done` → open PR / leave branch → `deputy wt-remove`.

## 6. xReview rule (cross-LLM gate on every artifact)
Every artifact deputy produces passes a cross-LLM (Gemini-primary) review before it
advances; **author ≠ reviewer**; no advance without a Gemini **PASS** (fix
CRITICAL/WARNING, re-review until clean):
- **Design review** — a design/spec artifact is reviewed before planning/coding builds on it.
- **Plan review** — the decomposed step plan is reviewed before the step loop starts.
- **Implementation review** — each step's staged diff is reviewed before `deputy commit`.

This also governs building deputy itself: the *design doc* and the *implementation plan*
for this work are Gemini-reviewed, not just the code.

## 7. Resume / forward-recovery
On interruption (Claude/machine down, or the run loop's **session-limit stop**), the
**ledger persists** in `.deputy/waypoints/<slug>/` and committed steps live on the
branch. `recover` reverts the item to `waiting`. On next pick, the orchestrator detects
the existing ledger → `deputy resume <slug>` (first uncommitted step), re-creates the
worktree from the branch, and **continues forward** — re-running only the uncommitted
step. **Before re-running, it purges any dirty state** in the worktree
(`git reset --hard HEAD && git clean -fd`) so a half-written interrupted step can't
poison the retry. (The run loop's quota reschedule composes: committed steps survive,
resume after reset.)

## 8. Claude-first seam
`_run_step_worker <step>` is the single chokepoint that executes a step (claude now).
The spine verbs are provider-neutral (they only track state), so cross-provider step
routing later just fills in this seam — no schema change. **Caveat:** inline steps
accumulate the orchestrator's context across all N steps (fine for V1's small step
counts); the same seam is where a **context-flushing per-step sub-worker** plugs in for
long/complex tasks (avoids context exhaustion / instruction amnesia).

## 9. Testing
Pure-bash unit tests (jq-backed), in the existing harness:
- each verb's state transition: `start` shape, `plan` appends `pending`, `set-step` sets
  `current_step`, `commit` flips to `succeeded` + records the SHA (real git in a temp
  repo) + regenerates `STATUS.md`, `steps`/`resume` outputs.
- **forward-recovery**: interrupt mid-plan → `resume` returns the first uncommitted step
  → continuing completes the task.
- slim-schema shape asserted; atomic-write (no torn file) sanity.
- `install.sh` jq-preflight test.

## 10. Scope (this item vs later)
**In:** the bash spine + verbs + slim ledger + uniform execution-through-the-spine +
forward-recovery resume + `jq` preflight + the xReview gates wired into the loop.
**Out (separate items that build on this):** the suspension *states*
(`preempted`/`blocked`/`scheduled`/`awaiting`), cross-provider step routing, true
parallel preemption. (See `2026-06-07-deputy-suspension-resume.md`.)

## 11. Decisions on prior open points
- **`task_id` = the deputy slug** (`kebab+hash`) as-is — the hash already guarantees
  uniqueness; no date prefix needed (it's just the ledger dir name).
- **Steps run inline** in the orchestrator (the claude agent does the step work itself)
  for V1 — no Agent tool in `--allowedTools`, no nested subagents. A spawned per-step
  sub-worker is a later option (and it's where the `_run_step_worker` seam / cross-provider
  routing would plug in).
