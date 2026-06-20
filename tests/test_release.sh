#!/usr/bin/env bash
# 'deputy release [version]' inserts a parser-safe dated delimiter at the top of
# the Done section. Version defaults to ./VERSION; malformed versions are rejected;
# re-releasing the same version+date is a no-op.
source "$(dirname "$0")/lib.sh"
export DEPUTY_NOTIFY_SYNC=1

today="$(date +%Y-%m-%d)"
block() { awk -v want="$1" '/^### /{inblk=($0 ~ "^### " want " \\(")} inblk && !/^### /{print}' "$DEPUTY_ROOT/BACKLOG.md"; }
lof() { grep -F -- "$1" "$DEPUTY_ROOT/BACKLOG.md" | head -1; }

# --- explicit version: delimiter inserted at top of Done, above existing done items ---
setup_repo
bash "$DEPUTY" add "shipped feature" --p0 >/dev/null
bash "$DEPUTY" list >/dev/null
bash "$DEPUTY" set "$(lof 'shipped feature')" done >/dev/null
out="$(bash "$DEPUTY" release 1.2.3 2>&1)"; rc=$?
assert_eq "$rc" "0" "release exits 0"
assert_contains "$out" "<!-- release v1.2.3 — $today -->" "release reports the marker"
dblk="$(block 'Done')"
delim_n="$(printf '%s\n' "$dblk" | grep -n "release v1.2.3" | head -1 | cut -d: -f1)"
item_n="$(printf '%s\n' "$dblk" | grep -n "shipped feature" | head -1 | cut -d: -f1)"
assert_eq "$([[ -n "$delim_n" && "$delim_n" -lt "$item_n" ]] && echo ok)" "ok" "delimiter sits above existing done items"
assert_contains "$(grep '^### Done' "$DEPUTY_ROOT/BACKLOG.md")" "(1)" "Done count excludes the delimiter"

# --- leading 'v' normalized (no double v) ---
setup_repo
bash "$DEPUTY" release v3.1 >/dev/null 2>&1
assert_eq "$(grep -c '<!-- release v3.1 —' "$DEPUTY_ROOT/BACKLOG.md")" "1" "leading v normalized (v3.1, not vv3.1)"

# --- default version from \$ROOT/VERSION ---
setup_repo
printf '2.0.0\n' > "$DEPUTY_ROOT/VERSION"
out="$(bash "$DEPUTY" release 2>&1)"; rc=$?
assert_eq "$rc" "0" "release with no arg uses VERSION file"
assert_contains "$out" "<!-- release v2.0.0 — $today -->" "default version read from ./VERSION"

# --- malformed VERSION file (internal whitespace) is rejected, not squashed ---
setup_repo
printf '1.0 beta\n' > "$DEPUTY_ROOT/VERSION"
bash "$DEPUTY" release >/dev/null 2>&1; assert_eq "$?" "2" "VERSION with internal whitespace rejected (not squashed)"
assert_eq "$(grep -cE '^<!-- release ' "$DEPUTY_ROOT/BACKLOG.md")" "0" "no delimiter written for malformed VERSION"

# --- error when no version and no VERSION file ---
setup_repo
out="$(bash "$DEPUTY" release 2>&1)"; rc=$?
assert_eq "$rc" "2" "release errors (exit 2) with no version and no VERSION file"
assert_contains "$out" "requires a clean version" "release prints a helpful error"

# --- malformed versions rejected (would break the HTML comment) ---
setup_repo
bash "$DEPUTY" release "1.0--beta" >/dev/null 2>&1; assert_eq "$?" "2" "version with '--' rejected"
bash "$DEPUTY" release "1 0"       >/dev/null 2>&1; assert_eq "$?" "2" "version with whitespace rejected"
bash "$DEPUTY" release "1<0>"      >/dev/null 2>&1; assert_eq "$?" "2" "version with angle brackets rejected"
# Count only real delimiters (line-start); the template legend mentions '<!-- release ... -->' mid-line.
assert_eq "$(grep -cE '^<!-- release ' "$DEPUTY_ROOT/BACKLOG.md")" "0" "no delimiter written for rejected versions"

# --- idempotent: re-releasing the same version+date is a no-op ---
setup_repo
bash "$DEPUTY" release 9.9.9 >/dev/null 2>&1
out="$(bash "$DEPUTY" release 9.9.9 2>&1)"; rc=$?
assert_eq "$rc" "0" "second release exits 0"
assert_contains "$out" "already present" "second release is a no-op"
assert_eq "$(grep -c '<!-- release v9.9.9 —' "$DEPUTY_ROOT/BACKLOG.md")" "1" "only one delimiter after re-release"

# --- a later completion lands ABOVE the release delimiter ---
setup_repo
bash "$DEPUTY" add "released work" --p0 >/dev/null
bash "$DEPUTY" list >/dev/null
bash "$DEPUTY" set "$(lof 'released work')" done >/dev/null
bash "$DEPUTY" release 1.0.0 >/dev/null 2>&1
bash "$DEPUTY" add "next-cycle work" --p1 >/dev/null
bash "$DEPUTY" set "$(lof 'next-cycle work')" done >/dev/null
dblk="$(block 'Done')"
new_n="$(printf '%s\n' "$dblk" | grep -n "next-cycle work" | head -1 | cut -d: -f1)"
del_n="$(printf '%s\n' "$dblk" | grep -n "release v1.0.0" | head -1 | cut -d: -f1)"
old_n="$(printf '%s\n' "$dblk" | grep -n "released work"  | head -1 | cut -d: -f1)"
assert_eq "$([[ "$new_n" -lt "$del_n" && "$del_n" -lt "$old_n" ]] && echo ok)" "ok" "new completion above delimiter; released work below"
