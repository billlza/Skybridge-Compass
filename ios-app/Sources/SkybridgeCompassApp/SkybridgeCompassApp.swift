import SwiftUI
import SkyBridgeCore

@main
struct SkybridgeCompassApp: App {
    @State private var appState = SkybridgeAppState()

    var body: some Scene {
        WindowGroup {
            RootView(appState: appState)
        }
    }
}
