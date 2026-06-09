# Risky-op Guardrail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a best-effort PreToolUse guardrail so the autonomous deputy orchestrator is *blocked* from common irreversible/out-of-scope ops (out-of-worktree writes; `git push`, `crontab`, `install.sh`, `rm -r`, etc.) and surfaces them instead.

**Architecture:** A self-contained bash hook (`hooks/guardrail.sh`) reads PreToolUse JSON on stdin and denies (exit 2 + stderr reason) when `DEPUTY_GUARDED=1`. `_spawn_orchestrator` exports `DEPUTY_GUARDED`/`DEPUTY_WT`/`DEPUTY_ROOT` and passes `claude -p --settings <generated>` so the hook applies only to the spawned session. SKILL.md prose covers judgment calls. Best-effort defense-in-depth atop the never-auto-push boundary — not an adversarial sandbox.

**Tech Stack:** Pure bash + `jq` (already a deputy dependency); Claude Code PreToolUse hooks; the existing `tests/lib.sh` harness.

**Spec:** `docs/superpowers/specs/2026-06-08-deputy-risky-op-guardrail-design.md`

---

## File Structure
- **Create `hooks/guardrail.sh`** — the PreToolUse hook (self-gate, field extraction, Bash denylist, path containment). One responsibility: decide allow/deny for one tool call.
- **Create `tests/test_guardrail.sh`** — unit tests feeding PreToolUse JSON to the hook.
- **Modify `bin/deputy.sh`** — `_spawn_orchestrator`: export guard env + generate settings + `--settings`.
- **Modify `skills/deputy/SKILL.md`** — add the "Guardrail" section.
- **Reference only:** `tests/run.sh` (auto-globs `tests/test_*.sh` — verify it picks up the new file).

A note on review: this repo's rule is cross-LLM review before every commit. **Gemini is the primary reviewer; if its quota is exhausted, use `codex exec` as the reviewer** (author≠reviewer). Run it on the staged diff at each commit step.

---

## Task 1: Feasibility spike — SHIP/NO-SHIP GATE (do this first, do not skip)

**Goal:** Prove the installed Claude CLI honors a *denying* PreToolUse hook in headless `claude -p --settings` mode, and pin the exact stdin JSON shape + deny mechanism. **If it does not work, STOP and report — do not build a hook that silently allows everything.**

**Files:**
- Create (throwaway, delete after): `/tmp/gr-spike/deny.sh`, `/tmp/gr-spike/settings.json`

- [ ] **Step 1: Write a throwaway always-deny-Bash hook**

```bash
mkdir -p /tmp/gr-spike
cat > /tmp/gr-spike/deny.sh <<'EOF'
#!/usr/bin/env bash
in="$(cat)"
printf 'SPIKE-SAW: %s\n' "$in" >> /tmp/gr-spike/seen.log
echo "BLOCKED by spike" >&2
exit 2
EOF
chmod +x /tmp/gr-spike/deny.sh
cat > /tmp/gr-spike/settings.json <<'EOF'
{ "hooks": { "PreToolUse": [ { "matcher": "Bash",
  "hooks": [ { "type": "command", "command": "/tmp/gr-spike/deny.sh" } ] } ] } }
EOF
```

- [ ] **Step 2: Run a headless claude that WANTS to run a Bash command**

Run:
```bash
: > /tmp/gr-spike/seen.log
claude -p "Run the bash command: echo hello-from-bash. Then tell me the exact output." \
  --settings /tmp/gr-spike/settings.json --allowedTools "Bash" 2>&1 | tee /tmp/gr-spike/out.txt
```
Expected: the run does NOT print `hello-from-bash` as a successful command result; `/tmp/gr-spike/seen.log` contains a `SPIKE-SAW:` line with JSON including `"tool_name":"Bash"` and `"tool_input":{"command":"echo hello-from-bash"...}`. This proves (a) the hook fired headless via `--settings`, and (b) exit-2 blocked the call.

- [ ] **Step 3: Record the findings**

Read `/tmp/gr-spike/seen.log`. Note in your report: the exact JSON keys (`tool_name`, `tool_input.command`), whether exit-2+stderr blocked (vs needing the JSON `permissionDecision:deny` form), and the `matcher` syntax that worked. **These pin the field names + deny mechanism used in Task 2/3.**

- [ ] **Step 4: Decision gate**

