//
// DeviceDiscoveryManager.swift
// Skybridge-Compass
//
// macOS 26.x / Swift 6.2.1
// 基于 Network.framework + Bonjour 的本地设备发现与 TCP 连接管理
//

import Foundation
import Network
import OSLog
import CryptoKit
import Combine
import Security

/// 设备发现管理器 - 基于 2025 年 Apple 推荐栈
/// 使用 Network.framework 的 Bonjour 能力 + TCP 连接
///
/// 继承 BaseManager，统一管理器模式和生命周期管理
@MainActor
public class P2PDiscoveryService: BaseManager {
    public static let shared = P2PDiscoveryService()

 // MARK: - 发布的属性（给 SwiftUI / 视图层用）

 /// 发现的设备列表（Bonjour + 自定义逻辑融合）
    @Published public var discoveredDevices: [DiscoveredDevice] = []
 /// P2P设备列表（供上层统一使用）
    @Published public var p2pDevices: [P2PDevice] = []

 /// 当前连接状态（只是对 connections 字典的一个抽象）
    @Published public var connectionStatus: P2PDiscoveryConnectionStatus = .disconnected

    /// 当前已建立的入站会话数量（用于 UI 显示“被连接/已连接”）
    @Published public private(set) var activeInboundSessions: Int = 0

 /// 是否正在扫描（有无浏览器在跑）
    @Published public var isScanning: Bool = false
 /// P2P发现是否运行中
    @Published public var isDiscovering: Bool = false
 /// 是否正在广播服务
    @Published public var isAdvertising: Bool = false

 // MARK: - 私有属性

 /// Bonjour 浏览器（一个 serviceType 对应一个 NWBrowser）
    private var browsers: [NWBrowser] = []

 /// Bonjour 监听器（本机作为服务端被发现）
    private var listener: NWListener?

    /// 当前活跃连接（按 DiscoveredDevice.id.uuidString 存）
    private var connections: [String: NWConnection] = [:]
    /// 已完成应用层握手认证的连接（用于保持 P2PConnection 生命周期）
    private var authenticatedConnections: [String: P2PConnection] = [:]
    private struct InboundControlSession {
        let connection: NWConnection
        var aliases: Set<String>
    }
    private var inboundControlSessions: [UUID: InboundControlSession] = [:]
    private var txtResolveCooldown: [String: Date] = [:]
    private let outboundConnectionQueue = DispatchQueue(
        label: "com.skybridge.p2p.discovery.outbound-connection",
        qos: .utility
    )

 /// 服务类型瘦身策略 - 默认仅SkyBridge；兼容/调试模式可扩展
    private let allServiceTypes = [
        BonjourInteropContract.controlServiceType,
        BonjourInteropContract.fileTransferServiceType,
        BonjourInteropContract.remoteControlServiceType,
        "_companion-link._tcp",
        "_airplay._tcp",
        "_rdlink._tcp",
        "_sftp-ssh._tcp"
    ]
 /// 兼容模式与 companion-link 开关（默认关闭，正常用户场景仅SkyBridge）
    public var enableCompatibilityMode: Bool = false
    public var enableCompanionLink: Bool = false
    private var activeBrowserServiceTypes: Set<String> = []
    private func effectiveServiceTypes() -> [String] {
        var base = BonjourInteropContract.defaultDiscoveryServiceTypes
        if enableCompanionLink { base.append("_companion-link._tcp") }
        if enableCompatibilityMode {
            base.append(contentsOf: allServiceTypes.filter { !$0.hasPrefix("_skybridge") && !$0.hasPrefix("_companion-link") })
        }
        return base
    }

    private let serviceDomain = "local."

    private enum ConnectionSecurityPlan: String {
        case encryptedTLS = "tls"
        case plainTCP = "tcp"
    }

    public enum ConnectionRoutePreference: Sendable {
        case automatic
        case preferUSB
        case managedRelayOnly
    }

    #if DEBUG
    func testingReplaceAuthenticatedConnections(_ connections: [String: P2PConnection]) {
        authenticatedConnections = connections
    }
    #endif

    private static let controlServiceType = BonjourInteropContract.controlServiceType
    private static let controlAdvertisementOwner = "P2PDiscoveryService"

    public func activeAuthenticatedConnectionsForClassicTransfer() -> [P2PConnection] {
        authenticatedConnections.values.filter { $0.status == .authenticated }
    }

