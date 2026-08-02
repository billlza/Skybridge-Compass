//
// DashboardViewModel.swift
// SkyBridgeCompassiOS
//
// 主控制台视图模型 - 管理仪表板状态和数据
//

import Foundation
import SwiftUI
import Combine
import Network
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Dashboard Metrics

/// 仪表板指标
public struct DashboardMetrics: Sendable {
    public var onlineDevices: Int = 0
    public var activeSessions: Int = 0
    public var fileTransfers: Int = 0
    public var pendingMessages: Int = 0
    
    public init() {}
}

// MARK: - Dashboard ViewModel

/// 仪表板视图模型
@available(iOS 17.0, *)
@MainActor
public class DashboardViewModel: ObservableObject {
    
    // MARK: - Singleton
    
    public static let shared = DashboardViewModel()
    
    // MARK: - Published Properties
    
    /// 仪表板指标
    @Published public var metrics = DashboardMetrics()
    
    /// 发现的设备列表
    @Published public var discoveredDevices: [DiscoveredDevice] = []
    
    /// 活跃连接
    @Published public var activeConnections: [Connection] = []
    
    /// 最近的文件传输
    @Published public var recentTransfers: [FileTransfer] = []
    
    /// 当前网络状态
    @Published public var networkStatus: NetworkStatus = .disconnected
    
    /// 系统性能状态
    @Published public var performanceStatus: PerformanceStatus = .excellent

    /// 顶部主连接状态展示（唯一语义来源）
    @Published public private(set) var topConnectionPresentation = ConnectionPresentation(
        phase: .disconnected,
        isConnected: false,
        statusText: RuntimeLocalization.string("离线"),
        detailText: nil
    )
    
    /// 是否正在刷新
    @Published public var isRefreshing: Bool = false
    
    /// 当前用户
    @Published public var currentUser: User?
    
    /// 错误消息
    @Published public var errorMessage: String?
    
    // MARK: - Private Properties
    
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.skybridge.dashboard.network")
    private let crossNetworkManager = CrossNetworkWebRTCManager.instance
    private var lastPresentedPeerDevice: DiscoveredDevice?
    
    // MARK: - Initialization
    
    private init() {
        setupBindings()
        startNetworkMonitoring()
    }

    deinit {
        pathMonitor.cancel()
    }
    
    // MARK: - Public Methods
    
    /// 启动仪表板
    public func start() async {
        // Idempotency: SwiftUI may recreate the dashboard view during launch/auth transitions.
        // If we schedule multiple timers we will trigger discovery/refresh storms and can get killed for memory.
        if refreshTimer != nil { return }
        await refresh()
        guard !SkyBridgeRuntimeEnvironment.shouldSkipInteractiveStartup else { return }
        startAutoRefresh()
    }
    
    /// 停止仪表板
    public func stop() {
        stopAutoRefresh()
    }
    
    /// 刷新数据
    public func refresh() async {
        guard !SkyBridgeRuntimeEnvironment.shouldSkipInteractiveStartup else {
            synchronizeDashboardSnapshot()
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        // 刷新设备发现
        let discoveryManager = DeviceDiscoveryManager.instance
        let startedNow = !discoveryManager.isDiscovering
        // 后台不重启发现：否则 30s 自动刷新会抵消 scenePhase 的省电拆除，让 Bonjour/NWBrowser 在后台持续运行耗电。
        if startedNow && UIApplication.shared.applicationState == .active {
            try? await discoveryManager.startDiscovery()
            // 仅在“本次确实启动了发现”时做一次短等待，避免空列表闪烁。
            try? await Task.sleep(for: .milliseconds(600))
        }

        synchronizeDashboardSnapshot()
    }
    
    /// 触发设备发现刷新
    public func triggerDiscoveryRefresh() {
        guard !SkyBridgeRuntimeEnvironment.shouldSkipInteractiveStartup else { return }
        Task {
            try? await DeviceDiscoveryManager.instance.startDiscovery()
        }
    }
    
    /// 快速连接到设备
    public func quickConnect(to device: DiscoveredDevice) async throws {
        try await P2PConnectionManager.instance.connect(to: device)
    }
    
    /// 断开设备连接
    public func disconnect(from device: DiscoveredDevice) async {
        await P2PConnectionManager.instance.disconnect(from: device)
    }
    
    // MARK: - Private Methods

    private func synchronizeDashboardSnapshot() {
        discoveredDevices = DeviceDiscoveryManager.instance.discoveredDevices
        activeConnections = P2PConnectionManager.instance.activeConnections
        updateMetrics()
    }

    private func setupBindings() {
        // 监听设备发现变化。节流到最多每 300ms 一次：发现扫描时该 publisher 会高频突发，
        // 每次都重算指标/呈现是主线程负担（与 mac 端节流修复同理）。latest:true 保证最终状态仍渲染。
        DeviceDiscoveryManager.instance.$discoveredDevices
            .throttle(for: .milliseconds(300), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] devices in
                self?.discoveredDevices = devices
                self?.updateMetrics()
            }
            .store(in: &cancellables)
        
        // 监听连接变化
        P2PConnectionManager.instance.$activeConnections
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connections in
                self?.activeConnections = connections
                self?.updateMetrics()
            }
            .store(in: &cancellables)

