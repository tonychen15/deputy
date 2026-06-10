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

# ── Test 5: dead-PID session in this repo + waiting item → item surfaced ──────
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
# Item must now be surfaced (not waiting, and NOT running — no claim file created)
item_state5="$(bash "$DEPUTY" list | grep -v '^$' | head -1 | cut -d'|' -f1)"
assert_eq "$item_state5" "surfaced" "dead-PID cli session in repo → item surfaced"
assert_eq "$(grep -c 'backing off' /tmp/t5_stderr.txt 2>/dev/null || true)" "0" \
  "dead-PID cli session → no backing-off message"
assert_contains "$(cat /tmp/t5_stderr.txt)" "stale" "stale session: stderr mentions stale"
assert_contains "$(cat /tmp/t5_stderr.txt)" "$DEAD_PID" "stale session: stderr includes the dead PID"
# No claim file should have been created.
assert_eq "$(ls "$DEPUTY_ROOT"/.deputy/*.claim 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "stale session surface → no claim file created"
# Questions file should contain the note (reflect picks this up).
reflect_out5="$(HOME="$FAKE_HOME5" bash "$DEPUTY" reflect 2>/dev/null)"
assert_contains "$reflect_out5" "$DEAD_PID" "stale session: reflect displays questions file note with dead PID"
assert_contains "$reflect_out5" "abnormal" "stale session: reflect note mentions abnormal crash"

rm -rf "$FAKE_HOME5"

# ── Test 8: stale + already-surfaced item → cascade guard, no second surface ──
setup_repo
printf '[P1] first item\n' >> "$DEPUTY_ROOT/BACKLOG.md"
printf '[P2] second item\n' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null
# Manually surface the first item.
first_line8="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" set "$first_line8" surfaced

FAKE_HOME8="$(mktemp -d)"
sleep 1 & DEAD_PID8=$!
kill "$DEAD_PID8" 2>/dev/null; wait "$DEAD_PID8" 2>/dev/null || true
write_session "$FAKE_HOME8/.claude/sessions" "sess8.json" \
  "$DEAD_PID8" "$DEPUTY_ROOT" "cli"

HOME="$FAKE_HOME8" DEPUTY_ALLOW_ANY_BRANCH=1 bash "$DEPUTY" run 2>/tmp/t8_stderr.txt
# Only 1 surfaced item (cascade guard respected).
surfaced_count8="$(bash "$DEPUTY" status | grep '^surfaced:' | awk '{print $2}')"
assert_eq "$surfaced_count8" "1" "stale + already-surfaced → cascade guard, only 1 surfaced item"
assert_contains "$(cat /tmp/t8_stderr.txt)" "already surfaced" "cascade guard: stderr mentions already surfaced"

rm -rf "$FAKE_HOME8"

# ── Test 9: stale + empty queue → proceeds/idles, no error ────────────────────
setup_repo
# No items added — empty queue.

FAKE_HOME9="$(mktemp -d)"
sleep 1 & DEAD_PID9=$!
kill "$DEAD_PID9" 2>/dev/null; wait "$DEAD_PID9" 2>/dev/null || true
write_session "$FAKE_HOME9/.claude/sessions" "sess9.json" \
  "$DEAD_PID9" "$DEPUTY_ROOT" "cli"

run_rc9=0
HOME="$FAKE_HOME9" DEPUTY_ALLOW_ANY_BRANCH=1 bash "$DEPUTY" run 2>/tmp/t9_stderr.txt || run_rc9=$?
assert_eq "$run_rc9" "0" "stale + empty queue → returns 0"
assert_contains "$(cat /tmp/t9_stderr.txt)" "no runnable" "stale + empty queue → logs no runnable items"

rm -rf "$FAKE_HOME9"

# ── Test 10: human_backoff=0 + stale session → surface NOT triggered (proceeds) ──
setup_repo
printf '[P1] backoff-disabled item\n' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null
mkdir -p "$DEPUTY_ROOT/.deputy"
printf 'human_backoff=0\n' > "$DEPUTY_ROOT/.deputy/config"

FAKE_HOME10="$(mktemp -d)"
sleep 1 & DEAD_PID10=$!
kill "$DEAD_PID10" 2>/dev/null; wait "$DEAD_PID10" 2>/dev/null || true
write_session "$FAKE_HOME10/.claude/sessions" "sess10.json" \
  "$DEAD_PID10" "$DEPUTY_ROOT" "cli"

