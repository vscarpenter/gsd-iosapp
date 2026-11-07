import Foundation
import GSDModel

/// A change the watch asks the iPhone to make (spec 6.3). The id is a UUID made on the watch;
/// the iPhone skips an id it has already applied.
public struct WatchCommand: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case complete(taskID: String)
        case reopen(taskID: String)
        case markUrgent(taskID: String)
        case snooze(taskID: String)
        case addToToday(taskID: String)
        case removeFromToday(taskID: String)
        case capture(text: String, quadrant: Quadrant)
    }

    public var id: String
    public var issuedAt: Date
    public var kind: Kind

    public init(id: String, issuedAt: Date, kind: Kind) {
        self.id = id
        self.issuedAt = issuedAt
        self.kind = kind
    }

    /// The task a command targets; `nil` for a capture.
    public var taskID: String? {
        switch kind {
        case .complete(let id), .reopen(let id), .markUrgent(let id), .snooze(let id),
             .addToToday(let id), .removeFromToday(let id): return id
        case .capture: return nil
        }
    }

    // Flat wire shape: {id, issuedAt, kind, taskID?, text?, quadrant?}. A new kind is additive,
    // and an unknown kind fails to decode rather than turning into some other command.
    private enum CodingKeys: String, CodingKey { case id, issuedAt, kind, taskID, text, quadrant }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        issuedAt = try c.decode(Date.self, forKey: .issuedAt)
        let name = try c.decode(String.self, forKey: .kind)
        if name == "capture" {
            kind = .capture(text: try c.decode(String.self, forKey: .text),
                            quadrant: try c.decode(Quadrant.self, forKey: .quadrant))
            return
        }
        let task = try c.decode(String.self, forKey: .taskID)
        switch name {
        case "complete": kind = .complete(taskID: task)
        case "reopen": kind = .reopen(taskID: task)
        case "markUrgent": kind = .markUrgent(taskID: task)
        case "snooze": kind = .snooze(taskID: task)
        case "addToToday": kind = .addToToday(taskID: task)
        case "removeFromToday": kind = .removeFromToday(taskID: task)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "unknown watch command kind \(name)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(issuedAt, forKey: .issuedAt)
        switch kind {
        case .complete(let t): try c.encode("complete", forKey: .kind); try c.encode(t, forKey: .taskID)
        case .reopen(let t): try c.encode("reopen", forKey: .kind); try c.encode(t, forKey: .taskID)
        case .markUrgent(let t): try c.encode("markUrgent", forKey: .kind); try c.encode(t, forKey: .taskID)
        case .snooze(let t): try c.encode("snooze", forKey: .kind); try c.encode(t, forKey: .taskID)
        case .addToToday(let t): try c.encode("addToToday", forKey: .kind); try c.encode(t, forKey: .taskID)
        case .removeFromToday(let t): try c.encode("removeFromToday", forKey: .kind); try c.encode(t, forKey: .taskID)
        case .capture(let text, let quadrant):
            try c.encode("capture", forKey: .kind)
            try c.encode(text, forKey: .text)
            try c.encode(quadrant, forKey: .quadrant)
        }
    }
}
