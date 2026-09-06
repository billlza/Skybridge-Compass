import Foundation
import Combine
import SkyBridgeProtocolCore

/// 跨网在线状态服务（F2-B / 向日葵·ToDesk 式）——macOS 端对共享引擎 `AccountPresenceRefreshEngine` 的薄封装：
/// - 周期性向信令服务器注册本设备在线（心跳），携带本机元数据（名称/平台/机型/系统版本/局域网地址/能力）。
/// - 周期性拉取「本账号设备列表」（`/api/devices/list`）：同一账号下所有已注册设备 + 服务端实时在线状态，
///   既驱动设备发现页/主控台的「账号设备」面板，也派生受信设备的在线子集（`onlinePeerDeviceIds`）。
///   历史上这里分别调用 presence 注册与 presence 查询两个接口；列表是查询的超集，现在只保留一次轮询。
///
/// 失败语义、单飞/世代/TTL 不变量都在引擎里实现并被测试锁定；本类只负责把引擎状态发布为 `@Published`。
/// 复用 `CrossNetworkConnectionManager` 已配置的 `SignalServerClient`（bearer/tenant 鉴权）。presence 键由服务端
/// 用已验证 JWT 的 tenantId:userId:deviceId 构成，因此只能看到「自己账号」的设备（隐私安全）。
@available(macOS 14.0, iOS 17.0, *)
@MainActor
public final class PresenceService: ObservableObject {
    public static let shared = PresenceService()

    typealias RegistrationOperation = AccountPresenceRefreshEngine.RegistrationOperation
    typealias AccountDeviceListOperation = AccountPresenceRefreshEngine.AccountDeviceListOperation
    typealias TrustedDeviceIDsProvider = AccountPresenceRefreshEngine.TrustedDeviceIDsProvider
    typealias NowProvider = AccountPresenceRefreshEngine.NowProvider
    typealias FailureClassifier = AccountPresenceRefreshEngine.FailureClassifier

    /// 当前在线的受信设备 id 集合（以 TrustRecord.currentDeviceId 为键）。
    @Published public private(set) var onlinePeerDeviceIds: Set<String> = []
    /// 本账号设备列表的最近一次成功快照；未登录/尚未拉取/已登出时为 nil。
    @Published public private(set) var accountDevices: AccountDeviceListSnapshot?
    @Published public private(set) var lastSuccessfulListAt: Date?
    /// 最近一次列表拉取失败（成功后清空）。UI 据此显示「列表可能已过期」而不是假装最新。
    @Published public private(set) var lastListFailure: AccountPresenceFailure?
    /// 最近一次心跳失败（成功后清空）。
    @Published public private(set) var lastHeartbeatFailure: AccountPresenceFailure?
    /// 服务是否处于运行态（登录后由 DashboardViewModel 启动；登出/访客模式为 false）。UI 据此区分「未登录」与「同步中」。
    @Published public private(set) var isActive = false

    private var engine: AccountPresenceRefreshEngine!

    private convenience init() {
        self.init(
            refreshInterval: .seconds(AccountPresenceRefreshPolicy.heartbeatInterval),
            onlineStateTTL: AccountPresenceRefreshPolicy.snapshotTTL,
            now: Date.init,
            registerPresence: {
                let report = try LocalDevicePresenceReportBuilder.currentReport()
                _ = try await CrossNetworkConnectionManager.shared.registerDevicePresence(report: report)
            },
            listAccountDevices: {
                try await CrossNetworkConnectionManager.shared.listAccountDevices()
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
        listAccountDevices: @escaping AccountDeviceListOperation,
        trustedDeviceIDs: @escaping TrustedDeviceIDsProvider,
        classifyFailure: @escaping FailureClassifier = SignalServerClient.presenceFailure(for:)
    ) {
        let (seconds, attoseconds) = refreshInterval.components
        engine = AccountPresenceRefreshEngine(
            refreshInterval: TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18,
            onlineStateTTL: onlineStateTTL,
            now: now,
            registerPresence: registerPresence,
            listAccountDevices: listAccountDevices,
            trustedDeviceIDs: trustedDeviceIDs,
            classifyFailure: classifyFailure,
            onStateChange: { [weak self] state in
                self?.apply(state)
            }
        )
    }

    /// 启动心跳 + 列表轮询（幂等）。失败会记录类别；列表持续失败超过 TTL 后在线状态会失效。
    public func start() {
        engine.start()
        isActive = engine.isStarted
    }

    /// 停止并清空快照（登出/账号切换）。
    public func stop() {
        engine.stop()
        isActive = false
    }

    /// 立即触发一次（例如前台恢复、用户点刷新）。
    public func triggerRefresh() { engine.triggerRefresh() }

    func waitForCurrentRefresh() async { await engine.waitForCurrentRefresh() }

    /// 该设备是否在线（按 TrustRecord 的任一已知 id 命中）。
    public func isOnline(deviceId: String) -> Bool { engine.isOnline(deviceId: deviceId) }

    /// 快照是否已超过 TTL 未刷新（UI 用于显示过期提示）。
    public func isAccountDevicesSnapshotStale(at currentTime: Date? = nil) -> Bool {
        engine.isSnapshotStale(at: currentTime)
    }

    private func apply(_ state: AccountPresenceRefreshEngine.State) {
        if onlinePeerDeviceIds != state.onlinePeerDeviceIds { onlinePeerDeviceIds = state.onlinePeerDeviceIds }
        if accountDevices != state.accountDevices { accountDevices = state.accountDevices }
        if lastSuccessfulListAt != state.lastSuccessfulListAt { lastSuccessfulListAt = state.lastSuccessfulListAt }
        if lastListFailure != state.lastListFailure { lastListFailure = state.lastListFailure }
        if lastHeartbeatFailure != state.lastHeartbeatFailure { lastHeartbeatFailure = state.lastHeartbeatFailure }
    }
}
