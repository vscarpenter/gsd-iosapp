# Unified Task-Card Interaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the iOS task card's completion disc tappable to complete, add a persistent `⋯` overflow menu for secondary actions, and extract one shared menu — so a web-fluent user needs no relearning, across both iPhone and iPad.

**Architecture:** All changes live in `App/Matrix/`. `TaskCardView` (the single card view both targets render) gains two optional callbacks — `onToggle` and a `menu` builder. When provided, the disc becomes a button and a `⋯ Menu` renders at the trailing edge; when nil, the card stays decorative (previews). A new `TaskRowMenu` de-duplicates the iPhone context menu, the iPad swipe menu, and the new `⋯`. The card-body tap is scoped to the content region so it can't swallow disc/⋯ taps.

**Tech Stack:** SwiftUI (iOS 26), Swift 6 strict concurrency. No new GSDKit logic — reuses `TaskActions.toggle`. Verification: `swift test` (regression), `xcodebuild` for iPhone + iPad, `simctl` smoke.

**Spec:** [docs/superpowers/specs/2026-06-13-unified-task-card-interaction-design.md](../specs/2026-06-13-unified-task-card-interaction-design.md)

---

## File Structure

- **Create** `App/Matrix/TaskRowMenu.swift` — shared `@ViewBuilder` menu content (Edit · Duplicate · Share · Complete · Timer · Snooze ▸ · Move ▸ · Delete). Single source for context menu, swipe menu, and `⋯`.
- **Modify** `App/Matrix/TaskCardView.swift` — add `onToggle: (() -> Void)?` and `menu: (() -> AnyView)?` (default nil); make `completionDisc` a button when `onToggle != nil`; render `⋯` Menu when `menu != nil`; scope body content; a11y.
- **Modify** `App/Matrix/TaskListRow.swift` (iPhone) — adopt `TaskRowMenu`; pass `onToggle`/`menu`; gate on edit mode.
- **Modify** `App/Matrix/QuadrantCell.swift` (iPad) — replace `cellMenu` body with `TaskRowMenu`; pass `onToggle`/`menu` in the non-selecting branch only.
- Inherited free: `QuadrantSection` (iPhone), `FilteredTaskListView` (smart views), `SwipeRevealRow` (iPad swipe) — all route through the views above; no signature changes needed.

---

## Task 1: Extract the shared row menu

**Files:**
- Create: `App/Matrix/TaskRowMenu.swift`

- [ ] **Step 1: Create `TaskRowMenu.swift` with the menu content**

The body is copied verbatim from the current `rowMenu` in `TaskListRow.swift` (it is the superset — it has all items in the same order as `cellMenu`). Snooze presets stay duplicated per the Phase-2 decision (do NOT extract them to a shared constant).

```swift
import SwiftUI
import GSDModel
import GSDStore

/// The full per-task action set, shared by the iPhone long-press context menu,
/// the iPad swipe-reveal menu, and the always-visible `⋯` button on the card —
/// so the three entry points can never drift apart.
struct TaskRowMenu: View {
    let task: Task
    let actions: TaskActions
    var onEdit: (Task) -> Void

    var body: some View {
        Button { onEdit(task) } label: { Label(String(localized: "Edit"), systemImage: "pencil") }
        Button { actions.duplicate(task) } label: {
            Label(String(localized: "Duplicate"), systemImage: "plus.square.on.square")
        }
        ShareLink(item: task.shareText) {
            Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
        }
        Button { actions.toggle(task) } label: {
            Label(task.completed ? String(localized: "Uncomplete") : String(localized: "Complete"), systemImage: "checkmark")
        }
        if TimeTracking.runningEntry(task.timeEntries) == nil {
            Button(String(localized: "Start Timer")) { actions.startTimer(task) }
        } else {
            Button(String(localized: "Stop Timer")) { actions.stopTimer(task) }
        }
        Menu(String(localized: "Snooze")) {
            ForEach(snoozeMenuPresets.indices, id: \.self) { i in
                Button(snoozeMenuPresets[i].0) { actions.snooze(task, by: snoozeMenuPresets[i].1) }
            }
        }
        Menu(String(localized: "Move to")) {
            ForEach(Quadrant.allCases, id: \.self) { q in
                Button(q.title) { actions.move(task, to: q) }
            }
        }
        Button(role: .destructive) { actions.delete(task) } label: { Label(String(localized: "Delete"), systemImage: "trash") }
    }

    /// Six §6.7 snooze presets — intentionally duplicated (not a shared constant), per the Phase-2 decision.
    private var snoozeMenuPresets: [(String, SnoozePreset)] {
        [(String(localized: "15 minutes"), .fifteenMinutes), (String(localized: "30 minutes"), .thirtyMinutes),
         (String(localized: "1 hour"), .oneHour), (String(localized: "3 hours"), .threeHours),
         (String(localized: "Tomorrow"), .tomorrow), (String(localized: "Next week"), .nextWeek)]
    }
}
```

- [ ] **Step 2: Verify it compiles in isolation**

