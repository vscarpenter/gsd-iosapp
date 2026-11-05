import Foundation
import Testing
@testable import GSDModel

/// The bundled notes ship inside every client, so a malformed entry would break What's New on
/// three platforms at once. These checks mirror the web repo's content contract
/// (gsd-taskmanager tests/data/whats-new-content.test.ts; spec tasks/spec-whats-new.md §3).
struct WhatsNewContentTests {
    @Test func bundledNotesAreSchemaOneWithEveryPlatform() throws {
        let notes = try WhatsNew.bundledNotes()
        #expect(notes.schema == 1)
        for platform in WhatsNew.Platform.allCases {
            #expect(notes.releases.contains { $0.platform == platform }, "missing \(platform)")
        }
    }

    @Test func everyReleaseMeetsTheContract() throws {
        for release in try WhatsNew.bundledNotes().releases {
            let label = "\(release.platform.rawValue) \(release.version)"
            #expect(WhatsNew.parseVersion(release.version) != nil, "\(label): version")
            #expect(Self.isCalendarDate(release.date), "\(label): date")
            if release.notable {
                #expect(!(release.headline ?? "").trimmingCharacters(in: .whitespaces).isEmpty, "\(label): headline")
            } else {
                #expect(release.headline == nil, "\(label): non-notable headline")
            }
            let items = release.new + release.improved + release.fixed
            #expect(!items.isEmpty, "\(label): no items")
            for line in items + [release.headline ?? ""] {
                #expect(!line.contains("\u{2014}"), "\(label): em dash")
            }
        }
    }

    /// YYYY-MM-DD, checked by hand to keep the test free of regex-literal syntax.
    private static func isCalendarDate(_ s: String) -> Bool {
        let chars = Array(s)
        guard chars.count == 10, chars[4] == "-", chars[7] == "-" else { return false }
        return chars.enumerated().allSatisfy { index, c in index == 4 || index == 7 || c.isASCII && c.isNumber }
    }

    @Test func noPlatformAndVersionRepeats() throws {
        let keys = try WhatsNew.bundledNotes().releases.map(\.id)
        #expect(Set(keys).count == keys.count)
    }
}

struct WhatsNewVersionTests {
    @Test(arguments: [("14.6.2", [14, 6, 2]), ("0.10.0", [0, 10, 0]), ("3.7.0", [3, 7, 0])])
    func readsValidVersions(input: String, parts: [Int]) {
        let v = WhatsNew.parseVersion(input)
        #expect(v.map { [$0.major, $0.minor, $0.patch] } == parts)
    }

    @Test(arguments: ["14.6", "14.6.2.1", "v14.6.2", "14.06.2", "14.6.2-beta", "", " 14.6.2", "1..2", "+1.2.3"])
    func rejectsInvalidVersions(input: String) {
        #expect(WhatsNew.parseVersion(input) == nil)
    }

    @Test func comparesNumericallyNotAsText() throws {
        let older = try #require(WhatsNew.parseVersion("1.2.0"))
        let newer = try #require(WhatsNew.parseVersion("1.10.0"))
        #expect(older < newer)
    }

    private func release(_ platform: WhatsNew.Platform, _ version: String) -> WhatsNew.Release {
        WhatsNew.Release(platform: platform, version: version, date: "2026-01-01", notable: true,
                         headline: "H", new: ["x"], improved: [], fixed: [])
    }

    @Test func keepsOnePlatformNewestFirstUpToTheRunningVersion() {
        let all = [release(.apple, "1.2.0"), release(.apple, "1.10.0"), release(.web, "9.0.0"),
                   release(.apple, "1.0.0"), release(.apple, "2.0.0")]
        let shown = WhatsNew.releases(all, for: .apple, upTo: "1.10.0").map(\.version)
        #expect(shown == ["1.10.0", "1.2.0", "1.0.0"])
    }

    @Test func keepsEveryReleaseWhenTheRunningVersionIsUnknown() {
        let all = [release(.apple, "1.0.0"), release(.apple, "2.0.0")]
        #expect(WhatsNew.releases(all, for: .apple, upTo: nil).count == 2)
        #expect(WhatsNew.releases(all, for: .apple, upTo: "dev").count == 2)
    }
}
