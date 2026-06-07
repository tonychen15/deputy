# Deputy Scheduling, CLI Adapters & Routing — Implementation Plan (Plan 2 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add the mechanical provider + scheduling primitives the orchestrator (Plan 3) will call: classify a CLI invocation's outcome, probe a CLI's availability, decide which provider handles a given work kind, and manage the cron safety-net / rate-limit reschedule.

**Architecture:** Pure-bash functions added to `bin/deputy.sh` (kept self-contained — symlink-safe, no sourced libs). The decision logic (`_detect_outcome`, `_route`) is **pure** and unit-tested with fixtures; the IO parts (`_probe`, cron) are tested with **mock CLIs on PATH** and a **crontab-command override** so no real LLM calls or real crontab writes happen in tests. Plan 3 wires these into the actual run loop + orchestrator spawn.

**Tech Stack:** Bash 5.2, coreutils, `crontab` (overridable via `$DEPUTY_CRONTAB`). Same dependency-free test harness as Plan 1.

**Scope (this plan):** `detect`, `probe`, `route`, `cron` subcommands + their helpers. **Out of scope** (Plan 3): the orchestrator skill, the actual claim→spawn run loop, worktree execution, waypoint/xReview wiring, SessionStart hook, install of skill/hooks.

**Conventions:**
- Run commands from repo root `/home/tong/src/tonychen15/jobflow`.
- Providers: `claude`, `gemini`, `codex`. Roles (spec §8): claude = orchestration/planning + primary coder; gemini = primary reviewer; codex = failover coder for *simple* coding when claude is quota-limited; complex/waypoint work waits for claude.
- Outcome classes: `ok | quota_exhausted | auth_error | hard_error`. Conservative default: an unrecognized non-zero exit is `hard_error` (never falsely `quota_exhausted`).
- All new functions go **above `main`** in `bin/deputy.sh`; each new subcommand gets a `case` arm before the `*)` catch-all.

---

## File Structure

| File | Change |
|---|---|
| `bin/deputy.sh` | add `_detect_outcome`, `_route`, `_probe`, `_set_cron`/`_parse_reset_hour`/`cmd_cron`, and `detect`/`route`/`probe`/`cron` dispatch arms + usage |
| `tests/test_detect.sh` | outcome classification fixtures |
| `tests/test_route.sh` | provider routing logic |
| `tests/test_probe.sh` | probe via mock CLIs |
| `tests/test_cron.sh` | cron set/reschedule via `$DEPUTY_CRONTAB` override + reset-hour parse |

---

## Task 1: `_detect_outcome` — classify a CLI invocation

**Files:**
- Modify: `bin/deputy.sh`
- Create: `tests/test_detect.sh`

`_detect_outcome <cli> <exit_code> <logfile>` echoes one of `ok|quota_exhausted|auth_error|hard_error`. Exit 0 → `ok`. Otherwise match per-CLI quota patterns, then common auth patterns, else `hard_error`.

- [ ] **Step 1: Write the failing test** — create `tests/test_detect.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

# helper: write content to a temp log and classify
det() {  # det <cli> <exit_code> <content>
  local f; f="$(mktemp)"; printf '%s\n' "$3" > "$f"
  bash "$DEPUTY" detect "$1" "$2" "$f"
  rm -f "$f"
}

assert_eq "$(det claude 0 'all good')"                       "ok"              "exit 0 is ok"
assert_eq "$(det claude 1 'You have hit your limit; resets 11pm')" "quota_exhausted" "claude limit"
assert_eq "$(det gemini 1 'Error: RESOURCE_EXHAUSTED 429')"  "quota_exhausted" "gemini 429"
assert_eq "$(det codex 1 'You have reached your usage limit')" "quota_exhausted" "codex usage limit"
assert_eq "$(det claude 1 'Please run /login to authenticate')" "auth_error"   "auth pattern"
assert_eq "$(det claude 1 'segfault: core dumped')"          "hard_error"      "unknown nonzero is hard_error"
assert_eq "$(det gemini 2 'random failure text')"            "hard_error"      "conservative default"
```

- [ ] **Step 2: Run — confirm FAIL** (`detect` unknown): `bash tests/test_detect.sh`

- [ ] **Step 3: Implement.** Add above `main` in `bin/deputy.sh`:

```bash
# Classify a CLI invocation outcome: ok|quota_exhausted|auth_error|hard_error.
# Conservative: an unrecognized non-zero exit is hard_error, never quota_exhausted.
_detect_outcome() {
  local cli="$1" rc="$2" log="$3" content=""
  [[ "$rc" -eq 0 ]] && { printf 'ok\n'; return 0; }
  [[ -f "$log" ]] && content="$(cat "$log")"
  local lc="${content,,}"   # lowercase for case-insensitive matching
  case "$cli" in
    claude) [[ "$lc" == *"hit your limit"* || "$lc" == *"usage limit"* || "$lc" == *"rate limit"* ]] \
              && { printf 'quota_exhausted\n'; return 0; } ;;
    gemini) [[ "$lc" == *"resource_exhausted"* || "$lc" == *"429"* || "$lc" == *"quota"* ]] \
              && { printf 'quota_exhausted\n'; return 0; } ;;
    codex)  [[ "$lc" == *"usage limit"* || "$lc" == *"rate limit"* || "$lc" == *"quota"* ]] \
              && { printf 'quota_exhausted\n'; return 0; } ;;
  esac
  case "$lc" in
    *"not authenticated"*|*"please log in"*|*"/login"*|*"api key"*|*"sign in"*|*"unauthorized"*) \
      printf 'auth_error\n'; return 0 ;;
  esac
  printf 'hard_error\n'
}
```

Add dispatch arm in `main` (before `*)`):
```bash
    detect) shift; _detect_outcome "${1:-}" "${2:-0}" "${3:-/dev/null}"; return 0 ;;
```

- [ ] **Step 4: Run — confirm `7 run, 0 failed`**, then `bash tests/run.sh; echo exit=$?` all green.

- [ ] **Step 5: Commit**
```bash
git add bin/deputy.sh tests/test_detect.sh
git commit -m "feat(runner): _detect_outcome CLI classifier (ok/quota/auth/hard)"
```

---

## Task 2: `_route` — pick a provider for a work kind

**Files:**
- Modify: `bin/deputy.sh`
- Create: `tests/test_route.sh`

`_route <kind> <available-csv>` echoes the chosen provider, or `wait` (claude-bound work but claude unavailable), or `none` (no provider). Kinds: `orchestrate`, `code-complex`, `code-simple`, `review`. `available-csv` is a comma list like `claude,gemini`.

Routing rules (spec §8):
- `orchestrate`, `code-complex` → `claude` if available else `wait` (claude-bound).
- `code-simple` → `claude` if available; else `codex` if available; else `wait`.
- `review` → `gemini` if available; else `wait`.

- [ ] **Step 1: Write the failing test** — create `tests/test_route.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo
r() { bash "$DEPUTY" route "$1" "$2"; }

assert_eq "$(r orchestrate claude,gemini,codex)" "claude" "orchestrate -> claude"
assert_eq "$(r orchestrate gemini,codex)"        "wait"   "orchestrate waits if no claude"
assert_eq "$(r code-complex claude)"             "claude" "complex -> claude"
assert_eq "$(r code-complex codex)"              "wait"   "complex waits (claude-bound) even if codex up"
assert_eq "$(r code-simple claude,codex)"        "claude" "simple prefers claude"
assert_eq "$(r code-simple gemini,codex)"        "codex"  "simple fails over to codex"
assert_eq "$(r code-simple gemini)"              "wait"   "simple waits if neither claude nor codex"
assert_eq "$(r review claude,gemini)"            "gemini" "review -> gemini"
assert_eq "$(r review claude,codex)"             "wait"   "review waits if no gemini"
```

- [ ] **Step 2: Run — confirm FAIL.**

- [ ] **Step 3: Implement.** Add above `main`:

```bash
# True if $1 appears in the comma-separated list $2.
_in_csv() { case ",$2," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# Choose a provider for a work kind given available providers (csv).
# Echoes: a provider name | "wait" (claude-bound work, claude down) | "none".
_route() {
  local kind="$1" avail="$2"
  case "$kind" in
    orchestrate|code-complex)
      _in_csv claude "$avail" && { printf 'claude\n'; return 0; }
      printf 'wait\n' ;;
    code-simple)
      _in_csv claude "$avail" && { printf 'claude\n'; return 0; }
      _in_csv codex  "$avail" && { printf 'codex\n';  return 0; }
      printf 'wait\n' ;;
    review)
      _in_csv gemini "$avail" && { printf 'gemini\n'; return 0; }
      printf 'wait\n' ;;
    *) printf 'none\n'; return 2 ;;
  esac
}
```

Add dispatch arm:
```bash
    route) shift; _route "${1:-}" "${2:-}"; return $? ;;
```

- [ ] **Step 4: Run — confirm `9 run, 0 failed`**, then full suite green.

- [ ] **Step 5: Commit**
```bash
git add bin/deputy.sh tests/test_route.sh
git commit -m "feat(runner): _route provider selection by work kind + availability"
```

---

## Task 3: `_probe` — availability of a CLI (mock-tested)

**Files:**
- Modify: `bin/deputy.sh`
- Create: `tests/test_probe.sh`