HOME="$FAKE_HOME10" DEPUTY_ALLOW_ANY_BRANCH=1 bash "$DEPUTY" run 2>/tmp/t10_stderr.txt
item_state10="$(bash "$DEPUTY" list | grep -v '^$' | head -1 | cut -d'|' -f1)"
# human_backoff=0 disables the stale-surface path — item should NOT be surfaced.
assert_eq "$item_state10" "waiting" "human_backoff=0 + stale → surface NOT triggered, item stays waiting"
assert_eq "$(grep -c 'stale\|surfaced' /tmp/t10_stderr.txt 2>/dev/null || true)" "0" \
  "human_backoff=0 + stale → no stale/surfaced messages"

rm -rf "$FAKE_HOME10"

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

# ── Test 7: human_backoff key appears in deputy help config section ────────────
help_output="$(bash "$DEPUTY" help 2>&1)"
assert_contains "$help_output" "human_backoff" "human_backoff config key documented in deputy help"

# ── Test 11: mid-drain back-off — session appears WHILE processing first item ──
# Prove the per-iteration gate: the drain loop must re-check before claiming item 2.
# The mock orchestrator processes item 1 (marks done) and then creates a fake live
# session file. The drain loop should back off before claiming item 2.
setup_repo
printf '[P0] first item\n' >> "$DEPUTY_ROOT/BACKLOG.md"
printf '[P1] second item\n' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null  # allocate IDs

FAKE_HOME11="$(mktemp -d)"
# Shared state: orchestrator writes the live session PID here after processing item 1.
SESSION_PID_FILE11="$(mktemp)"
# Start a background process that will serve as the fake "live session" PID.
# We start it now, capture its PID, and write the session file from the orchestrator.
sleep 300 & LIVE_PID11=$!
PROC_START11="$(sed 's/.*) //' /proc/"$LIVE_PID11"/stat 2>/dev/null | awk '{print $20}' || true)"

# Write the live session PID and procStart into a file the orchestrator can read.
printf '%s\n%s\n' "$LIVE_PID11" "$PROC_START11" > "$SESSION_PID_FILE11"

# Mock orchestrator: on first invocation, mark item done AND create the live session.
# On subsequent invocations (should not happen), just mark done.
ORCH11="$(mktemp)"
cat > "$ORCH11" <<EOF
#!/usr/bin/env bash
# Mark the item done.
bash "$DEPUTY" set "\$1" done >/dev/null 2>&1 || true
# Create the fake live session file so the mid-drain gate fires for the next item.
_lpid="\$(sed -n '1p' "$SESSION_PID_FILE11")"
_lps="\$(sed -n '2p' "$SESSION_PID_FILE11")"
_sdir="$FAKE_HOME11/.claude/sessions"
mkdir -p "\$_sdir"
printf '{"pid": %s, "cwd": "%s", "entrypoint": "cli", "status": "busy", "procStart": %s}\n' \\
  "\$_lpid" "$DEPUTY_ROOT" "\${_lps:-0}" > "\$_sdir/live_session.json"
EOF
chmod +x "$ORCH11"

HOME="$FAKE_HOME11" DEPUTY_ALLOW_ANY_BRANCH=1 \
  DEPUTY_ORCHESTRATOR_CMD="$ORCH11" DEPUTY_AVAIL="claude,gemini" DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run 2>/tmp/t11_stderr.txt

# Item 1 must be done (processed before session appeared).
item1_state11="$(bash "$DEPUTY" list | grep 'first item' | cut -d'|' -f1)"
assert_eq "$item1_state11" "done" "mid-drain: first item was processed before session appeared"

# Item 2 must still be waiting (gate fired before claiming it).
item2_state11="$(bash "$DEPUTY" list | grep 'second item' | cut -d'|' -f1)"
assert_eq "$item2_state11" "waiting" "mid-drain: second item stays waiting after session appeared mid-drain"

# The back-off message must have been emitted.
assert_contains "$(cat /tmp/t11_stderr.txt)" "backing off" \
  "mid-drain: back-off message emitted when session appeared mid-drain"

# No stale claim file should remain.
assert_eq "$(ls "$DEPUTY_ROOT"/.deputy/*.claim 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "mid-drain: no stale claim file after back-off"

kill "$LIVE_PID11" 2>/dev/null || true
rm -f "$ORCH11" "$SESSION_PID_FILE11"
rm -rf "$FAKE_HOME11"
