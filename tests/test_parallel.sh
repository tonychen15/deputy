#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

# ── default (max_parallel=1): serial behavior unchanged ──────────────────────
setup_repo
printf '%s\n' '[P0] first' '[P1] second' >> "$DEPUTY_ROOT/BACKLOG.md"
sleep 300 & LIVE=$!
bash "$DEPUTY" claim "[P0] first" --pid "$LIVE"; rc=$?
assert_eq "$rc" "0" "first claim succeeds (default serial)"
sleep 300 & LIVE2=$!
bash "$DEPUTY" claim "[P1] second" --pid "$LIVE2"; rc=$?
assert_eq "$rc" "3" "second claim refused (default serial cap=1)"
kill "$LIVE" "$LIVE2" 2>/dev/null

# ── max_parallel=2: two concurrent claims allowed ────────────────────────────
setup_repo
printf 'max_parallel=2\n' > "$DEPUTY_ROOT/.deputy/config"
printf '%s\n' '[P0] alpha' '[P1] beta' '[P2] gamma' >> "$DEPUTY_ROOT/BACKLOG.md"
sleep 300 & LIVE=$!
bash "$DEPUTY" claim "[P0] alpha" --pid "$LIVE"; rc=$?
assert_eq "$rc" "0" "first claim (par=2)"
sleep 300 & LIVE2=$!
bash "$DEPUTY" claim "[P1] beta" --pid "$LIVE2"; rc=$?
assert_eq "$rc" "0" "second claim allowed (par=2)"
# third claim refused — at cap
sleep 300 & LIVE3=$!
bash "$DEPUTY" claim "[P2] gamma" --pid "$LIVE3"; rc=$?
assert_eq "$rc" "3" "third claim refused at cap=2"
assert_eq "$(bash "$DEPUTY" list | grep -c 'running')" "2" "two items running"
kill "$LIVE" "$LIVE2" "$LIVE3" 2>/dev/null

# ── path conflict detection ───────────────────────────────────────────────────
setup_repo
printf 'max_parallel=2\n' > "$DEPUTY_ROOT/.deputy/config"
printf '%s\n' '[P0] fix auth bug' '[P1] update auth tests' >> "$DEPUTY_ROOT/BACKLOG.md"
# Pre-register paths for both items (orchestrators would do this at runtime)
bash "$DEPUTY" wt-paths "fix-auth-bug" "src/auth.py"
bash "$DEPUTY" wt-paths "update-auth-tests" "src/auth.py"
# First claim succeeds (no running items yet → no conflict possible)
sleep 300 & LIVE=$!
bash "$DEPUTY" claim "[P0] fix auth bug" --pid "$LIVE"; rc=$?
assert_eq "$rc" "0" "first claim (no conflict yet)"
# Second claim has an overlapping path and a live conflicting claim → refused
sleep 300 & LIVE2=$!
bash "$DEPUTY" claim "[P1] update auth tests" --pid "$LIVE2"; rc=$?
assert_eq "$rc" "5" "second claim refused (path conflict)"
kill "$LIVE" "$LIVE2" 2>/dev/null

# No conflict when paths don't overlap
setup_repo
printf 'max_parallel=2\n' > "$DEPUTY_ROOT/.deputy/config"
printf '%s\n' '[P0] fix ui bug' '[P1] update docs' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" wt-paths "fix-ui-bug" "src/ui.py"
bash "$DEPUTY" wt-paths "update-docs" "docs/readme.md"
sleep 300 & LIVE=$!
bash "$DEPUTY" claim "[P0] fix ui bug" --pid "$LIVE"; rc=$?
assert_eq "$rc" "0" "first claim (non-overlapping)"
sleep 300 & LIVE2=$!
bash "$DEPUTY" claim "[P1] update docs" --pid "$LIVE2"; rc=$?
assert_eq "$rc" "0" "second claim allowed (no path overlap)"
kill "$LIVE" "$LIVE2" 2>/dev/null

# Same slug = conflict regardless of paths (same worktree directory)
setup_repo
printf 'max_parallel=2\n' > "$DEPUTY_ROOT/.deputy/config"
# Two descriptions that slugify to the same string
printf '%s\n' '[P0] Fix Thing' '[P1] fix thing' >> "$DEPUTY_ROOT/BACKLOG.md"
sleep 300 & LIVE=$!
bash "$DEPUTY" claim "[P0] Fix Thing" --pid "$LIVE"; rc=$?
assert_eq "$rc" "0" "first claim (same slug, no paths)"
sleep 300 & LIVE2=$!
bash "$DEPUTY" claim "[P1] fix thing" --pid "$LIVE2"; rc=$?
assert_eq "$rc" "5" "second claim refused (same-slug conflict)"
kill "$LIVE" "$LIVE2" 2>/dev/null

# No conflict when new item has no registered paths
setup_repo
printf 'max_parallel=2\n' > "$DEPUTY_ROOT/.deputy/config"
printf '%s\n' '[P0] item a' '[P1] item b' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" wt-paths "item-a" "src/foo.py"
# item-b has NO paths file → no conflict check possible
sleep 300 & LIVE=$!
bash "$DEPUTY" claim "[P0] item a" --pid "$LIVE"; rc=$?
assert_eq "$rc" "0" "claim with paths"
sleep 300 & LIVE2=$!
bash "$DEPUTY" claim "[P1] item b" --pid "$LIVE2"; rc=$?
assert_eq "$rc" "0" "second claim succeeds when new item has no registered paths"
kill "$LIVE" "$LIVE2" 2>/dev/null

# ── parallel cmd_run: processes multiple items concurrently ──────────────────
setup_repo
printf 'max_parallel=2\n' > "$DEPUTY_ROOT/.deputy/config"
bash "$DEPUTY" add "task one" --p0
bash "$DEPUTY" add "task two" --p0

ORCH="$(mktemp)"
cat > "$ORCH" <<EOF
#!/usr/bin/env bash
bash "$DEPUTY" set "\$1" done >/dev/null 2>&1 || true
EOF
chmod +x "$ORCH"

out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude,gemini" DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run 2>&1)"
assert_eq "$(bash "$DEPUTY" list | grep -c 'done|P0')" "2" "parallel run processes both items"
assert_eq "$(ls "$DEPUTY_ROOT"/.deputy/*.claim 2>/dev/null | wc -l | tr -d ' ')" "0" "no stale claims"

# ── parallel run with max_items cap ──────────────────────────────────────────
setup_repo
printf 'max_parallel=2\nmax_items=1\n' > "$DEPUTY_ROOT/.deputy/config"
bash "$DEPUTY" add "only" --p0
bash "$DEPUTY" add "skipped" --p0

out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude,gemini" DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run 2>&1)"
assert_eq "$(bash "$DEPUTY" list | grep -c 'done|P0')" "1" "max_items=1 limits parallel run to one item"
assert_contains "$(bash "$DEPUTY" list)" "waiting|P0|skipped" "second item stays waiting"

rm -f "$ORCH"
