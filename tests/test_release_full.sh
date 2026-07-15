#!/usr/bin/env bash
# tests/test_release_full.sh — the full 'deputy release <ver>' orchestrator: bump VERSION,
# prepend a CHANGELOG entry, insert the BACKLOG delimiter, sync README, commit + annotated
# tag, and (default) do NOT push. DEPUTY_RELEASE_NO_LLM=1 forces the deterministic raw
# (release-notes) CHANGELOG path so this test never calls a worker.
source "$(dirname "$0")/lib.sh"

# A git repo shaped like a deputy project.
mkrepo() {
  setup_repo
  R="$DEPUTY_ROOT"
  git -C "$R" init -q; git -C "$R" config user.email t@t; git -C "$R" config user.name t
  printf '1.0.0\n' > "$R/VERSION"
  printf '# Changelog\n\n## v1.0.0 — 2020-01-01\n\n- first release\n' > "$R/CHANGELOG.md"
  printf 'Deputy. Check the installed version: `cat VERSION` (currently `1.0.0`).\n\n```\nVERSION   # 1.0.0\n```\n' > "$R/README.md"
  printf '.deputy/\n' > "$R/.gitignore"
  git -C "$R" add -A; git -C "$R" commit -qm init
  git -C "$R" tag -a v1.0.0 -m v1.0.0
  # A completed item so release-notes yields a bullet for the raw CHANGELOG fallback.
  bash "$DEPUTY" add "shipped the thing" --p1 >/dev/null
  bash "$DEPUTY" set "$(grep -F 'shipped the thing' "$R/BACKLOG.md" | head -1)" done >/dev/null
}
D() { DEPUTY_RELEASE_NO_LLM=1 bash "$DEPUTY" "$@"; }

# ── 1. happy path: VERSION + CHANGELOG + delimiter + README + tag, no push ──
mkrepo
out="$(D release 1.1.0 2>&1)"; rc=$?
assert_eq "$rc" "0" "full release exits 0"
assert_eq "$(cat "$R/VERSION")" "1.1.0" "VERSION bumped to 1.1.0"
assert_contains "$out" "released v1.1.0 locally" "reports local release"
assert_contains "$out" "push when ready" "prints the push command (opt-in, not auto-pushed)"
# CHANGELOG: new entry ABOVE the old one, containing the done item (raw fallback).
head1="$(grep -m1 '^## v' "$R/CHANGELOG.md")"
assert_contains "$head1" "## v1.1.0" "new CHANGELOG entry is the topmost ## v heading"
assert_contains "$(cat "$R/CHANGELOG.md")" "shipped the thing" "raw fallback lists the done item"
assert_contains "$(cat "$R/CHANGELOG.md")" "## v1.0.0" "old CHANGELOG entry preserved"
# BACKLOG delimiter + README sync + annotated tag on HEAD.
assert_eq "$(grep -c '<!-- release v1.1.0 —' "$R/BACKLOG.md")" "1" "BACKLOG delimiter inserted"
assert_contains "$(cat "$R/README.md")" 'currently `1.1.0`' "README 'currently' marker synced"
assert_contains "$(cat "$R/README.md")" 'VERSION   # 1.1.0' "README VERSION map line synced"
assert_eq "$(git -C "$R" tag --list v1.1.0)" "v1.1.0" "annotated tag v1.1.0 created"
assert_eq "$(git -C "$R" cat-file -t v1.1.0)" "tag" "tag is annotated (not lightweight)"

# ── 2. tag collision: refuse to clobber an existing tag ──
mkrepo
D release 1.1.0 >/dev/null 2>&1
out="$(D release 1.1.0 2>&1)"; rc=$?
assert_eq "$rc" "1" "re-release of an existing tag exits 1"
assert_contains "$out" "already exists" "reports the tag collision"

# ── 3. not a git repo → clean error, no partial writes ──
setup_repo
printf '2.0.0\n' > "$DEPUTY_ROOT/VERSION"
out="$(DEPUTY_RELEASE_NO_LLM=1 bash "$DEPUTY" release 2.0.0 2>&1)"; rc=$?
assert_eq "$rc" "1" "release in a non-git dir exits 1"
assert_contains "$out" "not a git repository" "reports the non-git error"

# ── 3b. preflight: uncommitted edits to a release-owned file abort (no partial writes) ──
mkrepo
printf '\n- a manual pending note\n' >> "$R/CHANGELOG.md"   # dirty CHANGELOG before release
out="$(D release 1.1.0 2>&1)"; rc=$?
assert_eq "$rc" "1" "dirty CHANGELOG.md aborts the release"
assert_contains "$out" "uncommitted changes" "reports the preflight block"
assert_eq "$(cat "$R/VERSION")" "1.0.0" "VERSION untouched after preflight abort"
assert_eq "$(git -C "$R" tag --list v1.1.0)" "" "no tag created after preflight abort"

# ── 4. --marker-only stays delimiter-only: no VERSION bump, no tag ──
mkrepo
D release --marker-only 1.1.0 >/dev/null 2>&1
assert_eq "$(cat "$R/VERSION")" "1.0.0" "--marker-only does NOT bump VERSION"
assert_eq "$(git -C "$R" tag --list v1.1.0)" "" "--marker-only does NOT create a tag"
assert_eq "$(grep -c '<!-- release v1.1.0 —' "$R/BACKLOG.md")" "1" "--marker-only still inserts the delimiter"
