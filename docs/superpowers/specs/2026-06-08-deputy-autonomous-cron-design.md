# Deputy — Autonomous cron heartbeat (design)

**Status:** Design (approved 2026-06-08). Small, focused — feeds a direct TDD implementation.
**One-liner:** Make deputy actually self-drive its queue via a 15-minute cron heartbeat
(research.sh-style), repo-aware and multi-repo, with no concurrent runs.

## Problem
deputy has the cron *machinery* (`cron --ensure`/`--reschedule`, `_set_cron`) and
`deputy run` already loops to drain the queue — but it never runs autonomously:
1. The heartbeat is opt-in and was never installed (no deputy crontab exists).
2. It is not self-arming (unlike research.sh, which re-arms on every run).
3. The cron line is repo-blind: `deputy run` from cron's `$HOME`/minimal PATH would
   neither resolve the repo's `BACKLOG.md` nor find `deputy`.
4. **PATH:** the agent CLIs (`claude`/`gemini`/`codex`) resolve via fnm's *ephemeral*
   per-shell bin, absent under cron — so an autonomous run would probe everything
   `absent` and reschedule forever.

## Design
1. **PATH self-fix in `deputy.sh`** (top of script, **idempotent**), mirroring research.sh:
   prepend `$HOME/.local/bin` and `$HOME/.local/share/fnm/aliases/default/bin` to `PATH`
   **only if not already present** (guard each dir with a `case ":$PATH:" in *":$d:"*)`
   check) so re-invocation never grows `PATH`. `…/fnm/aliases/default/bin` is the *stable*
   node bin (where `gemini`/`codex` live), not the ephemeral multishell — this makes cron
   runs find the CLIs.
2. **Heartbeat = `*/15 * * * *`** (every 15 minutes). `cmd_cron --ensure` and the
   reschedule fallback use this (replacing `0 */2`).
3. **Repo-aware, multi-repo cron line + per-repo marker.** `_set_cron` writes (paths
   **single-quoted** so spaces are safe under `/bin/sh`):
   ```
   */15 * * * * cd '<ABS_ROOT>' && '<ABS_DEPUTY>' run >> '<ABS_ROOT>/.deputy/cron.log' 2>&1  # deputy[<ABS_ROOT>]
   ```
   - `<ABS_ROOT>` = `resolve_root`; `<ABS_DEPUTY>` = `command -v deputy` (abs symlink),
     fallback `readlink -f "${BASH_SOURCE[0]}"`.
   - The marker is **per-repo and delimited**: `# deputy[<ABS_ROOT>]`. `_set_cron` filters
     out only the line containing the exact `grep -F "# deputy[<ABS_ROOT>]"` substring —
     the surrounding `[ ]` prevent a prefix collision (`/src/repo` must NOT match
     `/src/repo-two`), preserving every other repo's line. The reschedule path uses the
     same delimited marker so it updates this repo's line in place.
   - `cd '<ABS_ROOT>'` fixes cwd so `resolve_root` finds the repo; output appended to the
     already-gitignored `.deputy/cron.log`.
4. **Heartbeat lifecycle — present only when IDLE (REVISED 2026-06-08, research.sh model).**
   The cron line exists only while deputy is *waiting for work*; it is **removed while
   deputy is actively running**. This supersedes the original "self-arm `*/15` at the
   start, always-on" behavior.
   - **On `deputy add` and `deputy run`** (whether fired by the user OR by the cron):
     **remove this repo's cron line at the start** — deputy is now active, so a periodic
     heartbeat is redundant (no point firing a run while one is in progress).
   - **Drain:** after each task completes, pick the next (the existing `cmd_run` loop).
   - **On going idle** (`cmd_pick` returns nothing → no task left): **(re)create this
     repo's cron line** so the heartbeat wakes deputy later to pick up newly-added work.
   - **Two creation paths, same behavior:** the re-arm-when-idle fires whether the run was
     triggered by **(a) the cron itself** (a cron-fired run re-arms on its way out) or
     **(b) a `deputy` command** (`add`/`run` re-arms when it finishes idle).
   - Re-arm also happens on the quota path via `cron --reschedule` (arm at the reset hour),
     so autonomy survives a session-limit stop.
5. **Autonomous opt-in — marker file gates the lifecycle (REVISED 2026-06-08, implementation).** Because the cron line is
   *absent during active runs*, its presence can no longer signal "this repo wants a
   heartbeat." A persistent marker file records the opt-in: **`.deputy/cron.enabled`**
   (a zero-byte sentinel), created by `deputy cron --ensure` (and `install.sh cron`),
   deleted by `deputy cron --remove`. The helper `_cron_enabled()` tests for this file:
   `[[ -f "$STATE_DIR/cron.enabled" ]]`. The remove-on-active and re-arm-on-idle steps
   **only act when the marker is present**, so a manual `deputy run`/`add` in a
   non-autonomous repo never touches the crontab. `_live_claim_exists` still guards the
   brief window before removal against a concurrent cron fire.
   - *Robustness note:* removing the line at start means a hard crash mid-run (after remove,
     before re-arm) leaves no heartbeat until the next manual `deputy add`/`run` re-arms it.
     Accepted (this is research.sh's model); the quota path and normal idle-exit both re-arm.
6. **Logs/ignore:** `.deputy/` is already gitignored, so `.deputy/cron.log` needs no
   change.
7. **Stale-claim safety (already satisfied):** the no-concurrency guard
   (`_live_claim_exists`) uses `kill -0`, so a dead/stale claim is NOT treated as live,
   and `cmd_run` calls `cmd_recover` first to revert orphans — so a crashed run cannot
   starve the heartbeat indefinitely.

## REVISION 2026-06-09 — always-on heartbeat supersedes the idle-only lifecycle (§4/§5)
The idle-only model (remove-on-run, re-arm-on-idle) has a real **stall-on-abnormal-death**
flaw — the very "Robustness note" in §5: if a run dies by crash/kill/API-failure/reboot
*before* the re-arm step, the cron stays off and **nothing ever retries the stuck task**
(the human must notice and type `deputy run`). Replace it with a persistent heartbeat that
is *also* the recovery trigger.

**Model:** a fixed recurring **`*/15 * * * *`** line that is **never removed while
running**. Opt-in still gated by `.deputy/cron.enabled`. Each tick (and each `deputy run`)
is **state-aware**:
- **Live task running** (`_live_claim_exists` via `kill -0`) → **skip** (no-op). The
  single-claim lock already prevents a second concurrent task, so a mid-run tick is
  harmless. → This removes the need for *both* remove-on-run *and* self-rescheduling the
  line (a recurring cron simply fires again next interval).
- **Dead/orphaned task** (stale claim, or `@running`/`~triaging` with no live pid) →
  `cmd_recover` reverts to `waiting`, then the spine **resumes** it (forward-recovery from
  the first uncommitted step) — not a blind restart.
- **Quota-blocked task** → record the provider's reset time; each tick **skip** it (a
  per-task skip) and resume once quota is back. Do **NOT** `cron --reschedule` the shared
  line for a quota block — moving the whole heartbeat to the reset hour would also delay
  recovery and unrelated work (Gemini). The fixed `*/15` keeps serving everything; quota is
  a per-task skip, not a heartbeat change. (`cron --reschedule` is dropped in this model.)
