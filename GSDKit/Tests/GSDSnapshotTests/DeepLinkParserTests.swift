import Testing
import Foundation
import GSDSnapshot

struct DeepLinkParserTests {
    @Test func parsesFocus() {
        #expect(DeepLinkParser.route(from: URL(string: "gsd://focus")!) == .focus)
    }

    @Test func ignoresOAuthCallback() {
        // ASWebAuthenticationSession's callback must never trigger app navigation.
        #expect(DeepLinkParser.route(from: URL(string: "gsd://oauth-callback")!) == nil)
    }

    @Test func ignoresForeignScheme() {
        #expect(DeepLinkParser.route(from: URL(string: "https://focus")!) == nil)
    }

    @Test func ignoresUnknownHost() {
        #expect(DeepLinkParser.route(from: URL(string: "gsd://nonsense")!) == nil)
    }

    @Test func idsWithReservedCharactersRoundTrip() {
        // App-generated nanoid IDs are URL-safe, but imported/foreign IDs are arbitrary:
        // '%' must not be double-decoded and '/' must not split the ID into path segments.
        #expect(DeepLinkParser.route(from: DeepLinkRoute.task("50%").url) == .task("50%"))
        #expect(DeepLinkParser.route(from: DeepLinkRoute.task("a/b").url) == .task("a/b"))
        #expect(DeepLinkParser.route(from: DeepLinkRoute.task("50%20x").url) == .task("50%20x"))
        #expect(DeepLinkParser.route(from: DeepLinkRoute.smartView("week 1/2").url) == .smartView("week 1/2"))
    }

    @Test func routeURLRoundTrips() {
        #expect(DeepLinkParser.route(from: DeepLinkRoute.focus.url) == .focus)
        #expect(DeepLinkParser.route(from: DeepLinkRoute.capture.url) == .capture)
        #expect(DeepLinkParser.route(from: DeepLinkRoute.quadrant(.notUrgentImportant).url) == .quadrant(.notUrgentImportant))
        #expect(DeepLinkParser.route(from: DeepLinkRoute.task("task 1").url) == .task("task 1"))
        #expect(DeepLinkParser.route(from: DeepLinkRoute.smartView("today-focus").url) == .smartView("today-focus"))
        #expect(DeepLinkParser.route(from: DeepLinkRoute.dashboard.url) == .dashboard)
        #expect(DeepLinkParser.route(from: DeepLinkRoute.settings.url) == .settings)
        #expect(DeepLinkParser.route(from: DeepLinkRoute.archive.url) == .archive)
    }
}
