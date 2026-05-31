# Phase 4 — Notifications (Design Spec)

> **Date:** 2026-05-31 · **Status:** spec drafted during the autonomous run; **NOT yet planned or implemented** (the run paused here after completing the full offline app, Phases 0–3). Basis for the implementation plan. The next session: write the plan (`docs/superpowers/plans/2026-05-30-phase-4-notifications.md`), then execute subagent-driven.

## 1. Purpose & scope
Local reminder notifications + their settings/UI, app-icon badges, and background refresh — a **behavioral redesign** of the web's polling model (§9): iOS can't poll in the background, so reminders are **scheduled locally at write time** with `UNUserNotificationCenter`. The reminder fields already exist on `Task`/`NotificationSettings` and have been carried unwired since Phase 0; Phase 4 turns them on.

**Out of scope (deferred):** remote/APNs push + cross-device backgrounded reminders (§9.4 — out of scope entirely; each device schedules its own from synced data); sync itself (Phase 5); widgets/App-Intents/Share-Extension (Phase 6, §10). The background-refresh task runs the auto-archive sweep + badge refresh now; the "opportunistic sync" part is a Phase-5 TODO.

## 2. Builds on (Phases 0–3, on `main` at `phase-3c-insights-data`)
- `GSDModel`: `Task` (has `dueDate`, `notifyBefore: Int?`, `notificationEnabled: Bool`, `notificationSent`, `lastNotificationAt`, `snoozedUntil`, `recurrence`, `completed`), `RecurrenceEngine.spawnNext`, `Quadrant`, injected-time conventions.
- `GSDStore`: `TaskStore` (mutations: `add`/`save`/`toggleComplete`/`delete`/`snooze`/`move`; `AppGroupDefaults`/`ArchiveSettings` pattern for App-Group singletons; injected `clock`/`calendar`), `runAutoArchiveSweep()`.
- App: `TaskEditorView` (has a Snooze section; the reminder controls were hidden — Phase 4 surfaces them), `SettingsView` (the **Notifications** section was deliberately deferred from 3c — add it here), `GSDApp` (`@AppStorage`, `.task` launch hooks; `eraseAllData` preserves theme/onboarding), `ContentView`.

## 3. Scope calls (proposed — confirm/adjust when planning)
- **Pure scheduling math in `GSDModel`** (`ReminderMath` or similar, fully unit-testable, injected `calendar`/`now`):
  - `fireDate(for task:, default offsetMinutes:Int, calendar:) -> Date?` = `dueDate − (notifyBefore ?? default)`; nil when the task shouldn't fire (no dueDate, `notificationEnabled == false`, completed, or fireDate already past — decide past-due handling: skip vs fire-immediately; **propose: skip if fireDate < now**).
  - `applyQuietHours(_ fire:, quietStart:"HH:mm", quietEnd:"HH:mm", calendar:) -> Date` — if `fire` falls in the quiet window, defer to the window's end (handle windows that cross midnight). PROBE this (window math + midnight-crossing).
  - `shouldSchedule(task:, settings:) -> Bool`; `badgeCount(tasks:, now:, calendar:) -> Int` (active overdue + due-today; confirm the rule).
- **`NotificationSettings` (§5.4)** as an App-Group `UserDefaults` singleton (mirror `ArchiveSettings`): `enabled`, `defaultReminder` (15/30/60/120/1440), `soundEnabled`, `quietHoursStart`/`End` (`"HH:mm"`?), `permissionAsked`.
- **`ReminderScheduling` protocol** (in `GSDStore`, so the store orchestrates at write time, but the framework dependency is injected — keeps `GSDStore` free of `UserNotifications` and keeps tests deterministic): `schedule(_ task:)`, `cancel(taskID:)`, `cancelAll()`, `requestAuthorizationIfNeeded() async`, `setBadge(_ count:)`. **Default no-op impl** so existing `TaskStore` call sites/tests compile unchanged; `TaskStore.init` gains a defaulted `reminders: ReminderScheduling = NoopReminderScheduler()`. The store calls it on the §9.1 events (create/edit → schedule; completion/delete/disable → cancel; snooze → reschedule at `snoozedUntil`; recurrence spawn → schedule the new instance). Tests inject a **recording fake** and assert the right schedule/cancel calls — this is the testable seam.
- **`LiveReminderScheduler`** (App layer, `import UserNotifications`): implements the protocol over `UNUserNotificationCenter` using the pure `ReminderMath`; stable id `"task-<id>"` (reschedule replaces); maps `soundEnabled`; contextual `requestAuthorization`. Wired into the store in `GSDApp`.
- **Reminder UI (editor):** a Reminders section in `TaskEditorView` — `notificationEnabled` toggle + `notifyBefore` picker (None/at-time/5m/15m/30m/1h/1d, defaulting to `defaultReminder`); only meaningful when a due date is set.
- **Settings → Notifications section** (the 3c-deferred one): master `enabled`, default-reminder picker, `soundEnabled`, quiet-hours start/end (`DatePicker .hourAndMinute`), OS permission status + a "request"/"open Settings" affordance, `permissionAsked` tracking.
- **Badges:** `setBadge(count)` via the scheduler on relevant changes + from background refresh.
- **Background refresh:** register a `BGAppRefreshTask` (needs the `BGTaskSchedulerPermittedIdentifiers` Info.plist key + the `processing`/`refresh` background mode → **project.yml change**) that runs `runAutoArchiveSweep()` + badge refresh. (Sync is Phase 5.)

