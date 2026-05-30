/// URL-safe nanoid-compatible identifiers so records round-trip with the web
/// app and PocketBase (product spec §5). Randomness is injected for testability.
public enum IDGenerator {
    /// nanoid's URL-safe alphabet.
    public static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_")

    /// Minimum lengths the rest of the app should use.
    public enum Size {
        public static let task = 21       // web default; spec floor is 4
        public static let timeEntry = 8
        public static let smartView = 12
    }

    public static func generate(size: Int = Size.task, using rng: inout some RandomNumberGenerator) -> String {
        precondition(size >= 1, "id size must be positive")
        var result = ""
        result.reserveCapacity(size)
        for _ in 0..<size {
            let index = Int.random(in: 0..<alphabet.count, using: &rng)
            result.append(alphabet[index])
        }
        return result
    }

    public static func generate(size: Int = Size.task) -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(size: size, using: &rng)
    }
}
