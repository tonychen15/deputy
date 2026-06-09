#!/usr/bin/env bash
# tests/test_guardrail.sh — PreToolUse guardrail hook tests.
source "$(dirname "$0")/lib.sh"
HOOK="$REPO/hooks/guardrail.sh"

# Helper: run the hook with a tool_name + JSON tool_input, return exit code.
# Usage: gr <tool> <json-tool-input>
gr() {
  local tool="$1" ti="$2"
  printf '{"tool_name":"%s","tool_input":%s}' "$tool" "$ti" \
    | DEPUTY_GUARDED=1 DEPUTY_WT="$WT" DEPUTY_ROOT="$ROOT" bash "$HOOK" >/dev/null 2>&1
  echo $?
}
# A guarded worktree + root for path tests (Task 3 reuses these).
ROOT="$(mktemp -d)"; WT="$ROOT/.deputy/wt"; mkdir -p "$WT" "$ROOT/.deputy"

# bash() helper: pass a command string as Bash tool_input.
bash_cmd() { gr Bash "$(printf '{"command":%s}' "$(printf '%s' "$1" | jq -Rs .)")"; }

# --- self-gate: unguarded = allow everything ---
out="$(printf '{"tool_name":"Bash","tool_input":{"command":"git push"}}' | bash "$HOOK"; echo $?)"
assert_eq "$out" "0" "unguarded (no DEPUTY_GUARDED) allows everything"

# --- denylisted Bash → deny (exit 2) ---
assert_eq "$(bash_cmd 'git push origin master')" "2" "git push denied"
assert_eq "$(bash_cmd 'git push --force')" "2" "git force-push denied"
assert_eq "$(bash_cmd 'crontab -e')" "2" "crontab denied"
assert_eq "$(bash_cmd 'bash /home/x/install.sh link')" "2" "install.sh denied"
assert_eq "$(bash_cmd 'rm -rf build')" "2" "rm -rf denied"
assert_eq "$(bash_cmd 'rm -r foo')" "2" "rm -r denied"
assert_eq "$(bash_cmd 'rm build -rf')" "2" "rm build -rf (flag after path) denied"
assert_eq "$(bash_cmd 'rm -v -r build')" "2" "rm -v -r (flag before -r) denied"
assert_eq "$(bash_cmd 'rm -v foo -r')" "2" "rm -v foo -r (path before -r) denied"
assert_eq "$(bash_cmd 'rm foo --recursive')" "2" "rm foo --recursive denied"
assert_eq "$(bash_cmd 'rm --verbose --recursive foo')" "2" "rm --verbose --recursive denied"
assert_eq "$(bash_cmd 'git branch -D deputy/x')" "2" "git branch -D denied"
assert_eq "$(bash_cmd 'git config --global user.x y')" "2" "git config --global denied"
assert_eq "$(bash_cmd 'sudo apt-get update')" "2" "sudo denied"
assert_eq "$(bash_cmd 'gh pr merge 5')" "2" "gh pr merge denied"
assert_eq "$(bash_cmd 'npm install -g foo')" "2" "global npm install denied"
assert_eq "$(bash_cmd 'pip install foo')" "2" "pip install denied"
assert_eq "$(bash_cmd 'deputy cron --ensure')" "2" "deputy cron --ensure denied"
assert_eq "$(bash_cmd 'deputy cron --remove')" "2" "deputy cron --remove denied"
assert_eq "$(bash_cmd 'deputy cron --reschedule \"5pm reset\"')" "0" "deputy cron --reschedule allowed (quota failover)"
assert_eq "$(bash_cmd 'deputy cron --reschedule x; deputy cron --remove')" "2" "chained reschedule then remove denied"
assert_eq "$(bash_cmd 'deputy cron --reschedule x --ensure')" "2" "reschedule+ensure in one segment denied"
assert_eq "$(bash_cmd 'echo ok && git push')" "2" "chained git push denied"

# --- benign Bash → allow (exit 0) ---
assert_eq "$(bash_cmd 'ls -la')" "0" "ls allowed"
assert_eq "$(bash_cmd 'git status')" "0" "git status allowed"
assert_eq "$(bash_cmd 'git commit -m x')" "0" "git commit allowed"
assert_eq "$(bash_cmd 'deputy set "x" done')" "0" "deputy set allowed"
assert_eq "$(bash_cmd 'git checkout master && git merge --no-ff deputy/x')" "0" "done-gate merge allowed"
assert_eq "$(bash_cmd "git -C $WT reset --hard HEAD")" "0" "reset --hard inside wt allowed"
assert_eq "$(bash_cmd "git -C \"$WT\" reset --hard HEAD")" "0" "reset --hard inside wt (quoted path) allowed"
assert_eq "$(bash_cmd 'git reset --hard HEAD')" "2" "reset --hard outside wt denied"
assert_eq "$(bash_cmd 'git clean -fd')" "2" "clean -fd outside wt denied"
assert_eq "$(bash_cmd "git -C $WT clean -fd")" "0" "clean -fd inside wt allowed"

