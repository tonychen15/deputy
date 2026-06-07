#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
assert_eq "hello" "hello" "harness: equal strings pass"
assert_contains "the quick brown fox" "quick" "harness: substring"
[[ -f "$DEPUTY_ROOT/BACKLOG.md" ]] && assert_eq "ok" "ok" "harness: template copied"
