# Shared-Link Title Fetch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a link is shared to GSD without a title (the Mac/URL-only case), fetch the page's real title and upgrade the task's offline-derived title.

**Architecture:** A pure HTML→title parser in `GSDModel` (unit-tested) + a thin app-layer `URLSession` fetcher. The share drain creates the task immediately with the offline-derived title; an app-layer enricher then fetches the real title in the background and saves it, gated by a Settings toggle. iOS already gets the real title from Safari and is skipped automatically.

**Tech Stack:** Swift 6, SwiftUI, GRDB (via `TaskStore`), `URLSession`, App-Group `UserDefaults`, swift-testing.

## Global Constraints

- Swift language version 6.0; Swift 6 strict concurrency on — expect `Sendable`/actor-isolation diagnostics.
- `GSDModel` has ZERO dependencies (no GRDB import); `PageTitleParser` must be Foundation-only.
- Two `Task` types: `GSDModel.Task` (domain) vs `_Concurrency.Task` (concurrency). In the app, write the concurrency one as `_Concurrency.Task`.
- Title length cap is `FieldLimits.titleRange.upperBound` (80); clamp any title to it.
- App layer has no unit-test target: app-layer glue is verified by build + Catalyst build; pure logic is verified by `cd GSDKit && swift test`.
- No `project.yml`/entitlement change: iOS needs no entitlement for outbound HTTP; the Catalyst sandbox already has `com.apple.security.network.client`.
- Setting key default is `true` (ON).

---

### Task 1: `PageTitleParser` (pure HTML→title, GSDModel)

**Files:**
- Create: `GSDKit/Sources/GSDModel/PageTitleParser.swift`
- Test: `GSDKit/Tests/GSDModelTests/PageTitleParserTests.swift`

**Interfaces:**
- Produces: `public enum PageTitleParser { public static func parse(html: String) -> String? }` — returns the page title (prefers `og:title`, falls back to `<title>`), decoded + whitespace-collapsed + trimmed; `nil` if none.

- [ ] **Step 1: Write the failing tests**

```swift
// GSDKit/Tests/GSDModelTests/PageTitleParserTests.swift
import Testing
@testable import GSDModel

struct PageTitleParserTests {
    @Test func readsTitleElement() {
        let html = "<html><head><title>Hello World</title></head><body>x</body></html>"
        #expect(PageTitleParser.parse(html: html) == "Hello World")
    }

    @Test func prefersOgTitleOverTitleElement() {
        let html = """
        <head><meta property="og:title" content="OG Headline">
        <title>Tab Title</title></head>
        """
        #expect(PageTitleParser.parse(html: html) == "OG Headline")
    }

    @Test func handlesOgTitleWithContentBeforeProperty() {
        let html = #"<meta content="Reversed Attrs" property="og:title" />"#
        #expect(PageTitleParser.parse(html: html) == "Reversed Attrs")
    }

    @Test func decodesNamedEntities() {
        #expect(PageTitleParser.parse(html: "<title>Tom &amp; Jerry &quot;quoted&quot;</title>")
                == "Tom & Jerry \"quoted\"")
    }

    @Test func decodesNumericEntities() {
        #expect(PageTitleParser.parse(html: "<title>caf&#233; &#x2764;</title>") == "café ❤")
    }

    @Test func collapsesWhitespaceAndTrims() {
        #expect(PageTitleParser.parse(html: "<title>\n  Spaced   Out  \n</title>") == "Spaced Out")
    }

    @Test func caseInsensitiveTags() {
        #expect(PageTitleParser.parse(html: "<TITLE>Caps</TITLE>") == "Caps")
    }

    @Test func nilWhenNoTitle() {
        #expect(PageTitleParser.parse(html: "<html><body>no title here</body></html>") == nil)
    }

    @Test func nilForEmptyTitle() {
        #expect(PageTitleParser.parse(html: "<title>   </title>") == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd GSDKit && swift test --filter PageTitleParserTests`
Expected: FAIL — "cannot find 'PageTitleParser' in scope".