    private static func normalizedInboundControlAliases(_ aliases: [String?]) -> Set<String> {
        aliases.reduce(into: Set<String>()) { result, raw in
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return }
            for candidate in PeerTrustLookup.lookupCandidates(for: raw) {
                let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty else { continue }
                result.insert(normalized)
            }
        }
    }

    private func upsertInboundControlSession(
        id: UUID,
        connection: NWConnection,
        aliases rawAliases: [String?]
    ) {
        let aliases = Self.normalizedInboundControlAliases(rawAliases)
        guard !aliases.isEmpty else { return }

        var session = inboundControlSessions[id] ?? InboundControlSession(
            connection: connection,
            aliases: []
        )
        session.aliases.formUnion(aliases)
        inboundControlSessions[id] = session
    }

    private func removeInboundControlSession(id: UUID) {
        inboundControlSessions.removeValue(forKey: id)
    }

    private enum InterfacePreference: String {
        case automatic
        case wiredEthernetOnly
    }

    private actor NetServiceResolveLimiter {
        private let limit: Int
        private var inFlight = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(limit: Int) {
            self.limit = max(1, limit)
        }

        func withPermit<T>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
            await acquire()
            defer { release() }
            return try await operation()
        }

        private func acquire() async {
            if inFlight < limit {
                inFlight += 1
                return
            }

            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
            inFlight += 1
        }

        private func release() {
            inFlight = max(0, inFlight - 1)
            if let waiter = waiters.first {
                waiters.removeFirst()
                waiter.resume()
            }
        }
    }

    private struct NetServiceResolvedEndpoint: Sendable {
        let port: Int
        let ipv4: String?
        let ipv6: String?
    }

    private struct LocalInterfaceCacheEntry: Sendable {
        let addresses: Set<String>
        let normalizedHostName: String
        let updatedAt: Date
    }

    private enum NetServiceResolveError: LocalizedError {
        case resolveFailed([String: NSNumber])

        var errorDescription: String? {
            switch self {
            case .resolveFailed(let info):
                return "NetService 解析失败: \(info)"
            }
        }
    }

    private final class NetServiceResolveContext: NSObject, NetServiceDelegate, @unchecked Sendable {
        private let resumed = OSAllocatedUnfairLock(initialState: false)
        private let continuation: CheckedContinuation<NetServiceResolvedEndpoint, Error>
        private let service: NetService
        private let timeoutSeconds: TimeInterval
        private var timeoutTask: Task<Void, Never>?
        private var selfRetain: NetServiceResolveContext?

        init(
            service: NetService,
            timeoutSeconds: TimeInterval,
            continuation: CheckedContinuation<NetServiceResolvedEndpoint, Error>
        ) {
            self.service = service
            self.timeoutSeconds = timeoutSeconds
            self.continuation = continuation
            super.init()
            self.selfRetain = self
        }

        func start() {
            service.delegate = self
            service.schedule(in: .main, forMode: .common)
            service.resolve(withTimeout: timeoutSeconds)

            timeoutTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard !Task.isCancelled else { return }
                self.finish(.failure(P2PDiscoveryError.timeout))
            }
        }

        func netServiceDidResolveAddress(_ sender: NetService) {
            let port = max(0, sender.port)
            var foundIPv4: String?
            var foundIPv6: String?

            if let addresses = sender.addresses {
                for data in addresses {
                    let address = P2P_ExtractIPAddress(from: data)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    guard !address.isEmpty, address != "未知地址" else { continue }
                    if address.contains("."), !address.hasPrefix("169.254"), !address.hasPrefix("127."), foundIPv4 == nil {
                        foundIPv4 = address
                    } else if address.contains(":"), !address.hasPrefix("fe80:"), foundIPv6 == nil {
                        foundIPv6 = address
                    }
                }
            }

            finish(.success(NetServiceResolvedEndpoint(port: port, ipv4: foundIPv4, ipv6: foundIPv6)))
        }

        func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
            finish(.failure(NetServiceResolveError.resolveFailed(errorDict)))
        }

        private func finish(_ result: Result<NetServiceResolvedEndpoint, Error>) {
            let shouldResume = resumed.withLock { state -> Bool in
                guard !state else { return false }
                state = true
                return true
            }
            guard shouldResume else { return }

            timeoutTask?.cancel()
            timeoutTask = nil
            service.stop()
            service.delegate = nil
            service.remove(from: .main, forMode: .common)

            switch result {
            case .success(let resolved):
                continuation.resume(returning: resolved)
            case .failure(let error):
                continuation.resume(throwing: error)
            }

            selfRetain = nil
        }
    }

    private final class WaitForConnectionContext: @unchecked Sendable {
        private let resumed = OSAllocatedUnfairLock(initialState: false)
        private let continuation: CheckedContinuation<Void, Error>
        var timeoutTask: Task<Void, Never>?

        init(continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        func complete(_ result: Result<Void, Error>) {
            let shouldResume = resumed.withLock { isResumed -> Bool in
                guard !isResumed else { return false }
                isResumed = true
                return true
            }
            guard shouldResume else { return }
            timeoutTask?.cancel()
            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private final class SendContentContext: @unchecked Sendable {
        private let resumed = OSAllocatedUnfairLock(initialState: false)
        private let continuation: CheckedContinuation<Void, Error>
        private let connection: NWConnection
        var timeoutTask: Task<Void, Never>?

        init(continuation: CheckedContinuation<Void, Error>, connection: NWConnection) {
            self.continuation = continuation
            self.connection = connection
        }

        func cancelConnection() {
            connection.cancel()
        }

        func complete(_ result: Result<Void, Error>) {
            let shouldResume = resumed.withLock { isResumed -> Bool in
                guard !isResumed else { return false }
                isResumed = true
                return true
            }
            guard shouldResume else { return }
            timeoutTask?.cancel()
            timeoutTask = nil
            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private let netServiceResolveLimiter = NetServiceResolveLimiter(limit: 4)
    private var localInterfaceCacheEntry: LocalInterfaceCacheEntry?
    private let localInterfaceCacheTTL: TimeInterval = 8

 // MARK: - 初始化

    public init() {
        super.init(category: "DeviceDiscoveryManager")
        $discoveredDevices
            .map { $0.map { Self.mapToP2PDevice($0) } }
            .assign(to: &self.$p2pDevices)
    }

 // MARK: - BaseManager 重写

 /// 执行设备发现管理器的初始化逻辑
    public override func performInitialization() async {
        await super.performInitialization()
        logger.info("✅ 设备发现管理器初始化完成")
    }

 /// 启动设备发现管理器
    public override func performStart() async throws {
        logger.info("🚀 启动设备发现服务")
        startScanning()
    }

 /// 停止设备发现管理器
    public override func performStop() async {
        logger.info("🛑 停止设备发现服务")
        stopScanning()
    }

 /// 清理资源
    public override func cleanup() {
        super.cleanup()

 // 清理发现的设备
        discoveredDevices.removeAll()
        connectionStatus = .disconnected
        activeInboundSessions = 0
        isScanning = false

 // 清理网络连接
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        authenticatedConnections.values.forEach { $0.disconnect() }
        authenticatedConnections.removeAll()

 // 停止 Bonjour 浏览 / 广播
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        activeBrowserServiceTypes.removeAll()
        listener?.cancel()
        listener = nil
    }

 // MARK: - 公共方法（扫描 / 连接）

    /// 开始扫描设备 - 2025 增强版：多服务类型扫描（全基于 Network.framework）
    public func startScanning() {
        guard isInitialized else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if await self.waitUntilInitialized() {
                    self.startScanning()
                } else {
                    await self.handleError(.notInitialized)
                }
            }
            return
        }
        guard !isScanning else {
            logger.debug("startScanning() 忽略：已经在扫描中")
            return
        }

        let selected = effectiveServiceTypes()
        logger.info("🔍 开始扫描设备（Bonjour，服务类型：\(selected)）")
        isScanning = true
        isDiscovering = true

        startBrowsers(for: selected)
        startAdvertising()
    }

    private func startBrowsers(for selected: [String]) {
        activeBrowserServiceTypes = Set(selected)

	 // 为每种服务类型创建独立的浏览器
        for serviceType in selected {
            let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: serviceType, domain: serviceDomain)
            let parameters = NWParameters()
            parameters.includePeerToPeer = true  // 支持点对点（AWDL / 直连）

            let browser = NWBrowser(for: descriptor, using: parameters)

 // 设置状态更新处理器
            browser.stateUpdateHandler = { [weak self, serviceType] state in
                Task { @MainActor in
                    self?.handleBrowserStateUpdate(state, for: serviceType)
                }
            }

 // 设置结果变化处理器
            browser.browseResultsChangedHandler = { [weak self, serviceType] results, changes in
                Task { @MainActor in
                    self?.handleBrowseResultsChanged(results: results,
                                                     changes: changes,
                                                     serviceType: serviceType)
                }
            }

 // 启动浏览器
            browser.start(queue: .global(qos: .utility))
            browsers.append(browser)

            logger.debug("  ✅ 启动浏览器: \(serviceType)")
        }
    }

 /// 启动发现（与 startScanning 同义，供上层统一调用）
    public func startDiscovery() {
        startScanning()
    }

 /// 停止发现（与 stopScanning 同义，供上层统一调用）
    public func stopDiscovery() {
        stopScanning()
    }

    public func applyDiscoverySettings(
        compatibilityMode: Bool,
        companionLink: Bool
    ) {
        let previousDesired = Set(effectiveServiceTypes())
        enableCompatibilityMode = compatibilityMode
        enableCompanionLink = companionLink
        let desired = Set(effectiveServiceTypes())
        guard desired != previousDesired || desired != activeBrowserServiceTypes else {
            return
        }

        logger.info("🔄 P2P 发现设置已实时应用: compatibility=\(compatibilityMode) companionLink=\(companionLink) serviceTypes=\(desired.sorted())")
        guard isScanning else { return }

        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        startBrowsers(for: desired.sorted())
    }

 /// 刷新设备列表（重启扫描）
    public func refreshDevices() async {
        // UX fix:
        // A hard stop/start here interrupts ongoing handshakes/transfers and creates reconnect loops.
        // For "refresh", we keep browsers/listener running and simply clear transient caches.
        logger.info("🔄 刷新设备列表（软刷新：不停止扫描/不重启广播）")
        discoveredDevices.removeAll()
        txtResolveCooldown.removeAll()
        if connections.isEmpty && authenticatedConnections.isEmpty {
            connectionStatus = .disconnected
        }
        // Ensure advertising is on while scanning.
        if isScanning, !isAdvertising {
            startAdvertising()
        }
    }

    /// 停止扫描设备
    public func stopScanning() {
        if isScanning {
            logger.info("⏹️ 停止扫描设备")
            isScanning = false
            isDiscovering = false

            // 取消所有浏览器
            for browser in browsers {
                browser.cancel()
            }
            browsers.removeAll()
            activeBrowserServiceTypes.removeAll()
        }

        if connections.isEmpty && authenticatedConnections.isEmpty {
            connectionStatus = .disconnected
        }

        stopAdvertising()
    }

    /// 连接到指定设备（优先 Bonjour 服务名，失败时自动回退到 host:port）
    public func connectToDevice(_ device: DiscoveredDevice) async throws {
        let preferredRoute: ConnectionRoutePreference = SettingsManager.shared.enableP2PDirectConnection
            ? .automatic
            : .managedRelayOnly
        try await connectToDevice(device, routePreference: preferredRoute)
    }

    /// 连接到指定设备（可指定路由偏好，例如 USB 优先）。
    public func connectToDevice(
        _ device: DiscoveredDevice,
        routePreference: ConnectionRoutePreference
    ) async throws {
        let device = resolveLatestConnectableDevice(from: device)
        let deviceDiagnosticLabel = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(
            device.deviceId ?? device.uniqueIdentifier ?? device.name
        )
        logger.info("尝试连接到设备: \(deviceDiagnosticLabel, privacy: .public)")
        NetworkActivityLogStore.shared.record(
            category: "p2p",
            message: "connect start device=\(deviceDiagnosticLabel) route=\(String(describing: routePreference))"
        )
        let deviceKey = stableConnectionKey(for: device)
        connections[deviceKey]?.cancel()
        connections.removeValue(forKey: deviceKey)
        if let existingAuthenticated = authenticatedConnections.removeValue(forKey: deviceKey) {
            existingAuthenticated.disconnect()
        }

        await repairPeerKEMBootstrapAliasesIfNeeded(for: device)

        let preferUSBRoute = routePreference == .preferUSB
        let disableDirectRoute = routePreference == .managedRelayOnly
        let primaryServiceType = BonjourInteropContract.controlServiceType
        let connectableServiceTypes = P2PDiscoveryBonjourPolicy.normalizedConnectableServiceTypes(from: device.services)
        let preferredServiceType = connectableServiceTypes.contains(primaryServiceType) ? primaryServiceType : connectableServiceTypes.first
        let hasStrongRouteIdentity =
            device.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || device.pubKeyFP?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || P2PDiscoveryBonjourPolicy.isStrongUniqueIdentifier(device.uniqueIdentifier)
        let serviceNameCandidates = P2PDiscoveryBonjourPolicy.resolvedBonjourServiceNameCandidates(for: device)
        let serviceName = serviceNameCandidates.first ?? ""
        logger.info(
            "🧭 连接目标解析: displayName=\(deviceDiagnosticLabel, privacy: .public) bonjourInstance=\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(serviceName), privacy: .public) identifier=\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(device.uniqueIdentifier), privacy: .public)"
        )
        let hasBonjourIdentifier = P2PDiscoveryBonjourPolicy.isBonjourIdentifier(device.uniqueIdentifier)
        let portValue = resolvedPort(
            for: device,
            preferredServiceType: preferredServiceType,
            primaryServiceType: primaryServiceType,
            connectableServiceTypes: connectableServiceTypes
        )
        let hasSkyBridgeControlHint =
            connectableServiceTypes.contains(primaryServiceType)
            || connectableServiceTypes.contains("_skybridge._udp")
            || device.source == .skybridgeBonjour
            || device.source == .skybridgeP2P
        let hasLinkLocalAddress = {
            if let ipv6 = device.ipv6?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               ipv6.hasPrefix("fe80:") {
                return true
            }
            if let ipv4 = device.ipv4?.trimmingCharacters(in: .whitespacesAndNewlines),
               ipv4.hasPrefix("169.254.") {
                return true
            }
            return false
        }()
        let shouldAttemptBonjourService = !serviceNameCandidates.isEmpty
            && serviceNameCandidates.contains(where: { !P2PDiscoveryBonjourPolicy.isLikelyIPAddress($0) })
            && (hasBonjourIdentifier || hasSkyBridgeControlHint || hasLinkLocalAddress || (device.ipv4 == nil && device.ipv6 == nil))

        var serviceTypesToTry: [String] = []
        if let preferredServiceType {
            serviceTypesToTry.append(preferredServiceType)
        }
        if !serviceTypesToTry.contains(primaryServiceType) {
            serviceTypesToTry.append(primaryServiceType)
        }
        if serviceTypesToTry.isEmpty {
            serviceTypesToTry = [primaryServiceType]
        }

        var bonjourEndpointAttempts: [NWEndpoint] = []
        if shouldAttemptBonjourService {
            for candidateServiceName in serviceNameCandidates where !candidateServiceName.isEmpty && !P2PDiscoveryBonjourPolicy.isLikelyIPAddress(candidateServiceName) {
                for serviceType in serviceTypesToTry {
                    bonjourEndpointAttempts.append(
                        .service(
                            name: candidateServiceName,
                            type: serviceType,
                            domain: serviceDomain,
                            interface: nil
                        )
                    )
                }
            }
        }
        let freshBonjourHostFallbackEndpoints = await makeFreshBonjourHostFallbackEndpoints(
            serviceNameCandidates: shouldAttemptBonjourService ? serviceNameCandidates : [],
            serviceTypes: serviceTypesToTry,
            domain: serviceDomain
        )
        let hostFallbackEndpoints = makeHostFallbackEndpoints(device: device, portValue: portValue)

        var endpointAttempts: [NWEndpoint] = []
        if disableDirectRoute {
            endpointAttempts.append(contentsOf: bonjourEndpointAttempts)
        } else if preferUSBRoute {
            endpointAttempts.append(contentsOf: hostFallbackEndpoints)
            endpointAttempts.append(contentsOf: bonjourEndpointAttempts)
        } else if !bonjourEndpointAttempts.isEmpty {
            endpointAttempts.append(contentsOf: bonjourEndpointAttempts)
            endpointAttempts.append(contentsOf: freshBonjourHostFallbackEndpoints)
            endpointAttempts.append(contentsOf: hostFallbackEndpoints)
        } else if hasStrongRouteIdentity, !hostFallbackEndpoints.isEmpty {
            endpointAttempts.append(contentsOf: hostFallbackEndpoints)
        } else {
            endpointAttempts.append(contentsOf: hostFallbackEndpoints)
        }

        if !endpointAttempts.isEmpty {
            var seenEndpointKeys = Set<String>()
            endpointAttempts = endpointAttempts.filter { endpoint in
                let key = endpoint.debugDescription
                if seenEndpointKeys.contains(key) { return false }
                seenEndpointKeys.insert(key)
                return true
            }
        }

        RemoteControlSmokeStatusWriter.append(
            "p2p-connect-plan serviceCandidates=\(serviceNameCandidates.count) serviceEndpoints=\(bonjourEndpointAttempts.count) freshHostEndpoints=\(freshBonjourHostFallbackEndpoints.count) hostFallbackEndpoints=\(hostFallbackEndpoints.count) endpointOrder=\(Self.smokeEndpointPlanSummary(endpointAttempts))"
        )

        // If type metadata is missing but we still have Bonjour identity, probe SkyBridge default service.
        if endpointAttempts.isEmpty, shouldAttemptBonjourService {
            for candidateServiceName in serviceNameCandidates where !candidateServiceName.isEmpty && !P2PDiscoveryBonjourPolicy.isLikelyIPAddress(candidateServiceName) {
                endpointAttempts.append(
                    .service(
                        name: candidateServiceName,
                        type: primaryServiceType,
                        domain: serviceDomain,
                        interface: nil
                    )
                )
            }
        }

        guard !endpointAttempts.isEmpty else {
            NetworkActivityLogStore.shared.record(
                category: "p2p",
                message: "connect failed device=\(deviceDiagnosticLabel) reason=no_connectable_endpoint",
                level: "WARN"
            )
            throw P2PDiscoveryError.noConnectableEndpoint
        }

        try await ensureStrictPQCOutboundPreflightReady(
            for: device,
            endpointAttempts: endpointAttempts,
            preferredServiceType: preferredServiceType
        )

        var lastError: Error?
        for endpoint in endpointAttempts {
            let securityPlans = preferredConnectionSecurityPlans(
                for: endpoint,
                device: device,
                preferredServiceType: preferredServiceType
            )
            let interfacePreferences = interfacePreferences(for: endpoint, preferUSBRoute: preferUSBRoute)
            for interfacePreference in interfacePreferences {
                for plan in securityPlans {
                    do {
                        let endpointDiagnosticLabel = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(endpoint.debugDescription)
                        if case .service(let name, let type, _, _) = endpoint {
                            logger.info("📡 尝试 Bonjour 连接: \(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(name), privacy: .public) [\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(type), privacy: .public)] security=\(plan.rawValue, privacy: .public) route=\(interfacePreference.rawValue, privacy: .public)")
                        } else {
                            logger.info("📡 尝试地址连接: \(endpointDiagnosticLabel, privacy: .public) security=\(plan.rawValue, privacy: .public) route=\(interfacePreference.rawValue, privacy: .public)")
                        }

                        let connection = makeConnection(
                            to: endpoint,
                            securityPlan: plan,
                            interfacePreference: interfacePreference
                        )
                        connections[deviceKey] = connection
                        connectionStatus = .connecting
                        try await waitForConnection(connection, deviceId: deviceKey)

                        if shouldAuthenticateAsSkyBridgeControl(
                            endpoint: endpoint,
                            device: device,
                            preferredServiceType: preferredServiceType
                        ) {
                            logger.info("🔐 传输层已就绪，开始应用层握手认证")
                            let authenticated = try await authenticateConnection(
                                connection,
                                for: device,
                                endpoint: endpoint,
                                fallbackPort: portValue
                            )
                            if let replaced = authenticatedConnections.updateValue(authenticated, forKey: deviceKey),
                               replaced.id != authenticated.id {
                                replaced.disconnect()
                            }
                        } else {
                            if let replaced = authenticatedConnections.removeValue(forKey: deviceKey) {
                                replaced.disconnect()
                            }
                        }

                        logger.info("✅ 成功连接到设备: \(deviceDiagnosticLabel, privacy: .public)")
                        NetworkActivityLogStore.shared.record(
                            category: "p2p",
                            message: "connect success device=\(deviceDiagnosticLabel) endpoint=\(endpointDiagnosticLabel)"
                        )
                        connectionStatus = .connected
                        return
                    } catch {
                        lastError = error
                        logger.warning("⚠️ 连接尝试失败，将回退到下一方案: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)")
                        if let authenticated = authenticatedConnections.removeValue(forKey: deviceKey) {
                            authenticated.disconnect()
                        }
                        connections[deviceKey]?.cancel()
                        connections.removeValue(forKey: deviceKey)
                    }
                }
            }
        }

        connectionStatus = .failed
        NetworkActivityLogStore.shared.record(
            category: "p2p",
            message: "connect failed device=\(deviceDiagnosticLabel) reason=\(lastError.map(SkyBridgeDiagnosticRedaction.errorSummary) ?? "cancelled")",
            level: "WARN"
        )
        throw lastError ?? P2PDiscoveryError.connectionCancelled
    }

    private func shouldAuthenticateAsSkyBridgeControl(
        endpoint: NWEndpoint,
        device: DiscoveredDevice,
        preferredServiceType: String?
    ) -> Bool {
        isSkyBridgeControlEndpoint(endpoint, device: device, preferredServiceType: preferredServiceType)
    }

    private func authenticateConnection(
        _ connection: NWConnection,
        for device: DiscoveredDevice,
        endpoint: NWEndpoint,
        fallbackPort: Int,
        timeoutSeconds: TimeInterval = 12
    ) async throws -> P2PConnection {
        let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
        let requestedPolicy = HandshakePolicy.recommendedDefault(compatibilityModeEnabled: compatibilityModeEnabled)
        let requestedSelection: CryptoProviderFactory.SelectionPolicy = requestedPolicy.requirePQC ? .requirePQC : .preferPQC
        let prefersPQC = await Self.cryptoProviderSupportedSuites(policy: requestedSelection)
            .contains(where: { $0.isPQCGroup })
        let effectiveTimeoutSeconds: TimeInterval
        if requestedPolicy.requirePQC {
            effectiveTimeoutSeconds = max(timeoutSeconds, 90)
        } else if prefersPQC {
            // Compatibility/default mode may still need a classic bootstrap plus a PQC retry.
            effectiveTimeoutSeconds = max(timeoutSeconds, 45)
        } else {
            effectiveTimeoutSeconds = timeoutSeconds
        }

        let p2pDevice = makeP2PDeviceForConnection(
            from: device,
            endpoint: endpoint,
            fallbackPort: fallbackPort
        )
        let authenticatedConnection = P2PConnection(device: p2pDevice, connection: connection)
        authenticatedConnection.startReceivingForHandshake()

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await authenticatedConnection.authenticate()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(effectiveTimeoutSeconds))
                    throw P2PDiscoveryError.timeout
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
            return authenticatedConnection
        } catch {
            authenticatedConnection.disconnect()
            throw error
        }
    }

    private func makeP2PDeviceForConnection(
        from device: DiscoveredDevice,
        endpoint: NWEndpoint,
        fallbackPort: Int
    ) -> P2PDevice {
        let address: String = {
            switch endpoint {
            case .hostPort(let host, _):
                return String(describing: host)
            case .service(let name, _, let domain, _):
                return domain.isEmpty ? "\(name).local." : "\(name).\(domain)"
            default:
                return device.ipv4 ?? device.ipv6 ?? ""
            }
        }()

        let port: UInt16 = {
            switch endpoint {
            case .hostPort(_, let hostPort):
                return hostPort.rawValue
            case .service(_, _, let servicePort, _):
                if let parsed = UInt16(servicePort) { return parsed }
            default:
                break
            }
            if let parsedFallback = UInt16(exactly: fallbackPort), parsedFallback > 0 {
                return parsedFallback
            }
            return 0
        }()

        let persistentDeviceId = device.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesBonjourServiceEndpoint: Bool = {
            if case .service = endpoint { return true }
            return false
        }()
        let resolvedId: String = {
            if let connectionPeerId = P2PDiscoveryBonjourPolicy.connectionPeerIdentifier(
                for: device,
                usesBonjourServiceEndpoint: usesBonjourServiceEndpoint
            ) {
                return connectionPeerId
            }
            return device.id.uuidString
        }()

        let capabilities = Array(Set(device.services)).sorted()
        let endpoints = [endpoint.debugDescription]

        return P2PDevice(
            id: resolvedId,
            name: P2PDiscoveryBonjourPolicy.resolvedBonjourServiceName(for: device),
            type: .macOS,
            address: address,
            port: port,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            capabilities: capabilities,
            publicKey: Data(),
            lastSeen: Date(),
            endpoints: endpoints,
            lastMessageTimestamp: nil,
            isVerified: false,
            verificationFailedReason: device.pubKeyFP == nil ? "等待公钥交换" : nil,
            persistentDeviceId: persistentDeviceId,
            pubKeyFingerprint: device.pubKeyFP,
            macAddresses: device.macSet.isEmpty ? nil : device.macSet
        )
    }

    private func preferredConnectionSecurityPlans(
        for endpoint: NWEndpoint,
        device: DiscoveredDevice,
        preferredServiceType: String?
    ) -> [ConnectionSecurityPlan] {
        // SkyBridge 近距通道使用应用层握手加密（HandshakeDriver + SessionKeys）。
        // 为避免与 iOS 端 length-framed 明文控制通道发生 TLS 记录头错配，这里固定使用 plain TCP。
        if isSkyBridgeControlEndpoint(endpoint, device: device, preferredServiceType: preferredServiceType) {
            return [.plainTCP]
        }

        let net = RemoteDesktopSettingsManager.shared.settings.networkSettings
        guard net.enableEncryption, TLSConfigurator.options(for: net.encryptionAlgorithm) != nil else {
            return [.plainTCP]
        }
        return [.encryptedTLS, .plainTCP]
    }

    private func isSkyBridgeControlEndpoint(
        _ endpoint: NWEndpoint,
        device: DiscoveredDevice,
        preferredServiceType: String?
    ) -> Bool {
        let skybridgeServices = Set(["_skybridge._tcp", "_skybridge._udp"])

        if case .service(_, let type, _, _) = endpoint, skybridgeServices.contains(type) {
            return true
        }
        if let preferredServiceType, skybridgeServices.contains(preferredServiceType) {
            return true
        }
        if device.services.contains(where: { skybridgeServices.contains($0) }) {
            return true
        }
        if device.portMap["_skybridge._tcp"] != nil || device.portMap["_skybridge._udp"] != nil {
            return true
        }
        return false
    }

    private func makeConnection(
        to endpoint: NWEndpoint,
        securityPlan: ConnectionSecurityPlan,
        interfacePreference: InterfacePreference
    ) -> NWConnection {
        let net = RemoteDesktopSettingsManager.shared.settings.networkSettings
        if securityPlan == .encryptedTLS, let tls = TLSConfigurator.options(for: net.encryptionAlgorithm) {
            let tcp = NWProtocolTCP.Options()
            let params = NWParameters(tls: tls, tcp: tcp)
            params.includePeerToPeer = true
            params.allowLocalEndpointReuse = true
            applyInterfacePreference(interfacePreference, to: params)
            if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.enableKeepalive = true
                tcpOptions.keepaliveIdle = 30
                tcpOptions.keepaliveInterval = 15
                tcpOptions.keepaliveCount = 4
                tcpOptions.noDelay = true
            }
            return NWConnection(to: endpoint, using: params)
        }

        if securityPlan == .encryptedTLS {
            logger.warning("⚠️ TLS 配置不可用，降级为纯 TCP")
        }

        let params = NWParameters.tcp
        params.includePeerToPeer = true
        params.allowLocalEndpointReuse = true
        applyInterfacePreference(interfacePreference, to: params)
        if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 30
            tcpOptions.keepaliveInterval = 15
            tcpOptions.keepaliveCount = 4
            tcpOptions.noDelay = true
        }
        return NWConnection(to: endpoint, using: params)
    }

    private func applyInterfacePreference(_ preference: InterfacePreference, to params: NWParameters) {
        guard preference == .wiredEthernetOnly else { return }
        params.requiredInterfaceType = .wiredEthernet
    }

    private func resolvedPort(
        for device: DiscoveredDevice,
        preferredServiceType: String?,
        primaryServiceType: String,
        connectableServiceTypes: [String]
    ) -> Int {
        if let preferredServiceType, let preferredPort = device.portMap[preferredServiceType], preferredPort > 0 {
            return preferredPort
        }
        if let primaryPort = device.portMap[primaryServiceType], primaryPort > 0 {
            return primaryPort
        }
        for serviceType in connectableServiceTypes {
            if let port = device.portMap[serviceType], port > 0 {
                return port
            }
        }
        return 0
    }

    private func makeHostFallbackEndpoints(device: DiscoveredDevice, portValue: Int) -> [NWEndpoint] {
        guard portValue > 0, let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
            return []
        }

        var endpoints: [NWEndpoint] = []

        if let ipv4 = device.ipv4, !ipv4.isEmpty {
            let trimmedIPv4 = ipv4.trimmingCharacters(in: .whitespacesAndNewlines)
            if isLocalIPAddress(trimmedIPv4) {
                logger.debug("忽略本机地址，跳过连接尝试: \(trimmedIPv4)")
            } else if Self.isNonRoutableIPv4Endpoint(trimmedIPv4) {
                logger.debug("忽略不可路由 IPv4，跳过连接尝试: \(trimmedIPv4)")
            } else {
                endpoints.append(.hostPort(host: NWEndpoint.Host(trimmedIPv4), port: port))
            }
        }

        if let ipv6 = device.ipv6, !ipv6.isEmpty {
            let trimmedIPv6 = ipv6.trimmingCharacters(in: .whitespacesAndNewlines)
            if isLocalIPAddress(trimmedIPv6) {
                logger.debug("忽略本机地址，跳过连接尝试: \(trimmedIPv6)")
            } else if trimmedIPv6.lowercased().hasPrefix("fe80:") {
                // IPv6 链路本地地址必须保留 scope id（例如 %en0），否则连接不可达。
                endpoints.append(.hostPort(host: NWEndpoint.Host(trimmedIPv6), port: port))
            } else {
                let normalizedIPv6 = trimmedIPv6.split(separator: "%", maxSplits: 1).first.map(String.init) ?? trimmedIPv6
                endpoints.append(.hostPort(host: NWEndpoint.Host(normalizedIPv6), port: port))
            }
        }

        return endpoints
    }

    private func makeFreshBonjourHostFallbackEndpoints(
        serviceNameCandidates: [String],
        serviceTypes: [String],
        domain: String
    ) async -> [NWEndpoint] {
        let normalizedServiceTypes = P2PDiscoveryBonjourPolicy.normalizedConnectableServiceTypes(
            from: serviceTypes.isEmpty ? [BonjourInteropContract.controlServiceType] : serviceTypes
        )
        guard !serviceNameCandidates.isEmpty, !normalizedServiceTypes.isEmpty else {
            return []
        }

        var endpoints: [NWEndpoint] = []
        var seenEndpointKeys = Set<String>()
        for serviceName in serviceNameCandidates {
            let trimmedName = serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty,
                  !P2PDiscoveryBonjourPolicy.isLikelyIPAddress(trimmedName) else {
                continue
            }

            for serviceType in normalizedServiceTypes {
                guard let resolved = await resolveNetServiceEndpoint(
                    domain: domain,
                    type: serviceType,
                    name: trimmedName,
                    timeoutSeconds: 3.0
                ), resolved.port > 0,
                   let port = NWEndpoint.Port(rawValue: UInt16(resolved.port)) else {
                    RemoteControlSmokeStatusWriter.append(
                        "p2p-bonjour-resolve result=failure service=\(serviceType) name=\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(trimmedName))"
                    )
                    continue
                }

                let beforeCount = endpoints.count
                for host in [resolved.ipv4, resolved.ipv6].compactMap({ $0 }) {
                    let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedHost.isEmpty,
                          !isLocalIPAddress(trimmedHost),
                          !Self.isNonRoutableIPv4Endpoint(trimmedHost) else {
                        continue
                    }

                    let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(trimmedHost), port: port)
                    let key = endpoint.debugDescription
                    if seenEndpointKeys.insert(key).inserted {
                        endpoints.append(endpoint)
                    }
                }
                RemoteControlSmokeStatusWriter.append(
                    "p2p-bonjour-resolve result=success service=\(serviceType) name=\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(trimmedName)) port=\(resolved.port) directEndpoints=\(endpoints.count - beforeCount)"
                )
            }
        }
        return endpoints
    }

    private static func smokeEndpointPlanSummary(_ endpoints: [NWEndpoint]) -> String {
        endpoints.enumerated().map { index, endpoint in
            "\(index):\(smokeEndpointClass(endpoint)):\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(endpoint.debugDescription))"
        }.joined(separator: ",")
    }

    private static func smokeEndpointClass(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .service:
            return "service"
        case .hostPort:
            return "direct-host"
        default:
            return "other"
        }
    }

    private enum StrictPQCOutboundPreflightAction: Equatable {
        case proceed
        case attemptSignedLANRefresh
        case attemptOOBProtocolIdentityBindingThenRefresh
    }

    private struct BootstrapControlExchangeResult {
        let response: AppMessage
        let endpoint: NWEndpoint
        let connectLatencyMs: Double
        let attemptCount: Int
        let failedAttemptCount: Int
    }

    private struct LocalProtocolIdentityProof: Sendable {
        let algorithm: ProtocolSigningAlgorithm
        let publicKey: Data
        let keyHandle: SigningKeyHandle
        let fingerprint: String
    }

    private func ensureStrictPQCOutboundPreflightReady(
        for device: DiscoveredDevice,
        endpointAttempts: [NWEndpoint],
        preferredServiceType: String?
    ) async throws {
        let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
        let policy = HandshakePolicy.recommendedDefault(compatibilityModeEnabled: compatibilityModeEnabled)
        guard policy.requirePQC else { return }
        guard endpointAttempts.contains(where: {
            isSkyBridgeControlEndpoint($0, device: device, preferredServiceType: preferredServiceType)
        }) else {
            return
        }

        let stableTargetCandidates = Self.stableProtocolIdentityCandidates(for: device)
	        guard let targetDeviceId = Self.uniqueStableProtocolIdentityCandidate(from: stableTargetCandidates) else {
	            let reason = "missing stable protocol identity target; refusing endpoint alias target"
	            logger.warning(
	                "⛔️ PIB-1 protocol identity binding failed: peer=\(Self.protocolIdentityLogRedaction, privacy: .public) stage=preflight-identity-binding reason=\(reason, privacy: .public) lifecycle=identity-oob>failed"
	            )
	            throw P2PDiscoveryError.strictPQCTrustPreflightFailed(reason)
	        }

        let candidates = Self.outboundStrictPQCTrustCandidates(for: device, stableTarget: targetDeviceId)
        let preferredTargetSuite = await Self.preferredStrictPQCOutboundTargetSuite()
        let trustProvider = DefaultHandshakeTrustProvider()
        let trustedKEMSuites = await Self.trustedKEMSuites(
            provider: trustProvider,
            candidates: candidates
        )
        var pinnedFingerprints = await Self.trustedProtocolFingerprints(
            provider: trustProvider,
            candidates: candidates
        )
        let signedRefreshEvidence = await PeerKEMBootstrapStore.shared
            .signedRefreshEvidence(forCandidates: candidates)
        let preflightAction = Self.strictPQCOutboundPreflightAction(
            trustedPeerKEMSuites: trustedKEMSuites,
            signedRefreshEvidence: signedRefreshEvidence,
            pinnedProtocolFingerprints: pinnedFingerprints,
            preferredTargetSuite: preferredTargetSuite
        )
        guard preflightAction != .proceed else { return }

        let bootstrapEndpoints = Self.strictPQCBootstrapEndpointCandidates(from: endpointAttempts)
        guard !bootstrapEndpoints.isEmpty else {
            throw P2PDiscoveryError.strictPQCTrustPreflightFailed("missing direct LAN bootstrap endpoint")
        }

        var refreshFailure: Error?
        if preflightAction == .attemptSignedLANRefresh {
            do {
                try await attemptOutboundSignedLANKEMRefresh(
                    for: device,
                    targetDeviceId: targetDeviceId,
                    candidates: candidates,
                    endpoints: bootstrapEndpoints,
                    pinnedProtocolFingerprints: pinnedFingerprints,
                    preferredTargetSuite: preferredTargetSuite
                )
                return
            } catch {
                refreshFailure = error
                guard Self.shouldAttemptOOBProtocolIdentityBinding(afterSKRFailure: error) else {
                    throw error
                }
                let line = "⛔️ SKR-1 signed LAN KEM refresh failed: peer=\(Self.protocolIdentityLogRedaction) stage=preflight-kem-refresh reason=\(Self.protocolIdentityLogRedaction) pinnedProtocolIdentity=1 lifecycle=missing-kem>failed"
                logger.warning("\(line, privacy: .public)")
                RemoteControlSmokeStatusWriter.append(line)
            }
        }

        do {
            let reboundFingerprint = try await attemptOutboundOOBProtocolIdentityBinding(
                for: device,
                targetDeviceId: targetDeviceId,
                candidates: candidates,
                endpoints: bootstrapEndpoints
            )
            pinnedFingerprints = [reboundFingerprint]
            try await attemptOutboundSignedLANKEMRefresh(
                for: device,
                targetDeviceId: targetDeviceId,
                candidates: candidates,
                endpoints: bootstrapEndpoints,
                pinnedProtocolFingerprints: pinnedFingerprints,
                preferredTargetSuite: preferredTargetSuite
            )
        } catch {
            let baseReason = refreshFailure.map { "after SKR failure \($0.localizedDescription); " } ?? ""
            throw P2PDiscoveryError.strictPQCTrustPreflightFailed(baseReason + error.localizedDescription)
        }
    }

    private func attemptOutboundOOBProtocolIdentityBinding(
        for device: DiscoveredDevice,
        targetDeviceId: String,
        candidates: [String],
        endpoints: [NWEndpoint]
    ) async throws -> String {
        let requesterIdentity = try await localProtocolIdentityProofForOutboundPIB()
        let requesterDeviceId = try await localOutboundProtocolIdentityDeviceId()
        let nonce = Self.secureRandomNonce()
        let endpointDigest = Self.bootstrapEndpointDigest(for: device)
        let unsignedRequest = AppMessage.ProtocolIdentityBindingRequestPayload(
            requesterDeviceId: requesterDeviceId,
            targetDeviceId: targetDeviceId,
            requestedProtocolSigningAlgorithms: [
                ProtocolSigningAlgorithm.mlDSA65.rawValue,
                ProtocolSigningAlgorithm.ed25519.rawValue
            ],
            requesterProtocolSigningAlgorithm: requesterIdentity.algorithm.rawValue,
            requesterProtocolIdentityPublicKey: requesterIdentity.publicKey,
            requesterProtocolIdentityFingerprint: requesterIdentity.fingerprint,
            requesterSignature: Data(),
            policyRequirePQC: true,
            policyAllowClassicFallback: false,
            routeScope: "lan",
            bonjourEndpointDigest: endpointDigest,
            nonce: nonce
        )
        let requesterSignatureProvider = ProtocolSignatureProviderSelector.select(for: requesterIdentity.algorithm)
        let requesterSignature = try await requesterSignatureProvider.sign(
            unsignedRequest.canonicalPreimage,
            key: requesterIdentity.keyHandle
        )
        let request = AppMessage.ProtocolIdentityBindingRequestPayload(
            requesterDeviceId: unsignedRequest.requesterDeviceId,
            targetDeviceId: unsignedRequest.targetDeviceId,
            requestedProtocolSigningAlgorithms: unsignedRequest.requestedProtocolSigningAlgorithms,
            requesterProtocolSigningAlgorithm: requesterIdentity.algorithm.rawValue,
            requesterProtocolIdentityPublicKey: requesterIdentity.publicKey,
            requesterProtocolIdentityFingerprint: requesterIdentity.fingerprint,
            requesterSignature: requesterSignature,
            policyRequirePQC: true,
            policyAllowClassicFallback: false,
            routeScope: unsignedRequest.routeScope,
            bonjourEndpointDigest: unsignedRequest.bonjourEndpointDigest,
            nonce: unsignedRequest.nonce,
            sentAt: unsignedRequest.sentAt
        )

        let connectStartLine = "🔐 PIB-1 protocol identity binding connect-start: peer=\(Self.protocolIdentityLogRedaction) endpoints=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>connect"
        logger.info("\(connectStartLine, privacy: .public)")
        RemoteControlSmokeStatusWriter.append(connectStartLine)

        let responseTimeoutSeconds = Self.protocolIdentityBindingResponseTimeoutSeconds()
        let exchange = try await exchangeBootstrapControlMessage(
            .protocolIdentityBindingRequest(request),
            endpoints: endpoints,
            timeoutSeconds: responseTimeoutSeconds
        )
        let requestLine = "🔐 PIB-1 protocol identity binding request: peer=\(Self.protocolIdentityLogRedaction) endpoint=\(Self.protocolIdentityLogRedaction) algorithms=\(request.requestedProtocolSigningAlgorithms.joined(separator: ",")) responseTimeoutSeconds=\(Int(responseTimeoutSeconds)) lifecycle=identity-oob>request"
        logger.info("\(requestLine, privacy: .public)")
        RemoteControlSmokeStatusWriter.append(requestLine)

        if case .kemRefreshFailure(let failure) = exchange.response {
            throw Self.protocolIdentityBindingFailure("remote rejected PIB-1 stage=\(failure.stage) reasonCode=\(failure.reasonCode) reason=\(failure.reason)")
        }
        guard case .signedProtocolIdentityBinding(let payload) = exchange.response else {
            throw Self.protocolIdentityBindingFailure("unexpected PIB-1 response type")
        }

        let validated = try payload.validatedForOOBBinding(request: request)
        guard let algorithm = ProtocolSigningAlgorithm(rawValue: validated.protocolSigningAlgorithm) else {
            throw Self.protocolIdentityBindingFailure("invalid signature algorithm")
        }
        let signatureProvider = ProtocolSignatureProviderSelector.select(for: algorithm)
        let verified = try await signatureProvider.verify(
            validated.signaturePreimage,
            signature: validated.signature,
            publicKey: validated.protocolIdentityPublicKey
        )
        guard verified else {
            throw Self.protocolIdentityBindingFailure("signature verification failed")
        }

        let verifiedLine = "🔐 PIB-1 protocol identity binding signature verified: peer=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) lifecycle=identity-oob>verified"
        logger.info("\(verifiedLine, privacy: .public)")
        RemoteControlSmokeStatusWriter.append(verifiedLine)

        let approvalRequest = PairingTrustApprovalService.Request(
            peerEndpoint: exchange.endpoint.debugDescription,
            declaredDeviceId: validated.deviceId,
            policyBindingKey: PairingTrustApprovalService.policyBindingKey(
                declaredDeviceId: validated.deviceId,
                algorithmRawValue: validated.protocolSigningAlgorithm,
                protocolPublicKeyFingerprint: validated.protocolIdentityFingerprint
            ),
            displayName: validated.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? validated.deviceName!
                : device.name,
            model: device.modelName,
            platform: device.platformName,
            osVersion: device.osVersion,
            kemKeyCount: 0
        )
        let approval = await PairingTrustApprovalService.shared.decide(for: approvalRequest)
        guard approval != .reject else {
            throw Self.protocolIdentityBindingFailure("operator rejected PIB-1 verification code")
        }

        let promoted = try await TrustSyncService.shared.recordAuthenticatedRemoteAuthority(
            deviceId: validated.deviceId,
            displayName: validated.deviceName ?? device.name,
            preferredCurrentDeviceId: targetDeviceId,
            knownDeviceIds: candidates + [validated.deviceId] + validated.aliases,
            protocolSigningAlgorithm: algorithm,
            protocolPublicKeyFingerprint: validated.protocolIdentityFingerprint,
            pinSource: .pib1OperatorApproval
        )
        guard promoted else {
            throw Self.protocolIdentityBindingFailure("authority pin promotion failed")
        }
        await PeerProtocolIdentityBootstrapStore.shared.upsert(
            deviceIds: candidates + [validated.deviceId] + validated.aliases,
            fingerprints: [validated.protocolIdentityFingerprint]
        )

        let pinnedLine = "🔐 PIB-1 protocol identity binding pinned: peer=\(Self.protocolIdentityLogRedaction) deviceId=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) code=\(Self.protocolIdentityLogRedaction) operator=\(approval.rawValue) lifecycle=identity-oob>pinned"
        logger.info("\(pinnedLine, privacy: .public)")
        RemoteControlSmokeStatusWriter.append(pinnedLine)
        return validated.protocolIdentityFingerprint.lowercased()
    }

    private func attemptOutboundSignedLANKEMRefresh(
        for device: DiscoveredDevice,
        targetDeviceId: String,
        candidates: [String],
        endpoints: [NWEndpoint],
        pinnedProtocolFingerprints: Set<String>,
        preferredTargetSuite: CryptoSuite?
    ) async throws {
        let requestedSuites = await Self.signedLANRefreshRequestedSuites(preferredTargetSuite: preferredTargetSuite)
        let requesterDeviceId = try await localOutboundProtocolIdentityDeviceId()
        let requesterProof = try await localProtocolIdentityProofForOutboundPIB()
        let requesterFingerprint = requesterProof.fingerprint
        let request = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: requesterDeviceId,
            targetDeviceId: targetDeviceId,
            requesterProtocolIdentityFingerprint: requesterFingerprint,
            targetProtocolIdentityFingerprint: pinnedProtocolFingerprints.count == 1 ? pinnedProtocolFingerprints.sorted().first : nil,
            requestedSuiteWireIds: requestedSuites.map(\.wireId),
            policyRequirePQC: true,
            policyAllowClassicFallback: false,
            routeScope: "lan",
            bonjourEndpointDigest: Self.bootstrapEndpointDigest(for: device),
            nonce: Self.secureRandomNonce()
        )

        let connectStartLine = "🔐 SKR-1 signed LAN KEM refresh connect-start: peer=\(Self.protocolIdentityLogRedaction) endpointCount=\(endpoints.count) pinnedProtocolIdentity=\(pinnedProtocolFingerprints.isEmpty ? 0 : 1) missingPeerKEM=1 lifecycle=missing-kem>connect"
        logger.info("\(connectStartLine, privacy: .public)")
        RemoteControlSmokeStatusWriter.append(connectStartLine)
        let startedAt = Date()
        let exchange = try await exchangeBootstrapControlMessage(
            .kemRefreshRequest(request),
            endpoints: endpoints,
            timeoutSeconds: 8.0
        )
        let requestLine = "🔐 SKR-1 signed LAN KEM refresh request: peer=\(Self.protocolIdentityLogRedaction) endpoint=\(Self.protocolIdentityLogRedaction) requesterProtocolIdentity=\(Self.protocolIdentityLogRedaction) suites=\(requestedSuites.map(\.rawValue).joined(separator: ",")) suiteWireIds=\(requestedSuites.map { String(format: "0x%04X", $0.wireId) }.joined(separator: ",")) pinnedProtocolIdentity=\(pinnedProtocolFingerprints.isEmpty ? 0 : 1) missingPeerKEM=1 lifecycle=missing-kem>request"
        logger.info("\(requestLine, privacy: .public)")
        RemoteControlSmokeStatusWriter.append(requestLine)

        if case .kemRefreshFailure(let failure) = exchange.response {
            throw Self.signedLANRefreshFailure("remote rejected SKR-1 stage=\(failure.stage) reasonCode=\(failure.reasonCode)")
        }
        guard case .signedKEMRefresh(let payload) = exchange.response else {
            throw Self.signedLANRefreshFailure("unexpected SKR-1 response type")
        }

        let minimumGeneration = await PeerKEMBootstrapStore.shared.maximumKEMGeneration(forCandidates: candidates)
        let validated = try payload.validatedForStrictPQCImport(
            request: request,
            pinnedProtocolFingerprints: pinnedProtocolFingerprints,
            minimumGeneration: minimumGeneration
        )
        try await PeerKEMBootstrapStore.shared.upsertSignedKEMRefresh(
            deviceIds: candidates + [targetDeviceId, validated.deviceId] + validated.aliases,
            payload: validated,
            request: request,
            pinnedProtocolFingerprints: pinnedProtocolFingerprints,
            minimumGeneration: minimumGeneration
        )
        await PeerProtocolIdentityBootstrapStore.shared.upsert(
            deviceIds: candidates + [targetDeviceId, validated.deviceId] + validated.aliases,
            fingerprints: [validated.protocolIdentityFingerprint]
        )
        let importedSuites = validated.kemPublicKeys
            .map { CryptoSuite(wireId: $0.suiteWireId).rawValue }
            .sorted()
            .joined(separator: ",")
        let totalLatencyMs = Date().timeIntervalSince(startedAt) * 1_000.0
	        let verifiedLine = String(
	            format: "🔐 SKR-1 signed LAN KEM refresh verified and imported: peer=%@ suites=%@ wireId=%@ pinnedProtocolIdentity=1 signature=verified requestHash=bound latencyMs=%.1f connectLatencyMs=%.1f retryCount=%d lifecycle=served>verified metricScope=application-control-channel",
	            Self.protocolIdentityLogRedaction,
	            importedSuites,
	            validated.kemPublicKeys.map { String(format: "0x%04X", $0.suiteWireId) }.sorted().joined(separator: ","),
            totalLatencyMs,
            exchange.connectLatencyMs,
            max(0, exchange.attemptCount - 1)
        )
        logger.info("\(verifiedLine, privacy: .public)")
        RemoteControlSmokeStatusWriter.append(verifiedLine)

        let evidence = await PeerKEMBootstrapStore.shared.signedRefreshEvidence(forCandidates: candidates)
        guard Self.signedRefreshEvidenceSatisfiesStrictPQC(evidence, preferredTargetSuite: preferredTargetSuite) else {
            throw Self.signedLANRefreshFailure("SKR-1 completed but strict suite still unsatisfied")
        }
    }

    private func exchangeBootstrapControlMessage(
        _ message: AppMessage,
        endpoints: [NWEndpoint],
        timeoutSeconds: TimeInterval
    ) async throws -> BootstrapControlExchangeResult {
        var lastError: Error?
        var failedAttemptCount = 0
        for (index, endpoint) in endpoints.enumerated() {
            let connection = makeConnection(to: endpoint, securityPlan: .plainTCP, interfacePreference: .automatic)
            let connectStartedAt = Date()
            RemoteControlSmokeStatusWriter.append(
                "bootstrap-control-attempt index=\(index) endpointClass=\(Self.smokeEndpointClass(endpoint)) endpoint=\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(endpoint.debugDescription))"
            )
            do {
                try await waitForBootstrapControlConnection(connection, timeoutSeconds: min(10, max(3, timeoutSeconds)))
                let connectLatencyMs = Date().timeIntervalSince(connectStartedAt) * 1_000.0
                RemoteControlSmokeStatusWriter.append(
                    String(
                        format: "bootstrap-control-ready index=%d endpointClass=%@ connectLatencyMs=%.1f",
                        index,
                        Self.smokeEndpointClass(endpoint),
                        connectLatencyMs
                    )
                )
                try await sendBootstrapFrame(try JSONEncoder().encode(message), over: connection)
                let responseFrame = try await receiveBootstrapFrame(
                    over: connection,
                    timeoutSeconds: timeoutSeconds
                )
                connection.cancel()
                let decoded = try JSONDecoder().decode(
                    AppMessage.self,
                    from: Self.normalizeInboundControlFrame(responseFrame)
                )
                return BootstrapControlExchangeResult(
                    response: decoded,
                    endpoint: endpoint,
                    connectLatencyMs: connectLatencyMs,
                    attemptCount: index + 1,
                    failedAttemptCount: failedAttemptCount
                )
	            } catch {
	                failedAttemptCount += 1
	                lastError = error
	                connection.cancel()
	                logger.warning(
	                    "⚠️ bootstrap control exchange failed endpoint=\(Self.protocolIdentityLogRedaction, privacy: .public) error=\(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
	                )
                RemoteControlSmokeStatusWriter.append(
                    "bootstrap-control-failed index=\(index) endpointClass=\(Self.smokeEndpointClass(endpoint)) error=\(SkyBridgeDiagnosticRedaction.errorSummary(error))"
                )
	            }
        }
        throw lastError ?? P2PDiscoveryError.connectionCancelled
    }

    private func waitForBootstrapControlConnection(
        _ connection: NWConnection,
        timeoutSeconds: TimeInterval
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = WaitForConnectionContext(continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    context.complete(.success(()))
                case .failed(let error):
                    context.complete(.failure(error))
                case .cancelled:
                    context.complete(.failure(P2PDiscoveryError.connectionCancelled))
                default:
                    break
                }
            }
            connection.start(queue: outboundConnectionQueue)
            context.timeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard !Task.isCancelled else { return }
                connection.cancel()
                context.complete(.failure(P2PDiscoveryError.timeout))
            }
        }
    }

    private func sendBootstrapFrame(_ data: Data, over connection: NWConnection) async throws {
        var framed = Data()
        var length = UInt32(data.count).bigEndian
        framed.append(Data(bytes: &length, count: 4))
        framed.append(data)
        try await Self.sendContent(framed, over: connection, timeoutSeconds: 5.0)
    }

    private func receiveBootstrapFrame(
        over connection: NWConnection,
        timeoutSeconds: TimeInterval
    ) async throws -> Data {
        let reader = FramedReader.nwConnection(connection)
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await reader.receiveFrame(maxFrameLength: 1_048_576)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw P2PDiscoveryError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw P2PDiscoveryError.connectionCancelled
            }
            return result
        }
    }

    private func localProtocolIdentityProofForOutboundPIB(
        targetFingerprint: String? = nil
    ) async throws -> LocalProtocolIdentityProof {
        let normalizedTargetFingerprint = Self.normalizedFingerprint(targetFingerprint)
        let keyManager = DeviceIdentityKeyManager.shared
        var lastError: Error?
        for algorithm in [ProtocolSigningAlgorithm.mlDSA65, .ed25519] {
            do {
                let publicKey = try await keyManager.getProtocolSigningPublicKey(for: algorithm)
                let fingerprint = ProtocolIdentityPublicKeys(
                    protocolPublicKey: publicKey,
                    protocolAlgorithm: algorithm
                ).authoritativeFingerprint.lowercased()
                guard normalizedTargetFingerprint == nil || normalizedTargetFingerprint == fingerprint else {
                    continue
                }
                let keyHandle = try await keyManager.getProtocolSigningKeyHandle(for: algorithm)
                return LocalProtocolIdentityProof(
                    algorithm: algorithm,
                    publicKey: publicKey,
                    keyHandle: keyHandle,
                    fingerprint: fingerprint
                )
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw Self.protocolIdentityBindingFailure("missing local protocol identity proof: \(lastError.localizedDescription)")
        }
        throw Self.protocolIdentityBindingFailure("missing local protocol identity proof")
    }

    private func localOutboundProtocolIdentityDeviceId() async throws -> String {
        let raw = await SelfIdentityProvider.shared.protocolIdentityDeviceId(allowCreate: true)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Self.protocolIdentityBindingFailure("local device id unavailable")
        }
        return trimmed
    }

    private nonisolated static func cryptoProviderSupportedSuites(
        policy: CryptoProviderFactory.SelectionPolicy
    ) async -> [CryptoSuite] {
        await Task.detached(priority: .utility) {
            CryptoProviderFactory.make(policy: policy).supportedSuites
        }.value
    }

    private static func preferredStrictPQCOutboundTargetSuite() async -> CryptoSuite? {
        await cryptoProviderSupportedSuites(policy: .requirePQC)
            .first(where: { $0.isPQCGroup })?
            .canonicalKEMSuite
    }

    private static func signedLANRefreshRequestedSuites(preferredTargetSuite: CryptoSuite?) async -> [CryptoSuite] {
        let providerSuites = await cryptoProviderSupportedSuites(policy: .requirePQC)
            .filter(\.isPQCGroup)
            .map(\.canonicalKEMSuite)
        var suites = providerSuites
        if let preferred = preferredTargetSuite?.canonicalKEMSuite, preferred.isKnown, preferred.isPQCGroup {
            suites.insert(preferred, at: 0)
        }
        var seen = Set<UInt16>()
        let unique = suites.filter { suite in
            guard suite.isKnown, suite.isPQCGroup else { return false }
            return seen.insert(suite.wireId).inserted
        }
        return unique.isEmpty ? [.mlkem768MLDSA65] : unique
    }

    private static func strictPQCOutboundPreflightAction(
        trustedPeerKEMSuites: Set<CryptoSuite>,
        signedRefreshEvidence: PeerKEMBootstrapStore.SignedRefreshEvidence?,
        pinnedProtocolFingerprints: Set<String>,
        preferredTargetSuite: CryptoSuite?
    ) -> StrictPQCOutboundPreflightAction {
        let normalizedPins = Set(pinnedProtocolFingerprints.compactMap(normalizedFingerprint))
        guard !normalizedPins.isEmpty else {
            return .attemptOOBProtocolIdentityBindingThenRefresh
        }
        if signedRefreshEvidenceSatisfiesStrictPQC(
            signedRefreshEvidence,
            preferredTargetSuite: preferredTargetSuite
        ) {
            return .proceed
        }
        if signedRefreshEvidence == nil {
            return .attemptOOBProtocolIdentityBindingThenRefresh
        }
        if canSatisfyStrictPQCWithTrustedKEM(
            trustedPeerKEMSuites: trustedPeerKEMSuites,
            preferredTargetSuite: preferredTargetSuite
        ) {
            return .attemptSignedLANRefresh
        }
        return .attemptSignedLANRefresh
    }

    private static func canSatisfyStrictPQCWithTrustedKEM(
        trustedPeerKEMSuites: Set<CryptoSuite>,
        preferredTargetSuite: CryptoSuite?
    ) -> Bool {
        if let preferredTargetSuite {
            return trustedPeerKEMSuites.contains {
                suiteSupportsTargetKEM($0, target: preferredTargetSuite)
            }
        }
        return trustedPeerKEMSuites.contains(where: { $0.isPQCGroup })
    }

    private static func suiteSupportsTargetKEM(_ availableSuite: CryptoSuite, target: CryptoSuite) -> Bool {
        if availableSuite == target { return true }
        if availableSuite.canonicalKEMSuite == target.canonicalKEMSuite { return true }
        if target.isHybrid { return availableSuite.isHybrid }
        if availableSuite.isHybrid { return target.isHybrid }
        return false
    }

    private static func signedRefreshEvidenceSatisfiesStrictPQC(
        _ evidence: PeerKEMBootstrapStore.SignedRefreshEvidence?,
        preferredTargetSuite: CryptoSuite?
    ) -> Bool {
        guard let evidence else { return false }
        let suites = Set(evidence.suiteWireIds.map(CryptoSuite.init(wireId:)))
        return canSatisfyStrictPQCWithTrustedKEM(
            trustedPeerKEMSuites: suites,
            preferredTargetSuite: preferredTargetSuite
        )
    }

    private static func shouldAttemptOOBProtocolIdentityBinding(afterSKRFailure error: Error) -> Bool {
        let reason = error.localizedDescription.lowercased()
        return reason.contains("requester protocol identity fingerprint not pinned")
            || reason.contains("requester_protocol_identity_not_pinned")
            || reason.contains("missing requester protocol identity")
            || reason.contains("pinned protocol identity mismatch")
            || reason.contains("pinned_protocol_identity_mismatch")
            || reason.contains("missing pinned protocol identity")
            || reason.contains("missing_pinned")
    }

    private static func trustedKEMSuites(
        provider: DefaultHandshakeTrustProvider,
        candidates: [String]
    ) async -> Set<CryptoSuite> {
        var suites = Set<CryptoSuite>()
        for candidate in candidates {
            suites.formUnion(await provider.trustedKEMPublicKeys(for: candidate).keys)
        }
        return suites
    }

    private static func trustedProtocolFingerprints(
        provider: DefaultHandshakeTrustProvider,
        candidates: [String]
    ) async -> Set<String> {
        var fingerprints = Set<String>()
        for candidate in candidates {
            fingerprints.formUnion(await provider.trustedFingerprints(for: candidate))
        }
        return Set(fingerprints.compactMap(normalizedFingerprint))
    }

    private static func strictPQCBootstrapEndpointCandidates(from endpointAttempts: [NWEndpoint]) -> [NWEndpoint] {
        let service = endpointAttempts.filter { endpoint in
            if case .service = endpoint { return true }
            return false
        }
        let directRoutable = endpointAttempts.filter { endpoint in
            guard case .hostPort(let host, _) = endpoint else { return false }
            return isRoutableBootstrapHost(String(describing: host))
        }
        let directAny = endpointAttempts.filter { endpoint in
            if case .hostPort = endpoint { return true }
            return false
        }
        var seen = Set<String>()
        return (service + directRoutable + directAny).filter { endpoint in
            let key = endpoint.debugDescription
            return seen.insert(key).inserted
        }
    }

    private static func isRoutableBootstrapHost(_ raw: String) -> Bool {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("[") && value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        if let scope = value.firstIndex(of: "%") {
            value = String(value[..<scope])
        }
        if IPv4Address(value) != nil {
            return !isNonRoutableIPv4Endpoint(value)
        }
        if IPv6Address(value) != nil {
            return value != "::" && value != "::1" && !value.hasPrefix("fe80:") && !value.hasPrefix("ff")
        }
        return true
    }

    private static func outboundStrictPQCTrustCandidates(
        for device: DiscoveredDevice,
        stableTarget: String
    ) -> [String] {
        var ordered = [String]()
        var seen = Set<String>()
        func append(_ raw: String?) {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  seen.insert(trimmed).inserted else {
                return
            }
            ordered.append(trimmed)
        }
        append(stableTarget)
        for candidate in stableProtocolIdentityCandidates(for: device) {
            append(candidate)
        }
        for candidate in P2PDiscoveryKEMAliasRepairPolicy.aliasRepairCandidates(for: device) {
            append(candidate)
        }
        return ordered
    }

    private static func stableProtocolIdentityCandidates(for device: DiscoveredDevice) -> [String] {
        var ordered = [String]()
        var seen = Set<String>()
        func appendStable(_ raw: String?) {
            guard let stable = PeerTrustLookup.persistentDeviceId(from: raw),
                  seen.insert(stable).inserted else {
                return
            }
            ordered.append(stable)
        }
        appendStable(device.deviceId)
        appendStable(device.uniqueIdentifier)
        for routeIdentifier in device.routeIdentifiers {
            appendStable(routeIdentifier)
        }
        return ordered
    }

    private static func uniqueStableProtocolIdentityCandidate(from candidates: [String]) -> String? {
        var stableCandidates = [String]()
        var seen = Set<String>()
        for candidate in candidates {
            guard let stable = PeerTrustLookup.persistentDeviceId(from: candidate),
                  seen.insert(stable).inserted else {
                continue
            }
            stableCandidates.append(stable)
        }
        return stableCandidates.count == 1 ? stableCandidates[0] : nil
    }

    private static func bootstrapEndpointDigest(for device: DiscoveredDevice) -> String? {
        let material = [
            device.uniqueIdentifier,
            device.ipv4,
            device.ipv6,
            device.services.sorted().joined(separator: ","),
            device.portMap.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "|")
        guard !material.isEmpty else { return nil }
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func secureRandomNonce(count: Int = 24) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
            }
        }
        return Data(bytes)
    }

    private static func normalizedFingerprint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }

    nonisolated private static func signedLANRefreshFailure(_ reason: String) -> NSError {
        NSError(
            domain: "SkyBridge.SignedLANRefresh",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }

    nonisolated private static func protocolIdentityBindingFailure(_ reason: String) -> NSError {
        NSError(
            domain: "SkyBridge.ProtocolIdentityBinding",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }

    private static func protocolIdentityBindingResponseTimeoutSeconds() -> Double {
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_PIB_APPROVAL_TIMEOUT_SECONDS"],
              let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 195
        }
        return Double(min(max(value + 15, 45), 315))
    }

    private nonisolated static func isNonRoutableIPv4Endpoint(_ value: String) -> Bool {
        guard IPv4Address(value) != nil else { return false }
        return value.hasPrefix("169.254.")
            || value.hasPrefix("127.")
            || value.hasPrefix("0.")
            || value == "255.255.255.255"
    }

    private func interfacePreferences(
        for endpoint: NWEndpoint,
        preferUSBRoute: Bool
    ) -> [InterfacePreference] {
        guard preferUSBRoute else { return [.automatic] }
        if case .hostPort = endpoint {
            return [.wiredEthernetOnly, .automatic]
        }
        return [.automatic]
    }

    private func stableConnectionKey(for device: DiscoveredDevice) -> String {
        Self.handshakeDeviceIdentifier(for: device)
    }

    static func handshakeDeviceIdentifier(for device: DiscoveredDevice) -> String {
        P2PDiscoveryKEMAliasRepairPolicy.handshakeDeviceIdentifier(for: device)
    }

    private func repairPeerKEMBootstrapAliasesIfNeeded(for device: DiscoveredDevice) async {
        let handshakeId = Self.handshakeDeviceIdentifier(for: device)
        let aliases = Self.kemBootstrapAliasRepairCandidates(for: device)
        guard !handshakeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !aliases.isEmpty else {
            return
        }

        let provider = DefaultHandshakeTrustProvider()
        let directKeys = await provider.trustedKEMPublicKeys(for: handshakeId)
        guard directKeys.isEmpty else { return }

        for alias in aliases where alias != handshakeId {
            let aliasKeys = await provider.trustedKEMPublicKeys(for: alias)
            guard !aliasKeys.isEmpty else { continue }
            let kemKeys = P2PDiscoveryKEMAliasRepairPolicy.kemPublicKeys(from: aliasKeys)
            await PeerKEMBootstrapStore.shared.upsert(
                deviceIds: aliases,
                kemPublicKeys: kemKeys
	            )
	            logger.info(
	                "🔧 已修复 P2P KEM bootstrap 缓存别名: selected=\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(handshakeId), privacy: .public) alias=\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(alias), privacy: .public) keys=\(kemKeys.count)"
	            )
	            return
	        }

        guard let record = Self.uniqueKEMTrustRecordForAliasRepair(
            device: device,
            records: TrustSyncService.shared.activeTrustRecords
        ) else {
            return
        }
        let kemKeys = KEMPublicKeyInfo.normalizedValidKeys(record.kemPublicKeys ?? [])
        guard !kemKeys.isEmpty else { return }

        await PeerKEMBootstrapStore.shared.upsert(
            deviceIds: aliases + PeerTrustLookup.recordLookupCandidates(record),
            kemPublicKeys: kemKeys
	        )
	        logger.info(
	            "🔧 已修复 P2P KEM 信任记录别名: selected=\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(handshakeId), privacy: .public) trust=\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(record.deviceId), privacy: .public) keys=\(kemKeys.count)"
	        )
	    }

    static func kemBootstrapAliasRepairCandidates(for device: DiscoveredDevice) -> [String] {
        P2PDiscoveryKEMAliasRepairPolicy.aliasRepairCandidates(for: device)
    }

    static func uniqueKEMTrustRecordForAliasRepair(
        device: DiscoveredDevice,
        records: [TrustRecord]
    ) -> TrustRecord? {
        P2PDiscoveryKEMAliasRepairPolicy.uniqueTrustRecord(
            for: device,
            records: records
        )
    }

    private func resolveLatestConnectableDevice(from device: DiscoveredDevice) -> DiscoveredDevice {
        let strongIdentity = (deviceId: device.deviceId, pubKeyFP: device.pubKeyFP)
        let routeBoundBonjourIdentifier = P2PDiscoveryBonjourPolicy.preferredRoutableBonjourIdentifier(for: device)
            ?? device.uniqueIdentifier
        guard let matchIndex = findDiscoveredDeviceIndex(
            name: device.name,
            ipv4: device.ipv4,
            ipv6: device.ipv6,
            bonjourIdentifier: routeBoundBonjourIdentifier,
            strongIdentity: strongIdentity
        ) else {
            return device
        }

        var refreshed = discoveredDevices[matchIndex]
        if refreshed.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           let suppliedDeviceId = device.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suppliedDeviceId.isEmpty {
            refreshed.deviceId = suppliedDeviceId
        }
        if refreshed.pubKeyFP?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           let suppliedFingerprint = device.pubKeyFP?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suppliedFingerprint.isEmpty {
            refreshed.pubKeyFP = suppliedFingerprint
        }
        preserveSuppliedConnectableRouteContext(from: device, into: &refreshed)
        if refreshed.id != device.id {
            logger.info(
                "ℹ️ 连接目标已刷新为最新发现快照: \(device.name, privacy: .public) \(device.id.uuidString, privacy: .public) -> \(refreshed.id.uuidString, privacy: .public)"
            )
        }
        return refreshed
    }

    private func preserveSuppliedConnectableRouteContext(
        from supplied: DiscoveredDevice,
        into refreshed: inout DiscoveredDevice
    ) {
        guard Self.hasCompleteProtocolIdentity(
            deviceId: refreshed.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? supplied.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
            pubKeyFP: refreshed.pubKeyFP?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                ?? supplied.pubKeyFP?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ) else {
            return
        }

        let refreshedRoute = P2PDiscoveryBonjourPolicy.preferredRoutableBonjourIdentifier(for: refreshed)
        let suppliedRoute = P2PDiscoveryBonjourPolicy.preferredRoutableBonjourIdentifier(for: supplied)
        if let refreshedRoute,
           let suppliedRoute,
           P2PDiscoveryBonjourPolicy.normalizeIdentifierForMatching(refreshedRoute)
                != P2PDiscoveryBonjourPolicy.normalizeIdentifierForMatching(suppliedRoute) {
            return
        }

        let suppliedIPv4 = refreshed.ipv4?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            ? supplied.ipv4?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let suppliedIPv6 = refreshed.ipv6?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            ? supplied.ipv6?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        refreshed._updateTransient(
            ipv4: suppliedIPv4?.isEmpty == false ? suppliedIPv4 : nil,
            ipv6: suppliedIPv6?.isEmpty == false ? suppliedIPv6 : nil
        )
        for service in supplied.services {
            let normalized = service.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == BonjourInteropContract.controlServiceType || normalized == "_skybridge._udp" else {
                continue
            }
            if !refreshed.services.contains(normalized) {
                refreshed.services.append(normalized)
            }
        }
        for (service, port) in supplied.portMap where port > 0 {
            let normalized = service.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == BonjourInteropContract.controlServiceType || normalized == "_skybridge._udp" else {
                continue
            }
            if (refreshed.portMap[normalized] ?? 0) <= 0 {
                refreshed.portMap[normalized] = port
            }
        }
        refreshed.routeIdentifiers = DiscoveredDevice.mergedRouteIdentifiers(
            refreshed.routeIdentifiers,
            supplied.routeIdentifiers
        )
    }

    private func bonjourIdentifier(from endpoint: NWEndpoint) -> String? {
        guard case .service(let name, _, let domain, _) = endpoint else { return nil }
        let normalizedDomain = domain.isEmpty ? serviceDomain : domain.lowercased()
        return "bonjour:\(name)@\(normalizedDomain)"
    }

 /// 断开与指定设备的连接
    @discardableResult
    public func disconnectFromDevice(_ deviceId: String) -> Bool {
        logger.info("🔌 断开设备连接: \(deviceId)")

        let targetAliases = Set(PeerTrustLookup.lookupCandidates(for: deviceId))
        let directMatches = [deviceId]
        let activeKeys = Set(connections.keys).union(authenticatedConnections.keys)
        let aliasedMatches = activeKeys.filter { candidate in
            let candidateAliases = Set(PeerTrustLookup.lookupCandidates(for: candidate))
            return !candidateAliases.isDisjoint(with: targetAliases)
        }
        let keysToDisconnect = Array(Set(directMatches).union(aliasedMatches))
        let normalizedTargetAliases = Set(targetAliases.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })
        let inboundSessionsToDisconnect = inboundControlSessions.filter { _, session in
            !session.aliases.isDisjoint(with: normalizedTargetAliases)
        }

        guard !keysToDisconnect.isEmpty || !inboundSessionsToDisconnect.isEmpty else {
            logger.info("ℹ️ 未找到匹配的活跃连接: \(deviceId)")
            return false
        }

        for key in keysToDisconnect {
            if let authenticated = authenticatedConnections.removeValue(forKey: key) {
                authenticated.disconnect()
            }
            connections[key]?.cancel()
            connections.removeValue(forKey: key)
        }
        for (sessionId, session) in inboundSessionsToDisconnect {
            inboundControlSessions.removeValue(forKey: sessionId)
            session.connection.cancel()
        }

        if connections.isEmpty && authenticatedConnections.isEmpty && inboundControlSessions.isEmpty && activeInboundSessions == 0 {
            connectionStatus = .disconnected
        }
        return true
    }

 /// 发送数据到指定设备
    public func sendData(_ data: Data, to deviceId: String) async throws {
        guard let connection = connections[deviceId] else {
            throw P2PDiscoveryError.deviceNotConnected
        }

        try await Self.sendContent(data, over: connection, timeoutSeconds: 5.0)
    }

    private nonisolated static func sendContent(
        _ data: Data,
        over connection: NWConnection,
        timeoutSeconds: TimeInterval
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = SendContentContext(continuation: continuation, connection: connection)
            context.timeoutTask = Task { [context] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard !Task.isCancelled else { return }
                context.cancelConnection()
                context.complete(.failure(P2PDiscoveryError.timeout))
            }
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    context.complete(.failure(error))
                } else {
                    context.complete(.success(()))
                }
            })
        }
    }

 // MARK: - Bonjour 广播（本机作为服务端）

 /// 启动广播服务（Bonjour）
    @MainActor public func startAdvertising(forceRebind: Bool = false) {
        logger.info("📡 开始广播服务")

        Task { @MainActor [self] in
            let centerSnapshot = await ServiceAdvertiserCenter.shared.advertisementSnapshot(for: Self.controlServiceType)
            let centerHealthyForP2P = centerSnapshot.isOwned(by: Self.controlAdvertisementOwner)
                && (centerSnapshot.isConnectable || centerSnapshot.isStarting)
            if !forceRebind, centerHealthyForP2P {
                isAdvertising = true
                logger.debug("📡 广播已在运行，忽略重复启动")
                return
            }

            if centerSnapshot.isAdvertising {
                if forceRebind {
                    logger.info("🔁 强制重绑 _skybridge._tcp 广播监听")
                } else if !centerSnapshot.isOwned(by: Self.controlAdvertisementOwner) {
                    logger.warning(
                        "⚠️ 检测到 _skybridge._tcp 被外部组件占用，切换到 P2PDiscoveryService 独占监听: owner=\(centerSnapshot.owner ?? "-", privacy: .public)"
                    )
                } else {
                    logger.warning("⚠️ _skybridge._tcp 广播监听状态不可连接，执行自愈重绑")
                }
                await ServiceAdvertiserCenter.shared.stopAdvertising(Self.controlServiceType)
            } else if isAdvertising {
                logger.warning("⚠️ _skybridge._tcp 广播状态失配：内部标记为运行中，但中央监听器已丢失，执行自愈重绑")
            }

            if let existing = listener {
                existing.cancel()
                listener = nil
            }
            isAdvertising = false

            do {
                let port = try await ServiceAdvertiserCenter.shared.startAdvertising(
                    serviceName: getDeviceName(),
                    serviceType: Self.controlServiceType,
                    owner: Self.controlAdvertisementOwner,
                    includePeerToPeer: false,
                    connectionHandler: { [weak self] connection in
                        Task { @MainActor in self?.handleNewConnection(connection) }
                    },
                    stateHandler: { [weak self] state in
                        Task { @MainActor in self?.handleListenerStateUpdate(state) }
                    }
                )
                isAdvertising = true
                if port > 0 {
                    logger.info("📡 广播服务已启动，端口: \(port)")
                } else {
                    logger.info("📡 广播服务已启动（系统分配端口）")
                }
            } catch {
                logger.error("❌ 启动广播服务失败: \(error.localizedDescription)")
            }
        }
    }

    @MainActor public func ensureAdvertisingHealthy() async {
        let snapshot = await ServiceAdvertiserCenter.shared.advertisementSnapshot(for: Self.controlServiceType)
        let healthyForP2P = snapshot.isOwned(by: Self.controlAdvertisementOwner)
            && (snapshot.isConnectable || snapshot.isStarting)
        if healthyForP2P {
            isAdvertising = true
            return
        }

        logger.warning(
            "⚠️ P2P 广播健康检查失败，准备重绑: state=\(snapshot.state.rawValue, privacy: .public) owner=\(snapshot.owner ?? "-", privacy: .public) port=\(snapshot.port.map(String.init) ?? "-", privacy: .public) internal=\(self.isAdvertising, privacy: .public)"
        )
        startAdvertising(forceRebind: snapshot.isAdvertising || self.isAdvertising)
    }

 /// 停止广播服务
    private func stopAdvertising() {
        logger.info("📡 停止广播服务")
        listener?.cancel()
        listener = nil
        isAdvertising = false
        Task {
            await ServiceAdvertiserCenter.shared.stopAdvertising(
                Self.controlServiceType,
                owner: Self.controlAdvertisementOwner
            )
        }
    }

 // MARK: - Bonjour 浏览结果处理

 /// 处理浏览器状态更新
    private func handleBrowserStateUpdate(_ state: NWBrowser.State, for serviceType: String) {
        switch state {
        case .ready:
            logger.info("🔍 浏览器就绪: \(serviceType)")
        case .failed(let error):
            logger.error("❌ 浏览器失败 [\(serviceType)]: \(error.localizedDescription)")
        case .cancelled:
            logger.info("⏹️ 浏览器已取消: \(serviceType)")
        default:
            break
        }
    }

 /// 处理浏览结果变化 - 增强版：支持多服务类型
    private func handleBrowseResultsChanged(
        results: Set<NWBrowser.Result>,
        changes: Set<NWBrowser.Result.Change>,
        serviceType: String
    ) {
        for change in changes {
            switch change {
            case .added(let result):
                addDiscoveredDeviceAsync(from: result, serviceType: serviceType)
            case .removed(let result):
                removeDiscoveredDevice(from: result, serviceType: serviceType)
            case .changed(old: _, new: let new, flags: _):
                updateDiscoveredDeviceAsync(from: new, serviceType: serviceType)
            case .identical:
                break
            @unknown default:
                break
            }
        }
    }

    /// 从 Bonjour TXT 提取强身份（稳定 deviceId / pubKeyFP）
    private func extractStrongIdentity(from result: NWBrowser.Result) -> (deviceId: String?, pubKeyFP: String?) {
        guard case .bonjour(let txtRecord) = result.metadata else {
            return (nil, nil)
        }
        let dict = BonjourTXTParser.parse(txtRecord)
        let deviceId = sanitizeStableIdentity(
            dict["deviceId"]
                ?? dict["id"]
                ?? dict["deviceID"]
                ?? dict["device_id"]
                ?? dict["uuid"]
                ?? dict["uniqueId"]
                ?? dict["unique_id"]
        )
        let pubKeyFP = sanitizePubKeyFingerprint(
            dict["pubKeyFP"]
                ?? dict["pubkeyfp"]
                ?? dict["pubkeyFP"]
                ?? dict["pub_key_fp"]
                ?? dict["identityFingerprint"]
                ?? dict["fp"]
        )
        return (deviceId, pubKeyFP)
    }

    private func sanitizeStableIdentity(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        guard value.count >= 8 else { return nil }
        return value
    }

    private func sanitizePubKeyFingerprint(_ raw: String?) -> String? {
        BonjourInteropContract.normalizedPubKeyFingerprint(raw)
    }

    private func extractSOAFlag(from result: NWBrowser.Result) -> Bool {
        guard case .bonjour(let txtRecord) = result.metadata else {
            return false
        }
        let dict = BonjourTXTParser.parse(txtRecord)
        return P2PDiscoveryBonjourPolicy.normalizeSOAFlag(dict["hs_soa"] ?? dict["HS_SOA"])
    }

    private func extractNetworkLinkStatus(from result: NWBrowser.Result) -> DeviceNetworkLinkStatus? {
        guard case .bonjour(let txtRecord) = result.metadata else { return nil }
        return BonjourTXTParser.extractNetworkLinkStatus(txtRecord)
    }

    private nonisolated static func connectionTypes(
        from status: DeviceNetworkLinkStatus?,
        defaultTypes: Set<DeviceConnectionType>
    ) -> Set<DeviceConnectionType> {
        guard let status else { return defaultTypes }
        var updated = defaultTypes
        updated.remove(.unknown)
        updated.insert(status.connectionType)
        return updated
    }

    private nonisolated static func signalPercentage(from status: DeviceNetworkLinkStatus?) -> Double? {
        status?.normalizedSignalStrength.map { $0 * 100.0 }
    }

    private func extractAdvertisedServicePort(from result: NWBrowser.Result, serviceType: String) -> Int? {
        guard case .bonjour(let txtRecord) = result.metadata else { return nil }
        let dict = BonjourTXTParser.parse(txtRecord)
        return P2PDiscoveryBonjourPolicy.advertisedServicePort(from: dict, serviceType: serviceType)
    }

    private func findDiscoveredDeviceIndex(
        name: String,
        ipv4: String?,
        ipv6: String?,
        bonjourIdentifier: String?,
        strongIdentity: (deviceId: String?, pubKeyFP: String?)
    ) -> Int? {
        let normalizedDeviceId = strongIdentity.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFingerprint = strongIdentity.pubKeyFP?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasStrongIdentity = normalizedDeviceId?.isEmpty == false || normalizedFingerprint?.isEmpty == false
        let normalizedBonjourIdentifier = P2PDiscoveryBonjourPolicy.normalizeIdentifierForMatching(bonjourIdentifier)
        let normalizedIPv4 = P2PDiscoveryBonjourPolicy.normalizeIPAddressForMatching(ipv4)
        let normalizedIPv6 = P2PDiscoveryBonjourPolicy.normalizeIPAddressForMatching(ipv6)

        if let strongIndex = discoveredDevices.firstIndex(where: { existing in
            if let normalizedDeviceId,
               !normalizedDeviceId.isEmpty,
               let existingId = existing.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
               existingId == normalizedDeviceId {
                return true
            }

            if let normalizedFingerprint,
               !normalizedFingerprint.isEmpty,
               let existingFP = existing.pubKeyFP?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               existingFP == normalizedFingerprint {
                return true
            }
            return false
        }) {
            return strongIndex
        }

        if hasStrongIdentity,
           let normalizedBonjourIdentifier,
           P2PDiscoveryBonjourPolicy.isRoutableBonjourIdentifier(bonjourIdentifier),
           Self.hasCompleteProtocolIdentity(
               deviceId: normalizedDeviceId,
               pubKeyFP: normalizedFingerprint
           ),
           let routedIndex = discoveredDevices.firstIndex(where: { existing in
               Self.discoveredDevice(existing, hasNormalizedBonjourIdentifier: normalizedBonjourIdentifier)
           }) {
            return routedIndex
        }

        guard !hasStrongIdentity else {
            return nil
        }

        if let normalizedBonjourIdentifier,
           P2PDiscoveryBonjourPolicy.isRoutableBonjourIdentifier(bonjourIdentifier) {
            let routeMatchedIndexes = discoveredDevices.indices.filter {
                Self.discoveredDevice(
                    discoveredDevices[$0],
                    hasNormalizedBonjourIdentifier: normalizedBonjourIdentifier
                )
            }
            if let identityBackedIndex = routeMatchedIndexes.first(where: {
                Self.hasCompleteProtocolIdentity(
                    deviceId: discoveredDevices[$0].deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
                    pubKeyFP: discoveredDevices[$0].pubKeyFP?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                )
            }) {
                return identityBackedIndex
            }
            if let routedIndex = routeMatchedIndexes.first {
                return routedIndex
            }
        }

        return discoveredDevices.firstIndex(where: { existing in
            if let normalizedBonjourIdentifier,
               let existingIdentifier = P2PDiscoveryBonjourPolicy.normalizeIdentifierForMatching(existing.uniqueIdentifier),
               existingIdentifier == normalizedBonjourIdentifier {
                return true
            }

            if let normalizedIPv4,
               let existingIPv4 = P2PDiscoveryBonjourPolicy.normalizeIPAddressForMatching(existing.ipv4),
               existingIPv4 == normalizedIPv4 {
                return true
            }

            if let normalizedIPv6,
               let existingIPv6 = P2PDiscoveryBonjourPolicy.normalizeIPAddressForMatching(existing.ipv6),
               existingIPv6 == normalizedIPv6 {
                return true
            }

            return false
        })
    }

    private nonisolated static func hasCompleteProtocolIdentity(
        deviceId: String?,
        pubKeyFP: String?
    ) -> Bool {
        guard let deviceId, !deviceId.isEmpty,
              let pubKeyFP, !pubKeyFP.isEmpty else {
            return false
        }
        return true
    }

    private nonisolated static func discoveredDevice(
        _ device: DiscoveredDevice,
        hasNormalizedBonjourIdentifier normalizedBonjourIdentifier: String
    ) -> Bool {
        for identifier in [device.uniqueIdentifier].compactMap({ $0 }) + device.routeIdentifiers {
            guard P2PDiscoveryBonjourPolicy.isRoutableBonjourIdentifier(identifier),
                  let existingIdentifier = P2PDiscoveryBonjourPolicy.normalizeIdentifierForMatching(identifier),
                  existingIdentifier == normalizedBonjourIdentifier else {
                continue
            }
            return true
        }
        return false
    }

    /// 添加发现的设备 - 增强版：识别设备类型
    private func addDiscoveredDevice(from result: NWBrowser.Result, serviceType: String) {
        let deviceName = extractDeviceName(from: result)
        let networkInfo = extractNetworkInfo(from: result)
        let ipv4 = networkInfo.ipv4
        let ipv6 = networkInfo.ipv6
        let port = networkInfo.port > 0
            ? networkInfo.port
            : (extractAdvertisedServicePort(from: result, serviceType: serviceType) ?? 0)
        let bonjourUniqueIdentifier = bonjourIdentifier(from: result.endpoint)
        let strongIdentity = extractStrongIdentity(from: result)
        let supportsSOA = extractSOAFlag(from: result)
        let networkLinkStatus = extractNetworkLinkStatus(from: result)
        let connectionTypes = Self.connectionTypes(
            from: networkLinkStatus,
            defaultTypes: [.wifi]
        )

 // 根据服务类型推断设备类型（纯 UI 用，不影响连接逻辑）
        var detectedDeviceType = ""
        if serviceType.contains("airplay") {
 // AirPlay 服务通常是 iPhone/iPad/Apple TV
            if !deviceName.lowercased().contains("iphone"),
               !deviceName.lowercased().contains("ipad"),
               !deviceName.lowercased().contains("apple tv") {
                detectedDeviceType = " 📱"
            }
        } else if serviceType.contains("companion-link") {
 // Apple Continuity 设备
            if !deviceName.lowercased().contains("apple") {
                detectedDeviceType = " 🍎"
            }
        }

 // 创建 DiscoveredDevice 实例，使用从 result 中提取的真实网络信息
        let device = DiscoveredDevice(
            id: UUID(),
            name: deviceName + detectedDeviceType,
            ipv4: ipv4,
            ipv6: ipv6,
            services: supportsSOA ? [serviceType, "hs_soa"] : [serviceType],
            portMap: [serviceType: port],
            connectionTypes: connectionTypes,
            uniqueIdentifier: P2PDiscoveryBonjourPolicy.preferredUniqueIdentifier(
                deviceId: strongIdentity.deviceId,
                pubKeyFP: strongIdentity.pubKeyFP,
                bonjourIdentifier: bonjourUniqueIdentifier,
                ipv4: ipv4,
                ipv6: ipv6
            ),
            routeIdentifiers: [bonjourUniqueIdentifier].compactMap { $0 },
            signalStrength: Self.signalPercentage(from: networkLinkStatus),
            networkLinkStatus: networkLinkStatus,
            isLocalDevice: isProbablyLocalDevice(name: deviceName, ipv4: ipv4, ipv6: ipv6),
            deviceId: strongIdentity.deviceId,
            pubKeyFP: strongIdentity.pubKeyFP
        )

 // 检查是否已存在相同的设备；强身份存在时只允许强身份命中。
        if let existingIndex = findDiscoveredDeviceIndex(
            name: deviceName,
            ipv4: ipv4,
            ipv6: ipv6,
            bonjourIdentifier: bonjourUniqueIdentifier,
            strongIdentity: strongIdentity
        ) {
 // 设备已存在，更新服务列表
            var existingDevice = discoveredDevices[existingIndex]
            if !existingDevice.services.contains(serviceType) {
                existingDevice.services.append(serviceType)
                existingDevice.portMap[serviceType] = port
            } else if (existingDevice.portMap[serviceType] ?? 0) <= 0, port > 0 {
                existingDevice.portMap[serviceType] = port
            }
            if supportsSOA, !existingDevice.services.contains("hs_soa") {
                existingDevice.services.append("hs_soa")
            }
            existingDevice.connectionTypes = existingDevice.connectionTypes.union(connectionTypes)
            existingDevice.signalStrength = Self.signalPercentage(from: networkLinkStatus) ?? existingDevice.signalStrength
            existingDevice.networkLinkStatus = networkLinkStatus ?? existingDevice.networkLinkStatus
            if let newDeviceId = strongIdentity.deviceId, !newDeviceId.isEmpty {
                existingDevice.deviceId = newDeviceId
            }
            if let newPubKeyFP = strongIdentity.pubKeyFP, !newPubKeyFP.isEmpty {
                existingDevice.pubKeyFP = newPubKeyFP
            }
            existingDevice.mergeRouteIdentifiers([bonjourUniqueIdentifier].compactMap { $0 })
            if let preferredIdentifier = P2PDiscoveryBonjourPolicy.preferredUniqueIdentifier(
                deviceId: existingDevice.deviceId,
                pubKeyFP: existingDevice.pubKeyFP,
                bonjourIdentifier: bonjourUniqueIdentifier,
                ipv4: existingDevice.ipv4 ?? device.ipv4,
                ipv6: existingDevice.ipv6 ?? device.ipv6
            ) {
                if !P2PDiscoveryBonjourPolicy.isStrongUniqueIdentifier(existingDevice.uniqueIdentifier)
                    || P2PDiscoveryBonjourPolicy.isStrongUniqueIdentifier(preferredIdentifier)
                    || P2PDiscoveryBonjourPolicy.isBonjourIdentifier(preferredIdentifier) {
                    existingDevice.uniqueIdentifier = preferredIdentifier
                }
            }
            discoveredDevices[existingIndex] = existingDevice
            logger.debug("🔄 更新设备服务: \(device.name) - 新增服务: \(serviceType)")
        } else {
 // 新设备，添加到列表
            discoveredDevices.append(device)
            logger.info("✅ 发现[\(serviceType)]: \(device.name) - IPv4: \(ipv4 ?? "无"), IPv6: \(ipv6 ?? "无"), 端口: \(port)")
        }
    }

    private func addDiscoveredDeviceAsync(from result: NWBrowser.Result, serviceType: String) {
        let bonjourUniqueIdentifier = bonjourIdentifier(from: result.endpoint)
        let strongIdentity = extractStrongIdentity(from: result)
        let supportsSOA = extractSOAFlag(from: result)
        let networkLinkStatus = extractNetworkLinkStatus(from: result)
        let connectionTypes = Self.connectionTypes(
            from: networkLinkStatus,
            defaultTypes: [.wifi]
        )
        let advertisedPort = extractAdvertisedServicePort(from: result, serviceType: serviceType) ?? 0
        Task.detached { [
            serviceType,
            bonjourUniqueIdentifier,
            strongIdentity,
            supportsSOA,
            networkLinkStatus,
            connectionTypes,
            advertisedPort
        ] in
            let deviceName = P2P_ExtractDeviceName(result)
            let (ipv4, ipv6) = P2P_ExtractNetworkAddrs(result)
            let port = advertisedPort
            var detectedDeviceType = ""
            if serviceType.contains("airplay") {
                if !deviceName.lowercased().contains("iphone"),
                   !deviceName.lowercased().contains("ipad"),
                   !deviceName.lowercased().contains("apple tv") {
                    detectedDeviceType = " 📱"
                }
            } else if serviceType.contains("companion-link") {
                if !deviceName.lowercased().contains("apple") {
                    detectedDeviceType = " 🍎"
                }
            }
            let device = DiscoveredDevice(
                id: UUID(),
                name: deviceName + detectedDeviceType,
                ipv4: ipv4,
                ipv6: ipv6,
                services: supportsSOA ? [serviceType, "hs_soa"] : [serviceType],
                portMap: [serviceType: port],
                connectionTypes: connectionTypes,
                uniqueIdentifier: P2PDiscoveryBonjourPolicy.preferredUniqueIdentifier(
                    deviceId: strongIdentity.deviceId,
                    pubKeyFP: strongIdentity.pubKeyFP,
                    bonjourIdentifier: bonjourUniqueIdentifier,
                    ipv4: ipv4,
                    ipv6: ipv6
                ),
                routeIdentifiers: [bonjourUniqueIdentifier].compactMap { $0 },
                signalStrength: Self.signalPercentage(from: networkLinkStatus),
                networkLinkStatus: networkLinkStatus,
                deviceId: strongIdentity.deviceId,
                pubKeyFP: strongIdentity.pubKeyFP
            )
            await MainActor.run { [self] in
                if let existingIndex = self.findDiscoveredDeviceIndex(
                    name: deviceName,
                    ipv4: ipv4,
                    ipv6: ipv6,
                    bonjourIdentifier: bonjourUniqueIdentifier,
                    strongIdentity: strongIdentity
                ) {
                    var existing = self.discoveredDevices[existingIndex]
                    if !existing.services.contains(serviceType) {
                        existing.services.append(serviceType)
                        existing.portMap[serviceType] = port
                    } else if (existing.portMap[serviceType] ?? 0) <= 0, port > 0 {
                        existing.portMap[serviceType] = port
                    }
                    if supportsSOA, !existing.services.contains("hs_soa") {
                        existing.services.append("hs_soa")
                    }
                    existing.connectionTypes = existing.connectionTypes.union(connectionTypes)
                    existing.signalStrength = Self.signalPercentage(from: networkLinkStatus) ?? existing.signalStrength
                    existing.networkLinkStatus = networkLinkStatus ?? existing.networkLinkStatus
                    if let newDeviceId = strongIdentity.deviceId, !newDeviceId.isEmpty {
                        existing.deviceId = newDeviceId
                    }
                    if let newPubKeyFP = strongIdentity.pubKeyFP, !newPubKeyFP.isEmpty {
                        existing.pubKeyFP = newPubKeyFP
                    }
                    existing.mergeRouteIdentifiers([bonjourUniqueIdentifier].compactMap { $0 })
                    if let preferredIdentifier = P2PDiscoveryBonjourPolicy.preferredUniqueIdentifier(
                        deviceId: existing.deviceId,
                        pubKeyFP: existing.pubKeyFP,
                        bonjourIdentifier: bonjourUniqueIdentifier,
                        ipv4: existing.ipv4 ?? device.ipv4,
                        ipv6: existing.ipv6 ?? device.ipv6
                    ) {
                        if !P2PDiscoveryBonjourPolicy.isStrongUniqueIdentifier(existing.uniqueIdentifier)
                            || P2PDiscoveryBonjourPolicy.isStrongUniqueIdentifier(preferredIdentifier)
                            || P2PDiscoveryBonjourPolicy.isBonjourIdentifier(preferredIdentifier) {
                            existing.uniqueIdentifier = preferredIdentifier
                        }
                    }
                    self.discoveredDevices[existingIndex] = existing
                    self.logger.debug("🔄 更新设备服务: \(device.name) - 新增服务: \(serviceType)")
                    self.resolveViaNetServiceIfNeeded(result: result, deviceIndex: existingIndex, serviceType: serviceType)
                } else {
                    self.discoveredDevices.append(device)
                    let ipv4Str = ipv4 ?? "无"
                    let ipv6Str = ipv6 ?? "无"
                    self.logger.info("✅ 发现[\(serviceType)]: \(device.name) - IPv4: \(ipv4Str), IPv6: \(ipv6Str), 端口: \(port)")
                    self.resolveViaNetServiceIfNeeded(result: result, deviceIndex: self.discoveredDevices.count - 1, serviceType: serviceType)
                }
            }
        }
    }

 /// 移除设备
    private func removeDiscoveredDevice(from result: NWBrowser.Result, serviceType: String) {
        let deviceName = P2P_ExtractDeviceName(result)
        let (ipv4, ipv6) = P2P_ExtractNetworkAddrs(result)
        let bonjourUniqueIdentifier = bonjourIdentifier(from: result.endpoint)
        let strongIdentity = extractStrongIdentity(from: result)

        guard let existingIndex = findDiscoveredDeviceIndex(
            name: deviceName,
            ipv4: ipv4,
            ipv6: ipv6,
            bonjourIdentifier: bonjourUniqueIdentifier,
            strongIdentity: strongIdentity
        ) else {
            logger.debug("ℹ️ 忽略离线事件：未匹配到设备 [\(serviceType)] name=\(deviceName, privacy: .public)")
            return
        }

        var existing = discoveredDevices[existingIndex]
        existing.services.removeAll { $0 == serviceType }
        existing.portMap.removeValue(forKey: serviceType)

        let remainingTransportServices = existing.services.filter { $0.hasPrefix("_") }
        if remainingTransportServices.isEmpty {
            discoveredDevices.remove(at: existingIndex)
            logger.info("设备已离线: \(existing.name, privacy: .public) [\(serviceType, privacy: .public)]")
            return
        }

        if !remainingTransportServices.contains("_skybridge._tcp") {
            existing.services.removeAll { $0 == "hs_soa" }
        }

        discoveredDevices[existingIndex] = existing
        let remainingServiceSummary = remainingTransportServices.joined(separator: ",")
        logger.info(
            "🧹 设备服务下线: \(existing.name, privacy: .public) - 移除=\(serviceType, privacy: .public), 剩余=\(remainingServiceSummary, privacy: .public)"
        )
    }

 /// 更新设备信息
    private func updateDiscoveredDevice(from result: NWBrowser.Result, serviceType: String) {
        let deviceId = extractDeviceName(from: result)
        if discoveredDevices.firstIndex(where: { $0.name.contains(deviceId) }) != nil {
            let (ipv4, _, _) = extractNetworkInfo(from: result)
            logger.info("🔄 更新[\(serviceType)]: \(deviceId) - IPv4: \(ipv4 ?? "无")")
        }
    }

 // MARK: - 监听器 / 连接状态

 /// 处理监听器状态更新
    private func handleListenerStateUpdate(_ state: NWListener.State) {
        switch state {
        case .ready:
            isAdvertising = true
            logger.info("📡 监听器就绪")
        case .failed(let error):
            isAdvertising = false
            logger.error("❌ 监听器失败: \(error.localizedDescription)")
        case .cancelled:
            isAdvertising = false
            logger.info("⏹️ 监听器已取消")
        default:
            break
        }
    }

 /// 处理新连接（传入 TCP）
    private func handleNewConnection(_ connection: NWConnection) {
        logger.info("🔗 收到新连接")

 // 设置连接状态处理器
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor [weak self, weak connection] in
                guard let connection else { return }
                self?.handleIncomingConnectionStateUpdate(state, connection: connection)
            }
        }

 // 启动连接
        connection.start(queue: .global())
    }

 /// 处理主动发起的连接状态更新
    private func handleConnectionStateUpdate(_ state: NWConnection.State, for deviceId: String) {
        switch state {
        case .ready:
            logger.info("✅ 连接传输层就绪: \(deviceId)")
            if connectionStatus == .disconnected || connectionStatus == .failed {
                connectionStatus = .connecting
            }
        case .failed(let error):
            logger.error("❌ 连接失败: \(deviceId), 错误: \(error.localizedDescription)")
            if let authenticated = authenticatedConnections.removeValue(forKey: deviceId) {
                authenticated.disconnect()
            }
            connections.removeValue(forKey: deviceId)
            connectionStatus = .failed
        case .cancelled:
            logger.info("⏹️ 连接已取消: \(deviceId)")
            if let authenticated = authenticatedConnections.removeValue(forKey: deviceId) {
                authenticated.disconnect()
            }
            connections.removeValue(forKey: deviceId)
            connectionStatus = connections.isEmpty ? .disconnected : connectionStatus
        default:
            break
        }
    }

 /// 处理传入连接状态更新
    private func handleIncomingConnectionStateUpdate(_ state: NWConnection.State, connection: NWConnection) {
        switch state {
        case .ready:
            logger.info("✅ 传入连接就绪")
            connection.stateUpdateHandler = nil
            // 处理传入控制通道（握手/验签/能力协商）
            // 重要：P2PDiscoveryService 是 @MainActor；入站读取/握手必须放到后台，
            // 否则主线程繁忙时会导致对端握手超时并主动断开。
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.handleInboundControlChannel(connection)
            }
        case .failed(let error):
            if case NWError.posix(let posixErr) = error, posixErr == .ECONNREFUSED || posixErr == .EADDRNOTAVAIL {
                logger.debug("传入连接失败(预期探测失败): \(posixErr.rawValue)")
            } else {
                logger.error("❌ 传入连接失败: \(error.localizedDescription)")
            }
            connection.stateUpdateHandler = nil
            connection.cancel()
        case .cancelled:
            connection.stateUpdateHandler = nil
            logger.info("⏹️ 传入连接已取消")
        default:
            break
        }
    }

    private func resolveInboundPeerIdentifier(for endpoint: NWEndpoint) -> String {
        let fallback = Self.fallbackPeerIdentifier(for: endpoint)
        switch endpoint {
        case .hostPort(let host, _):
            let hostText = String(describing: host).lowercased()
            if let match = discoveredDevices.first(where: {
                ($0.ipv4?.lowercased() == hostText) || ($0.ipv6?.lowercased() == hostText)
            }) {
                if let deviceId = match.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines), !deviceId.isEmpty {
                    return "id:\(deviceId)"
                }
                if let unique = match.uniqueIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !unique.isEmpty {
                    return unique
                }
            }
            return fallback
        case .service(let name, _, let domain, _):
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedDomain = (domain.isEmpty ? "local." : domain).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let match = discoveredDevices.first(where: { device in
                let cleaned = device.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return cleaned == normalizedName || cleaned.contains(normalizedName)
            }) {
                if let deviceId = match.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines), !deviceId.isEmpty {
                    return "id:\(deviceId)"
                }
                if let unique = match.uniqueIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !unique.isEmpty {
                    return unique
                }
            }
            return "bonjour:\(normalizedName)@\(normalizedDomain)"
        default:
            return fallback
        }
    }

    private nonisolated static func fallbackPeerIdentifier(for endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .service(let name, _, let domain, _):
            let resolvedDomain = domain.isEmpty ? "local." : domain
            return "bonjour:\(name)@\(resolvedDomain)"
        case .hostPort(let host, _):
            return "host:\(host)"
        default:
            return endpoint.debugDescription
        }
    }

    private nonisolated static func canonicalSOAIdentityString(_ raw: String) -> String {
        var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("id:") {
            normalized.removeFirst(3)
        }
        return normalized
    }

    private nonisolated static func soaPeerIdBytes(from raw: String) -> Data {
        let canonical = canonicalSOAIdentityString(raw)
        return Data(SHA256.hash(data: Data(canonical.utf8)))
    }

    private nonisolated static func localSOAPeerIdBytes() async -> Data {
        if #available(macOS 14.0, iOS 17.0, *) {
            let deviceId = await SelfIdentityProvider.shared.protocolIdentityDeviceId(allowCreate: true)
            if !deviceId.isEmpty {
                return soaPeerIdBytes(from: deviceId)
            }
        }
        return soaPeerIdBytes(from: Host.current().localizedName ?? "mac-local")
    }

    /// 入站控制通道处理（回退 HandshakeDriver，与 iOS 互通）
    nonisolated private func handleInboundControlChannel(_ connection: NWConnection) async {
        let logger = Logger(subsystem: "com.skybridge.Compass", category: "P2PInboundHandshake")
        var didMarkEstablished = false
        var peerIdForPresence = Self.stableEndpointLabel(for: connection.endpoint)
        var declaredDeviceIdForVerification: String?
        let inboundControlSessionId = UUID()
        let classicTransferSessionId = "p2p-discovery-inbound-\(UUID().uuidString.lowercased())"
        defer {
            Task {
                await ClassicTransferSessionRegistry.shared.remove(sessionId: classicTransferSessionId)
            }
            Task { @MainActor [weak self] in
                self?.removeInboundControlSession(id: inboundControlSessionId)
            }
            if didMarkEstablished {
                let disconnectedPeerIds = Self.normalizedClassicTransferSessionAliases([
                    peerIdForPresence,
                    declaredDeviceIdForVerification
                ])
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.activeInboundSessions = max(0, self.activeInboundSessions - 1)
                    for peerId in disconnectedPeerIds {
                        ConnectionPresenceService.shared.markDisconnected(peerId: peerId)
                    }
                    if self.activeInboundSessions == 0, self.connections.isEmpty {
                        self.connectionStatus = .disconnected
                    }
                }
            }
        }

        func waitUntilReady(timeoutSeconds: Double) async -> Bool {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while Date() < deadline {
                if connection.state == .ready { return true }
                if case .failed = connection.state { return false }
                if case .cancelled = connection.state { return false }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return connection.state == .ready
        }

        if connection.state != .ready {
            _ = await waitUntilReady(timeoutSeconds: 3.0)
        }

        struct DirectHandshakeTransport: DiscoveryTransport {
            let connection: NWConnection
            func send(to peer: PeerIdentifier, data: Data) async throws {
                var framed = Data()
                var length = UInt32(data.count).bigEndian
                framed.append(Data(bytes: &length, count: 4))
                framed.append(data)
                try await P2PDiscoveryService.sendContent(framed, over: connection, timeoutSeconds: 5.0)
            }
        }

        let framedReader = FramedReader.nwConnection(connection)

        func sendAck(_ code: UInt8) async throws {
            try await Self.sendContent(Data([code]), over: connection, timeoutSeconds: 5.0)
        }

        func sendFramed(_ data: Data) async throws {
            var framed = Data()
            var length = UInt32(data.count).bigEndian
            framed.append(Data(bytes: &length, count: 4))
            framed.append(data)
            try await Self.sendContent(framed, over: connection, timeoutSeconds: 5.0)
        }

        let transport = DirectHandshakeTransport(connection: connection)
        let resolvedPeerId = await MainActor.run { [weak self] in
            self?.resolveInboundPeerIdentifier(for: connection.endpoint) ?? Self.fallbackPeerIdentifier(for: connection.endpoint)
        }
        let localSOAPeerId = await Self.localSOAPeerIdBytes()
        var expectedRemoteSOAPeerId: Data?
        var inboundPairKey: Data?
        // Protocol-grade gate:
        // Only .established promotes keys to the active business-traffic channel.
        // waitingFinished may derive candidate keys for verification UX, but must not
        // unlock app-message processing or shared connected state.
        var sessionKeys: SessionKeys?
        var previousSessionKeysBeforeRekey: SessionKeys?
        var lastPairingIdentityExchangeReply: PairingIdentityExchangeReplyThrottleState?
        var didSendPostAuthPairingIdentityExchange = false
        var authenticatedRemoteAuthority: AuthenticatedRemoteAuthority?
        var latestPeerFileTransferPort: UInt16?
        defer {
            if let pairKey = inboundPairKey {
                Task {
                    await PeerSessionArbiter.shared.clearEstablished(pairKey: pairKey)
                    await PeerSessionArbiter.shared.clearOutgoing(pairKey: pairKey, attemptId: nil)
                }
            }
        }
        let peer = PeerIdentifier(deviceId: resolvedPeerId)
        var driver: HandshakeDriver?
        peerIdForPresence = peer.deviceId
	        let endpointDescriptionForPresence = Self.stableEndpointLabel(for: connection.endpoint)
	        let endpointHostOrIPForClassicTransfer = Self.endpointHostOrIP(for: connection.endpoint)
	        let peerDiagnosticLabel = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(peer.deviceId)
	        let endpointDiagnosticLabel = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(endpointDescriptionForPresence)
	        var latestPeerCapabilities: [String] = []

        func refreshInboundControlSessionAliases() async {
            await MainActor.run {
                self.upsertInboundControlSession(
                    id: inboundControlSessionId,
                    connection: connection,
                    aliases: [
                        declaredDeviceIdForVerification,
                        peerIdForPresence,
                        peer.deviceId,
                        endpointHostOrIPForClassicTransfer,
                        endpointDescriptionForPresence
                    ]
                )
            }
        }
        await refreshInboundControlSessionAliases()

        func trimmedIdentifier(_ raw: String?) -> String? {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }

        func validatedPairingIdentityPayload(
            _ payload: AppMessage.PairingIdentityExchangePayload
        ) -> AppMessage.PairingIdentityExchangePayload? {
	            guard let normalized = payload.normalizedBootstrapPayload else {
	                logger.warning(
	                    "⚠️ ignoring pairingIdentityExchange with empty declaredDeviceId: peer=\(peerDiagnosticLabel, privacy: .public) endpoint=\(endpointDiagnosticLabel, privacy: .public)"
	                )
	                return nil
	            }
            return normalized
        }

        func isPairingIdentityBoundToAuthenticatedAuthority(
            _ payload: AppMessage.PairingIdentityExchangePayload
        ) -> Bool {
            guard let authority = authenticatedRemoteAuthority else { return false }
            let expectedAlgorithm = authority.protocolSigningAlgorithm.rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            let expectedFingerprint = authority.protocolPublicKeyFingerprint
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !expectedAlgorithm.isEmpty, !expectedFingerprint.isEmpty else {
                return false
            }

            let protocolKeys =
                AppMessage.ProtocolIdentityPublicKeyInfo.normalizedValidKeys(payload.protocolIdentityPublicKeys) ?? []
            return protocolKeys.contains { key in
                key.protocolSigningAlgorithm
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased() == expectedAlgorithm
                    && key.authoritativeFingerprint?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() == expectedFingerprint
            }
        }

        func cryptoKind(for suite: CryptoSuite) -> String {
            ConnectionCryptoPresentation.modeLabel(kind: nil, suite: suite.rawValue) ?? suite.rawValue
        }

        func displayNameFromPeerId(_ peerId: String) -> String? {
            if peerId.hasPrefix("bonjour:") {
                let rest = peerId.dropFirst("bonjour:".count)
                return LocalDevicePresentation.sanitizedDisplayNameCandidate(
                    rest.split(separator: "@", maxSplits: 1).first.map(String.init)
                )
            }
            return LocalDevicePresentation.sanitizedDisplayNameCandidate(peerId)
        }

        func resolvedDisplayName(
            raw: String?,
            model: String?,
            platform: String?,
            fallbackPeerId: String
        ) -> String {
            LocalDevicePresentation.displayDeviceName(
                rawDeviceName: raw ?? displayNameFromPeerId(fallbackPeerId),
                modelName: model,
                platformName: platform ?? ""
            ) ?? "P2P Peer"
        }

        func persistAuthenticatedRemoteAuthority(
            from payload: AppMessage.PairingIdentityExchangePayload,
            displayName: String
        ) async {
            guard let authority = authenticatedRemoteAuthority else {
                logger.warning(
                    "⚠️ inbound pairingIdentityExchange missing authenticated authority; skipping current-path trust bridge: peer=\(Self.protocolIdentityLogRedaction, privacy: .public) declared=\(Self.protocolIdentityLogRedaction, privacy: .public)"
                )
                return
            }

            var knownDeviceIds: [String] = []
            var seenKnownDeviceIds = Set<String>()

            func appendKnownDeviceId(_ raw: String?) {
                guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty,
                      seenKnownDeviceIds.insert(raw).inserted else {
                    return
                }
                knownDeviceIds.append(raw)
            }

            appendKnownDeviceId(payload.deviceId)
            appendKnownDeviceId(peer.deviceId)
            appendKnownDeviceId(peerIdForPresence)

            do {
                let persisted = try await TrustSyncService.shared.recordAuthenticatedRemoteAuthority(
                    deviceId: payload.deviceId,
                    displayName: displayName,
                    preferredCurrentDeviceId: payload.deviceId,
                    knownDeviceIds: knownDeviceIds,
                    protocolSigningAlgorithm: authority.protocolSigningAlgorithm,
                    protocolPublicKeyFingerprint: authority.protocolPublicKeyFingerprint
                )
                guard persisted else {
                    logger.warning(
                        "⚠️ inbound current-path trust bridge skipped: peer=\(Self.protocolIdentityLogRedaction, privacy: .public) declared=\(Self.protocolIdentityLogRedaction, privacy: .public)"
                    )
                    return
                }
                logger.info(
                    "🔐 inbound current-path trust bridge persisted: peer=\(Self.protocolIdentityLogRedaction, privacy: .public) current=\(Self.protocolIdentityLogRedaction, privacy: .public) alg=\(authority.protocolSigningAlgorithm.rawValue, privacy: .public) fp=\(Self.protocolIdentityLogRedaction, privacy: .public)"
                )
            } catch {
                logger.warning(
                    "⚠️ inbound current-path trust bridge failed: \(error.localizedDescription, privacy: .private)"
                )
            }
        }

        func encryptAppPayload(_ plaintext: Data, with keys: SessionKeys) throws -> Data {
            let key = SymmetricKey(data: keys.sendKey)
            let box = try AES.GCM.seal(plaintext, using: key)
            guard let combined = box.combined else {
                throw P2PDiscoveryError.connectionCancelled
            }
            return combined
        }

        func decryptAppPayload(_ ciphertext: Data, with keys: SessionKeys) throws -> Data {
            let key = SymmetricKey(data: keys.receiveKey)
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(box, using: key)
        }

        func isLikelyHandshakeControlPacket(_ data: Data) -> Bool {
            Self.isLikelyHandshakeControlFrame(data)
        }

        func publishInboundPresence(keys: SessionKeys) async -> Bool {
            let suite = keys.negotiatedSuite
            let kind = cryptoKind(for: suite)
            let peerId = trimmedIdentifier(declaredDeviceIdForVerification) ?? peerIdForPresence
            let advertisedTransferPort = latestPeerFileTransferPort.flatMap { port -> Int? in
                let value = Int(port)
                return (1...65535).contains(value) ? value : nil
            }

            return await MainActor.run {
                var resolved = Self.resolveInboundPresenceRoute(
                    peerId: peerId,
                    endpointLabel: endpointDescriptionForPresence,
                    discoveredDevices: self.discoveredDevices,
                    unifiedDevices: UnifiedOnlineDeviceManager.shared.onlineDevices
                )
                resolved.name = resolvedDisplayName(
                    raw: resolved.name,
                    model: nil,
                    platform: nil,
                    fallbackPeerId: peerId
                )

                guard let displayAddress = resolved.displayAddress?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !displayAddress.isEmpty,
                    (1...65535).contains(advertisedTransferPort ?? resolved.transferPort) else {
                    logger.error(
                        "❌ inbound establish route missing: peer=\(SkyBridgeDiagnosticRedaction.stableIdentifierLabel(peerId), privacy: .public) endpoint=\(endpointDiagnosticLabel, privacy: .public)"
                    )
                    return false
                }
                let transferPort = advertisedTransferPort ?? resolved.transferPort

                let routeDescriptor = ConnectionPresenceService.PresenceRouteDescriptor(
                    peerId: peerId,
                    deviceName: resolved.name,
                    displayAddress: displayAddress,
                    transferAddress: displayAddress,
                    transferPort: transferPort,
                    routeSource: .inbound,
                    connectedAt: Date()
                )

                guard ConnectionPresenceService.shared.publishConnectedAtomically(
                    peerId: peerId,
                    displayName: resolved.name,
                    address: displayAddress,
                    cryptoKind: kind,
                    suite: suite.rawValue,
                    routeDescriptor: routeDescriptor
                ) else {
                    logger.error("❌ inbound establish contract incomplete: peer=\(peerId, privacy: .public)")
                    return false
                }

                ConnectionPresenceService.shared.clearRekeying(peerId: peerId)
                UnifiedOnlineDeviceManager.shared.markDeviceAsConnected(
                    peerId: peerId,
                    displayName: resolved.name,
                    cryptoKind: kind,
                    suite: suite.rawValue,
                    guardStatus: "守护中"
                )
                return true
            }
        }

        func normalizedPeerCapabilities(
            capabilities rawCapabilities: [String]?,
            fileTransferPort: UInt16?,
            remoteControlPort: UInt16?
        ) -> [String] {
            var capabilities = rawCapabilities ?? []
            if !capabilities.contains(where: { $0 == ClassicTransferCapability.classicResume }) {
                capabilities.append(ClassicTransferCapability.classicResume)
            }
            if let port = fileTransferPort, port > 0,
               !capabilities.contains(where: {
                   let key = $0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? $0
                   return key
                       .trimmingCharacters(in: .whitespacesAndNewlines)
                       .lowercased()
                       .replacingOccurrences(of: "-", with: "_") == "filetransferport"
               }) {
                capabilities.append("fileTransferPort=\(port)")
            }
            if let port = remoteControlPort, port > 0,
               !capabilities.contains(where: {
                   let key = $0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? $0
                   return key
                       .trimmingCharacters(in: .whitespacesAndNewlines)
                       .lowercased()
                       .replacingOccurrences(of: "-", with: "_") == "remotecontrolport"
               }) {
                capabilities.append("remoteControlPort=\(port)")
            }
            return capabilities
        }

        func normalizedIdentityCapabilities(
            from payload: AppMessage.PairingIdentityExchangePayload
        ) -> [String] {
            normalizedPeerCapabilities(
                capabilities: payload.capabilities,
                fileTransferPort: payload.fileTransferPort,
                remoteControlPort: payload.remoteControlPort
            )
        }

        func recordRemoteControlSecurityIdentity(
            from payload: AppMessage.PairingIdentityExchangePayload
        ) {
            let identity = RemoteControlSecurityIdentity(
                accountDisplayName: payload.accountDisplayName,
                nebulaId: payload.nebulaId,
                deviceId: payload.deviceId,
                deviceName: LocalDevicePresentation.sanitizedDisplayNameCandidate(payload.deviceName)
            )
            guard !identity.isEmpty else { return }
            RemoteControlSecurityPeerIdentityStore.record(
                identity: identity,
                aliases: [
                    payload.deviceId,
                    LocalDevicePresentation.sanitizedDisplayNameCandidate(payload.deviceName),
                    peer.deviceId,
                    peerIdForPresence,
                    endpointHostOrIPForClassicTransfer,
                    endpointDescriptionForPresence
                ].compactMap { $0 }
            )
        }

        func recordRemoteControlSecurityIdentity(
            from payload: AppMessage.HeartbeatPayload
        ) {
            let identity = RemoteControlSecurityIdentity(
                accountDisplayName: payload.accountDisplayName,
                nebulaId: payload.nebulaId,
                deviceId: payload.deviceId,
                deviceName: LocalDevicePresentation.sanitizedDisplayNameCandidate(payload.deviceName)
            )
            guard !identity.isEmpty else { return }
            RemoteControlSecurityPeerIdentityStore.record(
                identity: identity,
                aliases: [
                    payload.deviceId,
                    LocalDevicePresentation.sanitizedDisplayNameCandidate(payload.deviceName),
                    peer.deviceId,
                    peerIdForPresence,
                    endpointHostOrIPForClassicTransfer,
                    endpointDescriptionForPresence
                ].compactMap { $0 }
            )
        }

        func makeLocalPairingIdentityExchangeMessage(
            reason: String
        ) async -> (
            message: AppMessage,
            kemKeyCount: Int,
            localId: String,
            fileTransferPort: UInt16?,
            remoteControlPort: UInt16?
        )? {
            let provider = CryptoProviderFactory.make(policy: .preferPQC)
            let km = DeviceIdentityKeyManager.shared
            let kemKeys: [KEMPublicKeyInfo]
            do {
                kemKeys = KEMPublicKeyInfo.normalizedValidKeys(
                    try await km.pairingIdentityKEMPublicKeys(using: provider)
                )
            } catch {
                logger.warning(
                    "⚠️ 本机 KEM 公钥准备失败（\(reason, privacy: .public)）：\(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                )
                return nil
            }
            guard !kemKeys.isEmpty else {
                logger.warning("⚠️ 跳过 pairingIdentityExchange \(reason, privacy: .public)：本机无有效 KEM 公钥")
                return nil
            }

            let localIdRaw = await SelfIdentityProvider.shared.protocolIdentityDeviceId(allowCreate: true)
            let localId = localIdRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !localId.isEmpty else {
                logger.warning("⚠️ 跳过 pairingIdentityExchange \(reason, privacy: .public)：本机 deviceId 为空")
                return nil
            }

            let endpoints = ServiceEndpointRegistry.shared.snapshot()
            let localIdentity = RemoteControlSecurityNoticeCenter.cachedLocalIdentitySnapshot()
            let localPresentation = LocalDevicePresentation.current()
            let message = AppMessage.pairingIdentityExchange(.init(
                deviceId: localId,
                kemPublicKeys: kemKeys,
                protocolIdentityPublicKeys: await Self.localProtocolIdentityPublicKeysForPairing(),
                deviceName: localPresentation.deviceName,
                modelName: localPresentation.modelName,
                platform: localPresentation.platformName,
                osVersion: localPresentation.osVersion,
                chip: nil,
                accountDisplayName: localIdentity?.accountDisplayName,
                nebulaId: localIdentity?.nebulaId,
                capabilities: ["clipboard_sync", "file_transfer", "remote_desktop", "remote_control"],
                fileTransferPort: endpoints.fileTransferPort,
                remoteControlPort: endpoints.remoteControlPort
            ))
            return (
                message: message,
                kemKeyCount: kemKeys.count,
                localId: localId,
                fileTransferPort: endpoints.fileTransferPort,
                remoteControlPort: endpoints.remoteControlPort
            )
        }

        func sendInboundPostAuthPairingIdentityExchange(keys: SessionKeys) async throws {
            guard !didSendPostAuthPairingIdentityExchange else { return }
            guard let localIdentity = await makeLocalPairingIdentityExchangeMessage(reason: "inbound post-auth") else {
                throw NSError(
                    domain: "SkyBridge.P2PDiscovery",
                    code: 1001,
                    userInfo: [
                        NSLocalizedDescriptionKey: "inbound_post_auth_pairing_identity_unavailable"
                    ]
                )
            }

            let outPlain = try JSONEncoder().encode(localIdentity.message)
            let outCipher = try encryptAppPayload(outPlain, with: keys)
            let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx")
            try await sendFramed(outPadded)
	            didSendPostAuthPairingIdentityExchange = true
	            let localDiagnosticLabel = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(localIdentity.localId)
	            logger.info(
	                "🔑 inbound post-auth pairingIdentityExchange sent: peer=\(peerDiagnosticLabel, privacy: .public) local=\(localDiagnosticLabel, privacy: .public) keys=\(localIdentity.kemKeyCount, privacy: .public) fileTransferPort=\(localIdentity.fileTransferPort.map(String.init) ?? "-", privacy: .public) remoteControlPort=\(localIdentity.remoteControlPort.map(String.init) ?? "-", privacy: .public)"
	            )
	        }

        func refreshInboundRouteFromHeartbeat(
            _ payload: AppMessage.HeartbeatPayload,
            keys: SessionKeys
        ) async {
            if let deviceId = trimmedIdentifier(payload.deviceId) {
                declaredDeviceIdForVerification = deviceId
                await refreshInboundControlSessionAliases()
            }
            latestPeerCapabilities = normalizedPeerCapabilities(
                capabilities: payload.capabilities ?? latestPeerCapabilities,
                fileTransferPort: payload.fileTransferPort ?? latestPeerFileTransferPort,
                remoteControlPort: payload.remoteControlPort
            )
            if let port = payload.fileTransferPort {
                latestPeerFileTransferPort = port
            }
            recordRemoteControlSecurityIdentity(from: payload)

            await publishInboundClassicTransferSession(keys: keys)
	            if await publishInboundPresence(keys: keys) {
	                let routeDiagnosticLabel = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(declaredDeviceIdForVerification ?? peer.deviceId)
	                logger.debug(
	                    "📡 refreshed inbound file-transfer route from heartbeat: peer=\(routeDiagnosticLabel, privacy: .public) fileTransferPort=\(latestPeerFileTransferPort.map(String.init) ?? "-", privacy: .public)"
	                )
	            }
	        }

        func publishInboundClassicTransferSession(keys: SessionKeys) async {
            let declaredPeerId = trimmedIdentifier(declaredDeviceIdForVerification)
            let fallbackPeerId = trimmedIdentifier(peer.deviceId)
                ?? trimmedIdentifier(peerIdForPresence)
                ?? endpointDescriptionForPresence
            let primaryPeerId = declaredPeerId ?? fallbackPeerId
            let resolvedPeerDeviceId = PeerTrustLookup.persistentDeviceId(from: declaredPeerId)
                ?? PeerTrustLookup.persistentDeviceId(from: fallbackPeerId)
                ?? primaryPeerId
            let aliases = Self.normalizedClassicTransferSessionAliases([
                declaredDeviceIdForVerification,
                primaryPeerId,
                peer.deviceId,
                peerIdForPresence,
                endpointHostOrIPForClassicTransfer,
                endpointDescriptionForPresence
            ])
            let snapshot = ClassicTransferSessionSnapshot(
                sessionId: classicTransferSessionId,
                matchDeviceId: primaryPeerId,
                resolvedPeerDeviceId: resolvedPeerDeviceId,
                aliases: aliases,
                endpointHostOrIP: endpointHostOrIPForClassicTransfer,
                capabilities: latestPeerCapabilities,
                sessionKeys: keys
            )
            await ClassicTransferSessionRegistry.shared.upsert(session: snapshot)
        }

        logger.info("🤝 入站连接：启用 HandshakeDriver 兼容通道（iOS 互通） state=\(String(describing: connection.state), privacy: .public)")

        do {
            while true {
                if case .failed = connection.state { break }
                if case .cancelled = connection.state { break }
                let lenData = try await framedReader.receiveExactly(4)
                let totalLen = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
                guard totalLen > 0 && totalLen < 1_048_576 else { break }

                let payload = try await framedReader.receiveExactly(Int(totalLen))
                let frame = Self.normalizeInboundControlFrame(payload)

                if let plaintextControl = try? JSONDecoder().decode(AppMessage.self, from: frame),
                   let controlResponse = await Self.makeBootstrapControlResponse(for: plaintextControl) {
                    let encoded = try JSONEncoder().encode(controlResponse.message)
                    try await sendFramed(encoded)
                    if let binding = controlResponse.protocolIdentityBindingPayload,
                       let code = controlResponse.protocolIdentityBindingCode {
                        await MainActor.run {
                            PairingTrustApprovalService.shared.showProtocolIdentityBindingCode(
                                peerEndpoint: endpointDescriptionForPresence,
                                declaredDeviceId: binding.deviceId,
                                displayName: resolvedDisplayName(
                                    raw: binding.deviceName,
                                    model: nil,
                                    platform: nil,
                                    fallbackPeerId: peer.deviceId
                                ),
                                model: nil,
                                platform: nil,
                                osVersion: nil,
                                verificationCode: code,
                                protocolIdentityFingerprint: binding.protocolIdentityFingerprint
                            )
                        }
                    }
                    if controlResponse.isFailure {
                        logger.error("\(controlResponse.statusLine, privacy: .public)")
                    } else {
                        logger.info("\(controlResponse.statusLine, privacy: .public)")
                    }
                    RemoteControlSmokeStatusWriter.append(controlResponse.statusLine)
                    connection.cancel()
                    return
                }

                if let currentDriver = driver,
                   let messageA = try? HandshakeMessageA.decode(from: frame) {
                    let driverState = await currentDriver.getCurrentState()
                    if Self.shouldRestartInboundHandshakeForRekey(state: driverState, frame: frame) {
                        let fromSuite = sessionKeys?.negotiatedSuite.rawValue ?? "?"
                        let fromKind = sessionKeys.map { cryptoKind(for: $0.negotiatedSuite) } ?? "?"
                        let toSuite = messageA.supportedSuites.first?.rawValue ?? "?"
                        let toKind = messageA.supportedSuites.first.map { cryptoKind(for: $0) } ?? "?"
                        let rekeyPeerId = peerIdForPresence

                        if let inboundPairKey {
                            logger.info("🧩 inbound rekey: releasing SOA established guard peer=\(peerIdForPresence, privacy: .public)")
                            await PeerSessionArbiter.shared.clearEstablished(pairKey: inboundPairKey)
                            await PeerSessionArbiter.shared.clearOutgoing(pairKey: inboundPairKey, attemptId: nil)
                        }

                        Task { @MainActor in
                            ConnectionPresenceService.shared.markRekeying(.init(
                                peerId: rekeyPeerId,
                                fromKind: fromKind,
                                fromSuite: fromSuite,
                                toKind: toKind,
                                toSuite: toSuite
                            ))
                        }
                        logger.info("🔁 入站 rekey：\(fromKind)·\(fromSuite) -> \(toKind)·\(toSuite) peer=\(peerIdForPresence, privacy: .public)")
                        previousSessionKeysBeforeRekey = sessionKeys
                        driver = nil
                        sessionKeys = nil
                    }
                }

                if let keys = sessionKeys, !isLikelyHandshakeControlPacket(frame) {
                    do {
                        let plaintext = try decryptAppPayload(frame, with: keys)
                        if let msg = try? JSONDecoder().decode(AppMessage.self, from: plaintext) {
                            switch msg {
                            case .kemRefreshRequest, .signedKEMRefresh, .kemRefreshFailure,
                                 .protocolIdentityBindingRequest, .signedProtocolIdentityBinding:
                                break
                            case .pairingIdentityExchange(let payload):
                                guard let payload = validatedPairingIdentityPayload(payload) else {
                                    break
                                }
                                recordRemoteControlSecurityIdentity(from: payload)
                                declaredDeviceIdForVerification = payload.deviceId
                                await refreshInboundControlSessionAliases()
                                latestPeerCapabilities = normalizedIdentityCapabilities(from: payload)
                                latestPeerFileTransferPort = payload.fileTransferPort
                                let displayName = resolvedDisplayName(
                                    raw: payload.deviceName,
                                    model: payload.modelName,
                                    platform: payload.platform,
                                    fallbackPeerId: peer.deviceId
                                )

                                await MainActor.run {
                                    PairingTrustApprovalService.shared.updateVerificationCode(
                                        declaredDeviceId: payload.deviceId,
                                        sessionKeys: keys
                                    )
                                }

                                let policyBindingKey = authenticatedRemoteAuthority.flatMap { authority in
                                    PairingTrustApprovalService.policyBindingKey(
                                        declaredDeviceId: payload.deviceId,
                                        algorithmRawValue: authority.protocolSigningAlgorithm.rawValue,
                                        protocolPublicKeyFingerprint: authority.protocolPublicKeyFingerprint
                                    )
                                }
                                let request = PairingTrustApprovalService.Request(
                                    peerEndpoint: endpointDescriptionForPresence,
                                    declaredDeviceId: payload.deviceId,
                                    policyBindingKey: policyBindingKey,
                                    displayName: displayName,
                                    model: payload.modelName,
                                    platform: payload.platform,
                                    osVersion: payload.osVersion,
                                    kemKeyCount: payload.kemPublicKeys.count
                                )

	                                let decision: PairingTrustApprovalService.Decision
	                                let payloadDiagnosticLabel = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(payload.deviceId)
	                                if isPairingIdentityBoundToAuthenticatedAuthority(payload) {
	                                    if let persistedDecision = await PairingTrustApprovalService.shared.persistedPolicyDecision(for: request) {
	                                        decision = persistedDecision
	                                        logger.info(
	                                            "🔐 pairingIdentityExchange resolved by persisted policy on authenticated protocol-identity channel: declared=\(payloadDiagnosticLabel, privacy: .public) decision=\(persistedDecision.rawValue, privacy: .public)"
	                                        )
	                                    } else {
	                                        decision = .allowOnce
	                                        logger.info(
	                                            "🔐 pairingIdentityExchange accepted on authenticated protocol-identity channel: declared=\(payloadDiagnosticLabel, privacy: .public)"
	                                        )
	                                    }
	                                } else {
	                                    decision = await PairingTrustApprovalService.shared.decide(for: request)
	                                }
	                                guard decision != PairingTrustApprovalService.Decision.reject else {
	                                    logger.info("🛑 Pairing/trust request rejected (no KEM reply): deviceId=\(payloadDiagnosticLabel, privacy: .public)")
	                                    break
	                                }

                                await PeerKEMBootstrapStore.shared.upsert(
                                    deviceIds: [payload.deviceId, peer.deviceId],
                                    kemPublicKeys: payload.kemPublicKeys,
                                    platform: payload.platform,
                                    osVersion: payload.osVersion
		                                )
	                                logger.info(
	                                    "🔑 已缓存对端 KEM 公钥（bootstrap）：declared=\(payloadDiagnosticLabel, privacy: .public) peer=\(peerDiagnosticLabel, privacy: .public) keys=\(payload.kemPublicKeys.count, privacy: .public)"
	                                )
	                                await publishInboundClassicTransferSession(keys: keys)
	                                if await publishInboundPresence(keys: keys) {
	                                    logger.info(
	                                        "📡 refreshed inbound file-transfer route from pairing identity: peer=\(payloadDiagnosticLabel, privacy: .public) fileTransferPort=\(payload.fileTransferPort.map(String.init) ?? "-", privacy: .public)"
	                                    )
	                                }

                                guard let localIdentity = await makeLocalPairingIdentityExchangeMessage(reason: "bootstrap reply") else {
                                    break
                                }
                                let outPlain = try JSONEncoder().encode(localIdentity.message)
                                let now = Date()
                                let requestKey = Self.pairingIdentityExchangeRequestKey(payload)
                                if Self.shouldSendPairingIdentityExchangeReply(
                                    lastReply: lastPairingIdentityExchangeReply,
                                    requestKey: requestKey,
                                    requestSentAt: payload.sentAt,
                                    now: now
                                ) {
                                    let outCipher = try encryptAppPayload(outPlain, with: keys)
                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx")
                                    try await sendFramed(outPadded)
                                    lastPairingIdentityExchangeReply = PairingIdentityExchangeReplyThrottleState(
                                        requestKey: requestKey,
                                        requestSentAt: payload.sentAt,
                                        repliedAt: now
                                    )
                                    logger.info("🔑 已回传本机 KEM 公钥：count=\(localIdentity.kemKeyCount, privacy: .public) decision=\(decision.rawValue, privacy: .public)")
                                } else {
                                    logger.debug("ℹ️ pairingIdentityExchange reply rate-limited during bootstrap")
                                }

                                await persistAuthenticatedRemoteAuthority(
                                    from: payload,
                                    displayName: displayName
                                )

                            case .ping(let payload):
                                let reply = AppMessage.pong(.init(id: payload.id))
                                let outPlain = try JSONEncoder().encode(reply)
                                let outCipher = try encryptAppPayload(outPlain, with: keys)
                                let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx")
                                try await sendFramed(outPadded)

                            case .peerDisconnecting(let payload):
                                let disconnectDisplayName = resolvedDisplayName(
                                    raw: payload.deviceName,
                                    model: nil,
                                    platform: nil,
                                    fallbackPeerId: peer.deviceId
                                )
                                let trimmedDisconnectPeerId =
                                    payload.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines)
                                let disconnectPeerId =
                                    (trimmedDisconnectPeerId?.isEmpty == false ? trimmedDisconnectPeerId : nil)
                                    ?? peerIdForPresence
                                let presenceDisconnectPeerIds = Self.normalizedClassicTransferSessionAliases([
                                    peerIdForPresence,
                                    declaredDeviceIdForVerification,
                                    disconnectPeerId
                                ])

                                await MainActor.run {
                                    for peerId in presenceDisconnectPeerIds {
                                        ConnectionPresenceService.shared.markDisconnected(peerId: peerId)
                                    }
                                    UnifiedOnlineDeviceManager.shared.markDeviceAsDisconnected(
                                        peerId: disconnectPeerId,
                                        displayName: disconnectDisplayName
                                    )
                                    if didMarkEstablished {
                                        self.activeInboundSessions = max(0, self.activeInboundSessions - 1)
                                        didMarkEstablished = false
                                    }
                                    if self.activeInboundSessions == 0, self.connections.isEmpty {
                                        self.connectionStatus = .disconnected
                                    }
                                }
                                connection.cancel()
                                return

                            case .heartbeat(let payload):
                                await refreshInboundRouteFromHeartbeat(payload, keys: keys)

                            case .authenticatedRouteBinding:
                                break

                            case .textMessage(let payload):
                                // 设备间文本消息：按发送者稳定公钥指纹归档（此入站会话路径同样可能收到）。
                                let senderDeviceId = declaredDeviceIdForVerification ?? peer.deviceId
                                if let record = await TrustSyncService.shared.getTrustRecord(deviceId: senderDeviceId),
                                   !record.pubKeyFP.isEmpty {
                                    await DeviceMessagingService.shared.handleIncoming(payload, fingerprint: record.pubKeyFP)
                                }

                            case .pong, .clipboard:
                                break
                            }
                        }
                    } catch {
                        logger.debug("ℹ️ 业务消息解密/解析失败（忽略）：\(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)")
                    }
                    continue
                }

                // 延迟初始化：必须先看到 MessageA 才知道对端 offeredSuites 分组，
                // 从而选择本机可用的 (sigAAlgorithm / provider / offeredSuites) 组合。
                if driver == nil {
                    if let messageA = try? HandshakeMessageA.decode(from: frame) {
                        let soaBinding = InboundHandshakeAdapter.bindSOAState(
                            from: messageA,
                            localPeerId: localSOAPeerId
                        )
                        expectedRemoteSOAPeerId = soaBinding.expectedRemotePeerId
                        inboundPairKey = soaBinding.pairKey
                        if soaBinding.usedAuthenticatedInitiator {
                            logger.info("🧩 inboundSOA: binding to MessageA initiatorPeerId (endpointId=\(peerDiagnosticLabel, privacy: .public))")
                        }
                        let peerHasPQCGroup = messageA.supportedSuites.contains { $0.isPQCGroup }
                        let peerHasClassicGroup = messageA.supportedSuites.contains { !$0.isPQCGroup }
                        let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
                        let policy = HandshakePolicy.recommendedDefault(compatibilityModeEnabled: compatibilityModeEnabled)
                        let capability = CryptoProviderFactory.detectCapability()
                        let localPQCAvailable = capability.hasApplePQC || capability.hasLiboqs
                        if let rejection = StrictPQCAdmissionGate.inboundRejection(
                            policy: policy,
                            peerSupportedSuites: messageA.supportedSuites,
                            localPQCSuitesAvailable: localPQCAvailable
                        ), rejection == .peerOfferedClassicOnly {
                            logger.error(
                                "❌ \(rejection.diagnosticMessage, privacy: .public). peer=\(peerDiagnosticLabel, privacy: .public)"
                            )
                            return
                        }

                        // Pick provider first, then derive sigA/offeredSuites from what we can actually support.
                        var selection: CryptoProviderFactory.SelectionPolicy = .classicOnly
                        var cryptoProvider: any CryptoProvider = CryptoProviderFactory.make(policy: .classicOnly)
                        var sigAAlgorithm: ProtocolSigningAlgorithm = .ed25519
                        var offeredSuites: [CryptoSuite] = cryptoProvider.supportedSuites.filter { !$0.isPQCGroup }
                        var effectivePolicy = policy

                        if peerHasPQCGroup {
                            selection = policy.requirePQC ? .requirePQC : .preferPQC
                            cryptoProvider = CryptoProviderFactory.makeInboundPQCResponderProvider(
                                policy: selection,
                                peerSupportedSuites: messageA.supportedSuites
                            )
                            let localPQCSuites = CryptoProviderFactory.handshakeOfferedPQCSuites(using: cryptoProvider)
                            if let rejection = StrictPQCAdmissionGate.inboundRejection(
                                policy: policy,
                                peerSupportedSuites: messageA.supportedSuites,
                                localPQCSuitesAvailable: !localPQCSuites.isEmpty
                            ) {
                                logger.error(
                                    "❌ \(rejection.diagnosticMessage, privacy: .public). peer=\(peerDiagnosticLabel, privacy: .public)"
                                )
                                return
                            }

                            if localPQCSuites.isEmpty {
                                // Best-effort classic fallback only if peer also advertises classic suites.
                                if peerHasClassicGroup {
                                    selection = .classicOnly
                                    cryptoProvider = CryptoProviderFactory.make(policy: selection)
                                    sigAAlgorithm = .ed25519
                                    offeredSuites = cryptoProvider.supportedSuites.filter { !$0.isPQCGroup }
                                    effectivePolicy = HandshakePolicy(
                                        requirePQC: false,
                                        allowClassicFallback: false,
                                        minimumTier: .classic,
                                        requireSecureEnclavePoP: policy.requireSecureEnclavePoP
                                    )
                                    // Make responder-side capability fallback auditable (no silent downgrade in telemetry).
		                                    SecurityEventEmitter.emitDetached(SecurityEvent(
		                                        type: .cryptoDowngrade,
		                                        severity: .warning,
		                                        message: "Inbound handshake: peer advertises PQC but local PQC unavailable; falling back to Classic",
		                                        context: [
		                                            "reason": "pqcProviderUnavailable",
		                                            "direction": "responder_inbound",
		                                            "deviceId": "present_redacted",
		                                            "policyInTranscript": "1",
	                                            "transcriptBinding": "1",
	                                            "downgradeResistance": "policy_gate+no_timeout_fallback+rate_limited",
	                                            "policyRequirePQC": policy.requirePQC ? "1" : "0",
	                                            "policyAllowClassicFallback": policy.allowClassicFallback ? "1" : "0",
	                                            "policyMinimumTier": policy.minimumTier.rawValue,
	                                            "policyRequireSecureEnclavePoP": policy.requireSecureEnclavePoP ? "1" : "0",
	                                            "fromStrategy": HandshakeAttemptStrategy.pqcOnly.rawValue,
	                                            "toStrategy": HandshakeAttemptStrategy.classicOnly.rawValue,
	                                            "strategy": HandshakeAttemptStrategy.classicOnly.rawValue
	                                        ]
	                                    ))
		                                    logger.info("🧩 inboundFallback(classic): peer advertises PQC but local PQC unavailable; falling back to classic handshake. peer=\(peerDiagnosticLabel, privacy: .public)")
		                            } else {
		                                    logger.error("❌ Peer offered PQC-only suites but local PQC unavailable; cannot continue. peer=\(peerDiagnosticLabel, privacy: .public)")
		                                    return
		                                }
                            } else {
                                sigAAlgorithm = .mlDSA65
                                offeredSuites = localPQCSuites
                            }
                        } else {
                            // Peer is classic-only.
                            selection = .classicOnly
                            cryptoProvider = CryptoProviderFactory.make(policy: selection)
                            sigAAlgorithm = .ed25519
                            offeredSuites = cryptoProvider.supportedSuites.filter { !$0.isPQCGroup }
                        }

                        let identityProvider = DeviceIdentityHandshakeProvider(
                            sigAAlgorithm: sigAAlgorithm,
                            includeSecureEnclavePoP: policy.requireSecureEnclavePoP
                        )

                        do {
                            let cryptoPolicy = HandshakeCryptoPolicyResolver.policy(for: offeredSuites)
                            driver = try HandshakeDriver(
                                transport: transport,
                                cryptoProvider: cryptoProvider,
                                protocolSignatureProvider: ProtocolSignatureProviderSelector.select(for: sigAAlgorithm),
                                identityProvider: identityProvider,
                                sigAAlgorithm: sigAAlgorithm,
                                offeredSuites: offeredSuites,
                                policy: effectivePolicy,
                                cryptoPolicy: cryptoPolicy,
                                localSOAPeerId: localSOAPeerId,
                                expectedRemoteSOAPeerId: expectedRemoteSOAPeerId,
                                authenticatedIncomingEstablishedPolicy: effectivePolicy.requirePQC
                                    ? .replaceAuthenticated
                                    : .rejectDuplicate
                            )
                            logger.info("🤝 入站 HandshakeDriver 初始化完成: sigA=\(sigAAlgorithm.rawValue, privacy: .public) provider=\(String(describing: type(of: cryptoProvider)), privacy: .public)")
                        } catch {
                            logger.error("❌ 入站 HandshakeDriver 初始化失败: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)")
                            return
                        }
                    } else {
                        logger.debug("ℹ️ 入站首帧不是 MessageA（忽略，等待下一帧） size=\(frame.count, privacy: .public)")
                        continue
                    }
                }

                guard let activeDriver = driver else { continue }
                await activeDriver.handleMessage(frame, from: peer)
                let st = await activeDriver.getCurrentState()
                logger.debug("🤝 HandshakeDriver state: \(st.diagnosticSummary, privacy: .public)")

                if case .failed(let reason) = st {
                    if let previousKeys = previousSessionKeysBeforeRekey {
                        previousSessionKeysBeforeRekey = nil
                        sessionKeys = previousKeys
                        let restoredPeerId = peerIdForPresence
                        Task { @MainActor in
                            ConnectionPresenceService.shared.clearRekeying(peerId: restoredPeerId)
                            self.connectionStatus = .connected
                        }
                        logger.warning(
                            "⚠️ 入站 rekey 失败，已恢复旧会话: peer=\(peerDiagnosticLabel, privacy: .public) reason=\(reason.diagnosticReasonCode, privacy: .public) suite=\(previousKeys.negotiatedSuite.rawValue, privacy: .public)"
                        )
                        driver = nil
                        continue
                    }

                    logger.warning(
                        "⚠️ 入站握手失败，等待同连接重试: peer=\(peerDiagnosticLabel, privacy: .public) reason=\(reason.diagnosticReasonCode, privacy: .public)"
                    )
                    authenticatedRemoteAuthority = nil
                    driver = nil
                    continue
                }

                switch st {
                case .waitingFinished(_, let keys, _):
                    if let declaredDeviceIdForVerification {
                        await MainActor.run {
                            PairingTrustApprovalService.shared.updateVerificationCode(
                                declaredDeviceId: declaredDeviceIdForVerification,
                                sessionKeys: keys
                            )
                        }
                    }
                case .established(let keys):
                    authenticatedRemoteAuthority = await activeDriver.getAuthenticatedRemoteAuthority()
                    sessionKeys = keys
                    previousSessionKeysBeforeRekey = nil
                    do {
                        try await sendInboundPostAuthPairingIdentityExchange(keys: keys)
                    } catch {
                        logger.error(
                            "❌ inbound post-auth pairingIdentityExchange fail-fast: peer=\(peerDiagnosticLabel, privacy: .public) stage=pairing_identity_exchange reason=\(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                        )
                        connection.cancel()
                        return
                    }
                    if let declaredDeviceIdForVerification {
                        await MainActor.run {
                            PairingTrustApprovalService.shared.updateVerificationCode(
                                declaredDeviceId: declaredDeviceIdForVerification,
                                sessionKeys: keys
                            )
                        }
                    }
                    await publishInboundClassicTransferSession(keys: keys)
                    let published = await publishInboundPresence(keys: keys)
                    if !published {
                        logger.warning(
                            "⚠️ inbound established before route metadata was complete; keeping control session alive while waiting for pairing identity or heartbeat metadata peer=\(peerDiagnosticLabel, privacy: .public)"
                        )
                    }

                    if !didMarkEstablished {
                        didMarkEstablished = true
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.activeInboundSessions += 1
                            self.connectionStatus = .connected
                        }
                    } else {
                        Task { @MainActor [weak self] in
                            self?.connectionStatus = .connected
                        }
                    }
                default:
                    break
                }
            }
        } catch {
            if let framedError = error as? FramedReaderError, framedError == .peerClosed {
                logger.debug("ℹ️ 入站控制通道结束（peer closed）")
            } else {
                logger.debug("ℹ️ 入站控制通道结束: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)")
            }
        }
    }

    private func normalizedHostNameToken(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func stableEndpointLabel(for endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .service(let name, _, let domain, _):
            let resolvedDomain = domain.isEmpty ? "local." : domain.lowercased()
            return "bonjour:\(name)@\(resolvedDomain)"
        case .hostPort(let host, _):
            return "peer:\(normalizePeerHostToken(String(describing: host)))"
        default:
            return "peer:\(normalizePeerHostToken(endpoint.debugDescription))"
        }
    }


    private static func localProtocolIdentityPublicKeysForPairing() async -> [AppMessage.ProtocolIdentityPublicKeyInfo] {
        var keys: [AppMessage.ProtocolIdentityPublicKeyInfo] = []
        for algorithm in [ProtocolSigningAlgorithm.ed25519, .mlDSA65] {
            do {
                let publicKey = try await DeviceIdentityKeyManager.shared.getProtocolSigningPublicKey(for: algorithm)
                keys.append(.init(protocolSigningAlgorithm: algorithm.rawValue, publicKey: publicKey))
            } catch {
                SkyBridgeLogger.p2p.debug(
                    "ℹ️ P2P pairingIdentityExchange reply skipped protocol identity key alg=\(algorithm.rawValue): \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                )
            }
        }
        return AppMessage.ProtocolIdentityPublicKeyInfo.normalizedValidKeys(keys) ?? []
    }

    nonisolated private static func endpointHostOrIP(for endpoint: NWEndpoint) -> String? {
        switch endpoint {
        case .hostPort(let host, _):
            return normalizePeerHostToken(String(describing: host))
        default:
            return nil
        }
    }

    nonisolated private static func normalizedClassicTransferSessionAliases(
        _ candidates: [String?]
    ) -> [String] {
        var normalized: [String] = []
        var seen = Set<String>()

        for raw in candidates {
            guard let raw else { continue }
            for candidate in PeerTrustLookup.lookupCandidates(for: raw) {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let lowered = trimmed.lowercased()
                guard seen.insert(lowered).inserted else { continue }
                normalized.append(trimmed)
            }
        }

        return normalized
    }

    nonisolated private static func normalizePeerHostToken(_ raw: String) -> String {
        P2PPeerHostTokenNormalizer.normalize(raw)
    }

    private func localInterfaceCacheSnapshot(forceRefresh: Bool = false) -> LocalInterfaceCacheEntry {
        if !forceRefresh,
           let cached = localInterfaceCacheEntry,
           Date().timeIntervalSince(cached.updatedAt) < localInterfaceCacheTTL {
            return cached
        }

        var addresses: Set<String> = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            defer { freeifaddrs(ifaddr) }
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee, let sa = interface.ifa_addr else { continue }
                let family = sa.pointee.sa_family
                guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }

                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, socklen_t(0), NI_NUMERICHOST) == 0 else {
                    continue
                }

                let data = Data(bytes: buf, count: buf.count)
                let trimmed = data.prefix { $0 != 0 }
                let ip = String(decoding: trimmed, as: UTF8.self)
                if let normalized = P2PDiscoveryBonjourPolicy.normalizeIPAddressForMatching(ip) {
                    addresses.insert(normalized)
                }
            }
        }

        let snapshot = LocalInterfaceCacheEntry(
            addresses: addresses,
            normalizedHostName: normalizedHostNameToken(Host.current().localizedName ?? ""),
            updatedAt: Date()
        )
        localInterfaceCacheEntry = snapshot
        return snapshot
    }

 /// 判断给定 IPv4 地址是否属于本机，避免自连接导致路径冲突
    private func isLocalIPAddress(_ address: String) -> Bool {
        guard let normalizedAddress = P2PDiscoveryBonjourPolicy.normalizeIPAddressForMatching(address) else { return false }
        return localInterfaceCacheSnapshot().addresses.contains(normalizedAddress)
    }

 /// 判断是否为本机设备（严格匹配）
    private func isProbablyLocalDevice(name: String, ipv4: String?, ipv6: String?) -> Bool {
        let snapshot = localInterfaceCacheSnapshot()

        if let normalizedIPv4 = P2PDiscoveryBonjourPolicy.normalizeIPAddressForMatching(ipv4), snapshot.addresses.contains(normalizedIPv4) {
            return true
        }
        if let normalizedIPv6 = P2PDiscoveryBonjourPolicy.normalizeIPAddressForMatching(ipv6), snapshot.addresses.contains(normalizedIPv6) {
            return true
        }

        let normalizedLocalName = snapshot.normalizedHostName
        guard !normalizedLocalName.isEmpty else { return false }
        return normalizedHostNameToken(name) == normalizedLocalName
    }

    /// 等待连接建立（负责设置 stateUpdateHandler + 启动连接）
    private func waitForConnection(_ connection: NWConnection, deviceId: String, timeoutSeconds: TimeInterval = 10) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = WaitForConnectionContext(continuation: continuation)

            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleConnectionStateUpdate(state, for: deviceId)
                }

                switch state {
                case .ready:
                    context.complete(.success(()))
                case .failed(let error):
                    context.complete(.failure(error))
                case .cancelled:
                    context.complete(.failure(P2PDiscoveryError.connectionCancelled))
                default:
                    break
                }
            }

            connection.start(queue: outboundConnectionQueue)

            context.timeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard !Task.isCancelled else { return }
                connection.cancel()
                context.complete(.failure(P2PDiscoveryError.timeout))
            }
        }
    }

 // MARK: - 辅助方法：名称 / 网络信息解析

 /// 获取本机设备名称
    private func getDeviceName() -> String {
        return Host.current().localizedName ?? "SkyBridge设备"
    }

 /// 从结果中提取设备名称 - 2025 增强版
    private func extractDeviceName(from result: NWBrowser.Result) -> String {
        var deviceName = "未知设备"

        if case .service(let name, _, _, _) = result.endpoint {
 // 使用服务名作为基础
            deviceName = name

 // 尝试从 result.metadata 获取 TXT 记录（使用统一解析器）
            let metadata = result.metadata
            if case .bonjour(let txtRecord) = metadata {
                let deviceInfo = BonjourTXTParser.extractDeviceInfo(txtRecord)
 // 优先使用设备名称
                if let friendlyName = deviceInfo.name ?? deviceInfo.hostname {
                    deviceName = friendlyName
                }

 // 添加设备类型信息
                if let deviceType = deviceInfo.type ?? deviceInfo.model {
                    deviceName += " (\(deviceType))"
                }
            }

 // 清理设备名称
            deviceName = cleanDeviceName(deviceName)

            if isProbablyLocalDevice(name: deviceName, ipv4: nil, ipv6: nil) {
                deviceName += " (本机)"
            }
        }

        logger.info("提取设备名称: \(deviceName)")
        return deviceName
    }

 /// 解析 TXT 记录（已废弃，请使用 BonjourTXTParser）
    @available(*, deprecated, message: "Use BonjourTXTParser.parse instead")
    private func parseTXTRecord(_ txtRecord: NWTXTRecord) -> [String: String]? {
        let dict = BonjourTXTParser.parse(txtRecord)
        return dict.isEmpty ? nil : dict
    }

 /// 清理设备名称
    private func cleanDeviceName(_ name: String) -> String {
        var cleaned = name

        cleaned = cleaned.replacingOccurrences(of: "._tcp", with: "")
        cleaned = cleaned.replacingOccurrences(of: "._udp", with: "")
        cleaned = cleaned.replacingOccurrences(of: ".local", with: "")

        cleaned = cleaned.trimmingCharacters(in: .whitespaces)

        if cleaned.count > 50 {
            cleaned = String(cleaned.prefix(47)) + "..."
        }

        return cleaned
    }

 /// 从 IP 地址反向解析主机名
    private func resolveHostnameFromIP(_ ipAddress: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ipAddress, nil, &hints, &result) == 0 else {
            return nil
        }
        defer { freeaddrinfo(result) }

        guard let resolved = result,
              let addressPtr = resolved.pointee.ai_addr else {
            return nil
        }

        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(addressPtr,
                       socklen_t(resolved.pointee.ai_addrlen),
                       &hostname,
                       socklen_t(hostname.count),
                       nil, 0,
                       NI_NAMEREQD) == 0 {
            let bytes = Data(bytes: hostname, count: hostname.count)
            let trimmed = bytes.prefix { $0 != 0 }
            return String(decoding: trimmed, as: UTF8.self)
        }

        return nil
    }

 /// 从结果中提取网络信息 - 2025 增强版
    private func extractNetworkInfo(from result: NWBrowser.Result) -> (ipv4: String?, ipv6: String?, port: Int) {
        var ipv4: String?
        var ipv6: String?
        var port: Int = 0 // 未知端口，必须依靠服务端点提供

        if case .service(_, _, let servicePort, _) = result.endpoint {
            port = Int(servicePort) ?? 0
        }

 // 方法 1: 使用 NWEndpoint 直接解析（通过 DNS）
        if case .service(let name, let type, _, _) = result.endpoint {
            let host = NWEndpoint.Host(name + "." + type.replacingOccurrences(of: "_", with: "") + ".local")

            if let resolvedAddresses = resolveHost(host) {
                if ipv4 == nil {
                    ipv4 = resolvedAddresses.ipv4
                }
                if ipv6 == nil {
                    ipv6 = resolvedAddresses.ipv6
                }
            }
        }

 // 方法 2: 使用 NetService (兼容性后备)
        if ipv4 == nil && ipv6 == nil {
            if case .service(let name, let type, _, _) = result.endpoint {
                let netService = NetService(domain: "local.", type: type, name: name)
                netService.resolve(withTimeout: 1.0)

                if let addresses = netService.addresses {
                    for addressData in addresses {
                        let address = extractIPAddress(from: addressData)
                        if address.contains("."),
                           !address.starts(with: "169.254"),
                           ipv4 == nil {
                            ipv4 = address
                        } else if address.contains(":"),
                                  ipv6 == nil {
                            ipv6 = address
                        }
                    }
                }
            }
        }

        logger.info("解析设备网络信息 - IPv4: \(ipv4 ?? "无"), IPv6: \(ipv6 ?? "无"), 端口: \(port)")
        return (ipv4, ipv6, port)
    }

 /// 通过接口名称获取 IP 地址
    private func getIPAddressesForInterface(_ interfaceName: String) -> (ipv4: String?, ipv6: String?)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ipv4: String?
        var ipv6: String?
        var ptr = ifaddr

        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }

            guard let interface = ptr?.pointee,
                  let name = decodeOptionalCString(interface.ifa_name),
                  let addressPtr = interface.ifa_addr else { continue }

 // 匹配接口名（Wi-Fi / AWDL 等）
            if name == interfaceName || name.hasPrefix("en") || name.hasPrefix("awdl") {
                let addr = addressPtr.pointee

                if addr.sa_family == UInt8(AF_INET) {
 // IPv4
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        addressPtr,
                        socklen_t(addr.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        socklen_t(0),
                        NI_NUMERICHOST
                    ) == 0 {
                        let data = Data(bytes: hostname, count: hostname.count)
                        let trimmed = data.prefix { $0 != 0 }
                        let address = String(decoding: trimmed, as: UTF8.self)
 // 排除本地链路地址
                        if !address.starts(with: "169.254") && !address.starts(with: "127.") {
                            ipv4 = address
                        }
                    }
                } else if addr.sa_family == UInt8(AF_INET6) {
 // IPv6
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        interface.ifa_addr,
                        socklen_t(addr.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        socklen_t(0),
                        NI_NUMERICHOST
                    ) == 0 {
                        let data = Data(bytes: hostname, count: hostname.count)
                        let trimmed = data.prefix { $0 != 0 }
                        let address = String(decoding: trimmed, as: UTF8.self)
 // 排除链路本地地址
                        if !address.starts(with: "fe80:") {
                            ipv6 = address
                        }
                    }
                }
            }
        }

        if ipv4 != nil || ipv6 != nil {
            return (ipv4, ipv6)
        }
        return nil
    }

 /// 解析主机名为 IP 地址
    private func resolveHost(_ host: NWEndpoint.Host) -> (ipv4: String?, ipv6: String?)? {
        var ipv4: String?
        var ipv6: String?

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC  // IPv4 或 IPv6
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        let hostString = "\(host)"

        guard getaddrinfo(hostString, nil, &hints, &result) == 0 else {
            return nil
        }
        defer { freeaddrinfo(result) }

        var ptr = result
        while ptr != nil {
            defer { ptr = ptr?.pointee.ai_next }

            guard let addr = ptr?.pointee,
                  let addressPtr = addr.ai_addr else { continue }

            if addr.ai_family == AF_INET {
 // IPv4
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    addressPtr,
                    socklen_t(addr.ai_addrlen),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    let bytes4 = Data(bytes: hostname, count: hostname.count)
                    let trimmed4 = bytes4.prefix { $0 != 0 }
                    ipv4 = String(decoding: trimmed4, as: UTF8.self)
                }
            } else if addr.ai_family == AF_INET6 {
 // IPv6
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    addressPtr,
                    socklen_t(addr.ai_addrlen),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    let bytes6 = Data(bytes: hostname, count: hostname.count)
                    let trimmed6 = bytes6.prefix { $0 != 0 }
                    ipv6 = String(decoding: trimmed6, as: UTF8.self)
                }
            }
        }

        if ipv4 != nil || ipv6 != nil {
            return (ipv4, ipv6)
        }
        return nil
    }

 /// 从地址数据中提取 IP 地址字符串
    private func extractIPAddress(from data: Data) -> String {
        return data.withUnsafeBytes { bytes in
            guard bytes.count >= MemoryLayout<sockaddr>.size,
                  let sockaddr = bytes.bindMemory(to: sockaddr.self).baseAddress else {
                return "未知地址"
            }

            switch Int32(sockaddr.pointee.sa_family) {
            case AF_INET:
                guard bytes.count >= MemoryLayout<sockaddr_in>.size,
                      let addr = bytes.bindMemory(to: sockaddr_in.self).baseAddress,
                      let cstr = inet_ntoa(addr.pointee.sin_addr) else {
                    return "未知地址"
                }
                return String(cString: cstr)

            case AF_INET6:
                guard bytes.count >= MemoryLayout<sockaddr_in6>.size,
                      let addr = bytes.bindMemory(to: sockaddr_in6.self).baseAddress else {
                    return "未知地址"
                }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                var sin6_addr = addr.pointee.sin6_addr
                guard inet_ntop(AF_INET6, &sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                    return "未知地址"
                }
                let data = Data(bytes: buffer, count: Int(INET6_ADDRSTRLEN))
                let trimmed = data.prefix { $0 != 0 }
                return String(decoding: trimmed, as: UTF8.self)

            default:
                return "未知地址"
            }
        }
    }

    private func resolveNetServiceEndpoint(
        domain: String,
        type: String,
        name: String,
        timeoutSeconds: TimeInterval
    ) async -> NetServiceResolvedEndpoint? {
        let resolved: NetServiceResolvedEndpoint? = await netServiceResolveLimiter.withPermit {
            try? await Self.resolveNetServiceEndpointOnMain(
                domain: domain,
                type: type,
                name: name,
                timeoutSeconds: timeoutSeconds
            )
        }

        if resolved == nil {
            logger.debug("ℹ️ NetService 解析失败: name=\(name, privacy: .public) type=\(type, privacy: .public)")
        }
        return resolved
    }

    @MainActor
    private static func resolveNetServiceEndpointOnMain(
        domain: String,
        type: String,
        name: String,
        timeoutSeconds: TimeInterval
    ) async throws -> NetServiceResolvedEndpoint {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NetServiceResolvedEndpoint, Error>) in
            let service = NetService(
                domain: domain.isEmpty ? "local." : domain,
                type: type,
                name: name
            )
            let context = NetServiceResolveContext(
                service: service,
                timeoutSeconds: timeoutSeconds,
                continuation: continuation
            )
            context.start()
        }
    }

    private func resolveViaNetServiceIfNeeded(result: NWBrowser.Result, deviceIndex: Int, serviceType: String) {
        guard deviceIndex >= 0 && deviceIndex < discoveredDevices.count else { return }
        let d = discoveredDevices[deviceIndex]
        let hasPort = (d.portMap[serviceType] ?? 0) > 0
        let hasAddr = (d.ipv4 != nil) || (d.ipv6 != nil)
        guard !hasPort || !hasAddr else { return }
        guard case .service(let name, let type, let domain, _) = result.endpoint else { return }

        let key = name + "|" + type
        let now = Date()
        if let last = txtResolveCooldown[key], now.timeIntervalSince(last) < 2.0 { return }
        txtResolveCooldown[key] = now

        let targetDeviceId = d.id

        Task { [weak self, domain, type, name, serviceType, result, targetDeviceId] in
            guard let self else { return }
            guard let resolved = await self.resolveNetServiceEndpoint(
                domain: domain,
                type: type,
                name: name,
                timeoutSeconds: 1.2
            ) else {
                return
            }

            guard let currentIndex = self.discoveredDevices.firstIndex(where: { $0.id == targetDeviceId }) else {
                return
            }

            let dd = self.discoveredDevices[currentIndex]
            var newPortMap = dd.portMap
            if (newPortMap[serviceType] ?? 0) == 0, resolved.port > 0 {
                newPortMap[serviceType] = resolved.port
            }

            let newIPv4 = dd.ipv4 ?? resolved.ipv4
            let newIPv6 = dd.ipv6 ?? resolved.ipv6
            let bonjourUniqueIdentifier = self.bonjourIdentifier(from: result.endpoint)
            let preferredIdentifier = P2PDiscoveryBonjourPolicy.preferredUniqueIdentifier(
                deviceId: dd.deviceId,
                pubKeyFP: dd.pubKeyFP,
                bonjourIdentifier: bonjourUniqueIdentifier,
                ipv4: newIPv4,
                ipv6: newIPv6
            )

            let updated = DiscoveredDevice(
                id: dd.id,
                name: dd.name,
                ipv4: newIPv4,
                ipv6: newIPv6,
                services: dd.services,
                portMap: newPortMap,
                connectionTypes: dd.connectionTypes,
                uniqueIdentifier: preferredIdentifier ?? dd.uniqueIdentifier,
                routeIdentifiers: DiscoveredDevice.mergedRouteIdentifiers(
                    dd.routeIdentifiers,
                    [bonjourUniqueIdentifier].compactMap { $0 }
                ),
                signalStrength: dd.signalStrength,
                networkLinkStatus: dd.networkLinkStatus,
                source: dd.source,
                isLocalDevice: dd.isLocalDevice,
                deviceId: dd.deviceId,
                pubKeyFP: dd.pubKeyFP,
                macSet: dd.macSet
            )
            self.discoveredDevices[currentIndex] = updated
        }
    }
    private func updateDiscoveredDeviceAsync(from result: NWBrowser.Result, serviceType: String) {
        let bonjourUniqueIdentifier = bonjourIdentifier(from: result.endpoint)
        let strongIdentity = extractStrongIdentity(from: result)
        Task.detached { [serviceType, bonjourUniqueIdentifier, strongIdentity] in
            let deviceId = P2P_ExtractDeviceName(result)
            let (ipv4, ipv6) = P2P_ExtractNetworkAddrs(result)
            await MainActor.run { [self] in
                if let idx = self.findDiscoveredDeviceIndex(
                    name: deviceId,
                    ipv4: ipv4,
                    ipv6: ipv6,
                    bonjourIdentifier: bonjourUniqueIdentifier,
                    strongIdentity: strongIdentity
                ) {
                    let ipv4Str = ipv4 ?? "无"
                    self.logger.info("🔄 更新[\(serviceType)]: \(deviceId) - IPv4: \(ipv4Str)")
                    self.resolveViaNetServiceIfNeeded(result: result, deviceIndex: idx, serviceType: serviceType)
                }
            }
        }
    }
 /// 将网络发现的设备映射为 P2P 设备（供上层统一使用）
 /// Swift 6.2.1：公钥数据在发现阶段暂不可用，将在安全握手时获取
    private static func mapToP2PDevice(_ d: DiscoveredDevice) -> P2PDevice {
        let address = d.ipv4 ?? d.ipv6 ?? ""
        let portInt: Int = {
            if let port = d.portMap["_skybridge._tcp"], port > 0 { return port }
            if let port = d.portMap["_skybridge._udp"], port > 0 { return port }
            for (serviceType, port) in d.portMap where port > 0 {
                if serviceType.hasPrefix("_"), serviceType.hasSuffix("._tcp") || serviceType.hasSuffix("._udp") {
                    return port
                }
            }
            return 0
        }()
        let endpoints: [String] = portInt > 0 ? ["\(address):\(portInt)"] : (address.isEmpty ? [] : [address])
        let stableId: String = {
            if let persistent = d.deviceId, !persistent.isEmpty {
                return persistent
            }
            return d.id.uuidString
        }()
        return P2PDevice(
            id: stableId,
            name: d.name,
            type: .macOS,
            address: address,
            port: UInt16(portInt),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            capabilities: Array(Set(d.services)).sorted(),
            publicKey: Data(), // 公钥在协议握手主路径中获取并完成绑定
            lastSeen: Date(),
            endpoints: endpoints,
            lastMessageTimestamp: nil,
            isVerified: false,
            verificationFailedReason: d.pubKeyFP == nil ? "等待公钥交换" : nil,
            persistentDeviceId: d.deviceId,
            pubKeyFingerprint: d.pubKeyFP,
            macAddresses: d.macSet.isEmpty ? nil : d.macSet
        )
    }
}

