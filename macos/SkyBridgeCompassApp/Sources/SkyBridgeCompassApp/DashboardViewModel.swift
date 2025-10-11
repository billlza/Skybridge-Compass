import Foundation
import Combine
import SkyBridgeCore
#if canImport(OrderedCollections)
import OrderedCollections
#endif
import AppKit
import SwiftUI

/// 仪表盘主视图模型，协调真实设备扫描、会话管理及文件传输状态。
@available(macOS 14.0, *)
@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var metrics = DashboardMetrics()
    @Published private(set) var sessions: [RemoteSessionSummary] = []
    @Published private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published private(set) var transferTasks: [FileTransferTask] = []
    @Published private(set) var discoveryStatus: String = "等待扫描真实设备"
    @Published private(set) var tenants: [TenantDescriptor] = []
    @Published private(set) var activeTenant: TenantDescriptor?
    
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

    private let discoveryService = DeviceDiscoveryService()
    private let sessionService = RemoteDesktopManager()
    private let fileTransferService = FileTransferManager()
    let systemMetricsService = SystemMetricsService()
    private let tenantController = TenantAccessController.shared
    
    // 性能优化组件
    private var performanceCoordinator: PerformanceCoordinator?
    
    private var cancellables = Set<AnyCancellable>()
    private var isAuthenticated: Bool {
        tenantController.accessToken != nil
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
        // 如果已经启动，直接返回
        if !cancellables.isEmpty {
            systemMetricsService.startMonitoring()
            return 
        }
        guard cancellables.isEmpty else { return }

        tenantController.bootstrap()
        
        // 启动系统指标监控
        systemMetricsService.startMonitoring()
        
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

        discoveryService.discoveryState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.discoveryStatus = state.statusDescription
                self?.discoveredDevices = state.devices
            }
            .store(in: &cancellables)

        sessionService.sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.sessions = $0 }
            .store(in: &cancellables)

        sessionService.metrics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] metrics in
                self?.metrics.merge(with: metrics)
            }
            .store(in: &cancellables)

        fileTransferService.transfers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.transferTasks = $0 }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .skyBridgeIntentConnect)
            .compactMap { $0.userInfo?[SkyBridgeIntentPayloadKey.deviceName] as? String }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] target in
                guard let self else { return }
                Task { await self.handleSiriConnectRequest(targetName: target) }
            }
            .store(in: &cancellables)

        await discoveryService.start()
        sessionService.bootstrap()
        await fileTransferService.prepare()
    }

    /// 停止所有订阅并释放资源，通常在界面离开或退出登录时调用。
    func stop() {
        cancellables.removeAll()
        discoveryService.stop()
        sessionService.shutdown()
        fileTransferService.stop()
        systemMetricsService.stopMonitoring()
        performanceCoordinator?.stopPerformanceCoordination()
        performanceCoordinator = nil
    }
    
    /// 设置性能监控
    private func setupPerformanceMonitoring() {
        guard let coordinator = performanceCoordinator else { return }
        
        // 监听性能指标更新
        coordinator.$performanceMetrics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] metrics in
                self?.performanceMetrics = metrics
            }
            .store(in: &cancellables)
        
        // 监听热量状态更新 - 从性能指标中获取
        coordinator.$performanceMetrics
            .map(\.thermalState)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.thermalState = state
            }
            .store(in: &cancellables)
        
        // 监听电源状态更新 - 从性能指标中获取
        coordinator.$performanceMetrics
            .map(\.powerState)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.powerState = state
            }
            .store(in: &cancellables)
        
        // 监听性能建议更新 - 从协调器获取
        Timer.publish(every: 5.0, on: .main, in: .common)
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
    func terminate(session: RemoteSessionSummary) async {
        await sessionService.terminate(sessionID: session.id)
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
        do {
            try tenantController.setActiveTenant(id: tenant.id)
        } catch {
            discoveryStatus = error.localizedDescription
        }
    }

    @discardableResult
    /// 注册一个新的真实租户并保存到钥匙串。
    func registerTenant(displayName: String,
                        username: String,
                        password: String,
                        domain: String?,
                        permissions: TenantPermission) -> Bool {
        do {
            try tenantController.registerTenant(displayName: displayName, username: username, password: password, domain: domain, permissions: permissions)
            return true
        } catch {
            discoveryStatus = error.localizedDescription
            return false
        }
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
