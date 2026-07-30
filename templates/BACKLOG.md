# Deputy Backlog

## LEGEND
**Status (line prefix):** (none) waiting | `~` triaging | `@` running | `?` surfaced | `+` done | `!` failed | `%` cancelled | `=` duplicate | `^` paused | `;` deferred | `&` pending-merge  (legacy `#`/`>` are still read and auto-migrated)
**Priority (tag):** `[P0]` urgent+important | `[P1]` urgent | `[P2]` important | `[P3]` default (bare items) | `[P4]` lowest lane
**Order:** P0 > P1 > P2 > P3 > P4 ; untagged items are assigned `[P3]` at numbering ; FIFO within a lane
**Line format:** `<status?>[#N][Px] <description>`  (`[#N]` id assigned automatically on first reference; either tag order is read, written id-first)
**Sub-ids (grouping):** an id may be hand-written with an optional `.<n>` suffix — `[#145.2]` reads as "a sub-item of #145". `#145.2` is a full, independent item id (run/set/target it like any other); only its RELATIONSHIP to `#145` is a human label — the two share no scheduling/merge/lifecycle. Auto-allocation still emits plain integers and counts a sub-id's integer prefix (so `[#145.2]` present ⇒ next auto id is `#146`); type a sub-id yourself to group related work.
**Add an item:** `deputy add [-ui|-u|-i|--p0|--p1|--p2|--p3|--p4] "your task"` — or just add a line below
**Sections:** items are auto-grouped under the `###` headers below (with live counts); add a
line in any section and it is re-sorted on the next write. `<!-- release ... -->` lines in
**Done** mark release boundaries. Order is by WHO resolves it: **Running/Surfaced/Waiting/
Deferred** are yours to read and act on; **Paused/Pending merge** deputy resolves by itself
(paused auto-resumes, pending-merge retries each tick) and never ask for you; then the
terminal sections.
---

## Items

### Running (0)

### Surfaced (0)

### Waiting (0)

### Deferred (0)

### Paused (0)

### Pending merge (0)

### Failed / Cancelled / Duplicate (0)

### Done (0)

