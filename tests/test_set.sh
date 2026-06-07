#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
printf '%s\n' '[P0] do the thing' 'plain one' >> "$DEPUTY_ROOT/BACKLOG.md"

# waiting -> running keeps the priority tag.
bash "$DEPUTY" set "[P0] do the thing" running
assert_contains "$(bash "$DEPUTY" list)" "running|P0|do the thing" "set waiting->running keeps P0"

# running -> done (use the now-current raw line).
bash "$DEPUTY" set "@ [P0] do the thing" done
assert_contains "$(bash "$DEPUTY" list)" "done|P0|do the thing" "set running->done"

# untagged transition.
bash "$DEPUTY" set "plain one" surfaced
assert_contains "$(bash "$DEPUTY" list)" "surfaced||plain one" "set untagged->surfaced"

# No match -> non-zero, file unchanged.
before="$(cat "$DEPUTY_ROOT/BACKLOG.md")"
bash "$DEPUTY" set "does not exist" done; rc=$?
after="$(cat "$DEPUTY_ROOT/BACKLOG.md")"
assert_eq "$rc" "1" "set no-match returns 1"
assert_eq "$after" "$before" "set no-match leaves file unchanged"

# Invalid state -> usage error (exit 2).
bash "$DEPUTY" set "[P0] x" bogus; rc=$?
assert_eq "$rc" "2" "set invalid state exits 2"
