#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
# REPO (from lib.sh) is the deputy repo root; install.sh lives at its top.
INSTALL="$REPO/install.sh"

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
