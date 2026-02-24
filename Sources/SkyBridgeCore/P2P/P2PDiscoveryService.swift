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

/// 设备发现管理器 - 基于 2025 年 Apple 推荐栈
/// 使用 Network.framework 的 Bonjour 能力 + TCP 连接
///
/// 继承 BaseManager，统一管理器模式和生命周期管理
@MainActor
public class P2PDiscoveryService: BaseManager {

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
    private var txtResolveCooldown: [String: Date] = [:]
    private let outboundConnectionQueue = DispatchQueue(
        label: "com.skybridge.p2p.discovery.outbound-connection",
        qos: .utility
    )

 /// 服务类型瘦身策略 - 默认仅SkyBridge；兼容/调试模式可扩展
    private let allServiceTypes = [
        "_skybridge._tcp",
        "_companion-link._tcp",
        "_airplay._tcp",
        "_rdlink._tcp",
        "_sftp-ssh._tcp"
    ]
 /// 兼容模式与 companion-link 开关（默认关闭，正常用户场景仅SkyBridge）
    public var enableCompatibilityMode: Bool = false
    public var enableCompanionLink: Bool = false
    private func effectiveServiceTypes() -> [String] {
        var base = ["_skybridge._tcp"]
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

    private enum InterfacePreference: String {
        case automatic
        case wiredEthernetOnly
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

 // 停止 Bonjour 浏览 / 广播
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        listener?.cancel()
        listener = nil
    }

 // MARK: - 公共方法（扫描 / 连接）

 /// 开始扫描设备 - 2025 增强版：多服务类型扫描（全基于 Network.framework）
    public func startScanning() {
        guard isInitialized else {
            Task { await self.handleError(.notInitialized) }
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

 // 为每种服务类型创建独立的浏览器
        for serviceType in selected {
            let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: serviceDomain)
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

 // 同时启动监听器以便其他设备发现我们
        startAdvertising()
    }

 /// 启动发现（与 startScanning 同义，供上层统一调用）
    public func startDiscovery() {
        startScanning()
    }

 /// 停止发现（与 stopScanning 同义，供上层统一调用）
    public func stopDiscovery() {
        stopScanning()
    }

 /// 刷新设备列表（重启扫描）
    public func refreshDevices() async {
        // UX fix:
        // A hard stop/start here interrupts ongoing handshakes/transfers and creates reconnect loops.
        // For "refresh", we keep browsers/listener running and simply clear transient caches.
        logger.info("🔄 刷新设备列表（软刷新：不停止扫描/不重启广播）")
        discoveredDevices.removeAll()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        authenticatedConnections.values.forEach { $0.disconnect() }
        authenticatedConnections.removeAll()
        txtResolveCooldown.removeAll()
        connectionStatus = .disconnected
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
        }

        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        authenticatedConnections.values.forEach { $0.disconnect() }
        authenticatedConnections.removeAll()
        connectionStatus = .disconnected

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
        logger.info("尝试连接到设备: \(device.name)")
        NetworkActivityLogStore.shared.record(
            category: "p2p",
            message: "connect start device=\(device.name) route=\(String(describing: routePreference))"
        )
        let deviceKey = device.id.uuidString
        connections[deviceKey]?.cancel()
        connections.removeValue(forKey: deviceKey)
        if let existingAuthenticated = authenticatedConnections.removeValue(forKey: deviceKey) {
            existingAuthenticated.disconnect()
        }

        let preferUSBRoute = routePreference == .preferUSB || device.connectionTypes.contains(.usb)
        let disableDirectRoute = routePreference == .managedRelayOnly
        let primaryServiceType = "_skybridge._tcp"
        let connectableServiceTypes = normalizedConnectableServiceTypes(from: device.services)
        let preferredServiceType = connectableServiceTypes.contains(primaryServiceType) ? primaryServiceType : connectableServiceTypes.first
        let serviceNameCandidates = resolvedBonjourServiceNameCandidates(for: device)
        let serviceName = serviceNameCandidates.first ?? ""
        logger.info(
            "🧭 连接目标解析: displayName=\(device.name, privacy: .public) bonjourInstance=\(serviceName, privacy: .public) identifier=\((device.uniqueIdentifier ?? "nil"), privacy: .public)"
        )
        let hasBonjourIdentifier = isBonjourIdentifier(device.uniqueIdentifier)
        let shouldFallbackToDefaultSkyBridgePort =
            hasBonjourIdentifier
            || device.source == .skybridgeBonjour
            || device.source == .skybridgeP2P
            || connectableServiceTypes.contains(primaryServiceType)
            || connectableServiceTypes.contains("_skybridge._udp")
        let portValue = resolvedPort(
            for: device,
            preferredServiceType: preferredServiceType,
            primaryServiceType: primaryServiceType,
            connectableServiceTypes: connectableServiceTypes,
            allowSkyBridgeDefaultFallback: shouldFallbackToDefaultSkyBridgePort
        )
        let hasSkyBridgeControlHint =
            shouldFallbackToDefaultSkyBridgePort
            || device.source == .skybridgeBonjour
            || device.source == .skybridgeP2P
        let shouldAttemptBonjourService = !serviceNameCandidates.isEmpty
            && serviceNameCandidates.contains(where: { !isLikelyIPAddress($0) })
            && (hasBonjourIdentifier || hasSkyBridgeControlHint || (device.ipv4 == nil && device.ipv6 == nil))

        var bonjourEndpointAttempts: [NWEndpoint] = []
        if shouldAttemptBonjourService {
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
            for candidateServiceName in serviceNameCandidates where !candidateServiceName.isEmpty && !isLikelyIPAddress(candidateServiceName) {
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
        let hostFallbackEndpoints = makeHostFallbackEndpoints(device: device, portValue: portValue)

        var endpointAttempts: [NWEndpoint] = []
        if disableDirectRoute {
            endpointAttempts.append(contentsOf: bonjourEndpointAttempts)
        } else if preferUSBRoute {
            endpointAttempts.append(contentsOf: hostFallbackEndpoints)
            endpointAttempts.append(contentsOf: bonjourEndpointAttempts)
        } else {
            endpointAttempts.append(contentsOf: bonjourEndpointAttempts)
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

        // If type metadata is missing but we still have Bonjour identity, probe SkyBridge default service.
        if endpointAttempts.isEmpty, shouldAttemptBonjourService {
            for candidateServiceName in serviceNameCandidates where !candidateServiceName.isEmpty && !isLikelyIPAddress(candidateServiceName) {
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
                message: "connect failed device=\(device.name) reason=no_connectable_endpoint",
                level: "WARN"
            )
            throw P2PDiscoveryError.noConnectableEndpoint
        }

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
                        if case .service(let name, let type, _, _) = endpoint {
                            logger.info("📡 尝试 Bonjour 连接: \(name, privacy: .public) [\(type, privacy: .public)] security=\(plan.rawValue, privacy: .public) route=\(interfacePreference.rawValue, privacy: .public)")
                        } else {
                            logger.info("📡 尝试地址连接: \(endpoint.debugDescription, privacy: .public) security=\(plan.rawValue, privacy: .public) route=\(interfacePreference.rawValue, privacy: .public)")
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

                        logger.info("✅ 成功连接到设备: \(device.name)")
                        NetworkActivityLogStore.shared.record(
                            category: "p2p",
                            message: "connect success device=\(device.name) endpoint=\(endpoint.debugDescription)"
                        )
                        connectionStatus = .connected
                        return
                    } catch {
                        lastError = error
                        logger.warning("⚠️ 连接尝试失败，将回退到下一方案: \(error.localizedDescription, privacy: .public)")
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
            message: "connect failed device=\(device.name) reason=\(lastError?.localizedDescription ?? "cancelled")",
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
        let strictPQCEnabled = HandshakePolicy
            .recommendedDefault(compatibilityModeEnabled: compatibilityModeEnabled)
            .requirePQC
        let effectiveTimeoutSeconds = strictPQCEnabled ? max(timeoutSeconds, 90) : timeoutSeconds

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
            return 9527
        }()

        let persistentDeviceId = device.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let uniqueIdentifier = device.uniqueIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedId: String = {
            if let persistentDeviceId, !persistentDeviceId.isEmpty { return persistentDeviceId }
            if let uniqueIdentifier, !uniqueIdentifier.isEmpty { return uniqueIdentifier }
            return device.id.uuidString
        }()

        let capabilities = Array(Set(device.services)).sorted()
        let endpoints = [endpoint.debugDescription]

        return P2PDevice(
            id: resolvedId,
            name: resolvedBonjourServiceName(for: device),
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
        connectableServiceTypes: [String],
        allowSkyBridgeDefaultFallback: Bool
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
        if allowSkyBridgeDefaultFallback {
            return 9527
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

    private func normalizedConnectableServiceTypes(from rawTypes: [String]) -> [String] {
        let allowedTypes: Set<String> = ["_skybridge._tcp", "_skybridge._udp"]
        var seen = Set<String>()
        var ordered: [String] = []

        for rawType in rawTypes {
            let normalized = rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard allowedTypes.contains(normalized), isValidBonjourServiceType(normalized) else {
                continue
            }
            if seen.insert(normalized).inserted {
                ordered.append(normalized)
            }
        }
        return ordered
    }

    private func isValidBonjourServiceType(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.hasPrefix("_") else { return false }
        guard value.hasSuffix("._tcp") || value.hasSuffix("._udp") else { return false }

        let serviceLabel = value
            .replacingOccurrences(of: "._tcp", with: "")
            .replacingOccurrences(of: "._udp", with: "")
            .dropFirst()
        guard !serviceLabel.isEmpty, serviceLabel.count <= 15 else { return false }
        return serviceLabel.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private func isBonjourIdentifier(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("bonjour:") || normalized.hasPrefix("recent:bonjour:")
    }

    private func isLikelyIPAddress(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(":") { return true }
        let segments = trimmed.split(separator: ".")
        return segments.count == 4 && segments.allSatisfy { part in
            guard let value = Int(part), (0...255).contains(value) else { return false }
            return String(value) == String(part) || part == "0"
        }
    }

    private func resolvedBonjourServiceName(for device: DiscoveredDevice) -> String {
        resolvedBonjourServiceNameCandidates(for: device).first ?? ""
    }

    private func resolvedBonjourServiceNameCandidates(for device: DiscoveredDevice) -> [String] {
        // Use the actual Bonjour instance name first (`bonjour:<name>@<domain>`),
        // not the user-facing display name from TXT ("name"), which may differ.
        var candidates: [String] = []
        var seen = Set<String>()

        func append(_ raw: String?) {
            let sanitized = sanitizedBonjourServiceName(raw ?? "")
            guard !sanitized.isEmpty else { return }
            guard !seen.contains(sanitized) else { return }
            seen.insert(sanitized)
            candidates.append(sanitized)
        }

        let identifierName = extractBonjourServiceName(fromIdentifier: device.uniqueIdentifier)
        let inferredAppleName = inferredDefaultAppleBonjourServiceName(fromDisplayName: device.name)

        append(identifierName)
        if identifierName == nil {
            append(inferredAppleName)
            append(device.name)
        } else {
            append(device.name)
            append(inferredAppleName)
        }
        return candidates
    }

    private func extractBonjourServiceName(fromIdentifier identifier: String?) -> String? {
        guard let identifier else { return nil }
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)

        func parseName(from payload: String) -> String? {
            let name = payload.split(separator: "@", maxSplits: 1).first.map(String.init)
            return name?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func parsePlainName(from payload: String) -> String? {
            payload.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if normalized.hasPrefix("recent:bonjour:") {
            let payload = String(normalized.dropFirst("recent:bonjour:".count))
            return parseName(from: payload)
        }
        if normalized.hasPrefix("bonjour:") {
            let payload = String(normalized.dropFirst("bonjour:".count))
            return parseName(from: payload)
        }
        if normalized.hasPrefix("recent:name:") {
            let payload = String(normalized.dropFirst("recent:name:".count))
            return parsePlainName(from: payload)
        }
        if normalized.hasPrefix("name:") {
            let payload = String(normalized.dropFirst("name:".count))
            return parsePlainName(from: payload)
        }
        return nil
    }

    private func bonjourIdentifier(from endpoint: NWEndpoint) -> String? {
        guard case .service(let name, _, let domain, _) = endpoint else { return nil }
        let normalizedDomain = domain.isEmpty ? serviceDomain : domain.lowercased()
        return "bonjour:\(name)@\(normalizedDomain)"
    }

    private func sanitizedBonjourServiceName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "" }

        if name.lowercased().hasPrefix("peer:") {
            return ""
        }

        // Strip unstable metadata suffixes often appended by discovery overlays:
        // "iPhone [高速]" / "iPhone (Model)" / "iPhone 【Wi-Fi】".
        while true {
            if let stripped = stripTrailingBracketSuffix(from: name, open: "(", close: ")") {
                name = stripped
                continue
            }
            if let stripped = stripTrailingBracketSuffix(from: name, open: "[", close: "]") {
                name = stripped
                continue
            }
            if let stripped = stripTrailingBracketSuffix(from: name, open: "【", close: "】") {
                name = stripped
                continue
            }
            break
        }

        for suffix in [" 📱", " 🍎"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripTrailingBracketSuffix(from raw: String, open: Character, close: Character) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.last == close else { return nil }
        guard let openIndex = value.lastIndex(of: open), openIndex > value.startIndex else { return nil }

        let prefix = value[..<openIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return nil }
        return String(prefix)
    }

    private func inferredDefaultAppleBonjourServiceName(fromDisplayName displayName: String) -> String? {
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        if normalized.contains("iphone") { return "iPhone" }
        if normalized.contains("ipad") { return "iPad" }
        if normalized.contains("macbook")
            || normalized.contains("imac")
            || normalized.contains("mac mini")
            || normalized.contains("mac studio")
            || normalized.contains("mac pro")
            || normalized == "mac"
            || normalized.contains(" mac ") {
            return "Mac"
        }
        return nil
    }

 /// 断开与指定设备的连接
    public func disconnectFromDevice(_ deviceId: String) {
        logger.info("🔌 断开设备连接: \(deviceId)")

        if let authenticated = authenticatedConnections.removeValue(forKey: deviceId) {
            authenticated.disconnect()
        }
        connections[deviceId]?.cancel()
        connections.removeValue(forKey: deviceId)

        if connections.isEmpty {
            connectionStatus = .disconnected
        }
    }

 /// 发送数据到指定设备
    public func sendData(_ data: Data, to deviceId: String) async throws {
        guard let connection = connections[deviceId] else {
            throw P2PDiscoveryError.deviceNotConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

 // MARK: - Bonjour 广播（本机作为服务端）

 /// 启动广播服务（Bonjour）
    @MainActor public func startAdvertising() {
        logger.info("📡 开始广播服务")
        if isAdvertising {
            logger.debug("📡 广播已在运行，忽略重复启动")
            return
        }
        if let existing = listener {
            existing.cancel()
            listener = nil
        }

        Task { @MainActor in
            if await ServiceAdvertiserCenter.shared.isAdvertising("_skybridge._tcp") {
                logger.debug("📡 广播中心已在运行，忽略重复启动")
                isAdvertising = true
                return
            }
            do {
                let port = try await ServiceAdvertiserCenter.shared.startAdvertising(
                    serviceName: getDeviceName(),
                    serviceType: "_skybridge._tcp",
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

 /// 停止广播服务
    private func stopAdvertising() {
        logger.info("📡 停止广播服务")
        listener?.cancel()
        listener = nil
        isAdvertising = false
        Task {
            await ServiceAdvertiserCenter.shared.stopAdvertising("_skybridge._tcp")
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
                removeDiscoveredDevice(from: result)
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
            dict["deviceId"] ?? dict["id"] ?? dict["deviceID"] ?? dict["device_id"] ?? dict["uuid"]
        )
        let pubKeyFP = sanitizePubKeyFingerprint(
            dict["pubKeyFP"] ?? dict["pubkeyfp"] ?? dict["pubkeyFP"] ?? dict["fp"]
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
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else {
            return nil
        }
        guard value.range(of: "^[0-9a-f]{16,128}$", options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    private func extractSOAFlag(from result: NWBrowser.Result) -> Bool {
        guard case .bonjour(let txtRecord) = result.metadata else {
            return false
        }
        let dict = BonjourTXTParser.parse(txtRecord)
        return normalizeSOAFlag(dict["hs_soa"] ?? dict["HS_SOA"])
    }

    private func normalizeSOAFlag(_ value: String?) -> Bool {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return false
        }
        return raw == "1" || raw == "true" || raw == "yes"
    }

    private func isStrongUniqueIdentifier(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.hasPrefix("id:") || value.hasPrefix("fp:")
    }

    private func preferredUniqueIdentifier(
        deviceId: String?,
        pubKeyFP: String?,
        bonjourIdentifier: String?,
        ipv4: String?,
        ipv6: String?
    ) -> String? {
        if let deviceId, !deviceId.isEmpty { return "id:\(deviceId)" }
        if let pubKeyFP, !pubKeyFP.isEmpty { return "fp:\(pubKeyFP)" }
        return bonjourIdentifier ?? ipv4 ?? ipv6
    }

 /// 添加发现的设备 - 增强版：识别设备类型
    private func addDiscoveredDevice(from result: NWBrowser.Result, serviceType: String) {
        let deviceName = extractDeviceName(from: result)
        let (ipv4, ipv6, port) = extractNetworkInfo(from: result)
        let bonjourUniqueIdentifier = bonjourIdentifier(from: result.endpoint)
        let strongIdentity = extractStrongIdentity(from: result)
        let supportsSOA = extractSOAFlag(from: result)

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
            connectionTypes: [.wifi], // 网络发现的设备默认为 Wi-Fi
            uniqueIdentifier: preferredUniqueIdentifier(
                deviceId: strongIdentity.deviceId,
                pubKeyFP: strongIdentity.pubKeyFP,
                bonjourIdentifier: bonjourUniqueIdentifier,
                ipv4: ipv4,
                ipv6: ipv6
            ),
            signalStrength: nil,
            isLocalDevice: isProbablyLocalDevice(name: deviceName, ipv4: ipv4, ipv6: ipv6),
            deviceId: strongIdentity.deviceId,
            pubKeyFP: strongIdentity.pubKeyFP
        )

 // 检查是否已存在相同的设备（基于 IP 地址，更准确）
        if let existingIndex = discoveredDevices.firstIndex(where: { existingDevice in
            if let existingDeviceId = existingDevice.deviceId,
               let newDeviceId = device.deviceId,
               !existingDeviceId.isEmpty,
               existingDeviceId == newDeviceId {
                return true
            }
            if let existingFP = existingDevice.pubKeyFP?.lowercased(),
               let newFP = device.pubKeyFP?.lowercased(),
               !existingFP.isEmpty,
               existingFP == newFP {
                return true
            }
            // 优先使用 IP 地址匹配
            if let existingIPv4 = existingDevice.ipv4,
               let newIPv4 = device.ipv4,
               existingIPv4 == newIPv4 {
                return true
            }
            if let existingIPv6 = existingDevice.ipv6,
               let newIPv6 = device.ipv6,
               existingIPv6 == newIPv6 {
                return true
            }
 // 如果没有 IP，使用名称匹配（去除 emoji 和特殊字符后）
            let cleanExistingName = existingDevice.name.filter { $0.isLetter || $0.isNumber }
            let cleanNewName = deviceName.filter { $0.isLetter || $0.isNumber }
            return cleanExistingName == cleanNewName && !cleanNewName.isEmpty
        }) {
 // 设备已存在，更新服务列表
            var existingDevice = discoveredDevices[existingIndex]
            if !existingDevice.services.contains(serviceType) {
                existingDevice.services.append(serviceType)
                existingDevice.portMap[serviceType] = port
            }
            if supportsSOA, !existingDevice.services.contains("hs_soa") {
                existingDevice.services.append("hs_soa")
            }
            if let newDeviceId = strongIdentity.deviceId, !newDeviceId.isEmpty {
                existingDevice.deviceId = newDeviceId
            }
            if let newPubKeyFP = strongIdentity.pubKeyFP, !newPubKeyFP.isEmpty {
                existingDevice.pubKeyFP = newPubKeyFP
            }
            if let preferredIdentifier = preferredUniqueIdentifier(
                deviceId: existingDevice.deviceId,
                pubKeyFP: existingDevice.pubKeyFP,
                bonjourIdentifier: bonjourUniqueIdentifier,
                ipv4: existingDevice.ipv4 ?? device.ipv4,
                ipv6: existingDevice.ipv6 ?? device.ipv6
            ) {
                if isStrongUniqueIdentifier(existingDevice.uniqueIdentifier) {
                    if isStrongUniqueIdentifier(preferredIdentifier) {
                        existingDevice.uniqueIdentifier = preferredIdentifier
                    }
                } else {
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
        Task.detached { [serviceType, bonjourUniqueIdentifier, strongIdentity, supportsSOA] in
            let deviceName = P2P_ExtractDeviceName(result)
            let (ipv4, ipv6) = P2P_ExtractNetworkAddrs(result)
            let port = 0
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
                connectionTypes: [.wifi],
                uniqueIdentifier: {
                    if let deviceId = strongIdentity.deviceId, !deviceId.isEmpty {
                        return "id:\(deviceId)"
                    }
                    if let pubKeyFP = strongIdentity.pubKeyFP, !pubKeyFP.isEmpty {
                        return "fp:\(pubKeyFP)"
                    }
                    return bonjourUniqueIdentifier ?? ipv4 ?? ipv6
                }(),
                deviceId: strongIdentity.deviceId,
                pubKeyFP: strongIdentity.pubKeyFP
            )
            await MainActor.run { [self] in
                if let existingIndex = self.discoveredDevices.firstIndex(where: { existing in
                    if let existingDeviceId = existing.deviceId,
                       let newDeviceId = device.deviceId,
                       !existingDeviceId.isEmpty,
                       existingDeviceId == newDeviceId { return true }
                    if let existingFP = existing.pubKeyFP?.lowercased(),
                       let newFP = device.pubKeyFP?.lowercased(),
                       !existingFP.isEmpty,
                       existingFP == newFP { return true }
                    if let e4 = existing.ipv4, let n4 = device.ipv4, e4 == n4 { return true }
                    if let e6 = existing.ipv6, let n6 = device.ipv6, e6 == n6 { return true }
                    let cleanExisting = existing.name.filter { $0.isLetter || $0.isNumber }
                    let cleanNew = deviceName.filter { $0.isLetter || $0.isNumber }
                    return !cleanNew.isEmpty && cleanExisting == cleanNew
                }) {
                    var existing = self.discoveredDevices[existingIndex]
                    if !existing.services.contains(serviceType) {
                        existing.services.append(serviceType)
                        existing.portMap[serviceType] = port
                    }
                    if supportsSOA, !existing.services.contains("hs_soa") {
                        existing.services.append("hs_soa")
                    }
                    if let newDeviceId = strongIdentity.deviceId, !newDeviceId.isEmpty {
                        existing.deviceId = newDeviceId
                    }
                    if let newPubKeyFP = strongIdentity.pubKeyFP, !newPubKeyFP.isEmpty {
                        existing.pubKeyFP = newPubKeyFP
                    }
                    if let preferredIdentifier = self.preferredUniqueIdentifier(
                        deviceId: existing.deviceId,
                        pubKeyFP: existing.pubKeyFP,
                        bonjourIdentifier: bonjourUniqueIdentifier,
                        ipv4: existing.ipv4 ?? device.ipv4,
                        ipv6: existing.ipv6 ?? device.ipv6
                    ) {
                        if self.isStrongUniqueIdentifier(existing.uniqueIdentifier) {
                            if self.isStrongUniqueIdentifier(preferredIdentifier) {
                                existing.uniqueIdentifier = preferredIdentifier
                            }
                        } else {
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
    private func removeDiscoveredDevice(from result: NWBrowser.Result) {
        let deviceId = extractDeviceName(from: result)
        discoveredDevices.removeAll { $0.name == deviceId }
        logger.info("设备已离线: \(deviceId)")
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
            logger.info("📡 监听器就绪")
        case .failed(let error):
            logger.error("❌ 监听器失败: \(error.localizedDescription)")
        case .cancelled:
            logger.info("⏹️ 监听器已取消")
        default:
            break
        }
    }

 /// 处理新连接（传入 TCP）
    private func handleNewConnection(_ connection: NWConnection) {
        logger.info("🔗 收到新连接")

 // 设置连接状态处理器
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
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
            connection.cancel()
        case .cancelled:
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
            let snapshot = await SelfIdentityProvider.shared.snapshot()
            if !snapshot.deviceId.isEmpty {
                return soaPeerIdBytes(from: snapshot.deviceId)
            }
        }
        return soaPeerIdBytes(from: Host.current().localizedName ?? "mac-local")
    }

 /// 统一的入站控制包模型，JSON使用Base64承载二进制字段
    private struct SecurePacket: Codable {
        enum PacketType: String, Codable { case message, keyExchange, heartbeat }
        let type: PacketType
        let data: Data
        let signature: Data
        let timestamp: TimeInterval
    }

    /// 入站控制通道处理（优先 SecurePacket(JSON)，否则回退 HandshakeDriver，与 iOS 互通）
    nonisolated private func handleInboundControlChannel(_ connection: NWConnection) async {
        let logger = Logger(subsystem: "com.skybridge.Compass", category: "P2PInboundHandshake")
        var didMarkEstablished = false
        defer {
            if didMarkEstablished {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.activeInboundSessions = max(0, self.activeInboundSessions - 1)
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
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    connection.send(content: framed, completion: .contentProcessed { err in
                        if let err { c.resume(throwing: err) } else { c.resume() }
                    })
                }
            }
        }

        let framedReader = FramedReader.nwConnection(connection)

        func sendAck(_ code: UInt8) async throws {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                connection.send(content: Data([code]), completion: .contentProcessed { err in
                    if let err { c.resume(throwing: err) } else { c.resume() }
                })
            }
        }

        func packetSenderId(_ packet: SecurePacket) -> String { String(packet.timestamp) }

        let transport = DirectHandshakeTransport(connection: connection)
        let resolvedPeerId = await MainActor.run { [weak self] in
            self?.resolveInboundPeerIdentifier(for: connection.endpoint) ?? Self.fallbackPeerIdentifier(for: connection.endpoint)
        }
        let localSOAPeerId = await Self.localSOAPeerIdBytes()
        var expectedRemoteSOAPeerId: Data?
        var inboundPairKey: Data?
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

        logger.info("🤝 入站连接：启用 HandshakeDriver 兼容通道（iOS 互通） state=\(String(describing: connection.state), privacy: .public)")

        do {
            while true {
                if case .failed = connection.state { break }
                if case .cancelled = connection.state { break }
                let lenData = try await framedReader.receiveExactly(4)
                let totalLen = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
                guard totalLen > 0 && totalLen < 1_048_576 else { break }

                let payload = try await framedReader.receiveExactly(Int(totalLen))
                let unwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx")

                if let packet = try? JSONDecoder().decode(SecurePacket.self, from: unwrapped) {
                    do {
                        let ok = try await EnhancedPostQuantumCrypto().verify(packet.data, signature: packet.signature, for: packetSenderId(packet))
                        guard ok else {
                            logger.error("❌ 入站控制包验签失败")
                            continue
                        }
                    } catch {
                        logger.error("❌ 入站控制包验签异常: \(error.localizedDescription, privacy: .public)")
                        continue
                    }

                    switch packet.type {
                    case .message:
                        NotificationCenter.default.post(name: Notification.Name("P2PInboundMessage"), object: self, userInfo: ["payload": packet.data])
                    case .keyExchange:
                        NotificationCenter.default.post(name: Notification.Name("P2PInboundKeyExchange"), object: self, userInfo: ["payload": packet.data])
                    case .heartbeat:
                        try await sendAck(0x09)
                    }
                    continue
                }

                // 延迟初始化：必须先看到 MessageA 才知道对端 offeredSuites 分组，
                // 从而选择本机可用的 (sigAAlgorithm / provider / offeredSuites) 组合。
                if driver == nil {
                    if let messageA = try? HandshakeMessageA.decode(from: unwrapped) {
                        let soaBinding = InboundHandshakeAdapter.bindSOAState(
                            from: messageA,
                            localPeerId: localSOAPeerId
                        )
                        expectedRemoteSOAPeerId = soaBinding.expectedRemotePeerId
                        inboundPairKey = soaBinding.pairKey
                        if soaBinding.usedAuthenticatedInitiator {
                            logger.info("🧩 inboundSOA: binding to MessageA initiatorPeerId (endpointId=\(peer.deviceId, privacy: .public))")
                        }
                        let peerHasPQCGroup = messageA.supportedSuites.contains { $0.isPQCGroup }
                        let peerHasClassicGroup = messageA.supportedSuites.contains { !$0.isPQCGroup }
                        let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
                        let policy = HandshakePolicy.recommendedDefault(compatibilityModeEnabled: compatibilityModeEnabled)

                        // Pick provider first, then derive sigA/offeredSuites from what we can actually support.
                        var selection: CryptoProviderFactory.SelectionPolicy = .classicOnly
                        var cryptoProvider: any CryptoProvider = CryptoProviderFactory.make(policy: .classicOnly)
                        var sigAAlgorithm: ProtocolSigningAlgorithm = .ed25519
                        var offeredSuites: [CryptoSuite] = cryptoProvider.supportedSuites.filter { !$0.isPQCGroup }
                        var effectivePolicy = policy

                        if peerHasPQCGroup {
                            selection = policy.requirePQC ? .requirePQC : .preferPQC
                            cryptoProvider = CryptoProviderFactory.make(policy: selection)
                            let localPQCSuites = DeviceIdentityKeyManager.pairingIdentityAdvertisedPQCSuites(using: cryptoProvider)

                            if localPQCSuites.isEmpty {
                                if policy.requirePQC {
                                    logger.error("❌ PQC required by policy but no PQC provider available on this device. peer=\(peer.deviceId, privacy: .public)")
                                    return
                                }
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
	                                            "deviceId": peer.deviceId,
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
	                                    logger.info("🧩 inboundFallback(classic): peer advertises PQC but local PQC unavailable; falling back to classic handshake. peer=\(peer.deviceId, privacy: .public)")
	                            } else {
	                                    logger.error("❌ Peer offered PQC-only suites but local PQC unavailable; cannot continue. peer=\(peer.deviceId, privacy: .public)")
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
                            effectivePolicy = HandshakePolicy(
                                requirePQC: false,
                                allowClassicFallback: false,
                                minimumTier: .classic,
                                requireSecureEnclavePoP: policy.requireSecureEnclavePoP
                            )
                        }

                        let keyManager = DeviceIdentityKeyManager.shared
                        let (protocolPublicKey, signingKeyHandle): (Data, SigningKeyHandle)
                        if sigAAlgorithm == .mlDSA65 {
                            (protocolPublicKey, signingKeyHandle) = try await keyManager.getOrCreateMLDSASigningKey()
                        } else {
                            (protocolPublicKey, signingKeyHandle) = try await keyManager.getOrCreateProtocolSigningKey()
                        }

                        let identityPublicKeyWire = ProtocolIdentityPublicKeys(
                            protocolPublicKey: protocolPublicKey,
                            protocolAlgorithm: sigAAlgorithm,
                            sePoPPublicKey: nil
                        ).asWire().encoded

                        do {
                            driver = try HandshakeDriver(
                                transport: transport,
                                cryptoProvider: cryptoProvider,
                                protocolSignatureProvider: ProtocolSignatureProviderSelector.select(for: sigAAlgorithm),
                                protocolSigningKeyHandle: signingKeyHandle,
                                sigAAlgorithm: sigAAlgorithm,
                                identityPublicKey: identityPublicKeyWire,
                                offeredSuites: offeredSuites,
                                policy: effectivePolicy,
                                localSOAPeerId: localSOAPeerId,
                                expectedRemoteSOAPeerId: expectedRemoteSOAPeerId
                            )
                            logger.info("🤝 入站 HandshakeDriver 初始化完成: sigA=\(sigAAlgorithm.rawValue, privacy: .public) provider=\(String(describing: type(of: cryptoProvider)), privacy: .public)")
                        } catch {
                            logger.error("❌ 入站 HandshakeDriver 初始化失败: \(error.localizedDescription, privacy: .public)")
                            return
                        }
                    } else {
                        logger.debug("ℹ️ 入站首帧不是 MessageA（忽略，等待下一帧） size=\(unwrapped.count, privacy: .public)")
                        continue
                    }
                }

                guard let activeDriver = driver else { continue }
                await activeDriver.handleMessage(unwrapped, from: peer)
                let st = await activeDriver.getCurrentState()
                logger.debug("🤝 HandshakeDriver state: \(String(describing: st), privacy: .public)")

                if case .failed(let reason) = st {
                    logger.warning(
                        "⚠️ 入站握手失败，等待同连接重试: peer=\(peer.deviceId, privacy: .public) reason=\(String(describing: reason), privacy: .public)"
                    )
                    driver = nil
                    continue
                }

                if !didMarkEstablished, case .established = st {
                    didMarkEstablished = true
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.activeInboundSessions += 1
                        self.connectionStatus = .connected
                    }
                }
            }
        } catch {
            if let framedError = error as? FramedReaderError, framedError == .peerClosed {
                logger.debug("ℹ️ 入站控制通道结束（peer closed）")
            } else {
                logger.debug("ℹ️ 入站控制通道结束: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

 /// 判断给定 IPv4 地址是否属于本机，避免自连接导致路径冲突
    private func isLocalIPAddress(_ address: String) -> Bool {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return false }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            guard let interface = ptr?.pointee, let sa = interface.ifa_addr else { continue }
            let family = sa.pointee.sa_family
            if family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                    let data = Data(bytes: buf, count: buf.count)
                    let trimmed = data.prefix { $0 != 0 }
                    let ip = String(decoding: trimmed, as: UTF8.self)
                    if ip == address { return true }
                }
            }
        }
        return false
    }

 /// 判断是否为本机设备（严格匹配）
    private func isProbablyLocalDevice(name: String, ipv4: String?, ipv6: String?) -> Bool {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        var locals: Set<String> = []
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee, let sa = interface.ifa_addr else { continue }
                let fam = sa.pointee.sa_family
                if fam == UInt8(AF_INET) || fam == UInt8(AF_INET6) {
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                        let data = Data(bytes: buf, count: buf.count)
                        let trimmed = data.prefix { $0 != 0 }
                        let ip = String(decoding: trimmed, as: UTF8.self)
                        if !ip.isEmpty { locals.insert(ip) }
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        if let v4 = ipv4, locals.contains(v4) { return true }
        if let v6 = ipv6, locals.contains(v6) { return true }
        func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "") }
        let localName = Host.current().localizedName ?? ""
        if !localName.isEmpty, norm(name) == norm(localName) { return true }
        return false
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

        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(result?.pointee.ai_addr,
                       socklen_t(result?.pointee.ai_addrlen ?? 0),
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

            guard let interface = ptr?.pointee else { continue }
            let name = String(decoding: Data(bytes: interface.ifa_name,
                                             count: Int(strlen(interface.ifa_name))),
                              as: UTF8.self)

 // 匹配接口名（Wi-Fi / AWDL 等）
            if name == interfaceName || name.hasPrefix("en") || name.hasPrefix("awdl") {
                let addr = interface.ifa_addr.pointee

                if addr.sa_family == UInt8(AF_INET) {
 // IPv4
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

            guard let addr = ptr?.pointee else { continue }

            if addr.ai_family == AF_INET {
 // IPv4
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    addr.ai_addr,
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
                    addr.ai_addr,
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
        Task.detached { [domain, type, name, serviceType] in
            let svc = NetService(domain: domain.isEmpty ? "local." : domain, type: type, name: name)
            svc.resolve(withTimeout: 1.0)
            var port = 0
            if svc.port > 0 { port = svc.port }
            var found4: String?
            var found6: String?
            if let addrs = svc.addresses {
                for data in addrs {
                    let addr = P2P_ExtractIPAddress(from: data)
                    if addr.contains("."), !addr.starts(with: "169.254"), !addr.starts(with: "127."), found4 == nil { found4 = addr }
                    else if addr.contains(":"), !addr.starts(with: "fe80:"), found6 == nil { found6 = addr }
                }
            }
            await MainActor.run { [self] in
                guard deviceIndex >= 0 && deviceIndex < self.discoveredDevices.count else { return }
                let dd = self.discoveredDevices[deviceIndex]
                var newPortMap = dd.portMap
                if (newPortMap[serviceType] ?? 0) == 0 && port > 0 { newPortMap[serviceType] = port }
                let newIPv4 = dd.ipv4 ?? found4
                let newIPv6 = dd.ipv6 ?? found6
                let bonjourUniqueIdentifier = self.bonjourIdentifier(from: result.endpoint)
                let preferredIdentifier = self.preferredUniqueIdentifier(
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
                    signalStrength: dd.signalStrength,
                    source: dd.source,
                    isLocalDevice: dd.isLocalDevice,
                    deviceId: dd.deviceId,
                    pubKeyFP: dd.pubKeyFP,
                    macSet: dd.macSet
                )
                self.discoveredDevices[deviceIndex] = updated
            }
        }
    }
    private func updateDiscoveredDeviceAsync(from result: NWBrowser.Result, serviceType: String) {
        Task.detached { [serviceType] in
            let deviceId = P2P_ExtractDeviceName(result)
            let (ipv4, _) = P2P_ExtractNetworkAddrs(result)
            await MainActor.run { [self] in
                if let idx = self.discoveredDevices.firstIndex(where: { $0.name.contains(deviceId) }) {
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
            publicKey: Data(), // 公钥在 P2PSecurityManager.establishSessionKey 握手时获取
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

// MARK: - 数据模型 & 错误类型

/// 网络发现的设备（内部使用）
internal struct P2PNetworkDiscoveredDevice: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let endpoint: NWEndpoint
    public var metadata: NWTXTRecord?
    public let discoveredAt: Date
    public var lastSeen: Date = Date()

    public init(id: String, name: String, endpoint: NWEndpoint, metadata: NWTXTRecord?, discoveredAt: Date) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.metadata = metadata
        self.discoveredAt = discoveredAt
    }
}

/// 设备发现连接状态
public enum P2PDiscoveryConnectionStatus: String, CaseIterable {
    case disconnected = "未连接"
    case connecting = "连接中"
    case connected = "已连接"
    case reconnecting = "重连中"
    case failed = "连接失败"
    case timeout = "连接超时"

    public var displayName: String {
        return rawValue
    }
}

/// 设备发现错误
public enum P2PDiscoveryError: Error, LocalizedError {
    case deviceNotConnected
    case connectionCancelled
    case timeout
    case scanningFailed
    case noConnectableEndpoint

    public var errorDescription: String? {
        switch self {
        case .deviceNotConnected:
            return "设备未连接"
        case .connectionCancelled:
            return "连接已取消"
        case .timeout:
            return "连接超时"
        case .scanningFailed:
            return "扫描失败"
        case .noConnectableEndpoint:
            return "设备未暴露可连接的 SkyBridge 控制端点"
        }
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
        guard let interface = ptr?.pointee else { continue }
        let name = String(decoding: Data(bytes: interface.ifa_name, count: Int(strlen(interface.ifa_name))), as: UTF8.self)
        if name == interfaceName || name.hasPrefix("en") || name.hasPrefix("awdl") {
            let addr = interface.ifa_addr.pointee
            if addr.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(interface.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                    let data = Data(bytes: hostname, count: hostname.count)
                    let trimmed = data.prefix { $0 != 0 }
                    let address = String(decoding: trimmed, as: UTF8.self)
                    if !address.starts(with: "169.254") && !address.starts(with: "127.") { ipv4 = address }
                }
            } else if addr.sa_family == UInt8(AF_INET6) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(interface.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST) == 0 {
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
        guard let addr = ptr?.pointee else { continue }
        if addr.ai_family == AF_INET {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr.ai_addr, socklen_t(addr.ai_addrlen), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                let bytes4 = Data(bytes: hostname, count: hostname.count)
                let trimmed4 = bytes4.prefix { $0 != 0 }
                ipv4 = String(decoding: trimmed4, as: UTF8.self)
            }
        } else if addr.ai_family == AF_INET6 {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr.ai_addr, socklen_t(addr.ai_addrlen), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
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
