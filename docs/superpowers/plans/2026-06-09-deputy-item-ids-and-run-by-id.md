# Deputy Item IDs + `run <id>` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every backlog item a stable, never-recycled integer ID (`[#N]` tag), and add `deputy run <id>` to target a specific item out of priority order.

**Architecture:** Extend `_parse_item`/`_serialize_item` to carry a fourth `id` field; add `_allocate_ids` (called lock-held at the start of every mutating/scanning command) that assigns sequential IDs to untagged items idempotently; extend `cmd_run` to accept an optional integer argument that bypasses priority to target a specific item.

**Tech Stack:** Pure bash (`set -euo pipefail`), existing `flock`/`_with_lock` mechanism, `mktemp`+`mv` atomic writes, the same dependency-free test harness (`tests/lib.sh`).

---

## File Map

| File | Change |
|------|--------|
| `bin/deputy.sh` | Extend `_parse_item`, `_serialize_item`, add `_allocate_ids`, extend `cmd_run`, call `_allocate_ids` in `_with_lock` blocks |
| `tests/test_item_ids.sh` | New — all ID-specific tests |
| `tests/test_parse.sh` | Update existing assertions that check exact parse output (they now get a fourth `id` field) |
| `tests/test_pick.sh` | Update exact-line match expectations (items get `[#N]` in BACKLOG) |
| `tests/test_claim.sh` | Same — update `@[P0] first` etc. to include `[#N]` |
| `tests/test_regroup.sh` | Same — exact line matches and assertions about regroup order |
| `tests/test_run.sh` | Update claim-file contents and `deputy list` assertions |
| `tests/test_add.sh` | Update list-content assertions that reference exact descriptions |
| `skills/deputy/SKILL.md` | Update slug-derivation rule + CLI reference |

---

## Task 1: Write failing tests for `_parse_item` ID extension

**Files:**
- Create: `tests/test_item_ids.sh`

The new `_parse_item` will output `state|priority|id|description` (four fields). First write tests that verify this new contract — they will fail until `_parse_item` is updated.

**Background:** The existing `_parse_item` currently returns `state|priority|description` (three fields). We're adding a fourth `id` field between `priority` and `description`. Legacy lines (no `[#N]`) return an empty id field: `state|priority||description`.

- [ ] **Step 1.1: Create the test file**

