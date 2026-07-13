#!/usr/bin/env bash
# tests/test_orphan_warn.sh — #57 Part B: warn-only stale-orphan detection.
source "$(dirname "$0")/lib.sh"

write_session() {
  local dir="$1" name="$2" pid="$3" cwd="$4" entry="$5" procstart="${6:-}"
  mkdir -p "$dir"
  local ps_field=""; [[ -n "$procstart" ]] && ps_field=", \"procStart\": $procstart"
  printf '{"pid": %s, "cwd": "%s", "entrypoint": "%s", "status": "busy", "statusUpdatedAt": 1%s}\n' \
    "$pid" "$cwd" "$entry" "$ps_field" > "$dir/$name"
}

SESS_PID=""; ORPHAN_PID=""; FAKE_HOME=""
# A fake session-root bash in its OWN process group (setsid -> detached from the test's
# group, so the harness doesn't wait on it). Its child is a bash blocked forever on a
# read = the "orphan" (comm=bash, no sleep grandchild; killed cleanly via the group).
mk_session_with_orphan() {
  local sf cf scr; sf="$(mktemp)"; cf="$(mktemp)"; scr="$(mktemp)"
  cat > "$scr" <<INNER
echo \$\$ > "$sf"
bash -c 'read -r _ < /dev/zero' &
echo \$! > "$cf"
wait
INNER
  setsid bash "$scr" >/dev/null 2>&1 &
  local i; for i in $(seq 1 15); do [ -s "$sf" ] && [ -s "$cf" ] && break; sleep 0.3; done
  SESS_PID="$(head -1 "$sf" 2>/dev/null)"; ORPHAN_PID="$(head -1 "$cf" 2>/dev/null)"
  rm -f "$sf" "$cf" "$scr"
  sleep 2   # age the orphan so etimes >= 1 (orphan_warn_mins=0 -> thresh 0s -> needs et>0)
}
ps_start() { sed 's/.*) //' /proc/"$1"/stat 2>/dev/null | awk '{print $20}' || true; }
do_run() { HOME="$FAKE_HOME" DEPUTY_ALLOW_ANY_BRANCH=1 bash "$DEPUTY" run --once 2>/tmp/orph_err.txt >/dev/null; }
cleanup() { [ -n "$SESS_PID" ] && kill -- -"$SESS_PID" 2>/dev/null; rm -rf "$FAKE_HOME"; SESS_PID=""; }

# 1: a bash orphan under an in-repo cli session is warned (orphan_warn_mins=0).
setup_repo
printf 'max_items=0\nhuman_backoff=0\norphan_warn_mins=0\n' > "$DEPUTY_ROOT/.deputy/config"
FAKE_HOME="$(mktemp -d)"; mk_session_with_orphan
write_session "$FAKE_HOME/.claude/sessions" "s.json" "$SESS_PID" "$DEPUTY_ROOT" "cli" "$(ps_start "$SESS_PID")"
do_run
assert_contains "$(cat /tmp/orph_err.txt)" "orphaned process pid $ORPHAN_PID" "warns about the stale bash orphan"
assert_contains "$(cat /tmp/orph_err.txt)" "kill $ORPHAN_PID" "warning includes the kill hint"
assert_eq "$(kill -0 "$ORPHAN_PID" 2>/dev/null && echo alive || echo dead)" "alive" "NEVER kills the orphan"
cleanup

# 2: per-pid throttle — an immediate second run does NOT re-warn.
setup_repo
printf 'max_items=0\nhuman_backoff=0\norphan_warn_mins=0\n' > "$DEPUTY_ROOT/.deputy/config"
FAKE_HOME="$(mktemp -d)"; mk_session_with_orphan
write_session "$FAKE_HOME/.claude/sessions" "s.json" "$SESS_PID" "$DEPUTY_ROOT" "cli" "$(ps_start "$SESS_PID")"
do_run; assert_contains "$(cat /tmp/orph_err.txt)" "orphaned process pid $ORPHAN_PID" "throttle: first run warns"
do_run; assert_eq "$(grep -c "orphaned process pid $ORPHAN_PID" /tmp/orph_err.txt)" "0" "throttle: second run is silent"
cleanup

# 3: below threshold (orphan_warn_mins huge) -> no warning.
setup_repo
printf 'max_items=0\nhuman_backoff=0\norphan_warn_mins=999\n' > "$DEPUTY_ROOT/.deputy/config"
FAKE_HOME="$(mktemp -d)"; mk_session_with_orphan
write_session "$FAKE_HOME/.claude/sessions" "s.json" "$SESS_PID" "$DEPUTY_ROOT" "cli" "$(ps_start "$SESS_PID")"
do_run
assert_eq "$(grep -c 'orphaned process pid' /tmp/orph_err.txt)" "0" "below threshold -> no warning"
cleanup

# 4: no false-positive — a bash orphan NOT under any cli session is ignored.
setup_repo
printf 'max_items=0\nhuman_backoff=0\norphan_warn_mins=0\n' > "$DEPUTY_ROOT/.deputy/config"
FAKE_HOME="$(mktemp -d)"; mkdir -p "$FAKE_HOME/.claude/sessions"   # no session file
mk_session_with_orphan
do_run
assert_eq "$(grep -c 'orphaned process pid' /tmp/orph_err.txt)" "0" "no in-repo cli session -> nothing flagged"
cleanup

# 5: config key documented in deputy help.
assert_contains "$(bash "$DEPUTY" help --full 2>&1)" "orphan_warn_mins" "orphan_warn_mins documented in deputy help --full"