If Step 2 blocked the command → **PROCEED** to Task 2 (the rest of the plan assumes exit-2 + stderr works and the fields are `tool_name`/`tool_input.command`/`tool_input.file_path`/`tool_input.notebook_path`; if the spike showed different field names or that only the JSON form denies, adjust Task 2/3 code accordingly).
If it did NOT block → **STOP. Report to the human.** Do not implement a non-enforcing hook. (Fallbacks per spec §6: PATH-shim best-effort-minus, or escalate to an OS sandbox — human decides.)

- [ ] **Step 5: Clean up the spike**

```bash
rm -rf /tmp/gr-spike
```

---

## Task 2: Hook — self-gate, field extraction, fail-closed, Bash denylist

**Files:**
- Create: `hooks/guardrail.sh`
- Create: `tests/test_guardrail.sh`

- [ ] **Step 1: Write failing tests for the Bash denylist + self-gate**

Create `tests/test_guardrail.sh`:
```bash
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
assert_eq "$(bash_cmd 'git branch -D deputy/x')" "2" "git branch -D denied"
assert_eq "$(bash_cmd 'git config --global user.x y')" "2" "git config --global denied"
assert_eq "$(bash_cmd 'sudo apt-get update')" "2" "sudo denied"
assert_eq "$(bash_cmd 'gh pr merge 5')" "2" "gh pr merge denied"
assert_eq "$(bash_cmd 'npm install -g foo')" "2" "global npm install denied"
assert_eq "$(bash_cmd 'pip install foo')" "2" "pip install denied"
assert_eq "$(bash_cmd 'deputy cron --ensure')" "2" "deputy cron denied"
assert_eq "$(bash_cmd 'echo ok && git push')" "2" "chained git push denied"

# --- benign Bash → allow (exit 0) ---
assert_eq "$(bash_cmd 'ls -la')" "0" "ls allowed"
assert_eq "$(bash_cmd 'git status')" "0" "git status allowed"
assert_eq "$(bash_cmd 'git commit -m x')" "0" "git commit allowed"
assert_eq "$(bash_cmd 'deputy set \"x\" done')" "0" "deputy set allowed"
assert_eq "$(bash_cmd 'git checkout master && git merge --no-ff deputy/x')" "0" "done-gate merge allowed"
assert_eq "$(bash_cmd "git -C $WT reset --hard HEAD")" "0" "reset --hard inside wt allowed"
assert_eq "$(bash_cmd 'git reset --hard HEAD')" "2" "reset --hard outside wt denied"

# --- fail-closed: Bash with no command → deny ---
assert_eq "$(gr Bash '{}')" "2" "Bash with no command denied (fail-closed)"

rm -rf "$ROOT"
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `bash tests/test_guardrail.sh`
Expected: FAIL (the hook doesn't exist yet — `bash: hooks/guardrail.sh: No such file`).

- [ ] **Step 3: Implement `hooks/guardrail.sh` (self-gate + dispatch + Bash denylist)**

```bash
#!/usr/bin/env bash
# hooks/guardrail.sh — Deputy risky-op guardrail (Claude Code PreToolUse hook).
# Best-effort tripwire: when DEPUTY_GUARDED=1, DENY known-risky tool calls by the spawned
# orchestrator so it surfaces them instead. Reads PreToolUse JSON on stdin; denies via
# exit 2 + a stderr reason (Claude feeds stderr back to the model). NOT a sandbox — see
# docs/superpowers/specs/2026-06-08-deputy-risky-op-guardrail-design.md.
set -uo pipefail

# Self-gate: only enforce for the guarded orchestrator session.
[[ "${DEPUTY_GUARDED:-}" == "1" ]] || exit 0

input="$(cat)"
command -v jq >/dev/null 2>&1 || { echo "guardrail: jq missing; denying for safety" >&2; exit 2; }

deny() {
  echo "BLOCKED by deputy guardrail: $1 Do NOT retry or work around it — run: deputy set \"<item-line>\" surfaced (with a note explaining why), then stop." >&2
  exit 2
}

_bash_risky() {
  local n; n="$(printf '%s' "$1" | tr '\n' ' ')"
  local p
  for p in \
    'git( +-C +[^ ]+)? +push' \
    '(^| )crontab( |$)' \
    'install\.sh' \
    '(^| )rm +(-[a-zA-Z]*[rRf]|--recursive|--force)' \
    'git +branch +-[Dd]( |$)' \
    'git +branch +-f' \
    'git +update-ref' \
    'git +config +--(global|system)' \
    'git +worktree +remove +[^|;&]*--force' \
    'git +remote( |$)' \
    '(^| )sudo( |$)' \
    'gh +pr +merge' \
    'gh +[^|;&]*--delete-branch' \
    '(npm|pnpm|yarn) +[^|;&]*( -g|--global)' \
    'pip[0-9]* +install' \
    '(^| )apt(-get)?( |$)' \
    '(^| )brew +install' \
    'deputy +cron' \
    ; do
    printf '%s' "$n" | grep -Eq "$p" && return 0
  done
  # reset --hard / clean -f that is NOT scoped to the worktree via -C "$DEPUTY_WT"
  if printf '%s' "$n" | grep -Eq 'git +[^|;&]*(reset +--hard|clean +-[a-zA-Z]*f)'; then
    printf '%s' "$n" | grep -Eq "git +-C +[\"']?${DEPUTY_WT}([\"' /]|$)" || return 0
  fi
  return 1
}

