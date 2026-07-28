#!/usr/bin/env bash
# tests/test_accept.sh — #113(A): the acceptance record, the falsifiable done-criterion.
#
# `done` in deputy means steps committed + tests green + merged — none of which proves the
# REPORTED SYMPTOM is gone. The acceptance record freezes what the human observed, at add
# time, in their words, so `deputy verify` has something to check the fix against.
#
# The grill itself is interactive-only and cannot run here (no TTY) — which is exactly the
# property most worth asserting: a test, a pipe, cron, or a headless worker must NEVER block
# on a read that will never be answered.
source "$(dirname "$0")/lib.sh"
setup_repo

id_of() { bash "$DEPUTY" list | grep -F "$1" | grep -oE '#[0-9]+' | head -1 | tr -d '#'; }

# ── flags record all four fields ─────────────────────────────────────────────
bash "$DEPUTY" add "FCF column is blank on the fundamentals tab" \
  --observe 'psql -f q/fcf.sql AAPL' --actual 'FCF column empty' \
  --expect 'a non-null number' --where 'prod nightly pipeline' >/dev/null
ID="$(id_of 'FCF column is blank')"
out="$(bash "$DEPUTY" accept "$ID")"
assert_contains "$out" "observe: psql -f q/fcf.sql AAPL" "accept records observe"
assert_contains "$out" "actual: FCF column empty"        "accept records actual"
assert_contains "$out" "expect: a non-null number"       "accept records expect"
assert_contains "$out" "where: prod nightly pipeline"    "accept records where"

# The record is keyed by the FROZEN slug (#99), so it survives every resume/rerun.
SLUG="$(bash "$DEPUTY" slug "$ID")"
assert_eq "$(test -f "$DEPUTY_ROOT/.deputy/accept/$SLUG.md" && echo yes || echo no)" "yes" \
  "record is stored under the frozen slug"

# ── non-interactive NEVER blocks, but never stays silent either ──────────────
# A bug-shaped description with no acceptance fields: the add must succeed and warn.
err="$(bash "$DEPUTY" add "login redirect is broken after logout" 2>&1 >/dev/null)"
assert_contains "$err" "no acceptance record" "bug-shaped add without fields warns on stderr"
assert_contains "$(bash "$DEPUTY" list)" "login redirect is broken" "warned add is still queued"

# A chore-shaped description is not bug-shaped: no prompt, no warning, no noise.
err2="$(bash "$DEPUTY" add "tidy the README wording" 2>&1 >/dev/null)"
assert_eq "$(printf '%s' "$err2" | grep -c 'acceptance')" "0" "chore-shaped add is not nagged"

# --no-accept silences the warning for a bug-shaped chore.
err3="$(bash "$DEPUTY" add "remove the broken-link checker script" --no-accept 2>&1 >/dev/null)"
assert_eq "$(printf '%s' "$err3" | grep -c 'acceptance')" "0" "--no-accept suppresses the notice"

# config accept_grill=0 disables it repo-wide.
printf 'accept_grill=0\n' > "$DEPUTY_ROOT/.deputy/config"
err4="$(bash "$DEPUTY" add "the exporter crashes on empty input" 2>&1 >/dev/null)"
assert_eq "$(printf '%s' "$err4" | grep -c 'acceptance')" "0" "accept_grill=0 disables the notice"
rm -f "$DEPUTY_ROOT/.deputy/config"

# DEPUTY_NO_GRILL=1 does the same per-invocation.
err5="$(DEPUTY_NO_GRILL=1 bash "$DEPUTY" add "search returns wrong results for quoted terms" 2>&1 >/dev/null)"
assert_eq "$(printf '%s' "$err5" | grep -c 'acceptance')" "0" "DEPUTY_NO_GRILL=1 disables the notice"

# ── backfill an existing item (the case that matters for a live backlog) ─────
BID="$(id_of 'login redirect is broken')"
bash "$DEPUTY" accept "$BID" --observe 'curl -sf localhost:3000/logout | grep -q dashboard' >/dev/null
assert_contains "$(bash "$DEPUTY" accept "$BID")" "curl -sf localhost:3000/logout" \
  "accept --observe backfills an item added without one"

# A partial update must not blank the fields already answered.
bash "$DEPUTY" accept "$BID" --actual 'redirects to /login instead' >/dev/null
out="$(bash "$DEPUTY" accept "$BID")"
assert_contains "$out" "curl -sf localhost:3000/logout" "partial update preserves observe"
assert_contains "$out" "actual: redirects to /login instead" "partial update writes actual"

# Unanswered fields read back as the placeholder, never as a satisfied criterion.
assert_contains "$out" "expect: (unspecified)" "unanswered field is an explicit placeholder"

# ── the record must never be forgeable into extra fields ────────────────────
bash "$DEPUTY" accept "$BID" --expect "$(printf 'line one\nobserve: injected')" >/dev/null
assert_eq "$(grep -c '^observe:' "$DEPUTY_ROOT/.deputy/accept/$(bash "$DEPUTY" slug "$BID").md")" "1" \
  "a newline in a value cannot forge a second observe field"

# ── a duplicate add never overwrites a frozen criterion ─────────────────────
bash "$DEPUTY" add "FCF column is blank on the fundamentals tab" --observe 'SOMETHING ELSE' >/dev/null
assert_contains "$(bash "$DEPUTY" accept "$ID")" "observe: psql -f q/fcf.sql AAPL" \
  "re-adding an existing description does not rewrite its acceptance record"

# ── error surfaces ──────────────────────────────────────────────────────────
bash "$DEPUTY" accept 9999 >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "accept on an unknown id fails"
bash "$DEPUTY" accept >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "accept with no id is a usage error"
bash "$DEPUTY" add "another thing" --observe >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "add --observe without a value is a usage error"

CID="$(id_of 'tidy the README wording')"
bash "$DEPUTY" accept "$CID" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "accept on an item with no record reports it rather than inventing one"

# A slug argument reaches a filesystem path — a traversal component must be refused, not
# resolved, or `accept` becomes an arbitrary-file write.
bash "$DEPUTY" accept '../../escape' --observe 'x' >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "accept rejects a path-traversal slug"
assert_eq "$(test -e "$DEPUTY_ROOT/../escape.md" && echo written || echo none)" "none" \
  "no file is written outside .deputy/accept"
