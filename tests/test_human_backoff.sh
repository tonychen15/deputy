#!/usr/bin/env bash
# tests/test_human_backoff.sh — tests for _interactive_session_active() back-off
source "$(dirname "$0")/lib.sh"

# Helper: write a mock Claude Code session file.
# usage: write_session <sessions_dir> <filename> <pid> <cwd> <entrypoint> [procstart]
write_session() {
  local dir="$1" name="$2" pid="$3" cwd="$4" entry="$5"
  local procstart="${6:-}"
  mkdir -p "$dir"
  local ps_field=""
  [[ -n "$procstart" ]] && ps_field=", \"procStart\": $procstart"
  printf '{"pid": %s, "cwd": "%s", "entrypoint": "%s", "status": "busy"%s}\n' \
    "$pid" "$cwd" "$entry" "$ps_field" > "$dir/$name"
}

# ── Test 1: live cli session in this repo → deputy run backs off ──────────────
setup_repo

# Add a waiting item.
printf '[P1] do something\n' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null  # allocate IDs

# Set up a fake HOME with a matching session file.
FAKE_HOME1="$(mktemp -d)"
sleep 300 & SESSION_PID1=$!
PROC_START1="$(sed 's/.*) //' /proc/"$SESSION_PID1"/stat 2>/dev/null | awk '{print $20}' || true)"
write_session "$FAKE_HOME1/.claude/sessions" "sess1.json" \
  "$SESSION_PID1" "$DEPUTY_ROOT" "cli" "$PROC_START1"

# Run deputy with fake HOME — should back off (item stays waiting).
HOME="$FAKE_HOME1" DEPUTY_ALLOW_ANY_BRANCH=1 bash "$DEPUTY" run 2>/tmp/t1_stderr.txt
item_state="$(bash "$DEPUTY" list | head -1 | cut -d'|' -f1)"
assert_eq "$item_state" "waiting" "live cli session in repo → item stays waiting (back-off)"
assert_contains "$(cat /tmp/t1_stderr.txt)" "backing off" "back-off message emitted to stderr"
assert_contains "$(cat /tmp/t1_stderr.txt)" "$SESSION_PID1" "back-off message includes PID"

kill "$SESSION_PID1" 2>/dev/null || true
rm -rf "$FAKE_HOME1"

# ── Test 2: cli session in a DIFFERENT repo → deputy run proceeds (no item to claim) ──
# (We can't test a full run end-to-end without a provider, but we can verify the item
# transitions to running/claimed, meaning the back-off was NOT triggered.)
setup_repo
printf '[P1] do another thing\n' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null

FAKE_HOME2="$(mktemp -d)"
sleep 300 & SESSION_PID2=$!
write_session "$FAKE_HOME2/.claude/sessions" "sess2.json" \
  "$SESSION_PID2" "/some/other/repo" "cli"

# Use a mock orchestrator that records invocation (deputy run would claim then spawn).
# Instead, just verify _interactive_session_active returns false by testing via run
# with DEPUTY_NO_AUTORUN=0 in a way that shows it passes the back-off gate.
# Simplest: verify run doesn't emit a back-off message.
HOME="$FAKE_HOME2" DEPUTY_ALLOW_ANY_BRANCH=1 bash "$DEPUTY" run 2>/tmp/t2_stderr.txt
assert_eq "$(grep -c 'backing off' /tmp/t2_stderr.txt 2>/dev/null || true)" "0" \
  "cli session in different repo → no back-off"

kill "$SESSION_PID2" 2>/dev/null || true
rm -rf "$FAKE_HOME2"

# ── Test 3: sdk-cli session in this repo → NOT treated as human, no back-off ──
setup_repo
printf '[P1] headless item\n' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null

FAKE_HOME3="$(mktemp -d)"
sleep 300 & SESSION_PID3=$!
write_session "$FAKE_HOME3/.claude/sessions" "sess3.json" \
  "$SESSION_PID3" "$DEPUTY_ROOT" "sdk-cli"

