import Foundation

/// The cross-process payload the Share Extension writes and the app ingests (spec §3, §4.1).
/// Raw user input — `urls`/`title`/`tags` are sanitized, clamped, and normalized on ingest by
/// `SharedCaptureBuilder`, never here.
public struct SharedCapture: Codable, Sendable, Equatable {
    public var title: String          // user-edited; clamped on ingest
    public var urls: [String]         // raw shared URLs; sanitized on ingest
    public var urgent: Bool
    public var important: Bool
    public var tags: [String]         // split from the comma field; normalized on ingest
    public var capturedAt: Date

    public init(title: String, urls: [String], urgent: Bool, important: Bool,
                tags: [String], capturedAt: Date) {
        self.title = title
        self.urls = urls
        self.urgent = urgent
        self.important = important
        self.tags = tags
        self.capturedAt = capturedAt
    }
}