## 4. Feature groups (→ plan groups)
- **A — Pure scheduling math (GSDModel, swift test):** `ReminderMath` (fireDate, quiet-hours defer incl. midnight-crossing, shouldSchedule, badgeCount). PROBE quiet-hours + fireDate boundaries.
- **B — Settings model + scheduler seam (GSDStore, swift test):** `NotificationSettings` (App-Group), `ReminderScheduling` protocol + `NoopReminderScheduler`, `TaskStore` reminder hooks on the §9.1 mutation events (inject a recording fake; assert schedule/cancel/reschedule on create/edit/complete/delete/snooze/spawn). `TaskStore.init` gains defaulted `reminders:`.
- **C — Live scheduler + permission (App, build):** `LiveReminderScheduler` over `UNUserNotificationCenter`; contextual permission request; wire into `GSDApp`; `project.yml` notification entitlement/background-mode + `xcodegen generate`.
- **D — Reminder UI (App, build):** `TaskEditorView` Reminders section (enabled + notifyBefore), reachable only with a due date.
- **E — Settings Notifications section + badges + background refresh (App, build+smoke):** the Settings Notifications section; `setBadge`; `BGAppRefreshTask` registration + handler (sweep + badge).

## 5. Testing
- **swift test:** `ReminderMath` (fireDate offset, past-due skip, quiet-hours defer incl. midnight-crossing, badge count); `TaskStore` reminder hooks via a recording fake `ReminderScheduling` (create→schedule, complete→cancel, delete→cancel, disable→cancel, snooze→reschedule@snoozedUntil, spawn→schedule). The `UNUserNotificationCenter`/`BGTask`/permission code is runtime — **build-verified + manual pass** (notification delivery, permission prompt, quiet-hours suppression, badge updates, background-refresh firing all need a device/simulator with notifications).
- **App:** build iPhone+iPad + simctl smoke (editor Reminders section, Settings Notifications section render). NOTE: actual notification delivery is NOT simctl-screenshot-verifiable.

## 6. Acceptance criteria (A35–A41)
- **A35** `ReminderMath` computes fire time = dueDate − offset; skips no-due/disabled/completed/past; quiet-hours defers into-window fires to window end (incl. midnight-crossing). Unit-tested.
- **A36** Store schedules at write time + reschedules on dueDate/notifyBefore/enabled/completion change + cancels on complete/delete/disable + reschedules on snooze + schedules recurrence spawns — via the injected scheduler (recording-fake tested).
- **A37** `LiveReminderScheduler` uses stable `task-<id>` ids (reschedule replaces, not stacks); maps sound; builds.
- **A38** Permission requested contextually (not at launch); `permissionAsked` tracked; Settings reflects OS state.
- **A39** Reminder UI in the editor (enabled + notifyBefore), due-date-gated.
- **A40** Settings Notifications section (enable/default/sound/quiet-hours/permission).
- **A41** App-icon badge reflects overdue+due-today; background `BGAppRefreshTask` runs sweep + badge.
- **Coverage:** swift test green for ReminderMath + store hooks; both sims build; manual pass for delivery/permission/badge/background.

## 7. Conventions (carried)
`GSDModel` zero-dep (Foundation only — `ReminderMath` here; NO `UserNotifications`). `GSDStore` no SwiftUI and **no `UserNotifications`** (the scheduler is an injected protocol; the live impl lives in the App). App may `import UserNotifications`/`BackgroundTasks`. `GSDModel.Task` shadows Swift's `Task` → `_Concurrency.Task`. Inject time. `String(localized:)`. Store stamps `updatedAt`. Swift Testing for logic; `xcodebuild`+simctl for UI; `xcodegen generate` for new files / project.yml changes; no `DEVELOPMENT_TEAM` in commits. Probe quiet-hours/fireDate math in `/tmp` before the plan.

## 8. Watch-outs
- **`project.yml` change** for background modes / `BGTaskSchedulerPermittedIdentifiers` + notification capability — regenerate the project; this is the first phase needing an entitlement/Info.plist capability beyond what exists.
- **Quiet-hours midnight-crossing** (e.g. 22:00–07:00) is the subtle bit — probe it.
- **Permission + delivery are device/runtime** — the manual pass (already tracked) must cover: permission prompt, a reminder actually firing, quiet-hours suppression, badge count, background-refresh execution.
- Keep the store's scheduler seam a protocol so `swift test` stays deterministic (no real `UNUserNotificationCenter` in tests).