        P2PConnectionManager.instance.$negotiatedSuiteByDeviceId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateConnectionPresentation()
            }
            .store(in: &cancellables)

        P2PConnectionManager.instance.$rekeyStatusByDeviceId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateConnectionPresentation()
            }
            .store(in: &cancellables)

        P2PConnectionManager.instance.$connectionStatusByDeviceId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateConnectionPresentation()
            }
            .store(in: &cancellables)
        
        // 监听文件传输变化（活跃 + 历史），确保首页能看到“进行中/已完成”
        Publishers.CombineLatest(
            FileTransferManager.instance.$activeTransfers,
            FileTransferManager.instance.$transferHistory
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] active, history in
            let merged = (active + history)
                .sorted { $0.timestamp > $1.timestamp }
            self?.recentTransfers = Array(merged.prefix(5))
            self?.updateMetrics()
        }
        .store(in: &cancellables)
        
        // 监听离线消息
        OfflineMessageQueue.shared.$totalCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.metrics.pendingMessages = count
            }
            .store(in: &cancellables)

        Publishers.CombineLatest4(
            crossNetworkManager.$state,
            crossNetworkManager.$readiness,
            crossNetworkManager.$remoteDeviceId,
            crossNetworkManager.$activeSessionSnapshot
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, _, _, _ in
            self?.updateMetrics()
        }
        .store(in: &cancellables)
    }
    
    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.updateNetworkStatus(isReachable: path.status == .satisfied)
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func updateNetworkStatus(isReachable: Bool) {
        networkStatus = isReachable ? .connected : .disconnected
        updateConnectionPresentation()
    }

    private func updateMetrics() {
        let hasCrossNetworkSession = isCrossNetworkSessionActive
        let hasDistinctCrossNetworkPeer = hasCrossNetworkSession && !isCrossNetworkPeerAlreadyDiscovered

        metrics.onlineDevices = discoveredDevices.count + (hasDistinctCrossNetworkPeer ? 1 : 0)
        metrics.activeSessions = activeConnections.count + (hasCrossNetworkSession ? 1 : 0)
        metrics.fileTransfers = FileTransferManager.instance.activeTransfers.count
        updateConnectionPresentation()
    }

    private var isCrossNetworkSessionActive: Bool {
        guard let snapshot = crossNetworkManager.activeSessionSnapshot else { return false }
        switch snapshot.phase {
        case .transportReady, .handshakeComplete, .reconnecting:
            return true
        case .connecting, .disconnecting:
            return false
        }
    }

    private var isCrossNetworkPeerAlreadyDiscovered: Bool {
        guard let remoteDeviceId = crossNetworkManager.remoteDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !remoteDeviceId.isEmpty else {
            return false
        }
        return discoveredDevices.contains { $0.id == remoteDeviceId }
    }
    
    private func startAutoRefresh() {
        // Defensive: avoid timer duplication even if startAutoRefresh is called twice.
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
        refreshTimer?.tolerance = 6 // 允许系统合并唤醒（省电）
    }
    
    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func updateConnectionPresentation() {
        let connectionManager = P2PConnectionManager.instance
        let latestPeerConnection = activeConnections
            .sorted { $0.connectedAt > $1.connectedAt }
            .first
            .map { connection in
                lastPresentedPeerDevice = connection.device
                if let rekey = connectionManager.resolvedRekeyStatus(for: connection.device) {
                    return ConnectionPresentationPeer(
                        displayName: connection.device.name,
                        cryptoKind: "\(rekey.fromSuite) → \(rekey.toSuite)",
                        suite: nil,
                        guardStatus: RuntimeLocalization.string("Rekey 中"),
                        isRekeying: true,
                        connectedAt: connection.connectedAt
                    )
                }

                return ConnectionPresentationPeer(
                    displayName: connection.device.name,
                    cryptoKind: nil,
                    suite: connectionManager.getNegotiatedSuite(for: connection.device.id)?.rawValue,
                    guardStatus: RuntimeLocalization.string("守护中"),
                    connectedAt: connection.connectedAt
                )
            }

        let localFallback = latestPeerConnection == nil
            ? localConnectionPresentationFallback(using: connectionManager)
            : (connected: Optional<ConnectionPresentationPeer>.none, pending: Optional<ConnectionPresentationPendingPeer>.none)

        let disconnectedText = networkStatus == .disconnected
            ? RuntimeLocalization.string("离线")
            : RuntimeLocalization.string("在线")

        topConnectionPresentation = ConnectionPresentationContract.evaluate(
            ConnectionPresentationInput(
                labels: ConnectionPresentationLabels(
                    connectedText: RuntimeLocalization.string("已连接"),
                    disconnectedText: disconnectedText,
                    connectingText: RuntimeLocalization.string("连接中"),
                    reconnectingText: RuntimeLocalization.string("重连中"),
                    defaultGuardStatus: RuntimeLocalization.string("守护中"),
                    crossNetworkGuardStatus: RuntimeLocalization.string("跨网已连接")
                ),
                fileTransferActive: !FileTransferManager.instance.activeTransfers.isEmpty,
                latestPeerConnection: latestPeerConnection,
                latestConnectedDevice: localFallback.connected,
                latestPendingPeer: localFallback.pending,
                activeSessionSnapshot: crossNetworkManager.activeSessionSnapshot,
                defaultPQCModeLabel: nil
            )
        )

        if localFallback.connected == nil, localFallback.pending == nil, latestPeerConnection == nil {
            lastPresentedPeerDevice = nil
        }
    }

    private func localConnectionPresentationFallback(
        using connectionManager: P2PConnectionManager
    ) -> (connected: ConnectionPresentationPeer?, pending: ConnectionPresentationPendingPeer?) {
        struct Candidate {
            let device: DiscoveredDevice
            let status: ConnectionStatus
            let suite: String?
            let rekey: P2PConnectionManager.RekeyPresentationStatus?
            let updatedAt: Date
        }

        let candidates = localPresentationCandidateDevices(using: connectionManager)
            .compactMap { device -> Candidate? in
                let resolvedDevice = connectionManager.resolvedPeerDevice(for: device)
                guard let status = connectionManager.resolvedConnectionStatus(for: resolvedDevice) else {
                    return nil
                }
                switch status {
                case .connected, .connecting, .disconnecting:
                    break
                case .failed, .error, .disconnected:
                    return nil
                }

                let rekey = connectionManager.resolvedRekeyStatus(for: resolvedDevice)
                let suite = connectionManager.getNegotiatedSuite(for: resolvedDevice.id)?.rawValue
                let updatedAt = rekey?.startedAt ?? resolvedDevice.lastSeen
                return Candidate(
                    device: resolvedDevice,
                    status: status,
                    suite: suite,
                    rekey: rekey,
                    updatedAt: updatedAt
                )
            }
            .sorted { lhs, rhs in
                let lhsPriority = localPresentationPriority(for: lhs.status)
                let rhsPriority = localPresentationPriority(for: rhs.status)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                return lhs.updatedAt > rhs.updatedAt
            }

        guard let candidate = candidates.first else {
            return (nil, nil)
        }

        lastPresentedPeerDevice = candidate.device

        if candidate.status == .connected {
            if let rekey = candidate.rekey {
                return (
                    connected: ConnectionPresentationPeer(
                        displayName: candidate.device.name,
                        cryptoKind: "\(rekey.fromSuite) → \(rekey.toSuite)",
                        suite: nil,
                        guardStatus: RuntimeLocalization.string("Rekey 中"),
                        isRekeying: true,
                        connectedAt: candidate.updatedAt
                    ),
                    pending: nil
                )
            }

            return (
                connected: ConnectionPresentationPeer(
                    displayName: candidate.device.name,
                    cryptoKind: nil,
                    suite: candidate.suite,
                    guardStatus: RuntimeLocalization.string("守护中"),
                    connectedAt: candidate.updatedAt
                ),
                pending: nil
            )
        }

        let phase: ConnectionPresentationPhase =
            (candidate.rekey != nil || candidate.suite != nil || candidate.status == .disconnecting)
            ? .reconnecting
            : .connecting

        return (
            connected: nil,
            pending: ConnectionPresentationPendingPeer(
                displayName: candidate.device.name,
                cryptoKind: candidate.rekey.map { "\($0.fromSuite) → \($0.toSuite)" },
                suite: candidate.rekey == nil ? candidate.suite : nil,
                guardStatus: candidate.rekey == nil ? nil : RuntimeLocalization.string("Rekey 中"),
                isRekeying: candidate.rekey != nil,
                phase: phase
            )
        )
    }

    private func localPresentationCandidateDevices(
        using connectionManager: P2PConnectionManager
    ) -> [DiscoveredDevice] {
        var devices = discoveredDevices
        devices.append(contentsOf: activeConnections.map(\.device))
        if let lastPresentedPeerDevice {
            devices.append(lastPresentedPeerDevice)
        }

        var ordered: [DiscoveredDevice] = []
        var seen = Set<String>()
        for device in devices {
            let resolved = connectionManager.resolvedPeerDevice(for: device)
            if seen.insert(resolved.id).inserted {
                ordered.append(resolved)
            }
        }
        return ordered
    }

    private func localPresentationPriority(for status: ConnectionStatus) -> Int {
        switch status {
        case .connected:
            return 0
        case .connecting:
            return 1
        case .disconnecting:
            return 2
        case .failed:
            return 3
        case .error:
            return 4
        case .disconnected:
            return 5
        }
    }
}

