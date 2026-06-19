# Changelog

## Unreleased

### Install
- **`install.sh` renamed to `inst_deputy.sh`** and added to `PATH` by `link` (alongside
  the `deputy` command). The installer now resolves its own `PATH` symlink back to the
  real checkout, so once linked it runs from **any directory** — `inst_deputy.sh init/cron`
  no longer requires `cd`-ing into the deputy repo or a `./` prefix. The risky-op guardrail
  denylist was updated to match the new name.

## v1.0.1 — 2026-06-10

Patch release. Safety and usability improvements across the queue engine, scheduler,
and orchestrator skill; no breaking changes.

### Safety
- **Human-session back-off**: `deputy run` now detects live interactive Claude sessions
  in the repo and skips the tick silently (logs PID to stderr). Configurable via
  `human_backoff=1` (default ON) in `.deputy/config`.
- **Run default-branch guard**: `deputy run` refuses to start when the repo is not on
  its configured default branch, preventing accidental item execution on feature branches.
- **Back-off recheck in drain loop**: the human-session back-off gate is re-evaluated
  on every iteration of the drain loop, not just at entry.
- **Stale-session surface**: when a stale CLI session file is detected, `deputy run`
  surfaces the top waiting item rather than proceeding silently.

### Queue engine
- **Extended priority system** (P0–P4): priority lanes expanded to five tiers. Untagged
  items now default to `[P3]` at numbering time; existing untagged items backfilled.
  `--p3`/`--p4` flags added to `deputy add`.
- **`deputy clean <id>`**: remove a single item by numeric ID without touching the rest
  of the queue; respects the cleanable-state guard.
- **Queue autocommit**: BACKLOG.md is auto-committed after every mutation; surface
  cleanup now consistent across all paths.
- **`deputy claim` hidden from public help**: orchestrator-internal plumbing, now
  documented only in `SKILL.md`.

### Orchestrator skill
- **`reflect` / `review` merge**: `reflect` now includes surfaced question files and a
  full status digest. `review` retained as a backward-compatible alias.

### Housekeeping
- Removed legacy project-name references from suspension-resume spec.

---

## v1.0.0 — 2026-06-09

First release. Deputy is an autonomous, cron-driven backlog runner for a code repo: add
tasks to `BACKLOG.md`, and deputy triages each, executes it in an isolated git worktree,
gates quality through cross-LLM review, and tracks state — surfacing for the human only
when it needs a decision.

### Core
- **Queue engine** (`bin/deputy.sh`): `BACKLOG.md` model — status prefixes, `[P0/P1/P2]`
  priorities, stable `[#N]` item IDs; `flock`-serialized atomic mutations; priority + FIFO
  scheduling; claim-based serial ownership; stale/orphan recovery.
- **Checkpoint spine**: resumable per-step execution in a dedicated `.deputy/wt` git
  worktree, per-step commits, and forward-recovery resume from the first uncommitted step.
- **Orchestrator skill** (`skills/deputy/SKILL.md`): triage → spine → cross-LLM xReview
  (Gemini-primary) → safe merge into the local default branch. **Never auto-pushes** —
  pushing is the user's decision.
- **Item states**: `waiting`, `triaging`, `running`, `surfaced`, `done`, `failed`,
  `cancelled`, `duplicate`, `paused` (mid-execution checkpoint), `deferred` (parked).
- **Targeted run** `deputy run <id>`; **state cleanup** `deputy clean [--dry-run]
  [--state <state>]`; re-triage `deputy reflect`.

### Autonomy & safety
- **Always-on heartbeat** (`*/N` cron, default 10 min — `heartbeat_mins` config):
  state-aware tick that recovers + resumes dead/interrupted tasks; atomic claim;
  PID + process-start-time validation; durable retry budget to prevent crash-loops.
- **Risky-op guardrail**: a PreToolUse hook scoped to the spawned orchestrator that blocks
  out-of-worktree writes and a Bash denylist (push, crontab, `install.sh`, `rm -r`,
  destructive git, global installs, …). Best-effort tripwire; the hard boundary is
  never-auto-push + human review.
- **Provider routing** across `claude`/`gemini`/`codex` with quota failover.

### Install
- `install.sh link` (symlink the CLI + orchestrator skill, worktree-safe),
  `install.sh init <repo>` (seed `BACKLOG.md`, config, protected globs, intake guidance),
  `install.sh cron` (opt into the heartbeat).
