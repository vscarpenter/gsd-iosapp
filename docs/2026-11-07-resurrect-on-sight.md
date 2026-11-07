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
