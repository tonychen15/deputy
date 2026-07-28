#!/usr/bin/env bash
# tests/test_verify.sh — #113(B/C/D/E/F): prove the SYMPTOM moved, not just that code landed.
#
# The failure this exists to stop: an item goes done with steps committed, tests green and the
# branch merged, while the reported symptom is untouched — because the fixing agent wrote the
# test, after the fix, about its own diff, and the reviewer only ever read the diff.
#
#   --red    the symptom must be REAL and the check must CAPTURE it (observe fails pre-fix)
#   --green  the symptom must be GONE (observe passes post-fix)
#   --bite   the fix must be LOAD-BEARING (revert it → observe fails again). This is the gate
#            that catches a test fitted to the implementation.
#   --smoke  green unit tests are not evidence when the bug only lives against real data
#   done     refuses to close an item whose criterion was never proven
source "$(dirname "$0")/lib.sh"

command -v jq >/dev/null 2>&1 || { printf 'jq missing — skipping\n'; exit 0; }

# A repo whose state.txt says "broken"; the observe command passes only once it says "fixed".
vsetup() {
  TMP="$(mktemp -d)"; export DEPUTY_ROOT="$TMP"
  cp "$REPO/templates/BACKLOG.md" "$TMP/BACKLOG.md"; mkdir -p "$TMP/.deputy"
  git -C "$TMP" init -q -b master
  git -C "$TMP" config user.email t@t; git -C "$TMP" config user.name t
  printf 'broken\n' > "$TMP/state.txt"
  git -C "$TMP" add -A; git -C "$TMP" commit -q -m init
}
d() { bash "$DEPUTY" "$@"; }
id_of() { d list | grep -F "$1" | grep -oE '#[0-9]+' | head -1 | tr -d '#'; }
# Land a fix on the item's branch through the real spine (wt-create → start → plan → commit).
fix_and_commit() { # <slug> <new state.txt content>
  d wt-create "$1" >/dev/null
  d start "$1" "goal" >/dev/null
  d plan "$1" --step 1 --purpose "fix it" >/dev/null
  d set-step "$1" --step 1 >/dev/null
  printf '%s\n' "$2" > "$DEPUTY_ROOT/.deputy/wt/state.txt"
  d commit "$1" --summary "fix" >/dev/null
}

OBS='grep -q fixed state.txt'

# ── A) the happy path: red → fix → green → bite → done ──────────────────────
vsetup
d add "state is broken" --observe "$OBS" --actual 'says broken' --expect 'says fixed' --where local >/dev/null
ID="$(id_of 'state is broken')"; SLUG="$(d slug "$ID")"
d wt-create "$SLUG" >/dev/null; d start "$SLUG" "goal" >/dev/null

d verify "$SLUG" --red >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "--red passes when the symptom reproduces before the fix"
assert_contains "$(d verify "$SLUG" --status)" "red: pass" "--red verdict is recorded in the ledger"

d plan "$SLUG" --step 1 --purpose "fix it" >/dev/null
d set-step "$SLUG" --step 1 >/dev/null
printf 'fixed\n' > "$DEPUTY_ROOT/.deputy/wt/state.txt"
d commit "$SLUG" --summary "fix" >/dev/null

d verify "$SLUG" --green >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "--green passes once the symptom is gone"
d verify "$SLUG" --bite >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "--bite passes when reverting the fix brings the symptom back"
assert_contains "$(d verify "$SLUG" --status)" "bite: pass" "--bite verdict is recorded"

# The scratch worktree used by --bite is always cleaned up (the path is PID-suffixed, so
# glob for it rather than testing a fixed name that would silently never match).
assert_eq "$(ls -d "$DEPUTY_ROOT"/.deputy/verify-wt.* 2>/dev/null | wc -l)" "0" \
  "--bite removes its scratch worktree"
assert_eq "$(git -C "$DEPUTY_ROOT" worktree list | grep -c 'verify-wt')" "0" \
  "--bite deregisters its scratch worktree from git"

# On a RESUMED run the fix is already committed, so --red must SKIP rather than report the
# now-passing check as "your check is wrong" and surface a perfectly healthy item.
out="$(d verify "$SLUG" --red 2>&1)"; rc=$?
assert_eq "$rc" "0" "--red on an item with committed work exits 0"
assert_contains "$out" "SKIPPED" "--red skips itself once the pre-fix state is gone"

d done "$SLUG" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "done is allowed once green and bite both pass"
assert_eq "$(jq -r .status "$DEPUTY_ROOT/.deputy/waypoints/$SLUG/waypoint.json")" "completed" \
  "done finalizes the waypoint ledger"

