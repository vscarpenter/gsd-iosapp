# Phase 4 — Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn on the reminder fields that have been carried unwired since Phase 0 — a **behavioral redesign** of the web's polling model (§9). iOS can't poll in the background, so reminders are **scheduled locally at write time** with `UNUserNotificationCenter`. Adds pure scheduling math (`ReminderMath`), a `NotificationSettings` App-Group singleton, an injected `ReminderScheduling` seam wired into `TaskStore`'s §9.1 mutation events, a live `UNUserNotificationCenter` scheduler in the App, the reminder UI in the editor, the Settings → Notifications section, app-icon badges, and a `BGAppRefreshTask` that runs the auto-archive sweep + badge refresh.

**Architecture:** Correctness-critical scheduling math lands as a pure, dependency-free unit in `GSDModel` (`ReminderMath`: `fireDate`/`applyQuietHours`/`shouldSchedule`/`badgeCount`), red→green'd with Swift Testing and an injected `Calendar`/`now` (fireDate offset + past-due skip, quiet-hours defer incl. midnight-crossing, and the badge start-of-today/start-of-tomorrow boundary are all probe-verified). `NotificationSettings` is an App-Group `UserDefaults` singleton mirroring `ArchiveSettings`. The store stays free of `UserNotifications`: it orchestrates through an injected `ReminderScheduling` protocol (with a `NoopReminderScheduler` default so existing call sites + tests compile unchanged), forwarding only the §9.1 events (create/edit → schedule; complete/delete/disable → cancel; snooze → reschedule; recurrence spawn → schedule). The live `LiveReminderScheduler` lives in the App target, `import`s `UserNotifications`, reads `NotificationSettings` itself, and owns the scheduling math via `ReminderMath`. The editor gains a due-date-gated Reminders section; Settings gains a Notifications section; `GSDApp` wires the live scheduler + registers the `BGAppRefreshTask`.

**Tech Stack:** Swift 6 (toolchain Apple Swift 6.3.2, Xcode 26.5), SwiftUI (Observation, `Form`/`Section`/`Picker`/`DatePicker`/`Toggle`), `UserNotifications` (`UNUserNotificationCenter`/`UNMutableNotificationContent`/`UNCalendarNotificationTrigger`/`UNNotificationRequest`) + `BackgroundTasks` (`BGTaskScheduler`/`BGAppRefreshTask`/`BGAppRefreshTaskRequest`) — App target only, GSDKit (`GSDModel` zero-deps + `GSDStore` over GRDB), Swift Testing (`@Test`/`#expect`) for logic, `xcodebuild` for the app, `xcodegen generate` for new files / project.yml capability changes.

**Builds on (Phases 0–3c, committed on `main`):**
- `GSDModel` (zero-dep, Foundation only): `Task` (full §5.1 field set incl. `dueDate`, `notifyBefore: Int?`, `notificationEnabled: Bool` [default `true`], `notificationSent: Bool`, `lastNotificationAt: Date?`, `snoozedUntil: Date?`, `recurrence`, `completed`/`completedAt`; the member init defaults every reminder field; custom lenient `init(from:)` + explicit `CodingKeys`), `Quadrant`, `RecurrenceEngine.spawnNext(from:now:newID:calendar:subtaskID:)` (carries `notifyBefore`/`notificationEnabled` to the new instance, resets `notificationSent`/`lastNotificationAt`/`snoozedUntil`), `DueDatePresets`/`DueDatePreset` + `TimeTracking` (the injected-`calendar`/`now` idiom; "do NOT refactor to locale-dependent math" precedent), `AnalyticsEngine` (its overdue/due-today boundary convention is the one `badgeCount` reuses), `IDGenerator`.
- `GSDStore` (GRDB, no SwiftUI, no `UserNotifications`): `TaskStore` (`@MainActor @Observable`; mutations `add`/`create`/`save`/`toggleComplete`/`move`/`delete`/`snooze`; `toggleComplete` spawns recurrence via `RecurrenceEngine.spawnNext`; injected `clock`/`newID`/`calendar`/`defaults`/repositories; `start()`), `TaskRepository`/`GRDBTaskRepository` (`upsert`/`fetchAll`/`fetch(id:)`/`delete(id:)`/`replaceAll(_:)`/`observeAll()`), `AppGroupDefaults` (`shared`, `Key` namespace) + `ArchiveSettings` (the App-Group singleton pattern `NotificationSettings` mirrors), `StoreLocation.appGroupID = "group.dev.vinny.gsd"`, `runAutoArchiveSweep()`.
- App: `TaskEditorView(request:)` (`Form` of `Section`s incl. `dueDateSection`/`snoozeSection`; `@State dueDate: Date?`/`recurrence`/`snoozedUntil`; the `save()` path with the `// TODO: Phase-4` reminder note), `SettingsView` (`Form`: Appearance/Archive/Data & Storage/About — Notifications was deferred from 3c), `GSDApp` (`@State store`, `@AppStorage(..., store: .shared)`, `.task { store.start(); try? await store.runAutoArchiveSweep() }`), `GSD.entitlements` (App-Group only), `project.yml` (source of truth; `GENERATE_INFOPLIST_FILE: YES`).

**Reference:** design spec `docs/specs/2026-05-30-phase-4-notifications.md` (Groups A–E, A35–A41); product spec `2026-05-30-native-ios-app-design.md` §9 (Notifications) + §5.4 (NotificationSettings); exemplars `docs/superpowers/plans/2026-05-30-phase-3a-filtering-navigation.md`, `…-3b-organize.md`, `…-3c-insights-data.md`.

---

## Architecture conventions locked by this plan (read first)

