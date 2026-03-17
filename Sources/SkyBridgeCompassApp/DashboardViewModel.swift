import Foundation
import Combine
import SkyBridgeCore
#if canImport(OrderedCollections)
import OrderedCollections
#endif
import AppKit
import SwiftUI
import Network

/// 仪表盘主视图模型，协调真实设备扫描、会话管理及文件传输状态。
@available(macOS 14.0, *)
@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var metrics = DashboardMetrics()
    @Published private(set) var connectionStatus: ConnectionStatus = .disconnected
    @Published private(set) var topConnectionPresentation = ConnectionPresentation(
        phase: .disconnected,
        isConnected: false,
        statusText: LocalizationManager.shared.localizedString("status.disconnected"),
        detailText: nil
    )
    @Published private(set) var sessions: [RemoteSessionSummary] = []
    @Published private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published private(set) var transferTasks: [FileTransferTask] = []
    @Published private(set) var discoveryStatus: String = "等待扫描真实设备"
    @Published private(set) var connectionDetail: String? = nil
    @Published private(set) var tenants: [TenantDescriptor] = []
    @Published private(set) var activeTenant: TenantDescriptor?

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
    private let discoveryService = DeviceDiscoveryService.shared
    private let p2pDiscoveryService = P2PDiscoveryService.shared
    private let connectionManager = ConnectionManager()  // 添加连接管理器以支持USB设备扫描
    private let crossNetworkManager = CrossNetworkConnectionManager.shared
    private let usbcManager = USBCConnectionManager()    // 直接监听USB设备连接，计入在线设备
    private let sessionService = RemoteDesktopManager.shared
    private let fileTransferService = FileTransferManager.shared
    private lazy var fileTransferListener = FileTransferListenerService(manager: fileTransferService)
    private let remoteControlManager = RemoteControlManager()
    private lazy var remoteControlServer = RemoteControlServer(manager: remoteControlManager)
    let systemMetricsService = SystemMetricsService()
    private let tenantController = TenantAccessController.shared

 // 🆕 统一的在线设备管理器(单例)
    private let unifiedDeviceManager = UnifiedOnlineDeviceManager.shared

 // 性能优化组件
    private var performanceCoordinator: PerformanceCoordinator?
    private var isNetworkOnline: Bool = false
    private var localIPv4: String? = nil
    private var pendingUpdate: DispatchWorkItem? = nil

    private var cancellables = Set<AnyCancellable>()
    private var presentationCancellables = Set<AnyCancellable>()
    private var hasStartedServices = false
    private var isAuthenticated: Bool {
        tenantController.accessToken != nil
    }

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
            await tenantController.bindAuthentication(session: session)
            await start()
        } else {
            await tenantController.clearAuthentication()
            stop()
        }
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

        #if DEBUG
        SkyBridgeLogger.ui.debugOnly("🚀 [DashboardViewModel] 启动所有后台服务")
        #endif

        tenantController.bootstrap()
        let shouldAutoScan = SettingsManager.shared.autoScanOnStartup

