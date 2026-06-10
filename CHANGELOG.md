# Changelog

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