// MARK: - Supporting Types

/// 网络状态
public enum NetworkStatus: String, Sendable {
    case connected = "connected"
    case disconnected = "disconnected"
    case connecting = "connecting"
    case limited = "limited"
    
    public var displayName: String {
        switch self {
        case .connected: return RuntimeLocalization.string("在线")
        case .disconnected: return RuntimeLocalization.string("离线")
        case .connecting: return RuntimeLocalization.string("连接中")
        case .limited: return RuntimeLocalization.string("受限")
        }
    }
    
    public var icon: String {
        switch self {
        case .connected: return "wifi"
        case .disconnected: return "wifi.slash"
        case .connecting: return "wifi.exclamationmark"
        case .limited: return "wifi.exclamationmark"
        }
    }
    
    public var color: Color {
        switch self {
        case .connected: return .green
        case .disconnected: return .red
        case .connecting: return .orange
        case .limited: return .yellow
        }
    }
}

/// 性能状态
public enum PerformanceStatus: String, Sendable {
    case excellent = "excellent"
    case good = "good"
    case fair = "fair"
    case poor = "poor"
    
    public var displayName: String {
        switch self {
        case .excellent: return RuntimeLocalization.string("优秀")
        case .good: return RuntimeLocalization.string("良好")
        case .fair: return RuntimeLocalization.string("一般")
        case .poor: return RuntimeLocalization.string("较差")
        }
    }
    
    public var icon: String {
        switch self {
        case .excellent: return "checkmark.circle.fill"
        case .good: return "checkmark.circle"
        case .fair: return "exclamationmark.circle"
        case .poor: return "xmark.circle"
        }
    }
    
    public var color: Color {
        switch self {
        case .excellent: return .green
        case .good: return .blue
        case .fair: return .orange
        case .poor: return .red
        }
    }
}
