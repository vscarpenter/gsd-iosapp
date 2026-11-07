# A build never sends a synced field it hasn't read

Branch: `fix/saved-at-unread-push`, from `4c4d44a`. Sprint 2 item IOS-SAVED, Goal 0 (owner
item 7). The web carries the same branch name as WEB-SAVED.

## The bug

The October 27 backfill (`docs/2026-10-27-synced-field-backfill.md`) brought `saved_at` to rows
an older build had stored without it. Three paths still pushed `saved_at: ""` from such a row and
cleared the server's placement. `sprint/findings/saved-at-exposure.md` reproduces each one (iOS
cases a1 to c3).

- **A payload queued before the upgrade.** The backfill repaired a same-version row, but push sent
  the queued payload, which still had no placement. A row newer than the server wasn't repaired at
  all, because the backfill only merged same-version records.
- **Sign-out on an older build, then upgrade and sign-in.** Sign-out cleared the cursor, and the
  backfill needed one. The seed queued every row, and the push cleared each placement at or past
  the server's stamp. This one needs no pending edit.
- **`pushNow` before the first sync after the upgrade.** It drained the queue with no pull, so an
  edit made on the upgraded build copied the unrepaired row's empty placement.

## The fix

Four changes at contract 3. IOS-C4 extends each one to the top three fields instead of building
them again.

1. **The stored version alone decides whether a backfill is due** (`SyncCursor.needsBackfill`,
   top three spec C4-1). A missing cursor no longer exempts a device. `clear()` keeps the version,
   so sign-out on this build doesn't read as an older build's. Only a completed pull stamps one.
2. **`pushNow` runs the full `sync()` while a backfill is due** (C4-2), so no push goes out before
   that pull.
3. **A local row that wins the backfill pull takes each synced field it never read**
   (`SyncBackfill.fillingUnreadFields`, C4-4). It wins when it's strictly newer, or when a queued
   write holds off a far-future remote (S-SPEC-01). The copy keeps the row's stamp, queues
   nothing, and counts no conflict. It runs only when the stored version predates the field and the
   row passes `SavedPlacement.canSave` (S-WEB-02), so a task completed on the old build stays
   completed and isn't also Saved. At contract 3 or later an empty `savedAt` is a real Return,
   and the copy leaves it alone.
4. **Push takes `saved_at` from the row as it is at drain time**, not from the queued payload
   (`TaskWireMapper.toWire(_:current:)`, C4-6's shape). When the row is gone, the key stays off the
   wire and the server keeps its value.

Android already did 3 and 4 (`SyncEngine.kt`, `lacksPlacement` and `sendSavedAt`). Its
`SavedPlacement.canSave` is the rule `GSDModel/SavedPlacement.swift` mirrors, and
`TaskStore.moveToSaved` now uses it too, so the two paths can't disagree.

## Evidence

- `SavedAtUnreadPushTests` runs each finding case through the real `SyncEngine`, GRDB
  repositories, and `TaskStore` against a fake server that merges a PATCH like PocketBase. Cases
  a1, a2, b1, b2, c1, and c3 failed on `main` exactly as the finding's tables show, and pass here.
  Controls a3, b3, c2, and c4 pass on both. The same file holds the spec's named tests that land at
  contract 3.
- `SyncBackfillTests`, `SavedPlacementTests`, `SavedWireTests`, and `SyncCursorTests` pin the
  pure rules. Removing the `canSave` check turns three of them red.
- The real-server run on a bare PocketBase is pending on owner item 24.

## Accepted edges

- **A Return that hadn't pushed, on a build that forgot the version.** A contract 3 build before
  this one forgot the version on sign-out. If a task was Returned there and the user signed out
  before it pushed, the first sync on this build reads as an older build's and copies the
  placement back. Nothing is lost, and the user can Return it again. The top three spec accepts
  this edge (C4-4), and this change closes it for later contracts.
- **Import Replace still pushes with the pull held off** (`flushDeletes`). That drain sends the
  imported rows as the user chose them, so it doesn't run a backfill first.
