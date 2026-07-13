#!/usr/bin/env bash
# tests/test_auto_merge.sh — #97/#98: the UNSANDBOXED runner auto-merges a headless worker's
# ready-merge branch when auto_merge=1 (the worker can't merge — #64 sandbox makes the repo
# read-only to it). Uses a mock orchestrator that produces a ready-merge branch, kept OUTSIDE
# the repo so it doesn't dirty the tree.
#
# The branch the runner merges is recorded in the ready-merge marker. #98 hardens HOW:
#   - the worker passes --branch=deputy/<slug> explicitly, so recording no longer depends on
#     .deputy/wt still being live at surface time (a RESUMED run may never re-create it);
#   - if no branch was recorded (old marker / non-compliant worker), the runner recovers ONLY
#     from a UNIQUE deputy/*-<id> branch, and refuses when it is ambiguous.
source "$(dirname "$0")/lib.sh"

# $1 = auto_merge value; $2 = "marker" (surface --ready-merge) or "nomarker" (blocking surface);
# $3 = mode: live (wt present at surface, --branch passed) | branch (wt REMOVED before surface,
#      --branch passed — the resumed-run case) | nobranch (wt removed, NO --branch — fallback) |
#      ambig (wt removed, NO --branch, a SECOND deputy/*-<id> branch exists — must refuse).
_am_setup() {  # sets AMR (repo), AMM (mock), AMID (item id)
  AMR="$(mktemp -d)"; AMM="$(mktemp)"     # mock is OUTSIDE the repo
  mkdir -p "$AMR/.deputy"; cp "$REPO/templates/BACKLOG.md" "$AMR/BACKLOG.md"
  printf 'auto_merge=%s\nwatchdog_mins=0\n' "$1" > "$AMR/.deputy/config"
  git -C "$AMR" init -q -b master; git -C "$AMR" config user.email t@t; git -C "$AMR" config user.name t
  git -C "$AMR" add -A; git -C "$AMR" commit -q -m init
  local mode="${3:-live}"
  local surface="surfaced --ready-merge"; [[ "$2" == "nomarker" ]] && surface="surfaced"
  cat > "$AMM" <<MOCK
#!/usr/bin/env bash
item="\$1"; root="$AMR"; DEP="$DEPUTY"; mode="$mode"
id=\$(printf '%s' "\$item" | grep -oE '#[0-9]+' | head -1 | tr -d '#'); slug="autotest-\$id"
git -C "\$root" worktree add -q "\$root/.deputy/wt" -b "deputy/\$slug" 2>/dev/null
echo "feat \$id" > "\$root/.deputy/wt/feature-\$id.txt"
git -C "\$root/.deputy/wt" add -A; git -C "\$root/.deputy/wt" commit -q -m "feat \$id"
mkdir -p "\$root/.deputy/waypoints/\$slug"; printf '{"steps":[{"status":"succeeded"}]}' > "\$root/.deputy/waypoints/\$slug/waypoint.json"
[[ "\$mode" == ambig ]] && git -C "\$root" branch "deputy/autotest-dup-\$id" "deputy/\$slug" 2>/dev/null
if [[ "\$mode" == live ]]; then
  DEPUTY_ROOT="\$root" bash "\$DEP" set "\$item" $surface --branch="deputy/\$slug" >/dev/null 2>&1
  DEPUTY_ROOT="\$root" bash "\$DEP" wt-remove >/dev/null 2>&1
else
  # RESUMED-run simulation: the worktree is gone BEFORE the surface, so the marker can't be
  # populated from a live .deputy/wt — only from --branch (branch mode) or the runner fallback.
  DEPUTY_ROOT="\$root" bash "\$DEP" wt-remove >/dev/null 2>&1
  if [[ "\$mode" == branch ]]; then
    DEPUTY_ROOT="\$root" bash "\$DEP" set "\$item" $surface --branch="deputy/\$slug" >/dev/null 2>&1
  else  # nobranch | ambig: surface WITHOUT --branch
    DEPUTY_ROOT="\$root" bash "\$DEP" set "\$item" $surface >/dev/null 2>&1
  fi
fi
MOCK
  chmod +x "$AMM"
  DEPUTY_NO_AUTORUN=1 DEPUTY_ROOT="$AMR" bash "$DEPUTY" add "autotest feature" --p0 >/dev/null
  AMID="$(DEPUTY_ROOT="$AMR" bash "$DEPUTY" list | grep -F 'autotest feature' | grep -oE '#[0-9]+' | tr -d '#' | head -1)"
}
_am_run() { DEPUTY_ORCHESTRATOR_CMD="$AMM" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true DEPUTY_ALLOW_ANY_BRANCH=1 DEPUTY_ROOT="$AMR" timeout 40 bash "$DEPUTY" run --once >/dev/null 2>&1; }

