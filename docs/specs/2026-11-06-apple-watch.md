# Apple Watch app

**Status:** DRAFT for owner review. Next step: owner answers section 13, then writing-plans, then execute.
**Date:** 2026-11-06
**Branch:** one per slice in section 11 (`feat/watch-contract`, `feat/watch-phone-session`, and so on)
**Floor:** watchOS 26.0 (owner decision, 2026-11-06)
**Depends on:** Phase 6a (widget snapshot), Phase 6d (the outbox pattern), B-17 (reminder actions, 3.7.0), and escalation (Sprint 1, 3.7.0). The Today screen also needs top three on Apple (roadmap phase 4, `gsd-taskmanager/tasks/spec-top-three.md`).

---

## 1. Goal

Put four things on the wrist: today's top three, voice capture, the Do First list with escalating tasks, and reminders you can act on. The watch is a thin client. The iPhone stays the only device that writes the database, schedules reminders, and syncs.

One sentence: *the iPhone sends the watch a small snapshot of the tasks it can show, and the watch sends back commands that the iPhone applies through `TaskStore`.*

## 2. Scope

**In:**

- A watchOS app target, `GSDWatch`, embedded in the iOS app, and a watch widget extension, `GSDWatchWidgets`.
- Four surfaces: Today, Do First, Capture, and reminder notifications (section 4).
- The iPhone-to-watch contract in `GSDSnapshot`: `WatchSnapshot`, `WatchCommand`, the selection builder, the command plan, and the pending-command overlay (section 6).
- App glue on the iPhone: `WatchSessionCoordinator` pushes snapshots and applies commands.

**Out of v1:**

- Direct PocketBase sync from the watch. Without the iPhone, the watch shows its last snapshot and queues changes (decision 1).
- Editing title, notes, due date, tags, subtasks, or dependencies. The matrix, Saved, Trash, the dashboard, settings, What's New, the weekly sweep, and the timer.
- Reminders scheduled on the watch. The iPhone schedules every reminder, so none fires twice.
- Any change on web, Android, MCP, or the server. This is an Apple-only feature; Android's matching item, Wear OS, is a non-goal in its spec.
- Mac: the Catalyst build must not embed the watch app.

## 3. Product rules

- **Offline-first.** The watch works with no account and no network. Data travels only between the paired iPhone and watch, over WatchConnectivity. No new server, synced field, or network call. Copy must not imply the cloud.
- **Same answers as the phone.** Every list the watch shows runs the shared `GSDModel` functions: `Escalation.evaluate`, plus `todaysPicks` and `suggest` from phase 4. The cross-platform corpora pin them, so there's no watch-only copy of a rule.
- **Calm.** No counts that grow, no red badges, no streaks, and none of the words top three bans (missed, unfinished, failed). The matrix stays on the phone; the watch shows short lists.

## 4. Surfaces

### 4.1 Today (home screen once phase 4 ships on Apple)

| | |
|---|---|
| With picks | Rows in rank order from `todaysPicks`: title, due chip, and a complete control |
| With no picks | One line, "Pick up to three for today", which opens the first three from `suggest`, each with "Add to today" |
| Full | "Add to today" is hidden on other rows |
| Two-device conflict | Show the three picks. The Tidy offer stays on the iPhone |
| Carry-over | Not on the watch in v1 |
| Accessible name | "Today, 2 of 3" on the section; each row reads its title, then "first", "second", or "third" (top three spec section 4) |

Before phase 4 ships, Do First is the home screen (decision 2).

### 4.2 Do First

- Rows: the same `today-focus` criteria the iPhone widget uses (`WidgetSnapshotBuilder.todaysFocusViewID`), in the same order.
- Below them, under "Coming up" (draft copy), the tasks `Escalation.evaluate` marks as escalating, using the iPhone's escalation window. Each row carries the existing marker text (`Escalation.accessibilityLabel(daysUntilDue:)`).
- Row actions: Complete; Mark urgent on escalating rows, with `Target.markUrgentHint` as the hint ("Moves to Do First" or "Moves to Delegate"); and Add to today once phase 4 ships.
- At most 20 rows, then "+N more on iPhone".

### 4.3 Capture

- Entry points: a button on the home screen and the circular complication (section 4.5).
- Step 1 is a text field, which offers dictation, Scribble, and the keyboard on supported watches.
- Step 2 is a quadrant choice: four labeled buttons, preselected by `CaptureParser.parse`. Typed shorthand still works (`!!`, `!`, `*`, `#tag`), but dictation rarely produces it, so the buttons are the real control. With no flags, the preselection matches the iPhone capture bar's default.
- Add queues a `capture` command and shows the task right away through the overlay (section 6.4).
- No due date in v1, because `CaptureParser` doesn't parse dates (decision 3).

