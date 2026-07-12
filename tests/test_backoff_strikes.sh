#!/usr/bin/env bash
# tests/test_backoff_strikes.sh — #55: 3-strike persistence for the undocumented
# 'waiting' session status in _human_backoff_gate. The durable counter is seeded to
# simulate prior strikes deterministically (rapid test ticks would otherwise collapse
# under the half-heartbeat dedup window).
source "$(dirname "$0")/lib.sh"

write_session() {
  local dir="$1" name="$2" pid="$3" cwd="$4" entry="$5" procstart="${6:-}" status="${7:-busy}" sua="${8:-}"
  mkdir -p "$dir"
  local ps_field=""; [[ -n "$procstart" ]] && ps_field=", \"procStart\": $procstart"
  [[ -n "$sua" ]] || sua="$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")"
  printf '{"pid": %s, "cwd": "%s", "entrypoint": "%s", "status": "%s", "statusUpdatedAt": %s%s}\n' \
    "$pid" "$cwd" "$entry" "$status" "$sua" "$ps_field" > "$dir/$name"
}

SUA=1700000000000
SESS_PID=""; FAKE_HOME=""; ORCH=""

mk_repo() {  # mk_repo <status> <sua> : fresh repo + waiting item + live session + mock orchestrator
  setup_repo
  printf '[P1] strike item\n' >> "$DEPUTY_ROOT/BACKLOG.md"
  bash "$DEPUTY" list >/dev/null
  FAKE_HOME="$(mktemp -d)"
  sleep 300 & SESS_PID=$!
  local ps; ps="$(sed 's/.*) //' /proc/"$SESS_PID"/stat 2>/dev/null | awk '{print $20}' || true)"
  write_session "$FAKE_HOME/.claude/sessions" "s.json" "$SESS_PID" "$DEPUTY_ROOT" "cli" "$ps" "$1" "$2"
  ORCH="$(mktemp)"
  printf '#!/usr/bin/env bash\nbash "%s" set "$1" done >/dev/null 2>&1\n' "$DEPUTY" > "$ORCH"; chmod +x "$ORCH"
}
seed()       { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" > "$DEPUTY_ROOT/.deputy/.backoff_waiting"; }
do_run()     { HOME="$FAKE_HOME" DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL=claude DEPUTY_ALLOW_ANY_BRANCH=1 \
                 bash "$DEPUTY" run --once 2>/tmp/bos_err.txt; }
item_state() { line_state "$(bash "$DEPUTY" list | grep 'strike item' | head -1)"; }
cleanup()    { kill "$SESS_PID" 2>/dev/null || true; rm -rf "$FAKE_HOME"; }
NOW() { date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)"; }

# ── 1: first 'waiting' tick -> strike 1, back off ───────────────────────────────
mk_repo waiting "$SUA"
do_run
assert_eq "$(item_state)" "waiting" "first waiting tick -> backs off (item stays waiting)"
assert_contains "$(cat /tmp/bos_err.txt)" "strike 1/3" "first waiting -> strike 1/3"
cleanup

# ── 2: 3rd consecutive 'waiting' -> proceeds (runs the item) ─────────────────────
mk_repo waiting "$SUA"
seed "$SESS_PID" "$SUA" 2 0            # count=2, ancient last_bump -> next bump increments to 3
do_run
assert_eq "$(item_state)" "done" "3rd consecutive waiting -> proceeds (item runs to done)"
assert_contains "$(cat /tmp/bos_err.txt)" "proceeding" "3rd strike -> 'proceeding' message"
cleanup

# ── 3: dedup — a recent last_bump does NOT double-count within the window ────────
mk_repo waiting "$SUA"
seed "$SESS_PID" "$SUA" 1 "$(NOW)"    # last_bump = now -> within half-heartbeat -> no increment
do_run
assert_eq "$(item_state)" "waiting" "dedup: recent bump -> still backs off"
assert_contains "$(cat /tmp/bos_err.txt)" "strike 1/3" "dedup: stays strike 1 (no double-count to 2)"
cleanup

# ── 4: a changed statusUpdatedAt resets the strike count ────────────────────────
mk_repo waiting "$SUA"
seed "$SESS_PID" "9999999999999" 2 0  # different sua + count=2 -> mismatch resets to 1
do_run
assert_eq "$(item_state)" "waiting" "changed statusUpdatedAt -> resets, backs off"
assert_contains "$(cat /tmp/bos_err.txt)" "strike 1/3" "changed sua -> strike resets to 1"
cleanup

# ── 5: a non-'waiting' status (busy) resets/clears the counter file ─────────────
mk_repo busy "$SUA"
seed "$SESS_PID" "$SUA" 2 0
do_run
assert_eq "$(item_state)" "waiting" "busy -> backs off"
assert_eq "$(test -f "$DEPUTY_ROOT/.deputy/.backoff_waiting" && echo y || echo n)" "n" \
  "busy -> strike counter cleared (file removed)"
cleanup

# ── 6: waiting_backoff_strikes config (=2) lowers the threshold ──────────────────
mk_repo waiting "$SUA"
printf 'waiting_backoff_strikes=2\n' >> "$DEPUTY_ROOT/.deputy/config"
seed "$SESS_PID" "$SUA" 1 0            # count=1 -> next bump = 2 >= 2 -> proceed
do_run
assert_eq "$(item_state)" "done" "waiting_backoff_strikes=2 -> proceeds at the 2nd strike"
cleanup

# ── 7: the config key is documented in `deputy help` ────────────────────────────
assert_contains "$(bash "$DEPUTY" help 2>&1)" "waiting_backoff_strikes" \
  "waiting_backoff_strikes config key documented in deputy help"
