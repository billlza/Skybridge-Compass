import SwiftUI

@main
struct SkybridgeCompassApp: App {
    @State private var viewModel = DashboardViewModel()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environment(viewModel)
                .task {
                    await viewModel.refreshOnce()
                }
        }
    }
}
