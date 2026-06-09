# Deputy — Risky-op surfacing guardrail (design)

**Status:** Design (approved 2026-06-08, revised after Codex review). Feeds an implementation plan.
**One-liner:** A **best-effort tripwire** that catches the *careless* risky ops an
autonomous orchestrator commonly does, and makes it **surface** them instead — layered on
top of the real hard boundary (deputy never auto-pushes; the human reviews local-master
merges). **Not** an adversarial sandbox.

## Problem
The orchestrator runs with full, unsandboxed tools:
`claude -p … --allowedTools "Bash,Edit,Write,Read,Glob,Grep"`. The only guardrail today is
prompt-level. That failed this session: autonomous runs **broke the `/deputy` skill**
(`install.sh link` from a worktree → dangling global symlink), **installed a rogue cron**,
and **merged unreviewed work to master** — all despite the prompt.

## Threat model & honest limitations (READ FIRST)
This guardrail targets a **careless** orchestrator (does the obvious risky command because
it seems reasonable), **not an adversarial** one. A regex denylist over full `Bash` is
**bypassable** (interpreters like `python -c`, absolute binaries `/bin/rm`, redirection
`tee > ~/x`, `cp`/`sed -i`, scripts) and **delegated providers escape it** (a `codex`/
`gemini`/nested-`claude` subprocess spawned via Bash is outside the parent's PreToolUse
hook). So this is **defense-in-depth, not a containment guarantee.**

The **actual hard boundary** (already in place, and what we rely on):
1. **deputy never auto-pushes** — nothing reaches the remote/outside world without the
   user manually pushing.
2. **The human reviews local-master merges** before pushing.
So a careless orchestrator's blast radius is **local + reviewable**. This guardrail just
catches the common *local* damage (the skill-break, rogue cron, casual deletes) before it
happens. **Adversarial-grade containment is a separate, larger item: an OS sandbox
(`bwrap`/container, write-confined to `.deputy/wt`, no network) — explicitly out of scope
here.**

## Design — hybrid: best-effort hook + SKILL prose
### 1. PreToolUse hook (`hooks/guardrail.sh`)
A Claude Code **PreToolUse hook** intercepts the orchestrator's tool calls and **denies**
the known-risky ones.
- **Scoped to the orchestrator session only.** `_spawn_orchestrator` exports
  `DEPUTY_GUARDED=1`, `DEPUTY_WT=<abs worktree>`, `DEPUTY_ROOT=<abs repo root>`, and spawns
  `claude -p … --settings <guardrail-settings>` so the hook registers **only for that
  session** — not interactive sessions, not other repos, no shared-settings change. The
  hook **self-gates**: if `DEPUTY_GUARDED≠1` it allows everything.
- **Contract:** reads PreToolUse JSON on stdin and selects the target field **per tool**
  (`Bash`→`command`, `Edit`/`Write`→`file_path`, `NotebookEdit`→`notebook_path`); an
  intercepted tool whose expected target field is **missing/empty/unparseable → DENY
  (fail-closed)**. Denies via the version's signal (exit `2` + stderr reason and/or
  `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
  "permissionDecisionReason":"…"}}`) — exact shape pinned by the spike (§6).
- **Deny reason:** *"BLOCKED by deputy guardrail: `<op>` is risky/out-of-scope. Do NOT
  retry or work around it — `deputy set "<item-line>" surfaced` with a note, then stop."*

### 2. What the hook denies
**`Edit`/`Write`/`NotebookEdit`** — deny if the target is outside the worktree. Path
containment must be **robust** (Codex): resolve the **nearest existing parent** with
`realpath`/`readlink -f` (handle non-existent target files), **resolve symlinks**, and
require a true **path-component boundary** under `$DEPUTY_WT` (so `…/wt-escape` or a
symlink inside the wt pointing out does NOT pass). **Canonicalize `$DEPUTY_WT` and
`$DEPUTY_ROOT` once** at hook start (resolve symlinks on the roots themselves); resolve
**relative** tool paths against the orchestrator's cwd (the worktree); a state file is
allowed only if **both it and its parent canonicalize within `$DEPUTY_ROOT/.deputy/`** (no
symlink escaping out). Allow only: under canonical `$DEPUTY_WT/`, and the two specific
state files `$DEPUTY_ROOT/.deputy/<slug>.questions.md` / `.fail.md`.

