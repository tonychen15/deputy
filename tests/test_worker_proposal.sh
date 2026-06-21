#!/usr/bin/env bash
# tests/test_worker_proposal.sh — #53: worker-initiated `deputy add` is gated as a
# human-approval *proposal* (surfaced + .deputy/proposed-<id> marker, no autorun),
# while a human's add is unchanged.
source "$(dirname "$0")/lib.sh"

proc_start() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//' || true; }

# A LIVE active-run lock owned by $pid (so _is_worker_context / _active_run_live pass).
write_active_lock() {
  local root="$1" pid="$2" start="$3"
  mkdir -p "$root/.deputy/active-run.lock"
  printf '%s\n' "$pid"   > "$root/.deputy/active-run.lock/pid"
  printf '%s\n' "$start" > "$root/.deputy/active-run.lock/start_time"
  printf 'run\n'         > "$root/.deputy/active-run.lock/owner"
  printf 'item\n'        > "$root/.deputy/active-run.lock/item"
}

make_autorun_mock() {  # touches $1 when invoked
  local marker="$1" mock; mock="$(mktemp)"
  printf '#!/usr/bin/env bash\ntouch "%s"\n' "$marker" > "$mock"; chmod +x "$mock"
  printf '%s' "$mock"
}

marker_count() { ls "$DEPUTY_ROOT/.deputy"/proposed-* 2>/dev/null | wc -l | tr -d ' '; }
proposal_id() { bash "$DEPUTY" list --surfaced | grep -F "$1" | head -1 | cut -d'|' -f3; }

# ── Test 1: worker add → surfaced + id + marker, NO autorun, "proposed" message ──
setup_repo
sleep 300 & WPID=$!
write_active_lock "$DEPUTY_ROOT" "$WPID" "$(proc_start "$WPID")"
FIRED="$DEPUTY_ROOT/.autorun.fired"; MOCK="$(make_autorun_mock "$FIRED")"
out="$(DEPUTY_GUARDED=1 DEPUTY_ACTIVE_RUN_PID=$WPID DEPUTY_NO_AUTORUN=0 DEPUTY_AUTORUN_CMD="$MOCK" \
        bash "$DEPUTY" add "worker found a bug" --p2)"
assert_contains "$out" "proposed" "worker add reports a proposal"
lst="$(bash "$DEPUTY" list)"
assert_contains "$lst" "surfaced|P2|" "worker add lands surfaced (not waiting)"
assert_contains "$lst" "worker found a bug" "proposal description present"
pid_id="$(proposal_id "worker found a bug")"
assert_eq "$([[ "$pid_id" =~ ^[0-9]+$ ]] && echo yes || echo no)" "yes" "proposal has a numeric id"
assert_eq "$(test -f "$DEPUTY_ROOT/.deputy/proposed-$pid_id" && echo yes || echo no)" "yes" \
  "worker add writes the proposed-<id> marker"
assert_eq "$(test -f "$FIRED" && echo yes || echo no)" "no" "worker add does NOT autorun"
rm -f "$MOCK"; kill "$WPID" 2>/dev/null

# ── Test 2: human add (no worker env) → waiting + autorun + no marker ────────────
setup_repo
FIRED="$DEPUTY_ROOT/.autorun.fired"; MOCK="$(make_autorun_mock "$FIRED")"
DEPUTY_NO_AUTORUN=0 DEPUTY_AUTORUN_CMD="$MOCK" bash "$DEPUTY" add "human task" --p1
assert_contains "$(bash "$DEPUTY" list)" "waiting|P1|" "human add lands waiting"
assert_eq "$(test -f "$FIRED" && echo yes || echo no)" "yes" "human add DOES autorun"
assert_eq "$(marker_count)" "0" "human add writes no proposal marker"
rm -f "$MOCK"

# ── Test 2b: the proposal NOTIFY path runs (sync, notify enabled) w/o breaking add ─
setup_repo
printf 'notify=desktop\n' > "$DEPUTY_ROOT/.deputy/config"   # enable a channel so _notify runs
sleep 300 & WPID=$!
write_active_lock "$DEPUTY_ROOT" "$WPID" "$(proc_start "$WPID")"
DEPUTY_GUARDED=1 DEPUTY_ACTIVE_RUN_PID=$WPID DEPUTY_NOTIFY_SYNC=1 \
  bash "$DEPUTY" add "notify path task" --p2
kill "$WPID" 2>/dev/null
assert_contains "$(bash "$DEPUTY" list)" "surfaced|P2|" "worker add with notify enabled (sync) still proposes"
assert_contains "$(bash "$DEPUTY" list)" "notify path task" "notify-enabled proposal description present"
assert_eq "$(marker_count)" "1" "notify-enabled worker add writes exactly one marker"

