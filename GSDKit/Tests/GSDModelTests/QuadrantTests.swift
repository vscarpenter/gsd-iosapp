import Testing
@testable import GSDModel

struct QuadrantTests {
    @Test func urgentImportant_isDoFirst() {
        #expect(Quadrant(urgent: true, important: true) == .urgentImportant)
        #expect(Quadrant.urgentImportant.title == "Do First")
        #expect(Quadrant.urgentImportant.rawValue == "urgent-important")
    }

    @Test func derivationCoversAllFourCombinations() {
        #expect(Quadrant(urgent: false, important: true) == .notUrgentImportant)
        #expect(Quadrant(urgent: true, important: false) == .urgentNotImportant)
        #expect(Quadrant(urgent: false, important: false) == .notUrgentNotImportant)
    }

    @Test func canonicalOrderIsQ1ThroughQ4() {
        #expect(Quadrant.allCases == [
            .urgentImportant, .notUrgentImportant,
            .urgentNotImportant, .notUrgentNotImportant,
        ])
    }

    @Test func reverseMappingExposesFlags() {
        #expect(Quadrant.urgentImportant.isUrgent && Quadrant.urgentImportant.isImportant)
        #expect(Quadrant.notUrgentImportant.isImportant && !Quadrant.notUrgentImportant.isUrgent)
        #expect(Quadrant.urgentNotImportant.isUrgent && !Quadrant.urgentNotImportant.isImportant)
        #expect(!Quadrant.notUrgentNotImportant.isUrgent && !Quadrant.notUrgentNotImportant.isImportant)
    }
    @Test func reverseMappingRoundTripsWithDerivation() {
        for q in Quadrant.allCases { #expect(Quadrant(urgent: q.isUrgent, important: q.isImportant) == q) }
    }
}
