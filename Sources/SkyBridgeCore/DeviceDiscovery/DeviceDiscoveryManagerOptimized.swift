// DEDUPLICATION TARGET — not inherently macOS-only.
//
// macOS 侧的发现/连接编排实现。iOS 目前有自己的一份（DeviceDiscoveryManager (iOS)），阶段 0 只让
// SkyBridgeCore 能为 iOS 编译，不在同一二进制里立起第二套实现。采用 iOS 版本是
// 阶段 3 的逐类型迁移工作，记录在 Docs/background-wake-capability-ledger.md。
#if os(macOS)
import Foundation
import Network
import OSLog
import Combine
import CryptoKit
import os
import Security
import UserNotifications
import SkyBridgeProtocolCore

#if canImport(SkyBridgeCore)
// 当作为模块导入时
#else
// 当在同一模块内时
#endif

/// 2025年10月最新：高性能设备发现管理器
/// 优化重点：
/// 1. 所有网络操作在后台队列执行
/// 2. DNS解析异步化
/// 3. 批量UI更新而非实时更新
/// 4. 使用actor隔离并发操作
@MainActor
public class DeviceDiscoveryManagerOptimized: ObservableObject {
    nonisolated private static let protocolIdentityLogRedaction = "<redacted>"

    private struct ResolvedBonjourService: Sendable {
        let port: Int
        let ipv4: String?
        let ipv6: String?
        let rawTXTData: Data?
    }

    private struct ValidatedBrowseMetadata: Sendable {
        let deviceId: String?
        let protocolPublicKeyFingerprint: String?
        let deviceInfo: BonjourDeviceInfo?
        let networkLinkStatus: DeviceNetworkLinkStatus?
    }

    private enum BonjourResolveError: Error {
        case timeout
        case failed([String: NSNumber])
    }

    private final class BonjourServiceResolveContext: NSObject, NetServiceDelegate, @unchecked Sendable {
        private let resumed = OSAllocatedUnfairLock(initialState: false)
        private let service: NetService
        private let timeoutSeconds: TimeInterval
        private let continuation: CheckedContinuation<ResolvedBonjourService, Error>
        private var timeoutTask: Task<Void, Never>?
        private var selfRetain: BonjourServiceResolveContext?

        init(
            service: NetService,
            timeoutSeconds: TimeInterval,
            continuation: CheckedContinuation<ResolvedBonjourService, Error>
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
                do {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                } catch is CancellationError {
                    return
                } catch {
                    self.finish(.failure(error))
                    return
                }
                self.finish(.failure(BonjourResolveError.timeout))
            }
        }

        func netServiceDidResolveAddress(_ sender: NetService) {
            let port = max(0, sender.port)
            var foundIPv4: String?
            var foundIPv6: String?

            for data in sender.addresses ?? [] {
                let address = DeviceDiscoveryManagerOptimized.extractIPAddress(from: data)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard !address.isEmpty else { continue }
                if address.contains("."), !address.hasPrefix("169.254"), !address.hasPrefix("127."), foundIPv4 == nil {
                    foundIPv4 = address
                } else if address.contains(":"), !address.hasPrefix("fe80:"), foundIPv6 == nil {
                    foundIPv6 = address
                }
            }

            finish(.success(ResolvedBonjourService(
                port: port,
                ipv4: foundIPv4,
                ipv6: foundIPv6,
                rawTXTData: sender.txtRecordData()
            )))
        }

