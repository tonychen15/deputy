#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
mkdir -p "$DEPUTY_ROOT/.deputy"
printf 'test_cmd=make test\nmax_items=3\n# comment\n\n' > "$DEPUTY_ROOT/.deputy/config"
printf '.env*\nsecrets/**\n' > "$DEPUTY_ROOT/.deputy/protected"

assert_eq "$(bash "$DEPUTY" config test_cmd)"  "make test" "config reads test_cmd"
assert_eq "$(bash "$DEPUTY" config max_items)" "3"         "config reads max_items"
assert_eq "$(bash "$DEPUTY" config missing)"   ""          "config missing key empty"

bash "$DEPUTY" protected ".env.local"; assert_eq "$?" "0" "protected matches .env.local"
bash "$DEPUTY" protected "secrets/key.pem"; assert_eq "$?" "0" "protected matches secrets glob"
bash "$DEPUTY" protected "src/main.py"; assert_eq "$?" "1" "protected allows normal path"
# Read paths from a file (not a pipe) so assert_eq runs in the main shell and is counted.
printf 'src/a.py\nsecrets/b\n' > "$DEPUTY_ROOT/paths.txt"
bash "$DEPUTY" protected --stdin < "$DEPUTY_ROOT/paths.txt"; assert_eq "$?" "0" "protected detects in a list"
