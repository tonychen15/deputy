#!/usr/bin/env bash
# #108: passive, read-only per-task progress view ('deputy watch <id> --once' /
# 'deputy progress <id>'). Verifies Tier 1 (step %, current step, done-so-far,
# time-since-update, run-log tail), Tier 2 (ETA band), graceful edge cases, and
# the HARD read-only constraint (no follow/signal/IPC with the worker).
source "$(dirname "$0")/lib.sh"
setup_repo

WPDIR="$DEPUTY_ROOT/.deputy/waypoints"
mkdir -p "$WPDIR"

iso() { date -d "$1" -Iseconds; }   # GNU date; the suite already assumes GNU date

# ── a PAST completed ledger, for ETA history (durations 10m then 20m) ─────────
past_slug="past-eta-history"
mkdir -p "$WPDIR/$past_slug"
cat > "$WPDIR/$past_slug/waypoint.json" <<EOF
{
  "task_id": "$past_slug", "goal": "past", "status": "completed",
  "created_at": "$(iso '40 minutes ago')", "updated_at": "$(iso '10 minutes ago')",
  "current_step": null,
  "steps": [
    {"id":"1","purpose":"p1","status":"succeeded","completed_at":"$(iso '30 minutes ago')",
     "actual_result":{"summary":"did one","artifacts":[{"path":".","step_commit":"aaaaaaaa1111"}]}},
    {"id":"2","purpose":"p2","status":"succeeded","completed_at":"$(iso '10 minutes ago')",
     "actual_result":{"summary":"did two","artifacts":[{"path":".","step_commit":"bbbbbbbb2222"}]}}
  ]
}
EOF

# ── the CURRENT multi-step ledger: 3 steps, 1 succeeded, step 2 in_progress ───
bash "$DEPUTY" add "multi step current task" >/dev/null
cid="$(bash "$DEPUTY" list --porcelain | awk -F'|' '/multi step current task/{print $3}')"
cslug="$(bash "$DEPUTY" slug "$cid")"
mkdir -p "$WPDIR/$cslug"
cat > "$WPDIR/$cslug/waypoint.json" <<EOF
{
  "task_id": "$cslug", "goal": "current multi", "status": "in_progress",
  "created_at": "$(iso '15 minutes ago')", "updated_at": "$(iso '2 minutes ago')",
  "current_step": "2",
  "steps": [
    {"id":"1","purpose":"first thing","status":"succeeded","completed_at":"$(iso '8 minutes ago')",
     "actual_result":{"summary":"finished the first thing","artifacts":[{"path":".","step_commit":"deadbeef9999"}]}},
    {"id":"2","purpose":"second thing underway","expected_result":"second done","status":"in_progress"},
    {"id":"3","purpose":"third thing","status":"pending"}
  ]
}
EOF

out="$(bash "$DEPUTY" watch "$cid" --once 2>&1)"
assert_contains "$out" "step 2 of 3"                 "shows current step of total"
assert_contains "$out" "1 of 3 succeeded"            "shows succeeded count"
assert_contains "$out" "~50%"                        "half-credit: (2*1+1)/(2*3)=50%"
assert_contains "$out" "second thing underway"       "shows current step purpose"
assert_contains "$out" "second done"                 "shows current step expected_result"
assert_contains "$out" "finished the first thing"    "done-so-far shows succeeded summary"
assert_contains "$out" "deadbeef"                    "done-so-far shows short commit SHA"
assert_contains "$out" "ETA (rough band)"            "ETA band computed from history"
assert_contains "$out" "run log"                     "run-log tail section present"

# 'deputy progress <id>' is an alias for the same view; '--once <id>' order too.
assert_contains "$(bash "$DEPUTY" progress "$cid" 2>&1)"    "step 2 of 3" "progress alias works"
assert_contains "$(bash "$DEPUTY" watch --once "$cid" 2>&1)" "step 2 of 3" "id after --once works"