// 启动系统指标监控
        systemMetricsService.startMonitoring()

        if shouldAutoScan {
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
            connectionManager.scanAvailableConnections()  // 触发USB设备扫描

            // 检查P2P服务是否已启动
            if !p2pDiscoveryService.isAdvertising {
                // 启动P2P广播服务（由系统分配端口，避免撞车）
                await MainActor.run { p2pDiscoveryService.startAdvertising() }
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
            unifiedDeviceManager.startDiscovery()
        } else {
            #if DEBUG
            SkyBridgeLogger.ui.debugOnly("⏸ [DashboardViewModel] 启动自动扫描已关闭，跳过自动发现链路")
            #endif
            discoveryService.stop()
            p2pDiscoveryService.stopDiscovery()
            unifiedDeviceManager.stopDiscovery()
            discoveryStatus = LocalizationManager.shared.localizedString("settings.general.autoScan") + "：OFF"
        }

        // 启动文件传输入站监听（iOS ↔ macOS 互传的最小闭环）
        do {
            try await fileTransferListener.start()
        } catch {
            SkyBridgeLogger.ui.error("❌ 启动文件传输监听失败: \(error.localizedDescription, privacy: .public)")
        }

        // 启动 iPhone → Mac 远程桌面/控制服务（JPEG 流 + 输入注入）
        do {
            try await remoteControlServer.start()
        } catch {
            SkyBridgeLogger.ui.error("❌ 启动远程控制服务失败: \(error.localizedDescription, privacy: .public)")
        }

 // 初始化性能协调器
        if let device = MTLCreateSystemDefaultDevice() {
            performanceCoordinator = PerformanceCoordinator(device: device)
            setupPerformanceMonitoring()
        }

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

 // 修改：同时监听两个设备发现服务
        discoveryService.discoveryState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (state: DiscoveryState) in
                self?.discoveryStatus = state.statusDescription
 // 合并设备发现结果
                self?.mergeDiscoveredDevices(networkDevices: state.devices)
            }
            .store(in: &cancellables)

 // 添加P2P设备发现监听
        p2pDiscoveryService.$p2pDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] p2pDevices in
                self?.mergeDiscoveredDevices(p2pDevices: p2pDevices)
            }
            .store(in: &cancellables)

 // 启动P2P设备发现（仅启动发现，不启动广播）
 // p2pDiscoveryService.startDiscovery() // 已在上面检查并启动

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
                guard let self else { return }
                Task { await self.handleSiriConnectRequest(targetName: target) }
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
                let (baseStatus, p2pStatus, inboundCount, isTransferring) = baseTuple
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
                } else if baseStatus == .connected || p2pStatus == .connected || inboundCount > 0 {
                    latestPeerConnection = ConnectionPresentationPeer(
                        displayName: "P2P",
                        cryptoKind: nil,
                        suite: nil,
                        guardStatus: "守护中",
                        connectedAt: Date()
                    )
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
                        defaultPQCModeLabel: ConnectionCryptoPresentation.inferredModeLabelForCurrentPolicy(
                            compatibilityModeEnabled: SettingsManager.shared.enableCompatibilityMode
                        ),
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
        hasStartedServices = false
        presentationCancellables.removeAll()
        cancellables.removeAll()
        discoveryService.stop()
        p2pDiscoveryService.stopDiscovery()
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

 /// 🆕 连接到在线设备(新的统一设备类型)
    func connect(to onlineDevice: OnlineDevice) async {
 // 将OnlineDevice转换为DiscoveredDevice以兼容现有的连接逻辑
        let discoveredDevice = DiscoveredDevice(
            id: onlineDevice.id,
            name: onlineDevice.name,
            ipv4: onlineDevice.ipv4,
            ipv6: onlineDevice.ipv6,
            services: onlineDevice.services,
            portMap: onlineDevice.portMap,
            connectionTypes: onlineDevice.connectionTypes,
            uniqueIdentifier: onlineDevice.uniqueIdentifier,
            signalStrength: nil
        )

 // 执行连接
        await connect(to: discoveredDevice)
    }

    private func handleSiriConnectRequest(targetName: String) async {
        guard let tenant = try? await tenantController.requirePermission(.remoteDesktop) else { return }
        if let matched = discoveredDevices.first(where: { $0.name.caseInsensitiveCompare(targetName) == .orderedSame }) {
            try? await sessionService.connect(to: matched, tenant: tenant)
        } else if let fallback = discoveredDevices.first {
            try? await sessionService.connect(to: fallback, tenant: tenant)
        }
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
 /// 合并来自不同发现服务的设备列表
    private func mergeDiscoveredDevices(networkDevices: [DiscoveredDevice]? = nil, p2pDevices: [P2PDevice]? = nil) {
        #if DEBUG
        SkyBridgeLogger.ui.debugOnly("🔄 DashboardViewModel: 开始合并设备列表")
        #endif
        #if DEBUG
        SkyBridgeLogger.ui.debugOnly("🔄 DashboardViewModel: 网络设备数量: \(networkDevices?.count ?? 0)")
        #endif
        #if DEBUG
        SkyBridgeLogger.ui.debugOnly("🔄 DashboardViewModel: P2P设备数量: \(p2pDevices?.count ?? 0)")
        #endif

        var mergedDevices: [DiscoveredDevice] = []

 // 添加网络扫描发现的设备
        if let networkDevices = networkDevices {
            mergedDevices.append(contentsOf: networkDevices)
            #if DEBUG
            SkyBridgeLogger.ui.debugOnly("🔄 DashboardViewModel: 添加了 \(networkDevices.count) 个网络设备")
            #endif
        } else {
 // 保留现有的网络设备
            let existingNetworkDevices = discoveredDevices.filter { device in
                !device.services.contains("_skybridge._tcp")
            }
            mergedDevices.append(contentsOf: existingNetworkDevices)
            #if DEBUG
            SkyBridgeLogger.ui.debugOnly("🔄 DashboardViewModel: 保留了 \(existingNetworkDevices.count) 个现有网络设备")
            #endif
        }

 // 转换并添加P2P设备
        if let p2pDevices = p2pDevices {
            let convertedP2PDevices = p2pDevices.map { p2pDevice in
                convertP2PDeviceToDiscoveredDevice(p2pDevice)
            }
            mergedDevices.append(contentsOf: convertedP2PDevices)
            #if DEBUG
            SkyBridgeLogger.ui.debugOnly("🔄 DashboardViewModel: 转换并添加了 \(convertedP2PDevices.count) 个P2P设备")
            #endif

 // 打印P2P设备详情
            for p2pDevice in p2pDevices {
                #if DEBUG
                SkyBridgeLogger.ui.debugOnly("   P2P设备: \(p2pDevice.name) (\(p2pDevice.type.rawValue)) - \(p2pDevice.address):\(p2pDevice.port)")
                #endif
            }
        } else {
 // 保留现有的P2P设备
            let existingP2PDevices = discoveredDevices.filter { device in
                device.services.contains("_skybridge._tcp")
            }
            mergedDevices.append(contentsOf: existingP2PDevices)
            #if DEBUG
            SkyBridgeLogger.ui.debugOnly("🔄 DashboardViewModel: 保留了 \(existingP2PDevices.count) 个现有P2P设备")
            #endif
        }

 // 🔧 智能去重：使用更完善的去重逻辑
        var uniqueDevices: [DiscoveredDevice] = []

        for device in mergedDevices {
 // 检查是否已存在相似设备
            if let existingIndex = uniqueDevices.firstIndex(where: { existing in
 // 1. 检查唯一标识符
                if let uid = device.uniqueIdentifier, let existingUid = existing.uniqueIdentifier,
                   !uid.isEmpty, !existingUid.isEmpty, uid == existingUid {
                    return true
                }

 // 2. 检查 IP 地址
                if let ip = device.ipv4, let existingIp = existing.ipv4,
                   !ip.isEmpty, !existingIp.isEmpty, ip == existingIp {
                    return true
                }

 // 3. 检查标准化名称
                let normalizedName = normalizeDeviceName(device.name)
                let normalizedExisting = normalizeDeviceName(existing.name)
                if !normalizedName.isEmpty && normalizedName == normalizedExisting {
                    return true
                }

 // 4. 检查名称包含关系
                if device.name.contains(existing.name) || existing.name.contains(device.name) {
                    let lengthDiff = abs(device.name.count - existing.name.count)
                    if lengthDiff < 20 {
                        return true
                    }
                }

                return false
            }) {
 // 设备已存在，合并信息
                uniqueDevices[existingIndex] = mergeDeviceInfo(existing: uniqueDevices[existingIndex], new: device)
                #if DEBUG
                SkyBridgeLogger.ui.debugOnly("🔄 DashboardViewModel: 合并重复设备: \(device.name) -> \(uniqueDevices[existingIndex].name)")
                #endif
            } else {
 // 新设备，添加到列表
                uniqueDevices.append(device)
                #if DEBUG
                SkyBridgeLogger.ui.debugOnly("✅ DashboardViewModel: 添加新设备: \(device.name)")
                #endif
            }
        }

        discoveredDevices = uniqueDevices

        #if DEBUG
        SkyBridgeLogger.ui.debugOnly("🔄 DashboardViewModel: 最终设备列表数量: \(discoveredDevices.count)")
        #endif
        for (index, device) in discoveredDevices.enumerated() {
            #if DEBUG
            SkyBridgeLogger.ui.debugOnly("   \(index + 1). \(device.name) - \(device.ipv4 ?? device.ipv6 ?? "无IP") - 服务: \(device.services)")
            #endif
        }

 // 更新发现状态
        if discoveredDevices.isEmpty {
            discoveryStatus = "未发现设备，正在扫描..."
        } else {
            discoveryStatus = "已发现 \(discoveredDevices.count) 台设备"
        }

 // 设备列表变化后刷新仪表盘计数
        updateDashboardCounts()
    }

 // MARK: - 智能设备去重辅助函数

 /// 标准化设备名称（去除常见前缀和后缀）
    private func normalizeDeviceName(_ name: String) -> String {
        var normalized = name.lowercased()

 // 去除常见前缀
        let prefixes = ["的", "de", "s-", "i-", "@"]
        for prefix in prefixes {
            if let range = normalized.range(of: prefix) {
                normalized.removeSubrange(range)
            }
        }

 // 去除空格和特殊字符
        normalized = normalized.replacingOccurrences(of: " ", with: "")
                                .replacingOccurrences(of: "-", with: "")
                                .replacingOccurrences(of: "_", with: "")

        return normalized
    }

 /// 合并设备信息
    private func mergeDeviceInfo(existing: DiscoveredDevice, new: DiscoveredDevice) -> DiscoveredDevice {
 // 合并 IP 地址
        let mergedIPv4 = existing.ipv4 ?? new.ipv4
        let mergedIPv6 = existing.ipv6 ?? new.ipv6

 // 合并服务列表
        var mergedServices = existing.services
        for service in new.services {
            if !mergedServices.contains(service) {
                mergedServices.append(service)
            }
        }

 // 合并端口映射
        var mergedPortMap = existing.portMap
        for (key, value) in new.portMap {
            mergedPortMap[key] = value
        }

 // 合并连接类型
        var mergedConnectionTypes = existing.connectionTypes
        mergedConnectionTypes.formUnion(new.connectionTypes)

 // 更新唯一标识符
        let mergedUniqueId = existing.uniqueIdentifier ?? new.uniqueIdentifier

 // 更新信号强度
        let mergedStrength = new.signalStrength ?? existing.signalStrength

 // 使用更详细的名称
        let mergedName = new.name.count > existing.name.count ? new.name : existing.name

        return DiscoveredDevice(
            id: existing.id,
            name: mergedName,
            ipv4: mergedIPv4,
            ipv6: mergedIPv6,
            services: mergedServices,
            portMap: mergedPortMap,
            connectionTypes: mergedConnectionTypes,
            uniqueIdentifier: mergedUniqueId,
            signalStrength: mergedStrength
        )
    }

 /// 将P2PDevice转换为DiscoveredDevice
    private func convertP2PDeviceToDiscoveredDevice(_ p2pDevice: P2PDevice) -> DiscoveredDevice {
 // 根据P2P设备的能力转换为服务列表
        var services: [String] = ["_skybridge._tcp"]
        var portMap: [String: Int] = ["_skybridge._tcp": Int(p2pDevice.port)]

 // 根据设备能力添加相应的服务
        for capability in p2pDevice.capabilities {
            switch capability {
            case "remote_desktop":
                services.append("_vnc._tcp")
                portMap["_vnc._tcp"] = 5900
            case "file_transfer":
                services.append("_ftp._tcp")
                portMap["_ftp._tcp"] = 21
            case "screen_sharing":
                services.append("_rfb._tcp")
                portMap["_rfb._tcp"] = 5900
            default:
                break
            }
        }

        return DiscoveredDevice(
            id: UUID(uuidString: p2pDevice.id) ?? UUID(),
            name: p2pDevice.name,
            ipv4: p2pDevice.address,
            ipv6: nil,
            services: services,
            portMap: portMap,
            connectionTypes: [.wifi],
            uniqueIdentifier: p2pDevice.address,
            signalStrength: min(100.0, max(0.0, p2pDevice.signalStrength * 100.0))
        )
    }

 // 启动网络连通性监控
 // 网络监控已集中，保留方法签名以兼容，但不再使用本地 NWPathMonitor

 // 统一更新"在线设备/活跃会话/传输任务"的仪表盘计数
 /// 🔧 优化：修复设备计数逻辑，确保与设备发现页面同步
    private func updateDashboardCounts() {
        pendingUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }

 // 🆕 使用统一设备管理器的设备数量
            let onlineCount = self.deviceStats.online
            let connectedCount = self.deviceStats.connected
            let totalDevices = self.deviceStats.total
            let hasUnifiedConnectedPeer = self.onlineDevices.contains { !$0.isLocalDevice && $0.connectionStatus == .connected }
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
            let crossNetworkPeerContribution = (hasCrossNetworkSession && !hasUnifiedConnectedPeer) ? 1 : 0

 // 兼容：如果统一设备列表为空，使用旧的计数逻辑
            let actualOnlineDevices: Int
            if totalDevices > 0 {
                actualOnlineDevices = totalDevices + crossNetworkPeerContribution
            } else {
 // 回退到旧的逻辑
                let discoveredCount = self.discoveredDevices.count
                let usbCount = self.usbcManager.discoveredUSBDevices.filter { info in
                    switch info.deviceType {
                    case .appleMFi, .androidDevice, .audioDevice:
                        return true
                    default:
                        return false
                    }
                }.count
                let fallbackCount = (discoveredCount + usbCount == 0 && self.isNetworkOnline) ? 1 : (discoveredCount + usbCount)
                actualOnlineDevices = fallbackCount + crossNetworkPeerContribution
            }

            self.metrics.onlineDevices = actualOnlineDevices
            self.metrics.activeSessions = self.sessions.filter { $0.status == .connected }.count
                + (hasCrossNetworkSession ? 1 : 0)
            self.metrics.fileTransfers = self.transferTasks.count

            #if DEBUG
            SkyBridgeLogger.ui.debugOnly("📊 DashboardViewModel: 在线设备统计")
            SkyBridgeLogger.ui.debugOnly("   在线设备: \(onlineCount)")
            SkyBridgeLogger.ui.debugOnly("   已连接设备: \(connectedCount)")
            SkyBridgeLogger.ui.debugOnly("   网络状态: \(self.isNetworkOnline ? "在线" : "离线")")
            SkyBridgeLogger.ui.debugOnly("   总设备数: \(actualOnlineDevices)")
            #endif
        }
        pendingUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
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
        onlineDevices = newMetrics.onlineDevices
        activeSessions = newMetrics.activeSessions
        fileTransfers = newMetrics.transferCount
        alerts = newMetrics.alertCount
        timeline = newMetrics.cpuTimeline
    }
}
