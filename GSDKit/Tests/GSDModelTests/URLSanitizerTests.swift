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
}