- **Surfaced or failed task** → **leave it.** `surfaced` is blocked on the human
  (auto-resuming would loop / re-surface); `failed` needs review. Only **interrupted** and
  **quota-blocked** are auto-resumable (the suspension-resume taxonomy).
- **Idle + runnable work** → pick the highest-priority item and run it.

**Concurrency hardening (Gemini, required for always-on).** Always-on + instant-trigger
raises the chance of concurrent run attempts, so:
- **Atomic claim:** the `_live_claim_exists` check and the claim write must occur in ONE
  flock-held critical section (or via an atomic create) — never check-then-act — so two
  ticks (or a tick + a manual `run`) can't both pass the check and double-claim (TOCTOU).
- **PID validation:** `_live_claim_exists` must validate the PID **and** its process
  start-time (or a boot id), not a bare `kill -0` — after a reboot/PID-reuse a stale claim's
  number can belong to an unrelated process, falsely reading "live" and starving recovery.

**Durable retry budget (NEW requirement).** A self-healing heartbeat that revives dead
tasks can **crash-loop** if a task fails the same way every tick. The spine's 2-retry
budget is per-run and resets across cron re-triggers, so add a **durable attempt counter in
the waypoint ledger**: after N (e.g. 3) cron-resumes with no progress (no new committed
step), stop reviving — mark the item `failed`/`surfaced` so a poisoned task can't loop
forever.

**Kept:** instant-trigger on `deputy add` (research.sh-style responsiveness) — it coexists
with the always-on cron because the lock serializes (a concurrent tick just skips). Per-repo
markers unchanged.

**Net:** simpler (no remove/re-arm dance, no self-reschedule except quota), self-healing
(survives any death mode), and it closes the recovery-trigger gap.

**Scope note:** this is the recovery mechanism for the **headless/autonomous** flow (the
cron re-spawns the orchestrator, which retries a failed API). It does **not** cover an
interactive session where Claude is driving and a tool call dies — that's a different layer.

## Decisions
- Interval **`*/15`**, **always-on** (recurring, never removed; state-aware tick) — this
  SUPERSEDES the idle-only remove/re-arm model of §4/§5. (Revised 2026-06-09; see the
  REVISION section above.)
- **Per-repo markers** so deputy + stock-pick (and any future repo) each get their own
  cron line and coexist.
- Opt-in is a **marker file `.deputy/cron.enabled`** (not a config key, not "is the line
  present?", since the line is removed during runs). (§5.)
- Auto-run (`deputy add` background dispatch) is a **detached background `deputy run`**
  (drain loop, not `--once`), overridable via `DEPUTY_AUTORUN_CMD` for tests, logging to
  `.deputy/run.log`.
- This consolidates with the **P0 "make `deputy add` trigger run + preemption"** item: the
  same entry points (`add`/`run`) own the remove-on-active / arm-on-idle lifecycle; the
  preemption half (higher-priority `add` preempts a running lower-priority task) is the
  remaining piece, built on the checkpoint spine + a `paused`/`preempted` status.

## Testing
- `cron --ensure` creates `.deputy/cron.enabled` marker AND arms the repo-aware `*/15` line
  (per-repo marker); a second repo's `--ensure` preserves the first repo's line
  (multi-repo, prefix-safe).
- `cron --remove` deletes `.deputy/cron.enabled` and removes only this repo's line.
- `deputy run` with the marker present **removes** the cron line at start; on going idle
  (empty queue) **re-creates** the `*/15` line. Without the marker, neither step touches
  the crontab.
- **Auto-run is a detached background `deputy run`** (not `--once`) spawned by `_autorun`
  so `deputy add` returns immediately. Tests override the spawn via `DEPUTY_AUTORUN_CMD`;
  the background process logs to `.deputy/run.log`.
- `--reschedule` arms this repo's line at the reset hour (quota path).
- `cmd_run` no-ops/declines a second run under a live claim (keep the existing test).
- PATH export present and idempotent (doesn't duplicate on re-invoke).

## Rollout
Install for **both** repos: `deputy cron --ensure` in `/home/tong/src/tonychen15/deputy`
and `/home/tong/src/cliffwoodave14/stock-pick`; verify `crontab -l` shows both
per-repo `*/15` lines.
