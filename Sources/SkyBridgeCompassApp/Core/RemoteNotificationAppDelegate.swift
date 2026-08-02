import AppKit
import Foundation
import Security
import SkyBridgeCore

/// Receives silent CloudKit pushes so the app can refresh without waiting for the 60 s poll.
///
/// SwiftUI has no entry point for remote notifications, so an `NSApplicationDelegate` is required.
/// This delegate is deliberately limited to the remote-notification path: adding unrelated lifecycle
/// work here would recreate the "everything happens in the app delegate" pattern the project avoids.
///
/// Registration is not a capability declaration on its own — a push only reaches the process when a
/// subsystem owns a matching CloudKit subscription, which `RemoteNotificationRouter` enforces.
@available(macOS 14.0, *)
final class RemoteNotificationAppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Self.hasRemoteNotificationEntitlement() else {
            SkyBridgeLogger.ui.error(
                "⛔️ 当前签名不含 macOS APNs entitlement；CloudKit 静默推送唤醒保持停用"
            )
            return
        }
        // Requesting the token is safe without user-facing notification authorization: silent
        // (`content-available`) pushes require no alert permission.
        NSApplication.shared.registerForRemoteNotifications()
        SkyBridgeLogger.ui.info("📮 已请求远程通知注册（用于 CloudKit 静默推送唤醒）")
    }

    private static func hasRemoteNotificationEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.aps-environment" as CFString,
                nil
              ) as? String else {
            return false
        }
        return value == "development" || value == "production"
    }

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // The token itself is never logged: it is a routable identifier for this install.
        SkyBridgeLogger.ui.info(
            "✅ 远程通知注册成功: tokenBytes=\(deviceToken.count, privacy: .public)"
        )
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Surfaced rather than swallowed: without a token the CloudKit wake channel is silently
        // absent and the app falls back to polling, which is exactly the degradation that must not
        // pass unnoticed.
        SkyBridgeLogger.ui.error(
            "❌ 远程通知注册失败，CloudKit 静默推送唤醒不可用: \(error.localizedDescription, privacy: .public)"
        )
    }

    func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        // Reduce the non-Sendable payload here, on the thread that received it, before crossing
        // into the router actor.
        let descriptor = RemoteNotificationPayloadDescriptor(
            remoteNotificationUserInfo: userInfo
        )
        // AppKit has no completion handler here, so the outcome is only logged. The router still
        // computes it because the iOS delegate must report it to the system.
        Task {
            let outcome = await RemoteNotificationRouter.shared.handle(descriptor: descriptor)
            SkyBridgeLogger.ui.info(
                "📬 远程通知处理完成: outcome=\(outcome.rawValue, privacy: .public)"
            )
        }
    }
}
