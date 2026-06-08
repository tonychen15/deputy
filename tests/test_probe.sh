#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
# Suppress the PATH self-fix so mock CLIs in $BIN aren't shadowed by real ones.
export DEPUTY_NO_PATH_FIX=1

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

# absent: probe a name that is guaranteed not on PATH (robust even if a real
# claude/gemini/codex is installed on the system).
assert_eq "$(PATH="$BIN:$PATH" bash "$DEPUTY" probe zzz_not_a_real_cli)" "absent" "probe absent"

rm -rf "$BIN"
