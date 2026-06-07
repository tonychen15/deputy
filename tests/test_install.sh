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
