# GSD iOS — Increment Spec: Phases 0–2 (Foundations · Core App · Task Depth)

- **Date:** 2026-05-30
- **Status:** Draft for review
- **Author:** Vinny Carpenter (with Claude)
- **Scope of this document:** The first build-ready increment of the native GSD iOS/iPadOS app. Covers Phases 0, 1, and 2 of the product spec's roadmap (§14). Produces a fully-functional, **offline, single-device** task manager on a simulator with no backend, no notifications, and no extensions.

### References (authoritative for behavior)

- **Product spec:** `2026-05-30-native-ios-app-design.md` — the source of truth for every behavioral rule, limit, and enumeration. Section references below (e.g. §6.2) point into it.
- **Coding standards:** `coding-standards.md` — process and quality bar (TDD, spec-driven, elegance check, Definition of Done).

This spec governs *what we build first and how we verify it*. Where it is silent on a behavior, the product spec governs.

---

## 1. Goal

Stand up the GSD app's foundation and full offline task-management experience: a versioned local store, all correctness-critical pure logic under test, an adaptive iPhone/iPad Matrix UI, and the complete task-depth feature set (due dates, recurrence, subtasks, snooze, dependencies, time tracking) — all runnable and verifiable on a simulator with zero network, account, or OS-notification dependencies.

---

## 2. Scope

### 2.1 In scope (Phases 0–2)

- **Phase 0 — Foundations.** Xcode project (`dev.vinny.gsd`), `GSDKit` package, App Group (`group.dev.vinny.gsd`), GRDB store + versioned migrations, the `Task` model and all embedded types, web-compatible ID generation, unit tests for the model and limits.
- **Phase 1 — Core local app.** Matrix (iPhone stacked sections + iPad 2×2 grid), capture field with the full shorthand parser, task editor, complete/uncomplete with confetti, delete, show-completed toggle, theming.
- **Phase 2 — Task depth.** Due dates + presets, recurrence engine, subtasks, snooze, dependencies with BFS cycle prevention, time tracking. Tests for each.

### 2.2 Out of scope (each gets its own later spec → plan cycle)

- **Phase 3:** Archive, smart views + the full `FilterCriteria` pipeline, search + command palette, analytics dashboard, import/export, onboarding/About.
- **Phase 4:** Notifications, reminder UI, quiet hours, badges, background refresh.
- **Phase 5:** Sync, PocketBase client (REST + SSE), OAuth, Keychain, LWW engine, sync queue.
- **Phase 6:** Widgets, App Intents/Siri/Shortcuts, Spotlight, Share Extension, Quick Actions, outbound task-share (§6.18).
- **Phase 7:** Sign in with Apple, privacy labels/policy, App Store submission.
- **Never:** iCloud / CloudKit. Sync routes through PocketBase to preserve web-app and MCP interop (§7, §11).

> **Note on deferred-but-present fields.** The `tasks` table carries the full §5.1 column set from `v1` (including notification/sync fields). Those columns simply go unwritten until their phase. Reminder/notification *UI* is hidden until Phase 4 — we will not ship a control that does nothing.

---

## 3. Architecture

### 3.1 Module & target structure

```
GSD.xcodeproj
├─ GSD (app target, bundle id: dev.vinny.gsd)
│    SwiftUI surfaces; observes @Observable stores; depends on GSDKit
│    Entitlement: App Group  group.dev.vinny.gsd
│
└─ GSDKit  (local Swift package)
     ├─ GSDModel    ← pure value types + pure functions. ZERO dependencies.
     ├─ GSDStore    ← GRDB persistence. depends on { GRDB, GSDModel }
     ├─ GSDModelTests   ← `swift test`, sub-second, no DB, no simulator
     └─ GSDStoreTests   ← `swift test` against in-memory DatabaseQueue
```

- **Compiler-enforced isolation.** `GSDModel` has no dependency on GRDB, so the correctness-critical logic *cannot* be entangled with persistence — it won't link. This is the structural bet that keeps the correctness loop fast.
- **One external dependency: GRDB**, pinned via `Package.resolved`. Justified under the "stdlib over external unless it cuts >2× the code" rule — hand-rolling SQLite + migrations + change-observation is far more than 2× the code.
- **`storeURL` provider.** The on-disk store location comes from one provider pointing at the App Group container, so Phase 6 widgets/extensions read the same DB with no refactor. If App Group signing causes simulator friction, the provider falls back to Application Support with no other code change.

