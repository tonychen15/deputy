#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

# ── helpers ──────────────────────────────────────────────────────────────────

reflect() { DEPUTY_NO_PATH_FIX=1 bash "$DEPUTY" reflect "$@"; }

# ── empty backlog ─────────────────────────────────────────────────────────────

setup_repo
out="$(reflect)"
assert_contains "$out" "=== Deputy Reflect ===" "empty: header present"
assert_contains "$out" "no done items" "empty: no done items"
assert_contains "$out" "no waiting items" "empty: no waiting items"
assert_contains "$out" "none" "empty: no surfaced items"
assert_contains "$out" "no candidates" "empty: no duplicates"

# ── learnings section — done items listed ─────────────────────────────────────

setup_repo
bash "$DEPUTY" add "fix the login bug" --p1
line="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" set "$line" done

out="$(reflect)"
assert_contains "$out" "fix the login bug" "learnings: done item appears"
assert_contains "$out" "Learnings (1 done)" "learnings: count shown"

# ── re-triage — untagged waiting items flagged ────────────────────────────────

setup_repo
bash "$DEPUTY" add "an untagged task"
bash "$DEPUTY" add "a tagged task" --p2

out="$(reflect)"
assert_contains "$out" "an untagged task" "retriage: untagged item appears in re-triage section"
assert_contains "$out" "a tagged task" "reprioritize: tagged item in waiting list"

# ── surfaced items listed ─────────────────────────────────────────────────────

setup_repo
bash "$DEPUTY" add "needs human input" --p1
line="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" set "$line" surfaced

out="$(reflect)"
assert_contains "$out" "needs human input" "surfaced: item appears in surfaced section"

# ── duplicate detection — pair with ≥3 shared words flagged ──────────────────

setup_repo
bash "$DEPUTY" add "support parallel execution via multiple git worktrees"
bash "$DEPUTY" add "implement parallel execution via multiple worktrees"

out="$(reflect)"
assert_contains "$out" "CANDIDATE" "duplicates: pair with 4 shared words flagged"

# ── no false positive — clearly different items not flagged ──────────────────

setup_repo
bash "$DEPUTY" add "fix login bug on mobile"
bash "$DEPUTY" add "add email notifications to onboarding flow"

out="$(reflect)"
assert_contains "$out" "no candidates detected" "duplicates: no false positive for different items"

# ── --apply writes learnings.md ───────────────────────────────────────────────

setup_repo
bash "$DEPUTY" add "ship the dashboard" --p0
line="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" set "$line" done

reflect --apply >/dev/null
assert_eq "$(test -f "$DEPUTY_ROOT/.deputy/learnings.md" && echo yes || echo no)" "yes" \
  "--apply: learnings.md written"
assert_contains "$(cat "$DEPUTY_ROOT/.deputy/learnings.md")" "ship the dashboard" \
  "--apply: done item in learnings.md"

# ── no --apply means no learnings.md written ─────────────────────────────────

setup_repo
bash "$DEPUTY" add "another item" --p1
line="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" set "$line" done

reflect >/dev/null
assert_eq "$(test -f "$DEPUTY_ROOT/.deputy/learnings.md" && echo yes || echo no)" "no" \
  "no --apply: learnings.md not written"

# ── --apply is idempotent (overwrite, not append) ─────────────────────────────

setup_repo
bash "$DEPUTY" add "item one" --p1
line="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" set "$line" done

reflect --apply >/dev/null
count1="$(grep -c 'item one' "$DEPUTY_ROOT/.deputy/learnings.md")"
reflect --apply >/dev/null
count2="$(grep -c 'item one' "$DEPUTY_ROOT/.deputy/learnings.md")"
assert_eq "$count1" "$count2" "--apply idempotent: item appears same number of times after second run"
