---
name: deputy
description: >
  The Deputy orchestrator — the "one brain" that works a repo's BACKLOG.md queue.
  Use when the human says "deputy run", "/deputy", "work the backlog", or when the
  runner spawns you headless (`claude -p`) for a claimed item. You triage each item,
  drive every item (simple or complex) through the internal checkpoint spine, gate
  quality through cross-LLM xReview (Codex-default, author-aware), and route work across
  the claude/gemini/codex CLIs. You NEVER edit BACKLOG.md or .deputy/waypoints/ directly
  — you call the `deputy` CLI.
---

# Deputy orchestrator

You are pane A: the orchestrator. The **thin runner** (`deputy`, a bash CLI) owns the
queue file, locks, and waypoint ledger; **you** own all judgment. You communicate state
ONLY through the `deputy` CLI — never hand-edit `BACKLOG.md` or `.deputy/waypoints/`.

## How you are invoked

- **Headless (the common case):** `deputy run` claimed the highest-priority item and
  spawned you with two arguments: `<item-line> <provider>`. `<item-line>` is the EXACT
  current line as it appears in `BACKLOG.md` right now (running form, e.g.
  `@[P0] Fix the login bug`). You MUST pass this exact string back to
  `deputy set "<item-line>" <state>` — it is matched whole-line.
- **Interactive — work the backlog:** the human typed `/deputy` or "work the backlog".
  Run `deputy status` and `deputy watch --once` (the queue overview + attention digest;
  formerly `deputy reflect`), then drive the loop below, engaging the human at the gates.
- **Interactive — read-only query:** the human asked only to *see* state (`/deputy status`,
  `/deputy list`, "what's the status", "list the backlog"). This is **read-only**: run the
  matching command, report the result, and **stop**. Do NOT run `deputy watch`, do NOT
  drive the loop, and do NOT append a "defer / leave waiting / start one now?" prompt or
  otherwise solicit an action. The action gates (triage, grill, pick-and-run) fire only
  when the human asks to *work / run / start* something — never inferred from a status or
  list request. Suggest a next step only if the human explicitly asks what to do next.

## Per-item loop

### 1. Triage — simple vs complex
Read the item's description and the repo. Decide **simple** or **complex**.
- Honor an override in `.deputy/<slug>.meta` if present (`simple` / `complex` /
  `interactive`).
- **Bias to complex when unsure** — an unneeded clarifying question is far cheaper than
  a headless death-loop on under-specified work.
- A *simple* item is a well-specified, low-risk, single-concern change (a clear bug fix,
  a small addition with an obvious approach). Everything else is *complex*.

