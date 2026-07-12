#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

# Fake crontab: a script backed by a file. `<cmd> -l` prints it; `<cmd> -` reads stdin into it.
STORE="$(mktemp)"; : > "$STORE"
FAKE="$(mktemp)"
cat > "$FAKE" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-l" ]]; then cat "$STORE"; exit 0; fi
if [[ "\${1:-}" == "-" ]]; then cat > "$STORE"; exit 0; fi
exit 0
EOF
chmod +x "$FAKE"
export DEPUTY_CRONTAB="$FAKE"

# ── Test 1: ensure installs a line with */10 (always-on default), cd '<root>', deputy, and marker # deputy[<root>] ──
ROOT_A="$DEPUTY_ROOT"
bash "$DEPUTY" cron --ensure
assert_eq "$(grep -c "deputy\[$ROOT_A\]" "$STORE")" "1" "ensure installs one entry with repo marker"
assert_contains "$(cat "$STORE")" "*/10 * * * *" "ensure uses */10 schedule (always-on default)"
assert_contains "$(cat "$STORE")" "cd '$ROOT_A'" "ensure uses cd '<root>'"
assert_contains "$(cat "$STORE")" "# deputy[$ROOT_A]" "ensure writes per-repo marker"

# ── Test 2: ensure is idempotent ──
bash "$DEPUTY" cron --ensure
assert_eq "$(grep -c "deputy\[$ROOT_A\]" "$STORE")" "1" "ensure idempotent"

# ── Test 3: reschedule at a parsed reset hour (11pm -> 23) ──
bash "$DEPUTY" cron --reschedule "resets 11pm"
assert_contains "$(cat "$STORE")" "0 23 " "reschedule uses parsed hour 23"
assert_eq "$(grep -c "deputy\[$ROOT_A\]" "$STORE")" "1" "reschedule keeps one entry with repo marker"

# ── Test 4: reschedule with NO parseable hour → conservative 0 */2 fallback ──
bash "$DEPUTY" cron --reschedule "no time info here"
assert_contains "$(cat "$STORE")" "0 */2 " "reschedule fallback uses 0 */2 schedule"
assert_eq "$(grep -c "deputy\[$ROOT_A\]" "$STORE")" "1" "reschedule fallback keeps one entry"

# ── Test 5: remove (must also exit 0, not just produce the right file) ──
bash "$DEPUTY" cron --ensure  # re-enable before remove test
bash "$DEPUTY" cron --remove; rc=$?
assert_eq "$rc" "0" "remove exits 0"
assert_eq "$(grep -c "deputy\[$ROOT_A\]" "$STORE" 2>/dev/null || true)" "0" "remove deletes entry for this repo"

# ── #88: bare subcommands (ensure|remove|reschedule) match the --flag aliases ──
bash "$DEPUTY" cron ensure
assert_eq "$(grep -c "deputy\[$ROOT_A\]" "$STORE")" "1" "bare 'cron ensure' installs the entry"
bash "$DEPUTY" cron reschedule "resets 11pm"
assert_contains "$(cat "$STORE")" "0 23 " "bare 'cron reschedule' parses the hour"
bash "$DEPUTY" cron remove
assert_eq "$(grep -c "deputy\[$ROOT_A\]" "$STORE" 2>/dev/null || true)" "0" "bare 'cron remove' deletes the entry"

# ── Test 6: multi-repo — ensure for repo A, then repo B, both markers preserved ──
: > "$STORE"
ROOT_B="$(mktemp -d)"
mkdir -p "$ROOT_B/.deputy"

# Ensure A
bash "$DEPUTY" cron --ensure
# Ensure B (different DEPUTY_ROOT)
DEPUTY_ROOT="$ROOT_B" bash "$DEPUTY" cron --ensure

assert_eq "$(grep -c "deputy\[$ROOT_A\]" "$STORE")" "1" "multi-repo: root A preserved after root B ensure"
assert_eq "$(grep -c "deputy\[$ROOT_B\]" "$STORE")" "1" "multi-repo: root B present"
total_lines="$(grep -c 'deputy\[' "$STORE")"
assert_eq "$total_lines" "2" "multi-repo: exactly two deputy lines total"

