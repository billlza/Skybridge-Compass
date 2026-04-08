import Foundation
import Network
import OSLog
import Combine
import CryptoKit
#if os(iOS)
import UIKit
#endif

/// 设备发现管理器 - 基于 Bonjour + Network.framework
/// 继承 BaseManager，统一管理器模式和生命周期管理
@MainActor
public class DeviceDiscoveryManager: BaseManager {

 // MARK: - 发布的属性

 /// 发现的设备列表
    @Published public var discoveredDevices: [DiscoveredDevice] = []
    @Published public var connectionStatus: DeviceDiscoveryConnectionStatus = .disconnected
    @Published public var isScanning: Bool = false

 // MARK: - 私有属性
    private var browsers: [NWBrowser] = []  // 多个浏览器，扫描不同服务类型
    private var listener: NWListener?
    private var connections: [String: NWConnection] = [:]

    /// Best-effort cache of Bonjour TXT info keyed by advertised deviceId.
    /// Static so it can be accessed from `nonisolated` inbound handler via `MainActor.run`.
    @MainActor private static var bonjourInfoByDeviceId: [String: BonjourDeviceInfo] = [:]

 // 服务类型瘦身 - 默认仅SkyBridge；兼容/调试模式可扩展
    private let allServiceTypes = [
        "_skybridge._tcp",
        "_companion-link._tcp",
        "_airplay._tcp",
        "_rdlink._tcp",
        "_sftp-ssh._tcp"
    ]
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

    public init() {
 // 调用父类初始化，传入管理器类别
        super.init(category: "DeviceDiscoveryManager")
    }

 // MARK: - BaseManager 重写方法

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
        isScanning = false

 // 清理网络连接
        connections.values.forEach { $0.cancel() }
        connections.removeAll()

