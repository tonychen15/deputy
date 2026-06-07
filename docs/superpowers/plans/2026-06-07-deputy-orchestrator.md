# Deputy Orchestrator & Integration — Implementation Plan (Plan 3 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Tie the queue engine (Plan 1) and provider primitives (Plan 2) into a working autonomous loop: `deputy run` claims the highest-priority item, runs it in an isolated worktree, and drives the orchestrator skill (triage → execute → review) across the routed CLIs; surfaced items and a morning report reach the human via a SessionStart hook; `install.sh` wires the skill, hook, and cron.

**Architecture:** The **thin runner** gains a `run` loop (recover → guard → pick → claim → worktree → spawn orchestrator → handle outcome → handoff). The **orchestrator** is a prompt (`skills/deputy/SKILL.md`) the runner spawns headless via `claude -p` (or the human invokes interactively); it performs LLM judgment and calls back into the `deputy` CLI to mutate state. The spawn point (`_spawn_orchestrator`) is **mockable** (`$DEPUTY_ORCHESTRATOR_CMD`) so the loop is unit-testable without real LLMs. Worktree, config, protected-path, and hook logic are pure bash and TDD'd.

**Tech Stack:** Bash 5.2, git worktrees, the Plan-1/2 deputy functions, claude/gemini/codex CLIs, waypoint + xReview (Claude-bound in V1). Same dependency-free harness.

**Scope (this plan):** `run` loop + `_spawn_orchestrator`; worktree helpers; `.deputy/config` + `.deputy/protected` loading and the deterministic protected-path commit gate; `hooks/session-start.sh`; `skills/deputy/SKILL.md`; `install.sh` skill/hook/cron wiring; e2e smoke. **Honest limit:** the orchestrator's autonomous triage/waypoint/xReview behavior is validated by a live smoke, not unit tests.

**Conventions:** as Plans 1–2. New bash funcs above `main`; new subcommands as `case` arms. Mockable IO via env overrides so no test spawns a real LLM.

---

## File Structure

| File | Change |
|---|---|
| `bin/deputy.sh` | add worktree helpers, `_load_config`, `_protected_violation`, `_spawn_orchestrator`, `cmd_run`, dispatch arms + usage |
| `skills/deputy/SKILL.md` | the orchestrator prompt (the "one brain") |
| `hooks/session-start.sh` | surfacing banner + morning report |
| `templates/config` | `.deputy/config` defaults (test_cmd/lint_cmd/build_cmd, max_items, time_cap) |
| `templates/protected` | default protected-path globs |
| `install.sh` | extend `link` to install skill + hook; add `init` config/protected seeding; optional `--cron` |
| `tests/test_run.sh` | run loop with a mock orchestrator |
| `tests/test_worktree.sh` | worktree create/remove in a temp git repo |
| `tests/test_protected.sh` | config load + protected-path gate |
| `tests/test_hook.sh` | session-start output |

---

## Task 1: `.deputy/config` + protected-path gate

**Files:** Modify `bin/deputy.sh`; create `templates/config`, `templates/protected`, `tests/test_protected.sh`.

`_load_config` reads `KEY=VALUE` lines from `.deputy/config` into shell vars `CFG_<KEY>` (ignoring comments/blank). `_protected_violation <newline-separated-paths>` returns 0 (violation) if any path matches a glob in `.deputy/protected`, else 1.

- [ ] **Step 1: Create `templates/config`:**
```ini
# Deputy per-repo config. KEY=VALUE, one per line.
test_cmd=
lint_cmd=
build_cmd=
max_items=5
time_cap_mins=30
```

- [ ] **Step 2: Create `templates/protected`:**
```gitignore
.env*
secrets/**
.git/**
.deputy/**
infra/**
```

- [ ] **Step 3: Write `tests/test_protected.sh`:**
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
mkdir -p "$DEPUTY_ROOT/.deputy"
printf 'test_cmd=make test\nmax_items=3\n# comment\n\n' > "$DEPUTY_ROOT/.deputy/config"
printf '.env*\nsecrets/**\n' > "$DEPUTY_ROOT/.deputy/protected"

assert_eq "$(bash "$DEPUTY" config test_cmd)"  "make test" "config reads test_cmd"
assert_eq "$(bash "$DEPUTY" config max_items)" "3"         "config reads max_items"
assert_eq "$(bash "$DEPUTY" config missing)"   ""          "config missing key empty"

