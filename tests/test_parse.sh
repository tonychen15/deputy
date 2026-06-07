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
assert_eq "$(parse '@mention the user')"  "waiting||@mention the user" "no-space prefix is text"
assert_eq "$(parse '@')"                  "waiting||@"             "bare prefix no space is text"
assert_eq "$(parse '~ [P2]')"             "triaging|P2|"           "prefix + tag, empty description"
