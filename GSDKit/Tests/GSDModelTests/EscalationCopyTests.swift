import Testing
@testable import GSDModel

/// Copy parity with web's `escalationLabel` and the Mark urgent hints (spec-escalation §5).
struct EscalationCopyTests {
    @Test(arguments: [
        (-3, "Escalating: 3 days overdue, not marked urgent."),
        (-1, "Escalating: 1 day overdue, not marked urgent."),
        (0, "Escalating: due today, not marked urgent."),
        (1, "Escalating: due tomorrow, not marked urgent."),
        (2, "Escalating: due in 2 days, not marked urgent."),
        (7, "Escalating: due in 7 days, not marked urgent."),
    ])
    func accessibilityLabelUsesTheDueChipPhrases(days: Int, expected: String) {
        #expect(Escalation.accessibilityLabel(daysUntilDue: days) == expected)
    }

    @Test func markUrgentHintNamesTheDestination() {
        #expect(Escalation.Target.urgentImportant.markUrgentHint == "Moves to Do First")
        #expect(Escalation.Target.urgentNotImportant.markUrgentHint == "Moves to Delegate")
    }
}
