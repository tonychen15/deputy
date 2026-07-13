#!/usr/bin/env bash
# tests/test_list_detail.sh — 'deputy list' prints a per-task DETAIL block for attention
# states (surfaced / failed / deferred / paused / cancelled): status · details · summary ·
# action. Shared with watch/pickup via _item_detail_block. Suppressed under --porcelain and
# for non-attention states.
source "$(dirname "$0")/lib.sh"
setup_repo
D() { bash "$DEPUTY" "$@"; }
_id() { D list | grep -F "$1" | grep -oE '#[0-9]+' | tr -d '#' | head -1; }
mkdir -p "$DEPUTY_ROOT/.deputy/questions" "$DEPUTY_ROOT/.deputy/fails"

# surfaced · needs-input (has a questions file, no marker)
D add "decide approach for auth" >/dev/null; ni="$(_id 'decide approach for auth')"
printf 'Should we use OAuth or SAML?\n' > "$DEPUTY_ROOT/.deputy/questions/decide-approach-$ni.md"
D set "#$ni" surfaced >/dev/null
out="$(D list surfaced)"
assert_contains "$out" "status:  needs input" "needs-input: status label"
assert_contains "$out" "details: $DEPUTY_ROOT/.deputy/questions/decide-approach-$ni.md" "needs-input: details path"
assert_contains "$out" "summary: Should we use OAuth or SAML?" "needs-input: summary (first line of questions)"
assert_contains "$out" "action:  deputy pickup #$ni" "needs-input: action is pickup"

# surfaced · ready-to-merge (has a ready-merge marker)
D add "mergeable change" >/dev/null; rm_id="$(_id 'mergeable change')"
printf 'branch ready for human merge-review\n' > "$DEPUTY_ROOT/.deputy/ready-merge-$rm_id"
D set "#$rm_id" surfaced >/dev/null
out="$(D list surfaced)"
assert_contains "$out" "status:  ready to merge" "ready-merge: status label"
assert_contains "$out" "action:  deputy pickup #$rm_id" "ready-merge: action is pickup"

# surfaced · proposed (has a proposed marker)
D add "worker suggested followup" >/dev/null; pr_id="$(_id 'worker suggested followup')"
printf 'proposed\n' > "$DEPUTY_ROOT/.deputy/proposed-$pr_id"
D set "#$pr_id" surfaced >/dev/null
assert_contains "$(D list surfaced)" "status:  proposed" "proposed: status label"

# failed (fails/<slug>.md, #70 subfolder convention)
D add "broken build task" >/dev/null; f_id="$(_id 'broken build task')"
printf 'tests failed: assertion in login_test\n' > "$DEPUTY_ROOT/.deputy/fails/broken-build-$f_id.md"
D set "#$f_id" failed >/dev/null
out="$(D list failed)"
assert_contains "$out" "details: $DEPUTY_ROOT/.deputy/fails/broken-build-$f_id.md" "failed: details path"
assert_contains "$out" "reason:  tests failed: assertion in login_test" "failed: reason (first line of fail file)"
assert_contains "$out" "action:  deputy pickup #$f_id   (requeue" "failed: action is pickup requeue"

# deferred → revive action
D add "someday maybe task" >/dev/null; d_id="$(_id 'someday maybe task')"
D set "#$d_id" deferred >/dev/null
assert_contains "$(D list deferred)" "action:  deputy pickup #$d_id   (revive" "deferred: action is pickup revive"

# non-attention (waiting) → NO detail block
D add "plain waiting task" >/dev/null; w_id="$(_id 'plain waiting task')"
w_out="$(D list waiting | grep -A1 "plain waiting task")"
assert_eq "$(printf '%s' "$w_out" | grep -c 'action:\|status:')" "0" "waiting item has no detail block"

# --porcelain suppresses the detail block entirely
por="$(D list surfaced --porcelain)"
assert_eq "$(printf '%s' "$por" | grep -c 'status:\|action:\|details:')" "0" "--porcelain suppresses the detail block"
assert_contains "$por" "surfaced|" "--porcelain still emits pipe lines for surfaced items"
