# Trash and full-fidelity backups (cross-platform parity)

| Field | Value |
|---|---|
| Date | 2026-08-28 |
| Status | Accepted |
| Deciders | Vinny Carpenter |

## Context

A parity audit against the web client (gsd-taskmanager 12.5.0) found two places
where the same user action produced different, silently lossy outcomes depending
on which client performed it.

**Delete meant different things.** The web has carried a 30-day recoverable trash
since its ADR 0015. This app deleted permanently, behind a transient undo toast.
The same gesture destroyed data on one client and not the other — and because the
web's trash is device-local recovery layered over a server delete, an iOS device
pulling that delete removed the task with no way back at all.

**Backups did not cross.** This app wrote `{ tasks, exportedAt, version }` with an
`Int` version. The web writes a semver string and gated import on `z.string()`, so
an iOS backup was refused outright — "expected string, received number" — before a
single task was read. In the other direction a web backup appeared to import only
because this app's lenient envelope decoder reads `tasks` and ignores every other
key: `archivedTasks`, `deletedTasks`, `smartViews`, `notificationSettings`,
`archiveSettings` and `appPreferences` were all discarded without a word. That is
the same silent partial-backup failure the web's ADR 0014 exists to fix,
reproduced across the fence.

Export is the only way data leaves either client without an account. A backup the
user's other device cannot read is not a backup.

## Decision

**Trash is a soft delete with a 30-day window, and the backup envelope matches the
web's shape byte-for-byte.**

### Trash

A `v6` `deletedTasks` table with the `archivedTasks` column set and a `deletedAt`
stamp. Separate table, so trashed rows are excluded from every matrix and
smart-view query by construction — the same reason the archive is separate.
`TrashRetention` holds the rules as a pure model, anchored to start-of-day like
`AutoArchive`, and a row stamped exactly on the cutoff is KEPT.

**The wire contract does not change.** `delete` still enqueues `.delete` *before*
touching the local row and still aborts if that enqueue fails; it simply moves the
row to `deletedTasks` instead of dropping it. Restore enqueues `.create`, matching
what the web does. Delete-forever and empty enqueue nothing — the server already
deleted the record when it was trashed.

### Envelope

`version` becomes the string `"2.1.0"`; decode accepts the legacy `Int`. The
envelope gains `archivedTasks`, `deletedTasks`, `smartViews`,
`notificationSettings`, `archiveSettings` and `appPreferences`. An absent key still
means "this backup says nothing about that store" and leaves it alone; only an
explicit `[]` clears.

Two shape mismatches had to be resolved in this app's favour of the wire:

- **`FilterCriteria` decodes leniently now.** Its synthesized decoder demanded all
  thirteen keys while the web writes only the ones a view actually constrains on,
  so no real web smart view could ever decode. Absent fields default exactly as the
  member init does, which matches what an absent key means on the web.
- **Backups write the derived `quadrant`.** `Task` omits it from `CodingKeys` so
  the stored value can never drift from `urgent`/`important` — right for this app,
  wrong for the wire, where the web persists it as an indexed column and requires
  it. `TaskWireMapper` already wrote it for sync; backups now follow suit and
  ignore it on read.

## Consequences

**Easier.** A backup taken on either client restores fully on the other. Deleting a
task is recoverable everywhere. "Erase all data" now clears the trash too — leaving
it would keep a copy of exactly what the user asked to be rid of.

**Harder.** `TaskStore` gains a dependency (`TrashRepository`) and `exportJSON`
became `async`, since it now reads the archive, trash and smart-view stores rather
than only the in-memory task snapshot.

**Verified by a shared fixture.** `Tests/GSDStoreTests/Fixtures/web-backup-2.1.0.json`
is a byte-identical copy of the web repo's `tests/fixtures/cross-platform/`, and
that repo's suite reads a real export produced by this one. Neither client's tests
could have caught either mismatch alone: each was internally consistent and only
disagreed with the other, so every same-client round-trip passed.

**Not fixed here.** `TaskImporter.maxImportTasks` counts `tasks` only, so a
lossless backup can carry more rows than the 10,000 guard admits. The web has the
identical gap. Changing a security limit did not belong inside a compatibility fix.

## Alternatives considered

**Widen only the version type and leave the envelope tasks-only.** Half a fix: the
two clients could exchange files, but a web backup restored here would still drop
five stores silently — the exact failure being fixed, one layer down.

**Drop the trash from the web to match this app.** Levels down rather than up,
takes a real safety net away from existing web users, and orphans whatever already
sits in their trash.

**Translate smart-view icons between SF Symbols and lucide keys.** These are
user-created views; there is no correct translation. Each client falls back to its
own default glyph for a string it does not recognise.
