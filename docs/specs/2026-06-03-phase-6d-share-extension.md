# Phase 6d — Share Extension

**Status:** SPEC — awaiting user review (brainstorming gate)
**Date:** 2026-06-03
**Branch:** `phase-6d-share-extension`
**Depends on:** Phases 0–5 + 6a (App Group, `GSDSnapshot` contract module, `TaskStore.onTasksChanged` widget hook)

---

## 1. Goal

Let users capture a task into GSD from any app's **Share Sheet** (a shared URL or text), via a small
compose sheet, without opening the app. Replaces the web PWA share-target (product spec §10.3).

One sentence: *the share extension drops a durable "pending capture" file in the App Group; the app
materializes it through the existing `TaskStore.create` path on next launch/foreground.*

## 2. Scope

**In:**
- New app-extension target `GSDShareExtension` (compose UI: title · quadrant · tags · Add/Cancel).
- The app↔extension contract in `GSDSnapshot`: `SharedCapture`, `ShareOutboxStore`,
  `SharedCaptureBuilder`, and a testable `ShareInbox` drain loop.
- App-side wiring: drain the outbox on launch + foreground through `TaskStore.create`.

**Out (deferred / YAGNI):**
- Images/files (spec §10.3 is URLs + text only).
- Instant cross-process materialization (the sync engine only runs in the app; the task syncs on
  next app run regardless of write path — see §12).
- Extracting inline URLs from shared *text* (text → title as-is; only explicit shared URLs are
  sanitized into the description).
- A dedicated `GSDShareKit` module (the share contract reuses `GSDSnapshot`; see §12).

## 3. Architecture

The extension is a **separate process** and is **GRDB-free** (matching the 6a principle: the app is
the sole GRDB writer). It hands off to the app via an App-Group "outbox" of one-file-per-capture.

```
Other app's Share Sheet → GSDShareExtension (separate process, GRDB-free)
   ShareComposeView: title (prefilled) · quadrant (default Q4) · tags · Add
                          │  Add
                          ▼
   ShareOutboxStore.write(SharedCapture)  →  <AppGroup>/share-outbox/<id>.json  (atomic)
                          ▼  extensionContext.completeRequest → sheet dismisses
   ───────────────────── process boundary ─────────────────────
   App launch (.task) AND foreground (scenePhase == .active):
   ShareInbox.drain(create:)            [single-flight]
     → ShareOutboxStore.pending()       (decode all files, sorted by capturedAt; skip+delete corrupt)
     → SharedCaptureBuilder.task(...)   (sanitize URLs, clamp, build a VALID Task)
     → create(task)  == TaskStore.create  (the ONE existing write path)
          → upsert + enqueue(.create) + reminders.schedule
          → ValueObservation fires → UI updates; onTasksChanged → widget refresh (6a)
     → ShareOutboxStore.remove(id)      (only after create succeeds)
     → next sync pushes the task to the server
```

## 4. Components

### 4.1 `GSDSnapshot` — the share contract (GRDB-free, → GSDModel)

`SharedCapture` (`GSDKit/Sources/GSDSnapshot/SharedCapture.swift`):

```swift
import Foundation

/// The cross-process payload the Share Extension writes and the app ingests (spec §3).
public struct SharedCapture: Codable, Sendable, Equatable {
    public var title: String          // user-edited; clamped on ingest
    public var urls: [String]         // raw shared URLs; sanitized on ingest
    public var urgent: Bool
    public var important: Bool
    public var tags: [String]         // split from the comma field; normalized on ingest
    public var capturedAt: Date
    public init(title: String, urls: [String], urgent: Bool, important: Bool,
                tags: [String], capturedAt: Date) {
        self.title = title; self.urls = urls; self.urgent = urgent
        self.important = important; self.tags = tags; self.capturedAt = capturedAt
    }
}
```

`ShareOutboxStore` (`GSDKit/Sources/GSDSnapshot/ShareOutboxStore.swift`) — App-Group directory IO:

```swift
public struct ShareOutboxStore: Sendable {
    public static let directoryName = "share-outbox"
    public init(appGroupID: String = AppGroup.id, fileManager: FileManager = .default)
    public init(directoryURL: URL?)                         // test seam
    public func write(_ capture: SharedCapture) throws      // atomic; unique filename; creates dir
    public func pending() -> [(id: String, capture: SharedCapture)]  // sorted by capturedAt; skips+DELETES corrupt
    public func remove(id: String)                          // delete one file after ingest
}
public enum ShareOutboxError: Error { case noContainer }
```

