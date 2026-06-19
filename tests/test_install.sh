#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
# REPO (from lib.sh) is the deputy repo root; inst_deputy.sh lives at its top.
INSTALL="$REPO/inst_deputy.sh"

# Use a global fake crontab throughout this file so no init/cron call
# accidentally modifies the real user crontab.
_GTAB="$(mktemp)"; _GSTORE="$(mktemp)"; : > "$_GSTORE"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == "-l" ]] && { cat "$_DEPUTY_TEST_CRON_STORE"; exit 0; }\n[[ "${1:-}" == "-" ]] && { cat > "$_DEPUTY_TEST_CRON_STORE"; exit 0; }\nexit 0\n' > "$_GTAB"
chmod +x "$_GTAB"
export DEPUTY_CRONTAB="$_GTAB" _DEPUTY_TEST_CRON_STORE="$_GSTORE"

# --- init seeds BACKLOG + gitignore into a fresh dir ---
d="$(mktemp -d)"
bash "$INSTALL" init "$d" >/dev/null
assert_eq "$([[ -f "$d/BACKLOG.md" ]] && echo yes || echo no)" "yes" "init seeds BACKLOG.md"
assert_eq "$(grep -c 'LEGEND' "$d/BACKLOG.md")" "1" "seeded BACKLOG has legend"
assert_eq "$(grep -cxF '.deputy/' "$d/.gitignore")" "1" "init gitignores .deputy/"

# --- init is idempotent: no dup gitignore line, no clobber of an edited backlog ---
echo "custom item" >> "$d/BACKLOG.md"
bash "$INSTALL" init "$d" >/dev/null
assert_eq "$(grep -cxF '.deputy/' "$d/.gitignore")" "1" "init gitignore idempotent"
assert_contains "$(cat "$d/BACKLOG.md")" "custom item" "init does not clobber existing BACKLOG"

# --- link into a temp prefix produces a working deputy ---
p="$(mktemp -d)"
DEPUTY_PREFIX="$p" bash "$INSTALL" link >/dev/null
assert_eq "$([[ -L "$p/deputy" ]] && echo yes || echo no)" "yes" "link creates symlink"
out="$("$p/deputy" help 2>&1)"
assert_contains "$out" "status" "linked deputy runs"

# --- link is idempotent ---
out="$(DEPUTY_PREFIX="$p" bash "$INSTALL" link 2>&1)"; rc=$?
assert_eq "$rc" "0" "re-link exits 0"
assert_contains "$out" "already linked" "re-link is idempotent"

# --- link refuses to clobber a foreign deputy without --force ---
p2="$(mktemp -d)"; printf '#!/bin/sh\necho foreign\n' > "$p2/deputy"; chmod +x "$p2/deputy"
DEPUTY_PREFIX="$p2" bash "$INSTALL" link >/dev/null 2>&1; rc=$?
assert_eq "$rc" "3" "link refuses foreign deputy without --force"
DEPUTY_PREFIX="$p2" bash "$INSTALL" link --force >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "link --force replaces foreign deputy"

# --- bare invocation (no args) defaults to link ---
p3="$(mktemp -d)"
DEPUTY_PREFIX="$p3" bash "$INSTALL" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "bare install defaults to link (exit 0)"
assert_eq "$([[ -L "$p3/deputy" ]] && echo yes || echo no)" "yes" "bare install creates symlink"

# --- refuses when target is a real directory ---
p4="$(mktemp -d)"; mkdir -p "$p4/deputy"
DEPUTY_PREFIX="$p4" bash "$INSTALL" link --force >/dev/null 2>&1; rc=$?
assert_eq "$rc" "3" "link refuses a directory target"

# --- init also seeds .deputy/config and .deputy/protected (idempotent, no clobber) ---
di="$(mktemp -d)"
bash "$INSTALL" init "$di" >/dev/null
assert_eq "$([[ -f "$di/.deputy/config" ]] && echo yes || echo no)" "yes" "init seeds .deputy/config"
assert_eq "$([[ -f "$di/.deputy/protected" ]] && echo yes || echo no)" "yes" "init seeds .deputy/protected"
echo "custom=1" >> "$di/.deputy/config"
bash "$INSTALL" init "$di" >/dev/null
assert_contains "$(cat "$di/.deputy/config")" "custom=1" "init does not clobber existing config"

