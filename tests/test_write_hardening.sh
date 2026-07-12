#!/usr/bin/env bash
# Failure-injection tests for hardened BACKLOG write paths (#47).
# Verifies that mktemp failure and mv failure surface as non-zero CLI exit and
# leave BACKLOG.md unchanged for paths where || return 1 guards propagate.
#
# deputy add IS covered now: _do_add does '_allocate_ids || return 1' and
# _append_item routes through the single-commit _regroup_backlog, so a write
# failure surfaces as a non-zero exit and leaves BACKLOG.md unchanged with no
# partially-added item (the one-transaction guarantee).
#
# mktemp failure is injected via a fake mktemp binary prepended to PATH
# (not chmod) so the tests run correctly even as root.
source "$(dirname "$0")/lib.sh"

# ── setup: fake tool directories ─────────────────────────────────────────────

PATH_ORIG="$PATH"

FAKE_MKTEMP_BIN="$(mktemp -d)" || exit 1
FAKE_MV_BIN="$(mktemp -d)" || exit 1

printf '#!/bin/bash\nexit 1\n' > "$FAKE_MKTEMP_BIN/mktemp"
chmod +x "$FAKE_MKTEMP_BIN/mktemp"
printf '#!/bin/bash\nexit 1\n' > "$FAKE_MV_BIN/mv"
chmod +x "$FAKE_MV_BIN/mv"

item_id_of() {
  line_id "$(bash "$DEPUTY" list 2>/dev/null | grep -F "$1")"
}

# ── mktemp failure tests (fake mktemp in PATH) ────────────────────────────────

# deputy set → _flip_line: mktemp || return 1 fires; _do_set returns exit code.
setup_repo
printf '%s\n' '[P1] set-mktemp-fail' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null
item="$(grep 'set-mktemp-fail' "$DEPUTY_ROOT/BACKLOG.md")"
before="$(cat "$DEPUTY_ROOT/BACKLOG.md")"

export PATH="$FAKE_MKTEMP_BIN:$PATH_ORIG"
rc=0; bash "$DEPUTY" set "$item" done 2>/dev/null || rc=$?
export PATH="$PATH_ORIG"
assert_eq "$rc" "1" "set: mktemp failure → non-zero exit"
assert_eq "$(cat "$DEPUTY_ROOT/BACKLOG.md")" "$before" "set: mktemp failure → BACKLOG unchanged"

# deputy clean (bulk) → _do_clean: mktemp || return 1 fires; _with_lock rc captured.
setup_repo
printf '%s\n' '[P1] bulk-clean-mktemp-a' '[P2] bulk-clean-mktemp-b' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null
before="$(cat "$DEPUTY_ROOT/BACKLOG.md")"

export PATH="$FAKE_MKTEMP_BIN:$PATH_ORIG"
rc=0; bash "$DEPUTY" clean --state waiting 2>/dev/null || rc=$?
export PATH="$PATH_ORIG"
assert_eq "$rc" "1" "clean (bulk): mktemp failure → non-zero exit"
assert_eq "$(cat "$DEPUTY_ROOT/BACKLOG.md")" "$before" "clean (bulk): mktemp failure → BACKLOG unchanged"

# deputy clean <id> → _allocate_ids: mktemp || return 1 fires; _cid_alloc_rc guard returns 1.
setup_repo
printf '%s\n' '[P1] id-clean-mktemp' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null
iid="$(item_id_of 'id-clean-mktemp')"
before="$(cat "$DEPUTY_ROOT/BACKLOG.md")"

export PATH="$FAKE_MKTEMP_BIN:$PATH_ORIG"
rc=0; bash "$DEPUTY" clean "$iid" 2>/dev/null || rc=$?
export PATH="$PATH_ORIG"
assert_eq "$rc" "1" "clean (ID): mktemp failure → non-zero exit"
assert_eq "$(cat "$DEPUTY_ROOT/BACKLOG.md")" "$before" "clean (ID): mktemp failure → BACKLOG unchanged"

# ── mv failure tests (fake mv in PATH) ───────────────────────────────────────

# deputy set → _flip_line: [[ -s tmp ]] passes, mv || return 1 fires; tmp cleaned up.
setup_repo
printf '%s\n' '[P1] set-mv-fail' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null
item="$(grep 'set-mv-fail' "$DEPUTY_ROOT/BACKLOG.md")"
before="$(cat "$DEPUTY_ROOT/BACKLOG.md")"

export PATH="$FAKE_MV_BIN:$PATH_ORIG"
rc=0; bash "$DEPUTY" set "$item" done 2>/dev/null || rc=$?
export PATH="$PATH_ORIG"
assert_eq "$rc" "1" "set: mv failure → non-zero exit"
assert_eq "$(cat "$DEPUTY_ROOT/BACKLOG.md")" "$before" "set: mv failure → BACKLOG unchanged"
assert_eq "$(ls "$DEPUTY_ROOT"/.backlog.tmp.* 2>/dev/null | wc -l | tr -d ' ')" "0" "set: mv failure → no tmp leak"

