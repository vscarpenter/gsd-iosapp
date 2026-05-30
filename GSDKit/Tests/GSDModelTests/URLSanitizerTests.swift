import Testing
@testable import GSDModel

struct URLSanitizerTests {
    @Test func acceptsPlainHttpsURL() {
        #expect(URLSanitizer.sanitize("https://example.com/path") == "https://example.com/path")
    }

    @Test func acceptsHttpURL() {
        #expect(URLSanitizer.sanitize("http://example.com") == "http://example.com")
    }

    @Test func stripsTrailingSentencePunctuation() {
        #expect(URLSanitizer.sanitize("https://example.com).") == "https://example.com")
        #expect(URLSanitizer.sanitize("https://example.com/a,") == "https://example.com/a")
    }

    @Test func rejectsNonHttpSchemes() {
        #expect(URLSanitizer.sanitize("ftp://example.com") == nil)
        #expect(URLSanitizer.sanitize("javascript:alert(1)") == nil)
        #expect(URLSanitizer.sanitize("file:///etc/passwd") == nil)
    }

    @Test func rejectsEmbeddedCredentials() {
        #expect(URLSanitizer.sanitize("https://user:pass@example.com") == nil)
    }

    @Test func rejectsMissingHost() {
        #expect(URLSanitizer.sanitize("https://") == nil)
    }

    @Test func rejectsOversizeURL() {
        let huge = "https://example.com/" + String(repeating: "a", count: 2048)
        #expect(URLSanitizer.sanitize(huge) == nil)
    }

    // Fix 2: percent-encoded credential host rejection
    @Test func rejectsPercentEncodedAtSignInHost() {
        #expect(URLSanitizer.sanitize("https://evil%40good.com") == nil)
    }

    @Test func normalHostStillAccepted() {
        #expect(URLSanitizer.sanitize("https://example.com") == "https://example.com")
    }

    // Fix 3: length boundary coverage
    @Test func accepts2047CharURL() {
        // "https://e.co/" is 13 chars; pad with 'a' to reach exactly 2047 total
        let padding = String(repeating: "a", count: 2047 - 13)
        let url = "https://e.co/" + padding
        assert(url.count == 2047, "url.count=\(url.count)")
        #expect(URLSanitizer.sanitize(url) != nil)
    }

    @Test func rejects2048CharURL() {
        // "https://e.co/" is 13 chars; pad with 'a' to reach exactly 2048 total
        let padding = String(repeating: "a", count: 2048 - 13)
        let url = "https://e.co/" + padding
        assert(url.count == 2048, "url.count=\(url.count)")
        #expect(URLSanitizer.sanitize(url) == nil)
    }
}
