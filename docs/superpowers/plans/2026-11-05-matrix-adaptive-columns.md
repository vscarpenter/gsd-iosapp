# Matrix Adaptive Columns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lay out each iPad and Mac matrix quadrant in as many columns as fit, with a toolbar switch back to today's one-column list.

**Architecture:** A pure `MatrixLayout` enum in `GSDModel` owns the setting and the column-count rule, unit tested. `QuadrantCell` measures its content width and lays its cards out in a `LazyVGrid` with that many flexible columns. `MatrixGridView` stores the choice in App Group defaults and adds the toolbar toggle.

**Tech Stack:** Swift 6, SwiftUI (iOS 26 floor, iOS 27 SDK), Swift Testing, XcodeGen.

**Spec:** `docs/2026-11-05-matrix-adaptive-columns.md`

## Global Constraints

- Minimum card width 280 points; column spacing 16 points.
- Columns = `max(1, floor((width + 16) / (280 + 16)))` of the quadrant's content width.
- `MatrixLayout.default` is `.columns`. Raw values `"list"` and `"columns"` are persisted; never rename them.
- Stored under `AppGroupDefaults.Key.matrixLayout` (`"matrixLayout"`), App Group defaults, per device, never synced.
- Accessibility text sizes always get one column.
- Toolbar toggle only (no Settings row, ⌘K command, or menu item). iPhone and `MatrixView` untouched.
- `GSDModel` keeps zero dependencies. Xcode calls need `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Prose (comments, commits) follows vinny-voice: no em dashes, no double hyphens.

## Review Focus

1. A width of zero, NaN, or infinity (before first layout, or a bad measurement) must give one column, never a trap in `Int(_:)`. Pinned in Task 1.
2. A quadrant narrower than one card in Columns mode gets one column at full width. Pinned in Task 1 (`279 → 1`).
3. iOS 27 swipe actions inside a multi-column grid: one card open at a time, and a swipe doesn't fight the cell's scroll. Owner device check; the grid keeps the same `swipeActionsContainer()` ScrollView.
4. Edit mode in Columns: the 28-point selection disc plus card still fits a 280-point column. Covered by the Mac smoke in Task 3.
5. Resizing a Mac window across 576 points of quadrant width reflows without losing the cell's scroll position. Covered by the Mac smoke in Task 3.

---

### Task 1: `MatrixLayout` setting and column rule

**Files:**
- Create: `GSDKit/Sources/GSDModel/MatrixLayout.swift`
- Modify: `GSDKit/Sources/GSDStore/AppGroupDefaults.swift` (add the key after `escalationWindowDays`)
- Test: `GSDKit/Tests/GSDModelTests/MatrixLayoutTests.swift`

**Interfaces:**
- Produces: `public enum MatrixLayout: String, CaseIterable, Sendable { case list, columns }`,
  `public static let default: MatrixLayout`, `public static let minimumCardWidth: Double`,
  `public static let columnSpacing: Double`,
  `public func columnCount(forWidth width: Double, accessibilityTextSize: Bool) -> Int`,
  and `AppGroupDefaults.Key.matrixLayout`.

- [ ] **Step 1: Write the failing tests** (`struct MatrixLayoutTests`, Swift Testing)
  - `defaultIsColumns`: `#expect(MatrixLayout.default == .columns)`
  - `rawValuesArePinned`: `"list"` and `"columns"`
  - `listIsAlwaysOneColumn`, arguments `[0, 280, 576, 2000]`: `.list.columnCount(forWidth:accessibilityTextSize: false) == 1`
  - `columnsFitCardsAtLeast280Wide`, arguments `zip([0, 279, 575, 576, 871, 872, 1168], [1, 1, 1, 2, 2, 3, 4])`
  - `degenerateWidthsGetOneColumn`, arguments `[-10, .nan, .infinity]`: `.columns` gives 1
  - `accessibilityTextSizesGetOneColumn`: `.columns.columnCount(forWidth: 2000, accessibilityTextSize: true) == 1`
  - `spacingAndMinimumMatchTheSpec`: 280 and 16

- [ ] **Step 2: Run to verify they fail**

Run: `cd GSDKit && swift test --filter MatrixLayoutTests`
Expected: build failure, `cannot find 'MatrixLayout' in scope`.

