import Testing
@testable import GSDModel

/// T8: "Not now" lasts until the next launch, not until the view goes away.
@MainActor
struct TidyOfferStateTests {
    @Test func theOfferShowsUntilNotNowIsTapped() {
        #expect(!TidyOfferState().isDismissed)
    }

    @Test func notNowSurvivesTheMatrixBeingRebuilt() {
        // The app keeps one instance for the process, so a view that remounts reads the same state.
        let process = TidyOfferState()
        process.dismiss()
        let remountedViewReads = process.isDismissed
        #expect(remountedViewReads)
    }

    @Test func aNewLaunchStartsWithTheOfferShowing() {
        let firstLaunch = TidyOfferState()
        firstLaunch.dismiss()
        let nextLaunch = TidyOfferState()   // a new process builds a new instance; nothing is stored
        #expect(firstLaunch.isDismissed)
        #expect(!nextLaunch.isDismissed)
    }
}
