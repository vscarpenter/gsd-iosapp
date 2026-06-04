import Testing
import Foundation
import GSDModel
import GSDSnapshot

struct SharedCaptureBuilderTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    private func capture(title: String = "Title", urls: [String] = [],
                         urgent: Bool = false, important: Bool = false,
                         tags: [String] = []) -> SharedCapture {
        SharedCapture(title: title, urls: urls, urgent: urgent, important: important,
                      tags: tags, capturedAt: now)
    }

    @Test func usesIdAndNow() {
        let task = SharedCaptureBuilder.task(from: capture(), id: "ID-1", now: now)
        #expect(task.id == "ID-1")
        #expect(task.createdAt == now)
        #expect(task.updatedAt == now)
    }

    @Test func clampsTitleTo80() {
        let long = String(repeating: "x", count: 200)
        let task = SharedCaptureBuilder.task(from: capture(title: long), id: "i", now: now)
        #expect(task.title.count == 80)
    }

    @Test func emptyTitleFallsBack() {
        let task = SharedCaptureBuilder.task(from: capture(title: "   "), id: "i", now: now)
        #expect(task.title == "Review link below")
    }

    @Test func quadrantFlagsPassThrough() {
        let task = SharedCaptureBuilder.task(
            from: capture(urgent: true, important: true), id: "i", now: now)
        #expect(task.urgent && task.important)
        #expect(task.quadrant == .urgentImportant)
    }

    @Test func defaultIsEliminate() {
        let task = SharedCaptureBuilder.task(from: capture(), id: "i", now: now)
        #expect(task.quadrant == .notUrgentNotImportant)
    }

    @Test func sanitizesUrlsIntoDescription() {
        let task = SharedCaptureBuilder.task(
            from: capture(urls: ["https://ok.com", "javascript:alert(1)", "http://two.com"]),
            id: "i", now: now)
        #expect(task.description == "https://ok.com\nhttp://two.com")  // unsafe dropped
    }

    @Test func clampsDescriptionTo600() {
        // A single very long (but http) URL is < 2048 so it survives sanitize; clamp to 600.
        let longURL = "https://e.com/" + String(repeating: "a", count: 1000)
        let task = SharedCaptureBuilder.task(from: capture(urls: [longURL]), id: "i", now: now)
        #expect(task.description.count == 600)
    }

    @Test func normalizesTags() {
        let task = SharedCaptureBuilder.task(
            from: capture(tags: [" Read ", "READ", "later", "", "x"]), id: "i", now: now)
        #expect(task.tags == ["read", "later", "x"])   // trimmed, lowercased, deduped, empty dropped
    }

    @Test func dropsOverlongTagsAndCapsAt20() {
        let overlong = String(repeating: "t", count: 31)
        let many = (0..<25).map { "tag\($0)" }
        let task = SharedCaptureBuilder.task(
            from: capture(tags: [overlong] + many), id: "i", now: now)
        #expect(!task.tags.contains(overlong))   // > 30 dropped
        #expect(task.tags.count == 20)            // capped
    }

    @Test func alwaysProducesValidTask() throws {
        // Adversarial: huge title, too many over-long tags, unsafe URL, empty everything.
        let adversarial = [
            capture(title: String(repeating: "z", count: 5000),
                    urls: ["not a url", "ftp://x", "https://ok.com"],
                    tags: (0..<50).map { _ in String(repeating: "q", count: 40) }),
            capture(title: "", urls: [], tags: []),
            capture(title: "ok", urls: ["javascript:alert(1)"], tags: ["", "  "]),
        ]
        for c in adversarial {
            let task = SharedCaptureBuilder.task(from: c, id: "i", now: now)
            #expect(throws: Never.self) { try TaskValidator.validate(task) }
        }
    }
}