/// 解析 TXT 记录（已废弃，使用统一解析器）
@available(*, deprecated, message: "Use BonjourTXTParser.parse instead")
fileprivate func P2P_ParseTXTRecord(_ txtRecord: NWTXTRecord) -> [String: String]? {
    let dict = BonjourTXTParser.parse(txtRecord)
    return dict.isEmpty ? nil : dict
}

fileprivate func P2P_CleanDeviceName(_ name: String) -> String {
    var cleaned = name
    cleaned = cleaned.replacingOccurrences(of: "._tcp", with: "")
    cleaned = cleaned.replacingOccurrences(of: "._udp", with: "")
    cleaned = cleaned.replacingOccurrences(of: ".local", with: "")
    cleaned = cleaned.trimmingCharacters(in: .whitespaces)
    if cleaned.count > 50 { cleaned = String(cleaned.prefix(47)) + "..." }
    return cleaned
}

fileprivate func P2P_ExtractDeviceName(_ result: NWBrowser.Result) -> String {
    var deviceName = "未知设备"
    if case .service(let name, _, _, _) = result.endpoint {
        deviceName = name
        let metadata = result.metadata
        if case .bonjour(let txtRecord) = metadata {
            let info = BonjourTXTParser.extractDeviceInfo(txtRecord)
            if let friendly = info.name ?? info.hostname { deviceName = friendly }
            if let model = info.type ?? info.model { deviceName += " (\(model))" }
        }
        deviceName = P2P_CleanDeviceName(deviceName)
        let localName = Host.current().localizedName ?? ""
        if !localName.isEmpty, deviceName == localName { deviceName += " (本机)" }
    }
    return deviceName
}

