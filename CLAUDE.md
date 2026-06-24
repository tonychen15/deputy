# Deputy — project rules

## Releasing (MANDATORY)

**A version bump must update `CHANGELOG.md` and `BACKLOG.md` together, in the same release —
never one without the other.** Steps for a release `vX.Y.Z`:

1. Bump `VERSION` (minor `X.Y.0` for features, patch `X.Y.Z` for fixes).
2. **CHANGELOG.md** — prepend a `## vX.Y.Z — YYYY-MM-DD` entry covering the items done
   since the previous release marker.
3. **BACKLOG.md** — insert a **new release-marker delimiter** at the top of the Done
   section via `deputy release X.Y.Z` (writes `<!-- release vX.Y.Z — YYYY-MM-DD -->`).
   This delimiter is what bounds "done since last release", so `deputy release-notes`
   scopes the *next* release correctly.
4. Sync version references in `README.md`.
5. Commit, then create an annotated tag `vX.Y.Z`. Push only when the user asks.

**Why the lockstep:** the v1.2.0 release bumped the CHANGELOG but skipped the BACKLOG
delimiter, so `deputy release-notes` later returned the entire Done history instead of
just the unreleased items. CHANGELOG and the BACKLOG delimiter must stay in lockstep so
every release's notes are correctly bounded.
