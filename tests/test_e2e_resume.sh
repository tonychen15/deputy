#!/usr/bin/env bash
# tests/test_e2e_resume.sh — E2E test for interrupt-mid-step → recover → resume.
#
# Scenario:
#   Run 1 (interrupted): orchestrator drives the spine for step 1, commits it,
#     activates step 2 — then "crashes" (exits) WITHOUT committing step 2 or
#     calling `deputy done`. The item remains @running in BACKLOG, but cmd_run
#     removes the claim file after the orchestrator returns (normal cleanup).
#
#   Recovery: the next `deputy run` calls `cmd_recover` first. It sees the
#     @running item with NO live claim → orphan-reverts it to waiting.
#
#   Run 2 (resumes): orchestrator detects the existing waypoint, calls
#     `deputy resume` (must return step 2), skips step 1 (already committed),
#     sets step 2, makes a change, commits, then calls `deputy done` + marks done.
#
# Key assertion: step-1 commit SHA is unchanged between Run 1 and Run 2
#   (resume did NOT redo step 1 — this distinguishes resume from restart).
set -uo pipefail

source "$(dirname "$0")/lib.sh"
setup_repo

# ── Set up a standalone git repo as the worktree ─────────────────────────────
WT="$(mktemp -d)"
export DEPUTY_WT="$WT"
git -C "$WT" init -q
git -C "$WT" config user.email test@deputy
git -C "$WT" config user.name deputy-test
printf 'seed\n' > "$WT/seed"
git -C "$WT" add -A
git -C "$WT" commit -qm seed

# ── Add the backlog item ──────────────────────────────────────────────────────
bash "$DEPUTY" add "two step e2e task" --p0

# Trigger ID allocation and pick the canonical running line
bash "$DEPUTY" list > /dev/null
ITEM_LINE="$(bash "$DEPUTY" pick)"

# Derive the waypoint slug from the allocated ID + description.
# _wp_slug in deputy.sh: "<id>-<desc with non-alnum→dash, collapsed>", max 64 chars.
ITEM_PARSED="$(bash "$DEPUTY" _parse "$(bash "$DEPUTY" pick)")"
ITEM_ID="${ITEM_PARSED#*|}"; ITEM_ID="${ITEM_ID#*|}"; ITEM_ID="${ITEM_ID%%|*}"
ITEM_DESC="two step e2e task"
# Replicate _wp_slug: replace non-alnum with dash, collapse, trim
_SLUG_RAW="${ITEM_ID}-${ITEM_DESC}"
SLUG="$(printf '%s' "$_SLUG_RAW" | tr -cs 'a-zA-Z0-9' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')"
SLUG="${SLUG:0:64}"

# ── Mock orchestrator 1: simulates §2c that gets interrupted mid-step 2 ──────
# Drives: start → plan 2 steps → set-step 1 → commit step 1 → set-step 2
# Then exits WITHOUT committing step 2 and WITHOUT calling deputy done/set done.
# This is a realistic crash: the orchestrator dies after partially starting step 2.
ORCH1="$(mktemp)"
cat > "$ORCH1" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ITEM_LINE="\$1"
# Always suppress auto-run so add doesn't trigger another run cycle
export DEPUTY_NO_AUTORUN=1
export DEPUTY_WT="$WT"
export DEPUTY_ROOT="$DEPUTY_ROOT"

SLUG="$SLUG"
DEPUTY="$DEPUTY"

# Start the checkpoint spine
bash "\$DEPUTY" start "\$SLUG" "goal: two step e2e task"

# Plan two steps
bash "\$DEPUTY" plan "\$SLUG" --step 1 --purpose "write file alpha"
bash "\$DEPUTY" plan "\$SLUG" --step 2 --purpose "write file beta"

# Execute step 1
bash "\$DEPUTY" set-step "\$SLUG" --step 1
printf 'alpha content\n' > "$WT/alpha"
bash "\$DEPUTY" commit "\$SLUG" --summary "step 1: wrote alpha"

# Activate step 2 but DON'T commit and DON'T call done — simulate crash
bash "\$DEPUTY" set-step "\$SLUG" --step 2
printf 'partial beta\n' > "$WT/beta"
# <crash here> — exit WITHOUT committing step 2
exit 0
EOF
chmod +x "$ORCH1"

# ── Run 1: orchestrator runs, "crashes" mid-step-2 ───────────────────────────
DEPUTY_ORCHESTRATOR_CMD="$ORCH1" DEPUTY_AVAIL="claude,gemini" DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run --once 2>&1

# After Run 1: item should be @running (orchestrator never called done),
# claim file should be GONE (cmd_run removes it after orchestrator exits).
ITEM_RUNNING_LINE="$(grep '^@' "$DEPUTY_ROOT/BACKLOG.md" | head -1 || true)"
assert_contains "$ITEM_RUNNING_LINE" "two step e2e task" "run1: item left @running after orchestrator crash"
claim_count="$(ls "$DEPUTY_ROOT/.deputy/"*.claim 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$claim_count" "0" "run1: no claim file left (cmd_run cleaned it up)"

