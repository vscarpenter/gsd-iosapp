# Feature Parity — iPhone vs iPad

_A snapshot of where the two device idioms agree, where they diverge by design, and where
they diverge by omission. Use this to plan parity work._

> Source of truth: the App layer (`App/`). The package layers (`GSDKit/`) are device-agnostic
> and shared verbatim, so all parity differences live in SwiftUI surfaces, not in logic.

---

## TL;DR

- **One fork, not many.** The whole iPhone↔iPad split is decided by a single
  `horizontalSizeClass` check in `ContentView.rootContent` (`ContentView.swift:206`). Compact → a 4-tab `TabView`;
  regular → a `NavigationSplitView` (`RegularRootView`). There is no scattering of `if iPad`
  conditionals — the divergence is _which root container hosts the shared surfaces_.
- **Almost everything is shared.** The editor, dashboard, settings, filtered lists, Saved, archive,
  Trash, command palette, capture parsing, onboarding, and help are the same views on both idioms.
- **Pull-to-refresh — CLOSED (2026-06-18).** This was the one user-facing _capability_ gap:
  iPhone's Matrix could pull-to-sync, iPad's could not. The iPad grid now injects
  `SyncCoordinator` and carries `.refreshable { await sync.syncNow() }` like the iPhone list.
  History and the fix are in [§4 Pull-to-refresh](#4-pull-to-refresh-resolved).

---

## 1. Navigation architecture (the root fork)

| | iPhone (compact) | iPad (regular) |
|---|---|---|
| Root container | `TabView` — `ContentView.swift:222` | `NavigationSplitView` — `RegularRootView`, `ContentView.swift:315,324` |
| Top-level destinations | 4 tabs: **Matrix · Browse · Dashboard · Settings** | Sidebar: **Matrix · Dashboard · Smart Views · Library (Saved, Archive, Settings)** |
| Chrome (search, sync status) | Per-surface toolbar (each tab supplies its own) | Persistent sidebar toolbar — visible regardless of detail selection (`ContentView.swift:357-367`) |
| Smart Views | Dedicated **Browse** tab (`SmartViewListView`) | Folded into the always-visible sidebar (`SmartViewRow` reused) |
| Saved / Archive / Settings reach | Browse → Saved and Archive links; Settings tab | Sidebar **Library** section |
| Palette "Browse" | Opens the Browse tab | Lands on Library › Saved, since the sidebar is the browse list (`ContentView.swift:289-290`) |

This is an intentional Apple-HIG adaptation, not a gap. The iPad uses its width for a
persistent sidebar; the iPhone collapses the same destinations into tabs.

---

## 2. Feature parity matrix

Legend: ✅ present · ⚠️ present but adapted · ❌ absent

| Feature / surface | iPhone | iPad | Notes & references |
|---|:---:|:---:|---|
| **Eisenhower matrix** | ⚠️ vertical List of Q1→Q4 sections | ⚠️ true 2×2 `LazyVGrid` | `MatrixView`/`MatrixListContent` vs `MatrixGridView`/`MatrixGridContent`. Same data, same cell actions; layout differs by design. |
| Capture bar (quick add) | ✅ | ✅ | Shared `CaptureBar`; pinned via `safeAreaInset(.top)` on iPhone, top of `VStack` on iPad. |
| Show Completed toggle | ✅ | ✅ | `showCompletedToggle` in both Matrix toolbars. |
| Multi-select + Bulk actions | ✅ | ✅ | `EditButton` + `BulkActionBar` on both (`MatrixView.swift:76,85`, `MatrixGridView.swift:100,103`). |
| Confetti on completion | ✅ | ✅ | `ConfettiView` wraps both Matrix roots. |
| ⌘1–⌘4 quadrant focus / deep link | ✅ | ✅ | `consumeQuadrantFocus` in both Matrix contents. |
| **Pull-to-refresh → sync** | ✅ `MatrixView.swift:62` | ✅ `MatrixGridView.swift:84` _(closed 2026-06-18)_ | Was iPad-absent; grid now injects `SyncCoordinator` + `.refreshable`. See §4. Saved also pulls to sync (`SavedListView.swift:69`). |
| Manual "Sync Now" (Settings) | ✅ | ✅ | Shared `SettingsView.swift:118-127` → `session.syncNow()`. |
| Automatic sync (timer, network, scenePhase, post-mutation) | ✅ | ✅ | Driven by `SyncCoordinator`, idiom-independent. iPad still syncs continuously. |
| Sync status chip | ✅ Matrix + Browse + Dashboard tabs _(closed 2026-06-18)_ | ✅ persistent sidebar (`ContentView.swift:364`) | Shared `syncStatusChip` helper now on all three iPhone content tabs (Settings shows the full section). iPad keeps the single sidebar chip — the Dashboard chip is compact-gated. Tapping → Settings on both. |
| Command palette (⌘K / search) | ✅ per-surface button (`paletteButton`) | ✅ sidebar button (`ContentView.swift:359`) | Hardware ⌘K (and ⌘F) works on both via hidden buttons (`ContentView.keyboardShortcuts`, `ContentView.swift:132-161`); Mac uses the menu bar. |
| Browse / Smart Views list | ✅ `SmartViewListView` (tab) | ⚠️ sidebar list | iPhone uses **swipe actions** (pin/edit/delete, `SmartViewListView.swift:121,132`); the iPad sidebar uses **context menus** (`ContentView.swift:421`). Same operations, different gesture. |
| Matrix card swipe | ✅ native `.swipeActions` (`TaskListRow.swift:36-56`) | ⚠️ hand-rolled `SwipeRevealRow` on the iOS 26 floor; native `.swipeActions` from iOS 27 (`QuadrantCell.swift:110-113`) | Right = Complete; left = Snooze (1 hour), Delete, and Mark urgent while escalating. |
| Drag a card between quadrants | ❌ (use ⋯ › Move to) | ✅ `.draggable` + `.dropDestination` (`QuadrantCell.swift:65,139`, `SwipeRevealRow.swift`) | The iPhone list has no drop targets; an opened iPhone Duo gets the grid and drag. |
| Smart View editor | ✅ | ✅ | Shared `SmartViewEditorView` sheet. |
| Filtered task list | ✅ | ✅ | Shared `FilteredTaskListView` (pushed on iPhone, detail column on iPad). |
| Saved | ✅ Browse → Saved | ✅ sidebar Library › Saved | Shared `SavedListView` + `SavedEditorView`; "Move to Saved" from the shared `TaskRowMenu`. |
| Archive | ✅ | ✅ | Shared `ArchiveListView`. |
| Trash | ✅ Settings › Trash | ✅ Settings › Trash | Shared `TrashListView` (30 days, `TrashRetention.days`); Undo window hosted on the shared root (`ContentView.swift:42-45`, `206-215`). |
| Escalation (Escalating marker, Mark urgent) | ✅ | ✅ | Shared `TaskCardView` marker and `TaskRowMenu` action; swipe per the row above. Setting in Settings › Appearance. |
| Task editor | ⚠️ half-height quick edit (medium/large detents) | ⚠️ page-sized sheet | Shared `TaskEditorView`; the presenter's size class decides, not the idiom (`TaskEditorView.swift:129-143`). |
| Editor discard prompt | ✅ | ✅ | "Discard changes?" alert only when there are edits (`TaskEditorView.swift:215-222`). |
| ⌘S saves in the editor | ✅ with a hardware keyboard | ✅ | `TaskEditorView.swift:205`. |
| Dependency picker | ✅ | ✅ | Shared `DependencyPickerView`. |
| Dashboard / analytics | ✅ | ✅ | Shared `DashboardView`. |
| Settings | ✅ | ✅ | Shared `SettingsView`. |
| Onboarding | ✅ | ✅ | Shared `OnboardingView`. |
| Sync history | ✅ (with its own pull-to-refresh, `SyncHistoryView.swift:32`) | ✅ (same) | This `.refreshable` reloads history rows — shared by both idioms. |
| Help "Field Guide" | ✅ | ✅ | Shared `HelpView`. |
| ↳ Keyboard-shortcuts section | ❌ hidden on a compact presenter | ✅ shown | `showsKeyboardShortcuts` (`HelpView.swift:411-420`): shown on Mac and on any regular-width presenter (iPad, an opened iPhone Duo), hidden on a compact one. The shortcuts stay bound there, so an iPhone with a hardware keyboard has working shortcuts and no list. |
| Deep links / Spotlight / Quick Actions | ✅ | ✅ | Routed in `ContentView.handleDeepLink`; `navigate(to:)` maps each destination to a tab (iPhone) or sidebar selection (iPad). |
| Cross-account switch guard | ✅ | ✅ | Hosted on the shared root (`ContentView.swift:111`). |

---

## 3. Differences, classified

### 3a. Intentional, by-design adaptations (NOT parity gaps)

These are correct platform behavior — closing them would be a regression, not a fix.

1. **Matrix layout** — vertical scrolling sections (iPhone) vs 2×2 grid (iPad). The grid needs
   width; the iPhone doesn't have it.
2. **Navigation shell** — tabs vs sidebar/split view.
3. **Chrome placement** — per-tab toolbars (iPhone) vs persistent sidebar toolbar (iPad).
4. **Browse gestures** — swipe actions (iPhone, where swipe is the idiom) vs context menus
   (iPad sidebar, where rows persist).
5. **Help keyboard-shortcuts section** — hidden on a compact presenter (no hardware keyboard expected).
6. **Drag between quadrants**: grid only; the iPhone list moves a task through ⋯ › Move to.
7. **Editor presentation**: half-height quick edit on a compact presenter, page sheet on a regular one.

### 3b. Genuine parity gaps

1. ~~**Pull-to-refresh on the Matrix — iPad missing.**~~ **CLOSED 2026-06-18** (see §4).
2. ~~**Sync-status visibility asymmetry — iPhone Matrix-tab-only.**~~ **CLOSED 2026-06-18.**
   The shared `syncStatusChip` helper (`MatrixView.swift`) now appears on the iPhone Matrix,
   Browse, and Dashboard tabs, matching iPad's always-visible sidebar chip. The Dashboard chip
   is gated to the compact size class so the shared `DashboardView` shows no second chip in the
   iPad detail column. Design: `docs/superpowers/specs/2026-06-18-iphone-sync-chip-parity-design.md`.
3. **Help shortcuts list on a compact presenter with a hardware keyboard: open.** An iPhone
   with a keyboard, or a narrow iPad window, has every shortcut bound but no list in the Field
   Guide (`HelpView.showsKeyboardShortcuts`). Behavior unchanged for now; tracked as a follow-up.

> Apart from 3b.3, everything in the matrix is ✅/✅ or an intentional ⚠️ adaptation.

---

## 4. Pull-to-refresh (resolved)

**Status: closed 2026-06-18.** Both idioms now trigger `SyncCoordinator.syncNow()` from a
pull-to-refresh gesture on the Matrix, in addition to the shared "Sync Now" button.

`SyncCoordinator.syncNow()` (the manual-sync entry, `SyncCoordinator.swift:121`) now has these
UI triggers:

| Trigger | Location | iPhone | iPad |
|---|---|:---:|:---:|
| Pull-to-refresh on the Matrix | iPhone `MatrixView.swift:62`; iPad `MatrixGridView.swift:84` | ✅ | ✅ |
| "Sync Now" button | `SettingsView.swift:118` (shared) | ✅ | ✅ |

### The fix

`MatrixGridContent` uses a `ScrollView` + `LazyVGrid` (not a `List`), and `.refreshable`
attaches to a `ScrollView` the same way. Two changes:

1. Added `@Environment(SyncCoordinator.self) private var sync` to `MatrixGridContent`.
2. Attached `.refreshable { await sync.syncNow() }` to the `ScrollView`.

No plumbing was required — `SyncCoordinator` is wired into the environment in `GSDApp.swift`
and, living in the App module, needed no extra `import`. Verified by a clean `xcodebuild` on
both the iPad Pro 13-inch and iPhone 17 Pro simulators.

### Context: this was never a sync outage

Even before the fix, iPad sync was **not broken**. The `SyncCoordinator` drives sync
automatically on a cadence timer, on network-path changes, on `scenePhase` foregrounding, and
on a debounced post-mutation push — all idiom-independent — and iPad users could already tap
**Settings → Sync Now**. The fix restored only the _gesture-based manual_ trigger from the
task surface itself, bringing it to parity with iPhone.

---

## 5. Where each surface lives (file index)

| Surface | iPhone view | iPad view |
|---|---|---|
| Matrix | `App/Matrix/MatrixView.swift` (`MatrixListContent`) | `App/Matrix/MatrixGridView.swift` (`MatrixGridContent`) |
| Root / navigation | `ContentView.rootContent` → `TabView` | `ContentView` → `RegularRootView` |
| Browse / Smart Views | `App/Browse/SmartViewListView.swift` | sidebar in `RegularRootView` (`SmartViewRow` reused) |
| Saved | `App/Saved/SavedListView.swift` (Browse → Saved) | same view, sidebar Library › Saved |
| Filtered list, Archive, Trash, Dashboard, Settings, Editor, Help, Onboarding | _shared — same view on both idioms_ | |

---

_Last reviewed: 2026-11-03. Regenerate by re-auditing `App/` for `horizontalSizeClass`,
`compactPresenter`, `refreshable`, `swipeActions`, `draggable`, and `SyncCoordinator.self`. Mac
Catalyst has no column yet._
