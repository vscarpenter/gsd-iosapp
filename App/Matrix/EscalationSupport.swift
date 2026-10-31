import SwiftUI
import GSDModel

private struct EscalationWindowKey: EnvironmentKey {
    static let defaultValue = EscalationWindow.default
}

extension EnvironmentValues {
    /// The per-device "Escalate tasks due within" setting. Injected once at the root from
    /// app-group defaults so every card, menu, and swipe reads (and re-renders on) the same value.
    var escalationWindow: EscalationWindow {
        get { self[EscalationWindowKey.self] }
        set { self[EscalationWindowKey.self] = newValue }
    }
}

extension Task {
    /// The escalation verdict in the device's current time zone (spec-escalation §3).
    func escalation(window: EscalationWindow, now: Date = .now) -> Escalation.Result {
        Escalation.evaluate(self, now: now, windowDays: window.days, timeZone: .current)
    }
}

extension Escalation.Target {
    /// The target quadrant's pigment: rust for Do First, ochre for Delegate.
    var accent: Color { QuadrantStyle.accent(quadrant) }
}

extension EscalationWindow {
    var label: String {
        switch self {
        case .off: String(localized: "Off")
        case .oneDay: String(localized: "1 day")
        case .twoDays: String(localized: "2 days")
        case .threeDays: String(localized: "3 days")
        case .oneWeek: String(localized: "1 week")
        }
    }
}