tool="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
case "$tool" in
  Bash)
    cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
    [[ -n "$cmd" ]] || deny "Bash call with no command (fail-closed)."
    _bash_risky "$cmd" && deny "risky command [$(printf '%s' "$cmd" | head -c 80)]."
    ;;
  # Edit/Write/NotebookEdit handled in Task 3.
esac
exit 0
```

- [ ] **Step 4: Run the tests to confirm Bash + self-gate cases pass**

Run: `bash tests/test_guardrail.sh`
Expected: all current asserts PASS (path/Edit tests are added in Task 3). If a denylist regex misses a case, adjust the pattern until the test passes (TDD).

- [ ] **Step 5: Cross-LLM review, then commit**

```bash
chmod +x hooks/guardrail.sh
git add hooks/guardrail.sh tests/test_guardrail.sh
gemini -p "Review as a staff engineer, flag CRITICAL/WARNING, end APPROVED/NEEDS_WORK: $(git diff --cached)" \
  || codex exec "Cross-LLM review (author Claude), flag CRITICAL/WARNING, end APPROVED or NEEDS_WORK: $(git diff --cached)"
# fix any CRITICAL/WARNING, re-stage, re-review until clean, then:
git commit -m "feat(guardrail): PreToolUse hook — self-gate + Bash denylist (deputy)"
```

---

## Task 3: Hook — Edit/Write/NotebookEdit out-of-worktree containment

**Files:**
- Modify: `hooks/guardrail.sh`
- Modify: `tests/test_guardrail.sh`

- [ ] **Step 1: Add failing path-containment tests**

Append to `tests/test_guardrail.sh` (before the final `rm -rf "$ROOT"`):
```bash
# write() helper: file_path as Edit/Write tool_input.
wr() { gr "$1" "$(printf '{"file_path":%s}' "$(printf '%s' "$2" | jq -Rs .)")"; }
nb() { gr NotebookEdit "$(printf '{"notebook_path":%s}' "$(printf '%s' "$1" | jq -Rs .)")"; }

