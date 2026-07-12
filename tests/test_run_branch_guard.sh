#!/usr/bin/env bash
# tests/test_run_branch_guard.sh
# Verifies that `deputy run` refuses to run when the repo is NOT on its
# default branch, and runs normally when it is (or when the escape hatch is set).
set -uo pipefail

source "$(dirname "$0")/lib.sh"

# ── Helper: create a scratch git repo with a BACKLOG.md and a waiting item ──
# Sets DEPUTY_ROOT to the scratch dir.
setup_git_repo() {
  local dir
  dir="$(mktemp -d)"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@deputy
  git -C "$dir" config user.name deputy-test
  cp "$REPO/templates/BACKLOG.md" "$dir/BACKLOG.md"
  git -C "$dir" add BACKLOG.md
  git -C "$dir" commit -qm "seed"
  mkdir -p "$dir/.deputy"
  export DEPUTY_ROOT="$dir"
}

# ── Mock orchestrator: marks the item done ──────────────────────────────────
ORCH="$(mktemp)"
cat > "$ORCH" <<EOF
#!/usr/bin/env bash
bash "$DEPUTY" set "\$1" done >/dev/null 2>&1 || true
EOF
chmod +x "$ORCH"

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: feature branch → refused + non-zero exit + no claim file created
# ─────────────────────────────────────────────────────────────────────────────
setup_git_repo
REPO_A="$DEPUTY_ROOT"
bash "$DEPUTY" add "feature branch item" --p0

# Create and switch to a feature branch
git -C "$REPO_A" checkout -qb feature/my-work

err_out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude,gemini" \
  bash "$DEPUTY" run --once 2>&1)"; rc=$?

assert_eq "$rc" "1" "feature branch: deputy run exits non-zero"
assert_contains "$err_out" "refusing to run" \
  "feature branch: refusal message printed"
assert_contains "$err_out" "feature/my-work" \
  "feature branch: current branch name in message"
# Item must still be waiting (no work done)
assert_contains "$(bash "$DEPUTY" list)" "[P0]" \
  "feature branch: item stays waiting (not claimed)"
# No claim file created
assert_eq "$(ls "$REPO_A/.deputy/"*.claim 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "feature branch: no claim file created"

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: default branch (master) → runs normally
# ─────────────────────────────────────────────────────────────────────────────
setup_git_repo
bash "$DEPUTY" add "default branch item" --p0

# On 'master' (the branch that git init creates) — should run
out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude,gemini" \
  DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run --once 2>&1)"; rc=$?

assert_eq "$rc" "0" "default branch: deputy run exits 0"
assert_contains "$(bash "$DEPUTY" list)" "+[#" \
  "default branch: item driven to done"

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: DEPUTY_ALLOW_ANY_BRANCH=1 on a feature branch → runs normally
# ─────────────────────────────────────────────────────────────────────────────
setup_git_repo
REPO_C="$DEPUTY_ROOT"
bash "$DEPUTY" add "escape hatch item" --p0
git -C "$REPO_C" checkout -qb feature/override

out="$(DEPUTY_ALLOW_ANY_BRANCH=1 DEPUTY_ORCHESTRATOR_CMD="$ORCH" \
  DEPUTY_AVAIL="claude,gemini" DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run --once 2>&1)"; rc=$?

assert_eq "$rc" "0" "escape hatch: deputy run exits 0 on feature branch"
assert_contains "$(bash "$DEPUTY" list)" "+[#" \
  "escape hatch: item driven to done"

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: detached HEAD → refused
# ─────────────────────────────────────────────────────────────────────────────
setup_git_repo
REPO_D="$DEPUTY_ROOT"
bash "$DEPUTY" add "detached head item" --p0

# Detach HEAD at the current commit
SHA="$(git -C "$REPO_D" rev-parse HEAD)"
git -C "$REPO_D" checkout -q --detach "$SHA"

err_out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude,gemini" \
  bash "$DEPUTY" run --once 2>&1)"; rc=$?

assert_eq "$rc" "1" "detached HEAD: deputy run exits non-zero"
assert_contains "$err_out" "refusing to run" \
  "detached HEAD: refusal message printed"
assert_contains "$err_out" "HEAD" \
  "detached HEAD: 'HEAD' appears in message"

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: non-git directory → runs normally (graceful fallback)
# ─────────────────────────────────────────────────────────────────────────────
# setup_repo (from lib.sh) creates a plain mktemp dir — not a git repo
setup_repo
bash "$DEPUTY" add "non-git item" --p0

out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude,gemini" \
  DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run --once 2>&1)"; rc=$?

assert_eq "$rc" "0" "non-git dir: deputy run exits 0"
assert_contains "$(bash "$DEPUTY" list)" "+[#" \
  "non-git dir: item driven to done"

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: targeted run (deputy run <id>) on a feature branch → also refused
# ─────────────────────────────────────────────────────────────────────────────
setup_git_repo
REPO_F="$DEPUTY_ROOT"
bash "$DEPUTY" add "targeted item" --p0
bash "$DEPUTY" list >/dev/null  # allocate IDs
git -C "$REPO_F" checkout -qb feature/targeted

err_out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude,gemini" \
  bash "$DEPUTY" run 1 2>&1)"; rc=$?

assert_eq "$rc" "1" "targeted run on feature branch: exits non-zero"
assert_contains "$err_out" "refusing to run" \
  "targeted run on feature branch: refusal message printed"

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────────────────────
rm -f "$ORCH"
