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

# ── Test 1: ensure installs a line with */15, cd '<root>', deputy, and marker # deputy[<root>] ──
ROOT_A="$DEPUTY_ROOT"
bash "$DEPUTY" cron --ensure
assert_eq "$(grep -c "deputy\[$ROOT_A\]" "$STORE")" "1" "ensure installs one entry with repo marker"
assert_contains "$(cat "$STORE")" "*/15 * * * *" "ensure uses */15 schedule"
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

# ── Test 9: self-arm — cron line present but NOT */15 → cmd_run restores */15 ──
: > "$STORE"
ROOT_SA="$DEPUTY_ROOT"  # use default setup_repo root

# Simulate a prior reschedule: write a non-*/15 line with the repo marker
printf "0 3 * * * cd '%s' && deputy run  # deputy[%s]\n" "$ROOT_SA" "$ROOT_SA" > "$STORE"

ORCH_SA="$(mktemp)"
cat > "$ORCH_SA" <<'EOFORCH'
#!/usr/bin/env bash
# no-op orchestrator for self-arm test
exit 0
EOFORCH
chmod +x "$ORCH_SA"

# deputy run should detect the marker, notice it's not */15, and re-arm
DEPUTY_ORCHESTRATOR_CMD="$ORCH_SA" DEPUTY_AVAIL="claude,gemini" \
  bash "$DEPUTY" run --once >/dev/null 2>&1 || true

assert_contains "$(cat "$STORE")" "*/15 * * * *" "self-arm: run restores */15 line when marker present but non-*/15"
assert_eq "$(grep -c "deputy\[$ROOT_SA\]" "$STORE")" "1" "self-arm: only one repo line after re-arm"

# ── Test 10: self-arm no-op when */15 line already present ──
: > "$STORE"
STORE_CONTENT="$(printf "*/15 * * * * cd '%s' && deputy run >> '%s/.deputy/cron.log' 2>&1  # deputy[%s]\n" \
  "$ROOT_SA" "$ROOT_SA" "$ROOT_SA")"
printf '%s\n' "$STORE_CONTENT" > "$STORE"
STORE_BEFORE="$(cat "$STORE")"

DEPUTY_ORCHESTRATOR_CMD="$ORCH_SA" DEPUTY_AVAIL="claude,gemini" \
  bash "$DEPUTY" run --once >/dev/null 2>&1 || true

STORE_AFTER="$(cat "$STORE")"
assert_eq "$STORE_BEFORE" "$STORE_AFTER" "self-arm: no rewrite when */15 line already present (byte-identical)"

# ── Test 11: no marker → deputy run does NOT add any cron line ──
: > "$STORE"  # empty — no marker for this repo

DEPUTY_ORCHESTRATOR_CMD="$ORCH_SA" DEPUTY_AVAIL="claude,gemini" \
  bash "$DEPUTY" run --once >/dev/null 2>&1 || true

assert_eq "$(grep -c 'deputy\[' "$STORE" 2>/dev/null || true)" "0" \
  "no marker: run must NOT add cron line"

rm -f "$ORCH_SA"

# ── Test 12: PATH idempotency — running deputy twice does not duplicate dirs ──
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

rm -f "$STORE" "$FAKE"
rm -rf "$ROOT_B" "$PREFIX_BASE" 2>/dev/null || true
