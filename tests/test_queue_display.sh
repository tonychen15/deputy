#!/usr/bin/env bash
# Verifies the post-completion queue table: 'deputy set <line> done' prints an
# aligned table of waiting + paused + deferred items (runnable first, then
# deferred; priority + FIFO within groups), with per-state header counts; prints
# "queue empty" when none; and the run loop relays exactly one table per done
# item (no double-print). Failures must NOT print the table (done-only).
source "$(dirname "$0")/lib.sh"
export DEPUTY_NOTIFY_SYNC=1   # deterministic: no backgrounded notify

line_of() { grep -F -- "$1" "$DEPUTY_ROOT/BACKLOG.md" | head -1; }

# --- table content, states, ordering (incl. FIFO ties) on a done-transition ---
# Add order matters for FIFO assertions: alpha(P2) before epsilon(P2);
# delta(P3) before zeta(P3). No explicit `deputy list` — the helper self-allocates
# ids, so even unallocated backlogs must render real #N (not #?).
setup_repo
bash "$DEPUTY" add "alpha task"   --p2  # waiting  (P2, earlier)
bash "$DEPUTY" add "epsilon task" --p2  # waiting  (P2, later  -> after alpha)
bash "$DEPUTY" add "beta task"    --p0  # waiting  (P0)
bash "$DEPUTY" add "gamma task"   --p1  # -> paused (P1)
bash "$DEPUTY" add "delta task"   --p3  # -> deferred (P3, earlier)
bash "$DEPUTY" add "zeta task"    --p3  # -> deferred (P3, later -> after delta)
bash "$DEPUTY" add "trigger task" --p0  # -> done (fires the table)
bash "$DEPUTY" set "$(line_of 'gamma task')" paused   >/dev/null
bash "$DEPUTY" set "$(line_of 'delta task')" deferred >/dev/null
bash "$DEPUTY" set "$(line_of 'zeta task')"  deferred >/dev/null

out="$(bash "$DEPUTY" set "$(line_of 'trigger task')" done 2>&1)"
assert_contains "$out" "Queue — 3 waiting, 1 paused, 2 deferred, 0 pending-merge:" "header carries per-state counts"
assert_contains "$out" "STATE"    "table has a STATE column header"
assert_contains "$out" "TASK"     "table has a TASK column header"
assert_contains "$out" "waiting"  "lists waiting items"
assert_contains "$out" "paused"   "lists paused items"
assert_contains "$out" "deferred" "lists deferred items"
assert_eq "$(printf '%s\n' "$out" | grep -c '#?')" "0" "ids are allocated (no '#?' rows)"

# Ordering within the table body.
rows="$(printf '%s\n' "$out" | awk '/^STATE /{f=1;next} f')"
pos() { printf '%s\n' "$rows" | grep -n "$1" | head -1 | cut -d: -f1; }
bpos="$(pos 'beta task')"; gpos="$(pos 'gamma task')"
apos="$(pos 'alpha task')"; epos="$(pos 'epsilon task')"
dpos="$(pos 'delta task')"; zpos="$(pos 'zeta task')"
assert_eq "$([[ "$bpos" -lt "$gpos" ]] && echo ok)" "ok" "P0 waiting before P1 paused"
assert_eq "$([[ "$gpos" -lt "$apos" ]] && echo ok)" "ok" "P1 paused before P2 waiting"
assert_eq "$([[ "$apos" -lt "$epos" ]] && echo ok)" "ok" "FIFO: earlier P2 (alpha) before later P2 (epsilon)"
assert_eq "$([[ "$epos" -lt "$dpos" ]] && echo ok)" "ok" "runnable group before deferred group"
# Tie-break is BACKLOG file-order preservation (matches cmd_pick), not add-order:
# the group-by-state writer fixes the deferred order, and the table must mirror it.
dfile="$(grep -nF 'delta task' "$DEPUTY_ROOT/BACKLOG.md" | cut -d: -f1)"
zfile="$(grep -nF 'zeta task'  "$DEPUTY_ROOT/BACKLOG.md" | cut -d: -f1)"
if [[ "$dfile" -lt "$zfile" ]]; then
  assert_eq "$([[ "$dpos" -lt "$zpos" ]] && echo ok)" "ok" "deferred group mirrors BACKLOG file order (delta before zeta)"
else
  assert_eq "$([[ "$zpos" -lt "$dpos" ]] && echo ok)" "ok" "deferred group mirrors BACKLOG file order (zeta before delta)"
fi

# --- empty case: last item done -> queue empty ---
setup_repo
bash "$DEPUTY" add "solo task" --p0
bash "$DEPUTY" list >/dev/null
out="$(bash "$DEPUTY" set "$(line_of 'solo task')" done 2>&1)"
assert_contains "$out" "Queue: empty (no waiting, paused, deferred, or pending-merge items)." "empty queue message"

# --- done-only: a failure transition does NOT print the table ---
setup_repo
bash "$DEPUTY" add "fail task" --p0
bash "$DEPUTY" add "keep task" --p1
bash "$DEPUTY" list >/dev/null
out="$(bash "$DEPUTY" set "$(line_of 'fail task')" failed 2>&1)"
assert_eq "$(printf '%s\n' "$out" | grep -c '^Queue')" "0" "failed transition prints no queue table"

# --- run loop relays exactly one table per done item (no double-print) ---
ORCH="$(mktemp)"
cat > "$ORCH" <<EOF
#!/usr/bin/env bash
DEPUTY_NOTIFY_SYNC=1 bash "$DEPUTY" set "\$1" done   # stdout NOT redirected -> runner relays it
EOF
chmod +x "$ORCH"
setup_repo
# #60: this test drains both items in one run — max_items now defaults to 1, so opt in.
mkdir -p "$DEPUTY_ROOT/.deputy"; printf 'max_items=2\n' >> "$DEPUTY_ROOT/.deputy/config"
bash "$DEPUTY" add "one" --p0
bash "$DEPUTY" add "two" --p1
out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run 2>&1)"
assert_eq "$(printf '%s\n' "$out" | grep -c '^Queue')" "2" "exactly one table per done item (2 items, no double-print)"
assert_contains "$out" "Queue: empty" "final completion shows empty queue"
rm -f "$ORCH"
