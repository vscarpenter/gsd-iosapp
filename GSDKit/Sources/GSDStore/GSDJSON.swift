import Foundation

/// Shared JSON coding for the embedded-collection columns. ISO-8601 dates keep
/// the JSON forward-compatible with the export/wire formats (increment spec §3.3).
///
/// Precision boundary: milliseconds. The web app and PocketBase always emit ISO-8601
/// with fractional seconds (e.g. "1970-01-01T00:25:00.500Z"). This is the canonical
/// wire format for sync — sub-millisecond precision is intentionally discarded.
/// Note: the formatter is strict — it rejects whole-second strings (no ".nnn").
/// Legacy whole-second data (pre-fix) would throw on decode.
enum GSDJSON {
    /// Returns a new ISO-8601 formatter with fractional seconds configured.
    /// Called inside encode/decode closures so each call site has its own instance,
    /// avoiding a shared-mutable-state concurrency violation (ISO8601DateFormatter
    /// does not conform to Sendable).
    private static func makeFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(makeFormatter().string(from: date))
        }
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = makeFormatter().date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected ISO-8601 date with fractional seconds, got: \(string)"
                )
            }
            return date
        }
        return d
    }()

    static func string<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func value<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }
}
