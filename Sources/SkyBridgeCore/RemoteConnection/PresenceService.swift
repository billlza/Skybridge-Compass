import Foundation
import Combine
import OSLog
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
    private static let maximumQueryBatchSize = 200

    typealias RegistrationOperation = @MainActor () async throws -> Void
    typealias QueryOperation = @MainActor ([String]) async throws -> [String]
    typealias TrustedDeviceIDsProvider = @MainActor () -> Set<String>
    typealias NowProvider = @MainActor () -> Date

    /// 当前在线的受信设备 id 集合（以 TrustRecord.currentDeviceId 为键）。
    @Published public private(set) var onlinePeerDeviceIds: Set<String> = []

    private var loopTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshToken: UUID?
    private var started = false
    private var lifecycleGeneration: UInt64 = 0
    private var lastSuccessfulQueryAt: Date?
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "Presence")
    private let refreshInterval: Duration
    private let onlineStateTTL: TimeInterval
    private let now: NowProvider
    private let registerPresence: RegistrationOperation
    private let queryPresence: QueryOperation
    private let trustedDeviceIDs: TrustedDeviceIDsProvider

    private convenience init() {
        self.init(
            refreshInterval: .seconds(30),
            onlineStateTTL: 90,
            now: Date.init,
            registerPresence: {
                _ = try await CrossNetworkConnectionManager.shared.registerDevicePresence(
                    deviceName: Self.localDeviceName()
                )
            },
            queryPresence: { deviceIDs in
                try await CrossNetworkConnectionManager.shared.queryDevicePresence(
                    deviceIDs: deviceIDs
                )
            },
            trustedDeviceIDs: {
                Set(
                    TrustSyncService.shared.activeTrustRecords
                        .map(\.currentDeviceId)
                        .filter { !$0.isEmpty }
                )
            }
        )
    }

    init(
        refreshInterval: Duration,
        onlineStateTTL: TimeInterval,
        now: @escaping NowProvider,
        registerPresence: @escaping RegistrationOperation,
        queryPresence: @escaping QueryOperation,
        trustedDeviceIDs: @escaping TrustedDeviceIDsProvider
    ) {
        precondition(onlineStateTTL > 0, "Presence online-state TTL must be positive")
        self.refreshInterval = refreshInterval
        self.onlineStateTTL = onlineStateTTL
        self.now = now
        self.registerPresence = registerPresence
        self.queryPresence = queryPresence
        self.trustedDeviceIDs = trustedDeviceIDs
    }

    /// 启动心跳 + 轮询（幂等）。失败会记录错误类别；查询持续失败超过 TTL 后在线状态会失效。
    public func start() {
        guard !started else { return }
        started = true
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        scheduleRefresh(for: generation)
        loopTask = Task { @MainActor [weak self] in
            while let self, self.isCurrentRefresh(generation) {
                do {
                    try await Task.sleep(for: self.refreshInterval)
                } catch {
                    return
                }
                guard self.isCurrentRefresh(generation) else { return }
                self.expireOnlineStateIfStale(at: self.now())
                self.scheduleRefresh(for: generation)
            }
        }
    }

    public func stop() {
        lifecycleGeneration &+= 1
        loopTask?.cancel()
        loopTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshToken = nil
        started = false
        lastSuccessfulQueryAt = nil
        onlinePeerDeviceIds = []
    }

    /// 立即触发一次（例如前台恢复时）。
    public func triggerRefresh() {
        guard started else { return }
        expireOnlineStateIfStale(at: now())
        scheduleRefresh(for: lifecycleGeneration)
    }

    func waitForCurrentRefresh() async {
        let task = refreshTask
        await task?.value
    }

    private func scheduleRefresh(for generation: UInt64) {
        guard isCurrentGeneration(generation), refreshTask == nil else { return }
        let token = UUID()
        refreshToken = token
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.tick(generation: generation)
            self.finishRefresh(token: token, generation: generation)
        }
    }

    private func finishRefresh(token: UUID, generation: UInt64) {
        guard lifecycleGeneration == generation, refreshToken == token else { return }
        refreshTask = nil
        refreshToken = nil
    }

    private func tick(generation: UInt64) async {
        // 1) 注册本设备在线（心跳）。未登录/网络失败不会中断其它功能，但必须可观测。
        do {
            try await registerPresence()
        } catch {
            guard isCurrentRefresh(generation) else { return }
            logger.warning(
                "Presence registration failed: errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public)"
            )
        }
        guard isCurrentRefresh(generation) else { return }

        // 2) 查询本账号受信设备的在线子集。
        let trustedIds = trustedDeviceIDs()
        guard !trustedIds.isEmpty else {
            if !onlinePeerDeviceIds.isEmpty { onlinePeerDeviceIds = [] }
            lastSuccessfulQueryAt = now()
            return
        }
        do {
            let sortedTrustedIds = trustedIds.sorted()
            var queriedOnlineIds = Set<String>()
            for batchStart in stride(
                from: 0,
                to: sortedTrustedIds.count,
                by: Self.maximumQueryBatchSize
            ) {
                let batchEnd = min(
                    batchStart + Self.maximumQueryBatchSize,
                    sortedTrustedIds.count
                )
                let onlineBatch = try await queryPresence(
                    Array(sortedTrustedIds[batchStart..<batchEnd])
                )
                guard isCurrentRefresh(generation) else { return }
                queriedOnlineIds.formUnion(onlineBatch)
            }

            // Trust may be revoked while requests are in flight. Publish once, only after every
            // batch succeeds, and intersect with both the queried snapshot and current trust.
            let currentTrustedIds = trustedDeviceIDs()
            let set = queriedOnlineIds
                .intersection(trustedIds)
                .intersection(currentTrustedIds)
            if set != onlinePeerDeviceIds { onlinePeerDeviceIds = set }
            lastSuccessfulQueryAt = now()
        } catch {
            guard isCurrentRefresh(generation) else { return }
            logger.warning(
                "Presence query failed: errorClass=\(String(reflecting: Swift.type(of: error)), privacy: .public)"
            )
            expireOnlineStateIfStale(at: now())
        }
    }

    private func expireOnlineStateIfStale(at currentTime: Date) {
        guard !onlinePeerDeviceIds.isEmpty else { return }
        guard let lastSuccessfulQueryAt else {
            onlinePeerDeviceIds = []
            return
        }
        let age = currentTime.timeIntervalSince(lastSuccessfulQueryAt)
        guard age >= 0, age < onlineStateTTL else {
            // Wall-clock rollback is not proof that a peer remains online; fail closed.
            onlinePeerDeviceIds = []
            return
        }
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        started && lifecycleGeneration == generation
    }

    private func isCurrentRefresh(_ generation: UInt64) -> Bool {
        isCurrentGeneration(generation) && !Task.isCancelled
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
