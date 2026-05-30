import Testing
@testable import GSDModel

/// Deterministic RNG so ID generation is reproducible in tests
/// (coding standards: inject randomness).
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        // xorshift64 — adequate for test determinism, not cryptography.
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

struct IDGeneratorTests {
    @Test func generatesRequestedLength() {
        var rng = SeededRNG(seed: 1)
        #expect(IDGenerator.generate(size: 8, using: &rng).count == 8)
        #expect(IDGenerator.generate(size: 12, using: &rng).count == 12)
    }

    @Test func usesOnlyUrlSafeCharacters() {
        var rng = SeededRNG(seed: 42)
        let id = IDGenerator.generate(size: 64, using: &rng)
        let allowed = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_")
        #expect(id.allSatisfy { allowed.contains($0) })
    }

    @Test func isDeterministicForAGivenSeed() {
        var a = SeededRNG(seed: 7)
        var b = SeededRNG(seed: 7)
        #expect(IDGenerator.generate(size: 21, using: &a) == IDGenerator.generate(size: 21, using: &b))
    }
}
