import WidgetKit
import SwiftUI

@main
struct GSDWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        GSDWatchWidget()
        CaptureControl()
    }
}