fileprivate func P2P_GetIPAddressesForInterface(_ interfaceName: String) -> (ipv4: String?, ipv6: String?)? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return nil }
    defer { freeifaddrs(ifaddr) }
    var ipv4: String?
    var ipv6: String?
    var ptr = ifaddr
    while ptr != nil {
        defer { ptr = ptr?.pointee.ifa_next }
        guard let interface = ptr?.pointee,
              let name = decodeOptionalCString(interface.ifa_name),
              let addressPtr = interface.ifa_addr else { continue }
        if name == interfaceName || name.hasPrefix("en") || name.hasPrefix("awdl") {
            let addr = addressPtr.pointee
            if addr.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addressPtr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                    let data = Data(bytes: hostname, count: hostname.count)
                    let trimmed = data.prefix { $0 != 0 }
                    let address = String(decoding: trimmed, as: UTF8.self)
                    if !address.starts(with: "169.254") && !address.starts(with: "127.") { ipv4 = address }
                }
            } else if addr.sa_family == UInt8(AF_INET6) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addressPtr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                    let data = Data(bytes: hostname, count: hostname.count)
                    let trimmed = data.prefix { $0 != 0 }
                    let address = String(decoding: trimmed, as: UTF8.self)
                    if !address.starts(with: "fe80:") { ipv6 = address }
                }
            }
        }
    }
    return (ipv4, ipv6)
}

