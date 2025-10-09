import SwiftUI
import WidgetKit
import SkyBridgeCore
import UserNotifications
import os.log
import AppKit

@main
struct SkyBridgeCompassApp: App {
    @StateObject private var appModel = DashboardViewModel()
    @StateObject private var authModel = AuthenticationViewModel()

    var body: some Scene {
        WindowGroup("云桥司南") {
            RootContainerView()
                .environmentObject(appModel)
                .environmentObject(authModel)
                .frame(minWidth: 1280, minHeight: 720)
        }
        .windowStyle(.automatic)
    }
    init() {
        if #available(macOS 14.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
        }
        BackgroundTaskCoordinator.shared.registerSystemTasks()
        configureNotifications()
    }

    private func configureNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                Logger(subsystem: "com.skybridge.compass", category: "Notifications").error("Notification authorization failed: %{public}@", error.localizedDescription)
            } else {
                Logger(subsystem: "com.skybridge.compass", category: "Notifications").info("Notification authorization granted: %{public}@", String(granted))
            }
        }
        DispatchQueue.main.async {
            NSApplication.shared.registerForRemoteNotifications()
        }
    }
}

/// 根容器视图，根据认证状态展示登录界面或主控面板。
private struct RootContainerView: View {
    @EnvironmentObject private var dashboardModel: DashboardViewModel
    @EnvironmentObject private var authModel: AuthenticationViewModel

    var body: some View {
        Group {
            if let session = authModel.currentSession {
                DashboardView()
                    .onAppear {
                        dashboardModel.updateAuthentication(session: session)
                    }
            } else {
                AuthenticationView()
                    .onAppear {
                        dashboardModel.updateAuthentication(session: nil)
                    }
            }
        }
        .onChange(of: authModel.currentSession) { newSession in
            dashboardModel.updateAuthentication(session: newSession)
        }
        .animation(.easeInOut(duration: 0.25), value: authModel.currentSession != nil)
    }
}
