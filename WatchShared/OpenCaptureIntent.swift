import AppIntents
import Foundation
import GSDModel
import GSDSnapshot

/// Opens the watch app on Capture. Compiled into both `GSDWatch` and `GSDWatchWidgets`: the
/// control in the widget extension names it, and the system runs it in the app (spec 4.5).
struct CaptureDestination: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Capture"
    static let defaultQuery = CaptureDestinationQuery()
    var id: String { "capture" }
    var displayRepresentation: DisplayRepresentation { "New task" }
}

struct CaptureDestinationQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [CaptureDestination] { [CaptureDestination()] }
    func suggestedEntities() async throws -> [CaptureDestination] { [CaptureDestination()] }
}

struct OpenCaptureIntent: OpenIntent {
    static let title: LocalizedStringResource = "Add a task"
    @Parameter(title: "Destination") var target: CaptureDestination

    init() { target = CaptureDestination() }

    func perform() async throws -> some IntentResult {
        if let defaults = UserDefaults(suiteName: AppGroup.id) { WatchCaptureRequest.request(in: defaults) }
        return .result()
    }
}
