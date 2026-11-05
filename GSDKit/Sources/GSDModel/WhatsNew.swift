import Foundation

/// What's New (cross-platform spec: gsd-taskmanager `tasks/spec-whats-new.md`, decision D-15).
///
/// `Resources/whats-new.json` is a byte-identical copy of the web repo's
/// `lib/whats-new/whats-new.json`, which holds every client's release notes. It ships inside
/// the build, so What's New works offline and never asks a server what changed. The show rule
/// (`decide`) is pinned by the shared `whats-new-corpus.json`, which the web and Android
/// suites run too. Change the web authority first, then copy both files here.
public enum WhatsNew {
    public enum Platform: String, Codable, Sendable, CaseIterable {
        case web, apple, android
    }

    public struct Release: Codable, Equatable, Sendable, Identifiable {
        public let platform: Platform
        public let version: String
        /// Calendar date, `YYYY-MM-DD`.
        public let date: String
        /// True when this release may show the one-line post-update cue.
        public let notable: Bool
        /// Required when notable; nil otherwise.
        public let headline: String?
        public let new: [String]
        public let improved: [String]
        public let fixed: [String]

        public var id: String { "\(platform.rawValue)@\(version)" }

        public init(platform: Platform, version: String, date: String, notable: Bool,
                    headline: String?, new: [String], improved: [String], fixed: [String]) {
            self.platform = platform
            self.version = version
            self.date = date
            self.notable = notable
            self.headline = headline
            self.new = new
            self.improved = improved
            self.fixed = fixed
        }
    }

    public struct Notes: Codable, Sendable {
        public let schema: Int
        public let releases: [Release]
    }

    public struct Version: Comparable, Sendable {
        public let major: Int
        public let minor: Int
        public let patch: Int

        public static func < (lhs: Version, rhs: Version) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
    }

    /// What the rule needs from a release: its version and whether it is notable.
    public struct Entry: Sendable {
        public let version: String
        public let notable: Bool
        public init(version: String, notable: Bool) {
            self.version = version
            self.notable = notable
        }
    }

    public struct Decision: Equatable, Sendable {
        public let show: Bool
        public let headlineVersion: String?
        public let unseenCount: Int
        /// Written as last seen right away, with no user action. Nil writes nothing.
        public let recordVersion: String?

        public init(show: Bool, headlineVersion: String?, unseenCount: Int, recordVersion: String?) {
            self.show = show
            self.headlineVersion = headlineVersion
            self.unseenCount = unseenCount
            self.recordVersion = recordVersion
        }

        static let nothing = Decision(show: false, headlineVersion: nil, unseenCount: 0, recordVersion: nil)
    }

    /// Three dot-separated non-negative integers with no leading zeros (0 itself is fine) and
    /// nothing else, so every client parses exactly the same set of strings.
    public static func parseVersion(_ value: String) -> Version? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part == "0" || part.first != "0",
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return Version(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    /// One platform's releases, newest first. Notes for a version newer than the running one
    /// are left out, so an entry can land before the build that ships it. An unknown running
    /// version keeps them all.
    public static func releases(_ all: [Release], for platform: Platform, upTo currentVersion: String?) -> [Release] {
        let current = currentVersion.flatMap(parseVersion)
        return all
            .compactMap { release -> (Release, Version)? in
                guard release.platform == platform, let version = parseVersion(release.version) else { return nil }
                if let current, version > current { return nil }
                return (release, version)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    /// Whether the post-update line shows. See the spec's section 4 for the reasoning; the
    /// shared corpus pins every branch.
    public static func decide(releases: [Entry], currentVersion: String, lastSeenVersion: String?,
                              existingUser: Bool) -> Decision {
        guard let current = parseVersion(currentVersion) else { return .nothing }
        let lastSeen = lastSeenVersion.flatMap(parseVersion)
        let startFromHere = Decision(show: false, headlineVersion: nil, unseenCount: 0,
                                     recordVersion: currentVersion)

        if lastSeen == nil && !existingUser { return startFromHere }
        if let lastSeen, lastSeen >= current { return .nothing }

        let counted = releases
            .compactMap { entry -> (label: String, version: Version, notable: Bool)? in
                guard let version = parseVersion(entry.version), version <= current else { return nil }
                return (entry.version, version, entry.notable)
            }
            .sorted { $0.version > $1.version }

        let unseen: [(label: String, version: Version, notable: Bool)]
        if let lastSeen {
            unseen = counted.filter { $0.version > lastSeen }
        } else if let newestNotable = counted.first(where: { $0.notable }) {
            unseen = counted.filter { $0.version >= newestNotable.version }
        } else {
            unseen = []
        }

        guard let headline = unseen.first(where: { $0.notable }) else { return startFromHere }
        return Decision(show: true, headlineVersion: headline.label, unseenCount: unseen.count, recordVersion: nil)
    }

    /// The notes bundled with this build.
    public static func bundledNotes() throws -> Notes {
        guard let url = Bundle.module.url(forResource: "whats-new", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(Notes.self, from: Data(contentsOf: url))
    }
}
