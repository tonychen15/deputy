# Deterministic, idempotent per-task branch/slug

**Status:** implemented (commit `feat(#99)`, tracked as BACKLOG #98).

## Problem

The slug (`→ branch deputy/<slug> → worktree .deputy/wt`) was invented by the LLM
orchestrator at **run time** by kebab-casing the item description. Consequences:

- **Non-deterministic.** Two runs of the same task could slugify differently → two
  branches. This is exactly how #96 ended up with both `deputy/cron-set-heartbeat-96`
  and `deputy/deputy-cron-set-heartbeat-96`.
- **Resume/rerun not idempotent** — no guarantee of landing on the prior branch/worktree.
- The whole #97/#98 machinery (record the branch in the ready-merge marker, fallback
  glob, ambiguity refusal) existed **only to compensate** for the non-determinism.

## Design

The slug is assigned **once, at `deputy add`, and frozen**, keyed to the **immutable
user-input description**.

### Two descriptions (per the user's model)
- **`user_desc`** — the original text the user typed. **Immutable.** Anchors the branch.
- **refined/display description** — may be edited during grilling. Shown in the queue.
  Changing it **never moves the branch**, because the branch keys off `user_desc`.

### Slug shape
`<id>-<hash8>-<descslug>` where `hash8 = first 8 hex of sha256(user_desc)` (portable
fallback: `shasum`, then `cksum`), and `descslug` is the kebab-cased `user_desc` capped
to 40 chars. A pure function of `(id, user_desc)` → same inputs, same slug, forever.

### Storage
`.deputy/meta/<id>.meta` (`user_desc:` + frozen `slug:` + `created-at:`), written
atomically (temp + rename), **required** at add (a task never exists without its frozen
slug; rolled back if the append then fails; a stale orphan meta for a reused id is
overwritten, not inherited).

### Single source of truth
`deputy slug <id>` — the orchestrator, `wt-create`, `resume`, and the runner all **ask**
for the slug instead of inventing one. Legacy items (added before meta existed) are
backfilled from their current description and frozen on first call.

## What it retires

`_auto_merge_ready` can derive the branch as `deputy/$(deputy slug <id>)` deterministically
(it now prefers this before the legacy glob). The #97/#98 marker-branch-recording +
unique-glob + ambiguity-refusal become **belt-and-suspenders** rather than load-bearing.

## Follow-ups (not yet done)
- Unify the internal `_wp_slug id desc` trail-path callers onto `deputy slug <id>`.
- After a release proves the above, simplify/remove the #97/#98 compensating machinery.
- `deputy clean` could remove a task's `.deputy/meta/<id>.meta` for orphan hygiene
  (correctness already handled by overwrite-on-mismatch).
- Existing pre-#99 branches keep their old names — this is forward-looking.