- [ ] **Step 3: Write the implementation**

```swift
// GSDKit/Sources/GSDModel/PageTitleParser.swift
import Foundation

/// Extracts a page title from raw HTML for shared-link enrichment. Prefers the Open Graph
/// `og:title`, falls back to the `<title>` element; decodes common entities, collapses
/// whitespace, trims. Foundation-only and pure so it is fully unit-tested. Regex-based title
/// extraction is intentionally lightweight, not a full HTML parser.
public enum PageTitleParser {
    public static func parse(html: String) -> String? {
        let ogPatterns = [
            #"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']*)["']"#,
            #"<meta[^>]+content=["']([^"']*)["'][^>]+property=["']og:title["']"#,
        ]
        for pattern in ogPatterns {
            if let raw = firstGroup(in: html, pattern: pattern) {
                let title = clean(raw)
                if !title.isEmpty { return title }
            }
        }
        if let raw = firstGroup(in: html, pattern: #"<title[^>]*>([\s\S]*?)</title>"#) {
            let title = clean(raw)
            if !title.isEmpty { return title }
        }
        return nil
    }

    private static func firstGroup(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func clean(_ raw: String) -> String {
        let decoded = decodeEntities(raw)
        let collapsed = decoded.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let namedEntities = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
        "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
    ]

    private static func decodeEntities(_ s: String) -> String {
        var result = s
        for (entity, char) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        return decodeNumericEntities(result)
    }

    /// Replaces `&#123;` and `&#x1F4A9;` with their Unicode scalars (matches reversed so
    /// earlier replacements don't shift later ranges).
    private static func decodeNumericEntities(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9A-Fa-f]+);"#) else { return s }
        var result = s
        let matches = regex.matches(in: s, range: NSRange(s.startIndex..., in: s))
        for match in matches.reversed() {
            guard let full = Range(match.range, in: result),
                  let hexFlag = Range(match.range(at: 1), in: result),
                  let digits = Range(match.range(at: 2), in: result) else { continue }
            let isHex = !result[hexFlag].isEmpty
            guard let code = UInt32(result[digits], radix: isHex ? 16 : 10),
                  let scalar = Unicode.Scalar(code) else { continue }
            result.replaceSubrange(full, with: String(scalar))
        }
        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd GSDKit && swift test --filter PageTitleParserTests`
Expected: PASS — 9 tests.

- [ ] **Step 5: Run full suite (no regressions)**

Run: `cd GSDKit && swift test`
Expected: PASS — all tests (527 + 9 new).

- [ ] **Step 6: Commit**

```bash
git add GSDKit/Sources/GSDModel/PageTitleParser.swift GSDKit/Tests/GSDModelTests/PageTitleParserTests.swift
git commit -m "feat(model): PageTitleParser — extract og:title/<title> from HTML"
```

---

### Task 2: `fetchShareTitles` setting key + Settings toggle

**Files:**
- Modify: `GSDKit/Sources/GSDStore/AppGroupDefaults.swift` (add the key)
- Modify: `App/Settings/SettingsView.swift` (add the toggle + a section)

**Interfaces:**
- Produces: `AppGroupDefaults.Key.fetchShareTitles` (String key `"fetchShareTitles"`). Default when unset is `true`. Read elsewhere as `AppGroupDefaults.shared.object(forKey: AppGroupDefaults.Key.fetchShareTitles) as? Bool ?? true`.

- [ ] **Step 1: Add the key**

In `GSDKit/Sources/GSDStore/AppGroupDefaults.swift`, inside `enum Key`, after `deviceName`:

```swift
        public static let fetchShareTitles = "fetchShareTitles"
```

- [ ] **Step 2: Add the toggle to SettingsView**

In `App/Settings/SettingsView.swift`, add an `@AppStorage` property next to the existing ones (near line 15–17):

```swift
    @AppStorage(AppGroupDefaults.Key.fetchShareTitles, store: .shared) private var fetchShareTitles = true
