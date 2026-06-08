#!/usr/bin/env bash
# tests/test_autorun.sh — tests for _autorun dispatch in cmd_add
source "$(dirname "$0")/lib.sh"

# Helper: create a mock autorun command that touches a marker file when invoked.
make_autorun_mock() {
  local marker="$1"
  local mock; mock="$(mktemp)"
  cat > "$mock" <<EOFMOCK
#!/usr/bin/env bash
touch "$marker"
EOFMOCK
  chmod +x "$mock"
  printf '%s' "$mock"
}

# ── Test 1: idle + pickable item + not suppressed → autorun fired ────────────
setup_repo
FIRED1="$DEPUTY_ROOT/.autorun.fired"
MOCK1="$(make_autorun_mock "$FIRED1")"

DEPUTY_NO_AUTORUN=0 DEPUTY_AUTORUN_CMD="$MOCK1" \
  bash "$DEPUTY" add "do the thing" --p0

assert_eq "$(test -f "$FIRED1" && echo yes || echo no)" "yes" \
  "idle + pickable item + not suppressed → autorun fired"
rm -f "$MOCK1"

# ── Test 2: DEPUTY_NO_AUTORUN=1 → NOT fired ──────────────────────────────────
setup_repo
FIRED2="$DEPUTY_ROOT/.autorun.fired"
MOCK2="$(make_autorun_mock "$FIRED2")"

DEPUTY_NO_AUTORUN=1 DEPUTY_AUTORUN_CMD="$MOCK2" \
  bash "$DEPUTY" add "suppressed task"

assert_eq "$(test -f "$FIRED2" && echo yes || echo no)" "no" \
  "DEPUTY_NO_AUTORUN=1 → autorun NOT fired"
rm -f "$MOCK2"

# ── Test 3: live claim present → NOT fired ───────────────────────────────────
setup_repo
FIRED3="$DEPUTY_ROOT/.autorun.fired"
MOCK3="$(make_autorun_mock "$FIRED3")"

# Install a live claim using the current shell's PID (always alive)
printf '@[P0] the running job\n' >> "$DEPUTY_ROOT/BACKLOG.md"
printf '@[P0] the running job\n' > "$DEPUTY_ROOT/.deputy/$$.claim"

DEPUTY_NO_AUTORUN=0 DEPUTY_AUTORUN_CMD="$MOCK3" \
  bash "$DEPUTY" add "new work item"

assert_eq "$(test -f "$FIRED3" && echo yes || echo no)" "no" \
  "live claim present → autorun NOT fired"
rm -f "$DEPUTY_ROOT/.deputy/$$.claim"
rm -f "$MOCK3"

# ── Test 4: empty queue (no pickable item after dedup) → NOT fired ───────────
# Add an item, set it done, then try to add the same description again.
# After dedup (already present), pick returns empty → autorun should NOT fire.
setup_repo
FIRED4="$DEPUTY_ROOT/.autorun.fired"
MOCK4="$(make_autorun_mock "$FIRED4")"

# First add the item (this will fire; ignore it)
bash "$DEPUTY" add "already existing"
WAITING_LINE="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" set "$WAITING_LINE" done >/dev/null 2>&1

# Now the queue has only a done item; adding the same description dedupes (no new item).
# pick will return empty because there's no waiting item → autorun NOT fired.
DEPUTY_NO_AUTORUN=0 DEPUTY_AUTORUN_CMD="$MOCK4" \
  bash "$DEPUTY" add "already existing"

assert_eq "$(test -f "$FIRED4" && echo yes || echo no)" "no" \
  "dedup + no pickable items → autorun NOT fired"
rm -f "$MOCK4"
