import Foundation
import Combine
import os

enum DeviceMessagingError: Error { case notDeliverable }

/// 设备间文本消息服务：把 `DeviceMessageStore`（会话历史）、`OfflineMessageQueue`（离线排队）与
/// P2P 传输（`AppMessage.textMessage`）粘合在一起。
///
/// - 发送：在线（已认证连接）则直接经 P2P 发出并标记“已发送”；否则入离线队列，待设备上线后自动投递。
/// - 上线驱动：跟随 `P2PNetworkManager.activeConnections` 的「已认证」集合变化，调用队列的
///   `deviceOnline/deviceOffline`（上线即 flush 待发消息）。
/// - 接收：由 `P2PConnection.handleAppMessage` 调用 `handleIncoming` 落库（按发送者公钥指纹归档）。
/// 跨平台（不依赖 AppKit）。
@available(macOS 14.0, iOS 17.0, *)
@MainActor
public final class DeviceMessagingService: ObservableObject {
    public static let shared = DeviceMessagingService()

    private let log = Logger(subsystem: "com.skybridge.compass", category: "DeviceMessaging")
    private var started = false
    private var cancellables = Set<AnyCancellable>()
    private var onlineDeviceIds: Set<String> = []

    /// 离线队列 payload 信封：携带文本消息 + 稳定指纹（投递后回填会话存储用）。
    private struct QueuedTextEnvelope: Codable {
        let payload: AppMessage.TextMessagePayload
        let fingerprint: String
    }

    private init() {}

    /// 启动（幂等）：接入离线队列投递回调 + 跟随活动连接驱动上线/下线。应在 P2P 服务就绪后调用一次。
    public func start() {
        guard !started else { return }
        started = true

        OfflineMessageQueue.shared.sendHandler = { [weak self] queued in
            try await self?.deliver(queued)
        }

        P2PNetworkManager.shared.$activeConnections
            .receive(on: DispatchQueue.main)
            .sink { [weak self] conns in
                self?.syncOnline(conns)
            }
            .store(in: &cancellables)
    }

    private func syncOnline(_ conns: [String: P2PConnection]) {
        let authed = Set(conns.filter { $0.value.status == .authenticated }.keys)
        let newlyOnline = authed.subtracting(onlineDeviceIds)
        let wentOffline = onlineDeviceIds.subtracting(authed)
        onlineDeviceIds = authed
        for id in newlyOnline {
            Task { await OfflineMessageQueue.shared.deviceOnline(id) } // 标记上线 + flush 待发消息
        }
        for id in wentOffline {
            OfflineMessageQueue.shared.deviceOffline(id)
        }
    }

    /// 发送一条文本消息。
    /// - Parameters:
    ///   - deviceId: 当前用于投递的设备 id（活动连接键 / 离线队列目标）。
    ///   - fingerprint: 稳定公钥指纹（会话历史键）。
    public func send(text: String, toDeviceId deviceId: String, fingerprint: String) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, !fingerprint.isEmpty, !deviceId.isEmpty else { return }
        let payload = AppMessage.TextMessagePayload(text: trimmedText)
        DeviceMessageStore.shared.appendOutgoing(text: trimmedText, fingerprint: fingerprint, messageId: payload.id)

        if let conn = P2PNetworkManager.shared.activeConnections[deviceId], conn.status == .authenticated {
            do {
                try await conn.sendAppMessage(.textMessage(payload))
                DeviceMessageStore.shared.markDelivered(messageId: payload.id, fingerprint: fingerprint)
                return
            } catch {
                log.warning("📨 直接发送失败，转入离线队列: \(error.localizedDescription, privacy: .public)")
            }
        }
        await enqueue(payload: payload, fingerprint: fingerprint, deviceId: deviceId)
    }

    private func enqueue(payload: AppMessage.TextMessagePayload, fingerprint: String, deviceId: String) async {
        guard let data = try? JSONEncoder().encode(QueuedTextEnvelope(payload: payload, fingerprint: fingerprint)) else { return }
        _ = try? await OfflineMessageQueue.shared.enqueue(
            targetDeviceID: deviceId,
            messageType: .text,
            priority: .normal,
            payload: data
        )
    }

    /// 离线队列投递回调（设备上线 flush 时调用）。
    private func deliver(_ queued: QueuedMessage) async throws {
        guard queued.messageType == .text,
              let envelope = try? JSONDecoder().decode(QueuedTextEnvelope.self, from: queued.payload) else {
            return // 非本服务负责的消息类型：忽略（兼容队列的其他未来用途）
        }
        guard let conn = P2PNetworkManager.shared.activeConnections[queued.targetDeviceID],
              conn.status == .authenticated else {
            throw DeviceMessagingError.notDeliverable // 当前不可投递：抛出以让队列保留，待下次上线重试
        }
        try await conn.sendAppMessage(.textMessage(envelope.payload))
        DeviceMessageStore.shared.markDelivered(messageId: envelope.payload.id, fingerprint: envelope.fingerprint)
    }

    /// 收到远端文本消息（由 P2PConnection.handleAppMessage 调用）。
    public func handleIncoming(_ payload: AppMessage.TextMessagePayload, fingerprint: String) {
        DeviceMessageStore.shared.receiveIncoming(
            text: payload.text,
            fingerprint: fingerprint,
            messageId: payload.id,
            sentAt: payload.sentAt
        )
    }
}
