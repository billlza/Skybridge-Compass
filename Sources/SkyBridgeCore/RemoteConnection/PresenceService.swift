import Foundation
import Combine
#if canImport(AppKit)
import AppKit
#endif

/// 跨网在线状态服务（F2-B / 向日葵·ToDesk 式）：
/// - 周期性向信令服务器注册本设备在线（心跳），使本账号的其它设备能看到自己在线（即使跨网络）。
/// - 周期性查询「本账号受信设备」中当前在线的子集，发布给 UI 显示「在线」指示。
///
/// 复用 `CrossNetworkConnectionManager` 已配置的 `SignalServerClient`（bearer/tenant 鉴权）。presence 键由服务端
/// 用已验证 JWT 的 tenantId:userId:deviceId 构成，因此只能看到「自己账号」的设备在线状态（隐私安全）。
/// 端到端验证需要：把更新后的 `Server/skybridge-signaling/server.js` 部署到信令服务器。
@available(macOS 14.0, iOS 17.0, *)
@MainActor
public final class PresenceService: ObservableObject {
    public static let shared = PresenceService()

    /// 当前在线的受信设备 id 集合（以 TrustRecord.currentDeviceId 为键）。
    @Published public private(set) var onlinePeerDeviceIds: Set<String> = []

    private var loopTask: Task<Void, Never>?
    private var started = false
    /// 心跳/轮询间隔（秒）。需与服务端 PRESENCE_TTL_MS(默认 90s) 留足余量，避免单次丢心跳即判离线。
    private let intervalSeconds: UInt64 = 30

    private init() {}

    /// 启动心跳 + 轮询（幂等）。未登录时各次请求会安全失败（忽略），不影响其它功能。
    public func start() {
        guard !started else { return }
        started = true
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(nanoseconds: self.intervalSeconds * 1_000_000_000)
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        started = false
        onlinePeerDeviceIds = []
    }

    /// 立即触发一次（例如前台恢复时）。
    public func triggerRefresh() {
        guard started else { return }
        Task { await tick() }
    }

    private func tick() async {
        // 1) 注册本设备在线（心跳）。未登录/网络失败时忽略。
        _ = try? await CrossNetworkConnectionManager.shared.registerDevicePresence(deviceName: Self.localDeviceName())

        // 2) 查询本账号受信设备的在线子集。
        let trustedIds = Set(
            TrustSyncService.shared.activeTrustRecords
                .map { $0.currentDeviceId }
                .filter { !$0.isEmpty }
        )
        guard !trustedIds.isEmpty else {
            if !onlinePeerDeviceIds.isEmpty { onlinePeerDeviceIds = [] }
            return
        }
        if let online = try? await CrossNetworkConnectionManager.shared.queryDevicePresence(deviceIDs: Array(trustedIds)) {
            let set = Set(online)
            if set != onlinePeerDeviceIds { onlinePeerDeviceIds = set }
        }
    }

    /// 该设备是否在线（按 TrustRecord 的任一已知 id 命中）。
    public func isOnline(deviceId: String) -> Bool {
        !deviceId.isEmpty && onlinePeerDeviceIds.contains(deviceId)
    }

    private static func localDeviceName() -> String {
        #if canImport(AppKit)
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        let name = ProcessInfo.processInfo.hostName
        #endif
        return String(name.prefix(128))
    }
}