### 3.2 App architecture (Approach 1 — layered package + native Observation store)

- SwiftUI views observe `@MainActor @Observable` store objects.
- Stores are fed by GRDB `ValueObservation` (DB change → store republishes `[Task]` → views update).
- Mutations call `TaskRepository` async methods (write to GRDB; observation pushes the result back) — an effectively unidirectional flow.
- Repositories are injected behind a protocol, so views and logic are testable without a real database.
- **No third-party state framework** (no TCA) — native Observation + repository pattern only, per "boring tech."

### 3.3 Data layer & GRDB modeling

- **Embedded collections as JSON columns, not child tables.** `tags`, `subtasks`, `dependencies`, `timeEntries` are JSON-encoded `TEXT` columns on the `tasks` row — matching the web's Dexie embedding and PocketBase's `json` fields (§7.1), minimizing Phase 5 mapper impedance. All in-memory logic operates on decoded structs.
- **`Task` stays pure; `TaskRecord` does the GRDB work.** `TaskRecord` (flat columns; JSON strings for arrays) conforms to GRDB's protocols and maps bidirectionally to the pure `Task`, with a round-trip identity test. Same shape we'll reuse for the PocketBase mapper later (§7.2).
- **`quadrant` is persisted and indexed** (derived from the flags, never allowed to drift). Indexes also on `completed`, `dueDate`, `updatedAt`.
- **`TaskRepository`** exposes async CRUD + `ValueObservation` streams. Every mutation bumps `updatedAt`. Delete strips the deleted id from every other task's `dependencies` (§6.8 cleanup-on-delete).
- **UI prefs → `UserDefaults`** (App-Group-scoped), not the DB: `showCompleted`, theme (light/dark/system), section-collapse state (§5.7).
- **Migrations:** `v1` creates only the `tasks` table (full §5.1 column set). Archive/smart-view/settings/sync tables arrive in `v2`+ when their phases land — not created speculatively.

---

## 4. Decisions locked (with rationale)

