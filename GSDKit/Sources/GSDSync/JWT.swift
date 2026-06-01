import Foundation

/// Decodes the `exp` claim from a PocketBase JWT and answers the proactive-refresh question. Pure;
/// does NOT verify the signature (the server does). Internal.
enum JWT {
    /// The `exp` (expiry) as a `Date`, or nil if the token is malformed or has no numeric `exp`.
    static func expiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3,
              let payload = base64urlDecode(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let exp = obj["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// True when `token` expires within `skew` of `now`, OR is unparseable (treat as needs-refresh).
    static func expiresWithin(_ skew: TimeInterval, of token: String, now: Date) -> Bool {
        guard let exp = expiry(token) else { return true }
        return exp.timeIntervalSince(now) <= skew
    }

    private static func base64urlDecode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 { str += "=" }
        return Data(base64Encoded: str)
    }
}