fileprivate func P2P_ExtractIPAddress(from data: Data) -> String {
    return data.withUnsafeBytes { bytes in
        guard bytes.count >= MemoryLayout<sockaddr>.size,
              let sockaddr = bytes.bindMemory(to: sockaddr.self).baseAddress else {
            return "未知地址"
        }
        switch Int32(sockaddr.pointee.sa_family) {
        case AF_INET:
            guard bytes.count >= MemoryLayout<sockaddr_in>.size,
                  let addr = bytes.bindMemory(to: sockaddr_in.self).baseAddress,
                  let cstr = inet_ntoa(addr.pointee.sin_addr) else {
                return "未知地址"
            }
            return String(cString: cstr)
        case AF_INET6:
            guard bytes.count >= MemoryLayout<sockaddr_in6>.size,
                  let addr = bytes.bindMemory(to: sockaddr_in6.self).baseAddress else {
                return "未知地址"
            }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var sin6_addr = addr.pointee.sin6_addr
            guard inet_ntop(AF_INET6, &sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                return "未知地址"
            }
            let data = Data(bytes: buffer, count: Int(INET6_ADDRSTRLEN))
            let trimmed = data.prefix { $0 != 0 }
            return String(decoding: trimmed, as: UTF8.self)
        default:
            return "未知地址"
        }
    }
}

