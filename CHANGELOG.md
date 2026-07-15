# Changelog

## v1.5.1 — 2026-07-15

Quality-of-life release adding passive task-progress visibility, automated test selection, priority-aware run/add commands, and several reliability fixes to the quality gate and worktree cleanup.

**Features**

- `deputy progress <id>` / `deputy watch <id> --once`: passive read-only progress view — step %, ETA band, done-so-far digest, and run-log tail; never touches the running worker (#108)
- Tier 3 within-step % for single-step tasks: passive run-log milestone inference (files edited → staged → tests → xReview → commit) labelled clearly as a heuristic estimate (#110)
- `deputy test --changed`: automated changed-files → affected-tests selector via function-level naming-convention manifest; falls back to full suite on unmapped changes (#109)
- Priority-aware `deputy run <id>`: higher-priority targeted run cooperatively pauses the running item; lower/equal-priority warns and leaves waiting; cron tick still silent-skips (#102)
- `deputy run --<prio> <desc>`: add-and-run shorthand — adds task then immediately runs or queues based on priority relative to waiting items (#104)
- `deputy add --<prio>`: runs the new task immediately when idle with no higher-priority waiting tasks (#105)
- Hardness-routed, config-driven worker model: sonnet/fable/opus tier selection based on task complexity
- `deputy release` is now a one-command release orchestrator

**Fixes**

- Fix test_install false-failures when run inside `.deputy/wt`: introduce `MAIN_REPO` for path assertions so 4 previously failing tests pass from both main tree and worktree (#106)
- Auto-delete merged `deputy/<slug>` branch when `auto_merge=1`; treat explicit empty `delete_merged_branch=` as disabled (#103)
- Harden #89 quality gate: on full-suite failure isolate to failing test file(s) rather than re-running the whole suite; add environmental-failure allowlist covering the worktree test_install case (#107)

## v1.5.0 — 2026-07-12

Minor — the "what needs me" UX (list / watch / pickup), deterministic task branches, a
working `auto_merge`, and CLI/config ergonomics (12 backlog items).

**New commands & flags**
- **`deputy pickup <id>` (#99).** Bring up ONE attention task and act on it: ready-to-merge →
  merge into the default branch (→ done); proposed → approve; needs-input → resume via
  `/deputy`; failed/cancelled/deferred/paused → requeue. Local/safe only (never pushes).
- **`deputy config <key> <value>` setter + `autonomy on|off` (#90).** `config` was read-only;
  it now upserts `.deputy/config` atomically. `autonomy on|off` flips both autonomy knobs at
  once. Renamed `auto_mode` → `self_review_fallback` (back-compat alias kept).
- **`deputy list --porcelain` + `list <id>` (#93/#91).** Stable `state|prio|id|desc` machine
  output; filter by id. Plus a blank line between items (#92) and a count summary (#100).
- **`deputy cron set <N>` (#96).** Change the heartbeat interval live (crontab-first, atomic).
- **`deputy -h --full` (#101).** Config keys are hidden from the default help; `--full` shows them.

**The "what needs me" consolidation (#99)**
- Three clear roles — **`list`** (LOOK: per-task detail for surfaced/failed/deferred/…),
  **`watch`** (ALERT: queue overview + 3-beep summon; monitors surfaced/failed/deferred),
  **`pickup`** (ACT). `deputy reflect` is folded into `watch` (kept as an alias).

**Deterministic, idempotent task branches (#98/#99)**
- A task's branch/worktree slug is frozen at add-time from the immutable user description
  (`<id>-<hash>-<desc>`, via `deputy slug <id>`), so every resume/rerun reuses the SAME
  branch — no more duplicate branches from re-slugging a description.

**Fixes**
- **`auto_merge` actually works (#97/#98).** The merge moved to the UNSANDBOXED runner (the
  #64 sandbox made the worker's in-tree merge impossible); the ready-merge branch is recorded
  deterministically so resumed runs merge too.
- **Guardrail hardening (#95).** Deny patterns now resist `VAR=val` / `command` / `env` /
  wrapper prefixes; `GIT_DIR=`/`GIT_WORK_TREE=` env-redirects and multiple-`-C` are handled;
  `git --no-pager push` is anchored. Security-reviewed.
- **Watchdog `.bak` torn-write recovery (#94).**

## v1.4.0 — 2026-07-12

Minor — autonomy hardening + CLI consistency (10 backlog items + follow-up fixes).

**Autonomy & resilience**
- **Inode-preserving BACKLOG writes (#85).** A concurrent human/agent queue edit no longer
  orphans a running sandboxed worker's inode-pinned `BACKLOG.md` bind: `_backlog_commit`
  writes in-place (preserving the inode) while a run is live, and uses atomic `mv` only when
  idle. Fixes the death-loop where a worker got wedged on "BACKLOG.md not writable".
- **Fail-fast on unrecoverable writes (#86).** `_backlog_commit` emits a distinct exit(3) +
  message when `BACKLOG.md` is persistently unwritable; the SKILL tells the worker to write a
  fail-file and exit (never `set surfaced`, which writes the same broken file) rather than
  burn tokens retrying. `cmd_set`/`cmd_claim` preserve the rc.
- **Runner watchdog (#87).** A background watchdog kills a headless worker that makes no
  waypoint progress for `watchdog_mins` (default 45; 0 disables) and surfaces it — an
  enforcement backstop independent of agent cooperation. Progress = newest file mtime under
  the item's own waypoint dir.
- **`deputy cron status` (#82).** Reports enabled / schedule / last-run for the current repo.

**CLI consistency**
- **Unified state/id grammar (#80).** `#<id>` = item id, a bare word = state, `p0`–`p4` =
  priority, across list/set/clean/run; every prior flag/keyword form kept as a back-compat
  alias, and the headless worker whole-line `set "<line>" <state>` contract is preserved.
- **`deputy list` prints BACKLOG.md format (#84)** (`@[#1][P0] desc`), consistent with the
  file, instead of the `state|priority|id|desc` pipe format. (No longer pipe-parseable —
  see the `--porcelain` follow-up #93.)
- **`deputy add` reports the assigned id (#83)** — `deputy: added #<id>: …`.
- **`deputy list <state>` prints "0 tasks in <state> state" when empty (#81).**
- **`deputy cron` bare subcommands (#88)** — `ensure|remove|status` (legacy `--flags` kept);
  `reschedule` stays as the orchestrator-internal quota-failover verb (unadvertised).

**Performance**
- **Two-phase quality gate (#89).** Headless workers run *targeted* tests during iteration
  and the full suite *once* before the final commit (was: full suite on every step/retry — a
  ~1-line change took ~30 min), plus a tightened, unambiguous per-step retry budget.

Also: `deputy watch` (the v1.3.3 quiescence monitor) now beeps + surfaces **all** pending
kinds — needs-input, ready-to-merge, and proposed — not only blocking surfaces; and the
opt-in merged-branch delete (#77) gained default-branch containment.

## v1.3.3 — 2026-07-12

Patch — `deputy watch` becomes a passive summon-on-quiescence monitor; opt-in merged-branch cleanup.

- **`deputy watch` is now a passive, read-only quiescence monitor (#79).** While a worker
  runs it live-tails as before; when the backlog goes quiescent — no runnable items left and
  at least one item surfaced needing input — it beeps 3× (TTY-guarded) and prints a one-time
  resume digest (each surfaced item with its questions-file path, first-line summary, and a
  `run /deputy` resume tip), re-arming after each new run. Never mutates queue state; adds a
  `--once` single-pass seam. The digest resolves the questions file across both slug
  conventions (`<desc>-<id>` and `<id>-<desc>`) plus legacy flat paths.
- **Opt-in auto-delete of merged `deputy/<slug>` branches (#77).** New `delete_merged_branch`
  config (default `0`). When enabled, `_wt_remove` deletes the local branch after a clean
  merge via `git branch -d` (merged-only, never `-D/-f`), gated on HEAD being the default
  branch **and** the branch being an ancestor of HEAD — so it fires only on the post-merge
  success path and safely preserves the branch on surface / ready-merge / conflict-abort.
  Local only; never touches the remote.

## v1.3.2 — 2026-06-24

Patch — customer-project upgrade ergonomics.

- **Self-heal so customer projects never need re-init after an upgrade (#76).** Protected
  globs now LAYER the per-project `.deputy/protected` over the release template defaults, so
  new default globs shipped in a release reach existing projects automatically (and a project
  with no file still gets the safe baseline); a missing `.deputy/config` / `.deputy/protected`
  is auto-seeded from the templates on run; and `_config_get` is now **last-wins** on
  duplicate keys, so an appended override beats an earlier (e.g. template-seeded) line instead
  of returning the stale first value. Net: a customer runs `init` **once**, and every release
  afterward auto-applies (command, skill, hook, config defaults, and protected globs) with
  zero per-project action.
- **Document the upgrade story (#75).** The README "Upgrading" section now makes explicit that
  the `deputy` command, the `/deputy` skill, and the guardrail hook are a single **global**
  install shared by every project — so `git pull` in the deputy repo upgrades all projects at
  once — and folds in the #76 self-heal behaviour.

## v1.3.1 — 2026-06-24

Patch — docs & process.

- **BACKLOG legend refresh (#74).** The live `BACKLOG.md` legend had drifted: it showed the
  pre-#62 line format `<status?>[Px][#N]` and the pre-#46 status symbols (`#` done / `>`
  deferred). Updated to the id-first `<status?>[#N][Px]` order and the current `+`/`;`
  symbols (with the legacy-read note); aligned `templates/BACKLOG.md` to match.
- **Release-process rule.** Added `CLAUDE.md`: a version bump must update `CHANGELOG.md`
  **and** insert a new `BACKLOG.md` release-marker delimiter (`deputy release X.Y.Z`)
  together — the lockstep the v1.2.0 release missed.

## v1.3.0 — 2026-06-24

Minor release. Clears the backlog to zero open items — write-path safety, the agent-claim
race protocol, and a batch of CLI/format polish. All changes cross-LLM reviewed; the full
suite stands at 68 suites / 1221 tests.

### Reliability & race safety
- **Repo-wide write-path hardening (#47, #73).** Every `BACKLOG.md` write
  (`_regroup_backlog`, `_flip_line`, `_allocate_ids`, `_append_item`, `cmd_clean`) is now a
  single atomic transaction routed through `_regroup_backlog`, and every internal `printf`
  loop is failure-checked — a disk-full / partial write can no longer leave a
  truncated-but-non-empty `BACKLOG.md` and still report success. Also works when the repo
  directory is read-only but `BACKLOG.md` is rw-bound (the bwrap sandbox case).
- **Working-tree leftover gate (#65).** `deputy recover` and a new **`deputy doctor`** warn
  about a hung worker's stray uncommitted changes in the main tree (excluding `BACKLOG.md`
  and `.deputy/`), instead of only discovering them when the next merge aborts.
- **Agent-claim protocol — the agent now conforms (#67).** The interactive orchestrator
  acquires the active-run claim (`deputy claim --agent`) with agent-shaped heartbeat-TTL
  liveness (refresh-while-active, auto-EXPIRE after ~2× `heartbeat_mins`), so the cron
  heartbeat backs off uniformly across human/agent/cron rather than racing on the single
  `.deputy/wt` slot. `cmd_recover` is TTL-aware (a fresh agent claim survives; an expired
  one is reaped). Adds a **startup-crash circuit-breaker** (`startup_fail_strikes`, default
  3): a worker that dies before any waypoint progress is retried, then surfaced for a human
  instead of respawning every tick.

### CLI & format
- **`deputy set prio|state` (#69).** Re-prioritize an item by id (`set prio #N p0`) or set
  state explicitly (`set state #N done`). The bare `set "<line>" <state>` whole-line form
  (the headless-worker contract) is unchanged.
- **Per-command help (#72).** `deputy <cmd> --help|-h` prints focused help for that command,
  sliced from the canonical `usage()` so it can never drift; aliases and a full-usage
  fallback for plumbing verbs.
- **Id-first item line order (#62).** Serialized items are now `<state>[#N][Pn]` (id first).
  The parser is order-free and content-driven (`P…` → priority, `[#N]` → id) and old
  `[Pn][#N]` files migrate on next write.
- **Tidier `.deputy/` (#70).** Per-item runtime trails moved into `reviews/`, `questions/`,
  `fails/` subfolders, with a one-shot migration of existing flat trails.

## v1.2.0 — 2026-06-21

Minor release. **Autonomous runs are now safe to leave armed.** A batch of hardening so a
headless heartbeat worker can't crash, run stale code, silently run away, auto-merge
unsupervised, or leak processes — plus reviewer-routing, run-mode, and CLI improvements.

### Autonomy safety
- **Decoupled executable (#50).** `deputy` re-execs at startup from an immutable,
  content-addressed snapshot under `~/.cache/deputy/`, so editing or merging `bin/deputy.sh`
  mid-run can no longer truncate a running invocation.
- **Surface, don't auto-merge (#60).** A spawned (headless) worker no longer merges its
  branch to the default branch — the guardrail blocks it (unless `auto_merge=1`) and the
  worker SURFACES the branch for human review (`deputy set <line> surfaced --ready-merge`,
  excluded from the blocking-surfaced count). `max_items` now defaults to **1** and has no
  unbounded mode, so a single tick can't drain + merge the whole queue.
- **Announce every autonomous spawn (#59).** The heartbeat emits a `===SPAWN===` cron.log
  line + a notification (`notify_on_spawn`, default on) whenever it auto-spawns a worker.
- **Reap leaked worker subtrees (#58).** A headless worker runs in its own process group;
  deputy reaps any background children it leaks on completion (never deputy's own group).
- **Stale-orphan warnings (#57).** On each run deputy WARNS (never kills) about a long-lived
  bash orphan under an in-repo Claude session (`orphan_warn_mins`, default 30).
- **Cautious `waiting` back-off (#55).** A session at the (undocumented) `waiting` status
  must hold it for `waiting_backoff_strikes` ticks (default 3) before the heartbeat proceeds.
- **Worker-proposed tasks need approval (#53).** A `deputy add` by a running worker lands
  `surfaced` (a proposal), never auto-runs, until a human approves it.

### Reviewer routing & run modes
- **Author-aware xReview (#54).** The reviewer is the highest-preference non-author peer
  (Codex-first when Claude authored; Claude-first when Codex/Gemini did) — never the author.
- **Headed worker runs (#51).** An interactive `deputy run` streams the worker's output
  live; cron/no-TTY stays buffered.

### CLI & UX
- **`deputy set <id> <state>` (#56)** accepts an item id, like `run #N` / `clean N`.
- **`deputy list --<state>`** filters by state (#48); read-only `status`/`list` no longer
  solicit an action (#45); state symbols migrated with dual-read back-compat (#46).
- New config keys: `auto_merge`, `notify_on_spawn`, `orphan_warn_mins`,
  `waiting_backoff_strikes`, `human_idle_grace_mins`, `heartbeat_mins`.

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