Run: `cd GSDKit && swift build` is NOT applicable (app file). Instead build the app after Task 3 wires it. For now, just confirm no syntax errors by eye — the file is self-contained and uses only already-imported symbols (`TaskActions`, `TimeTracking`, `Quadrant`, `SnoozePreset`).

- [ ] **Step 3: Commit**

```bash
git add App/Matrix/TaskRowMenu.swift
git commit -m "refactor(matrix): extract shared TaskRowMenu"
```

---

## Task 2: Make the card disc tappable + add the `⋯` menu

**Files:**
- Modify: `App/Matrix/TaskCardView.swift`

- [ ] **Step 1: Add the two optional callbacks to the view's stored properties**

After the existing `var blockingCount: Int = 0` line, add:

```swift
    /// When non-nil, the completion disc becomes a tappable button (parity with the
    /// web's complete circle). Nil keeps the disc decorative (previews/non-interactive hosts).
    var onToggle: (() -> Void)?
    /// When non-nil, a trailing `⋯` button presents this menu content.
    var menu: (() -> AnyView)?
```

- [ ] **Step 2: Replace the trailing `completionDisc` in `body` with the trailing controls cluster**

Change the end of the outer `HStack` (currently `Spacer(minLength: 0)` then `completionDisc`) to:

```swift
            Spacer(minLength: 0)

            trailingControls
```

- [ ] **Step 3: Add `trailingControls` and make the disc interactive**

Add these computed properties; replace the existing `completionDisc` definition with the version below (it now takes no a11y-hidden when interactive).

```swift
    @ViewBuilder private var trailingControls: some View {
        HStack(spacing: 10) {
            if let menu {
                Menu { menu() } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Surface.ink3)
                        .frame(width: 30, height: 30)          // ≥30pt; full 44pt row height gives the rest
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "More actions"))
            }
            completionControl
        }
    }

    @ViewBuilder private var completionControl: some View {
        if let onToggle {
            Button(action: onToggle) { completionDisc }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)                  // §12.3 hit target around the 28pt disc
                .contentShape(Rectangle())
                .accessibilityLabel(task.completed ? String(localized: "Uncomplete") : String(localized: "Complete"))
        } else {
            completionDisc.accessibilityHidden(true)
        }
    }

    private var completionDisc: some View {
        ZStack {
            if task.completed {
                Circle().fill(QuadrantStyle.accent(task.quadrant))
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Surface.inkOnAccent)
            } else {
                Circle().stroke(Surface.hairlineStrong, lineWidth: 2)
            }
        }
        .frame(width: 28, height: 28)
    }
```

Note: the old `completionDisc` had `.accessibilityHidden(true)` baked in — that moves to the `else` branch of `completionControl` so the interactive disc is NOT hidden.

- [ ] **Step 4: Scope the body tap (gesture precedence)**

The card-body tap currently lives on the whole row in the containers. To stop it swallowing disc/⋯ taps, the body content region must be the tap surface, not the trailing controls. The card view itself stays gesture-free (containers own the body tap), but it must expose a content-only region. Wrap the leading `VStack(alignment: .leading, spacing: 6)` content + spine in a region the container can target. Simplest: keep structure, and in Tasks 3–4 attach the body tap to the card via `.contentShape` on the content only. No change needed in this file beyond Step 3 — the containers handle gesture scoping. (Verstandard SwiftUI: a `Button`/`Menu` inside the row wins hit-testing over a `.contentShape` tap on the row, but only if the row tap is `.onTapGesture` not a high-priority `.gesture`. The container tasks switch to `.onTapGesture`.)

- [ ] **Step 5: Build for iPhone**

Run:
```bash
xcodegen generate
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: BUILD SUCCEEDED (existing call sites still compile — both new params default to nil).

- [ ] **Step 6: Commit**

```bash
git add App/Matrix/TaskCardView.swift
git commit -m "feat(matrix): tappable completion disc + ⋯ menu on TaskCardView"
```

---

## Task 3: Wire iPhone (`TaskListRow`)

**Files:**
- Modify: `App/Matrix/TaskListRow.swift`

- [ ] **Step 1: Replace the inline `rowMenu` with `TaskRowMenu` and pass card callbacks**

In `body`, change the `TimelineView { ... TaskCardView(...) }` so the card receives `onToggle` and `menu` only when NOT selecting, and switch the body tap to `.onTapGesture` scoped to the card content. Replace the card construction + `.gesture(...)` block with:

```swift
        TimelineView(.periodic(from: .now, by: 1)) { context in
            TaskCardView(task: task, now: context.date,
                         blockedByCount: blockedByCount, blockingCount: blockingCount,
                         onToggle: isSelecting ? nil : { actions.toggle(task) },
                         menu: isSelecting ? nil : { AnyView(TaskRowMenu(task: task, actions: actions, onEdit: onEdit)) })
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isSelecting { onEdit(task) } }
```

Remove the old `.gesture(TapGesture().onEnded { onEdit(task) }, including: ...)` line.

- [ ] **Step 2: Point the context menu at the shared view**

Replace `.contextMenu { rowMenu }` with:

```swift
        .contextMenu { TaskRowMenu(task: task, actions: actions, onEdit: onEdit) }
