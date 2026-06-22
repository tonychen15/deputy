#!/usr/bin/env bash
# Failure-injection tests for hardened BACKLOG write paths (#47).
# Verifies that mktemp failure and mv failure surface as non-zero CLI exit and
# leave BACKLOG.md unchanged for paths where || return 1 guards propagate.
#
# deputy add is NOT tested here: _do_add calls _allocate_ids without a rc
# check, and set -e is suppressed by the surrounding || context, so write
# failures in _do_add do not surface as a non-zero exit. That is the
# transactional-consistency gap explicitly scoped out of #47.
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
  bash "$DEPUTY" list 2>/dev/null | grep -F "$1" | grep -oE '\|[0-9]+\|' | head -1 | tr -d '|'
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

# ── teardown ──────────────────────────────────────────────────────────────────
rm -rf "$FAKE_MKTEMP_BIN" "$FAKE_MV_BIN"
