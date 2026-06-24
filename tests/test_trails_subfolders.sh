#!/usr/bin/env bash
# #70: per-item runtime trails live in .deputy/{reviews,questions,fails}/<slug>.md,
# with a one-shot migration of pre-existing flat trails and dual-read in reflect.
source "$(dirname "$0")/lib.sh"

# review-log writes to the reviews/ subfolder (not the flat .deputy/ top level)
setup_repo
printf '## t\n- x\n' | bash "$DEPUTY" review-log slug-a-7 >/dev/null 2>&1
assert_eq "$([ -f "$DEPUTY_ROOT/.deputy/reviews/slug-a-7.md" ] && echo yes || echo no)" "yes" "review-log writes reviews/<slug>.md"
assert_eq "$([ -e "$DEPUTY_ROOT/.deputy/slug-a-7.review.md" ] && echo yes || echo no)" "no"  "review-log does NOT write the flat path"

# one-shot migration: pre-existing flat trails move into subfolders on the next run
setup_repo
printf 'q\n' > "$DEPUTY_ROOT/.deputy/legacy-3.questions.md"
printf 'r\n' > "$DEPUTY_ROOT/.deputy/legacy-3.review.md"
printf 'f\n' > "$DEPUTY_ROOT/.deputy/legacy-3.fail.md"
bash "$DEPUTY" status >/dev/null 2>&1     # any invocation triggers _migrate_trails
assert_eq "$(ls "$DEPUTY_ROOT"/.deputy/*.questions.md "$DEPUTY_ROOT"/.deputy/*.review.md "$DEPUTY_ROOT"/.deputy/*.fail.md 2>/dev/null | wc -l | tr -d ' ')" "0" "migration: no flat trails remain"
assert_eq "$([ -f "$DEPUTY_ROOT/.deputy/questions/legacy-3.md" ] && echo yes || echo no)" "yes" "migration: questions moved to subfolder"
assert_eq "$([ -f "$DEPUTY_ROOT/.deputy/reviews/legacy-3.md" ] && echo yes || echo no)"   "yes" "migration: review moved to subfolder"
assert_eq "$([ -f "$DEPUTY_ROOT/.deputy/fails/legacy-3.md" ] && echo yes || echo no)"     "yes" "migration: fail moved to subfolder"

# reflect reads questions from the subfolder (dual-read)
assert_contains "$(bash "$DEPUTY" reflect 2>&1)" "legacy-3.md" "reflect lists migrated questions trail"

# #70 collision: a stale flat write landing over an already-migrated subfolder trail —
# the newer content wins and the flat file is swept (no duplicate left for reflect).
setup_repo
mkdir -p "$DEPUTY_ROOT/.deputy/questions"
printf 'OLD\n' > "$DEPUTY_ROOT/.deputy/questions/coll-5.md"; sleep 1
printf 'NEW\n' > "$DEPUTY_ROOT/.deputy/coll-5.questions.md"     # newer flat (stale SKILL-style write)
bash "$DEPUTY" status >/dev/null 2>&1
assert_eq "$(ls "$DEPUTY_ROOT"/.deputy/*.questions.md 2>/dev/null | wc -l | tr -d ' ')" "0" "collision: flat file swept (no leftover)"
assert_eq "$(cat "$DEPUTY_ROOT/.deputy/questions/coll-5.md")" "NEW" "collision: newer flat content wins"
