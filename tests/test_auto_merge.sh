#!/usr/bin/env bash
# tests/test_auto_merge.sh — #97: the UNSANDBOXED runner auto-merges a headless worker's
# ready-merge branch when auto_merge=1 (the worker can't merge — #64 sandbox makes the repo
# read-only to it). Uses a mock orchestrator that produces a ready-merge branch, kept OUTSIDE
# the repo so it doesn't dirty the tree.
source "$(dirname "$0")/lib.sh"

# Build a fresh git repo + a mock worker (outside the repo). $1 = auto_merge value;
# $2 = "marker" to surface --ready-merge (real completion) or "nomarker" (a blocking surface).
_am_setup() {  # sets AMR (repo), AMM (mock), AMID (item id)
  AMR="$(mktemp -d)"; AMM="$(mktemp)"     # mock is OUTSIDE the repo
  mkdir -p "$AMR/.deputy"; cp "$REPO/templates/BACKLOG.md" "$AMR/BACKLOG.md"
  printf 'auto_merge=%s\nwatchdog_mins=0\n' "$1" > "$AMR/.deputy/config"
  git -C "$AMR" init -q -b master; git -C "$AMR" config user.email t@t; git -C "$AMR" config user.name t
  git -C "$AMR" add -A; git -C "$AMR" commit -q -m init
  local surface="surfaced --ready-merge"; [[ "$2" == "nomarker" ]] && surface="surfaced"
  cat > "$AMM" <<MOCK
#!/usr/bin/env bash
item="\$1"; root="$AMR"; DEP="$DEPUTY"
id=\$(printf '%s' "\$item" | grep -oE '#[0-9]+' | head -1 | tr -d '#'); slug="autotest-\$id"
git -C "\$root" worktree add -q "\$root/.deputy/wt" -b "deputy/\$slug" 2>/dev/null
echo "feat \$id" > "\$root/.deputy/wt/feature-\$id.txt"
git -C "\$root/.deputy/wt" add -A; git -C "\$root/.deputy/wt" commit -q -m "feat \$id"
mkdir -p "\$root/.deputy/waypoints/\$slug"; printf '{"steps":[{"status":"succeeded"}]}' > "\$root/.deputy/waypoints/\$slug/waypoint.json"
DEPUTY_ROOT="\$root" bash "\$DEP" set "\$item" $surface >/dev/null 2>&1
DEPUTY_ROOT="\$root" bash "\$DEP" wt-remove >/dev/null 2>&1
MOCK
  chmod +x "$AMM"
  DEPUTY_NO_AUTORUN=1 DEPUTY_ROOT="$AMR" bash "$DEPUTY" add "autotest feature" --p0 >/dev/null
  AMID="$(DEPUTY_ROOT="$AMR" bash "$DEPUTY" list | grep -F 'autotest feature' | grep -oE '#[0-9]+' | tr -d '#' | head -1)"
}
_am_run() { DEPUTY_ORCHESTRATOR_CMD="$AMM" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true DEPUTY_ALLOW_ANY_BRANCH=1 DEPUTY_ROOT="$AMR" timeout 40 bash "$DEPUTY" run --once >/dev/null 2>&1; }

# A) auto_merge=1 + ready-merge → runner merges to master, item done, branch's change lands
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