`SharedCaptureBuilder` (`GSDKit/Sources/GSDSnapshot/SharedCaptureBuilder.swift`) — **pure**, builds a
guaranteed-valid `Task`:

```swift
public enum SharedCaptureBuilder {
    public static func task(from capture: SharedCapture, id: String, now: Date) -> Task
    // - sanitize each url via URLSanitizer; keep valid; join into description (clamp 600)
    // - clamp title to FieldLimits.titleRange (1...80); empty → "Review link below"
    // - normalize tags: lowercased, deduped, ≤20, each ≤30 chars
    // - urgent/important straight from the capture
    // - result always passes TaskValidator.validate (tested invariant)
}
```

`ShareInbox` (`GSDKit/Sources/GSDSnapshot/ShareInbox.swift`) — the **testable, single-flight** drain
loop (GRDB-free; the app injects `TaskStore.create`):

```swift
import Foundation
import GSDModel

@MainActor
public final class ShareInbox {
    private let store: ShareOutboxStore
    private let now: () -> Date
    private let newID: () -> String
    private var isDraining = false

    public init(store: ShareOutboxStore,
                now: @escaping () -> Date = { Date() },
                newID: @escaping () -> String = { IDGenerator.generate(size: IDGenerator.Size.task) }) {
        self.store = store; self.now = now; self.newID = newID
    }

    /// Single-flight: launch + foreground fire near-simultaneously at cold start; the guard is set
    /// synchronously (no await between check and set) so an overlapping call returns immediately —
    /// without it, two drains both read the same file before either removes it → duplicate task.
    public func drain(create: (Task) async throws -> Void) async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        for item in store.pending() {
            let task = SharedCaptureBuilder.task(from: item.capture, id: newID(), now: now())
            do {
                try await create(task)
                store.remove(id: item.id)            // only after success
            } catch {
                continue                              // transient failure → keep file, retry next drain
            }
        }
    }
}
```

### 4.2 `GSDShareExtension` — the extension target

- `type: app-extension`, `NSExtensionPointIdentifier = com.apple.share-services`, bundle id
  `dev.vinny.gsd.share`, App-Group entitlement, version pinned to the app (the 6a lesson). Sources in
  `ShareExtension/`. Depends on `GSDModel` (Quadrant) + `GSDSnapshot`. Embedded in the app.
- **`NSExtensionActivationRule`** (make-or-break — governs whether GSD appears in the share sheet, and
  gates URL vs text independently): support **web URL** (max 1) **and plain text**.
- `ShareViewController` (principal class): reads the shared item from `NSItemProvider`
  (`UTType.url` / `UTType.plainText`), prefills the title (page title/text, or the URL string), then
  hosts a SwiftUI `ShareComposeView` via `UIHostingController`.
- `ShareComposeView`: editable title; quadrant picker defaulting to **Eliminate/Q4**; comma-separated
  tags field; the captured URL(s) shown read-only; **Add** / **Cancel**.
  - **Add:** build `SharedCapture` → `ShareOutboxStore.write` → `extensionContext.completeRequest`.
    On write failure (no container) → inline "Couldn't save to GSD" alert; do not dismiss.
  - **Cancel:** `extensionContext.cancelRequest`.
- The extension never opens GRDB and never schedules notifications or does networking.

### 4.3 App wiring

Construct a `ShareInbox` in `GSDApp` (like the 6a `WidgetSnapshotRefresher`); call
`await shareInbox.drain { try await store.create($0) }` in the root `.task` (launch) and on
`scenePhase == .active` (foreground). Trivial glue; the substance is in the tested `ShareInbox`.

### 4.4 project.yml

- New `GSDShareExtension` target (bundle id `dev.vinny.gsd.share`, NSExtension share-services config,
  `ShareExtension/GSDShareExtension.entitlements` with the App Group, version vars matching the app,
  deps GSDModel + GSDSnapshot).
- Add `{ target: GSDShareExtension, embed: true }` to the `GSD` target's dependencies.
- (No `Package.swift` change — the new types are additional files in the existing `GSDSnapshot` target.)

## 5. Capture & build rules (product spec §10.3)

- **Default quadrant Eliminate/Q4** (`urgent=false, important=false`); the picker overrides.
- **Title:** prefilled from the shared page title/text (or the URL); editable; **clamped to 80** —
  note the *web* clamps to 300, but `FieldLimits.titleRange` is `1...80`, so the native clamp is 80.
  Empty → `"Review link below"` (matches `CaptureParser`).
