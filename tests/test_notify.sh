#!/usr/bin/env bash
# tests/test_notify.sh — external notification tests.
# Injects fake notify-send / curl / mail binaries via a temp PATH prefix so
# deputy's _notify_* helpers are exercised without touching any real service.
source "$(dirname "$0")/lib.sh"
# The PATH self-fix would prepend ~/.local/bin ahead of our fake notifier dir on
# some machines, giving false-greens. Disable it so the injected fakes always win.
export DEPUTY_NO_PATH_FIX=1

# Run notifications synchronously so assertions don't race the background process.
export DEPUTY_NOTIFY_SYNC=1

# ── helpers ──────────────────────────────────────────────────────────────────

# Create a fake binary that records its arguments to <marker_file> and exits 0.
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

# Prepend a directory to PATH so the fake binary is found first.
prepend_path() {
  local dir="$1" name="$2" target="$3"
  ln -sf "$target" "$dir/$name"
}

setup_notify_repo() {
  setup_repo
  NOTIFY_DIR="$(mktemp -d)"
  export PATH="$NOTIFY_DIR:$PATH"
}

# ── Test 1: no notify config → no notification fired ─────────────────────────
setup_notify_repo
MARKER1="$DEPUTY_ROOT/.notify1"
REC1="$(make_recorder "$MARKER1")"
prepend_path "$NOTIFY_DIR" notify-send "$REC1"

printf '%s\n' 'item one' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" set "item one" done >/dev/null 2>&1

assert_eq "$(test -f "$MARKER1" && echo yes || echo no)" "no" \
  "no notify config → notify-send never called"

rm -f "$REC1"

# ── Test 2: notify=desktop → fires on 'done' ─────────────────────────────────
setup_notify_repo
MARKER2="$DEPUTY_ROOT/.notify2"
REC2="$(make_recorder "$MARKER2")"
prepend_path "$NOTIFY_DIR" notify-send "$REC2"

printf 'notify=desktop\n' > "$DEPUTY_ROOT/.deputy/config"
printf '%s\n' 'finish me' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" set "finish me" done >/dev/null 2>&1

assert_eq "$(test -f "$MARKER2" && echo yes || echo no)" "yes" \
  "notify=desktop fires notify-send on done"
assert_contains "$(cat "$MARKER2")" "Deputy: Done" "done notification has correct title"
assert_contains "$(cat "$MARKER2")" "finish me"    "done notification has description"

rm -f "$REC2"

# ── Test 3: notify=desktop fires on 'surfaced' ───────────────────────────────
setup_notify_repo
MARKER3="$DEPUTY_ROOT/.notify3"
REC3="$(make_recorder "$MARKER3")"
prepend_path "$NOTIFY_DIR" notify-send "$REC3"

printf 'notify=desktop\n' > "$DEPUTY_ROOT/.deputy/config"
printf '%s\n' 'needs input' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" set "needs input" surfaced >/dev/null 2>&1

assert_contains "$(cat "$MARKER3")" "Needs Input"  "surfaced notification title"
assert_contains "$(cat "$MARKER3")" "needs input"  "surfaced notification body"

rm -f "$REC3"

# ── Test 4: notify=desktop fires on 'failed' and 'cancelled' ─────────────────
setup_notify_repo
MARKER4="$DEPUTY_ROOT/.notify4"
REC4="$(make_recorder "$MARKER4")"
prepend_path "$NOTIFY_DIR" notify-send "$REC4"

printf 'notify=desktop\n' > "$DEPUTY_ROOT/.deputy/config"
printf '%s\n' 'will fail' 'will cancel' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" set "will fail"   failed    >/dev/null 2>&1
bash "$DEPUTY" set "will cancel" cancelled >/dev/null 2>&1

assert_contains "$(cat "$MARKER4")" "Failed"    "failed  notification title"
assert_contains "$(cat "$MARKER4")" "Cancelled" "cancelled notification title"

rm -f "$REC4"

# ── Test 5: intermediate states (running, paused, waiting) → NOT notified ────
setup_notify_repo
MARKER5="$DEPUTY_ROOT/.notify5"
REC5="$(make_recorder "$MARKER5")"
prepend_path "$NOTIFY_DIR" notify-send "$REC5"

printf 'notify=desktop\n' > "$DEPUTY_ROOT/.deputy/config"
printf '%s\n' 'in flight' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" set "in flight" running >/dev/null 2>&1
bash "$DEPUTY" set "@in flight" paused  >/dev/null 2>&1

assert_eq "$(test -f "$MARKER5" && echo yes || echo no)" "no" \
  "running/paused transitions do NOT fire notification"

