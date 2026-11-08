# Tasks deleted while signed out come back on sight

Branch: `fix/resurrect-on-sight`, Sprint 2 item IOS-RESURRECT. The authority is
`gsd-taskmanager/tasks/spec-resurrect-on-sight.md` (SPEC-3), and Android #64 is the reference.
This note records where iOS puts each piece. Vinny decided the rule on 2026-11-06: a task deleted
while signed out reappears when the account lists it.

## Before

iOS queues every mutation whatever the sign-in state and keeps the queue through sign-out. After
the next sign-in, the pull suppressed the server copy because it was older than the Trash row, and
then the push sent the queued delete. The task left every device.

## Where each piece goes

- **The sign-in moment.** `SyncEngine.dropSignedOutDeletes()` remembers the ids of queued Trash
  and Replace deletes (no payload) and removes every queued delete. An archive's delete carries
  the task, so it's dropped without being remembered, and the archive stands. `SessionStore.signIn`
  calls `SyncEngine.beginSignIn()` before the token exists, and the engine's first run of any kind
  (a sync or a push-only drain) does the drop before anything else, so nothing can push those
  deletes first. Every sign-in, including the account-switch paths, goes through that one call.
- **Only with no cursor.** A rejected token clears only the Keychain token and keeps the cursor,
  so a re-sign-in after one drops nothing, and its deletes still push. That's today's behavior,
  and owner decision D-2 owns it. A sign-out clears the cursor, and so does a device that never
  synced. The one misread: a token rejected before that session's first sync completed leaves no
  cursor either, so its queued deletes come back instead of pushing. Android does the same today,
  and nothing is lost.
- **Once per sign-in, never per sync.** A failed first sync leaves the cursor nil, so a drop inside
  `sync()` would swallow a delete made while signed in.
- **Storage.** The ids sit beside the cursor in App Group defaults
  (`AppGroupDefaults.Key.resurrectOnSight`). Sign-out keeps them, and Erase all data clears them.
- **The step.** In `sync()`, after the pull and before the push. One complete listing
  (`listEveryTask`, which also refuses a record it can't read), then `auth-refresh` to confirm the
  owner, because a rejected token lists as an empty account. Each remembered id the account lists
  comes back: a Trash row goes, and an active copy follows last-write-wins. The far-future hold-off
  applies, and a held-off id stays remembered so the push heals its record first. Everything else
  is forgotten. A throw forgets nothing.
- **An archive row stays archived** (spec section 8, reading 2, owner item 26). It's its own
  commit, so it can be reverted cleanly if Vinny overrules it. Android brings the task back today,
  until AND-RESURRECT-ARCHIVE lands.

## Evidence

`ResurrectOnSightTests` runs every iOS row of the spec's section 6 table under its exact name,
through the real `SyncEngine`, GRDB repositories, and `TaskStore`, against a fake account that
lists, deletes, and confirms the owner. The Erase row is in `TaskStoreDataTests`. Fourteen of the
17 failed before the change, including the three journeys, where today's iOS sent the delete to
the server. The other three are guards that pass both ways: a re-sign-in drops nothing, a failed
first sync swallows nothing, and a signed-in delete still deletes. The real-server run is pending
on owner item 24.

## After review

S-AND's review and the Lead's decisions (2026-11-07) added three fixes, each red first:

- **The drop runs before any push.** At first the coordinator ran the drop just after sign-in,
  which left windows: a debounced push, or a foreground sync as OAuth returns, could reach the
  queue first. Now the mark is set before the token exists and the engine drops on its first run,
  whatever triggered it (`a mutation-triggered push right after sign-in sends no signed-out
  delete`). The mark records order only; the drop still decides by the cursor, once per sign-in.
- **A run forgets only its own snapshot.** An id that a concurrent sign-in remembers during the
  step's awaits survives (`anIdRememberedWhileTheStepAwaitsIsKept`).
- **A resurrected task merges into its Trash row,** as web does, so its rich time entries and this
  device's reminder state survive (`a resurrected task keeps this device's reminder state and
  time-entry notes`). Android gets the same change in AND-RESURRECT-PARITY.

## IOS-RESURRECT-2

S-AND's review of web #701 found two gaps on Android (A1, A2), and iOS had both. The Lead's
decisions (2026-11-08) put them in one PR, each red first:

- **A delete queued since the id was remembered wins (A1).** A run that fails keeps its ids. If
  the user then restores that task and trashes it again, the step brought it back, the push sent
  the delete, and the reconcile removed the active copy with no Trash copy left. The step now
  waits on any queued delete for the id, keeps the id, and leaves the Trash row
  (`waitsForThisDevice`, mirroring web's guard). SPEC-3 rule 3 says "a queued delete that will
  still push". A failed delete counts, because `requeueFailed` re-arms it, and Android counts
  failed rows too; web counts pending only. A stale delete counts as well: the push drops it, and
  its newer server copy brings the task back through the pull instead, so excluding it would change
  nothing. Tests: `a remembered id with a pending delete stays in Trash and is kept`, `a remembered
  id with a failed delete stays in Trash and is kept`, and the journey `a task restored and trashed
  again while its id is remembered stays in Trash after the next sync`.
- **A failing step doesn't stop the push (A2).** A throw from the step ended `sync()` before its
  push, so a server copy this build can't read, which fails every complete listing, would have held
  back the user's own edits for as long as an id stayed remembered. The step's error is now logged
  (`os.Logger`, subsystem `dev.vinny.gsd`, category `sync`), it forgets nothing (rule 5), and the
  run goes on to the push and the reconcile, as web does. An ended session (`StaleSyncSession`)
  still stops the run. Test: `a step that fails forgets nothing and leaves the sync successful`.
- **A token confirmed for another account still stops the run** (the Lead's review of #97). The
  step's `SyncIdentityMismatch` stays fatal, because iOS pulls, runs the step, then pushes, and the
  push has no identity check of its own. The reconcile has one, but it runs after the push and only
  when something is missing from the server. Web pushes before its step, so it can skip the step
  safely. Test: `a step whose identity check fails stops the run before the push`.
- **A token the server rejects still stops the run** (S-AND's second review of #97, F1). A rejected
  token lists as an empty account, so the step's auth-refresh is the first to see it, as a
  `PocketBaseError` with status 401 or 403. Those statuses stay fatal, read as `AccountDeleter`
  reads them, so the push never sends queued writes to a dead session and spends no retry on them.
  Android rethrows its `Unauthorized` for the same reason. Test, Android's name: `a dead session
  found by the step pushes nothing`.
