# Feature Parity — iPhone vs iPad

_A snapshot of where the two device idioms agree, where they diverge by design, and where
they diverge by omission. Use this to plan parity work._

> Source of truth: the App layer (`App/`). The package layers (`GSDKit/`) are device-agnostic
> and shared verbatim, so all parity differences live in SwiftUI surfaces, not in logic.

---

## TL;DR

- **One fork, not many.** The whole iPhone↔iPad split is decided by a single
  `horizontalSizeClass` check in `ContentView.swift:167`. Compact → a 4-tab `TabView`;
  regular → a `NavigationSplitView` (`RegularRootView`). There is no scattering of `if iPad`
  conditionals — the divergence is _which root container hosts the shared surfaces_.
- **Almost everything is shared.** The editor, dashboard, settings, filtered lists, archive,
  command palette, capture parsing, onboarding, and help are the same views on both idioms.
- **Pull-to-refresh — CLOSED (2026-06-18).** This was the one user-facing _capability_ gap:
  iPhone's Matrix could pull-to-sync, iPad's could not. The iPad grid now injects
  `SyncCoordinator` and carries `.refreshable { await sync.syncNow() }` like the iPhone list.
  History and the fix are in [§4 Pull-to-refresh](#4-pull-to-refresh-resolved).

---

## 1. Navigation architecture (the root fork)

| | iPhone (compact) | iPad (regular) |
|---|---|---|
| Root container | `TabView` — `ContentView.swift:168` | `NavigationSplitView` — `RegularRootView`, `ContentView.swift:249` |
| Top-level destinations | 4 tabs: **Matrix · Browse · Dashboard · Settings** | Sidebar: **Matrix · Dashboard · Smart Views · Library (Archive, Settings)** |
| Chrome (search, sync status) | Per-surface toolbar (each tab supplies its own) | Persistent sidebar toolbar — visible regardless of detail selection (`ContentView.swift:276-286`) |
| Smart Views | Dedicated **Browse** tab (`SmartViewListView`) | Folded into the always-visible sidebar (`SmartViewRow` reused) |
| Archive / Settings reach | Browse → Archive link; Settings tab | Sidebar **Library** section |

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
| Multi-select + Bulk actions | ✅ | ✅ | `EditButton` + `BulkActionBar` on both (`MatrixView.swift:72,84`, `MatrixGridView.swift:70,72`). |
| Confetti on completion | ✅ | ✅ | `ConfettiView` wraps both Matrix roots. |
| ⌘1–⌘4 quadrant focus / deep link | ✅ | ✅ | `consumeQuadrantFocus` in both Matrix contents. |
| **Pull-to-refresh → sync** | ✅ `MatrixView.swift:61` | ✅ `MatrixGridView.swift:63` _(closed 2026-06-18)_ | Was iPad-absent; grid now injects `SyncCoordinator` + `.refreshable`. See §4. |
| Manual "Sync Now" (Settings) | ✅ | ✅ | Shared `SettingsView.swift:83-88` → `session.syncNow()`. iPad's only manual sync entry point. |
| Automatic sync (timer, network, scenePhase, post-mutation) | ✅ | ✅ | Driven by `SyncCoordinator`, idiom-independent. iPad still syncs continuously. |
| Sync status chip | ⚠️ Matrix tab only (`MatrixView.swift:74`) | ⚠️ persistent sidebar (`ContentView.swift:283`) | On iPhone the chip is visible only from the Matrix tab; on iPad it's always visible in the sidebar. Tapping → Settings on both. |
| Command palette (⌘K / search) | ✅ per-surface button (`paletteButton`) | ✅ sidebar button (`ContentView.swift:278`) | Hardware ⌘K works on both via hidden buttons (`ContentView.swift:104`); Mac uses the menu bar. |
| Browse / Smart Views list | ✅ `SmartViewListView` (tab) | ⚠️ sidebar list | iPhone uses **swipe actions** (pin/edit/delete); iPad uses **context menus** (`ContentView.swift:332`). Same operations, different gesture. |
| Smart View editor | ✅ | ✅ | Shared `SmartViewEditorView` sheet. |
| Filtered task list | ✅ | ✅ | Shared `FilteredTaskListView` (pushed on iPhone, detail column on iPad). |
| Archive | ✅ | ✅ | Shared `ArchiveListView`. |
| Task editor | ✅ | ✅ | Shared `TaskEditorView` sheet. |
| Dependency picker | ✅ | ✅ | Shared `DependencyPickerView`. |
| Dashboard / analytics | ✅ | ✅ | Shared `DashboardView`. |
| Settings | ✅ | ✅ | Shared `SettingsView`. |
| Onboarding | ✅ | ✅ | Shared `OnboardingView`. |
| Sync history | ✅ (with its own pull-to-refresh, `SyncHistoryView.swift:32`) | ✅ (same) | This `.refreshable` reloads history rows — shared by both idioms. |
| Help "Field Guide" | ✅ | ✅ | Shared `HelpView`. |
| ↳ Keyboard-shortcuts section | ❌ hidden | ✅ shown | `showsKeyboardShortcuts` (`HelpView.swift:285-290`): shown on iPad + Mac (hardware keyboard realistic), hidden on iPhone. Intentional. |
| Deep links / Spotlight / Quick Actions | ✅ | ✅ | Routed in `ContentView.handleDeepLink`; `navigate(to:)` maps each destination to a tab (iPhone) or sidebar selection (iPad). |
| Cross-account switch guard | ✅ | ✅ | Hosted on the shared root (`ContentView.swift:73`). |

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
5. **Help keyboard-shortcuts section** — hidden on iPhone (no hardware keyboard expected).

### 3b. Genuine parity gaps

1. ~~**Pull-to-refresh on the Matrix — iPad missing.**~~ **CLOSED 2026-06-18** (see §4).
2. **Sync-status visibility asymmetry (minor — still open).** On iPhone the `SyncStatusChip` lives only on
   the Matrix tab — switch to Browse/Dashboard/Settings and the live status disappears. On iPad
   it's always visible in the sidebar. Not a missing feature, but an inconsistency worth a
   decision: should the iPhone surface sync status more globally?

> Everything else in the matrix is either ✅/✅ or an intentional ⚠️ adaptation.

---

## 4. Pull-to-refresh (resolved)

**Status: closed 2026-06-18.** Both idioms now trigger `SyncCoordinator.syncNow()` from a
pull-to-refresh gesture on the Matrix, in addition to the shared "Sync Now" button.

`SyncCoordinator.syncNow()` (the manual-sync entry, `SyncCoordinator.swift:96`) now has these
UI triggers:

| Trigger | Location | iPhone | iPad |
|---|---|:---:|:---:|
| Pull-to-refresh on the Matrix | iPhone `MatrixView.swift:61`; iPad `MatrixGridView.swift:63` | ✅ | ✅ |
| "Sync Now" button | `SettingsView.swift:83` (shared) | ✅ | ✅ |

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
| Filtered list, Archive, Dashboard, Settings, Editor, Help, Onboarding | _shared — same view on both idioms_ | |

---

_Last reviewed: 2026-06-18. Regenerate by re-auditing `App/` for `horizontalSizeClass`,
`refreshable`, and `SyncCoordinator.self`._
