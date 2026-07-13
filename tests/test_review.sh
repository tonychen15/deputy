#!/usr/bin/env bash
# 'deputy review' is a back-compat alias for 'deputy watch --once' (the queue overview +
# attention digest; the command formerly known as 'deputy reflect').
source "$(dirname "$0")/lib.sh"
setup_repo

# empty queue → the overview header prints
out="$(bash "$DEPUTY" review 2>&1)"
assert_contains "$out" "=== Deputy Queue Overview ===" "review: overview header present"

# surface an item with an id-named questions file → the attention digest shows it + its summary
bash "$DEPUTY" add "redesign onboarding" --p0
line="$(bash "$DEPUTY" pick)"
rid="$(printf '%s' "$line" | grep -oE '#[0-9]+' | tr -d '#')"
bash "$DEPUTY" set "$line" surfaced
mkdir -p "$DEPUTY_ROOT/.deputy/questions"
printf 'Q1: which flow?\nQ2: keep the wizard?\n' > "$DEPUTY_ROOT/.deputy/questions/redesign-onboarding-$rid.md"

out="$(bash "$DEPUTY" review 2>&1)"
assert_contains "$out" "redesign onboarding" "review lists the surfaced item"
assert_contains "$out" "Q1: which flow?"     "review shows the questions summary (first line)"
assert_contains "$out" "action:"             "review shows the item's action (deputy pickup)"
assert_contains "$out" "surfaced: 1"         "review shows the status digest"