### 4.4 Reminders

- The iPhone keeps scheduling every reminder (`ReminderScheduling`, `ReminderResyncer`). The watch app schedules none.
- iPhone notifications already appear on the watch when the iPhone is locked. With the watch app installed, the watch draws a GSD notification scene: title, quadrant, due time, and the escalation marker when one applies.
- The category stays `ReminderAction.categoryID`, with the same two actions: Complete and Snooze 1 hour (`ReminderAction.completeID`, `ReminderAction.snoozeID`).
- An action the watch app receives becomes a `complete` or `snooze` command. An action the iPhone receives takes the existing `ReminderActionInbox` path. Which app receives it is open item 2 in section 10; the design works either way.
- Tapping the notification opens the watch app on the list that holds the task.

### 4.5 Widgets and complications

The watch widget extension reads the snapshot that the watch app saves into the watch's App Group container.

| Family | Shows |
|---|---|
| `accessoryRectangular` (Smart Stack and faces) | Today's picks (up to three titles) when there are picks for the local today; otherwise the first Do First rows; when both are empty, "Clear for now" (draft copy) |
| `accessoryInline` | The next timed task due today, as "2:00 PM Call the dentist"; otherwise the app name |
| `accessoryCircular`, `accessoryCorner` | The app glyph, no number. A tap opens Capture |

- **Midnight.** Top three spec section 9 applies: compare the snapshot's dates with the local date when drawing. Timeline entries: now, each due time left today, and the next local midnight, with `.atEnd`.
- **Relevance.** Give the Smart Stack relevance around today's due times, if watchOS 26 offers it (open item 4).
- The widget doesn't add, remove, or complete in v1. A tap opens the app.

## 5. Data flow

```
iPhone                                                Watch
TaskStore.onTasksChanged
  → WatchSnapshotBuilder (pure)
  → WCSession.updateApplicationContext  ──────────→  save snapshot to the watch App Group
                                                       → screens and widgets read it

iPhone WatchCommandApplier                            user action
  ← WCSession didReceiveUserInfo  ←───────────────   WatchOutbox (watch App Group) + overlay
  → WatchCommandPlan (pure) → TaskStore                → WCSession.transferUserInfo
  → onTasksChanged → new snapshot carrying the applied command ids
```

- `updateApplicationContext` keeps only the latest value and delivers it when the watch app next runs, which fits a snapshot.
- `transferUserInfo` queues in order and delivers when it can, which fits commands that must not be lost. `sendMessage` isn't used in v1.
- Applied commands are ordinary `TaskStore` edits. They stamp `updatedAt` and enqueue to sync, so `SyncCoordinator` pushes them like any other edit. Sync needs no change.
- **Known edge:** `TaskStore` stamps `updatedAt` when the iPhone applies a command, not when the watch issued it. A command made at 9:00 and applied at 11:00 can win last-write-wins over a 10:00 edit from another device. This matches how any offline edit behaves, so v1 accepts it.

## 6. The contract (in `GSDSnapshot`, GRDB-free)

### 6.1 `WatchSnapshot`

| Field | Type | Notes |
|---|---|---|
| `version` | `Int` | 1 |
| `generatedAt` | `Date` | Shown as "Updated 9:41 AM" |
| `escalationWindowDays` | `Int?` | The iPhone's setting; `nil` is Off |
| `tasks` | `[WatchTask]` | At most 100 (section 6.2) |
| `doFirstTotal` | `Int` | For "+N more on iPhone" |
| `appliedCommandIDs` | `[String]` | The last 50 applied, so the watch can drop them from the overlay |

`WatchTask`: `id`, `title`, `urgent`, `important`, `dueDate`, `createdAt`, `updatedAt`, `isRecurring`, and the optional `focusDate` and `focusRank`, which stay `nil` until phase 4. The watch maps a `WatchTask` to `GSDModel.Task` with the init's defaults for every other field, then runs the shared rules on it. The rules are evaluated on the watch at draw time, in the watch's time zone, so a snapshot from yesterday still draws today's answer.

Every field added later is optional, so a newer iPhone and an older watch app (or the reverse) still decode.

### 6.2 What the snapshot carries

Active rows only: not completed, no `savedAt`, never archived or trashed. A row goes in when any of these is true:

1. It's urgent and important.
2. It could escalate under the longest window (7 days): not urgent, with a due date no more than 7 calendar days ahead, or overdue.
3. It has a `focusDate` of yesterday or later (phase 4), so time-zone edges and the midnight rule still have the data.