# --- fail-closed: Bash with no command → deny ---
assert_eq "$(gr Bash '{}')" "2" "Bash with no command denied (fail-closed)"
# fail-closed: invalid JSON → deny
assert_eq "$(printf 'not-valid-json' | DEPUTY_GUARDED=1 DEPUTY_WT="$WT" DEPUTY_ROOT="$ROOT" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "invalid JSON input denied (fail-closed)"
# fail-closed: per-segment reset-hard: chained non-wt reset must be denied
assert_eq "$(bash_cmd "git -C $WT status; git reset --hard HEAD")" "2" "chained: unscoped reset after wt-scoped cmd denied"
# git -C <non-wt-path> + risky subcommand must be denied
assert_eq "$(bash_cmd "git -C $ROOT branch -D deputy/x")" "2" "git -C non-wt branch -D denied"
assert_eq "$(bash_cmd "git -C $ROOT config --global user.x y")" "2" "git -C non-wt config --global denied"
# git -C with ../ escape from wt must be denied
assert_eq "$(bash_cmd "git -C $WT/../../ reset --hard HEAD")" "2" "git -C wt/../.. reset --hard denied"
# git --git-dir / --work-tree overrides must be denied
assert_eq "$(bash_cmd "git -C $WT --git-dir=/other/.git --work-tree=/other reset --hard")" "2" "git --git-dir override denied"
assert_eq "$(bash_cmd "GIT_DIR=/other/.git git reset --hard")" "2" "GIT_DIR env override denied"
assert_eq "$(bash_cmd "GIT_WORK_TREE=/other git reset --hard")" "2" "GIT_WORK_TREE env override denied"
# tab whitespace normalization: git<TAB>push must be denied
assert_eq "$(bash_cmd "$(printf 'git\tpush origin main')")" "2" "git tab push denied"

# --- Task 3: path containment ---
# write() helper: file_path as Edit/Write tool_input.
wr() { gr "$1" "$(printf '{"file_path":%s}' "$(printf '%s' "$2" | jq -Rs .)")"; }
nb() { gr NotebookEdit "$(printf '{"notebook_path":%s}' "$(printf '%s' "$1" | jq -Rs .)")"; }

mkdir -p "$WT/src"; : > "$WT/src/app.py"
assert_eq "$(wr Write "$WT/src/new.py")" "0" "write inside wt allowed"
assert_eq "$(wr Edit "$WT/src/app.py")" "0" "edit inside wt allowed"
assert_eq "$(wr Write "$ROOT/.deputy/fix-x.questions.md")" "0" "questions file allowed"
assert_eq "$(wr Write "$ROOT/.deputy/fix-x.fail.md")" "0" "fail file allowed"
assert_eq "$(wr Write "$ROOT/.deputy/nested/evil.questions.md")" "2" "nested .deputy path denied"
# fail-closed: DEPUTY_WT unset + risky write must be denied
assert_eq "$(printf '{"tool_name":"Write","tool_input":{"file_path":"/etc/passwd"}}' | DEPUTY_GUARDED=1 DEPUTY_ROOT="$ROOT" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "write /etc/passwd with DEPUTY_WT unset denied"
# fail-closed: DEPUTY_WT set to non-canonicalizable path + risky write must be denied
assert_eq "$(printf '{"tool_name":"Write","tool_input":{"file_path":"/etc/passwd"}}' | DEPUTY_GUARDED=1 DEPUTY_WT="/nonexistent/../evil" DEPUTY_ROOT="$ROOT" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "write /etc/passwd with empty-wt canonicalization denied"
assert_eq "$(wr Write "$HOME/.claude/skills/x")" "2" "write to ~/.claude denied"
assert_eq "$(wr Write "/etc/passwd")" "2" "write to /etc denied"
assert_eq "$(wr Write "$ROOT/bin/deputy.sh")" "2" "write to main repo (outside wt) denied"
assert_eq "$(wr Write "$WT/../escape.txt")" "2" "../escape from wt denied"
assert_eq "$(gr Write '{}')" "2" "Write with no file_path denied (fail-closed)"
assert_eq "$(nb "$HOME/x.ipynb")" "2" "notebook outside wt denied"
assert_eq "$(nb "$WT/n.ipynb")" "0" "notebook inside wt allowed"
# symlink inside wt pointing outside must NOT pass
ln -s /etc "$WT/lnk"
assert_eq "$(wr Write "$WT/lnk/evil")" "2" "symlinked-out path denied"

# --- Task 4: _guardrail_settings_path writes a settings file referencing the hook ---
gp="$(DEPUTY_ROOT="$ROOT" ROOT="$ROOT" SRC_DIR="$REPO" bash -c 'source "'"$REPO"'/bin/deputy.sh"; _guardrail_settings_path' 2>/dev/null)"
assert_eq "$([[ -f "$gp" ]] && echo yes || echo no)" "yes" "settings file generated"
assert_contains "$(cat "$gp")" "PreToolUse" "settings has PreToolUse hook"
assert_contains "$(cat "$gp")" "$REPO/hooks/guardrail.sh" "settings references the hook by abs path"

rm -rf "$ROOT"
