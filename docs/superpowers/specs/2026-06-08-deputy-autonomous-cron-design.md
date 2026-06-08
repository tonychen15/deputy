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

## Decisions
- Interval **`*/15`** (user), but the cron is **idle-only** (removed while running, re-armed
  when idle) — NOT a fixed always-on `*/15`. (Revised 2026-06-08, §4.)
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
