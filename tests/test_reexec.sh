#!/usr/bin/env bash
# tests/test_reexec.sh — #50: deputy re-execs from an immutable, content-addressed snapshot
# so editing/merging bin/deputy.sh mid-run can't truncate a running invocation.
source "$(dirname "$0")/lib.sh"

CACHE=""
new_cache() { CACHE="$(mktemp -d)"; }
# Run deputy with an isolated snapshot cache.
dep() { XDG_CACHE_HOME="$CACHE" DEPUTY_ROOT="$DEPUTY_ROOT" DEPUTY_ALLOW_ANY_BRANCH=1 bash "$DEPUTY" "$@"; }
snaps() { ls "$CACHE"/deputy/deputy-*.sh 2>/dev/null; }
srcsha() { sha256sum "$DEPUTY" | cut -c1-16; }

# 1: a run creates a snapshot whose content matches the source.
setup_repo; new_cache
dep list >/dev/null 2>&1
snap="$(snaps | head -1)"
assert_eq "$([ -n "$snap" ] && echo yes || echo no)" "yes" "a snapshot is created on first run"
assert_eq "$(cmp -s "$snap" "$DEPUTY" && echo same || echo diff)" "same" "snapshot content == source"

# 2: deputy still works through the re-exec (SRC_DIR/templates preserved).
setup_repo; new_cache
dep add --p2 "reexec smoke item" >/dev/null 2>&1
assert_contains "$(dep list 2>&1)" "reexec smoke item" "add+list works after re-exec (SRC_DIR preserved)"

# 3: a second run with unchanged source REUSES the snapshot (not rewritten).
setup_repo; new_cache
dep list >/dev/null 2>&1; snap="$(snaps | head -1)"; m1="$(stat -c %Y "$snap")"
sleep 1; dep list >/dev/null 2>&1; m2="$(stat -c %Y "$snap")"
assert_eq "$m1" "$m2" "unchanged source -> snapshot reused, not rewritten"
assert_eq "$(snaps | wc -l | tr -d ' ')" "1" "still exactly one snapshot"

# 4: DEPUTY_REEXEC=1 short-circuits the guard (no re-exec, no snapshot) — loop safety.
setup_repo; new_cache
DEPUTY_REEXEC=1 XDG_CACHE_HOME="$CACHE" DEPUTY_ROOT="$DEPUTY_ROOT" DEPUTY_ALLOW_ANY_BRANCH=1 bash "$DEPUTY" list >/dev/null 2>&1
assert_eq "$(snaps | wc -l | tr -d ' ')" "0" "DEPUTY_REEXEC=1 -> no snapshot (guard prevents exec loop)"

# 5: an unwritable cache falls back to running in place (no crash).
setup_repo; new_cache
badcache="$(mktemp)"   # a FILE, so mkdir -p "$badcache/deputy" fails
out="$(XDG_CACHE_HOME="$badcache" DEPUTY_ROOT="$DEPUTY_ROOT" DEPUTY_ALLOW_ANY_BRANCH=1 bash "$DEPUTY" add --p3 "fallback item" 2>&1; echo "rc=$?")"
assert_contains "$out" "rc=0" "unwritable cache -> deputy still runs in place (exit 0)"
assert_contains "$(DEPUTY_ROOT="$DEPUTY_ROOT" bash "$DEPUTY" list 2>&1)" "fallback item" "fallback run still did the work"

# 6: a corrupt cache entry (name says <sha> but content differs) is NOT trusted; self-heals.
setup_repo; new_cache
mkdir -p "$CACHE/deputy"; printf 'echo CORRUPT-SNAPSHOT\n' > "$CACHE/deputy/deputy-$(srcsha).sh"
out="$(dep list 2>&1)"
assert_eq "$(echo "$out" | grep -c 'CORRUPT-SNAPSHOT')" "0" "corrupt cache entry (hash mismatch) is not executed"
assert_eq "$(cmp -s "$CACHE/deputy/deputy-$(srcsha).sh" "$DEPUTY" && echo healed || echo stillbad)" "healed" "slow path republishes correct content (self-heal)"