| Decision | Choice | Rationale |
|---|---|---|
| Sync target | PocketBase (iOS ↔ web ↔ MCP); **no iCloud** | Preserves web-app data sharing and the §11 "MCP just works" guarantee. CloudKit reaches only Apple devices and would break both. |
| Persistence | **GRDB (SQLite)** | Explicit rows + `ValueObservation` make the Phase 5 custom LWW engine tractable; maps ~1:1 to the web's Dexie + sync-queue model. |
| App architecture | **Layered GSDKit + native `@Observable` store + repository** | Maximum isolation/testability; boring tech; sets up Phase 5 (sync engine becomes another repository consumer). |
| Typography | **System fonts per Apple HIG** — San Francisco body, New York serif display | Editorial serif feel with full Dynamic Type, no bundled assets, no licensing. |
| Bundle ID / App Group | `dev.vinny.gsd` / `group.dev.vinny.gsd`, wired day one | Paid Developer account available; avoids a Phase 6 store-path refactor. |
| iPhone Matrix layout | **Stacked quadrant sections** | Product spec §4.1 recommendation; revisit if it tests cramped (open q#5). |
| Test framework | **Swift Testing** (`@Test`) | Native to Xcode 26; modern default. |
| Confetti | **Native `Canvas` + `TimelineView`**, Reduce-Motion-aware | No dependency; respects accessibility. |
| Cross-provider identity (§8.4) | **Deferred, tracked risk** | Phase 5, backend-owned. Must be resolved before sync ships; does not block this increment. |

---

## 5. Pure-logic units & contracts (`GSDModel`)

Each is a pure function/type, TDD'd via `swift test`. Behavior is authoritative per the referenced product-spec section.

| Unit | Contract (inputs → outputs / rules) | Source |
|---|---|---|
| `IDGenerator` | URL-safe nanoid; **injectable randomness**; min lengths task ≥4, time-entry 8, smart-view 12 | §5, §5.2–5.3 |
| `CaptureParser` | Parse `!!`/`!`/`*`/`#tag` on word boundaries; tags lowercased, deduped, cap 20; default quadrant **Q4** with no flags; manual override cycle. **URL sanitizer:** http/https only, reject `user:pass@`, require valid host, reject ≥2048 chars, strip trailing `,;:.!?)`; valid URL → description; empty title + URL found → "Review link below"; invalid URL left in title | §6.2 |
| `Quadrant` | Pure derivation `(urgent, important)` → id + display metadata; canonical order Q1→Q4 | §5.8 |
| `RecurrenceEngine` | Advance due date: daily +1d, weekly +7d, monthly +1 calendar month with **month-end clamping**; spawn next instance on completion (new id/timestamps, single-level `parentTaskId`, reset subtasks + completion + reminder fields; no-due-date stays none). **Clock + calendar injected** | §6.5 |
| `DependencyGraph` | **BFS cycle prevention** (reject self-ref, missing id, cycle); queries `blockingTasks`, `uncompletedBlockers`, `isBlocked`, `blockedTasks`, `readyTasks` | §6.8 |
| `TimeTracking` | One running entry max; stop recalculates `timeSpent` (sum of whole minutes); format `< 1m` / `Xm` / `Xh Ym` / `Xh` | §6.9 |
| `DueDatePresets` | None / Today / This week (Friday; next Friday on a weekend) / Next week (Monday strictly after today); local time zone. **Clock injected** | §6.10 |
| `Validation` | Every §5.1 / Appendix-B limit; `estimatedMinutes == 0 → unset`; snooze max 1 year | §5.1, App. B |

*Deferred to Phase 3:* full `FilterCriteria` pipeline, analytics/streak math. The dependency queries above are in scope because Phase 2 de-emphasizes blocked tasks.

---

## 6. SwiftUI surfaces (Phase 0–2)

- **Adaptive root by size class.** iPhone (compact): Matrix is the app, with a Settings entry for theme + show-completed (the full `TabView` arrives in Phase 3 when its tabs exist). iPad (regular): `NavigationSplitView` — sidebar (Matrix, Settings) · content (2×2 grid) · **inspector = editor**.
- **Matrix.** iPhone: sticky capture field + vertical stack of 4 collapsible quadrant sections, sticky headers, live counts (active/done/overdue). iPad: true **2×2 grid** (Q1 TL → Q4 BR) with **drag-and-drop across quadrants** (`.draggable`/`.dropDestination`).
- **Capture field.** Live parse preview (quadrant chip reacts to `!`/`*`; `#tags` render as chips); Return adds and keeps focus; "Details" opens the editor pre-filled; quadrant-override segmented chip (Tab cycles on a hardware keyboard).
- **Task card.** Title (strikethrough if done), 2-line description with tappable links, tag chips, subtask progress bar + `done/total`, dependency badges (Blocked by N / Blocking N; blocked de-emphasized), relative due date (Due today highlighted, overdue in alert color), recurrence glyph, live-ticking timer when running + total tracked, snooze indicator with remaining time.
- **Row interactions.** Leading swipe → complete/uncomplete (**success haptic + Reduce-Motion-aware confetti**); trailing swipe → Snooze + Delete; tap → editor; context menu (Edit, Complete, Start/Stop timer, Snooze, Duplicate, Move to quadrant, Delete).
- **Editor.** Sheet w/ detents on iPhone, inspector on iPad. Fields: title, description, 2×2 quadrant picker, due date (`DatePicker` + presets), tags token field w/ autocomplete, recurrence picker, inline reorderable subtasks, **dependency picker with live cycle-rejection**, estimate, total-tracked-vs-estimate readout. Save validates limits; Save disabled while title empty. *(Reminder/notification controls hidden until Phase 4.)*
- **Theme.** Light/Dark/System; quadrant accents in the asset catalog (rust / ocean / olive / warning) meeting **WCAG AA** in both modes; New York serif display headings.

---

## 7. Data model — `tasks` table (`v1` migration)

Columns are the full §5.1 `Task` shape. Types below are the SQLite/GRDB storage form; the product spec governs semantics.

- Scalars: `id` (PK, TEXT), `title`, `description`, `urgent`, `important`, `quadrant` (indexed), `completed` (indexed), `completedAt`, `createdAt`, `updatedAt` (indexed), `dueDate` (indexed), `recurrence`, `parentTaskId`, `notifyBefore`, `notificationEnabled`, `notificationSent`, `lastNotificationAt`, `snoozedUntil`, `estimatedMinutes`, `timeSpent`.
- JSON `TEXT` columns: `tags`, `subtasks`, `dependencies`, `timeEntries`.
- Timestamps stored as `Date` internally; ISO-8601 with offset in any future wire/export form.
- Device-local fields (`notificationSent`, `lastNotificationAt`, `snoozedUntil`) exist now; only `snoozedUntil` is exercised in this increment (snooze, Phase 2).

---

## 8. Constraints

- **Performance:** matrix stays smooth with hundreds of tasks (lazy lists); no analytics/aggregation on the main actor; store reads off the main actor, UI updates on `@MainActor`.
- **Accessibility (baseline, required):** Dynamic Type throughout (no clipped fixed sizes); VoiceOver labels + custom actions (complete/snooze/edit) on cards with coherent reading order; Reduce Motion suppresses confetti; quadrant accents meet WCAG AA in both appearances; hit targets ≥ 44pt; full keyboard operability on iPad.
- **Security:** the URL sanitizer (§6.2) is security-relevant — http/https only, reject embedded credentials, reject oversize URLs. No secrets logged; no task content logged.
- **Localization-ready:** `String(localized:)`, no concatenated UI strings.
- **Swift 6 strict concurrency:** actors/`@MainActor` isolation respected; no data races.
- **Limits:** enforce Appendix-B values exactly.

---

## 9. Edge cases (must be covered by tests)

- Capture: `!!` precedence over `!`; `#Tag` vs `#tag` dedup; URL with trailing punctuation; URL with `user:pass@` rejected and left in title; URL ≥2048 chars rejected; title emptied by URL removal → "Review link below"; >20 tags truncated; no-flag input → Q4.
- Recurrence: Jan 31 + 1 month → Feb 28/29; weekly across a month boundary; recurring task with no due date spawns a no-due-date instance; subtasks reset to incomplete on spawn; single-level lineage when completing an instance of an instance.
- Dependencies: self-reference rejected; adding an edge that closes a cycle rejected (BFS); dependency on a non-existent id rejected; deleting a task removes it from others' `dependencies`; `readyTasks` excludes tasks with an incomplete blocker.
- Time tracking: starting a second timer while one runs is rejected; `timeSpent` sums only completed entries; formatting boundaries (0, <1m, exactly 60m, 61m).
- Due-date presets: "This week" on Saturday/Sunday → next Friday; "Next week" → Monday strictly after today; time-zone correctness.
- Store: round-trip identity through `TaskRecord`; `ValueObservation` emits on insert/update/delete; `quadrant` column matches the flags after every mutation.
- Validation: title length 0 and 81; description 601; estimate 0 (→ unset) and 10081; 51 subtasks; 21 tags.

---

## 10. Acceptance criteria (checkable)

**Foundations**
- A1. `swift test` runs the `GSDModel` + `GSDStore` suites with no simulator and passes.
- A2. The `v1` migration creates the `tasks` table with the full §5.1 column set; a migration test asserts the schema.
- A3. Generated IDs are URL-safe and meet the minimum lengths; a web-format fixture round-trips.

**Core app**
- A4. Capturing `Buy milk !! #errand` creates an urgent+important (Q1) task tagged `errand` with a cleaned title.
- A5. A captured `https://…` URL is moved to the description per the sanitizer rules; an unsafe URL is left in the title.
- A6. The Matrix renders 4 quadrants (iPhone stacked / iPad 2×2) with correct live counts and respects show-completed.
- A7. Completing a task sets `completedAt`, fires a success haptic, and shows confetti — suppressed under Reduce Motion.
- A8. iPad drag-and-drop moves a card between quadrants and updates `urgent`/`important` accordingly.

**Task depth**
- A9. Completing a recurring task spawns the next instance with the correctly advanced due date and reset subtasks.
- A10. Snooze sets `snoozedUntil` and the card shows remaining time; presets match §6.7.
- A11. The dependency picker rejects an edge that would create a cycle, with an explanation; blocked cards are de-emphasized.
- A12. Start/stop timer produces a correct `timeSpent`; a running timer shows live elapsed time; only one runs per task.
- A13. The editor validates every limit and disables Save on an empty title.

**Quality bar**
- A14. Each acceptance criterion above maps to at least one passing test.
- A15. Dynamic Type at max and a VoiceOver pass on the matrix + editor have no blocking issues.

---

## 11. Test stubs (draft names, mapped to criteria)

```
// GSDModelTests — CaptureParser
captureParser_doubleExclamation_setsUrgentAndImportant()          // A4
captureParser_singleExclamation_setsUrgentOnly()                  // A4
captureParser_asterisk_setsImportant()                            // A4
captureParser_hashTag_lowercasesAndDeduplicates()                 // A4
captureParser_over20Tags_truncatesAt20()                          // A4
captureParser_validUrl_movedToDescription()                       // A5
captureParser_urlWithEmbeddedCredentials_leftInTitle()            // A5
captureParser_urlOver2048Chars_rejected()                         // A5
captureParser_titleEmptiedByUrl_setsReviewLinkBelow()             // A5
captureParser_noFlags_defaultsToEliminateQuadrant()               // A4

// Quadrant
quadrant_urgentImportant_isDoFirst()                              // A6
quadrant_derivationNeverDriftsFromFlags()                         // A2/A6

// RecurrenceEngine
recurrence_monthly_jan31_clampsToFebEnd()                         // A9
recurrence_weekly_advancesSevenDays()                             // A9
recurrence_completion_resetsSubtasksToIncomplete()                // A9
recurrence_noDueDate_spawnsNoDueDateInstance()                    // A9
recurrence_instanceOfInstance_keepsSingleLevelLineage()           // A9

// DependencyGraph
dependency_selfReference_rejected()                               // A11
dependency_edgeClosingCycle_rejectedViaBfs()                      // A11
dependency_nonexistentId_rejected()                               // A11
dependency_readyTasks_excludeIncompleteBlockers()                 // A11

// TimeTracking
timeTracking_secondStartWhileRunning_rejected()                   // A12
timeTracking_timeSpent_sumsCompletedEntriesInWholeMinutes()       // A12
timeTracking_formatting_boundaries()                              // A12

// DueDatePresets
dueDate_thisWeek_onWeekend_resolvesToNextFriday()                 // A13
dueDate_nextWeek_resolvesToMondayStrictlyAfterToday()             // A13

// Validation
validation_titleLength_rejectsEmptyAndOver80()                    // A13
validation_estimateZero_coercedToUnset()                          // A13

// GSDStoreTests
store_v1Migration_createsTasksTableWithFullSchema()               // A2
store_taskRecord_roundTripsToDomainIdentity()                     // A2
store_valueObservation_emitsOnInsertUpdateDelete()                // A6
store_deleteTask_removesIdFromOtherDependencies()                 // A11

// App/UI (xcodebuild test)
matrix_iPhone_rendersFourStackedQuadrantsWithCounts()             // A6
matrix_iPad_dragMovesCardBetweenQuadrants()                       // A8
completion_firesConfetti_suppressedUnderReduceMotion()            // A7
editor_emptyTitle_disablesSave()                                  // A13
```

---

## 12. Verification method & loop

- **Fast core loop:** `swift test` for `GSDModel` + `GSDStore` (sub-second, no simulator) — the primary red→green→refactor loop.
- **App loop:** `xcodebuild test -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17'` for UI/snapshot tests; an iPad destination for the 2×2 + drag tests.
- **Visual confirmation:** boot the simulator and capture a screenshot of the matrix + editor on iPhone and iPad.
- **Accessibility:** Dynamic Type at max sizes and a VoiceOver pass on the two primary surfaces.
- Discipline per coding standards: tests before implementation, run affected tests each change, full suite before commit, elegance check on non-trivial changes.

---

## 13. Open questions / tracked risks

1. **Cross-provider identity (§8.4)** — blocking for Phase 5 sync, backend-owned. Not a blocker for this increment; recorded so it isn't forgotten.
2. **iPhone matrix layout (open q#5)** — building stacked; validate against a paged 2×2 if it tests cramped.
3. **Confetti feel** — native particle counts are a feel reference (≈120 + 60×2), tunable; correctness is "fires on complete, suppressed under Reduce Motion."
4. **GRDB ↔ Observation bridging ergonomics** — first real use of `ValueObservation` → `@Observable`; validate the pattern early on the matrix store before replicating it.
```
