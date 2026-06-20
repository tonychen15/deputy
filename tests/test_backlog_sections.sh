#!/usr/bin/env bash
# Sectioned BACKLOG.md: markdown '###' section headers and '<!-- release ... -->'
# delimiter lines that live inside the items area must never be parsed as items
# (list/status) nor receive an ID/priority (_allocate_ids).
source "$(dirname "$0")/lib.sh"

# --- step 1: headers + delimiters are not items, not ID'd ---
setup_repo
bash "$DEPUTY" add "real item" --p1 >/dev/null
bash "$DEPUTY" list >/dev/null          # allocate the item's id first (so the
                                        # verification pass below makes no change
                                        # and thus triggers no regroup — isolates
                                        # step-1 parsing from step-2's regroup)
# Inject a future-structure header and a release delimiter after the real item.
{
  printf '\n### Running (1)\n'
  printf '<!-- release v9.9 — 2026-01-01 -->\n'
} >> "$DEPUTY_ROOT/BACKLOG.md"

# list() runs _allocate_ids; only the real item should be yielded.
out="$(bash "$DEPUTY" list 2>&1)"
assert_eq "$(printf '%s\n' "$out" | grep -c .)" "1"        "list yields exactly one item (header+delimiter ignored)"
assert_contains "$out" "real item"                          "the real item is listed"
assert_eq "$(printf '%s\n' "$out" | grep -c 'Running (1)')" "0" "section header not parsed as an item"
assert_eq "$(printf '%s\n' "$out" | grep -c 'release v9.9')" "0" "delimiter not parsed as an item"

# status counts must not miscount the header as a done item.
st="$(bash "$DEPUTY" status 2>&1)"
assert_contains "$st" "waiting:  1" "status counts the one waiting item"
assert_contains "$st" "done:     0" "status does not count the header as done"

# _allocate_ids (just run via list) must leave header + delimiter verbatim, untagged.
assert_eq "$(grep -c '^### Running (1)$' "$DEPUTY_ROOT/BACKLOG.md")" "1" "section header preserved verbatim"
assert_eq "$(grep -c '^<!-- release v9.9 — 2026-01-01 -->$' "$DEPUTY_ROOT/BACKLOG.md")" "1" "delimiter preserved verbatim"
assert_eq "$(grep -cE '^### Running.*\[#[0-9]+\]' "$DEPUTY_ROOT/BACKLOG.md")" "0" "header never received an [#N] id"
