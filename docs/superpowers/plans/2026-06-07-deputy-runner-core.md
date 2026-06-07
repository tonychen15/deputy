# Deputy Runner Core — Implementation Plan (Plan 1 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure-bash queue engine (`bin/deputy.sh` + the `BACKLOG.md` model) that parses the backlog, picks the highest-priority waiting item, mutates item state atomically by exact-line match, enforces serial ownership via claim files, and recovers stale claims.

**Architecture:** A single stateless bash script operating on two paths under a repo root (`$DEPUTY_ROOT`): the human-editable `BACKLOG.md` and a `.deputy/` state dir (`lock`, `*.claim`). All queue mutations are serialized by a short-held `flock` and written atomically (tmpfile + `mv`). Ownership of a running item is a `<pid>.claim` file plus an `@` status marker; serial execution is enforced by refusing to claim while any live claim exists. This is a direct descendant of `research.sh`.

**Tech Stack:** Bash 5.2, `flock`, coreutils (`mktemp`, `mv`, `grep`). Tests are a dependency-free pure-bash harness (no `bats`).

**Scope (this plan):** queue data model + `add`, `list`, `status`, `pick`, `set`, `claim`, `recover`. **Out of scope** (later plans): cron, LLM/CLI adapters, routing, the orchestrator skill, git worktrees, `install.sh`, hooks.

**Conventions used throughout this plan:**
- Run all commands from the repo root (`/home/tong/src/tonychen15/jobflow`).
- The runner resolves its root from `$DEPUTY_ROOT` (default: `git rev-parse --show-toplevel`, else `$PWD`). Tests set `$DEPUTY_ROOT` to a temp dir.
- **Status prefixes:** waiting = *(none)*, `~` triaging, `@` running, `?` surfaced, `#` done, `!` failed.
- **Priority tags:** `[P0]` `[P1]` `[P2]`, absent = lowest. Rank P0<P1<P2<none; FIFO within a rank (file order).
- **Canonical line:** `<prefix?> <[Px]?> <description>` — single spaces, no leading pad (e.g. `@ [P0] Fix it`, `# Done thing`, `[P2] Later`, `Plain waiting`).

---

## File Structure

| File | Responsibility |
|---|---|
| `bin/deputy.sh` | the runner: arg dispatch, parsing, serialization, all subcommands |
| `templates/BACKLOG.md` | seed queue with the legend header (also used by tests) |
| `tests/lib.sh` | pure-bash assert harness + `setup_repo` helper |
| `tests/test_*.sh` | one test file per behavior |
| `tests/run.sh` | runs every `tests/test_*.sh`, aggregates pass/fail |
| `.gitignore` | ignore `.deputy/` runtime state |

---

## Task 1: Test harness + backlog template

**Files:**
- Create: `templates/BACKLOG.md`
- Create: `tests/lib.sh`
- Create: `tests/run.sh`
- Create: `tests/test_harness.sh`

- [ ] **Step 1: Write the backlog template**

Create `templates/BACKLOG.md`:

```markdown
# Deputy Backlog
<!-- LEGEND — do not edit this block. Everything below the closing arrow is an item.
Status (line prefix):  (none) waiting   ~ triaging   @ running   ? surfaced   # done   ! failed
Priority (tag):        [P0] urgent+important   [P1] urgent   [P2] important   (none) lowest lane
Order:                 P0 > P1 > P2 > untagged ; FIFO within a lane
Line format:           <status?> <priority?> <description>
Add an item:           deputy "your task" [-ui | -u | -i]    — or just add a line below
-->

```

- [ ] **Step 2: Write the test harness library**

Create `tests/lib.sh`:

```bash
# tests/lib.sh — dependency-free bash test harness.
# Each test file sources this, calls setup_repo, makes assertions, and exits
# via the EXIT trap which prints a summary and sets the exit code.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPUTY="$REPO/bin/deputy.sh"
TESTS_RUN=0
TESTS_FAILED=0

# Create an isolated temp repo with a fresh BACKLOG.md and point the runner at it.
setup_repo() {
  TMP="$(mktemp -d)"
  cp "$REPO/templates/BACKLOG.md" "$TMP/BACKLOG.md"
  export DEPUTY_ROOT="$TMP"
}

assert_eq() {  # assert_eq <actual> <expected> [msg]
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$1" != "$2" ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "${3:-}" "$2" "$1" >&2
  fi
}

assert_contains() {  # assert_contains <haystack> <needle> [msg]
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$1" != *"$2"* ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL: %s\n  [%s] does not contain [%s]\n' "${3:-}" "$1" "$2" >&2
  fi
}

_summarize() {
  printf '%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
  [[ "$TESTS_FAILED" -eq 0 ]]
}
trap _summarize EXIT
```

