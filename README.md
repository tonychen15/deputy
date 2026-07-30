# Deputy

**An autonomous, cron-driven backlog runner for a code repository.**

You add work to a plain-text backlog; Deputy **triages** each item, **does the easy
ones headlessly**, **grills you on the hard ones**, executes in an isolated git
worktree, gates quality through **cross-LLM review (xReview, Codex-default)**, and
**routes work across the `claude` / `codex` / `gemini` CLIs** with quota-aware failover. When
Claude's session limit is hit, the next heartbeat tick picks it up and resumes.

Deputy is a thin, dependency-light **bash** tool — a descendant of the `research.sh`
queue pattern. Its distinguishing trait versus blind backlog-drainers is
**discernment**: it decides *whether* and *how hard* to do each item, escalates the
genuinely hard calls, and never blocks the queue while it waits on you.

> **v1.5.1** — **observability, automation & one-command releases**: **`deputy progress <id>`**
> — a purely passive, read-only view of a running task's step %, ETA band, done-so-far digest,
> and run-log tail that never touches the worker (#108/#110); **`deputy test --changed`** — an
> automated changed-files → affected-tests selector that fails safe to the full suite (#109);
> **priority-aware `deputy run <id>`** + `run`/`add --<prio>` shorthands (#102/#104/#105); a
> **hardness-routed worker model** (sonnet/fable/opus by task complexity); **`deputy release`
> is now a one-command orchestrator** — worker-summarized CHANGELOG, VERSION bump, delimiter,
> README sync, commit + annotated tag (`--push` opt-in); plus quality-gate and worktree-cleanup
> fixes (#106/#103/#107).
> **v1.5.0** — the **"what needs me" UX**: three clear commands — **`list`** (per-task
> detail), **`watch`** (queue overview + beep-summon; absorbs `reflect`), and **`pickup <id>`**
> (act on one attention task) (#99); **deterministic, idempotent per-task branches** frozen at
> add-time (#98/#99); **`auto_merge` now actually works** — the unsandboxed runner performs the
> merge (#97/#98); a **`deputy config` setter** + `autonomy on|off` (#90); `list --porcelain`
> + `list <id>` (#93/#91); `cron set N` (#96); security-reviewed **guardrail hardening** (#95).
> **v1.3.0** — **backlog cleared to zero open items**: repo-wide *atomic* write-path
> hardening so a partial write can't corrupt `BACKLOG.md` (#47); the **agent-claim race
> protocol** — the interactive agent now holds the active-run claim so the cron heartbeat
> backs off uniformly across human/agent/cron, with a startup-crash circuit-breaker (#67);
> a working-tree leftover gate + `deputy doctor` (#65); `deputy set prio|state` (#69);
> per-command `--help` (#72); id-first `[#N][Pn]` line order (#62); tidier `.deputy/` trail
> subfolders (#70).
> **v1.2.0** — **autonomous runs are now safe to leave armed**: `deputy` re-execs from an
> immutable `~/.cache/deputy/` snapshot so a mid-run edit can't truncate it (#50); a headless
> worker **surfaces its branch for review instead of auto-merging** and `max_items` is bounded
> (#60); the heartbeat **announces every autonomous spawn** (#59) and **reaps** a worker's
> leaked subtree (#58); plus stale-orphan warnings (#57) and author-aware xReview (#54).
> **v1.1.1** — adds a `deputy version` subcommand (`--version`/`-V`). Builds on
> **v1.1.0**, where the xReview gate became **Codex-default and author-aware**: the
> reviewer is chosen by `deputy route review` (author-aware: claude-first when codex/gemini
> authored, codex-first when claude authored), so a dead or rate-limited reviewer no longer deadlocks the spine, plus a
> per-project `self_review_fallback` no-peer degradation policy and an append-only
> `.deputy/reviews/<slug>.md` audit trail (`deputy review-log`). The repo's own
> `BACKLOG.md` is the project's task queue — Deputy dogfoods itself.

---

## Highlights

- **Discernment, not blind draining.** Deputy *triages* every item — it does the
  well-specified ones headlessly and **surfaces the genuinely hard calls** for your
  input, instead of charging at under-specified work.
- **⏸️ Priority preemption.** Add an urgent item while a lower-priority one is running and
  Deputy **checkpoint-pauses** the running item — its work preserved on its own branch —
  runs the urgent one, then **resumes** the paused item from exactly where it left off.
- **🤝 It coexists with you.** A **human-session back-off** detects your live interactive
  Claude session in the repo and steps aside rather than racing your edits — re-checked on
  *every* drain-loop iteration, so an item you add mid-run is never grabbed out from under
  you. A **default-branch guard** keeps the runner off your feature branches.
- **🔒 Safe by construction.** Every item runs on its own `deputy/<slug>` branch in an
  isolated git worktree; **Deputy never auto-pushes** (publishing is always your call);
  cross-LLM review (xReview) gates design, plan, and *every commit*; and a risky-op
  guardrail constrains the headless agent. When [`bwrap`](https://github.com/containers/bubblewrap)
  is available, the headless worker also runs in an **OS-enforced read-only sandbox**: the
  repo's *code* is physically unwritable to it — only `.deputy/` (its worktree + state),
  `.git`, and `BACKLOG.md` are writable — so a stray write can't escape into the main tree.
  Disable with `sandbox=0` (falls back to pinning the worker's cwd to the worktree).
- **🔁 Resumable.** A checkpoint spine commits each step and **forward-recovers** after any
  interruption — it continues from the first uncommitted step, never re-doing finished work.

---

## Install

```bash
# 1) Clone the deputy repo
git clone https://github.com/tonychen15/deputy
cd deputy

# 2) Initialize each repo you want Deputy to manage (idempotent; never clobbers your backlog).
#    `init` first ensures `deputy` + `inst_deputy.sh` + the skill are on your PATH, so the
#    very first run can go straight here — no separate `link` step needed.
./inst_deputy.sh init /path/to/your/repo   # seeds BACKLOG.md, .deputy/config, .deputy/protected, .gitignore

# 3) (Optional) Enable the always-on cron heartbeat in that repo
inst_deputy.sh cron              # writes a */10 cron entry (interval configurable via heartbeat_mins)
```
The **only** invocation that needs a path prefix is the very first one on a fresh clone
(`./inst_deputy.sh …`), because the command isn't on your PATH until it installs itself.
After that, `inst_deputy.sh init/cron` work from **any directory** with no `./` and no `cd`.

If you just want the command on PATH without seeding a repo, run `./inst_deputy.sh link`
(or bare `./inst_deputy.sh`, which defaults to `link`). `inst_deputy.sh` uses **symlinks**,
so the command + skill always run the latest code — no per-repo copying; it resolves its own
PATH symlink back to the real checkout. Re-run `inst_deputy.sh init <dir>` in a repo only to
pick up newly-seeded config files.

**Isolated installs:** set `DEPUTY_PREFIX` to override the bin directory (default `~/.local/bin`)
and `DEPUTY_SKILLS_DIR` to override the skills directory (default `~/.claude/skills`).

**Dependencies:** `bash` 5+, `git`, `flock`, coreutils; `jq` (for the checkpoint
spine); and the agent CLIs (`claude` required; `codex` and/or `gemini` for xReview).
`inst_deputy.sh` preflights them and warns about what's missing.

---

## Upgrading

The `deputy` CLI, the `/deputy` orchestrator skill, and the guardrail hook are **global** —
one shared install (symlinks into the deputy repo: `~/.local/bin/deputy → <repo>/bin/deputy.sh`,
`~/.claude/skills/deputy → <repo>/skills/deputy`, and the hook referenced at `<repo>/hooks/`)
that *every* project using Deputy shares. There is **no copy of the deputy code inside a
customer project** — so one upgrade in the deputy repo updates Deputy for **all** projects at
once:

```bash
cd <deputy-repo>
git pull          # updates Deputy for ALL projects: command + skill via their symlinks, hook via its absolute <repo>/hooks reference
```

**`git pull` is safe even while a `deputy run` is executing.** On startup `deputy` re-execs
from an immutable, content-addressed snapshot under `~/.cache/deputy/` (keyed by the source
hash, rebuilt only when `bin/deputy.sh` changes), so editing or merging the working-tree
file mid-run can't truncate a running invocation. The change simply takes effect on the
next invocation. (Set `XDG_CACHE_HOME` to relocate the snapshot cache.)

No per-repo skill re-install is needed in any project that uses Deputy.

**Re-link only if** the symlinks are missing or broken, or if `inst_deputy.sh`'s link layout
changed:

```bash
./inst_deputy.sh link   # idempotent — safe to re-run
```

**Customer projects need no re-init on upgrade — they self-heal.** The only per-project
files *copied* from the templates are `.deputy/config`, `.deputy/protected`, and your
`BACKLOG.md` (everything else under `.deputy/` is generated runtime state — locks, the
worktree, logs, and trails). The `.deputy/config`/`.deputy/protected` pair auto-reconciles on the next `deputy` run (your `BACKLOG.md` is never touched): a missing `.deputy/config` or
`.deputy/protected` is re-seeded from the templates; new default **protected** globs shipped
in a release are layered on automatically (the per-project file is read *over* the release
defaults, so you never lose a new safety glob); and new **config keys** fall back to their
built-in defaults. So a release upgrade needs **zero** per-project action. Re-running `init`
is **optional** — only to *materialize* new config keys into `.deputy/config` for editing;
it never overwrites your `BACKLOG.md` or existing config:

```bash
./inst_deputy.sh init /path/to/your/repo   # optional — surfaces new config keys for editing
```

**Cron schedule:** if the heartbeat interval or cron format changed, refresh it:

```bash
./inst_deputy.sh cron           # or: deputy cron --ensure
```

**Check the installed version:** `cat <deputy-repo>/VERSION` (currently `1.6.0`).

---

## Usage

```bash
deputy add "fix the login redirect loop" -ui   # add an urgent+important item (-ui=P0, -u=P1, -i=P2)
deputy add "tidy the README"                    # bare items default to P3 at numbering (P4 is the lowest lane); --p0/--p1/--p2/--p3/--p4 also accepted
deputy accept <id>     # the item's acceptance record — the reported symptom, frozen at add time
deputy verify <id> --red|--green|--bite|--smoke # prove the symptom moved (see "Proving a fix" below)
deputy list [--<state>] # items in BACKLOG.md format: @[#N][Pn] desc (running), [#N][Pn] desc (waiting), etc.
                       # --<state> (e.g. --waiting, --running, --deferred) filters to that state
deputy status          # counts by state
deputy run [--once]    # work the backlog (triage → do / surface), until empty or session limit
                       # interactive (TTY): streams the worker's output live; cron/no-TTY: buffered
deputy run --headless  # force buffered output even interactively (or set headed=0 in .deputy/config)
deputy run <id>        # targeted run: bypass priority order and run a specific item by id
deputy watch [--once] [--apply]
                       # the "what needs me" command (replaces the former 'deputy reflect'):
                       # prints the queue OVERVIEW (learnings, untagged, reprioritization,
                       # duplicates, status) then monitors — live-tails a running worker and,
                       # on quiescence (runnable→0 with a surfaced/failed/deferred item),
                       # beeps 3× + prints the attention digest (each item's action →
                       # 'deputy pickup <id>'); --once: overview + one poll then exit;
                       # --apply: overview + write .deputy/learnings.md; Ctrl-C exits
                       # (aliases: deputy tail, deputy review)
deputy pickup <id>     # bring up ONE attention task and act: ready-to-merge → merge (→ done);
                       # proposed → approve; needs-input → /deputy; failed/cancelled/deferred/
                       # paused → requeue. Local/safe only (never pushes)
deputy release [version] [--push]  # cut a release: bump VERSION, prepend a worker-summarized
                       # CHANGELOG entry (--no-llm for raw bullets), insert the Done delimiter,
                       # sync README, commit + annotated tag. Local unless --push. --marker-only
                       # inserts just the delimiter (version defaults to ./VERSION).
deputy clean [<id>] [--dry-run] [--state <state>]
                       # <id>: remove one item by its numeric id (bare, e.g. 7)
                       # --state: remove all items of <state> (default: waiting = untouched)
                       # cleanable: waiting, done, failed, cancelled, duplicate, deferred
```

**Priority flags** (Eisenhower): `-ui` urgent+important (`P0`), `-u` urgent (`P1`),
`-i` important (`P2`), none = defaults to P3 at numbering (P4 is the lowest lane).
`--p0/--p1/--p2/--p3/--p4` also accepted. Use `--` before a description that starts with `-`.

### Autonomy controls

**A spawned headless worker reads its autonomy ONLY from `.deputy/config`.** The interactive
Claude terminal's "auto-mode" is Claude Code *session* state — ephemeral and **invisible** to
workers — so it does **not** propagate to a cron/headless run. To make headless runs
autonomous, set the config explicitly (with the `deputy config` setter — no more hand-editing):

```bash
deputy config auto_merge 1             # let a completed worker's branch be merged locally
                                       #   (the unsandboxed runner merges it); 0 = surface for review
deputy config self_review_fallback 1   # if no peer xReviewer is up, self-review + proceed;
                                       #   0 = surface the item instead
deputy config autonomy on              # shorthand: sets BOTH of the above at once (off = both 0)
```

These are two **independent** risk knobs (merge-safety vs review-quality); `autonomy on|off`
is just a convenience that flips both. **Push is never automatic** regardless — `auto_merge`
governs only the *local* merge; publishing is always your explicit call. *(The former key name
`auto_mode` is still read as an alias for `self_review_fallback`.)*

**Merging while you have work in progress.** Deputy no longer needs a pristine tree to merge a
ready branch. It applies git's own rule: the merge proceeds when your index is clean **and** the
paths the merge writes are disjoint from your dirty paths — git preserves your uncommitted work
and keeps it out of the merge commit. Overlapping or *staged* changes still surface for a manual
merge (git's `ort` strategy refuses any merge with a dirty index, even a non-overlapping one).

```bash
deputy config merge_dirty_disjoint 0   # restore the strict "tree must be pristine" rule
```

**A merge you cannot make never becomes your problem.** When a merge genuinely can't proceed —
you have staged changes, or uncommitted edits to the very files the merge writes — the item is
**not** dumped in your queue. It parks in `pending-merge` (`&`), a state that is neither runnable
nor an attention item, and the runner retries it at the top of every tick, including ticks that
run other work. A dirty tree never stalls the queue. You only ever hear about it when deputy
genuinely can't finish the job:

| Outcome | What deputy does |
|---|---|
| Merge succeeds | item → `done`, silently |
| Blocked by your working tree | parks in `pending-merge`, retries every tick |
| Branch conflicts with the default branch | surfaces **immediately** — detected up front with `git merge-tree`, which needs no clean tree, so deputy never wastes retries on a merge it can't resolve |
| Still blocked after `merge_retry_strikes` tries | surfaces, with the blocker recorded |

```bash
deputy config merge_retry_strikes 10   # retries before a stuck merge is surfaced (default 10)
deputy config merge_drain_limit 10     # most parked merges landed per tick (default 10)
deputy pickup <id>                     # land a parked merge now instead of waiting for a tick
```

---

## Proving a fix (the acceptance record)

Deputy's `done` used to mean *steps committed, tests green, branch merged*. None of that
proves the **reported symptom** is gone — the agent writes the fix, then writes the test
about the fix, and the reviewer reads the diff. Every artifact is downstream of the
implementation, so an item can go green and merged while the bug is untouched.

The acceptance record fixes that by capturing what *you* observed, before any work starts:

```bash
deputy add "FCF column is blank on the fundamentals tab" --p1 \
  --observe 'psql -f q/fcf.sql AAPL' \
  --actual  'FCF column empty' \
  --expect  'a non-null number for any ticker with quarterly revenue + NI' \
  --where   'prod nightly pipeline, live catalog DB'
```

When a description reads like a bug and you're at a terminal, `deputy add` asks for those
four instead of requiring the flags (skip any with Enter; `--no-accept`, `DEPUTY_NO_GRILL=1`
or `accept_grill=0` turn it off). Backfill an existing item with `deputy accept <id>
--observe ...`. The record is keyed by the frozen slug, so it survives every resume, and the
orchestrator is forbidden from rewriting it.

`observe` is the whole mechanism — it becomes a check deputy runs at three points:

| Gate | When | Must | Catches |
|------|------|------|---------|
| `verify --red` | before the fix | **fail** | a check that doesn't capture the symptom, or a stale item — "fixing" it would ship a green false positive |
| `verify --green` | after the fix | **pass** | the symptom is still there |
| `verify --bite` | after the fix | **fail** with the item's own commits reverted in a scratch worktree | a test fitted to the diff: if the symptom stays fixed without the fix, nothing was proven |
| `verify --smoke` | after the fix | **pass** | green unit tests over a live-data failure (set `deputy config smoke_cmd`) |

Exit codes are `0` pass (or a deliberately skipped gate — `--red` skips itself once the item
has committed work, so a resumed run is never falsely flagged), `1` the gate genuinely
failed, `2` cannot run, `3` **inconclusive**: the check timed out or couldn't run, so it
produced no evidence. `3` is deliberately not `1` — "the fix is wrong" and "we learned
nothing" call for different responses, and neither is a pass.

Verdicts are stamped with a fingerprint of the item's commits, so a `green` taken before a
later commit no longer counts — otherwise the gate would be defeated by verifying early and
committing after.

`deputy done` refuses to close an item whose `green` and `bite` verdicts aren't both
recorded as passing on the current code (`--no-verify` waives it, and records the waiver in
the ledger). The
runner's auto-merge does the same: an unverified branch still merges — it was reviewed and
tested — but the item **surfaces** instead of closing, with a note on what's unproven.

`actual` earns its place separately: it tells the agent what *failure* looks like, so a
**different** failure isn't scored as success. An item whose blank column becomes a thrown
exception is not fixed, and without `actual` that reads as "no longer blank".

`actual` is prose, though, and prose can't be checked mechanically — `--red`/`--bite` score
*any* nonzero exit as "the symptom is present", so that blank-becomes-exception case would
still pass them. Where the difference matters, add the optional fifth field:

```bash
deputy accept 194 --match 'FCF.*(NULL|empty)'
```

`match` is a regex the failing output must match for red/bite to count as the reported
symptom. Left unset (the default), the gates work on exit codes alone exactly as described
above — it's there for when you want the check pinned to *this* bug rather than any failure.

Items with no acceptance record behave exactly as before — the gate is opt-in via the
record itself.

---

## The backlog file (`BACKLOG.md`)

Human-editable. A fixed markdown legend at the top, then a `## Items` section that the
tool keeps grouped into `### ` sub-sections (with live counts), ordered by **who resolves
the state**:

```markdown
## Items

### Running (1)
@[#3][P1] Wire up the importer

### Surfaced (0)

### Waiting (2)
[#7][P0] Fix the login redirect loop
[#9][P2] Refactor the data layer

### Deferred (0)

### Paused (0)

### Pending merge (0)

### Failed / Cancelled / Duplicate (0)

### Done (2)
+[#8][P1] Add caching
<!-- release v1.2.0 — 2026-06-21 -->
+[#5][P0] Initial setup
```

All eight sections are **always present** (even when empty). The tool regroups on every
write, so you can add a bare line anywhere under `## Items` and it lands in the right
section.

The grouping is deliberate. **Running / Surfaced / Waiting / Deferred** are the states you
read and act on, kept contiguous so your queue is one block. **Paused** and **Pending
merge** are resolved by deputy itself — paused auto-resumes on the next tick, pending-merge
retries every tick and escalates to `surfaced` only if it truly can't land — so neither is
an attention state and neither is asking for you; they sit below your lane but still above
the terminal sections, because the work is in flight. Then the terminals: **Failed /
Cancelled / Duplicate** holds all three non-done terminals, and **Done** is last,
newest-completed first. **Surfaced** also holds triaging items.

Section order is cosmetic — items are parsed by their line prefix, never by which section
they sit under — so reordering or hand-moving a line never changes an item's state.

`<!-- release vX — date -->` delimiters in **Done** mark release boundaries; completed
tasks above the most-recent delimiter are the unreleased set for the next version.

**Status prefix** (first char): *(none)* waiting · `~` triaging · `@` running · `?`
surfaced · `+` done · `!` failed · `%` cancelled · `=` duplicate · `^` paused · `;` deferred.
(Legacy `#` done / `>` deferred are still read and auto-migrated to `+`/`;` on the next write.)
**`^` paused** — mid-execution checkpoint; auto-resumes on next heartbeat.
**`;` deferred** — parked for future consideration; inert, never auto-scheduled; revive with
`deputy set "<line>" waiting`.
**Priority tag:** `[P0] > [P1] > [P2] > [P3] > [P4]`; untagged items default to `[P3]`
at numbering time; FIFO within a lane. Use `--p0`/`--p1`/`--p2`/`--p3`/`--p4` flags
with `deputy add` to assign a lane explicitly.
**Item IDs** `[#N]` are assigned automatically on first reference (e.g., `list`, `run`, `watch`); use
`deputy run <id>` to target a specific item directly.
The parser reads everything after `## Items`, skipping `###` section headers and release
delimiter comments.

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
- **xReview** — cross-LLM review (**Codex-default, author-aware**) gates **design, plan,
  and each commit**; author ≠ reviewer; nothing advances without an APPROVED verdict.
  Every iteration is logged to a deputy-owned `.deputy/reviews/<slug>.md` trail (deputy's
  equivalent of xReview's `.review/REVIEW.md`).
- **Routing** — `claude` orchestrates and executes steps. The reviewer is chosen by
  `deputy route review` (author-aware, author-excluded): claude authored → **codex** then
  gemini; codex authored → **claude** then gemini; gemini authored → **claude** then codex
  — so a dead or rate-limited reviewer no longer deadlocks the gate. If only the author is
  up, the gate degrades per the project's `self_review_fallback` config (`self_review_fallback=1` → self-review
  with a warning; default → surface the item). The routing infrastructure also supports a
  `codex` simple-coding failover path, but step execution still runs inline with `claude`.
  On full quota exhaustion, Deputy skips the blocked item and retries on the next
  heartbeat tick — it does **not** reschedule the shared cron line.
- **Heartbeat** — a fixed recurring `*/N` cron entry (default 10 min, configurable via
  `heartbeat_mins` in `.deputy/config`) drives the always-on safety-net; install with
  `./inst_deputy.sh cron`. Each tick: live task → skip; dead/orphaned → recover + resume;
  idle + work → pick highest-priority item.
- **Priority preemption** — when a higher-priority item arrives while a lower-priority one
  is running, the orchestrator **checkpoint-pauses** the running item (`^ paused`, its work
  committed on its `deputy/<slug>` branch), runs the higher-priority one, then **resumes**
  the paused item from its first uncommitted step — no work lost, no queue blocked.
- **Worker proposals need your approval** — when an autonomous worker calls `deputy add`
  (to record follow-up work it discovered), the new task is filed as a **proposal**: it
  lands `surfaced` with a `.deputy/proposed-<id>` marker, notifies you, and is **never
  auto-run**. Approve it with `deputy set "<line>" waiting` or reject with
  `deputy set "<line>" cancelled`. Your own `deputy add` is unaffected (it queues and may
  auto-run). Proposals don't count toward the "one surfaced at a time" guard, so a pending
  proposal never stalls the queue.
- **Human-session back-off** — `deputy run` detects live interactive Claude sessions in
  the repo (`~/.claude/sessions/`) and steps aside while they are busy or recently idle.
  An `idle` session that's been idle longer than `human_idle_grace_mins` (default 5) lets
  cron proceed; a `waiting` session (idle-at-prompt, but an *undocumented* status) must
  hold `waiting` for `waiting_backoff_strikes` consecutive heartbeat ticks (default 3)
  before cron proceeds — a cautious persistence check, since a transient mid-tool
  `waiting` can't survive N ticks. It **re-checks on every drain-loop iteration**, so an
  item you add mid-run is never claimed out from under you. A stale (crashed-session) file
  instead **surfaces** the top item for you to check. Configurable via `human_backoff=1`
  in `.deputy/config` (default ON).
- **Default-branch guard** — `deputy run` refuses to start when the repo is not on its
  default branch, preventing accidental execution on feature branches.
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
inst_deputy.sh               # link (command+skill) / init (per-repo seed) / cron
templates/               # BACKLOG.md, config, protected seeds
tests/                   # dependency-free bash test harness (no bats)
docs/superpowers/        # specs/ (design) and plans/ (implementation plans)
BACKLOG.md               # Deputy's own task queue
VERSION                  # 1.6.0
```

Run the test suite with `bash tests/run.sh`.

---

## Design docs

The full design lives in `docs/superpowers/specs/` (the V1 design, the suspension &
resume subsystem, and the waypoint checkpoint spine) and `docs/superpowers/plans/` (the
bite-sized implementation plans). Future work is tracked as **deferred** items in
`BACKLOG.md`.
