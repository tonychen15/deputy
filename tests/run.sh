#!/usr/bin/env bash
# Runs every tests/test_*.sh in its own bash process; aggregates results.
cd "$(dirname "$0")/.."
fail=0
for f in tests/test_*.sh; do
  echo "== $f =="
  bash "$f" || fail=1
done
exit "$fail"
