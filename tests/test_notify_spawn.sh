#!/usr/bin/env bash
# test_notify_spawn.sh — #59: notify + cron.log on autonomous (headless) spawn.
# Tests:
#   A: headless + notify_on_spawn=1 + notify=desktop → notify-send fires with
#      'Autonomous spawn' title and the item description in the body
#   B: queue empty (nothing claimed) → no notification fired
#   C: notify_on_spawn=0 → notify-send NOT called even on a headless spawn
source "$(dirname "$0")/lib.sh"
export DEPUTY_NO_PATH_FIX=1
export DEPUTY_NOTIFY_SYNC=1
ORIG_PATH="$PATH"

# ── helpers ──────────────────────────────────────────────────────────────────

make_recorder() {
  local marker="$1" bin
  bin="$(mktemp)"
  cat > "$bin" <<EOFBIN
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$marker"
EOFBIN
  chmod +x "$bin"
  printf '%s' "$bin"
}

prepend_path() {
  local dir="$1" name="$2" target="$3"
  ln -sf "$target" "$dir/$name"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test A: headless spawn fires desktop notification with 'Autonomous spawn' title
# ─────────────────────────────────────────────────────────────────────────────
setup_repo
NOTIFY_DIR_A="$(mktemp -d)"
export PATH="$NOTIFY_DIR_A:$ORIG_PATH"

MARKER_A="$DEPUTY_ROOT/.notifyA"
REC_A="$(make_recorder "$MARKER_A")"
prepend_path "$NOTIFY_DIR_A" notify-send "$REC_A"

printf 'notify=desktop\nnotify_on_spawn=1\n' > "$DEPUTY_ROOT/.deputy/config"
bash "$DEPUTY" add "auto spawn item" --p0

# Orchestrator that marks the item done immediately
ORCH_A="$(mktemp)"
cat > "$ORCH_A" <<EOFA
#!/usr/bin/env bash
bash "$DEPUTY" set "\$1" done >/dev/null 2>&1 || true
exit 0
EOFA
chmod +x "$ORCH_A"

# Run headless (no TTY, so _run_is_headed returns false → spawn notification fires)
DEPUTY_ORCHESTRATOR_CMD="$ORCH_A" DEPUTY_AVAIL="claude,gemini" \
  bash "$DEPUTY" run --headless --once >/dev/null 2>&1 || true

assert_eq "$(test -f "$MARKER_A" && echo yes || echo no)" "yes" \
  "headless spawn: notify-send fired"
assert_contains "$(cat "$MARKER_A")" "Autonomous spawn" \
  "headless spawn: notification title is 'Autonomous spawn'"
assert_contains "$(cat "$MARKER_A")" "auto spawn item" \
  "headless spawn: notification body contains item description"

# cron.log must have ===SPAWN=== line
assert_contains "$(cat "$DEPUTY_ROOT/.deputy/cron.log" 2>/dev/null || true)" "===SPAWN===" \
  "headless spawn: ===SPAWN=== written to cron.log"
assert_contains "$(cat "$DEPUTY_ROOT/.deputy/cron.log" 2>/dev/null || true)" "auto spawn item" \
  "headless spawn: item text in cron.log spawn line"

rm -f "$REC_A" "$ORCH_A"

# ─────────────────────────────────────────────────────────────────────────────
# Test B: empty queue → nothing claimed → no spawn notification
# ─────────────────────────────────────────────────────────────────────────────
setup_repo
NOTIFY_DIR_B="$(mktemp -d)"
export PATH="$NOTIFY_DIR_B:$ORIG_PATH"

MARKER_B="$DEPUTY_ROOT/.notifyB"
REC_B="$(make_recorder "$MARKER_B")"
prepend_path "$NOTIFY_DIR_B" notify-send "$REC_B"

printf 'notify=desktop\nnotify_on_spawn=1\n' > "$DEPUTY_ROOT/.deputy/config"
# No items in the queue

DEPUTY_AVAIL="claude,gemini" \
  bash "$DEPUTY" run --headless --once >/dev/null 2>&1 || true

assert_eq "$(test -f "$MARKER_B" && echo yes || echo no)" "no" \
  "empty queue: no spawn notification when nothing is claimed"

assert_eq "$(grep '===SPAWN===' "$DEPUTY_ROOT/.deputy/cron.log" 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "empty queue: no ===SPAWN=== line in cron.log"

rm -f "$REC_B"

# ─────────────────────────────────────────────────────────────────────────────
# Test C: notify_on_spawn=0 → notification suppressed even on headless spawn
# ─────────────────────────────────────────────────────────────────────────────
setup_repo
NOTIFY_DIR_C="$(mktemp -d)"
export PATH="$NOTIFY_DIR_C:$ORIG_PATH"

MARKER_C="$DEPUTY_ROOT/.notifyC"
REC_C="$(make_recorder "$MARKER_C")"
prepend_path "$NOTIFY_DIR_C" notify-send "$REC_C"

printf 'notify=desktop\nnotify_on_spawn=0\n' > "$DEPUTY_ROOT/.deputy/config"
bash "$DEPUTY" add "suppressed spawn item" --p0

ORCH_C="$(mktemp)"
cat > "$ORCH_C" <<EOFC
#!/usr/bin/env bash
bash "$DEPUTY" set "\$1" done >/dev/null 2>&1 || true
exit 0
EOFC
chmod +x "$ORCH_C"

DEPUTY_ORCHESTRATOR_CMD="$ORCH_C" DEPUTY_AVAIL="claude,gemini" \
  bash "$DEPUTY" run --headless --once >/dev/null 2>&1 || true

# The 'done' state notification may still fire, but the spawn notification must not.
assert_eq "$(grep 'Autonomous spawn' "$MARKER_C" 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "notify_on_spawn=0: spawn notification suppressed"

assert_eq "$(grep '===SPAWN===' "$DEPUTY_ROOT/.deputy/cron.log" 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "notify_on_spawn=0: no ===SPAWN=== in cron.log"

rm -f "$REC_C" "$ORCH_C"
