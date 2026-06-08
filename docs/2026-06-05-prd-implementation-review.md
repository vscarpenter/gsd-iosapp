# GSD iOS — PRD Implementation Review

- **Date:** 2026-06-05
- **Authority compared against:** `spec.md` (root product spec), `PRODUCT.md`
- **Method:** Source-tree audit of `GSDKit/`, `App/`, `Widgets/`, `ShareExtension/`, `project.yml`, and entitlements, cross-referenced with the per-phase specs/plans and project memory. Shipped-and-live-gated phases (sync, notifications, core matrix) taken as evidenced by their gate notes; remaining-work claims verified directly against source.

---

## Part 1 — What's implemented (by spec section)

Phases 0–6a + 6d are complete and merged; TestFlight prep (icon, launch screen, privacy manifest) shipped. 441 tests green via `swift test`.

### Data & core logic (§5, §6.1–6.10)
- **Data model (§5):** `Task` + embedded `Subtask`/`TimeEntry`, `NotificationSettings`, `ArchiveSettings`, `SmartView`, `AppPreferences`, `FilterCriteria`, quadrant derivation. GRDB store with versioned migrations v1–v5, JSON columns for embedded collections. Device-local field semantics honored.
- **Matrix (§6.1):** iPhone stacked quadrant sections + iPad 2×2 grid with drag-to-reclassify; leading/trailing swipe, context menu, card indicators (tags, subtask progress, dependency badges, due date, recurrence glyph, live timer, snooze remaining).
- **Capture + parser (§6.2):** full `!`/`!!`/`*`/`#tag`/URL grammar with `URLSanitizer`; live classification preview; quadrant override.
- **Editor (§6.3):** all fields; iPad inspector / iPhone sheet; quadrant picker, date presets, token tags, reorderable subtasks, dependency picker with live cycle rejection, reminder, estimate.
- **Completion + confetti (§6.4):** reduce-motion-gated `ConfettiView`, success haptic.
- **Recurrence (§6.5):** `RecurrenceEngine` spawn-on-complete, month-end clamping, single-level lineage.
- **Subtasks (§6.6), Snooze (§6.7), Dependencies + BFS cycle prevention (§6.8), Time tracking (§6.9), Due-date presets (§6.10):** all implemented with unit tests.

### Organization & insight (§6.12–6.17)
- **Archive (§6.12):** manual archive/restore/delete + auto-archive sweep (launch + background refresh).
- **Smart Views (§6.13):** 9 built-ins + custom CRUD + criteria editor + pinning (≤5).
- **Search + ⌘K Command Palette (§6.14):** `.searchable` + `CommandPaletteView`.
- **Analytics Dashboard (§6.15):** `AnalyticsEngine` (all metrics) + Swift Charts UI.
- **Import/Export + Onboarding (§6.16):** lenient JSON import (replace/merge + id-remap), export via ShareLink, type-RESET erase, 5-page onboarding.
- **Settings (§6.17):** Appearance, Notifications, Cloud Sync, Archive, Data & Storage, About.

### Notifications (§9) — Phase 4
Local scheduling at write time, contextual permission flow, quiet hours, badges, `BGAppRefreshTask` sweep + opportunistic sync.

### Sync & backend (§7, §8) — Phase 5 (5a–5d), live-gated on device
Hand-built PocketBase REST + SSE client; OAuth2-PKCE via `ASWebAuthenticationSession`; Keychain tokens; pure `SyncEngine` actor (pull/push/LWW/deletion-reconcile/device-local preservation); persisted sync queue with retry/backoff; realtime SSE + 2-min cadence + `NWPathMonitor`; sync history table + screen + health monitoring.

### Native surfaces — partial
- **Widgets (§10.1):** Today's Focus widget (`.systemSmall` + `.systemMedium`) via `GSDSnapshot` App-Group contract. ✅
- **Share Extension (§10.3):** full inbound URL/text capture → outbox → app drain. ✅

---

## Part 2 — What's left to implement

> Grouped by *kind*, not flattened — the buckets mean different things for planning.

### A. Owner-deferred per PRD (descoped for first TestFlight, not oversights)
These are in the spec but the owner explicitly chose to skip them to reach TestFlight (see project memory).

- **Phase 6b — additional widget families (§10.1):**
  - *Quadrant Overview* widget (2×2 live counts, small/medium).
  - *Upcoming Deadlines* widget (medium/large).
  - *Today's Focus* `.systemLarge` family (only small/medium ship today).
  - **Lock Screen accessory widgets** (compact count + tap-to-capture).
