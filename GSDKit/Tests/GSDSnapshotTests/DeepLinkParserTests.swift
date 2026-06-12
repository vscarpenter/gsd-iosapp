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
