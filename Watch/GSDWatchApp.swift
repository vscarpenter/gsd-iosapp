import SwiftUI

@main
struct GSDWatchApp: App {
    @State private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            DoFirstView()
                .environment(model)
                .task { model.start() }
        }
    }
}
