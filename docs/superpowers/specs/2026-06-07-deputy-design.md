# Deputy — Design Spec

**Status:** Draft for review
**Date:** 2026-06-07
**Repo:** `deputy` (currently the `jobflow` working dir; to be renamed)
**Supersedes:** the bullet notes in `docs/features-todo.md`

---

## 1. What Deputy is

Deputy is an **autonomous, cron-driven backlog runner** for a code repository. You
add work to a plain-text backlog (by command or by hand-editing the file); Deputy
**triages** each item, **does the easy ones headlessly**, **grills you on the hard
ones**, executes via resumable **waypoint** checkpoints, gates quality through
cross-LLM **xReview**, and **routes work across the `claude` / `gemini` / `codex`
CLIs** with quota-aware failover. It reports back via a session banner and a
morning digest.

It deliberately covers the full GTD loop — **capture → clarify → do → reflect** —
*autonomously*. Its distinguishing trait versus blind backlog-drainers (Ralph
Wiggum, nightshift, agent-relay) is **discernment**: it decides *whether* and
*how hard* to do each item, escalates the genuinely hard calls, and never blocks
the queue while it waits on you.

### Pillars it builds on
- **[research.sh]** — the queue/lock/cron pattern it descends from (markdown queue,
  `flock`-serialized mutations, cron safety-net, stale-marker recovery, headless
  `claude -p` orchestration).
- **[waypoint]** (`github.com/tonychen15/claude-waypoint`) — resumable checkpointed
  step execution with worker subagents.
- **[xReview]** (`github.com/tonychen15/xReview`) — cross-LLM review with a
  `.review/LOCK` state machine (`implementing → reviewing → committing`).

---

## 2. Vocabulary (canonical glossary)

| Term | Meaning |
|---|---|
| **Deputy** | the system / repo / command |
| **item** | one unit of work on the backlog (never "task"/"job" — both are overloaded) |
| **the backlog** | the editable queue, file `BACKLOG.md` |
| **orchestrator** | the single skill that runs the loop (the "one brain"); interactive or headless |
| **the runner** | the thin per-repo script `bin/deputy.sh` (research.sh descendant; plumbing only) |
| **worker** | a subagent that executes one item (via waypoint) |
| **triage** | classify an item simple vs complex; emit a work order |
| **surface** | present a complex item for the human's answers; the item is *surfaced* |
| **mode** | `auto` (grill+approve, then headless) or `interactive` (stay with the human) |
| **work order** | triage output: clarifying questions, proposed plan, affected files, risk/effort |
| **morning report** | the digest of what happened: done / failed / surfaced / degraded |

---

## 3. Architecture

**Approach: thin script + smart orchestrator skill.** All judgment (triage,
grilling, driving waypoint, calling xReview, routing) lives in **one orchestrator
skill**. The bash runner is pure plumbing. The *same* skill runs whether a human
typed `deputy …` (interactive) or cron spawned `claude -p` (headless) — one brain,
two entry points.

```
deputy/                              # this repo (source + installer)
├── install.sh                       # installs global skill; optional per-repo runner; preflights CLIs
├── bin/
│   └── deputy.sh                    # the runner: queue, flock, cron, stale recovery, helpers, CLI adapters
├── skills/
│   └── deputy/SKILL.md              # the orchestrator skill (installed globally)
├── hooks/
│   └── session-start.sh             # surfacing banner + morning report (V1)
├── templates/
│   ├── BACKLOG.md                   # seed queue with legend header
│   ├── config                       # .deputy/config defaults
│   └── protected                    # .deputy/protected default globs
└── docs/superpowers/specs/…         # this spec
```

**Per-repo state** (created in the target repo on install / first run):
- `BACKLOG.md` — the queue (human-editable)
- `.deputy/` — `lock`, `log`, `<pid>.claim`, `<slug>.questions.md`,
  `<slug>.fail.md`, `<slug>.meta` (overrides), `config`, `protected`, and the
  `wt/` execution worktree (gitignored)
- reuses `.claude/waypoint/` (waypoint state) and `.review/` (xReview state)

**Execution model:** **serial** — one worker at a time.