`_probe <cli>` echoes `ok|quota_exhausted|auth_error|hard_error|absent`. `absent` if the CLI is not on PATH. Otherwise it runs a trivial prompt, captures exit code + output, and classifies via `_detect_outcome`. The probe command per CLI is `"$cli" -p ping` (claude/gemini) / `"$cli" exec ping` (codex) — but to stay testable and simple, use `"$cli" --version`-style liveness is insufficient for auth; instead run the cli with a minimal prompt and a short timeout. Tests stub each CLI with a mock on PATH.

- [ ] **Step 1: Write the failing test** — create `tests/test_probe.sh`:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
setup_repo

# Build a fake PATH dir holding mock CLIs.
BIN="$(mktemp -d)"
mk() {  # mk <name> <exit_code> <stdout-text>
  printf '#!/usr/bin/env bash\necho %q\nexit %s\n' "$3" "$2" > "$BIN/$1"
  chmod +x "$BIN/$1"
}

# claude healthy
mk claude 0 "pong"
assert_eq "$(PATH="$BIN:$PATH" bash "$DEPUTY" probe claude)" "ok" "probe ok"

# gemini quota-limited
mk gemini 1 "Error: RESOURCE_EXHAUSTED"
assert_eq "$(PATH="$BIN:$PATH" bash "$DEPUTY" probe gemini)" "quota_exhausted" "probe quota"

# codex absent (remove it)
rm -f "$BIN/codex"
assert_eq "$(PATH="$BIN:$PATH" bash "$DEPUTY" probe codex)" "absent" "probe absent"

rm -rf "$BIN"
```

- [ ] **Step 2: Run — confirm FAIL.**

- [ ] **Step 3: Implement.** Add above `main`:

```bash
# The trivial liveness prompt invocation per CLI (overridable for tests via funcs).
_probe_cmd() {
  case "$1" in
    claude) claude -p "ping" ;;
    gemini) gemini -p "ping" ;;
    codex)  codex exec "ping" ;;
    *) return 127 ;;
  esac
}

# Probe a CLI: absent | ok | quota_exhausted | auth_error | hard_error.
_probe() {
  local cli="$1"
  command -v "$cli" >/dev/null 2>&1 || { printf 'absent\n'; return 0; }
  local log rc
  log="$(mktemp)"
  set +e
  _probe_cmd "$cli" >"$log" 2>&1
  rc=$?
  set -e
  _detect_outcome "$cli" "$rc" "$log"
  rm -f "$log"
}
```

Add dispatch arm:
```bash
    probe) shift; _probe "${1:-}"; return 0 ;;
```

- [ ] **Step 4: Run — confirm `3 run, 0 failed`**, then full suite green.

NOTE: `_probe_cmd` calls the real CLIs by name, so the mock-on-PATH approach works because the mocks shadow the real ones. Real-CLI probe behavior (actual `claude -p ping` etc.) is validated manually in Task 5, not in the unit suite.

- [ ] **Step 5: Commit**
```bash
git add bin/deputy.sh tests/test_probe.sh
git commit -m "feat(runner): _probe CLI availability via trivial prompt + detect"
```

---

## Task 4: cron safety-net + rate-limit reschedule

**Files:**
- Modify: `bin/deputy.sh`
- Create: `tests/test_cron.sh`

Manage exactly one Deputy cron entry, mirroring research.sh's `set_cron`. Make it testable by routing all crontab access through `$DEPUTY_CRONTAB` (default: the real `crontab`). `_parse_reset_hour <text>` extracts a 24h hour from "resets 11pm"/"resets 3am" (else empty). `cmd_cron`:
- `cron --ensure` → install the safety-net schedule (default every 2h) if absent.
- `cron --reschedule "<reset text>"` → set a one-shot-ish schedule at the parsed reset hour, else default 2h.
- `cron --remove` → remove the Deputy entry.

- [ ] **Step 1: Write the failing test** — create `tests/test_cron.sh`:

```bash
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

# remove
bash "$DEPUTY" cron --remove
assert_eq "$(grep -c 'deputy' "$STORE")" "0" "remove deletes entry"

# reset-hour parser unit checks via a hidden subcommand
assert_eq "$(bash "$DEPUTY" _resethour 'resets 3am')"  "3"  "3am -> 3"
assert_eq "$(bash "$DEPUTY" _resethour 'resets 12am')" "0"  "12am -> 0"
assert_eq "$(bash "$DEPUTY" _resethour 'resets 12pm')" "12" "12pm -> 12"
assert_eq "$(bash "$DEPUTY" _resethour 'no time here')" ""  "no match -> empty"

rm -f "$STORE" "$FAKE"
```

- [ ] **Step 2: Run — confirm FAIL.**

- [ ] **Step 3: Implement.** Add above `main`:

```bash
_crontab() { "${DEPUTY_CRONTAB:-crontab}" "$@"; }

