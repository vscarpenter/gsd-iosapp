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

Two fences, either of which would have prevented the incident. The first was widened after the
review of PR #30 on 2026-10-25, which found the demo launch still driving every out-of-process
writer against the real App Group (the share outbox drain, reminders and the badge, Spotlight,
the widget snapshot, and the App Group defaults) and the isolation keyed on one flag while other
harness launches opened the real store.

- **A harness launch never touches what the real app owns.** One switch,
  `HarnessLaunch.isIsolated` in GSDStore, is true for any `--demo-` argument (`--demo-seed`,
  `--demo-home`, `--demo-clock`, `--demo-appearance`, `--demo-window`), so every XCUITest launch
  flips it. `GSDApp.init` reads it before it builds anything. Isolated, the database is
  `AppDatabase.inMemory()`; the token store is `SignedOutTokenStore`, so `SyncCoordinator.start`
  returns at its signed-in guard, SSE never connects, and the queue has nowhere to go; the
  reminder scheduler is the no-op one; Spotlight is never indexed; and the share outbox and the
  widget snapshot live in a per-process scratch folder. `AppGroupDefaults.shared`, which
  `UserDefaults.shared` and every `@AppStorage(store: .shared)` resolve, is a suite that starts
  empty on each launch and is not the App Group's. The onboarding flag is set there in `init`,
  so the harness never meets the onboarding cover. The legacy `ScreenshotTests` runner now
  launches with `--demo-seed` too. `ReleaseReadinessTests` stay on the live store on purpose,
  since they test persistence across relaunches, behind their `RELEASE_QA` gate for a
  disposable simulator.
- **The seed fills an empty store and refuses any other.** The fixtures live in the package as
  `DemoFixtures`. `seed(into:now:)` throws `SeedError.storeNotEmpty` on a store that holds
  anything, fixture or real, and has no delete path at all, so it cannot clear a store even by
  mistake. `GSDStoreTests/DemoFixturesTests` pins the incident's shape, fixtures beside a real
  task: both rows stay and nothing is queued. The guard reads the live table. Archived and
  trashed rows were never in the seed's reach, and the first fence keeps a seed with a session
  from running at all.

A refused or failed seed stops the launch with `fatalError` at the reason instead of printing and
carrying on. A sign-in completed during a harness run trips an assertion in
`SignedOutTokenStore.save` rather than vanishing. `App/Support/DemoSeed.swift` keeps the launch
argument and calls the package seed.

## Consequences

- The Mac harness is safe to run while signed in. It seeds an in-memory store and shows Settings
  signed out, which is what the simulator walks already showed.
- Each launch starts empty, and the seed has no clear step any more. `DemoChoreography`'s
  multi-launch scenes get the same fixtures every time, which is what the frozen clock was for.
- The widget snapshot refreshes into the scratch folder, so a Mac harness run no longer
  overwrites the App Group snapshot. The faux Home Screen scene (`--demo-home`) never read the
  snapshot: `DemoHomeScreen` builds its own entry inline.
- A refused or failed seed stops the launch at the reason. The harness fails on the crash
  instead of capturing whatever store it found.
- Pending real shares survive a harness run, because the drain reads the scratch outbox, not
  the App Group's. Real reminders, the badge, and Spotlight are left alone.
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