```bash
cat > /home/tong/src/tonychen15/deputy/tests/test_item_ids.sh << 'TESTEOF'
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

parse() { bash "$DEPUTY" _parse "$1"; }

# ── Parse: [#N] tag recognition ──────────────────────────────────────────────
# [P1][#7] in the tag zone → id=7
assert_eq "$(parse '[P1][#7] fix the bug')"   "waiting|P1|7|fix the bug"   "parse P1+id"
# [#7][P1] reversed order → same result
assert_eq "$(parse '[#7][P1] fix the bug')"   "waiting|P1|7|fix the bug"   "parse id+P1 reversed"
# no priority, just id
assert_eq "$(parse '[#3] plain item')"         "waiting||3|plain item"      "parse id no priority"
# status prefix + id
assert_eq "$(parse '@[P0][#12] running one')"  "running|P0|12|running one"  "parse running P0+id"
assert_eq "$(parse '#[#9] done one')"          "done||9|done one"           "parse done+id"
assert_eq "$(parse '^[P1][#4] paused')"        "paused|P1|4|paused"         "parse paused P1+id"
# legacy line (no [#N]) → empty id field
assert_eq "$(parse '[P0] legacy no id')"       "waiting|P0||legacy no id"   "parse legacy no id"
assert_eq "$(parse 'plain no id')"             "waiting|||plain no id"      "parse plain legacy"
assert_eq "$(parse '# done legacy')"           "done|||done legacy"         "parse done legacy"
# [#5] in the description body must NOT become the id
assert_eq "$(parse '[P1][#7] fix [#5] bug')"   "waiting|P1|7|fix [#5] bug"  "desc [#5] not parsed as id"
# [#5] in description on a legacy line (no tag-zone id) → empty id, full desc
assert_eq "$(parse 'fix [#5] crash')"          "waiting|||fix [#5] crash"   "legacy desc [#5] stays in desc"
# large id
assert_eq "$(parse '[#100] big id')"           "waiting||100|big id"        "large id"
# id=0 edge case
assert_eq "$(parse '[#0] zero id')"            "waiting||0|zero id"         "id=0 parses"

# ── Serialize: canonical order status[Pn][#N] description ────────────────────
ser() { bash "$DEPUTY" _serialize "$1" "$2" "$3" "$4"; }
assert_eq "$(ser waiting P1 7 'fix the bug')"  "[P1][#7] fix the bug"    "serialize waiting P1+id"
assert_eq "$(ser running P0 12 'run me')"      "@[P0][#12] run me"       "serialize running P0+id"
assert_eq "$(ser done '' 9 'done one')"        "#[#9] done one"          "serialize done+id"
assert_eq "$(ser waiting '' 3 'plain')"        "[#3] plain"              "serialize waiting no prio+id"
assert_eq "$(ser waiting P2 '' 'no id')"       "[P2] no id"              "serialize waiting P2 no id"
assert_eq "$(ser waiting '' '' 'bare')"        "bare"                    "serialize bare no prio no id"
assert_eq "$(ser paused P1 4 'paused')"        "^[P1][#4] paused"        "serialize paused P1+id"

# ── Parse/serialize round-trip ────────────────────────────────────────────────
# Parse then re-serialize must yield canonical form
line="[P0][#7] do a thing"
parsed="$(parse "$line")"
state="${parsed%%|*}"; rest="${parsed#*|}"
prio="${rest%%|*}"; rest="${rest#*|}"
id="${rest%%|*}"; desc="${rest#*|}"
reser="$(ser "$state" "$prio" "$id" "$desc")"
assert_eq "$reser" "$line" "round-trip canonical form"

# Reversed order normalizes on round-trip
line_rev="[#7][P0] do a thing"
parsed2="$(parse "$line_rev")"
state2="${parsed2%%|*}"; rest2="${parsed2#*|}"
prio2="${rest2%%|*}"; rest2="${rest2#*|}"
id2="${rest2%%|*}"; desc2="${rest2#*|}"
reser2="$(ser "$state2" "$prio2" "$id2" "$desc2")"
assert_eq "$reser2" "[P0][#7] do a thing" "reversed order normalizes to canonical on round-trip"

# ── _allocate_ids: sequential, idempotent, append-only ───────────────────────
setup_repo
bash "$DEPUTY" add "alpha" --p1
bash "$DEPUTY" add "beta"  --p0
bash "$DEPUTY" add "gamma"
# After add, allocation should have fired; list should show state|prio|id|desc
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "waiting|P1|1|alpha"  "alloc: alpha gets id 1"
assert_contains "$out" "waiting|P0|2|beta"   "alloc: beta gets id 2"
assert_contains "$out" "waiting||3|gamma"    "alloc: gamma gets id 3"

# Second pass is a no-op (no new IDs, ids don't change)
out2="$(bash "$DEPUTY" list)"
assert_contains "$out2" "waiting|P1|1|alpha"  "alloc idempotent: alpha still id 1"
assert_contains "$out2" "waiting|P0|2|beta"   "alloc idempotent: beta still id 2"

# New add gets max+1 (4)
bash "$DEPUTY" add "delta" --p2
out3="$(bash "$DEPUTY" list)"
assert_contains "$out3" "waiting|P2|4|delta"  "alloc: delta gets max+1 = 4"

# Done item's ID is not reused: mark alpha done, add new item → gets 5 not 1
setup_repo
bash "$DEPUTY" add "task one"
bash "$DEPUTY" add "task two"
# list to allocate ids
bash "$DEPUTY" list >/dev/null
# mark task one done (exact running line lookup is tricky; use set with raw line)
raw_one="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" set "$raw_one" done
bash "$DEPUTY" add "task three"
out4="$(bash "$DEPUTY" list)"
assert_contains "$out4" "done||1|task one"   "done item keeps its id"
assert_contains "$out4" "waiting||3|task three" "new item skips over done id"

# Status preserves id
setup_repo
bash "$DEPUTY" add "check status" --p0
bash "$DEPUTY" list >/dev/null
raw="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" set "$raw" done
out5="$(bash "$DEPUTY" list)"
assert_contains "$out5" "done|P0|1|check status" "set done preserves id"

# ── Regroup preserves IDs ─────────────────────────────────────────────────────
setup_repo
bash "$DEPUTY" add "regroup waiting" --p2
bash "$DEPUTY" add "regroup urgent" --p0
bash "$DEPUTY" list >/dev/null
# trigger regroup via set
raw_urgent="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" set "$raw_urgent" done
out6="$(bash "$DEPUTY" list)"
# Both items should still have their IDs after regroup
assert_contains "$out6" "done|P0|" "regroup: P0 item preserved with id"
assert_contains "$out6" "waiting|P2|" "regroup: P2 item preserved with id"

# ── deputy run <id> ───────────────────────────────────────────────────────────
setup_repo
bash "$DEPUTY" add "low prio"  --p2
bash "$DEPUTY" add "high prio" --p0
# list to allocate ids (low=1, high=2)
bash "$DEPUTY" list >/dev/null

ORCH="$(mktemp)"
cat > "$ORCH" <<'ORCHEOF'
#!/usr/bin/env bash
# record which item we got
printf '%s\n' "$1" > "${ORCH_LOG:-/dev/null}"
bash "$DEPUTY" set "$1" done >/dev/null 2>&1 || true
ORCHEOF
chmod +x "$ORCH"

ORCH_LOG="$(mktemp)"
# Run item id=1 (low prio) bypassing priority
out7="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" ORCH_LOG="$ORCH_LOG" DEPUTY_AVAIL="claude,gemini" DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run 1 2>&1)"
item_ran="$(cat "$ORCH_LOG")"
# Item 1 (low prio) should have run, not item 2 (high prio)
assert_contains "$item_ran" "low prio" "run <id> targeted low-prio item directly"
assert_contains "$(bash "$DEPUTY" list)" "done||1|low prio" "run <id> marks targeted item done"
assert_contains "$(bash "$DEPUTY" list)" "waiting|P0|2|high prio" "run <id> leaves other item untouched"
rm -f "$ORCH_LOG"

# run <id> with leading # (deputy run '#1')
setup_repo
bash "$DEPUTY" add "hash id test" --p1
bash "$DEPUTY" list >/dev/null
ORCH_LOG2="$(mktemp)"
DEPUTY_ORCHESTRATOR_CMD="$ORCH" ORCH_LOG="$ORCH_LOG2" DEPUTY_AVAIL="claude,gemini" DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run '#1' 2>&1 || true
assert_contains "$(bash "$DEPUTY" list)" "done|P1|1|hash id test" "run '#1' accepted with leading hash"
rm -f "$ORCH_LOG2"

# run <id> unknown → non-zero + message
setup_repo
bash "$DEPUTY" add "only item"
bash "$DEPUTY" list >/dev/null
out8="$(bash "$DEPUTY" run 99 2>&1)"; rc8=$?
assert_eq "$rc8" "1" "run unknown id → exit 1"
assert_contains "$out8" "no item with id 99" "run unknown id → error message"

# run <id> on done item → non-zero + message
setup_repo
bash "$DEPUTY" add "already done"
bash "$DEPUTY" list >/dev/null
raw_done="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" set "$raw_done" done
out9="$(bash "$DEPUTY" run 1 2>&1)"; rc9=$?
assert_eq "$rc9" "1" "run done id → exit 1"
assert_contains "$out9" "item 1 is done" "run done id → error message"

# run <id> on running item → non-zero
setup_repo
bash "$DEPUTY" add "currently running"
bash "$DEPUTY" list >/dev/null
raw_run="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" set "$raw_run" running
out10="$(bash "$DEPUTY" run 1 2>&1)"; rc10=$?
assert_eq "$rc10" "1" "run running id → exit 1"
assert_contains "$out10" "item 1 is running" "run running id → error message"

# non-integer id → non-zero + message
setup_repo
bash "$DEPUTY" add "any item"
out11="$(bash "$DEPUTY" run abc 2>&1)"; rc11=$?
assert_eq "$rc11" "2" "run non-integer id → exit 2"
assert_contains "$out11" "id must be an integer" "run non-integer → error message"

# run (no arg) still picks by priority (regression)
setup_repo
bash "$DEPUTY" add "low priority"  --p2
bash "$DEPUTY" add "high priority" --p0
bash "$DEPUTY" list >/dev/null
ORCH_LOG3="$(mktemp)"
DEPUTY_ORCHESTRATOR_CMD="$ORCH" ORCH_LOG="$ORCH_LOG3" DEPUTY_AVAIL="claude,gemini" DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run --once 2>&1 || true
item_ran3="$(cat "$ORCH_LOG3")"
assert_contains "$item_ran3" "high priority" "run no-arg still picks highest priority"
rm -f "$ORCH_LOG3" "$ORCH"

printf '=== test_item_ids done ===\n'
TESTEOF
chmod +x /home/tong/src/tonychen15/deputy/tests/test_item_ids.sh
```