- **Phase 6c — App Intents / Siri / Shortcuts / Spotlight (§10.2):** *entirely unbuilt* — no `AppIntent`, `AppShortcutsProvider`, `AppEntity`, or `CoreSpotlight`/`CSSearchableItem` anywhere. This is the largest single missing capability. Includes Create/Complete/Open/Query intents, zero-setup Siri phrases, and Spotlight task indexing.

### B. Genuinely unbuilt within shipped phases
Feature items the spec lists for phases already considered "done."

- **Outbound task Share (§6.18):** No per-task `ShareLink`/share sheet on the card, swipe overflow, or editor. (`ShareLink` exists only for JSON export in `DataStorageView`.) Spec wants a formatted plain-text share + optional `gsd://task/<id>` link.
- **Duplicate task action (§6.1 context menu):** card context menu has Complete, Edit, Start/Stop Timer, Snooze, Move-to-quadrant, Delete — but **no Duplicate** and **no Share**.
- **Bulk actions on the Matrix (§6.11):** multi-select bulk bar exists on filtered Smart-View lists + Archive, but **not on the matrix** (explicitly deferred in Phase 3b).
- **Deep-link routes (§4.3):** only `gsd://focus` is parsed. Missing: open a **specific task**, a **specific quadrant**, the **capture field**, and a **specific smart view** — needed for widget taps, Spotlight results, notifications, and the §6.18 share link.
- **Full iPad keyboard shortcut set (§6.14 / §10.4):** only **⌘K**. Missing ⌘N (new), ⌘F (search), ⌘1–4 (jump to quadrant), etc.
- **State restoration (§4.3):** tab/sidebar selection is in-memory (`@Observable`), not `@SceneStorage`/`@AppStorage` — last-selected surface and scroll position are **not restored across cold launch**. *(Verify whether intentional.)*

### C. App Store blockers (gate submission — §8, §13)
- **Sign in with Apple (§8.1, §13, Guideline 4.8):** **not started** — no `com.apple.developer.applesignin` entitlement, no UI. Because the app offers third-party social login, Apple sign-in is *required* for approval. Hard blocker.
- **GitHub provider in UI (§6.17, §8.1):** auth layer is provider-agnostic but Settings only wires the **Google** button. GitHub (configured on backend) is not surfaced; Apple not surfaced.
- **Cross-provider identity (§8.4):** resolved in principle to email-keyed convergence; revisit once Apple sign-in lands (Apple "Hide My Email" relay is the documented edge case).

### D. Human-gated / non-code (App Store readiness — Phase 7, §13)
These are not engineering "implement" tasks — they need a person, Xcode, or App Store Connect.

- **Archive (Release) → upload** to App Store Connect (Xcode Organizer / Transporter).
- **Privacy nutrition labels** filled in App Store Connect (accurate to sync/diagnostics behavior).
- **Privacy policy URL** covering optional backend + any opt-in diagnostics.
- **Screenshots** (iPhone + iPad), description, keywords.
- **Manual accessibility validation pass:** VoiceOver + Dynamic Type at AX sizes + Reduce Motion across all surfaces (requires a real device + a human; still owed).
- **On-device behavioral walkthroughs** simctl can't reach (reminder delivery, quiet-hours-at-delivery, badge, BGAppRefresh firing, recurrence-spawn/live-timer/snooze-remaining with data).

### E. Minor / lower-priority polish
- **Keychain access group (§8.3):** token is a plain Keychain item with no access group, so extensions can't do authenticated reads (acceptable today; needed if an extension ever needs network sync).
- **Quick Actions (§10.4):** Home-Screen long-press "New Task" / "Today's Focus" — not present (no `UIApplicationShortcutItems` in `project.yml`, none dynamic).
- **Handoff / `NSUserActivity` (§10.4):** not implemented (called out as "optional but cheap" in the spec).

---

## Part 3 — Explicitly out of scope (spec §2 anti-goals — not gaps)
Listed so they aren't misread as missing work:
- No Apple Watch app.
- No Live Activities / Dynamic Island.
- No macOS-native / Mac Catalyst target.
- No changes to the existing MCP server (it already works against the shared backend).
- No new backend features; no real-time collaborative / shared task lists.

---

## Suggested priority order
1. **Sign in with Apple (C)** — the only thing that *blocks* App Store submission once the human Phase-7 steps are underway.
2. **Human-gated Phase 7 items (D)** — archive/upload, labels, policy, screenshots, accessibility pass — these get a build into testers' hands.
3. **Quick wins in B** — outbound task Share §6.18 + Duplicate action + expanded deep-link routes + full keyboard set (mostly small, high user-visible value).
4. **Bulk-on-matrix (B)** — moderate.
5. **Phase 6c App Intents/Siri/Spotlight (A)** — largest net-new surface; high value, owner-deferred.
6. **Phase 6b extra widgets + Lock Screen (A)** — owner-deferred.
