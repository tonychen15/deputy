#!/usr/bin/env bash
# tests/test_test_changed.sh — #109: 'deputy test --changed' affected-test selection.
# Builds a temp repo shaped like a deputy project (bin/deputy.sh with named functions, tests/,
# a test-map) and runs the REAL deputy's _affected_tests against it via DEPUTY_ROOT.
source "$(dirname "$0")/lib.sh"

mk() {   # fresh temp repo → sets R
  R="$(mktemp -d)"; mkdir -p "$R/bin" "$R/tests"
  cat > "$R/bin/deputy.sh" <<'SH'
#!/usr/bin/env bash
cmd_foo() {
  echo foo
  echo foo2
}
cmd_bar() {
  echo bar
}
_helper() {
  echo help
}
cmd_baz() {
  echo baz
}
top_level_var=1
SH
  : > "$R/tests/test_foo.sh"; : > "$R/tests/test_bar.sh"
  printf '_helper: test_bar\n' > "$R/tests/test-map"
  printf '.deputy/\n' > "$R/.gitignore"   # as deputy init does — .deputy runtime state is gitignored
  git -C "$R" init -q; git -C "$R" config user.email t@t; git -C "$R" config user.name t
  git -C "$R" add -A; git -C "$R" commit -q -m init
}
AFF() { ( export DEPUTY_ROOT="$R"; source "$DEPUTY"; _affected_tests ); }

# 1. change inside cmd_foo → cmd_<X>→test_<X> convention
mk; sed -i 's/echo foo2/echo foo2 x/' "$R/bin/deputy.sh"
assert_eq "$(AFF)" "test_foo" "cmd_foo change → test_foo (convention)"

# 2. change inside _helper → test-map manifest
mk; sed -i 's/echo help/echo help x/' "$R/bin/deputy.sh"
assert_eq "$(AFF)" "test_bar" "_helper change → test_bar (manifest)"

# 3. change inside cmd_baz (no test_baz, not mapped) → FULL (fail-safe)
mk; sed -i 's/echo baz/echo baz x/' "$R/bin/deputy.sh"
assert_eq "$(AFF)" "FULL" "unmapped function → FULL"

# 4. top-level change (after a function's closing brace) → FULL
mk; sed -i 's/top_level_var=1/top_level_var=2/' "$R/bin/deputy.sh"
assert_eq "$(AFF)" "FULL" "top-level change → FULL"

# 5. a changed test file → run itself
mk; echo "# edit" >> "$R/tests/test_foo.sh"
assert_eq "$(AFF)" "test_foo" "changed test file → itself"

# 6. two mapped changes → union, deduped/sorted
mk; sed -i 's/echo foo2/echo foo2 x/; s/echo help/echo help x/' "$R/bin/deputy.sh"
assert_eq "$(AFF)" "test_bar test_foo" "two mapped changes → sorted union"

# 7. an unknown non-doc file → FULL
mk; echo "print()" > "$R/foo.py"; git -C "$R" add foo.py
assert_eq "$(AFF)" "FULL" "unknown file → FULL"

# 8. docs-only change → no affected tests (empty)
mk; echo "readme" > "$R/README.md"; git -C "$R" add README.md
assert_eq "$(AFF)" "" "docs-only change → no affected tests"

# 9. harness change (tests/test-map) → FULL
mk; echo "cmd_baz: test_bar" >> "$R/tests/test-map"
assert_eq "$(AFF)" "FULL" "test-map change → FULL"

# 10. deletion-only hunk (remove a whole function) → FULL (can't map a removed function)
mk; perl -0pi -e 's/cmd_bar\(\) \{\n  echo bar\n\}\n//' "$R/bin/deputy.sh"
assert_eq "$(AFF)" "FULL" "deletion-only hunk → FULL"

# 11. both staged AND unstaged bin/deputy.sh edits → FULL (staged line numbers shift)
mk
sed -i 's/echo foo2/echo foo2 STAGED/' "$R/bin/deputy.sh"; git -C "$R" add bin/deputy.sh
sed -i 's/echo bar/echo bar UNSTAGED/' "$R/bin/deputy.sh"
assert_eq "$(AFF)" "FULL" "both staged + unstaged bin/deputy.sh → FULL"

# 12. VERSION change → version/release tests (never silently skipped)
mk; printf '1.0.0\n' > "$R/VERSION"; git -C "$R" add VERSION
assert_eq "$(AFF)" "test_release test_release_notes test_version" "VERSION change → version/release tests"

# 13. an UNTRACKED unknown source file is seen → FULL (not silently ignored)
mk; echo "x" > "$R/newthing.conf"
assert_eq "$(AFF)" "FULL" "untracked unknown file → FULL"

# 14. an UNTRACKED new test file → run itself
mk; : > "$R/tests/test_new.sh"
assert_eq "$(AFF)" "test_new" "untracked new test file → itself"
