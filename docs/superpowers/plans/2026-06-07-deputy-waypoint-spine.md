# Deputy Waypoint Checkpoint Spine — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Absorb waypoint's forward-recovery checkpoint mechanism into deputy as a pure-bash, `jq`-backed spine: every item executes as resumable, checkpointed steps stored in `.deputy/waypoints/<id>/`, with per-step git commits on the item branch.

**Architecture:** New internal subcommands in `bin/deputy.sh` (`start/plan/set-step/commit/steps/resume/done`) operate on a slim `waypoint.json` ledger via `jq` (atomic tmp+mv, under `.deputy/lock`), regenerating a derived `STATUS.md`. `commit` stages **all** worktree changes and records the git SHA. The orchestrator `SKILL.md` drives these verbs with xReview gates. Reference design: `docs/superpowers/specs/2026-06-07-deputy-waypoint-spine-design.md`.

**Tech Stack:** Bash 5.2, `jq` 1.8, `git`, the existing dependency-free test harness (`tests/lib.sh`).

**Schema refinement (vs the design doc):** steps carry `status ∈ {pending, in_progress, succeeded}` in a single `steps[]` array; `current_step` is a top-level **pointer** (the active step's id, or `null`) — simpler in bash than a duplicated object, and resumability is unchanged.

**Conventions:**
- Run from the repo root `/home/tong/src/tonychen15/deputy`.
- New verbs are **internal** (not added to `deputy help`).
- All ledger writes go through `_wp_jq` (atomic; caller holds `.deputy/lock`).
- Slug/`task_id` = the existing deputy slug. Timestamps via `date -Iseconds`.

---

## File Structure
| File | Change |
|---|---|
| `bin/deputy.sh` | add `_wp_*` helpers + `start/plan/set-step/commit/steps/resume/done` arms + `_wp_show` (hidden, tests) + jq runtime guard |
| `install.sh` | jq preflight warning |
| `skills/deputy/SKILL.md` | orchestrator drives the spine + xReview gates + resume/purge |
| `tests/test_wp_*.sh` | one file per verb group |

The slim `waypoint.json`:
```json
{
  "task_id": "fix-x-a1b2", "goal": "...", "status": "in_progress",
  "created_at": "...", "updated_at": "...", "note": "",
  "current_step": null,
  "steps": [
    { "id": "1", "purpose": "...", "expected_result": "", "status": "succeeded",
      "completed_at": "...", "actual_result": { "summary": "...",
        "artifacts": [ { "path": ".", "step_commit": "<sha>" } ] } }
  ]
}
```

---

## Task 1: Ledger IO helpers + `start` / `done` + `STATUS.md`

**Files:** Modify `bin/deputy.sh`; Create `tests/test_wp_start.sh`.

- [ ] **Step 1: Write the failing test** — `tests/test_wp_start.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

bash "$DEPUTY" start demo-1 "Build the thing"
j="$DEPUTY_ROOT/.deputy/waypoints/demo-1/waypoint.json"
assert_eq "$([[ -f "$j" ]] && echo yes || echo no)" "yes" "start creates waypoint.json"
assert_eq "$(jq -r .task_id "$j")" "demo-1"        "task_id set"
assert_eq "$(jq -r .goal "$j")"    "Build the thing" "goal set"
assert_eq "$(jq -r .status "$j")"  "in_progress"    "status in_progress"
assert_eq "$(jq -r '.steps|length' "$j")" "0"       "no steps yet"
assert_eq "$(jq -r '.current_step==null' "$j")" "true" "no current step"

# STATUS.md derived
assert_contains "$(cat "$DEPUTY_ROOT/.deputy/waypoints/demo-1/STATUS.md")" "Build the thing" "STATUS.md has goal"

# start is idempotent (does not clobber)
bash "$DEPUTY" plan demo-1 --step 1 --purpose "p" >/dev/null 2>&1 || true
bash "$DEPUTY" start demo-1 "DIFFERENT goal"
assert_eq "$(jq -r .goal "$j")" "Build the thing" "start idempotent (no clobber)"

# done
bash "$DEPUTY" done demo-1
assert_eq "$(jq -r .status "$j")" "completed" "done marks completed"
```

- [ ] **Step 2: Run — confirm FAIL** (`start` unknown): `bash tests/test_wp_start.sh`

- [ ] **Step 3: Implement.** Add to `bin/deputy.sh` **above `main`**:
```bash
# ── Checkpoint spine (absorbed waypoint), stored under .deputy/waypoints/ ──────
_wp_dir()      { printf '%s/waypoints' "$STATE_DIR"; }
_wp_task_dir() { printf '%s/waypoints/%s' "$STATE_DIR" "$1"; }
_wp_json()     { printf '%s/waypoints/%s/waypoint.json' "$STATE_DIR" "$1"; }
_wp_now()      { date -Iseconds; }
_wp_require_jq(){ command -v jq >/dev/null 2>&1 || { printf 'deputy: jq is required for the checkpoint spine\n' >&2; return 1; }; }

# Apply a jq filter to a task's waypoint.json, atomically; regenerate STATUS.md.
# Caller holds .deputy/lock.
_wp_jq() {
  local id="$1" filter="$2"; shift 2
  local f tmp; f="$(_wp_json "$id")"
  tmp="$(mktemp "$(dirname "$f")/.wp.XXXXXX")"
  # Guard the write: if jq fails, do NOT mv (an empty/partial tmp would truncate
  # the ledger). Only replace on success.
  if jq "$@" "$filter" "$f" > "$tmp"; then mv "$tmp" "$f"; else rm -f "$tmp"; return 1; fi
  _wp_render_status "$id"
}

# Regenerate the human-readable STATUS.md from waypoint.json.
_wp_render_status() {
  local id="$1" f td; f="$(_wp_json "$id")"; td="$(_wp_task_dir "$id")"
  { jq -r '"# Task: \(.task_id)   (\(.status))\n\n**Goal:** \(.goal)\n\n## Steps"' "$f"
    jq -r '.steps[] | (if .status=="succeeded" then "[x] " elif .status=="in_progress" then "[>] " else "[ ] " end) + .id + "  " + .purpose' "$f"
  } > "$td/STATUS.md"
}

cmd_wp_start() {
  local id="${1:?start needs <id>}" goal="${2:-}"
  _wp_require_jq || return 1
  [[ -f "$(_wp_json "$id")" ]] && return 0          # idempotent: never clobber
  _do_start() {
    local td; td="$(_wp_task_dir "$id")"; mkdir -p "$td"
    local now; now="$(_wp_now)"
    jq -n --arg id "$id" --arg g "$goal" --arg now "$now" \
      '{task_id:$id, goal:$g, status:"in_progress", created_at:$now, updated_at:$now, note:"", current_step:null, steps:[]}' \
      > "$(_wp_json "$id")"
    _wp_render_status "$id"
  }
  _with_lock _do_start
}

cmd_wp_done() {
  local id="${1:?done needs <id>}"; _wp_require_jq || return 1
  _do_done() { _wp_jq "$id" '.status="completed" | .current_step=null | .updated_at=$now' --arg now "$(_wp_now)"; }
  _with_lock _do_done
}

# Hidden helper for tests: print the raw waypoint.json.
cmd_wp_show() { cat "$(_wp_json "${1:?}")"; }
```
Add dispatch arms in `main` (before `*)`):
```bash
    start) shift; cmd_wp_start "$@"; return $? ;;
    done) shift; cmd_wp_done "$@"; return $? ;;
    _wp_show) shift; cmd_wp_show "$@"; return 0 ;;
```

- [ ] **Step 4: Run — confirm `8 run, 0 failed`**, then `bash tests/run.sh; echo exit=$?` all green.
- [ ] **Step 5: Commit** `feat(spine): waypoint ledger IO + start/done + STATUS.md`.

---

## Task 2: `plan` (append step) + `steps` (list)

**Files:** Modify `bin/deputy.sh`; Create `tests/test_wp_plan.sh`.

- [ ] **Step 1: Write the failing test** — `tests/test_wp_plan.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
bash "$DEPUTY" start t "goal"
bash "$DEPUTY" plan t --step 1 --purpose "first step"
bash "$DEPUTY" plan t --step 2 --purpose "second step"

out="$(bash "$DEPUTY" steps t)"
assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "2" "two steps listed"
assert_contains "$out" "1|pending|first step"  "step 1 pending"
assert_contains "$out" "2|pending|second step" "step 2 pending"
j="$DEPUTY_ROOT/.deputy/waypoints/t/waypoint.json"
assert_eq "$(jq -r '.steps[0].status' "$j")" "pending" "appended as pending"
```

- [ ] **Step 2: Run — confirm FAIL.**

- [ ] **Step 3: Implement.** Add above `main`:
```bash
cmd_wp_plan() {
  local id="" sid="" purpose=""
  id="${1:?plan needs <id>}"; shift
  while [[ $# -gt 0 ]]; do case "$1" in
    --step) sid="${2:-}"; shift 2 ;;
    --purpose) purpose="${2:-}"; shift 2 ;;
    *) printf 'deputy: plan: unexpected arg %s\n' "$1" >&2; return 2 ;;
  esac; done
  [[ -n "$sid" && -n "$purpose" ]] || { printf 'deputy: plan needs --step and --purpose\n' >&2; return 2; }
  _wp_require_jq || return 1
  _do_plan() {
    _wp_jq "$id" \
      '.steps += [{id:$sid, purpose:$p, expected_result:"", status:"pending", completed_at:null, actual_result:null}] | .updated_at=$now' \
      --arg sid "$sid" --arg p "$purpose" --arg now "$(_wp_now)"
  }
  _with_lock _do_plan
}

cmd_wp_steps() {
  local id="${1:?steps needs <id>}"; _wp_require_jq || return 1
  jq -r '.steps[] | "\(.id)|\(.status)|\(.purpose)"' "$(_wp_json "$id")"
}
```
Add arms:
```bash
    plan) shift; cmd_wp_plan "$@"; return $? ;;
    steps) shift; cmd_wp_steps "$@"; return $? ;;
```

- [ ] **Step 4: Run — confirm `4 run, 0 failed`**, full suite green.
- [ ] **Step 5: Commit** `feat(spine): plan + steps`.

---

## Task 3: `set-step` (activate) + `resume` (first uncommitted)

**Files:** Modify `bin/deputy.sh`; Create `tests/test_wp_setstep.sh`.

- [ ] **Step 1: Write the failing test** — `tests/test_wp_setstep.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
bash "$DEPUTY" start t "goal"
bash "$DEPUTY" plan t --step 1 --purpose "one"
bash "$DEPUTY" plan t --step 2 --purpose "two"

# resume returns the first non-succeeded step
assert_contains "$(bash "$DEPUTY" resume t)" "1|one" "resume points at first pending"

bash "$DEPUTY" set-step t --step 1 --expected "done looks like X"
j="$DEPUTY_ROOT/.deputy/waypoints/t/waypoint.json"
assert_eq "$(jq -r '.current_step' "$j")" "1" "current_step set to 1"
assert_eq "$(jq -r '.steps[0].status' "$j")" "in_progress" "step 1 active"
assert_eq "$(jq -r '.steps[0].expected_result' "$j")" "done looks like X" "expected recorded"
# an in_progress step is still 'uncommitted' -> resume still returns it
assert_contains "$(bash "$DEPUTY" resume t)" "1|one" "resume returns the in_progress step"
```

- [ ] **Step 2: Run — confirm FAIL.**

- [ ] **Step 3: Implement.** Add above `main`:
```bash
cmd_wp_setstep() {
  local id="" sid="" expected=""
  id="${1:?set-step needs <id>}"; shift
  while [[ $# -gt 0 ]]; do case "$1" in
    --step) sid="${2:-}"; shift 2 ;;
    --expected) expected="${2:-}"; shift 2 ;;
    *) printf 'deputy: set-step: unexpected arg %s\n' "$1" >&2; return 2 ;;
  esac; done
  [[ -n "$sid" ]] || { printf 'deputy: set-step needs --step\n' >&2; return 2; }
  _wp_require_jq || return 1
  _do_setstep() {
    _wp_jq "$id" \
      '(.steps[] | select(.id==$sid) | .status) = "in_progress"
       | (.steps[] | select(.id==$sid) | .expected_result) = $e
       | .current_step = $sid | .updated_at=$now' \
      --arg sid "$sid" --arg e "$expected" --arg now "$(_wp_now)"
  }
  _with_lock _do_setstep
}

# Print "<id>|<purpose>" of the first step not yet succeeded (empty if none).
cmd_wp_resume() {
  local id="${1:?resume needs <id>}"; _wp_require_jq || return 1
  jq -r 'first(.steps[] | select(.status!="succeeded")) | "\(.id)|\(.purpose)"' \
    "$(_wp_json "$id")" 2>/dev/null
  return 0
}
```
Add arms:
```bash
    set-step) shift; cmd_wp_setstep "$@"; return $? ;;
    resume) shift; cmd_wp_resume "$@"; return $? ;;
```

- [ ] **Step 4: Run — confirm `5 run, 0 failed`**, full suite green.
- [ ] **Step 5: Commit** `feat(spine): set-step + resume`.

---

## Task 4: `commit` (git add -A + commit + ledger flip)

**Files:** Modify `bin/deputy.sh`; Create `tests/test_wp_commit.sh`.

`commit` stages **all** changes in the worktree (`.deputy/wt`), commits, records the SHA, and flips the in-progress step to `succeeded`. For tests we point the worktree at a temp git repo via a `DEPUTY_WT` override (default `_wt_path`).

- [ ] **Step 1: Add a `DEPUTY_WT` override to `_wt_path`** so tests can target a plain git repo. Modify `_wt_path`:
```bash
_wt_path() { printf '%s' "${DEPUTY_WT:-$STATE_DIR/wt}"; }
```

- [ ] **Step 2: Write the failing test** — `tests/test_wp_commit.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
# a temp git repo acting as the worktree
WT="$(mktemp -d)"; export DEPUTY_WT="$WT"
git -C "$WT" init -q; git -C "$WT" config user.email t@t; git -C "$WT" config user.name t
echo seed > "$WT/seed"; git -C "$WT" add -A; git -C "$WT" commit -qm seed

bash "$DEPUTY" start t "goal"
bash "$DEPUTY" plan t --step 1 --purpose "one"
bash "$DEPUTY" set-step t --step 1
# worker makes a change (undeclared) in the worktree
echo "hello" > "$WT/new.txt"
bash "$DEPUTY" commit t --summary "did one"

j="$DEPUTY_ROOT/.deputy/waypoints/t/waypoint.json"
assert_eq "$(jq -r '.steps[0].status' "$j")" "succeeded" "step flipped to succeeded"
assert_eq "$(jq -r '.current_step==null' "$j")" "true"   "current cleared"
assert_eq "$(jq -r '.steps[0].actual_result.summary' "$j")" "did one" "summary recorded"
sha="$(jq -r '.steps[0].actual_result.artifacts[0].step_commit' "$j")"
assert_eq "$(git -C "$WT" rev-parse HEAD)" "$sha" "recorded SHA = HEAD"
# undeclared change WAS committed (git add -A)
assert_contains "$(git -C "$WT" show --stat HEAD)" "new.txt" "staged all changes"
# resume now reports nothing (all steps succeeded)
assert_eq "$(bash "$DEPUTY" resume t)" "" "resume empty after commit"
rm -rf "$WT"
```

- [ ] **Step 3: Run — confirm FAIL.**

- [ ] **Step 4: Implement.** Add above `main`:
```bash
cmd_wp_commit() {
  local id="" summary="" ; local -a arts=()
  id="${1:?commit needs <id>}"; shift
  while [[ $# -gt 0 ]]; do case "$1" in
    --summary) summary="${2:-}"; shift 2 ;;
    --artifact) arts+=("${2:-}"); shift 2 ;;
    *) printf 'deputy: commit: unexpected arg %s\n' "$1" >&2; return 2 ;;
  esac; done
  _wp_require_jq || return 1
  local wt; wt="$(_wt_path)"
  [[ -d "$wt/.git" || -e "$wt/.git" ]] || { printf 'deputy: no worktree at %s\n' "$wt" >&2; return 1; }
  # Stage ALL changes; commit only if there is something staged.
  git -C "$wt" add -A
  local sha=""
  if ! git -C "$wt" diff --cached --quiet; then
    git -C "$wt" commit -q -m "${summary:-deputy step}"
    sha="$(git -C "$wt" rev-parse HEAD)"
  else
    sha="$(git -C "$wt" rev-parse HEAD)"   # no change → point at current HEAD
  fi
  # Build artifacts array: declared paths (or "." if none), each tagged with the SHA.
  local arts_json
  if [[ "${#arts[@]}" -eq 0 ]]; then arts=("."); fi
  arts_json="$(printf '%s\n' "${arts[@]}" | jq -R --arg sha "$sha" '{path:., step_commit:$sha}' | jq -s '.')"
  _do_commit() {
    _wp_jq "$id" \
      '(.steps[] | select(.status=="in_progress")) |=
         (.status="succeeded" | .completed_at=$now
          | .actual_result={summary:$sum, artifacts:$arts})
       | .current_step=null | .updated_at=$now' \
      --arg sum "$summary" --arg now "$(_wp_now)" --argjson arts "$arts_json"
  }
  _with_lock _do_commit
}
```
Add arm:
```bash
    commit) shift; cmd_wp_commit "$@"; return $? ;;
```

- [ ] **Step 5: Run — confirm `6 run, 0 failed`**, full suite green.
- [ ] **Step 6: Commit** `feat(spine): commit (stage-all + record SHA + flip step)`.

---

## Task 5: Forward-recovery integration test + `jq` preflight

**Files:** Modify `install.sh`; Create `tests/test_wp_resume.sh`, `tests/test_wp_preflight.sh`.

- [ ] **Step 1: Forward-recovery test** — `tests/test_wp_resume.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
WT="$(mktemp -d)"; export DEPUTY_WT="$WT"
git -C "$WT" init -q; git -C "$WT" config user.email t@t; git -C "$WT" config user.name t
echo seed > "$WT/seed"; git -C "$WT" add -A; git -C "$WT" commit -qm seed

bash "$DEPUTY" start t "goal"
bash "$DEPUTY" plan t --step 1 --purpose "one"
bash "$DEPUTY" plan t --step 2 --purpose "two"
# do step 1
bash "$DEPUTY" set-step t --step 1; echo a > "$WT/a"; bash "$DEPUTY" commit t --summary "one done"
# "interruption": step 2 set active but never committed
bash "$DEPUTY" set-step t --step 2; echo b-partial > "$WT/b"

# resume points at the first uncommitted step = step 2
assert_contains "$(bash "$DEPUTY" resume t)" "2|two" "resume continues at step 2"
# finish step 2
bash "$DEPUTY" commit t --summary "two done"; bash "$DEPUTY" done t
assert_eq "$(bash "$DEPUTY" resume t)" "" "nothing left to resume"
j="$DEPUTY_ROOT/.deputy/waypoints/t/waypoint.json"
assert_eq "$(jq -r '.status' "$j")" "completed" "task completed"
assert_eq "$(jq -r '[.steps[]|select(.status=="succeeded")]|length' "$j")" "2" "both steps succeeded"
rm -rf "$WT"
```

- [ ] **Step 2: jq preflight test** — `tests/test_wp_preflight.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
# A spine verb completes cleanly when jq is present. Use && (not ;) so a bash
# syntax error / crash in the verb fails the assertion instead of passing.
out="$(bash "$DEPUTY" start p2 "g" && echo OK)"
assert_contains "$out" "OK" "start completes cleanly (jq present)"
assert_eq "$([[ -f "$DEPUTY_ROOT/.deputy/waypoints/p2/waypoint.json" ]] && echo yes || echo no)" "yes" "ledger written"
# install.sh carries a jq preflight line.
assert_eq "$([[ "$(grep -c 'jq' "$REPO/install.sh")" -ge 1 ]] && echo yes || echo no)" "yes" "install.sh references jq preflight"
```

- [ ] **Step 3: Add jq preflight to `install.sh`** — in `cmd_link` (or a preflight section), after the runner checks, add:
```bash
  command -v jq >/dev/null 2>&1 || printf 'install: NOTE: jq not found — the checkpoint spine needs jq (apt install jq / brew install jq).\n' >&2
```

- [ ] **Step 4: Run** `bash tests/test_wp_resume.sh` (`6 run, 0 failed`), `bash tests/test_wp_preflight.sh` (green), then `bash tests/run.sh; echo exit=$?` all green.
- [ ] **Step 5: Commit** `test(spine): forward-recovery + jq preflight`.

---

## Task 6: Orchestrator `SKILL.md` wiring (authored prompt)

**Files:** Modify `skills/deputy/SKILL.md`. (Prompt artifact — validated by inspection, not unit tests.)

- [ ] **Step 1: Rewrite the SKILL's execution section** so the orchestrator drives the spine for *every* item:
  1. `deputy start <slug> "<item>"` (or, if `.deputy/waypoints/<slug>/waypoint.json` exists, **resume**: `git -C .deputy/wt reset --hard HEAD && git -C .deputy/wt clean -fd`, then continue from `deputy resume <slug>`).
  2. Decompose → `deputy plan <slug> --step <n> --purpose …` (1 step if simple, N if complex) → **plan xReview** (Gemini reviews the step list before execution).
  3. For each step from `deputy steps`/`deputy resume`: `deputy set-step` → do the work in `.deputy/wt` → **implementation xReview** (Gemini on staged diff) → `deputy commit <slug> --summary …`. Retries (incl. review rejections) bounded by `max_retries` (2), then surface/fail.
  4. `deputy done <slug>` → `deputy set "<item-line>" done` → PR/leave branch → `deputy wt-remove`.
  Add the **hard rules**: never hand-edit `.deputy/waypoints/`; commits stage all changes (don't rely on per-file declaration); author≠reviewer; no step/plan/design advances without a Gemini PASS.

- [ ] **Step 2: Sanity-check** every referenced subcommand exists:
```bash
for c in start plan set-step commit steps resume done wt-create wt-remove set; do
  grep -qE "^[[:space:]]*${c}\)" bin/deputy.sh && echo "ok $c" || echo "MISSING $c"
done
```
Expected: all `ok`.

- [ ] **Step 3: Commit** `feat(skill): orchestrator drives the checkpoint spine + xReview gates`.

---

## Task 7: Finalize

- [ ] **Step 1: Full suite** — `bash tests/run.sh; echo exit=$?` → all green.
- [ ] **Step 2: Manual lifecycle smoke** (real git temp repo):
```bash
d=$(mktemp -d); export DEPUTY_ROOT="$d" DEPUTY_WT="$d/wt"
git init -q "$d/wt"; git -C "$d/wt" config user.email t@t; git -C "$d/wt" config user.name t
( cd "$d/wt" && echo x>x && git add -A && git commit -qm seed )
deputy start s1 "demo"; deputy plan s1 --step 1 --purpose "do x"; deputy set-step s1 --step 1
echo y > "$d/wt/y"; deputy commit s1 --summary "did x"; deputy done s1
deputy _wp_show s1 | jq '{status, steps:[.steps[]|{id,status}]}'; cat "$d/.deputy/waypoints/s1/STATUS.md"
unset DEPUTY_ROOT DEPUTY_WT
```
Expected: status `completed`, step 1 `succeeded`, STATUS.md shows `[x] 1 do x`.
- [ ] **Step 3: Plan-level + holistic xReview** — per the xReview rule, run `gemini -p "Review ... $(git diff master..HEAD -- bin/ tests/ skills/ install.sh)"`; fix CRITICAL/WARNING.
- [ ] **Step 4: Commit** any review fixes; the branch is ready to merge.

---

## Self-Review (completed during authoring)
**Spec coverage:** slim ledger + `.deputy/waypoints/<id>/{waypoint.json,STATUS.md}` (T1) ✓; verbs start/done (T1), plan/steps (T2), set-step/resume (T3), commit stage-all+SHA (T4) ✓; forward-recovery resume + purge-dirty (T5 test + T6 SKILL) ✓; jq preflight (T5) ✓; xReview gates design/plan/impl + retry-bounds-review (T6 SKILL, T7 review) ✓; archive-not-delete — *note:* `archive/` dir is created by a future cleanup item, not this plan (resume/`done` don't delete); uniform spine via SKILL (T6) ✓; claude-first inline steps (T6) ✓.
**Deferred (per design §10):** suspension states, cross-provider routing, parallel preemption.
**Placeholder scan:** none — every step has runnable code/commands + expected output.
**Type/name consistency:** `_wp_dir/_wp_task_dir/_wp_json/_wp_now/_wp_jq/_wp_render_status/_wp_require_jq` and verbs `start/plan/set-step/commit/steps/resume/done` (+ hidden `_wp_show`) are used identically across tasks; `current_step` is a string id or null throughout; step `status ∈ {pending,in_progress,succeeded}` everywhere; `DEPUTY_WT` override defined in T4 before its test uses it.