# ── Test 7: prefix collision — /tmp/x/repo and /tmp/x/repo-two both coexist ──
: > "$STORE"
ROOT_REPO="$(mktemp -d)"
ROOT_REPO_TWO="$(mktemp -d)"
# rename to create a prefix relationship
PREFIX_BASE="$(mktemp -d)"
rmdir "$ROOT_REPO" "$ROOT_REPO_TWO" 2>/dev/null || true
ROOT_REPO="$PREFIX_BASE/repo"
ROOT_REPO_TWO="$PREFIX_BASE/repo-two"
mkdir -p "$ROOT_REPO/.deputy" "$ROOT_REPO_TWO/.deputy"

DEPUTY_ROOT="$ROOT_REPO" bash "$DEPUTY" cron --ensure
DEPUTY_ROOT="$ROOT_REPO_TWO" bash "$DEPUTY" cron --ensure

assert_eq "$(grep -c "deputy\[$ROOT_REPO\]" "$STORE")" "1" "prefix-collision: exact repo line present"
assert_eq "$(grep -c "deputy\[$ROOT_REPO_TWO\]" "$STORE")" "1" "prefix-collision: repo-two line present"
# Verify repo line was NOT clobbered by repo-two ensure
assert_contains "$(cat "$STORE")" "# deputy[$ROOT_REPO]" "prefix-collision: repo marker intact after repo-two ensure"

# ── Test 8: --remove for root A removes only A's line, leaving B ──
: > "$STORE"
bash "$DEPUTY" cron --ensure   # A
DEPUTY_ROOT="$ROOT_B" bash "$DEPUTY" cron --ensure  # B

bash "$DEPUTY" cron --remove   # remove A only
assert_eq "$(grep -c "deputy\[$ROOT_A\]" "$STORE" 2>/dev/null || true)" "0" "remove A leaves zero A lines"
assert_eq "$(grep -c "deputy\[$ROOT_B\]" "$STORE")" "1" "remove A preserves B line"

# ── reset-hour parser unit checks via a hidden subcommand ──
assert_eq "$(bash "$DEPUTY" _resethour 'resets 3am')"  "3"  "3am -> 3"
assert_eq "$(bash "$DEPUTY" _resethour 'resets 12am')" "0"  "12am -> 0"
assert_eq "$(bash "$DEPUTY" _resethour 'resets 12pm')" "12" "12pm -> 12"
assert_eq "$(bash "$DEPUTY" _resethour 'no time here')" ""  "no match -> empty"

# ── _resetsecs: per-provider seconds extraction (pure / deterministic) ──
# Gemini: "retry after: Ns" (colon form)
assert_eq "$(bash "$DEPUTY" _resetsecs 'retry after: 3600s')" "3600" "gemini: retry after: 3600s"
assert_eq "$(bash "$DEPUTY" _resetsecs 'retry after: 60')"    "60"   "gemini: retry after: 60 (no unit)"
# Gemini: "retry-after: N" (HTTP header echo)
assert_eq "$(bash "$DEPUTY" _resetsecs 'retry-after: 120')"   "120"  "gemini: retry-after header"
# Gemini JSON: retryDelay
assert_eq "$(bash "$DEPUTY" _resetsecs '{"retryDelay":"3600s"}')" "3600" "gemini: retryDelay JSON"
assert_eq "$(bash "$DEPUTY" _resetsecs 'retryDelay: 1800s')"      "1800" "gemini: retryDelay plain"
# Codex: "retry after N seconds" (no colon)
assert_eq "$(bash "$DEPUTY" _resetsecs 'Rate limit exceeded. Please retry after 60 seconds.')" "60" "codex: retry after 60 seconds"
assert_eq "$(bash "$DEPUTY" _resetsecs 'please retry after 30 sec')" "30" "codex: retry after 30 sec"
# Codex: "try again in N minutes/seconds"
assert_eq "$(bash "$DEPUTY" _resetsecs 'try again in 5 minutes')"  "300" "codex: try again in 5 minutes"
assert_eq "$(bash "$DEPUTY" _resetsecs 'try again in 90 seconds')" "90"  "codex: try again in 90 seconds"
assert_eq "$(bash "$DEPUTY" _resetsecs 'try again in 2 min')"      "120" "codex: try again in 2 min"
# No match
assert_eq "$(bash "$DEPUTY" _resetsecs 'RESOURCE_EXHAUSTED quota exceeded')" "" "no seconds: empty"
assert_eq "$(bash "$DEPUTY" _resetsecs 'no time info here')"                 "" "no time: empty"