# ── B) --red FAILS when the check does not capture the symptom ───────────────
# The single most valuable early stop: if observe already passes before any fix, either the
# item is stale or the check is wrong — "fixing" it would produce a green false positive.
vsetup
d add "state is broken" --observe 'true' >/dev/null
ID="$(id_of 'state is broken')"; SLUG="$(d slug "$ID")"
d wt-create "$SLUG" >/dev/null; d start "$SLUG" "goal" >/dev/null
out="$(d verify "$SLUG" --red 2>&1)"; rc=$?
assert_eq "$rc" "1" "--red fails when observe already succeeds pre-fix"
assert_contains "$out" "does not capture the reported symptom" "--red explains why it refused"

# ── C) --bite FAILS on a check that does not discriminate ───────────────────
# observe='true' passes with or without the fix: it proves nothing about this change.
fix_and_commit "$SLUG" fixed
d verify "$SLUG" --green >/dev/null 2>&1
out="$(d verify "$SLUG" --bite 2>&1)"; rc=$?
assert_eq "$rc" "1" "--bite fails when the symptom stays fixed with the fix reverted"
assert_contains "$out" "does not bite" "--bite names the real problem: the check, not the code"

# ── D) done REFUSES an unproven criterion ───────────────────────────────────
out="$(d done "$SLUG" 2>&1)"; rc=$?
assert_eq "$rc" "1" "done refuses while bite has not passed"
assert_contains "$out" "not proven fixed" "done says the symptom is unproven"
assert_contains "$out" "bite  (fix is load-bearing): fail" "done reports which gate failed"
assert_eq "$(jq -r .status "$DEPUTY_ROOT/.deputy/waypoints/$SLUG/waypoint.json")" "in_progress" \
  "a refused done leaves the ledger open"

# The waiver works, and is itself recorded — an override is never silent.
out="$(d done "$SLUG" --no-verify 2>&1)"; rc=$?
assert_eq "$rc" "0" "done --no-verify overrides the gate"
assert_contains "$out" "WAIVED" "the waiver is announced"
assert_eq "$(jq -r .verify_waived "$DEPUTY_ROOT/.deputy/waypoints/$SLUG/waypoint.json")" "true" \
  "the waiver is recorded in the ledger"

# ── E) an item with NO acceptance record is unaffected (backward compatible) ─
vsetup
d add "plain chore" >/dev/null
ID="$(id_of 'plain chore')"; SLUG="$(d slug "$ID")"
fix_and_commit "$SLUG" fixed
d done "$SLUG" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "an item with no acceptance record still closes normally"

# ── F) smoke_cmd gates done when configured ─────────────────────────────────
vsetup
printf 'smoke_cmd=grep -q fixed state.txt\n' > "$DEPUTY_ROOT/.deputy/config"
d add "plain chore" >/dev/null
ID="$(id_of 'plain chore')"; SLUG="$(d slug "$ID")"
fix_and_commit "$SLUG" fixed
out="$(d done "$SLUG" 2>&1)"; rc=$?
assert_eq "$rc" "1" "done refuses while a configured smoke_cmd has not been run"
assert_contains "$out" "smoke_cmd is configured" "done names the missing smoke run"
d verify "$SLUG" --smoke >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "--smoke passes against the fixed tree"
d done "$SLUG" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "done proceeds once smoke passes"

# A failing smoke keeps the item open even though every unit-level gate is green.
vsetup
printf 'smoke_cmd=grep -q NEVERTHERE state.txt\n' > "$DEPUTY_ROOT/.deputy/config"
d add "plain chore" >/dev/null
ID="$(id_of 'plain chore')"; SLUG="$(d slug "$ID")"
fix_and_commit "$SLUG" fixed
d verify "$SLUG" --smoke >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "--smoke fails against the real environment when the check does not hold"
d done "$SLUG" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "done refuses on a failed smoke run"

# ── G) --allow-empty is recorded and reported, never silent ─────────────────
vsetup
d add "plain chore" >/dev/null
ID="$(id_of 'plain chore')"; SLUG="$(d slug "$ID")"
fix_and_commit "$SLUG" fixed
d plan "$SLUG" --step 2 --purpose "no-op step" >/dev/null
d set-step "$SLUG" --step 2 >/dev/null
err="$(d commit "$SLUG" --summary "nothing" --allow-empty 2>&1 >/dev/null)"
assert_contains "$err" "NO file changes" "an empty step commit warns at commit time"
assert_eq "$(jq -r '[.steps[]|select(.empty==true)]|length' "$DEPUTY_ROOT/.deputy/waypoints/$SLUG/waypoint.json")" "1" \
  "the empty step is flagged in the ledger"