# --- link also installs the orchestrator skill into DEPUTY_SKILLS_DIR ---
sk="$(mktemp -d)"; pf="$(mktemp -d)"
DEPUTY_SKILLS_DIR="$sk" DEPUTY_PREFIX="$pf" bash "$INSTALL" link >/dev/null
assert_eq "$([[ -e "$sk/deputy/SKILL.md" ]] && echo yes || echo no)" "yes" "link installs orchestrator skill"

# --- link is idempotent for the skill too ---
DEPUTY_SKILLS_DIR="$sk" DEPUTY_PREFIX="$pf" bash "$INSTALL" link >/dev/null; rc=$?
assert_eq "$rc" "0" "re-link with skill exits 0"

# --- link also puts the installer itself on PATH, resolving to the real script ---
pi="$(mktemp -d)"
DEPUTY_PREFIX="$pi" bash "$INSTALL" link >/dev/null 2>&1
assert_eq "$([[ -L "$pi/inst_deputy.sh" ]] && echo yes || echo no)" "yes" "link symlinks inst_deputy.sh onto PATH"
assert_eq "$(readlink -f "$pi/inst_deputy.sh" 2>/dev/null)" "$(readlink -f "$REPO/inst_deputy.sh")" "linked installer resolves to the real script"

# --- migration: a pre-existing runner-only install still gains the installer self-link on re-run ---
pm="$(mktemp -d)"
ln -sfn "$REPO/bin/deputy.sh" "$pm/deputy"          # simulate an old install (runner linked, no installer)
DEPUTY_PREFIX="$pm" bash "$INSTALL" link >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "re-link over an old runner-only install exits 0"
assert_eq "$([[ -L "$pm/inst_deputy.sh" ]] && echo yes || echo no)" "yes" "re-link backfills inst_deputy.sh for old installs"

# --- self-link refuses to clobber a FOREIGN inst_deputy.sh symlink without --force ---
pf2="$(mktemp -d)"; foreign="$(mktemp)"
ln -sfn "$REPO/bin/deputy.sh" "$pf2/deputy"          # deputy is ours (so the runner block passes)
ln -sfn "$foreign" "$pf2/inst_deputy.sh"             # but inst_deputy.sh points elsewhere
DEPUTY_PREFIX="$pf2" bash "$INSTALL" link >/dev/null 2>&1
assert_eq "$(readlink "$pf2/inst_deputy.sh")" "$foreign" "self-link leaves a foreign installer symlink untouched without --force"
DEPUTY_PREFIX="$pf2" bash "$INSTALL" link --force >/dev/null 2>&1
assert_eq "$(readlink -f "$pf2/inst_deputy.sh" 2>/dev/null)" "$(readlink -f "$REPO/inst_deputy.sh")" "self-link --force replaces a foreign installer symlink"

# --- init also enables the cron heartbeat (combined in one step) ---
di_cron="$(mktemp -d)"
cron_store2="$(mktemp)"; : > "$cron_store2"
fake_tab2="$(mktemp)"
cat > "$fake_tab2" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == "-l" ]] && { cat "$cron_store2"; exit 0; }
[[ "\${1:-}" == "-" ]] && { cat > "$cron_store2"; exit 0; }
exit 0
EOF
chmod +x "$fake_tab2"
out_cron_init="$(DEPUTY_CRONTAB="$fake_tab2" bash "$INSTALL" init "$di_cron" 2>&1)"
assert_contains "$out_cron_init" "cron heartbeat enabled" "init prints cron heartbeat confirmation"
assert_eq "$(grep -c 'deputy' "$cron_store2")" "1" "init enables one cron entry"
assert_eq "$(test -f "$di_cron/.deputy/cron.enabled" && echo yes || echo no)" "yes" "init creates cron.enabled marker"
rm -rf "$di_cron" "$cron_store2" "$fake_tab2" 2>/dev/null || true

