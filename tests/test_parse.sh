#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

# A helper that calls the script's internal parser via an exposed subcommand.
parse() { bash "$DEPUTY" _parse "$1"; }

assert_eq "$(parse '[P0] Fix it')"        "waiting|P0||Fix it"      "waiting P0"
assert_eq "$(parse '@ [P1] Build it')"    "running|P1||Build it"    "running P1"
assert_eq "$(parse '# Done thing')"       "done|||Done thing"       "done untagged"
assert_eq "$(parse '   Plain waiting')"   "waiting|||Plain waiting" "left-trim untagged"
assert_eq "$(parse '? [P2] Ask me')"      "surfaced|P2||Ask me"     "surfaced P2"
assert_eq "$(parse '! Broke')"            "failed|||Broke"          "failed untagged"
assert_eq "$(parse '@mention the user')"  "running|||mention the user" "leading prefix is a status prefix"
assert_eq "$(parse '@')"                  "running|||"               "bare prefix is a status"
assert_eq "$(parse '~ [P2]')"             "triaging|P2||"           "prefix + tag, empty description"
assert_eq "$(parse '% Dropped')"          "cancelled|||Dropped"     "cancelled untagged"
assert_eq "$(parse '%[P1] Skip this')"    "cancelled|P1||Skip this" "cancelled P1"
assert_eq "$(parse '= Dup of #3')"        "duplicate|||Dup of #3"   "duplicate untagged"
assert_eq "$(parse '=[P0] Same as X')"    "duplicate|P0||Same as X" "duplicate P0"
assert_eq "$(parse '^ Interrupted')"      "paused|||Interrupted"    "paused untagged"
assert_eq "$(parse '^[P1] Paused job')"   "paused|P1||Paused job"   "paused P1"
assert_eq "$(parse '[P3] Low prio')"      "waiting|P3||Low prio"    "waiting P3"
assert_eq "$(parse '[P4] Lowest prio')"   "waiting|P4||Lowest prio" "waiting P4"

# list + legend-skip
printf '%s\n' '[P0] one' '~ [P1] two' '# three' >> "$DEPUTY_ROOT/BACKLOG.md"
out="$(bash "$DEPUTY" list)"
assert_contains "$out" "waiting|P0|" "list: item one state+prio"
assert_contains "$out" "|one"        "list: item one description"
assert_contains "$out" "triaging|P1|" "list: item two state+prio"
assert_contains "$out" "|two"         "list: item two description"
assert_contains "$out" "done|P4|"    "list: item three gets P4 default"
assert_contains "$out" "|three"      "list: item three description"
assert_eq "$(printf '%s\n' "$out" | grep -c 'LEGEND')" "0" "list: legend not parsed as item"

# _serialize subcommand now takes 4 args: state priority id description
ser() { bash "$DEPUTY" _serialize "$1" "$2" "$3" "$4"; }
assert_eq "$(ser running P0 '' 'Fix it')"       "@[P0] Fix it"     "serialize running P0"
assert_eq "$(ser waiting '' '' 'Plain')"         "Plain"             "serialize waiting untagged"
assert_eq "$(ser done '' '' 'Thing')"            "#Thing"            "serialize done untagged"
assert_eq "$(ser surfaced P2 '' 'Ask')"          "?[P2] Ask"         "serialize surfaced P2"
assert_eq "$(ser cancelled P1 '' 'Skip this')"   "%[P1] Skip this"  "serialize cancelled P1"
assert_eq "$(ser cancelled '' '' 'Dropped')"     "%Dropped"          "serialize cancelled untagged"
assert_eq "$(ser duplicate P0 '' 'Same as X')"   "=[P0] Same as X"  "serialize duplicate P0"
assert_eq "$(ser duplicate '' '' 'Dup of #3')"   "=Dup of #3"        "serialize duplicate untagged"
assert_eq "$(ser paused P0 '' 'Halted')"         "^[P0] Halted"      "serialize paused P0"
assert_eq "$(ser paused '' '' 'Bare halt')"      "^Bare halt"         "serialize paused untagged"
