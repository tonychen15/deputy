#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

# ── --due flag ───────────────────────────────────────────────────────────────
bash "$DEPUTY" add "Fix login" --due 2026-07-01
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "waiting||Fix login :due:2026-07-01" "--due appended to description"

# --due must be YYYY-MM-DD
bash "$DEPUTY" add "Bad due" --due 07/01/2026 2>/dev/null; rc=$?
assert_eq "$rc" "2" "--due rejects non-ISO date"
bash "$DEPUTY" add "Bad due" --due 2026-7-1 2>/dev/null; rc=$?
assert_eq "$rc" "2" "--due rejects partial-format date"
assert_eq "$(bash "$DEPUTY" list | grep -c 'Bad due')" "0" "invalid --due not written"

# ── --project flag ───────────────────────────────────────────────────────────
bash "$DEPUTY" add "Setup CI" --project infra
assert_contains "$(bash "$DEPUTY" list)" "waiting||Setup CI :project:infra" "--project appended"

# --project with dots and underscores is allowed
bash "$DEPUTY" add "Deploy DB" --project infra.prod_v2
assert_contains "$(bash "$DEPUTY" list)" "waiting||Deploy DB :project:infra.prod_v2" "--project allows dots/underscores"

# --project with spaces is rejected
bash "$DEPUTY" add "Space proj" --project "my project" 2>/dev/null; rc=$?
assert_eq "$rc" "2" "--project rejects value with spaces"

# ── --goal flag ──────────────────────────────────────────────────────────────
bash "$DEPUTY" add "Write docs" --goal launch-v2
assert_contains "$(bash "$DEPUTY" list)" "waiting||Write docs :goal:launch-v2" "--goal appended"

# ── --depends-on flag (repeatable) ──────────────────────────────────────────
bash "$DEPUTY" add "Deploy prod" --depends-on fix-login --depends-on setup-ci
out="$(bash "$DEPUTY" list | grep 'Deploy prod')"
assert_contains "$out" ":depends-on:fix-login" "first --depends-on appended"
assert_contains "$out" ":depends-on:setup-ci"  "second --depends-on appended"

# --depends-on with spaces is rejected
bash "$DEPUTY" add "Bad dep" --depends-on "has spaces" 2>/dev/null; rc=$?
assert_eq "$rc" "2" "--depends-on rejects value with spaces"

# ── Combined flags ───────────────────────────────────────────────────────────
bash "$DEPUTY" add "Big task" --p1 --due 2026-12-31 --project backend --goal v3
out="$(bash "$DEPUTY" list | grep 'Big task')"
assert_contains "$out" "waiting|P1|Big task"           "combined flags: priority preserved"
assert_contains "$out" ":due:2026-12-31"               "combined flags: due preserved"
assert_contains "$out" ":project:backend"              "combined flags: project preserved"
assert_contains "$out" ":goal:v3"                      "combined flags: goal preserved"

# ── Dedup: same bare description, different attributes ───────────────────────
bash "$DEPUTY" add "Fix login" --due 2026-08-01 --project backend
n="$(bash "$DEPUTY" list | grep -c 'Fix login')"
assert_eq "$n" "1" "dedup strips attrs: same bare desc not added twice"

# ── Slug generation strips attributes ────────────────────────────────────────
slug="$(bash "$DEPUTY" slug "Fix login bug :due:2026-07-01 :project:auth")"
assert_eq "$slug" "fix-login-bug" "slug strips attribute tokens"

slug2="$(bash "$DEPUTY" slug "Fix login bug")"
assert_eq "$slug2" "fix-login-bug" "slug without attrs unchanged"

# ── Glob-safety: brackets in description don't expand ───────────────────────
slug3="$(bash "$DEPUTY" slug "Fix [P0] duplicate :due:2026-07-01")"
assert_eq "$slug3" "fix-p0-duplicate" "slug handles brackets without glob expansion"

# ── Round-trip: attributes survive state transitions ─────────────────────────
setup_repo
bash "$DEPUTY" add "Roundtrip task" --due 2026-09-15 --project alpha
raw_line="$(grep 'Roundtrip task' "$DEPUTY_ROOT/BACKLOG.md")"
assert_contains "$raw_line" ":due:2026-09-15"  "round-trip: due persisted in BACKLOG.md"
assert_contains "$raw_line" ":project:alpha"   "round-trip: project persisted in BACKLOG.md"

# Transition to running state preserves attributes
bash "$DEPUTY" set "$raw_line" running
running_line="$(grep 'Roundtrip task' "$DEPUTY_ROOT/BACKLOG.md")"
assert_contains "$running_line" "@"             "round-trip: running prefix set"
assert_contains "$running_line" ":due:2026-09-15"  "round-trip: due survives running transition"
assert_contains "$running_line" ":project:alpha"   "round-trip: project survives running transition"

# Transition to done preserves attributes
bash "$DEPUTY" set "$running_line" done
done_line="$(grep 'Roundtrip task' "$DEPUTY_ROOT/BACKLOG.md")"
assert_contains "$done_line" "#"               "round-trip: done prefix set"
assert_contains "$done_line" ":due:2026-09-15"  "round-trip: due survives done transition"

# ── list output format unchanged (3 pipe-separated fields) ───────────────────
setup_repo
bash "$DEPUTY" add "Simple task"
bash "$DEPUTY" add "Tagged task" --project web
out="$(bash "$DEPUTY" list)"
# Each line must have exactly 2 pipes (3 fields)
while IFS= read -r ln; do
  [[ -z "$ln" ]] && continue
  count="$(printf '%s' "$ln" | tr -cd '|' | wc -c)"
  assert_eq "$count" "2" "list output has exactly 3 pipe-separated fields"
done <<< "$out"
