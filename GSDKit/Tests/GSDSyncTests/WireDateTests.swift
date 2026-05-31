import Testing
import Foundation
@testable import GSDSync

struct WireDateTests {
    @Test func parsesFractionalSeconds() {
        #expect(WireDate.parse("2026-06-15T09:00:00.500Z") != nil)
    }

    @Test func parsesWholeSeconds() {
        // The strict GSDJSON rejects this form; WireDate must accept it.
        #expect(WireDate.parse("2026-06-15T09:00:00Z") != nil)
    }

    @Test func parsesNumericOffset() {
        #expect(WireDate.parse("2026-06-15T09:00:00+00:00") != nil)
    }

    @Test func emptyStringIsNil() {
        #expect(WireDate.parse("") == nil)
    }

    @Test func garbageIsNil() {
        #expect(WireDate.parse("not-a-date") == nil)
    }

    @Test func formatNilIsEmptyString() {
        #expect(WireDate.format(nil) == "")
    }

    @Test func fractionalRoundTrips() throws {
        let original = try #require(WireDate.parse("2026-06-15T09:00:00.500Z"))
        let restored = try #require(WireDate.parse(WireDate.format(original)))
        #expect(abs(restored.timeIntervalSince1970 - original.timeIntervalSince1970) < 0.0005)
    }
}