**Ownership vs locking (important):** the `flock` on `.deputy/lock` is **short-held**
— it covers only fast queue *mutations* (pick/claim/mark/complete), exactly as
research.sh does. It is **not** held for the (minutes-to-hours) duration of a
worker run; doing so would block `status`, adds, and recovery the whole time.
Long-lived **ownership** of an item is instead represented by its `@`/`~` status
marker **plus** a `<pid>.claim` file (the research.sh pattern). **Serial execution
is enforced** by a single rule, checked under the lock: *the runner refuses to
start a new worker while any live claim exists.* A dead worker's claim is reclaimed
by stale-recovery (§13). Concurrent runner invocations (cron + interactive) are
therefore safe: they contend only for the short lock, and only one can hold a live
claim at a time.

**Worktree isolation (V1):** Deputy **never mutates your main working tree.** All
execution happens in a dedicated, gitignored **`.deputy/wt` worktree**. On a fresh
item the runner creates it from the *committed* base HEAD with a new branch
(`git worktree add .deputy/wt -b deputy/<slug> <base-HEAD>`). On **resume /
forward-recovery** the `deputy/<slug>` branch already exists, so the runner attaches
to it **without `-b`** (`git worktree add .deputy/wt deputy/<slug>`) to continue
from the last committed checkpoint — the `-b` form would error on an existing
branch. The runner therefore branches on "does `deputy/<slug>` already exist?". This means a background cron run cannot move your main HEAD,
cannot collide with your uncommitted edits, and cannot leave you on the wrong
branch if it is killed mid-run. It is still **serial** — one worktree, one worker
at a time (this is isolation for *safety*, not the V2 parallelism, which would use
*multiple* worktrees). The worktree is removed on completion; stale-recovery also
prunes an orphaned `.deputy/wt` left by a dead worker.

---

## 4. Installation

- **Global:** the `deputy` orchestrator skill + the `deputy` command, available in
  every repo.
- **Per-repo (optional):** drop `bin/deputy.sh`, seed `BACKLOG.md`, `.deputy/config`,
  the SessionStart hook, and a cron entry — enabling unattended background runs in
  that repo.
- **CLI preflight:** `install.sh` checks `claude`, `gemini`, `codex` exist and are
  authenticated; **warns** (does not block) if Gemini/Codex are missing or
  unauthenticated — Claude alone is sufficient for V1, with failover simply
  disabled until the others are ready.

---

## 5. The backlog file (`BACKLOG.md`)

```markdown
# Deputy Backlog
<!-- LEGEND — do not edit this block. Everything below the closing arrow is an item.
Status (line prefix):  (none) waiting   ~ triaging   @ running   ? surfaced   # done   ! failed
Priority (tag):        [P0] urgent+important   [P1] urgent   [P2] important   (none) lowest lane
Order:                 P0 > P1 > P2 > untagged ; FIFO within a lane
Line format:           <status?> <priority?> <description>
Add an item:           deputy "your task" [-ui | -u | -i]    — or just add a line below
-->

[P0] Fix the login redirect loop
[P1] Rotate the leaked API key
[P2] Refactor the auth module
     Tidy up the README
# Set up CI pipeline
```

### Parsing rule
Everything from the top of the file **through the closing `-->`** is a skipped
header region. Every non-blank line **after** it is an item. This avoids the
markdown-heading collision (a `#`-prefixed done line or the `# Deputy Backlog`
title could otherwise look like an item/heading).

### Line grammar
`<status-prefix?> <priority-tag?> <description>`

**Status prefixes** (leading char): none = `waiting`, `~` = `triaging`,
`@` = `running`, `?` = `surfaced`, `#` = `done`, `!` = `failed`.

**Priority tags:** `[P0]` urgent+important, `[P1]` urgent, `[P2]` important,
absent = lowest lane.

### Authority
The runner is the **only** writer of `BACKLOG.md`, and only via a lock-serialized
helper, never by direct edit — the research.sh discipline. The orchestrator calls
the helper; it never edits the file itself.

The helper mutates **by exact whole-line match**, not by line number
(`deputy.sh --set "<exact line text>" <new-state>`, implemented like research.sh's
`flip_line`). This is deliberately robust to a human editing the file mid-run:
line *numbers* shift when lines are added/removed, but an exact-line match either
finds its target or is a safe no-op. The runner never caches a line index across
the lock boundary.

- **Reserved-prefix constraint:** an item description may not *begin* with a status
  prefix char (`~ @ ? # !`) followed by a space, nor with a `[Px]` tag — those forms
  are ambiguous with the line grammar. `add` rejects them; hand-edited lines must
  avoid them too. (A future escaping scheme could lift this; out of scope for V1.)

