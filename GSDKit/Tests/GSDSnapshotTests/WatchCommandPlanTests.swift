import Testing
import Foundation
import GSDModel
import GSDSnapshot

struct WatchCommandPlanTests {
    let at = Date(timeIntervalSince1970: 1_800_000_000)

    private func task(urgent: Bool = false, important: Bool = true,
                      completed: Bool = false, recurrence: RecurrenceType = .none) -> Task {
        Task(id: "t1", title: "t1", urgent: urgent, important: important, completed: completed,
             createdAt: at, updatedAt: at, recurrence: recurrence)
    }

    private func cmd(_ kind: WatchCommand.Kind, id: String = "c1") -> WatchCommand {
        WatchCommand(id: id, issuedAt: at, kind: kind)
    }

    private func decide(_ kind: WatchCommand.Kind, _ t: Task?, applied: Bool = false) -> WatchCommandPlan.Decision {
        WatchCommandPlan.decide(cmd(kind), task: t, alreadyApplied: applied)
    }

    // MARK: complete

    @Test func completeAppliesToAnActiveTaskIncludingARecurringOne() {
        #expect(decide(.complete(taskID: "t1"), task()) == .apply(.toggleComplete))
        #expect(decide(.complete(taskID: "t1"), task(recurrence: .daily)) == .apply(.toggleComplete))
    }

    @Test func completeSkipsMissingAndAlreadyCompleted() {
        #expect(decide(.complete(taskID: "t1"), nil) == .skip(.missingTask))
        #expect(decide(.complete(taskID: "t1"), task(completed: true)) == .skip(.alreadyCompleted))
    }

    // MARK: reopen

    @Test func reopenAppliesOnlyToACompletedTask() {
        #expect(decide(.reopen(taskID: "t1"), task(completed: true)) == .apply(.toggleComplete))
        #expect(decide(.reopen(taskID: "t1"), task()) == .skip(.notCompleted))
        #expect(decide(.reopen(taskID: "t1"), nil) == .skip(.missingTask))
    }

    // MARK: markUrgent

    @Test func markUrgentKeepsImportanceAndPicksTheEscalationTarget() {
        #expect(decide(.markUrgent(taskID: "t1"), task(important: true)) == .apply(.move(to: .urgentImportant)))
        #expect(decide(.markUrgent(taskID: "t1"), task(important: false)) == .apply(.move(to: .urgentNotImportant)))
        #expect(decide(.markUrgent(taskID: "t1"), task(important: true, recurrence: .weekly))
                == .apply(.move(to: .urgentImportant)))
    }

    @Test func markUrgentSkipsMissingCompletedAndAlreadyUrgent() {
        #expect(decide(.markUrgent(taskID: "t1"), nil) == .skip(.missingTask))
        #expect(decide(.markUrgent(taskID: "t1"), task(completed: true)) == .skip(.alreadyCompleted))
        #expect(decide(.markUrgent(taskID: "t1"), task(urgent: true)) == .skip(.alreadyUrgent))
    }

    // MARK: snooze

    @Test func snoozeAppliesToActiveAndSkipsMissingOrCompleted() {
        #expect(decide(.snooze(taskID: "t1"), task()) == .apply(.snoozeOneHour))
        #expect(decide(.snooze(taskID: "t1"), task(recurrence: .daily)) == .apply(.snoozeOneHour))
        #expect(decide(.snooze(taskID: "t1"), nil) == .skip(.missingTask))
        #expect(decide(.snooze(taskID: "t1"), task(completed: true)) == .skip(.alreadyCompleted))
    }

    // MARK: capture

    @Test func captureCarriesTrimmedTextAndQuadrantAndNeedsNoTask() {
        #expect(decide(.capture(text: "  Call Sam !!  ", quadrant: .urgentImportant), nil)
                == .apply(.capture(text: "Call Sam !!", quadrant: .urgentImportant)))
    }

    @Test func captureSkipsEmptyAfterTrimming() {
        #expect(decide(.capture(text: " \n ", quadrant: .notUrgentImportant), nil) == .skip(.emptyText))
    }

    // MARK: top three kinds wait for phase 4

    @Test func topThreeKindsSkipUntilPhaseFourShips() {
        #expect(decide(.addToToday(taskID: "t1"), task()) == .skip(.notAvailableYet))
        #expect(decide(.removeFromToday(taskID: "t1"), task()) == .skip(.notAvailableYet))
    }

    // MARK: idempotency

    @Test func aRepeatedCommandIDSkipsEvenWhenTheTaskStillMatches() {
        for kind: WatchCommand.Kind in [.complete(taskID: "t1"), .markUrgent(taskID: "t1"),
                                        .snooze(taskID: "t1"),
                                        .capture(text: "x", quadrant: .notUrgentNotImportant)] {
            #expect(decide(kind, task(), applied: true) == .skip(.duplicate))
        }
    }

    // MARK: wire format

    @Test func everyKindRoundTripsThroughJSON() throws {
        let kinds: [WatchCommand.Kind] = [
            .complete(taskID: "a"), .reopen(taskID: "a"), .markUrgent(taskID: "a"), .snooze(taskID: "a"),
            .addToToday(taskID: "a"), .removeFromToday(taskID: "a"),
            .capture(text: "Call Sam #home", quadrant: .urgentNotImportant),
        ]
        for kind in kinds {
            let command = cmd(kind)
            let back = try JSONDecoder().decode(WatchCommand.self, from: JSONEncoder().encode(command))
            #expect(back == command)
        }
    }

    @Test func anUnknownKindFailsToDecodeInsteadOfBecomingAnotherCommand() {
        let json = #"{"id":"c","issuedAt":0,"kind":"teleport","taskID":"a"}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WatchCommand.self, from: Data(json.utf8))
        }
    }
}