```

Add a section to the body's section list (after `appearanceSection`, before `accountSection` at ~line 35):

```swift
                sharingSection
```

Add the section definition (place it right after `appearanceSection`'s closing brace, ~line 67):

```swift
    private var sharingSection: some View {
        Section {
            Toggle(String(localized: "Fetch titles for shared links"), isOn: $fetchShareTitles)
        } header: {
            Text(String(localized: "Sharing"))
        } footer: {
            Text(String(localized: "When you share a link to GSD, fetch the page title for a readable task name. Only links you share are fetched."))
        }
    }
```

- [ ] **Step 3: Regenerate is not needed (no new files in app target); build for iPhone**

Run: `xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -2`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add GSDKit/Sources/GSDStore/AppGroupDefaults.swift App/Settings/SettingsView.swift
git commit -m "feat(settings): 'Fetch titles for shared links' toggle (default on)"
```

---

### Task 3: `PageTitleFetcher` (app-layer URLSession glue)

**Files:**
- Create: `App/Sharing/PageTitleFetcher.swift`

**Interfaces:**
- Consumes: `PageTitleParser.parse(html:)` (Task 1).
- Produces: `struct PageTitleFetcher { func title(for url: URL) async -> String? }` — fetches the page and returns its parsed title, or `nil` on any failure.

- [ ] **Step 1: Write the implementation**

```swift
// App/Sharing/PageTitleFetcher.swift
import Foundation
import GSDModel

/// Fetches a web page's title for shared-link enrichment. Thin `URLSession` glue over the
/// pure `PageTitleParser`; reads at most ~64 KB (enough for `<head>`), times out at 8s, and
/// returns nil on any failure (offline, non-2xx, plain-http blocked by ATS, no title) so the
/// caller keeps the offline-derived title. App-layer I/O — verified by build + on-device smoke.
struct PageTitleFetcher {
    private let maxBytes = 64 * 1024

    func title(for url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        var data = Data()
        data.reserveCapacity(maxBytes)
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= maxBytes { break }
            }
        } catch {
            if data.isEmpty { return nil }
        }
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        return html.flatMap(PageTitleParser.parse)
    }
}
```

- [ ] **Step 2: Regenerate the project (new file in the app target) and build for iPhone**

Run: `xcodegen generate && xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -2`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/Sharing/PageTitleFetcher.swift GSD.xcodeproj/project.pbxproj
git commit -m "feat(sharing): PageTitleFetcher — URLSession title fetch (64KB cap, 8s)"
```

---

### Task 4: `ShareTitleEnricher` + drain wiring

**Files:**
- Create: `App/Sharing/ShareTitleEnricher.swift`
- Modify: `App/GSDApp.swift` (construct the enricher; call it from the three drain sites)

**Interfaces:**
- Consumes: `PageTitleFetcher.title(for:)` (Task 3); `AppGroupDefaults.Key.fetchShareTitles` (Task 2); `TaskStore` (`tasks`, `save`); `URLSanitizer.sanitize`, `URLTitle.derive`, `FieldLimits` (GSDModel).
- Produces: `@MainActor final class ShareTitleEnricher { init(store: TaskStore, fetch: @escaping (URL) async -> String?); func schedule(for task: GSDModel.Task) }` — fire-and-forget background title upgrade.

- [ ] **Step 1: Write the enricher**

```swift
// App/Sharing/ShareTitleEnricher.swift
import Foundation
import GSDModel
import GSDStore

/// Upgrades a share-created task's URL-derived title to the real page title, in the background.
/// Only acts when (1) the setting is on, (2) the task's title was derived from its shared URL
/// (so iOS's real titles, which differ, are skipped), and (3) the title is still that derived
/// value at save time (so a manual edit is never clobbered). Fire-and-forget: never blocks the
/// task appearing. App-layer glue — verified by build + on-device smoke; its logic reuses the
/// unit-tested URLTitle / PageTitleParser.
@MainActor
final class ShareTitleEnricher {
    private let store: TaskStore
    private let fetch: (URL) async -> String?