**`Bash`** — deny if the command (scanned across `&&`/`;`/`|` segments) hits the denylist:
- `git push` (any, incl. `-f`/`--force`/`--force-with-lease`).
- `crontab`.
- any `install.sh` invocation.
- `rm -r`/`rm -rf`/`rm … -r` (deletes → use `to-be-deleted/`).
- `git` **state-mutating-outside-wt / shared-metadata** ops: `branch -D`/`-d`/`-f`,
  `update-ref`, `config --global`/`--system`, `reset --hard`/`clean -fd` **not** scoped to
  `.deputy/wt` (allow when `-C "$DEPUTY_WT"` / cwd is the wt), `worktree remove --force`,
  `push`, `remote …`.
- `sudo`, `gh pr merge`, `gh … --delete-branch`, global installs (`npm|pnpm|yarn … -g`,
  `pip(3)? install`, `apt`/`apt-get …`, `brew install`).
- `deputy cron …` (cron is user-owned; the orchestrator must never touch it).

**Allowed (must keep working) — by explicit allow, not blanket:** any command whose
effects stay inside `.deputy/wt`; the `deputy` **state verbs only** (`set/claim/wt-create/
wt-remove/start/plan/set-step/commit/resume/done/status/list/pick/review/config/
protected/detect/route/probe`) — but **not** `deputy cron`; and the done-gate sequence
`git checkout <default> && git merge --no-ff deputy/<slug>` (already guarded). Anything not
recognized as clearly-safe is **allowed by default** (best-effort: we deny *known* risks,
we don't allowlist the universe — that's the (B) sandbox's job).

### 3. SKILL.md prose
Add a **"Guardrail"** section: never attempt denylisted ops (they're blocked); **surface**
judgment-call risky ops the hook can't catch (destructive data/DB ops, prod/service
changes, repo/dir rename, mass rewrites); **if a tool call is blocked, surface the item —
don't work around it**; and note that **delegated `codex`/`gemini` coding is NOT hooked**,
so the orchestrator must not hand denylisted/out-of-scope work to a failover provider.

### 4. `_spawn_orchestrator` change
Export `DEPUTY_GUARDED=1`, `DEPUTY_WT="$(_wt_path)"`, `DEPUTY_ROOT="$ROOT"`; add
`--settings <guardrail-settings>` (generate a small settings file under `.deputy/` at spawn
with the absolute `hooks/guardrail.sh` path). Mock path (`DEPUTY_ORCHESTRATOR_CMD`)
unaffected.

## 5. Testing
Pure-bash unit tests of `hooks/guardrail.sh` (feed PreToolUse JSON on stdin, assert
deny/allow):
- each denylisted Bash pattern → deny; benign (`ls`, `git status`, `deputy set …`, the
  done-gate `git merge`, `git -C "$DEPUTY_WT" reset --hard`) → allow.
- `Write`/`Edit` outside `$DEPUTY_WT` → deny; inside + the two `.deputy/` state files →
  allow; **bypass attempts** (`$DEPUTY_WT/../evil`, a symlink inside wt → outside,
  `${DEPUTY_WT}-escape/x`, non-existent nested target) → deny.
- `DEPUTY_GUARDED` unset → allow everything (no-op).
- `deputy cron` → deny; other `deputy` verbs → allow.

## 6. Feasibility spike — **SHIP/NO-SHIP GATE** (first task)
Confirm against the installed Claude CLI that **`claude -p --settings <file>` honors a
PreToolUse hook that can DENY a tool call headless**. Pin the exact stdin JSON shape + deny
output format. **If it does not work, do NOT ship a hook that silently allows everything**
(false sense of safety) — instead stop and report; the fallback options are (a) the weaker
`PATH`-shim *documented as best-effort-minus*, or (b) escalate to the (B) OS sandbox. The
spike decides.

## 7. Scope
**In:** the hook + denylist, robust path containment, `_spawn_orchestrator` wiring, SKILL
prose, unit tests, the spike. **Out (documented limitations / future):** adversarial
containment / arbitrary out-of-repo Bash writes (→ (B) OS sandbox); interception of
delegated `codex`/`gemini` subprocesses; per-repo configurable denylist; notify-on-block.
