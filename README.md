# Deputy

**An autonomous, cron-driven backlog runner for a code repository.**

You add work to a plain-text backlog; Deputy **triages** each item, **does the easy
ones headlessly**, **grills you on the hard ones**, executes in an isolated git
worktree, gates quality through **cross-LLM review (xReview, Gemini)**, and **routes
work across the `claude` / `gemini` / `codex` CLIs** with quota-aware failover. When
Claude's session limit is hit, it reschedules itself (cron) and resumes after reset.

Deputy is a thin, dependency-light **bash** tool — a descendant of the `research.sh`
queue pattern. Its distinguishing trait versus blind backlog-drainers is
**discernment**: it decides *whether* and *how hard* to do each item, escalates the
genuinely hard calls, and never blocks the queue while it waits on you.

> Status: **V1 shipped** (queue engine, scheduling/routing, orchestrator) and
> live-validated end-to-end. **V2 in progress** (a forward-recovery checkpoint
> "spine"; see the roadmap). The repo's own `BACKLOG.md` *is* the V2 roadmap —
> Deputy dogfoods itself.

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

**Dependencies:** `bash` 5+, `git`, `flock`, coreutils; `jq` (for the V2 checkpoint
spine); and the agent CLIs you want to route to (`claude` required; `gemini` for review;
`codex` optional failover). `install.sh` preflights them and warns about what's missing.

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
Items are blank-line separated; the parser reads everything after `## Items`.

---

## How it works

- **Thin runner (`bin/deputy.sh`)** — pure-bash queue plumbing: `flock`-serialized
  atomic mutations, claim-based serial ownership, stale recovery, the `run` loop, cron
  safety-net + rate-limit reschedule, and the CLI adapters (`detect`/`probe`/`route`).
- **Orchestrator skill (`skills/deputy/SKILL.md`)** — the "one brain." Spawned headless
  (`claude -p`) per claimed item, or invoked interactively (`/deputy`). It triages,
  does simple items, surfaces complex ones for your input, and drives execution.
- **Isolation** — every item runs on its own `deputy/<slug>` branch in a dedicated
  `.deputy/wt` git worktree; your main working tree is never touched.
- **xReview** — cross-LLM review (Gemini-primary) gates **design, plan, and each
  commit**; author ≠ reviewer; nothing advances without a PASS.
- **Routing** — `claude` orchestrates/plans + primary coder; `gemini` reviews; `codex`
  is the simple-coding failover when Claude's quota is limited. On quota exhaustion,
  Deputy skips the blocked item and retries on the next heartbeat tick — it does **not**
  reschedule the shared cron line.
- **Heartbeat** — a fixed recurring `*/N` cron entry (default 10 min, configurable via
  `heartbeat_mins` in `.deputy/config`) drives the always-on safety-net; install with
  `./install.sh cron`.
- **State** lives under the gitignored `.deputy/` (locks, claims, config, protected
  globs, surfaced questions); the queue is `BACKLOG.md`.

---

## Repo layout

```
bin/deputy.sh            # the runner (queue engine + scheduling + adapters)
skills/deputy/SKILL.md   # the orchestrator skill
hooks/session-start.sh   # surfacing banner + morning digest
install.sh               # link (command+skill) / init (per-repo seed)
templates/               # BACKLOG.md, config, protected seeds
tests/                   # dependency-free bash test harness (no bats)
docs/superpowers/        # specs/ (design) and plans/ (implementation plans)
BACKLOG.md               # Deputy's own queue = the V2 roadmap
```

Run the test suite with `bash tests/run.sh`.

---

## Roadmap (V2 — see `BACKLOG.md` + `docs/superpowers/specs/`)

- **Checkpoint spine** — a forward-recovery, resumable-step mechanism absorbed into
  Deputy (pure bash, ledger under `.deputy/waypoints/`, per-step git commits).
  **Shipped** — every item runs as checkpointed, resumable steps via the spine.
- **Suspension & resume** — `preempted` / `blocked` / `scheduled` / `awaiting` states,
  `surfaced` reasons (answer vs approve), dependency-aware scheduling.
- Cross-provider step execution; parallel worktrees; external notifications;
  full Reflect (re-triage/prune/learn); richer item attributes; intake from issues/CI.

---

## Design docs

The full design lives in `docs/superpowers/specs/` (the V1 design, the suspension &
resume subsystem, and the waypoint checkpoint spine) and `docs/superpowers/plans/` (the
bite-sized implementation plans). Deputy was itself built — and is being extended —
through a brainstorm → spec → plan → subagent-driven-implementation → xReview loop.