# Extract a 24h hour from "resets 11pm" / "resets 3am". Echoes nothing if no match.
_parse_reset_hour() {
  local s="${1,,}" h ampm
  [[ "$s" =~ ([0-9]+)[[:space:]]*(am|pm) ]] || return 0
  h="${BASH_REMATCH[1]}"; ampm="${BASH_REMATCH[2]}"
  if [[ "$ampm" == "pm" && "$h" -lt 12 ]]; then h=$((h + 12))
  elif [[ "$ampm" == "am" && "$h" -eq 12 ]]; then h=0; fi
  printf '%s\n' "$h"
}

# Replace the single deputy cron line with $1 (empty $1 removes it). Marker: a
# trailing "# deputy" comment so we own exactly our line.
_set_cron() {
  local schedule="$1" existing filtered
  existing="$(_crontab -l 2>/dev/null || true)"
  filtered="$(printf '%s\n' "$existing" | grep -v '# deputy' || true)"
  {
    printf '%s\n' "$filtered" | grep -v '^[[:space:]]*$' || true
    [[ -n "$schedule" ]] && printf '%s deputy run  # deputy\n' "$schedule"
  } | _crontab -
}

cmd_cron() {
  case "${1:-}" in
    --ensure)     _set_cron "0 */2 * * *" ;;
    --remove)     _set_cron "" ;;
    --reschedule) local h; h="$(_parse_reset_hour "${2:-}")"
                  if [[ -n "$h" ]]; then _set_cron "0 $h * * *"; else _set_cron "0 */2 * * *"; fi ;;
    *) printf 'deputy: cron needs --ensure|--remove|--reschedule "<text>"\n' >&2; return 2 ;;
  esac
}
```

Add dispatch arms:
```bash
    cron) shift; cmd_cron "$@"; return $? ;;
    _resethour) shift; _parse_reset_hour "${1:-}"; return 0 ;;
```

- [ ] **Step 4: Run — confirm `9 run, 0 failed`**, then full suite green.

- [ ] **Step 5: Commit**
```bash
git add bin/deputy.sh tests/test_cron.sh
git commit -m "feat(runner): cron safety-net + rate-limit reschedule (crontab-overridable)"
```

---

## Task 5: usage + manual smoke + finalize

**Files:**
- Modify: `bin/deputy.sh` (usage text)

- [ ] **Step 1: Update `usage()`** — add the new commands under the existing list:

```
  detect <cli> <rc> <log>         (internal) classify a CLI outcome
  probe <cli>                     check a provider's availability
  route <kind> <avail-csv>        choose a provider (orchestrate|code-complex|code-simple|review)
  cron --ensure|--remove|--reschedule "<text>"   manage the safety-net schedule
```

- [ ] **Step 2: Full suite** — `bash tests/run.sh; echo exit=$?` → all green, exit 0.

- [ ] **Step 3: Manual smoke (real CLIs, may vary by environment)** — run and report; do NOT assert exact provider since availability is environment-dependent:
```bash
deputy probe claude; deputy probe gemini; deputy probe codex
deputy route code-simple "$(for c in claude gemini codex; do [[ "$(deputy probe $c)" == ok ]] && printf '%s,' "$c"; done)"
```

- [ ] **Step 4: Commit**
```bash
git add bin/deputy.sh
git commit -m "docs(runner): document detect/probe/route/cron in usage"
```

---

## Self-Review (completed during authoring)

**Spec coverage (Plan-2 slice):** CLI adapter / outcome classification (Task 1) ✓; provider routing per roles incl. codex-simple-failover + claude-bound-waits (Task 2) ✓; availability probe (Task 3) ✓; cron safety-net + reset-time parse + reschedule (Task 4) ✓; conservative-default (unknown→hard_error) (Task 1) ✓.

**Deferred to Plan 3:** the run loop that claims an item, computes availability, routes, spawns the orchestrator, and the orchestrator skill itself; worktree execution; waypoint/xReview wiring; SessionStart hook; installing the skill/hooks/cron via install.sh.

**Type/name consistency:** outcome strings `ok|quota_exhausted|auth_error|hard_error` are identical across `_detect_outcome`, `_probe`, and tests. `_route` kinds `orchestrate|code-complex|code-simple|review` match the test and the spec roles. `_in_csv`, `_crontab`, `_parse_reset_hour`, `_set_cron` are defined before use. Subcommand names (`detect/probe/route/cron/_resethour`) match their dispatch arms.

**No placeholders:** every step has runnable code + commands + expected counts.

**Testability note:** no test calls a real LLM or writes a real crontab — mocks-on-PATH and `$DEPUTY_CRONTAB` isolate all IO.
