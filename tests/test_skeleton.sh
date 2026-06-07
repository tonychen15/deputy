#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

# Unknown command exits non-zero with usage on stderr.
out="$(bash "$DEPUTY" bogus 2>&1)"; rc=$?
assert_eq "$rc" "2" "unknown command exits 2"
assert_contains "$out" "usage" "unknown command prints usage"

# `help` exits 0 and lists commands.
out="$(bash "$DEPUTY" help 2>&1)"; rc=$?
assert_eq "$rc" "0" "help exits 0"
assert_contains "$out" "status" "help lists status"

# State dir is created on demand.
bash "$DEPUTY" help >/dev/null 2>&1
[[ -d "$DEPUTY_ROOT/.deputy" ]] && r=yes || r=no
assert_eq "$r" "yes" ".deputy state dir created"
