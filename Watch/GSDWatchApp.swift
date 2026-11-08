import SwiftUI
import GSDModel
import GSDSnapshot

@main
struct GSDWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @State private var model = WatchModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            DoFirstView()
                .environment(model)
                .task { model.start() }
                .onOpenURL { model.open(url: $0) }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active { model.consumeCaptureRequest() }
                }
        }
        WKNotificationScene(controller: ReminderNotificationController.self,
                            category: ReminderAction.categoryID)
    }
}