- **URLs:** `URLSanitizer` (http/https only, no embedded creds, ≤2048) → joined into the description
  (clamp 600).
- **Tags:** comma field → split, lowercased, deduped, ≤20 × ≤30 chars.

## 6. Outbox semantics & duplicate avoidance

- **Directory of one-file-per-capture** (not one appended array): the extension's write and the app's
  drain never race on the same file, and multiple shares before the app opens each survive.
- **Single-flight drain (§4.1):** prevents the launch+foreground concurrent-drain duplicate.
- **Corrupt file:** `pending()` skips and deletes it (unrecoverable; prevents accumulation).
- **Success:** file removed only *after* `create` succeeds.
- **Transient `create` failure:** file kept, retried next drain. The builder guarantees a valid Task,
  so validation never fails — only transient DB errors keep a file, and they self-heal.
- **Accepted narrow risk:** a crash *between* `create` and `remove` re-ingests that one capture as a
  duplicate. Documented; an idempotency key is deferred (YAGNI).

## 7. Error handling

- **Extension:** item-extraction failure → present with an empty title (user types). `write` throws
  (no container) → inline alert, don't dismiss. Cancel → `cancelRequest`.
- **App:** corrupt files purged by the store; transient create errors keep the file; builder
  guarantees validity (no poison); single-flight prevents concurrent dup.
- **Reminders:** scheduled by the app on ingest via `create`; never by the extension.

## 8. Testing

**`swift test` (GSDSnapshotTests):**
- `SharedCapture` Codable round-trip.
- `ShareOutboxStore`: write→pending→remove via injected temp dir; multiple captures; corrupt file
  skipped **and deleted**; `pending()` sorted by `capturedAt`; `write` throws without a container.
- `SharedCaptureBuilder`: title clamp + empty→fallback; URL sanitize (valid kept / invalid dropped)
  into description; description clamp 600; tag normalize/dedupe/clamp; quadrant→flags; **always-valid
  invariant** (`TaskValidator.validate` never throws on builder output, incl. adversarial input).
- `ShareInbox`: success removes the file; transient `create` throw keeps the file; corrupt-skip;
  **single-flight** — an overlapping `drain` during a suspended `create` does not double-create
  (fake `create` gated on a continuation; assert one create per file).

**Build + simctl smoke (iPhone 17 Pro + iPad Pro 13" M5):** extension appears in the share sheet;
**share a URL from Safari** and **share text from Notes** (activation rule gates these independently);
compose sheet renders; Add writes an outbox file; opening the app materializes the task, refreshes the
widget, and enqueues sync.

## 9. Build vs. portal boundary

- **Sim-verifiable now:** target builds + embeds; share sheet, compose UI, outbox write, and app drain
  all work in the simulator (the iOS share sheet is available in-sim).
- **Device/portal (live-gate, user):** register App ID `dev.vinny.gsd.share` + App-Group capability +
  provisioning. Share from a real app → confirm the task appears and syncs to web; confirm sign-in /
  sync unaffected. `DEVELOPMENT_TEAM=52HVJ3VDSM` stays committed.

## 10. Decisions & rejected alternatives

- **Outbox handoff (A) over direct GRDB write (B):** the extension stays GRDB-free; reuses the single
  tested `TaskStore.create` path (UI + widget + reminders + sync for free); avoids cross-process sqlite
  locking (the DB is a non-WAL `DatabaseQueue`) and the fact that `ValueObservation` can't see another
  process's writes. B buys nothing because the server push needs the app to run regardless.
- **`ShareInbox` in `GSDSnapshot`, not App glue:** the drain loop has real branching (corrupt-skip,
  keep-on-failure, single-flight) — it must be unit-tested, unlike the trivial 6a refresher. A
  closure-parameterized type stays GRDB-free and testable with a fake `create`.
- **Reuse `GSDSnapshot`** as the GRDB-free app↔extension contract module (already holds the widget
  snapshot + deep-link) rather than a new `GSDShareKit`.

## 11. Risks / watch-outs

- `NSExtensionActivationRule` mis-set → GSD silently absent from the share sheet (or present for URL
  but not text). The §8 smoke test exercises both paths.
- Extension signing/provisioning is the XcodeGen/portal time-sink; most is sim-verifiable first.
- Concurrent-drain duplicate — mitigated by single-flight (§4.1) and covered by a test (§8).