1. **`GSDModel` stays zero-dependency.** `ReminderMath` and the `NotificationSettings` *value type* link only `Foundation`. **NO `UserNotifications`, NO GRDB, NO SwiftUI.** `String(localized:)` is Foundation-provided (precedent: `TimeTracking.format`).
2. **`GSDStore` has NO `UserNotifications` and NO SwiftUI.** The store orchestrates reminders through an injected `ReminderScheduling` protocol (defined in `GSDStore`); the framework dependency lives only in the App's `LiveReminderScheduler`. `NoopReminderScheduler` is the default so every existing `TaskStore` call site + test compiles unchanged. This protocol seam is the testable boundary (a recording fake asserts the calls).
3. **The store FORWARDS §9.1 events; it does NOT compute fire dates.** `create/save → reminders.schedule(task)`; `toggleComplete(→completed)/delete → reminders.cancel(taskID:)`; `toggleComplete(→active) → reminders.schedule(task)`; `snooze → reminders.schedule(task)` (the live impl reads `snoozedUntil` and schedules there); recurrence spawn → `reminders.schedule(newInstance)`. The store NEVER calls `ReminderMath.fireDate`/`applyQuietHours` and NEVER reads `NotificationSettings` — so it stays free of scheduling policy. The recording-fake tests assert *which call fired with which id/task*, never a fire `Date`.
4. **`LiveReminderScheduler` (App) owns the scheduling math.** Its `schedule(_ task:)` reads `NotificationSettings` from App-Group defaults itself, calls `ReminderMath.fireDate` then `ReminderMath.applyQuietHours` on the survivor, and builds the `UNNotificationRequest` with the stable id `"task-<id>"` (so a reschedule *replaces* rather than stacks: it removes the pending request for that id first, or relies on `UNUserNotificationCenter` de-duplicating by identifier). When `fireDate` returns nil, `schedule` cancels the pending request (a disabled/completed/past task must not keep a stale pending notification).
5. **`badgeCount` is the shared exception.** It is pure `GSDModel` (Foundation), so the *store* and the *background task* may call `ReminderMath.badgeCount(...)` and then `reminders.setBadge(count)` without pulling `UserNotifications` into `GSDStore` (the count is an `Int`; `setBadge` is the protocol method). fireDate/applyQuietHours stay in the App's scheduler; only `badgeCount` is called from the store/background side.
6. **Two distinct gates — do not conflate them.** `shouldSchedule(task:settings:) = settings.enabled (master) && task.notificationEnabled && !task.completed && task.dueDate != nil`. `fireDate` returns nil when `shouldSchedule` is false **OR** the computed fire time is already past. Composition order in the scheduler: `fireDate` (nil → cancel) **then** `applyQuietHours` on the survivor. **PROBE-VERIFIED** (firedate 11/11).
7. **Quiet-hours rule (PROBE-VERIFIED — quiethours 14/14):** if `fire` is in the quiet window, defer to the **next occurrence of `quietEnd` at-or-after `fire`**; else unchanged. Window inclusivity is half-open `[quietStart, quietEnd)`. A window with `quietStart < quietEnd` is same-day; `quietStart > quietEnd` crosses midnight; `quietStart == quietEnd` or a nil endpoint → no suppression. `"HH:mm"` is parsed and the target rebuilt **in the injected calendar's timezone via component arithmetic** (DST-safe — never `TimeInterval` addition, never `Calendar.current`). Midnight-crossing 22:00–07:00: 23:30 → next-day 07:00; 06:00 → same-day 07:00; 12:00 → unchanged; exactly 22:00 → defers; exactly 07:00 → unchanged.
8. **Badge boundary (PROBE-VERIFIED — badge 8/8):** `badgeCount = active tasks with dueDate < startOfTomorrow` = overdue (`dueDate < startOfToday`) + due-today (`[startOfToday, startOfTomorrow)`). Due-yesterday counts; due exactly 00:00 today counts; due exactly 00:00 tomorrow does NOT; completed-overdue excluded; no-due excluded. This **reuses `AnalyticsEngine`'s overdue/due-today boundary convention** so the two cannot drift.
9. **`NotificationSettings` mirrors `ArchiveSettings`.** A `Sendable` value type in `GSDModel` (so the App's scheduler can read it without importing `GSDStore`) + App-Group-`UserDefaults`-backed get/set on the store (new `AppGroupDefaults.Key`s). Defaults per §5.4: `enabled=true`, `defaultReminder=15`, `soundEnabled=true`, `quietHoursStart/End=nil`, `permissionAsked=false`. `defaultReminder` is constrained to the offered presets the way `ArchiveSettings.afterDays` is.
10. **`GSDModel.Task` shadows Swift Concurrency's `Task`.** Use bare `Task` only as the domain type; in app/test/store concurrency use `_Concurrency.Task { }` (never bare `Task { }`).
11. **`ReminderScheduling` methods are `async` and the recording fake is `@MainActor`.** `UNUserNotificationCenter` is async; the store `await`s the calls. `TaskStore` is `@MainActor`, so the calls land on the main actor; the recording fake is a `@MainActor` class collecting calls. `NoopReminderScheduler` is `async` no-ops (and must be `Sendable` to be a default `init` argument).
12. **Inject time.** `ReminderMath` takes `now`/`calendar`; tests pin a fixed UTC gregorian calendar + fixed `now`. The live scheduler passes `Date()` / `Calendar.current` at the call site (the only place real time enters).
13. **Accessibility + localization (carried):** Dynamic Type, VoiceOver labels, `String(localized:)` for ALL UI copy, ≥44pt targets.
14. **`UNUserNotificationCenter` / `BGTaskScheduler` / permission / SwiftUI APIs are "confirm at build."** `UNCalendarNotificationTrigger`/`UNMutableNotificationContent`/`requestAuthorization`/`BGAppRefreshTaskRequest`/`setBadgeCount` and the editor/Settings SwiftUI cannot be `/tmp`-probed; they are verified via `xcodebuild` on both simulators (iPhone 17 + iPad Pro 13-inch (M5)). **Notification delivery, the permission prompt, quiet-hours suppression at delivery, the badge appearing, and background-refresh firing are RUNTIME-ONLY — "build-verified + manual pass," NOT unit-testable** (they need a device/simulator with notifications). This is flagged per-task and in the Definition of Done.

---

## Scope calls (from the approved spec §3; do not relitigate)

- **Past-due rule = SKIP.** `fireDate < now` → no schedule (probe-pinned). Rationale: a reminder that should already have fired is stale; firing it immediately on every edit/launch is noise. The badge still reflects overdue tasks, so overdue is surfaced without a stale alert.
- **`fireDate = dueDate − (notifyBefore ?? defaultReminder)`** in minutes; `notifyBefore == 0` means "at due time"; nil offset falls back to `settings.defaultReminder`.
- **No-schedule conditions:** no `dueDate`, master `enabled == false`, task `notificationEnabled == false`, `completed`, or fire already past → nil (cancel any pending).
- **Quiet-hours defer-to-end**, half-open `[start, end)`, midnight-crossing handled (convention 7). Matches the web's suppression intent.
- **Snooze** schedules at `snoozedUntil` directly (the live impl ignores the offset for a snoozed task — `snoozedUntil` is the explicit fire time). The store forwards a `schedule(task)` after `snooze` mutates `snoozedUntil`.
- **Recurrence spawn** schedules the new instance's reminder (carrying `notifyBefore`/`notificationEnabled`; `notificationSent`/`lastNotificationAt`/`snoozedUntil` reset by `spawnNext`).
- **Stable id `"task-<id>"`** so reschedules replace, not stack.
- **`NotificationSettings` (§5.4)** App-Group singleton: `enabled`/`defaultReminder` (15/30/60/120/1440)/`soundEnabled`/`quietHoursStart`/`quietHoursEnd` (`"HH:mm"`?)/`permissionAsked`/`updatedAt`.
- **Editor Reminders section:** `notificationEnabled` toggle + `notifyBefore` picker (None=disabled / At time=0 / 5m / 15m / 30m / 1h / 1d), **due-date-gated** (only shown when a due date is set). "None" maps to `notificationEnabled = false`; any offset maps to `notificationEnabled = true` + that `notifyBefore`. Default selection when first enabling = `defaultReminder`.
- **Settings → Notifications section:** master `enabled`, default-reminder picker, `soundEnabled`, quiet-hours start/end (`DatePicker .hourAndMinute`, each toggleable on/off → nil), OS permission status row + a contextual "Enable Notifications" (request) / "Open Settings" (denied) affordance, `permissionAsked` tracking.
- **Badges:** `setBadge(count)` via the scheduler on relevant store changes + from background refresh; count from `ReminderMath.badgeCount`.
- **Background refresh:** register one `BGAppRefreshTask` (id `dev.vinny.gsd.refresh`) that runs `runAutoArchiveSweep()` + a badge refresh; reschedules itself. Needs `project.yml`: `UIBackgroundModes` (`fetch` + `processing`) + `BGTaskSchedulerPermittedIdentifiers` Info.plist keys (via `GENERATE_INFOPLIST_FILE` `INFOPLIST_KEY_*` / an explicit `info` plist) + the notification capability is entitlement-free (UNUserNotificationCenter needs no entitlement; only background modes + the permitted-identifiers key are required). **Opportunistic sync is a Phase-5 TODO** (a `// NOTE (Phase 5)` comment, no behavior).
- **Permission requested contextually** (when the user enables reminders / sets a reminder), NOT at cold launch.

---

## Probe Results (run before this plan shipped; folded in)

Three standalone Swift probes ran against the installed toolchain (Apple Swift 6.3.2) in `/tmp/p4-probe/`, each with a fixed UTC gregorian calendar and fixed `now = 2026-06-15 09:00 UTC`:

- **`firedate.swift` — 11/11 PASS.** Pinned rules: `fireDate = dueDate − (notifyBefore ?? defaultReminder)` minutes; `notifyBefore == 0` = at due time; `1440` = 1 day before; nil offset → `defaultReminder`. Returns nil when: no `dueDate`, task `notificationEnabled == false`, master `enabled == false`, `completed`, or `fire < now` (past-due SKIP). The `fire >= now` boundary is **inclusive** (fire exactly at `now` → scheduled). The past-due test is governed by the computed `fire`, not by `dueDate` (a past due with a 0 offset is still nil).
- **`quiethours.swift` — 14/14 PASS.** Pinned rules (convention 7): defer an in-window fire to the next occurrence of `quietEnd` at-or-after `fire`. **Midnight-crossing 22:00–07:00:** 23:30 → next-day 07:00; 06:00 → same-day 07:00; 00:00 → same-day 07:00; 12:00 → unchanged; exactly 22:00 (start, inclusive) → next-day 07:00; exactly 07:00 (end, exclusive) → unchanged. **Same-day 09:00–17:00:** 12:00 → 17:00; 08:00/18:00 → unchanged; exactly 09:00 → 17:00; exactly 17:00 → unchanged. nil start, nil end, and zero-length (22:00–22:00) windows → unchanged. Target built via component arithmetic in the injected calendar's timezone (DST-safe).
- **`badge.swift` — 8/8 PASS.** Pinned rule (convention 8): active tasks with `dueDate < startOfTomorrow`. Overdue-yesterday counts; due exactly 00:00 today counts; due later today counts; due exactly 00:00 tomorrow excluded; due tomorrow excluded; completed-overdue excluded; no-due excluded; a mixed 7-task set → 3.

> The `UNUserNotificationCenter` (`UNCalendarNotificationTrigger`/`UNMutableNotificationContent`/`requestAuthorization`/`setBadgeCount`), `BGTaskScheduler`/`BGAppRefreshTask`, permission, and editor/Settings SwiftUI APIs are **confirm-at-build** (cannot be `/tmp`-probed) — verified by `xcodebuild` on both simulators in Groups C, D, E. Delivery / permission prompt / quiet-hours-at-delivery / badge appearing / background-refresh firing are **runtime-only (build-verified + manual pass)**.

---

## File Structure

```
GSDKit/Sources/GSDModel/
├─ ReminderMath.swift             # NEW (A): fireDate / applyQuietHours / shouldSchedule / badgeCount (pure)
└─ NotificationSettings.swift     # NEW (B): the §5.4 value type (Foundation-only, Sendable)

GSDKit/Tests/GSDModelTests/
└─ ReminderMathTests.swift        # NEW (A): fireDate offset/past-skip, quiet-hours incl. midnight, badge boundary

GSDKit/Sources/GSDStore/
├─ ReminderScheduling.swift       # NEW (B): protocol + NoopReminderScheduler default
├─ AppGroupDefaults.swift         # MODIFIED (B): + notification Key.s
└─ TaskStore.swift                # MODIFIED (B): + reminders: ReminderScheduling dep; notificationSettings get/set;
                                  #               schedule/cancel hooks on create/save/toggleComplete/delete/snooze/spawn;
                                  #               refreshBadge()

GSDKit/Tests/GSDStoreTests/
├─ TaskStoreReminderHooksTests.swift   # NEW (B): recording fake asserts schedule/cancel/reschedule on every §9.1 event
└─ NotificationSettingsStoreTests.swift # NEW (B): App-Group get/set round-trip + defaults + defaultReminder clamp

App/
├─ Notifications/
│  └─ LiveReminderScheduler.swift  # NEW (C): UNUserNotificationCenter impl (fireDate+quietHours via ReminderMath); permission
├─ Background/
│  └─ BackgroundRefresh.swift      # NEW (E): BGAppRefreshTask register/schedule/handle (sweep + badge)
├─ Editor/TaskEditorView.swift     # MODIFIED (D): + Reminders section (notificationEnabled + notifyBefore), due-date-gated
├─ Settings/SettingsView.swift     # MODIFIED (E): + Notifications section (enable/default/sound/quiet-hours/permission)
├─ GSDApp.swift                    # MODIFIED (C+E): inject LiveReminderScheduler into the store; register/schedule BGAppRefreshTask
└─ project.yml                     # MODIFIED (C+E): UIBackgroundModes + BGTaskSchedulerPermittedIdentifiers (→ xcodegen generate)
```

**Sequencing:** A (pure math) → B (settings value + scheduler seam + store hooks, recording-fake tested) land the package/logic before the App groups that consume them: C (live scheduler + permission + wire + project.yml capability) → D (editor UI) → E (Settings section + badges + background refresh). C lands before D/E because D/E exercise the wired scheduler at runtime; the badge/background work in E depends on the store's `refreshBadge()` (B) and the live `setBadge` (C).

---

## Group A — Pure scheduling math (`GSDModel`, `swift test`, sub-second)

> Pure value-in/value-out with injected time. Build fully red→green before anything consumes it. Run from the package root: `cd GSDKit && swift test --filter ReminderMathTests`. Maps **A35**. PROBE-VERIFIED (firedate 11/11, quiethours 14/14, badge 8/8).

### Task A1: `ReminderMath` (fireDate / applyQuietHours / shouldSchedule / badgeCount)

**Files:**
- Create: `GSDKit/Sources/GSDModel/ReminderMath.swift`
- Test: `GSDKit/Tests/GSDModelTests/ReminderMathTests.swift`

`shouldSchedule` and `fireDate` take a tiny `ReminderInputs` projection of the settings (`enabled` master + `defaultReminder`) rather than `NotificationSettings` itself, so `ReminderMath` has no ordering dependency on the `NotificationSettings` type (which lands in Group B) and stays trivially testable. `applyQuietHours`/`badgeCount` take primitives. The live scheduler (Group C) adapts `NotificationSettings` → these inputs at the call site.

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDModelTests/ReminderMathTests.swift`:
```swift
import Testing
import Foundation
@testable import GSDModel

struct ReminderMathTests {
    /// Fixed UTC gregorian calendar; now = Mon 2026-06-15 09:00 UTC (matches the probes).
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }
    private var now: Date { at(2026, 6, 15, 9, 0) }

    private func task(due: Date? = nil, notifyBefore: Int? = nil,
                      enabled: Bool = true, completed: Bool = false) -> Task {
        Task(id: "t", title: "t", urgent: false, important: false, completed: completed,
             createdAt: at(2026, 6, 1), updatedAt: at(2026, 6, 1), dueDate: due,
             notifyBefore: notifyBefore, notificationEnabled: enabled)
    }
    private let on = ReminderMath.Inputs(masterEnabled: true, defaultReminder: 15)

    // MARK: shouldSchedule (the master/task/completed/due gate — not the past gate)
    @Test func shouldScheduleGate() {
        #expect(ReminderMath.shouldSchedule(task(due: at(2026,6,15,12)), inputs: on))
        #expect(!ReminderMath.shouldSchedule(task(due: nil), inputs: on))               // no due
        #expect(!ReminderMath.shouldSchedule(task(due: at(2026,6,15,12), enabled: false), inputs: on)) // task off
        #expect(!ReminderMath.shouldSchedule(task(due: at(2026,6,15,12), completed: true), inputs: on)) // done
        #expect(!ReminderMath.shouldSchedule(task(due: at(2026,6,15,12)),
                inputs: .init(masterEnabled: false, defaultReminder: 15)))              // master off
    }

    // MARK: fireDate (offset + past-due skip) — probe firedate 11/11
    @Test func fireDateUsesDefaultWhenNotifyBeforeNil() {
        #expect(ReminderMath.fireDate(for: task(due: at(2026,6,15,12), notifyBefore: nil),
                inputs: on, now: now) == at(2026,6,15,11,45))
    }
    @Test func fireDateUsesExplicitNotifyBefore() {
        #expect(ReminderMath.fireDate(for: task(due: at(2026,6,15,12), notifyBefore: 60),
                inputs: on, now: now) == at(2026,6,15,11,0))
    }
    @Test func fireDateZeroOffsetIsAtDueTime() {
        #expect(ReminderMath.fireDate(for: task(due: at(2026,6,15,12), notifyBefore: 0),
                inputs: on, now: now) == at(2026,6,15,12,0))
    }
    @Test func fireDateNilWhenShouldNotSchedule() {
        #expect(ReminderMath.fireDate(for: task(due: nil), inputs: on, now: now) == nil)
        #expect(ReminderMath.fireDate(for: task(due: at(2026,6,15,12), completed: true), inputs: on, now: now) == nil)
    }
    @Test func fireDateNilWhenPast() {
        // due 09:05, 15m before → fire 08:50 < now 09:00 → SKIP.
        #expect(ReminderMath.fireDate(for: task(due: at(2026,6,15,9,5), notifyBefore: 15), inputs: on, now: now) == nil)
    }
    @Test func fireDateInclusiveAtNow() {
        // due 09:15, 15m before → fire exactly 09:00 == now → scheduled.
        #expect(ReminderMath.fireDate(for: task(due: at(2026,6,15,9,15), notifyBefore: 15),
                inputs: on, now: now) == at(2026,6,15,9,0))
    }

    // MARK: applyQuietHours — probe quiethours 14/14
    private func q(_ fire: Date, _ start: String?, _ end: String?) -> Date {
        ReminderMath.applyQuietHours(fire, quietStart: start, quietEnd: end, calendar: cal)
    }
    @Test func quietCrossingMidnight() {
        #expect(q(at(2026,6,15,23,30), "22:00", "07:00") == at(2026,6,16,7,0))   // 23:30 → next-day 07:00
        #expect(q(at(2026,6,15,6,0),  "22:00", "07:00") == at(2026,6,15,7,0))    // 06:00 → same-day 07:00
        #expect(q(at(2026,6,15,0,0),  "22:00", "07:00") == at(2026,6,15,7,0))    // 00:00 → same-day 07:00
        #expect(q(at(2026,6,15,12,0), "22:00", "07:00") == at(2026,6,15,12,0))   // 12:00 → unchanged
        #expect(q(at(2026,6,15,22,0), "22:00", "07:00") == at(2026,6,16,7,0))    // exactly start → defers
        #expect(q(at(2026,6,15,7,0),  "22:00", "07:00") == at(2026,6,15,7,0))    // exactly end → unchanged
    }
    @Test func quietSameDay() {
        #expect(q(at(2026,6,15,12,0), "09:00", "17:00") == at(2026,6,15,17,0))
        #expect(q(at(2026,6,15,8,0),  "09:00", "17:00") == at(2026,6,15,8,0))
        #expect(q(at(2026,6,15,18,0), "09:00", "17:00") == at(2026,6,15,18,0))
        #expect(q(at(2026,6,15,9,0),  "09:00", "17:00") == at(2026,6,15,17,0))   // exactly start → defers
        #expect(q(at(2026,6,15,17,0), "09:00", "17:00") == at(2026,6,15,17,0))   // exactly end → unchanged
    }
    @Test func quietNilOrZeroLengthIsUnchanged() {
        #expect(q(at(2026,6,15,23,0), nil, "07:00") == at(2026,6,15,23,0))
        #expect(q(at(2026,6,15,23,0), "22:00", nil) == at(2026,6,15,23,0))
        #expect(q(at(2026,6,15,22,0), "22:00", "22:00") == at(2026,6,15,22,0))
    }

    // MARK: badgeCount — probe badge 8/8
    private func dueTask(_ due: Date?, completed: Bool = false) -> Task {
        Task(id: UUID().uuidString, title: "t", urgent: false, important: false, completed: completed,
             createdAt: at(2026,6,1), updatedAt: at(2026,6,1), dueDate: due)
    }
    @Test func badgeBoundary() {
        #expect(ReminderMath.badgeCount(tasks: [dueTask(at(2026,6,14))], now: now, calendar: cal) == 1)
        #expect(ReminderMath.badgeCount(tasks: [dueTask(at(2026,6,15,0,0))], now: now, calendar: cal) == 1)
        #expect(ReminderMath.badgeCount(tasks: [dueTask(at(2026,6,16,0,0))], now: now, calendar: cal) == 0)
        #expect(ReminderMath.badgeCount(tasks: [dueTask(at(2026,6,14), completed: true)], now: now, calendar: cal) == 0)
        #expect(ReminderMath.badgeCount(tasks: [dueTask(nil)], now: now, calendar: cal) == 0)
    }
    @Test func badgeMixedSet() {
        let ts = [dueTask(at(2026,6,10)), dueTask(at(2026,6,15,8,0)), dueTask(at(2026,6,15,0,0)),
                  dueTask(at(2026,6,16,0,0)), dueTask(at(2026,6,20)),
                  dueTask(at(2026,6,9), completed: true), dueTask(nil)]
        #expect(ReminderMath.badgeCount(tasks: ts, now: now, calendar: cal) == 3)
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter ReminderMathTests` → FAIL (`ReminderMath` not found).

- [ ] **Step 3: Write `ReminderMath.swift`** (pure; date math probe-verified — firedate 11/11, quiethours 14/14, badge 8/8):
```swift
import Foundation

/// Pure reminder scheduling math (product spec §9). Value-in/value-out with injected
/// `now`/`calendar` — no `Date()`, no `Calendar.current`, no `UserNotifications`. The
/// live scheduler (App layer) calls these; the store calls only `badgeCount`. All rules
/// are PROBE-VERIFIED (firedate 11/11, quiethours 14/14, badge 8/8).
public enum ReminderMath {
    /// The slice of `NotificationSettings` that fire-time math needs. Kept separate from
    /// `NotificationSettings` so `ReminderMath` has no type dependency on it (and stays in
    /// `GSDModel` with zero ordering constraints). The live scheduler adapts settings → this.
    public struct Inputs: Sendable, Equatable {
        public let masterEnabled: Bool
        public let defaultReminder: Int   // minutes
        public init(masterEnabled: Bool, defaultReminder: Int) {
            self.masterEnabled = masterEnabled
            self.defaultReminder = defaultReminder
        }
    }

    /// The master/task/completed/due gate (NOT the past-time gate — that lives in `fireDate`).
    /// True iff a reminder is conceptually wanted for this task.
    public static func shouldSchedule(task: Task, inputs: Inputs) -> Bool {
        inputs.masterEnabled && task.notificationEnabled && !task.completed && task.dueDate != nil
    }

    /// The local fire time = `dueDate − (notifyBefore ?? defaultReminder)` minutes, or nil
    /// when the task shouldn't fire (`shouldSchedule` false) OR the fire time is already past
    /// (the `fire >= now` boundary is inclusive). Quiet-hours deferral is applied separately.
    public static func fireDate(for task: Task, inputs: Inputs, now: Date) -> Date? {
        guard shouldSchedule(task: task, inputs: inputs), let due = task.dueDate else { return nil }
        let offsetMinutes = task.notifyBefore ?? inputs.defaultReminder
        let fire = due.addingTimeInterval(TimeInterval(-offsetMinutes * 60))
        guard fire >= now else { return nil }   // past-due rule: SKIP
        return fire
    }

    /// Defer an in-window fire to the next occurrence of `quietEnd` at-or-after `fire`;
    /// otherwise unchanged. Window is half-open `[quietStart, quietEnd)`. `quietStart > quietEnd`
    /// crosses midnight; `quietStart == quietEnd` or a nil/invalid endpoint → no suppression.
    /// `"HH:mm"` is parsed and the target rebuilt in the injected calendar's timezone via
    /// component arithmetic (DST-safe).
    public static func applyQuietHours(_ fire: Date, quietStart: String?, quietEnd: String?,
                                       calendar: Calendar) -> Date {
        guard let qs = quietStart, let qe = quietEnd,
              let start = parseHHmm(qs), let end = parseHHmm(qe) else { return fire }
        let startMin = start.hour * 60 + start.minute
        let endMin = end.hour * 60 + end.minute
        guard startMin != endMin else { return fire }   // zero-length → no suppression

        let comps = calendar.dateComponents([.hour, .minute], from: fire)
        let f = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let inWindow = startMin < endMin
            ? (f >= startMin && f < endMin)              // same-day window
            : (f >= startMin || f < endMin)              // crosses midnight
        guard inWindow else { return fire }

        let startOfDay = calendar.startOfDay(for: fire)
        var target = calendar.date(byAdding: DateComponents(hour: end.hour, minute: end.minute),
                                   to: startOfDay)!
        if target <= fire { target = calendar.date(byAdding: .day, value: 1, to: target)! }
        return target
    }

    /// App-icon badge: active tasks with `dueDate < startOfTomorrow` (overdue + due-today).
    /// Reuses `AnalyticsEngine`'s overdue/due-today boundary so the two cannot drift.
    public static func badgeCount(tasks: [Task], now: Date, calendar: Calendar) -> Int {
        let startToday = calendar.startOfDay(for: now)
        let startTomorrow = calendar.date(byAdding: .day, value: 1, to: startToday)!
        return tasks.filter { task in
            guard !task.completed, let due = task.dueDate else { return false }
            return due < startTomorrow
        }.count
    }

    /// Parse `"HH:mm"` (24-hour). Returns nil for malformed or out-of-range input.
    private static func parseHHmm(_ s: String) -> (hour: Int, minute: Int)? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return (h, m)
    }
}
```

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter ReminderMathTests` → PASS (13 tests). Re-run full `cd GSDKit && swift test` → still green (additive; nothing else references `ReminderMath`).
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDModel/ReminderMath.swift GSDKit/Tests/GSDModelTests/ReminderMathTests.swift && git commit -m "feat: add pure ReminderMath (fireDate, quiet-hours defer, badge count)"`

> **Probe note:** `fireDate` offset + past-skip verified in `/tmp/p4-probe/firedate.swift` (11/11); quiet-hours defer incl. midnight-crossing in `/tmp/p4-probe/quiethours.swift` (14/14); badge start-of-today/start-of-tomorrow boundary in `/tmp/p4-probe/badge.swift` (8/8), before this plan shipped.

> **Milestone after Group A:** `ReminderMath` is green via `swift test`. Run `cd GSDKit && swift test --filter ReminderMathTests` and the full `swift test` (no regression) before Group B.

---

## Group B — Settings value + scheduler seam + store hooks (`GSDModel`/`GSDStore`, `swift test`)

> The `NotificationSettings` value type + the `ReminderScheduling` protocol + `NoopReminderScheduler`, then `TaskStore`'s reminder hooks on the §9.1 mutation events (recording-fake tested). Run from the package root: `cd GSDKit && swift test --filter <SuiteName>`. Maps **A36** (store hooks) + part of **A40** (the settings model the UI binds). Lands BEFORE the App groups that consume it.

### Task B1: `NotificationSettings` value type (`GSDModel`)

**Files:** Create `GSDKit/Sources/GSDModel/NotificationSettings.swift`

The §5.4 singleton as a `Sendable` value type in `GSDModel` (so the App's `LiveReminderScheduler` can read it without importing `GSDStore`). No test on its own — it is a plain value type with a clamped `defaultReminder`, exercised through the store in B4. Mirrors `ArchiveSettings`'s shape (defaults + an allowed-values clamp).

- [ ] **Step 1: Write `NotificationSettings.swift`:**
```swift
import Foundation

