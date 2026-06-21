#!/usr/bin/env bash
# tests/test_headed.sh — #51: headed (live-streaming) vs headless (buffered) run output.
# Headed when stdout is a TTY, unless opted out via --headless / headed=0.
source "$(dirname "$0")/lib.sh"

# A mock orchestrator: echo a unique marker, then mark the item done so the loop ends.
make_orch() {
  local f; f="$(mktemp)"
  printf '#!/usr/bin/env bash\necho "ORCH_MARKER_42"\nbash "%s" set "$1" done >/dev/null 2>&1\n' "$DEPUTY" > "$f"
  chmod +x "$f"; printf '%s' "$f"
}

# ── _run_is_headed precedence (no TTY in the test harness) ───────────────────────
setup_repo
assert_eq "$(source "$DEPUTY"; _run_is_headed && echo headed || echo headless)" \
  "headless" "_run_is_headed: no TTY (cron/pipe) -> headless"
assert_eq "$(source "$DEPUTY"; _RUN_HEADLESS=1; _run_is_headed && echo headed || echo headless)" \
  "headless" "_run_is_headed: --headless flag -> headless"
printf 'headed=0\n' >> "$DEPUTY_ROOT/.deputy/config"
assert_eq "$(source "$DEPUTY"; _run_is_headed && echo headed || echo headless)" \
  "headless" "_run_is_headed: headed=0 config -> headless"

# ── Headless run: orchestrator output surfaced exactly once (no double-print) ────
setup_repo
printf 'max_items=0\nhuman_backoff=0\n' > "$DEPUTY_ROOT/.deputy/config"
: > "$DEPUTY_ROOT/.deputy/cron.enabled"
ORCH="$(make_orch)"
bash "$DEPUTY" add "headless job" --p0 >/dev/null
out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude" DEPUTY_ALLOW_ANY_BRANCH=1 \
        bash "$DEPUTY" run --once 2>&1)"
assert_contains "$out" "ORCH_MARKER_42" "headless run surfaces the orchestrator output"
assert_eq "$(printf '%s\n' "$out" | grep -c 'ORCH_MARKER_42')" "1" "headless: output appears exactly once (no double-print)"

# ── Headed run under a PTY (so [ -t 1 ] is true): streams live, exactly once ─────
if command -v script >/dev/null 2>&1; then
  setup_repo
  printf 'max_items=0\nhuman_backoff=0\n' > "$DEPUTY_ROOT/.deputy/config"
  : > "$DEPUTY_ROOT/.deputy/cron.enabled"
  ORCH="$(make_orch)"
  bash "$DEPUTY" add "headed job" --p0 >/dev/null
  # 'script' gives the child a pseudo-TTY on stdout -> _run_is_headed true -> tee path.
  pcmd="DEPUTY_ROOT='$DEPUTY_ROOT' DEPUTY_ORCHESTRATOR_CMD='$ORCH' DEPUTY_AVAIL=claude DEPUTY_ALLOW_ANY_BRANCH=1 bash '$DEPUTY' run --once"
  pout="$(script -qec "$pcmd" /dev/null 2>&1 || true)"
  assert_contains "$pout" "ORCH_MARKER_42" "headed (PTY) run streams the orchestrator output"
  assert_eq "$(printf '%s\n' "$pout" | grep -c 'ORCH_MARKER_42')" "1" "headed: streamed exactly once (no tee+cat double-print)"
  # item completed under headed mode
  assert_contains "$(bash "$DEPUTY" list --done)" "headed job" "headed run completes the item"
else
  printf 'note: skipping PTY headed test (no script(1) available)\n' >&2
fi