fileprivate func P2P_ResolveHost(_ host: NWEndpoint.Host) -> (ipv4: String?, ipv6: String?)? {
    var ipv4: String?
    var ipv6: String?
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var result: UnsafeMutablePointer<addrinfo>?
    let hostString = "\(host)"
    guard getaddrinfo(hostString, nil, &hints, &result) == 0 else { return nil }
    defer { freeaddrinfo(result) }
    var ptr = result
    while ptr != nil {
        defer { ptr = ptr?.pointee.ai_next }
        guard let addr = ptr?.pointee,
              let addressPtr = addr.ai_addr else { continue }
        if addr.ai_family == AF_INET {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addressPtr, socklen_t(addr.ai_addrlen), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                let bytes4 = Data(bytes: hostname, count: hostname.count)
                let trimmed4 = bytes4.prefix { $0 != 0 }
                ipv4 = String(decoding: trimmed4, as: UTF8.self)
            }
        } else if addr.ai_family == AF_INET6 {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addressPtr, socklen_t(addr.ai_addrlen), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                let bytes6 = Data(bytes: hostname, count: hostname.count)
                let trimmed6 = bytes6.prefix { $0 != 0 }
                ipv6 = String(decoding: trimmed6, as: UTF8.self)
            }
        }
    }
    return (ipv4, ipv6)
}

fileprivate func P2P_ExtractNetworkAddrs(_ result: NWBrowser.Result) -> (ipv4: String?, ipv6: String?) {
    // Never infer peer address from local interfaces; that produces false self-IP and broken connectability checks.
    // For Bonjour services we rely on NetService resolveViaNetServiceIfNeeded(...) to hydrate real addresses later.
    if case .hostPort(let host, _) = result.endpoint {
        return P2P_ResolveHost(host) ?? (nil, nil)
    }
    return (nil, nil)
}
