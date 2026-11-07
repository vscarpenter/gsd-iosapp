import Foundation

/// One run through the weekly sweep (spec-weekly-sweep section 4). Pure state: the cards are
/// computed once when the sweep opens and later syncs never reorder them. It writes nothing. The
/// screen stamps "last swept" only when `reachedEnd` is true or the user taps Done.
public struct SweepSession: Sendable, Equatable {
    public let cards: [WeeklySweep.Card]
    private var index = 0
    /// True once the user moved past the last card. A sweep that opened with nothing to do is
    /// finished but never reached the end, so it stamps nothing.
    public private(set) var reachedEnd = false

    public init(cards: [WeeklySweep.Card]) {
        self.cards = cards
    }

    public var isFinished: Bool { index >= cards.count }

    public var current: WeeklySweep.Card? { isFinished ? nil : cards[index] }

    /// "3 of 12": position only, with no bar and no percentage.
    public var position: String? {
        isFinished ? nil : String(localized: "\(index + 1) of \(cards.count)")
    }

    /// Skip, and the step after any action. Skip writes nothing; the card can return next time.
    public mutating func advance() {
        guard !isFinished else { return }
        index += 1
        if isFinished { reachedEnd = true }
    }

    /// Before each card is shown, drop the ones whose task no longer qualifies for any card
    /// (completed or edited elsewhere), without saying so. `qualifying` is the ids that still do.
    public mutating func settle(qualifying: Set<String>) {
        while let card = current, !qualifying.contains(card.id) {
            advance()
        }
    }

    /// After "That's the sweep.", offer "Pick today's top three" only on a client where top three
    /// has shipped, and only while today has a free slot (SPEC-7). A full day ends on the line alone.
    public static func offersTopThree(freeSlot: Bool, topThreeShipped: Bool) -> Bool {
        freeSlot && topThreeShipped
    }
}