- [ ] **Step 3: Write the test runner**

Create `tests/run.sh`:

```bash
#!/usr/bin/env bash
# Runs every tests/test_*.sh in its own bash process; aggregates results.
cd "$(dirname "$0")/.."
fail=0
for f in tests/test_*.sh; do
  echo "== $f =="
  bash "$f" || fail=1
done
exit "$fail"
```

- [ ] **Step 4: Write a smoke test that exercises the harness**

Create `tests/test_harness.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
assert_eq "hello" "hello" "harness: equal strings pass"
assert_contains "the quick brown fox" "quick" "harness: substring"
[[ -f "$DEPUTY_ROOT/BACKLOG.md" ]] && assert_eq "ok" "ok" "harness: template copied"
```

- [ ] **Step 5: Make the runner executable placeholder & run the harness test**

```bash
chmod +x tests/run.sh
bash tests/run.sh
```

Expected: `== tests/test_harness.sh ==` then `3 run, 0 failed`, overall exit 0.

- [ ] **Step 6: Commit**

```bash
git add templates/BACKLOG.md tests/
git commit -m "test: add dependency-free bash test harness + backlog template"
```

---

## Task 2: Runner skeleton (root resolution, state dir, dispatch)

**Files:**
- Create: `bin/deputy.sh`
- Create: `tests/test_skeleton.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_skeleton.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

# Unknown command exits non-zero with usage on stderr.
out="$(bash "$DEPUTY" bogus 2>&1)"; rc=$?
assert_eq "$rc" "2" "unknown command exits 2"
assert_contains "$out" "usage" "unknown command prints usage"

# `help` exits 0 and lists commands.
out="$(bash "$DEPUTY" help 2>&1)"; rc=$?
assert_eq "$rc" "0" "help exits 0"
assert_contains "$out" "status" "help lists status"

# State dir is created on demand.
bash "$DEPUTY" help >/dev/null 2>&1
[[ -d "$DEPUTY_ROOT/.deputy" ]] && r=yes || r=no
assert_eq "$r" "yes" ".deputy state dir created"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_skeleton.sh`
Expected: FAIL — `bin/deputy.sh` does not exist (errors / non-matching assertions).

- [ ] **Step 3: Write the skeleton**

Create `bin/deputy.sh`:

```bash
#!/usr/bin/env bash
# deputy.sh — the Deputy runner (queue plumbing). Stateless tooling: it reads and
# mutates BACKLOG.md + .deputy/ under a repo root. No LLM logic lives here.
set -euo pipefail

# ── Root + paths ────────────────────────────────────────────────────────────
resolve_root() {
  if [[ -n "${DEPUTY_ROOT:-}" ]]; then
    printf '%s' "$DEPUTY_ROOT"
  elif root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s' "$root"
  else
    printf '%s' "$PWD"
  fi
}
ROOT="$(resolve_root)"
BACKLOG="$ROOT/BACKLOG.md"
STATE_DIR="$ROOT/.deputy"
LOCK_FILE="$STATE_DIR/lock"
mkdir -p "$STATE_DIR"
[[ -f "$LOCK_FILE" ]] || : > "$LOCK_FILE"

usage() {
  cat <<'EOF'
usage: deputy.sh <command> [args]

commands:
  add "<text>" [--p0|--p1|--p2]   add a waiting item
  list                            print parsed items (state|priority|description)
  status                          counts by state
  pick                            print the highest-priority waiting item (raw line)
  set "<exact line>" <state>      transition an item's state by exact-line match
  claim "<exact line>" [--pid N]  mark an item running and write a claim (serial)
  recover                         revert stale/orphaned claims to waiting
  help                            show this message

states: waiting triaging running surfaced done failed
EOF
}

main() {
  local cmd="${1:-help}"
  case "$cmd" in
    help|-h|--help) usage; return 0 ;;
    *) usage >&2; return 2 ;;
  esac
}

main "$@"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_skeleton.sh`
Expected: `4 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
chmod +x bin/deputy.sh
git add bin/deputy.sh tests/test_skeleton.sh
git commit -m "feat(runner): skeleton with root resolution, state dir, dispatch"
```

---

## Task 3: Item parsing & legend-skip iteration

**Files:**
- Modify: `bin/deputy.sh` (add `_each_item`, `_parse_item`)
- Create: `tests/test_parse.sh`

`_parse_item` left-trims a raw line, then extracts `(state, priority, description)`.
A status prefix is recognized **only** when the char is followed by whitespace
(so `@mention` stays a plain waiting description). `_each_item` yields raw item
lines after the legend's closing `-->` (or all non-blank lines if there is no legend).

- [ ] **Step 1: Write the failing test**