HOME="$FAKE_HOME3" DEPUTY_ALLOW_ANY_BRANCH=1 bash "$DEPUTY" run 2>/tmp/t3_stderr.txt
assert_eq "$(grep -c 'backing off' /tmp/t3_stderr.txt 2>/dev/null || true)" "0" \
  "sdk-cli (headless) session → not treated as human, no back-off"

kill "$SESSION_PID3" 2>/dev/null || true
rm -rf "$FAKE_HOME3"

# ── Test 4: human_backoff=0 config → back-off disabled ────────────────────────
setup_repo
printf '[P1] opt-out item\n' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null

# Configure human_backoff=0
mkdir -p "$DEPUTY_ROOT/.deputy"
printf 'human_backoff=0\n' > "$DEPUTY_ROOT/.deputy/config"

FAKE_HOME4="$(mktemp -d)"
sleep 300 & SESSION_PID4=$!
PROC_START4="$(sed 's/.*) //' /proc/"$SESSION_PID4"/stat 2>/dev/null | awk '{print $20}' || true)"
write_session "$FAKE_HOME4/.claude/sessions" "sess4.json" \
  "$SESSION_PID4" "$DEPUTY_ROOT" "cli" "$PROC_START4"

HOME="$FAKE_HOME4" DEPUTY_ALLOW_ANY_BRANCH=1 bash "$DEPUTY" run 2>/tmp/t4_stderr.txt
assert_eq "$(grep -c 'backing off' /tmp/t4_stderr.txt 2>/dev/null || true)" "0" \
  "human_backoff=0 → back-off disabled despite live cli session"

kill "$SESSION_PID4" 2>/dev/null || true
rm -rf "$FAKE_HOME4"

# ── Test 5: dead-PID session in this repo → warning logged, deputy proceeds ───
setup_repo
printf '[P1] proceed item\n' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null

FAKE_HOME5="$(mktemp -d)"
# Use a definitely-dead PID (use a process we start and immediately kill)
sleep 1 & DEAD_PID=$!
kill "$DEAD_PID" 2>/dev/null; wait "$DEAD_PID" 2>/dev/null || true
write_session "$FAKE_HOME5/.claude/sessions" "sess5.json" \
  "$DEAD_PID" "$DEPUTY_ROOT" "cli"

HOME="$FAKE_HOME5" DEPUTY_ALLOW_ANY_BRANCH=1 bash "$DEPUTY" run 2>/tmp/t5_stderr.txt
assert_eq "$(grep -c 'backing off' /tmp/t5_stderr.txt 2>/dev/null || true)" "0" \
  "dead-PID cli session → no back-off (proceed)"
assert_contains "$(cat /tmp/t5_stderr.txt)" "stale" "dead-PID session logs stale warning"

rm -rf "$FAKE_HOME5"

# ── Test 6: no ~/.claude/sessions/ dir (jq fallback via /proc) → no back-off when
#    the only claude process is deputy itself (sdk-cli) ─────────────────────────
setup_repo
printf '[P1] fallback item\n' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null

# HOME with no .claude/sessions dir → triggers /proc fallback path.
FAKE_HOME6="$(mktemp -d)"
# No session files written — fallback scans /proc for 'claude' processes.
# The only match would be if 'claude' is running, but in test context it shouldn't
# have a cwd matching DEPUTY_ROOT, so no back-off expected.
HOME="$FAKE_HOME6" DEPUTY_ALLOW_ANY_BRANCH=1 bash "$DEPUTY" run 2>/tmp/t6_stderr.txt
assert_eq "$(grep -c 'backing off' /tmp/t6_stderr.txt 2>/dev/null || true)" "0" \
  "no sessions dir (proc fallback) → no back-off when no matching claude process"

rm -rf "$FAKE_HOME6"
