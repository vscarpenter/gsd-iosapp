# Top three syncs under pull contract 4

Branch: `feat/top-three-contract-4`, Sprint 2 item IOS-C4. It builds on IOS-SAVED
(`docs/2026-11-07-saved-at-unread-push.md`) and IOS-TOP3-RULES. The authority is the top three
spec (`gsd-taskmanager/tasks/spec-top-three.md`), sections 5 to 7, as amended by SPEC-1. The web
records the same change in its own ADR in WEB-C4.

## What changes

- **Storage.** GRDB `v8-top-three` adds nullable `focusDate` (text) and `focusRank` (integer) to
  the tasks, archive, and trash tables, with no index and no backfill. A pick survives the trash,
  the archive, and a Restore.
- **Wire.** `focus_date` is text and `focus_rank` a number, with `""` and `0` for no pick. A bad
  or missing pick pulls as unset and keeps the task. The conversions are `TopThree.fromWire`,
  `toWire`, and `pushFocus`, which the shared corpus pins.
- **Contract 4.** `SyncCursor.contractVersion` moves from 3 to 4. A device on contract 3 runs the
  backfill once: it pulls everything, merges same-version records (C4-5), and a local row that
  wins takes the pick it never read (C4-4).
- **One copy rule.** `SyncBackfill` asks `TopThree.unreadFieldsToCopy` which fields to copy, as the
  web does (S-IOS-01, mirroring S-WEB-03). The engine keeps its own newer, same, or older verdict,
  the far-future hold-off, and the can-be-Saved check for `savedAt`. The pick copies without that
  check, because a pick on a completed or Saved row is inert (SPEC-1). `TopThree` holds both "first
  read" numbers, 3 for `saved_at` and 4 for the pick.
- **Push.** The pick comes from the row at drain time, never the queued payload. When the row is
  gone, both keys stay off the wire and the server keeps its value (C4-6).
- **Backup.** Envelope 2.2.0. Each task, archived and trashed rows included, carries the pick when
  set and omits it when not.
- **New tasks.** A duplicate or a recurring task's next instance starts with no pick.

## Why the backfill needs the version gate

An empty pick means "never read" only on a build older than contract 4. On this build, an empty
pick on a newer row is a real un-pick that may not have pushed yet, and copying the server's pick
over it would undo what the user did. The same holds for `savedAt` below contract 3.

## Evidence

- `TopThreeContract4Tests` runs the pick half of every iOS named test in spec section 6 through the
  real `SyncEngine` and GRDB repositories, starting from a contract 3 device. Six failed at
  contract 3 and pass at 4. The rest landed with IOS-SAVED.
- `TopThreePersistenceTests`, `TopThreeWireTests`, `TopThreeBackupTests`, and `SyncBackfillTests`
  pin the storage, wire, envelope, and copy rules. `web-top-three-2.2.0.json` is the frozen web
  export (md5 `6da5aec65096d917c777e7a51a8d925e`).
- The real-server run on a bare PocketBase is pending on owner item 24.

## Release order

The hosted `tasks` collection needs both fields before any build that reads them ships (owner
item 18). A server without them returns 200 and drops both keys, so every pick would be lost with
no error.