mkdir -p "$WT/src"; : > "$WT/src/app.py"
assert_eq "$(wr Write "$WT/src/new.py")" "0" "write inside wt allowed"
assert_eq "$(wr Edit "$WT/src/app.py")" "0" "edit inside wt allowed"
assert_eq "$(wr Write "$ROOT/.deputy/fix-x.questions.md")" "0" "questions file allowed"
assert_eq "$(wr Write "$ROOT/.deputy/fix-x.fail.md")" "0" "fail file allowed"
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
```

- [ ] **Step 2: Run to confirm new path tests fail**

Run: `bash tests/test_guardrail.sh`
Expected: the new `wr`/`nb` asserts FAIL (Edit/Write/NotebookEdit not yet handled → hook exits 0 → allowed where deny expected).

- [ ] **Step 3: Implement path containment in `hooks/guardrail.sh`**

Add the helper after `_bash_risky` (before `tool=`):
```bash
_path_outside_wt() {
  local p="$1"
  [[ -n "$p" ]] || return 0                 # fail-closed: empty path -> deny
  [[ "$p" = /* ]] || p="$PWD/$p"            # relative -> resolve against cwd (the worktree)
  local rp wt root
  rp="$(realpath -m -- "$p" 2>/dev/null)"   || return 0
  wt="$(realpath -m -- "$DEPUTY_WT" 2>/dev/null)"
  root="$(realpath -m -- "$DEPUTY_ROOT" 2>/dev/null)"
  case "$rp/" in "$wt/"*) return 1 ;; esac  # inside the worktree -> allow
  case "$rp" in                             # the two permitted state files
    "$root"/.deputy/*.questions.md|"$root"/.deputy/*.fail.md) return 1 ;;
  esac
  return 0                                   # everything else -> deny
}
```
And extend the `case "$tool"` block:
```bash
  Edit|Write|MultiEdit)
    path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
    _path_outside_wt "$path" && deny "write outside the worktree [${path:-<none>}]."
    ;;
  NotebookEdit)
    path="$(printf '%s' "$input" | jq -r '.tool_input.notebook_path // empty')"
    _path_outside_wt "$path" && deny "notebook write outside the worktree [${path:-<none>}]."
    ;;
```

- [ ] **Step 4: Run all guardrail tests**

Run: `bash tests/test_guardrail.sh`
Expected: ALL asserts PASS. Then `bash tests/run.sh; echo exit=$?` → exit 0 (confirm run.sh auto-globs the new test file; if not, add `tests/test_guardrail.sh` to its list).

- [ ] **Step 5: Cross-LLM review, then commit**

```bash
git add hooks/guardrail.sh tests/test_guardrail.sh
gemini -p "Review as a staff engineer, flag CRITICAL/WARNING, end APPROVED/NEEDS_WORK: $(git diff --cached)" \
  || codex exec "Cross-LLM review (author Claude), flag CRITICAL/WARNING, end APPROVED or NEEDS_WORK: $(git diff --cached)"
# fix, re-review until clean, then:
git commit -m "feat(guardrail): deny out-of-worktree Edit/Write/NotebookEdit"
```

---

## Task 4: Wire the hook into `_spawn_orchestrator`

**Files:**
- Modify: `bin/deputy.sh` (`_spawn_orchestrator`)
- Modify: `tests/test_guardrail.sh` (settings-generation assertions)

- [ ] **Step 1: Add a failing test for the generated settings**

Append to `tests/test_guardrail.sh` (before final cleanup). This tests a small extracted helper `_guardrail_settings_path` that writes the settings file and echoes its path:
```bash
# --- _guardrail_settings_path writes a settings file referencing the hook (abs path) ---
gp="$(DEPUTY_ROOT="$ROOT" ROOT="$ROOT" SRC_DIR="$REPO" bash -c 'source "'"$REPO"'/bin/deputy.sh"; _guardrail_settings_path' 2>/dev/null)"
assert_eq "$([[ -f "$gp" ]] && echo yes || echo no)" "yes" "settings file generated"
assert_contains "$(cat "$gp")" "PreToolUse" "settings has PreToolUse hook"
assert_contains "$(cat "$gp")" "$REPO/hooks/guardrail.sh" "settings references the hook by abs path"
```
Note: sourcing `bin/deputy.sh` must not auto-run its dispatch. If it does, guard the helper test by calling the function in a subshell where `$1` is empty/no command — or (simpler) the implementer extracts `_guardrail_settings_path` such that sourcing is side-effect-free (deputy.sh already guards its `main "$@"` with the usual `${BASH_SOURCE[0]}` check; verify and rely on it).

- [ ] **Step 2: Run to confirm it fails**

Run: `bash tests/test_guardrail.sh`
Expected: FAIL (`_guardrail_settings_path` undefined).

- [ ] **Step 3: Implement the helper + wire the spawn**

In `bin/deputy.sh`, add near `_spawn_orchestrator`:
```bash
# Write a per-spawn Claude settings file registering the guardrail PreToolUse hook
# (absolute hook path), and echo its path. SRC_DIR is the deputy install dir.
_guardrail_settings_path() {
  local hook="$SRC_DIR/hooks/guardrail.sh"
  local f="$STATE_DIR/guardrail-settings.json"
  mkdir -p "$STATE_DIR"
  cat > "$f" <<JSON
{ "hooks": { "PreToolUse": [ { "matcher": "Bash|Edit|Write|MultiEdit|NotebookEdit",
  "hooks": [ { "type": "command", "command": "$hook" } ] } ] } }
JSON
  printf '%s' "$f"
}
```
Then in `_spawn_orchestrator`, change the real `claude -p` invocation (leave the
`DEPUTY_ORCHESTRATOR_CMD` mock path untouched) to export the guard env + pass `--settings`:
```bash
  local gset; gset="$(_guardrail_settings_path)"
  DEPUTY_GUARDED=1 DEPUTY_WT="$(_wt_path)" DEPUTY_ROOT="$ROOT" \
    claude -p "$prompt" --model claude-sonnet-4-6 \
      --allowedTools "Bash,Edit,Write,Read,Glob,Grep" \
      --settings "$gset"
```
(Confirm `_wt_path` and `STATE_DIR` and `SRC_DIR` are the correct existing variable names in `bin/deputy.sh`; adjust to match. `STATE_DIR` is the repo's `.deputy` dir.)

- [ ] **Step 4: Run tests + full suite**

Run: `bash tests/test_guardrail.sh && bash tests/run.sh; echo exit=$?`
Expected: PASS; suite exit 0.

- [ ] **Step 5: Cross-LLM review, then commit**

```bash
git add bin/deputy.sh tests/test_guardrail.sh
gemini -p "Review as a staff engineer, flag CRITICAL/WARNING, end APPROVED/NEEDS_WORK: $(git diff --cached)" \
  || codex exec "Cross-LLM review (author Claude), flag CRITICAL/WARNING, end APPROVED or NEEDS_WORK: $(git diff --cached)"
# fix, re-review until clean, then:
git commit -m "feat(guardrail): spawn orchestrator with DEPUTY_GUARDED env + --settings hook"
```

---

## Task 5: SKILL.md "Guardrail" prose (judgment-call half)

**Files:**
- Modify: `skills/deputy/SKILL.md` (add a section under "Hard rules")

- [ ] **Step 1: Add the Guardrail section**

Insert into `skills/deputy/SKILL.md` immediately after the "## Hard rules" list:
```markdown
## Guardrail (enforced + judgment)
A PreToolUse hook **blocks** these in headless runs — never attempt them (and never hand
them to a failover `codex`/`gemini`, which run unhooked): writes outside `.deputy/wt`;
`git push`, `crontab`, `install.sh`, `rm -r/-rf`, `git branch -D`, `git config --global`,
`git reset --hard`/`clean -f` outside the worktree, `sudo`, `gh pr merge`, global package
installs, and `deputy cron`. **If a tool call is blocked, that means SURFACE the item**
(`deputy set "<item-line>" surfaced` with a note) — do not try to work around the block.
Additionally, **surface (do not execute) judgment-call risky ops** the hook can't catch:
destructive data/DB operations, production/service changes, repo or directory renames, and
mass/irreversible rewrites.
```

- [ ] **Step 2: Verify SKILL.md still resolves + suite green**

Run: `[[ -e ~/.claude/skills/deputy/SKILL.md ]] && echo ok; bash tests/run.sh; echo exit=$?`
Expected: `ok`; suite exit 0 (prose-only change).

- [ ] **Step 3: Cross-LLM review, then commit**

```bash
git add skills/deputy/SKILL.md
gemini -p "Review as a staff engineer, flag CRITICAL/WARNING, end APPROVED/NEEDS_WORK: $(git diff --cached)" \
  || codex exec "Cross-LLM review (author Claude), flag CRITICAL/WARNING, end APPROVED or NEEDS_WORK: $(git diff --cached)"
git commit -m "docs(skill): add Guardrail section (enforced denylist + judgment-call surfacing)"
```

---

## Task 6: Final integration check

**Files:** none (verification only)

- [ ] **Step 1: Full suite green**

Run: `bash tests/run.sh; echo exit=$?`
Expected: exit 0, including `test_guardrail.sh`.

- [ ] **Step 2: Live smoke (guarded) — optional but recommended**

Run a real guarded `claude -p` against a scratch worktree dir and confirm a `git push`
attempt is blocked (reuses the Task-1 spike approach but with the real `hooks/guardrail.sh`
+ `DEPUTY_GUARDED=1 DEPUTY_WT=<scratch> DEPUTY_ROOT=<scratch>`):
```bash
d="$(mktemp -d)"; mkdir -p "$d/.deputy/wt"
s="$(DEPUTY_ROOT="$d" SRC_DIR="$(pwd)" bash -c 'source bin/deputy.sh; STATE_DIR="'"$d"'/.deputy" SRC_DIR="'"$(pwd)"'" _guardrail_settings_path')"
DEPUTY_GUARDED=1 DEPUTY_WT="$d/.deputy/wt" DEPUTY_ROOT="$d" \
  claude -p "Run bash: git push origin master" --settings "$s" --allowedTools "Bash" 2>&1 | tail -5
rm -rf "$d"
```
Expected: the push is blocked / not executed (no real push happens; this dir has no remote anyway).

- [ ] **Step 3: Final cross-LLM review of the whole branch diff vs master**

```bash
gemini -p "Staff-engineer review of the full guardrail feature, flag CRITICAL/WARNING, end APPROVED/NEEDS_WORK: $(git diff master...HEAD)" \
  || codex exec "Cross-LLM review (author Claude) of the full guardrail diff, flag CRITICAL/WARNING, end APPROVED or NEEDS_WORK: $(git diff master...HEAD)"
```
Fix anything surfaced, then this feature is ready for the done-gate merge to local master
(never auto-push — the human pushes).
```
