#!/usr/bin/env bash
# Regression test for #73: deputy set/status work when the BACKLOG.md directory
# is read-only but BACKLOG.md itself is writable (bind-mount sandbox scenario).
# Requires running as a non-root user (root ignores chmod 555 on directories).
source "$(dirname "$0")/lib.sh"

setup_repo

# Verify this test can actually model the constraint; skip gracefully if not.
# Pre-check: ensure mktemp in the BACKLOG dir would fail after chmod 555.
test_dir="$DEPUTY_ROOT"
chmod 555 "$test_dir"
if mktemp "$test_dir/.probe.XXXXXX" 2>/dev/null; then
  # Either root or a filesystem that ignores dir permissions — cannot model the
  # bind-mount scenario; restore and skip.
  chmod 755 "$test_dir"
  printf 'SKIP: cannot enforce read-only directory (root or permissive fs)\n'
  exit 0
fi
# Restore write bit; re-apply 555 just before the actual test calls below.
chmod 755 "$test_dir"

# Add an item and allocate its id (run from writable dir first).
bash "$DEPUTY" add "ro-dir-test-item" >/dev/null
item_id="$(bash "$DEPUTY" list | grep 'ro-dir-test-item' | cut -d'|' -f3)"

# Now make the BACKLOG.md directory read-only while the file stays writable.
# STATE_DIR (.deputy/) remains writable (chmod 555 sets the parent dir perms,
# not the subdirectory's own perms — traversal requires only the execute bit).
chmod 644 "$test_dir/BACKLOG.md"
chmod 555 "$test_dir"
[[ -w "$test_dir/.deputy" ]] || { chmod 755 "$test_dir"; printf 'SKIP: STATE_DIR not writable after chmod 555\n'; exit 0; }

# deputy set must succeed even though the directory is read-only.
out="$(bash "$DEPUTY" set "$item_id" running 2>&1)"; rc=$?
chmod 755 "$test_dir"  # restore before any assert (which may inspect files)
assert_eq "$rc" "0" "deputy set succeeds with ro dir / rw BACKLOG.md"
assert_contains "$(bash "$DEPUTY" list)" "running" "item state changed to running"

# No temp files should be left in the read-only directory (they should have
# gone to STATE_DIR instead, or been cleaned up).
leftover="$(find "$test_dir" -maxdepth 1 -name '.backlog.tmp.*' -print 2>/dev/null || true)"
assert_eq "$leftover" "" "no temp files left in BACKLOG dir"
