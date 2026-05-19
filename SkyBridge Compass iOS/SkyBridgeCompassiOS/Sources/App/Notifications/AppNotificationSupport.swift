import Foundation

#if os(iOS)
import UserNotifications

/// 通知代理
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationDelegate()

    private override init() {
        super.init()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // 前台显示通知
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let actionIdentifier = response.actionIdentifier
        let deviceID = userInfo["deviceID"] as? String

        // 处理通知响应（仅捕获 Sendable 数据，避免 Swift 6.2 并发发送检查报错）
        Task { @MainActor [actionIdentifier, deviceID] in
            await handleNotificationResponse(actionIdentifier, deviceID: deviceID)
        }

        completionHandler()
    }

    private func handleNotificationResponse(_ actionIdentifier: String, deviceID: String?) async {
        switch actionIdentifier {
        case "ACCEPT":
            // 处理连接请求接受
            if let deviceID {
                await P2PConnectionManager.instance.acceptConnection(from: deviceID)
            }

        case "REJECT":
            // 处理连接请求拒绝
            if let deviceID {
                await P2PConnectionManager.instance.rejectConnection(from: deviceID)
            }

        case "KEEP_CONNECTION":
            await CrossNetworkWebRTCManager.instance.disarmIdleConnectionReminder(clearPrompt: true)

        case "DISCONNECT_CONNECTION":
            await CrossNetworkWebRTCManager.instance.disconnect()

        default:
            break
        }
    }
}
#else
@MainActor
class NotificationDelegate: NSObject {
    static let shared = NotificationDelegate()
    private override init() { super.init() }
}
#endif

/// 通知管理器
@MainActor
class NotificationManager {
    static func requestAuthorization() async {
#if os(iOS)
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])

            if granted {
                SkyBridgeLogger.shared.info("✅ 通知权限已授予")
            } else {
                SkyBridgeLogger.shared.warning("⚠️ 通知权限被拒绝")
            }
        } catch {
            SkyBridgeLogger.shared.error("❌ 通知权限请求失败: \(error.localizedDescription)")
        }
#else
        SkyBridgeLogger.shared.info("ℹ️ Notification authorization not applicable on this platform build")
#endif
    }
}
