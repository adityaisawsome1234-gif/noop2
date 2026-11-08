import SwiftUI
import FormaFeatures

@main
struct FormaApp: App {
    /// Created at process start, before any UI: the Bluetooth central (with its constant restoration
    /// identifier) must exist immediately when iOS relaunches Forma for a Bluetooth event.
    @State private var model = AppModel.makeForIOS()
    @State private var appLock = AppLock()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(appLock)
        }
    }
}
