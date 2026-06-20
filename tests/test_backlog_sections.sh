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

# Print the lines under the '### <name> (' section (until the next '### ').
block() { awk -v want="$1" '/^### /{inblk=($0 ~ "^### " want " \\(")} inblk && !/^### /{print}' "$DEPUTY_ROOT/BACKLOG.md"; }

# --- step 2: sectioned layout, order, mapping, counts, newest-on-top ---
setup_repo
bash "$DEPUTY" add "w-one"   --p0 >/dev/null   # waiting
bash "$DEPUTY" add "w-two"   --p2 >/dev/null   # waiting
bash "$DEPUTY" add "runner"  --p1 >/dev/null   # -> running
bash "$DEPUTY" add "trog"    --p2 >/dev/null   # -> triaging (maps to Surfaced)
bash "$DEPUTY" add "dupe-task" --p3 >/dev/null   # -> duplicate (maps to Failed/Cancelled/Duplicate)
bash "$DEPUTY" add "done-a"  --p0 >/dev/null   # -> done first
bash "$DEPUTY" add "done-b"  --p1 >/dev/null   # -> done second (newest)
bash "$DEPUTY" list >/dev/null
lof() { grep -F -- "$1" "$DEPUTY_ROOT/BACKLOG.md" | head -1; }
bash "$DEPUTY" set "$(lof 'runner')" running   >/dev/null
bash "$DEPUTY" set "$(lof 'trog')"   triaging  >/dev/null
bash "$DEPUTY" set "$(lof 'dupe-task')"    duplicate >/dev/null
bash "$DEPUTY" set "$(lof 'done-a')" done       >/dev/null
bash "$DEPUTY" set "$(lof 'done-b')" done       >/dev/null

# All seven section headers present, in the required order.
hdrs="$(grep -oE '^### [^(]+' "$DEPUTY_ROOT/BACKLOG.md" | sed 's/ *$//' | tr '\n' '|')"
assert_eq "$hdrs" "### Running|### Surfaced|### Waiting|### Paused|### Deferred|### Failed / Cancelled / Duplicate|### Done|" "all 7 section headers, in order"

# Counts in headers.
assert_contains "$(grep '^### Waiting' "$DEPUTY_ROOT/BACKLOG.md")"  "(2)" "Waiting count = 2"
assert_contains "$(grep '^### Running' "$DEPUTY_ROOT/BACKLOG.md")"  "(1)" "Running count = 1"
assert_contains "$(grep '^### Paused'  "$DEPUTY_ROOT/BACKLOG.md")"  "(0)" "empty Paused section still shows (0)"

# State mapping: triaging shows under Surfaced; duplicate under Failed/Cancelled/Duplicate.
assert_contains "$(block 'Surfaced')" "trog" "triaging item appears under Surfaced"
assert_contains "$(grep '^### Surfaced' "$DEPUTY_ROOT/BACKLOG.md")" "(1)" "Surfaced count includes the triaging item"
assert_contains "$(block 'Failed / Cancelled / Duplicate')" "dupe-task" "duplicate item appears under Failed/Cancelled/Duplicate"

# Newest completed sits at the TOP of Done.
dblk="$(block 'Done')"
apos="$(printf '%s\n' "$dblk" | grep -n 'done-a' | cut -d: -f1)"
bpos="$(printf '%s\n' "$dblk" | grep -n 'done-b' | cut -d: -f1)"
assert_eq "$([[ "$bpos" -lt "$apos" ]] && echo ok)" "ok" "newest completion (done-b) above earlier (done-a)"

# --- step 2: release delimiter preserved; new completion lands above it ---
setup_repo
bash "$DEPUTY" add "released item" --p0 >/dev/null
bash "$DEPUTY" add "fresh item"    --p1 >/dev/null
bash "$DEPUTY" list >/dev/null
bash "$DEPUTY" set "$(lof 'released item')" done >/dev/null
# Simulate a 'deputy release' delimiter at the top of Done.
delim='<!-- release v1.0 — 2026-01-01 -->'
awk -v d="$delim" '/^### Done /{print; print d; next} {print}' "$DEPUTY_ROOT/BACKLOG.md" > "$DEPUTY_ROOT/B.tmp" && mv "$DEPUTY_ROOT/B.tmp" "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" set "$(lof 'fresh item')" done >/dev/null
dblk="$(block 'Done')"
assert_contains "$dblk" "$delim" "release delimiter preserved across regroup"
fpos="$(printf '%s\n' "$dblk" | grep -n 'fresh item'   | cut -d: -f1)"
dpos="$(printf '%s\n' "$dblk" | grep -n 'release v1.0' | cut -d: -f1)"
rpos="$(printf '%s\n' "$dblk" | grep -n 'released item' | cut -d: -f1)"
assert_eq "$([[ "$fpos" -lt "$dpos" && "$dpos" -lt "$rpos" ]] && echo ok)" "ok" "new completion above delimiter; older release below it"
assert_contains "$(grep '^### Done' "$DEPUTY_ROOT/BACKLOG.md")" "(2)" "Done count = 2 items (delimiter excluded)"
