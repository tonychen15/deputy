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

# Unknown flags are rejected, not absorbed into the description.
bash "$DEPUTY" add "real task" --p3 2>/dev/null; rc=$?
assert_eq "$rc" "2" "add rejects unknown flag"
assert_eq "$(bash "$DEPUTY" list | grep -c -- '--p3')" "0" "unknown flag not absorbed"

# Bare multi-word descriptions still join.
bash "$DEPUTY" add Buy the milk
assert_contains "$(bash "$DEPUTY" list)" "waiting||Buy the milk" "bare multi-word add joins"

# Descriptions that collide with the line grammar are rejected (would corrupt state).
bash "$DEPUTY" add "@ ping the oncall" 2>/dev/null; rc=$?
assert_eq "$rc" "2" "add rejects description starting with status prefix + space"
bash "$DEPUTY" add "[P1] looks like a tag" 2>/dev/null; rc=$?
assert_eq "$rc" "2" "add rejects description starting with priority tag"
n="$(bash "$DEPUTY" list | grep -c 'oncall\|looks like a tag')"
assert_eq "$n" "0" "rejected descriptions are not written"
# A description merely CONTAINING @ (not a leading prefix+space) is still allowed.
bash "$DEPUTY" add "email @bob about it"
assert_contains "$(bash "$DEPUTY" list)" "waiting||email @bob about it" "non-prefix @ still allowed"

# Newlines in a description are rejected (would corrupt the one-line-per-item queue).
bash "$DEPUTY" add "$(printf 'line one\nline two')" 2>/dev/null; rc=$?
assert_eq "$rc" "2" "add rejects embedded newline"

# Eisenhower flag aliases: -ui=P0, -u=P1, -i=P2 (equivalent to --p0/--p1/--p2).
setup_repo
bash "$DEPUTY" add "urgent important" -ui
bash "$DEPUTY" add "just urgent" -u
bash "$DEPUTY" add "just important" -i
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "waiting|P0|urgent important" "-ui maps to P0"
assert_contains "$out" "waiting|P1|just urgent"      "-u maps to P1"
assert_contains "$out" "waiting|P2|just important"   "-i maps to P2"

# Flag may come before or after the text; last priority flag wins.
bash "$DEPUTY" add -ui "flag first"
assert_contains "$(bash "$DEPUTY" list)" "waiting|P0|flag first" "flag may precede text"

# `--` ends flag parsing so a description can start with a dash.
bash "$DEPUTY" add -u -- "-5% drop alert"
assert_contains "$(bash "$DEPUTY" list)" "waiting|P1|-5% drop alert" "-- allows leading-dash description"

# An unknown single-dash flag is rejected (not silently absorbed).
bash "$DEPUTY" add "task" -x 2>/dev/null; rc=$?
assert_eq "$rc" "2" "unknown single-dash flag rejected"
assert_eq "$(bash "$DEPUTY" list | grep -c -- '-x')" "0" "unknown single-dash flag not absorbed"

# ── Auto-run: add triggers _autorun dispatch when nothing is running ─────────
# Use DEPUTY_AUTORUN_CMD mock so add returns immediately (non-blocking _autorun).
setup_repo
AUTORUN_FIRED="$DEPUTY_ROOT/.autorun.fired"
AUTORUN_MOCK="$(mktemp)"
cat > "$AUTORUN_MOCK" <<EOFMOCK
#!/usr/bin/env bash
touch "$AUTORUN_FIRED"
EOFMOCK
chmod +x "$AUTORUN_MOCK"

DEPUTY_NO_AUTORUN=0 DEPUTY_AUTORUN_CMD="$AUTORUN_MOCK" \
  bash "$DEPUTY" add "auto run me" --p0
assert_eq "$(test -f "$AUTORUN_FIRED" && echo yes || echo no)" "yes" \
  "add dispatches _autorun when idle and item is pickable"

# add does NOT dispatch autorun when a live claim already exists
setup_repo
AUTORUN_FIRED2="$DEPUTY_ROOT/.autorun.fired2"
AUTORUN_MOCK2="$(mktemp)"
cat > "$AUTORUN_MOCK2" <<EOFMOCK2
#!/usr/bin/env bash
touch "$AUTORUN_FIRED2"
EOFMOCK2
chmod +x "$AUTORUN_MOCK2"
sleep 300 & LIVE=$!
printf '@[P0] already running\n' >> "$DEPUTY_ROOT/BACKLOG.md"
printf '@[P0] already running\n' > "$DEPUTY_ROOT/.deputy/$LIVE.claim"
DEPUTY_NO_AUTORUN=0 DEPUTY_AUTORUN_CMD="$AUTORUN_MOCK2" \
  bash "$DEPUTY" add "new lower" --p1
assert_contains "$(bash "$DEPUTY" list)" "waiting|P1|new lower" "add queues item but does not run when claim exists"
assert_eq "$(test -f "$AUTORUN_FIRED2" && echo yes || echo no)" "no" \
  "add does not dispatch autorun when live claim exists"
kill "$LIVE" 2>/dev/null
rm -f "$AUTORUN_MOCK" "$AUTORUN_MOCK2"
