import Foundation

/// Lenient ISO-8601 handling for the PocketBase wire boundary — the lenient counterpart to
/// GSDStore's strict `GSDJSON`. PocketBase/web may emit dates with or without fractional
/// seconds, and §7.1 uses the empty string for an absent date. Parsing tolerates both forms
/// and maps empty/unparseable to nil; formatting emits the canonical fractional-seconds form.
/// A fresh `ISO8601DateFormatter` is created per call (it is not `Sendable`).
enum WireDate {
    private static func fractional() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
    private static func wholeSecond() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    /// Empty → nil; fractional-seconds → Date; whole-second → Date; otherwise nil.
    static func parse(_ string: String) -> Date? {
        if string.isEmpty { return nil }
        if let date = fractional().date(from: string) { return date }
        return wholeSecond().date(from: string)
    }

    /// nil → "" (the §7.1 absent-date form); otherwise canonical fractional-seconds.
    static func format(_ date: Date?) -> String {
        guard let date else { return "" }
        return fractional().string(from: date)
    }
}