/// Notification configuration singleton (product spec §5.4). A `Sendable` value type in
/// `GSDModel` so the App's live scheduler can read it without importing `GSDStore`; the
/// store persists it in App-Group `UserDefaults` (mirrors `ArchiveSettings`). `quietHours*`
/// are `"HH:mm"` local-time strings (nil = that bound unset → no quiet window).
public struct NotificationSettings: Equatable, Sendable {
    public var enabled: Bool                 // global reminder master switch
    public var defaultReminder: Int          // minutes before due; one of `allowedReminders`
    public var soundEnabled: Bool
    public var quietHoursStart: String?      // "HH:mm"
    public var quietHoursEnd: String?        // "HH:mm"
    public var permissionAsked: Bool         // whether the OS prompt was shown

    /// The offered default-reminder presets (§5.4): 15m, 30m, 1h, 2h, 1 day.
    public static let allowedReminders = [15, 30, 60, 120, 1440]

    public init(enabled: Bool = true, defaultReminder: Int = 15, soundEnabled: Bool = true,
                quietHoursStart: String? = nil, quietHoursEnd: String? = nil,
                permissionAsked: Bool = false) {
        self.enabled = enabled
        self.defaultReminder = NotificationSettings.allowedReminders.contains(defaultReminder) ? defaultReminder : 15
        self.soundEnabled = soundEnabled
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.permissionAsked = permissionAsked
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test` → still green (additive value type).
- [ ] **Step 3: Commit:** `git add GSDKit/Sources/GSDModel/NotificationSettings.swift && git commit -m "feat: add NotificationSettings value type (§5.4)"`

### Task B2: `ReminderScheduling` protocol + `NoopReminderScheduler` (`GSDStore`)

**Files:** Create `GSDKit/Sources/GSDStore/ReminderScheduling.swift`

The injected seam (convention 2/11). `async` methods (UNUNC is async); a `Sendable` no-op default so existing `TaskStore` call sites/tests compile unchanged. No test on its own — exercised via the recording fake in B4 and the live impl in Group C.

- [ ] **Step 1: Write `ReminderScheduling.swift`:**
```swift
import Foundation
import GSDModel

/// The store's reminder-orchestration seam (product spec §9.1). The store calls these on
/// the §9.1 mutation events but never imports `UserNotifications` — the live implementation
/// lives in the App target (`LiveReminderScheduler`). `async` because `UNUserNotificationCenter`
/// is async. `Sendable` so a default instance can be a defaulted `init` argument.
public protocol ReminderScheduling: Sendable {
    /// (Re)schedule the task's local reminder. The implementation computes the fire time
    /// (`ReminderMath` + quiet hours), using the stable id `task-<id>` so a reschedule REPLACES
    /// the pending request. If the task shouldn't fire (disabled/completed/no-due/past), the
    /// implementation cancels any pending request for that id instead.
    func schedule(_ task: Task) async

    /// Cancel the pending reminder for a task (completion / delete / disable).
    func cancel(taskID: String) async

    /// Cancel every pending reminder (used by a full reset).
    func cancelAll() async

    /// Request notification authorization if not already determined (contextual — product
    /// spec §9.2). No-op if already asked/granted/denied. Returns whether reminders are
    /// authorized after the call.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool

    /// Set the app-icon badge (product spec §9.4).
    func setBadge(_ count: Int) async
}

/// The default no-op scheduler so existing `TaskStore` call sites and tests compile and run
/// unchanged (the live scheduler is injected only by the App). Every method is an async no-op.
public struct NoopReminderScheduler: ReminderScheduling {
    public init() {}
    public func schedule(_ task: Task) async {}
    public func cancel(taskID: String) async {}
    public func cancelAll() async {}
    public func requestAuthorizationIfNeeded() async -> Bool { false }
    public func setBadge(_ count: Int) async {}
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test` → still green (additive; nothing references it yet).
- [ ] **Step 3: Commit:** `git add GSDKit/Sources/GSDStore/ReminderScheduling.swift && git commit -m "feat: add ReminderScheduling protocol + NoopReminderScheduler seam"`

### Task B3: `NotificationSettings` App-Group persistence on `TaskStore`

**Files:**
- Modify: `GSDKit/Sources/GSDStore/AppGroupDefaults.swift`
- Modify: `GSDKit/Sources/GSDStore/TaskStore.swift`
- Test: `GSDKit/Tests/GSDStoreTests/NotificationSettingsStoreTests.swift`

Mirror `ArchiveSettings`: new `AppGroupDefaults.Key`s + a `notificationSettings` get/set on the store (UserDefaults-backed). Stores `quietHours*` as optional strings (`removeObject` on nil).

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDStoreTests/NotificationSettingsStoreTests.swift`:
```swift
import Testing
import Foundation
import GSDModel
@testable import GSDStore

@MainActor
struct NotificationSettingsStoreTests {
    private func makeStore() throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        return TaskStore(repository: GRDBTaskRepository(db),
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db),
                         defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
    }

    @Test func defaultsMatchSpec() throws {
        let s = try makeStore().notificationSettings
        #expect(s.enabled == true && s.defaultReminder == 15 && s.soundEnabled == true)
        #expect(s.quietHoursStart == nil && s.quietHoursEnd == nil && s.permissionAsked == false)
    }
    @Test func roundTripsThroughDefaults() throws {
        let store = try makeStore()
        store.notificationSettings = NotificationSettings(enabled: false, defaultReminder: 60,
            soundEnabled: false, quietHoursStart: "22:00", quietHoursEnd: "07:00", permissionAsked: true)
        let back = store.notificationSettings
        #expect(back.enabled == false && back.defaultReminder == 60 && back.soundEnabled == false)
        #expect(back.quietHoursStart == "22:00" && back.quietHoursEnd == "07:00" && back.permissionAsked == true)
    }
    @Test func clearingQuietHoursPersistsNil() throws {
        let store = try makeStore()
        store.notificationSettings = NotificationSettings(quietHoursStart: "22:00", quietHoursEnd: "07:00")
        store.notificationSettings = NotificationSettings(quietHoursStart: nil, quietHoursEnd: nil)
        #expect(store.notificationSettings.quietHoursStart == nil)
        #expect(store.notificationSettings.quietHoursEnd == nil)
    }
    @Test func invalidDefaultReminderClampsTo15() throws {
        let store = try makeStore()
        store.notificationSettings = NotificationSettings(defaultReminder: 999)   // not an allowed value
        #expect(store.notificationSettings.defaultReminder == 15)
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter NotificationSettingsStoreTests` → FAIL (`notificationSettings` not found).

- [ ] **Step 3: Add the keys** to `AppGroupDefaults.Key` in `GSDKit/Sources/GSDStore/AppGroupDefaults.swift` (after `archiveAfterDays`):
```swift
        public static let notificationsEnabled = "notificationsEnabled"
        public static let notificationDefaultReminder = "notificationDefaultReminder"
        public static let notificationSoundEnabled = "notificationSoundEnabled"
        public static let notificationQuietHoursStart = "notificationQuietHoursStart"
        public static let notificationQuietHoursEnd = "notificationQuietHoursEnd"
        public static let notificationPermissionAsked = "notificationPermissionAsked"
```

- [ ] **Step 4: Add `notificationSettings`** to `TaskStore`, in the `// MARK: Archive settings` region (after the `archiveSettings` computed property), as a new `// MARK: Notification settings` block. Because the §5.4 defaults are non-false (`enabled`/`soundEnabled` default `true`), the getter must distinguish "unset" from "set to false" — it reads `object(forKey:) as? Bool ?? <default>`:
```swift
    // MARK: Notification settings (App-Group UserDefaults; mirrors archiveSettings, product spec §5.4)

    public var notificationSettings: NotificationSettings {
        get {
            NotificationSettings(
                enabled: defaults.object(forKey: AppGroupDefaults.Key.notificationsEnabled) as? Bool ?? true,
                defaultReminder: defaults.object(forKey: AppGroupDefaults.Key.notificationDefaultReminder) as? Int ?? 15,
                soundEnabled: defaults.object(forKey: AppGroupDefaults.Key.notificationSoundEnabled) as? Bool ?? true,
                quietHoursStart: defaults.string(forKey: AppGroupDefaults.Key.notificationQuietHoursStart),
                quietHoursEnd: defaults.string(forKey: AppGroupDefaults.Key.notificationQuietHoursEnd),
                permissionAsked: defaults.bool(forKey: AppGroupDefaults.Key.notificationPermissionAsked)
            )
        }
        set {
            defaults.set(newValue.enabled, forKey: AppGroupDefaults.Key.notificationsEnabled)
            defaults.set(newValue.defaultReminder, forKey: AppGroupDefaults.Key.notificationDefaultReminder)
            defaults.set(newValue.soundEnabled, forKey: AppGroupDefaults.Key.notificationSoundEnabled)
            setOrRemove(newValue.quietHoursStart, forKey: AppGroupDefaults.Key.notificationQuietHoursStart)
            setOrRemove(newValue.quietHoursEnd, forKey: AppGroupDefaults.Key.notificationQuietHoursEnd)
            defaults.set(newValue.permissionAsked, forKey: AppGroupDefaults.Key.notificationPermissionAsked)
        }
    }

    private func setOrRemove(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
```

- [ ] **Step 5: Run** `cd GSDKit && swift test --filter NotificationSettingsStoreTests` → PASS (4 tests). Re-run full `cd GSDKit && swift test` → still green (additive).
- [ ] **Step 6: Commit:** `git add GSDKit/Sources/GSDStore/AppGroupDefaults.swift GSDKit/Sources/GSDStore/TaskStore.swift GSDKit/Tests/GSDStoreTests/NotificationSettingsStoreTests.swift && git commit -m "feat: persist NotificationSettings in App-Group UserDefaults on TaskStore"`

### Task B4: `TaskStore` reminder hooks on the §9.1 mutation events (recording-fake tested)

**Files:**
- Modify: `GSDKit/Sources/GSDStore/TaskStore.swift`
- Test: `GSDKit/Tests/GSDStoreTests/TaskStoreReminderHooksTests.swift`

The central testable seam (A36). `TaskStore.init` gains a defaulted `reminders: ReminderScheduling = NoopReminderScheduler()`. The store forwards §9.1 events (convention 3) — it does NOT compute fire dates. A recording fake asserts which `schedule`/`cancel` call fired with which id/task on create/save/toggleComplete/delete/snooze/recurrence-spawn.

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDStoreTests/TaskStoreReminderHooksTests.swift`:
```swift
import Testing
import Foundation
import GSDModel
@testable import GSDStore

/// Records every reminder call so the test can assert the store's §9.1 forwarding.
/// `@MainActor` because `TaskStore` is `@MainActor` and calls land there.
@MainActor
final class RecordingReminderScheduler: ReminderScheduling {
    enum Call: Equatable { case schedule(String), cancel(String), cancelAll, badge(Int), auth }
    var calls: [Call] = []
    nonisolated init() {}
    func schedule(_ task: Task) async { calls.append(.schedule(task.id)) }
    func cancel(taskID: String) async { calls.append(.cancel(taskID)) }
    func cancelAll() async { calls.append(.cancelAll) }
    func requestAuthorizationIfNeeded() async -> Bool { calls.append(.auth); return true }
    func setBadge(_ count: Int) async { calls.append(.badge(count)) }
    /// Schedule/cancel calls only (badge is asserted separately where it matters).
    var scheduleCancelCalls: [Call] { calls.filter { if case .badge = $0 { false } else if case .auth = $0 { false } else { true } } }
}

@MainActor
struct TaskStoreReminderHooksTests {
    private let now: Date = {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 9))!
    }()
    private func utc() -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    private func makeStore(_ rec: RecordingReminderScheduler) throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        let fixed = now
        var idCount = 0
        return TaskStore(repository: GRDBTaskRepository(db),
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db),
                         defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                         clock: { fixed },
                         newID: { idCount += 1; return "id-\(idCount)" },
                         calendar: utc(),
                         reminders: rec)
    }
    private func task(_ id: String, due: Date? = nil, recurrence: RecurrenceType = .none,
                      completed: Bool = false) -> Task {
        Task(id: id, title: id, urgent: false, important: false, completed: completed,
             completedAt: completed ? now : nil, createdAt: now, updatedAt: now,
             dueDate: due, recurrence: recurrence)
    }

    @Test func createSchedules() async throws {
        let rec = RecordingReminderScheduler()
        let store = try makeStore(rec)
        try await store.create(task("a", due: now.addingTimeInterval(3600)))
        #expect(rec.scheduleCancelCalls == [.schedule("a")])
    }
    @Test func saveReschedules() async throws {
        let rec = RecordingReminderScheduler()
        let store = try makeStore(rec)
        try await store.save(task("a", due: now.addingTimeInterval(3600)))
        #expect(rec.scheduleCancelCalls == [.schedule("a")])
    }
    @Test func completeCancelsAndReactivateSchedules() async throws {
        let rec = RecordingReminderScheduler()
        let store = try makeStore(rec)
        try await store.create(task("a", due: now.addingTimeInterval(3600)))      // schedule
        // toggleComplete reads the persisted row; persist it first via create above.
        try await store.toggleComplete(task("a", due: now.addingTimeInterval(3600)))   // → completed → cancel
        try await store.toggleComplete(task("a", due: now.addingTimeInterval(3600), completed: true)) // → active → schedule
        #expect(rec.scheduleCancelCalls == [.schedule("a"), .cancel("a"), .schedule("a")])
    }
    @Test func deleteCancels() async throws {
        let rec = RecordingReminderScheduler()
        let store = try makeStore(rec)
        try await store.delete(task("a"))
        #expect(rec.scheduleCancelCalls == [.cancel("a")])
    }
    @Test func snoozeReschedules() async throws {
        let rec = RecordingReminderScheduler()
        let store = try makeStore(rec)
        try await store.snooze(task("a", due: now.addingTimeInterval(3600)), by: .oneHour)
        #expect(rec.scheduleCancelCalls == [.schedule("a")])
    }
    @Test func completingRecurringSchedulesBothCancelAndSpawn() async throws {
        let rec = RecordingReminderScheduler()
        let store = try makeStore(rec)
        // A recurring task with a due date; toggleComplete cancels the original + schedules the spawn.
        try await store.create(task("r", due: now.addingTimeInterval(3600), recurrence: .daily)) // schedule "r"
        try await store.toggleComplete(task("r", due: now.addingTimeInterval(3600), recurrence: .daily))
        // → cancel "r"; the spawn (a fresh newID, here "id-1") is scheduled. Assert the SHAPE
        // (cancel original + schedule a new, different id) rather than hardcoding the spawn id,
        // since `newID()` is evaluated as a `spawnNext` argument on every toggleComplete call.
        #expect(rec.scheduleCancelCalls.contains(.schedule("r")))
        #expect(rec.scheduleCancelCalls.contains(.cancel("r")))
        let spawnSchedules = rec.scheduleCancelCalls.filter {
            if case .schedule(let id) = $0 { id != "r" } else { false }
        }
        #expect(spawnSchedules.count == 1)   // exactly one schedule for the spawned instance
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter TaskStoreReminderHooksTests` → FAIL (`TaskStore.init` has no `reminders:` parameter; no hooks fire).

- [ ] **Step 3: Edit `TaskStore.swift`.** (a) Add the stored dep + the `init` parameter; (b) add the schedule/cancel calls on the §9.1 events; (c) keep every existing call site working via the default.

(a) After `private let calendar: Calendar` (the stored deps), add:
```swift
    private let reminders: any ReminderScheduling
```
Add the parameter to `init` (last, defaulted — so all existing call sites compile unchanged):
```swift
        calendar: Calendar = .current,
        reminders: any ReminderScheduling = NoopReminderScheduler()
```
and assign it in the body (after `self.calendar = calendar`):
```swift
        self.reminders = reminders
```

(b) Add the forwarding calls. In `create(_:)`, after `try await repository.upsert(t)`:
```swift
        await reminders.schedule(t)
```
In `save(_:)`, after `try await repository.upsert(t)`:
```swift
        await reminders.schedule(t)
```
In `toggleComplete(_:)`: after the main `try await repository.upsert(t)` and before the recurrence guard, branch on the transition:
```swift
        if willComplete { await reminders.cancel(taskID: t.id) }
        else { await reminders.schedule(t) }
```
and after the recurrence spawn upsert (`try await repository.upsert(next)`):
```swift
        await reminders.schedule(next)
```
In `delete(_:)`, replace the one-liner body with:
```swift
    public func delete(_ task: Task) async throws {
        try await repository.delete(id: task.id)
        await reminders.cancel(taskID: task.id)
    }
```
In `snooze(_:by:)`, after `try await repository.upsert(t)`:
```swift
        await reminders.schedule(t)   // live impl schedules at snoozedUntil
```

> **Note (`move`):** `move` changes only the quadrant, not any reminder-bearing field (`dueDate`/`notifyBefore`/`notificationEnabled`/`completed`), so it does NOT forward a reminder call — keeping the call set minimal and the §9.1 mapping exact. (The editor's full-field edit goes through `save`, which reschedules.)

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter TaskStoreReminderHooksTests` → PASS (6 tests). Re-run full `cd GSDKit && swift test` → **must stay green**: every existing `TaskStore(...)` call site (app + tests) uses the `NoopReminderScheduler` default, so the new `await` calls are no-ops and no existing assertion changes.
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDStore/TaskStore.swift GSDKit/Tests/GSDStoreTests/TaskStoreReminderHooksTests.swift && git commit -m "feat: forward §9.1 reminder events from TaskStore via injected ReminderScheduling"`

### Task B5: `TaskStore.refreshBadge()` (badge via the seam)

**Files:**
- Modify: `GSDKit/Sources/GSDStore/TaskStore.swift`
- Test: extend `GSDKit/Tests/GSDStoreTests/TaskStoreReminderHooksTests.swift`

A thin store method computing `ReminderMath.badgeCount` over the live snapshot (the GSDModel exception, convention 5) and forwarding `setBadge`. The App calls it after mutations + the background task calls it. Lands here (Group B) so Group E's background task can call it.

- [ ] **Step 1: Add the failing test** to `TaskStoreReminderHooksTests`:
```swift
    @Test func refreshBadgeForwardsComputedCount() async throws {
        let rec = RecordingReminderScheduler()
        let store = try makeStore(rec)
        store.start()
        // Two due-today/overdue tasks + one future → badge 2.
        try await store.create(task("a", due: now.addingTimeInterval(-3600)))   // overdue
        try await store.create(task("b", due: now))                              // due today
        try await store.create(task("c", due: now.addingTimeInterval(7 * 86_400))) // future
        var waited = 0
        while store.tasks.count != 3 && waited < 200 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
        await store.refreshBadge()
        #expect(rec.calls.contains(.badge(2)))
    }
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter TaskStoreReminderHooksTests` → FAIL (`refreshBadge` not found).

- [ ] **Step 3: Add to `TaskStore`** in the `// MARK: Notification settings` block (after `notificationSettings`):
```swift
    /// Recompute the app-icon badge over the live snapshot and forward it (product spec §9.4).
    /// Uses the pure `ReminderMath.badgeCount` (the only scheduling math the store touches —
    /// it returns an `Int`, so `GSDStore` stays free of `UserNotifications`).
    public func refreshBadge() async {
        let count = ReminderMath.badgeCount(tasks: tasks, now: clock(), calendar: calendar)
        await reminders.setBadge(count)
    }
```

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter TaskStoreReminderHooksTests` → PASS (7 tests). Full `cd GSDKit && swift test` → green.
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDStore/TaskStore.swift GSDKit/Tests/GSDStoreTests/TaskStoreReminderHooksTests.swift && git commit -m "feat: add TaskStore.refreshBadge() forwarding ReminderMath.badgeCount"`

> **Milestone after Group B:** `NotificationSettings` persists; the store forwards every §9.1 event + the badge through the injected seam; the recording-fake suite is green; the full `swift test` shows no regression (Noop default keeps every existing call site intact). The store still imports NO `UserNotifications`.

---
## Group C — Live scheduler + permission + project.yml capability + wiring (App, `xcodebuild`)

> Build-verified UI-less App code. `LiveReminderScheduler` implements `ReminderScheduling` over `UNUserNotificationCenter`, owning the scheduling math (`ReminderMath` + quiet hours, convention 4); `project.yml` gains the background-modes + permitted-identifiers keys; `GSDApp` injects the live scheduler into the store. Maps **A37** + **A38**. Lands AFTER Groups A/B (it consumes `ReminderMath` + `NotificationSettings` + the protocol) and BEFORE D/E (which exercise the wired scheduler).
>
> **Build command** (run after each task that says to build; run `xcodegen generate` first whenever a NEW file was added or `project.yml` changed so the regenerated `GSD.xcodeproj` includes it):
> ```
> xcodegen generate
> xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17' build -quiet ; echo "exit $?"
> xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build -quiet ; echo "exit $?"
> ```
>
> **RUNTIME-ONLY (build-verified + manual pass, NOT unit-testable):** the actual permission prompt, a reminder firing, quiet-hours suppression at delivery, the badge appearing. The build only confirms the `UNUserNotificationCenter`/permission code COMPILES on the toolchain.

### Task C1: `project.yml` — background modes + permitted task identifiers

**Files:** Modify `project.yml`

Notifications via `UNUserNotificationCenter` need **no entitlement** (the existing `GSD.entitlements` App-Group file is untouched). What's needed is the Info.plist `UIBackgroundModes` (`fetch` + `processing`) + `BGTaskSchedulerPermittedIdentifiers` (an array — the Group-E background task). `BGTaskSchedulerPermittedIdentifiers` cannot be expressed as an `INFOPLIST_KEY_*` build setting (those are scalar/space-separated only), so use an explicit xcodegen `info:` plist. **When you supply an explicit `info:` plist, turn `GENERATE_INFOPLIST_FILE` OFF** — Xcode 26 emits a "Multiple commands produce Info.plist" / duplicate-Info.plist error if both an explicit `INFOPLIST_FILE` and `GENERATE_INFOPLIST_FILE: YES` are set. The explicit plist must therefore also carry the keys Xcode would have generated (`CFBundle*` come from `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`/the target; supply `UILaunchScreen` so there's a launch screen).

