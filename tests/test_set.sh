#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
printf '%s\n' '[P0] do the thing' 'plain one' >> "$DEPUTY_ROOT/BACKLOG.md"

# Trigger allocation so items get [#N] tags before we use them with set
bash "$DEPUTY" list >/dev/null
thing_line="$(grep 'do the thing' "$DEPUTY_ROOT/BACKLOG.md")"
plain_line="$(grep '^plain one$\|^\[#.*\] plain one$' "$DEPUTY_ROOT/BACKLOG.md")"

# waiting -> running keeps the priority tag.
bash "$DEPUTY" set "$thing_line" running
assert_contains "$(bash "$DEPUTY" list)" "running|P0|" "set waiting->running keeps P0"
assert_contains "$(bash "$DEPUTY" list)" "do the thing" "set waiting->running: description preserved"

# running -> done (use the now-current raw line).
running_thing="$(grep 'do the thing' "$DEPUTY_ROOT/BACKLOG.md")"
bash "$DEPUTY" set "$running_thing" done
assert_contains "$(bash "$DEPUTY" list)" "done|P0|" "set running->done"
assert_contains "$(bash "$DEPUTY" list)" "do the thing" "set running->done: description preserved"

# untagged transition.
bash "$DEPUTY" set "$plain_line" surfaced
assert_contains "$(bash "$DEPUTY" list)" "surfaced||" "set untagged->surfaced"
assert_contains "$(bash "$DEPUTY" list)" "plain one"  "set untagged->surfaced: description preserved"

# No match -> non-zero, file unchanged.
before="$(cat "$DEPUTY_ROOT/BACKLOG.md")"
bash "$DEPUTY" set "does not exist" done; rc=$?
after="$(cat "$DEPUTY_ROOT/BACKLOG.md")"
assert_eq "$rc" "1" "set no-match returns 1"
assert_eq "$after" "$before" "set no-match leaves file unchanged"

# Invalid state -> usage error (exit 2).
bash "$DEPUTY" set "[P0] x" bogus; rc=$?
assert_eq "$rc" "2" "set invalid state exits 2"

# Missing the state arg -> usage error (exit 2).
bash "$DEPUTY" set "only-one-arg"; rc=$?
assert_eq "$rc" "2" "set missing state arg exits 2"

# A description containing a pipe survives the transition (no truncation).
printf '%s\n' '[P1] a|b' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null
pipe_line="$(grep 'a|b' "$DEPUTY_ROOT/BACKLOG.md")"
bash "$DEPUTY" set "$pipe_line" running
assert_contains "$(bash "$DEPUTY" list)" "running|P1|" "set preserves pipe in description (state)"
assert_contains "$(bash "$DEPUTY" list)" "a|b"          "set preserves pipe in description"
