# The demo seed never touches real data

| Field | Value |
|---|---|
| Date | 2026-10-25 |
| Status | Accepted |
| Deciders | Vinny Carpenter |

## Context

`--demo-seed` is the launch argument the screenshot and video harness passes (`RefreshBaseline`,
`DemoChoreography`). `DemoSeed.seedIfRequested` deleted every task in the live store through
`TaskStore.delete`, which queues a server delete for each one, then created 24 fixtures stamped
with the frozen demo clock.

On a simulator that is harmless: simulators are never signed in, and each one has its own
container. On the Mac it is not. A dev-signed Catalyst build carries the same team and app group
as the installed app, so it opens the same `gsd.sqlite` in
`~/Library/Group Containers/group.dev.vinny.gsd` and reads the same session token from the shared
keychain. The Sept 15 harness runs were safe only because Catalyst signing was broken then. The
Oct 18 signing fix made the harness destructive, and the demo fixtures showed up in the owner's
account that morning.

On Oct 24 at 17:17 CDT the Mac widths tests (`testSelectionSurvivesRootSwap`,
`testCaptureWidths`) launched the dev build several times. The first launch's sync pushed 191
operations in 32 seconds. Afterward the Mac's Trash held 166 real tasks, every one stamped
2026-09-11 17:00 UTC, and PocketBase held nothing from before that evening. The web and the
iPhone dropped the tasks through deletion reconcile, which keeps no Trash copy. On Oct 25 the
tasks were rebuilt from the Mac's Trash table and merge-imported on the web.

## Decision

Two fences, either of which would have prevented the incident.

- **A demo-seed launch never opens the shared store and never has a session.** `GSDApp.init`
  reads the flag before it builds anything. With the flag set, the database is
  `AppDatabase.inMemory()` and the token store is `SignedOutTokenStore`, so
  `SyncCoordinator.start` returns at its signed-in guard, SSE never connects, and the queue has
  nowhere to go. Every harness launch seeds a fresh, empty store and leaves nothing behind.
- **The seed may only clear tasks it created itself.** The fixtures moved into the package as
  `DemoFixtures`, with `seed(into:now:)` guarded by `DemoFixtures.ids`. A store that holds any
  other task is refused untouched (`SeedError.storeHoldsRealTasks`), and
  `GSDStoreTests/DemoFixturesTests` pins that: the real task stays, and nothing is queued. The
  guard reads the live table only, which is the set the seed deletes.

`App/Support/DemoSeed.swift` keeps the launch argument and the `hasOnboarded` write and calls
the package seed.

## Consequences

- The Mac harness is safe to run while signed in. It seeds an in-memory store and shows Settings
  signed out, which is what the simulator walks already showed.
- Each launch starts empty, so the seed's "clear the prior run" step is a no-op in practice.
  `DemoChoreography`'s multi-launch scenes get the same fixtures every time, which is what the
  frozen clock was for.
- The widget snapshot still refreshes from the seeded store, so the faux Home Screen scene
  (`--demo-home`) keeps its data. As before, a Mac harness run overwrites the snapshot file in
  the App Group with fixture data.
- A refused seed prints to the console and leaves the matrix as it was. The harness then fails
  loudly on "seeded cards never appeared" instead of destroying data.
- Not changed here: the Apple push still has no edit-beats-delete guard (backlog B-42),
  deletion reconcile on web and iOS still hard-deletes local copies, and the web's import pushes
  a task's original `client_updated_at`, which other clients' cursor pulls never fetch.

## Alternatives considered

- **Refuse to seed when a session token exists.** Rejected as the only fence: a signed-out Mac
  still holds the owner's real local tasks, and the seed would trash them with a 2026-09-11
  stamp that the 30-day retention sweep purges on the next real launch.
- **A demo database file in the container.** Rejected: an on-disk store needs cleanup between
  runs and still sits beside the real one. In-memory is isolated by construction and costs
  nothing the harness notices.
- **Guard the seed inside the App target.** Rejected: the App target has no unit tests, and the
  guard is the part that must stay tested.
