#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

# Fake crontab: a script backed by a file. `<cmd> -l` prints it; `<cmd> -` reads stdin into it.
STORE="$(mktemp)"; : > "$STORE"
FAKE="$(mktemp)"
cat > "$FAKE" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-l" ]]; then cat "$STORE"; exit 0; fi
if [[ "\${1:-}" == "-" ]]; then cat > "$STORE"; exit 0; fi
exit 0
EOF
chmod +x "$FAKE"
export DEPUTY_CRONTAB="$FAKE"

# ensure installs exactly one deputy entry
bash "$DEPUTY" cron --ensure
assert_eq "$(grep -c 'deputy' "$STORE")" "1" "ensure installs one entry"
# ensure is idempotent
bash "$DEPUTY" cron --ensure
assert_eq "$(grep -c 'deputy' "$STORE")" "1" "ensure idempotent"

# reschedule at a parsed reset hour (11pm -> 23)
bash "$DEPUTY" cron --reschedule "resets 11pm"
assert_contains "$(cat "$STORE")" "0 23 " "reschedule uses parsed hour 23"
assert_eq "$(grep -c 'deputy' "$STORE")" "1" "reschedule keeps one entry"

# remove (must also exit 0, not just produce the right file)
bash "$DEPUTY" cron --remove; rc=$?
assert_eq "$rc" "0" "remove exits 0"
assert_eq "$(grep -c 'deputy' "$STORE")" "0" "remove deletes entry"

# reset-hour parser unit checks via a hidden subcommand
assert_eq "$(bash "$DEPUTY" _resethour 'resets 3am')"  "3"  "3am -> 3"
assert_eq "$(bash "$DEPUTY" _resethour 'resets 12am')" "0"  "12am -> 0"
assert_eq "$(bash "$DEPUTY" _resethour 'resets 12pm')" "12" "12pm -> 12"
assert_eq "$(bash "$DEPUTY" _resethour 'no time here')" ""  "no match -> empty"

rm -f "$STORE" "$FAKE"