### Priority vs the command flags
Command flags map 1:1 to on-disk tags: `-ui → [P0]`, `-u → [P1]`, `-i → [P2]`.
A hand-edited line with no tag is the lowest lane. Nothing is ever auto-dropped.

### Overrides (not in the visible file)
`--simple` / `--complex` (triage override) and `--interactive` (mode override) are
stored in `.deputy/<slug>.meta`, keyed to the item — keeping `BACKLOG.md` minimal.

---

## 6. The lifecycle of an item (GTD mapping)

### 6.1 Capture
An item enters the queue three ways: `deputy "…" [flags]`, hand-editing
`BACKLOG.md`, or being already present when cron ticks.

### 6.2 Schedule (pick next)
On each cron wake or `deputy run`, the runner: runs stale-recovery, acquires the
lock, and **picks the highest-priority `waiting` item** (`P0 > P1 > P2 > untagged`,
**FIFO within a lane**), marks it `~ triaging`, and spawns the orchestrator
(`claude -p` headless, or inline if interactive).

### 6.3 Clarify (triage)
The orchestrator classifies the item **simple vs complex** (LLM triage via Claude
Haiku; honoring any `.deputy/<slug>.meta` override) and emits a **work order**
(clarifying questions, proposed plan, affected files, risk/effort). Triage is
**orthogonal** to priority.

