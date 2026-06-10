# Deputy

**An autonomous, cron-driven backlog runner for a code repository.**

You add work to a plain-text backlog; Deputy **triages** each item, **does the easy
ones headlessly**, **grills you on the hard ones**, executes in an isolated git
worktree, gates quality through **cross-LLM review (xReview, Gemini)**, and **routes
work across the `claude` / `gemini` CLIs** with quota-aware failover. When
Claude's session limit is hit, the next heartbeat tick picks it up and resumes.

Deputy is a thin, dependency-light **bash** tool — a descendant of the `research.sh`
queue pattern. Its distinguishing trait versus blind backlog-drainers is
**discernment**: it decides *whether* and *how hard* to do each item, escalates the
genuinely hard calls, and never blocks the queue while it waits on you.

> **v1.0.0** — queue engine, scheduling/routing, orchestrator, checkpoint spine,
> always-on heartbeat, risky-op guardrail, item IDs, Gemini xReview,
> `paused`/`deferred` states, `clean --state`, and `reflect` are all shipped and
> live-validated end-to-end. The repo's own `BACKLOG.md` is the project's task queue
> — Deputy dogfoods itself.

---

## Install

```bash
# 1) Clone the deputy repo, then put the `deputy` command on your PATH + install the orchestrator skill
git clone https://github.com/tonychen15/deputy
cd deputy
./install.sh link            # → ~/.local/bin/deputy  and  ~/.claude/skills/deputy

# 2) Initialize each repo you want Deputy to manage (idempotent; never clobbers your backlog)
./install.sh init /path/to/your/repo   # seeds BACKLOG.md, .deputy/config, .deputy/protected, .gitignore

# 3) (Optional) Enable the always-on cron heartbeat in that repo
./install.sh cron            # writes a */10 cron entry (interval configurable via heartbeat_mins)
```
`install.sh` uses **symlinks**, so the command + skill always run the latest code — no
per-repo copying. Re-run `install.sh init <dir>` in a repo only to pick up newly-seeded
config files.

**Isolated installs:** set `DEPUTY_PREFIX` to override the bin directory (default `~/.local/bin`)
and `DEPUTY_SKILLS_DIR` to override the skills directory (default `~/.claude/skills`).

**Dependencies:** `bash` 5+, `git`, `flock`, coreutils; `jq` (for the checkpoint
spine); and the agent CLIs (`claude` required; `gemini` for xReview).
`install.sh` preflights them and warns about what's missing.

---

## Upgrading

The `deputy` CLI and the `/deputy` orchestrator skill are **symlinks** into the deputy
repo (`~/.local/bin/deputy → <repo>/bin/deputy.sh` and
`~/.claude/skills/deputy → <repo>/skills/deputy`), so upgrading is just:

```bash
cd <deputy-repo>
git pull          # command + skill auto-update — symlinks resolve to the live files
```

No per-repo skill re-install is needed in any project that uses Deputy.

**Re-link only if** the symlinks are missing or broken, or if `install.sh`'s link layout
changed:

```bash
./install.sh link   # idempotent — safe to re-run
```

**Per-repo seed files are copied, not symlinked.** After a deputy upgrade, optionally
re-run `init` to pick up newly-seeded config keys or templates — it never overwrites
your existing `BACKLOG.md` or config:

```bash
./install.sh init /path/to/your/repo
```

**Cron schedule:** if the heartbeat interval or cron format changed, refresh it:

```bash
./install.sh cron           # or: deputy cron --ensure
```

**Check the installed version:** `cat <deputy-repo>/VERSION` (currently `1.0.0`).

---

## Usage

```bash
deputy add "fix the login redirect loop" -ui   # add an urgent+important item (-ui=P0, -u=P1, -i=P2)
deputy add "tidy the README"                    # untagged = lowest lane; --p0/--p1/--p2 also accepted
deputy list            # parsed items: state|priority|id|description
deputy status          # counts by state
deputy pick            # the highest-priority waiting item (raw line)
deputy run [--once]    # work the backlog (triage → do / surface), until empty or session limit
deputy run <id>        # targeted run: bypass priority order and run a specific item by id
deputy review          # show surfaced items, their questions, and the digest
deputy reflect         # re-triage report: learnings, untagged items, reprioritization, duplicates
deputy clean [--dry-run] [--state <state>]
                       # remove items of <state> (default: waiting = untouched);
                       # cleanable: waiting, done, failed, cancelled, duplicate, deferred
```