Create `tests/test_parse.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

# A helper that calls the script's internal parser via an exposed subcommand.
parse() { bash "$DEPUTY" _parse "$1"; }

assert_eq "$(parse '[P0] Fix it')"        "waiting|P0|Fix it"      "waiting P0"
assert_eq "$(parse '@ [P1] Build it')"    "running|P1|Build it"    "running P1"
assert_eq "$(parse '# Done thing')"       "done||Done thing"       "done untagged"
assert_eq "$(parse '   Plain waiting')"   "waiting||Plain waiting" "left-trim untagged"
assert_eq "$(parse '? [P2] Ask me')"      "surfaced|P2|Ask me"     "surfaced P2"
assert_eq "$(parse '! Broke')"            "failed||Broke"          "failed untagged"
assert_eq "$(parse '@mention the user')"  "waiting||@mention the user" "no-space prefix is text"

# Iteration skips the legend header.
printf '%s\n' '[P0] one' '~ [P1] two' '# three' >> "$DEPUTY_ROOT/BACKLOG.md"
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "waiting|P0|one"  "list: item one"
assert_contains "$out" "triaging|P1|two" "list: item two"
assert_contains "$out" "done||three"     "list: item three"
assert_eq "$(printf '%s\n' "$out" | grep -c 'LEGEND')" "0" "list: legend not parsed as item"
```

