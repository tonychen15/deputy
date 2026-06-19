#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

want="deputy $(tr -d '[:space:]' < "$REPO/VERSION")"

assert_eq "$(bash "$DEPUTY" version)"    "$want" "version subcommand prints 'deputy <VERSION>'"
assert_eq "$(bash "$DEPUTY" --version)"  "$want" "--version alias"
assert_eq "$(bash "$DEPUTY" -V)"         "$want" "-V alias"

# symlink-safe: invoke deputy THROUGH a symlink from an unrelated dir and assert it
# still resolves VERSION via SRC_DIR (readlink -f of the script), not cwd.
linkdir="$(mktemp -d)"
ln -s "$DEPUTY" "$linkdir/deputy"
assert_eq "$(cd "$linkdir" && ./deputy version)" "$want" "version resolves VERSION through a PATH symlink"
rm -rf "$linkdir"

# missing VERSION file -> error exit
out="$(SRC_DIR=/nonexistent bash "$DEPUTY" version 2>&1; echo "rc=$?")"
assert_contains "$out" "version unknown" "missing VERSION reports clearly"
assert_contains "$out" "rc=1" "missing VERSION exits non-zero"