 // 停止浏览器和监听器
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        listener?.cancel()
        listener = nil
    }

 // MARK: - 公共方法

 /// 开始扫描设备 - 多服务类型扫描
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
            logger.debugOnly("startScanning() 忽略：已经在扫描中")
            return
        }
        let selected = effectiveServiceTypes()
        logger.info("🔍 开始扫描设备（服务类型：\(selected)）")
        isScanning = true

 // 为每种服务类型创建独立的浏览器
        for serviceType in selected {
            let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: serviceDomain)
            let parameters = NWParameters()
            parameters.includePeerToPeer = true  // 支持点对点（AWDL）

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
                    self?.handleBrowseResultsChanged(results: results, changes: changes, serviceType: serviceType)
                }
            }

 // 启动浏览器
            browser.start(queue: .global(qos: .utility))
            browsers.append(browser)

            logger.debugOnly("  ✅ 启动浏览器: \(serviceType)")
        }

 // 同时启动监听器以便其他设备发现我们
        startAdvertising()
    }

 /// 停止扫描设备
    public func stopScanning() {
        logger.info("⏹️ 停止扫描设备")
        isScanning = false

 // 取消所有浏览器
        for browser in browsers {
            browser.cancel()
        }
        browsers.removeAll()

        stopAdvertising()

 // 扫描结束后清洗缓存，确保本机唯一性
        Task { [weak self] in
            guard let self = self else { return }
            let selfId = await SelfIdentityProvider.shared.snapshot()
            await self.sanitizeCache(selfId)
        }
    }

 /// 连接到指定设备
    public func connectToDevice(_ device: DiscoveredDevice) async throws {
        logger.info("尝试连接到设备: \(device.name)")

        guard let ipv4 = device.ipv4 else {
            throw DeviceDiscoveryError.deviceNotConnected
        }
        if isLocalIPAddress(ipv4) {
            logger.debugOnly("忽略本机地址，跳过连接尝试: \(ipv4)")
            throw DeviceDiscoveryError.connectionCancelled
        }

        let portNumber = resolvedConnectablePort(for: device)
        guard portNumber > 0 else { throw DeviceDiscoveryError.scanningFailed }
        let host = NWEndpoint.Host(ipv4)
        let port = NWEndpoint.Port(integerLiteral: UInt16(portNumber))
        let endpoint = NWEndpoint.hostPort(host: host, port: port)

 // 应用统一 TLS 策略（近距连接）
        let net = RemoteDesktopSettingsManager.shared.settings.networkSettings

        let connection: NWConnection
        if isSkyBridgeControlDevice(device) {
            // SkyBridge 控制通道使用应用层握手加密；传输层固定纯 TCP。
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            params.allowLocalEndpointReuse = true
            connection = NWConnection(to: endpoint, using: params)
        } else if net.enableEncryption,
                  let tls = TLSConfigurator.options(for: net.encryptionAlgorithm) {
            let tcp = NWProtocolTCP.Options()
            let params = NWParameters(tls: tls, tcp: tcp)
            connection = NWConnection(to: endpoint, using: params)
        } else {
            connection = NWConnection(to: endpoint, using: .tcp)
        }

        let deviceId = device.id.uuidString
        connections[deviceId] = connection

 // 等待连接建立（内部会设置 stateUpdateHandler 并启动连接）
        try await waitForConnection(connection, deviceId: deviceId)

        logger.info("✅ 成功连接到设备: \(device.name, privacy: .public)")
    }

    private func isSkyBridgeControlDevice(_ device: DiscoveredDevice) -> Bool {
        device.services.contains("_skybridge._tcp")
            || device.services.contains("_skybridge._udp")
            || device.portMap["_skybridge._tcp"] != nil
            || device.portMap["_skybridge._udp"] != nil
    }

    private func resolvedConnectablePort(for device: DiscoveredDevice) -> Int {
        if let port = device.portMap["_skybridge._tcp"], port > 0 { return port }
        if let port = device.portMap["_skybridge._udp"], port > 0 { return port }

        for (serviceType, port) in device.portMap where port > 0 {
            if looksLikeBonjourServiceType(serviceType) {
                return port
            }
        }
        return 0
    }

    private func looksLikeBonjourServiceType(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("_") && (value.hasSuffix("._tcp") || value.hasSuffix("._udp"))
    }

 /// 断开与指定设备的连接
    public func disconnectFromDevice(_ deviceId: String) {
        logger.info("🔌 断开设备连接: \(deviceId, privacy: .public)")

        connections[deviceId]?.cancel()
        connections.removeValue(forKey: deviceId)

        if connections.isEmpty {
            connectionStatus = .disconnected
        }
    }

 /// 发送数据到指定设备
    public func sendData(_ data: Data, to deviceId: String) async throws {
        guard let connection = connections[deviceId] else {
            throw DeviceDiscoveryError.deviceNotConnected
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

 // MARK: - 私有方法

 // MARK: - 本机判定核心（"永久防第三方设备变本机"）

 /// 推断设备来源（source）
    private func inferSource(from serviceType: String) -> DeviceSource {
        let lower = serviceType.lowercased()

 // SkyBridge 自有服务
        if lower.contains("skybridge") {
            return DeviceSource.skybridgeBonjour
        }

 // 第三方 Bonjour 服务
        if lower.contains("airplay") ||
           lower.contains("ipp") ||
           lower.contains("printer") ||
           lower.contains("companion-link") ||
           lower.contains("rdlink") ||
           lower.contains("sftp") {
            return DeviceSource.thirdPartyBonjour
        }

        return DeviceSource.unknown
    }

 /// A. 统一写入点：唯一能调用 setIsLocalDeviceByDiscovery() 的地方
    private func applyLocalFlag(_ device: inout DiscoveredDevice, selfId: SelfIdentitySnapshot) async {
 // 前置检查：只有 SkyBridge 来源才有资格成为本机
        let eligible =
            device.source == .skybridgeBonjour ||
            device.source == .skybridgeP2P ||
            device.source == .skybridgeUSB ||
            device.source == .skybridgeCloud

        if !eligible {
 // 非本服务：强制清零身份字段
            device.deviceId = nil
            device.pubKeyFP = nil
            device.macSet.removeAll()
            device.setIsLocalDeviceByDiscovery(false)
            return
        }

        let local = await IdentityResolver.resolveIsLocal(device: device, selfId: selfId)
        device.setIsLocalDeviceByDiscovery(local)
    }

 /// 同步版本的本机判定（内联 IdentityResolver 逻辑）
    private func resolveIsLocalSync(device: DiscoveredDevice, selfId: SelfIdentitySnapshot) -> Bool {
 // 前置检查：selfId 为空不允许判定本机
        if selfId.deviceId.isEmpty || selfId.pubKeyFP.isEmpty {
            if let id = device.deviceId, id == selfId.deviceId, !id.isEmpty {
                return true
            }
            return false
        }

 // 优先级 A：deviceId 硬匹配
        if let deviceId = device.deviceId,
           !deviceId.isEmpty,
           deviceId.count >= 8,
           !selfId.deviceId.isEmpty,
           selfId.deviceId.count >= 8,
           deviceId == selfId.deviceId {
            return true
        }

 // 优先级 B：pubKeyFP 硬匹配
        if let pubKeyFP = device.pubKeyFP,
           !pubKeyFP.isEmpty,
           pubKeyFP.count == 64,
           pubKeyFP.allSatisfy({ $0.isHexDigit }),
           !selfId.pubKeyFP.isEmpty,
           selfId.pubKeyFP.count == 64,
           pubKeyFP == selfId.pubKeyFP {
            return true
        }

 // 优先级 C：MAC 地址匹配（仅 SkyBridge 来源）
        if !device.macSet.isEmpty && !selfId.macSet.isEmpty {
            let overlap = device.macSet.intersection(selfId.macSet)
            if !overlap.isEmpty {
                return true
            }
        }

        return false
    }

 /// B. 刷新后清洗：对历史缓存污染进行一次性清洗
    private func sanitizeCache(_ selfId: SelfIdentitySnapshot) async {
        for i in discoveredDevices.indices {
            var d = discoveredDevices[i]
            await applyLocalFlag(&d, selfId: selfId)
            discoveredDevices[i] = d
        }
        hardClampSingleLocal(selfId: selfId)
    }

 /// C. 周期末兜底：确保全局只有一个本机（"单机硬化"）
    private func hardClampSingleLocal(selfId: SelfIdentitySnapshot) {
        var localCount = 0
        var firstLocalIndex: Int?

        for (index, device) in discoveredDevices.enumerated() {
            if device.isLocalDevice {
                localCount += 1
                if firstLocalIndex == nil {
                    firstLocalIndex = index
                }
            }
        }

 // 如果发现多个本机，只保留第一个强匹配的
        if localCount > 1 {
            logger.warning("⚠️ 检测到多个本机设备（\(localCount)个），执行硬化清零")

            for i in discoveredDevices.indices {
                if i != firstLocalIndex {
                    discoveredDevices[i].setIsLocalDeviceByDiscovery(false)
                }
            }
        }
    }

 /// 开始广播服务
    private func startAdvertising() {
        logger.info("📡 开始广播服务")
        if let existing = listener {
            existing.cancel()
            listener = nil
        }

        Task { @MainActor in
            if await ServiceAdvertiserCenter.shared.isAdvertising("_skybridge._tcp") {
                logger.debugOnly("📡 广播中心已在运行，忽略重复启动")
                return
            }
            do {
                let snap = await SelfIdentityProvider.shared.snapshot()
                var txt = NWTXTRecord()
                txt["platform"] = "macos"
                txt["osVersion"] = ProcessInfo.processInfo.operatingSystemVersionString
                txt["name"] = self.getDeviceName()
                if !snap.deviceId.isEmpty { txt["deviceId"] = snap.deviceId }
                if !snap.pubKeyFP.isEmpty { txt["pubKeyFP"] = snap.pubKeyFP }
                txt["capabilities"] = "file,file_transfer,rdview,rdcontrol,remote_control,remote_desktop,clipboard"
                let endpoints = ServiceEndpointRegistry.shared.snapshot()
                if let transferPort = endpoints.fileTransferPort, transferPort > 0 {
                    let port = String(transferPort)
                    txt["transferPort"] = port
                    txt["fileTransferPort"] = port
                }
                if let remotePort = endpoints.remoteControlPort, remotePort > 0 {
                    let port = String(remotePort)
                    txt["remotePort"] = port
                    txt["remoteControlPort"] = port
                }
 // 通过统一广播中心启动，避免跨管理器重复监听同一服务类型
                let port = try await ServiceAdvertiserCenter.shared.startAdvertising(
                    serviceName: getDeviceName(),
                    serviceType: "_skybridge._tcp",
                    txtRecord: txt,
                    connectionHandler: { [weak self] connection in
                        Task { @MainActor in self?.handleNewConnection(connection) }
                    },
                    stateHandler: { [weak self] state in
                        Task { @MainActor in self?.handleListenerStateUpdate(state) }
                    }
                )
                if port > 0 {
                    logger.info("📡 广播服务已启动，端口: \(port, privacy: .public)")
                } else {
                    logger.info("📡 广播服务已启动（系统分配端口）")
                }
            } catch {
                logger.error("❌ 启动广播服务失败: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

 /// 停止广播服务
    private func stopAdvertising() {
        logger.info("📡 停止广播服务")
        listener?.cancel()
        listener = nil
        Task {
            await ServiceAdvertiserCenter.shared.stopAdvertising("_skybridge._tcp")
        }
    }

 /// 处理浏览器状态更新
    private func handleBrowserStateUpdate(_ state: NWBrowser.State, for serviceType: String) {
        switch state {
        case .ready:
            logger.info("🔍 浏览器就绪: \(serviceType, privacy: .public)")
        case .failed(let error):
            logger.error("❌ 浏览器失败 [\(serviceType, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
        case .cancelled:
            logger.info("⏹️ 浏览器已取消: \(serviceType, privacy: .public)")
        default:
            break
        }
    }

 /// 处理浏览结果变化 - 多服务类型
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
            case .changed(_, let new, _):
                updateDiscoveredDevice(from: new, serviceType: serviceType)
            case .identical:
                break
            @unknown default:
                break
            }
        }
    }
 /// 异步添加发现的设备（后台解析 + 主线程回填）
    private func addDiscoveredDeviceAsync(from result: NWBrowser.Result, serviceType: String) {
        Task(priority: .userInitiated) { [serviceType, weak self] in
            guard let self = self else { return }

            let deviceName = Self.DDM_ExtractDeviceName(result)
            let (ipv4, ipv6, port) = Self.DDM_ExtractNetworkInfo(result)
            let bonjourInfo = Self.DDM_ExtractBonjourDeviceInfo(result)
            var detectedDeviceType = ""
            if serviceType.contains("airplay") {
                if !deviceName.lowercased().contains("iphone") &&
                    !deviceName.lowercased().contains("ipad") {
                    detectedDeviceType = " 📱"
                }
            } else if serviceType.contains("companion-link") {
                if !deviceName.lowercased().contains("apple") {
                    detectedDeviceType = " 🍎"
                }
            }

 // 推断设备来源
            let source = self.inferSource(from: serviceType)

            var device = DiscoveredDevice(
                id: UUID(),
                name: deviceName + detectedDeviceType,
                ipv4: ipv4,
                ipv6: ipv6,
                services: [serviceType],
                portMap: [serviceType: port],
                connectionTypes: [.wifi],
                uniqueIdentifier: ipv4 ?? ipv6,
                signalStrength: nil,
                source: source,
                isLocalDevice: false  // 初始化为 false，由 applyLocalFlag 统一判定
            )
 // 获取本机身份快照
            let selfId = await SelfIdentityProvider.shared.snapshot()

 // 应用本机标志（统一写入点）
            await self.applyLocalFlag(&device, selfId: selfId)
            await MainActor.run { [self] in
                if let info = bonjourInfo, let did = info.deviceId, !did.isEmpty {
                    Self.bonjourInfoByDeviceId[did] = info
                }
                if let existingIndex = self.discoveredDevices.firstIndex(where: { existing in
                    if let existingIPv4 = existing.ipv4,
                       let newIPv4 = device.ipv4,
                       existingIPv4 == newIPv4 {
                        return true
                    }
                    if let existingIPv6 = existing.ipv6,
                       let newIPv6 = device.ipv6,
                       existingIPv6 == newIPv6 {
                        return true
                    }
                    let cleanExistingName = existing.name.filter { $0.isLetter || $0.isNumber }
                    let cleanNewName = deviceName.filter { $0.isLetter || $0.isNumber }
                    return !cleanExistingName.isEmpty && cleanExistingName == cleanNewName
                }) {
                    var existingDevice = self.discoveredDevices[existingIndex]
                    if !existingDevice.services.contains(serviceType) {
                        existingDevice.services.append(serviceType)
                        existingDevice.portMap[serviceType] = port
 // 合并后重新判定本机（异步）
                        Task { [weak self] in
                            guard let self = self else { return }
                            var updated = existingDevice
                            await self.applyLocalFlag(&updated, selfId: selfId)
                            await MainActor.run { self.discoveredDevices[existingIndex] = updated }
                        }
                        self.logger.debug("🔄 更新设备服务: \(device.name) - 新增服务: \(serviceType)")
                    }
                } else {
                    self.discoveredDevices.append(device)
                    let ipv4Str = ipv4 ?? "无"
                    let ipv6Str = ipv6 ?? "无"
                    self.logger.debugOnly("✅ 发现[\(serviceType)]: \(device.name) - IPv4: \(ipv4Str), IPv6: \(ipv6Str), 端口: \(port)")
                }
            }
        }
    }

 /// 移除设备
    private func removeDiscoveredDevice(from result: NWBrowser.Result) {
        let rawName = extractDeviceName(from: result)
        let cleanTarget = rawName.filter { $0.isLetter || $0.isNumber }

        discoveredDevices.removeAll { existing in
            let cleanExisting = existing.name.filter { $0.isLetter || $0.isNumber }
            return !cleanTarget.isEmpty && cleanExisting == cleanTarget
        }

        logger.info("设备已离线: \(rawName, privacy: .public)")
    }

 /// 更新设备信息（目前仅日志）
    private func updateDiscoveredDevice(from result: NWBrowser.Result, serviceType: String) {
        let deviceId = extractDeviceName(from: result)
        if discoveredDevices.firstIndex(where: { $0.name.contains(deviceId) }) != nil {
            let (ipv4, _, _) = extractNetworkInfo(from: result)
            logger.info("🔄 更新[\(serviceType, privacy: .public)]: \(deviceId, privacy: .public) - IPv4: \(ipv4 ?? "无")")
        }
    }

 /// 处理监听器状态更新
    private func handleListenerStateUpdate(_ state: NWListener.State) {
        switch state {
        case .ready:
            logger.info("📡 监听器就绪")
        case .failed(let error):
            logger.error("❌ 监听器失败: \(error.localizedDescription, privacy: .public)")
        case .cancelled:
            logger.info("⏹️ 监听器已取消")
        default:
            break
        }
    }

 /// 处理新连接
    private func handleNewConnection(_ connection: NWConnection) {
        logger.info("🔗 收到新连接")

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleIncomingConnectionStateUpdate(state, connection: connection)
            }
        }

        connection.start(queue: .global())
    }

 /// 处理连接状态更新（主动连接）
    private func handleConnectionStateUpdate(_ state: NWConnection.State, for deviceId: String) {
        switch state {
        case .ready:
            logger.info("✅ 连接就绪: \(deviceId, privacy: .public)")
            connectionStatus = .connected
        case .failed(let error):
            if case NWError.posix(let posixErr) = error, posixErr == .ECONNREFUSED || posixErr == .EADDRNOTAVAIL {
                logger.debug("连接失败(预期探测失败): \(deviceId, privacy: .public) - \(posixErr.rawValue)")
            } else {
                logger.error("❌ 连接失败: \(deviceId, privacy: .public), 错误: \(error.localizedDescription, privacy: .public)")
            }
            connections.removeValue(forKey: deviceId)
            connectionStatus = .failed
        case .cancelled:
            logger.info("⏹️ 连接已取消: \(deviceId, privacy: .public)")
            connections.removeValue(forKey: deviceId)
            if connections.isEmpty {
                connectionStatus = .disconnected
            }
        case .waiting:
            connectionStatus = .connecting
        default:
            break
        }
    }

 /// 处理传入连接状态更新
    private func handleIncomingConnectionStateUpdate(_ state: NWConnection.State, connection: NWConnection) {
        switch state {
        case .ready:
            logger.info("✅ 传入连接就绪")
            // iOS 端会在此连接上发起 HandshakeDriver 握手；这里必须读取并回包，否则对端必然 timeout
            // 重要：DeviceDiscoveryManager 是 @MainActor；入站读取/握手必须放到后台，
            // 否则主线程繁忙时会“只打印启用通道”但永远读不到帧。
            Task(priority: .userInitiated) {
                await Self.consumeInboundHandshakeOrControlChannel(connection)
            }
        case .failed(let error):
            if case NWError.posix(let posixErr) = error, posixErr == .ECONNREFUSED || posixErr == .EADDRNOTAVAIL {
                logger.debug("传入连接失败(预期探测失败): \(posixErr.rawValue)")
            } else {
                logger.error("❌ 传入连接失败: \(error.localizedDescription, privacy: .public)")
            }
            connection.cancel()
        case .cancelled:
            logger.info("⏹️ 传入连接已取消")
        default:
            break
        }
    }

    // MARK: - Inbound control channel (HandshakeDriver compatibility)

    nonisolated private static func stablePeerIdentifier(for endpoint: NWEndpoint) -> String {
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

    nonisolated private static func stableEndpointLabel(for endpoint: NWEndpoint) -> String {
        stablePeerIdentifier(for: endpoint)
    }

    nonisolated private static func normalizePeerHostToken(_ raw: String) -> String {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if token.hasPrefix("[") && token.hasSuffix("]") {
            token = String(token.dropFirst().dropLast())
        }
        if let pct = token.firstIndex(of: "%") {
            token = String(token[..<pct])
        }

        if token.contains(":"),
           let dot = token.lastIndex(of: "."),
           token[token.index(after: dot)...].allSatisfy({ $0.isNumber }) {
            token = String(token[..<dot])
        } else {
            let parts = token.split(separator: ".")
            if parts.count == 5,
               parts.dropLast().allSatisfy({ Int($0) != nil }),
               let port = Int(parts.last ?? ""), (0...65535).contains(port) {
                token = parts.dropLast().map(String.init).joined(separator: ".")
            }
        }

        return token.lowercased()
    }

    nonisolated private static func canonicalSOAIdentityString(_ raw: String) -> String {
        var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("id:") {
            normalized.removeFirst(3)
        }
        return normalized
    }

    nonisolated private static func soaPeerIdBytes(from raw: String) -> Data {
        let canonical = canonicalSOAIdentityString(raw)
        return Data(SHA256.hash(data: Data(canonical.utf8)))
    }

    nonisolated private static func localSOAPeerIdBytes() async -> Data {
        if #available(macOS 14.0, iOS 17.0, *) {
            let snapshot = await SelfIdentityProvider.shared.snapshot()
            if !snapshot.deviceId.isEmpty {
                return soaPeerIdBytes(from: snapshot.deviceId)
            }
        }
        return soaPeerIdBytes(from: Host.current().localizedName ?? "mac-local")
    }

    nonisolated private static func consumeInboundHandshakeOrControlChannel(_ connection: NWConnection) async {
        let logger = Logger(subsystem: "com.skybridge.Compass", category: "InboundHandshake")

        // 如果被调用时连接还没 ready，则等待短时间进入 ready（避免 race）
        if connection.state != .ready {
            logger.info("⏳ 入站连接尚未 ready，等待就绪… current=\(String(describing: connection.state), privacy: .public)")
            let becameReady = await waitUntilReady(connection, timeoutSeconds: 3.0)
            logger.info("⏳ 入站连接等待结束: ready=\(becameReady, privacy: .public) state=\(String(describing: connection.state), privacy: .public)")
        }

        let endpointDescription = stableEndpointLabel(for: connection.endpoint)

        struct DirectHandshakeTransport: DiscoveryTransport {
            let sendRaw: @Sendable (Data) async throws -> Void
            func send(to peer: PeerIdentifier, data: Data) async throws {
                try await sendRaw(data)
            }
        }

        @Sendable func sendFramed(_ data: Data) async throws {
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

        let framedReader = FramedReader.nwConnection(connection)

        let transport = DirectHandshakeTransport(sendRaw: { data in
            try await sendFramed(data)
        })

        // Use a stable peer id string aligned with iOS discovery (bonjour:<name>@<domain>) when possible.
        // This improves trust/pairing UX and ensures trust lookups don't churn across reconnects.
        let peerDeviceId = stablePeerIdentifier(for: connection.endpoint)
        let localSOAPeerId = await localSOAPeerIdBytes()
        var expectedRemoteSOAPeerId: Data?
        var inboundPairKey: Data?
        defer {
            if let inboundPairKey {
                Task {
                    await PeerSessionArbiter.shared.clearEstablished(pairKey: inboundPairKey)
                    await PeerSessionArbiter.shared.clearOutgoing(pairKey: inboundPairKey, attemptId: nil)
                }
            }
        }
        let peer = PeerIdentifier(deviceId: peerDeviceId)

        // 关键：入站 responder 不能硬编码 Classic。
        // 需要先读取 MessageA，再根据 offeredSuites 选择：
        // - sigAAlgorithm: ML-DSA-65 (PQC/Hybrid) vs Ed25519 (Classic)
        // - cryptoProvider: preferPQC vs classicOnly
        // 并使用本机稳定的身份密钥（DeviceIdentityKeyManager），而不是每次随机生成。
        var driver: HandshakeDriver?
        var sessionKeys: SessionKeys?
        var declaredDeviceIdForVerification: String?
        var lastPairingIdentityExchangeReplyAt: Date?
        var authenticatedRemoteAuthority: AuthenticatedRemoteAuthority?

        func isLikelyHandshakeControlPacket(_ data: Data) -> Bool {
            // Finished: 固定长度 38 bytes（magic 4 + version 1 + direction 1 + mac 32）
            if data.count == 38, (try? HandshakeFinished.decode(from: data)) != nil {
                return true
            }
            if (try? HandshakeMessageA.decode(from: data)) != nil { return true }
            if (try? HandshakeMessageB.decode(from: data)) != nil { return true }
            return false
        }

        func encryptAppPayload(_ plaintext: Data, with keys: SessionKeys) throws -> Data {
            let key = SymmetricKey(data: keys.sendKey)
            let sealed = try AES.GCM.seal(plaintext, using: key)
            return sealed.combined ?? Data()
        }

        func decryptAppPayload(_ ciphertext: Data, with keys: SessionKeys) throws -> Data {
            let key = SymmetricKey(data: keys.receiveKey)
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(box, using: key)
        }

        func persistAuthenticatedRemoteAuthority(
            from payload: AppMessage.PairingIdentityExchangePayload,
            displayName: String
        ) async {
            guard let authority = authenticatedRemoteAuthority else {
                logger.warning(
                    "⚠️ inbound pairingIdentityExchange missing authenticated authority; skipping current-path trust bridge: peer=\(peer.deviceId, privacy: .public) declared=\(payload.deviceId, privacy: .public)"
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
            appendKnownDeviceId(peerDeviceId)
            appendKnownDeviceId(peer.deviceId)

            do {
                let persisted = try await TrustSyncService.shared.recordAuthenticatedRemoteAuthority(
                    deviceId: peerDeviceId,
                    displayName: displayName,
                    preferredCurrentDeviceId: payload.deviceId,
                    knownDeviceIds: knownDeviceIds,
                    protocolSigningAlgorithm: authority.protocolSigningAlgorithm,
                    protocolPublicKeyFingerprint: authority.protocolPublicKeyFingerprint
                )
                guard persisted else {
                    logger.warning(
                        "⚠️ inbound current-path trust bridge skipped: peer=\(peerDeviceId, privacy: .public) declared=\(payload.deviceId, privacy: .public)"
                    )
                    return
                }
                logger.info(
                    "🔐 inbound current-path trust bridge persisted: peer=\(peerDeviceId, privacy: .public) current=\(payload.deviceId, privacy: .public) alg=\(authority.protocolSigningAlgorithm.rawValue, privacy: .public) fp=\(authority.protocolPublicKeyFingerprint, privacy: .public)"
                )
            } catch {
                logger.warning(
                    "⚠️ inbound current-path trust bridge failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        logger.info("🤝 入站连接：启用 HandshakeDriver 兼容通道（iOS 互通） endpoint=\(endpointDescription, privacy: .public) state=\(String(describing: connection.state), privacy: .public)")

        do {
            while true {
                if case .failed = connection.state { break }
                if case .cancelled = connection.state { break }
                logger.info("📥 等待入站帧（读取 4B length header）… state=\(String(describing: connection.state), privacy: .public)")
                let lenData = try await framedReader.receiveExactly(4)
                let totalLen = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
                guard totalLen > 0 && totalLen < 1_048_576 else { break }
                let payload = try await framedReader.receiveExactly(Int(totalLen))
                logger.info("📥 入站帧: \(payload.count, privacy: .public) bytes")
                // Phase C2: optional traffic padding (SBP2) — unwrap before handing to handshake driver.
                // Phase C1: optional handshake padding (SBP1) — unwrap before decoding handshake frames.
                let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx")
                let frame = HandshakePadding.unwrapIfNeeded(trafficUnwrapped, label: "rx")

                // 如果已建立会话密钥且不是握手控制包，则作为业务消息处理
                if let keys = sessionKeys, !isLikelyHandshakeControlPacket(frame) {
                    do {
                        let plaintext = try decryptAppPayload(frame, with: keys)
                        if let msg = try? JSONDecoder().decode(AppMessage.self, from: plaintext) {
                            switch msg {
                            case .pairingIdentityExchange(let payload):
                                // Pairing / trust UI prompt: Always allow / Allow once / Reject.
                                // This gates the bootstrap KEM identity exchange used for strict-PQC onboarding.
                                declaredDeviceIdForVerification = payload.deviceId
                                let endpoint = endpointDescription
                                let info = await MainActor.run { Self.bonjourInfoByDeviceId[payload.deviceId] }
                                let displayName = info?.displayName ?? info?.hostname ?? endpoint

                                await MainActor.run {
                                    PairingTrustApprovalService.shared.updateVerificationCode(
                                        declaredDeviceId: payload.deviceId,
                                        sessionKeys: keys
                                    )
                                }

                                let request = PairingTrustApprovalService.Request(
                                    peerEndpoint: endpoint,
                                    declaredDeviceId: payload.deviceId,
                                    displayName: displayName,
                                    model: info?.model ?? info?.type,
                                    platform: info?.platform,
                                    osVersion: info?.osVersion ?? info?.version,
                                    kemKeyCount: payload.kemPublicKeys.count
                                )

                                let decision = await PairingTrustApprovalService.shared.decide(for: request)
                                guard decision != PairingTrustApprovalService.Decision.reject else {
                                    logger.info("🛑 Pairing/trust request rejected (no KEM reply): deviceId=\(payload.deviceId, privacy: .public)")
                                    break
                                }

                                await PeerKEMBootstrapStore.shared.upsert(
                                    deviceIds: [payload.deviceId, peerDeviceId],
                                    kemPublicKeys: payload.kemPublicKeys
                                )
                                logger.info(
                                    "🔑 已缓存对端 KEM 公钥（bootstrap）：declared=\(payload.deviceId, privacy: .public) peer=\(peerDeviceId, privacy: .public) keys=\(payload.kemPublicKeys.count, privacy: .public)"
                                )
                                await persistAuthenticatedRemoteAuthority(
                                    from: payload,
                                    displayName: displayName
                                )

                                let now = Date()
                                guard P2PDiscoveryService.shouldSendPairingIdentityExchangeReply(
                                    lastSentAt: lastPairingIdentityExchangeReplyAt,
                                    now: now
                                ) else {
                                    logger.debug("ℹ️ pairingIdentityExchange reply rate-limited during bootstrap")
                                    break
                                }

                                // Reply with our KEM identity public keys (bootstrap for iOS initiator).
                                let provider = CryptoProviderFactory.make(policy: .preferPQC)
                                let km = DeviceIdentityKeyManager.shared
                                let kemKeys: [KEMPublicKeyInfo]
                                do {
                                    kemKeys = try await km.pairingIdentityKEMPublicKeys(using: provider)
                                } catch {
                                    logger.warning("⚠️ 本机 KEM 公钥准备失败（bootstrap reply）：\(error.localizedDescription, privacy: .public)")
                                    kemKeys = []
                                }
                                let localId = await SelfIdentityProvider.shared.snapshot().deviceId
                                let localPlatform: String = {
#if os(macOS)
                                    return "macOS"
#elseif os(iOS)
                                    return "iOS"
#else
                                    return "unknown"
#endif
                                }()
                                let localOS = ProcessInfo.processInfo.operatingSystemVersionString
                                let localName = Host.current().localizedName
                                let endpoints = ServiceEndpointRegistry.shared.snapshot()
                                let localModel: String? = {
#if os(macOS)
                                    return "Mac"
#elseif os(iOS)
                                    return UIDevice.current.model
#else
                                    return nil
#endif
                                }()
                                let reply = AppMessage.pairingIdentityExchange(.init(
                                    deviceId: localId,
                                    kemPublicKeys: kemKeys,
                                    deviceName: localName,
                                    modelName: localModel,
                                    platform: localPlatform,
                                    osVersion: localOS,
                                    chip: nil,
                                    capabilities: ["clipboard_sync", "file_transfer", "remote_desktop", "remote_control"],
                                    fileTransferPort: endpoints.fileTransferPort,
                                    remoteControlPort: endpoints.remoteControlPort
                                ))
                                let outPlain = try JSONEncoder().encode(reply)
                                let outCipher = try encryptAppPayload(outPlain, with: keys)
                                let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx")
                                try await sendFramed(outPadded)
                                lastPairingIdentityExchangeReplyAt = now
                                logger.info("🔑 已回传本机 KEM 公钥：count=\(kemKeys.count, privacy: .public) decision=\(decision.rawValue, privacy: .public)")
                            case .ping(let payload):
                                // RTT probe: respond as fast as possible with an echoed pong.
                                let reply = AppMessage.pong(.init(id: payload.id))
                                let outPlain = try JSONEncoder().encode(reply)
                                let outCipher = try encryptAppPayload(outPlain, with: keys)
                                let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx")
                                try await sendFramed(outPadded)
                            case .pong:
                                break
                            default:
                                break
                            }
                        }
                    } catch {
                        logger.debug("ℹ️ 业务消息解密/解析失败（忽略）：\(error.localizedDescription, privacy: .public)")
                    }
                    continue
                }

                // 延迟初始化：必须先看到 MessageA 才知道 offeredSuites 的分组，从而选择 sigAAlgorithm / provider
                if driver == nil {
                    if let messageA = try? HandshakeMessageA.decode(from: frame) {
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
                        let requestedPolicy = HandshakePolicy.recommendedDefault(compatibilityModeEnabled: compatibilityModeEnabled)

                        // IMPORTANT (paper-aligned legacy gating):
                        // On macOS 26+ default is strictPQC, which would reject classic-only MessageA.
                        // But iOS strictPQC onboarding requires a one-time classic bootstrap channel to provision KEM identity keys
                        // when `missingPeerKEMPublicKey` happens. Therefore, if the peer offered *only classic suites*, we MUST
                        // run the responder with a classic policy (minimumTier=classic) even when strictPQC is enabled.
                        let effectivePolicy: HandshakePolicy = {
                            if peerHasPQCGroup { return requestedPolicy }
                            if requestedPolicy.requirePQC {
                                logger.info("🧩 legacyBootstrap(inbound): strictPQC enabled but peer offered classic-only. Allowing classic bootstrap channel for KEM provisioning. peer=\(peer.deviceId, privacy: .public)")
                            }
                            return HandshakePolicy(requirePQC: false, allowClassicFallback: false, minimumTier: .classic, requireSecureEnclavePoP: false)
                        }()

                        // Choose provider first, then derive sigA/offeredSuites from local capability.
                        var selection: CryptoProviderFactory.SelectionPolicy = .classicOnly
                        var cryptoProvider: any CryptoProvider = CryptoProviderFactory.make(policy: .classicOnly)
                        var sigAAlgorithm: ProtocolSigningAlgorithm = .ed25519
                        var offeredSuites: [CryptoSuite] = cryptoProvider.supportedSuites.filter { !$0.isPQCGroup }

                        if peerHasPQCGroup {
                            selection = (effectivePolicy.requirePQC ? .requirePQC : .preferPQC)
                            cryptoProvider = CryptoProviderFactory.makeInboundPQCResponderProvider(
                                policy: selection,
                                peerSupportedSuites: messageA.supportedSuites
                            )
                            let localPQCSuites = CryptoProviderFactory.handshakeOfferedPQCSuites(using: cryptoProvider)

                            if localPQCSuites.isEmpty {
                                if effectivePolicy.requirePQC {
                                    logger.error("❌ PQC required by policy but no PQC provider available on this device. peer=\(peer.deviceId, privacy: .public)")
                                    return
                                }
	                                if peerHasClassicGroup {
	                                    selection = .classicOnly
	                                    cryptoProvider = CryptoProviderFactory.make(policy: selection)
	                                    sigAAlgorithm = .ed25519
	                                    offeredSuites = cryptoProvider.supportedSuites.filter { !$0.isPQCGroup }
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
	                                            "policyRequirePQC": effectivePolicy.requirePQC ? "1" : "0",
	                                            "policyAllowClassicFallback": effectivePolicy.allowClassicFallback ? "1" : "0",
	                                            "policyMinimumTier": effectivePolicy.minimumTier.rawValue,
	                                            "policyRequireSecureEnclavePoP": effectivePolicy.requireSecureEnclavePoP ? "1" : "0",
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
                            selection = .classicOnly
                            cryptoProvider = CryptoProviderFactory.make(policy: selection)
                            sigAAlgorithm = .ed25519
                            offeredSuites = cryptoProvider.supportedSuites.filter { !$0.isPQCGroup }
                        }

                        let identityProvider = DeviceIdentityHandshakeProvider(
                            sigAAlgorithm: sigAAlgorithm,
                            includeSecureEnclavePoP: effectivePolicy.requireSecureEnclavePoP
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
                                expectedRemoteSOAPeerId: expectedRemoteSOAPeerId
                            )
                            logger.info("🤝 入站 HandshakeDriver 初始化完成: sigA=\(sigAAlgorithm.rawValue, privacy: .public) provider=\(String(describing: type(of: cryptoProvider)), privacy: .public)")
                        } catch {
                            logger.error("❌ 入站 HandshakeDriver 初始化失败: \(error.localizedDescription, privacy: .public)")
                            return
                        }
                    } else {
                        // 如果不是 MessageA（例如 probe/噪声），直接丢给一个最小 classic driver 会引入误判。
                        // 这里选择忽略，等待下一帧 MessageA。
                        logger.debug("ℹ️ 入站首帧不是 MessageA（忽略，等待下一帧） size=\(frame.count, privacy: .public)")
                        continue
                    }
                }

                guard let driver else { continue }
                await driver.handleMessage(frame, from: peer)
                let st = await driver.getCurrentState()
                logger.info("🤝 HandshakeDriver state: \(String(describing: st), privacy: .public)")

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
                    authenticatedRemoteAuthority = await driver.getAuthenticatedRemoteAuthority()
                    sessionKeys = keys
                    if let declaredDeviceIdForVerification {
                        await MainActor.run {
                            PairingTrustApprovalService.shared.updateVerificationCode(
                                declaredDeviceId: declaredDeviceIdForVerification,
                                sessionKeys: keys
                            )
                        }
                    }
                default:
                    break
                }
            }
        } catch {
            // 连接被对端关闭 / 读取不足在真实网络环境下很常见（例如对端取消、并发探测连接等）。
            // 这里降级为 debug，避免污染正常日志与论文采集数据。
            if let framedError = error as? FramedReaderError, framedError == .peerClosed {
                logger.debug("ℹ️ 入站控制通道结束（peer closed）")
            } else if let ns = error as NSError?, ns.domain == "SkyBridgeInbound", ns.code == -1 {
                logger.debug("ℹ️ 入站控制通道结束（EOF/short read）: \(ns.localizedDescription, privacy: .public)")
            } else {
                logger.debug("ℹ️ 入站控制通道结束: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated private static func waitUntilReady(_ connection: NWConnection, timeoutSeconds: Double) async -> Bool {
        // 简易等待：轮询 state（避免额外 handler 干扰现有 handler）
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if connection.state == .ready { return true }
            if case .failed = connection.state { return false }
            if case .cancelled = connection.state { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return connection.state == .ready
    }

 /// 等待连接建立（负责设置 stateUpdateHandler + 启动连接）
    private func waitForConnection(_ connection: NWConnection, deviceId: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
 // 一旦 ready，清理 handler，避免重复 resume
                    connection.stateUpdateHandler = nil
                    let shouldResume = resumed.withLock { isResumed -> Bool in
                        guard !isResumed else { return false }
                        isResumed = true
                        return true
                    }
                    guard shouldResume else { return }
                    Task { @MainActor in
                        self?.handleConnectionStateUpdate(state, for: deviceId)
                        continuation.resume()
                    }
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    let shouldResume = resumed.withLock { isResumed -> Bool in
                        guard !isResumed else { return false }
                        isResumed = true
                        return true
                    }
                    guard shouldResume else { return }
                    Task { @MainActor in
                        self?.handleConnectionStateUpdate(state, for: deviceId)
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    let shouldResume = resumed.withLock { isResumed -> Bool in
                        guard !isResumed else { return false }
                        isResumed = true
                        return true
                    }
                    guard shouldResume else { return }
                    Task { @MainActor in
                        self?.handleConnectionStateUpdate(state, for: deviceId)
                        continuation.resume(throwing: DeviceDiscoveryError.connectionCancelled)
                    }
                default:
                    Task { @MainActor in
                        self?.handleConnectionStateUpdate(state, for: deviceId)
                    }
                }
            }

            let connectionQueue = DispatchQueue(label: "com.skybridge.discovery.connection", qos: .utility)
            connection.start(queue: connectionQueue)

            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                let shouldResume = resumed.withLock { isResumed -> Bool in
                    guard !isResumed else { return false }
                    isResumed = true
                    return true
                }
                guard shouldResume else { return }
                connection.stateUpdateHandler = nil
                connection.cancel()
                await MainActor.run {
                    continuation.resume(throwing: DeviceDiscoveryError.connectionTimeout)
                }
            }
        }
    }

 /// 获取设备名称
    private func getDeviceName() -> String {
        return Host.current().localizedName ?? "SkyBridge设备"
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
            if family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                    let data = Data(bytes: hostname, count: hostname.count)
                    let trimmed = data.prefix { $0 != 0 }
                    let ip = String(decoding: trimmed, as: UTF8.self)
                    if ip == address { return true }
                }
            }
        }
        return false
    }

 /// 从结果中提取设备名称
    private func extractDeviceName(from result: NWBrowser.Result) -> String {
        var deviceName = "未知设备"

        if case .service(let name, _, _, _) = result.endpoint {
            deviceName = name

            let metadata = result.metadata
            if case .bonjour(let txtRecord) = metadata {
                let deviceInfo = BonjourTXTParser.extractDeviceInfo(txtRecord)

                if let friendlyName = deviceInfo.name ?? deviceInfo.hostname {
                    deviceName = friendlyName
                }

                if let deviceType = deviceInfo.type ?? deviceInfo.model {
                    deviceName += " (\(deviceType))"
                }
            }

            deviceName = cleanDeviceName(deviceName)
            if DDM_IsProbablyLocalDevice(name: deviceName, ipv4: nil, ipv6: nil) {
                let localName = Host.current().localizedName ?? deviceName
                deviceName = cleanDeviceName(localName) + " (本机)"
            }
        }

        logger.info("提取设备名称: \(deviceName, privacy: .public)")
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

 /// 从 IP 地址反向解析主机名（目前未在业务流程中使用，可保留做调试）
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
        if getnameinfo(addressPtr, socklen_t(resolved.pointee.ai_addrlen),
                       &hostname, socklen_t(hostname.count),
                       nil, 0, NI_NAMEREQD) == 0 {
            let bytes = Data(bytes: hostname, count: hostname.count)
            let trimmed = bytes.prefix { $0 != 0 }
            return String(decoding: trimmed, as: UTF8.self)
        }

        return nil
    }

 /// 从结果中提取网络信息（IPv4 / IPv6 / 端口）
    private func extractNetworkInfo(from result: NWBrowser.Result) -> (ipv4: String?, ipv6: String?, port: Int) {
        var ipv4: String?
        var ipv6: String?
        var port: Int = 0

 // 方法 1: 使用 NetService 解析端口 + 地址（当 endpoint 为 service 时）
        if case .service(let name, let type, let domain, _) = result.endpoint {
            let netService = NetService(domain: domain.isEmpty ? "local." : domain,
                                        type: type,
                                        name: name)
            netService.resolve(withTimeout: 1.0)

            if netService.port > 0 {
                port = netService.port
            }

            if let addresses = netService.addresses, (ipv4 == nil || ipv6 == nil) {
                for addressData in addresses {
                    let address = extractIPAddress(from: addressData)
                    if address.contains("."),
                       !address.starts(with: "169.254"),
                       !address.starts(with: "127."),
                       ipv4 == nil {
                        ipv4 = address
                    } else if address.contains(":"), !address.starts(with: "fe80:"), ipv6 == nil {
                        ipv6 = address
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

            if name == interfaceName || name.hasPrefix("en") || name.hasPrefix("awdl") {
                let addr = addressPtr.pointee

                if addr.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addressPtr, socklen_t(addr.sa_len),
                                   &hostname, socklen_t(hostname.count),
                                   nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                        let data = Data(bytes: hostname, count: hostname.count)
                        let trimmed = data.prefix { $0 != 0 }
                        let address = String(decoding: trimmed, as: UTF8.self)
                        if !address.starts(with: "169.254") && !address.starts(with: "127.") {
                            ipv4 = address
                        }
                    }
                } else if addr.sa_family == UInt8(AF_INET6) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addressPtr, socklen_t(addr.sa_len),
                                   &hostname, socklen_t(hostname.count),
                                   nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                        let data = Data(bytes: hostname, count: hostname.count)
                        let trimmed = data.prefix { $0 != 0 }
                        let address = String(decoding: trimmed, as: UTF8.self)
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

 /// 从地址数据中提取 IP 字符串
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

// MARK: - 辅助函数（后台解析用）

/// 解析 TXT 记录（已废弃，使用统一解析器）
@available(*, deprecated, message: "Use BonjourTXTParser.parse instead")
nonisolated private static func DDM_ParseTXTRecord(_ txtRecord: NWTXTRecord) -> [String: String]? {
    let dict = BonjourTXTParser.parse(txtRecord)
    return dict.isEmpty ? nil : dict
}

nonisolated private static func DDM_CleanDeviceName(_ name: String) -> String {
    var cleaned = name
    cleaned = cleaned.replacingOccurrences(of: "._tcp", with: "")
    cleaned = cleaned.replacingOccurrences(of: "._udp", with: "")
    cleaned = cleaned.replacingOccurrences(of: ".local", with: "")
    cleaned = cleaned.trimmingCharacters(in: .whitespaces)
    if cleaned.count > 50 { cleaned = String(cleaned.prefix(47)) + "..." }
    return cleaned
}

nonisolated private static func DDM_ExtractDeviceName(_ result: NWBrowser.Result) -> String {
    var deviceName = "未知设备"
    if case .service(let name, _, _, _) = result.endpoint {
        deviceName = name
        let metadata = result.metadata
        if case .bonjour(let txtRecord) = metadata {
            let info = BonjourTXTParser.extractDeviceInfo(txtRecord)
            if let friendly = info.name ?? info.hostname { deviceName = friendly }
            if let model = info.type ?? info.model { deviceName += " (\(model))" }
        }
        deviceName = DDM_CleanDeviceName(deviceName)
        if DDM_IsProbablyLocalDevice(name: deviceName, ipv4: nil, ipv6: nil) { deviceName += " (本机)" }
    }
    return deviceName
}

nonisolated private static func DDM_ExtractBonjourDeviceInfo(_ result: NWBrowser.Result) -> BonjourDeviceInfo? {
    let metadata = result.metadata
    guard case .bonjour(let txtRecord) = metadata else { return nil }
    return BonjourTXTParser.extractDeviceInfo(txtRecord)
}

    nonisolated private static func DDM_GetIPAddressesForInterface(_ interfaceName: String) -> (ipv4: String?, ipv6: String?)? {
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

nonisolated private static func DDM_ExtractIPAddress(from data: Data) -> String {
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

nonisolated private static func DDM_ExtractNetworkInfo(_ result: NWBrowser.Result) -> (ipv4: String?, ipv6: String?, port: Int) {
    var ipv4: String?
    var ipv6: String?
    var port: Int = 0
    if case .service(let name, let type, let domain, _) = result.endpoint, port == 0 {
        let netService = NetService(domain: domain.isEmpty ? "local." : domain, type: type, name: name)
        netService.resolve(withTimeout: 1.0)
        if netService.port > 0 { port = netService.port }
        if let addresses = netService.addresses, (ipv4 == nil || ipv6 == nil) {
            for data in addresses {
                let addr = DDM_ExtractIPAddress(from: data)
                if addr.contains("."), !addr.starts(with: "169.254"), !addr.starts(with: "127."), ipv4 == nil { ipv4 = addr }
                else if addr.contains(":"), !addr.starts(with: "fe80:"), ipv6 == nil { ipv6 = addr }
            }
        }
    }
    return (ipv4, ipv6, port)
}
}

// MARK: - 数据模型

/// 网络发现的设备（内部使用，当前未实际用到，可做调试扩展）
internal struct NetworkDiscoveredDevice: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let endpoint: NWEndpoint
    public var metadata: NWTXTRecord?
    public let discoveredAt: Date
    public var lastSeen: Date = Date()

    public init(id: String,
                name: String,
                endpoint: NWEndpoint,
                metadata: NWTXTRecord?,
                discoveredAt: Date) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.metadata = metadata
        self.discoveredAt = discoveredAt
    }
}

/// 设备发现连接状态
public enum DeviceDiscoveryConnectionStatus: String, CaseIterable {
    case disconnected = "未连接"
    case connecting = "连接中"
    case connected = "已连接"
    case reconnecting = "重连中"
    case failed = "连接失败"
    case timeout = "连接超时"

    public var displayName: String {
        rawValue
    }
}

/// 设备发现错误
public enum DeviceDiscoveryError: Error, LocalizedError {
    case deviceNotConnected
    case connectionCancelled
    case scanningFailed
    case connectionTimeout

    public var errorDescription: String? {
        switch self {
        case .deviceNotConnected:
            return "设备未连接"
        case .connectionCancelled:
            return "连接已取消"
        case .scanningFailed:
            return "扫描失败"
        case .connectionTimeout:
            return "连接超时"
        }
    }
}
 /// 判断是否为本机设备（严格匹配，文件级辅助）：优先按IP命中，其次按规范化名称精确相等
    fileprivate func DDM_IsProbablyLocalDevice(name: String, ipv4: String?, ipv6: String?) -> Bool {
 // 1) IP 检查：与本机任一接口的地址完全相等
        func localIPSet() -> Set<String> {
            var set: Set<String> = []
            var ifaddr: UnsafeMutablePointer<ifaddrs>?
            if getifaddrs(&ifaddr) == 0 {
                var ptr = ifaddr
                while ptr != nil {
                    defer { ptr = ptr?.pointee.ifa_next }
                    guard let interface = ptr?.pointee, let sa = interface.ifa_addr else { continue }
                    let fam = sa.pointee.sa_family
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if fam == UInt8(AF_INET) || fam == UInt8(AF_INET6) {
                        if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                            let data = Data(bytes: buf, count: buf.count)
                            let trimmed = data.prefix { $0 != 0 }
                            let ip = String(decoding: trimmed, as: UTF8.self)
                            if !ip.isEmpty { set.insert(ip) }
                        }
                    }
                }
                freeifaddrs(ifaddr)
            }
            return set
        }
        let locals = localIPSet()
        if let v4 = ipv4, locals.contains(v4) { return true }
        if let v6 = ipv6, locals.contains(v6) { return true }
 // 2) 名称严格相等（规范化后比较），避免 substring 误判
        func norm(_ s: String) -> String {
            return s.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        }
        let localName = Host.current().localizedName ?? ""
        if !localName.isEmpty, norm(name) == norm(localName) { return true }
        return false
    }
