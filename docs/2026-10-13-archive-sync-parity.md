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

- `TaskStore.archive` queues a `.delete` before it moves the row, the same order `delete` uses.
  If the delete can't be recorded, the task stays active and `archive` throws
  `TaskStoreError.archiveNotRecorded`. If the move fails, the queued delete is removed.
- `runAutoArchiveSweep` archives through `TaskStore.archive`, so each swept task also leaves the
  server.
- `restore` is unchanged. It already queued an `.update`, which now re-uploads the task.
- Archive membership itself still doesn't sync. The archived row lives only on the device that
  archived it.

## Consequences

- **Other devices drop the task.** When a task is archived on any client, the others drop it
  from their live list through deletion reconcile or a realtime delete. They don't archive it
  themselves. This is the existing cross-client behavior; Apple now takes part in it.
- **Older archives stay as they are.** Tasks already in an Apple archive before this change keep
  their server copies (owner's call). Restoring one and archiving it again removes the copy.
- **Edits made elsewhere can lose to the delete.** Apple's push has no edit-beats-delete guard
  (backlog B-42; Android also lacks it, web has it). If another device edits an archived task
  before this device pushes the delete, the delete still removes that edit from the server.
- **Archive then restore before a sync costs a retry.** Push doesn't drop a deleted task from its
  in-memory index (backlog B-45), so the restore's update PATCHes the deleted record and spends a
  retry. The next sync creates the task again.

## Alternatives considered

- **Keep archiving device-local and only fix Delete permanently.** This was rejected: archived
  tasks would still show as active on web and Android, and Apple would disagree with its own spec.
- **Also delete the server copy of every task already archived, once.** This was rejected for
  now: without B-42's guard, a one-time pass could delete copies that other devices edited after
  the archive.
