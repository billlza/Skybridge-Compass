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

enum RemoteDesktopTerminalNotificationKind: String, Sendable {
    case normal
    case interrupted
}

/// 通知管理器
@MainActor
class NotificationManager {
    static let remoteDesktopSessionCategoryIdentifier = "REMOTE_DESKTOP_SESSION"
    private static var sentRemoteDesktopTerminalNotificationKeys: Set<String> = []

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

    static func beginRemoteDesktopSession(
        sessionId: String,
        transport: String,
        role: String? = nil
    ) {
        sentRemoteDesktopTerminalNotificationKeys.remove(
            remoteDesktopNotificationDedupeKey(
                sessionId: sessionId,
                transport: transport,
                role: role
            )
        )
    }

    static func sendRemoteDesktopTerminalNotificationIfNeeded(
        sessionId: String,
        deviceName: String?,
        transport: String,
        role: String? = nil,
        kind: RemoteDesktopTerminalNotificationKind,
        reason: String? = nil
    ) async {
#if os(iOS)
        let trimmedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionId.isEmpty else { return }

        let key = remoteDesktopNotificationDedupeKey(
            sessionId: trimmedSessionId,
            transport: transport,
            role: role
        )
        guard sentRemoteDesktopTerminalNotificationKeys.insert(key).inserted else { return }

        let titleKey: String
        let bodyKey: String
        let bodyWithDeviceKey: String
        switch kind {
        case .normal:
            titleKey = "remoteDesktop.notification.ended.title"
            bodyKey = "remoteDesktop.notification.ended.body"
            bodyWithDeviceKey = "remoteDesktop.notification.ended.bodyWithDevice"
        case .interrupted:
            titleKey = "remoteDesktop.notification.interrupted.title"
            bodyKey = "remoteDesktop.notification.interrupted.body"
            bodyWithDeviceKey = "remoteDesktop.notification.interrupted.bodyWithDevice"
        }

        let meaningfulName = meaningfulDeviceName(deviceName)
        let body = meaningfulName.map {
            RuntimeLocalization.format(bodyWithDeviceKey, [$0])
        } ?? RuntimeLocalization.string(bodyKey)

        let content = UNMutableNotificationContent()
        content.title = RuntimeLocalization.string(titleKey)
        content.body = body
        content.sound = .default
        content.categoryIdentifier = remoteDesktopSessionCategoryIdentifier
        content.threadIdentifier = "remote-desktop-\(trimmedSessionId)"
        var userInfo: [AnyHashable: Any] = [
            "kind": "REMOTE_DESKTOP_SESSION",
            "sessionId": trimmedSessionId,
            "transport": transport,
            "terminalKind": kind.rawValue
        ]
        if let role {
            userInfo["role"] = role
        }
        if let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userInfo["reason"] = reason
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: "remote-desktop-\(key)",
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            SkyBridgeLogger.shared.warning(
                "⚠️ 发送远程桌面终态通知失败: \(error.localizedDescription)"
            )
        }
#else
        _ = (sessionId, deviceName, transport, role, kind, reason)
#endif
    }

    private static func remoteDesktopNotificationDedupeKey(
        sessionId: String,
        transport: String,
        role: String?
    ) -> String {
        [
            transport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            (role ?? "session").trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            sessionId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ].joined(separator: "|")
    }

    private static func meaningfulDeviceName(_ deviceName: String?) -> String? {
        guard let trimmed = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != "Remote Device",
              trimmed != "Unknown Device",
              trimmed != "-",
              trimmed.lowercased() != "missing" else {
            return nil
        }
        return trimmed
    }
}