- [ ] **Step 1: Edit `project.yml`.** Under `targets.GSD.settings.base`, set `GENERATE_INFOPLIST_FILE: "NO"`. Add an `info:` block under `targets.GSD` (alongside `sources:`/`dependencies:`/`settings:`) — xcodegen writes `App/Info.plist` from `properties` and wires `INFOPLIST_FILE` to it:
```yaml
    info:
      path: App/Info.plist
      properties:
        UILaunchScreen: {}
        UIBackgroundModes:
          - fetch
          - processing
        BGTaskSchedulerPermittedIdentifiers:
          - dev.vinny.gsd.refresh
```
and change the `settings.base` line:
```yaml
        GENERATE_INFOPLIST_FILE: "NO"
```

> **Build-time note (confirm at `xcodegen generate` + build):** the explicit `info:` plist (`GENERATE_INFOPLIST_FILE: NO`) is the primary form. If a build error reports a *missing* generated key (e.g. `CFBundleShortVersionString` not found, breaking the `appVersion` About row), add it to `properties` as `CFBundleShortVersionString: "$(MARKETING_VERSION)"` / `CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"` (xcodegen expands build-setting refs). Alternatively, if keeping `GENERATE_INFOPLIST_FILE: YES` proves cleaner on this toolchain, drop the `info:` block and add only `BGTaskSchedulerPermittedIdentifiers` via a minimal supplementary `INFOPLIST_FILE` merged with the generated one — but the OFF-plus-explicit-plist form above is the known-good combination. Pick the xcodegen/Xcode-accepted form and note it. **Do NOT add a `DEVELOPMENT_TEAM` line** (the commented placeholder stays as-is).