Over 100 rows, keep picks first, then order by due date ascending, then `createdAt`.

### 6.3 `WatchCommand`

Each command has an `id` (a UUID made on the watch), an `issuedAt`, and one kind:

| Kind | iPhone applies | Skips when |
|---|---|---|
| `complete(taskID)` | `toggleComplete` | Missing or already completed |
| `reopen(taskID)` | `toggleComplete` (Undo) | Missing or not completed (see open item 8) |
| `markUrgent(taskID)` | `move` to the escalation target quadrant; importance never changes | Missing, completed, or already urgent |
| `snooze(taskID)` | `snooze(by: .oneHour)` | Missing or completed |
| `addToToday(taskID)` | Top three write rules (spec-top-three section 3.2) | `nextRank` is `nil`, or not eligible |
| `removeFromToday(taskID)` | Clear both fields | Not a pick |
| `capture(text, quadrant)` | `add(CaptureParser.parse(text), override: quadrant)`; the iPhone parses the raw text again, so both devices read it the same way | Empty after trimming |

`toggleComplete` flips state, which is why the plan checks state before calling it. Without that check, a command delivered twice would complete and then reopen.

`WatchCommandPlan.decide(command, current task) -> action or skip(reason)` is pure and lives in `GSDSnapshot`. The App-layer applier only calls `TaskStore`.

**Idempotency.** The iPhone records applied command ids (the last 200) in App-Group `UserDefaults`. A repeated id is skipped and still reported back in `appliedCommandIDs`.

### 6.4 The overlay

`WatchOverlay.apply(snapshot, pending) -> lists` is pure, and it shows pending commands on top of the snapshot. A completed row leaves the list, and a capture appears in its chosen quadrant. Mark urgent moves the row, and picks change. A pending command leaves the overlay once its id appears in `appliedCommandIDs`.

- After Complete, the row shows Undo for 4 seconds. Undo removes the command if it hasn't left the queue; otherwise it queues `reopen`.
- While commands are pending, the home screen footer reads "2 changes waiting for iPhone" (draft copy). The footer always shows when the snapshot was made.

## 7. Package and project changes

- **`GSDKit/Package.swift`:** add `.watchOS(.v26)` to `platforms`. The watch targets link only `GSDModel` and `GSDSnapshot`. `GSDStore`, `GSDSync`, `GSDWire`, and GRDB stay off the watch.
- **`project.yml`:** add `GSDWatch` (bundle id `dev.vinny.gsd.watchkitapp`) and `GSDWatchWidgets` (`dev.vinny.gsd.watchkitapp.widgets`). Embed the watch app in `GSD` with `platformFilter: iOS`, as the widgets are, so the Catalyst build doesn't carry it. The watch targets share the project-wide version. Each gets a `PrivacyInfo.xcprivacy`. Run `xcodegen generate`; never edit the pbxproj or plists by hand.
- **App Group:** the watch app and watch widgets share a container on the watch. Reuse `AppGroup.id` (`group.dev.vinny.gsd`) so the constant stays the single source of truth; App Group containers are per device, so this shares nothing with the iPhone.
- **iPhone app:** `App/Watch/WatchSessionCoordinator.swift`, an `@MainActor @Observable` like `SyncCoordinator`. It does nothing when `WCSession.isSupported()` is false (iPad, Mac) or in the isolated test harness (`isolated`, as Spotlight is gated in `GSDApp.swift:136`). It pushes a snapshot debounced by 1 second, and again when the watch app is installed or the pairing changes. It applies commands in arrival order.
- **Hook:** `store.onTasksChanged` in `GSDApp.swift:133` is a single closure that already fans out to the widget, reminder, and Spotlight refreshers. Add `watchSession.schedule()` inside it; don't replace the closure.
- **Feedback:** when the watch ships, retire the `apple-watch` slug from `Feedback.swift`, and never reuse it.

## 8. Accessibility

- VoiceOver names on every row and control, including the top three ordinals. Quadrant buttons carry names, not only color.
- Dynamic Type at every size, including the accessibility sizes. Rows wrap instead of truncating to one letter.
- Capture works with dictation and Scribble alone.
- No Double tap shortcut on Complete in v1 (decision 4).
- Reduce Motion replaces the overlay's row animation with a fade.

## 9. Tests (TDD, red first)

`GSDSnapshotTests`:

1. `WatchSnapshotBuilder`: each selection rule in section 6.2; completed and Saved rows left out; the 100-row cap and its order; `appliedCommandIDs` carried through.
2. `WatchSnapshot` decodes a version 1 payload with the phase 4 fields missing.
3. `WatchCommandPlan`: every kind against a missing, active, completed, and recurring task; a repeated command id skips.
4. `WatchOverlay`: every pending kind; acknowledged ids drop out; Undo before and after the command leaves the queue.
5. **Corpus reuse.** Run `escalation-corpus.json` through the `WatchTask` to `Task` mapping, to prove the mapping keeps every field escalation reads. When phase 4 lands, do the same with the `top-three-corpus.json` cases for `todaysPicks` and `suggest`.

App glue is verified by build and smoke, as with the other extensions:

- Builds: iPhone, iPad, Mac Catalyst (still builds with no watch app embedded), and a watch simulator.
- Paired-simulator smoke: add a task on the iPhone and see it on the watch; complete on the watch and see it on the iPhone; capture on the watch while the iPhone app isn't running, then open it.
- Device gate (owner, signed build on a real watch): reminder action routing, background delivery to the iPhone, the widget's midnight refresh, and dictation.

## 10. Verify before building

Items 6 and 7 were checked against the code on 2026-11-06. The others weren't confirmed here; check them before the slice that needs them.

1. The XcodeGen target type and embed settings for a single-target watchOS app (slice W3).
2. Which app gets a notification action when an iPhone notification shows on the watch and a GSD watch app is installed (W4).
3. Whether `transferUserInfo` to the iPhone wakes the iOS app in the background or waits for its next launch. If it waits, watch changes land when the iPhone app next runs, as share captures did before iOS #23. That's acceptable for v1, and the "waiting for iPhone" footer covers it (W2).
4. The Smart Stack relevance API on watchOS 26, and how the watchOS 27 tap gesture treats our widget (W5).
5. Whether a watchOS 26 Control (Control Center, and the Action button on Ultra) can open Capture cheaply. If so, add it to W5.
6. **Checked.** `Task.init` gives defaults for every field `WatchTask` leaves out (`GSDModel/Task.swift:37`).
7. **Checked.** `onTasksChanged` is a single closure; chain into it (section 7).
8. What `toggleComplete` does when it reopens a completed recurring task. If the spawned next instance stays, offer Undo only on tasks that don't repeat (W3).

## 11. Rollout as PR slices

| Slice | Branch | Contents | Needs |
|---|---|---|---|
| W1 | `feat/watch-contract` | `.watchOS(.v26)`, `WatchSnapshot`, `WatchTask`, `WatchCommand`, the builder, the plan, the overlay, and tests 1 to 5. No app change | None |
| W2 | `feat/watch-phone-session` | `WatchSessionCoordinator`, snapshot push, the command applier, the applied-id store | W1 |
| W3 | `feat/watch-app` | The two targets in `project.yml`, the watch session client and outbox, Do First, and Capture | W1 |
| W4 | `feat/watch-reminders` | The notification scene and action routing | W3 |
| W5 | `feat/watch-widgets` | The widget families and timeline | W3 |
| W6 | `feat/watch-today` | The Today screen and picks in the widget | W3, and phase 4 merged on Apple |

W2 and W3 can run at the same time once W1 merges. Release: the next Apple minor after W5, with its `whats-new.json` entry written in the web repo first (backlog R-10), watch screenshots in App Store Connect, and the app-launch-kit play.

## 12. Acceptance criteria

- The watch works with no account and no network while the iPhone is nearby, and shows its last snapshot when the iPhone isn't.
- Each watch action produces exactly one `TaskStore` edit on the iPhone, even when delivered twice.
- No reminder fires twice.
- Every list on the watch matches the iPhone's rules, as the corpora prove.
- A widget never shows a pick dated other than the local today.
- The iPad and Mac builds behave as before.

## 13. Decisions for Vinny

These are working defaults. Each is yours to change.

1. **The iPhone is required for sync in v1.** The watch works from its last snapshot and queues changes until the iPhone is reachable. Direct PocketBase sync from the watch, for signed-in users on Wi-Fi or cellular, is a v2 candidate.
2. **Home screen.** Do First until phase 4 ships on Apple, then Today above Do First.
3. **No due date on capture in v1.** The natural-language-dates roadmap item would change this.
4. **No Double tap shortcut on Complete,** to avoid completing by accident. Undo covers mistakes instead.
5. **Mark urgent on the watch.** Included.
6. **Draft copy:** "Pick up to three for today", "Coming up", "Clear for now", "+N more on iPhone", "2 changes waiting for iPhone", and "Updated 9:41 AM".
7. **Retire `apple-watch`** from the feedback roadmap list when the watch ships.