- [ ] **Step 1.2: Run the test to confirm it fails**

```bash
cd /home/tong/src/tonychen15/deputy && bash tests/test_item_ids.sh 2>&1 | head -60
```

Expected: Multiple FAIL lines (parse returns 3 fields not 4, allocate_ids doesn't exist, etc.)

---

## Task 2: Extend `_parse_item` to recognize `[#N]` in the tag zone

**Files:**
- Modify: `bin/deputy.sh` — `_parse_item` and `_serialize_item` functions

The key constraint: `[#N]` is only recognized immediately after the status symbol + optional `[Pn]` tag. Once the description body starts, any `[#digits]` is treated as part of the text.

Current `_parse_item` signature: produces `state|priority|description`
New signature: produces `state|priority|id|description`

Current `_serialize_item` signature: `(state, priority, description)` → canonical line
New signature: `(state, priority, id, description)` → canonical line (with `[#N]` after `[Pn]`)

- [ ] **Step 2.1: Update `_parse_item`**

Find the current function in `bin/deputy.sh` (lines ~58–76) and replace with:

```bash
# Parse one raw line -> "state|priority|id|description". Lenient: accepts an optional
# space after the status prefix (so both `#[P0] x` and `# [P0] x` parse the same).
# [#N] is recognized ONLY in the tag zone (immediately after status + optional [Pn]),
# never inside the description body.
_parse_item() {
  local line="$1" state="waiting" prio="" id="" desc=""
  line="${line#"${line%%[![:space:]]*}"}"          # left-trim
  if [[ "$line" =~ ^([~@?#!%=^])[[:space:]]*(.*)$ ]]; then
    case "${BASH_REMATCH[1]}" in
      '~') state=triaging ;;  '@') state=running ;;    '?') state=surfaced ;;
      '#') state=done ;;      '!') state=failed ;;
      '%') state=cancelled ;; '=') state=duplicate ;; '^') state=paused ;;
    esac
    line="${BASH_REMATCH[2]}"
  fi
  # Tag zone: consume [Pn] and [#N] in either order (both optional).
  # We consume at most one [Pn] and one [#N]; stop as soon as neither matches.
  local consumed=1
  while [[ "$consumed" -eq 1 ]]; do
    consumed=0
    if [[ -z "$prio" && "$line" =~ ^\[(P[0-2])\][[:space:]]*(.*) ]]; then
      prio="${BASH_REMATCH[1]}"; line="${BASH_REMATCH[2]}"; consumed=1
    fi
    if [[ -z "$id" && "$line" =~ ^\[#([0-9]+)\][[:space:]]*(.*) ]]; then
      id="${BASH_REMATCH[1]}"; line="${BASH_REMATCH[2]}"; consumed=1
    fi
  done
  desc="$line"
  printf '%s|%s|%s|%s' "$state" "$prio" "$id" "$desc"
}
```

- [ ] **Step 2.2: Update `_serialize_item`**

Find the current function (lines ~79–94) and replace with:

```bash
# Build a canonical line from (state, priority, id, description).
# Canonical order: <status>[Pn][#N] description
# The status symbol directly abuts what follows (no space): `#[P0][#3] x`, `[#7] x`, `Plain`.
_serialize_item() {
  local state="$1" prio="$2" id="$3" desc="$4" prefix="" body=""
  case "$state" in
    waiting)   prefix="" ;;  triaging)  prefix="~" ;; running)   prefix="@" ;;
    surfaced)  prefix="?" ;; done)      prefix="#" ;; failed)    prefix="!" ;;
    cancelled) prefix="%" ;; duplicate) prefix="=" ;; paused)    prefix="^" ;;
    *) printf 'deputy: bad state: %s\n' "$state" >&2; return 1 ;;
  esac
  body=""
  [[ -n "$prio" ]] && body="${body}[${prio}]"
  [[ -n "$id"   ]] && body="${body}[#${id}]"
  if [[ -n "$body" ]]; then
    [[ -n "$desc" ]] && body="${body} ${desc}"
  else
    body="$desc"
  fi
  printf '%s%s' "$prefix" "$body"
}
```

- [ ] **Step 2.3: Update `main()` to pass 4 args to `_serialize_item`**

The `_serialize` subcommand in `main()` currently calls `_serialize_item "${2:-}" "${3:-}" "${4:-}"`. It needs to accept 4 args now:

```bash
_serialize) _serialize_item "${2:-}" "${3:-}" "${4:-}" "${5:-}" && printf '\n' || return 1 ;;
```

- [ ] **Step 2.4: Run `test_item_ids.sh` to check parse/serialize tests pass**

```bash
cd /home/tong/src/tonychen15/deputy && bash tests/test_item_ids.sh 2>&1 | head -40
```

Expected: parse/serialize tests pass; `_allocate_ids` and `run <id>` tests still fail.

---

## Task 3: Fix all callers of `_parse_item` and `_serialize_item` in `deputy.sh`

**Files:**
- Modify: `bin/deputy.sh` — every place that calls `_parse_item` or `_serialize_item` or destructures the result

`_parse_item` now returns 4 fields (`state|prio|id|desc`). All callers that do `${parsed#*|*|}` to get the description will now get `id|description` instead. Fix every call site.

- [ ] **Step 3.1: Audit all `_parse_item` call sites**

```bash
grep -n '_parse_item\|_serialize_item\|parsed.*#\*|\*|' /home/tong/src/tonychen15/deputy/bin/deputy.sh
```

The key callers are:
- `cmd_list` — calls `_parse_item` and prints, no destructuring
- `cmd_status` — extracts `state` only (`${parsed%%|*}`) — OK unchanged
- `cmd_pick` — extracts `state`, then `prio`; must now handle 4-field format
- `_desc_exists` — extracts description via `${parsed#*|*|}` — must change
- `cmd_add` — no direct parse, but calls `_serialize_item` via `_append_item`
- `cmd_set` — parses `$from`, extracts `prio` and `desc`; must handle 4th field
- `cmd_claim` — same as `cmd_set`
- `_revert_to_waiting` — same
- `cmd_reflect` — extracts `state`, `prio`, `desc`
- `_regroup_backlog` — extracts `state` only — OK

- [ ] **Step 3.2: Fix `cmd_pick` — extract `prio` from 4-field parse**

Current code:
```bash
prio="${parsed#*|}"; prio="${prio%%|*}"
```
This extracts the second field (after first `|`). With 4 fields `state|prio|id|desc`, the second field is still `prio`. This is **correct** — no change needed here.

- [ ] **Step 3.3: Fix `_desc_exists` — extract description from 4-field parse**

Current code:
```bash
[[ "${parsed#*|*|}" == "$want" ]] && return 0
```
`${parsed#*|*|}` strips up to the second `|`, yielding `id|description`. Must strip 3 delimiters:
```bash
local _rest="${parsed#*|}"; _rest="${_rest#*|}"; _rest="${_rest#*|}"
[[ "$_rest" == "$want" ]] && return 0
```

- [ ] **Step 3.4: Fix `cmd_set` — extract `prio` and `desc` from 4-field parse**

Current:
```bash
prio="${parsed#*|}"; prio="${prio%%|*}"
desc="${parsed#*|*|}"
```
Fix `desc` extraction (strip 3 delimiters):
```bash
prio="${parsed#*|}"; prio="${prio%%|*}"
local _id_rest="${parsed#*|}"; _id_rest="${_id_rest#*|}"; local _id="${_id_rest%%|*}"
desc="${_id_rest#*|}"
```

But we also need to preserve the `id` when we re-serialize! `cmd_set` currently: builds `to="$(_serialize_item "$newstate" "$prio" "$desc")"`. Must become: `to="$(_serialize_item "$newstate" "$prio" "$_id" "$desc")"`.

- [ ] **Step 3.5: Fix `cmd_claim` — same pattern as `cmd_set`**

```bash
prio="${parsed#*|}"; prio="${prio%%|*}"
local _cid_rest="${parsed#*|}"; _cid_rest="${_cid_rest#*|}"; local _cid="${_cid_rest%%|*}"
desc="${_cid_rest#*|}"
to="$(_serialize_item running "$prio" "$_cid" "$desc")"
```

- [ ] **Step 3.6: Fix `_revert_to_waiting` — same pattern**

```bash
prio="${parsed#*|}"; prio="${prio%%|*}"
local _rid_rest="${parsed#*|}"; _rid_rest="${_rid_rest#*|}"; local _rid="${_rid_rest%%|*}"
desc="${_rid_rest#*|}"
to="$(_serialize_item waiting "$prio" "$_rid" "$desc")"
```

- [ ] **Step 3.7: Fix `cmd_reflect` — extract `prio` and `desc` from 4-field parse**

Current:
```bash
local rest="${parsed#*|}"
prio="${rest%%|*}"
desc="${parsed#*|*|}"
```
Fix:
```bash
local rest="${parsed#*|}"
prio="${rest%%|*}"
local _rrest="${rest#*|}"; local _rid="${_rrest%%|*}"; desc="${_rrest#*|}"
```
Note: `cmd_reflect` doesn't use `id` in its output, just `prio` and `desc` — the above extraction is sufficient.

- [ ] **Step 3.8: Fix `cmd_add` validation — check the description doesn't start with `[#`**

The existing validation `[[ "$text" =~ ^\[P[0-2]\] ]]` rejects descriptions that look like a priority tag. Add a check for `[#<digits>]` too, since a description starting with that would parse as an id-in-description-zone (which is harmless), but it's consistent to warn:

Actually per spec: "description may not begin with a status prefix or `[Px]` tag". No new restriction needed for `[#N]` in the description. Skip this.

- [ ] **Step 3.9: Run the full existing test suite (expect failures only in tests that assert exact BACKLOG lines)**

```bash
cd /home/tong/src/tonychen15/deputy && bash tests/run.sh 2>&1 | tail -30
```

Expected: Some failures in `test_parse.sh`, `test_pick.sh`, `test_claim.sh`, `test_regroup.sh`, `test_set.sh`, and `test_run.sh` because they use 3-field parse results or exact BACKLOG line strings. Those will be fixed in Task 6.

---

## Task 4: Implement `_allocate_ids`

**Files:**
- Modify: `bin/deputy.sh` — add `_allocate_ids` function; call it in every `_with_lock` block

`_allocate_ids` must run **inside** the flock (i.e., called from within `_do_*` functions that are already lock-held). It:
1. Scans ALL items (via `_each_item`) for the max existing `[#N]`.
2. Assigns sequential IDs to items with no ID, in file order.
3. Rewrites BACKLOG atomically only if something changed.

- [ ] **Step 4.1: Add `_allocate_ids` to `deputy.sh`**

Insert after `_regroup_backlog` (around line 160):

```bash
# Assign sequential [#N] IDs to any item that lacks one. Lock-held, idempotent,
# append-only: existing IDs are never changed. Writes back atomically only if
# something changed (so status/list calls are pure no-op after the first pass).
# Caller holds the lock.
_allocate_ids() {
  [[ -f "$BACKLOG" ]] || return 0
  # Pass 1: find max existing ID across ALL items (including done/failed/etc.)
  local max_id=0 raw parsed id
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"
    id="${parsed#*|}"; id="${id#*|}"; id="${id%%|*}"  # third field
    if [[ "$id" =~ ^[0-9]+$ && "$id" -gt "$max_id" ]]; then max_id="$id"; fi
  done < <(_each_item)

  # Pass 2: rewrite only items lacking an ID. Track whether anything changed.
  local changed=0 next_id=$(( max_id + 1 ))
  local tmp
  tmp="$(mktemp "$(dirname "$BACKLOG")/.backlog.tmp.XXXXXX")"
  chmod --reference="$BACKLOG" "$tmp" 2>/dev/null || chmod 644 "$tmp"

  # Rewrite the whole file, replacing unid'd item lines in-place.
  local line seen=0 mode=none
  if grep -qE '^[[:space:]]*##[[:space:]]+Items[[:space:]]*$' "$BACKLOG" 2>/dev/null; then mode=items
  elif grep -q -- '-->' "$BACKLOG" 2>/dev/null; then mode=comment
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Detect where the items section starts (copy header lines verbatim)
    if [[ "$seen" -eq 0 && "$mode" != "none" ]]; then
      printf '%s\n' "$line" >> "$tmp"
      if [[ "$mode" == "items" && "$line" =~ ^[[:space:]]*##[[:space:]]+Items[[:space:]]*$ ]]; then seen=1; fi
      [[ "$mode" == "comment" && "$line" == *'-->'* ]] && seen=1
      continue
    fi
    # In items section: skip blank lines (preserve) and process item lines
    if [[ -z "${line//[[:space:]]/}" ]]; then
      printf '%s\n' "$line" >> "$tmp"; continue
    fi
    # Check if this item line needs an ID
    parsed="$(_parse_item "$line")"
    id="${parsed#*|}"; id="${id#*|}"; id="${id%%|*}"
    if [[ -z "$id" ]]; then
      # Need to assign an ID
      local state="${parsed%%|*}"
      local prio="${parsed#*|}"; prio="${prio%%|*}"
      local desc_rest="${parsed#*|}"; desc_rest="${desc_rest#*|}"; desc_rest="${desc_rest#*|}"
      local new_line
      new_line="$(_serialize_item "$state" "$prio" "$next_id" "$desc_rest")"
      printf '%s\n' "$new_line" >> "$tmp"
      next_id=$(( next_id + 1 ))
      changed=1
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$BACKLOG"

  if [[ "$changed" -eq 1 ]]; then
    mv "$tmp" "$BACKLOG"
    _regroup_backlog
  else
    rm -f "$tmp"
  fi
}
```

- [ ] **Step 4.2: Call `_allocate_ids` inside every `_do_*` function that runs under the lock**

Add `_allocate_ids` as the **first** statement in each of these functions (before any other logic):

1. `_do_add()` — in `cmd_add`
2. `_do_set()` — in `cmd_set`
3. `_do_claim()` — in `cmd_claim`
4. `_do_recover()` — in `cmd_recover`
5. `_do_clean()` — in `cmd_clean`
6. `_do_write_learnings()` — in `cmd_reflect` (note: this is the apply path)

Also add `_allocate_ids` in non-locking read commands that call `_each_item`. These need a `_with_lock` wrapper for the allocation:

For `cmd_list`, `cmd_status`, `cmd_pick`, `cmd_review`, and `cmd_reflect` (read paths): wrap the allocation call in `_with_lock`:

```bash
# Add at the top of cmd_list (before the while loop):
_with_lock _allocate_ids

# Add at the top of cmd_status (before the while loop):
_with_lock _allocate_ids

# Add at the top of cmd_pick (before the while loop):
_with_lock _allocate_ids

# Add at the top of cmd_review (before the while loop):
_with_lock _allocate_ids

# Add at the top of cmd_reflect (before the while loop):
_with_lock _allocate_ids
```

For `cmd_run`: add `_with_lock _allocate_ids` near the top (after `cmd_recover`).

- [ ] **Step 4.3: Run `test_item_ids.sh` allocation tests**

```bash
cd /home/tong/src/tonychen15/deputy && bash tests/test_item_ids.sh 2>&1 | grep -E 'alloc|FAIL|done'
```

Expected: allocation tests pass; `run <id>` tests still fail.

---

## Task 5: Implement `deputy run <id>`

**Files:**
- Modify: `bin/deputy.sh` — `cmd_run` function

The current `cmd_run` checks for `--once` flag. Add id handling: if the first non-flag argument is a non-empty value that isn't `--once`, treat it as an ID.

- [ ] **Step 5.1: Update `cmd_run` to handle optional `<id>` argument**

Replace the `cmd_run` function with:

```bash
# One tick: claim the top item and hand it to the orchestrator. --once = no loop.
# If an integer id is given (deputy run <id> or deputy run '#<id>'), run that
# specific item bypassing priority, then return.
cmd_run() {
  local once=0 target_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --once) once=1; shift ;;
      '#'*) target_id="${1#'#'}"; shift ;;
      *)
        if [[ "$1" =~ ^[0-9]+$ ]]; then
          target_id="$1"; shift
        elif [[ -n "$1" ]]; then
          printf 'deputy: run: id must be an integer (got: %s)\n' "$1" >&2; return 2
        else
          shift
        fi
        ;;
    esac
  done

  # Validate id if given (strip any leading # already handled above)
  if [[ -n "$target_id" ]]; then
    # Strip leading # in case it wasn't stripped above (e.g. passed as '#7')
    target_id="${target_id#'#'}"
    if [[ ! "$target_id" =~ ^[0-9]+$ ]]; then
      printf 'deputy: run: id must be an integer (got: %s)\n' "$target_id" >&2; return 2
    fi
  fi

  cmd_recover >/dev/null 2>&1 || true
  if _live_claim_exists; then return 0; fi
  _cron_enabled && _set_cron "" >/dev/null 2>&1 || true

  local cap; cap="$(_config_get max_items)"; cap="${cap:-0}"; [[ "$cap" =~ ^[0-9]+$ ]] || cap=0
  local processed=0 item avail decision running_line log rc outcome reset

  # ── Targeted run: find item by id and run it ──────────────────────────────
  if [[ -n "$target_id" ]]; then
    _with_lock _allocate_ids
    # Find the item with this id
    local found_line="" found_state=""
    while IFS= read -r raw; do
      local p; p="$(_parse_item "$raw")"
      local raw_id="${p#*|}"; raw_id="${raw_id#*|}"; raw_id="${raw_id%%|*}"
      if [[ "$raw_id" == "$target_id" ]]; then
        found_line="$raw"
        found_state="${p%%|*}"
        break
      fi
    done < <(_each_item)

    if [[ -z "$found_line" ]]; then
      printf 'deputy: no item with id %s\n' "$target_id" >&2; return 1
    fi
    if [[ "$found_state" != "waiting" && "$found_state" != "paused" ]]; then
      printf 'deputy: item %s is %s, not runnable\n' "$target_id" "$found_state" >&2; return 1
    fi

    avail="$(_availability)"; decision="$(_route orchestrate "$avail")"
    if [[ "$decision" != "claude" ]]; then
      _cron_enabled && cmd_cron --reschedule "orchestrator unavailable" >/dev/null 2>&1 || true
      return 0
    fi
    cmd_claim "$found_line" --pid "$$" >/dev/null 2>&1 || return 1
    running_line="$(cat "$STATE_DIR/$$.claim" 2>/dev/null || printf '%s' "$found_line")"
    log="$(mktemp)"
    set +e
    _spawn_orchestrator "$running_line" "$decision" >"$log" 2>&1
    rc=$?
    set -e
    rm -f "$STATE_DIR/$$.claim" 2>/dev/null || true
    cat "$log"
    outcome="$(_detect_outcome claude "$rc" "$log")"
    if [[ "$outcome" == "quota_exhausted" ]]; then
      reset="$(grep -iE 'reset|limit' "$log" | head -3)"; rm -f "$log"
      _with_lock _revert_to_waiting "$running_line" >/dev/null 2>&1 || true
      _cron_enabled && cmd_cron --reschedule "$reset" >/dev/null 2>&1 || true
      printf 'deputy: Claude session limit reached — rescheduled for reset; stopping this cycle.\n'
      return 0
    fi
    rm -f "$log"
    _cron_enabled && _set_cron "*/15 * * * *" >/dev/null 2>&1 || true
    return 0
  fi

  # ── Normal priority-driven run ────────────────────────────────────────────
  while :; do
    item="$(cmd_pick)"; [[ -n "$item" ]] || break
    avail="$(_availability)"; decision="$(_route orchestrate "$avail")"
    if [[ "$decision" != "claude" ]]; then
      _cron_enabled && cmd_cron --reschedule "orchestrator unavailable" >/dev/null 2>&1 || true
      return 0
    fi
    cmd_claim "$item" --pid "$$" >/dev/null 2>&1 || break
    running_line="$(cat "$STATE_DIR/$$.claim" 2>/dev/null || printf '%s' "$item")"
    log="$(mktemp)"
    set +e
    _spawn_orchestrator "$running_line" "$decision" >"$log" 2>&1
    rc=$?
    set -e
    rm -f "$STATE_DIR/$$.claim" 2>/dev/null || true
    cat "$log"
    outcome="$(_detect_outcome claude "$rc" "$log")"
    if [[ "$outcome" == "quota_exhausted" ]]; then
      reset="$(grep -iE 'reset|limit' "$log" | head -3)"; rm -f "$log"
      _with_lock _revert_to_waiting "$running_line" >/dev/null 2>&1 || true
      _cron_enabled && cmd_cron --reschedule "$reset" >/dev/null 2>&1 || true
      printf 'deputy: Claude session limit reached — rescheduled for reset; stopping this cycle.\n'
      return 0
    fi
    rm -f "$log"
    processed=$((processed + 1))
    [[ "$once" -eq 1 ]] && break
    [[ "$cap" -gt 0 && "$processed" -ge "$cap" ]] && break
  done
  _cron_enabled && _set_cron "*/15 * * * *" >/dev/null 2>&1 || true
  return 0
}
```

- [ ] **Step 5.2: Update `usage()` to document `run [<id>]`**

Find the `run [--once]` line in usage and change to:

```
  run [<id>] [--once]             work the backlog: claim the top item, run the orchestrator.
                                  if <id> given (integer; '#7' also accepted), run that
                                  specific item bypassing priority order (targeted, one item only).
```

- [ ] **Step 5.3: Run `test_item_ids.sh` and check all `run <id>` tests pass**

```bash
cd /home/tong/src/tonychen15/deputy && bash tests/test_item_ids.sh 2>&1
```

Expected: All tests in `test_item_ids.sh` pass.

---

## Task 6: Fix existing tests that assert exact BACKLOG line contents

**Files:**
- Modify: `tests/test_parse.sh`
- Modify: `tests/test_pick.sh`
- Modify: `tests/test_claim.sh`
- Modify: `tests/test_regroup.sh`
- Modify: `tests/test_run.sh`
- Modify: `tests/test_add.sh`
- Modify: `tests/test_set.sh` (check for issues)

The impact:
1. `_parse_item` now returns 4 fields — existing tests that check `state|prio|desc` now see `state|prio|id|desc`. Tests using `assert_eq` on exact parse output will fail.
2. `_serialize_item` now takes 4 args — the test invocation `ser <state> <prio> <desc>` passes only 3 args, so `desc` lands in `id` position and the 4th arg (`desc`) is empty. All serialize tests will produce wrong output.
3. Tests that write raw item lines to BACKLOG and then check them with `assert_eq "$(bash "$DEPUTY" pick)" "[P0] top"` will fail because `pick` returns the actual BACKLOG line which now has `[#N]` in it.
4. Tests that call `deputy claim "<exact line>"` or `deputy set "<exact line>"` will fail if the line in BACKLOG has been modified to include `[#N]` that the test doesn't know about. **Solution:** Since these tests write raw lines directly to BACKLOG (bypassing `deputy add`), allocation will assign IDs on the first `_with_lock`-guarded command. We need to either: (a) use `deputy add` + `deputy pick` to get the real line, OR (b) pre-write lines with IDs already in them.

**Approach:** For each test file, identify whether it's doing raw BACKLOG writes or going through `deputy add`, and fix accordingly.

- [ ] **Step 6.1: Fix `test_parse.sh` — update the 4-field parse assertions**

The file currently checks `"waiting|P0|Fix it"` etc. Each becomes `"waiting|P0||Fix it"` (empty id field for legacy lines with no `[#N]`).

Also the `ser()` helper calls `bash "$DEPUTY" _serialize "$1" "$2" "$3"` — needs a 4th arg:
```bash
ser() { bash "$DEPUTY" _serialize "$1" "$2" "$3" "$4"; }
```

All existing `ser` calls pass 3 args (`state prio desc`) — they need a 4th arg for id. For tests that verify the old behavior (no id in output), pass `''` as the id:
```bash
assert_eq "$(ser running P0 '' 'Fix it')"       "@[P0] Fix it"     "serialize running P0"
```

Update ALL assertions in `test_parse.sh`:

Parse assertions — add empty `id` field:
```
"waiting|P0|Fix it"         → "waiting|P0||Fix it"
"running|P1|Build it"       → "running|P1||Build it"
"done||Done thing"          → "done|||Done thing"
"waiting||Plain waiting"    → "waiting|||Plain waiting"
"surfaced|P2|Ask me"        → "surfaced|P2||Ask me"
"failed||Broke"             → "failed|||Broke"
"running||mention the user" → "running|||mention the user"
"running||"                 → "running|||"
"triaging|P2|"              → "triaging|P2||"
"cancelled||Dropped"        → "cancelled|||Dropped"
"cancelled|P1|Skip this"    → "cancelled|P1||Skip this"
"duplicate||Dup of #3"      → "duplicate|||Dup of #3"
"duplicate|P0|Same as X"    → "duplicate|P0||Same as X"
"paused||Interrupted"       → "paused|||Interrupted"
"paused|P1|Paused job"      → "paused|P1||Paused job"
```

List tests — the `cmd_list` output also changes to 4-field:
```
"waiting|P0|one"   → "waiting|P0||one"
"triaging|P1|two"  → "triaging|P1||two"
"done||three"      → "done|||three"
```

Serialize tests — add `''` as the id arg:
```bash
ser() { bash "$DEPUTY" _serialize "$1" "$2" "$3" "$4"; }
assert_eq "$(ser running P0 '' 'Fix it')"       "@[P0] Fix it"     "serialize running P0"
assert_eq "$(ser waiting '' '' 'Plain')"         "Plain"             "serialize waiting untagged"
# ... all others with '' as 3rd arg
```

- [ ] **Step 6.2: Fix `test_pick.sh` — update exact-line expectations**

The problem: `test_pick.sh` writes raw lines to BACKLOG (`printf '[P0] top\n' >> ...`) then calls `deputy pick` and expects `"[P0] top"`. After allocation runs (triggered by `pick`), the line becomes `[P0][#N] top` and `pick` returns the updated line.

**Fix strategy:** After each `printf` block writes raw lines, trigger allocation explicitly by calling `deputy list > /dev/null`, then use `deputy pick` and capture the result. The assertions need to check CONTENT not exact line format. Change to `assert_contains` where possible, or rebuild the expected value dynamically.

Best approach: in each `setup_repo` block, add `bash "$DEPUTY" list >/dev/null` after the `printf` writes to force allocation, then get the actual line via `pick` and compare with `assert_contains`.

```bash
# BEFORE:
printf '%s\n' 'untagged old' '[P2] important' '@ [P0] already running' '[P1] urgent' '[P0] top' \
  >> "$DEPUTY_ROOT/BACKLOG.md"
assert_eq "$(bash "$DEPUTY" pick)" "[P0] top" "pick chooses highest priority waiting"

# AFTER:
printf '%s\n' 'untagged old' '[P2] important' '@ [P0] already running' '[P1] urgent' '[P0] top' \
  >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null  # trigger allocation
pick_out="$(bash "$DEPUTY" pick)"
assert_contains "$pick_out" "[P0]" "pick chooses highest priority waiting"
assert_contains "$pick_out" "top"  "pick chooses 'top' item"
```

Do this for all assertions in `test_pick.sh`.

- [ ] **Step 6.3: Fix `test_claim.sh` — exact line match**

`test_claim.sh` does `bash "$DEPUTY" claim "[P0] first" --pid "$LIVE"` where `[P0] first` is the raw written line. After allocation, the line in BACKLOG is `[P0][#1] first`. The claim command does an exact line match, so it will fail.

Fix: After writing raw lines, trigger allocation, then get the actual line to use:
```bash
printf '%s\n' '[P0] first' '[P1] second' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null  # force allocation
first_line="$(bash "$DEPUTY" pick)"  # gets [P0][#1] first

bash "$DEPUTY" claim "$first_line" --pid "$LIVE"; rc=$?
assert_eq "$rc" "0" "claim succeeds when free"
assert_contains "$(bash "$DEPUTY" list)" "running|P0|" "claimed item is running"
# claim file holds the running form
running_form="$(cat "$DEPUTY_ROOT/.deputy/$LIVE.claim")"
assert_contains "$running_form" "@[P0]" "claim file holds running line"
assert_contains "$running_form" "first" "claim file has description"
```

- [ ] **Step 6.4: Fix `test_regroup.sh` — exact-line state transitions**

The file calls `bash "$DEPUTY" set "[P1] alpha" done`. After allocation, the line is `[P1][#N] alpha`. Fix: trigger allocation first, then capture the actual line.

```bash
printf '%s\n' '[P1] alpha' '[P2] beta' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null  # trigger allocation
alpha_raw="$(bash "$DEPUTY" list | grep 'alpha')"
# Extract the state|prio|id|desc and reconstruct the BACKLOG line
# Simpler: just pick the raw line from BACKLOG
alpha_line="$(grep 'alpha' "$DEPUTY_ROOT/BACKLOG.md")"
bash "$DEPUTY" set "$alpha_line" done
```

Similarly for the `@[P1] running one` direct write:
```bash
printf '%s\n' '[P2] waiting one' '@[P1] running one' '#[P0] done one' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null  # trigger allocation; rewriting @-prefixed line too
running_line="$(grep '@' "$DEPUTY_ROOT/BACKLOG.md" | head -1)"
bash "$DEPUTY" set "$running_line" running
```

For the legacy format test (no `## Items` header), `_allocate_ids` has a mode=none path that still writes through the file. But `_regroup_backlog` no-ops on files without `## Items`. The legacy format test will be fine as long as item lines still appear in the file. The assertion uses `assert_contains "$after" "task one"` which is fine.

- [ ] **Step 6.5: Fix `test_run.sh` — claim file content and list assertions**

In `test_run.sh`, there are assertions like:
- `assert_contains "$(bash "$DEPUTY" list)" "done|P0|do a thing"` → becomes `"done|P0|1|do a thing"` (4-field). Use `assert_contains "$out" "done|P0|"` + `assert_contains "$out" "do a thing"`.
- The existing `bash "$DEPUTY" add "do a thing" --p0` + `run --once` flow: after `add`, allocation fires in `_do_add`. The `pick` inside `run` returns the allocated line. The orchestrator receives the running form. These should work without changes IF the `done|P0|do a thing` assertion is updated to `done|P0|1|do a thing`.

Also check:
- `assert_contains "$(bash "$DEPUTY" list)" "waiting|P1|later"` → `"waiting|P1|1|later"`.
- The `waiting|P0` count assertions use `grep -c 'waiting|P0'` which is fine as a substring.

- [ ] **Step 6.6: Fix `test_add.sh` — 4-field list output**

Tests like:
```bash
assert_contains "$out" "waiting||First task"
```
Become:
```bash
assert_contains "$out" "waiting||1|First task"   "add untagged"
assert_contains "$out" "waiting|P0|2|Urgent one" "add --p0"
```

Note: the IDs depend on add order, so verify the expected IDs match insertion order.

The autorun test section writes `@[P0] already running` directly to BACKLOG without going through `deputy add`, and then does `deputy add "new lower"`. After allocation, the running item gets an ID too. Update:
```bash
assert_contains "$(bash "$DEPUTY" list)" "waiting|P1|" "add queues item but does not run when claim exists"
assert_contains "$(bash "$DEPUTY" list)" "new lower"   "add queues item description correct"
```

- [ ] **Step 6.7: Check `test_set.sh` and `test_status.sh` for failures**

`test_set.sh` likely uses exact line matching for `deputy set "<line>" <state>`. Check and fix similarly.

```bash
cd /home/tong/src/tonychen15/deputy && bash tests/test_set.sh 2>&1
```

- [ ] **Step 6.8: Run full suite and verify green**

```bash
cd /home/tong/src/tonychen15/deputy && bash tests/run.sh 2>&1
echo "exit=$?"
```

Expected: All tests pass. exit=0.

---

## Task 7: Update `SKILL.md` — slug uniqueness + CLI reference

**Files:**
- Modify: `skills/deputy/SKILL.md`

Per spec refinement 4: the slug derivation in §1 Triage must fold the item ID into the slug so two items with identical descriptions don't collide in `.deputy/`.

- [ ] **Step 7.1: Update the slug-derivation rule in `SKILL.md`**

Find the sentence:
```
Derive a **slug** from the description: kebab-case, ~6 words max, plus a short hash for
uniqueness (e.g. `fix-login-bug-a1b2`). Use it for the branch and the questions file.
```

Replace with:
```
Derive a **slug** from the description: kebab-case, ~6 words max, suffixed with the
item's `[#N]` ID (e.g. `fix-login-bug-7`). If no ID is available (pre-allocation),
append a short hash instead (e.g. `fix-login-bug-a1b2`). The ID suffix guarantees slug
uniqueness — two items with identical descriptions never share a branch or questions file.
```

- [ ] **Step 7.2: Update the CLI quick reference in `SKILL.md`**

Find the `run` entry in the public CLI reference section and update:
```
`deputy run [<id>] [--once]` — run the top priority item; if `<id>` given, run that specific item bypassing priority (targeted, one-shot).
```

---

## Task 8: Gemini review + commit

- [ ] **Step 8.1: Stage all changed files**

```bash
cd /home/tong/src/tonychen15/deputy
git add bin/deputy.sh tests/test_item_ids.sh tests/test_parse.sh tests/test_pick.sh \
        tests/test_claim.sh tests/test_regroup.sh tests/test_run.sh tests/test_add.sh \
        tests/test_set.sh skills/deputy/SKILL.md docs/superpowers/plans/2026-06-09-deputy-item-ids-and-run-by-id.md
```

- [ ] **Step 8.2: Run Gemini review**

```bash
cd /home/tong/src/tonychen15/deputy
gemini -p "Review as a staff engineer, flag CRITICAL/WARNING only, end with exactly APPROVED or NEEDS_WORK: $(git diff --cached)"
```

- [ ] **Step 8.3: Fix any CRITICAL/WARNING items, re-stage, re-review until APPROVED**

- [ ] **Step 8.4: Commit on `feat/item-ids-run-by-id`**

```bash
cd /home/tong/src/tonychen15/deputy
git commit -m "$(cat <<'EOF'
feat: add stable item IDs ([#N]) and deputy run <id>

Every backlog item gets a lazy, lock-held, idempotent [#N] tag
(allocated append-only; never recycled). `deputy run <id>` targets
a specific item bypassing priority. Parse/serialize extended to a
4-field state|priority|id|description contract.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 8.5: Verify final suite**

```bash
cd /home/tong/src/tonychen15/deputy && bash tests/run.sh; echo exit=$?
```

Expected: exit=0

---

## Self-Review Against Spec

**Spec coverage check:**

| Requirement | Task(s) | Status |
|-------------|---------|--------|
| `[#N]` grammar: parse in tag zone only | Task 2 | ✓ |
| `[#5]` in description not parsed as id | Task 2 test | ✓ |
| Either order `[P1][#7]`/`[#7][P1]` | Task 2 | ✓ |
| `_serialize_item` emits canonical order | Task 2 | ✓ |
| Legacy lines (no `[#N]`) parse fine | Task 2 test | ✓ |
| `_allocate_ids`: lazy, lock-held, idempotent | Task 4 | ✓ |
| Append-only (no reuse/change of existing IDs) | Task 4 | ✓ |
| Called at start of add/run/pick/status/list/set/claim/recover/review/cron tick | Task 4.2 | ✓ |
| `deputy run <id>` targets by id | Task 5 | ✓ |
| Unknown id → non-zero + message | Task 5 (test Task 1) | ✓ |
| Not runnable state → non-zero + message | Task 5 (test Task 1) | ✓ |
| `#7` form accepted | Task 5 | ✓ |
| Non-integer → error | Task 5 | ✓ |
| `run` (no arg) unchanged | Task 5 | ✓ |
| Slug uniqueness with ID suffix | Task 7 | ✓ |
| Help documents `run [<id>]` | Task 5.2 | ✓ |
| Tests: allocation sequential/idempotent/add→max+1/no-reuse-after-done | Task 1 | ✓ |
| Tests: parse round-trip incl. desc `[#5]` and both tag orders and legacy | Task 1 | ✓ |
| Tests: regroup preserves IDs | Task 1 | ✓ |
| Tests: `run <id>` targeted/unknown/done/running/`#7`/non-integer | Task 1 | ✓ |
| Tests: `run` no-arg priority-picks (regression) | Task 1 | ✓ |
| Existing tests updated for 4-field output | Task 6 | ✓ |
| Commit on `feat/item-ids-run-by-id` only | Task 8 | ✓ |

**Placeholder scan:** No TBD, no vague "handle edge cases" — all code is spelled out.

**Type/signature consistency:**
- `_parse_item` → `state|prio|id|desc` (4 fields) used consistently
- `_serialize_item(state, prio, id, desc)` — 4 args — all callers updated
- `_allocate_ids()` — no args, called lock-held — consistent
- `cmd_run` now accepts optional `<id>` before or after `--once` — documented in usage
