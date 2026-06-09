# Deputy — stable item IDs + `run <id>` (design)

**Status:** Design (2026-06-09). Covers backlog items P1 (item-id allocation) + P2
(targeted execution), folded together. Feeds an implementation plan.
**One-liner:** Give every backlog item a stable, never-recycled integer ID (allocated
lazily under the lock by any `deputy` invocation), and add `deputy run <id>` to run a
specific item out of priority order.

## Problem
There's no durable handle for a specific backlog item. The orchestrator slug is derived
from the description (changes if the text changes) and items get reordered by the
group-by-state writer, so position isn't stable either. To let a human say "run *that*
one," we need a stable reference + a command that uses it.

## Design

### 1. The ID
- **Monotonic positive integer.** Allocation = `max(existing IDs across ALL items,
  including done/failed/cancelled/duplicate) + 1`. Scanning all items (not just waiting)
  guarantees **no recycling** — a given ID always refers to the same task for the life of
  the file.
- **Distinct from the slug.** The slug remains the branch/waypoint name (derived from
  text); the ID is a stable user-facing reference only.

### 2. Storage in `BACKLOG.md`
- The ID is a bracket tag **`[#N]`** carried in the item line, placed immediately after
  the priority tag: `@[P1][#7] description` (a waiting untagged item: `[#7] description`;
  with priority: `[P1][#7] description`). `#` only denotes the *done status* when it's the
  **line-leading status symbol**; inside `[...]` it is unambiguous.
- **Parser:** extend `_parse_item` to recognize an optional `[#<digits>]` tag (in addition
  to the existing optional `[P<n>]`), tolerant of either order (`[P1][#7]` or `[#7][P1]`).
- **Serializer:** `_serialize_item` always emits the canonical order `status [P<n>] [#N]
  description` and preserves the ID. The group-by-state regrouping is content-preserving
  (already raw-line based), so IDs survive reordering.
- Lines with no `[#N]` parse fine (ID empty) — backward compatible; they get an ID on the
  next allocation pass.

### 3. Lazy allocation (`_allocate_ids`)
- A new internal helper runs **inside the existing `flock`** at the start of any queue
  mutation/scan path (`add`, `run`, `pick`, `status`, `list`, `set`, `claim`, `recover`,
  `review`, and the cron tick). It:
  1. Parses all items; finds `max` existing `[#N]`.
  2. For each item lacking an ID (in file order), assigns `max+1`, `max+2`, … and rewrites
     the line via `_serialize_item`.
  3. Writes back atomically (tmp + `mv`), only if something changed (idempotent — a second
     pass is a no-op).
- Allocation is **append-only**: existing IDs are never changed or reused.
- Because it's lock-held + idempotent, concurrent `deputy` invocations can't double-assign.

### 4. `deputy run <id>`
- **`deputy run`** (no arg): unchanged — claim the highest-priority runnable item per the
  scheduler.
- **`deputy run <id>`**: under the lock, find the item whose `[#N]` equals `<id>`.
  - If not found → exit non-zero with `deputy: no item with id <id>`.
  - If found but not runnable (already `done`/`@running`/`~triaging`) → exit non-zero with a
    clear reason (`deputy: item <id> is <state>, not runnable`).
  - If runnable (`waiting`/`paused`) → claim it and run it **bypassing priority order**
    (otherwise identical to a normal run: spawn the orchestrator on that item line).
- `<id>` is the bare integer (e.g. `deputy run 7`); a leading `#` is accepted and stripped
  (`deputy run '#7'`).
- The bounded run-until-session-limit loop is unaffected; `run <id>` runs exactly that one
  item then returns (it does not then drain the rest — targeted means targeted).

### 5. Help / docs
- `deputy help`: document `run [<id>]`. No new top-level verb (no `pick` for execution).
- SKILL.md CLI reference: note `run [<id>]`. (The internal `deputy pick` priority-probe is
  unchanged.)

## Testing
Pure-bash tests (existing harness):
- **Allocation:** items without IDs get sequential IDs on the first scanning command;
  second pass is a no-op (idempotent); a new `add` gets `max+1`; IDs are not reused after
  an item is `done`; allocation preserves status/priority/description.
- **Parse/serialize round-trip:** `[P1][#7]` and `[#7][P1]` both parse; serialize emits
  canonical order; legacy lines (no `[#N]`) still parse.
- **Regroup preserves IDs:** group-by-state write keeps each item's `[#N]`.
- **`run <id>`:** runs the targeted item (mock orchestrator) regardless of priority;
  unknown id → non-zero + message; done/running id → non-zero + message; `#7` form works.
- **`run` (no arg)** still picks by priority (regression).

## Scope
**In:** the `[#N]` grammar + parse/serialize, `_allocate_ids` (lazy, lock-held,
idempotent, append-only), `deputy run <id>`, help/SKILL docs, tests. **Out:** changing the
slug mechanism; dependency-aware scheduling (separate item); richer attributes
(due/depends-on — separate item); reusing/compacting IDs.

## Review refinements (folded from Gemini review, APPROVED-with-warnings)
1. **Parse only in the tag zone.** Detect `[#N]` ONLY immediately after the status/priority
   tags and before the description body — never match a `[#<digits>]` that appears inside
   the description text. e.g. `[P1][#7] fix [#5] crash` → ID is **7**, not 5. Add a test
   for a description that contains a bracketed number.
2. **"Never recycled" caveat.** The guarantee holds as long as the highest-ID line exists.
   If a user *manually deletes* the highest-ID item line, the next allocation could reissue
   that number — an acceptable trade-off for a markdown-as-state tool (and `run <id>` is
   typically used right after `list`, so the window is tiny). Document it; don't engineer
   around it.
3. **Read-path writes are one-time, not perpetual.** Because allocation only writes back
   when something changed (idempotent), `status`/`list` write at most ONCE — the first time
   they encounter unallocated items; subsequent reads are pure no-op no-write. That keeps
   IDs immediately visible without turning reads into perpetual writers. (If write-on-read
   ever proves noisy, allocation can later be narrowed to mutating paths + the cron tick.)
4. **Slug uniqueness must include the ID.** Targeted `run <id>` (and runs generally) must
   not let two items with identical descriptions collide in `.deputy/` (same derived slug →
   shared branch/waypoint state). The orchestrator slug derivation must incorporate the
   item ID (e.g. suffix `-<id>` or fold the ID into the uniqueness hash). Add this to the
   SKILL's slug rule + cover it in the plan.