    init(store: TaskStore, fetch: @escaping (URL) async -> String?) {
        self.store = store
        self.fetch = fetch
    }

    func schedule(for task: GSDModel.Task) {
        guard AppGroupDefaults.shared.object(forKey: AppGroupDefaults.Key.fetchShareTitles) as? Bool ?? true,
              let url = sharedURL(in: task),
              task.title == derivedTitle(for: url) else { return }   // not URL-derived (incl. iOS) → skip
        _Concurrency.Task { [weak self] in
            guard let self,
                  let fetched = await self.fetch(url)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !fetched.isEmpty,
                  var current = self.store.tasks.first(where: { $0.id == task.id }),
                  current.title == self.derivedTitle(for: url) else { return }   // edited meanwhile → skip
            current.title = String(fetched.prefix(FieldLimits.titleRange.upperBound))
            try? await self.store.save(current)
        }
    }

    /// The shared URL is the first line of the task's description (the share path stores it there).
    private func sharedURL(in task: GSDModel.Task) -> URL? {
        let firstLine = task.description.split(separator: "\n", maxSplits: 1).first.map(String.init)
            ?? task.description
        guard let safe = URLSanitizer.sanitize(firstLine), let url = URL(string: safe) else { return nil }
        return url
    }

    /// The exact title the builder/extension produced from this URL, clamped identically.
    private func derivedTitle(for url: URL) -> String {
        String(URLTitle.derive(from: url.absoluteString).prefix(FieldLimits.titleRange.upperBound))
    }
}
```

- [ ] **Step 2: Construct the enricher in GSDApp.init**

In `App/GSDApp.swift`, find the share-inbox wiring (`let shareInbox = ShareInbox(store: ShareOutboxStore())`, ~line 102) and add an enricher `@State`. Add the stored property near `@State private var shareInbox` (~line 18):

```swift
    @State private var titleEnricher: ShareTitleEnricher
```

In `init()`, right after the `_shareInbox = State(initialValue: shareInbox)` line (~line 103):

```swift
        let fetcher = PageTitleFetcher()
        _titleEnricher = State(initialValue: ShareTitleEnricher(store: store, fetch: fetcher.title))
```

- [ ] **Step 3: Wire enrichment into the three drain sites**

In `App/GSDApp.swift`, each share drain currently reads `await shareInbox.drain { try await store.create($0) }`. Replace the closure in all THREE places (the launch `.task` ~line 138, the `scenePhase == .active` case ~line 150, and the `ShareOutboxSignal.observe` block ~line 139) so each created task is handed to the enricher:

The launch `.task` and the `scenePhase` site:

```swift
                    await shareInbox.drain { task in
                        try await store.create(task)
                        titleEnricher.schedule(for: task)
                    }
```

The `ShareOutboxSignal.observe` block:

```swift
                    ShareOutboxSignal.observe {
                        _Concurrency.Task {
                            await shareInbox.drain { task in
                                try await store.create(task)
                                titleEnricher.schedule(for: task)
                            }
                        }
                    }
```

- [ ] **Step 4: Regenerate (new app file) and build for iPhone**

Run: `xcodegen generate && xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -2`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Build for Mac Catalyst (the target platform)**

Run: `xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -2`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Build for iPad**

Run: `xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build 2>&1 | tail -2`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add App/Sharing/ShareTitleEnricher.swift App/GSDApp.swift GSD.xcodeproj/project.pbxproj
git commit -m "feat(sharing): enrich share-created tasks with the real page title"
```

---

## Owner verification (on a real Mac)

1. Rebuild & run the Catalyst app from Xcode (install to /Applications if needed for the Share menu).
2. Share an `ft.com` article from Safari → the task appears titled `ft.com`, then upgrades to the real headline within a moment.
3. Settings → toggle **Fetch titles for shared links** OFF → share again → title stays `ft.com` (no fetch).
4. iOS unaffected: sharing on iPhone/iPad still uses Safari's title immediately.