- [ ] **Step 3: Implement `MatrixLayout`** in `GSDModel/MatrixLayout.swift`, plus `public static let matrixLayout = "matrixLayout"` in `AppGroupDefaults.Key` with a one-line "per device, never synced" comment. Guard `width.isFinite && width > 0` before the floor.

- [ ] **Step 4: Run the full suite**

Run: `cd GSDKit && swift test`
Expected: all tests pass, including the 7 new ones.

- [ ] **Step 5: Commit** (`feat(model): add the matrix layout setting and column rule`)

### Task 2: Adaptive grid in `QuadrantCell` and the toolbar toggle

**Files:**
- Modify: `App/Matrix/QuadrantCell.swift` (`rows`, new stored properties, width measurement)
- Modify: `App/Matrix/MatrixGridView.swift` (setting, toggle, `QuadrantCell(layout:)`)

**Interfaces:**
- Consumes: `MatrixLayout`, `columnCount(forWidth:accessibilityTextSize:)`, `columnSpacing`, `AppGroupDefaults.Key.matrixLayout` (Task 1).
- Produces: `QuadrantCell(... layout: MatrixLayout ...)`, a required `let`, placed after `isSelecting`.

- [ ] **Step 1: `QuadrantCell`**
  - Add `let layout: MatrixLayout`, `@Environment(\.dynamicTypeSize) private var typeSize`, and `@State private var contentWidth: CGFloat = 0`.
  - Measure the outer `VStack` before `.padding(14)` with `.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }`.
  - `rows`: keep the empty prompt, then a `LazyVGrid` of `columnCount` copies of `GridItem(.flexible(), spacing: MatrixLayout.columnSpacing, alignment: .top)`, `alignment: .leading`, `spacing: 10`. Each item is a `VStack(spacing: 10)` holding the hairline when `index >= columnCount`, then `cardRow(task).fixedSize(horizontal: false, vertical: true)`.
  - One column must render exactly today's rhythm: card, 10, hairline, 10, card.

- [ ] **Step 2: `MatrixGridView`**
  - `@AppStorage(AppGroupDefaults.Key.matrixLayout, store: .shared) private var matrixLayout: MatrixLayout = .default`
  - Pass `layout: matrixLayout` to `QuadrantCell`.
  - Toolbar, between `showCompletedToggle` and `EditButton`: a `ToolbarItem(placement: .topBarTrailing)` holding `Toggle(isOn:)` bound to `matrixLayout == .columns`, label `Label("Columns", systemImage: "rectangle.split.3x1")`, `.toggleStyle(.button)`, `.help` and `.accessibilityHint` "Shows tasks in columns when there's room", then `.overflowsFirst()`.

- [ ] **Step 3: Build iPad**

Run: `xcodegen generate && xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,id=FE95EE9A-29AA-4135-BAD2-B201A53FE419' build -quiet`
Expected: `** BUILD SUCCEEDED **` (quiet prints nothing on success; exit 0).

- [ ] **Step 4: Commit** (`feat(matrix): lay quadrants out in adaptive columns with a list toggle`)

### Task 3: Full verification, smoke, and docs

**Files:**
- Modify: `docs/2026-11-05-matrix-adaptive-columns.md` (verification notes)

- [ ] **Step 1:** `cd GSDKit && swift test` passes.
- [ ] **Step 2:** Build iPhone (`id=1A403867-D27E-4DCC-98D7-F83D8A8FFF52`), iPad (Task 2), and Mac Catalyst (`-destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO`). All exit 0.
- [ ] **Step 3: iPad smoke.** Install on the iOS 26.5 iPad Air, launch with `--demo-seed`, screenshot. Expected: one column (portrait), the Columns toggle in the toolbar, cards and hairlines as before.
- [ ] **Step 4: Mac smoke.** Launch the signed Debug Catalyst build with `--demo-seed --demo-window 1400x900`, screenshot. Expected: two columns per quadrant, per-column hairlines, top-aligned rows. Click the toggle if GUI scripting is available and screenshot List.
- [ ] **Step 5:** Record what the smoke showed in the design note, commit (`docs(matrix): record adaptive columns verification`).
