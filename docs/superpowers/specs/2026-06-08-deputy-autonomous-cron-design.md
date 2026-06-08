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
4. **Running-check / no concurrency** (the wake-up behavior): on each 15-min wake,
   `deputy run` first checks `_live_claim_exists` (a task is running). If yes → it
   **returns immediately without starting a second run**; the fixed `*/15` schedule
   fires again in 15 minutes and retries. If no → it drains the queue. (This guard
   already exists in `cmd_run`; the design just relies on it under the `*/15` cron.)
5. **Self-arming (idempotent, write-only-if-needed).** `cmd_run` re-ensures this repo's
   `*/15` heartbeat **only if the repo is already cron-enabled** (its `# deputy[<ROOT>]`
   line exists) — so the line self-heals, without a manual `deputy run` in a
   non-autonomous repo surprising the user by installing cron. Crucially, self-arm
   **reads the crontab first and only rewrites if the expected line is missing or wrong**
   — so a healthy heartbeat is a no-op, which cuts churn and shrinks the window for a
   cross-repo `crontab -` write race. `deputy cron --ensure` (and `install.sh cron`) is
   how a repo opts in.
6. **Logs/ignore:** `.deputy/` is already gitignored, so `.deputy/cron.log` needs no
   change.
7. **Stale-claim safety (already satisfied):** the no-concurrency guard
   (`_live_claim_exists`) uses `kill -0`, so a dead/stale claim is NOT treated as live,
   and `cmd_run` calls `cmd_recover` first to revert orphans — so a crashed run cannot
   starve the heartbeat indefinitely.

## Decisions
- Interval **`*/15`** (user). Fixed schedule + the live-claim guard *is* the
  "if a task is running, wait for the next 15-min tick; else run" behavior — no
  one-shot reschedule needed.
- **Per-repo markers** so deputy + stock-pick (and any future repo) each get their own
  cron line and coexist.
- Self-arm is **gated on cron-enabled** (line present) to avoid surprising installs.

## Testing
- `_set_cron` writes the repo-aware line with the per-repo marker; a second repo's
  `--ensure` preserves the first repo's line (multi-repo).
- `--reschedule` updates only this repo's line; `--remove` removes only this repo's line.
- `cmd_run` self-arms iff the repo's cron line is present (mock `DEPUTY_CRONTAB`).
- `cmd_run` no-ops under a live claim (existing behavior — keep a test).
- PATH export present and idempotent (doesn't duplicate on re-source).

## Rollout
Install for **both** repos: `deputy cron --ensure` in `/home/tong/src/tonychen15/deputy`
and `/home/tong/src/cliffwoodave14/stock-pick`; verify `crontab -l` shows both
per-repo `*/15` lines.
