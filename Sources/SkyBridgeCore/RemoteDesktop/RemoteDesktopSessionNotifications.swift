import Foundation

public enum RemoteDesktopSessionTerminationKind: String, Sendable, Equatable {
    case normal
    case interrupted
}

public enum RemoteDesktopSessionTerminationPolicy {
    public static func notificationKind(
        disconnectKind: SessionDisconnectKind,
        reason: String,
        hadUserVisibleSession: Bool
    ) -> RemoteDesktopSessionTerminationKind? {
        guard hadUserVisibleSession else { return nil }

        switch disconnectKind {
        case .remoteLeave:
            return .normal
        case .transient:
            return .interrupted
        case .explicit:
            return explicitTerminationKind(reason: reason)
        }
    }

    public static func explicitTerminationKind(reason: String) -> RemoteDesktopSessionTerminationKind {
        let normalized = normalize(reason)
        guard !normalized.isEmpty else { return .normal }

        if explicitNormalReasons.contains(normalized) {
            return .normal
        }

        if explicitInterruptedFragments.contains(where: { normalized.contains($0) }) {
            return .interrupted
        }

        return .normal
    }

    public static func notificationDedupeKey(
        sessionID: String,
        transport: String,
        role: String?
    ) -> String {
        let session = normalize(sessionID)
        let normalizedTransport = normalize(transport)
        let normalizedRole = normalize(role ?? "session")
        return "\(normalizedTransport)|\(normalizedRole)|\(session)"
    }

    private static let explicitNormalReasons: Set<String> = [
        "explicit_disconnect",
        "manual_disconnect",
        "p2p_superseded_by_new_session",
        "p2p_user_stop",
        "rdp_manager_stop",
        "rdp_terminate",
        "remote_control_notice_disconnect",
        "user_disconnect",
        "viewer_disconnect_transport"
    ]

    private static let explicitInterruptedFragments: [String] = [
        "aborted",
        "closed",
        "failed",
        "failure",
        "forbidden",
        "handshake",
        "invalid",
        "lost",
        "missing",
        "rejected",
        "rejection",
        "strict",
        "timeout",
        "unavailable",
        "untrusted"
    ]

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

@MainActor
public final class RemoteDesktopSessionNotificationService {
    public static let shared = RemoteDesktopSessionNotificationService()

    public static let categoryIdentifier = "REMOTE_DESKTOP_SESSION"

    private var sentTerminalNotificationKeys: Set<String> = []

    private init() {}

    public func beginSession(
        sessionID: String,
        transport: String,
        role: String? = nil
    ) {
        let key = RemoteDesktopSessionTerminationPolicy.notificationDedupeKey(
            sessionID: sessionID,
            transport: transport,
            role: role
        )
        sentTerminalNotificationKeys.remove(key)
    }

    public func sendTerminalNotificationIfNeeded(
        sessionID: String,
        deviceName: String?,
        transport: String,
        role: String? = nil,
        kind: RemoteDesktopSessionTerminationKind,
        reason: String? = nil
    ) {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionID.isEmpty else { return }

        let key = RemoteDesktopSessionTerminationPolicy.notificationDedupeKey(
            sessionID: trimmedSessionID,
            transport: transport,
            role: role
        )
        guard sentTerminalNotificationKeys.insert(key).inserted else { return }

        let titleKey: String
        let bodyKey: String
        let bodyWithDeviceKey: String
        switch kind {
        case .normal:
            titleKey = "notifications.remoteDesktop.ended.title"
            bodyKey = "notifications.remoteDesktop.ended.body"
            bodyWithDeviceKey = "notifications.remoteDesktop.ended.bodyWithDevice"
        case .interrupted:
            titleKey = "notifications.remoteDesktop.interrupted.title"
            bodyKey = "notifications.remoteDesktop.interrupted.body"
            bodyWithDeviceKey = "notifications.remoteDesktop.interrupted.bodyWithDevice"
        }

        let name = meaningfulDeviceName(deviceName)
        let body = name.map {
            String(
                format: LocalizationManager.shared.localizedString(bodyWithDeviceKey),
                locale: LocalizationManager.shared.locale,
                $0
            )
        } ?? LocalizationManager.shared.localizedString(bodyKey)

        var userInfo: [AnyHashable: Any] = [
            "kind": "REMOTE_DESKTOP_SESSION",
            "sessionId": trimmedSessionID,
            "transport": transport,
            "terminalKind": kind.rawValue
        ]
        if let role {
            userInfo["role"] = role
        }
        if let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userInfo["reason"] = reason
        }

        SettingsManager.shared.sendSystemNotification(
            title: LocalizationManager.shared.localizedString(titleKey),
            body: body,
            identifier: "remote-desktop-\(key)",
            categoryIdentifier: Self.categoryIdentifier,
            userInfo: userInfo
        )
    }

    private func meaningfulDeviceName(_ deviceName: String?) -> String? {
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
