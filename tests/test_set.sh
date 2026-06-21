#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
printf '%s\n' '[P0] do the thing' 'plain one' >> "$DEPUTY_ROOT/BACKLOG.md"

# Trigger allocation so items get [#N] tags before we use them with set
bash "$DEPUTY" list >/dev/null
thing_line="$(grep 'do the thing' "$DEPUTY_ROOT/BACKLOG.md")"
plain_line="$(grep 'plain one' "$DEPUTY_ROOT/BACKLOG.md")"

# waiting -> running keeps the priority tag.
bash "$DEPUTY" set "$thing_line" running
assert_contains "$(bash "$DEPUTY" list)" "running|P0|" "set waiting->running keeps P0"
assert_contains "$(bash "$DEPUTY" list)" "do the thing" "set waiting->running: description preserved"

# running -> done (use the now-current raw line).
running_thing="$(grep 'do the thing' "$DEPUTY_ROOT/BACKLOG.md")"
bash "$DEPUTY" set "$running_thing" done
assert_contains "$(bash "$DEPUTY" list)" "done|P0|" "set running->done"
assert_contains "$(bash "$DEPUTY" list)" "do the thing" "set running->done: description preserved"

# P3-defaulted item transition (items without explicit priority get P3 assigned).
bash "$DEPUTY" set "$plain_line" surfaced
assert_contains "$(bash "$DEPUTY" list)" "surfaced|P3|" "set P3-default->surfaced"
assert_contains "$(bash "$DEPUTY" list)" "plain one"    "set P3-default->surfaced: description preserved"

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

# ── #56: set by item id (N or #N) resolves to the unique line ────────────────────
printf '%s\n' '[P2] set-by-id target' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null
sid="$(bash "$DEPUTY" list | grep 'set-by-id target' | cut -d'|' -f3)"
bash "$DEPUTY" set "$sid" deferred
assert_contains "$(bash "$DEPUTY" list)" "deferred|P2|"    "set <id> resolves and transitions"
assert_contains "$(bash "$DEPUTY" list)" "set-by-id target" "set <id>: description preserved"
bash "$DEPUTY" set "#$sid" waiting
assert_contains "$(bash "$DEPUTY" list)" "waiting|P2|"     "set #<id> resolves and transitions"

# absent id -> exit 2 + message, file unchanged.
b2="$(cat "$DEPUTY_ROOT/BACKLOG.md")"
out="$(bash "$DEPUTY" set 99999 waiting 2>&1)"; rc=$?
assert_eq "$rc" "2" "set <absent id> exits 2"
assert_contains "$out" "no item with id #99999" "set <absent id>: clear error"
assert_eq "$(cat "$DEPUTY_ROOT/BACKLOG.md")" "$b2" "set <absent id> leaves file unchanged"

# duplicated [#N] -> 'multiple items' error (defensive; ids are normally unique).
printf '%s\n' "[P2][#$sid] duplicate id line" >> "$DEPUTY_ROOT/BACKLOG.md"
out="$(bash "$DEPUTY" set "$sid" running 2>&1)"; rc=$?
assert_eq "$rc" "2" "set <duplicated id> exits 2"
assert_contains "$out" "multiple items with id #$sid" "set <duplicated id>: clear error"
