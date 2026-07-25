#!/usr/bin/env bash
# tests/test_pending_merge.sh — #112: a merge-ready task must NEVER enter the human's pickup
# queue. Deputy owns the merge and makes it safe.
#
# Before this, a merge the runner could not perform left the item 'surfaced' FOREVER: nothing
# ever retried it, because _auto_merge_ready only runs for the item that just ran. Now a merge
# blocked by the human's working tree parks in the non-attention 'pending-merge' state and the
# runner drains it at the top of every tick — including ticks that run a DIFFERENT item. Only
# outcomes deputy genuinely cannot resolve (a real content conflict, an unresolvable branch, or
# a merge still blocked after merge_retry_strikes attempts) ever reach the human.
source "$(dirname "$0")/lib.sh"

# $1..: extra .deputy/config lines. Mock commits api-<id>.js on the branch (disjoint from the
# human's frontend.js) so blocking is controlled purely by what the test dirties.
_pm_setup() {  # sets PMR (repo), PMM (mock)
  PMR="$(mktemp -d)"; PMM="$(mktemp)"
  mkdir -p "$PMR/.deputy"; cp "$REPO/templates/BACKLOG.md" "$PMR/BACKLOG.md"
  { printf 'auto_merge=1\nwatchdog_mins=0\nmax_items=1\n'; [[ $# -gt 0 ]] && printf '%s\n' "$@"; } > "$PMR/.deputy/config"
  git -C "$PMR" init -q -b master; git -C "$PMR" config user.email t@t; git -C "$PMR" config user.name t
  printf 'api v1\n' > "$PMR/api.js"; printf 'frontend v1\n' > "$PMR/frontend.js"
  git -C "$PMR" add -A; git -C "$PMR" commit -q -m init
  cat > "$PMM" <<MOCK
#!/usr/bin/env bash
item="\$1"; root="$PMR"; DEP="$DEPUTY"
id=\$(printf '%s' "\$item" | grep -oE '#[0-9]+' | head -1 | tr -d '#'); slug="task-\$id"
git -C "\$root" worktree add -q "\$root/.deputy/wt" -b "deputy/\$slug" 2>/dev/null
echo "api from task \$id" > "\$root/.deputy/wt/api-\$id.js"
git -C "\$root/.deputy/wt" add -A; git -C "\$root/.deputy/wt" commit -q -m "task \$id"
mkdir -p "\$root/.deputy/waypoints/\$slug"; printf '{"steps":[{"status":"succeeded"}]}' > "\$root/.deputy/waypoints/\$slug/waypoint.json"
DEPUTY_ROOT="\$root" bash "\$DEP" set "\$item" surfaced --ready-merge --branch="deputy/\$slug" >/dev/null 2>&1
DEPUTY_ROOT="\$root" bash "\$DEP" wt-remove >/dev/null 2>&1
MOCK
  chmod +x "$PMM"
}
_pm_add() { DEPUTY_NO_AUTORUN=1 DEPUTY_ROOT="$PMR" bash "$DEPUTY" add "$1" --p1 >/dev/null; }
_pm_run() { DEPUTY_ORCHESTRATOR_CMD="$PMM" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true \
            DEPUTY_ALLOW_ANY_BRANCH=1 DEPUTY_ROOT="$PMR" timeout 40 bash "$DEPUTY" run --once >"$PMR/.runout" 2>&1; }
_pm_state() { grep -o "^.\[#$1\]" "$PMR/BACKLOG.md" 2>/dev/null | head -1 | cut -c1; }
_pm_landed() { git -C "$PMR" show "master:api-$1.js" 2>/dev/null || echo MISSING; }

# ── A) A transient block PARKS the item instead of surfacing it ──────────────────────
# A staged change makes git's ort strategy refuse ANY merge, even a non-overlapping one.
_pm_setup; _pm_add "task one"
printf 'wip\n' >> "$PMR/frontend.js"; git -C "$PMR" add frontend.js
_pm_run
assert_eq "$(_pm_state 1)" "&" "transient block: item parks in pending-merge"
assert_eq "$(_pm_landed 1)" "MISSING" "transient block: nothing merged yet"
assert_eq "$(test -f "$PMR/.deputy/ready-merge-1" && echo kept || echo GONE)" "kept" "transient block: ready-merge marker retained for the drain"
assert_contains "$(DEPUTY_ROOT="$PMR" bash "$DEPUTY" list surfaced)" "0 tasks" "transient block: nothing put in the human's pickup queue"

# ── B) THE SCENARIO: the drain lands the parked merge on a tick that runs ANOTHER item ─
git -C "$PMR" commit -q -m "human: frontend wip"     # blocker cleared, no conflict with the branch
_pm_add "task two"
_pm_run
assert_eq "$(_pm_state 1)" "+" "drain: the parked item is merged and marked done"
assert_eq "$(_pm_landed 1)" "api from task 1" "drain: the parked branch actually landed in master"
assert_eq "$(_pm_state 2)" "+" "drain: the newly-run item also completed on the same tick"
assert_contains "$(cat "$PMR/.runout")" "pending-merge drain: #1" "drain: reported what it landed"
assert_eq "$(git -C "$PMR" show master:frontend.js | tr '\n' ' ')" "frontend v1 wip " "drain: the human's committed work is intact"

# ── C) A dirty tree must never STALL the queue ───────────────────────────────────────
_pm_setup; _pm_add "task one"
printf 'wip\n' >> "$PMR/frontend.js"; git -C "$PMR" add frontend.js   # stays blocked all run
_pm_run
_pm_add "task two"
_pm_run
assert_eq "$(_pm_state 1)" "&" "still-blocked: item remains parked"
assert_eq "$(_pm_state 2)" "&" "still-blocked: the next item ran and parked too (queue kept moving)"
assert_contains "$(cat "$PMR/.runout")" "SPAWN" "still-blocked: a blocked merge did not prevent the next item from running"

# ── D) A real content conflict surfaces IMMEDIATELY — deputy cannot resolve it ───────
# Pre-detection uses `git merge-tree`, which works even though the tree is dirty here.
_pm_setup; _pm_add "task one"
_pm_run                                                    # lands cleanly first
git -C "$PMR" checkout -q -b deputy/task-9 master
printf 'conflicting\n' > "$PMR/api.js"; git -C "$PMR" add -A; git -C "$PMR" commit -q -m branch-side
git -C "$PMR" checkout -q master
printf 'master side\n' > "$PMR/api.js"; git -C "$PMR" add -A; git -C "$PMR" commit -q -m master-side
_pm_add "conflicting task"
DEPUTY_ROOT="$PMR" bash "$DEPUTY" set "$(grep '^\[#2\]' "$PMR/BACKLOG.md")" surfaced --ready-merge --branch=deputy/task-9 >/dev/null 2>&1
printf 'dirty too\n' >> "$PMR/frontend.js"                 # dirty AS WELL: the conflict must win
out="$(DEPUTY_ROOT="$PMR" bash "$DEPUTY" pickup 2 2>&1)"
assert_contains "$out" "conflicts with master" "conflict: reported as a conflict, not as a dirty tree"
assert_eq "$(_pm_state 2)" "?" "conflict: surfaced immediately for the human (never parked)"
assert_eq "$(test -f "$PMR/.deputy/ready-merge-2" && echo present || echo dropped)" "dropped" \
  "conflict: ready-merge marker dropped so it isn't advertised as 'ready to merge'"
assert_eq "$(test -f "$PMR/.git/MERGE_HEAD" && echo present || echo clean)" "clean" "conflict: no half-finished merge left behind"

# ── E) Escalation: a merge blocked forever eventually reaches the human ──────────────
_pm_setup "merge_retry_strikes=2"; _pm_add "task one"
printf 'wip\n' >> "$PMR/frontend.js"; git -C "$PMR" add frontend.js
_pm_run                                             # strike 1 -> parked
assert_eq "$(_pm_state 1)" "&" "escalation: parked after the first failure"
_pm_add "task two"; _pm_run                         # drain retries -> strike 2 -> cap reached
assert_eq "$(_pm_state 1)" "?" "escalation: surfaced once merge_retry_strikes is reached"
assert_contains "$(DEPUTY_ROOT="$PMR" bash "$DEPUTY" list surfaced)" "MERGE STILL BLOCKED after 2 attempts" \
  "escalation: the surfaced item carries a discoverable explanation"

# ── F) pickup on a parked item merges it now rather than requeueing it as work ───────
_pm_setup; _pm_add "task one"
printf 'wip\n' >> "$PMR/frontend.js"; git -C "$PMR" add frontend.js
_pm_run
assert_eq "$(_pm_state 1)" "&" "pickup: precondition — item is parked"
git -C "$PMR" commit -q -m "human: done with that"
out="$(DEPUTY_ROOT="$PMR" bash "$DEPUTY" pickup 1 2>&1)"
assert_contains "$out" "merged deputy/task-1" "pickup: merges a parked item on demand"
assert_eq "$(_pm_state 1)" "+" "pickup: parked item ends done, not requeued to waiting"

# ── G) pending-merge is non-runnable and non-attention ──────────────────────────────
_pm_setup; _pm_add "task one"
printf 'wip\n' >> "$PMR/frontend.js"; git -C "$PMR" add frontend.js
_pm_run
_pm_add "task two"
assert_contains "$(DEPUTY_ROOT="$PMR" bash "$DEPUTY" pick)" "task two" "non-runnable: cmd_pick skips a parked item and picks real work"
assert_contains "$(DEPUTY_ROOT="$PMR" bash "$DEPUTY" status)" "pending-merge: 1" "visible: status counts parked merges"
assert_contains "$(DEPUTY_ROOT="$PMR" bash "$DEPUTY" list pending-merge)" "action:  none" \
  "non-attention: the detail block asks the human for nothing"
assert_contains "$(grep -E '^### ' "$PMR/BACKLOG.md" | tr '\n' '|')" "### Pending merge (1)" "regroup: parked items get their own section"
# survives a regroup — _regroup_backlog's state case has no default arm, so a missing bucket
# would silently DROP the item from BACKLOG.md entirely
_pm_add "task three"
assert_eq "$(_pm_state 1)" "&" "regroup: the parked item survives a BACKLOG rewrite"

# ── H) A parked item whose branch becomes unresolvable must SURFACE, not stay parked ──
# pending-merge is a non-attention state, so an item nothing can ever complete would otherwise
# sit silent forever — the one way this feature could swallow work.
_pm_setup; _pm_add "task one"
printf 'wip\n' >> "$PMR/frontend.js"; git -C "$PMR" add frontend.js
_pm_run
assert_eq "$(_pm_state 1)" "&" "orphan: precondition — item is parked"
rm -f "$PMR/.deputy/ready-merge-1"; git -C "$PMR" branch -D deputy/task-1 >/dev/null 2>&1
out="$(DEPUTY_ROOT="$PMR" bash "$DEPUTY" pickup 1 2>&1)"
assert_contains "$out" "unresolvable" "orphan: pickup reports the unresolvable branch"
assert_eq "$(_pm_state 1)" "?" "orphan: item is surfaced, never left silently parked"