err="$(d done "$SLUG" 2>&1 >/dev/null)"
assert_contains "$err" "1 of 2 steps produced NO file changes" "done reports the empty steps"

# ── H) the runner's merge path: finalize the ledger, and refuse a false close ─
# Two bugs in one place. (1) _merge_ready_branch used to write ONLY BACKLOG.md, so every
# auto-merged item left waypoint.json saying "in_progress" while the queue said Done.
# (2) It closed the item on merge success alone — which is exactly how a fix that never
# touched the symptom gets recorded as done.
vsetup
d add "state is broken" --observe "$OBS" >/dev/null
ID="$(id_of 'state is broken')"; SLUG="$(d slug "$ID")"
fix_and_commit "$SLUG" fixed
d wt-remove >/dev/null 2>&1
d set "#$ID" surfaced --ready-merge --branch="deputy/$SLUG" >/dev/null
out="$(d pickup "$ID" 2>&1)"; rc=$?
assert_eq "$rc" "0" "pickup on an unverified ready-merge item still exits 0"
assert_eq "$(git -C "$DEPUTY_ROOT" show master:state.txt 2>/dev/null | head -1)" "fixed" \
  "the branch is still merged — the code was reviewed and tested"
assert_contains "$out" "SURFACED (not done)" "an unverified item is surfaced, not closed"
assert_contains "$(d list surfaced)" "state is broken" "the unverified item lands in surfaced"
assert_eq "$(cat "$DEPUTY_ROOT/.deputy/questions/$SLUG.md" 2>/dev/null | grep -c 'MERGED BUT NOT CLOSED')" "1" \
  "the human gets a note explaining what is unproven and how to resolve it"

# Same item, once the criterion is actually proven: it closes, and BOTH records agree.
d wt-create "$SLUG" >/dev/null
d verify "$SLUG" --green >/dev/null 2>&1
d verify "$SLUG" --bite >/dev/null 2>&1
d wt-remove >/dev/null 2>&1
d done "$SLUG" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "done succeeds once the symptom is proven fixed"
assert_eq "$(jq -r .status "$DEPUTY_ROOT/.deputy/waypoints/$SLUG/waypoint.json")" "completed" \
  "the waypoint ledger and the backlog no longer disagree"

# ── I) a verdict about code that has since changed is NOT evidence ──────────
# Without this, the gate is trivially defeated by verifying early and committing after:
# green/bite would describe a tree that no longer exists.
vsetup
d add "state is broken" --observe "$OBS" >/dev/null
ID="$(id_of 'state is broken')"; SLUG="$(d slug "$ID")"
fix_and_commit "$SLUG" fixed
d verify "$SLUG" --green >/dev/null 2>&1
d verify "$SLUG" --bite  >/dev/null 2>&1
d done "$SLUG" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "fresh verdicts close the item"

# Now land another commit on the same item and try to close it again on the old verdicts.
vsetup
d add "state is broken" --observe "$OBS" >/dev/null
ID="$(id_of 'state is broken')"; SLUG="$(d slug "$ID")"
fix_and_commit "$SLUG" fixed
d verify "$SLUG" --green >/dev/null 2>&1
d verify "$SLUG" --bite  >/dev/null 2>&1
d plan "$SLUG" --step 2 --purpose "more work" >/dev/null
d set-step "$SLUG" --step 2 >/dev/null
printf 'fixed\nand changed again\n' > "$DEPUTY_ROOT/.deputy/wt/state.txt"
d commit "$SLUG" --summary "more" >/dev/null
out="$(d done "$SLUG" 2>&1)"; rc=$?
assert_eq "$rc" "1" "done refuses when the verdicts predate the latest commit"
assert_contains "$out" "stale" "done says the verdicts are stale, not merely missing"
d verify "$SLUG" --green >/dev/null 2>&1
# Two step commits, made within the same second: --bite must revert them NEWEST-FIRST or the
# revert conflicts. Ordering by commit date here is a coin flip, so this asserts the ledger
# order is used.
bout="$(d verify "$SLUG" --bite 2>&1)"; brc=$?
assert_eq "$brc" "0" "--bite reverts multiple same-second step commits in the right order${bout:+ — $bout}"
out="$(d done "$SLUG" 2>&1)"; rc=$?
assert_eq "$rc" "0" "re-verifying against the new code closes it${out:+ — done: $out}"

