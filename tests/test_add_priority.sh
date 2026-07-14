#!/usr/bin/env bash
# tests/test_add_priority.sh — #105: 'deputy add --<prio>' prints the just-added task's
# priority DISPOSITION when idle (no running task), consistent with 'run --<prio>' (#104).
# Behavior is unchanged — _autorun still drains the top runnable task (mocked here).
source "$(dirname "$0")/lib.sh"
D() { bash "$DEPUTY" "$@"; }
_id() { D list | grep -F "$1" | grep -oE '#[0-9]+' | tr -d '#' | head -1; }
MOCK=/bin/true   # DEPUTY_AUTORUN_CMD → _autorun becomes a no-op (no real run spawned)

# (a) empty queue → the new task is the top runnable → "running now"
setup_repo
out="$(DEPUTY_NO_AUTORUN=0 DEPUTY_AUTORUN_CMD="$MOCK" D add "solo task" --p2)"
id="$(_id 'solo task')"
assert_contains "$out" "#$id (P2) is currently the highest-priority runnable task" "(a) empty queue: new task runs now"

# (b) a HIGHER-priority task already waiting → the new task is queued
setup_repo
DEPUTY_NO_AUTORUN=1 D add "big important" --p0 >/dev/null
out="$(DEPUTY_NO_AUTORUN=0 DEPUTY_AUTORUN_CMD="$MOCK" D add "small later" --p3)"
sid="$(_id 'small later')"
assert_contains "$out" "#$sid (P3) queued" "(b) higher waiting: new task queued"

# (c) all waiting tasks LOWER priority → the new task is top → "running now"
setup_repo
DEPUTY_NO_AUTORUN=1 D add "someday low" --p4 >/dev/null
out="$(DEPUTY_NO_AUTORUN=0 DEPUTY_AUTORUN_CMD="$MOCK" D add "urgent now" --p1)"
uid="$(_id 'urgent now')"
assert_contains "$out" "#$uid (P1) is currently the highest-priority runnable task" "(c) all lower: new task runs now"

# (d) DEPUTY_NO_AUTORUN=1 suppresses the disposition message entirely
setup_repo
out="$(DEPUTY_NO_AUTORUN=1 D add "quiet add" --p2)"
if printf '%s' "$out" | grep -qiE 'highest-priority runnable|queued'; then
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); printf 'FAIL: NO_AUTORUN=1 leaked a disposition message\n' >&2
else TESTS_RUN=$((TESTS_RUN+1)); fi

# (e) a DUPLICATE add ('already present') must NOT print a disposition (handoff not written)
setup_repo
DEPUTY_NO_AUTORUN=1 D add "twin task" --p2 >/dev/null
out="$(DEPUTY_NO_AUTORUN=0 DEPUTY_AUTORUN_CMD="$MOCK" D add "twin task" --p2)"
assert_contains "$out" "already present" "(e) duplicate add reports already present"
if printf '%s' "$out" | grep -qiE 'highest-priority runnable|queued'; then
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); printf 'FAIL: duplicate add leaked a disposition message\n' >&2
else TESTS_RUN=$((TESTS_RUN+1)); fi
# handoff file must not leak
assert_eq "$(ls "$DEPUTY_ROOT"/.deputy/.add_pending.* 2>/dev/null | wc -l | tr -d ' ')" "0" "(e) .add_pending handoff cleaned up (no leak)"