# ── _resethour: ISO 8601 timestamps (Gemini quota reset) — deterministic ──
assert_eq "$(bash "$DEPUTY" _resethour '2025-01-15T23:00:00Z')" "23" "ISO: exact hour 23 (no rounding)"
assert_eq "$(bash "$DEPUTY" _resethour '2025-01-15T09:00:00Z')" "9"  "ISO: exact hour 9 (no rounding)"
assert_eq "$(bash "$DEPUTY" _resethour '2025-01-15T23:05:00Z')" "0"  "ISO: 23:05 rounds up to 0 (midnight)"
assert_eq "$(bash "$DEPUTY" _resethour '2025-01-15T08:30:00Z')" "9"  "ISO: 08:30 rounds up to 9"
# _resethour with seconds-based input: inject time for deterministic result
# 10:30 + 3600s (60 min) = 11:30 → ceil to hour 12
assert_eq "$(DEPUTY_NOW_HOUR="10:30" bash "$DEPUTY" _resethour 'retry after: 3600s')" "12" \
  "seconds-based: 10:30 + 3600s → hour 12"
# 10:00 + 3600s = 11:00 → exactly on the hour → 11
assert_eq "$(DEPUTY_NOW_HOUR="10:00" bash "$DEPUTY" _resethour 'retry after: 3600s')" "11" \
  "seconds-based: 10:00 + 3600s → hour 11"
# _resetsecs is time-independent; no injection needed
assert_eq "$(bash "$DEPUTY" _resetsecs 'try again in 5 minutes')" "300" \
  "seconds-based: _resetsecs 5min = 300s (no time injection needed)"

# ── Test 9: cron --ensure creates cron.enabled marker AND writes */10 line (always-on default) ──
: > "$STORE"
ROOT_MARKER="$DEPUTY_ROOT"
bash "$DEPUTY" cron --ensure
assert_eq "$(test -f "$ROOT_MARKER/.deputy/cron.enabled" && echo yes || echo no)" "yes" \
  "ensure creates cron.enabled marker"
assert_contains "$(cat "$STORE")" "*/10 * * * *" "ensure writes */10 line (always-on default)"
# _cron_enabled via the marker (indirect: ensure it's a file, covered above)

# ── Test 10: cron --remove deletes the marker AND removes the line ──
bash "$DEPUTY" cron --remove
assert_eq "$(test -f "$ROOT_MARKER/.deputy/cron.enabled" && echo yes || echo no)" "no" \
  "remove deletes cron.enabled marker"
assert_eq "$(grep -c "deputy\[$ROOT_MARKER\]" "$STORE" 2>/dev/null || true)" "0" \
  "remove deletes cron line from store"

# ── Test 11: marker absent → deputy run leaves crontab store unchanged ──
: > "$STORE"  # empty store, no marker file for this repo (just removed above)
rm -f "$ROOT_MARKER/.deputy/cron.enabled" 2>/dev/null || true

ORCH_LC="$(mktemp)"
cat > "$ORCH_LC" <<'EOFORCH'
#!/usr/bin/env bash
# no-op orchestrator
exit 0
EOFORCH
chmod +x "$ORCH_LC"

bash "$DEPUTY" add "lifecycle job" --p0

DEPUTY_ORCHESTRATOR_CMD="$ORCH_LC" DEPUTY_AVAIL="claude,gemini" \
  bash "$DEPUTY" run --once >/dev/null 2>&1 || true
assert_eq "$(grep -c 'deputy\[' "$STORE" 2>/dev/null || true)" "0" \
  "no marker: run must NOT add cron line"

# ── Test 12 (Always-on): marker present → deputy run does NOT remove cron line ──
: > "$STORE"
# Re-enable (sets marker + arms initial line)
bash "$DEPUTY" cron --ensure
# Add a couple of items so the run loop has work to do
bash "$DEPUTY" add "lifecycle item 1" --p0
bash "$DEPUTY" add "lifecycle item 2" --p0

# Record what the crontab looks like before run (should have */10 from --ensure)
STORE_BEFORE_RUN="$(cat "$STORE")"

