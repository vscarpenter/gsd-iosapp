import Foundation
import GSDModel

/// What the Today screen draws (watch spec 4.1). The rules live in `TopThree`; this holds the
/// answer and the words for it.
public struct WatchToday: Sendable, Equatable {
    /// Today's picks in rank order.
    public var picks: [WatchTask]
    /// With no picks, the first three suggestions, each offered with "Add to today".
    public var suggestions: [WatchTask]
    /// False when three picks are in: "Add to today" is hidden on other rows.
    public var canAdd: Bool

    public init(picks: [WatchTask], suggestions: [WatchTask], canAdd: Bool) {
        self.picks = picks
        self.suggestions = suggestions
        self.canAdd = canAdd
    }

    /// "Today, 2 of 3".
    public var sectionLabel: String {
        String(localized: "Today, \(picks.count) of \(TopThree.maxPicks)")
    }

    /// A pick row reads its title, then its place: "Call Sam, first".
    public func rowLabel(at index: Int) -> String {
        let title = picks[index].title
        switch index {
        case 0: return String(localized: "\(title), first")
        case 1: return String(localized: "\(title), second")
        default: return String(localized: "\(title), third")
        }
    }
}
