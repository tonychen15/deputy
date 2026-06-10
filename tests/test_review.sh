#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

# nothing surfaced — review forwards to reflect; expect the reflect header and (none) for surfaced
out="$(bash "$DEPUTY" review)"
assert_contains "$out" "=== Deputy Reflect ===" "review: reflect header present"
assert_contains "$out" "(none)" "review: empty case shows (none)"

# surface an item + add a questions file
bash "$DEPUTY" add "redesign onboarding" --p0
line="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" set "$line" surfaced
mkdir -p "$DEPUTY_ROOT/.deputy"
printf 'Q1: which flow?\nQ2: keep the wizard?\n' > "$DEPUTY_ROOT/.deputy/redesign-onboarding.questions.md"

out="$(bash "$DEPUTY" review)"
assert_contains "$out" "redesign onboarding" "review lists surfaced item"
assert_contains "$out" "Q1: which flow?"     "review dumps questions file"
assert_contains "$out" "surfaced: 1"          "review shows digest"