**Priority flags** (Eisenhower): `-ui` urgent+important (`P0`), `-u` urgent (`P1`),
`-i` important (`P2`), none = lowest. `--p0/--p1/--p2` also accepted. Use `--` before a
description that starts with `-`.

---

## The backlog file (`BACKLOG.md`)

Human-editable. A markdown legend header, then a `## Items` section — one item per line:

```markdown
## Items

[P0] Fix the login redirect loop
#[P1] Add caching                  # done
Refactor the data layer            # waiting, no priority
```

**Status prefix** (first char): *(none)* waiting · `~` triaging · `@` running · `?`
surfaced · `#` done · `!` failed · `%` cancelled · `=` duplicate · `^` paused · `>` deferred.
**`^` paused** — mid-execution checkpoint; auto-resumes on next heartbeat.
**`>` deferred** — parked for future consideration; inert, never auto-scheduled; revive with
`deputy set "<line>" waiting`.
**Priority tag:** `[P0] > [P1] > [P2] > untagged`; FIFO within a lane.
**Item IDs** `[#N]` are assigned automatically when an item is picked; use
`deputy run <id>` to target a specific item directly.
Items are blank-line separated; the parser reads everything after `## Items`.

---

## How it works

- **Thin runner (`bin/deputy.sh`)** — pure-bash queue plumbing: `flock`-serialized
  atomic mutations, claim-based serial ownership, stale recovery, the `run` loop, cron
  safety-net + rate-limit reschedule, and the CLI adapters (`detect`/`probe`/`route`).
- **Orchestrator skill (`skills/deputy/SKILL.md`)** — the "one brain." Spawned headless
  (`claude -p`) per claimed item, or invoked interactively (`/deputy`). It triages,
  does simple items, surfaces complex ones for your input, and drives execution.
- **Checkpoint spine** — every item runs as resumable, forward-recovery steps. Per-step
  git commits land in a dedicated `.deputy/wt` worktree; the ledger lives under
  `.deputy/waypoints/`. On resume, the spine purges dirty state and continues from the
  first uncommitted step.
- **Isolation** — every item runs on its own `deputy/<slug>` branch in the dedicated
  `.deputy/wt` git worktree; your main working tree is never touched.
- **xReview** — cross-LLM review (Gemini-primary) gates **design, plan, and each
  commit**; author ≠ reviewer; nothing advances without a PASS.
- **Routing** — `claude` orchestrates and executes steps; `gemini` reviews (xReview).
  The routing infrastructure supports a `codex` simple-coding failover path, but in
  v1.0.0 all step execution runs inline with `claude`. On quota exhaustion, Deputy skips
  the blocked item and retries on the next heartbeat tick — it does **not** reschedule
  the shared cron line.
- **Heartbeat** — a fixed recurring `*/N` cron entry (default 10 min, configurable via
  `heartbeat_mins` in `.deputy/config`) drives the always-on safety-net; install with
  `./install.sh cron`. Each tick: live task → skip; dead/orphaned → recover + resume;
  idle + work → pick highest-priority item.
- **Risky-op guardrail** (`hooks/guardrail.sh`) — a PreToolUse hook scoped to the
  spawned orchestrator that blocks out-of-worktree writes and a Bash denylist (push,
  crontab, destructive git, global installs, …).
- **State** lives under the gitignored `.deputy/` (locks, claims, config, protected
  globs, surfaced questions); the queue is `BACKLOG.md`.

---

## Repo layout

```
bin/deputy.sh            # the runner (queue engine + scheduling + adapters)
skills/deputy/SKILL.md   # the orchestrator skill
hooks/guardrail.sh       # PreToolUse risky-op guardrail (headless runs)
hooks/session-start.sh   # surfacing banner + morning digest
install.sh               # link (command+skill) / init (per-repo seed) / cron
templates/               # BACKLOG.md, config, protected seeds
tests/                   # dependency-free bash test harness (no bats)
docs/superpowers/        # specs/ (design) and plans/ (implementation plans)
BACKLOG.md               # Deputy's own task queue
VERSION                  # 1.0.0
```

Run the test suite with `bash tests/run.sh`.

---

## Design docs

The full design lives in `docs/superpowers/specs/` (the V1 design, the suspension &
resume subsystem, and the waypoint checkpoint spine) and `docs/superpowers/plans/` (the
bite-sized implementation plans). Future work is tracked as **deferred** items in
`BACKLOG.md`.
