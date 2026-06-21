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
# ── review: AUTHOR-AWARE reviewer order (preference depends on who authored) ──
#   author=claude -> codex, gemini ; author=codex -> claude, gemini ;
#   author=gemini -> claude, codex ; author='' -> codex, gemini (no claude self-review)
rr() { bash "$DEPUTY" route review "$1" "$2"; }

# No author given: external peers only, codex preferred (claude never self-reviews).
assert_eq "$(r review claude,gemini)"            "gemini" "review -> gemini when codex absent"
assert_eq "$(r review claude,codex)"             "codex"  "review -> codex by default (no longer waits)"
assert_eq "$(rr claude,gemini,codex '')"         "codex"  "review default reviewer is codex"
assert_eq "$(rr claude,gemini '')"               "gemini" "review falls back to gemini"
# Empty author: claude is NOT eligible (it is the orchestrator; would risk self-review).
assert_eq "$(rr claude '')"                      "wait"   "no author + only claude -> wait (not claude)"

# Author excluded (author != reviewer), claude-FIRST when a non-claude peer authored.
assert_eq "$(rr claude,gemini,codex claude)"     "codex"  "claude authored -> codex reviews"
assert_eq "$(rr claude,gemini,codex codex)"      "claude" "codex authored -> claude reviews first (was gemini)"
assert_eq "$(rr claude,gemini,codex gemini)"     "claude" "gemini authored -> claude reviews first"
assert_eq "$(rr claude,codex codex)"             "claude" "codex authored, gemini down -> claude reviews"
assert_eq "$(rr claude,codex gemini)"            "claude" "gemini authored -> claude reviews (claude-first)"
assert_eq "$(rr gemini,codex codex)"             "gemini" "codex authored, claude down -> gemini reviews"
assert_eq "$(rr gemini,codex gemini)"            "codex"  "gemini authored, claude down -> codex reviews"

# Only the author is up -> 'self' (caller degrades per auto_mode).
assert_eq "$(rr codex codex)"                    "self"   "only author up -> self-review signal"
assert_eq "$(rr claude claude)"                  "self"   "only claude up & authored -> self"

# Nothing up at all -> wait.
assert_eq "$(rr '' codex)"                       "wait"   "no providers -> wait"