rm -f "$REC5"

# ── Test 6: notify=push → fires curl with correct URL and headers ─────────────
setup_notify_repo
MARKER6="$DEPUTY_ROOT/.notify6"
REC6="$(make_recorder "$MARKER6")"
prepend_path "$NOTIFY_DIR" curl "$REC6"

printf 'notify=push\nnotify_push_url=https://ntfy.example.com/myboard\n' > "$DEPUTY_ROOT/.deputy/config"
printf '%s\n' 'push test' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" set "push test" done >/dev/null 2>&1

assert_eq "$(test -f "$MARKER6" && echo yes || echo no)" "yes" \
  "notify=push fires curl on done"
assert_contains "$(cat "$MARKER6")" "ntfy.example.com" "push curl uses configured URL"
assert_contains "$(cat "$MARKER6")" "push test"         "push body contains description"

rm -f "$REC6"

# ── Test 7: notify=push with no notify_push_url → curl NOT called ─────────────
setup_notify_repo
MARKER7="$DEPUTY_ROOT/.notify7"
REC7="$(make_recorder "$MARKER7")"
prepend_path "$NOTIFY_DIR" curl "$REC7"

printf 'notify=push\n' > "$DEPUTY_ROOT/.deputy/config"  # no notify_push_url
printf '%s\n' 'push no url' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" set "push no url" done >/dev/null 2>&1

assert_eq "$(test -f "$MARKER7" && echo yes || echo no)" "no" \
  "push without notify_push_url does not call curl"

rm -f "$REC7"

# ── Test 8: notify=email → fires mail with correct subject and recipient ──────
setup_notify_repo
MARKER8="$DEPUTY_ROOT/.notify8"
REC8="$(make_recorder "$MARKER8")"
prepend_path "$NOTIFY_DIR" mail "$REC8"

printf 'notify=email\nnotify_email=boss@example.com\n' > "$DEPUTY_ROOT/.deputy/config"
printf '%s\n' 'email test' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" set "email test" done >/dev/null 2>&1

assert_eq "$(test -f "$MARKER8" && echo yes || echo no)" "yes" \
  "notify=email fires mail on done"
assert_contains "$(cat "$MARKER8")" "boss@example.com" "email recipient is correct"
assert_contains "$(cat "$MARKER8")" "Done"             "email subject contains state label"

rm -f "$REC8"

# ── Test 9: notify=email with no notify_email → mail NOT called ───────────────
setup_notify_repo
MARKER9="$DEPUTY_ROOT/.notify9"
REC9="$(make_recorder "$MARKER9")"
prepend_path "$NOTIFY_DIR" mail "$REC9"

printf 'notify=email\n' > "$DEPUTY_ROOT/.deputy/config"  # no notify_email
printf '%s\n' 'email no addr' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" set "email no addr" done >/dev/null 2>&1

assert_eq "$(test -f "$MARKER9" && echo yes || echo no)" "no" \
  "email without notify_email does not call mail"

rm -f "$REC9"

# ── Test 10: multiple channels in one config ──────────────────────────────────
setup_notify_repo
MARKER10_D="$DEPUTY_ROOT/.notify10d"
MARKER10_C="$DEPUTY_ROOT/.notify10c"
REC10D="$(make_recorder "$MARKER10_D")"
REC10C="$(make_recorder "$MARKER10_C")"
prepend_path "$NOTIFY_DIR" notify-send "$REC10D"
prepend_path "$NOTIFY_DIR" curl        "$REC10C"

printf 'notify=desktop,push\nnotify_push_url=https://ntfy.example.com/combo\n' \
  > "$DEPUTY_ROOT/.deputy/config"
printf '%s\n' 'multi channel' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" set "multi channel" failed >/dev/null 2>&1

assert_eq "$(test -f "$MARKER10_D" && echo yes || echo no)" "yes" \
  "multi-channel: desktop fires"
assert_eq "$(test -f "$MARKER10_C" && echo yes || echo no)" "yes" \
  "multi-channel: push fires"

rm -f "$REC10D" "$REC10C"

# ── Test 11: set no-match → no notification even when channels configured ─────
setup_notify_repo
MARKER11="$DEPUTY_ROOT/.notify11"
REC11="$(make_recorder "$MARKER11")"
prepend_path "$NOTIFY_DIR" notify-send "$REC11"

printf 'notify=desktop\n' > "$DEPUTY_ROOT/.deputy/config"
bash "$DEPUTY" set "ghost item" done 2>/dev/null || true

assert_eq "$(test -f "$MARKER11" && echo yes || echo no)" "no" \
  "no-match set → no notification fired"

rm -f "$REC11"
