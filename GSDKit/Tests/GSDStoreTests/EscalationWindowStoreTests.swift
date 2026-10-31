import Testing
import Foundation
import GSDModel
@testable import GSDStore

struct EscalationWindowStoreTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    }

    @Test func defaultsToTwoDays() {
        #expect(EscalationWindow.load(from: freshDefaults()) == .twoDays)
        #expect(EscalationWindow.load(from: freshDefaults()).days == 2)
    }

    @Test func offersOffOneTwoThreeSevenInOrder() {
        #expect(EscalationWindow.allCases.map(\.days) == [nil, 1, 2, 3, 7])
    }

    @Test(arguments: EscalationWindow.allCases)
    func roundTripsEveryOption(_ window: EscalationWindow) {
        let d = freshDefaults()
        window.save(to: d)
        #expect(EscalationWindow.load(from: d) == window)
    }

    @Test func offSurvivesAsOffNotAsDefault() {
        let d = freshDefaults()
        EscalationWindow.off.save(to: d)
        #expect(EscalationWindow.load(from: d) == .off)
    }

    @Test(arguments: [-1, 4, 5, 30, 999])
    func unknownStoredValueFallsBackToTwoDays(_ stored: Int) {
        let d = freshDefaults()
        d.set(stored, forKey: AppGroupDefaults.Key.escalationWindowDays)
        #expect(EscalationWindow.load(from: d) == .twoDays)
    }

    @Test func wrongTypeFallsBackToTwoDays() {
        let d = freshDefaults()
        d.set("soon", forKey: AppGroupDefaults.Key.escalationWindowDays)
        #expect(EscalationWindow.load(from: d) == .twoDays)
    }
}
