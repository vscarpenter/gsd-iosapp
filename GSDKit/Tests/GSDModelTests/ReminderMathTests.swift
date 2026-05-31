import Testing
import Foundation
@testable import GSDModel

struct ReminderMathTests {
    /// Fixed UTC gregorian calendar; now = Mon 2026-06-15 09:00 UTC (matches the probes).
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }
    private var now: Date { at(2026, 6, 15, 9, 0) }

    private func task(due: Date? = nil, notifyBefore: Int? = nil,
                      enabled: Bool = true, completed: Bool = false) -> Task {
        Task(id: "t", title: "t", urgent: false, important: false, completed: completed,
             createdAt: at(2026, 6, 1), updatedAt: at(2026, 6, 1), dueDate: due,
             notifyBefore: notifyBefore, notificationEnabled: enabled)
    }
    private let on = ReminderMath.Inputs(masterEnabled: true, defaultReminder: 15)

    // MARK: shouldSchedule (the master/task/completed/due gate — not the past gate)
    @Test func shouldScheduleGate() {
        #expect(ReminderMath.shouldSchedule(task(due: at(2026,6,15,12)), inputs: on))
        #expect(!ReminderMath.shouldSchedule(task(due: nil), inputs: on))               // no due
        #expect(!ReminderMath.shouldSchedule(task(due: at(2026,6,15,12), enabled: false), inputs: on)) // task off
        #expect(!ReminderMath.shouldSchedule(task(due: at(2026,6,15,12), completed: true), inputs: on)) // done
        #expect(!ReminderMath.shouldSchedule(task(due: at(2026,6,15,12)),
                inputs: .init(masterEnabled: false, defaultReminder: 15)))              // master off
    }

    // MARK: fireDate (offset + past-due skip) — probe firedate 11/11
    @Test func fireDateUsesDefaultWhenNotifyBeforeNil() {
        #expect(ReminderMath.fireDate(for: task(due: at(2026,6,15,12), notifyBefore: nil),
                inputs: on, now: now) == at(2026,6,15,11,45))
    }
    @Test func fireDateUsesExplicitNotifyBefore() {
        #expect(ReminderMath.fireDate(for: task(due: at(2026,6,15,12), notifyBefore: 60),
                inputs: on, now: now) == at(2026,6,15,11,0))
    }
    @Test func fireDateZeroOffsetIsAtDueTime() {
        #expect(ReminderMath.fireDate(for: task(due: at(2026,6,15,12), notifyBefore: 0),
                inputs: on, now: now) == at(2026,6,15,12,0))
    }
    @Test func fireDateNilWhenShouldNotSchedule() {
        #expect(ReminderMath.fireDate(for: task(due: nil), inputs: on, now: now) == nil)
        #expect(ReminderMath.fireDate(for: task(due: at(2026,6,15,12), completed: true), inputs: on, now: now) == nil)
    }
    @Test func fireDateNilWhenPast() {
        // due 09:05, 15m before → fire 08:50 < now 09:00 → SKIP.
        #expect(ReminderMath.fireDate(for: task(due: at(2026,6,15,9,5), notifyBefore: 15), inputs: on, now: now) == nil)
    }
    @Test func fireDateInclusiveAtNow() {
        // due 09:15, 15m before → fire exactly 09:00 == now → scheduled.
        #expect(ReminderMath.fireDate(for: task(due: at(2026,6,15,9,15), notifyBefore: 15),
                inputs: on, now: now) == at(2026,6,15,9,0))
    }

    // MARK: applyQuietHours — probe quiethours 14/14
    private func q(_ fire: Date, _ start: String?, _ end: String?) -> Date {
        ReminderMath.applyQuietHours(fire, quietStart: start, quietEnd: end, calendar: cal)
    }
    @Test func quietCrossingMidnight() {
        #expect(q(at(2026,6,15,23,30), "22:00", "07:00") == at(2026,6,16,7,0))   // 23:30 → next-day 07:00
        #expect(q(at(2026,6,15,6,0),  "22:00", "07:00") == at(2026,6,15,7,0))    // 06:00 → same-day 07:00
        #expect(q(at(2026,6,15,0,0),  "22:00", "07:00") == at(2026,6,15,7,0))    // 00:00 → same-day 07:00
        #expect(q(at(2026,6,15,12,0), "22:00", "07:00") == at(2026,6,15,12,0))   // 12:00 → unchanged
        #expect(q(at(2026,6,15,22,0), "22:00", "07:00") == at(2026,6,16,7,0))    // exactly start → defers
        #expect(q(at(2026,6,15,7,0),  "22:00", "07:00") == at(2026,6,15,7,0))    // exactly end → unchanged
    }
    @Test func quietSameDay() {
        #expect(q(at(2026,6,15,12,0), "09:00", "17:00") == at(2026,6,15,17,0))
        #expect(q(at(2026,6,15,8,0),  "09:00", "17:00") == at(2026,6,15,8,0))
        #expect(q(at(2026,6,15,18,0), "09:00", "17:00") == at(2026,6,15,18,0))
        #expect(q(at(2026,6,15,9,0),  "09:00", "17:00") == at(2026,6,15,17,0))   // exactly start → defers
        #expect(q(at(2026,6,15,17,0), "09:00", "17:00") == at(2026,6,15,17,0))   // exactly end → unchanged
    }
    @Test func quietNilOrZeroLengthIsUnchanged() {
        #expect(q(at(2026,6,15,23,0), nil, "07:00") == at(2026,6,15,23,0))
        #expect(q(at(2026,6,15,23,0), "22:00", nil) == at(2026,6,15,23,0))
        #expect(q(at(2026,6,15,22,0), "22:00", "22:00") == at(2026,6,15,22,0))
    }

    // MARK: applyQuietHours across DST transitions — locks wall-clock reconstruction
    @Test func quietHoursDefersToWallClockEndAcrossDST() {
        // America/New_York observes DST, so the window-end must be rebuilt as a wall-clock
        // time (07:00 local) rather than by adding elapsed hours. With the elapsed-time bug
        // the resolved hour would be 08 (spring-forward) or 06 (fall-back) instead of 07.
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        func nyAt(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
            ny.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
        }
        func deferredHour(_ fire: Date) -> Int {
            let target = ReminderMath.applyQuietHours(fire, quietStart: "22:00", quietEnd: "07:00", calendar: ny)
            return ny.component(.hour, from: target)
        }
        // Spring-forward night: clocks jump 02:00 → 03:00 on 2026-03-08. A 23:30 fire defers
        // to 07:00 EDT the next morning, not 08:00.
        #expect(deferredHour(nyAt(2026, 3, 8, 23, 30)) == 7)
        // Fall-back night: clocks fall 02:00 → 01:00 on 2026-11-01. A 23:30 fire defers to
        // 07:00 EST the next morning, not 06:00.
        #expect(deferredHour(nyAt(2026, 11, 1, 23, 30)) == 7)
    }

    // MARK: badgeCount — probe badge 8/8
    private func dueTask(_ due: Date?, completed: Bool = false) -> Task {
        Task(id: UUID().uuidString, title: "t", urgent: false, important: false, completed: completed,
             createdAt: at(2026,6,1), updatedAt: at(2026,6,1), dueDate: due)
    }
    @Test func badgeBoundary() {
        #expect(ReminderMath.badgeCount(tasks: [dueTask(at(2026,6,14))], now: now, calendar: cal) == 1)
        #expect(ReminderMath.badgeCount(tasks: [dueTask(at(2026,6,15,0,0))], now: now, calendar: cal) == 1)
        #expect(ReminderMath.badgeCount(tasks: [dueTask(at(2026,6,16,0,0))], now: now, calendar: cal) == 0)
        #expect(ReminderMath.badgeCount(tasks: [dueTask(at(2026,6,14), completed: true)], now: now, calendar: cal) == 0)
        #expect(ReminderMath.badgeCount(tasks: [dueTask(nil)], now: now, calendar: cal) == 0)
    }
    @Test func badgeMixedSet() {
        let ts = [dueTask(at(2026,6,10)), dueTask(at(2026,6,15,8,0)), dueTask(at(2026,6,15,0,0)),
                  dueTask(at(2026,6,16,0,0)), dueTask(at(2026,6,20)),
                  dueTask(at(2026,6,9), completed: true), dueTask(nil)]
        #expect(ReminderMath.badgeCount(tasks: ts, now: now, calendar: cal) == 3)
    }
}