# ── Test 3: stale worker env (guarded+pid but NO live lock) → behaves like human ─
setup_repo
sleep 0.1 & DEADPID=$!; wait "$DEADPID" 2>/dev/null   # a guaranteed-dead, just-reaped pid
FIRED="$DEPUTY_ROOT/.autorun.fired"; MOCK="$(make_autorun_mock "$FIRED")"
DEPUTY_GUARDED=1 DEPUTY_ACTIVE_RUN_PID=$DEADPID DEPUTY_NO_AUTORUN=0 DEPUTY_AUTORUN_CMD="$MOCK" \
  bash "$DEPUTY" add "stale env task" --p2
assert_contains "$(bash "$DEPUTY" list)" "waiting|P2|" "stale worker env does not gate (waiting)"
assert_eq "$(marker_count)" "0" "stale env: no marker"
assert_eq "$(test -f "$FIRED" && echo yes || echo no)" "yes" "stale env autoruns like a human add"
rm -f "$MOCK"

# ── Test 4: live lock but DEPUTY_ACTIVE_RUN_PID mismatches lock pid → like human ─
setup_repo
sleep 300 & WPID=$!
write_active_lock "$DEPUTY_ROOT" "$WPID" "$(proc_start "$WPID")"
FIRED="$DEPUTY_ROOT/.autorun.fired"; MOCK="$(make_autorun_mock "$FIRED")"
DEPUTY_GUARDED=1 DEPUTY_ACTIVE_RUN_PID=123456 DEPUTY_NO_AUTORUN=0 DEPUTY_AUTORUN_CMD="$MOCK" \
  bash "$DEPUTY" add "pid mismatch task" --p2
assert_contains "$(bash "$DEPUTY" list)" "waiting|P2|" "pid mismatch is not worker context (waiting)"
assert_eq "$(marker_count)" "0" "pid mismatch: no marker"
assert_eq "$(test -f "$FIRED" && echo yes || echo no)" "yes" "pid mismatch autoruns like a human add"
rm -f "$MOCK"; kill "$WPID" 2>/dev/null

# ── Test 5: approve (set waiting) flips to waiting AND removes the marker ─────────
setup_repo
sleep 300 & WPID=$!
write_active_lock "$DEPUTY_ROOT" "$WPID" "$(proc_start "$WPID")"
DEPUTY_GUARDED=1 DEPUTY_ACTIVE_RUN_PID=$WPID bash "$DEPUTY" add "approve me" --p2
kill "$WPID" 2>/dev/null
aid="$(proposal_id "approve me")"
assert_eq "$([[ "$aid" =~ ^[0-9]+$ ]] && echo yes || echo no)" "yes" "approve-me: proposal has numeric id"
assert_eq "$(test -f "$DEPUTY_ROOT/.deputy/proposed-$aid" && echo yes || echo no)" "yes" \
  "approve-me: marker EXISTS before approve (precondition)"
aln="$(grep -F "approve me" "$DEPUTY_ROOT/BACKLOG.md")"
bash "$DEPUTY" set "$aln" waiting >/dev/null
assert_contains "$(bash "$DEPUTY" list)" "waiting|P2|" "approved proposal -> waiting"
assert_eq "$(test -f "$DEPUTY_ROOT/.deputy/proposed-$aid" && echo yes || echo no)" "no" \
  "approve removes the proposal marker"

# ── Test 6: reject (set cancelled) removes the marker ───────────────────────────
setup_repo
sleep 300 & WPID=$!
write_active_lock "$DEPUTY_ROOT" "$WPID" "$(proc_start "$WPID")"
DEPUTY_GUARDED=1 DEPUTY_ACTIVE_RUN_PID=$WPID bash "$DEPUTY" add "reject me" --p2
kill "$WPID" 2>/dev/null
rid="$(proposal_id "reject me")"
assert_eq "$([[ "$rid" =~ ^[0-9]+$ ]] && echo yes || echo no)" "yes" "reject-me: proposal has numeric id"
assert_eq "$(test -f "$DEPUTY_ROOT/.deputy/proposed-$rid" && echo yes || echo no)" "yes" \
  "reject-me: marker EXISTS before reject (precondition)"
rln="$(grep -F "reject me" "$DEPUTY_ROOT/BACKLOG.md")"
bash "$DEPUTY" set "$rln" cancelled >/dev/null
assert_eq "$(test -f "$DEPUTY_ROOT/.deputy/proposed-$rid" && echo yes || echo no)" "no" \
  "reject removes the proposal marker"