```

- [ ] **Step 3: Delete the now-unused `rowMenu` and `snoozeMenuPresets`**

Remove the `@ViewBuilder private var rowMenu` block and the `private var snoozeMenuPresets` block from `TaskListRow` (they now live in `TaskRowMenu`). Keep `.accessibilityActions { ... }` and `.swipeActions` as-is.

- [ ] **Step 4: Build for iPhone**

Run:
```bash
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Smoke test on iPhone simulator**

Run (boot + install + launch):
```bash
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null; \
xcrun simctl install booted "$(xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -showBuildSettings 2>/dev/null | awk '/TARGET_BUILD_DIR/{d=$3}/FULL_PRODUCT_NAME/{p=$3}END{print d"/"p}')"; \
xcrun simctl launch booted dev.vinny.gsd
```
Verify by hand: tap disc → completes (strikethrough + filled disc); tap again → uncompletes; tap card body → editor opens; `⋯` shows all actions; swipe + long-press still work.

- [ ] **Step 6: Commit**

```bash
git add App/Matrix/TaskListRow.swift
git commit -m "feat(matrix): wire iPhone row to tappable disc + shared ⋯ menu"
```

---

## Task 4: Wire iPad (`QuadrantCell`)

**Files:**
- Modify: `App/Matrix/QuadrantCell.swift`

- [ ] **Step 1: Pass card callbacks in the non-selecting `swipeRow` content**

In `swipeRow(_:)`, the `content:` closure builds `TaskCardView`. Add the callbacks (the swipe row is only used when NOT selecting, so no edit-mode guard needed here):

```swift
            content: {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    TaskCardView(
                        task: task,
                        now: context.date,
                        blockedByCount: graph.uncompletedBlockers(of: task.id).count,
                        blockingCount: graph.blockedTasks(of: task.id).count,
                        onToggle: { actions.toggle(task) },
                        menu: { AnyView(TaskRowMenu(task: task, actions: actions, onEdit: onEdit)) }
                    )
                }
            }
```

Leave the `isSelecting` branch's `TaskCardView` (inside `cardRow`) unchanged — it stays decorative so taps toggle selection.

- [ ] **Step 2: Replace `cellMenu` usage with `TaskRowMenu`**

In `swipeRow`, change `menu: { cellMenu(task) }` to:

```swift
            menu: { TaskRowMenu(task: task, actions: actions, onEdit: onEdit) }
```

- [ ] **Step 3: Delete the now-unused `cellMenu` and `snoozeMenuPresets`**

Remove the `@ViewBuilder private func cellMenu(_:)` block and the `private var snoozeMenuPresets` block from `QuadrantCell`.

- [ ] **Step 4: Build for iPad**

Run:
```bash
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Smoke test on iPad simulator**

Boot/install/launch as in Task 3 Step 5 but with `iPad Pro 13-inch (M5)`. Verify: tap disc → completes; `⋯` shows actions; swipe-reveal still works; **enter Edit (multi-select) → tapping a card toggles selection, NOT completion/menu**; Done clears selection.

- [ ] **Step 6: Commit**

```bash
git add App/Matrix/QuadrantCell.swift
git commit -m "feat(matrix): wire iPad cell to tappable disc + shared ⋯ menu"
```

---

## Task 5: Regression + final verification

**Files:** none (verification only)

- [ ] **Step 1: Run the GSDKit suite (must be unaffected)**

Run: `cd GSDKit && swift test`
Expected: all tests pass (the change added no package logic).

- [ ] **Step 2: Clean build both targets**

Run:
```bash
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```
Expected: BUILD SUCCEEDED for both.

- [ ] **Step 3: Confirm smart-view list inherits the behavior**

Launch, open a smart view (e.g. Today's Focus) → confirm rows show the tappable disc + `⋯` (it routes through `TaskListRow`, fixed in Task 3). No code change expected; this is a verification only.

- [ ] **Step 4: Final commit if any cleanup**

```bash
git status   # expect clean; commit any stragglers
```

---

## Self-Review notes

- **Spec coverage:** §5.1 disc → Task 2; §5.2 ⋯ → Task 2; §5.3 TaskRowMenu → Task 1 (+ adopted in 3/4); §5.4 edit-mode gating → Task 3 Step 1 (`isSelecting ? nil`) + Task 4 (selecting branch untouched); §5.5 gesture precedence → Task 2 Step 4 + Task 3 Step 1 (`.onTapGesture`); §5.6 files → all tasks; §6 a11y → Task 2 Step 3; §7 testing → Task 5.
- **No new GSDKit tests:** intentional — no new pure logic (spec §7); regression-gated instead.
- **Type consistency:** `onToggle: (() -> Void)?` and `menu: (() -> AnyView)?` used identically in Tasks 2/3/4; `TaskRowMenu(task:actions:onEdit:)` signature constant across call sites.