# A) auto_merge=1 + ready-merge (wt live) → runner merges to master, item done, branch lands
_am_setup 1 marker; _am_run
assert_eq "$(git -C "$AMR" show master:feature-$AMID.txt 2>/dev/null || echo MISSING)" "feat $AMID" "auto_merge=1: worker's branch change is merged to master"
assert_contains "$(DEPUTY_ROOT="$AMR" bash "$DEPUTY" list)" "+[#$AMID]" "auto_merge=1: item marked done"
assert_eq "$(test -f "$AMR/.deputy/ready-merge-$AMID" && echo present || echo cleared)" "cleared" "auto_merge=1: ready-merge marker cleared"

# B) auto_merge=0 + ready-merge → NOT merged, stays surfaced for human
_am_setup 0 marker; _am_run
assert_eq "$(git -C "$AMR" show master:feature-$AMID.txt 2>/dev/null || echo MISSING)" "MISSING" "auto_merge=0: branch NOT merged"
assert_contains "$(DEPUTY_ROOT="$AMR" bash "$DEPUTY" list surfaced)" "autotest feature" "auto_merge=0: item stays surfaced"

# D) auto_merge=1 but a BLOCKING surface (no ready-merge marker) → NOT merged
_am_setup 1 nomarker; _am_run
assert_eq "$(git -C "$AMR" show master:feature-$AMID.txt 2>/dev/null || echo MISSING)" "MISSING" "auto_merge=1 + no marker: NOT merged (blocking surface preserved)"
assert_contains "$(DEPUTY_ROOT="$AMR" bash "$DEPUTY" list surfaced)" "autotest feature" "auto_merge=1 + no marker: item stays surfaced"

# E) #98 — RESUMED run: worktree GONE at surface, but --branch recorded it → runner merges.
#    (This is exactly the #92 bug: a rev-parse of the absent .deputy/wt recorded nothing.)
_am_setup 1 marker branch; _am_run
# The merge itself proves --branch recorded the branch: with no live .deputy/wt, the ONLY way
# the runner learns the branch is the marker the worker wrote from --branch (a rev-parse of the
# absent worktree would have recorded nothing — the #92 bug). The marker is consumed on merge.
assert_eq "$(git -C "$AMR" show master:feature-$AMID.txt 2>/dev/null || echo MISSING)" "feat $AMID" "resumed run (--branch, no live wt): still auto-merged"
assert_contains "$(DEPUTY_ROOT="$AMR" bash "$DEPUTY" list)" "+[#$AMID]" "resumed run: item marked done"

# F) #98 — marker with NO branch, but a UNIQUE deputy/*-<id> branch exists → runner recovers + merges
_am_setup 1 marker nobranch; _am_run
assert_eq "$(git -C "$AMR" show master:feature-$AMID.txt 2>/dev/null || echo MISSING)" "feat $AMID" "no-branch marker + unique branch: runner recovers and merges"
assert_contains "$(DEPUTY_ROOT="$AMR" bash "$DEPUTY" list)" "+[#$AMID]" "no-branch fallback: item marked done"

# G) #98 — marker with NO branch and TWO candidate branches → ambiguous, runner REFUSES
_am_setup 1 marker ambig; _am_run
assert_eq "$(git -C "$AMR" show master:feature-$AMID.txt 2>/dev/null || echo MISSING)" "MISSING" "ambiguous branches: NOT merged (refuses to guess)"
assert_contains "$(DEPUTY_ROOT="$AMR" bash "$DEPUTY" list surfaced)" "autotest feature" "ambiguous branches: item left surfaced for a human"
