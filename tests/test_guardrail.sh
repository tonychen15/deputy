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

active_gr() {
  local tool="$1" ti="$2" owner_pid="${3:-}"
  if [[ -n "$owner_pid" ]]; then
    printf '{"tool_name":"%s","tool_input":%s}' "$tool" "$ti" \
      | DEPUTY_ACTIVE_RUN_PID="$owner_pid" DEPUTY_ROOT="$ROOT" bash "$HOOK" >/dev/null 2>&1
  else
    printf '{"tool_name":"%s","tool_input":%s}' "$tool" "$ti" \
      | DEPUTY_ROOT="$ROOT" bash "$HOOK" >/dev/null 2>&1
  fi
  echo $?
}

# bash() helper: pass a command string as Bash tool_input.
bash_cmd() { gr Bash "$(printf '{"command":%s}' "$(printf '%s' "$1" | jq -Rs .)")"; }

# bash_cwd() helper: pass a command + a top-level .cwd field (session cwd).
bash_cwd() {
  local cmd="$1" cwd="$2"
  printf '{"tool_name":"Bash","tool_input":{"command":%s},"cwd":%s}' \
    "$(printf '%s' "$cmd" | jq -Rs .)" \
    "$(printf '%s' "$cwd" | jq -Rs .)" \
    | DEPUTY_GUARDED=1 DEPUTY_WT="$WT" DEPUTY_ROOT="$ROOT" bash "$HOOK" >/dev/null 2>&1
  echo $?
}

# --- self-gate: unguarded = allow everything ---
out="$(printf '{"tool_name":"Bash","tool_input":{"command":"git push"}}' | bash "$HOOK"; echo $?)"
assert_eq "$out" "0" "unguarded (no DEPUTY_GUARDED) allows everything"
assert_eq "$(printf 'not-json' | DEPUTY_ROOT="$ROOT" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" \
  "unguarded with no active-run lock exits before JSON validation"

# --- active-run lock: unguarded interactive mutating tools are blocked ---
sleep 300 & LOCK_PID=$!
mkdir -p "$ROOT/.deputy/active-run.lock"
printf '%s\n' "$LOCK_PID" > "$ROOT/.deputy/active-run.lock/pid"
ps -o lstart= -p "$LOCK_PID" 2>/dev/null | sed 's/^ *//' > "$ROOT/.deputy/active-run.lock/start_time"
printf 'test\n' > "$ROOT/.deputy/active-run.lock/owner"
printf 'item\n' > "$ROOT/.deputy/active-run.lock/item"
printf 'now\n' > "$ROOT/.deputy/active-run.lock/started_at"
assert_eq "$(active_gr Write '{"file_path":"/tmp/x"}')" "2" "active-run lock blocks non-owner Write"
assert_eq "$(active_gr Bash '{"command":"sed -i s/a/b/ file"}')" "2" "active-run lock blocks non-owner Bash"
assert_eq "$(active_gr Write '{"file_path":"/tmp/x"}' "$LOCK_PID")" "0" "active-run lock allows owner past self-gate"
kill "$LOCK_PID" 2>/dev/null || true
rm -rf "$ROOT/.deputy/active-run.lock"

# --- denylisted Bash → deny (exit 2) ---
assert_eq "$(bash_cmd 'git push origin master')" "2" "git push denied"
assert_eq "$(bash_cmd 'git push --force')" "2" "git force-push denied"
assert_eq "$(bash_cmd 'crontab -e')" "2" "crontab denied"
assert_eq "$(bash_cmd 'bash /home/x/inst_deputy.sh link')" "2" "inst_deputy.sh denied"
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
assert_eq "$(bash_cmd 'git checkout master && git merge --no-ff deputy/x')" "2" "#60: a guarded worker's done-gate merge is now BLOCKED (auto_merge unset) — it must surface for human review"
assert_eq "$(bash_cmd "git -C $WT reset --hard HEAD")" "0" "reset --hard inside wt allowed"
assert_eq "$(bash_cmd "git -C \"$WT\" reset --hard HEAD")" "0" "reset --hard inside wt (quoted path) allowed"
assert_eq "$(bash_cmd 'git reset --hard HEAD')" "2" "reset --hard outside wt denied"
assert_eq "$(bash_cmd 'git clean -fd')" "2" "clean -fd outside wt denied"
assert_eq "$(bash_cmd "git -C $WT clean -fd")" "0" "clean -fd inside wt allowed"

# --- regression: false-positive fixes (Fix 1 — command-position anchoring) ---
# Risky token appears only in DATA (quoted arg / commit message) — must ALLOW.
assert_eq "$(bash_cmd "deputy commit --summary 'remove rm -rf usage'")" "0" "deputy commit with rm-rf in summary allowed (data FP)"
assert_eq "$(bash_cmd 'git commit -m "fix: handle rm -rf safely"')" "0" "git commit with rm-rf in message allowed (data FP)"
assert_eq "$(bash_cmd "echo 'remember to git push later'")" "0" "echo with git-push in string allowed (data FP)"
assert_eq "$(bash_cmd 'grep "git push" README.md')" "0" "grep for git push pattern allowed (data FP)"
assert_eq "$(bash_cmd 'sed -n "/rm -rf/d" file.txt')" "0" "sed pattern mentioning rm-rf allowed (data FP)"

