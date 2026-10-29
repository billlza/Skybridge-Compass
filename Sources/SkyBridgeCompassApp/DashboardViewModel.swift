import Foundation
import Combine
import SkyBridgeCore
#if canImport(OrderedCollections)
import OrderedCollections
#endif
import AppKit
import SwiftUI
import Network

@available(macOS 14.0, *)
struct PendingSiriConnectionRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let requestedDeviceName: String
    let matchedDeviceID: UUID
    let matchedDeviceName: String

    init(
        id: UUID = UUID(),
        requestedDeviceName: String,
        matchedDeviceID: UUID,
        matchedDeviceName: String
    ) {
        self.id = id
        self.requestedDeviceName = requestedDeviceName
        self.matchedDeviceID = matchedDeviceID
        self.matchedDeviceName = matchedDeviceName
    }
}

/// 仪表盘主视图模型，协调真实设备扫描、会话管理及文件传输状态。
@available(macOS 14.0, *)
@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var metrics = DashboardMetrics()
    @Published private(set) var connectionStatus: ConnectionStatus = .disconnected
    @Published private(set) var topConnectionPresentation = ConnectionPresentation(
        phase: .disconnected,
        isConnected: false,
        statusText: ConnectionStatus.disconnected.displayName,
        detailText: nil
    )
    @Published private(set) var sessions: [RemoteSessionSummary] = []
    @Published private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published private(set) var transferTasks: [FileTransferTask] = []
    @Published private(set) var discoveryStatus: String = "等待扫描真实设备"
    @Published private(set) var connectionDetail: String? = nil
    @Published private(set) var tenants: [TenantDescriptor] = []
    @Published private(set) var activeTenant: TenantDescriptor?
    @Published private(set) var pendingSiriConnectionRequest: PendingSiriConnectionRequest?

 // 🆕 统一的在线设备列表(使用新的统一管理器)
    @Published public var onlineDevices: [OnlineDevice] = []
    @Published public var deviceStats: DeviceStats = DeviceStats()

 // 性能监控相关属性
    @Published private(set) var performanceMetrics = SkyBridgeCore.PerformanceMetrics(
        frameRate: 60.0,
        frameTime: 16.67,
        cpuUsage: 0.0,
        gpuUsage: 0.0,
        memoryUsage: 0.0,
        thermalState: .nominal,
        powerState: .normal,
        batteryLevel: 1.0,
        timestamp: Date()
    )
    @Published private(set) var thermalState: SkyBridgeCore.ThermalState = .nominal
    @Published private(set) var powerState: SkyBridgeCore.PowerState = .normal
    @Published private(set) var performanceRecommendations: [PerformanceRecommendation] = []
    @Published private(set) var overallPerformanceState: OverallPerformanceState = .optimal

 // 添加设置界面显示状态的回调
    var onNavigateToSettings: (() -> Void)?

 // 修改：避免重复初始化设备发现服务，使用单独的实例但检查是否已启动
    private lazy var discoveryService = DeviceDiscoveryService.shared
    private lazy var p2pDiscoveryService = P2PDiscoveryService.shared
    private lazy var connectionManager = ConnectionManager()  // 添加连接管理器以支持USB设备扫描
    private lazy var crossNetworkManager = CrossNetworkConnectionManager.shared
    private lazy var usbcManager = USBCConnectionManager()    // 直接监听USB设备连接，计入在线设备
    private lazy var sessionService = RemoteDesktopManager.shared
    private lazy var fileTransferService = FileTransferManager.shared
    private lazy var localPeerServices = LocalPeerServiceCoordinator.shared
    let systemMetricsService = SystemMetricsService()
    private lazy var tenantController = TenantAccessController.shared

 // 🆕 统一的在线设备管理器(单例)
    private lazy var unifiedDeviceManager = UnifiedOnlineDeviceManager.shared

 // 性能优化组件
    private var performanceCoordinator: PerformanceCoordinator?
    private var isNetworkOnline: Bool = false
    private var localIPv4: String? = nil

    private var cancellables = Set<AnyCancellable>()
    private var presentationCancellables = Set<AnyCancellable>()
    private var authenticatedStartupTask: Task<Void, Never>?
    private var authenticatedStartupSessionKey: String?
    private var authenticatedStartupGeneration: UUID?
    private var hasStartedServices = false
    private var isStartingServices = false

 /// 设备扫描状态
    var isScanning: Bool {
        discoveryService.isScanning
    }

 // MARK: - 初始化
    init() {
 // 监听菜单命令通知
        NotificationCenter.default.addObserver(
            forName: .openPreferences,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.openSettings()
        }
    }

    func bootstrapConnectionPresentationBindings() {
        installConnectionPresentationBindingsIfNeeded()
    }

    deinit {
 // 移除通知观察者
        NotificationCenter.default.removeObserver(self)
    }

 /// UI 层消费的远端纹理发布者。
    var textureFeed: RemoteTextureFeed { sessionService.textureFeed }

 /// 由根视图调用以更新认证状态。
    func updateAuthentication(session: AuthSession?) async {
        if let session {
            guard session.isAuthenticatedForProtectedServices else {
                await tenantController.clearAuthentication()
                stop()
                return
            }
            await tenantController.bindAuthentication(session: session)
            scheduleAuthenticatedStartup(for: session)
        } else {
            await tenantController.clearAuthentication()
            stop()
        }
    }

    private func scheduleAuthenticatedStartup(for session: AuthSession) {
        let sessionKey = Self.startupKey(for: session)
        if authenticatedStartupSessionKey == sessionKey,
           (hasStartedServices || isStartingServices) {
            return
        }

        authenticatedStartupSessionKey = sessionKey
        let previousStartupTask = authenticatedStartupTask
        previousStartupTask?.cancel()
        let startupGeneration = UUID()
        authenticatedStartupGeneration = startupGeneration
        authenticatedStartupTask = Task { @MainActor [weak self] in
            defer {
                if self?.authenticatedStartupGeneration == startupGeneration {
                    self?.authenticatedStartupTask = nil
                    self?.authenticatedStartupGeneration = nil
                }
            }
            // Cancellation is cooperative. The previous owner may still be in
            // an awaited dependency; let its defer release the startup gate.
            await previousStartupTask?.value
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.authenticatedStartupGeneration == startupGeneration,
                  self.isCurrentAuthenticatedSession(session) else {
                return
            }

            await self.start()

            guard !Task.isCancelled,
                  self.isCurrentAuthenticatedSession(session) else {
                return
            }
            await CurrentPathDeviceActivationCoordinator.shared.syncIfNeeded(session: session)
        }
    }

    private func isCurrentAuthenticatedSession(_ session: AuthSession) -> Bool {
        session.isAuthenticatedForProtectedServices
            && tenantController.accessToken == session.accessToken
    }

    private static func startupKey(for session: AuthSession) -> String {
        [
            session.userIdentifier,
            String(session.issuedAt.timeIntervalSince1970),
            session.nebulaId ?? ""
        ].joined(separator: "|")
    }

 /// 根据当前认证状态启动各项后台服务。
    func start() async {
        installConnectionPresentationBindingsIfNeeded()

 // 如果已经启动，只启动系统监控并返回
        if hasStartedServices {
        #if DEBUG
        SkyBridgeLogger.ui.debugOnly("🔍 [DashboardViewModel] 服务已启动，仅启动系统监控")
        #endif
            systemMetricsService.startMonitoring()
            return
        }

        guard !isStartingServices else {
            return
        }
        isStartingServices = true
        defer { isStartingServices = false }

        #if DEBUG
        SkyBridgeLogger.ui.debugOnly("🚀 [DashboardViewModel] 启动所有后台服务")
        #endif

        tenantController.bootstrap()
        let shouldAutoScan = SettingsManager.shared.autoScanOnStartup

// 启动系统指标监控
        systemMetricsService.startMonitoring()

        // 账号设备（跨网在线状态）：只依赖登录态与信令服务器，与下面这些本地服务无关。
        // 必须在它们之前启动，否则任何一个本地服务启动失败都会把「账号设备」永久卡在
        // 未启动状态，而 UI 只能把它显示成「未登录」。
        PresenceService.shared.start()

        do {
            try await DeviceMessagingService.shared.prepare()
            DeviceMessagingService.shared.start()
        } catch {
            SkyBridgeLogger.ui.error("❌ 统一消息仓库启动失败: \(error.localizedDescription, privacy: .public)")
            return
        }

        if !localPeerServices.hasStarted {
            guard await pauseBetweenStartupBursts() else { return }
            do {
                try await localPeerServices.startIfNeeded()
            } catch {
                SkyBridgeLogger.ui.error("❌ 常驻本地服务启动失败: \(error.localizedDescription, privacy: .public)")
                return
            }
        }

        if shouldAutoScan {
            guard await pauseBetweenStartupBursts() else { return }
            // 检查设备发现服务是否已启动，避免重复初始化
            if !discoveryService.isScanning {
                #if DEBUG
                SkyBridgeLogger.ui.debugOnly("🔍 [DashboardViewModel] 启动设备发现服务")
                #endif
                await discoveryService.start()
            } else {
                #if DEBUG
                SkyBridgeLogger.ui.debugOnly("🔍 [DashboardViewModel] 设备发现服务已在运行")
                #endif
            }

            // 启动连接管理器以支持USB设备扫描
            #if DEBUG
            SkyBridgeLogger.ui.debugOnly("🔌 [DashboardViewModel] 启动连接管理器")
            #endif
            guard await pauseBetweenStartupBursts() else { return }
            connectionManager.scanAvailableConnections()  // 触发USB设备扫描

            // 检查P2P服务是否已启动
            if !p2pDiscoveryService.isAdvertising {
                // 启动P2P广播服务（由系统分配端口，避免撞车）
                guard await pauseBetweenStartupBursts() else { return }
                do {
                    try await p2pDiscoveryService.ensureAdvertisingHealthy()
                } catch {
                    SkyBridgeLogger.ui.error("❌ P2P 广播启动失败: \(error.localizedDescription, privacy: .public)")
                    return
                }
                #if DEBUG
                SkyBridgeLogger.ui.debugOnly("✅ P2P广播已启动")
                #endif
            } else {
                #if DEBUG
                SkyBridgeLogger.ui.debugOnly("🔍 [DashboardViewModel] P2P广播服务已在运行")
                #endif
            }

            // 检查P2P发现是否已启动
            if !p2pDiscoveryService.isDiscovering {
                #if DEBUG
                SkyBridgeLogger.ui.debugOnly("🔍 [DashboardViewModel] 启动P2P设备发现")
                #endif
                // 将设置中的兼容模式与 companion‑link 开关注入到P2P发现服务
                p2pDiscoveryService.enableCompatibilityMode = SettingsManager.shared.enableCompatibilityMode
                p2pDiscoveryService.enableCompanionLink = SettingsManager.shared.enableCompanionLink
                guard await pauseBetweenStartupBursts() else { return }
                p2pDiscoveryService.startDiscovery()
            } else {
                #if DEBUG
                SkyBridgeLogger.ui.debugOnly("🔍 [DashboardViewModel] P2P设备发现已在运行")
                #endif
            }

            // 🆕 启动统一设备管理器
            #if DEBUG
            SkyBridgeLogger.ui.debugOnly("🌐 [DashboardViewModel] 启动统一在线设备管理器")
            #endif
            guard await pauseBetweenStartupBursts() else { return }
            unifiedDeviceManager.startDiscovery()

            // 🆕 启动随航自动连接：仅连接「用户逐设备开启随航 + 仍受信 + 当前可发现」的设备，
            // 维持后台 P2P 会话供随航剪贴板等使用（默认全部关闭，需在设备详情里逐个开启）。
            guard await pauseBetweenStartupBursts() else { return }
            TrustedAutoConnectManager.shared.start()
        } else {
            #if DEBUG
            SkyBridgeLogger.ui.debugOnly("⏸ [DashboardViewModel] 启动自动扫描已关闭，跳过自动发现链路")
            #endif
            discoveryService.stop()
            p2pDiscoveryService.stopDiscovery()
            unifiedDeviceManager.stopDiscovery()
            discoveryStatus = LocalizationManager.shared.localizedString("settings.general.autoScan") + "：OFF"
        }

 // 初始化性能协调器
        if let device = MTLCreateSystemDefaultDevice() {
            performanceCoordinator = PerformanceCoordinator(device: device)
            setupPerformanceMonitoring()
        }

        // A dependency can finish after stop(), including when scanning is off.
        // Do not reinstall observations from a retired startup task.
        guard !Task.isCancelled else { return }

        tenantController.tenantsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.tenants = $0
                if $0.isEmpty {
                    self?.discoveryStatus = "请先在租户面板中添加真实凭据"
                }
            }
            .store(in: &cancellables)

        tenantController.activeTenantPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tenant in
                self?.activeTenant = tenant
            }
            .store(in: &cancellables)

        // Preserve the current protocol discovery records. Auxiliary discovery is
        // presentation-only and follows the existing compatibility setting.
        Publishers.CombineLatest4(
            discoveryService.discoveryState,
            p2pDiscoveryService.$discoveredDevices,
            SettingsManager.shared.$enableCompatibilityMode,
            Publishers.CombineLatest(
                p2pDiscoveryService.$connectionStatus,
                ConnectionPresenceService.shared.$activeConnections
            )
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] state, peers, compatibilityMode, _ in
            guard let self else { return }
            self.discoveredDevices = DashboardDeviceProjection.project(
                currentPeers: peers,
                connectedUSBPeers: self.p2pDiscoveryService.connectedUSBControlDevices,
                supplementary: state.devices,
                compatibilityMode: compatibilityMode
            )
            self.discoveryStatus = state.statusDescription
            self.updateDashboardCounts()
        }
        .store(in: &cancellables)

