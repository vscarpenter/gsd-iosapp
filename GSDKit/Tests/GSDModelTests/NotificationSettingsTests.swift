import Testing
@testable import GSDModel

/// The editor's reminder picker derives its rows from this list: the canonical five
/// presets (§5.4) plus, when the stored `notifyBefore` is off-list, that value offered
/// in sorted position rather than snapped — mirroring the web's reminder control so an
/// existing task's choice (e.g. `notifyBefore: 5` from an older editor) is never
/// silently rewritten.
struct NotificationSettingsTests {
    @Test func optionsAreTheCanonicalPresetsWhenNothingIsStored() {
        #expect(NotificationSettings.reminderOptions(including: nil) == [15, 30, 60, 120, 1440])
    }

    @Test func anOnListStoredValueAddsNothing() {
        #expect(NotificationSettings.reminderOptions(including: 60) == [15, 30, 60, 120, 1440])
        #expect(NotificationSettings.reminderOptions(including: 1440) == [15, 30, 60, 120, 1440])
    }

    @Test func anOffListStoredValueIsOfferedInSortedPosition() {
        #expect(NotificationSettings.reminderOptions(including: 5) == [5, 15, 30, 60, 120, 1440])
        #expect(NotificationSettings.reminderOptions(including: 45) == [15, 30, 45, 60, 120, 1440])
        #expect(NotificationSettings.reminderOptions(including: 2880) == [15, 30, 60, 120, 1440, 2880])
    }

    @Test func atTimeOfEventZeroIsOfferedFirst() {
        #expect(NotificationSettings.reminderOptions(including: 0) == [0, 15, 30, 60, 120, 1440])
    }
}
