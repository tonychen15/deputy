# Changelog

## v1.1.1 — 2026-06-19

Patch release. Usability.

- **`deputy version` subcommand** (aliases `--version`, `-V`) — prints the installed
  version from the `VERSION` file, resolved via the real script directory so it works
  when `deputy` is invoked through its PATH symlink from any repo. Exits non-zero with a
  clear message if `VERSION` is missing. Listed in `deputy help`.

## v1.1.0 — 2026-06-19

Minor release. Migrates deputy's cross-LLM review gate to xReview's **Codex-default,
author-aware** model and removes the dead-reviewer deadlock.

### xReview gate
- **Codex is now the default reviewer**, with an author-aware fallback chain
  (`codex → gemini → claude`, the author always excluded). `deputy route review
  "<avail>" "<author>"` picks the reviewer; `claude` is eligible only when an explicit
  non-claude author is given, since it is the orchestrator. This replaces the old
  **Gemini-only** gate that bare-`wait`ed and **deadlocked** the spine when Gemini was
  unavailable (OAuth `IneligibleTierError` / rate limits).
- **No-peer degradation, per project.** When only the author is up, `route review`
  returns `self`; the spine degrades per the new `auto_mode` config key
  (`.deputy/config`): `auto_mode=1` → self-review with a loud WARNING and proceed;
  default (`0`/unset) → surface the item for the user. Reviewer-side rate-limits are
  re-routed to the next peer instead of failing the item.
- **xReview audit trail.** Every review iteration (plan / design / each implementation
  commit) is recorded via the new append-only `deputy review-log <slug>` command to
  `.deputy/<slug>.review.md` — deputy's equivalent of xReview's `.review/REVIEW.md`
  (numbered iterations with Implementing/Reviewing lines, Verdict, Findings, Action
  Items). The guardrail allowlist now permits writes to `*.review.md`.
- **New plumbing:** `deputy avail` (echoes available providers) and `deputy review-log`.
  SKILL.md and README review/routing wording are now provider-agnostic; **author ≠
  reviewer** is preserved throughout.

## v1.0.2 — 2026-06-19

Patch release. Installer usability: one-command setup and run-from-anywhere.

### Install
- **`install.sh` renamed to `inst_deputy.sh`** and added to `PATH` by `link` (alongside
  the `deputy` command). The installer now resolves its own `PATH` symlink back to the
  real checkout, so once linked it runs from **any directory** — `inst_deputy.sh init/cron`
  no longer requires `cd`-ing into the deputy repo or a `./` prefix. The risky-op guardrail
  denylist was updated to match the new name.
- **`inst_deputy.sh init` is now one-command setup**: it enables the cron heartbeat and
  bootstraps the `PATH` link (the `deputy` command, this installer, and the skill) before
  seeding the repo, so a fresh clone can run `./inst_deputy.sh init <dir>` directly — no
  separate `link` step. A foreign/locked link target only warns and never aborts the seed.
- **Hardened `cmd_link`**: every `mkdir`/`ln` is guarded with `|| return 1`, so a real
  link failure is surfaced (and `init`'s warning fires) instead of being masked by the
  suppressed `errexit` when `init` calls `cmd_link` in an `||` chain.

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
