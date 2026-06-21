#!/usr/bin/env bash
# tests/test_notify_spawn.sh — #59: announce when the heartbeat autonomously spawns a worker.
source "$(dirname "$0")/lib.sh"

mk_orch() { local f; f="$(mktemp)"; printf '#!/usr/bin/env bash\nbash "%s" set "$1" done >/dev/null 2>&1\n' "$DEPUTY" > "$f"; chmod +x "$f"; printf '%s' "$f"; }
ORCH="$(mk_orch)"
run_once() { DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true bash "$DEPUTY" run --once 2>&1; }

# 1: a headless (no-TTY) spawn writes the prominent ===SPAWN=== marker naming the item.
setup_repo
bash "$DEPUTY" add "spawn me" --p0 >/dev/null
out="$(run_once)"
assert_contains "$out" "===SPAWN===" "headless spawn writes the ===SPAWN=== cron.log marker"
assert_contains "$out" "autonomous worker started" "spawn line announces the worker start"

# 2: notify_on_spawn=0 suppresses it.
setup_repo
mkdir -p "$DEPUTY_ROOT/.deputy"; printf 'notify_on_spawn=0\n' > "$DEPUTY_ROOT/.deputy/config"
bash "$DEPUTY" add "spawn me" --p0 >/dev/null
out="$(run_once)"
assert_eq "$(printf '%s' "$out" | grep -c '===SPAWN===')" "0" "notify_on_spawn=0 suppresses the spawn marker"

# 3: empty queue -> nothing claimed -> no spawn notify.
setup_repo
out="$(run_once)"
assert_eq "$(printf '%s' "$out" | grep -c '===SPAWN===')" "0" "empty queue -> no spawn notify"

# 4: notify=desktop -> notify-send fires with the 'Autonomous spawn' label.
setup_repo
BIN="$(mktemp -d)"; rec="$BIN/.ns"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$rec" > "$BIN/notify-send"; chmod +x "$BIN/notify-send"
mkdir -p "$DEPUTY_ROOT/.deputy"; printf 'notify=desktop\n' > "$DEPUTY_ROOT/.deputy/config"
bash "$DEPUTY" add "spawn me" --p0 >/dev/null
DEPUTY_NOTIFY_SYNC=1 PATH="$BIN:$PATH" DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true bash "$DEPUTY" run --once >/dev/null 2>&1
assert_contains "$(cat "$rec" 2>/dev/null)" "Autonomous spawn" "notify=desktop fires notify-send with the spawn label"

# 5: an interactive (headed/PTY) run does NOT fire the spawn marker.
if command -v script >/dev/null 2>&1; then
  setup_repo
  bash "$DEPUTY" add "spawn me" --p0 >/dev/null
  pcmd="DEPUTY_ORCHESTRATOR_CMD='$ORCH' DEPUTY_AVAIL='claude' DEPUTY_CRONTAB=/bin/true bash '$DEPUTY' run --once"
  pout="$(script -qec "$pcmd" /dev/null 2>&1 || true)"
  assert_eq "$(printf '%s' "$pout" | grep -c '===SPAWN===')" "0" "interactive (headed) run does NOT fire the spawn marker"
fi

# 6: notify_on_spawn documented in deputy help.
assert_contains "$(bash "$DEPUTY" help 2>&1)" "notify_on_spawn" "notify_on_spawn documented in deputy help"

rm -f "$ORCH"
