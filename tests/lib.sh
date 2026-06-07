# tests/lib.sh — dependency-free bash test harness.
# Each test file sources this, calls setup_repo, makes assertions, and exits
# via the EXIT trap which prints a summary and sets the exit code.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPUTY="$REPO/bin/deputy.sh"
TESTS_RUN=0
TESTS_FAILED=0

# Create an isolated temp repo with a fresh BACKLOG.md and point the runner at it.
setup_repo() {
  TMP="$(mktemp -d)"
  cp "$REPO/templates/BACKLOG.md" "$TMP/BACKLOG.md"
  export DEPUTY_ROOT="$TMP"
}

assert_eq() {  # assert_eq <actual> <expected> [msg]
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$1" != "$2" ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "${3:-}" "$2" "$1" >&2
  fi
}

assert_contains() {  # assert_contains <haystack> <needle> [msg]
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$1" != *"$2"* ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL: %s\n  [%s] does not contain [%s]\n' "${3:-}" "$1" "$2" >&2
  fi
}

_summarize() {
  printf '%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
  [[ "$TESTS_FAILED" -eq 0 ]]
}
trap _summarize EXIT