// 🆕 订阅统一设备列表
// 🔧 优化：添加节流和去重，减少不必要的状态更新
        unifiedDeviceManager.$onlineDevices
            .removeDuplicates()  // 只在设备列表真正改变时更新
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)  // 100ms节流
            .sink { [weak self] devices in
                self?.onlineDevices = devices
                self?.updateDashboardCounts()
                #if DEBUG
                SkyBridgeLogger.ui.debugOnly("🔄 [DashboardViewModel] 在线设备更新: \(devices.count)")
                #endif
            }
            .store(in: &cancellables)

 // 🆕 订阅设备统计
 // 🔧 优化：添加节流，减少频繁更新（DeviceStats可能未实现Equatable，所以不使用removeDuplicates）
        unifiedDeviceManager.$deviceStats
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)  // 200ms节流
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stats in
                self?.deviceStats = stats
            }
            .store(in: &cancellables)

        sessionService.sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.sessions = $0 }
            .store(in: &cancellables)

        sessionService.metrics
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)  // 🔧 优化：200ms节流，减少频繁更新
            .receive(on: DispatchQueue.main)
            .sink { [weak self] metrics in
                self?.metrics.merge(with: metrics)
                self?.updateDashboardCounts()
            }
            .store(in: &cancellables)

        fileTransferService.$activeTransfers
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)  // 🔧 优化：100ms节流，减少频繁更新
            .receive(on: DispatchQueue.main)
            .map { transfers in
                transfers.values.map { tf in
                    let mbps = (tf.transferSpeed * 8.0) / 1_000_000.0 // 字节/秒 → Mbps
                    return FileTransferTask(
                        id: UUID(uuidString: tf.id) ?? UUID(),
                        fileName: tf.fileName,
                        progress: tf.progress,
                        throughputMbps: mbps,
                        remainingTime: tf.estimatedTimeRemaining
                    )
                }
            }
            .sink { [weak self] in self?.transferTasks = $0 }
            .store(in: &cancellables)

 // 根据传输任务与会话状态更新仪表盘计数
 // 🔧 优化：合并到上面的sink中，避免重复订阅
 // 已在上面的sink中调用updateDashboardCounts，这里可以移除

 // 监听USB设备连接变化
        usbcManager.$discoveredUSBDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateDashboardCounts() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .skyBridgeIntentConnect)
            .compactMap { $0.userInfo?[SkyBridgeIntentPayloadKey.deviceName] as? String }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] target in
                self?.recordSiriConnectRequest(targetName: target)
            }
            .store(in: &cancellables)
        sessionService.bootstrap()
 // FileTransferManager 不需要prepare方法
 // 集中网络监控，订阅共享发布者
        NetworkFrameworkEnhancements.NetworkPathMonitor.shared.startMonitoring(queue: DispatchQueue(label: "skybridge.network.monitor"))
        NetworkFrameworkEnhancements.NetworkPathMonitor.shared.$isOnline
            .receive(on: DispatchQueue.main)
            .sink { [weak self] online in
                self?.isNetworkOnline = online
                self?.localIPv4 = self?.currentIPv4Address()
                self?.updateDashboardCounts()
            }
            .store(in: &cancellables)

        hasStartedServices = true
    }

    private func pauseBetweenStartupBursts() async -> Bool {
        await Task.yield()
        do {
            try await Task.sleep(for: .milliseconds(220))
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func synthesizedCrossNetworkSnapshot(
        status: CrossNetworkConnectionManager.CrossNetworkConnectionStatus,
        readiness: CrossNetworkConnectionManager.CrossNetworkReadiness,
        activeSnapshot: ActiveSessionSnapshot?,
        currentConnection: RemoteConnection?
    ) -> ActiveSessionSnapshot? {
        guard activeSnapshot == nil else { return nil }

        switch readiness {
        case .handshakeComplete(let sessionId, let negotiatedSuite):
            return ActiveSessionSnapshot(
                sessionId: sessionId,
                source: .reused,
                phase: .handshakeComplete,
                deviceId: nil,
                deviceName: currentConnection?.deviceName,
                negotiatedSuite: negotiatedSuite
            )
        case .transportReady(let sessionId):
            return ActiveSessionSnapshot(
                sessionId: sessionId,
                source: .reused,
                phase: .transportReady,
                deviceId: nil,
                deviceName: currentConnection?.deviceName,
                negotiatedSuite: nil
            )
        case .idle:
            break
        }

        switch status {
        case .connecting:
            if let currentConnection {
                return ActiveSessionSnapshot(
                    sessionId: currentConnection.id,
                    source: .reused,
                    phase: .transportReady,
                    deviceId: nil,
                    deviceName: currentConnection.deviceName,
                    negotiatedSuite: nil
                )
            }
            return ActiveSessionSnapshot(
                sessionId: "cross-network-pending",
                source: .reused,
                phase: .connecting,
                deviceId: nil,
                deviceName: nil,
                negotiatedSuite: nil
            )
        case .connected:
            return ActiveSessionSnapshot(
                sessionId: currentConnection?.id ?? "cross-network-active",
                source: .reused,
                phase: .handshakeComplete,
                deviceId: nil,
                deviceName: currentConnection?.deviceName,
                negotiatedSuite: nil
            )
        case .idle, .generating, .waiting, .failed:
            return nil
        }
    }

    private func installConnectionPresentationBindingsIfNeeded() {
        guard presentationCancellables.isEmpty else { return }

        let base = Publishers.CombineLatest4(
            connectionManager.$connectionStatus,
            p2pDiscoveryService.$connectionStatus,
            p2pDiscoveryService.$activeInboundSessions,
            fileTransferService.$isTransferring
        )

        let presence = Publishers.CombineLatest(
            ConnectionPresenceService.shared.$activeConnections,
            ConnectionPresenceService.shared.$rekeyStatusByPeerId
        )

        let unified = unifiedDeviceManager.$onlineDevices

        let crossNetworkBase = Publishers.CombineLatest4(
            crossNetworkManager.$connectionStatus,
            crossNetworkManager.$readiness,
            crossNetworkManager.$activeSessionSnapshot,
            crossNetworkManager.$currentConnection
        )
        let crossNetwork = Publishers.CombineLatest(
            crossNetworkBase,
            crossNetworkManager.$signalingHealth
        )

        Publishers.CombineLatest4(base, presence, unified, crossNetwork)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] baseTuple, presenceTuple, unifiedDevices, crossNetworkTuple in
                guard let self else { return }
                let (_, _, _, isTransferring) = baseTuple
                let (presenceConnections, rekeyStatusByPeerId) = presenceTuple
                let ((crossStatus, crossReadiness, crossSnapshot, crossConnection), crossSignalingHealth) = crossNetworkTuple

                let unifiedLinkedPeers = unifiedDevices
                    .filter { device in
                        !device.isLocalDevice && device.connectionStatus == .connected
                    }
                    .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }

                let activeCrossNetworkPresencePeerID: String? = {
                    if let sessionId = crossSnapshot?.sessionId {
                        return "cross-network:\(sessionId)"
                    }
                    if let sessionId = crossConnection?.id {
                        return "cross-network:\(sessionId)"
                    }
                    return nil
                }()

                let filteredPresenceConnections = presenceConnections.filter { connection in
                    guard let activeCrossNetworkPresencePeerID else { return true }
                    return connection.id != activeCrossNetworkPresencePeerID
                }

                let latestPeerConnection: ConnectionPresentationPeer?
                if let newest = filteredPresenceConnections.sorted(by: { $0.connectedAt > $1.connectedAt }).first {
                    if let rekey = rekeyStatusByPeerId[newest.id] {
                        latestPeerConnection = ConnectionPresentationPeer(
                            displayName: newest.displayName,
                            cryptoKind: "\(rekey.fromKind)·\(rekey.fromSuite) → \(rekey.toKind)·\(rekey.toSuite)",
                            suite: nil,
                            guardStatus: "Rekey 中",
                            isRekeying: true,
                            connectedAt: newest.connectedAt
                        )
                    } else {
                        latestPeerConnection = ConnectionPresentationPeer(
                            displayName: newest.displayName,
                            cryptoKind: newest.cryptoKind,
                            suite: newest.suite,
                            guardStatus: "守护中",
                            connectedAt: newest.connectedAt
                        )
                    }
                } else {
                    latestPeerConnection = nil
                }

                let latestConnectedDevice = unifiedLinkedPeers.first.map { device in
                    ConnectionPresentationPeer(
                        displayName: device.name,
                        cryptoKind: device.lastCryptoKind,
                        suite: device.lastCryptoSuite,
                        guardStatus: device.guardStatus ?? "守护中",
                        connectedAt: device.lastConnectedAt ?? device.lastSeen
                    )
                }

                let crossNetworkFallback = self.synthesizedCrossNetworkSnapshot(
                    status: crossStatus,
                    readiness: crossReadiness,
                    activeSnapshot: crossSnapshot,
                    currentConnection: crossConnection
                )

                let presentation = ConnectionPresentationContract.evaluate(
                    ConnectionPresentationInput(
                        labels: ConnectionPresentationLabels(
                            connectedText: LocalizationManager.shared.localizedString("device.status.connected"),
                            disconnectedText: LocalizationManager.shared.localizedString("status.disconnected"),
                            connectingText: ConnectionStatus.connecting.displayName,
                            reconnectingText: ConnectionStatus.reconnecting.displayName,
                            defaultGuardStatus: "守护中",
                            crossNetworkGuardStatus: "跨网已连接"
                        ),
                        fileTransferActive: isTransferring,
                        latestPeerConnection: latestPeerConnection,
                        latestConnectedDevice: latestConnectedDevice,
                        activeSessionSnapshot: crossSnapshot,
                        crossNetworkFallback: crossNetworkFallback,
                        defaultPQCModeLabel: nil,
                        compatibilityModeEnabled: SettingsManager.shared.enableCompatibilityMode,
                        signalingHealth: crossSignalingHealth
                    )
                )

                self.topConnectionPresentation = presentation
                self.connectionDetail = presentation.detailText

                switch presentation.phase {
                case .connected:
                    self.connectionStatus = .connected
                case .connecting:
                    self.connectionStatus = .connecting
                case .reconnecting:
                    self.connectionStatus = .reconnecting
                case .disconnected:
                    self.connectionStatus = .disconnected
                }
            }
            .store(in: &presentationCancellables)
    }

    /// 停止所有订阅并释放资源，通常在界面离开或退出登录时调用。
    func stop() {
        authenticatedStartupTask?.cancel()
        // Retain the retiring owner until its generation-bound defer completes.
        // A subsequent login must await it rather than start beside it.
        authenticatedStartupSessionKey = nil

        let shouldStopStartedServices = hasStartedServices || isStartingServices
        hasStartedServices = false
        presentationCancellables.removeAll()
        cancellables.removeAll()
        guard shouldStopStartedServices else {
            systemMetricsService.stopMonitoring()
            performanceCoordinator?.stopPerformanceCoordination()
            performanceCoordinator = nil
            return
        }

        discoveryService.stop()
        p2pDiscoveryService.stopDiscovery()
        PresenceService.shared.stop()
        TrustedAutoConnectManager.shared.stop()
        sessionService.shutdown()
 // FileTransferManager 不需要stop方法
        systemMetricsService.stopMonitoring()
        performanceCoordinator?.stopPerformanceCoordination()
        performanceCoordinator = nil

 // 🆕 停止统一设备管理器
        unifiedDeviceManager.stopDiscovery()
    }

 /// 设置性能监控
    private func setupPerformanceMonitoring() {
        guard let coordinator = performanceCoordinator else { return }

 // 监听性能指标更新
 // 🔧 优化：添加节流，减少频繁的性能指标更新
        coordinator.$performanceMetrics
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)  // 500ms节流
            .receive(on: DispatchQueue.main)
            .sink { [weak self] metrics in
                self?.performanceMetrics = metrics
            }
            .store(in: &cancellables)

 // 监听热量状态更新 - 从性能指标中获取
 // 🔧 优化：添加去重，只在状态真正改变时更新
        coordinator.$performanceMetrics
            .map(\.thermalState)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.thermalState = state
            }
            .store(in: &cancellables)

 // 监听电源状态更新 - 从性能指标中获取
 // 🔧 优化：添加去重，只在状态真正改变时更新
        coordinator.$performanceMetrics
            .map(\.powerState)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.powerState = state
            }
            .store(in: &cancellables)

 // 监听性能建议更新 - 从协调器获取
 // 🔧 优化：降低更新频率，从5秒增加到10秒，减少不必要的计算
        Timer.publish(every: 10.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, let coordinator = self.performanceCoordinator else { return }
                self.performanceRecommendations = coordinator.getCurrentPerformanceRecommendations()
            }
            .store(in: &cancellables)

 // 监听整体性能状态更新
        coordinator.$overallPerformanceState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.overallPerformanceState = state
            }
            .store(in: &cancellables)

 // 启动性能监控
        coordinator.startPerformanceCoordination()
    }

 /// 手动触发一次真实设备重新扫描。
    func triggerDiscoveryRefresh() {
        discoveryService.refresh()
        Task {
            await p2pDiscoveryService.refreshDevices()
        }
    }

 // 扩展搜索（兼容模式）临时开启，持续指定秒数后自动关闭并收回，避免长期高能耗
    @MainActor
    func triggerExtendedDiscovery(seconds: Int = 15) {
        SettingsManager.shared.enableCompatibilityMode = true
        discoveryService.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self] in
            SettingsManager.shared.enableCompatibilityMode = false
            self?.discoveryService.refresh()
        }
    }

 // 手动连接兜底（IP/端口/配对码可选），用于 mDNS 被禁或跨网段场景
    @MainActor
    func manualConnect(ip: String, port: UInt16, pairingCode: String?) async {
        var device = DiscoveredDevice(
            id: UUID(),
            name: ip,
            ipv4: ip,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": Int(port)],
            connectionTypes: [.wifi],
            uniqueIdentifier: nil,
            signalStrength: nil
        )
        if let code = pairingCode, !code.isEmpty { device.uniqueIdentifier = code }
        do {
            try await p2pDiscoveryService.connectToDevice(device)
            self.connectionStatus = .connected
            SkyBridgeLogger.discovery.info("✅ 手动连接成功: \(ip):\(port)")
        } catch {
            SkyBridgeLogger.discovery.error("❌ 手动连接失败: \(error.localizedDescription, privacy: .private)")
        }
    }

 /// 打开应用设置界面 - 使用符合macOS规范的原生设置窗口样式
    nonisolated public func openSettings() {
 // 调用回调函数切换到设置页面
        Task { @MainActor in
            onNavigateToSettings?()
        }
    }

 /// 将远程桌面窗口提升到前台。
    func focus(on session: RemoteSessionSummary) {
        sessionService.focus(on: session.id)
    }

 /// 终止指定的远程桌面会话。
    func terminate(session: RemoteSessionSummary) {
        sessionService.terminate(sessionID: session.id)
    }

 /// 与真实设备建立远程桌面连接。
    func connect(to device: DiscoveredDevice) async {
        do {
            let tenant = try await tenantController.requirePermission(.remoteDesktop)
            try await sessionService.connect(to: device, tenant: tenant)
        } catch {
            await MainActor.run {
                discoveryStatus = error.localizedDescription
            }
        }
    }

    /// Connect the selected current SkyBridge record through the MAIN transport.
    /// The discovery service owns route policy, identity checks, and authentication.
    func connectDiscoveredPeer(to device: DiscoveredDevice) async {
        guard !device.isLocalDevice,
              DashboardDeviceProjection.isSkyBridgePeer(device) else {
            discoveryStatus = P2PDiscoveryError.noConnectableEndpoint.localizedDescription
            return
        }
        discoveryStatus = "正在连接到 \(device.name)"
        do {
            try await p2pDiscoveryService.connectToDevice(device)
            discoveryStatus = "已连接到 \(device.name)"
        } catch {
            discoveryStatus = error.localizedDescription
        }
    }

 /// 🆕 连接到在线设备(新的统一设备类型)
    func connect(to onlineDevice: OnlineDevice) async {
        discoveryStatus = "正在连接到 \(onlineDevice.name)"
        do {
            try await OnlineDeviceConnectionCoordinator.connect(to: onlineDevice)
            discoveryStatus = "已连接到 \(onlineDevice.name)"
        } catch {
            discoveryStatus = error.localizedDescription
        }
    }

    private func recordSiriConnectRequest(targetName: String) {
        let requestedName = targetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedName.isEmpty else {
            pendingSiriConnectionRequest = nil
            discoveryStatus = "Siri 连接请求缺少设备名称，已中止"
            return
        }

        let matches = discoveredDevices.filter { device in
            device.name.caseInsensitiveCompare(requestedName) == .orderedSame
        }
        guard matches.count == 1, let matched = matches.first else {
            pendingSiriConnectionRequest = nil
            discoveryStatus = matches.isEmpty
                ? "未找到 Siri 请求的设备「\(requestedName)」，未执行连接"
                : "Siri 请求的设备名称「\(requestedName)」不唯一，未执行连接"
            return
        }

        pendingSiriConnectionRequest = PendingSiriConnectionRequest(
            requestedDeviceName: requestedName,
            matchedDeviceID: matched.id,
            matchedDeviceName: matched.name
        )
        discoveryStatus = "Siri 已准备连接「\(matched.name)」，请在应用内确认"
    }

    func confirmPendingSiriConnectionRequest() async {
        guard let request = pendingSiriConnectionRequest else {
            discoveryStatus = "没有待确认的 Siri 连接请求"
            return
        }
        guard let matched = discoveredDevices.first(where: { $0.id == request.matchedDeviceID }) else {
            pendingSiriConnectionRequest = nil
            discoveryStatus = "待确认设备已不可用，未执行连接"
            return
        }

        pendingSiriConnectionRequest = nil
        await connect(to: matched)
    }

 /// 激活指定租户，以便使用其权限进行后续操作。
    func activateTenant(_ tenant: TenantDescriptor) {
        Task {
            do {
                try await tenantController.setActiveTenant(id: tenant.id)
            } catch {
                await MainActor.run {
                    discoveryStatus = error.localizedDescription
                }
            }
        }
    }

    @discardableResult
 /// 注册一个新的真实租户并保存到钥匙串。
    func registerTenant(displayName: String,
                        username: String,
                        password: String,
                        domain: String?,
                        permissions: TenantPermission) -> Bool {
        Task {
            do {
                try await tenantController.registerTenant(displayName: displayName, username: username, password: password, domain: domain, permissions: permissions)
                return true
            } catch {
                await MainActor.run {
                    discoveryStatus = error.localizedDescription
                }
                return false
            }
        }
        return true // 临时返回值，实际结果通过Task异步处理
    }
 // 启动网络连通性监控
 // 网络监控已集中，保留方法签名以兼容，但不再使用本地 NWPathMonitor

 // 统一更新"在线设备/活跃会话/传输任务"的仪表盘计数
 /// 🔧 优化：修复设备计数逻辑，确保与设备发现页面同步
    private func updateDashboardCounts() {
        let hasCrossNetworkSession: Bool
        if let snapshot = self.crossNetworkManager.activeSessionSnapshot {
            switch snapshot.phase {
            case .transportReady, .handshakeComplete, .reconnecting:
                hasCrossNetworkSession = true
            case .connecting, .disconnecting:
                hasCrossNetworkSession = false
            }
        } else {
            hasCrossNetworkSession = false
        }
        // This metric describes the same current discovery projection shown
        // below; authentication/session presence has its own metric.
        let online = discoveredDevices.count
        let active = sessions.filter { $0.status == .connected }.count + (hasCrossNetworkSession ? 1 : 0)
        let transfers = transferTasks.count
        guard metrics.onlineDevices != online || metrics.activeSessions != active || metrics.fileTransfers != transfers else { return }
        var next = metrics
        next.onlineDevices = online
        next.activeSessions = active
        next.fileTransfers = transfers
        metrics = next
    }

 // 获取本机IPv4地址（优先en0）
    private func currentIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return nil
        }
        defer { freeifaddrs(first) }

        var discoveredAddress: String?
        var current: UnsafeMutablePointer<ifaddrs>? = first

        while let interfacePointer = current {
            let interface = interfacePointer.pointee
            defer { current = interface.ifa_next }

            guard let namePtr = interface.ifa_name,
                  let sa = interface.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                sa,
                socklen_t(sa.pointee.sa_len),
                &hostBuf,
                socklen_t(hostBuf.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else {
                continue
            }

            let ip = hostBuf.withUnsafeBufferPointer { ptr -> String in
                guard let base = ptr.baseAddress,
                      let value = String(validatingCString: base) else {
                    return ""
                }
                return value
            }
            guard !ip.isEmpty else { continue }

            let name = decodeCString(namePtr)
            if name == "en0" {
                return ip
            }
            if discoveredAddress == nil {
                discoveredAddress = ip
            }
        }

        return discoveredAddress
    }

}

struct DashboardMetrics {
    var onlineDevices: Int = 0
    var activeSessions: Int = 0
    var fileTransfers: Int = 0
    var alerts: Int = 0
    var timeline: OrderedDictionary<Date, Double> = [:]

    mutating func merge(with newMetrics: RemoteMetricsSnapshot) {
        // Remote-desktop counters describe only that subsystem. The dashboard
        // owns aggregate discovery/session/transfer counts and updates them from
        // their current sources; a remote-metrics tick must not replace them.
        alerts = newMetrics.alertCount
        timeline = newMetrics.cpuTimeline
    }
}
