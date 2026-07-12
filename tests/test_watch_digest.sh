#!/usr/bin/env bash
# tests/test_watch_digest.sh — #79: quiescence detection, beep guard, digest rendering.
source "$(dirname "$0")/lib.sh"

# Helper: add a surfaced item with an optional questions file.
_add_surfaced() {
  local desc="$1" qtext="${2:-}"
  DEPUTY_NO_AUTORUN=1 bash "$DEPUTY" add "$desc" --p2 >/dev/null
  id="$(line_id "$(bash "$DEPUTY" list | grep -F "$desc")")"
  bash "$DEPUTY" set "$id" surfaced >/dev/null 2>&1
  if [[ -n "$qtext" ]]; then
    # Real orchestrator convention (SKILL.md): '<desc>-<id>' (id suffix), not '<id>-<desc>'.
    local slug; slug="$(printf '%s' "${desc}-${id}" | tr -cs 'a-zA-Z0-9' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')"
    slug="${slug:0:64}"
    mkdir -p "$DEPUTY_ROOT/.deputy/questions"
    printf '%s\n' "$qtext" > "$DEPUTY_ROOT/.deputy/questions/${slug}.md"
  fi
  printf '%s' "$id"
}

# 1: non-TTY stdout -> _watch_beep is a no-op; digest still prints to stdout
setup_repo
sid="$(_add_surfaced "alpha stuck item")"
out="$(bash "$DEPUTY" watch --once 2>&1)"
# No bell char should appear when stdout is not a TTY (piped to $())
if printf '%s' "$out" | grep -qP '\x07'; then
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1))
  printf 'FAIL: non-TTY watch emitted a BEL char\n' >&2
else
  TESTS_RUN=$((TESTS_RUN+1))
fi
assert_contains "$out" "alpha stuck item" "non-TTY watch --once: digest lists the surfaced item"
assert_contains "$out" "quiescent" "non-TTY watch --once: digest prints quiescent header"

# 2: digest includes questions file path and first-line summary when file exists
setup_repo
sid2="$(_add_surfaced "beta stuck item" "Design choice needed: pick A or B")"
out2="$(bash "$DEPUTY" watch --once 2>&1)"
assert_contains "$out2" "beta stuck item" "digest: item description present"
assert_contains "$out2" "details:" "digest: questions/details path label present"
assert_contains "$out2" "Design choice needed" "digest: first line of questions file shown"
assert_contains "$out2" "resume:" "digest: resume tip present"
assert_contains "$out2" "/deputy" "digest: resume tip mentions /deputy"

# 3: quiescence edge — blocking-surfaced item with runnable==0 triggers digest
setup_repo
sid3="$(_add_surfaced "gamma stuck item")"
# Confirm queue is quiescent: no runnable, one blocking-surfaced
r_count="$(bash "$DEPUTY" list --waiting 2>/dev/null | grep -vc '^$' || true)"
s_count="$(bash "$DEPUTY" list --surfaced 2>/dev/null | grep -vc '^$' || true)"
# Check with --once: should emit digest (quiescent trigger)
out3="$(bash "$DEPUTY" watch --once 2>&1)"
assert_contains "$out3" "gamma stuck item" "quiescence edge: --once digest fires when runnable==0 + surfaced>0"

# 4: runnable items present → no digest emitted (NOT quiescent)
setup_repo
DEPUTY_NO_AUTORUN=1 bash "$DEPUTY" add "delta runnable item" --p2 >/dev/null
out4="$(bash "$DEPUTY" watch --once 2>&1)"
# With runnable items but no worker, should stay quiet (no digest)
if printf '%s' "$out4" | grep -q "quiescent"; then
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1))
  printf 'FAIL: watch --once emitted digest while runnable items exist (not quiescent)\n' >&2
else
  TESTS_RUN=$((TESTS_RUN+1))
fi

# 5: proposal surfaces ARE shown, labeled 'proposed', with approve/reject tips
setup_repo
DEPUTY_NO_AUTORUN=1 bash "$DEPUTY" add "epsilon proposal item" --p2 >/dev/null
pid5="$(line_id "$(bash "$DEPUTY" list | grep -F "epsilon proposal item")")"
bash "$DEPUTY" set "$pid5" surfaced >/dev/null 2>&1
mkdir -p "$DEPUTY_ROOT/.deputy"
printf 'proposed-by-run-pid: 0\nitem: epsilon proposal item\n' > "$DEPUTY_ROOT/.deputy/proposed-$pid5"
out5="$(bash "$DEPUTY" watch --once 2>&1)"
assert_contains "$out5" "epsilon proposal item" "watch --once: proposal surface is shown in the digest"
assert_contains "$out5" "proposed"              "watch --once: proposal labeled 'proposed'"
assert_contains "$out5" "approve:"              "watch --once: proposal shows approve/reject tip"

# 5b: ready-merge surfaces ARE shown, labeled 'ready to merge', with a merge command
setup_repo
DEPUTY_NO_AUTORUN=1 bash "$DEPUTY" add "zeta merge item" --p2 >/dev/null
mid="$(line_id "$(bash "$DEPUTY" list | grep -F "zeta merge item")")"
bash "$DEPUTY" set "$mid" surfaced >/dev/null 2>&1
mkdir -p "$DEPUTY_ROOT/.deputy"
printf 'ready-merge-at: t\nbranch ready for human merge-review\n' > "$DEPUTY_ROOT/.deputy/ready-merge-$mid"
out5b="$(bash "$DEPUTY" watch --once 2>&1)"
assert_contains "$out5b" "zeta merge item" "watch --once: ready-merge surface is shown in the digest"
assert_contains "$out5b" "ready to merge"  "watch --once: ready-merge labeled 'ready to merge'"
assert_contains "$out5b" "merge:"          "watch --once: ready-merge shows a merge command"

# 6: totally-empty queue → "nothing to watch" friendly exit
setup_repo
out6="$(bash "$DEPUTY" watch --once 2>&1)"
assert_contains "$out6" "nothing to watch" "watch --once: empty queue exits with nothing-to-watch"

# 7: digest resolves the questions file across ALL lookup conventions (not just <desc>-<id>).
#    Covers: <id>-<desc> (runner _wp_slug prefix), and legacy flat .deputy/<*>.questions.md.
for conv in "prefix" "legacy-suffix" "legacy-prefix"; do
  setup_repo
  DEPUTY_NO_AUTORUN=1 bash "$DEPUTY" add "zeta $conv item" --p2 >/dev/null
  zid="$(line_id "$(bash "$DEPUTY" list | grep -F "zeta $conv item")")"
  bash "$DEPUTY" set "$zid" surfaced >/dev/null 2>&1
  base="$(printf '%s' "zeta-$conv-item-$zid" | tr -cs 'a-zA-Z0-9' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')"
  case "$conv" in
    prefix)        mkdir -p "$DEPUTY_ROOT/.deputy/questions"; printf 'MARKER-%s\n' "$conv" > "$DEPUTY_ROOT/.deputy/questions/${zid}-zeta-prefix-item.md" ;;
    legacy-suffix) printf 'MARKER-%s\n' "$conv" > "$DEPUTY_ROOT/.deputy/${base}.questions.md" ;;
    legacy-prefix) printf 'MARKER-%s\n' "$conv" > "$DEPUTY_ROOT/.deputy/${zid}-zeta-legacy.questions.md" ;;
  esac
  outc="$(bash "$DEPUTY" watch --once 2>&1)"
  assert_contains "$outc" "MARKER-$conv" "digest resolves questions file via $conv convention"
done
