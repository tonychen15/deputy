#!/usr/bin/env bash
# tests/test_worker_model.sh — _worker_model_for: 3-tier hardness-routed worker model.
# simple → worker_model (default sonnet); moderate → worker_model_moderate; complex →
# worker_model_complex. Unset tiers fall through to the next lighter one.
source "$(dirname "$0")/lib.sh"
setup_repo
cfg="$DEPUTY_ROOT/.deputy/config"
WM() { ( source "$DEPUTY"; _worker_model_for "$1" ); }

SIMPLE='[#1][P3] tiny fix'
MODERATE='[#2][P3] add a --json flag to deputy list'
COMPLEX='[#3][P2] refactor the auth module and fix the race condition; scope is large'
LONG="[#4][P3] $(printf 'x%.0s' {1..420})"

# 1. nothing configured → default base for all
: > "$cfg"
assert_eq "$(WM "$SIMPLE")"  "claude-sonnet-4-6" "unconfigured: simple → sonnet default"
assert_eq "$(WM "$COMPLEX")" "claude-sonnet-4-6" "unconfigured: complex → sonnet default (no tiers set)"

# 2. all three tiers set (sonnet / fable / opus) → routed by hardness
printf 'worker_model=claude-sonnet-4-6\nworker_model_moderate=claude-fable-5\nworker_model_complex=claude-opus-4-8\n' > "$cfg"
assert_eq "$(WM "$SIMPLE")"   "claude-sonnet-4-6" "simple → sonnet"
assert_eq "$(WM "$MODERATE")" "claude-fable-5"    "moderate (add ... flag) → fable"
assert_eq "$(WM "$COMPLEX")"  "claude-opus-4-8"   "complex (refactor/race/scope) → opus"
assert_eq "$(WM "$LONG")"     "claude-opus-4-8"   "long (>400 chars) → complex → opus"

# 3. fallthrough — only complex set: a moderate item falls back to base
printf 'worker_model=claude-sonnet-4-6\nworker_model_complex=claude-opus-4-8\n' > "$cfg"
assert_eq "$(WM "$MODERATE")" "claude-sonnet-4-6" "moderate with no moderate model → base (fallthrough)"
assert_eq "$(WM "$COMPLEX")"  "claude-opus-4-8"   "complex → complex model"

# 4. fallthrough — only moderate set: a complex item falls back to the moderate model
printf 'worker_model=claude-sonnet-4-6\nworker_model_moderate=claude-fable-5\n' > "$cfg"
assert_eq "$(WM "$COMPLEX")"  "claude-fable-5"    "complex with no complex model → moderate (fallthrough)"

# 5. validation — a typo/flag-like model id is rejected → falls to the sonnet default
printf 'worker_model_complex=--rm -rf\n' > "$cfg"
assert_eq "$(WM "$COMPLEX" 2>/dev/null)" "claude-sonnet-4-6" "invalid complex model id → sonnet default"
printf 'worker_model=claude-fable-5\nworker_model_complex=not_a_model\n' > "$cfg"
assert_eq "$(WM "$SIMPLE" 2>/dev/null)"  "claude-fable-5"    "valid base still used when a higher tier is invalid + not selected"
