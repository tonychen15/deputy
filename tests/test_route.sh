#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
r() { bash "$DEPUTY" route "$@"; }

assert_eq "$(r orchestrate claude,gemini,codex)" "claude"  "orchestrate -> claude"
assert_eq "$(r orchestrate gemini,codex)"        "gemini"  "orchestrate fails over to gemini"
assert_eq "$(r orchestrate codex)"               "wait"    "orchestrate waits if no claude or gemini"
assert_eq "$(r code-complex claude)"             "claude"  "complex -> claude"
assert_eq "$(r code-complex gemini)"             "gemini"  "complex fails over to gemini"
assert_eq "$(r code-complex codex)"              "wait"    "complex waits if no claude or gemini"
assert_eq "$(r code-simple claude,codex)"        "claude"  "simple prefers claude"
assert_eq "$(r code-simple gemini,codex)"        "codex"   "simple fails over to codex"
assert_eq "$(r code-simple gemini)"              "wait"    "simple waits if neither claude nor codex"
assert_eq "$(r review claude,gemini)"            "gemini"  "review -> gemini"
assert_eq "$(r review claude,codex)"             "claude"  "review falls back to claude if no gemini"
assert_eq "$(r review claude,gemini --not gemini)" "claude"  "review skips gemini author -> claude"
assert_eq "$(r review gemini,codex --not gemini)"  "codex"   "review skips gemini author -> codex"
assert_eq "$(r review gemini --not gemini)"        "wait"    "review waits when only author available"
assert_eq "$(r review codex --not gemini)"         "codex"   "--not is no-op when excluded not in avail"
assert_eq "$(r review codex)"                      "codex"   "review falls back to codex if no gemini or claude"
