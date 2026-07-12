#!/usr/bin/env bash
# tests/test_torn_write_recovery.sh — #94: torn BACKLOG detection and .bak restore.
source "$(dirname "$0")/lib.sh"

_make_valid_backlog() {
  # Minimal valid BACKLOG.md content for use as a .bak restore candidate.
  printf '# Deputy Backlog\n\n## Items\n\n[P1] restored item\n'
}

# ── A) Empty BACKLOG + valid .bak → restored ──────────────────────────────────
setup_repo
_make_valid_backlog > "$DEPUTY_ROOT/.backlog.tmp.abc123.bak"
> "$DEPUTY_ROOT/BACKLOG.md"  # truncate to empty (torn state)
bash "$DEPUTY" recover >/dev/null 2>&1
out="$(cat "$DEPUTY_ROOT/BACKLOG.md")"
assert_contains "$out" "## Items" "empty torn: BACKLOG restored from .bak"
assert_contains "$out" "restored item" "empty torn: restored item present"
[[ -f "$DEPUTY_ROOT/.backlog.tmp.abc123.bak" ]] && r=yes || r=no
assert_eq "$r" "no" "empty torn: .bak cleaned up after restore"

# ── B) BACKLOG missing '## Items' header + valid .bak → restored ──────────────
setup_repo
_make_valid_backlog > "$DEPUTY_ROOT/.backlog.tmp.def456.bak"
printf '# Deputy Backlog\n\nno sections here\n' > "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" recover >/dev/null 2>&1
out="$(cat "$DEPUTY_ROOT/BACKLOG.md")"
assert_contains "$out" "## Items" "no-header torn: BACKLOG restored from .bak"
assert_contains "$out" "restored item" "no-header torn: restored item present"
[[ -f "$DEPUTY_ROOT/.backlog.tmp.def456.bak" ]] && r=yes || r=no
assert_eq "$r" "no" "no-header torn: .bak cleaned up after restore"

# ── C) Healthy BACKLOG + stale .bak → .bak cleaned up, BACKLOG unchanged ─────
setup_repo
stale_bak="$DEPUTY_ROOT/.backlog.tmp.stale1.bak"
stale_tmp="$DEPUTY_ROOT/.backlog.tmp.stale1"
_make_valid_backlog > "$stale_bak"
printf 'stale tmp content\n' > "$stale_tmp"
original="$(cat "$DEPUTY_ROOT/BACKLOG.md")"
bash "$DEPUTY" recover >/dev/null 2>&1
assert_eq "$(cat "$DEPUTY_ROOT/BACKLOG.md")" "$original" "healthy: BACKLOG unchanged"
[[ -f "$stale_bak" ]] && r=yes || r=no
assert_eq "$r" "no" "healthy: stale .bak removed"
[[ -f "$stale_tmp" ]] && r=yes || r=no
assert_eq "$r" "no" "healthy: stale paired .tmp removed"

# ── D) Torn BACKLOG + invalid .bak (no ## Items) → warning, no crash ─────────
setup_repo
printf 'corrupt content without header\n' > "$DEPUTY_ROOT/.backlog.tmp.bad1.bak"
> "$DEPUTY_ROOT/BACKLOG.md"  # torn
rc=0; bash "$DEPUTY" recover 2>/dev/null || rc=$?
# Should not crash (rc from recover is 0 since torn-backlog recovery is best-effort).
assert_eq "$rc" "0" "invalid .bak: recover exits cleanly"
# The invalid .bak should be cleaned up since it was not selected for restore.
[[ -f "$DEPUTY_ROOT/.backlog.tmp.bad1.bak" ]] && r=yes || r=no
assert_eq "$r" "no" "invalid .bak: cleaned up"

# ── E) Torn BACKLOG + no .bak → warning, no crash ────────────────────────────
setup_repo
> "$DEPUTY_ROOT/BACKLOG.md"  # torn
rc=0; bash "$DEPUTY" recover 2>/dev/null || rc=$?
assert_eq "$rc" "0" "no .bak: recover exits cleanly"

# ── F) Multiple .bak files → most-recent (by mtime) picked ───────────────────
setup_repo
bak_old="$DEPUTY_ROOT/.backlog.tmp.old1.bak"
bak_new="$DEPUTY_ROOT/.backlog.tmp.new1.bak"
_make_valid_backlog > "$bak_old"
sleep 1  # ensure different mtime
printf '# Deputy Backlog\n\n## Items\n\n[P1] newer item\n' > "$bak_new"
> "$DEPUTY_ROOT/BACKLOG.md"  # torn
bash "$DEPUTY" recover >/dev/null 2>&1
out="$(cat "$DEPUTY_ROOT/BACKLOG.md")"
assert_contains "$out" "newer item" "multiple .bak: most-recent picked"
[[ -f "$bak_old" ]] && r=yes || r=no
assert_eq "$r" "no" "multiple .bak: older .bak cleaned up"
[[ -f "$bak_new" ]] && r=yes || r=no
assert_eq "$r" "no" "multiple .bak: selected .bak cleaned up after restore"

# ── G) STATE_DIR .bak (deduplication: STATE_DIR != BACKLOG dir) ───────────────
setup_repo
# Write a .bak in STATE_DIR (.deputy/) rather than the BACKLOG dir (root).
_make_valid_backlog > "$DEPUTY_ROOT/.deputy/.backlog.tmp.statedr.bak"
> "$DEPUTY_ROOT/BACKLOG.md"  # torn
bash "$DEPUTY" recover >/dev/null 2>&1
out="$(cat "$DEPUTY_ROOT/BACKLOG.md")"
assert_contains "$out" "## Items" "state_dir .bak: restored from STATE_DIR .bak"
[[ -f "$DEPUTY_ROOT/.deputy/.backlog.tmp.statedr.bak" ]] && r=yes || r=no
assert_eq "$r" "no" "state_dir .bak: .bak cleaned up"
