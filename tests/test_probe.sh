#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

# Build a fake PATH dir holding mock CLIs.
BIN="$(mktemp -d)"
mk() {  # mk <name> <exit_code> <stdout-text>
  printf '#!/usr/bin/env bash\necho %q\nexit %s\n' "$3" "$2" > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# claude healthy
mk claude 0 "pong"
assert_eq "$(PATH="$BIN:$PATH" bash "$DEPUTY" probe claude)" "ok" "probe ok"

# gemini quota-limited
mk gemini 1 "Error: RESOURCE_EXHAUSTED"
assert_eq "$(PATH="$BIN:$PATH" bash "$DEPUTY" probe gemini)" "quota_exhausted" "probe quota"

# codex absent (remove it)
rm -f "$BIN/codex"
assert_eq "$(PATH="$BIN:$PATH" bash "$DEPUTY" probe codex)" "absent" "probe absent"

rm -rf "$BIN"