# --- install.sh cron delegates to deputy cron --ensure (fake crontab) ---
# Isolate DEPUTY_ROOT to a temp repo: `cron --ensure` now also writes a
# `.deputy/cron.enabled` marker under DEPUTY_ROOT, which must NOT touch the real repo.
cron_root="$(mktemp -d)"; mkdir -p "$cron_root/.deputy"
store="$(mktemp)"; : > "$store"
fake="$(mktemp)"
cat > "$fake" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == "-l" ]] && { cat "$store"; exit 0; }
[[ "\${1:-}" == "-" ]] && { cat > "$store"; exit 0; }
exit 0
EOF
chmod +x "$fake"
DEPUTY_ROOT="$cron_root" DEPUTY_CRONTAB="$fake" bash "$INSTALL" cron >/dev/null 2>&1
assert_eq "$(grep -c 'deputy' "$store")" "1" "install cron ensures one entry"
assert_eq "$(test -f "$cron_root/.deputy/cron.enabled" && echo yes || echo no)" "yes" "install cron creates the opt-in marker in DEPUTY_ROOT"
rm -rf "$cron_root" "$store" "$fake" 2>/dev/null || true

# --- init appends Deputy task-intake guidance to CLAUDE.md ---
dc="$(mktemp -d)"
bash "$INSTALL" init "$dc" >/dev/null
assert_eq "$([[ -f "$dc/CLAUDE.md" ]] && echo yes || echo no)" "yes" "init creates CLAUDE.md"
assert_contains "$(cat "$dc/CLAUDE.md")" "Deputy: task intake" "CLAUDE.md contains sentinel"
assert_contains "$(cat "$dc/CLAUDE.md")" "BACKLOG.md" "CLAUDE.md mentions BACKLOG.md"

# --- init CLAUDE.md guidance is idempotent ---
bash "$INSTALL" init "$dc" >/dev/null
count="$(grep -c 'Deputy: task intake' "$dc/CLAUDE.md")"
assert_eq "$count" "1" "init CLAUDE.md guidance is not duplicated"

# --- init preserves existing CLAUDE.md content ---
dc2="$(mktemp -d)"
printf '# My Project\nCustom instructions here.\n' > "$dc2/CLAUDE.md"
bash "$INSTALL" init "$dc2" >/dev/null
assert_contains "$(cat "$dc2/CLAUDE.md")" "Custom instructions here." "init preserves existing CLAUDE.md"
assert_contains "$(cat "$dc2/CLAUDE.md")" "Deputy: task intake" "init appends to existing CLAUDE.md"

# --- inst_deputy.sh link from inside a worktree must target the MAIN repo, not the worktree (regression) ---
mr="$(mktemp -d)"
git -C "$mr" init -q; git -C "$mr" config user.email t@t; git -C "$mr" config user.name t
mkdir -p "$mr/bin" "$mr/skills/deputy"
cp "$REPO/inst_deputy.sh" "$mr/inst_deputy.sh"; cp "$REPO/bin/deputy.sh" "$mr/bin/deputy.sh"; cp "$REPO/skills/deputy/SKILL.md" "$mr/skills/deputy/SKILL.md"
chmod +x "$mr/inst_deputy.sh" "$mr/bin/deputy.sh"
git -C "$mr" add -A; git -C "$mr" commit -qm init
wt="$(mktemp -d)/wt"; git -C "$mr" worktree add -q "$wt" -b wtbranch
pfx="$(mktemp -d)"; sk="$(mktemp -d)"
DEPUTY_PREFIX="$pfx" DEPUTY_SKILLS_DIR="$sk" bash "$wt/inst_deputy.sh" link >/dev/null 2>&1
tgt="$(readlink -f "$sk/deputy" 2>/dev/null)"
assert_eq "$(case "$tgt" in "$mr"/*) echo main;; "$wt"/*) echo worktree;; *) echo other;; esac)" "main" "skill symlink targets MAIN repo, not the worktree"
ctgt="$(readlink -f "$pfx/deputy" 2>/dev/null)"
assert_eq "$(case "$ctgt" in "$mr"/*) echo main;; "$wt"/*) echo worktree;; *) echo other;; esac)" "main" "command symlink targets MAIN repo, not the worktree"
git -C "$mr" worktree remove --force "$wt" 2>/dev/null; rm -rf "$mr" "$pfx" "$sk" 2>/dev/null || true
