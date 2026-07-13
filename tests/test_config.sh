#!/usr/bin/env bash
# tests/test_config.sh — #90: 'deputy config' read + atomic-upsert setter, the 'autonomy
# on|off' shorthand (sets both autonomy knobs), and the self_review_fallback←auto_mode
# back-compat alias.
source "$(dirname "$0")/lib.sh"
setup_repo
C() { bash "$DEPUTY" config "$@"; }

# read/write roundtrip
C auto_merge 1 >/dev/null
assert_eq "$(C auto_merge)" "1" "set then read"

# upsert: repeated sets keep exactly ONE line per key (no accumulation)
C auto_merge 0 >/dev/null; C auto_merge 1 >/dev/null; C auto_merge 0 >/dev/null
assert_eq "$(grep -c '^auto_merge=' "$DEPUTY_ROOT/.deputy/config")" "1" "upsert keeps one line per key"
assert_eq "$(C auto_merge)" "0" "upsert: last value wins"

# 'autonomy on|off' shorthand sets BOTH knobs
C autonomy on >/dev/null
assert_eq "$(C auto_merge)"           "1" "autonomy on → auto_merge=1"
assert_eq "$(C self_review_fallback)" "1" "autonomy on → self_review_fallback=1"
C autonomy off >/dev/null
assert_eq "$(C auto_merge)"           "0" "autonomy off → auto_merge=0"
assert_eq "$(C self_review_fallback)" "0" "autonomy off → self_review_fallback=0"
C autonomy maybe >/dev/null 2>&1; assert_eq "$?" "2" "autonomy invalid value exits 2"

# back-compat alias: a legacy auto_mode is read via self_review_fallback when the new key is unset
setup_repo
printf 'auto_mode=1\n' > "$DEPUTY_ROOT/.deputy/config"
assert_eq "$(C self_review_fallback)" "1" "legacy auto_mode read via self_review_fallback alias"
# an explicit self_review_fallback overrides the legacy alias
C self_review_fallback 0 >/dev/null
assert_eq "$(C self_review_fallback)" "0" "explicit self_review_fallback overrides legacy auto_mode"

# invalid key rejected (rc 2); unset key reads empty (rc 0)
C 'bad key' 1 >/dev/null 2>&1; assert_eq "$?" "2" "invalid key rejected"
out="$(C never_set_key)"; rc=$?
assert_eq "$rc" "0" "read unset key exits 0"
assert_eq "$out" "" "read unset key is empty"

# upsert tolerates spaces around '=' (which _config_get also trims) — no stale dup left
setup_repo
printf 'auto_merge = 1\n' > "$DEPUTY_ROOT/.deputy/config"   # spaced form
C auto_merge 0 >/dev/null
assert_eq "$(grep -c 'auto_merge' "$DEPUTY_ROOT/.deputy/config")" "1" "upsert removes the spaced 'key = value' form too"
assert_eq "$(C auto_merge)" "0" "spaced-form upsert: new value wins"

# too many args rejected (rc 2)
C auto_merge 1 junk >/dev/null 2>&1; assert_eq "$?" "2" "extra args rejected"

# zero-arg lists the current config (non-comment lines)
setup_repo
C max_items 5 >/dev/null
assert_contains "$(C)" "max_items=5" "bare 'config' lists current keys"
