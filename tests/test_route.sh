#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
r() { bash "$DEPUTY" route "$1" "$2"; }

assert_eq "$(r orchestrate claude,gemini,codex)" "claude" "orchestrate -> claude"
assert_eq "$(r orchestrate gemini,codex)"        "wait"   "orchestrate waits if no claude"
assert_eq "$(r code-complex claude)"             "claude" "complex -> claude"
assert_eq "$(r code-complex codex)"              "wait"   "complex waits (claude-bound) even if codex up"
assert_eq "$(r code-simple claude,codex)"        "claude" "simple prefers claude"
assert_eq "$(r code-simple gemini,codex)"        "codex"  "simple fails over to codex"
assert_eq "$(r code-simple gemini)"              "wait"   "simple waits if neither claude nor codex"
assert_eq "$(r review claude,gemini)"            "gemini" "review -> gemini"
assert_eq "$(r review claude,codex)"             "wait"   "review waits if no gemini"
