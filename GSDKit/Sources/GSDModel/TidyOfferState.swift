/// Whether "Not now" was tapped on the "Two devices picked for today. Tidy up?" offer (spec-top-three
/// section 4). It lasts until the next launch, so the offer comes back only on a new run of the app,
/// not when the Matrix view is rebuilt. The app holds one `shared` instance for the whole process;
/// nothing is stored, so a relaunch starts with the offer showing again.
@MainActor
public final class TidyOfferState {
    public static let shared = TidyOfferState()

    public init() {}

    public private(set) var isDismissed = false

    /// "Not now": write nothing, and stop offering until the next launch.
    public func dismiss() { isDismissed = true }
}
