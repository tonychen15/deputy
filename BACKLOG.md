# Deputy Backlog

## LEGEND
**Status (line prefix):** (none) waiting | `~` triaging | `@` running | `?` surfaced | `#` done | `!` failed | `%` cancelled | `=` duplicate | `^` paused | `>` deferred
**Priority (tag):** `[P0]` urgent+important | `[P1]` urgent | `[P2]` important | (none) lowest lane
**Order:** P0 > P1 > P2 > untagged ; FIFO within a lane
**Line format:** `<status?>[Px][#N] <description>`  (`[#N]` assigned automatically on first reference)
**Add an item:** `deputy add [-ui|-u|-i|--p0|--p1|--p2] "your task"` — or just add a line below
---

## Items

[P2][#41] Add 'deputy release [version]' command: insert a parser-safe dated delimiter ('<!-- release vX — YYYY-MM-DD -->') at the top of the Done section; version defaults to the VERSION file; update help + README + tests
[P3][#42] Add release-notes extraction: a command to print Done items above the most-recent release delimiter (done-since-last-release), ready to paste into CHANGELOG. Depends on the BACKLOG release-delimiter feature
[P3][#43] Redesign 'deputy clean' for the sectioned/delimiter Done structure: decide and implement how 'clean --state done' (and clean <id> of a done item) handles release-delimiter lines — strip orphaned delimiters, or refuse, or collapse. Depends on #40 (sectioned BACKLOG) and #41 (release delimiter). Until then, avoid 'clean --state done'.
[P2][#40] Reformat BACKLOG.md into headed sections (legend fixed on top; ## Items with ### sub-headers+counts in order: Running, Surfaced(+triaging), Waiting, Paused, Deferred, Failed/Cancelled, Done(+duplicate) at bottom). Newest-completed moves to top of Done. Rewrite _regroup_backlog for the sectioned layout + preserve release-delimiter lines within Done; make _each_item/_parse_item skip markdown headings and delimiter comments. Update template/README/SKILL backlog-format docs; add tests for layout, newest-on-top, delimiter preservation

>[P3][#4] Add richer item attributes: due dates, dependencies (depends-on), project/goal grouping
>[P3][#3] Add intake from GitHub issues, failing CI, and TODO/FIXME scan
>[P2][#2] Support parallel execution via multiple git worktrees (capped, conflict-aware)
>[P2][#1] Migrate waypoint and xReview to run on Gemini and Codex so complex items can fail over

#[P2][#39] Rework the post-completion queue display: trigger on every completion (in 'deputy set <line> done') so interactive and autonomous runs both show it, render as an aligned TABLE listing waiting+paused+deferred items (runnable first by priority+FIFO, deferred after) with per-state counts; remove the now-redundant cmd_run loop calls; update tests
#[P2][#38] After each completed task in the run loop, display the remaining waiting task list (readable, priority-sorted; show 'queue empty' when none) before picking up the next waiting task to run
#[P1][#37] Adopt xReview-style review audit trail in deputy: persist each review touchpoint (plan/design/each implementation commit) to a deputy-owned append-only log (.deputy/<slug>.review.md) mirroring xReview's .review/REVIEW.md structure — numbered Iterations with Reviewing line (reviewer+timestamp), Verdict (APPROVED/NEEDS_CHANGES), Findings, Action Items. Author != reviewer recorded. Part of v1.1.0 xReview migration with #36.
#[P1][#36] Align xReview gate with Codex-default model: _route review (bin/deputy.sh ~L798) is Gemini-only with no Codex fallback, so review work stalls on 'wait' when Gemini is unavailable (IneligibleTierError / rate limits). Make reviewer routing author-aware: prefer Codex, fall back to Gemini when Codex authored the step (never bare 'wait' while a peer is available); update SKILL.md 'Gemini-primary' wording to be provider-agnostic. Mirrors xReview's codex>gemini>peer>self.
#[P3][#35] combine 'install.sh cron' with 'install.sh init <folder>', so user only need to run one install.sh one time
#[P2][#34] upgrade the version to v1.0.1 (bump VERSION + add a CHANGELOG entry for the changes since v1.0.0)
#[P3][#33] clean any left-over jobflow references/files from this deputy project
#[P1][#31] update README.md: 1. remove deputy pick from usage; 2. remove deputy review from usage; 3. update item format in BACKLOG.md to match current line format
#[P0][#32] add a 'deputy clean <id>' option to clean a single item by id, and update the usage in README.md
#[P3][#29] when a deputy is fired and picks an item to execute, and at the same time claude is working on the same repo/branch, then deputy should back off to avoid mixing different changes on the same branch. Do a thorough research on this
#[P2][#30] when an item is added without a priority tag (no Px, no -i/-u), assign it [P4] when it gets its item number, so every line has a consistent [Px] tag
#[P2][#28] try to merge set and reflect subcommands or merge reflect and review subcommands
#[P2][#27] remove or hide the 'deputy claim' command from public help (orchestrator-internal, like 'pick') without any regression — keep it fully working
#[P1][#26] update README.md based on the latest code status, remove those roadmap related wording if it doesn't align with the latest code
#[P0][#25] check whether deputy project is ready for release and install to other project, verify it with stock_pick project
#[P0][#24] Add a new 'deferred' item state (line symbol '>') for items parked for FUTURE consideration. Semantics: INERT + intentional — never scheduled/picked by run/pick, and the always-on heartbeat LEAVES it (never auto-resumes, unlike paused). User-driven: 'deputy set <item> deferred' parks it, 'deputy set <item> waiting' revives. Distinct from cancelled (terminal/won't-do) and paused (mid-execution checkpoint, auto-resumable). Group deferred items in their own BACKLOG.md section between active and done. Cleanable ONLY via explicit 'deputy clean --state deferred' (never bare clean — it's revivable). Implement across: parse/serialize the '>' prefix, set/transitions, scheduler+heartbeat skip (not-runnable), group-by-state writer, clean --state allowlist, and SKILL.md legend + states list. Name/symbol 'deferred'/'>' is the recommended default; confirm/adjust at build.
#[P2][#6] extend deputy clean with augment, such as duplicate, waiting, running, paused. With this augment, deputy can remove tasks with a specific state.
#[P2][#5] E2E test: interrupt a run mid-step and verify orchestrator-driven resume — recover reverts the orphaned @running item, the next run re-picks it, SKILL §2c purges dirty worktree state + calls 'deputy resume', and execution continues from the first uncommitted step to completion. Covers the one untested hole in the resume story (SKILL §2c is prompt-only today).
#[P1][#9] Replace idle-only cron with an ALWAYS-ON state-aware heartbeat that is also the recovery trigger (supersedes the idle-only remove/re-arm in specs/2026-06-08-deputy-autonomous-cron-design.md). Interval default 10 min, CONFIGURABLE via heartbeat_mins in .deputy/config (deputy cron --ensure reads it and writes the matching */N schedule; validate 1-59, fall back to 10). Never remove the line while running. Per tick: live task->skip (single-claim lock); dead/orphaned->cmd_recover + spine forward-resume; quota-blocked->per-task skip until provider reset (do NOT reschedule the shared line); surfaced/failed->leave; idle+work->pick highest priority. Required hardening: ATOMIC flock claim (no check-then-act TOCTOU); _live_claim_exists validates PID + process start-time (not bare kill -0); durable retry-attempt counter in the waypoint ledger so a poisoned task can't crash-loop every interval. Keep instant-trigger on 'deputy add' (lock serializes).
#[P2][#8] add one 'pick' option which is similar to 'run' command. 'pick' will specify an item id to run but the later one 'run' will follow the general scheduling rule
#[P1][#7] Whether we need a unique item id for each item at the time when this item is picked to run? Or any time a deputy command is run or crontab is woke up. they may scan the items, if one item is not allocated an item id yet, then they allocate a unique id for it. The reason I prefer this way is provide a reference for a new /deputy command 'pick'
#[P1][#10] BUG (breaking): install.sh link run from inside a .deputy/wt-* worktree repoints the GLOBAL ~/.claude/skills/deputy (and ~/.local/bin/deputy) symlink to the ephemeral worktree path; when the worktree is torn down at task end the symlink dangles and /deputy breaks. Fix: install.sh must resolve the symlink target to the CANONICAL repo root (git --git-common-dir / main worktree), never a linked worktree; autonomous task runs must NOT run install.sh link; emit a notification on such breaking changes.
#[P1][#11] Add cancelled and duplicate item statuses to the queue (parse/serialize/status)
#[P1][#12] Install and wire the Codex CLI so simple-coding failover is live (probes absent today)
#[P1][#13] Add a token/cost budget cap to the run loop (stop a cycle past N output tokens)
#[P2][#14] Add precise per-provider rate-limit reset parsing for gemini and codex
#[P2][#15] Implement full Reflect: re-triage stale items, reprioritize, prune duplicates, capture learnings
#[P3][#16] Add external notifications (push/desktop/email) when an item is surfaced or finishes
#[P0][#17] rename jobflow folder name to deputy and update its reference
#[P0][#18] add a 'clean' option for deputy to clean those untouched items
=[P1][#19] Priority preemption: when a higher-priority item arrives, checkpoint-pause the running lower-priority item (waypoint forward-recovery) and resume it later — DEPENDS ON wiring waypoint into execution + parallel-worktree concurrency; needs a 'paused' status
#[P1][#20] install.sh should append project README/CLAUDE guidance instructing Claude to record any found unfinished or newly-planned tasks into BACKLOG.md, so deputy schedules them
#[P0][#21] Make 'deputy add' trigger execution like research.sh, not just enqueue. On 'deputy add --pX <task>': if NO task is running, immediately run the new task (no separate 'deputy run' needed). If a task IS running and the new task is higher priority (P0>P1>P2>untagged), PREEMPT the running lower-priority task — checkpoint-pause it via the spine (paused/preempted status) and run the new one, then resume the paused one after. Builds on the checkpoint spine; overlaps the existing 'Priority preemption' item (consolidate).
#[P2][#22] Group BACKLOG.md by state on write: waiting items first (right after the '## Items' title), done items at the bottom, each group separated by a blank line
#[P0][#23] Change the 'done' gate: a task is done only when its work is committed AND merged into LOCAL master (orchestrator merges deputy/<slug> into master before 'deputy set done'); pushing local master to remote stays the USER's decision — deputy never auto-pushes. Update SKILL.md's done-flow (and runner if needed). Supersedes the earlier 'done = committed-to-branch' semantics.
