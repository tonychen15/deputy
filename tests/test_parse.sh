#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

# A helper that calls the script's internal parser via an exposed subcommand.
parse() { bash "$DEPUTY" _parse "$1"; }

assert_eq "$(parse '[P0] Fix it')"        "waiting|P0|Fix it"      "waiting P0"
assert_eq "$(parse '@ [P1] Build it')"    "running|P1|Build it"    "running P1"
assert_eq "$(parse '# Done thing')"       "done||Done thing"       "done untagged"
assert_eq "$(parse '   Plain waiting')"   "waiting||Plain waiting" "left-trim untagged"
assert_eq "$(parse '? [P2] Ask me')"      "surfaced|P2|Ask me"     "surfaced P2"
assert_eq "$(parse '! Broke')"            "failed||Broke"          "failed untagged"
assert_eq "$(parse '@mention the user')"  "running||mention the user" "leading prefix is a status prefix"
assert_eq "$(parse '@')"                  "running||"               "bare prefix is a status"
assert_eq "$(parse '~ [P2]')"             "triaging|P2|"           "prefix + tag, empty description"

# list + legend-skip
printf '%s\n' '[P0] one' '~ [P1] two' '# three' >> "$DEPUTY_ROOT/BACKLOG.md"
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "waiting|P0|one"  "list: item one"
assert_contains "$out" "triaging|P1|two" "list: item two"
assert_contains "$out" "done||three"     "list: item three"
assert_eq "$(printf '%s\n' "$out" | grep -c 'LEGEND')" "0" "list: legend not parsed as item"

ser() { bash "$DEPUTY" _serialize "$1" "$2" "$3"; }
assert_eq "$(ser running P0 'Fix it')" "@[P0] Fix it" "serialize running P0"
assert_eq "$(ser waiting '' 'Plain')"  "Plain"         "serialize waiting untagged"
assert_eq "$(ser done '' 'Thing')"     "#Thing"        "serialize done untagged"
assert_eq "$(ser surfaced P2 'Ask')"   "?[P2] Ask"     "serialize surfaced P2"