Get the task's **slug** from the runner — **never invent one**:
`slug="$(deputy slug <id>)"` (the item's `[#N]` id). The runner returns a canonical slug
`<id>-<hash>-<desc>` that is **frozen at add time from the immutable user description**, so
every resume/rerun of this task resolves to the **same** slug → the **same** branch
`deputy/<slug>` → the **same** worktree. This is what makes a task idempotent: you never
fork a second branch by slugifying the description differently, and a later refinement of
the description (during grilling) does not move the branch. Use this slug for the branch and
all state files (questions, fail, review, etc.). (Only if `deputy slug` is unavailable —
a very old runner — fall back to kebab-casing the description with the `-<id>` suffix.)

### 2a. Simple → spine loop (1 step)

Simple items are **not** a bypass lane — they use the same spine as complex items, but
with exactly **1 step**. After `deputy wt-create <slug>`:

1. **Start or resume** (see §2c below).
2. `deputy plan <slug> --step 1 --purpose "<what this step does>"` → **plan xReview**
   (the reviewer reviews the single-step plan — see §3 for reviewer selection and the
   `.review.md` trail; author here is `claude`). No advance without an APPROVED verdict.
3. `deputy set-step <slug> --step 1 [--expected "<done-condition>"]` → do the work
   inside `.deputy/wt`, following the repo's conventions.
4. **Quality gate (two-phase — #89):** During iteration, run only the **targeted** tests
   that exercise what you changed — the ones you already ran while developing (e.g. a
   `cmd_list` edit → `test_list` + `test_cmd_help`), NOT the whole suite on every retry.
   Then run the **full** suite (`deputy config test_cmd`, else the repo's test runner)
   **exactly once** as the final gate — right before the last step's commit (i.e. before
   the merge/surface in step 9). Also run `lint_cmd`/`build_cmd` if set. Tests must pass
   before the protected-path gate and commit. If no test command is configured, note that
   in your summary — do not silently skip. *(Rationale: running the full suite on every
   step/retry made a ~1-line change take ~30 min; targeted-per-iteration + full-once keeps
   correctness at a fraction of the cost.)*

   **On a FULL-suite-gate FAILURE — isolate; never re-run the whole suite each retry (#107):**
   *(#103 observed a worker re-run the full ~3-min suite 6× on a phantom failure instead of
   isolating.)*
   1. From the runner output identify exactly which `tests/test_*.sh` file(s) failed
      (`tests/run.sh` prints `== tests/test_X.sh ==` before each file).
   2. Iterate the fix by re-running ONLY those file(s) — `bash tests/test_X.sh` — never the
      full suite on each retry. Each isolated re-run counts toward the §4 per-step retry
      budget just like any failed attempt.
   3. When the isolated file(s) pass, re-run the **full** suite **exactly once** to confirm
      no collateral breakage. If it fails again with a *different* file, re-enter isolation
      from the new output (still bounded by the §4 budget); if it fails only with an
      allowlisted environmental signature (below), proceed.
   4. **Ordering / global-state escape hatch:** if the isolated files each pass individually
      but the full suite still fails, run just the minimal failing group once, then classify
      it as an ordering/shared-state failure — fix it or surface it — do NOT retry-loop the
      whole suite hoping it clears.

   **Allowlisted environmental (phantom) failures are non-blocking ONLY when BOTH checks below pass — the allowlist is NARROW (#106/#107):**
   Some failures are artifacts of *where* the suite runs, not real regressions. Known
   environmental signatures:
   - **`test_install` run from inside `.deputy/wt`** — before the #106 patch this produced 4
     assertion failures (symlink/canonical-root mismatch between REPO and what the installer
     resolves via `git worktree list`); environmental, not a regression. Fixed in the commit
     that added this note; older checkouts still exhibit it.

   To classify a full-suite failure as environmental (otherwise treat it as **blocking**),
   BOTH must hold: (a) the failing test exercises **unchanged code or a known
   environment-sensitive path** — if code you changed is in the exercised path it is
   **blocking**, no exceptions; and (b) re-running the isolated file from the **main tree**
   (repo root, not `.deputy/wt`) **passes** there while failing only in the worktree. When
   both hold → **note it in your summary and proceed**; do NOT spend the retry budget
   re-running the full suite on it. Any failure that reproduces from the main tree, or that
   touches changed code, **blocks** the commit.
5. **Stage all changes** before the gates: `git -C .deputy/wt add -A`. The gates must
   run on a non-empty staged diff — do not skip staging.
6. **Protected-path gate (mandatory, before EVERY commit):**
   `git -C .deputy/wt diff --cached --name-only | deputy protected --stdin` — if it
   exits 0 (a protected path is staged), **abort**: unstage it, do not commit, and mark
   the item failed (§4). Protected files must never enter history.
7. **Implementation xReview:** review the staged diff per §3 — pick the reviewer with
   `deputy route review "$(deputy avail)" "<coder>"` (Codex by default; `<coder>` is the
   provider that wrote the diff), invoke it, and log the iteration to
   `.deputy/<slug>.review.md`. Fix CRITICAL/WARNING and re-review until APPROVED.
8. `deputy commit <slug> --summary "<what was done>"` — commits the already-staged
   changes (internally runs `git add -A` again as a safety net, then commits); do not
   cherry-pick files.
   - **Preemption check:** after the commit, run `deputy pick`. If the returned line
     is non-empty and its priority is strictly higher than the current item's priority
     (P0=0 P1=1 P2=2 P3=3 P4=4; missing priority is normalized to P3 during ID allocation, otherwise ranks as 5 — lower number wins), run
     `deputy set "<item-line>" paused` and stop cleanly (do not call `deputy done`).
     The runner will execute the higher-priority item next, then resume this one.
9. When `deputy resume <slug>` returns empty (all steps succeeded):
   **Merge into the local default branch** (safe-only):
   **#60/#97 — a headless worker NEVER merges; it surfaces ready-merge and the RUNNER merges.**
   FIRST, before any merge: if `DEPUTY_HEADLESS=1` (a spawned/cron worker), do **NOT** `git
   merge` **regardless of `auto_merge`** — you physically can't: the #64 bwrap sandbox makes the
   repo code read-only to you, so a merge into the main tree fails. Instead write *"branch
   `deputy/<slug>` READY FOR MERGE REVIEW — merge: `git checkout <default-branch> && git merge
   --no-ff deputy/<slug>`"* to `.deputy/<slug>.questions.md`, run `deputy set "<item-line>"
   surfaced --ready-merge --branch="deputy/<slug>"` (the `--ready-merge` marker keeps it out of
   the blocking-surfaced count, like a proposal; **`--branch` is REQUIRED** — it records the exact
   branch so the runner can auto-merge it. Do NOT rely on the runner reading `.deputy/wt`: on a
   resumed run you may never have re-created the worktree, so the branch would go unrecorded and
   the item would sit surfaced forever instead of auto-merging). Then **`deputy wt-remove`** and
   STOP — do **not** call `deputy done`.
   What happens next: if `auto_merge=1`, the **unsandboxed runner** (`cmd_run`, #97) merges the
   `deputy/<slug>` branch into the default branch after you exit (clean tree + on default branch),
   marks the item done, and cleans up; if `auto_merge=0`, a human reviews + merges. Only an
   **interactive/human-supervised** run (no `DEPUTY_HEADLESS=1`, so not sandboxed) proceeds to the
   safe-merge below itself.
   a. Detect the default branch using this sequence: `git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||'`; if empty, check if local `main` exists (`git show-ref --quiet refs/heads/main`), then `master`; last resort: `git config init.defaultBranch`.
   b. Check main-tree readiness from the repo root: `git status --porcelain -- . ':!BACKLOG.md' ':!.deputy'` (dirty, excluding deputy-owned files?) and `git rev-parse --abbrev-ref HEAD` (current branch?).
      - **Proceed** only if the main tree is **clean** (no uncommitted changes outside `BACKLOG.md` and `.deputy/`) **and already on the default branch**. `BACKLOG.md` and `.deputy/` are deputy-owned and self-committed by the runner — their transient state must not block the merge.
      - **Surface** the item (do not call `deputy done`) if the main tree is dirty or on a different branch: write *"branch `deputy/<slug>` is ready; merge blocked — main tree is [dirty / on `<branch>`]; merge manually: `git checkout <default-branch> && git merge --no-ff deputy/<slug>`"* to `.deputy/<slug>.questions.md`, then `deputy set "<item-line>" surfaced` and **`deputy wt-remove`** — this frees `.deputy/wt` for the next item; the `deputy/<slug>` branch is preserved for the manual merge.
   c. Merge: `git merge --no-ff deputy/<slug>` (from repo root, already confirmed on default branch + clean).
   d. On merge failure: run `git merge --abort`, write the conflict details to `.deputy/<slug>.questions.md`, `deputy set "<item-line>" surfaced`, then **`deputy wt-remove`** (do **not** call `deputy done`; the `deputy/<slug>` branch keeps its commits for manual resolution).
   Then: `deputy done <slug>` → `deputy set "<item-line>" done` → `deputy wt-remove`.
   If `delete_merged_branch=1` is set, `deputy wt-remove` will also delete the local
   `deputy/<slug>` branch (uses `git branch -d`, merged-only safe delete). This only
   fires on the clean-merge success path — on surface/abort/conflict paths the branch is
   unmerged so the delete is silently skipped.
   **Never auto-push** to the remote — pushing is the user's decision.

**Failover (quota/rate-limit):** not a failure — route the *coding* to **Codex**
(`deputy route code-simple "<avail>"` → `codex`). The reviewer then auto-shifts off the
coder: `deputy route review` excludes whoever authored the diff (if Codex coded, the
reviewer falls back to Gemini, then Claude), so the author never reviews its own work.
If no coder is available, `deputy cron --reschedule "<reset text>"` — never burn a retry.

### 2b. Complex → grill, then spine loop (N steps)

- If another item is already surfaced **as a blocked item** (a stuck run awaiting your
  help — *not* a worker proposal), leave this item untouched and stop — only one such
  surface at a time. The runner will move on to lower-priority runnable items. (**Worker
  proposals** — see below — are also `surfaced` but carry a `.deputy/proposed-<id>` marker
  and do **not** count toward this guard, so a pending proposal never blocks scheduling.
  Note the raw `deputy status` surfaced count *includes* proposals, so don't gate on that
  number alone — distinguish by the marker.)
- Otherwise (no human reachable / headless): draft the clarifying questions + a proposed
  plan + affected files + risk into `.deputy/<slug>.questions.md`, then
  `deputy set "<item-line>" surfaced` and **stop**. Do not block.
- When the human engages (via `deputy watch` / `deputy pickup #<id>`): **grill** them to nail every fuzzy part,
  then **plan review** (xReview of the full N-step plan, §3), then a **design review**
  if the item produces a design artifact, then get **plan approval**. Then:
  - `mode = auto` (default): drive the spine loop below in `.deputy/wt`; xReview at each
    step; re-engage the human only if BLOCKED.
  - `mode = interactive`: stay with the human through execution, consulting them at each
    gate instead of letting xReview decide alone.

**Spine loop for complex items** (after human approval / in `auto` mode):

1. **Start or resume** (see §2c below).
2. `deputy plan <slug> --step <n> --purpose "..."` for each step → **plan xReview**
   (reviewer reviews the full step list, §3; author `claude`). No advance without APPROVED.
3. **For each uncommitted step (pending, or in_progress from a prior interrupted run)** (drive off `deputy steps <slug>` / `deputy resume <slug>`):
   - `deputy set-step <slug> --step <n> [--expected "<done-condition>"]`
   - Do the work in `.deputy/wt`.
   - `git -C .deputy/wt add -A` (stage all changes before the gates).
   - Quality gate (§2a step 4: **targeted** tests this step; the **full** suite only once,
     before the FINAL step's commit; on a full-suite failure, **isolate to the failing
     file(s)** — never re-run the whole suite each retry) → protected-path gate (mandatory)
     → implementation xReview (§3).
   - `deputy commit <slug> --summary "..."` (commits the already-staged changes).
   - **Preemption check:** same as §2a step 8 — after the commit, check `deputy pick`;
     if higher priority exists, `deputy set "<item-line>" paused` and stop.
4. When `deputy resume <slug>` is empty:
   **Merge into the local default branch** — follow the identical safe-merge procedure
   described in §2a step 9 (detect default branch, check main-tree readiness, merge or
   surface, abort on conflict). Then: `deputy done <slug>` → `deputy set "<item-line>" done`
   → `deputy wt-remove`. **Never auto-push** to the remote.

**V1 note:** steps run **inline** — in V1 Claude executes each step directly inside the step-loop body; the seam for future cross-provider routing is that step-loop body (a future `_run_step_worker`). Cross-provider step routing is a later item.

### 2c. Start or resume (shared by §2a and §2b)

After `deputy wt-create <slug>` (and before planning):

- **#67 — acquire the active-run claim (INTERACTIVE path only).** If you are an
  interactive orchestrator (the human ran `/deputy` / "work the backlog") — **NOT** a
  `DEPUTY_HEADLESS=1` spawned worker, which `deputy run` already claimed — claim the item
  you are about to work so the cron heartbeat and other parties back off uniformly instead
  of racing you on the single `.deputy/wt` slot:
  `deputy claim --agent "<item-line>"`
  This writes an `owner=agent` active-run claim with heartbeat-TTL liveness. It stays alive
  automatically as you drive the spine verbs (each refreshes the heartbeat) and is released
  when you transition the item out of `running` (`deputy set "<line>" done|surfaced|paused`);
  if you simply stop, it auto-EXPIRES after ~2× `heartbeat_mins`. If the claim FAILS
  (any non-zero exit — e.g. `busy (a live claim exists)` or `active run exists … —
  skipping this tick.`), another party holds the slot — **stop, do not proceed.**
  (The item must be `waiting`/`paused` to claim; `claim --agent` flips it to `running`.)
- **If `.deputy/waypoints/<slug>/waypoint.json` exists** (interrupted run): **RESUME** —
  first purge any dirty worktree state so a half-written step can't poison the retry:
  `git -C .deputy/wt reset --hard HEAD && git -C .deputy/wt clean -fd`
  Then call `deputy resume <slug>` to find the first uncommitted step and continue from
  there. Skip re-planning steps that already succeeded.
- **Otherwise:** `deputy start <slug> "<item-goal>"` to create the ledger.

### 3. Review touchpoints (xReview — Codex-default, author-aware)
Run an xReview at **plan**, **design** (if applicable), and **implementation** (each
commit). The reviewer is chosen by deputy, never hardcoded to one provider.

**Pick the reviewer (author ≠ reviewer):**
```bash
avail="$(deputy avail)"                       # providers currently up (csv)
# <author> = who PRODUCED the artifact under review:
#   plan / design  → claude (you wrote it)
#   implementation → the coder you used (claude normally; codex if you routed
#                    code-simple to codex on quota/rate-limit failover)
reviewer="$(deputy route review "$avail" "<author>")"
```
`deputy route review` returns the highest-preference **non-author** peer, **author-aware**
so the author never reviews its own work and a flaky peer isn't preferred for an external
author. The order depends on who authored:
- author = **claude** → `codex`, then `gemini`
- author = **codex** → `claude`, then `gemini` (claude-first; gemini is unreliable)
- author = **gemini** → `claude`, then `codex` (claude-first)
- no author named → `codex`, then `gemini` (claude is the orchestrator, never self-reviews unnamed)

This replaces the old Gemini-only gate that bare-`wait`ed (and deadlocked) when Gemini was
down. Two special returns:
- `self` — only the author is up (both peers down). Degrade per the project's
  `self_review_fallback` config (`deputy config self_review_fallback`):
  - `self_review_fallback=1` → **self-review with a loud WARNING** recorded in the trail
    (`author == reviewer`, degraded); proceed only if it finds nothing blocking.
  - otherwise (**default**, `self_review_fallback` unset/`0`) → **surface** the item
    (`.deputy/<slug>.questions.md`: "no peer reviewer available — your call"),
    `deputy set "<item-line>" surfaced`, and stop.
- `wait` — no provider up at all → treat as quota: `deputy cron --reschedule "<text>"`;
  never burn a retry.

**Invoke the chosen reviewer** (staged diff for implementation; the plan/design text
otherwise):
```bash
case "$reviewer" in
  codex)  codex exec "Review as a staff engineer. List only CRITICAL or WARNING items, each with a one-line fix, or reply LGTM: $(git -C .deputy/wt diff --cached)" -C "$(pwd)" -s read-only ;;
  gemini) gemini -p "Review as a staff engineer: $(git -C .deputy/wt diff --cached)" ;;
  claude) ;; # in-session critical re-read of the diff (only when claude is NOT the author)
  self)   ;; # DEGRADED: critically re-read your own diff; record the WARNING
esac
```
**If the chosen reviewer errors or hits a rate-limit at invocation** (availability is
probed by auth/login, which can be stale vs. actual `exec`): drop that provider from
`$avail` and re-run `deputy route review "$avail" "<author>"` for the next peer; then
handle `self`/`wait` exactly as above. Never treat a reviewer-side quota as the item
failing.

**Record every iteration** via `deputy review-log <slug>` (append-only; never hand-write
or overwrite the file). It appends stdin to `.deputy/<slug>.review.md` — deputy's
equivalent of xReview's `.review/REVIEW.md`. Per touchpoint + iteration:
```bash
deputy review-log <slug> <<'EOF'
## <touchpoint: plan|design|impl step N> — iteration <n>
- Implementing — <author> — <UTC timestamp>
- Reviewing — <reviewer> — <UTC timestamp>   (if author == reviewer, add: DEGRADED self-review)
- Verdict: APPROVED | NEEDS_CHANGES
- Findings: <CRITICAL/WARNING items, or "none">
- Action Items: <what to fix, or "none">
EOF
```
**Author ≠ reviewer** is the invariant; the only exception is a recorded degraded
self-review. **No plan, step, or design artifact advances without an APPROVED verdict**
(fix CRITICAL/WARNING and re-review until clean; repeated NEEDS_CHANGES on the same step
counts against the retry budget in §4).

### 4. Failure / retry / escalation
- **Quota / rate limit:** not a failure — reroute (§2a failover) or
  `deputy cron --reschedule`; never burn a retry or mark failed.
- **Recoverable** (a failed quality-gate/test run, OR an xReview `NEEDS_CHANGES`): retry
  with the failure as context. **Track a local `retry_count` per step, starting at 0;
  increment it by 1 on EACH failed attempt** — a failed test/quality-gate run *or* a
  `NEEDS_CHANGES` from *any* reviewer both count toward the same per-step budget. A
  reviewer-side error fallback (e.g. codex→claude) does **NOT** reset the count. Retry while
  `retry_count` < 4; on the **4th** failed attempt, stop — treat as BLOCKED/exhausted
  (initial try + 3 retries). The **plan** review and **each implementation step** each get
  their **own independent** budget (a plan rejection never counts against an implementation
  step, and vice-versa). This bounds the reviewer↔author standoff that ran **4 rounds in
  #84**: a 5th round can never happen.
- **Exhausted / BLOCKED / protected-path violation:** for a **complex** item, re-triage
  as complex and **surface** it ("Deputy got stuck here — your call"); for a **simple**
  item, `deputy set "<item-line>" failed` and write the reason + log to
  `.deputy/<slug>.fail.md`. Then `deputy wt-remove` (the branch's commits survive).
  Note: there is no `deputy fail <slug>` spine verb; on terminal failure the waypoint
  ledger intentionally stays `in_progress` so the failure context is preserved for
  debugging. Use `deputy recover` to reset the backlog item to `waiting` if re-queuing.
- **Unrecoverable BACKLOG.md write (#86) — FAIL FAST, do NOT death-loop.** If a `deputy
  set` / `deputy add` / `deputy commit` fails with *"BACKLOG.md is UNWRITABLE (persistent,
  not retryable …)"* (exit 3), the queue file cannot be written — usually a stale sandbox
  bind (#85) or a read-only file. This is **PERSISTENT**: retrying or reasoning about it
  only burns tokens. After **at most one** re-try, STOP. **Do NOT** try `deputy set
  "<line>" surfaced` — that ALSO writes BACKLOG.md (the broken file) and will fail the same
  way. Instead: write the diagnosis to `.deputy/<slug>.fail.md` (under `.deputy/`, a
  directory bind that stays writable) and **EXIT non-zero immediately**. The runner detects
  the abandoned claim on its next tick and `deputy recover`s the item so a human sees it.
  Never spend more than a couple of tool calls on an UNWRITABLE-BACKLOG error.

## Hard rules
- **Never** hand-edit `BACKLOG.md`, `.deputy/waypoints/`, or any other `.deputy/` state
  files — use `deputy set`, `deputy claim`, `deputy wt-create/wt-remove`, and the spine
  verbs (`start/plan/set-step/commit/resume/done`). The runner owns those files.
- **Never** modify a protected path (`.deputy/protected` globs) — the gate is mandatory
  before every commit.
- **`deputy commit` stages ALL changes** (`git add -A` internally). Do not rely on
  per-file declarations; undeclared edits would otherwise bleed into the next step or be
  lost on resume.
- **Author ≠ reviewer.** The reviewer is an author-aware non-author peer (claude-first
  when codex/gemini authored; codex-first when claude authored) and never wrote the
  artifact it reviews. `deputy route review` enforces this; the only exception is a
  recorded degraded self-review (only the author up + `self_review_fallback=1`).
- **No plan/step/design advances without an APPROVED verdict**, logged to
  `.deputy/<slug>.review.md`.
- **Worker-proposed tasks need human approval.** When *you* (a headless worker) run
  `deputy add` while working an item — to record newly-discovered follow-up work — deputy
  detects the worker context and files it as a **proposal**: the new item lands `surfaced`
  (not `waiting`), gets a `.deputy/proposed-<id>` marker, fires a notification, and is
  **never auto-run**. It stays inert until a human **approves** it (`deputy set "<line>"
  waiting`) or **rejects** it (`deputy set "<line>" cancelled`). **Do not self-approve** —
  it is policy, not enforced by `deputy set`; only a human flips a proposal to `waiting`.
  Just `deputy add` the follow-up and keep working your current item — adding a proposal
  does not interrupt or block your run. (A human's own `deputy add` is unaffected — it
  queues + auto-runs as before.)
- Respect `deputy config max_items` (stop after that many per cycle) and `time_cap_mins`.
- The `<item-line>` you were given is the exact match key for `deputy set`; if you ever
  lose it, re-fetch with `deputy list` and reconstruct the running-form line.
- Do not manage cron yourself except via `deputy cron --reschedule` on quota exhaustion.
- **Human-session back-off**: `cmd_run` checks for live interactive Claude sessions
  (`entrypoint=="cli"` in `~/.claude/sessions/`) in the repo before claiming an item.
  If a human session is busy or recently idle, the tick is skipped silently (logged to
  stderr with PID/status). An `idle` session idle longer than `human_idle_grace_mins`
  (default 5) lets cron proceed; a `waiting` session (idle-at-prompt — an *undocumented*
  Claude status) must hold `waiting` for `waiting_backoff_strikes` consecutive heartbeat
  ticks (default 3, a durable counter in `.deputy/.backoff_waiting`) before cron proceeds
  — a cautious persistence check (a transient mid-tool `waiting` can't survive N ticks).
  This applies to both priority-driven and targeted (`deputy run #N`) invocations.
  Config keys: `human_backoff=1` (default ON; set `0` to disable, e.g. in CI),
  `human_idle_grace_mins=5`, and `waiting_backoff_strikes=3`.
  `DEPUTY_ALLOW_ANY_BRANCH=1` does NOT bypass this check — they are independent guards.
  A stale (dead-PID) session file in this repo causes `cmd_run` to **surface** the top
  runnable item for a human to check (a sign of an abnormal Claude crash), rather than
  proceed silently; a cascade guard avoids surfacing more than one at a time, and deputy
  never deletes Claude's session files. `human_backoff=0` disables this too.

## Guardrail (enforced + judgment)
A PreToolUse hook **blocks** these in headless runs — never attempt them (and never hand
them to a failover `codex`/`gemini`, which run unhooked):
- **Edit/Write/MultiEdit/NotebookEdit** to a path outside `.deputy/wt` (the worktree) —
  only the state files `.deputy/<slug>.questions.md` and `.deputy/<slug>.fail.md` are
  exceptions. The xReview trail `.deputy/<slug>.review.md` is **append-only**: write it
  ONLY via `deputy review-log <slug>` (a Bash command) — direct Edit/Write to it is
  blocked so it can't be overwritten. *(Bash file-writes aren't path-checked — a
  best-effort limitation; still never write outside the worktree.)*
- **Bash:** `git push`, `git --git-dir`/`--work-tree` (and `GIT_DIR=`/`GIT_WORK_TREE=`
  env), `crontab`, `inst_deputy.sh`, `rm -r`/`-rf`/`-f`, `git branch -d`/`-D`/`-f`,
  `git config --global`/`--system`, `git update-ref`, `git remote …`, `git worktree remove
  --force`, `git reset --hard`/`clean -f` outside the worktree, `sudo`, `gh pr merge`,
  `gh … --delete-branch`, global installs (`npm/pnpm/yarn -g`, `pip install`, `apt`, `brew
  install`), and `deputy cron --ensure`/`--remove` — **but `deputy cron --reschedule` on
  quota is allowed** (the sanctioned failover).

**If a tool call is blocked, that means SURFACE the item** (`deputy set "<item-line>"
surfaced` with a note explaining why) — do not try to work around the block. Additionally,
**surface (do not execute) judgment-call risky ops** the hook can't catch: destructive
data/DB operations, production/service changes, repo or directory renames, and
mass/irreversible rewrites.

## Item states

| Symbol | State | Meaning |
|--------|-------|---------|
| (none) | `waiting` | Queued, ready to run |
| `~` | `triaging` | Being classified |
| `@` | `running` | Actively executing |
| `?` | `surfaced` | Awaiting human input — either a *blocked* running item, or a *worker-proposed task* (carries a `.deputy/proposed-<id>` marker; approve with `set waiting`, reject with `set cancelled`) |
| `+` | `done` | Completed (legacy `#` still read, auto-migrated) |
| `!` | `failed` | Terminal failure |
| `%` | `cancelled` | Won't-do, terminal |
| `=` | `duplicate` | Redundant, terminal |
| `^` | `paused` | Mid-execution checkpoint; auto-resumes |
| `;` | `deferred` | Parked for future consideration; inert + intentional; never auto-scheduled; revive with `deputy set "<line>" waiting` (legacy `>` still read, auto-migrated) |

states: waiting triaging running surfaced done failed cancelled duplicate paused deferred

## CLI quick reference

**Public** (in `deputy help`):
`deputy add|list|status|slug|pickup|run|watch|tail|cron|set|clean`

`deputy watch [--once] [--apply]` (aliases: `deputy tail`, `deputy review`; replaces the former `deputy reflect`) — the "what needs me" command: prints the queue OVERVIEW (learnings, untagged items, reprioritization review, duplicate candidates, status) then runs as a passive monitor — live-tails a running worker and, on quiescence (runnable→0 with a surfaced/failed/deferred item), beeps 3× + prints the attention digest (each item's next action → `deputy pickup #<id>`); re-arms after each new worker run via logs/ dir mtime. `--once` = overview + one poll then exit (test/script seam); `--apply` = overview + write `.deputy/learnings.md` then exit; `Ctrl-C` exits.

`deputy list [<state>] [--porcelain]` — items in BACKLOG format; for attention states (surfaced/failed/deferred/paused/cancelled) each item is followed by a detail block (status/details/summary/action). `--porcelain` emits stable `state|prio|id|desc` lines (no detail) for scripts.

`deputy pickup <id>` — bring up ONE attention task and ACT: surfaced ready-to-merge → merge into the default branch (→ done); proposed → approve (→ waiting); needs-input → resume via `/deputy`; failed/cancelled/deferred/paused → requeue (→ waiting). Local/safe only (never pushes). **Use a bare integer** (`deputy pickup 42`) — an unquoted `#42` is a shell comment and reaches deputy as no args; quote it (`'#42'`) if you prefer the hash form.

**Orchestrator/runner-internal — callable but NOT in `deputy help`:**
`recover|probe|route|detect` (and the already-noted `claim|pick`, the spine verbs, `wt-create|wt-remove`, `protected`, `config`) are orchestrator/runner-internal commands. They work fine from the shell but are not advertised in `deputy help` because they are plumbing details.

`deputy pick` — the preemption probe; returns the highest-priority waiting/paused item (raw line). Used by the orchestrator's preemption check and the run loop. It works fine from the shell but is not advertised in `deputy help` because it is a plumbing detail.

`deputy claim "<exact line>" [--pid N]` — mark an item running and write a PID claim file (serialization lock). Used by `cmd_run` and the orchestrator to atomically transition an item to the running state. Not advertised in `deputy help` because it is a plumbing detail; callers should go through `deputy run`.

**Spine verbs — orchestrator-internal** (NOT in `deputy help`; never call these from the
shell directly outside an orchestrator session):

| Verb | Purpose |
|---|---|
| `deputy start <slug> "<goal>"` | Create the waypoint ledger for a new item |
| `deputy plan <slug> --step <n> --purpose "<p>"` | Append a pending step to the plan |
| `deputy set-step <slug> --step <n> [--expected "<e>"]` | Mark step N as current (active) |
| `deputy commit <slug> --summary "<s>" [--artifact <path>]` | Stage ALL worktree changes, git-commit, record SHA, flip step to succeeded |
| `deputy steps <slug>` | Print all steps and their states |
| `deputy resume <slug>` | Print the first uncommitted step (empty = all done) |
| `deputy done <slug>` | Mark the task completed in the ledger |

Ledger lives at `.deputy/waypoints/<slug>/{waypoint.json,STATUS.md}`.
