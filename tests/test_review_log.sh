#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
F="$DEPUTY_ROOT/.deputy/reviews/fix-thing.md"   # #70: trails live in subfolders

# missing slug -> usage error
bash "$DEPUTY" review-log </dev/null >/dev/null 2>&1
assert_eq "$?" "2" "review-log requires a slug"

# slug with a slash -> rejected (must stay a single .deputy component)
printf 'x\n' | bash "$DEPUTY" review-log "nested/evil" >/dev/null 2>&1
assert_eq "$?" "2" "review-log rejects slug with slash"

# first append creates the file with a header
printf '## plan — iteration 1\n- Verdict: APPROVED\n' | bash "$DEPUTY" review-log fix-thing
assert_eq "$?" "0" "review-log first append ok" 2>/dev/null || true
assert_eq "$([[ -f "$F" ]] && echo yes)" "yes" "review trail file created"
assert_contains "$(cat "$F")" "# xReview trail — fix-thing" "trail has self-describing header"
assert_contains "$(cat "$F")" "## plan — iteration 1" "trail has first record"

# second append is ADDITIVE (append-only, does not overwrite)
printf '## impl step 1 — iteration 1\n- Verdict: NEEDS_CHANGES\n' | bash "$DEPUTY" review-log fix-thing
body="$(cat "$F")"
assert_contains "$body" "## plan — iteration 1" "first record still present after second append"
assert_contains "$body" "## impl step 1 — iteration 1" "second record appended"
# header appears exactly once (not re-seeded on append)
assert_eq "$(grep -c '# xReview trail' "$F")" "1" "header written only once"