        func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
            finish(.failure(BonjourResolveError.failed(errorDict)))
        }

        private func finish(_ result: Result<ResolvedBonjourService, Error>) {
            let shouldResume = resumed.withLock { isResumed -> Bool in
                guard !isResumed else { return false }
                isResumed = true
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

 // MARK: - 发布的属性

    @Published public var discoveredDevices: [DiscoveredDevice] = []
    @Published public var connectionStatus: DeviceDiscoveryConnectionStatus = .disconnected
 /// 加密状态（TLS版本），用于UI展示
    @Published public var encryptionStatus: String? = nil
 /// TLS握手详情（协议版本与密码套件），用于UI展示
 /// 中文说明：当启用TLS时，尝试在握手阶段通过验证回调获取协议与cipher suite，并发布到UI。
    @Published public var tlsHandshakeDetails: TLSHandshakeDetails? = nil
    @Published public var isScanning: Bool = false
 // MARK: - 私有属性

    private let logger = Logger(subsystem: "com.skybridge.discovery.optimized", category: "Performance")

 // 使用专用的高优先级并发队列
    private let discoveryQueue = DispatchQueue(
        label: "com.skybridge.discovery.optimized",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private var browsers: [NWBrowser] = []
    /// 浏览失败（通常是缺少 NSBonjourServices 条目导致的 mDNSResponder 策略拒绝 -65555）后
    /// 记录的非核心服务类型，后续不再重建其浏览器，避免无限 churn 拖垮主线程与电量。
    private var knownUnsupportedServiceTypes: Set<String> = []
    private var connections: [String: NWConnection] = [:]

 // 使用 actor 来管理设备缓存，避免数据竞争
    private let deviceCache = DeviceCache()

 // 批量更新控制（事件驱动 + 防抖）
    private var flushTask: Task<Void, Never>?
 /// 统一身份解析器，用于设备指纹生成与合并决策。
    private let identityResolver = IdentityResolver()
 /// 外部候选指纹提供者（例如来自 DeviceDiscoveryService 的 SSDP/ARP/HTTP 指纹聚合）。
    private var fingerprintProvider: (@Sendable (DiscoveredDevice) async -> IdentityFingerprint?)?
    private var pendingUpdates: Set<DiscoveredDevice> = []

    /// 最近被 `.removed` 浏览事件移除的设备身份及其时间戳，用于在短 TTL 内压制
    /// 在途 detached 解析 Task 把已移除设备重新插回 pendingUpdates 导致的“幽灵设备”。
    /// key = 有稳定 deviceId 时为该 id，否则为 "name:" + 清洗后的名称。仅在 @MainActor 上读写。
    private var recentlyRemovedIdentities: [String: Date] = [:]
    private let removedTTL: TimeInterval = 5.0

    /// Backoff gate for the local identity authority resolution performed by every
    /// discovery batch. Bonjour result changes arrive per TXT/endpoint mutation, so an
    /// unthrottled retry after a resolution failure replays the full Keychain lookup
    /// per event. On macOS that is user-visible as a Keychain authorization panel storm.
    /// The batch still fails closed; only the retry rate is bounded.
    private var identityResolutionFailureCount: Int = 0
    private var identityResolutionRetryNotBefore: Date?
    nonisolated private static let identityResolutionBackoffSchedule: [TimeInterval] = [2, 5, 15, 30, 60]
    private var primaryControlResolveCooldown: [String: Date] = [:]
    private let primaryControlResolveCooldownTTL: TimeInterval = 10.0

 // USB设备管理器
    private var usbManager: USBCConnectionManager?
    private var usbCancellable: AnyCancellable?
    /// Network discovery owns network-reachable endpoints. USB presence is owned by
    /// UnifiedOnlineDeviceManager so it cannot overwrite Bonjour identity or ports.
    public var publishesUSBPresenceInDiscoveredDevices = false

 // 服务类型瘦身 - 默认仅SkyBridge，兼容/调试模式可扩展其余类型
    // 服务类型分类 - 核心服务（默认扫描）
    private let coreServiceTypes = [
        BonjourInteropContract.controlServiceType,
        BonjourInteropContract.fileTransferServiceType,
        BonjourInteropContract.remoteControlServiceType,
        "_companion-link._tcp",
        "_airplay._tcp",
        "_rdlink._tcp",
        "_sftp-ssh._tcp",
        "_smb._tcp",
        "_afpovertcp._tcp",
        "_device-info._tcp",
        "_android._tcp"
    ]

 // 扩展服务类型（仅在兼容模式下启用）
    private let extendedServiceTypes = [
        "_printer._tcp",
        "_ipp._tcp",
        "_http._tcp",
        "_rtsp._tcp",
        "_googlecast._tcp",
        "_hap._tcp",     // HomeKit
        "_matter._tcp",  // Matter
        "_sleep-proxy._udp",
        "_raop._tcp",
        "_workstation._tcp"
    ]

 /// 兼容模式开关（默认关闭）；可选启用 companion-link
    public var enableCompatibilityMode: Bool = false
    public var enableCompanionLink: Bool = false

 /// IPv6 支持开关（从 SettingsManager 同步）
    public var enableIPv6Support: Bool = false {
        didSet {
            let enabled = enableIPv6Support
            logger.info("🌐 IPv6 支持已\(enabled ? "启用" : "禁用")")
        }
    }

 /// 新发现算法开关（从 SettingsManager 同步）
 /// 新算法使用并行扫描 + 智能去重 + 指纹优先匹配
    public var useNewDiscoveryAlgorithm: Bool = false {
        didSet {
            let useNew = useNewDiscoveryAlgorithm
            logger.info("🔬 发现算法已切换为: \(useNew ? "新算法(并行+指纹)" : "经典算法")")
        }
    }

    public var enableBonjourDiscovery: Bool = true
    public var enableMDNSResolution: Bool = true
    public var scanCustomPorts: Bool = false
    public var customServiceTypes: [String] = []
    public var discoveryTimeout: Int = 30

    public func applyRuntimeSettings(
        compatibilityMode: Bool,
        companionLink: Bool,
        ipv6Support: Bool,
        useNewDiscoveryAlgorithm: Bool,
        enableBonjourDiscovery: Bool = true,
        enableMDNSResolution: Bool = true,
        scanCustomPorts: Bool = false,
        customServiceTypes: [String] = [],
        discoveryTimeout: Int = 30,
        restartIfNeeded: Bool = true
    ) {
        let normalizedCustomServiceTypes = Self.normalizedCustomServiceTypes(customServiceTypes)
        let normalizedDiscoveryTimeout = max(1, discoveryTimeout)
        let serviceTypesWillChange =
            self.enableCompatibilityMode != compatibilityMode ||
            self.enableCompanionLink != companionLink ||
            self.useNewDiscoveryAlgorithm != useNewDiscoveryAlgorithm ||
            self.enableBonjourDiscovery != enableBonjourDiscovery ||
            self.enableMDNSResolution != enableMDNSResolution ||
            self.scanCustomPorts != scanCustomPorts ||
            self.customServiceTypes != normalizedCustomServiceTypes
        let wasScanning = isScanning

        self.enableCompatibilityMode = compatibilityMode
        self.enableCompanionLink = companionLink
        self.enableIPv6Support = ipv6Support
        self.useNewDiscoveryAlgorithm = useNewDiscoveryAlgorithm
        self.enableBonjourDiscovery = enableBonjourDiscovery
        self.enableMDNSResolution = enableMDNSResolution
        self.scanCustomPorts = scanCustomPorts
        self.customServiceTypes = normalizedCustomServiceTypes
        self.discoveryTimeout = normalizedDiscoveryTimeout

        guard restartIfNeeded, wasScanning, serviceTypesWillChange else { return }
        logger.info("🔄 发现运行时设置改变，重建 Bonjour 浏览器集合")
        stopScanning()
        startScanning()
    }

    private func effectiveServiceTypes() -> [String] {
        guard enableBonjourDiscovery else { return [] }

 // 1. 基础核心服务
        var types = coreServiceTypes

 // 2. 如果未启用 Companion Link，移除相关服务（虽然 core 中包含，这里做个双重检查或过滤）
        if !enableCompanionLink {
            types.removeAll { $0 == "_companion-link._tcp" }
        }

 // 3. 兼容模式下添加扩展服务
        if enableCompatibilityMode {
            types.append(contentsOf: extendedServiceTypes)
        }

        if scanCustomPorts {
            types.append(contentsOf: customServiceTypes)
        }

        // 排除已知不可浏览的服务类型，避免对其反复重建浏览器。
        return Array(Set(types).subtracting(knownUnsupportedServiceTypes)).sorted()
    }

    private static func normalizedCustomServiceTypes(_ rawValues: [String]) -> [String] {
        let normalized = rawValues.compactMap { rawValue -> String? in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("_"),
                  value.contains("._tcp") || value.contains("._udp") else {
                return nil
            }
            return value
        }
        return Array(Set(normalized)).sorted()
    }
    private let serviceDomain = "local."

    public init() {
        logger.info("🚀 初始化高性能设备发现管理器")

 // 初始化USB管理器
        setupUSBManager()
    }

 /// 设置USB设备管理器
    private func setupUSBManager() {
        usbManager = USBCConnectionManager()

 // 订阅USB设备变化
        usbCancellable = usbManager?.$discoveredUSBDevices
            .sink { [weak self] usbDevices in
                Task { @MainActor [weak self] in
                    await self?.handleUSBDevicesUpdate(usbDevices)
                }
            }
    }

 /// 处理USB设备更新
    private func handleUSBDevicesUpdate(_ usbDevices: [USBDeviceInfo]) async {
        logger.info("🔌 收到USB设备更新，共 \(usbDevices.count) 台设备")
        guard publishesUSBPresenceInDiscoveredDevices else {
            logger.debug("↪️ USB presence 由 UnifiedOnlineDeviceManager 合并，网络发现器不发布 USB-only 设备")
            return
        }

        for usbDevice in usbDevices {
 // 将USB设备转换为DiscoveredDevice
            let discoveredDevice = convertUSBDeviceToDiscoveredDevice(usbDevice)

 // 直接添加到待处理更新队列（会被批量刷新机制处理，包含去重逻辑）
            pendingUpdates.insert(discoveredDevice)
            scheduleFlush()

            logger.info("✅ 添加USB设备到发现列表: \(discoveredDevice.name)")
        }
    }

 /// 将USB设备信息转换为DiscoveredDevice
    private func convertUSBDeviceToDiscoveredDevice(_ usbDevice: USBDeviceInfo) -> DiscoveredDevice {
        return DiscoveredDevice(
            id: UUID(),
            name: usbDevice.name,
            ipv4: nil, // USB设备没有IP地址
            ipv6: nil,
            // USB capability（例如“高速”）不是 Bonjour service type，不能写入 services；
            // 否则连接层会把它当成 NWEndpoint.service(type:)，触发非法端点构造。
            services: [],
            portMap: [:],
            connectionTypes: [.usb],
            uniqueIdentifier: Self.usbPresenceIdentifier(
                serialNumber: usbDevice.serialNumber,
                deviceID: usbDevice.deviceID
            ),
            signalStrength: nil,
            source: .skybridgeUSB,  // USB 设备来源
            isLocalDevice: false  // 初始化为 false，由 applyLocalFlag 统一判定
        )
    }

 // MARK: - 公共方法

 /// 开始扫描 - 完全异步化
    public func startScanning() {
        guard !isScanning else {
            logger.debug("startScanning() 忽略：已经在扫描中")
            return
        }
        logger.info("🔍 开始高性能网络扫描")
        isScanning = true

 // 改为事件驱动 + 防抖，无需定时器

 // 在后台并发启动所有浏览器
        Task(priority: .userInitiated) { [weak self] in
            await self?.startBrowsersConcurrently()
        }

        // `_skybridge._tcp` advertising and its authenticated inbound handler
        // are owned exclusively by P2PDiscoveryService. This manager only browses.

        if publishesUSBPresenceInDiscoveredDevices {
 // Legacy opt-in only. The normal path keeps USB presence out of network discoveredDevices.
            Task { @MainActor [weak self] in
                await self?.scanUSBDevices()
            }
        }
    }

 /// 去重门闩：仅在未运行时启动扫描，避免重复 start
    public func startScanningIfNeeded() {
        if isScanning {
            logger.debug("startScanningIfNeeded() 忽略：已在扫描")
            return
        }
        startScanning()
    }

 /// 去重门闩：仅在运行时停止扫描，避免重复 stop
    public func stopScanningIfNeeded() {
        if !isScanning {
            logger.debug("stopScanningIfNeeded() 忽略：未在扫描")
            return
        }
        stopScanning()
    }

 /// 扫描USB设备
    private func scanUSBDevices() async {
        logger.info("🔌 开始扫描USB设备")

        guard let usbManager = usbManager else {
            logger.warning("⚠️ USB管理器未初始化")
            return
        }

 // 触发USB设备扫描。MFi/ExternalAccessory 扫描需要用户显式入口，避免通用发现路径在启动或连接时触发隐私/TCC框架。
        await usbManager.scanForUSBDevices()

        logger.info("✅ USB设备扫描完成")
    }

 /// 停止扫描
    public func stopScanning() {
        logger.info("⏹️ 停止扫描")
        isScanning = false

 // 取消防抖任务
        flushTask?.cancel()
        flushTask = nil

 // 取消所有浏览器（在后台）
        Task { [weak self] in
            guard let self = self else { return }
            await MainActor.run {
                for browser in self.browsers {
                    browser.cancel()
                }
                self.browsers.removeAll()
 // 扫描停止后清空已发布的设备列表，避免下游读取到已不再广播的陈旧路由
                self.discoveredDevices.removeAll()
            }
        }

 // 扫描结束后清洗缓存，确保本机唯一性
        Task { [weak self] in
            let selfId = await SelfIdentityProvider.shared.presentationSnapshot()
            await MainActor.run {
                self?.sanitizeCache(selfId)
            }
        }
    }

 /// 连接到设备 - 完全异步
 /// 根据 enableIPv6Support 设置决定是否优先使用 IPv6 地址
    public func connectToDevice(_ device: DiscoveredDevice) async throws {
        logger.info("连接设备: \(device.name)")

 // 根据 IPv6 设置选择地址；若地址缺失，则仅在拥有可信 Bonjour 实例名时回退到 service endpoint。
        let endpoint: NWEndpoint
        let serverNameForTLS: String
        let portInt = resolvedConnectablePort(for: device)

        if enableIPv6Support, let ipv6 = Self.sanitizedConnectableAddress(device.ipv6) {
            guard portInt > 0 else { throw DeviceDiscoveryError.scanningFailed }
            let port = NWEndpoint.Port(integerLiteral: UInt16(portInt))
            endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(ipv6), port: port)
            serverNameForTLS = ipv6
            logger.info("🌐 使用 IPv6 地址连接: \(ipv6)")
        } else if let ipv4 = Self.sanitizedConnectableAddress(device.ipv4) {
            guard portInt > 0 else { throw DeviceDiscoveryError.scanningFailed }
            let port = NWEndpoint.Port(integerLiteral: UInt16(portInt))
            endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(ipv4), port: port)
            serverNameForTLS = ipv4
            logger.info("🌐 使用 IPv4 地址连接: \(ipv4)")
        } else if let serviceType = resolvedConnectableServiceType(for: device),
                  let bonjourEndpoint = Self.preferredBonjourEndpoint(for: device, defaultDomain: serviceDomain) {
            endpoint = .service(
                name: bonjourEndpoint.name,
                type: serviceType,
                domain: bonjourEndpoint.domain,
                interface: nil
            )
            serverNameForTLS = "\(bonjourEndpoint.name).\(bonjourEndpoint.domain)"
            logger.info("🌐 使用 Bonjour 服务连接: \(bonjourEndpoint.name) \(serviceType)")
        } else {
            logger.error(
                "❌ 无法为设备解析有效连接目标: name=\(device.name, privacy: .public) uniqueId=\(device.uniqueIdentifier ?? "", privacy: .public) ipv4=\(device.ipv4 ?? "", privacy: .public) ipv6=\(device.ipv6 ?? "", privacy: .public)"
            )
            throw DeviceDiscoveryError.deviceNotConnected
        }

        let isSkyBridgeControlChannel = isSkyBridgeControlDevice(device)
 // 应用TLS配置（统一近距加密策略）
        let net = RemoteDesktopSettingsManager.shared.settings.networkSettings
        var connection: NWConnection
        if isSkyBridgeControlChannel {
            // SkyBridge 控制通道使用应用层握手加密；传输层固定纯 TCP，避免 iOS 端 length-framed 通道出现 TLS 头错配。
            encryptionStatus = "应用层握手加密"
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            params.allowLocalEndpointReuse = true
            if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.enableKeepalive = true
                tcpOptions.keepaliveIdle = 30
                tcpOptions.keepaliveInterval = 15
                tcpOptions.keepaliveCount = 4
            }
            connection = NWConnection(to: endpoint, using: params)
        } else if net.enableEncryption, let tls = TLSConfigurator.options(for: net.encryptionAlgorithm) {
            let tcp = NWProtocolTCP.Options()
            let params = NWParameters(tls: tls, tcp: tcp)
            if SettingsManager.shared.enablePQCHybridTLS {
 // 启用TLS混合协商能力检测（实际协商结果在verify_block中记录并发布到UI）
                logger.info("🔐 启用TLS混合协商能力检测")
                encryptionStatus = "TLS (hybrid candidate)"
            } else {
                encryptionStatus = "TLS"
            }
 // 设置SNI（Server Name Indication），使用目标地址/服务名作为服务器名称
 // 中文说明：SNI用于服务器选择证书；在隐私诊断开启时也用于展示。
            serverNameForTLS.withCString { cstr in
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, cstr)
            }
 // 在TLS握手验证回调中提取握手元数据（版本与cipher）
 // 中文说明：verify_block 在握手期间被调用，我们在此解析 sec_protocol_metadata 以便 UI 展示。
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] metadata, trust, complete in
 // 提取协议版本（macOS 14 API：获取TLS协商版本）
                let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata)
 // 提取密码套件
                let cipher = sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata)
 // 可选采集：ALPN与SNI，仅当开启隐私诊断时
                var negotiatedALPN: String? = nil
                if SettingsManager.shared.enableHandshakeDiagnostics {
                    if let alpnC = sec_protocol_metadata_get_negotiated_protocol(metadata) {
 // 统一采用 UTF8 解码替代已弃用的 String(cString:)
                negotiatedALPN = decodeCString(alpnC)
                    }
                }
                let details = TLSHandshakeDetails(
                    protocolVersion: TLSHandshakeDetails.string(from: version),
                    cipherSuite: TLSHandshakeDetails.string(from: cipher),
                    alpn: negotiatedALPN,
                    sni: SettingsManager.shared.enableHandshakeDiagnostics ? serverNameForTLS : nil
                )
                Task { @MainActor in
                    self?.tlsHandshakeDetails = details
 // 同时更新UI加密状态，便于与 TLSSecurityManager 统计一致
                    self?.encryptionStatus = [details.protocolVersion, details.cipherSuite].joined(separator: " ")
                    NotificationCenter.default.post(name: Notification.Name("TLSHandshakeDetailsUpdated"), object: self, userInfo: [
                        "version": details.protocolVersion,
                        "cipher": details.cipherSuite,
                        "alpn": details.alpn ?? ""
                    ])
                }

 // 证书链基础验证（若系统策略允许）
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                var error: CFError?
                let ok = SecTrustEvaluateWithError(secTrust, &error)
 // 若验证失败，这里仍允许连接（近距场景可由用户信任策略控制）；如需强制，可改为 complete(false)
                complete(ok)
            }, .main)
            encryptionStatus = net.encryptionAlgorithm.displayName
            if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.enableKeepalive = true
                tcpOptions.keepaliveIdle = 30
                tcpOptions.keepaliveInterval = 15
                tcpOptions.keepaliveCount = 4
            }
            connection = NWConnection(to: endpoint, using: params)
        } else {
            encryptionStatus = "不加密"
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            params.allowLocalEndpointReuse = true
            if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.enableKeepalive = true
                tcpOptions.keepaliveIdle = 30
                tcpOptions.keepaliveInterval = 15
                tcpOptions.keepaliveCount = 4
            }
            connection = NWConnection(to: endpoint, using: params)
        }
        let connKey = device.id.uuidString
 // 若同一设备已有在途连接，先解除其 handler 再取消，避免：
 // 1) 旧 NWConnection 失去唯一引用却未 cancel（保活 TCP socket 泄漏）；
 // 2) 旧 handler 的 .cancelled 回调异步 removeValue 误删新写入的条目。
        if let old = connections[connKey] {
            old.stateUpdateHandler = nil
            old.cancel()
        }
        connections[connKey] = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionStateUpdate(state, for: device.id.uuidString)
            }
        }

 // 在后台队列启动连接
        connection.start(queue: discoveryQueue)

        try await waitForConnection(connection)
        logger.info("✅ 连接成功: \(device.name)")
    }

    private func isSkyBridgeControlDevice(_ device: DiscoveredDevice) -> Bool {
        device.services.contains("_skybridge._tcp")
            || device.services.contains(BonjourInteropContract.remoteControlServiceType)
            || device.services.contains(BonjourInteropContract.legacyRemoteControlServiceType)
            || device.services.contains("_skybridge._udp")
            || device.portMap["_skybridge._tcp"] != nil
            || device.portMap[BonjourInteropContract.remoteControlServiceType] != nil
            || device.portMap[BonjourInteropContract.legacyRemoteControlServiceType] != nil
            || device.portMap["_skybridge._udp"] != nil
    }

    private func resolvedConnectablePort(for device: DiscoveredDevice) -> Int {
        if let port = device.portMap[BonjourInteropContract.remoteControlServiceType]
            ?? device.portMap[BonjourInteropContract.legacyRemoteControlServiceType], port > 0 {
            return port
        }
        if let port = device.portMap["_skybridge._tcp"], port > 0 { return port }
        if let port = device.portMap["_skybridge._udp"], port > 0 { return port }

        for (serviceType, port) in device.portMap where port > 0 {
            if looksLikeBonjourServiceType(serviceType) {
                return port
            }
        }
        return 0
    }

    private func resolvedConnectableServiceType(for device: DiscoveredDevice) -> String? {
        guard enableMDNSResolution else { return nil }

        if device.services.contains(BonjourInteropContract.remoteControlServiceType) {
            return BonjourInteropContract.remoteControlServiceType
        }
        if device.services.contains(BonjourInteropContract.legacyRemoteControlServiceType) {
            return BonjourInteropContract.legacyRemoteControlServiceType
        }
        if device.services.contains("_skybridge._tcp") { return "_skybridge._tcp" }
        if device.services.contains("_skybridge._udp") { return "_skybridge._udp" }

        for serviceType in device.services where looksLikeBonjourServiceType(serviceType) {
            return serviceType
        }

        if device.portMap[BonjourInteropContract.remoteControlServiceType] != nil {
            return BonjourInteropContract.remoteControlServiceType
        }
        if device.portMap[BonjourInteropContract.legacyRemoteControlServiceType] != nil {
            return BonjourInteropContract.legacyRemoteControlServiceType
        }
        if device.portMap["_skybridge._tcp"] != nil { return "_skybridge._tcp" }
        if device.portMap["_skybridge._udp"] != nil { return "_skybridge._udp" }

        for (serviceType, _) in device.portMap where looksLikeBonjourServiceType(serviceType) {
            return serviceType
        }

        return nil
    }

    private func looksLikeBonjourServiceType(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("_") && (value.hasSuffix("._tcp") || value.hasSuffix("._udp"))
    }

 // MARK: - TLS 握手详情模型与辅助映射
 /// TLS握手详情（版本、密码套件，以及可选ALPN与SNI）
    public struct TLSHandshakeDetails: Sendable {
 /// 已协商的TLS协议版本
        public let protocolVersion: String
 /// 已协商的密码套件
        public let cipherSuite: String
 /// 可选：已协商的应用层协议（ALPN），仅在开启隐私诊断时采集
        public let alpn: String?
 /// 可选：服务器名称指示（SNI），仅在开启隐私诊断时采集
        public let sni: String?

 /// 自定义初始化器，兼容旧调用点（alpn/sni默认为nil）
 /// 中文说明：为避免影响现有代码，仅需传入协议版本与密码套件，其余字段在隐私诊断开启时填充。
        public init(protocolVersion: String, cipherSuite: String, alpn: String? = nil, sni: String? = nil) {
            self.protocolVersion = protocolVersion
            self.cipherSuite = cipherSuite
            self.alpn = alpn
            self.sni = sni
        }

 /// 将 tls_protocol_version_t 映射为可读字符串
 /// 中文说明：API返回的协议枚举转换为中文友好名称
        public static func string(from v: tls_protocol_version_t) -> String {
            switch v {
            case .TLSv13: return "TLS 1.3"
            case .TLSv12: return "TLS 1.2"
            case .DTLSv12: return "DTLS 1.2" // 近距TCP不涉及DTLS，但保留兼容
            default: return "未知版本"
            }
        }

 /// 将 tls_ciphersuite_t 映射为常见TLS 1.3密码套件名称
 /// 中文说明：常见套件包含 AES-GCM 与 CHACHA20-POLY1305，其他值以十六进制显示
 /// 内部桥接工具：将 `tls_ciphersuite_t` 安全转换为 `UInt16`
 /// 中文说明：系统头文件在不同平台上可能对 `tls_ciphersuite_t` 的泛型约束不同，
 /// 这里通过 unsafeBitCast（大小一致）进行无符号16位数值提取，便于数值匹配。
        private static func toU16(_ v: tls_ciphersuite_t) -> UInt16 {
            return unsafeBitCast(v, to: UInt16.self)
        }

        public static func string(from cs: tls_ciphersuite_t) -> String {
 // 中文说明：为避免 Security 框架常量类型不一致（SSLCipherSuite 与 tls_ciphersuite_t）导致编译报错，
 // 这里统一使用数值匹配TLS 1.3套件编号：
 // 0x1301 -> TLS_AES_128_GCM_SHA256
 // 0x1302 -> TLS_AES_256_GCM_SHA384
 // 0x1303 -> TLS_CHACHA20_POLY1305_SHA256
            let raw = toU16(cs)
            switch raw {
            case 0x1302: return "TLS_AES_256_GCM_SHA384"
            case 0x1301: return "TLS_AES_128_GCM_SHA256"
            case 0x1303: return "TLS_CHACHA20_POLY1305_SHA256"
            default:
                return String(format: "未知套件(0x%04X)", UInt32(raw))
            }
        }

 /// 兼容旧版 SecureTransport 常量类型（SSLCipherSuite）
 /// 中文说明：某些系统头文件返回SSLCipherSuite类型，与tls_ciphersuite_t不同，这里提供重载以兼容。
        public static func string(from cs: SSLCipherSuite) -> String {
            switch cs {
            case 0x1302: return "TLS_AES_256_GCM_SHA384"
            case 0x1301: return "TLS_AES_128_GCM_SHA256"
            case 0x1303: return "TLS_CHACHA20_POLY1305_SHA256"
            default:
                return String(format: "未知套件(0x%04X)", UInt32(cs))
            }
        }
    }

    nonisolated static func preferredBonjourEndpoint(
        for device: DiscoveredDevice,
        defaultDomain: String
    ) -> (name: String, domain: String)? {
        if let parsed = parseBonjourIdentifier(device.uniqueIdentifier) {
            return parsed
        }

        guard let name = sanitizeBonjourServiceName(device.name) else {
            return nil
        }
        return (name, normalizedBonjourDomain(defaultDomain))
    }

    nonisolated private static func parseBonjourIdentifier(
        _ raw: String?
    ) -> (name: String, domain: String)? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix("bonjour:") else {
            return nil
        }

        let payload = String(raw.dropFirst("bonjour:".count))
        let components = payload.split(separator: "@", maxSplits: 1).map(String.init)
        guard let name = sanitizeBonjourServiceName(components.first) else {
            return nil
        }

        let domain = components.count > 1 ? components[1] : "local."
        return (name, normalizedBonjourDomain(domain))
    }

    nonisolated private static func sanitizeBonjourServiceName(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        if value.hasPrefix("bonjour:") {
            return parseBonjourIdentifier(value)?.name
        }

        if let range = value.range(of: "._") {
            value = String(value[..<range.lowerBound])
        }

        return PeerTrustLookup.sanitizedBonjourServiceInstanceName(value)
    }

    nonisolated private static func normalizedBonjourDomain(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "local."
        }
        return trimmed.hasSuffix(".") ? trimmed : "\(trimmed)."
    }

    nonisolated private static func sanitizedConnectableAddress(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return parsedIPAddress(raw)
    }

    nonisolated static func mergedPortMapPreservingResolvedPorts(
        incoming: [String: Int],
        existing: [String: Int]
    ) -> [String: Int] {
        var merged = existing
        for (serviceType, incomingPort) in incoming {
            let existingPort = merged[serviceType] ?? 0
            if incomingPort > 0 || existingPort <= 0 {
                merged[serviceType] = incomingPort
            }
        }
        return merged
    }

    nonisolated private static func parsedIPAddress(_ raw: String) -> String? {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.hasPrefix("[") && token.hasSuffix("]") {
            token = String(token.dropFirst().dropLast())
        }
        if let percent = token.firstIndex(of: "%") {
            token = String(token[..<percent])
        }

        if IPv4Address(token) != nil || IPv6Address(token) != nil {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

 /// 获取指定设备的活动连接
 /// - Parameter deviceId: 设备的唯一标识符
 /// - Returns: 如果连接存在且处于就绪/活动状态，返回对应的 `NWConnection`；否则返回 `nil`
    public func activeConnection(for deviceId: UUID) -> NWConnection? {
        let key = deviceId.uuidString
        guard let connection = connections[key] else { return nil }
 // 仅在连接未被取消时返回，避免使用已失效连接
        return connection
    }

 // MARK: - 私有方法（性能优化核心）

 /// 并发启动所有浏览器
    private func startBrowsersConcurrently() async {
        guard enableBonjourDiscovery else {
            logger.info("📡 Bonjour 发现已关闭，跳过浏览器启动")
            return
        }

 // 在兼容模式下，先动态扫描服务目录，再合并到有效服务类型集合
        var types = effectiveServiceTypes()
        if enableMDNSResolution && (enableCompatibilityMode || useNewDiscoveryAlgorithm) {
            let dynamicTimeout = min(max(Double(discoveryTimeout), 1.0), 10.0)
            let dynamicTypes = await discoverServiceTypesDynamic(timeoutSeconds: dynamicTimeout)
            let merged = Set(types).union(dynamicTypes)
 // 过滤自身目录类型与异常条目
            types = merged.filter { t in
                t != "_services._dns-sd._udp"
                    && (t.contains("._tcp") || t.contains("._udp"))
                    && !knownUnsupportedServiceTypes.contains(t)
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for serviceType in types {
                group.addTask { [weak self] in
                    await self?.startSingleBrowser(serviceType: serviceType)
                }
            }
        }
    }

 // 动态服务目录扫描（_services._dns-sd._udp），收集当前网络可用的全部服务类型
    private func discoverServiceTypesDynamic(timeoutSeconds: Double) async -> Set<String> {
        let accumulator = ServiceTypeAccumulator()
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_services._dns-sd._udp", domain: serviceDomain)
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.browseResultsChangedHandler = { results, _ in
 // 收集服务类型名称（endpoint 为 meta 目录，name 即服务类型）
            for r in results {
                if case let .service(name, _, _, _) = r.endpoint {
 // 规范化与过滤非法条目
                    let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.hasPrefix("_") && (t.contains("._tcp") || t.contains("._udp")) {
 // 通过 actor 序列化写入，避免并发写入捕获变量
                        Task { await accumulator.insert(t) }
                    }
                }
            }
        }

 // 在专用并发队列启动浏览器
        browser.start(queue: discoveryQueue)

 // 限定扫描时间窗口，结束后取消浏览器并返回集合
        do {
            try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
        } catch is CancellationError {
            browser.cancel()
            return []
        } catch {
            logger.error(
                "❌ 动态 Bonjour 服务目录扫描中止: errorType=\(String(reflecting: Swift.type(of: error)), privacy: .public)"
            )
            browser.cancel()
            return []
        }
        browser.cancel()
 // 读取 actor 内的最终快照
        return await accumulator.snapshot()
    }

 /// 启动单个浏览器（在后台队列）
 /// Bonjour discovery must let Network.framework pick Wi-Fi/Ethernet/AWDL interfaces.
    private func startSingleBrowser(serviceType: String) async {
        // 已知不可浏览的服务类型不再重建浏览器。
        if knownUnsupportedServiceTypes.contains(serviceType) {
            logger.debug("⏭️ 跳过已知不可浏览的服务类型: \(serviceType)")
            return
        }
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: serviceType, domain: serviceDomain)
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        if enableIPv6Support {
            logger.debug("🌐 浏览器使用系统接口选择（IPv4/IPv6/AWDL）: \(serviceType)")
        }

        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { [weak self, weak browser] state in
            Task { @MainActor in
                self?.handleBrowserStateUpdate(state, for: serviceType, browser: browser)
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
 // 在后台队列处理结果变化
            Task(priority: .userInitiated) {
                await self?.handleBrowseResultsChanged(results: results, changes: changes, serviceType: serviceType)
            }
        }

 // 在专用队列启动浏览器（非主线程）
        browser.start(queue: discoveryQueue)

        await MainActor.run {
            self.browsers.append(browser)
            self.logger.debug("✅ 浏览器已启动: \(serviceType)")
        }
    }

    /// Bounded, monotonically increasing retry spacing for identity-authority failures.
    /// The last entry is the steady-state ceiling: retries continue (a denied Keychain
    /// prompt or a missing entitlement can be fixed by the user at any time) but never
    /// faster than once per ceiling interval.
    nonisolated static func identityResolutionBackoffDelay(
        forFailureCount failureCount: Int
    ) -> TimeInterval {
        precondition(failureCount >= 0)
        let schedule = identityResolutionBackoffSchedule
        let index = min(failureCount, schedule.count - 1)
        return schedule[index]
    }

 /// 事件驱动的防抖刷新（200ms）
    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 200_000_000) // 200ms 防抖
                await self?.flushPendingUpdates()
            } catch is CancellationError {
                return
            } catch {
                self?.logger.error(
                    "❌ 发现更新防抖任务中止: errorType=\(String(reflecting: Swift.type(of: error)), privacy: .public)"
                )
            }
        }
    }

 /// 刷新待处理的更新（批量UI更新）
    private func flushPendingUpdates() async {
        guard !pendingUpdates.isEmpty else { return }

        // A previous resolution failed and the backoff window has not elapsed. The batch
        // stays pending and no Keychain access is attempted, so a persistent identity
        // failure cannot be amplified into one Keychain lookup per Bonjour event.
        if let retryNotBefore = identityResolutionRetryNotBefore {
            guard Date() >= retryNotBefore else { return }
        }

        // Local-device classification is a security decision: keep the batch pending
        // if the complete authority tuple cannot be resolved, rather than publishing
        // rows against an empty presentation snapshot.
        let selfId: SelfIdentitySnapshot
        do {
            selfId = try await SelfIdentityProvider.shared
                .snapshotEnsuringProtocolDeviceId(allowCreate: true)
        } catch {
            let delay = Self.identityResolutionBackoffDelay(
                forFailureCount: identityResolutionFailureCount
            )
            identityResolutionFailureCount += 1
            identityResolutionRetryNotBefore = Date().addingTimeInterval(delay)
            logger.error(
                """
                ❌ Discovery batch blocked because local identity authority is unavailable: \
                \(error.localizedDescription, privacy: .public) \
                failures=\(self.identityResolutionFailureCount, privacy: .public) \
                retryAfter=\(Int(delay), privacy: .public)s
                """
            )
            return
        }
        identityResolutionFailureCount = 0
        identityResolutionRetryNotBefore = nil

        let updates = pendingUpdates
        pendingUpdates.removeAll()

 // 清理过期的移除身份守卫，限制字典增长
        let now = Date()
        recentlyRemovedIdentities = recentlyRemovedIdentities.filter { now.timeIntervalSince($0.value) < removedTTL }

 // 批量生成候选弱指纹并持久化，提高后续合并命中率
        let fpMap = await generateFingerprintsBatch(for: updates)

 // 批量更新设备列表（严格防止不同设备错误合并）
        for device in updates {
 // 守卫：若该身份在 TTL 内刚被 `.removed` 移除，跳过这条在途解析结果，避免幽灵设备复活
            if isRecentlyRemoved(device) { continue }

 // 硬闸：只有 SkyBridge 来源才允许判定本机
            let eligibleForLocal =
                device.services.contains(where: { $0.lowercased().contains("skybridge") })

            if !eligibleForLocal {
 // 非 SkyBridge 来源：强制清空强身份，确保永远非本机
                var sanitized = device
                sanitized.setIsLocalDeviceByDiscovery(false)
                sanitized.deviceId = nil
                sanitized.pubKeyFP = nil
                sanitized.macSet.removeAll()

                #if DEBUG
                logger.debug("🚫 非SkyBridge来源[\(device.name)]，强制清空强身份，isLocal=false")
                #endif

 // 继续使用清理后的设备
                let candidateFP = fpMap[sanitized.id] ?? nil
                let mergeIndex = await identityResolver.findMergeIndex(in: discoveredDevices, candidate: sanitized, candidateFP: candidateFP)

                if let index = mergeIndex, discoveredDevices.indices.contains(index) {
                    let existingDevice = discoveredDevices[index]
                    let betterName = Self.preferredDisplayName(
                        existing: existingDevice.name,
                        candidate: sanitized.name
                    )
                    let mergedConnectionTypes = sanitized.connectionTypes.union(existingDevice.connectionTypes)
                    let sanitizedIsUSBPresence =
                        sanitized.source == .skybridgeUSB
                        || (sanitized.connectionTypes == [.usb] && sanitized.services.isEmpty && sanitized.portMap.isEmpty)
                    let existingHasSkyBridgeEndpoint =
                        existingDevice.services.contains(where: { $0.lowercased().contains("skybridge") })
                        || existingDevice.portMap.keys.contains(where: { $0.lowercased().contains("skybridge") })
                    let preserveExistingNetworkIdentity = sanitizedIsUSBPresence && existingHasSkyBridgeEndpoint

                    let updatedDevice = DiscoveredDevice(
                        id: existingDevice.id,
                        name: betterName,
                        ipv4: sanitized.ipv4 ?? existingDevice.ipv4,
                        ipv6: sanitized.ipv6 ?? existingDevice.ipv6,
                        platformName: sanitized.platformName ?? existingDevice.platformName,
                        osVersion: sanitized.osVersion ?? existingDevice.osVersion,
                        modelName: sanitized.modelName ?? existingDevice.modelName,
                        chip: sanitized.chip ?? existingDevice.chip,
                        services: preserveExistingNetworkIdentity
                            ? existingDevice.services
                            : Array(Set(sanitized.services + existingDevice.services)),
                        portMap: preserveExistingNetworkIdentity
                            ? existingDevice.portMap
                            : Self.mergedPortMapPreservingResolvedPorts(
                                incoming: sanitized.portMap,
                                existing: existingDevice.portMap
                            ),
                        remoteVideoFormats: sanitized.remoteVideoFormats.union(existingDevice.remoteVideoFormats),
                        connectionTypes: mergedConnectionTypes,
                        uniqueIdentifier: preserveExistingNetworkIdentity
                            ? existingDevice.uniqueIdentifier
                            : (sanitized.uniqueIdentifier ?? existingDevice.uniqueIdentifier),
                        routeIdentifiers: preserveExistingNetworkIdentity
                            ? existingDevice.routeIdentifiers
                            : DiscoveredDevice.mergedRouteIdentifiers(sanitized.routeIdentifiers, existingDevice.routeIdentifiers),
                        signalStrength: sanitized.signalStrength ?? existingDevice.signalStrength,
                        networkLinkStatus: sanitized.networkLinkStatus ?? existingDevice.networkLinkStatus,
                        source: preserveExistingNetworkIdentity ? existingDevice.source : sanitized.source,
                        isLocalDevice: false, // 强制非本机
                        deviceId: preserveExistingNetworkIdentity ? existingDevice.deviceId : nil,
                        pubKeyFP: preserveExistingNetworkIdentity ? existingDevice.pubKeyFP : nil,
                        macSet: preserveExistingNetworkIdentity ? existingDevice.macSet : []
                    )
                    discoveredDevices[index] = updatedDevice
                } else {
                    discoveredDevices.append(sanitized)
                }
                continue // 跳过后续的本机判定
            }

 // 改为通过 IdentityResolver 进行统一决策，避免跨源误并。
 // 若存在外部指纹提供者，则生成候选指纹参与合并判定。
            let candidateFP = fpMap[device.id] ?? nil
            let routeBoundMergeIndex = Self.routeBoundMergeIndex(in: discoveredDevices, candidate: device)
            let mergeIndex: Int?
            if let routeBoundMergeIndex {
                mergeIndex = routeBoundMergeIndex
            } else {
                mergeIndex = await identityResolver.findMergeIndex(in: discoveredDevices, candidate: device, candidateFP: candidateFP)
            }

 // 判定候选设备是否为本机（强身份硬匹配）
            let candidateIsLocal = await identityResolver.resolveIsLocal(device, selfId: selfId)

            #if DEBUG
 // DEBUG 日志：精简版 - 只打印强身份来源和匹配结果
            let source = "Bonjour"
            let deviceIdValid = device.deviceId != nil && !device.deviceId!.isEmpty && device.deviceId!.count >= 8
            let pubKeyFPValid = device.pubKeyFP != nil && !device.pubKeyFP!.isEmpty && device.pubKeyFP!.count == 64

 // 判定触发了哪条优先级
            var matchedRule = "无匹配"
            if candidateIsLocal {
                if deviceIdValid && device.deviceId == selfId.deviceId {
                    matchedRule = "优先级A:deviceId"
                } else if pubKeyFPValid && device.pubKeyFP == selfId.pubKeyFP {
                    matchedRule = "优先级B:pubKeyFP"
                }
            }

            logger.debug("""
                [\(source)] \(device.name): \
                deviceId=\(deviceIdValid ? "✓" : "✗") \
                pubKeyFP=\(pubKeyFPValid ? "✓" : "✗") \
                → \(candidateIsLocal ? "本机" : "非本机") \
                (\(matchedRule))
                """)

 // 异常警告：品牌设备被误判
            if candidateIsLocal && (device.name.lowercased().contains("hp") ||
                                    device.name.lowercased().contains("dell") ||
                                    device.name.lowercased().contains("lenovo")) {
                logger.warning("⚠️ 异常: 品牌设备[\(device.name)]判为本机, 触发规则:\(matchedRule)")
            }
            #endif

            if let index = mergeIndex, discoveredDevices.indices.contains(index) {
                let existingDevice = discoveredDevices[index]
                // ⚠️ 重要：不要在 `await` 之后继续使用旧的 index 写回数组。
                // 由于本类是 @MainActor，`await` 会让出执行权，期间其他任务可能会移除/重排 `discoveredDevices`，
                // 从而导致 index 过期（Release 下会触发 Swift runtime "Index out of range"）。
                let existingRecordId = existingDevice.id
                let existingStableDeviceId = existingDevice.deviceId
                let existingPubKeyFP = existingDevice.pubKeyFP

 // 判定现有设备是否为本机
                let existingIsLocal = await identityResolver.resolveIsLocal(existingDevice, selfId: selfId)

                #if DEBUG
                logger.debug("🔄 合并判定 [\(existingDevice.name)]: existing=\(existingIsLocal), candidate=\(candidateIsLocal)")
                #endif

 // 1️⃣ 强匹配检查（只有强身份匹配才允许合并）
                let validId: (String?) -> Bool = { id in
                    guard let id = id, !id.isEmpty, id.count >= 8 else { return false }
                    return true
                }
                let validFP: (String?) -> Bool = { fp in
                    guard let fp = fp, fp.count == 64, fp.allSatisfy({ $0.isHexDigit }) else { return false }
                    return true
                }

                // Allow same-record updates (same UUID) even if strong identity fields weren't present in the initial placeholder.
                let routeBoundProtocolMerge = Self.isRouteBoundProtocolMerge(
                    existing: existingDevice,
                    candidate: device
                )
                let strongMatch =
                    (existingDevice.id == device.id) ||
                    (validId(existingDevice.deviceId) && validId(device.deviceId) && existingDevice.deviceId == device.deviceId) ||
                    (validFP(existingDevice.pubKeyFP) && validFP(device.pubKeyFP) && existingDevice.pubKeyFP == device.pubKeyFP) ||
                    routeBoundProtocolMerge

 // 若非强匹配，禁止合并（视为不同设备）
                guard strongMatch else {
                    #if DEBUG
                    logger.debug("⚠️ 非强匹配，拒绝合并: [\(existingDevice.name)] vs [\(device.name)]")
                    #endif
 // 作为新设备添加
                    var newDevice = device
                    newDevice.setIsLocalDeviceByDiscovery(candidateIsLocal)
                    discoveredDevices.append(newDevice)
                    continue
                }

 // 2️⃣ 开始合并（基于 existing）
                var merged = existingDevice

 // 2.1 始终更新 transient 字段（IP、在线状态、延迟等）
                merged._updateTransient(ipv4: device.ipv4, ipv6: device.ipv6)
                merged.signalStrength = device.signalStrength ?? merged.signalStrength
                merged.networkLinkStatus = device.networkLinkStatus ?? merged.networkLinkStatus
                merged.connectionTypes = merged.connectionTypes.union(device.connectionTypes)

 // 2.2 字段保护策略
                if existingIsLocal && !candidateIsLocal {
 // 本机记录不被第三方候选覆盖 identity/name/services
                    #if DEBUG
                    logger.debug("🛡️ 保护本机字段: [\(merged.name)]，拒绝候选[\(device.name)]的覆盖")
                    #endif
 // 只更新 transient 字段（已在上方完成）
 // 绝不覆盖 name/model/services/deviceId/pubKeyFP/source
                } else if strongMatch {
 // 强匹配时才允许更新展示/服务字段
                    let betterName = Self.preferredDisplayName(
                        existing: merged.name,
                        candidate: device.name
                    )
                    merged._updateDisplayNameIfAllowed(betterName)
                    merged.services = Array(Set(device.services + merged.services))
                    merged.portMap = Self.mergedPortMapPreservingResolvedPorts(
                        incoming: device.portMap,
                        existing: merged.portMap
                    )
                    merged.mergeRouteIdentifiers(device.routeIdentifiers)
                    if device.source != .unknown {
                        merged.source = device.source
                    }

 // 合并强身份字段（优先非空）
                    merged.deviceId = device.deviceId ?? merged.deviceId
                    merged.pubKeyFP = device.pubKeyFP ?? merged.pubKeyFP
                    merged.macSet = device.macSet.union(merged.macSet)
 // bestUniqueIdentifier 是同步方法，无需 await
                    merged.uniqueIdentifier = identityResolver.bestUniqueIdentifier(existing: merged, candidate: device, candidateFP: candidateFP)
                }

 // 3️⃣ DEBUG 断言：防止第三方设备误判为本机
                #if DEBUG
                if merged.source != DeviceSource.skybridgeBonjour &&
                   merged.source != DeviceSource.skybridgeP2P &&
                   merged.source != DeviceSource.skybridgeUSB &&
                   merged.source != DeviceSource.skybridgeCloud {
                    logger.warning("⚠️ 异常: 合并后 source=\(merged.source.rawValue)，强制回源 existing.source")
                    merged.source = existingDevice.source
                }
                #endif

 // 4️⃣ 重新应用本机标志（统一写入点）
                applyLocalFlag(&merged, selfId: selfId)

                // 重新定位：优先按 record UUID，其次按强身份字段，最后回退追加（避免崩溃 & 避免写错槽位）
                let targetIndex =
                    discoveredDevices.firstIndex(where: { $0.id == existingRecordId }) ??
                    (existingStableDeviceId.flatMap { sid in
                        sid.isEmpty ? nil : discoveredDevices.firstIndex(where: { $0.deviceId == sid })
                    }) ??
                    (existingPubKeyFP.flatMap { fp in
                        fp.isEmpty ? nil : discoveredDevices.firstIndex(where: { $0.pubKeyFP == fp })
                    })

                if let targetIndex {
                    discoveredDevices[targetIndex] = merged
                } else {
                    discoveredDevices.append(merged)
                }
                logger.debug("🔄 合并设备: \(merged.name) - 本机: \(merged.isLocalDevice)")
            } else {
 // 新设备，添加到列表
                var newDevice = device
                newDevice.setIsLocalDeviceByDiscovery(candidateIsLocal) // 设置本机标记
                discoveredDevices.append(newDevice)
                logger.debug("➕ 新设备: \(device.name) - 连接方式: \(device.connectionTypes), 本机: \(candidateIsLocal)")
            }
        }

 // 单本机硬阀：确保列表中最多只有一个本机标记
        await hardClampSingleLocal(selfId: selfId)

        logger.debug("📊 批量更新了 \(updates.count) 个设备，当前总数: \(self.discoveredDevices.count)")
    }

 /// 批量生成弱指纹（优先使用外部提供者，否则回退到端口谱散列），并持久化到缓存
    private func generateFingerprintsBatch(for devices: Set<DiscoveredDevice>) async -> [UUID: IdentityFingerprint?] {
        var result: [UUID: IdentityFingerprint?] = [:]
        if let provider = fingerprintProvider {
            await withTaskGroup(of: (UUID, IdentityFingerprint?).self) { group in
                for d in devices {
                    group.addTask { [provider] in
                        let fp = await provider(d)
                        if let fp = fp {
                            await IdentityResolver.WeakFingerprintStore.shared.save(fp, for: d)
                        }
                        return (d.id, fp)
                    }
                }
                for await (id, fp) in group { result[id] = fp }
            }
        } else {
            for d in devices {
                let ps = IdentityResolver.computePortSpectrumHash(from: d.portMap)
                let fp = IdentityFingerprint(
                    pairedID: nil,
                    macAddress: nil,
                    usnUUID: nil,
                    usbSerial: d.uniqueIdentifier,
                    mdnsDeviceID: nil,
                    hostname: d.name,
                    model: nil,
                    httpServer: nil,
                    portSpectrumHash: ps,
                    ipv4: d.ipv4,
                    ipv6: d.ipv6,
                    primaryConnectionType: d.primaryConnectionType.rawValue
                )
                await IdentityResolver.WeakFingerprintStore.shared.save(fp, for: d)
                result[d.id] = fp
            }
        }
        return result
    }

 /// 单本机硬阀：确保设备列表中最多只有一个本机标记
 /// 中文说明：即使前面判定有误差，这里也会强制校正，只保留最强匹配者为本机。
    private func hardClampSingleLocal(selfId: SelfIdentitySnapshot) async {
        let locals = self.discoveredDevices.filter { $0.isLocalDevice }

        guard locals.count > 1 else {
 // 0或1个本机标记，无需处理
            return
        }

        logger.warning("⚠️ 检测到多个本机标记（\(locals.count)个），执行硬阀校正")

        #if DEBUG
 // DEBUG：列出所有被误判为本机的设备
        for (idx, local) in locals.enumerated() {
            logger.debug("""
                🚨 误判设备 #\(idx+1) [\(local.name)]:
                  - DeviceID: \(local.deviceId ?? "nil")
                  - PubKeyFP: \(local.pubKeyFP?.prefix(16) ?? "nil")...
                  - MAC数: \(local.macSet.count)
                  - Services: \(local.services.joined(separator: ", "))
                """)
        }
        #endif

        // 重新计算所有设备的 isLocal 状态
        // ⚠️ 重要：不要在 `await` 之后继续使用旧的 index 写回数组（同上，避免 index 过期崩溃）。
        let snapshot = self.discoveredDevices
        for device in snapshot {
            let isLocal = await identityResolver.resolveIsLocal(device, selfId: selfId)
            if let idx = self.discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                self.discoveredDevices[idx].setIsLocalDeviceByDiscovery(isLocal)
            }
        }

 // 再次检查是否仍有多个本机标记（极端情况：脏数据）
        let finalLocals = self.discoveredDevices.enumerated().filter { $0.element.isLocalDevice }

        if finalLocals.count > 1 {
            logger.error("❌ 硬阀后仍有多个本机标记，保留最强匹配者")

 // 优先级：deviceId 匹配 > pubKeyFP 匹配 > MAC 匹配 > 第一个
            var keepIndex: Int? = nil

 // 优先级 A：deviceId 匹配
            keepIndex = finalLocals.first(where: {
                $0.element.deviceId == selfId.deviceId && !(selfId.deviceId.isEmpty)
            })?.offset

 // 优先级 B：pubKeyFP 匹配
            if keepIndex == nil {
                keepIndex = finalLocals.first(where: {
                    $0.element.pubKeyFP == selfId.pubKeyFP && !(selfId.pubKeyFP.isEmpty)
                })?.offset
            }

 // 优先级 C：MAC 交集匹配
            if keepIndex == nil {
                keepIndex = finalLocals.first(where: {
                    !$0.element.macSet.intersection(selfId.macSet).isEmpty
                })?.offset
            }

 // 默认：保留第一个
            if keepIndex == nil {
                keepIndex = finalLocals.first?.offset
            }

 // 清除其他所有本机标记
            if let keep = keepIndex {
                for (idx, _) in finalLocals where idx != keep {
                    self.discoveredDevices[idx].setIsLocalDeviceByDiscovery(false)
                    logger.warning("🔧 移除设备 [\(self.discoveredDevices[idx].name)] 的本机标记")
                }
                logger.info("✅ 保留设备 [\(self.discoveredDevices[keep].name)] 为唯一本机")
            }
        } else {
            logger.info("✅ 硬阀校正完成，本机标记唯一")
        }
    }

 /// 设置外部候选指纹提供者（由发现服务提供）。
    public func setFingerprintProvider(_ provider: @escaping @Sendable (DiscoveredDevice) async -> IdentityFingerprint?) {
        fingerprintProvider = provider
    }


 /// 处理浏览结果变化（异步+批量）
    private func handleBrowseResultsChanged(
        results: Set<NWBrowser.Result>,
        changes: Set<NWBrowser.Result.Change>,
        serviceType: String
    ) async {
        for change in changes {
            switch change {
            case .added(let result):
                await addDiscoveredDeviceAsync(from: result, serviceType: serviceType)
            case .removed(let result):
                await removeDiscoveredDeviceAsync(from: result, serviceType: serviceType)
            case .changed(old: _, new: let new, flags: _):
                await updateDiscoveredDeviceAsync(from: new, serviceType: serviceType)
            case .identical:
                break
            @unknown default:
                break
            }
        }
    }

    private func validatedBrowseMetadata(
        from result: NWBrowser.Result,
        serviceType: String
    ) -> ValidatedBrowseMetadata? {
        if let role = BonjourInteropContract.advertisementRole(for: serviceType) {
            guard case .bonjour(let txtRecord) = result.metadata else {
                return nil
            }
            do {
                let projection = try BonjourInteropContract.decodeAdvertisement(
                    txtRecord,
                    role: role
                ).discoveryProjection
                let info = projection.platform.map {
                    BonjourDeviceInfo(platform: $0.rawValue)
                }
                return ValidatedBrowseMetadata(
                    deviceId: projection.deviceId,
                    protocolPublicKeyFingerprint: projection.protocolPublicKeyFingerprint,
                    deviceInfo: info,
                    networkLinkStatus: nil
                )
            } catch {
                logger.error(
                    "❌ 拒绝无效 SkyBridge Bonjour TXT: service=\(serviceType, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }

        guard case .bonjour(let txtRecord) = result.metadata else {
            return ValidatedBrowseMetadata(
                deviceId: nil,
                protocolPublicKeyFingerprint: nil,
                deviceInfo: nil,
                networkLinkStatus: nil
            )
        }
        return ValidatedBrowseMetadata(
            deviceId: nil,
            protocolPublicKeyFingerprint: nil,
            deviceInfo: Self.nonEmptyDeviceInfo(
                BonjourTXTParser.extractDeviceInfo(txtRecord)
            ),
            networkLinkStatus: BonjourTXTParser.extractNetworkLinkStatus(txtRecord)
        )
    }

 /// 异步添加设备（在后台解析网络信息）
    private func addDiscoveredDeviceAsync(from result: NWBrowser.Result, serviceType: String) async {
 // 快速提取基本信息（不阻塞）
        guard let validated = validatedBrowseMetadata(
            from: result,
            serviceType: serviceType
        ) else {
            return
        }
        let metadata = validated.deviceInfo
        let deviceName = resolvedDisplayName(
            metadata: metadata,
            endpointFallback: extractDeviceNameQuick(from: result)
        )
        let strong = (
            deviceId: validated.deviceId,
            pubKeyFP: validated.protocolPublicKeyFingerprint
        )
        let bonjourID = Self.bonjourIdentifier(from: result.endpoint)
        let networkLinkStatus = validated.networkLinkStatus
        let connectionTypes = Self.connectionTypes(
            from: networkLinkStatus,
            defaultTypes: [.wifi]
        )
        let source = inferSource(from: serviceType)
        let deviceId = UUID()
        schedulePrimaryControlServiceHydrationIfNeeded(
            from: result,
            serviceType: serviceType,
            fallbackMetadata: metadata,
            fallbackNetworkLinkStatus: networkLinkStatus
        )

 // 守卫：非 SkyBridge serviceType 的设备强制标记为非本机
        let isSkyBridgeService = serviceType.lowercased().contains("skybridge")

        #if DEBUG
        if !isSkyBridgeService {
            logger.debug("🔍 Bonjour 发现非SkyBridge服务: [\(deviceName)] serviceType=\(serviceType)")
        }
        #endif

 // 创建临时设备（先显示，后更新网络信息）
        let tempDevice = DiscoveredDevice(
            id: deviceId,
            name: deviceName,
            ipv4: nil,  // 异步解析
            ipv6: nil,  // 异步解析
            platformName: metadata?.platform,
            osVersion: metadata?.osVersion,
            modelName: metadata?.model,
            chip: metadata?.chip,
            services: [serviceType],
            portMap: [serviceType: 0],
            remoteVideoFormats: Set(metadata?.remoteVideoFormats ?? []),
            connectionTypes: connectionTypes,
            uniqueIdentifier: Self.preferredUniqueIdentifier(
                deviceId: strong.deviceId,
                pubKeyFP: strong.pubKeyFP,
                bonjourID: bonjourID,
                ipv4: nil,
                ipv6: nil
            ),
            routeIdentifiers: [bonjourID].compactMap { $0 },
            signalStrength: Self.signalPercentage(from: networkLinkStatus),
            networkLinkStatus: networkLinkStatus,
            source: source,
            isLocalDevice: false, // 非SkyBridge服务默认非本机，后续由resolveIsLocal统一判定
            deviceId: strong.deviceId,
            pubKeyFP: strong.pubKeyFP
        )

 // 立即添加到待处理更新（快速显示）
        await MainActor.run(resultType: Void.self) { [weak self] in
            self?.pendingUpdates.insert(tempDevice)
            self?.scheduleFlush()
        }

 // 在后台异步解析网络信息
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            let (ipv4, ipv6, port) = await self.extractNetworkInfoAsync(
                from: result,
                serviceType: serviceType
            )

 // 更新设备信息
            let resolvedSignalStrength = Self.signalPercentage(from: networkLinkStatus)
            let updatedDevice = DiscoveredDevice(
                id: deviceId,
                name: deviceName,
                ipv4: ipv4,
                ipv6: ipv6,
                platformName: metadata?.platform,
                osVersion: metadata?.osVersion,
                modelName: metadata?.model,
                chip: metadata?.chip,
                services: [serviceType],
                portMap: [serviceType: port],
                remoteVideoFormats: Set(metadata?.remoteVideoFormats ?? []),
                connectionTypes: connectionTypes,
                uniqueIdentifier: Self.preferredUniqueIdentifier(
                    deviceId: strong.deviceId,
                    pubKeyFP: strong.pubKeyFP,
                    bonjourID: bonjourID,
                    ipv4: ipv4,
                    ipv6: ipv6
                ),
                routeIdentifiers: [bonjourID].compactMap { $0 },
                signalStrength: resolvedSignalStrength,
                networkLinkStatus: networkLinkStatus,
                source: source,
                isLocalDevice: false, // 后续由 resolveIsLocal 统一判定
                deviceId: strong.deviceId,
                pubKeyFP: strong.pubKeyFP
            )

            await MainActor.run(resultType: Void.self) { [weak self] in
                self?.pendingUpdates.insert(updatedDevice)
                self?.scheduleFlush()
            }
        }
    }

 /// 快速提取设备名称（不进行DNS查询）
    private func extractDeviceNameQuick(from result: NWBrowser.Result) -> String {
        if case .service(let name, _, _, _) = result.endpoint {
            return name.replacingOccurrences(of: "._tcp", with: "")
                      .replacingOccurrences(of: ".local", with: "")
        }
        return "未知设备"
    }

    private func resolvedDisplayName(
        metadata: BonjourDeviceInfo?,
        endpointFallback: String
    ) -> String {
        let rawName = metadata?.displayName
            ?? LocalDevicePresentation.sanitizedDisplayNameCandidate(endpointFallback)
        return LocalDevicePresentation.displayDeviceName(
            rawDeviceName: rawName,
            modelName: metadata?.model,
            platformName: metadata?.platform ?? ""
        ) ?? "未知设备"
    }

    private static func preferredDisplayName(existing: String, candidate: String) -> String {
        let existingScore = displayNameQualityScore(existing)
        let candidateScore = displayNameQualityScore(candidate)
        if candidateScore != existingScore {
            return candidateScore > existingScore ? candidate : existing
        }
        return candidate.count > existing.count ? candidate : existing
    }

    private static func displayNameQualityScore(_ raw: String) -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        if LocalDevicePresentation.isIdentifierLikeDisplayName(trimmed) { return 10 }
        let normalized = trimmed.lowercased().replacingOccurrences(of: " ", with: "")
        switch normalized {
        case "未知设备", "unknown", "unknowndevice":
            return 20
        case "ipad", "iphone":
            return 40
        default:
            if normalized.hasPrefix("ipad") || normalized.hasPrefix("iphone") || normalized.contains("mac") {
                return 70
            }
            if normalized.contains("ipad") || normalized.contains("iphone") {
                return 90
            }
            return 100
        }
    }

 /// 异步提取网络信息（使用NWConnection而非同步DNS）
    private func extractNetworkInfoAsync(
        from result: NWBrowser.Result,
        serviceType: String
    ) async -> (ipv4: String?, ipv6: String?, port: Int) {
        guard enableMDNSResolution else {
            return (nil, nil, 0)
        }
        guard case .service(let name, let endpointType, let domain, _) = result.endpoint else {
            return (nil, nil, 0)
        }
        guard endpointType.caseInsensitiveCompare(serviceType) == .orderedSame else {
            logger.error(
                "❌ Bonjour endpoint type mismatch expected=\(serviceType, privacy: .public) actual=\(endpointType, privacy: .public)"
            )
            return (nil, nil, 0)
        }

        do {
            let resolved = try await Self.resolveBonjourServiceOnMain(
                domain: Self.normalizedBonjourDomain(domain),
                type: endpointType,
                name: name,
                timeoutSeconds: 3.0
            )
            return (resolved.ipv4, resolved.ipv6, resolved.port)
        } catch {
            logger.debug(
                "ℹ️ Bonjour SRV resolve unavailable service=\(serviceType, privacy: .public) reason=\(String(describing: error), privacy: .public)"
            )
            return (nil, nil, 0)
        }
    }

    private func schedulePrimaryControlServiceHydrationIfNeeded(
        from result: NWBrowser.Result,
        serviceType: String,
        fallbackMetadata: BonjourDeviceInfo?,
        fallbackNetworkLinkStatus: DeviceNetworkLinkStatus?
    ) {
        let normalizedServiceType = serviceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedServiceType != BonjourInteropContract.controlServiceType,
              normalizedServiceType.hasPrefix("_skybridge") else {
            return
        }
        guard case .service(let name, _, let domain, _) = result.endpoint else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let normalizedDomain = Self.normalizedBonjourDomain(domain)
        let cooldownKey = "\(trimmedName)|\(normalizedDomain)|\(BonjourInteropContract.controlServiceType)"
        let now = Date()
        primaryControlResolveCooldown = primaryControlResolveCooldown.filter {
            now.timeIntervalSince($0.value) < primaryControlResolveCooldownTTL
        }
        if let last = primaryControlResolveCooldown[cooldownKey],
           now.timeIntervalSince(last) < primaryControlResolveCooldownTTL {
            return
        }
        primaryControlResolveCooldown[cooldownKey] = now

        Task { [weak self, trimmedName, normalizedDomain, fallbackMetadata, fallbackNetworkLinkStatus] in
            guard let self else { return }
            do {
                let resolved = try await Self.resolveBonjourServiceOnMain(
                    domain: normalizedDomain,
                    type: BonjourInteropContract.controlServiceType,
                    name: trimmedName,
                    timeoutSeconds: 3.0
                )
                self.publishHydratedPrimaryControlService(
                    resolved,
                    serviceName: trimmedName,
                    domain: normalizedDomain,
                    fallbackMetadata: fallbackMetadata,
                    fallbackNetworkLinkStatus: fallbackNetworkLinkStatus
                )
            } catch {
                self.logger.debug(
                    "ℹ️ primary-control hydration skipped name=\(trimmedName, privacy: .public) reason=\(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    @MainActor
    private static func resolveBonjourServiceOnMain(
        domain: String,
        type: String,
        name: String,
        timeoutSeconds: TimeInterval
    ) async throws -> ResolvedBonjourService {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ResolvedBonjourService, Error>) in
            let service = NetService(
                domain: domain.isEmpty ? "local." : domain,
                type: type,
                name: name
            )
            let context = BonjourServiceResolveContext(
                service: service,
                timeoutSeconds: timeoutSeconds,
                continuation: continuation
            )
            context.start()
        }
    }

    private func publishHydratedPrimaryControlService(
        _ resolved: ResolvedBonjourService,
        serviceName: String,
        domain: String,
        fallbackMetadata: BonjourDeviceInfo?,
        fallbackNetworkLinkStatus: DeviceNetworkLinkStatus?
    ) {
        let controlType = BonjourInteropContract.controlServiceType
        guard let rawTXTData = resolved.rawTXTData else {
            logger.debug("ℹ️ primary-control hydration missing TXT name=\(serviceName, privacy: .public)")
            return
        }
        let projection: BonjourInteropProtocolContract.DiscoveryProjection
        do {
            guard let decoded = try BonjourInteropContract.discoveryProjection(
                rawTXTData,
                serviceType: controlType
            ) else {
                logger.error("❌ primary-control hydration has no SkyBridge projection")
                return
            }
            projection = decoded
        } catch {
            logger.error(
                "❌ primary-control hydration rejected invalid TXT error=\(error.localizedDescription, privacy: .public)"
            )
            return
        }
        let metadata = projection.platform.map {
            BonjourDeviceInfo(platform: $0.rawValue)
        } ?? fallbackMetadata
        let identity = (
            deviceId: projection.deviceId,
            pubKeyFP: projection.protocolPublicKeyFingerprint
        )
        let controlPort = resolved.port
        guard controlPort > 0 else {
            logger.debug("ℹ️ primary-control hydration missing port name=\(serviceName, privacy: .public)")
            return
        }

        let route = "bonjour:\(serviceName)@\(domain)"
        let displayName = resolvedDisplayName(
            metadata: metadata,
            endpointFallback: serviceName
        )
        let hydrated = DiscoveredDevice(
            id: UUID(),
            name: displayName,
            ipv4: resolved.ipv4,
            ipv6: resolved.ipv6,
            platformName: metadata?.platform,
            osVersion: metadata?.osVersion,
            modelName: metadata?.model,
            chip: metadata?.chip,
            services: [controlType],
            portMap: [controlType: controlPort],
            remoteVideoFormats: Set(metadata?.remoteVideoFormats ?? []),
            connectionTypes: Self.connectionTypes(
                from: fallbackNetworkLinkStatus,
                defaultTypes: [.wifi]
            ),
            uniqueIdentifier: Self.preferredUniqueIdentifier(
                deviceId: identity.deviceId,
                pubKeyFP: identity.pubKeyFP,
                bonjourID: route,
                ipv4: resolved.ipv4,
                ipv6: resolved.ipv6
            ),
            routeIdentifiers: [route],
            signalStrength: Self.signalPercentage(from: fallbackNetworkLinkStatus),
            networkLinkStatus: fallbackNetworkLinkStatus,
            source: .skybridgeBonjour,
            isLocalDevice: false,
            deviceId: identity.deviceId,
            pubKeyFP: identity.pubKeyFP
        )

        pendingUpdates.insert(hydrated)
        scheduleFlush()
        logger.debug(
            "✅ primary-control hydration queued name=\(serviceName, privacy: .public) port=\(controlPort, privacy: .public) identity=\(identity.deviceId == nil ? "missing" : "present", privacy: .public) fingerprint=\(identity.pubKeyFP == nil ? "missing" : "present", privacy: .public)"
        )
    }

    private nonisolated static func extractIPAddress(from data: Data) -> String {
        data.withUnsafeBytes { bytes in
            guard bytes.count >= MemoryLayout<sockaddr>.size,
                  let sockaddr = bytes.bindMemory(to: sockaddr.self).baseAddress else {
                return ""
            }
            switch Int32(sockaddr.pointee.sa_family) {
            case AF_INET:
                guard bytes.count >= MemoryLayout<sockaddr_in>.size,
                      let addr = bytes.bindMemory(to: sockaddr_in.self).baseAddress,
                      let cstr = inet_ntoa(addr.pointee.sin_addr) else {
                    return ""
                }
                return String(cString: cstr)
            case AF_INET6:
                guard bytes.count >= MemoryLayout<sockaddr_in6>.size,
                      let addr = bytes.bindMemory(to: sockaddr_in6.self).baseAddress else {
                    return ""
                }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                var sin6Addr = addr.pointee.sin6_addr
                guard inet_ntop(AF_INET6, &sin6Addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                    return ""
                }
                let data = Data(bytes: buffer, count: Int(INET6_ADDRSTRLEN))
                let trimmed = data.prefix { $0 != 0 }
                return String(decoding: trimmed, as: UTF8.self)
            default:
                return ""
            }
        }
    }

 /// 异步获取接口IP地址（使用getifaddrs，更快）
    private func getIPAddressesForInterfaceAsync(_ interfaceName: String) async -> (ipv4: String?, ipv6: String?)? {
        return await Task.detached(priority: .utility) {
            var ipv4: String?
            var ipv6: String?
            var ifaddrs: UnsafeMutablePointer<ifaddrs>?

            guard getifaddrs(&ifaddrs) == 0 else { return nil }
            defer { freeifaddrs(ifaddrs) }

            var interface = ifaddrs
            while interface != nil {
                defer { interface = interface?.pointee.ifa_next }

                guard let ifa = interface?.pointee,
                      let name = decodeOptionalCString(ifa.ifa_name),
                      name == interfaceName,
                      let addr = ifa.ifa_addr else {
                    continue
                }

                if addr.pointee.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ifa.ifa_addr, socklen_t(addr.pointee.sa_len),
                                   &hostname, socklen_t(hostname.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let data4 = Data(bytes: hostname, count: hostname.count)
                        let trimmed4 = data4.prefix { $0 != 0 }
                        let address = String(decoding: trimmed4, as: UTF8.self)
                        if !address.starts(with: "169.254") && !address.starts(with: "127.") {
                            ipv4 = address
                        }
                    }
                } else if addr.pointee.sa_family == UInt8(AF_INET6) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ifa.ifa_addr, socklen_t(addr.pointee.sa_len),
                                   &hostname, socklen_t(hostname.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let data6 = Data(bytes: hostname, count: hostname.count)
                        let trimmed6 = data6.prefix { $0 != 0 }
                        let address = String(decoding: trimmed6, as: UTF8.self)
                        if !address.starts(with: "fe80:") {
                            ipv6 = address
                        }
                    }
                }
            }

            return (ipv4, ipv6)
        }.value
    }

    private func removeDiscoveredDeviceAsync(
        from result: NWBrowser.Result,
        serviceType: String
    ) async {
        // Prefer strong identity removal when available; fall back to name.
        guard let validated = validatedBrowseMetadata(
            from: result,
            serviceType: serviceType
        ) else {
            return
        }
        let strong = (
            deviceId: validated.deviceId,
            pubKeyFP: validated.protocolPublicKeyFingerprint
        )
        if let stableId = strong.deviceId, !stableId.isEmpty {
            await MainActor.run {
                discoveredDevices.removeAll { $0.deviceId == stableId }
 // 记录移除身份并立即清理已排队的同身份候选，关闭“移除后又被在途 Task 插回”的竞态
                recentlyRemovedIdentities[stableId] = Date()
                pendingUpdates = pendingUpdates.filter { !isRecentlyRemoved($0) }
            }
            return
        }
// 精确移除（基于设备名称）
        if case .service(let name, _, _, _) = result.endpoint {
            let cleanName = name.replacingOccurrences(of: "._tcp", with: "")
                               .replacingOccurrences(of: ".local", with: "")

            await MainActor.run {
                let targetCleanName = cleanName.filter { $0.isLetter || $0.isNumber }
 // 只移除完全匹配的设备
                discoveredDevices.removeAll { device in
                    let deviceCleanName = device.name.filter { $0.isLetter || $0.isNumber }
                    return deviceCleanName == targetCleanName && !targetCleanName.isEmpty
                }
 // 记录移除身份（按清洗后的名称键）并清理已排队的同名候选
                if !targetCleanName.isEmpty {
                    recentlyRemovedIdentities["name:" + targetCleanName] = Date()
                    pendingUpdates = pendingUpdates.filter { !isRecentlyRemoved($0) }
                }
            }
        }
    }

 /// 判断候选设备是否命中 TTL 内刚被移除的身份（同时覆盖稳定 deviceId 与清洗后名称两种键）。
 /// 仅在 @MainActor 上调用，与 recentlyRemovedIdentities 的读写共享 actor 隔离，无额外加锁。
    private func isRecentlyRemoved(_ d: DiscoveredDevice) -> Bool {
        if let id = d.deviceId, !id.isEmpty, recentlyRemovedIdentities[id] != nil { return true }
        let cleaned = d.name.filter { $0.isLetter || $0.isNumber }
        return !cleaned.isEmpty && recentlyRemovedIdentities["name:" + cleaned] != nil
    }

    private func updateDiscoveredDeviceAsync(from result: NWBrowser.Result, serviceType: String) async {
 // 更新现有设备信息（不添加新设备）
        guard let validated = validatedBrowseMetadata(
            from: result,
            serviceType: serviceType
        ) else {
            return
        }
        let metadata = validated.deviceInfo
        let deviceName = resolvedDisplayName(
            metadata: metadata,
            endpointFallback: extractDeviceNameQuick(from: result)
        )
        let strong = (
            deviceId: validated.deviceId,
            pubKeyFP: validated.protocolPublicKeyFingerprint
        )
        let bonjourID = Self.bonjourIdentifier(from: result.endpoint)
        let networkLinkStatus = validated.networkLinkStatus
        let (ipv4, ipv6, port) = await extractNetworkInfoAsync(
            from: result,
            serviceType: serviceType
        )
        let source = inferSource(from: serviceType)
        schedulePrimaryControlServiceHydrationIfNeeded(
            from: result,
            serviceType: serviceType,
            fallbackMetadata: metadata,
            fallbackNetworkLinkStatus: networkLinkStatus
        )

        await MainActor.run {
            let candidate = DiscoveredDevice(
                id: UUID(),
                name: deviceName,
                ipv4: ipv4,
                ipv6: ipv6,
                platformName: metadata?.platform,
                osVersion: metadata?.osVersion,
                modelName: metadata?.model,
                chip: metadata?.chip,
                services: [serviceType],
                portMap: [serviceType: port],
                remoteVideoFormats: Set(metadata?.remoteVideoFormats ?? []),
                connectionTypes: Self.connectionTypes(
                    from: networkLinkStatus,
                    defaultTypes: [.wifi]
                ),
                uniqueIdentifier: Self.preferredUniqueIdentifier(
                    deviceId: strong.deviceId,
                    pubKeyFP: strong.pubKeyFP,
                    bonjourID: bonjourID,
                    ipv4: ipv4,
                    ipv6: ipv6
                ),
                routeIdentifiers: [bonjourID].compactMap { $0 },
                signalStrength: Self.signalPercentage(from: networkLinkStatus),
                networkLinkStatus: networkLinkStatus,
                source: source,
                deviceId: strong.deviceId,
                pubKeyFP: strong.pubKeyFP
            )
            let routeBoundIndex = Self.routeBoundMergeIndex(in: discoveredDevices, candidate: candidate)
            let hasProtocolIdentity = Self.hasAnyProtocolIdentity(
                deviceId: strong.deviceId,
                pubKeyFP: strong.pubKeyFP
            )
 // 查找现有设备
            let weakIndex = hasProtocolIdentity ? nil : discoveredDevices.firstIndex(where: { existingDevice in
                // Prefer stable deviceId match when available.
                if let sid = strong.deviceId, !sid.isEmpty, existingDevice.deviceId == sid { return true }
                if let existingIPv4 = existingDevice.ipv4, let newIPv4 = ipv4, existingIPv4 == newIPv4 {
                    return true
                }
                let cleanExistingName = existingDevice.name.filter { $0.isLetter || $0.isNumber }
                let cleanNewName = deviceName.filter { $0.isLetter || $0.isNumber }
                return cleanExistingName == cleanNewName && !cleanNewName.isEmpty
            })

            if let index = routeBoundIndex ?? weakIndex {
 // 更新现有设备（重新创建以更新不可变属性）
                let existingDevice = discoveredDevices[index]
                var newServices = existingDevice.services
                var newPortMap = existingDevice.portMap

                if !existingDevice.services.contains(serviceType) {
                    newServices.append(serviceType)
                    newPortMap[serviceType] = port
                } else if (newPortMap[serviceType] ?? 0) <= 0, port > 0 {
                    newPortMap[serviceType] = port
                }

                let updatedDevice = DiscoveredDevice(
                    id: existingDevice.id,
                    name: Self.preferredDisplayName(existing: existingDevice.name, candidate: deviceName),
                    ipv4: ipv4 ?? existingDevice.ipv4,
                    ipv6: ipv6 ?? existingDevice.ipv6,
                    platformName: metadata?.platform ?? existingDevice.platformName,
                    osVersion: metadata?.osVersion ?? existingDevice.osVersion,
                    modelName: metadata?.model ?? existingDevice.modelName,
                    chip: metadata?.chip ?? existingDevice.chip,
                    services: newServices,
                    portMap: newPortMap,
                    remoteVideoFormats: Set(metadata?.remoteVideoFormats ?? Array(existingDevice.remoteVideoFormats)),
                    connectionTypes: Self.connectionTypes(
                        from: networkLinkStatus ?? existingDevice.networkLinkStatus,
                        defaultTypes: existingDevice.connectionTypes
                    ),
                    uniqueIdentifier: Self.preferredUniqueIdentifier(
                        deviceId: strong.deviceId ?? existingDevice.deviceId,
                        pubKeyFP: strong.pubKeyFP ?? existingDevice.pubKeyFP,
                        bonjourID: bonjourID,
                        ipv4: ipv4 ?? existingDevice.ipv4,
                        ipv6: ipv6 ?? existingDevice.ipv6
                    ) ?? existingDevice.uniqueIdentifier,
                    routeIdentifiers: DiscoveredDevice.mergedRouteIdentifiers(
                        existingDevice.routeIdentifiers,
                        [bonjourID].compactMap { $0 }
                    ),
                    signalStrength: Self.signalPercentage(from: networkLinkStatus) ?? existingDevice.signalStrength,
                    networkLinkStatus: networkLinkStatus ?? existingDevice.networkLinkStatus,
                    source: Self.preferredDeviceSource(existing: existingDevice.source, candidate: source),
                    isLocalDevice: existingDevice.isLocalDevice,
                    deviceId: strong.deviceId ?? existingDevice.deviceId,
                    pubKeyFP: strong.pubKeyFP ?? existingDevice.pubKeyFP,
                    macSet: existingDevice.macSet
                )
                discoveredDevices[index] = updatedDevice
                logger.debug("🔄 更新设备: \(deviceName)")
            }
        }
    }

    private nonisolated static func nonEmptyDeviceInfo(
        _ info: BonjourDeviceInfo
    ) -> BonjourDeviceInfo? {
        if info.deviceId == nil,
           info.hostname == nil,
           info.model == nil,
           info.chip == nil,
           info.platform == nil,
           info.osVersion == nil,
           info.name == nil,
           info.remoteVideoFormats.isEmpty {
            return nil
        }
        return info
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

    nonisolated static func routeBoundMergeIndex(
        in devices: [DiscoveredDevice],
        candidate: DiscoveredDevice
    ) -> Int? {
        let normalizedDeviceId = sanitizeStableDeviceId(candidate.deviceId)
        let normalizedFingerprint = sanitizePubKeyFingerprint(candidate.pubKeyFP)
        let hasProtocolIdentity = hasAnyProtocolIdentity(
            deviceId: normalizedDeviceId,
            pubKeyFP: normalizedFingerprint
        )

        if let strongIndex = devices.firstIndex(where: { existing in
            if let normalizedDeviceId,
               let existingId = sanitizeStableDeviceId(existing.deviceId),
               existingId == normalizedDeviceId {
                return true
            }
            if let normalizedFingerprint,
               let existingFingerprint = sanitizePubKeyFingerprint(existing.pubKeyFP),
               existingFingerprint == normalizedFingerprint {
                return true
            }
            return false
        }) {
            return strongIndex
        }

        guard let routeIdentifier = P2PDiscoveryBonjourPolicy.preferredRoutableBonjourIdentifier(for: candidate),
              let normalizedRouteIdentifier = P2PDiscoveryBonjourPolicy.normalizeIdentifierForMatching(routeIdentifier) else {
            return nil
        }

        let routeMatchedIndexes = devices.indices.filter {
            discoveredDevice(
                devices[$0],
                hasNormalizedBonjourIdentifier: normalizedRouteIdentifier
            )
        }
        guard !routeMatchedIndexes.isEmpty else { return nil }

        if hasCompleteProtocolIdentity(
            deviceId: normalizedDeviceId,
            pubKeyFP: normalizedFingerprint
        ) {
            return routeMatchedIndexes.first(where: {
                !hasAnyProtocolIdentity(
                    deviceId: devices[$0].deviceId,
                    pubKeyFP: devices[$0].pubKeyFP
                )
            })
        }

        guard !hasProtocolIdentity else {
            return nil
        }

        return routeMatchedIndexes.first(where: {
            hasCompleteProtocolIdentity(
                deviceId: devices[$0].deviceId,
                pubKeyFP: devices[$0].pubKeyFP
            )
        }) ?? routeMatchedIndexes.first
    }

    nonisolated static func isRouteBoundProtocolMerge(
        existing: DiscoveredDevice,
        candidate: DiscoveredDevice
    ) -> Bool {
        guard let routeIdentifier = P2PDiscoveryBonjourPolicy.preferredRoutableBonjourIdentifier(for: candidate),
              let normalizedRouteIdentifier = P2PDiscoveryBonjourPolicy.normalizeIdentifierForMatching(routeIdentifier),
              discoveredDevice(existing, hasNormalizedBonjourIdentifier: normalizedRouteIdentifier) else {
            return false
        }

        let existingComplete = hasCompleteProtocolIdentity(
            deviceId: existing.deviceId,
            pubKeyFP: existing.pubKeyFP
        )
        let candidateComplete = hasCompleteProtocolIdentity(
            deviceId: candidate.deviceId,
            pubKeyFP: candidate.pubKeyFP
        )
        let existingHasAnyIdentity = hasAnyProtocolIdentity(
            deviceId: existing.deviceId,
            pubKeyFP: existing.pubKeyFP
        )
        let candidateHasAnyIdentity = hasAnyProtocolIdentity(
            deviceId: candidate.deviceId,
            pubKeyFP: candidate.pubKeyFP
        )

        if existingComplete && !candidateHasAnyIdentity {
            return true
        }
        if candidateComplete && !existingHasAnyIdentity {
            return true
        }
        return false
    }

    nonisolated static func preferredDeviceSource(
        existing: DeviceSource,
        candidate: DeviceSource
    ) -> DeviceSource {
        candidate == .unknown ? existing : candidate
    }

    nonisolated static func hasCompleteProtocolIdentity(
        deviceId: String?,
        pubKeyFP: String?
    ) -> Bool {
        sanitizeStableDeviceId(deviceId) != nil && sanitizePubKeyFingerprint(pubKeyFP) != nil
    }

    nonisolated static func hasAnyProtocolIdentity(
        deviceId: String?,
        pubKeyFP: String?
    ) -> Bool {
        sanitizeStableDeviceId(deviceId) != nil || sanitizePubKeyFingerprint(pubKeyFP) != nil
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

    nonisolated private static func preferredUniqueIdentifier(
        deviceId: String?,
        pubKeyFP: String?,
        bonjourID: String?,
        ipv4: String?,
        ipv6: String?
    ) -> String? {
        if let id = sanitizeStableDeviceId(deviceId) {
            return "id:\(id)"
        }
        if let fp = sanitizePubKeyFingerprint(pubKeyFP) {
            return "fp:\(fp)"
        }
        if let bonjourID, !bonjourID.isEmpty {
            return bonjourID
        }
        if let ipv4 = ipv4?.trimmingCharacters(in: .whitespacesAndNewlines), !ipv4.isEmpty {
            return "ip:\(ipv4)"
        }
        if let ipv6 = ipv6?.trimmingCharacters(in: .whitespacesAndNewlines), !ipv6.isEmpty {
            return "ip:\(ipv6)"
        }
        return nil
    }

    nonisolated static func usbPresenceIdentifier(
        serialNumber: String?,
        deviceID: String?
    ) -> String? {
        for raw in [serialNumber, deviceID] {
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                continue
            }
            return "serial:\(value)"
        }
        return nil
    }

    nonisolated private static func bonjourIdentifier(from endpoint: NWEndpoint) -> String? {
        guard case .service(let name, _, let domain, _) = endpoint else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDomain = trimmedDomain.isEmpty ? "local." : trimmedDomain.lowercased()
        return "bonjour:\(trimmedName)@\(normalizedDomain)"
    }

    nonisolated private static func sanitizeStableDeviceId(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        guard value.count >= 8 else { return nil }
        return value
    }

    nonisolated private static func sanitizePubKeyFingerprint(_ raw: String?) -> String? {
        BonjourInteropContract.normalizedPubKeyFingerprint(raw)
    }

    private func handleBrowserStateUpdate(_ state: NWBrowser.State, for serviceType: String, browser: NWBrowser? = nil) {
        switch state {
        case .ready:
            logger.info("🔍 浏览器就绪: \(serviceType)")
        case .failed(let error):
            logger.error("❌ 浏览器失败 [\(serviceType)]: \(error)")
            // NWBrowser 进入 .failed 后不会自行恢复。取消它并从活动列表移除；对于非核心服务类型，
            // 标记为不可浏览，避免重启发现时反复重建并触发 -65555 策略拒绝 churn。
            browser?.cancel()
            if let browser {
                browsers.removeAll { $0 === browser }
            }
            if !coreServiceTypes.contains(serviceType) {
                knownUnsupportedServiceTypes.insert(serviceType)
                logger.info("🚫 标记不可浏览的服务类型，停止重试: \(serviceType)")
            }
        case .cancelled:
            logger.info("⏹️ 浏览器已取消: \(serviceType)")
        default:
            break
        }
    }

    private func handleConnectionStateUpdate(_ state: NWConnection.State, for deviceId: String) {
        Task { @MainActor in
            switch state {
            case .ready:
                connectionStatus = .connected
            case .failed, .cancelled:
                connections.removeValue(forKey: deviceId)
                if connections.isEmpty {
                    connectionStatus = .disconnected
                }
            default:
                break
            }
        }
    }

 // 处理传入连接（统一入口），避免在后台队列直接操作 UI/状态
    @MainActor
    private func handleIncomingConnection(_ connection: NWConnection) {
        // 等连接就绪后再启动入站读取/握手，避免在 .preparing 时启动导致循环直接退出
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Task(priority: .userInitiated) {
                    await Self.consumeInboundHandshakeOrControlChannel(connection)
                }
            case .failed, .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
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

        // IPv6 debug strings often append ".<ephemeralPort>".
        if token.contains(":"),
           let dot = token.lastIndex(of: "."),
           token[token.index(after: dot)...].allSatisfy({ $0.isNumber }) {
            token = String(token[..<dot])
        } else {
            // IPv4 debug string may appear as "a.b.c.d.<port>" (5 components).
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

    nonisolated private static func consumeInboundHandshakeOrControlChannel(_ connection: NWConnection) async {
        let logger = Logger(subsystem: "com.skybridge.discovery.optimized", category: "InboundHandshake")

        // 理论上只会在 .ready 时调用，但这里加一层兜底，避免 race
        if connection.state != .ready {
            logger.info("⏳ 入站连接尚未 ready，等待就绪… current=\(String(describing: connection.state), privacy: .public)")
            let becameReady = await waitUntilReady(connection, timeoutSeconds: 3.0)
            logger.info("⏳ 入站连接等待结束: ready=\(becameReady, privacy: .public) state=\(String(describing: connection.state), privacy: .public)")
        }

        struct DirectHandshakeTransport: DiscoveryTransport {
            let connection: NWConnection
            func send(to peer: PeerIdentifier, data: Data) async throws {
                let framed = try P2PControlFramePolicy.frame(body: data)
                try await DeviceDiscoveryManagerOptimized.sendContent(
                    framed,
                    on: connection,
                    timeoutSeconds: 5.0
                )
            }
        }

        let framedReader = FramedReader.nwConnection(connection)

        let transport = DirectHandshakeTransport(connection: connection)

        // Use a stable peer id aligned with iOS discovery (bonjour:<name>@<domain>) when possible.
        // This avoids churn across reconnects and improves trust/pairing semantics.
        let peerDeviceId = stablePeerIdentifier(for: connection.endpoint)
        let endpointHostOrIP: String? = {
            if case let .hostPort(host, _) = connection.endpoint {
                return String(describing: host)
            }
            return nil
        }()
        let classicTransferSessionId = "discovery-optimized-inbound:\(UUID().uuidString)"
        let localIdentityDeviceId: String
        do {
            localIdentityDeviceId = try await SelfIdentityProvider.shared
                .protocolIdentityDeviceId(allowCreate: true)
        } catch {
            logger.error(
                "❌ optimized inbound handshake local identity unavailable: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
            )
            connection.cancel()
            return
        }
        let localSOAPeerId = soaPeerIdBytes(from: localIdentityDeviceId)
        var expectedRemoteSOAPeerId: Data?
        var inboundPairKey: Data?
        var establishedArbiterLease: PeerSessionArbiter.EstablishedLease?
        var driver: HandshakeDriver?
        var presenceLease: ConnectionPresenceService.PresenceLease?
        var classicTransferSessionLease: ClassicTransferSessionRegistry.SessionLease?
        let peer = PeerIdentifier(deviceId: peerDeviceId)
        
        // Precompute identity info for heartbeat without crossing actor boundaries inside GCD timer handlers.
        let localIdForHeartbeat = localIdentityDeviceId

        // ⚠️ 关键修复：不要硬编码 classic-only。
        // iOS 26.2 会优先 PQC（ML-DSA-65 + ML-KEM-768）；如果 mac 端这里固定 Ed25519 会导致 suite 不一致，
        // 触发 iOS 端 fallback（再叠加 fallbackRateLimited 就会出现你截图里的循环失败）。
        var sessionKeys: SessionKeys? = nil
        var declaredDeviceIdForVerification: String? = nil
        var lastPairingIdentityExchangeReplyAt: Date? = nil
        var authenticatedRemoteAuthority: AuthenticatedRemoteAuthority? = nil
        var didMarkConnected = false
        var latestPeerCapabilities: [String] = []
        
        // Heartbeat: avoid Swift concurrency Tasks here (StrictConcurrency) because they would capture
        // mutable locals like `sessionKeys` and non-Sendable types like `NWConnection`, causing build errors.
        // Use an explicit GCD timer + async-safe critical state instead.
        struct HeartbeatState {
            var timer: DispatchSourceTimer?
            var sessionKeys: SessionKeys?
            var authority: AuthenticatedRemoteAuthority?
            var pausedForRekey: Bool
            var stopped: Bool
        }
        let hbState = OSAllocatedUnfairLock(initialState: HeartbeatState(
            timer: nil,
            sessionKeys: nil,
            authority: nil,
            pausedForRekey: false,
            stopped: false
        ))
        let closeForAuthenticatedHeartbeatFailure: @Sendable (String) -> Void = { errorSummary in
            let shouldClose = hbState.withLock { state in
                guard !state.stopped else { return false }
                state.stopped = true
                return true
            }
            guard shouldClose else { return }
            logger.error(
                "⛔️ authenticated heartbeat failed; closing session: error=\(errorSummary, privacy: .public)"
            )
            connection.cancel()
        }

        let peerIdForPresence = peer.deviceId
        let endpointDescriptionForPresence = stableEndpointLabel(for: connection.endpoint)

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
                    "⚠️ ignoring pairingIdentityExchange with empty declaredDeviceId: peer=\(peer.deviceId, privacy: .public) endpoint=\(endpointDescriptionForPresence, privacy: .public)"
                )
                return nil
            }
            return normalized
        }

        func validatedPairingIdentityAuthority(
            _ payload: AppMessage.PairingIdentityExchangePayload
        ) async -> ValidatedPairingIdentityAuthority? {
            await AuthenticatedProtocolIdentityBinding
                .validatedPairingIdentityAuthorityForPersistence(
                    payload: payload,
                    authority: authenticatedRemoteAuthority,
                    authenticatedRemoteSOAPeerId: expectedRemoteSOAPeerId,
                    sessionDeviceIds: [peer.deviceId, peerIdForPresence]
                )
        }

        func normalizedClassicTransferSessionAliases(_ values: [String?]) -> [String] {
            var normalized: [String] = []
            var seen = Set<String>()

            for value in values {
                for candidate in PeerTrustLookup.lookupCandidates(for: value) {
                    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    let lowered = trimmed.lowercased()
                    guard seen.insert(lowered).inserted else { continue }
                    normalized.append(trimmed)
                }
            }

            return normalized
        }

        func publishClassicTransferSessionSnapshot(keys: SessionKeys) async -> Bool {
            let declaredPeerId = trimmedIdentifier(declaredDeviceIdForVerification)
            let fallbackPeerId = trimmedIdentifier(peerDeviceId)
                ?? trimmedIdentifier(peerIdForPresence)
                ?? endpointDescriptionForPresence
            let primaryPeerId = declaredPeerId ?? fallbackPeerId
            let resolvedPeerDeviceId = PeerTrustLookup.persistentDeviceId(from: declaredPeerId)
                ?? PeerTrustLookup.persistentDeviceId(from: fallbackPeerId)
                ?? primaryPeerId
            let aliases = normalizedClassicTransferSessionAliases([
                declaredDeviceIdForVerification,
                primaryPeerId,
                peerDeviceId,
                endpointHostOrIP,
                endpointDescriptionForPresence
            ])
            let snapshot = ClassicTransferSessionSnapshot(
                sessionId: classicTransferSessionId,
                matchDeviceId: primaryPeerId,
                resolvedPeerDeviceId: resolvedPeerDeviceId,
                aliases: aliases,
                endpointHostOrIP: endpointHostOrIP,
                capabilities: latestPeerCapabilities,
                sessionKeys: keys
            )
            if let activeLease = classicTransferSessionLease {
                guard await ClassicTransferSessionRegistry.shared
                    .updateAuthenticatedSessionIfOwned(activeLease, snapshot: snapshot) else {
                    logger.error(
                        "⛔️ optimized inbound classic transfer owner was replaced; closing stale session"
                    )
                    connection.cancel()
                    return false
                }
            } else {
                classicTransferSessionLease = await ClassicTransferSessionRegistry.shared
                    .upsertOwned(session: snapshot)
            }
            return true
        }

        func cryptoKind(for suite: CryptoSuite) -> String {
            ConnectionCryptoPresentation.modeLabel(kind: nil, suite: suite.rawValue) ?? suite.rawValue
        }

        func displayNameFromPeerId(_ peerId: String) -> String? {
            // Format: bonjour:<name>@local.
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

        func extractIPFromPeerId(_ peerId: String) -> (ipv4: String?, ipv6: String?) {
            // Examples:
            // - peer:fe80::c47:6caa:...%en0.52802
            // - peer:192.168.0.104.53321
            guard peerId.hasPrefix("peer:") else { return (nil, nil) }
            var rest = String(peerId.dropFirst("peer:".count))
            // Drop trailing ".<port>" if present
            if let lastDot = rest.lastIndex(of: "."),
               rest[rest.index(after: lastDot)...].allSatisfy({ $0.isNumber }) {
                rest = String(rest[..<lastDot])
            }
            // Drop interface scope "%en0" for IPv6 comparisons
            let withoutScope = rest.split(separator: "%", maxSplits: 1).first.map(String.init) ?? rest
            if withoutScope.contains(":") {
                return (nil, withoutScope)
            }
            if withoutScope.contains(".") {
                return (withoutScope, nil)
            }
            return (nil, nil)
        }

        func postConnectedUX(keys: SessionKeys) async {
            guard !didMarkConnected else { return }
            didMarkConnected = true

            let suite = keys.negotiatedSuite
            let kind = cryptoKind(for: suite)
            let fallbackName = resolvedDisplayName(
                raw: nil,
                model: nil,
                platform: nil,
                fallbackPeerId: peerIdForPresence
            )
            let extracted = extractIPFromPeerId(peerIdForPresence)

            let publishedLease: ConnectionPresenceService.PresenceLease? = await MainActor.run {
                () -> ConnectionPresenceService.PresenceLease? in
                // Best-effort: map raw peer:<ip> to a known device name/address from unified discovery.
                let resolved: (name: String, address: String?) = {
                    let devices = UnifiedOnlineDeviceManager.shared.onlineDevices
                    if let v6 = extracted.ipv6,
                       let d = devices.first(where: { ($0.ipv6?.contains(v6) ?? false) }) {
                        return (d.name, d.ipv4 ?? d.ipv6 ?? v6)
                    }
                    if let v4 = extracted.ipv4,
                       let d = devices.first(where: { $0.ipv4 == v4 }) {
                        return (d.name, d.ipv4 ?? d.ipv6 ?? v4)
                    }
                    // If endpoint is a bonjour service, prefer that name.
                    if endpointDescriptionForPresence.contains("bonjour:") {
                        let bonjourName = endpointDescriptionForPresence
                            .replacingOccurrences(of: "bonjour:", with: "")
                            .split(separator: "@", maxSplits: 1)
                            .first
                            .map(String.init) ?? fallbackName
                        if let d = devices.first(where: { $0.name == bonjourName }) {
                            return (d.name, d.ipv4 ?? d.ipv6)
                        }
                        return (bonjourName, nil)
                    }
                    return (fallbackName, nil)
                }()
                let resolvedAddress = resolved.address ?? extracted.ipv4 ?? extracted.ipv6

                guard let lease = ConnectionPresenceService.shared.markConnectedOwned(
                    peerId: peerIdForPresence,
                    displayName: resolved.name,
                    address: resolvedAddress,
                    cryptoKind: kind,
                    suite: suite.rawValue
                ) else {
                    return nil
                }
                ConnectionPresenceService.shared.clearRekeying(peerId: peerIdForPresence)

                UnifiedOnlineDeviceManager.shared.markDeviceAsConnected(
                    peerId: peerIdForPresence,
                    displayName: resolved.name,
                    cryptoKind: kind,
                    suite: suite.rawValue,
                    guardStatus: "守护中"
                )

                SettingsManager.shared.sendSystemNotification(
                    title: "✅ 已连接 \(resolved.name)",
                    body: "\(kind) · \(suite.rawValue) · 守护连接中",
                    categoryIdentifier: "DISCOVERY_ALERT"
                )
                return lease
            }
            guard let publishedLease else {
                didMarkConnected = false
                logger.error("⛔️ optimized inbound presence publication failed; closing session")
                connection.cancel()
                return
            }
            presenceLease = publishedLease
        }

        func isLikelyHandshakeControlPacket(_ data: Data) -> Bool {
            // Handshake control frames include:
            // - MessageA/MessageB: first byte == protocolVersion
            // - FINISHED: magic "FIN1" (0x46 0x49 0x4E 0x31) + version + direction + mac
            //
            // If we misclassify FINISHED as "business ciphertext", we will try AES.GCM.open(...)
            // and log CryptoKitError, then *never* pass FINISHED into HandshakeDriver (stuck in waitingFinished).
            if data.count >= 4, data.prefix(4).elementsEqual([0x46, 0x49, 0x4E, 0x31]) {
                return true
            }
            // Fast path: first byte is protocol version for MessageA/MessageB.
            return data.first == HandshakeConstants.protocolVersion
        }

        func decryptAppPayload(_ ciphertext: Data, with keys: SessionKeys) throws -> Data {
            let key = SymmetricKey(data: keys.receiveKey)
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(box, using: key)
        }

        @Sendable func encryptAppPayload(_ plaintext: Data, with keys: SessionKeys) throws -> Data {
            let key = SymmetricKey(data: keys.sendKey)
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else {
                throw AuthenticatedAppPayloadCryptoError.combinedCiphertextUnavailable
            }
            return combined
        }

        func runSession() async throws {
        logger.info("🤝 入站连接：启用 HandshakeDriver 兼容通道（iOS 互通） state=\(String(describing: connection.state), privacy: .public)")

            while true {
                if case .failed = connection.state { break }
                if case .cancelled = connection.state { break }
                logger.debug("📥 等待入站帧（读取 4B length header）… state=\(String(describing: connection.state), privacy: .public)")
                let lenData = try await framedReader.receiveExactly(
                    P2PControlFramePolicy.lengthPrefixByteCount
                )
                let totalLen = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
                let bodyByteCount = try P2PControlFramePolicy.inboundBodyByteCount(
                    from: totalLen
                )
                let payload = try await framedReader.receiveExactly(bodyByteCount)
                logger.debug("📥 入站帧: \(payload.count, privacy: .public) bytes")
                // Phase C2: optional traffic padding (SBP2)
                let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx")
                // Phase C1: handshake padding (SBP1) used by iOS for MessageA/MessageB framing
                let frame = HandshakePadding.unwrapIfNeeded(trafficUnwrapped, label: "rx")

                // Rekey / renegotiation support:
                // Once a transport is already established, a fresh inbound MessageA can start a new handshake
                // on that same channel. If we keep the old driver, it treats the new MessageA as "unexpected"
                // (for example while waitingFinished), and the renegotiation fails spuriously.
                if let currentDriver = driver,
                   let messageA = try? HandshakeMessageA.decode(from: frame) {
                    let st = await currentDriver.getCurrentState()
                    switch st {
                    case .waitingFinished, .established:
                        if case .waitingFinished = st {
                            // No established lease exists yet, but the driver
                            // still owns an inbound reservation that must not be
                            // abandoned when a new MessageA restarts the flow.
                            await currentDriver.cancel()
                        }
                        if let inboundPairKey {
                            logger.info("🧩 inbound rekey: releasing SOA established guard peer=\(peerIdForPresence, privacy: .public)")
                            if case .established = st {
                                guard let activeLease = establishedArbiterLease,
                                      activeLease.pairKey == inboundPairKey,
                                      await PeerSessionArbiter.shared.clearEstablished(activeLease) else {
                                    logger.error(
                                        "⛔️ inbound rekey could not release exact SOA lease; closing session peer=\(peerIdForPresence, privacy: .public)"
                                    )
                                    connection.cancel()
                                    return
                                }
                                establishedArbiterLease = nil
                            }
                        }
                        let fromSuite = sessionKeys?.negotiatedSuite.rawValue ?? "?"
                        let fromKind = sessionKeys.map { cryptoKind(for: $0.negotiatedSuite) } ?? "?"
                        let toSuite = messageA.supportedSuites.first?.rawValue ?? "?"
                        let toKind = messageA.supportedSuites.first.map { cryptoKind(for: $0) } ?? "?"
                        Task { @MainActor in
                            ConnectionPresenceService.shared.markRekeying(.init(
                                peerId: peerIdForPresence,
                                fromKind: fromKind,
                                fromSuite: fromSuite,
                                toKind: toKind,
                                toSuite: toSuite
                            ))
                        }
                        hbState.withLock { $0.pausedForRekey = true }
                        logger.info("🔁 入站 rekey：\(fromKind)·\(fromSuite) -> \(toKind)·\(toSuite) peer=\(peerIdForPresence, privacy: .public)")
                        authenticatedRemoteAuthority = nil
                        driver = nil
                        sessionKeys = nil
                        if let activeClassicTransferSessionLease = classicTransferSessionLease {
                            _ = await ClassicTransferSessionRegistry.shared.remove(
                                ifOwned: activeClassicTransferSessionLease
                            )
                            classicTransferSessionLease = nil
                        }
                    default:
                        break
                    }
                }

                // Post-handshake: decrypt & handle app messages (pairingIdentityExchange, etc.)
                if let keys = sessionKeys, !isLikelyHandshakeControlPacket(frame) {
                    do {
                        let plaintext = try decryptAppPayload(frame, with: keys)
                        let msg = try AppMessage.decodeWireMessage(from: plaintext)
                        switch msg {
                            case .kemRefreshRequest, .signedKEMRefresh, .kemRefreshFailure,
                                 .protocolIdentityBindingRequest, .signedProtocolIdentityBinding,
                                 .protocolIdentityBindingConfirm, .signedProtocolIdentityBindingFinalAck:
                                break
                            case .heartbeat(let hb):
                                guard let activeClassicTransferSessionLease = classicTransferSessionLease,
                                      await ClassicTransferSessionRegistry.shared.refreshIfOwned(
                                        activeClassicTransferSessionLease,
                                        capabilities: hb.capabilities,
                                        fileTransferPort: hb.fileTransferPort,
                                        remoteControlPort: hb.remoteControlPort
                                      ) else {
                                    logger.error(
                                        "⛔️ optimized inbound classic transfer heartbeat lost exact owner; closing stale session"
                                    )
                                    connection.cancel()
                                    return
                                }
                                // Best-effort: use heartbeat metadata to resolve the real device name/id.
                                let suite = keys.negotiatedSuite
                                let kind = cryptoKind(for: suite)
                                let resolvedName: String? = {
                                    if let dn = hb.deviceName, !dn.isEmpty { return dn }
                                    if let model = hb.modelName, !model.isEmpty { return model }
                                    return nil
                                }()
                                if let resolvedName,
                                   let activePresenceLease = presenceLease {
                                    let didRefreshPresence = await MainActor.run {
                                        let extracted = extractIPFromPeerId(peerIdForPresence)
                                        let normalizedName = resolvedName
                                            .trimmingCharacters(in: .whitespacesAndNewlines)
                                            .lowercased()
                                        let devices = UnifiedOnlineDeviceManager.shared.onlineDevices
                                        let matched = devices.first { device in
                                            device.name
                                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                                .lowercased() == normalizedName
                                        }
                                        let resolvedAddress =
                                            matched?.ipv4
                                            ?? matched?.ipv6
                                            ?? extracted.ipv4
                                            ?? extracted.ipv6
                                        guard ConnectionPresenceService.shared.refreshConnectedIfOwned(
                                            activePresenceLease,
                                            displayName: resolvedName,
                                            address: resolvedAddress,
                                            cryptoKind: kind,
                                            suite: suite.rawValue
                                        ) else {
                                            return false
                                        }
                                        UnifiedOnlineDeviceManager.shared.markDeviceAsConnected(
                                            peerId: peerIdForPresence,
                                            displayName: resolvedName,
                                            cryptoKind: kind,
                                            suite: suite.rawValue,
                                            guardStatus: "守护中"
                                        )
                                        return true
                                    }
                                    guard didRefreshPresence else {
                                        logger.error(
                                            "⛔️ optimized inbound presence owner was replaced; closing stale session"
                                        )
                                        connection.cancel()
                                        return
                                    }
                                }
                            case .pairingIdentityExchange(let payload):
                                guard let payload = validatedPairingIdentityPayload(payload) else {
                                    connection.cancel()
                                    return
                                }
                                guard let validatedAuthority = await validatedPairingIdentityAuthority(payload) else {
                                    logger.error(
                                        "⛔️ inbound pairingIdentityExchange rejected before persistence: peer=\(Self.protocolIdentityLogRedaction, privacy: .public) declared=\(Self.protocolIdentityLogRedaction, privacy: .public) reason=identity_authority_unbound"
                                    )
                                    connection.cancel()
                                    return
                                }
                                guard let pairingAuthorityLease = authenticatedRemoteAuthority else {
                                    logger.error("⛔️ pairing identity exchange lost authenticated authority owner")
                                    connection.cancel()
                                    return
                                }
                                let pairingReservation: PairingIdentityExchangeCommitCoordinator.Reservation
                                do {
                                    pairingReservation = try await PairingIdentityExchangeCommitCoordinator
                                        .reserve(deviceIds: validatedAuthority.authorizedDeviceIds)
                                } catch {
                                    logger.error(
                                        "⛔️ pairing commit admission unavailable: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                                    )
                                    connection.cancel()
                                    return
                                }
                                let transportIsCurrent: @MainActor @Sendable () -> Bool = {
                                    let current = hbState.withLock { $0 }
                                    guard !Task.isCancelled,
                                          !current.pausedForRekey,
                                          !current.stopped,
                                          let currentKeys = current.sessionKeys,
                                          currentKeys.sessionId == keys.sessionId,
                                          currentKeys.transcriptHash == keys.transcriptHash,
                                          current.authority == pairingAuthorityLease else {
                                        return false
                                    }
                                    if case .ready = connection.state { return true }
                                    return false
                                }
                                guard await transportIsCurrent() else {
                                    _ = await PairingIdentityExchangeCommitCoordinator
                                        .rollback(pairingReservation)
                                    return
                                }
                                let endpoint = stableEndpointLabel(for: connection.endpoint)
                                let displayName: String = {
                                    resolvedDisplayName(
                                        raw: payload.deviceName,
                                        model: payload.modelName,
                                        platform: payload.platform,
                                        fallbackPeerId: peer.deviceId
                                    )
                                }()

                                declaredDeviceIdForVerification = validatedAuthority.declaredDeviceId
                                latestPeerCapabilities = payload.capabilities ?? []
                                let declaredDiagnosticLabel = SkyBridgeDiagnosticRedaction.stableIdentifierLabel(
                                    validatedAuthority.declaredDeviceId
                                )
                                await MainActor.run {
                                    PairingTrustApprovalService.shared.updateVerificationCode(
                                        declaredDeviceId: validatedAuthority.declaredDeviceId,
                                        sessionKeys: keys
                                    )
                                }

                                let policyBindingKey = PairingTrustApprovalService.policyBindingKey(
                                    declaredDeviceId: validatedAuthority.declaredDeviceId,
                                    algorithmRawValue: validatedAuthority.protocolSigningAlgorithm.rawValue,
                                    protocolPublicKeyFingerprint: validatedAuthority.protocolPublicKeyFingerprint
                                )

                                let request = PairingTrustApprovalService.Request(
                                    peerEndpoint: endpoint,
                                    declaredDeviceId: validatedAuthority.declaredDeviceId,
                                    policyBindingKey: policyBindingKey,
                                    displayName: displayName,
                                    model: payload.modelName,
                                    platform: payload.platform,
                                    osVersion: payload.osVersion,
                                    kemKeyCount: payload.kemPublicKeys.count
                                )
                                let decision = await PairingTrustApprovalService.shared.decide(for: request)
                                guard decision != PairingTrustApprovalService.Decision.reject else {
                                    _ = await PairingIdentityExchangeCommitCoordinator
                                        .rollback(pairingReservation)
                                    logger.info("🛑 Pairing/trust request rejected (no KEM reply): deviceId=\(declaredDiagnosticLabel, privacy: .public)")
                                    break
                                }

                                let commitReceipt: PairingIdentityExchangeCommitCoordinator.CommitReceipt
                                do {
                                    let result = try await PairingIdentityExchangeCommitCoordinator
                                        .commitAuthorityAndKEM(
                                            reservation: pairingReservation,
                                            payload: payload,
                                            authority: pairingAuthorityLease,
                                            displayName: displayName,
                                            platform: payload.platform,
                                            osVersion: payload.osVersion,
                                            isCurrent: transportIsCurrent
                                        )
                                    guard case .committed(let receipt) = result else { return }
                                    commitReceipt = receipt
                                } catch {
                                    logger.error(
                                        "⛔️ pairing authority/KEM persistence failed closed: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                                    )
                                    connection.cancel()
                                    return
                                }
                                let shouldReturnFromPairingHandler = try await
                                    PairingIdentityExchangeCommitCoordinator.withCommittedReceipt(
                                        commitReceipt
                                    ) {
                                guard await publishClassicTransferSessionSnapshot(keys: keys) else {
                                    return true
                                }
                                guard await PairingIdentityExchangeCommitCoordinator.isCurrent(
                                    commitReceipt,
                                    transportIsCurrent: transportIsCurrent
                                ) else {
                                    return true
                                }

                                let now = Date()
                                guard P2PDiscoveryService.shouldSendPairingIdentityExchangeReply(
                                    lastSentAt: lastPairingIdentityExchangeReplyAt,
                                    now: now
                                ) else {
                                    logger.debug("ℹ️ pairingIdentityExchange reply rate-limited during bootstrap")
                                    return false
                                }

                                // Reply with our KEM identity public keys (bootstrap for iOS initiator).
                                let provider = CryptoProviderFactory.make(policy: .preferPQC)
                                let km = DeviceIdentityKeyManager.shared
                                let kemKeys: [KEMPublicKeyInfo]
                                do {
                                    kemKeys = KEMPublicKeyInfo.normalizedValidKeys(
                                        try await km.pairingIdentityKEMPublicKeys(using: provider)
                                    )
                                } catch {
                                    logger.warning("⚠️ 本机 KEM 公钥准备失败（bootstrap reply）：\(error.localizedDescription, privacy: .public)")
                                    kemKeys = []
                                }
                                guard !kemKeys.isEmpty else {
                                    logger.warning("⚠️ 跳过 pairingIdentityExchange reply：本机无有效 KEM 公钥")
                                    return false
                                }
                                let localIdRaw = localIdentityDeviceId
                                let localId = localIdRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !localId.isEmpty else {
                                    logger.warning("⚠️ 跳过 pairingIdentityExchange reply：本机 deviceId 为空")
                                    return false
                                }
                                let localPresentation = LocalDevicePresentation.current()
                                let endpoints = ServiceEndpointRegistry.shared.snapshot()
                                let protocolIdentityPublicKeys = try await LocalProtocolIdentityAdvertisement.load()
                                let reply = AppMessage.pairingIdentityExchange(.init(
                                    deviceId: localId,
                                    kemPublicKeys: kemKeys,
                                    protocolIdentityPublicKeys: protocolIdentityPublicKeys,
                                    deviceName: localPresentation.deviceName,
                                    modelName: localPresentation.modelName,
                                    platform: localPresentation.platformName,
                                    osVersion: localPresentation.osVersion,
                                    chip: nil,
                                    capabilities: ["clipboard_sync", "file_transfer", "remote_desktop", "remote_control"],
                                    fileTransferPort: endpoints.fileTransferPort,
                                    remoteControlPort: endpoints.remoteControlPort
                                ))
                                let outPlain = try JSONEncoder().encode(reply)
                                let outCipher = try encryptAppPayload(outPlain, with: keys)
                                let outPadded = try TrafficPadding.wrapForP2PControlFrame(
                                    outCipher,
                                    label: "tx"
                                )
                                try await transport.send(to: peer, data: outPadded)
                                guard await PairingIdentityExchangeCommitCoordinator.isCurrent(
                                    commitReceipt,
                                    transportIsCurrent: transportIsCurrent
                                ) else {
                                    return true
                                }
                                lastPairingIdentityExchangeReplyAt = now
                                logger.info("🔑 已回传本机 KEM 公钥：count=\(kemKeys.count, privacy: .public) decision=\(decision.rawValue, privacy: .public)")
                                return false
                            }
                            if shouldReturnFromPairingHandler {
                                return
                            }
                            case .ping(let payload):
                                // RTT probe: respond as fast as possible with an echoed pong.
                                let reply = AppMessage.pong(.init(id: payload.id))
                                let outPlain = try JSONEncoder().encode(reply)
                                let outCipher = try encryptAppPayload(outPlain, with: keys)
                                let outPadded = try TrafficPadding.wrapForP2PControlFrame(
                                    outCipher,
                                    label: "tx"
                                )
                                try await transport.send(to: peer, data: outPadded)
                            case .pong:
                                break
                            default:
                                break
                        }
                    } catch {
                        logger.error(
                            "⛔️ authenticated app frame failed validation; closing session: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public)"
                        )
                        connection.cancel()
                        return
                    }
                    continue
                }

                // 延迟初始化：必须先看到 MessageA 才能知道对端 offeredSuites 属于 PQC 组还是 Classic 组，
                // 从而选择 sigAAlgorithm / provider / identity key。
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
                        let inboundProtocolIdentity: InboundProtocolIdentitySelection
                        do {
                            inboundProtocolIdentity = try await InboundProtocolIdentitySelectionPolicy.resolve(
                                messageA: messageA,
                                candidateDeviceIds: [peer.deviceId, endpointDescriptionForPresence]
                            )
                        } catch {
                            logger.error(
                                "❌ 入站协议身份选择失败: \(SkyBridgeDiagnosticRedaction.errorSummary(error), privacy: .public). peer=\(peer.deviceId, privacy: .public)"
                            )
                            return
                        }
                        let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
                        let requestedPolicy = HandshakePolicy.recommendedDefault(compatibilityModeEnabled: compatibilityModeEnabled)
                        // This pre-selection gate only evaluates the peer offer shape.
                        // Local PQC capability is checked after choosing the responder provider.
                        if let rejection = StrictPQCAdmissionGate.inboundRejection(
                            policy: requestedPolicy,
                            peerSupportedSuites: messageA.supportedSuites,
                            localPQCSuitesAvailable: true
                        ), rejection == .peerOfferedClassicOnly {
                            logger.error(
                                "❌ \(rejection.diagnosticMessage, privacy: .public). peer=\(peer.deviceId, privacy: .public)"
                            )
                            return
                        }

                        let effectivePolicy = requestedPolicy

                        // Choose provider first, then derive sigA/offeredSuites from local capability.
                        var selection: CryptoProviderFactory.SelectionPolicy = .classicOnly
                        var cryptoProvider: any CryptoProvider = CryptoProviderFactory.make(policy: .classicOnly)
                        var sigAAlgorithm: ProtocolSigningAlgorithm = .ed25519
                        var offeredSuites: [CryptoSuite] = cryptoProvider.supportedSuites.filter { !$0.isPQCGroup }

                        if inboundProtocolIdentity.algorithm != .ed25519 {
                            selection = (effectivePolicy.requirePQC ? .requirePQC : .preferPQC)
                            cryptoProvider = CryptoProviderFactory.makeInboundPQCResponderProvider(
                                policy: selection,
                                peerSupportedSuites: messageA.supportedSuites
                            )
                            let localPQCSuites = CryptoProviderFactory.handshakeOfferedPQCSuites(using: cryptoProvider)

                            if let rejection = StrictPQCAdmissionGate.inboundRejection(
                                policy: effectivePolicy,
                                peerSupportedSuites: messageA.supportedSuites,
                                localPQCSuitesAvailable: !localPQCSuites.isEmpty
                            ) {
                                logger.error(
                                    "❌ \(rejection.diagnosticMessage, privacy: .public). peer=\(peer.deviceId, privacy: .public)"
                                )
                                return
                            }

                            let compatibleSuites = InboundProtocolIdentitySelectionPolicy
                                .compatibleResponderPQCSuites(
                                    localPQCSuites,
                                    algorithm: inboundProtocolIdentity.algorithm
                                )
                            guard !compatibleSuites.isEmpty else {
                                logger.error(
                                    "❌ \(InboundProtocolIdentitySelectionError.noCompatibleResponderSuite(inboundProtocolIdentity.algorithm).localizedDescription, privacy: .public). peer=\(peer.deviceId, privacy: .public)"
                                )
                                return
                            }
                            sigAAlgorithm = inboundProtocolIdentity.algorithm
                            offeredSuites = compatibleSuites
                        } else {
                            selection = .classicOnly
                            cryptoProvider = CryptoProviderFactory.make(policy: selection)
                            sigAAlgorithm = .ed25519
                            offeredSuites = cryptoProvider.supportedSuites.filter { !$0.isPQCGroup }
                        }

                        let identityProvider = DeviceIdentityHandshakeProvider(
                            sigAAlgorithm: sigAAlgorithm,
                            protocolSigningKeyProtection: inboundProtocolIdentity.protection,
                            includeSecureEnclavePoP: effectivePolicy.requireSecureEnclavePoP
                        )

        do {
            let trustProvider: (any HandshakeTrustProvider)?
            let decodedMessageAIdentity = try? messageA.decodedIdentityPublicKeys()
            let messageAFingerprint = try? decodedMessageAIdentity?
                .authoritativeProtocolFingerprint()
                .lowercased()
            if let messageAFingerprint,
               await PeerProtocolIdentityBootstrapStore.shared.containsTrustedFingerprint(messageAFingerprint),
               let bootstrapProvider = BootstrapProtocolIdentityTrustProvider(
                    protocolIdentityFingerprint: messageAFingerprint,
                    protocolSigningAlgorithm: decodedMessageAIdentity.flatMap {
                        ProtocolSigningAlgorithm(from: $0.protocolAlgorithm)
                    },
                    protocolPublicKey: decodedMessageAIdentity?.protocolPublicKey
               ) {
                trustProvider = bootstrapProvider
                RemoteControlSmokeStatusWriter.append(
                    "mac-control-inbound handshake-bootstrap-pin matched fingerprint=\(messageAFingerprint) endpoint=\(endpointDescriptionForPresence)"
                )
            } else {
                trustProvider = nil
                RemoteControlSmokeStatusWriter.append(
                    "mac-control-inbound handshake-bootstrap-pin missing endpoint=\(endpointDescriptionForPresence)"
                )
            }
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
                                trustProvider: trustProvider,
                                localSOAPeerId: localSOAPeerId,
                                expectedRemoteSOAPeerId: expectedRemoteSOAPeerId
            )
                            logger.info("🤝 入站 HandshakeDriver 初始化完成: sigA=\(sigAAlgorithm.rawValue, privacy: .public) provider=\(String(describing: type(of: cryptoProvider)), privacy: .public)")
        } catch {
                            logger.error("❌ 入站 HandshakeDriver 初始化失败: \(error.localizedDescription, privacy: .public)")
                            return
                        }

                        // 继续处理当前这帧 MessageA（不要丢）
                    } else {
                        logger.debug("ℹ️ 入站首帧不是 MessageA（忽略，等待下一帧） size=\(frame.count, privacy: .public)")
                        continue
                    }
                }

                if let driver {
                    await driver.handleMessage(frame, from: peer)
                    let st = await driver.getCurrentState()
                    logger.debug("🤝 HandshakeDriver state: \(String(describing: st), privacy: .public)")

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
                        let establishedAuthority = await driver.getAuthenticatedRemoteAuthority()
                        authenticatedRemoteAuthority = establishedAuthority
                        let newArbiterLease = await driver.getEstablishedArbiterLease()
                        if let inboundPairKey {
                            guard let newArbiterLease,
                                  newArbiterLease.pairKey == inboundPairKey,
                                  newArbiterLease.sessionId == keys.sessionId else {
                                logger.error(
                                    "⛔️ inbound established without matching SOA lease; closing session peer=\(peerIdForPresence, privacy: .public)"
                                )
                                connection.cancel()
                                return
                            }
                        }
                        establishedArbiterLease = newArbiterLease
                        sessionKeys = keys
                        guard await publishClassicTransferSessionSnapshot(keys: keys) else {
                            return
                        }
                        await postConnectedUX(keys: keys)
                        if let declaredDeviceIdForVerification {
                            await MainActor.run {
                                PairingTrustApprovalService.shared.updateVerificationCode(
                                    declaredDeviceId: declaredDeviceIdForVerification,
                                    sessionKeys: keys
                                )
                            }
                        }
                        hbState.withLock {
                            $0.sessionKeys = keys
                            $0.authority = establishedAuthority
                            $0.pausedForRekey = false
                        }
                    default:
                        break
                    }
                }

                // Start heartbeat once we have session keys (only once).
                if hbState.withLock({ $0.timer }) == nil, sessionKeys != nil {
                    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                    timer.schedule(deadline: .now() + 10, repeating: 10)
                    timer.setEventHandler {
                        // Fast exit if the connection is no longer ready.
                        if connection.state != .ready { return }
                        
                        let snapshot = hbState.withLock { $0 }
                        let stopped = snapshot.stopped
                        let paused = snapshot.pausedForRekey
                        let keysNow = snapshot.sessionKeys
                        if stopped { return }
                        if paused { return }
                        guard let keysNow else { return }
                        
                        do {
                            // Build and encrypt the authenticated liveness frame. A failure means
                            // this control channel can no longer prove bidirectional liveness.
                            let localPresentation = LocalDevicePresentation.current()
                            let endpoints = ServiceEndpointRegistry.shared.snapshot()
                            let localIdentity = RemoteControlSecurityNoticeCenter.cachedLocalIdentitySnapshot()
                            let msg = AppMessage.heartbeat(.init(
                                sentAt: Date(),
                                deviceId: localIdForHeartbeat,
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
                            let plain = try JSONEncoder().encode(msg)
                            let cipher = try encryptAppPayload(plain, with: keysNow)
                            let padded = try TrafficPadding.wrapForP2PControlFrame(
                                cipher,
                                label: "tx/hb"
                            )
                            
                            // Frame length prefix (same as transport.send, but done inline to avoid async).
                            let framed = try P2PControlFramePolicy.frame(body: padded)
                            connection.send(content: framed, completion: .contentProcessed { error in
                                guard let error else { return }
                                closeForAuthenticatedHeartbeatFailure(
                                    SkyBridgeDiagnosticRedaction.errorSummary(error)
                                )
                            })
                        } catch {
                            closeForAuthenticatedHeartbeatFailure(
                                SkyBridgeDiagnosticRedaction.errorSummary(error)
                            )
                        }
                    }
                    timer.resume()
                    hbState.withLock { $0.timer = timer }
                }
            }
        }

        do {
            try await runSession()
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
        if let driver {
            switch await driver.getCurrentState() {
            case .idle, .established, .failed:
                break
            default:
                await driver.cancel()
            }
        }
        if let establishedArbiterLease {
            _ = await PeerSessionArbiter.shared.clearEstablished(establishedArbiterLease)
        }
        if let classicTransferSessionLease {
            _ = await ClassicTransferSessionRegistry.shared.remove(
                ifOwned: classicTransferSessionLease
            )
        }

        hbState.withLock {
            $0.stopped = true
            $0.timer?.cancel()
            $0.timer = nil
        }
        if let presenceLease {
            _ = await MainActor.run {
                ConnectionPresenceService.shared.disconnectIfOwned(presenceLease)
            }
        }
    }

    nonisolated private static func waitUntilReady(_ connection: NWConnection, timeoutSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if connection.state == .ready { return true }
            if case .failed = connection.state { return false }
            if case .cancelled = connection.state { return false }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch is CancellationError {
                return false
            } catch {
                SkyBridgeLogger.p2p.error(
                    "P2P readiness polling failed: errorType=\(String(reflecting: Swift.type(of: error)), privacy: .public)"
                )
                return false
            }
        }
        return connection.state == .ready
    }

 /// 获取设备展示名称（回退到通用名称以保证稳定）
    private func getDeviceName() -> String {
        return LocalHostName.localizedName ?? "SkyBridge-Device"
    }

 /// 非隔离版本的设备名解析，供后台方法使用
    nonisolated private static func resolveDeviceName() -> String {
        return LocalHostName.localizedName ?? "SkyBridge-Device"
    }

 // 处理监听器状态更新（主线程入口）
    @MainActor
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

    private func waitForConnection(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
 // 仅第一个解析者获得 true，确保 continuation 只 resume 一次
 // 用 @Sendable 闭包而非局部函数，以便在 @Sendable 的 stateUpdateHandler / asyncAfter 闭包中捕获
            let claim: @Sendable () -> Bool = {
                resumed.withLock { isResumed in
                    if isResumed { return false }
                    isResumed = true
                    return true
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard claim() else { return }
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    guard claim() else { return }
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard claim() else { return }
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: DeviceDiscoveryError.deviceNotConnected)
                default:
 // .setup/.preparing/.waiting 为瞬态；卡死的 .waiting 由下方超时兜底
                    break
                }
            }

 // 超时边界：避免不可达对端在 .waiting/.preparing 永久挂起。
            discoveryQueue.asyncAfter(deadline: .now() + 10.0) {
                guard claim() else { return }
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(throwing: DeviceDiscoveryError.connectionTimeout)
            }
        }
    }

    private final class SendContentContinuationContext: @unchecked Sendable {
        private let resumed = OSAllocatedUnfairLock(initialState: false)
        private let continuation: CheckedContinuation<Void, Error>
        private let connection: NWConnection
        var timeoutTask: Task<Void, Never>?

        init(continuation: CheckedContinuation<Void, Error>, connection: NWConnection) {
            self.continuation = continuation
            self.connection = connection
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

        func cancelConnection() {
            connection.cancel()
        }
    }

    nonisolated private static func sendContent(
        _ data: Data,
        on connection: NWConnection,
        timeoutSeconds: TimeInterval
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = SendContentContinuationContext(
                continuation: continuation,
                connection: connection
            )
            context.timeoutTask = Task {
                do {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                } catch is CancellationError {
                    return
                } catch {
                    context.cancelConnection()
                    context.complete(.failure(error))
                    return
                }
                context.cancelConnection()
                context.complete(.failure(DeviceDiscoveryError.connectionTimeout))
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
    private func applyLocalFlag(_ device: inout DiscoveredDevice, selfId: SelfIdentitySnapshot) {
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

 // 同步判定本机（使用内联实现避免异步复杂度）
        let local = resolveIsLocalSync(device: device, selfId: selfId)
        device.setIsLocalDeviceByDiscovery(local)
    }

 /// 同步版本复用唯一的强身份判定，避免异步/同步路径语义漂移。
    private func resolveIsLocalSync(device: DiscoveredDevice, selfId: SelfIdentitySnapshot) -> Bool {
        IdentityResolver.resolveIsLocalSynchronously(device: device, selfId: selfId)
    }

 /// 检查 IP 是否为本机 IP
    private func isLocalIP(_ ip: String) -> Bool {
 // 获取本机所有 IP 地址
        var ifaddrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrs) == 0 else { return false }
        defer { freeifaddrs(ifaddrs) }

        var interface = ifaddrs
        while interface != nil {
            defer { interface = interface?.pointee.ifa_next }
            guard let ifa = interface?.pointee,
                  let addr = ifa.ifa_addr else { continue }

            if addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
 // Swift 6.2: 使用 String(decoding:as:) 替代已弃用的 String(cString:)
                    let localIP = String(decoding: hostname.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if localIP == ip {
                        return true
                    }
                }
            }
        }
        return false
    }

 /// B. 刷新后清洗：对历史缓存污染进行一次性清洗
    private func sanitizeCache(_ selfId: SelfIdentitySnapshot) {
        for i in discoveredDevices.indices {
            applyLocalFlag(&discoveredDevices[i], selfId: selfId)
        }
        hardClampSingleLocalSync(selfId: selfId)
    }

 /// C. 周期末兜底（同步版本）：确保全局只有一个本机（"单机硬化"）
 /// 注意：异步版本见 `hardClampSingleLocal(selfId:) async`
    private func hardClampSingleLocalSync(selfId: SelfIdentitySnapshot) {
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
}

// MARK: - 设备缓存 Actor
actor DeviceCache {
    private var cache: [UUID: DiscoveredDevice] = [:]

    func add(_ device: DiscoveredDevice) {
        cache[device.id] = device
    }

    func remove(_ id: UUID) {
        cache.removeValue(forKey: id)
    }

    func getAll() -> [DiscoveredDevice] {
        Array(cache.values)
    }
}

// DiscoveredDevice 已经在其他地方实现了 Hashable
 // 动态服务类型收集器（actor保证并发安全）
    private actor ServiceTypeAccumulator {
        private var set: Set<String> = []
        func insert(_ t: String) { set.insert(t) }
        func snapshot() -> Set<String> { set }
    }
#endif