# True positives still deny after Fix 1.
assert_eq "$(bash_cmd 'echo ok && git push origin main')" "2" "chained git push still denied (Fix 1 TP)"
assert_eq "$(bash_cmd 'ls; rm -rf /tmp/x')" "2" "semicolon-chained rm -rf still denied (Fix 1 TP)"
assert_eq "$(bash_cmd '(rm -rf foo)')" "2" "subshell rm -rf still denied (Fix 1 TP)"

# --- regression: newline-bypass (later-line risky command must still be caught) ---
assert_eq "$(bash_cmd "$(printf 'ls\ngit push origin main')")" "2" "git push on a later line still denied (newline bypass)"
assert_eq "$(bash_cmd "$(printf 'echo hello\nrm -rf build')")" "2" "rm -rf on a later line still denied (newline bypass)"
assert_eq "$(bash_cmd "$(printf 'echo a\necho b')")" "0" "benign multi-line allowed"
# --- regression: risky tokens as DATA in arguments are anchored away (no false positive) ---
assert_eq "$(bash_cmd 'echo "remember to git reset --hard later"')" "0" "git reset --hard as echo data allowed"
assert_eq "$(bash_cmd 'deputy commit --summary "use git reset --hard to undo"')" "0" "git reset --hard in commit summary allowed"
assert_eq "$(bash_cmd 'echo "pass --git-dir to git"')" "0" "--git-dir as echo data allowed"

# --- regression: false-positive fixes (Fix 2 — cwd-aware reset/clean) ---
# reset --hard with no -C BUT cwd is inside the worktree (session already cd'd in) — ALLOW.
assert_eq "$(bash_cwd 'git reset --hard HEAD' "$WT")" "0" "reset --hard with cwd=WT allowed (cwd FP)"
assert_eq "$(bash_cwd 'git clean -fd' "$WT")" "0" "clean -fd with cwd=WT allowed (cwd FP)"
assert_eq "$(bash_cwd 'git reset --hard HEAD' "$WT/src")" "0" "reset --hard with cwd=WT/subdir allowed (cwd FP)"
# reset --hard with no -C and cwd is repo ROOT — still DENY.
assert_eq "$(bash_cwd 'git reset --hard HEAD' "$ROOT")" "2" "reset --hard with cwd=ROOT denied (cwd TP)"
# cd into wt then reset — ALLOW.
assert_eq "$(bash_cmd "cd $WT && git reset --hard HEAD")" "0" "cd WT then reset --hard allowed (cd FP)"

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
# review trail is append-only via `deputy review-log` (a Bash cmd); direct Write/Edit denied
assert_eq "$(wr Write "$ROOT/.deputy/fix-x.review.md")" "2" "direct Write to review trail denied (append-only via CLI)"
assert_eq "$(wr Edit "$ROOT/.deputy/fix-x.review.md")" "2" "direct Edit to review trail denied (append-only via CLI)"
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

# --- #60: a guarded worker's auto-merge is blocked unless auto_merge=1 ---
# Dedicated root ($ROOT was rm -rf'd just above).
MR="$(mktemp -d)"; mkdir -p "$MR/.deputy/wt"
mb() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)" \
  | DEPUTY_GUARDED=1 DEPUTY_WT="$MR/.deputy/wt" DEPUTY_ROOT="$MR" bash "$HOOK" >/dev/null 2>&1; echo $?; }
assert_eq "$(mb 'git merge --no-ff deputy/fix-thing-7')" "2" "guarded git merge denied when auto_merge unset"
printf 'auto_merge=0\n' > "$MR/.deputy/config"
assert_eq "$(mb 'git merge --no-ff deputy/fix-thing-7')" "2" "guarded git merge denied when auto_merge=0"
printf 'auto_merge=1\n' > "$MR/.deputy/config"
assert_eq "$(mb 'git merge --no-ff deputy/fix-thing-7')" "0" "guarded git merge ALLOWED when auto_merge=1"
assert_eq "$(mb "git -C $MR/.deputy/wt merge deputy/x")" "0" "auto_merge=1 allows the merge (git -C form)"
rm -f "$MR/.deputy/config"
assert_eq "$(mb 'echo git merge later')" "0" "'git merge' only as data (echo) is not blocked"
# wrapped/bypass forms must still be blocked (auto_merge unset)
assert_eq "$(mb 'time git merge deputy/x')"            "2" "wrapped 'time git merge' blocked"
assert_eq "$(mb 'if git merge deputy/x; then :; fi')"  "2" "wrapped 'if git merge' blocked"
assert_eq "$(mb 'GIT_CONFIG=/tmp/x git merge deputy/x')" "2" "env-prefixed 'X=.. git merge' blocked"
assert_eq "$(mb 'git -C "/path with spaces" merge deputy/x')" "2" "quoted git -C merge blocked"
assert_eq "$(mb 'cd /tmp && git merge deputy/x')"      "2" "chained 'cd && git merge' blocked"
assert_eq "$(mb 'time -p git merge deputy/x')"         "2" "wrapper-flag 'time -p git merge' blocked"
assert_eq "$(mb 'env -i git merge deputy/x')"          "2" "wrapper-flag 'env -i git merge' blocked"
assert_eq "$(mb 'if ! git merge deputy/x; then :; fi')" "2" "negated 'if ! git merge' blocked"
