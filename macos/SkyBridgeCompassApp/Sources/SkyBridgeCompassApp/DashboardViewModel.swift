import Foundation
import Combine
import OrderedCollections
import AppKit
import SkyBridgeCore

/// 仪表盘主视图模型，协调真实设备扫描、会话管理及文件传输状态。
@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var metrics = DashboardMetrics()
    @Published private(set) var sessions: [RemoteSessionSummary] = []
    @Published private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published private(set) var transferTasks: [FileTransferTask] = []
    @Published private(set) var discoveryStatus: String = "等待扫描真实设备"
    @Published private(set) var tenants: [TenantDescriptor] = []
    @Published private(set) var activeTenant: TenantDescriptor?

    private let discoveryService = DeviceDiscoveryService()
    private let sessionService = RemoteDesktopManager()
    private let fileTransferService = FileTransferManager()
    private let tenantController = TenantAccessController.shared
    private var cancellables = Set<AnyCancellable>()
    private var isAuthenticated: Bool {
        tenantController.accessToken != nil
    }

    /// 由根视图调用以更新认证状态。
    func updateAuthentication(session: AuthSession?) {
        if let session {
            tenantController.bindAuthentication(session: session)
        } else {
            tenantController.clearAuthentication()
            stop()
        }
    }

    /// 根据当前认证状态启动各项后台服务。
    func start() async {
        guard isAuthenticated else { return }
        guard cancellables.isEmpty else { return }

        tenantController.bootstrap()

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
        fileTransferService.prepare()
    }

    /// 停止所有订阅并释放资源，通常在界面离开或退出登录时调用。
    func stop() {
        cancellables.removeAll()
        discoveryService.stop()
        sessionService.shutdown()
        fileTransferService.stop()
    }

    /// 手动触发一次真实设备重新扫描。
    func triggerDiscoveryRefresh() {
        discoveryService.refresh()
    }

    /// 打开标准的应用设置面板。
    func openSettings() {
        NSApp.sendAction(#selector(NSApplication.orderFrontStandardAboutPanel(_:)), to: nil, from: nil)
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
            let tenant = try tenantController.requirePermission(.remoteDesktop)
            try await sessionService.connect(to: device, tenant: tenant)
        } catch {
            await MainActor.run {
                discoveryStatus = error.localizedDescription
            }
        }
    }

    private func handleSiriConnectRequest(targetName: String) async {
        guard let tenant = try? tenantController.requirePermission(.remoteDesktop) else { return }
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