# deputy clean (bulk) → _do_clean: [[ -s tmp ]] passes, mv || return 1 fires; tmp cleaned up.
setup_repo
printf '%s\n' '[P1] bulk-mv-fail-a' '[P2] bulk-mv-fail-b' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null
before="$(cat "$DEPUTY_ROOT/BACKLOG.md")"

export PATH="$FAKE_MV_BIN:$PATH_ORIG"
rc=0; bash "$DEPUTY" clean --state waiting 2>/dev/null || rc=$?
export PATH="$PATH_ORIG"
assert_eq "$rc" "1" "clean (bulk): mv failure → non-zero exit"
assert_eq "$(cat "$DEPUTY_ROOT/BACKLOG.md")" "$before" "clean (bulk): mv failure → BACKLOG unchanged"
assert_eq "$(ls "$DEPUTY_ROOT"/.backlog.tmp.* 2>/dev/null | wc -l | tr -d ' ')" "0" "clean (bulk): mv failure → no tmp leak"

# deputy clean <id> → _do_clean_id: IDs pre-allocated so _allocate_ids takes no-mv path;
# then _do_clean_id's mv || return 1 fires; tmp cleaned up.
setup_repo
printf '%s\n' '[P1] id-mv-fail' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null   # pre-allocate IDs so _allocate_ids changed=0 (no mv call)
iid="$(item_id_of 'id-mv-fail')"
before="$(cat "$DEPUTY_ROOT/BACKLOG.md")"

export PATH="$FAKE_MV_BIN:$PATH_ORIG"
rc=0; bash "$DEPUTY" clean "$iid" 2>/dev/null || rc=$?
export PATH="$PATH_ORIG"
assert_eq "$rc" "1" "clean (ID): mv failure → non-zero exit"
assert_eq "$(cat "$DEPUTY_ROOT/BACKLOG.md")" "$before" "clean (ID): mv failure → BACKLOG unchanged"
assert_eq "$(ls "$DEPUTY_ROOT"/.backlog.tmp.* 2>/dev/null | wc -l | tr -d ' ')" "0" "clean (ID): mv failure → no tmp leak"

# ── add: single-transaction atomicity (now that _do_add propagates rc) ────────

# add → mktemp failure: _allocate_ids 'mktemp || return 1' fires before any append,
# so _do_add returns non-zero and nothing is added.
setup_repo
before="$(cat "$DEPUTY_ROOT/BACKLOG.md")"
export PATH="$FAKE_MKTEMP_BIN:$PATH_ORIG"
rc=0; DEPUTY_NO_AUTORUN=1 bash "$DEPUTY" add "add-mktemp-fail" 2>/dev/null || rc=$?
export PATH="$PATH_ORIG"
assert_eq "$rc" "1" "add: mktemp failure → non-zero exit"
assert_eq "$(cat "$DEPUTY_ROOT/BACKLOG.md")" "$before" "add: mktemp failure → BACKLOG unchanged"
assert_eq "$(bash "$DEPUTY" list 2>/dev/null | grep -c 'add-mktemp-fail')" "0" "add: mktemp failure → item not added"

# add → mv (commit) failure: _append_item's single-commit regroup hits 'mv || return 1'.
# One transaction: BACKLOG stays exactly as before — no partial/unsorted item lands.
setup_repo
before="$(cat "$DEPUTY_ROOT/BACKLOG.md")"
export PATH="$FAKE_MV_BIN:$PATH_ORIG"
rc=0; DEPUTY_NO_AUTORUN=1 bash "$DEPUTY" add "add-mv-fail" 2>/dev/null || rc=$?
export PATH="$PATH_ORIG"
assert_eq "$rc" "1" "add: mv failure → non-zero exit"
assert_eq "$(cat "$DEPUTY_ROOT/BACKLOG.md")" "$before" "add: mv failure → BACKLOG unchanged (single transaction)"
assert_eq "$(bash "$DEPUTY" list 2>/dev/null | grep -c 'add-mv-fail')" "0" "add: mv failure → no partial item committed"
assert_eq "$(ls "$DEPUTY_ROOT"/.backlog.tmp.* 2>/dev/null | wc -l | tr -d ' ')" "0" "add: mv failure → no tmp leak"

# ── legacy-format source (no '## Items' header): mutation persists verbatim ────
# _regroup_backlog, handed a staged temp with no '## Items', commits it as-is so a
# mutation on a legacy/pre-sections BACKLOG.md is never silently dropped.
setup_repo
printf '%s\n' '# Legacy Backlog' '' '[P1] legacy-existing' > "$DEPUTY_ROOT/BACKLOG.md"
rc=0; DEPUTY_NO_AUTORUN=1 bash "$DEPUTY" add "legacy-added-item" 2>/dev/null || rc=$?
assert_eq "$rc" "0" "add (legacy format): succeeds"
assert_contains "$(cat "$DEPUTY_ROOT/BACKLOG.md")" "legacy-added-item" "add (legacy format): new item persisted"
assert_contains "$(cat "$DEPUTY_ROOT/BACKLOG.md")" "legacy-existing"   "add (legacy format): existing item preserved"

# ── teardown ──────────────────────────────────────────────────────────────────
rm -rf "$FAKE_MKTEMP_BIN" "$FAKE_MV_BIN"
