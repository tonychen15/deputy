#!/usr/bin/env bash
# tests/test_sandbox.sh — #64: the headless worker runs in a bwrap read-only sandbox so it
# cannot write to the repo CODE (only .git, .deputy, BACKLOG.md, and the worktree are
# writable). Tests _sandbox_worker DIRECTLY — the DEPUTY_ORCHESTRATOR_CMD mock path bypasses it.
source "$(dirname "$0")/lib.sh"

if ! command -v bwrap >/dev/null 2>&1; then
  printf '0 run, 0 failed (bwrap not installed; sandbox tests skipped)\n'; exit 0
fi

# Probe (run by the sandboxed command): try to write the repo code / worktree / .git, + cwd.
PROBE="$(mktemp)"
cat > "$PROBE" <<'PS'
#!/usr/bin/env bash
( touch "$DEPUTY_ROOT/bin/SBTEST"        2>/dev/null && echo "code:writable" ) || echo "code:ro"
( touch "$DEPUTY_ROOT/.deputy/wt/SBTEST" 2>/dev/null && echo "wt:writable"   ) || echo "wt:ro"
( touch "$DEPUTY_ROOT/.git/SBTEST"       2>/dev/null && echo "git:writable"  ) || echo "git:ro"
( printf x >> "$DEPUTY_ROOT/BACKLOG.md"  2>/dev/null && echo "backlog:writable" ) || echo "backlog:ro"
echo "cwd:$PWD"
PS
chmod +x "$PROBE"

mkrepo() { R="$(mktemp -d)"; ( cd "$R" && git init -q && mkdir -p bin .deputy/wt && echo code > bin/foo && echo '# Backlog' > BACKLOG.md ); }
sb_run() { DEPUTY_ROOT="$R" bash -c 'source "'"$DEPUTY"'" >/dev/null 2>&1; _sandbox_worker bash "'"$PROBE"'"' 2>&1; }

# 1: sandbox ON (default) — repo code RO; worktree + .git writable; cwd = worktree
mkrepo
out="$(sb_run)"
assert_contains "$out" "code:ro"          "sandbox: repo CODE is read-only (breach closed)"
assert_contains "$out" "wt:writable"      "sandbox: worktree is writable"
assert_contains "$out" "git:writable"      "sandbox: .git is writable (deputy commit works)"
assert_contains "$out" "backlog:writable"  "sandbox: BACKLOG.md is writable (queue updates work)"
assert_contains "$out" "/.deputy/wt"       "sandbox: worker cwd pinned to the worktree"

# 2: sandbox=0 — fallback to cwd-pin only (no OS sandbox; code writable; still cwd-pinned)
mkrepo; printf 'sandbox=0\n' > "$R/.deputy/config"
out="$(sb_run)"
assert_contains "$out" "code:writable"    "sandbox=0: OS sandbox disabled (code writable)"
assert_contains "$out" "/.deputy/wt"      "sandbox=0: worker still cwd-pinned to the worktree"

# A repo WITHOUT .deputy/wt — the cold-start shape (the worker creates the worktree later).
mkrepo_cold() { R="$(mktemp -d)"; ( cd "$R" && git init -q && mkdir -p bin .deputy && echo code > bin/foo && echo '# Backlog' > BACKLOG.md ); }

# 3: COLD START (#68) — .deputy/wt ABSENT at spawn: the worker must still START (no bwrap
#    --chdir abort), repo code stays RO, and cwd falls back to .deputy (not the missing wt).
mkrepo_cold
out="$(sb_run)"
assert_contains "$out" "code:ro" "cold-start: worker ran + repo code still read-only (no .deputy/wt)"
assert_contains "$out" "cwd:"    "cold-start: sandboxed worker actually ran (did not abort at --chdir)"
assert_eq "$(printf '%s\n' "$out" | grep -c 'cwd:.*/\.deputy/wt')" "0" "cold-start: cwd is NOT the absent worktree"

# 4: COLD START + sandbox=0 — the non-bwrap fallback ( cd _cd ) must also not crash on a
#    missing worktree (it falls back to .deputy too).
mkrepo_cold; printf 'sandbox=0\n' > "$R/.deputy/config"
out="$(sb_run)"
assert_contains "$out" "code:writable" "cold-start sandbox=0: fallback ran (no crash on missing wt)"
assert_eq "$(printf '%s\n' "$out" | grep -c 'cwd:.*/\.deputy/wt')" "0" "cold-start sandbox=0: cwd is NOT the absent worktree"

rm -f "$PROBE"
