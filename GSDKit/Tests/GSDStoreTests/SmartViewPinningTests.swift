import Testing
@testable import GSDStore

struct SmartViewPinningTests {
    @Test func pinAppendsUpToFiveAndIgnoresDuplicates() {
        var pins: [String] = []
        for id in ["a", "b", "c", "d", "e", "f"] { pins = SmartViewPinning.pin(id, in: pins) }
        #expect(pins == ["a", "b", "c", "d", "e"])           // capped at 5; "f" rejected
        #expect(SmartViewPinning.pin("a", in: pins) == pins)  // duplicate is a no-op
    }
    @Test func unpinRemovesPreservingOrder() {
        #expect(SmartViewPinning.unpin("b", in: ["a", "b", "c"]) == ["a", "c"])
        #expect(SmartViewPinning.unpin("z", in: ["a", "b"]) == ["a", "b"])  // absent = no-op
    }
    @Test func reorderMovesWithinList() {
        // Move "c" (index 2) to the front (offset 0).
        #expect(SmartViewPinning.reorder(["a", "b", "c"], fromOffsets: [2], toOffset: 0) == ["c", "a", "b"])
    }
    @Test func maxIsFive() { #expect(SmartViewPinning.maxPins == 5) }
}
