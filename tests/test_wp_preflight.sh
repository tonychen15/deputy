#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
# A spine verb completes cleanly when jq is present. Use && (not ;) so a bash
# syntax error / crash in the verb fails the assertion instead of passing.
out="$(bash "$DEPUTY" start p2 "g" && echo OK)"
assert_contains "$out" "OK" "start completes cleanly (jq present)"
assert_eq "$([[ -f "$DEPUTY_ROOT/.deputy/waypoints/p2/waypoint.json" ]] && echo yes || echo no)" "yes" "ledger written"
# inst_deputy.sh carries a jq preflight line.
assert_eq "$([[ "$(grep -c 'jq' "$REPO/inst_deputy.sh")" -ge 1 ]] && echo yes || echo no)" "yes" "inst_deputy.sh references jq preflight"