# Step 1 must be succeeded; step 2 still in_progress (partial work)
STEP1_STATUS="$(jq -r '.steps[] | select(.id=="1") | .status' "$DEPUTY_ROOT/.deputy/waypoints/$SLUG/waypoint.json")"
assert_eq "$STEP1_STATUS" "succeeded" "run1: step 1 succeeded in waypoint"
STEP2_STATUS="$(jq -r '.steps[] | select(.id=="2") | .status' "$DEPUTY_ROOT/.deputy/waypoints/$SLUG/waypoint.json")"
assert_eq "$STEP2_STATUS" "in_progress" "run1: step 2 left in_progress (crash before commit)"

# Capture step-1 commit SHA — we'll verify it's unchanged after Run 2
STEP1_SHA="$(jq -r '.steps[] | select(.id=="1") | .actual_result.artifacts[0].step_commit' \
  "$DEPUTY_ROOT/.deputy/waypoints/$SLUG/waypoint.json")"

# ── Mock orchestrator 2: simulates §2c recovery/resume logic ─────────────────
# Detects the existing waypoint, calls `deputy resume` to find the first
# uncommitted step, then continues from there (step 2 only).
ORCH2="$(mktemp)"
cat > "$ORCH2" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ITEM_LINE="\$1"
export DEPUTY_NO_AUTORUN=1
export DEPUTY_WT="$WT"
export DEPUTY_ROOT="$DEPUTY_ROOT"

SLUG="$SLUG"
DEPUTY="$DEPUTY"

# Purge any dirty worktree state left by the interrupted run
git -C "$WT" reset --hard >/dev/null 2>&1 || true
git -C "$WT" clean -fd >/dev/null 2>&1 || true

# Ask the spine where to resume — MUST report step 2 (not step 1)
RESUME_OUTPUT="\$(bash "\$DEPUTY" resume "\$SLUG")"
printf '%s\n' "RESUME_OUTPUT=\$RESUME_OUTPUT" >&2

# Validate: resume must say step 2
RESUME_STEP="\${RESUME_OUTPUT%%|*}"
if [[ "\$RESUME_STEP" != "2" ]]; then
  printf 'ERROR: expected resume step=2, got: %s\n' "\$RESUME_STEP" >&2
  exit 1
fi

# Continue from step 2 (do NOT redo step 1)
bash "\$DEPUTY" set-step "\$SLUG" --step "\$RESUME_STEP"
printf 'beta content\n' > "$WT/beta"
bash "\$DEPUTY" commit "\$SLUG" --summary "step 2: wrote beta"

# Mark the spine done, then mark the backlog item done
bash "\$DEPUTY" done "\$SLUG"
bash "\$DEPUTY" set "\$ITEM_LINE" done
EOF
chmod +x "$ORCH2"

# ── Recovery + Run 2 ──────────────────────────────────────────────────────────
# cmd_run calls cmd_recover internally; it will see the orphaned @running item
# (no live claim) and revert it to waiting before picking it up again.
DEPUTY_ORCHESTRATOR_CMD="$ORCH2" DEPUTY_AVAIL="claude,gemini" DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run --once 2>&1

# ── Assertions ───────────────────────────────────────────────────────────────

# 1. Item is now done in BACKLOG
LIST_OUT="$(bash "$DEPUTY" list)"
assert_contains "$LIST_OUT" "+[#"                 "item reached done state"
assert_contains "$LIST_OUT" "two step e2e task"   "done item description preserved"

# 2. Waypoint shows task completed with both steps succeeded
WP_JSON="$DEPUTY_ROOT/.deputy/waypoints/$SLUG/waypoint.json"
WP_STATUS="$(jq -r '.status' "$WP_JSON")"
assert_eq "$WP_STATUS" "completed" "waypoint task status is completed"

SUCCEEDED_COUNT="$(jq -r '[.steps[] | select(.status=="succeeded")] | length' "$WP_JSON")"
assert_eq "$SUCCEEDED_COUNT" "2" "both steps are marked succeeded"

# 3. Step 1 commit SHA is UNCHANGED (resume did NOT redo step 1)
STEP1_SHA_AFTER="$(jq -r '.steps[] | select(.id=="1") | .actual_result.artifacts[0].step_commit' "$WP_JSON")"
assert_eq "$STEP1_SHA_AFTER" "$STEP1_SHA" "step 1 commit SHA unchanged — resume did not redo step 1"

# 4. resume returned step 2 as the resume point (verified inside ORCH2; confirm step 2 now succeeded)
STEP2_STATUS_FINAL="$(jq -r '.steps[] | select(.id=="2") | .status' "$WP_JSON")"
assert_eq "$STEP2_STATUS_FINAL" "succeeded" "step 2 completed in run 2"

# 5. No live claim remains
CLAIM_COUNT_FINAL="$(ls "$DEPUTY_ROOT/.deputy/"*.claim 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$CLAIM_COUNT_FINAL" "0" "no claim file remains after run 2"

# ── Cleanup ───────────────────────────────────────────────────────────────────
rm -f "$ORCH1" "$ORCH2"
rm -rf "$WT"
