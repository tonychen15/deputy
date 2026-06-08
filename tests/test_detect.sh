#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

# helper: write content to a temp log and classify
det() {  # det <cli> <exit_code> <content>
  local f; f="$(mktemp)"; printf '%s\n' "$3" > "$f"
  bash "$DEPUTY" detect "$1" "$2" "$f"
  rm -f "$f"
}

assert_eq "$(det claude 0 'all good')"                       "ok"              "exit 0 is ok"
assert_eq "$(det claude 1 'You have hit your limit; resets 11pm')" "quota_exhausted" "claude limit"
assert_eq "$(det gemini 1 'Error: RESOURCE_EXHAUSTED 429')"  "quota_exhausted" "gemini 429"
assert_eq "$(det codex 1 'You have reached your usage limit')" "quota_exhausted" "codex usage limit"
assert_eq "$(det claude 1 'Please run /login to authenticate')" "auth_error"   "auth pattern"
assert_eq "$(det codex 1 'Not logged in')"                   "auth_error"      "codex not-logged-in is auth"
assert_eq "$(det claude 1 'segfault: core dumped')"          "hard_error"      "unknown nonzero is hard_error"
assert_eq "$(det gemini 2 'random failure text')"            "hard_error"      "conservative default"
