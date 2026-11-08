import SwiftUI
import GSDModel

@main
struct GSDWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @State private var model = WatchModel.shared

    var body: some Scene {
        WindowGroup {
            DoFirstView()
                .environment(model)
                .task { model.start() }
        }
        WKNotificationScene(controller: ReminderNotificationController.self,
                            category: ReminderAction.categoryID)
    }
}
