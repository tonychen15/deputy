# Deputy Backlog

## LEGEND
**Status (line prefix):** (none) waiting | `~` triaging | `@` running | `?` surfaced | `#` done | `!` failed | `%` cancelled | `=` duplicate
**Priority (tag):** `[P0]` urgent+important | `[P1]` urgent | `[P2]` important | (none) lowest lane
**Order:** P0 > P1 > P2 > untagged ; FIFO within a lane
**Line format:** `<status?> <priority?> <description>`
**Add an item:** `deputy "your task" [-ui | -u | -i]` — or just add a line below
---

## Items


#[P1] Add cancelled and duplicate item statuses to the queue (parse/serialize/status)

#[P1] Install and wire the Codex CLI so simple-coding failover is live (probes absent today)

[P1] Add a token/cost budget cap to the run loop (stop a cycle past N output tokens)

[P2] Add precise per-provider rate-limit reset parsing for gemini and codex

[P2] Implement full Reflect: re-triage stale items, reprioritize, prune duplicates, capture learnings

[P2] Migrate waypoint and xReview to run on Gemini and Codex so complex items can fail over

[P2] Support parallel execution via multiple git worktrees (capped, conflict-aware)

Add external notifications (push/desktop/email) when an item is surfaced or finishes

Add richer item attributes: due dates, dependencies (depends-on), project/goal grouping

Add intake from GitHub issues, failing CI, and TODO/FIXME scan

#[P0] rename jobflow folder name to deputy and update its reference

#[P0] add a 'clean' option for deputy to clean those untouched items

[P1] Priority preemption: when a higher-priority item arrives, checkpoint-pause the running lower-priority item (waypoint forward-recovery) and resume it later — DEPENDS ON wiring waypoint into execution + parallel-worktree concurrency; needs a 'paused' status
