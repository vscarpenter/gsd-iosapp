import Testing
import Foundation
@testable import GSDModel

/// The editor shows the card menu's hint while the DRAFT escalates, the same words as Android
/// and web (spec-escalation §5). It reads the unsaved quadrant and due date, so it follows edits.
struct EscalationEditorHintTests {
    private let zone = TimeZone(identifier: "America/Chicago")!
    private var now: Date { ISO8601DateFormatter().date(from: "2026-10-29T10:00:00-05:00")! }
    private var tomorrow: Date { ISO8601DateFormatter().date(from: "2026-10-30T12:00:00-05:00")! }

    private func target(_ quadrant: Quadrant, due: Date?, window: EscalationWindow = .twoDays,
                        completed: Bool = false, saved: Bool = false) -> Escalation.Target? {
        Escalation.editorTarget(quadrant: quadrant, dueDate: due, isCompleted: completed, isSaved: saved,
                                now: now, window: window, timeZone: zone)
    }

    private func hint(_ quadrant: Quadrant, due: Date?, window: EscalationWindow = .twoDays,
                      completed: Bool = false, saved: Bool = false) -> String? {
        target(quadrant, due: due, window: window, completed: completed, saved: saved)?.markUrgentHint
    }

    /// The hint takes the target quadrant's ink, like the card marker: Do First's for Schedule,
    /// Delegate's for Eliminate.
    @Test func theTargetNamesWhichQuadrantInkTheHintWears() {
        #expect(target(.notUrgentImportant, due: tomorrow)?.quadrant == .urgentImportant)
        #expect(target(.notUrgentNotImportant, due: tomorrow)?.quadrant == .urgentNotImportant)
    }

    @Test func aScheduleDraftDueTomorrowHintsDoFirst() {
        #expect(hint(.notUrgentImportant, due: tomorrow) == "Moves to Do First")
    }

    @Test func anEliminateDraftDueTomorrowHintsDelegate() {
        #expect(hint(.notUrgentNotImportant, due: tomorrow) == "Moves to Delegate")
    }

    @Test(arguments: [Quadrant.urgentImportant, .urgentNotImportant])
    func anUrgentDraftHasNoHint(quadrant: Quadrant) {
        #expect(hint(quadrant, due: tomorrow) == nil)
    }

    @Test func offHidesTheHint() {
        #expect(hint(.notUrgentImportant, due: tomorrow, window: .off) == nil)
    }

    @Test func noDueDateHasNoHint() {
        #expect(hint(.notUrgentImportant, due: nil) == nil)
    }

    @Test func aDueDateOutsideTheWindowHasNoHint() {
        let nextMonth = now.addingTimeInterval(30 * 86_400)
        #expect(hint(.notUrgentImportant, due: nextMonth) == nil)
    }

    @Test func aCompletedOrSavedTaskHasNoHint() {
        #expect(hint(.notUrgentImportant, due: tomorrow, completed: true) == nil)
        #expect(hint(.notUrgentImportant, due: tomorrow, saved: true) == nil)
    }
}
