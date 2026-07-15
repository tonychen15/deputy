#!/usr/bin/env bash
# #72: per-command focused help — `deputy <cmd> --help|-h` slices that command's block
# out of usage() (single source of truth) and exits 0; plumbing/unknown fall back to usage.
source "$(dirname "$0")/lib.sh"
setup_repo

# focused help for a public command, exit 0
out="$(bash "$DEPUTY" set --help 2>&1)"; rc=$?
assert_eq "$rc" "0" "set --help: exits 0"
assert_contains "$out" "<state|pN>" "set --help: shows the set block"
# focused = ONLY that command's block (no other command's unique text bleeds in)
if [[ "$out" == *'add "<text>"'* ]]; then
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); printf 'FAIL: set --help leaked the add block\n' >&2
else
  TESTS_RUN=$((TESTS_RUN+1))
fi

# -h alias works
out="$(bash "$DEPUTY" list -h 2>&1)"; rc=$?
assert_eq "$rc" "0" "list -h: exits 0 (alias)"
assert_contains "$out" "list [<state>]" "list -h: shows the list block"

# prefix-collision: 'release --help' must NOT bleed into the 'release-notes' block
out="$(bash "$DEPUTY" release --help 2>&1)"
assert_contains "$out" "cut a release" "release --help: shows release block"
if [[ "$out" == *"print Done items"* ]]; then
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); printf 'FAIL: release --help bled into release-notes\n' >&2
else
  TESTS_RUN=$((TESTS_RUN+1))
fi

# plumbing verb (no documented block) → full usage fallback
out="$(bash "$DEPUTY" claim --help 2>&1)"; rc=$?
assert_eq "$rc" "0" "claim --help: exits 0 (plumbing fallback)"
assert_contains "$out" "usage: deputy <command>" "claim --help: falls back to full usage"
assert_contains "$out" "commands:" "claim --help: full usage includes the commands section"

# top-level help unchanged
assert_contains "$(bash "$DEPUTY" --help 2>&1)" "usage: deputy <command>" "deputy --help: top-level usage"
assert_contains "$(bash "$DEPUTY" help 2>&1)"   "commands:"               "deputy help: top-level usage"

# a command WITHOUT --help still parses/runs normally (no interception)
assert_contains "$(bash "$DEPUTY" status 2>&1)" "waiting:" "status (no --help): runs normally"

# the `--` escape is respected: 'add -- --help' adds a "--help" item, not help output
DEPUTY_NO_AUTORUN=1 bash "$DEPUTY" add -- "--help" >/dev/null 2>&1
assert_contains "$(bash "$DEPUTY" list 2>&1)" "--help" "add -- --help: '--' escape adds the literal item (not help)"

# regex-shaped unknown command does NOT match a real block (literal prefix match)
out="$(bash "$DEPUTY" 's.t' --help 2>&1)"
assert_contains "$out" "usage: deputy <command>" "regex-shaped cmd falls back to usage (no regex match)"

# public aliases resolve to their documented command's block
assert_contains "$(bash "$DEPUTY" review --help 2>&1)" "what needs me" "review --help: shows the watch block (alias)"
assert_contains "$(bash "$DEPUTY" tail --help 2>&1)"   "passive monitor"    "tail --help: shows the watch block (alias, new passive-monitor description)"

# #101: --full flag hides/shows config key documentation
# default (-h) must NOT show config keys section or any specific key
out_default="$(bash "$DEPUTY" -h 2>&1)"
if [[ "$out_default" == *'config keys (.deputy/config)'* ]]; then
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); printf 'FAIL: deputy -h leaked config keys section heading\n' >&2
else
  TESTS_RUN=$((TESTS_RUN+1))
fi
if [[ "$out_default" == *'auto_merge=1'* ]]; then
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); printf 'FAIL: deputy -h leaked auto_merge=1\n' >&2
else
  TESTS_RUN=$((TESTS_RUN+1))
fi
assert_contains "$out_default" "--full" "deputy -h: shows --full hint"

# deputy help (alias) also hides config keys by default
out_help="$(bash "$DEPUTY" help 2>&1)"
if [[ "$out_help" == *'auto_merge=1'* ]]; then
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); printf 'FAIL: deputy help leaked auto_merge=1\n' >&2
else
  TESTS_RUN=$((TESTS_RUN+1))
fi

# --full reveals config keys
assert_contains "$(bash "$DEPUTY" -h --full 2>&1)" "auto_merge=1" "deputy -h --full: shows auto_merge=1"
assert_contains "$(bash "$DEPUTY" help --full 2>&1)" "auto_merge=1" "deputy help --full: shows auto_merge=1"

# plumbing fallback with --full also reveals config keys
assert_contains "$(bash "$DEPUTY" claim --help --full 2>&1)" "auto_merge=1" "claim --help --full: plumbing fallback shows config keys"
