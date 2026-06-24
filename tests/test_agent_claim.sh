#!/usr/bin/env bash
# #67: agent-shaped claim liveness — `deputy claim --agent`, heartbeat-TTL liveness,
# and recover awareness (a fresh agent claim survives recover; an expired one is reaped).
source "$(dirname "$0")/lib.sh"

claimfile() { ls "$DEPUTY_ROOT"/.deputy/*.claim 2>/dev/null | head -1; }
# liveness as seen by the cron guard (source deputy in a fresh shell; main is sourced-guarded)
live() {
  if DEPUTY_ROOT="$DEPUTY_ROOT" bash -c 'source "'"$DEPUTY"'"; _live_claim_exists' >/dev/null 2>&1; then
    echo live; else echo dead; fi
}

# ── claim --agent writes a 4-line agent claim and runs the item ──────────────────
setup_repo
printf '%s\n' '[P1] agent work' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null                                  # allocate id
line="$(grep -F 'agent work' "$DEPUTY_ROOT/BACKLOG.md" | head -1)"
( bash "$DEPUTY" claim --agent "$line" >/dev/null 2>&1 )         # subshell: the claiming PID dies
cf="$(claimfile)"
assert_eq "$([ -n "$cf" ] && echo yes || echo no)" "yes"        "claim --agent creates a claim file"
assert_eq "$(sed -n '3p' "$cf" 2>/dev/null)" "agent"            "claim --agent: owner on line 3"
assert_eq "$([[ "$(sed -n '4p' "$cf" 2>/dev/null)" =~ ^[0-9]+$ ]] && echo yes || echo no)" "yes" \
                                                                "claim --agent: heartbeat epoch on line 4"
assert_contains "$(bash "$DEPUTY" list)" "running|P1|"          "claim --agent: item transitioned to running"

# ── live despite a dead claiming PID (fresh heartbeat) ───────────────────────────
assert_eq "$(live)" "live" "agent claim is live via fresh heartbeat despite a dead PID"

# ── recover leaves a FRESH agent claim alone (the #67 cmd_recover TTL fix) ────────
bash "$DEPUTY" recover >/dev/null 2>&1
assert_contains "$(bash "$DEPUTY" list)" "running|P1|"          "recover: fresh agent claim NOT reverted"
assert_eq "$([ -n "$(claimfile)" ] && echo yes || echo no)" "yes" "recover: fresh agent claim file kept"

# ── expire the heartbeat → not live, and recover reverts + reaps ─────────────────
cf="$(claimfile)"; awk 'NR==4{print "1"} NR!=4{print}' "$cf" > "$cf.t"; mv "$cf.t" "$cf"
assert_eq "$(live)" "dead" "agent claim EXPIRES once heartbeat is stale (> 2x heartbeat_mins)"
bash "$DEPUTY" recover >/dev/null 2>&1
assert_contains "$(bash "$DEPUTY" list)" "waiting|P1|"          "recover: expired agent claim reverted to waiting"
assert_eq "$([ -z "$(claimfile)" ] && echo yes || echo no)" "yes" "recover: expired agent claim file reaped"

# ── regression: a non-agent (worker) claim stays PID-based, no heartbeat TTL ──────
setup_repo
printf '%s\n' '[P2] worker work' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null
wline="$(grep -F 'worker work' "$DEPUTY_ROOT/BACKLOG.md" | head -1)"
bash "$DEPUTY" claim --pid 999999 "$wline" >/dev/null 2>&1       # owner=run, dead pid
assert_eq "$(live)" "dead" "non-agent claim with a dead PID is NOT live (PID-based, unchanged)"

# ── agent release: setting the claimed item out of running drops claim + active-run ──
# (the claim + this 'set' run as children of the same test shell, so both see the same
#  $PPID — exactly the orchestrator-then-spine-verb relationship in real use.)
setup_repo
printf '%s\n' '[P1] agent done-release' >> "$DEPUTY_ROOT/BACKLOG.md"
bash "$DEPUTY" list >/dev/null
wait_line="$(grep -F 'agent done-release' "$DEPUTY_ROOT/BACKLOG.md" | head -1)"
bash "$DEPUTY" claim --agent "$wait_line" >/dev/null 2>&1
assert_eq "$([ -n "$(claimfile)" ] && echo yes || echo no)" "yes" "release: agent claim exists after claim"
run_line="$(grep -F 'agent done-release' "$DEPUTY_ROOT/BACKLOG.md" | head -1)"   # now the running line
bash "$DEPUTY" set "$run_line" done >/dev/null 2>&1
assert_contains "$(bash "$DEPUTY" list)" "done|P1|" "release: item transitioned to done"
assert_eq "$([ -z "$(claimfile)" ] && echo yes || echo no)" "yes" "release: agent claim removed on done (no TTL wait)"
assert_eq "$([ -d "$DEPUTY_ROOT/.deputy/active-run.lock" ] && echo yes || echo no)" "no" "release: agent active-run released on done"