# ── grown-denominator guard: all planned steps succeeded but status not done ──
bash "$DEPUTY" add "single step nearly done" >/dev/null
sid="$(bash "$DEPUTY" list --porcelain | awk -F'|' '/single step nearly done/{print $3}')"
sslug="$(bash "$DEPUTY" slug "$sid")"
mkdir -p "$WPDIR/$sslug"
cat > "$WPDIR/$sslug/waypoint.json" <<EOF
{
  "task_id": "$sslug", "goal": "one", "status": "in_progress",
  "created_at": "$(iso '5 minutes ago')", "updated_at": "$(iso '1 minute ago')",
  "current_step": null,
  "steps": [
    {"id":"1","purpose":"only step","status":"succeeded","completed_at":"$(iso '1 minute ago')",
     "actual_result":{"summary":"only step done","artifacts":[{"path":".","step_commit":"cafe12345678"}]}}
  ]
}
EOF
gout="$(bash "$DEPUTY" progress "$sid" 2>&1)"
assert_contains "$gout" ">=99%" "grown-denominator guard: never show ~100% until status=completed"

# ── ETA graceful when there is no usable history (isolated root) ──────────────
ISO_TMP="$(mktemp -d)"
cp "$REPO/templates/BACKLOG.md" "$ISO_TMP/BACKLOG.md"; mkdir -p "$ISO_TMP/.deputy/waypoints"
DEPUTY_ROOT="$ISO_TMP" bash "$DEPUTY" add "lonely task" >/dev/null
lid="$(DEPUTY_ROOT="$ISO_TMP" bash "$DEPUTY" list --porcelain | awk -F'|' '/lonely task/{print $3}')"
lslug="$(DEPUTY_ROOT="$ISO_TMP" bash "$DEPUTY" slug "$lid")"
mkdir -p "$ISO_TMP/.deputy/waypoints/$lslug"
cat > "$ISO_TMP/.deputy/waypoints/$lslug/waypoint.json" <<EOF
{ "task_id":"$lslug","goal":"lonely","status":"in_progress",
  "created_at":"$(iso '3 minutes ago')","updated_at":"$(iso '1 minute ago')","current_step":"1",
  "steps":[{"id":"1","purpose":"only","status":"in_progress"}] }
EOF
lout="$(DEPUTY_ROOT="$ISO_TMP" bash "$DEPUTY" progress "$lid" 2>&1)"
assert_contains "$lout" "ETA: unknown" "ETA degrades gracefully with no history"

# ── missing-waypoint (task exists but never started a ledger) ─────────────────
bash "$DEPUTY" add "no ledger task" >/dev/null
nid="$(bash "$DEPUTY" list --porcelain | awk -F'|' '/no ledger task/{print $3}')"
nout="$(bash "$DEPUTY" progress "$nid" 2>&1)"
assert_contains "$nout" "no waypoint ledger yet" "missing ledger handled gracefully"

# ── torn-write resilience: malformed JSON must not crash ──────────────────────
printf '{ "steps": [ this is not valid json' > "$WPDIR/$cslug/waypoint.json.bad"
cp "$WPDIR/$cslug/waypoint.json.bad" "$WPDIR/$cslug/waypoint.json"
tout="$(bash "$DEPUTY" progress "$cid" 2>&1)"; trc=$?
assert_contains "$tout" "being updated" "torn/partial JSON handled softly"
assert_eq "$trc" "0" "torn JSON is a soft (rc 0), not a crash"

# ── invalid id rejected ──────────────────────────────────────────────────────
bash "$DEPUTY" progress "notanid" >/dev/null 2>&1
assert_eq "$?" "2" "non-numeric id rejected with rc 2"

# ── HARD read-only constraint: the progress code path must not follow, signal, ─
# ── or otherwise touch the worker. Grep the relevant function bodies. ─────────
body="$(awk '/^cmd_progress\(\) \{/,/^\}/' "$DEPUTY"; awk '/^_progress_log_tail\(\) \{/,/^\}/' "$DEPUTY")"
assert_contains "$body" "tail -n" "log tail is a one-shot 'tail -n' read"
for bad in "tail -f" "--pid" "kill " "kill_group" "SIGTERM" "SIGKILL" "pkill" " ps " "git commit" "git merge" "mktemp"; do
  if [[ "$body" == *"$bad"* ]]; then
    assert_eq "found:$bad" "" "read-only violation: progress path must not use '$bad'"
  else
    assert_eq "ok" "ok" "progress path is free of '$bad'"
  fi
done