- [ ] **Step 2: Regenerate + build:**
```
xcodegen generate
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17' build -quiet ; echo "exit $?"
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build -quiet ; echo "exit $?"
```
Both → exit 0. After install, verify the generated `Info.plist` carries both keys: `plutil -p $(xcodebuild ... -showBuildSettings | ...)` is overkill — simplest is to grep the built app's `Info.plist` from DerivedData, or `xcodebuild ... -showBuildSettings | grep -i background`. Confirm `BGTaskSchedulerPermittedIdentifiers` contains `dev.vinny.gsd.refresh`.

- [ ] **Step 3: Commit:** `git add project.yml GSD.xcodeproj App/Info.plist 2>/dev/null; git commit -m "build: add background modes + BGTaskScheduler permitted identifier"` (omit `App/Info.plist` from the `add` if the chosen form didn't create one).

### Task C2: `LiveReminderScheduler` (UNUserNotificationCenter, owns the scheduling math)

**Files:** Create `App/Notifications/LiveReminderScheduler.swift`

Implements `ReminderScheduling` over `UNUserNotificationCenter`. Reads `NotificationSettings` from App-Group defaults itself (convention 4) via a closure injected at construction (so it doesn't import `GSDStore` — `GSDApp` passes `{ store.notificationSettings }`). Uses `ReminderMath` for the fire time + quiet hours; stable id `"task-<id>"`; `UNCalendarNotificationTrigger` (date components, non-repeating). When `fireDate` is nil it removes the pending request for that id (no stale notification).

- [ ] **Step 1: Write `LiveReminderScheduler.swift`:**
```swift
import Foundation
import UserNotifications
import GSDModel
import GSDStore

/// The live `ReminderScheduling` implementation (product spec §9). Lives in the App target —
/// the only layer that imports `UserNotifications`. Owns the scheduling math (`ReminderMath` +
/// quiet hours), reads `NotificationSettings` via an injected closure (so it needn't reach into
/// the store's internals), and uses the stable id `task-<id>` so a reschedule REPLACES rather
/// than stacks. `@unchecked Sendable`: `UNUserNotificationCenter.current()` is a thread-safe
/// singleton and the injected closure is `@Sendable`; the type holds no mutable state.
final class LiveReminderScheduler: ReminderScheduling, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()
    private let settingsProvider: @Sendable () -> NotificationSettings
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    init(settingsProvider: @escaping @Sendable () -> NotificationSettings,
         calendar: Calendar = .current,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.settingsProvider = settingsProvider
        self.calendar = calendar
        self.now = now
    }

    func schedule(_ task: Task) async {
        let id = identifier(for: task.id)
        let settings = settingsProvider()
        // A snoozed task fires at snoozedUntil (if still future); otherwise normal fireDate.
        let baseFire: Date?
        if let snoozed = task.snoozedUntil, snoozed > now(), !task.completed, settings.enabled, task.notificationEnabled {
            baseFire = snoozed
        } else {
            let inputs = ReminderMath.Inputs(masterEnabled: settings.enabled, defaultReminder: settings.defaultReminder)
            baseFire = ReminderMath.fireDate(for: task, inputs: inputs, now: now())
        }
        guard let fire = baseFire else {
            // Nothing to fire → ensure no stale pending request lingers.
            center.removePendingNotificationRequests(withIdentifiers: [id])
            return
        }
        let deferred = ReminderMath.applyQuietHours(fire, quietStart: settings.quietHoursStart,
                                                    quietEnd: settings.quietHoursEnd, calendar: calendar)

        let content = UNMutableNotificationContent()
        content.title = task.title
        if !task.description.isEmpty { content.body = task.description }
        content.sound = settings.soundEnabled ? .default : nil
        content.userInfo = ["taskID": task.id]

        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: deferred)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        // Replace any existing pending request for this id, then add.
        center.removePendingNotificationRequests(withIdentifiers: [id])
        do { try await center.add(request) } catch { /* delivery is best-effort; ignore add failure */ }
    }

    func cancel(taskID: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [identifier(for: taskID)])
    }

    func cancelAll() async {
        center.removeAllPendingNotificationRequests()
    }

    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let current = await center.notificationSettings()
        switch current.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            return granted
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    func setBadge(_ count: Int) async {
        try? await center.setBadgeCount(count)
    }

    private func identifier(for taskID: String) -> String { "task-\(taskID)" }
}
```

- [ ] **Step 2: Regenerate (new file) + build** both simulators → exit 0. The build confirms `UNUserNotificationCenter`/`UNCalendarNotificationTrigger`/`UNMutableNotificationContent`/`setBadgeCount(_:)`/`requestAuthorization`/`notificationSettings()` compile on the toolchain. If `setBadgeCount(_:)` async API differs (e.g. needs a completion-handler form on this SDK), adjust to the compiler-accepted form and note it. (`@unchecked Sendable` is required because `UNUserNotificationCenter` is not `Sendable`.)
- [ ] **Step 3: Commit:** `git add App/Notifications/LiveReminderScheduler.swift GSD.xcodeproj && git commit -m "feat: add LiveReminderScheduler over UNUserNotificationCenter (ReminderMath-driven)"`

### Task C3: Wire `LiveReminderScheduler` into the store in `GSDApp`

**Files:** Modify `App/GSDApp.swift`

Inject the live scheduler when constructing the store. The scheduler reads settings via `{ store.notificationSettings }` — but the store is being constructed, so use a two-step: build the store with the scheduler, where the scheduler captures the settings via the App-Group defaults directly (not the store), to avoid the construction cycle.

- [ ] **Step 1: Edit `App/GSDApp.swift`.** Replace the `init()` so the live scheduler reads settings from the App-Group defaults (no store cycle), and inject it:
```swift
    init() {
        // The local store is the app's source of truth; failure to open it is unrecoverable.
        let database = try! AppDatabase.live()
        // The live scheduler reads NotificationSettings straight from App-Group defaults
        // (the same suite the store persists to) — avoids a store-construction cycle.
        let scheduler = LiveReminderScheduler(settingsProvider: {
            TaskStore.readNotificationSettings(from: .shared)
        })
        _store = State(initialValue: TaskStore(
            repository: GRDBTaskRepository(database),
            smartViewRepository: GRDBSmartViewRepository(database),
            archiveRepository: GRDBArchiveRepository(database),
            reminders: scheduler
        ))
    }
```

- [ ] **Step 2: Add the static reader** to `TaskStore` (so the scheduler reads the same defaults shape the instance getter uses, without an instance). In `GSDKit/Sources/GSDStore/TaskStore.swift`, in the `// MARK: Notification settings` block, refactor the instance getter to delegate to a static helper:
```swift
    /// Read `NotificationSettings` from a `UserDefaults` suite without a store instance — used
    /// by the App's live scheduler (which captures the App-Group suite directly to avoid a
    /// store-construction cycle). The instance getter delegates here so the shape can't drift.
    public static func readNotificationSettings(from defaults: UserDefaults) -> NotificationSettings {
        NotificationSettings(
            enabled: defaults.object(forKey: AppGroupDefaults.Key.notificationsEnabled) as? Bool ?? true,
            defaultReminder: defaults.object(forKey: AppGroupDefaults.Key.notificationDefaultReminder) as? Int ?? 15,
            soundEnabled: defaults.object(forKey: AppGroupDefaults.Key.notificationSoundEnabled) as? Bool ?? true,
            quietHoursStart: defaults.string(forKey: AppGroupDefaults.Key.notificationQuietHoursStart),
            quietHoursEnd: defaults.string(forKey: AppGroupDefaults.Key.notificationQuietHoursEnd),
            permissionAsked: defaults.bool(forKey: AppGroupDefaults.Key.notificationPermissionAsked)
        )
    }
```
and change the instance getter body to:
```swift
        get { TaskStore.readNotificationSettings(from: defaults) }
```

- [ ] **Step 3: Add `requestNotificationAuthorization()` to `TaskStore`** (the contextual-permission entry point — §9.2). It routes through the injected scheduler (so `GSDStore` stays free of `UserNotifications`) and stamps `permissionAsked`. Lands here (Group C) because BOTH the editor (D1, "sets a due date with a reminder") and Settings (E1, "Enable Notifications" button) call it. In the `// MARK: Notification settings` block:
```swift
    /// Request OS notification authorization (contextual — product spec §9.2) and stamp
    /// `permissionAsked`. Routes through the injected scheduler so `GSDStore` stays free of
    /// `UserNotifications`. Returns whether reminders are authorized after the request. The
    /// scheduler's own `requestAuthorizationIfNeeded` no-ops when already determined, so calling
    /// this repeatedly (e.g. on every editor enable) only prompts once.
    @discardableResult
    public func requestNotificationAuthorization() async -> Bool {
        let granted = await reminders.requestAuthorizationIfNeeded()
        var settings = notificationSettings
        settings.permissionAsked = true
        notificationSettings = settings
        return granted
    }
```

- [ ] **Step 4: Run** `cd GSDKit && swift test` → still green (the static helper + `requestNotificationAuthorization` are additive; the instance getter now delegates but returns the same values — `NotificationSettingsStoreTests` still passes; the Noop default returns `false`, no existing test asserts on it).
- [ ] **Step 5: Regenerate (no new file, but `GSDApp`/`TaskStore` edits) + build** both simulators → exit 0. (No new file → `xcodegen generate` not strictly required, but run it for consistency since the GSDKit source changed; the SPM package recompiles either way.)
- [ ] **Step 6: Commit:** `git add App/GSDApp.swift GSDKit/Sources/GSDStore/TaskStore.swift GSD.xcodeproj && git commit -m "feat: inject LiveReminderScheduler + add contextual requestNotificationAuthorization"`

> **Milestone after Group C:** the live scheduler compiles + is wired; `project.yml` carries the background-modes + permitted-identifier keys; both simulators build. The store schedules through the live `UNUserNotificationCenter` at runtime (delivery is a manual-pass item). `swift test` still green.

---
## Group D — Reminder UI in the editor (App, `xcodebuild`)

> Build-verified UI. A due-date-gated Reminders section in `TaskEditorView`: a `notificationEnabled` toggle + a `notifyBefore` picker. The save path threads `notificationEnabled`/`notifyBefore` into the task (replacing the `// TODO: Phase-4` note). Maps **A39**. Lands AFTER Group C (the wired scheduler picks up the saved fields at runtime).
>
> **Build command:** as Group C (regenerate only if a new file is added; here `TaskEditorView` is an existing file → `xcodegen generate` optional but run for consistency).
>
> **RUNTIME-ONLY (manual pass):** that a reminder actually fires from the saved fields. The build confirms the section compiles + the save path threads the fields.

### Task D1: Reminders section in `TaskEditorView` (enabled + notifyBefore, due-date-gated)

**Files:** Modify `App/Editor/TaskEditorView.swift`

The section is shown only when `dueDate != nil` (a reminder is meaningless without a due date — convention/scope). A single `notifyBefore` picker drives both fields: a `None` option maps to `notificationEnabled = false`; any offset maps to `notificationEnabled = true` + that `notifyBefore`. Default offset on first enable = the store's `defaultReminder`.

- [ ] **Step 1: Edit `App/Editor/TaskEditorView.swift`.** Add the backing `@State` (after `@State private var snoozedUntil: Date?`):
```swift
    @State private var notificationEnabled: Bool
    @State private var notifyBefore: Int?
```
Initialize them in BOTH `init` branches. In `.new`:
```swift
            _notificationEnabled = State(initialValue: false)
            _notifyBefore = State(initialValue: nil)
```
In `.edit(let t)`:
```swift
            _notificationEnabled = State(initialValue: t.notificationEnabled && t.dueDate != nil)
            _notifyBefore = State(initialValue: t.notifyBefore)
```

> **Note on the `.edit` initial value:** `Task.notificationEnabled` defaults to `true` for every task (Phase 0 carry-over), so showing the toggle "on" for every dated task would be wrong. The editor treats the reminder as "on" only when the task is both `notificationEnabled` AND dated — matching what the scheduler would actually fire. Saving normalizes this back (Step 3).

Add the section to the `Form`. In the second `Group { ... }`, after `dependenciesSection` (and before the `saveError` section), insert:
```swift
                    reminderSection
```

Add the `reminderSection` view (after `snoozeSection`):
```swift
    /// Reminder controls (product spec §9) — shown only when a due date is set. The picker's
    /// `None` selection disables the reminder; any offset enables it with that `notifyBefore`.
    @ViewBuilder private var reminderSection: some View {
        if dueDate != nil {
            Section(String(localized: "Reminder")) {
                Picker(String(localized: "Remind me"), selection: reminderSelection) {
                    Text(String(localized: "None")).tag(ReminderOption.none)
                    Text(String(localized: "At time of event")).tag(ReminderOption.offset(0))
                    Text(String(localized: "5 minutes before")).tag(ReminderOption.offset(5))
                    Text(String(localized: "15 minutes before")).tag(ReminderOption.offset(15))
                    Text(String(localized: "30 minutes before")).tag(ReminderOption.offset(30))
                    Text(String(localized: "1 hour before")).tag(ReminderOption.offset(60))
                    Text(String(localized: "2 hours before")).tag(ReminderOption.offset(120))
                    Text(String(localized: "1 day before")).tag(ReminderOption.offset(1440))
                }
            }
        }
    }

    /// The reminder picker's options. `.none` = no reminder; `.offset(m)` = m minutes before due.
    private enum ReminderOption: Hashable { case none, offset(Int) }

    /// Binds the picker to `notificationEnabled` + `notifyBefore`. Selecting `.none` disables;
    /// selecting an offset enables with that value. When enabled but `notifyBefore` is nil
    /// (legacy/new), the displayed selection falls back to the store's `defaultReminder` — which
    /// is always one of the offered offsets (the picker's offsets `{0,5,15,30,60,120,1440}` are a
    /// superset of `NotificationSettings.allowedReminders` `{15,30,60,120,1440}`, so the Picker
    /// never renders blank). Enabling a reminder requests OS authorization contextually (§9.2:
    /// "when the user … sets a due date with a reminder") — a no-op if already asked/determined.
    private var reminderSelection: Binding<ReminderOption> {
        Binding(
            get: {
                guard notificationEnabled else { return .none }
                return .offset(notifyBefore ?? store.notificationSettings.defaultReminder)
            },
            set: { option in
                switch option {
                case .none:
                    notificationEnabled = false
                    notifyBefore = nil
                case .offset(let minutes):
                    notificationEnabled = true
                    notifyBefore = minutes
                    _Concurrency.Task { await store.requestNotificationAuthorization() }
                }
            }
        )
    }
```

- [ ] **Step 2: Edit the `save()` path.** In `save()`, replace the `// TODO: Phase-4 …` line + `task.dueDate = dueDate` (the edit branch) so reminder fields thread through, and reset reminder state when the reminder is off:
```swift
            task.dueDate = dueDate
            // Phase-4: the editor's reminder controls drive these (§9). Clearing the due date
            // also clears the reminder (a reminder is meaningless without a due date).
            if dueDate == nil {
                task.notificationEnabled = false
                task.notifyBefore = nil
            } else {
                task.notificationEnabled = notificationEnabled
                task.notifyBefore = notificationEnabled ? notifyBefore : nil
            }
```
In the `.new` branch's `Task(...)` initializer, add the reminder arguments **between `dependencies: dependencies,` and `snoozedUntil: snoozedUntil,`** (Swift requires call arguments in declaration order — in `Task.init` `notifyBefore`/`notificationEnabled` come after `parentTaskId` and before `snoozedUntil`, so this is the only valid slot; the existing call skips straight from `dependencies` to `snoozedUntil`):
```swift
                        dependencies: dependencies,
                        notifyBefore: (dueDate != nil && notificationEnabled) ? notifyBefore : nil,
                        notificationEnabled: dueDate != nil && notificationEnabled,
                        snoozedUntil: snoozedUntil,
```
(Shown with the two surrounding existing lines for placement; only the two `notif*` lines are new.)

> **Note:** `store.save`/`store.create` (Group B) forward the reschedule to the live scheduler, which recomputes the fire time from these saved fields. The editor does NOT call the scheduler directly — it just persists; the store seam handles scheduling.

- [ ] **Step 3: Build** both simulators → exit 0. Launch iPhone: open the editor for a task with no due date → no Reminder section. Set a due date → the Reminder section appears with "None" selected; pick "1 hour before" → Save. Re-open → the picker shows "1 hour before". Clear the due date → Reminder section disappears; Save → re-open shows it disabled. iPad: same in the regular editor sheet. Screenshot the editor with the Reminder section (due-date set).
- [ ] **Step 4: Commit:** `git add App/Editor/TaskEditorView.swift GSD.xcodeproj && git commit -m "feat: add due-date-gated Reminder section to the task editor"`

> **Milestone after Group D:** the editor surfaces the reminder controls (due-date-gated); saving threads `notificationEnabled`/`notifyBefore` through the store, which reschedules via the live scheduler. Both simulators build. Actual firing is a manual-pass item.

---
## Group E — Settings Notifications section + badges + background refresh (App, `xcodebuild` + manual)

> Build-verified UI + App wiring. The Settings → Notifications section (the 3c-deferred one); badge refresh wired into `GSDApp`'s launch + active-scene hooks; the `BGAppRefreshTask` registration + handler (sweep + badge). Maps **A40** (Settings section) + **A41** (badge + background). Lands LAST (it consumes the store's `notificationSettings`/`refreshBadge` + the live scheduler's `requestAuthorizationIfNeeded`/`setBadge`).
>
> **RUNTIME-ONLY (manual pass):** the permission prompt appearing, the badge appearing on the home-screen icon, the `BGAppRefreshTask` actually firing in the background (only testable via the debugger's `_simulateLaunchForTaskWithIdentifier:` LLDB command or a real device). The build confirms the section + registration code compile.

### Task E1: Settings → Notifications section

**Files:** Modify `App/Settings/SettingsView.swift`

Add a Notifications section between Archive and Data & Storage: master enable, default-reminder picker, sound, quiet-hours start/end (each a toggle + a `.hourAndMinute` `DatePicker`), and a permission-status row with a contextual action. The section mirrors the local-mirror-flushes-back pattern the Archive section uses.

- [ ] **Step 1: Edit `App/Settings/SettingsView.swift`.** Add the imports/state. After `@State private var archiveStatus: String?`:
```swift
    @State private var notificationSettings: NotificationSettings = .init()
    /// OS authorization status, refreshed on appear (nil = not yet read).
    @State private var authStatusText: String?
    @State private var authIsDenied = false
```
Add `import UserNotifications` at the top (Settings is App-layer, allowed). In `body`, add the section call between `archiveSection` and `DataStorageView()`:
```swift
                notificationSection
```
Update the `.onAppear` to also load notification settings + the OS status:
```swift
            .onAppear {
                archiveSettings = store.archiveSettings
                notificationSettings = store.notificationSettings
                refreshAuthStatus()
            }
```

Add the section + helpers (after `archiveSection`):
```swift
    private var notificationSection: some View {
        Section(String(localized: "Notifications")) {
            Toggle(String(localized: "Enable Reminders"), isOn: Binding(
                get: { notificationSettings.enabled },
                set: { notificationSettings.enabled = $0; flushNotificationSettings() }
            ))
            if notificationSettings.enabled {
                Picker(String(localized: "Default Reminder"), selection: Binding(
                    get: { notificationSettings.defaultReminder },
                    set: { notificationSettings.defaultReminder = $0; flushNotificationSettings() }
                )) {
                    ForEach(NotificationSettings.allowedReminders, id: \.self) { minutes in
                        Text(reminderLabel(minutes)).tag(minutes)
                    }
                }
                Toggle(String(localized: "Sound"), isOn: Binding(
                    get: { notificationSettings.soundEnabled },
                    set: { notificationSettings.soundEnabled = $0; flushNotificationSettings() }
                ))
                quietHoursControls
                authStatusRow
            }
        }
    }

    /// Quiet-hours start/end, each a toggle (nil ↔ a default time) + a `.hourAndMinute` picker.
    @ViewBuilder private var quietHoursControls: some View {
        Toggle(String(localized: "Quiet Hours"), isOn: Binding(
            get: { notificationSettings.quietHoursStart != nil && notificationSettings.quietHoursEnd != nil },
            set: { on in
                if on {
                    notificationSettings.quietHoursStart = notificationSettings.quietHoursStart ?? "22:00"
                    notificationSettings.quietHoursEnd = notificationSettings.quietHoursEnd ?? "07:00"
                } else {
                    notificationSettings.quietHoursStart = nil
                    notificationSettings.quietHoursEnd = nil
                }
                flushNotificationSettings()
            }
        ))
        if notificationSettings.quietHoursStart != nil {
            DatePicker(String(localized: "From"), selection: quietBinding(\.quietHoursStart, default: "22:00"),
                       displayedComponents: .hourAndMinute)
            DatePicker(String(localized: "To"), selection: quietBinding(\.quietHoursEnd, default: "07:00"),
                       displayedComponents: .hourAndMinute)
        }
    }

    /// The OS permission status + a contextual action (request when not-asked; open Settings when denied).
    @ViewBuilder private var authStatusRow: some View {
        if let authStatusText {
            LabeledContent(String(localized: "System Permission"), value: authStatusText)
        }
        if authIsDenied {
            Button(String(localized: "Open System Settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } else if !store.notificationSettings.permissionAsked {
            Button(String(localized: "Enable Notifications")) {
                _Concurrency.Task { @MainActor in
                    _ = await store.requestNotificationAuthorization()
                    refreshAuthStatus()
                }
            }
        }
    }

    /// Bind a `"HH:mm"` setting field to a `DatePicker` `Date` (today at that time, injected-tz-free
    /// since the picker shows local). Reading parses HH:mm → today's date; writing formats back.
    private func quietBinding(_ keyPath: WritableKeyPath<NotificationSettings, String?>,
                              default fallback: String) -> Binding<Date> {
        Binding(
            get: { Self.dateFrom(notificationSettings[keyPath: keyPath] ?? fallback) },
            set: { notificationSettings[keyPath: keyPath] = Self.hhmm(from: $0); flushNotificationSettings() }
        )
    }

    private func flushNotificationSettings() { store.notificationSettings = notificationSettings }

    private func refreshAuthStatus() {
        _Concurrency.Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                authStatusText = String(localized: "Allowed"); authIsDenied = false
            case .denied:
                authStatusText = String(localized: "Denied"); authIsDenied = true
            case .notDetermined:
                authStatusText = String(localized: "Not requested"); authIsDenied = false
            @unknown default:
                authStatusText = nil; authIsDenied = false
            }
        }
    }

    private func reminderLabel(_ minutes: Int) -> String {
        switch minutes {
        case 15:   String(localized: "15 minutes before")
        case 30:   String(localized: "30 minutes before")
        case 60:   String(localized: "1 hour before")
        case 120:  String(localized: "2 hours before")
        case 1440: String(localized: "1 day before")
        default:   String(localized: "\(minutes) minutes before")
        }
    }

    /// Parse `"HH:mm"` → a Date at that time today (local). Malformed → start of today.
    private static func dateFrom(_ hhmm: String) -> Date {
        let parts = hhmm.split(separator: ":")
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        comps.hour = parts.count == 2 ? Int(parts[0]) : 0
        comps.minute = parts.count == 2 ? Int(parts[1]) : 0
        return Calendar.current.date(from: comps) ?? .now
    }
    /// Format a Date → `"HH:mm"` (local, zero-padded).
    private static func hhmm(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
```

> **Note:** `store.requestNotificationAuthorization()` (the "Enable Notifications" button + `refreshAuthStatus`) was added to `TaskStore` in **C3 Step 3** — Settings consumes it; no new store method here.

- [ ] **Step 2: Build** both simulators → exit 0. If `DatePicker(_:selection:displayedComponents: .hourAndMinute)` or `UIApplication.openSettingsURLString` need a different form on the toolchain, adjust + note. Launch iPhone: Settings shows a Notifications section between Archive and Data & Storage — toggle Enable Reminders → the default/sound/quiet-hours/permission rows appear; pick a default; toggle Quiet Hours → two time pickers (22:00 / 07:00); the permission row shows "Not requested" + an "Enable Notifications" button (tapping it triggers the OS prompt — manual pass). iPad: same. Screenshot the Notifications section expanded.
- [ ] **Step 3: Commit:** `git add App/Settings/SettingsView.swift GSD.xcodeproj && git commit -m "feat: add Settings Notifications section (enable/default/sound/quiet-hours/permission)"`

### Task E2: Badge refresh on launch + scene-active

**Files:** Modify `App/GSDApp.swift`

Refresh the badge when the app launches + becomes active (so it reflects overdue/due-today after the user acts elsewhere). Uses the store's `refreshBadge()` (Group B) → the live `setBadge` (Group C).

- [ ] **Step 1: Edit `App/GSDApp.swift`.** Add `@Environment(\.scenePhase)` and extend the launch `.task` + add an `onChange(of: scenePhase)`:
```swift
    @Environment(\.scenePhase) private var scenePhase
```
Update the `.task` modifier on `ContentView()`:
```swift
                .task {
                    store.start()
                    try? await store.runAutoArchiveSweep()
                    await store.refreshBadge()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        _Concurrency.Task { await store.refreshBadge() }
                    }
                }
```

- [ ] **Step 2: Build** both simulators → exit 0. (Badge appearing on the home-screen icon is a manual-pass item — the simulator shows it after granting permission + with an overdue/due-today task.)
- [ ] **Step 3: Commit:** `git add App/GSDApp.swift GSD.xcodeproj && git commit -m "feat: refresh app-icon badge on launch and scene-active"`

### Task E3: `BGAppRefreshTask` registration + handler (sweep + badge)

**Files:**
- Create: `App/Background/BackgroundRefresh.swift`
- Modify: `App/GSDApp.swift`

Register the `BGAppRefreshTask` (id `dev.vinny.gsd.refresh` — matches `project.yml` C1) at launch, schedule it, and on fire run `runAutoArchiveSweep()` + `refreshBadge()`, then reschedule. The opportunistic sync is a Phase-5 TODO.

- [ ] **Step 1: Write `App/Background/BackgroundRefresh.swift`:**
```swift
import Foundation
import BackgroundTasks
import GSDStore

/// Background app-refresh (product spec §9.4): runs the auto-archive sweep + badge refresh so
/// data is fresh on next open. NOT relied on for timely reminders (those are pre-scheduled, §9.1).
/// The identifier must match `project.yml`'s `BGTaskSchedulerPermittedIdentifiers`.
enum BackgroundRefresh {
    static let taskIdentifier = "dev.vinny.gsd.refresh"

    /// Register the handler — call ONCE, early in app launch (before the scene appears).
    @MainActor
    static func register(store: TaskStore) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            handle(refreshTask, store: store)
        }
    }

    /// Submit the next refresh request (earliest ~15 minutes out — the OS decides actual timing).
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    private static func handle(_ task: BGAppRefreshTask, store: TaskStore) {
        schedule()   // always queue the next one
        let work = _Concurrency.Task { @MainActor in
            try? await store.runAutoArchiveSweep()
            await store.refreshBadge()
            // NOTE (Phase 5): perform an opportunistic sync here so data is fresh on next open.
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel(); task.setTaskCompleted(success: false) }
    }
}
```

- [ ] **Step 2: Edit `App/GSDApp.swift`** to register at launch + schedule when backgrounded. Add `import` is implicit via the type; register in `init()` is too early (store not in `@State` yet) — instead register in the launch `.task` (before scheduling), and schedule on scene-background. Update the `.task` + `.onChange`:
```swift
                .task {
                    BackgroundRefresh.register(store: store)
                    store.start()
                    try? await store.runAutoArchiveSweep()
                    await store.refreshBadge()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        _Concurrency.Task { await store.refreshBadge() }
                    case .background:
                        BackgroundRefresh.schedule()
                    default:
                        break
                    }
                }
```

> **Build-time note:** `BGTaskScheduler.register(forTaskWithIdentifier:using:launchHandler:)` must run before the app finishes launching. Calling it at the top of the root `.task` (which runs at first appearance, within the launch window) is the SwiftUI-lifecycle-friendly placement; if the toolchain/OS warns it's too late (a "must be registered before application finishes launching" runtime exception), move `register` into an `init()`-time path by constructing the scheduler registration against the already-built `_store.wrappedValue`. Flag at build/runtime and pick the working placement.

- [ ] **Step 3: Regenerate (new file) + build** both simulators → exit 0. Confirms `BGTaskScheduler`/`BGAppRefreshTask`/`BGAppRefreshTaskRequest` compile + the identifier matches `project.yml`. **Background firing is a manual-pass item** (force it in the debugger with `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"dev.vinny.gsd.refresh"]` while paused, or verify on a real device): the sweep archives eligible completed tasks + the badge updates.
- [ ] **Step 4: Commit:** `git add App/Background/BackgroundRefresh.swift App/GSDApp.swift GSD.xcodeproj && git commit -m "feat: register BGAppRefreshTask running sweep + badge refresh"`

> **Milestone after Group E:** Settings has a full Notifications section; the badge refreshes on launch/active; the background task is registered + schedules itself and runs the sweep + badge on fire. Both simulators build. The runtime items (permission prompt, badge on icon, background fire, delivery, quiet-hours suppression) are covered by the manual pass.

---
## Phase 4 — Definition of Done

Mapped to the spec's acceptance criteria (A35–A41). **swift test** items are fully automated; **build** items are `xcodebuild` exit 0 on both simulators; **manual pass** items are runtime-only (delivery/permission/badge-on-icon/background-fire) and CANNOT be unit- or screenshot-verified.

- [ ] **A35 — ReminderMath.** Fire time = `dueDate − offset` (notifyBefore ?? defaultReminder; 0 = at-time); skips no-due/disabled-task/master-off/completed/past (inclusive `fire >= now`); quiet-hours defers an in-window fire to the next `quietEnd` occurrence (half-open `[start,end)`, midnight-crossing); badge = active overdue + due-today (`< startOfTomorrow`). *Tests:* `ReminderMathTests` (13). *Probes:* firedate 11/11, quiethours 14/14, badge 8/8. (A1)
- [ ] **A36 — Store schedules at write time.** `create/save → schedule`; `complete → cancel`, re-activate → `schedule`; `delete → cancel`; `snooze → schedule` (at `snoozedUntil`); recurrence-spawn → `cancel` original + `schedule` the new instance — all via the injected `ReminderScheduling` seam; `move` (quadrant-only) does NOT fire. `TaskStore.init` gains a defaulted `reminders:`; existing call sites/tests use `NoopReminderScheduler` unchanged. *Tests:* `TaskStoreReminderHooksTests` (7, recording fake). (B2, B4, B5)
- [ ] **A37 — LiveReminderScheduler.** Implements the protocol over `UNUserNotificationCenter`; stable `task-<id>` ids (reschedule REPLACES via `removePendingNotificationRequests` before `add`); maps `soundEnabled` → `.default`/`nil`; reads `NotificationSettings` itself; uses `ReminderMath.fireDate` + `applyQuietHours`; nil fire → removes pending. *Build:* both destinations exit 0 (C2, C3). *Manual pass:* a reminder actually fires; quiet-hours suppression at delivery. (C2)
- [ ] **A38 — Permission contextual.** `requestNotificationAuthorization()` (store → seam, added C3) prompts only on a user action — BOTH §9.2 triggers: enabling a reminder in the editor ("sets a due date with a reminder", D1's `reminderSelection` setter) and the Settings "Enable Notifications" button (E1) — never at cold launch; stamps `permissionAsked` (idempotent prompt: the seam no-ops when already determined); Settings reflects the OS state (Allowed/Denied/Not requested) with an "Open System Settings" path when denied. *Build:* C3, D1, E1 exit 0. *Manual pass:* the prompt appears on first editor-enable AND on the Settings button; the status row reflects the granted/denied state. (C2, C3, D1, E1)
- [ ] **A39 — Reminder UI (editor).** A due-date-gated Reminders section in `TaskEditorView` (a `notifyBefore` picker driving `notificationEnabled` + `notifyBefore`; None disables); clearing the due date clears the reminder; save threads the fields → the store reschedules. *Build:* both destinations exit 0 (D1). (D1)
- [ ] **A40 — Settings Notifications section.** Master enable, default-reminder picker (15/30/60/120/1440), sound, quiet-hours start/end (`.hourAndMinute` pickers, toggleable→nil), permission status + action; persists via `store.notificationSettings` (App-Group). *Tests:* `NotificationSettingsStoreTests` (4, persistence/defaults/clamp). *Build:* E1 exit 0. (B1, B3, E1)
- [ ] **A41 — Badge + background refresh.** Badge = overdue + due-today via `ReminderMath.badgeCount` → `setBadge`, refreshed on launch + scene-active + background; `BGAppRefreshTask` (`dev.vinny.gsd.refresh`, registered + self-rescheduling) runs `runAutoArchiveSweep()` + `refreshBadge()` on fire; `project.yml` carries `UIBackgroundModes` + `BGTaskSchedulerPermittedIdentifiers`. *Tests:* `TaskStoreReminderHooksTests.refreshBadgeForwardsComputedCount`. *Build:* C1, E2, E3 exit 0. *Manual pass:* the badge appears on the icon; the background task fires (debugger/device) and runs the sweep + badge. (B5, C1, E2, E3)
- **Coverage:** `swift test` green for `ReminderMathTests` (13) + `NotificationSettingsStoreTests` (4) + `TaskStoreReminderHooksTests` (7); both simulators build; manual pass for delivery/permission-prompt/quiet-hours-at-delivery/badge-on-icon/background-fire.

---

## Self-review (spec coverage · placeholders · type consistency)

**Spec coverage (Groups A–E, A35–A41):** `ReminderMath` fireDate/quiet-hours/badge with all boundaries (A1, probe-verified) → **A35** ✔; `ReminderScheduling` seam + `NoopReminderScheduler` (B2) + `TaskStore` §9.1 forwarding (B4) + `refreshBadge` (B5) → **A36** ✔; `LiveReminderScheduler` over `UNUserNotificationCenter` (stable id, sound map, ReminderMath-driven, nil→remove-pending) (C2) + wiring (C3) → **A37** ✔; contextual `requestNotificationAuthorization` (C2 seam → C3 store method, fired from BOTH §9.2 triggers: the editor's reminder-enable D1 + the Settings button E1) + `permissionAsked` + OS-state row (E1) → **A38** ✔; editor due-date-gated Reminders section threading `notificationEnabled`/`notifyBefore` + the contextual permission prompt on enable (D1) → **A39** ✔; Settings Notifications section (enable/default/sound/quiet-hours/permission) (E1) + `NotificationSettings` value (B1) + App-Group persistence (B3) → **A40** ✔; badge via `ReminderMath.badgeCount` + launch/active/background refresh (B5, E2) + `BGAppRefreshTask` sweep+badge (E3) + `project.yml` capability (C1) → **A41** ✔. Deferred items honored: opportunistic sync = a `// NOTE (Phase 5)` comment (E3), no behavior; no remote/APNs push; no widgets/intents (Phase 6). Sequencing A → B (logic, swift test) → C → D → E (App, build) lands the package before the consuming App layers; C (live scheduler + capability) lands before D/E ✔.

**Placeholder scan:** every code step is complete + compilable — no `TBD`/`...`/"similar to"/"as before" stand-ins. The two intentional comments are a `// NOTE (Phase 5)` sync TODO (E3) and the existing-style build-time "confirm/adjust + note" guidance for the genuinely confirm-at-build APIs (`project.yml` explicit-`info:`-plist + `GENERATE_INFOPLIST_FILE: NO` form C1; `setBadgeCount` async form C2; `DatePicker .hourAndMinute`/`openSettingsURLString` E1; `BGTaskScheduler.register` placement E3) — these are explicit fallbacks, not placeholders, matching the 3c exemplar's `chartForegroundStyleScale`/`ShareLink` notes. The editor's `// TODO: Phase-4` note from 3c is explicitly REPLACED in D1 Step 2.

**Type consistency:** `ReminderMath.Inputs(masterEnabled:defaultReminder:)` + `.shouldSchedule(task:inputs:)` / `.fireDate(for:inputs:now:)` / `.applyQuietHours(_:quietStart:quietEnd:calendar:)` / `.badgeCount(tasks:now:calendar:)` used consistently (A1 → C2 `LiveReminderScheduler`, B5 `refreshBadge`). `NotificationSettings(enabled:defaultReminder:soundEnabled:quietHoursStart:quietHoursEnd:permissionAsked:)` + `.allowedReminders` (B1 → B3, C3 `readNotificationSettings`, E1 picker). `ReminderScheduling` (`schedule(_:)`/`cancel(taskID:)`/`cancelAll()`/`requestAuthorizationIfNeeded() -> Bool`/`setBadge(_:)`, all `async`) + `NoopReminderScheduler` (B2 → B4 store calls, C2 live impl, B4 recording fake). `TaskStore.init(... reminders: any ReminderScheduling = NoopReminderScheduler())` + `notificationSettings` get/set + `readNotificationSettings(from:)` static + `refreshBadge()` + `requestNotificationAuthorization()` — the last two added in B5/C3 respectively and consumed by D1 (`reminderSelection` setter) + E1 (button) + E2/E3 (badge), so every App consumer references a store method that already exists by sequence (B/C precede D/E). `AppGroupDefaults.Key.notification*` six keys (B3 → C3). App refs match real Phase-3 APIs: `TaskEditorView(request:)` `.new`/`.edit`, the `Form`/`Section` + `dueDateSection`/`snoozeSection`/`save()` structure, `@Environment(TaskStore.self)`, `store.notificationSettings` (D1, E1); `SettingsView` `Form` + `archiveSection` local-mirror-flush pattern + `.onAppear` (E1); `GSDApp` `@State store`/`@AppStorage(..., store: .shared)`/`.task`/`@Environment(\.scenePhase)`/`AppGroupDefaults.shared` via `.shared` (C3, E2, E3). `String(localized:)` on all UI copy + in `ReminderMath`/`NotificationSettings` (Foundation-provided, `TimeTracking.format` precedent). `_Concurrency.Task` in every app/store/test concurrency site (never bare `Task {}`) — `GSDModel.Task` is the domain type only. New `.swift` files (`ReminderMath`, `NotificationSettings`, `ReminderScheduling`, `LiveReminderScheduler`, `BackgroundRefresh`) + the `project.yml` change trigger `xcodegen generate` before `xcodebuild`. No `DEVELOPMENT_TEAM` line added.

**Convention compliance:** `GSDModel` additions (`ReminderMath`, `NotificationSettings`) link only Foundation — NO `UserNotifications` ✔. `GSDStore` additions (`ReminderScheduling`, store hooks) import GRDB/`GSDModel`/Observation, never SwiftUI, never `UserNotifications` (the seam is a protocol; `badgeCount` returns an `Int`) ✔. `UserNotifications`/`BackgroundTasks` imported ONLY in the App (`LiveReminderScheduler`, `SettingsView`, `BackgroundRefresh`, `GSDApp`) ✔. Time injected in `ReminderMath` (now/calendar) + the live scheduler's `now`/`calendar` ✔. Store stamps `updatedAt` on primary mutations (unchanged; reminder hooks are additive `await`s after the upsert) ✔. One commit per task (A1; B1–B5; C1–C3; D1; E1–E3 = 13 commits) ✔.
