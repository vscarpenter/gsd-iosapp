import AppIntents
import SwiftUI
import WidgetKit

/// A Control that opens Capture from Control Center, the Smart Stack, or the Action button on
/// Ultra (spec 4.5, item 5).
struct CaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "GSDWatchCaptureControl") {
            ControlWidgetButton(action: OpenCaptureIntent()) {
                Label("Add task", systemImage: "plus")
            }
        }
        .displayName("Add task")
        .description("Open GSD on a new task.")
    }
}
