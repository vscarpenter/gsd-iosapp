# Archiving deletes the server copy (cross-platform parity)

| Field | Value |
|---|---|
| Date | 2026-10-13 |
| Status | Accepted. Supersedes the Phase 5c "archive is device-local" call |
| Deciders | Vinny Carpenter |

## Context

Phase 5c (May 30) kept archiving device-local: archiving moved the row into `archivedTasks`
and queued nothing, because syncing it "would mean a destructive server-side delete." Restore
queued an `.update`.

The other clients made the opposite call, and so does this app's own behavior spec (`spec.md`
§6.12: "archiving a task syncs as a delete of the active record; restoring as a create/update").
Web archiving (`lib/archive.ts`, `archiveOldTasks` and `archiveTaskNow`) and Android archiving
(`ArchiveStore.archive`, used by its sweep) both queue a remote delete.

The October 12 parity audit logged the gap as backlog B-43:

- **Archived tasks stayed live elsewhere.** A task archived on Apple stayed active on web and
  Android, because its server copy was never removed.
- **Delete permanently didn't stick.** It removed the archive row, which is also the sync
  tombstone (parity S9). The surviving server copy came back on the next full pull.

## Decision

**Archiving on Apple deletes the server copy, as on web and Android.**

- `TaskStore.archive` moves the row first and then queues a `.delete`. That is the reverse of
  `delete`, because the two are separate writes and the database can be suspended between them in
  the background. Moving first means a failure can at worst leave an archived task whose server
  copy survives. Queuing first could leave a delete pending for a task that is still live, which
  deletion reconcile would then remove with no archive or trash copy. If the queue write fails,
  the task goes back to active and `archive` throws `TaskStoreError.archiveNotRecorded`.
- `runAutoArchiveSweep` archives through `TaskStore.archive`, so each swept task also leaves the
  server.
- **While signed in, auto-archive runs only after a sync has pulled.** The sweep picks tasks from
  the local copy, and its delete is newer than any edit made elsewhere since the last sync. A
  sweep from a stale copy would delete a task someone reopened on another device. So the launch
  sweep and the background-refresh sweep (which never syncs) run only when signed out. Signed in,
  `SyncCoordinator.afterCleanSync` runs the sweep after every sync that pulled without an error.
  Archive now in Settings and the auto-archive controls in Archive still sweep directly. That is
  usually current in the foreground, through the 2-minute cadence and realtime, but not when the
  device is offline, before the launch sync finishes, or with a session the server rejects.
  Routing those actions through a sync first is a possible follow-up.
- Two edges of the signed-in check: a session the server rejects makes every sync fail, so
  auto-archive stops until the user signs in again. And the check reads the token from the
  keychain, so a keychain read error in the background reads as signed out and lets that sweep run.
- A realtime delete for a task with no live row, such as an archive's own delete echoing back, is
  now ignored. Before, it still scrubbed the task's id from other tasks' dependencies and
  restamped them with nothing queued.
- `restore` is unchanged. It already queued an `.update`, which now re-uploads the task.
- Archive membership itself still doesn't sync. The archived row lives only on the device that
  archived it.

## Consequences

- **Other devices drop the task.** When a task is archived on any client, the others drop it
  from their live list through deletion reconcile or a realtime delete. They don't archive it
  themselves. This is the existing cross-client behavior; Apple now takes part in it.
- **Older archives stay as they are.** Tasks already in an Apple archive before this change keep
  their server copies (owner's call). Restoring one and archiving it again removes the copy.
- **Edits made elsewhere can lose to the delete.** If another device edits an archived task
  before this device pushes the delete, the delete still removes that edit from the server.
  Apple's push has no edit-beats-delete guard (backlog B-42; Android also lacks it, web has it).
  A guard on push alone wouldn't be enough. A queued delete also suppresses newer remote edits in
  pull and realtime (the B-04 rule), and pull advances its cursor past what it suppressed. B-42
  must lift those exemptions too, or the task ends up archived here and live everywhere else.
- **Imported archive rows behave like older archives.** Restoring a backup writes its archived
  rows without queuing deletes, as web's import does. For those rows and for tasks archived before
  this change, the server copy stays active elsewhere. Delete permanently in Archive still brings
  them back on the next full pull, because it removes the tombstone while the server copy survives.
- **Archive then restore before a sync costs a retry.** Push doesn't drop a deleted task from its
  in-memory index (backlog B-45), so the restore's update PATCHes the deleted record and spends a
  retry. The next sync creates the task again.

## Alternatives considered

- **Keep archiving device-local and only fix Delete permanently.** This was rejected: archived
  tasks would still show as active on web and Android, and Apple would disagree with its own spec.
- **Also delete the server copy of every task already archived, once.** This was rejected for
  now: without B-42's guard, a one-time pass could delete copies that other devices edited after
  the archive.
