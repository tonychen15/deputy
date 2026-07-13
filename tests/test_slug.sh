#!/usr/bin/env bash
# tests/test_slug.sh — #99: deterministic, idempotent per-task slug/branch.
# The slug is FROZEN at add time from the IMMUTABLE user description, so every resume/rerun
# of a task resolves to the SAME slug (→ branch deputy/<slug> → worktree). A later change to
# the display/refined description must NOT move it. Legacy items (no meta) backfill + freeze.
source "$(dirname "$0")/lib.sh"
setup_repo
D() { bash "$DEPUTY" "$@"; }

# add a task and capture its id
out="$(D add "fix the login bug")"
id="$(printf '%s' "$out" | grep -oE '#[0-9]+' | tr -d '#' | head -1)"

s1="$(D slug "$id")"
s2="$(D slug "$id")"
assert_eq "$s1" "$s2" "slug is deterministic across calls"
assert_eq "$s1" "$(D slug "#$id")" "slug accepts the #<id> form identically"

# format: <id>-<8 hex>-<descslug>
assert_eq "$(printf '%s' "$s1" | grep -cE "^${id}-[0-9a-f]{8}-fix-the-login-bug$")" "1" "slug format is <id>-<hash8>-<descslug>"

# meta persisted the immutable user_desc + the frozen slug
meta="$(cat "$DEPUTY_ROOT/.deputy/meta/$id.meta" 2>/dev/null || true)"
assert_contains "$meta" "user_desc: fix the login bug" "meta stores the immutable user_desc"
assert_contains "$meta" "slug: $s1" "meta stores the frozen slug"

# THE KEY PROPERTY: refine (edit) the display description — the frozen slug must not move.
# (Simulate a grilling-time refinement by rewriting the BACKLOG line directly.)
sed -i 's/fix the login bug/fix the SSO login redirect flow/' "$DEPUTY_ROOT/BACKLOG.md"
assert_eq "$(D slug "$id")" "$s1" "slug is STABLE after the description is refined (branch never moves)"

# uniqueness: a different description yields a different slug
out2="$(D add "improve the search ranking")"
id2="$(printf '%s' "$out2" | grep -oE '#[0-9]+' | tr -d '#' | head -1)"
s_other="$(D slug "$id2")"
assert_eq "$([[ "$s_other" != "$s1" ]] && echo differ || echo same)" "differ" "different tasks get different slugs"

# legacy backfill: an item present in BACKLOG but with NO meta (added before #99) freezes on
# first slug call from its current description and stays stable thereafter. Simulate by adding
# normally then removing the meta the runner would not have written pre-#99.
out3="$(D add "legacy style item without meta")"
id3="$(printf '%s' "$out3" | grep -oE '#[0-9]+' | tr -d '#' | head -1)"
s3="$(D slug "$id3")"                                   # meta present here
rm -f "$DEPUTY_ROOT/.deputy/meta/$id3.meta"             # now it looks like a pre-#99 item
sl1="$(D slug "$id3")"                                  # must backfill from the BACKLOG desc
assert_eq "$sl1" "$s3" "legacy backfill reproduces the same slug (deterministic from desc)"
assert_eq "$(test -f "$DEPUTY_ROOT/.deputy/meta/$id3.meta" && echo yes || echo no)" "yes" "legacy backfill re-writes+freezes meta"
assert_eq "$(D slug "$id3")" "$sl1" "legacy slug is stable after backfill"

# orphan-meta hygiene: an add interrupted between meta-rename and append leaves a stale meta
# for an id a later add reuses. That mismatching orphan must be OVERWRITTEN by the real add,
# never inherited (which would give the new task the wrong frozen slug).
setup_repo   # fresh repo → first add gets id 1
mkdir -p "$DEPUTY_ROOT/.deputy/meta"
printf 'user_desc: stale orphan task\nslug: 1-deadbeef-stale-orphan-task\ncreated-at: x\n' > "$DEPUTY_ROOT/.deputy/meta/1.meta"
o="$(D add "the real first task")"
oid="$(printf '%s' "$o" | grep -oE '#[0-9]+' | tr -d '#' | head -1)"
assert_eq "$oid" "1" "fresh add reuses id 1 (over the orphan)"
assert_contains "$(D slug 1)" "the-real-first-task" "stale orphan meta is overwritten by the real add"
assert_eq "$(D slug 1)" "$(D slug 1)" "post-overwrite slug is stable"

# validation
D slug abc >/dev/null 2>&1; assert_eq "$?" "2" "non-numeric id is rejected (rc 2)"
D slug 999999 >/dev/null 2>&1; assert_eq "$?" "1" "unknown id with no BACKLOG line is rejected (rc 1)"