# ── J) a hung check is never evidence ───────────────────────────────────────
# --red/--bite read "observe failed" as proof the symptom is present, so a check that
# merely times out must be INCONCLUSIVE — otherwise hanging is the easiest way to pass.
vsetup
printf 'verify_timeout_secs=2\n' > "$DEPUTY_ROOT/.deputy/config"
d add "state is broken" --observe 'sleep 30' >/dev/null
ID="$(id_of 'state is broken')"; SLUG="$(d slug "$ID")"
d wt-create "$SLUG" >/dev/null; d start "$SLUG" "goal" >/dev/null
out="$(d verify "$SLUG" --red 2>&1)"; rc=$?
assert_eq "$rc" "3" "a timed-out --red is inconclusive (rc 3), not a pass and not a fail"
assert_contains "$out" "INCONCLUSIVE" "a timed-out check is inconclusive, not evidence"
assert_eq "$(jq -r '.verification.red.verdict' "$DEPUTY_ROOT/.deputy/waypoints/$SLUG/waypoint.json")" \
  "inconclusive" "the timeout is recorded as inconclusive, never as pass"

# Same for a check that never ran at all — a mistyped observe command must not "prove" the bug.
vsetup
d add "state is broken" --observe 'definitely-not-a-real-command-xyz' >/dev/null
ID="$(id_of 'state is broken')"; SLUG="$(d slug "$ID")"
d wt-create "$SLUG" >/dev/null; d start "$SLUG" "goal" >/dev/null
out="$(d verify "$SLUG" --red 2>&1)"; rc=$?
assert_eq "$rc" "3" "an unrunnable --red check is inconclusive (rc 3)"
assert_contains "$out" "not found" "an unrunnable check says so instead of counting as evidence"

# ── K) --match: a DIFFERENT failure is not the reported failure ─────────────
# The stock-pick shape: a blank column becomes a thrown exception. Both are nonzero exits,
# so without --match the second still scores as "the symptom reproduces".
vsetup
printf 'blank\n' > "$DEPUTY_ROOT/state.txt"; git -C "$DEPUTY_ROOT" commit -qam blank
d add "state is broken" --observe 'grep -q fixed state.txt || { grep -q blank state.txt && echo "COLUMN BLANK"; exit 1; }' \
  --match 'COLUMN BLANK' >/dev/null
ID="$(id_of 'state is broken')"; SLUG="$(d slug "$ID")"
d wt-create "$SLUG" >/dev/null; d start "$SLUG" "goal" >/dev/null
d verify "$SLUG" --red >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "--red passes when the failure matches the reported one"

# Now the observed failure changes shape: still nonzero, but no longer the reported symptom.
vsetup
printf 'CatalogException\n' > "$DEPUTY_ROOT/state.txt"; git -C "$DEPUTY_ROOT" commit -qam boom
d add "state is broken" --observe 'grep -q fixed state.txt || { grep -q blank state.txt && echo "COLUMN BLANK"; exit 1; }' \
  --match 'COLUMN BLANK' >/dev/null
ID="$(id_of 'state is broken')"; SLUG="$(d slug "$ID")"
d wt-create "$SLUG" >/dev/null; d start "$SLUG" "goal" >/dev/null
out="$(d verify "$SLUG" --red 2>&1)"; rc=$?
assert_eq "$rc" "1" "--red fails when the command fails a DIFFERENT way than reported"
assert_contains "$out" "NOT in the reported way" "--red names the mismatch explicitly"
assert_eq "$(jq -r '.verification.red.verdict' "$DEPUTY_ROOT/.deputy/waypoints/$SLUG/waypoint.json")" \
  "fail" "a mismatched failure is recorded as fail, not pass"

# --match is optional: without it, behaviour is exactly as before.
vsetup
d add "state is broken" --observe "$OBS" >/dev/null
ID="$(id_of 'state is broken')"; SLUG="$(d slug "$ID")"
d wt-create "$SLUG" >/dev/null; d start "$SLUG" "goal" >/dev/null
d verify "$SLUG" --red >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "a record with no --match gates on the exit code alone, as before"

# ── L) usage / preconditions ────────────────────────────────────────────────
vsetup
d add "plain chore" >/dev/null
ID="$(id_of 'plain chore')"; SLUG="$(d slug "$ID")"
d wt-create "$SLUG" >/dev/null; d start "$SLUG" "goal" >/dev/null
d verify "$SLUG" --red >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "verify without an acceptance record cannot run (rc 2, not a false pass)"
d verify "$SLUG" --smoke >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "verify --smoke without smoke_cmd cannot run"
d verify "$SLUG" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "verify without a phase is a usage error"
d verify "$SLUG" --bogus >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "verify rejects an unknown phase"
