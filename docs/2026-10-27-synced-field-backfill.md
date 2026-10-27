# Synced fields reach rows an older build already pulled

Branch: `fix/synced-field-backfill`, based on `a1555bb`. The web carries the same
branch name and records the decision in its ADR 0019.

## The bug

Saved shipped on the web on October 26 and on iOS in 3.6.0 (37) a few hours
later. By the next morning the server held five saved records, all written by
Apple devices, and the web showed every one of them. An iPhone showed only the
items it had saved itself.

Two gaps caused that, and both clients had them.

1. The pull cursor never rewinds on an upgrade. iOS pulls `updated >= cursor`
   (`SyncCursor`), so a record the previous build already consumed is never
   requested again. That build had no `saved_at` key, dropped the value on
   decode, and stored the row without it.
2. An equal stamp is a no-op. `LWW.resolve` returns `.noOp` when the local
   `updatedAt` equals the remote `client_updated_at`, and `pull` skipped the
   record. The old build stamped `updatedAt` straight from the wire, so even a
   sign-out and sign-in, which clears the cursor, could not copy the field across.

The stale device also held those items as active tasks. An edit there pushed
`saved_at: ""` with a newer stamp and un-saved the item on every client.

## The fix

`SyncCursor` now carries a contract version (`gsd.sync.contractVersion`, 3 today,
numbered like the web's `PULL_CURSOR_VERSION` so the two histories read the same).
A cursor without the current version was written by an older build. `sync()` then
pulls everything once from the epoch with `mergeSameVersion`, which accepts a
same-version record and merges it through the existing mapper, so device-local
fields survive and the missing field lands. The cursor stays set during that pull,
so the first-sign-in seed does not run. The seed would have pushed every local
row with the field still empty and cleared the server's placement.

`advance` and `markBackfilled` stamp the version, and `clear` forgets it. A fresh
install has no cursor and nothing to backfill. Ordinary pulls keep the
strictly-newer rule, and push is unchanged.

When a build is the first to read a new synced field, bump
`SyncCursor.contractVersion` here and `SYNC_CONFIG.PULL_CURSOR_VERSION` on the web
in the same change. Android will need the same mechanism when it adds a synced
field of its own.

## Evidence

- `SyncCursorTests` covers the contract: an unset cursor needs no backfill, a
  cursor from an older build or a legacy client cursor does, `markBackfilled` and
  `advance` stamp it, and `clear` forgets it.
- `SyncEngineBackfillTests` runs the engine against a fake server that honors the
  `updated` filter. With an older build's cursor past the record, one `sync()`
  applies `saved_at` to the same-version row, leaves the queue empty, keeps the
  server's placement, and the next sync is incremental. A plain `pull` still
  skips a same-version record; the backfill pull merges it without counting a
  conflict.
- Both new tests failed before the change and pass after it. The full package
  suite and the three app builds are recorded in `tasks/todo.md`.

## Devices already on 3.6.0

A device that upgraded before this fix has a cursor with no version, so its first
sync on the fixed build runs the backfill. No manual step is needed.
