#!/usr/bin/env bash
# #76: self-heal so a customer never needs to re-run `init` after a deputy upgrade —
# (a) auto-seed missing per-project default files from the release templates, and
# (b) layer protected globs from the template at read time so new release defaults apply
#     to existing projects without re-init.
source "$(dirname "$0")/lib.sh"

# ── (b)-prereq + (a): a fresh repo with no .deputy/config|protected gets them on first run ──
setup_repo
assert_eq "$([[ -e "$DEPUTY_ROOT/.deputy/config" ]] && echo y)" "" "precondition: no config before any run"
bash "$DEPUTY" list >/dev/null 2>&1
assert_eq "$([[ -f "$DEPUTY_ROOT/.deputy/config" ]] && echo y)"    "y" "#76: missing .deputy/config auto-seeded on run"
assert_eq "$([[ -f "$DEPUTY_ROOT/.deputy/protected" ]] && echo y)" "y" "#76: missing .deputy/protected auto-seeded on run"
assert_eq "$(cat "$DEPUTY_ROOT/.deputy/config")" "$(cat "$REPO/templates/config")" "#76: seeded config matches template"

# auto-seed is idempotent and NEVER overwrites an existing per-project file
setup_repo
printf 'max_items=7\n' > "$DEPUTY_ROOT/.deputy/config"
bash "$DEPUTY" list >/dev/null 2>&1
assert_eq "$(bash "$DEPUTY" config max_items)" "7" "#76: existing config preserved (auto-seed never overwrites)"

# ── (b) protected union: a glob present ONLY in the release template applies even when the
#        per-project file omits it (new defaults reach existing projects without re-init) ──
setup_repo
printf 'custom/secret/**\n' > "$DEPUTY_ROOT/.deputy/protected"   # per-project file lacks .env*/infra/**
bash "$DEPUTY" protected ".env.local";       assert_eq "$?" "0" "#76: template glob .env* applies via union"
bash "$DEPUTY" protected "infra/main.tf";    assert_eq "$?" "0" "#76: template glob infra/** applies via union"
bash "$DEPUTY" protected "custom/secret/k";  assert_eq "$?" "0" "#76: per-project glob still applies"
bash "$DEPUTY" protected "src/app.py";       assert_eq "$?" "1" "#76: a non-protected path is still allowed"