**Misclassification guards** (a cheap triager *will* sometimes call a complex item
"simple"): (a) triage **biases toward `complex` when confidence is low** — the cost
of an unneeded question is far less than a headless death-loop on under-specified
work; (b) a *simple* item that **exhausts its retries** is **re-triaged as
complex** and surfaced ("Deputy thought this was simple but got stuck — your
call"), rather than silently marked `! failed`; (c) the per-item **time cap** and
**max-retries** (§9, §10) bound any loop regardless.

### 6.4a Engage — simple item (headless)
1. **Guard:** refuse to start while a live claim exists (serial). The main working
   tree is never touched, so its dirtiness does not block a headless run.
2. **Isolate:** create the `.deputy/wt` worktree on branch `deputy/<slug>` from the
   base HEAD (§3 worktree isolation). All steps below run inside it.
3. Run **waypoint** (worker = Claude Sonnet) to execute the steps.
4. **xReview** (Gemini) at each waypoint **commit checkpoint**.
5. **Quality gate:** tests + lint + build must pass before `done`.
6. On success → mark `# done`; **open a PR** via `gh` if a remote exists, else
   **leave the `deputy/<slug>` branch** for manual merge (A→B fallback). Either way,
   the branch's commits are durable; the `.deputy/wt` worktree is then **removed**
   (the branch survives).
7. **Failover:** if Claude quota is exhausted mid-run, route the *simple coding*
   to **Codex** (V1). (waypoint/xReview themselves remain Claude-bound in V1.)

### 6.4b Engage — complex item
- If an item is **already surfaced** (`?` exists), leave this one **untouched** and
  continue scanning for the next runnable item. **At most one surfaced at a time.**
- **Non-starvation rule (intentional priority inversion):** a surfaced/blocked item
  — *even a P0* — does **not** block lower-priority runnable items. While you have
  not answered it, Deputy keeps executing the next runnable (simple) items down the
  lanes. "Don't block the queue on a human" is the explicit goal; the morning report
  keeps the surfaced item visible so it isn't forgotten.
- Otherwise (defer-until-human): the orchestrator (Claude Opus) drafts the
  clarifying questions + proposed plan into `.deputy/<slug>.questions.md`, marks the
  item `? surfaced`, and **stops** — it does not block the queue.
- When the human engages (`deputy review`, or via the SessionStart banner): grill
  to nail down fuzzy parts → **plan review** (Gemini xReview) → **design review**
  if a design artifact is produced → **plan approval**. Then:
  - `mode = auto` (default): hand off to a **headless** waypoint run in
    `.deputy/wt`; xReview at each commit; re-engage the human only if BLOCKED.
  - `mode = interactive`: stay with the human through execution and each review
    gate. Execution still happens in `.deputy/wt` (main tree untouched); the human
    is simply consulted at each gate instead of xReview deciding alone.

### 6.5 Reflect (light, V1)
A `deputy review` / morning-report pass summarizes **done / failed / surfaced /
degraded-failover** and re-surfaces the single outstanding needs-input item.
(Full Reflect — re-triage stale items, reprioritize, prune duplicates, capture
learnings — is V2.)

### 6.6 Cycle handoff
After an item completes, if `waiting` items remain **and** the cycle was not
rate-limited, the runner re-invokes itself (research.sh handoff) to keep draining,
**bounded by `max-items-per-cycle`**.

---

## 7. xReview integration (review touchpoints)

Per `features-todo.md`, xReview fires at **three** points, with **Gemini as primary
reviewer**:

1. **Plan review** — after Opus decomposes a complex item, before execution.
2. **Design review** — if the item yields a system/architecture design artifact,
   before building on it.
3. **Commit review** — at each waypoint commit checkpoint.

### State-machine ownership (strict nesting, one owner per layer)
Three lock/state systems coexist; ownership is strictly nested, outermost holds
the claim longest:
- **Deputy** owns the **item claim** (`@` marker + `.deputy/lock`) for the item's
  whole lifetime and is the **only** editor of `BACKLOG.md`.
- Within a claimed item, Deputy invokes **waypoint**, which owns `.claude/waypoint/`
  and the step loop. Deputy does not touch waypoint state.
- At a waypoint commit checkpoint, **xReview** is invoked as a sub-phase and owns
  `.review/LOCK` for that one cycle (honoring the `CLAUDE.md` write-restriction
  while `reviewing`). On `approved`, control returns to waypoint to commit, then to
  Deputy.
- **No layer reaches up.** Locks release inner→outer; Deputy's claim releases last.
  If a worker dies mid-flight, research.sh-style stale recovery reverts the `@`
  marker to `waiting`.

---

## 8. LLM routing (claude / gemini / codex)

### Roles
- **Claude** — orchestration + planning for complex items; primary coder.
- **Gemini** — primary reviewer (all three xReview touchpoints).
- **Codex** — failover coder for *simple* coding when Claude quota is limited.

> **Note on "Codex":** this means the current **OpenAI Codex CLI** (the agentic
> coding tool driving a modern GPT-class model), **not** the deprecated 2021
> `code-*` completion model. It is a peer-class agentic coder, not a weak fallback.
>
> **Why not fail over to Gemini for coding?** Gemini is our **reviewer**. Using the
> reviewer as the author would collapse the author≠reviewer independence that makes
> cross-LLM review valuable. Codex stays the failover *coder*; Gemini stays the
> *reviewer*. Any review-rejection churn from a Codex-authored change is bounded by
> `max-retries` (§10), after which the item escalates per the standard policy.

### Model tiering
| Step | Model |
|---|---|
| Triage (classify) | Claude **Haiku** |
| Simple execution | Claude **Sonnet** |
| Complex orchestration (decompose/grill) | Claude **Opus** |
| Complex step-workers | Claude **Sonnet** |
| Review (all touchpoints) | **Gemini** |

### Failover policy
- **Simple coding:** Claude exhausted → **Codex**.
- **Complex / waypoint-driven items:** depend structurally on Claude (waypoint &
  xReview are Claude-bound in V1) → **wait** for Claude's reset rather than
  reroute.
- **All providers exhausted:** reschedule via cron — parse **Claude's reset time**
  if available, else default to a **2-hour** retry (research.sh behavior).

### Quota detection (per-CLI adapter)
A single `detect_outcome <cli> <logfile>` classifies each invocation as
`{ ok | quota_exhausted | auth_error | hard_error }`:
- **Claude** — match `"hit your limit"` / `"resets <time>"` (reuse research.sh).
- **Gemini** — match `RESOURCE_EXHAUSTED` / HTTP 429 wording.
- **Codex** — match its quota/usage-limit wording.
- Match patterns are **centralized in one place**.
- **Conservative default:** an unrecognized non-zero exit is `hard_error`, *not*
  `quota_exhausted` — so Deputy never falsely "reroutes forever"; the morning report
  shows the raw log tail so a missed pattern is visible.

### Runtime probe (failover health)
Before routing to a provider, a tiny probe (trivial prompt → `detect_outcome`)
confirms it is callable + authed. Unavailable providers are skipped in the chain
and the degradation is **surfaced in the morning report**
("⚠️ Codex unavailable, failover degraded").

---

## 9. Safety & guardrails

| Guardrail | V1 default |
|---|---|
| Worktree isolation | all execution in a dedicated `.deputy/wt` worktree; **main tree never mutated** (§3) |
| Branch isolation | every item on `deputy/<slug>`; PR if remote+`gh`, else leave branch |
| Serial guard | **refuse to start** an item while a live claim exists (one worker at a time) |
| Max items / cycle | `5` |
| Per-item time cap | `30` min → kill + `! failed` |
| Protected paths | `.deputy/protected` globs (e.g. `.env*`, `secrets/**`, `.git/**`, `infra/**`); violation → `! failed` |
| Dry-run | `deputy --dry-run` triages + plans, touches nothing |
| Token/cost budget | *V1-light* — rely on each CLI's native quota; precise cap later |

All limits live in `.deputy/config`, overridable per repo.

**Protected-path enforcement is deterministic, not LLM-trusted.** A worker (Sonnet)
could *attempt* to touch a protected file before any "check" notices. So the
**runner (bash)** enforces it: a mandatory **pre-commit gate** diffs the staged
changes (`git diff --cached --name-only`) against `.deputy/protected` globs *before*
any waypoint checkpoint commit is finalized. A match aborts the commit and marks the
item `! failed` — the protected file never enters history. (The glob list is also
surfaced to the worker as guidance, but guidance is not the enforcement.)

**Quality-gate command discovery.** Deputy must know *how* to test/lint/build a repo
to honor the §6.4a quality gate. `.deputy/config` declares the commands explicitly:

```ini
test_cmd  = <repo's test runner, using its own toolchain/venv>
lint_cmd  = <optional>
build_cmd = <optional>
```

If unset, `install.sh` attempts a best-effort auto-detect by project type
(e.g. `package.json` scripts, `pytest`, `cargo test`, `go test`, a `Makefile`
`check`/`test` target) and writes its guess into `.deputy/config` for the user to
confirm. If no gate command can be determined, the quality gate is **skipped with a
loud warning in the morning report** rather than silently passing.

---

## 10. Failure / retry / escalation

| Kind | Detection | Action |
|---|---|---|
| **Quota / rate limit** | adapter → `quota_exhausted` | reroute (per §8) or reschedule; **never** a retry-burn or `! failed`; item stays `@` / reverts to `waiting` |
| **Recoverable** | non-zero exit, failing tests, xReview `NEEDS_CHANGES` | retry with failure as context, up to **`max-retries` = 2** (waypoint's own loop) |
| **Hard** | retries exhausted, BLOCKED, or protected-path violation | mark `! failed`, write `.deputy/<slug>.fail.md` (reason + log path), **surface in morning report**, **stop** (no loop); branch left for inspection |

**Escalation on exhausted retries:** **complex** items are **surfaced** as
needs-input ("Deputy got stuck here — your call"); **simple** items are marked
`! failed` and Deputy moves on.

---

## 11. Surfacing (V1: in-Claude)

A **SessionStart hook** injects a banner whenever you open Claude in the repo:

> ⚠️ 1 item needs your input · ✅ 3 done · ✗ 1 failed — run `deputy review`

Surfaced questions live in `.deputy/<slug>.questions.md`; the hook also renders the
**morning report**. External push/desktop/email notification is **V2**.

---

## 12. Command surface

| Command | Effect |
|---|---|
| `deputy "task" [-ui\|-u\|-i] [--simple\|--complex] [--interactive]` | add an item (writes the tag) and trigger a cycle |
| `deputy run` | trigger a cycle (headless via cron, or inline if interactive) |
| `deputy status` | counts, active workers, cron schedule, recent log (research.sh-style) |
| `deputy review` | engage the surfaced item(s) + show the morning report |
| `deputy --dry-run` | triage + plan only; touch nothing |

Internal runner helpers (not for humans): `deputy.sh --set <line> <state>`,
`--complete`, `--surface`, `--probe <cli>` — all lock-serialized.

---

## 13. Error recovery (durability)

- **flock** on `.deputy/lock` serializes every queue mutation; concurrent runners
  (cron + interactive) are safe.
- **Stale recovery:** a dead worker's `@`/`~` markers revert to `waiting` (research.sh
  `revert_stale`, keyed on a `<pid>.claim` file), and any orphaned `.deputy/wt`
  worktree it left is pruned (`git worktree remove --force` + `git worktree prune`).
  The item's `deputy/<slug>` branch (with committed checkpoints) is preserved for
  forward-recovery.
- **Forward recovery:** partial work survives on the item's `deputy/<slug>` branch +
  waypoint checkpoints; on resume Deputy continues forward, never rolls back.

---

## 14. Testing strategy

- **Runner (bash):** queue mutations, legend-skip parsing, priority ordering + FIFO,
  exact-line `--set`, stale recovery — via `bats` or shell tests.
- **CLI adapters:** `detect_outcome` against fixture logs for
  `quota_exhausted` / `auth_error` / `hard_error` / `ok`, including the conservative
  default.
- **Routing/failover:** **mock `claude`/`gemini`/`codex` stubs** (scripts that emit
  canned quota/auth/success output) to make routing deterministic.
- **Guardrails:** a fake slow/failing worker to exercise the time cap, retry count,
  and complex-vs-simple escalation split.
- **End-to-end:** `deputy --dry-run` on a scratch repo; a full headless cycle on a
  throwaway repo with a stub worker.
- **Triage prompt:** smoke-test classification on a sample item set (not
  unit-testable; assert reasonable routing).

---

## 15. Scope: V1 vs V2

**V1**
- Thin runner + global orchestrator skill; serial; single repo per install.
- Capture (command + hand-edit + cron), priority lanes, triage, surface/grill,
  `auto`/`interactive` modes.
- waypoint execution (Claude-bound), xReview at plan/design/commit (Gemini).
- LLM routing with **Codex simple-coding failover**; complex items wait for Claude.
- **Worktree-isolated** execution (`.deputy/wt`, main tree never mutated);
  branch-per-item + PR/fallback; serial guard; guardrails (max-items, time cap,
  protected paths, dry-run).
- SessionStart surfacing + light Reflect/morning report.
- **Separate task:** install + wire the Codex CLI.

**V2**
- Migrate waypoint + xReview to run on Gemini/Codex (so complex items can fail over too).
- External notifications (push/desktop/email).
- Full Reflect: re-triage stale items, reprioritize, prune duplicates, capture learnings.
- Parallel execution via *multiple* git worktrees (V1 already isolates a single one).
- Richer attributes: due/scheduled dates, dependencies (`depends-on`), project/goal grouping.
- Extra statuses (cancelled / duplicate); intake from GitHub issues / failing CI / `TODO:` scan.
- Token/cost budget cap; precise per-provider reset parsing.

---

## 16. Open questions for review

1. **Reflect/Review in V1?** Spec'd as *light* (digest + morning report), full
   version deferred to V2. *(Gemini concurs: light is correct for V1; full Reflect
   would derail V1 momentum.)* Final call is yours.
2. **Command name** — `deputy` as a standalone CLI, a Claude slash-command
   `/deputy`, or both? *(Spec assumes both; Gemini concurs this is the right
   usability path.)* Final call is yours.

### Resolved during the Gemini review (2026-06-07)
- **Slug derivation:** `deputy/<slug>` where `slug = kebab(truncate(text, ~6 words))
  + "-" + short-hash(full text)`; the hash suffix guarantees uniqueness so common
  descriptions ("fix bug") don't collide.
- **Quality-gate discovery:** `.deputy/config` `test_cmd`/`lint_cmd`/`build_cmd`
  with best-effort auto-detect at install (§9).
- **Stale line numbers / mutation-by-content:** the helper matches by exact line
  text, never index (§5 Authority).
- **Lock vs ownership:** short-held `flock` for mutations; `@`/claim file for
  ownership; serial enforced by "no new worker while a live claim exists" (§3).
- **Protected paths:** deterministic bash pre-commit gate, not LLM-trusted (§9).
- **Triage misclassification:** bias-to-complex + re-triage-on-retry-exhaustion (§6.3).
- **"Codex":** the current OpenAI Codex CLI; reviewer (Gemini) ≠ author by design (§8).

### Escalated by the Gemini review — now resolved (2026-06-07)
- **[P0] Background isolation → adopted in V1.** All execution runs in a dedicated
  `.deputy/wt` worktree; the main tree is never mutated (§3, §6.4a, §9). Still
  serial; multi-worktree parallelism remains V2.
- **[P2] Surfacing priority inversion → kept one-at-a-time, by design.** A blocked
  high-priority item must **not** starve lower-priority runnable items; Deputy keeps
  draining the queue while you have not answered (§6.4b non-starvation rule). The
  morning report keeps the surfaced item visible.
