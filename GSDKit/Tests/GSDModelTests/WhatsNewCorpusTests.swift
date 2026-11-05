import Foundation
import Testing
@testable import GSDModel

/// Runs the shared What's New corpus: a byte-identical copy of the web repo's
/// `tests/fixtures/cross-platform/whats-new-corpus.json` (md5
/// 7a8d4ac630e8a07303d29a80b424a3aa). Web is the authority. If a case fails here, decide the
/// correct behavior first, then change the corpus and all three implementations together.
struct WhatsNewCorpusTests {
    private struct Corpus: Decodable {
        let version: Int
        let releases: [Release]
        let cases: [Case]
    }
    private struct Release: Decodable { let version: String; let notable: Bool }
    private struct Case: Decodable {
        let name: String
        let currentVersion: String
        let lastSeenVersion: String?
        let existingUser: Bool
        let expect: Expected
    }
    private struct Expected: Decodable {
        let show: Bool
        let headlineVersion: String?
        let unseenCount: Int
        let recordVersion: String?
    }

    @Test func everyCorpusCaseDecidesIdentically() throws {
        let url = try #require(Bundle.module.url(forResource: "whats-new-corpus",
                                                 withExtension: "json",
                                                 subdirectory: "Fixtures"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        #expect(corpus.version == 1)
        #expect(corpus.cases.count == 21)
        let releases = corpus.releases.map { WhatsNew.Entry(version: $0.version, notable: $0.notable) }
        for c in corpus.cases {
            let decision = WhatsNew.decide(releases: releases,
                                           currentVersion: c.currentVersion,
                                           lastSeenVersion: c.lastSeenVersion,
                                           existingUser: c.existingUser)
            let expected = WhatsNew.Decision(show: c.expect.show,
                                             headlineVersion: c.expect.headlineVersion,
                                             unseenCount: c.expect.unseenCount,
                                             recordVersion: c.expect.recordVersion)
            #expect(decision == expected, "case: \(c.name)")
        }
    }
}