# Capture-script: record the crontab at orchestrator-call time
# (always-on model: the line should STILL BE PRESENT during run)
CAPTURE_FILE="$(mktemp)"
ORCH_CAP="$(mktemp)"
cat > "$ORCH_CAP" <<EOFCAP
#!/usr/bin/env bash
# Capture crontab state at orchestrator invocation; also mark the item done.
bash "$DEPUTY" set "\$1" done >/dev/null 2>&1 || true
# Capture the crontab store at this instant (first invocation wins; don't overwrite if exists)
[[ -s "$CAPTURE_FILE" ]] || cat "$STORE" > "$CAPTURE_FILE"
exit 0
EOFCAP
chmod +x "$ORCH_CAP"

DEPUTY_ORCHESTRATOR_CMD="$ORCH_CAP" DEPUTY_AVAIL="claude,gemini" \
  bash "$DEPUTY" run >/dev/null 2>&1 || true

# Always-on model: the deputy line must be PRESENT during the run (NOT removed)
assert_eq "$(grep -c "deputy\[$ROOT_MARKER\]" "$CAPTURE_FILE" 2>/dev/null || true)" "1" \
  "always-on: cron line present at orchestrator-call time (NOT removed)"

# After idle exit, the */10 line should still be present (never removed)
assert_eq "$(grep -c "deputy\[$ROOT_MARKER\]" "$STORE")" "1" \
  "always-on: cron line still present after run goes idle"
assert_contains "$(cat "$STORE")" "*/10 * * * *" \
  "always-on: persistent line uses */10 schedule"

rm -f "$ORCH_LC" "$ORCH_CAP" "$CAPTURE_FILE"

# ── Test 13: PATH idempotency — running deputy twice does not duplicate dirs ──
# We source deputy.sh in a subshell to check PATH expansion doesn't duplicate entries.
path_check="$(bash -c '
  source "'"$DEPUTY"'" help >/dev/null 2>&1 || true
  source "'"$DEPUTY"'" help >/dev/null 2>&1 || true
  # Count occurrences of fnm/aliases/default/bin in PATH
  count=0
  IFS=: read -ra dirs <<< "$PATH"
  for d in "${dirs[@]}"; do
    [[ "$d" == *"fnm/aliases/default/bin"* ]] && count=$((count+1))
  done
  printf "%d" "$count"
' 2>/dev/null)"
# Should be 0 (not installed) or 1 (installed once), never > 1
if [[ "$path_check" -gt 1 ]]; then
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf 'FAIL: PATH idempotency: fnm dir appears %d times (expected <=1)\n' "$path_check" >&2
fi
TESTS_RUN=$((TESTS_RUN + 1))

# ── Test 14: cron status — enabled + scheduled ──
: > "$STORE"
bash "$DEPUTY" cron --ensure
status_out="$(bash "$DEPUTY" cron status)"
assert_contains "$status_out" "enabled:  yes" "status shows enabled yes after --ensure"
assert_contains "$status_out" "schedule: */10" "status shows schedule when line is in crontab"

# ── Test 15: cron status — disabled + not scheduled ──
bash "$DEPUTY" cron --remove
status_out2="$(bash "$DEPUTY" cron status)"
assert_contains "$status_out2" "enabled:  no" "status shows enabled no after --remove"
assert_contains "$status_out2" "schedule: (not scheduled)" "status shows not-scheduled when no crontab line"

# ── Test 16: cron status — last run shows never when no cron.log ──
assert_contains "$status_out2" "last run: (never)" "status shows never when cron.log absent"

# ── Test 17: cron status — last run shows timestamp when cron.log exists ──
bash "$DEPUTY" cron --ensure
touch "$DEPUTY_ROOT/.deputy/cron.log"
status_out3="$(bash "$DEPUTY" cron status)"
assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    TESTS_FAILED=$((TESTS_FAILED+1)); printf 'FAIL: %s\n' "$msg" >&2
  else TESTS_RUN=$((TESTS_RUN+1)); fi
}
assert_not_contains "$status_out3" "last run: (never)" "status shows non-never last run when cron.log present"
assert_contains "$status_out3" "last run:" "status includes last run line"

rm -f "$STORE" "$FAKE"
rm -rf "$ROOT_B" "$PREFIX_BASE" 2>/dev/null || true
