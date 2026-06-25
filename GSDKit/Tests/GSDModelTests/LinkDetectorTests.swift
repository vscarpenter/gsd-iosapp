import Testing
import Foundation
@testable import GSDModel

/// `LinkDetector` finds http/https URLs in free text and re-validates each through
/// `URLSanitizer`, so the editor only ever surfaces a vetted, openable URL.
struct LinkDetectorTests {
    private func strings(_ urls: [URL]) -> [String] { urls.map(\.absoluteString) }

    @Test func detectsURLEmbeddedInText() {
        let found = LinkDetector.detect(in: "Check out https://example.com today")
        #expect(strings(found) == ["https://example.com"])
    }

    @Test func detectsBareURL() {
        #expect(strings(LinkDetector.detect(in: "https://example.com/path")) == ["https://example.com/path"])
    }

    @Test func detectsMultipleURLsInOrder() {
        // The share path joins captured URLs with newlines.
        let found = LinkDetector.detect(in: "https://first.com\nhttps://second.com")
        #expect(strings(found) == ["https://first.com", "https://second.com"])
    }

    @Test func dedupesRepeatedURLs() {
        let found = LinkDetector.detect(in: "https://a.com and again https://a.com")
        #expect(strings(found) == ["https://a.com"])
    }

    @Test func stripsTrailingSentencePunctuation() {
        let found = LinkDetector.detect(in: "Read https://example.com. Then stop.")
        #expect(strings(found) == ["https://example.com"])
    }

    @Test func rejectsJavascriptScheme() {
        #expect(LinkDetector.detect(in: "javascript:alert(1)").isEmpty)
    }

    @Test func rejectsDataScheme() {
        #expect(LinkDetector.detect(in: "data:text/html,<script>alert(1)</script>").isEmpty)
    }

    @Test func rejectsFileScheme() {
        #expect(LinkDetector.detect(in: "file:///etc/passwd").isEmpty)
    }

    @Test func rejectsEmailAddress() {
        // NSDataDetector surfaces emails as mailto links; URLSanitizer must drop them.
        #expect(LinkDetector.detect(in: "email me at foo@bar.com").isEmpty)
    }

    @Test func rejectsEmbeddedCredentials() {
        #expect(LinkDetector.detect(in: "https://user:pass@evil.com").isEmpty)
    }

    @Test func rejectsPercentEncodedCredentials() {
        #expect(LinkDetector.detect(in: "https://evil%40good.com").isEmpty)
    }

    @Test func rejectsBareWwwWithoutScheme() {
        // Conservative by design: no explicit scheme means no link.
        #expect(LinkDetector.detect(in: "visit www.example.com for more").isEmpty)
    }

    @Test func dropsOversizeURL() {
        // Slash-separated segments make NSDataDetector match the whole URL, so the
        // matched substring (2819 chars) exceeds URLSanitizer's 2048 cap and is dropped.
        let huge = "https://example.com/" + Array(repeating: "seg", count: 700).joined(separator: "/")
        assert(huge.count > URLSanitizer.maxLength, "huge.count=\(huge.count)")
        #expect(LinkDetector.detect(in: huge).isEmpty)
    }

    @Test func emptyInputYieldsNoURLs() {
        #expect(LinkDetector.detect(in: "").isEmpty)
    }

    @Test func plainTextYieldsNoURLs() {
        #expect(LinkDetector.detect(in: "just a normal note with no links").isEmpty)
    }
}
