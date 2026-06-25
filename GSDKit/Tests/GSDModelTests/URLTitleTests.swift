import Testing
@testable import GSDModel

/// `URLTitle.derive` turns a URL into a readable title (its path slug, else host) for when no
/// real page title is available — e.g. a Mac Catalyst share, which carries only the bare URL.
struct URLTitleTests {
    @Test func derivesTitleFromArticleSlug() {
        let url = "https://fortune.com/2026/06/24/exclusive-seltz-a-startup-rebuilding-web-search/"
        #expect(URLTitle.derive(from: url) == "Exclusive Seltz A Startup Rebuilding Web Search")
    }

    @Test func keepsNumbersWithinAWordySlug() {
        let url = "https://example.com/raises-12-5-million-in-seed-funding"
        #expect(URLTitle.derive(from: url) == "Raises 12 5 Million In Seed Funding")
    }

    @Test func replacesUnderscores() {
        #expect(URLTitle.derive(from: "https://example.com/my_cool_post") == "My Cool Post")
    }

    @Test func stripsHtmlExtension() {
        #expect(URLTitle.derive(from: "https://example.com/blog/my-post.html") == "My Post")
    }

    @Test func fallsBackToHostWhenNoPath() {
        #expect(URLTitle.derive(from: "https://fortune.com/") == "fortune.com")
    }

    @Test func stripsWwwFromHostFallback() {
        #expect(URLTitle.derive(from: "https://www.example.com") == "example.com")
    }

    @Test func fallsBackToHostForNumericSlug() {
        #expect(URLTitle.derive(from: "https://example.com/12345") == "example.com")
    }

    @Test func fallsBackToHostForUuidSlug() {
        let url = "https://www.ft.com/content/b6ef5e8a-4288-4223-a017-c97b89cac2fa"
        #expect(URLTitle.derive(from: url) == "ft.com")
    }

    @Test func fallsBackToHostForOpaqueHexSlug() {
        #expect(URLTitle.derive(from: "https://example.com/a1b2c3d4e5f6") == "example.com")
    }

    @Test func emptyForUnparseableInput() {
        #expect(URLTitle.derive(from: "") == "")
    }
}