(Note: `list` is implemented in Task 4; this test file also covers it. Implement `_parse` here; the `list` assertions will pass once Task 4 lands. To keep tasks independently green, the `list` assertions are repeated in Task 4's test — here, run only the `_parse` assertions by temporarily trusting Task 4. The runner exposes a hidden `_parse` subcommand for testing.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_parse.sh`
Expected: FAIL — `_parse` subcommand unknown (`list` also unknown yet).

- [ ] **Step 3: Implement parsing + iteration**

In `bin/deputy.sh`, add these functions **above** `main`:

```bash
# Yield raw item lines: everything after the legend's closing '-->'. If the file
# has no '-->', every non-blank line is an item.
_each_item() {
  local line seen=0 has_legend=0
  grep -q -- '-->' "$BACKLOG" && has_legend=1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$has_legend" -eq 1 && "$seen" -eq 0 ]]; then
      [[ "$line" == *'-->'* ]] && seen=1
      continue
    fi
    [[ -z "${line//[[:space:]]/}" ]] && continue   # skip blank/whitespace-only
    printf '%s\n' "$line"
  done < "$BACKLOG"
}

# Parse one raw line -> "state|priority|description" (priority may be empty).
_parse_item() {
  local line="$1" state="waiting" prio="" desc=""
  line="${line#"${line%%[![:space:]]*}"}"          # left-trim
  if [[ "$line" =~ ^([~@?#!])[[:space:]]+(.*)$ ]]; then
    case "${BASH_REMATCH[1]}" in
      '~') state=triaging ;; '@') state=running ;;  '?') state=surfaced ;;
      '#') state=done ;;     '!') state=failed ;;
    esac
    line="${BASH_REMATCH[2]}"
  fi
  if [[ "$line" =~ ^\[(P[0-2])\]([[:space:]]+(.*))?$ ]]; then
    prio="${BASH_REMATCH[1]}"
    desc="${BASH_REMATCH[3]:-}"
  else
    desc="$line"
  fi
  printf '%s|%s|%s' "$state" "$prio" "$desc"
}
```

Add to the `case` in `main` (before the `*)` catch-all):

```bash
    _parse) _parse_item "${2:-}"; printf '\n'; return 0 ;;
```

- [ ] **Step 4: Run test to verify the `_parse` assertions pass**

Run: `bash tests/test_parse.sh`
Expected: the 7 `_parse` assertions pass; the 4 `list` assertions still fail (FAIL lines for "list: ..."). That is expected until Task 4.

- [ ] **Step 5: Commit**

```bash
git add bin/deputy.sh tests/test_parse.sh
git commit -m "feat(runner): item parsing + legend-skip iteration"
```

---

## Task 4: `list` & canonical serialization

**Files:**
- Modify: `bin/deputy.sh` (add `_serialize_item`, `cmd_list`)

`_serialize_item state prio desc` produces the canonical line. `list` prints one
`state|priority|description` per item (the same format `_parse_item` emits).

- [ ] **Step 1: Add to the test (serialization round-trips)**

Append to `tests/test_parse.sh`:

```bash
ser() { bash "$DEPUTY" _serialize "$1" "$2" "$3"; }
assert_eq "$(ser running P0 'Fix it')" "@ [P0] Fix it" "serialize running P0"
assert_eq "$(ser waiting '' 'Plain')"  "Plain"         "serialize waiting untagged"
assert_eq "$(ser done '' 'Thing')"     "# Thing"       "serialize done untagged"
assert_eq "$(ser surfaced P2 'Ask')"   "? [P2] Ask"    "serialize surfaced P2"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_parse.sh`
Expected: FAIL — `_serialize` unknown and `list` assertions still failing.

- [ ] **Step 3: Implement serialization + `list`**

Add above `main` in `bin/deputy.sh`:

```bash
# Build a canonical line from (state, priority, description).
_serialize_item() {
  local state="$1" prio="$2" desc="$3" prefix="" tag="" out=""
  case "$state" in
    waiting) prefix="" ;;  triaging) prefix="~" ;; running) prefix="@" ;;
    surfaced) prefix="?" ;; done) prefix="#" ;;   failed) prefix="!" ;;
    *) printf 'deputy: bad state: %s\n' "$state" >&2; return 1 ;;
  esac
  [[ -n "$prio" ]] && tag="[$prio]"
  for part in "$prefix" "$tag" "$desc"; do
    [[ -z "$part" ]] && continue
    [[ -n "$out" ]] && out+=" "
    out+="$part"
  done
  printf '%s' "$out"
}

cmd_list() {
  local raw
  while IFS= read -r raw; do
    _parse_item "$raw"; printf '\n'
  done < <(_each_item)
}
```

Add to the `case` in `main`:

```bash
    list) cmd_list; return 0 ;;
    _serialize) _serialize_item "${2:-}" "${3:-}" "${4:-}"; printf '\n'; return 0 ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_parse.sh`
Expected: `15 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/deputy.sh tests/test_parse.sh
git commit -m "feat(runner): canonical serialization + list command"
```

---

## Task 5: Locking helpers + `add` (with dedup)

**Files:**
- Modify: `bin/deputy.sh` (add `_with_lock`, `_flip_line`, `_append_item`, `cmd_add`)
- Create: `tests/test_add.sh`

`add` writes a canonical **waiting** line. Priority flags map `--p0/--p1/--p2` to
tags. Dedup is by **description** (re-adding the same text is a no-op, regardless
of the existing item's state). All writes go through `_with_lock` and are atomic.

- [ ] **Step 1: Write the failing test**

Create `tests/test_add.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

bash "$DEPUTY" add "First task"
bash "$DEPUTY" add "Urgent one" --p0
bash "$DEPUTY" add "Important one" --p2

out="$(bash "$DEPUTY" list)"
assert_contains "$out" "waiting||First task"       "add untagged"
assert_contains "$out" "waiting|P0|Urgent one"     "add --p0"
assert_contains "$out" "waiting|P2|Important one"  "add --p2"

# Dedup by description (no duplicate even with a different flag).
bash "$DEPUTY" add "First task" --p1
n="$(bash "$DEPUTY" list | grep -c 'First task')"
assert_eq "$n" "1" "add dedups by description"

# The legend survives an add.
assert_eq "$(grep -c 'LEGEND' "$DEPUTY_ROOT/BACKLOG.md")" "1" "legend intact after add"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_add.sh`
Expected: FAIL — `add` not implemented.

- [ ] **Step 3: Implement locking helpers + `add`**

Add above `main` in `bin/deputy.sh`:

```bash
# Run a function while holding an exclusive lock on LOCK_FILE (short-held).
_with_lock() { ( flock -x 200; "$@" ) 200>"$LOCK_FILE"; }

# Exact whole-line replacement (research.sh flip_line). Atomic via tmpfile+mv.
# Caller holds the lock.
_flip_line() {
  local from="$1" to="$2" tmp line; tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$from" ]]; then printf '%s\n' "$to"; else printf '%s\n' "$line"; fi
  done < "$BACKLOG" > "$tmp"
  mv "$tmp" "$BACKLOG"
}

# Append a raw line to BACKLOG. Caller holds the lock.
_append_item() { printf '%s\n' "$1" >> "$BACKLOG"; }

# True if any item's parsed description equals $1.
_desc_exists() {
  local want="$1" raw IFS='|' parsed
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"
    [[ "${parsed#*|*|}" == "$want" ]] && return 0
  done < <(_each_item)
  return 1
}

cmd_add() {
  local text="" prio=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --p0) prio=P0 ;; --p1) prio=P1 ;; --p2) prio=P2 ;;
      --*) printf 'deputy: unknown flag: %s\n' "$1" >&2; return 2 ;;
      *) text="${text}${text:+ }$1" ;;
    esac
    shift
  done
  [[ -n "$text" ]] || { printf 'deputy: add requires text\n' >&2; return 2; }
  _do_add() {
    if _desc_exists "$text"; then
      printf 'deputy: already present: %s\n' "$text"; return 0
    fi
    _append_item "$(_serialize_item waiting "$prio" "$text")"
    printf 'deputy: added: %s\n' "$text"
  }
  _with_lock _do_add
}
```

Add to the `case` in `main`:

```bash
    add) shift; cmd_add "$@"; return 0 ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_add.sh`
Expected: `5 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/deputy.sh tests/test_add.sh
git commit -m "feat(runner): locking helpers + add with description dedup"
```

---

## Task 6: `status` counts

**Files:**
- Modify: `bin/deputy.sh` (add `cmd_status`)
- Create: `tests/test_status.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_status.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
printf '%s\n' '[P0] a' 'b' '@ c' '? [P1] d' '# e' '! f' '~ g' >> "$DEPUTY_ROOT/BACKLOG.md"

out="$(bash "$DEPUTY" status)"
assert_contains "$out" "waiting:  2"  "status waiting count"
assert_contains "$out" "triaging: 1" "status triaging count"
assert_contains "$out" "running:  1"  "status running count"
assert_contains "$out" "surfaced: 1" "status surfaced count"
assert_contains "$out" "done:     1" "status done count"
assert_contains "$out" "failed:   1" "status failed count"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_status.sh`
Expected: FAIL — `status` not implemented.

- [ ] **Step 3: Implement `status`**

Add above `main` in `bin/deputy.sh`:

```bash
cmd_status() {
  local raw state w=0 t=0 r=0 s=0 d=0 f=0 parsed
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"; state="${parsed%%|*}"
    case "$state" in
      waiting) w=$((w+1)) ;; triaging) t=$((t+1)) ;; running) r=$((r+1)) ;;
      surfaced) s=$((s+1)) ;; done) d=$((d+1)) ;; failed) f=$((f+1)) ;;
    esac
  done < <(_each_item)
  printf 'waiting:  %d\ntriaging: %d\nrunning:  %d\nsurfaced: %d\ndone:     %d\nfailed:   %d\n' \
    "$w" "$t" "$r" "$s" "$d" "$f"
}
```

Add to the `case` in `main`:

```bash
    status) cmd_status; return 0 ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_status.sh`
Expected: `6 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/deputy.sh tests/test_status.sh
git commit -m "feat(runner): status counts by state"
```

---

## Task 7: `pick` (priority order + FIFO)

**Files:**
- Modify: `bin/deputy.sh` (add `cmd_pick`)
- Create: `tests/test_pick.sh`

`pick` prints the **raw line** of the highest-priority *waiting* item
(rank P0<P1<P2<untagged; ties broken by file order = FIFO), or nothing if there
are no waiting items. It does not mutate. Returning the raw line lets the caller
pass it straight back to `set`/`claim` for an exact match.

- [ ] **Step 1: Write the failing test**

Create `tests/test_pick.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

# Mixed priorities + a running item that must be ignored.
printf '%s\n' 'untagged old' '[P2] important' '@ [P0] already running' '[P1] urgent' '[P0] top' \
  >> "$DEPUTY_ROOT/BACKLOG.md"
assert_eq "$(bash "$DEPUTY" pick)" "[P0] top" "pick chooses highest priority waiting"

# FIFO within a lane: two P1 waiting -> first in file wins.
setup_repo
printf '%s\n' '[P1] first urgent' '[P1] second urgent' >> "$DEPUTY_ROOT/BACKLOG.md"
assert_eq "$(bash "$DEPUTY" pick)" "[P1] first urgent" "pick FIFO within lane"

# Untagged is the lowest lane but still picked when nothing else waits.
setup_repo
printf '%s\n' '@ [P0] running' 'plain waiting' >> "$DEPUTY_ROOT/BACKLOG.md"
assert_eq "$(bash "$DEPUTY" pick)" "plain waiting" "pick falls back to untagged"

# Nothing waiting -> empty output, exit 0.
setup_repo
printf '%s\n' '# done item' >> "$DEPUTY_ROOT/BACKLOG.md"
out="$(bash "$DEPUTY" pick)"; rc=$?
assert_eq "$out" "" "pick empty when nothing waits"
assert_eq "$rc" "0" "pick exits 0 when empty"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_pick.sh`
Expected: FAIL — `pick` not implemented.

- [ ] **Step 3: Implement `pick`**

Add above `main` in `bin/deputy.sh`:

```bash
# Numeric rank for a priority tag: P0=0 P1=1 P2=2 (none)=3.
_prio_rank() {
  case "$1" in P0) echo 0 ;; P1) echo 1 ;; P2) echo 2 ;; *) echo 3 ;; esac
}

cmd_pick() {
  local raw parsed state prio best_rank=99 best_line="" rank
  while IFS= read -r raw; do
    parsed="$(_parse_item "$raw")"
    state="${parsed%%|*}"
    [[ "$state" == "waiting" ]] || continue
    prio="${parsed#*|}"; prio="${prio%%|*}"
    rank="$(_prio_rank "$prio")"
    if (( rank < best_rank )); then          # strict < preserves FIFO on ties
      best_rank="$rank"; best_line="$raw"
    fi
  done < <(_each_item)
  [[ -n "$best_line" ]] && printf '%s\n' "$best_line"
  return 0
}
```

Add to the `case` in `main`:

```bash
    pick) cmd_pick; return 0 ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_pick.sh`
Expected: `5 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/deputy.sh tests/test_pick.sh
git commit -m "feat(runner): pick highest-priority waiting item with FIFO"
```

---

## Task 8: `set` (exact-line state transition)

**Files:**
- Modify: `bin/deputy.sh` (add `cmd_set`)
- Create: `tests/test_set.sh`

`set "<exact raw line>" <state>` finds the line by exact match, re-serializes it
into the new state (preserving priority + description), and writes atomically under
the lock. A non-matching line is a safe no-op returning non-zero.

- [ ] **Step 1: Write the failing test**

Create `tests/test_set.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
printf '%s\n' '[P0] do the thing' 'plain one' >> "$DEPUTY_ROOT/BACKLOG.md"

# waiting -> running keeps the priority tag.
bash "$DEPUTY" set "[P0] do the thing" running
assert_contains "$(bash "$DEPUTY" list)" "running|P0|do the thing" "set waiting->running keeps P0"

# running -> done (pick the now-current raw line back via pick? it's running, so use list).
bash "$DEPUTY" set "@ [P0] do the thing" done
assert_contains "$(bash "$DEPUTY" list)" "done|P0|do the thing" "set running->done"

# untagged transition.
bash "$DEPUTY" set "plain one" surfaced
assert_contains "$(bash "$DEPUTY" list)" "surfaced||plain one" "set untagged->surfaced"

# No match -> non-zero, file unchanged.
before="$(cat "$DEPUTY_ROOT/BACKLOG.md")"
bash "$DEPUTY" set "does not exist" done; rc=$?
after="$(cat "$DEPUTY_ROOT/BACKLOG.md")"
assert_eq "$rc" "1" "set no-match returns 1"
assert_eq "$after" "$before" "set no-match leaves file unchanged"

# Invalid state -> usage error (exit 2).
bash "$DEPUTY" set "[P0] x" bogus; rc=$?
assert_eq "$rc" "2" "set invalid state exits 2"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_set.sh`
Expected: FAIL — `set` not implemented.

- [ ] **Step 3: Implement `set`**

Add above `main` in `bin/deputy.sh`:

```bash
_valid_state() {
  case "$1" in waiting|triaging|running|surfaced|done|failed) return 0 ;; *) return 1 ;; esac
}

cmd_set() {
  local from="${1:-}" newstate="${2:-}"
  [[ -n "$from" && -n "$newstate" ]] || { printf 'deputy: set requires "<line>" <state>\n' >&2; return 2; }
  _valid_state "$newstate" || { printf 'deputy: invalid state: %s\n' "$newstate" >&2; return 2; }
  _do_set() {
    grep -qxF -- "$from" "$BACKLOG" || return 1     # exact-line existence
    local parsed prio desc to
    parsed="$(_parse_item "$from")"
    prio="${parsed#*|}"; prio="${prio%%|*}"
    desc="${parsed##*|}"
    to="$(_serialize_item "$newstate" "$prio" "$desc")"
    _flip_line "$from" "$to"
  }
  _with_lock _do_set
}
```

Add to the `case` in `main`:

```bash
    set) shift; cmd_set "$@"; return $? ;;
```

Note: `cmd_set` returns the inner status through `_with_lock` (subshell exit code), so the `set` branch propagates `1` on no-match.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_set.sh`
Expected: `6 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/deputy.sh tests/test_set.sh
git commit -m "feat(runner): set state by exact-line match (atomic, locked)"
```

---

## Task 9: `claim` (serial ownership)

**Files:**
- Modify: `bin/deputy.sh` (add `_live_claim_exists`, `cmd_claim`)
- Create: `tests/test_claim.sh`

`claim "<exact waiting line>" [--pid N]` (default PID = `$PPID`): under the lock,
verify the item is currently *waiting*, refuse if **any live claim already
exists** (serial guard), then mark it `running` and write `.deputy/<pid>.claim`
containing the now-running canonical line.

- [ ] **Step 1: Write the failing test**

Create `tests/test_claim.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
printf '%s\n' '[P0] first' '[P1] second' >> "$DEPUTY_ROOT/BACKLOG.md"

# A live "owner" process to attribute a claim to.
sleep 300 & LIVE=$!

bash "$DEPUTY" claim "[P0] first" --pid "$LIVE"; rc=$?
assert_eq "$rc" "0" "claim succeeds when free"
assert_contains "$(bash "$DEPUTY" list)" "running|P0|first" "claimed item is running"
[[ -f "$DEPUTY_ROOT/.deputy/$LIVE.claim" ]] && r=yes || r=no
assert_eq "$r" "yes" "claim file written"
assert_eq "$(cat "$DEPUTY_ROOT/.deputy/$LIVE.claim")" "@ [P0] first" "claim file holds running line"

# Second claim refused while a live claim exists (serial).
sleep 300 & LIVE2=$!
bash "$DEPUTY" claim "[P1] second" --pid "$LIVE2"; rc=$?
assert_eq "$rc" "3" "second claim refused (serial guard)"
assert_contains "$(bash "$DEPUTY" list)" "waiting|P1|second" "second item still waiting"

kill "$LIVE" "$LIVE2" 2>/dev/null
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_claim.sh`
Expected: FAIL — `claim` not implemented.

- [ ] **Step 3: Implement `claim`**

Add above `main` in `bin/deputy.sh`:

```bash
# True if any .deputy/<pid>.claim is owned by a live process.
_live_claim_exists() {
  local f pid
  shopt -s nullglob
  for f in "$STATE_DIR"/*.claim; do
    pid="$(basename "$f" .claim)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      shopt -u nullglob; return 0
    fi
  done
  shopt -u nullglob; return 1
}

cmd_claim() {
  local from="" pid="$PPID"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pid) pid="${2:-}"; shift 2 ;;
      *) [[ -z "$from" ]] && { from="$1"; shift; } || { printf 'deputy: unexpected arg: %s\n' "$1" >&2; return 2; } ;;
    esac
  done
  [[ -n "$from" ]] || { printf 'deputy: claim requires "<line>"\n' >&2; return 2; }
  _do_claim() {
    _live_claim_exists && { printf 'deputy: busy (a live claim exists)\n' >&2; return 3; }
    local parsed state
    parsed="$(_parse_item "$from")"; state="${parsed%%|*}"
    [[ "$state" == "waiting" ]] || { printf 'deputy: item is not waiting (%s)\n' "$state" >&2; return 4; }
    grep -qxF -- "$from" "$BACKLOG" || { printf 'deputy: item not found\n' >&2; return 1; }
    local prio desc to
    prio="${parsed#*|}"; prio="${prio%%|*}"; desc="${parsed##*|}"
    to="$(_serialize_item running "$prio" "$desc")"
    _flip_line "$from" "$to"
    printf '%s\n' "$to" > "$STATE_DIR/$pid.claim"
  }
  _with_lock _do_claim
}
```

Add to the `case` in `main`:

```bash
    claim) shift; cmd_claim "$@"; return $? ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_claim.sh`
Expected: `5 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/deputy.sh tests/test_claim.sh
git commit -m "feat(runner): claim with serial ownership guard"
```

---

## Task 10: `recover` (stale + orphan recovery)

**Files:**
- Modify: `bin/deputy.sh` (add `cmd_recover`)
- Create: `tests/test_recover.sh`

`recover` (under the lock): (1) for each `.deputy/<pid>.claim` whose PID is dead,
revert its claimed line (`@`/`~` → waiting) and delete the claim file; (2) revert
any orphaned `@`/`~` item that no **live** claim accounts for. Mirrors research.sh
`revert_stale`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_recover.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
printf '%s\n' '@ [P0] was running' '~ [P1] was triaging' '[P2] untouched' >> "$DEPUTY_ROOT/BACKLOG.md"

# A claim owned by a DEAD pid: pick an unused pid (99999) -> reverts + removed.
echo '@ [P0] was running' > "$DEPUTY_ROOT/.deputy/99999.claim"

bash "$DEPUTY" recover
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "waiting|P0|was running"  "stale claim reverted to waiting"
[[ -f "$DEPUTY_ROOT/.deputy/99999.claim" ]] && r=yes || r=no
assert_eq "$r" "no" "dead claim file removed"

# The triaging item had NO claim at all -> orphan revert.
assert_contains "$out" "waiting|P1|was triaging" "orphan triaging reverted"

# Untouched waiting item stays put.
assert_contains "$out" "waiting|P2|untouched" "untouched item unchanged"

# A claim owned by a LIVE pid must NOT be reverted.
setup_repo
printf '%s\n' '@ [P0] live work' >> "$DEPUTY_ROOT/BACKLOG.md"
sleep 300 & LIVE=$!
echo '@ [P0] live work' > "$DEPUTY_ROOT/.deputy/$LIVE.claim"
bash "$DEPUTY" recover
assert_contains "$(bash "$DEPUTY" list)" "running|P0|live work" "live claim preserved"
kill "$LIVE" 2>/dev/null
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_recover.sh`
Expected: FAIL — `recover` not implemented.

- [ ] **Step 3: Implement `recover`**

Add above `main` in `bin/deputy.sh`:

```bash
# Revert a running/triaging line back to waiting (strip the prefix). Caller holds lock.
_revert_to_waiting() {
  local raw="$1" parsed prio desc to
  parsed="$(_parse_item "$raw")"
  prio="${parsed#*|}"; prio="${prio%%|*}"; desc="${parsed##*|}"
  to="$(_serialize_item waiting "$prio" "$desc")"
  _flip_line "$raw" "$to"
}

cmd_recover() {
  _do_recover() {
    local f pid line
    shopt -s nullglob
    # (1) Dead-claim recovery.
    for f in "$STATE_DIR"/*.claim; do
      pid="$(basename "$f" .claim)"
      if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
        line="$(cat "$f")"
        _revert_to_waiting "$line"
        rm -f "$f"
      fi
    done
    # Collect lines still claimed by LIVE pids.
    local -a claimed=()
    for f in "$STATE_DIR"/*.claim; do
      pid="$(basename "$f" .claim)"
      if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        claimed+=("$(cat "$f")")
      fi
    done
    shopt -u nullglob
    # (2) Orphan recovery: any @/~ item not in a live claim.
    local raw parsed state c found
    while IFS= read -r raw; do
      parsed="$(_parse_item "$raw")"; state="${parsed%%|*}"
      [[ "$state" == "running" || "$state" == "triaging" ]] || continue
      found=0
      for c in "${claimed[@]:-}"; do [[ "$c" == "$raw" ]] && { found=1; break; }; done
      [[ "$found" -eq 0 ]] && _revert_to_waiting "$raw"
    done < <(_each_item)
  }
  _with_lock _do_recover
}
```

Add to the `case` in `main`:

```bash
    recover) cmd_recover; return 0 ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_recover.sh`
Expected: `6 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/deputy.sh tests/test_recover.sh
git commit -m "feat(runner): stale + orphan claim recovery"
```

---

## Task 11: `.gitignore`, full suite, finalize

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Write `.gitignore`**

Create `.gitignore`:

```gitignore
# Deputy runtime state (per-repo). Keep BACKLOG.md and templates tracked.
.deputy/
```

- [ ] **Step 2: Run the entire suite**

Run: `bash tests/run.sh; echo "exit=$?"`
Expected: every `test_*.sh` prints `N run, 0 failed`, final line `exit=0`.

- [ ] **Step 3: Manual end-to-end smoke (no test harness)**

```bash
tmp="$(mktemp -d)"; cp templates/BACKLOG.md "$tmp/BACKLOG.md"
DEPUTY_ROOT="$tmp" bash bin/deputy.sh add "Write the README" --p2
DEPUTY_ROOT="$tmp" bash bin/deputy.sh add "Fix the outage" --p0
line="$(DEPUTY_ROOT="$tmp" bash bin/deputy.sh pick)"; echo "picked: $line"
DEPUTY_ROOT="$tmp" bash bin/deputy.sh claim "$line" --pid $$
DEPUTY_ROOT="$tmp" bash bin/deputy.sh status
rm -rf "$tmp"
```

Expected: `picked: [P0] Fix the outage`; status shows `running: 1`, `waiting: 1`.

- [ ] **Step 4: Commit**

```bash
git add .gitignore
git commit -m "chore(runner): gitignore .deputy runtime state"
```

---

## Self-Review (completed during authoring)

**Spec coverage (Plan-1 slice):** `BACKLOG.md` legend + parsing rule (Tasks 1,3) ✓;
status prefixes & priority tags (Tasks 3,4) ✓; runner is the only writer via
exact-line helper (Tasks 5,8) ✓; short-held `flock`, atomic writes (Task 5) ✓;
priority order P0>P1>P2>untagged + FIFO (Task 7) ✓; claim-based ownership + serial
guard (Task 9) ✓; stale + orphan recovery (Task 10) ✓; status counts (Task 6) ✓.

**Deferred to later plans (intentionally not in Plan 1):** cron safety-net,
CLI adapters / `detect_outcome` / probe, routing & failover (Plan 2); orchestrator
skill, triage, `.deputy/wt` worktree execution, waypoint + xReview wiring,
surfacing hook, `install.sh`, templates wiring, `--dry-run`, guardrails (Plan 3).

**Type/name consistency:** function names (`_parse_item`, `_serialize_item`,
`_each_item`, `_flip_line`, `_with_lock`, `_prio_rank`, `_revert_to_waiting`,
`_live_claim_exists`) and the `state|priority|description` interchange format are
used identically across Tasks 3–10. The `cmd_*` dispatch names match the `case`
branches added per task. Claim file format (`@ [Px] desc`) written in Task 9 is the
exact string matched in Task 10's recovery.

**No placeholders:** every step contains runnable code/commands and concrete
expected output.
```
