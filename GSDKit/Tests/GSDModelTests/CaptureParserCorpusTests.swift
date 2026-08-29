import Testing
import Foundation
@testable import GSDModel

/// Runs the shared cross-platform capture-parser corpus — a byte-identical copy of the
/// web repo's `tests/fixtures/cross-platform/capture-parser-corpus.json`, executed by
/// both suites so the two parsers cannot drift apart unnoticed (the same discipline as
/// the backup fixture pair). If a case here fails, decide the correct behavior first,
/// then change the corpus in BOTH repos and both implementations together.
struct CaptureParserCorpusTests {
    private struct Corpus: Decodable { let cases: [Case] }
    private struct Case: Decodable { let name: String; let input: String; let expect: Expected }
    private struct Expected: Decodable {
        let title: String
        let urgent: Bool
        let important: Bool
        let tags: [String]
        let urls: [String]
    }

    @Test func everyCorpusCaseParsesIdentically() throws {
        let url = try #require(Bundle.module.url(forResource: "capture-parser-corpus",
                                                 withExtension: "json",
                                                 subdirectory: "Fixtures"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        #expect(corpus.cases.count >= 40)
        for c in corpus.cases {
            let r = CaptureParser.parse(c.input)
            #expect(r.title == c.expect.title, "\(c.name) — title")
            #expect(r.urgent == c.expect.urgent, "\(c.name) — urgent")
            #expect(r.important == c.expect.important, "\(c.name) — important")
            #expect(r.tags == c.expect.tags, "\(c.name) — tags")
            #expect(r.descriptionAdditions == c.expect.urls, "\(c.name) — urls")
        }
    }
}
