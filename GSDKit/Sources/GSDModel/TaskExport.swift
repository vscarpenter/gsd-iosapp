import Foundation

/// The export/import envelope (design-spec §3): a versioned set of tasks plus a timestamp.
/// `version` lets future imports branch on schema changes (currently always 1).
public struct TaskExport: Codable, Equatable, Sendable {
    public var tasks: [Task]
    public var exportedAt: Date
    public var version: Int

    public init(tasks: [Task], exportedAt: Date, version: Int = 1) {
        self.tasks = tasks
        self.exportedAt = exportedAt
        self.version = version
    }

    /// GSDModel-local fractional-seconds ISO-8601 coders. GSDModel cannot import GSDStore's
    /// internal `GSDJSON`, so this mirrors its strategy verbatim (design-spec round-trip
    /// fidelity decision). Each call builds its own `ISO8601DateFormatter` instance because
    /// the type is not `Sendable` (matches the GSDJSON pattern).
    private static func makeFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    public static func encode(_ export: TaskExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(makeFormatter().string(from: date))
        }
        return try encoder.encode(export)
    }

    public static func decode(_ data: Data) throws -> TaskExport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = makeFormatter().date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad ISO-8601 date: \(s)")
            }
            return date
        }
        return try decoder.decode(TaskExport.self, from: data)
    }
}