# ── Test 7: _blocking_surfaced_count excludes proposals, counts blocked items ────
setup_repo
bash "$DEPUTY" add "blocked item" --p1
bln="$(grep -F "blocked item" "$DEPUTY_ROOT/BACKLOG.md")"
bash "$DEPUTY" set "$bln" surfaced >/dev/null   # a genuine blocked surface (no marker)
sleep 300 & WPID=$!
write_active_lock "$DEPUTY_ROOT" "$WPID" "$(proc_start "$WPID")"
DEPUTY_GUARDED=1 DEPUTY_ACTIVE_RUN_PID=$WPID bash "$DEPUTY" add "a proposal" --p2
kill "$WPID" 2>/dev/null
total="$(bash "$DEPUTY" status | grep '^surfaced:' | awk '{print $2}')"
assert_eq "$total" "2" "status surfaced count includes both (blocked + proposal)"
bcount="$(source "$DEPUTY"; _blocking_surfaced_count)"
assert_eq "$bcount" "1" "_blocking_surfaced_count excludes the proposal (only the blocker counts)"

# ── Test 8: a surfaced item with NO id counts as blocking (conservative) ─────────
setup_repo
printf '? raw blocker no id\n' >> "$DEPUTY_ROOT/BACKLOG.md"
bcount="$(source "$DEPUTY"; _blocking_surfaced_count)"
assert_eq "$bcount" "1" "surfaced item without an id counts as blocking"

# ── Test 9 (#60): a ready-merge surface is excluded from the blocking count ──────
setup_repo
bash "$DEPUTY" add "rm blocker" --p1
bash "$DEPUTY" add "ready item 60" --p2
bid="$(bash "$DEPUTY" list | grep -F 'rm blocker' | cut -d'|' -f3)"
rid="$(bash "$DEPUTY" list | grep -F 'ready item 60' | cut -d'|' -f3)"
bash "$DEPUTY" set "$bid" surfaced >/dev/null              # genuine blocked surface (no marker)
bash "$DEPUTY" set "$rid" surfaced --ready-merge >/dev/null
assert_eq "$(test -f "$DEPUTY_ROOT/.deputy/ready-merge-$rid" && echo yes || echo no)" "yes" \
  "set surfaced --ready-merge writes the ready-merge-<id> marker"
bcount="$(source "$DEPUTY"; _blocking_surfaced_count)"
assert_eq "$bcount" "1" "_blocking_surfaced_count excludes the ready-merge surface (only the blocker counts)"
bash "$DEPUTY" set "$rid" done >/dev/null
assert_eq "$(test -f "$DEPUTY_ROOT/.deputy/ready-merge-$rid" && echo yes || echo no)" "no" \
  "leaving surfaced removes the ready-merge marker"

# ── Test 10 (#60): clean removes a stale ready-merge marker for the freed id ─────
# (clean-by-id refuses surfaced items, so a leftover marker can only be reaped when the
# item is cleaned in a terminal state — the defensive net for id reuse.)
setup_repo
bash "$DEPUTY" add "done item 60" --p2
did="$(bash "$DEPUTY" list | grep -F 'done item 60' | cut -d'|' -f3)"
bash "$DEPUTY" set "$did" done >/dev/null
touch "$DEPUTY_ROOT/.deputy/ready-merge-$did"      # simulate a stale marker
bash "$DEPUTY" clean "$did" >/dev/null
assert_eq "$(test -f "$DEPUTY_ROOT/.deputy/ready-merge-$did" && echo yes || echo no)" "no" \
  "clean reaps a stale ready-merge marker for the freed id"

# ── Test 9: clean removes a (leaked) proposal marker on both paths ───────────────
setup_repo
bash "$DEPUTY" add "to clean by id" --p2
cid="$(bash "$DEPUTY" list | grep -F "to clean by id" | cut -d'|' -f3)"
cln="$(grep -F "to clean by id" "$DEPUTY_ROOT/BACKLOG.md")"
bash "$DEPUTY" set "$cln" cancelled >/dev/null
touch "$DEPUTY_ROOT/.deputy/proposed-$cid"        # simulate a leaked marker
bash "$DEPUTY" clean "$cid" >/dev/null
assert_eq "$(test -f "$DEPUTY_ROOT/.deputy/proposed-$cid" && echo yes || echo no)" "no" \
  "clean <id> removes the proposal marker"

setup_repo
bash "$DEPUTY" add "to clean by state" --p2
sid="$(bash "$DEPUTY" list | grep -F "to clean by state" | cut -d'|' -f3)"
sln="$(grep -F "to clean by state" "$DEPUTY_ROOT/BACKLOG.md")"
bash "$DEPUTY" set "$sln" cancelled >/dev/null
touch "$DEPUTY_ROOT/.deputy/proposed-$sid"
bash "$DEPUTY" clean --state cancelled >/dev/null
assert_eq "$(test -f "$DEPUTY_ROOT/.deputy/proposed-$sid" && echo yes || echo no)" "no" \
  "clean --state removes the proposal marker"
