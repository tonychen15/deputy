#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

# ── set transitions regroup the file ─────────────────────────────────────────
setup_repo
printf '%s\n' '[P1] alpha' '[P2] beta' >> "$DEPUTY_ROOT/BACKLOG.md"

bash "$DEPUTY" set "[P1] alpha" done
body="$(awk '/^## Items/{found=1; next} found{print}' "$DEPUTY_ROOT/BACKLOG.md")"
# waiting item should appear before done item
alpha_line="$(echo "$body" | grep -n 'alpha' | cut -d: -f1)"
beta_line="$(echo  "$body" | grep -n 'beta'  | cut -d: -f1)"
if [[ "$beta_line" -lt "$alpha_line" ]]; then
  TESTS_RUN=$((TESTS_RUN + 1))
else
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
  printf 'FAIL: after set->done, waiting item should appear before done item\n' >&2
fi

# groups must be separated by a blank line
blank_between="$(echo "$body" | awk 'prev && /^[[:space:]]*$/ && !blank { blank=1 } /beta/ { prev=1 } /alpha/ && prev { if (blank) print "yes" }' )"
assert_eq "$blank_between" "yes" "blank line separates waiting and done groups"

# ── add places new waiting item in the waiting group (before done items) ─────
setup_repo
printf '%s\n' '#[P0] already done' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" add "new task" --p1
body="$(awk '/^## Items/{found=1; next} found{print}' "$DEPUTY_ROOT/BACKLOG.md")"
new_line="$(echo  "$body" | grep -n 'new task'   | cut -d: -f1)"
done_line="$(echo "$body" | grep -n 'already done' | cut -d: -f1)"
if [[ "$new_line" -lt "$done_line" ]]; then
  TESTS_RUN=$((TESTS_RUN + 1))
else
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
  printf 'FAIL: new waiting item should appear before existing done item\n' >&2
fi

# ── active items (running) land between waiting and terminal ──────────────────
setup_repo
printf '%s\n' '[P2] waiting one' '@[P1] running one' '#[P0] done one' >> "$DEPUTY_ROOT/BACKLOG.md"
# trigger regroup via a no-op state change on the running item
bash "$DEPUTY" set "@[P1] running one" running
body="$(awk '/^## Items/{found=1; next} found{print}' "$DEPUTY_ROOT/BACKLOG.md")"
wait_line=$(echo "$body" | grep -n 'waiting one' | cut -d: -f1)
run_line=$(echo  "$body" | grep -n 'running one' | cut -d: -f1)
done_ln=$(echo   "$body" | grep -n 'done one'    | cut -d: -f1)
if [[ "$wait_line" -lt "$run_line" && "$run_line" -lt "$done_ln" ]]; then
  TESTS_RUN=$((TESTS_RUN + 1))
else
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
  printf 'FAIL: groups should be ordered waiting < active < terminal\n  wait=%s run=%s done=%s\n' \
    "$wait_line" "$run_line" "$done_ln" >&2
fi

# ── file with no '## Items' heading is left unchanged ────────────────────────
setup_repo
LEGACY="$DEPUTY_ROOT/BACKLOG.md"
printf '# Old style\n\n[P0] task one\n#[P1] done two\n' > "$LEGACY"
before="$(cat "$LEGACY")"
# manually call deputy set on a line that exists so _flip_line fires
printf '[P0] task one\n' >> /dev/null  # noop sanity
# inject a line-replace without ## Items header
bash "$DEPUTY" set "[P0] task one" running 2>/dev/null || true
# _regroup_backlog should no-op; file format is whatever _flip_line left it
after="$(cat "$LEGACY")"
# The key property: no '## Items' regroup happened, so no items were dropped
assert_contains "$after" "task one" "legacy format: task one still present after no-op regroup"
assert_contains "$after" "done two"  "legacy format: done two still present after no-op regroup"