# protected check: returns 0 (violation) if any path matches
bash "$DEPUTY" protected ".env.local"; assert_eq "$?" "0" "protected matches .env.local"
bash "$DEPUTY" protected "secrets/key.pem"; assert_eq "$?" "0" "protected matches secrets glob"
bash "$DEPUTY" protected "src/main.py"; assert_eq "$?" "1" "protected allows normal path"
printf 'src/a.py\nsecrets/b\n' | { bash "$DEPUTY" protected --stdin; assert_eq "$?" "0" "protected detects in a list"; }
```

- [ ] **Step 4: Run — confirm FAIL.**

- [ ] **Step 5: Implement.** Add above `main`:
```bash
# Read a single key from .deputy/config (KEY=VALUE). Echoes the value or empty.
_config_get() {
  local key="$1" cfg="$STATE_DIR/config" line k v
  [[ -f "$cfg" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"; v="${line#*=}"
    k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"  # trim
    if [[ "$k" == "$key" ]]; then printf '%s\n' "$v"; return 0; fi
  done < "$cfg"
}

# True (0) if any path (newline-separated, from $1 or stdin) matches a glob in
# .deputy/protected. Deterministic; used as the pre-commit gate.
_protected_violation() {
  local input="$1" prot="$STATE_DIR/protected" path glob
  [[ -f "$prot" ]] || return 1
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    while IFS= read -r glob; do
      [[ -n "$glob" && "$glob" != \#* ]] || continue
      case "$path" in $glob) return 0 ;; esac
    done < "$prot"
  done <<< "$input"
  return 1
}
```
Add dispatch arms:
```bash
    config) shift; _config_get "${1:-}"; return 0 ;;
    protected) shift
      if [[ "${1:-}" == "--stdin" ]]; then _protected_violation "$(cat)"; else _protected_violation "${1:-}"; fi
      return $? ;;
```

- [ ] **Step 6: Run — confirm `7 run, 0 failed`**, full suite green.
- [ ] **Step 7: Commit** `feat(runner): config loader + deterministic protected-path gate`.

NOTE: the `case "$path" in $glob)` relies on unquoted `$glob` for globbing; `secrets/**` matches under bash default globbing only partially (`**` == `*` without globstar). For the gate, treat `secrets/**` as `secrets/*` semantics; document that nested matching uses a prefix check. If a glob ends in `/**`, also match the prefix dir: add a special case `[[ "$path" == "${glob%/**}/"* ]]`.

---

## Task 2: worktree helpers

**Files:** Modify `bin/deputy.sh`; create `tests/test_worktree.sh`.

`_wt_path` echoes `$STATE_DIR/wt`. `_wt_create <slug>` makes the worktree on branch `deputy/<slug>` from HEAD (new branch, or attach if it exists — for resume). `_wt_remove` removes it and prunes. Requires the repo to be a real git repo.

- [ ] **Step 1: Write `tests/test_worktree.sh`:**
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
# make the temp root a real git repo with one commit
git -C "$DEPUTY_ROOT" init -q
git -C "$DEPUTY_ROOT" config user.email t@t; git -C "$DEPUTY_ROOT" config user.name t
git -C "$DEPUTY_ROOT" add -A; git -C "$DEPUTY_ROOT" commit -qm init

bash "$DEPUTY" wt-create fix-thing
assert_eq "$([[ -d "$DEPUTY_ROOT/.deputy/wt" ]] && echo yes || echo no)" "yes" "worktree created"
assert_eq "$(git -C "$DEPUTY_ROOT/.deputy/wt" rev-parse --abbrev-ref HEAD)" "deputy/fix-thing" "on item branch"

bash "$DEPUTY" wt-remove
assert_eq "$([[ -d "$DEPUTY_ROOT/.deputy/wt" ]] && echo yes || echo no)" "no" "worktree removed"
# branch survives
assert_contains "$(git -C "$DEPUTY_ROOT" branch)" "deputy/fix-thing" "branch preserved after remove"

# resume: re-create attaching to existing branch
bash "$DEPUTY" wt-create fix-thing
assert_eq "$(git -C "$DEPUTY_ROOT/.deputy/wt" rev-parse --abbrev-ref HEAD)" "deputy/fix-thing" "resume attaches branch"
bash "$DEPUTY" wt-remove
```

- [ ] **Step 2: Run — confirm FAIL.**

- [ ] **Step 3: Implement.** Add above `main`:
```bash
_wt_path() { printf '%s/wt' "$STATE_DIR"; }

# Create the execution worktree on branch deputy/<slug>. New branch from HEAD, or
# attach to it if it already exists (resume / forward-recovery).
_wt_create() {
  local slug="$1" wt branch
  wt="$(_wt_path)"; branch="deputy/$slug"
  [[ -e "$wt" ]] && git -C "$ROOT" worktree remove --force "$wt" 2>/dev/null || true
  if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$ROOT" worktree add "$wt" "$branch" >/dev/null
  else
    git -C "$ROOT" worktree add "$wt" -b "$branch" >/dev/null
  fi
}

_wt_remove() {
  local wt; wt="$(_wt_path)"
  [[ -e "$wt" ]] && git -C "$ROOT" worktree remove --force "$wt" 2>/dev/null || true
  git -C "$ROOT" worktree prune 2>/dev/null || true
}
```
Add dispatch arms:
```bash
    wt-create) shift; _wt_create "${1:?slug}"; return 0 ;;
    wt-remove) shift; _wt_remove; return 0 ;;
```

- [ ] **Step 4: Run — confirm `5 run, 0 failed`**, full suite green.
- [ ] **Step 5: Commit** `feat(runner): git-worktree create/remove for isolated execution`.

---

## Task 3: `run` loop (mockable orchestrator)

**Files:** Modify `bin/deputy.sh`; create `tests/test_run.sh`.

`_spawn_orchestrator <item-line> <provider>` invokes `${DEPUTY_ORCHESTRATOR_CMD:-claude}` — overridable for tests. `cmd_run`:
1. `recover`. 2. if a live claim exists → exit 0 (another run active). 3. `pick` an item; none → exit 0. 4. probe → availability; if `route orchestrate` == wait → `cron --reschedule` (best-effort) + exit 0. 5. claim the item. 6. spawn orchestrator. 7. the orchestrator is responsible for marking the item done/failed/surfaced and committing; `run` just cleans the claim afterward and re-invokes if work remains and `max_items` not hit.

For V1 test scope, the loop is verified with a **mock orchestrator** that marks the item done via `deputy set`.

- [ ] **Step 1: Write `tests/test_run.sh`:**
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
bash "$DEPUTY" add "do a thing" --p0

# Mock orchestrator: receives the item line as $1; marks it done.
ORCH="$(mktemp)"
cat > "$ORCH" <<EOF
#!/usr/bin/env bash
# args: <item-line> <provider>
bash "$DEPUTY" set "\$1" done >/dev/null 2>&1 || true
EOF
chmod +x "$ORCH"

# Force availability + a no-op cron so run doesn't touch real crontab.
out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude,gemini" DEPUTY_CRONTAB=/bin/true \
  bash "$DEPUTY" run --once 2>&1)"
assert_contains "$(bash "$DEPUTY" list)" "done|P0|do a thing" "run drove orchestrator to done"
assert_eq "$(ls "$DEPUTY_ROOT"/.deputy/*.claim 2>/dev/null | wc -l)" "0" "no stale claim left"

# Nothing waiting -> run is a clean no-op
out="$(DEPUTY_ORCHESTRATOR_CMD="$ORCH" DEPUTY_AVAIL="claude" DEPUTY_CRONTAB=/bin/true bash "$DEPUTY" run --once 2>&1)"; rc=$?
assert_eq "$rc" "0" "run no-op exits 0"
rm -f "$ORCH"
```

- [ ] **Step 2: Run — confirm FAIL.**

- [ ] **Step 3: Implement.** Add above `main`:
```bash
# Availability csv: $DEPUTY_AVAIL override (tests), else probe the three CLIs.
_availability() {
  if [[ -n "${DEPUTY_AVAIL:-}" ]]; then printf '%s\n' "$DEPUTY_AVAIL"; return 0; fi
  local c avail=""
  for c in claude gemini codex; do [[ "$(_probe "$c")" == ok ]] && avail+="$c,"; done
  printf '%s\n' "$avail"
}

_spawn_orchestrator() { "${DEPUTY_ORCHESTRATOR_CMD:-claude}" "$@"; }

# A single tick: claim the top item and hand it to the orchestrator.
cmd_run() {
  local once=0; [[ "${1:-}" == "--once" ]] && once=1
  _with_lock cmd_recover >/dev/null 2>&1 || true
  if _live_claim_exists; then return 0; fi
  local item; item="$(cmd_pick)"
  [[ -n "$item" ]] || return 0
  local avail decision; avail="$(_availability)"; decision="$(_route orchestrate "$avail")"
  if [[ "$decision" != "claude" ]]; then
    cmd_cron --reschedule "orchestrator unavailable" >/dev/null 2>&1 || true
    return 0
  fi
  cmd_claim "$item" --pid "$$" >/dev/null 2>&1 || return 0
  set +e
  _spawn_orchestrator "$item" "$decision"
  set -e
  # The orchestrator owns final state (done/failed/surfaced). Release our claim.
  rm -f "$STATE_DIR/$$.claim" 2>/dev/null || true
  # Handoff: if work remains and not --once, loop (bounded by max_items handled by orchestrator/runner caller).
  if [[ "$once" -eq 0 ]]; then
    local remaining; remaining="$(cmd_pick)"
    [[ -n "$remaining" ]] && cmd_run
  fi
  return 0
}
```
Add dispatch arm:
```bash
    run) shift; cmd_run "$@"; return 0 ;;
```

- [ ] **Step 4: Run — confirm `3 run, 0 failed`**, full suite green.
- [ ] **Step 5: Commit** `feat(runner): run loop (recover/pick/claim/spawn orchestrator, mockable)`.

---

## Task 4: SessionStart hook (surfacing + morning report)

**Files:** create `hooks/session-start.sh`, `tests/test_hook.sh`.

The hook reads `$DEPUTY_ROOT` (or git toplevel) and prints a one-block summary: surfaced items needing input, plus counts of done/failed since — for V1, just current counts + the surfaced list + a pointer to `deputy review`. Pure read.

- [ ] **Step 1: Write `tests/test_hook.sh`:**
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
HOOK="$REPO/hooks/session-start.sh"
setup_repo
bash "$DEPUTY" add "needs your call" --p0
line="$(bash "$DEPUTY" pick)"
bash "$DEPUTY" set "$line" surfaced
bash "$DEPUTY" add "a done one" >/dev/null; dl="$(bash "$DEPUTY" pick)"  # not done; just counts
out="$(DEPUTY_ROOT="$DEPUTY_ROOT" bash "$HOOK")"
assert_contains "$out" "needs your call" "hook lists surfaced item"
assert_contains "$out" "deputy review" "hook points to review"

# No surfaced items -> quiet (no banner noise)
setup_repo
out="$(DEPUTY_ROOT="$DEPUTY_ROOT" bash "$HOOK")"
assert_eq "$out" "" "hook silent when nothing surfaced"
```

- [ ] **Step 2: Run — confirm FAIL.**

- [ ] **Step 3: Implement `hooks/session-start.sh`:**
```bash
#!/usr/bin/env bash
# Deputy SessionStart hook: surface items needing input + a one-line digest.
# Prints nothing if there is nothing surfaced (no banner noise).
set -uo pipefail
ROOT="${DEPUTY_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
DEP="$(command -v deputy || true)"
[[ -n "$DEP" && -f "$ROOT/BACKLOG.md" ]] || exit 0

surfaced="$(DEPUTY_ROOT="$ROOT" "$DEP" list | awk -F'|' '$1=="surfaced"{print "  ? " $3}')"
[[ -n "$surfaced" ]] || exit 0

counts="$(DEPUTY_ROOT="$ROOT" "$DEP" status | tr '\n' ' ')"
printf '⚠️  Deputy: items need your input\n%s\n[%s]\nRun: deputy review\n' "$surfaced" "$counts"
```

- [ ] **Step 4: Run — confirm `3 run, 0 failed`**, full suite green.
- [ ] **Step 5: Commit** `feat(hook): SessionStart surfacing + digest`.

---

## Task 5: the orchestrator skill `skills/deputy/SKILL.md`

**Files:** create `skills/deputy/SKILL.md`. (Authored prompt; no unit test — validated by the live smoke in Task 7.)

- [ ] **Step 1: Write `skills/deputy/SKILL.md`** capturing the design's orchestrator loop:
  - Front matter: name `deputy`, description (triggers: "deputy run", "/deputy", "work the backlog").
  - The loop: given an item, (1) **triage** simple vs complex (honor `.deputy/<slug>.meta` override; bias to complex when unsure); (2) **simple** → in `.deputy/wt` (call `deputy wt-create <slug>`), do the work, run the quality gate (`deputy config test_cmd`), gate each commit through the protected-path check (`git diff --cached --name-only | deputy protected --stdin`) and **xReview via Gemini**, then `deputy set "<line>" done`, open a PR or leave the branch, `deputy wt-remove`; (3) **complex** → if one is already surfaced, leave untouched; else draft questions to `.deputy/<slug>.questions.md`, `deputy set "<line>" surfaced`, stop; when the human engages, grill → plan review (Gemini) → design review → approval → headless waypoint execution (xReview per commit); (4) failures: retry ≤2, then surface (complex) or `deputy set "<line>" failed` (simple); (5) quota: reroute simple coding to codex, else `deputy cron --reschedule`.
  - Rules: never edit `BACKLOG.md` directly (use `deputy set/claim`); never touch `.deputy/protected` paths; respect `max_items`/`time_cap`.

- [ ] **Step 2: Sanity-check** the SKILL.md is valid markdown with front matter and references only real `deputy` subcommands (`grep` for each referenced subcommand in `bin/deputy.sh`).
- [ ] **Step 3: Commit** `feat(skill): deputy orchestrator skill (the one brain)`.

---

## Task 6: `install.sh` — wire skill, hook, cron

**Files:** Modify `install.sh`; extend `tests/test_install.sh`.

- `link` also: symlink `skills/deputy` into the global skills dir (`${DEPUTY_SKILLS_DIR:-$HOME/.claude/skills}/deputy`) and the SessionStart hook into the repo or global hooks (configurable; for V1 print the hook path + how to register).
- `init` also: seed `.deputy/config` and `.deputy/protected` from templates (idempotent, no clobber).
- `install.sh cron` → `deputy cron --ensure` (opt-in).

- [ ] **Step 1: Extend `tests/test_install.sh`** — init seeds config+protected; link installs skill into a temp `$DEPUTY_SKILLS_DIR`. (Full code in the task.)
- [ ] **Step 2: Run — confirm FAIL.**
- [ ] **Step 3: Implement** the `cmd_link` skill/hook additions and `cmd_init` config/protected seeding (idempotent).
- [ ] **Step 4: Run — confirm green**, full suite green.
- [ ] **Step 5: Commit** `feat(install): wire orchestrator skill, hook, config/protected, cron`.

---

## Task 7: e2e smoke + finalize

- [ ] **Step 1: Full suite** green.
- [ ] **Step 2: Mock e2e** — in a temp git repo: seed via `install.sh init`, `deputy add` a couple items, run `DEPUTY_ORCHESTRATOR_CMD=<mock> DEPUTY_AVAIL=claude,gemini DEPUTY_CRONTAB=/bin/true deputy run --once`, confirm the item reaches `done` and no stale claim/worktree remains.
- [ ] **Step 3: Live smoke (best-effort, documented)** — with real `claude`, run a single trivial simple item end-to-end in a scratch git repo and report what happened (this is the only real validation of the orchestrator prompt; note any gaps).
- [ ] **Step 4: Update the design spec** status to "implemented (V1)" and note the live-validation results.
- [ ] **Step 5: Commit** `docs: mark Deputy V1 implemented; record live smoke`.

---

## Self-Review (completed during authoring)

**Spec coverage (Plan-3 slice):** run loop (Task 3) ✓; worktree isolation (Task 2) ✓; config + protected-path deterministic gate (Task 1) ✓; SessionStart surfacing (Task 4) ✓; orchestrator skill with triage/waypoint/xReview/routing (Task 5) ✓; install wiring (Task 6) ✓; e2e + live smoke (Task 7) ✓.

**Testability:** every bash unit is tested with mocks (`$DEPUTY_ORCHESTRATOR_CMD`, `$DEPUTY_AVAIL`, `$DEPUTY_CRONTAB`, `$DEPUTY_SKILLS_DIR`) — no test spawns a real LLM or writes a real crontab/skills dir. The SKILL.md prompt and the waypoint/xReview live integration are validated by Task 7's live smoke only; this limit is called out explicitly.

**Name consistency:** `_wt_path/_wt_create/_wt_remove`, `_config_get`, `_protected_violation`, `_availability`, `_spawn_orchestrator`, `cmd_run` defined before use; subcommands `config/protected/wt-create/wt-remove/run` match dispatch arms; env overrides spelled identically in code and tests.

**Open risk:** `_protected_violation` glob semantics for `**` are limited under bash default globbing — Task 1 handles `/**` via a prefix check; deeper patterns are documented as best-effort.
