import SwiftUI
import GSDModel
import GSDSnapshot

@main
struct GSDWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @State private var model = WatchModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var page = Page.today

    private enum Page { case today, doFirst }

    var body: some Scene {
        WindowGroup {
            // Today is the home page; Do First sits below it. A tapped reminder or a Capture
            // request lands on Do First, which already handles both.
            TabView(selection: $page) {
                TodayView().tag(Page.today)
                DoFirstView().tag(Page.doFirst)
            }
            .tabViewStyle(.verticalPage)
                .environment(model)
                .onChange(of: model.openedTaskID, initial: true) { _, id in if id != nil { page = .doFirst } }
                .onChange(of: model.captureRequested, initial: true) { _, requested in if requested { page = .doFirst } }
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
