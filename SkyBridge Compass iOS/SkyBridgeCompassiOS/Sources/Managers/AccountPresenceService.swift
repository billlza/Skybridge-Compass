import Combine
import Foundation
import SkyBridgeProtocolCore

/// iOS 端本机心跳元数据组装（控制端专用：永远不上报 `remote_desktop` 被控能力）。
enum IOSDevicePresenceReportBuilder {
    static func currentReport() throws -> AccountDevicePresenceReport {
        try makeReport(
            identity: AppleMobileDeviceIdentity.currentSnapshot(),
            lanAddresses: LocalNetworkAddressInspector.routableAddresses().map(\.address)
        )
    }

    static func makeReport(
        identity: AppleMobileDeviceIdentity.Snapshot,
        lanAddresses: [String]
    ) throws -> AccountDevicePresenceReport {
        try AccountDevicePresenceReport(
            deviceName: identity.deviceName,
            platform: identity.platform == .iPadOS ? .iPadOS : .iOS,
            deviceModel: identity.modelName,
            osVersion: identity.osVersion,
            lanAddresses: LANAddressRoutabilityPolicy.routableAddresses(
                from: lanAddresses,
                limit: AccountDevicePresenceReport.maximumLANAddresses
            ),
            capabilities: [.fileTransfer, .clipboard]
        )
    }
}

/// iOS 端「账号设备」服务：对共享引擎 `AccountPresenceRefreshEngine` 的薄封装。
///
/// - 登录后（`updateAuthentication(principal:)` 收到非 nil）开始心跳 + 拉取账号设备列表；登出即停止并清空。
/// - 进入后台挂起（保留快照，不再计时）；回到前台恢复并立即刷新一次。
/// - 失败按 `AccountPresenceFailure` 分类发布，退避由共享策略决定；本机身份未就绪是独立类别。
@MainActor
final class AccountPresenceService: ObservableObject {
    static let shared = AccountPresenceService()

    typealias BindingLoader = @Sendable () async throws -> ProtocolIdentityBindingCompat
    typealias ReportProvider = @MainActor () throws -> AccountDevicePresenceReport

    @Published private(set) var accountDevices: AccountDeviceListSnapshot?
    @Published private(set) var lastSuccessfulListAt: Date?
    @Published private(set) var lastListFailure: AccountPresenceFailure?
    @Published private(set) var lastHeartbeatFailure: AccountPresenceFailure?
    @Published private(set) var isAuthenticated = false

    private var engine: AccountPresenceRefreshEngine!
    private var principal: CurrentPathAuthenticationPrincipal?
    private var isForeground = true

    private convenience init() {
        self.init(
            signalServer: SignalServerClientCompat(),
            loadBinding: {
                let snapshot = try await SkyBridgeiOSCore.shared.committedActiveProtocolIdentitySnapshot()
                return try ProtocolIdentityBindingCompat(
                    deviceId: snapshot.deviceId,
                    protocolSigningAlgorithm: snapshot.algorithm,
                    protocolPublicKeyBytes: snapshot.publicKey
                )
            },
            reportProvider: { try IOSDevicePresenceReportBuilder.currentReport() }
        )
    }

    init(
        signalServer: SignalServerClientCompat,
        loadBinding: @escaping BindingLoader,
        reportProvider: @escaping ReportProvider,
        refreshInterval: TimeInterval = AccountPresenceRefreshPolicy.heartbeatInterval,
        onlineStateTTL: TimeInterval = AccountPresenceRefreshPolicy.snapshotTTL,
        now: @escaping AccountPresenceRefreshEngine.NowProvider = Date.init,
        classifyFailure: @escaping AccountPresenceRefreshEngine.FailureClassifier = SignalServerClientCompat.presenceFailure(for:)
    ) {
        let binding: BindingLoader = {
            do {
                return try await loadBinding()
            } catch {
                throw AccountPresenceClientError.localIdentityUnavailable(
                    underlying: String(reflecting: type(of: error))
                )
            }
        }
        engine = AccountPresenceRefreshEngine(
            refreshInterval: refreshInterval,
            onlineStateTTL: onlineStateTTL,
            now: now,
            registerPresence: {
                let report = try reportProvider()
                _ = try await signalServer.registerPresence(binding: try await binding(), report: report)
            },
            listAccountDevices: {
                try await signalServer.listAccountDevices(binding: try await binding())
            },
            trustedDeviceIDs: { [] },
            classifyFailure: classifyFailure,
            onStateChange: { [weak self] state in
                self?.apply(state)
            }
        )
    }

    /// 认证主体变化：登录 → 启动；登出/切换账号 → 停止并清空（旧账号的列表绝不残留）。
    func updateAuthentication(principal newPrincipal: CurrentPathAuthenticationPrincipal?) {
        guard newPrincipal != principal else { return }
        principal = newPrincipal
        engine.stop()
        isAuthenticated = newPrincipal != nil
        if newPrincipal != nil, isForeground {
            engine.start()
        }
    }

    /// 前台/后台切换：后台只挂起计时（保留快照），前台恢复并立即刷新。
    func handleScenePhase(isActive: Bool) {
        isForeground = isActive
        if isActive {
            guard principal != nil else { return }
            engine.start()
            engine.triggerRefresh()
        } else {
            engine.suspend()
        }
    }

    func triggerRefresh() {
        engine.triggerRefresh()
    }

    func waitForCurrentRefresh() async {
        await engine.waitForCurrentRefresh()
    }

    func isSnapshotStale(at currentTime: Date? = nil) -> Bool {
        engine.isSnapshotStale(at: currentTime)
    }

    private func apply(_ state: AccountPresenceRefreshEngine.State) {
        if accountDevices != state.accountDevices { accountDevices = state.accountDevices }
        if lastSuccessfulListAt != state.lastSuccessfulListAt { lastSuccessfulListAt = state.lastSuccessfulListAt }
        if lastListFailure != state.lastListFailure { lastListFailure = state.lastListFailure }
        if lastHeartbeatFailure != state.lastHeartbeatFailure { lastHeartbeatFailure = state.lastHeartbeatFailure }
    }
}
