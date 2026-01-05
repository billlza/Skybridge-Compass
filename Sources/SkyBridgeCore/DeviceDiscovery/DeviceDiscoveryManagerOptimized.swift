import Foundation
import Network
import OSLog
import Combine
import os
import Security

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
    private var listener: NWListener?
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
    
 // USB设备管理器
    private var usbManager: USBCConnectionManager?
    private var usbCancellable: AnyCancellable?
    
 // 服务类型瘦身 - 默认仅SkyBridge，兼容/调试模式可扩展其余类型
 // 服务类型分类 - 核心服务（默认扫描）
    private let coreServiceTypes = [
        "_skybridge._tcp",
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
    
    private func effectiveServiceTypes() -> [String] {
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
        
        return types
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
 // 使用序列号作为唯一标识符，如果没有序列号则使用设备ID
        let uniqueId = usbDevice.serialNumber ?? usbDevice.deviceID
        
 // 构建服务列表
        var services: [String] = ["USB"]
        services.append(contentsOf: usbDevice.capabilities)
        
        return DiscoveredDevice(
            id: UUID(),
            name: usbDevice.name,
            ipv4: nil, // USB设备没有IP地址
            ipv6: nil,
            services: services,
            portMap: [:],
            connectionTypes: [.usb],
            uniqueIdentifier: uniqueId,
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
        logger.info("🔍 开始高性能扫描（包括USB设备）")
        isScanning = true
        
 // 改为事件驱动 + 防抖，无需定时器
        
 // 在后台并发启动所有浏览器
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.startBrowsersConcurrently()
        }
        
 // 异步启动广播（捕获服务类型，避免在后台线程读取 MainActor 隔离状态）
        let serviceTypeForBroadcast = "_skybridge._tcp"
        Task.detached(priority: .utility) { [weak self, serviceTypeForBroadcast] in
            await self?.startAdvertisingBackground(serviceType: serviceTypeForBroadcast)
        }
        
 // 扫描USB设备
        Task { @MainActor [weak self] in
            await self?.scanUSBDevices()
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
        
 // 触发MFi设备扫描
        await usbManager.scanForMFiDevices()
        
 // 触发USB设备扫描
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
        Task.detached { [weak self] in
            guard let self = self else { return }
            await MainActor.run {
                for browser in self.browsers {
                    browser.cancel()
                }
                self.browsers.removeAll()
            }
        }
        
        stopAdvertising()
        
 // 扫描结束后清洗缓存，确保本机唯一性
        Task { [weak self] in
            let selfId = await SelfIdentityProvider.shared.snapshot()
            await MainActor.run {
                self?.sanitizeCache(selfId)
            }
        }
    }
    
 /// 连接到设备 - 完全异步
 /// 根据 enableIPv6Support 设置决定是否优先使用 IPv6 地址
    public func connectToDevice(_ device: DiscoveredDevice) async throws {
        logger.info("连接设备: \(device.name)")
        
 // 根据 IPv6 设置选择地址
        let hostAddress: String
        if enableIPv6Support, let ipv6 = device.ipv6, !ipv6.isEmpty {
 // 优先使用 IPv6 地址
            hostAddress = ipv6
            logger.info("🌐 使用 IPv6 地址连接: \(ipv6)")
        } else if let ipv4 = device.ipv4 {
 // 回退到 IPv4
            hostAddress = ipv4
            logger.info("🌐 使用 IPv4 地址连接: \(ipv4)")
        } else {
            throw DeviceDiscoveryError.deviceNotConnected
        }
        
        let host = NWEndpoint.Host(hostAddress)
        let portInt = device.portMap.values.first ?? 0
        guard portInt > 0 else { throw DeviceDiscoveryError.scanningFailed }
        let port = NWEndpoint.Port(integerLiteral: UInt16(portInt))
        let endpoint = NWEndpoint.hostPort(host: host, port: port)
 // 应用TLS配置（统一近距加密策略）
        let net = RemoteDesktopSettingsManager.shared.settings.networkSettings
        var connection: NWConnection
        if net.enableEncryption, let tls = TLSConfigurator.options(for: net.encryptionAlgorithm) {
            let tcp = NWProtocolTCP.Options()
            let params = NWParameters(tls: tls, tcp: tcp)
            if SettingsManager.shared.enablePQCHybridTLS {
 // 启用TLS混合协商能力检测（实际协商结果在verify_block中记录并发布到UI）
                logger.info("🔐 启用TLS混合协商能力检测")
                encryptionStatus = "TLS (hybrid candidate)"
            } else {
                encryptionStatus = "TLS"
            }
 // 设置SNI（Server Name Indication），使用目标地址作为服务器名称
 // 中文说明：SNI用于服务器选择证书；在隐私诊断开启时也用于展示。
            hostAddress.withCString { cstr in
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
                    sni: SettingsManager.shared.enableHandshakeDiagnostics ? hostAddress : nil
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
            connection = NWConnection(to: endpoint, using: params)
        } else {
            encryptionStatus = "不加密"
            connection = NWConnection(to: endpoint, using: .tcp)
        }
        connections[device.id.uuidString] = connection
        
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
 // 在兼容模式下，先动态扫描服务目录，再合并到有效服务类型集合
        var types = effectiveServiceTypes()
        if enableCompatibilityMode {
            let dynamicTypes = await discoverServiceTypesDynamic(timeoutSeconds: 3.0)
            let merged = Set(types).union(dynamicTypes)
 // 过滤自身目录类型与异常条目
            types = merged.filter { t in
                t != "_services._dns-sd._udp" && (t.contains("._tcp") || t.contains("._udp"))
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
        } catch {
 // 忽略取消错误
        }
        browser.cancel()
 // 读取 actor 内的最终快照
        return await accumulator.snapshot()
    }
    
 /// 启动单个浏览器（在后台队列）
 /// 根据 enableIPv6Support 设置配置网络参数
    private func startSingleBrowser(serviceType: String) async {
        let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: serviceDomain)
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
 // 根据 IPv6 设置配置协议栈
        if enableIPv6Support {
 // 允许 IPv4 和 IPv6 双栈
            parameters.requiredInterfaceType = .other
            logger.debug("🌐 浏览器启用 IPv6 双栈模式: \(serviceType)")
        } else {
 // 仅 IPv4
            parameters.requiredInterfaceType = .other
        }
        
        let browser = NWBrowser(for: descriptor, using: parameters)
        
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleBrowserStateUpdate(state, for: serviceType)
            }
        }
        
        browser.browseResultsChangedHandler = { [weak self] results, changes in
 // 在后台队列处理结果变化
            Task.detached(priority: .userInitiated) {
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
    
 /// 事件驱动的防抖刷新（200ms）
    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 200_000_000) // 200ms 防抖
                await self?.flushPendingUpdates()
            } catch {
 // 任务被取消时静默忽略，避免无谓日志
            }
        }
    }
    
 /// 刷新待处理的更新（批量UI更新）
    private func flushPendingUpdates() async {
        guard !pendingUpdates.isEmpty else { return }
        
        let updates = pendingUpdates
        pendingUpdates.removeAll()
        
 // 批量生成候选弱指纹并持久化，提高后续合并命中率
        let fpMap = await generateFingerprintsBatch(for: updates)
        
 // 获取本机强身份快照
        let selfId = await SelfIdentityProvider.shared.snapshot()
        
 // 批量更新设备列表（严格防止不同设备错误合并）
        for device in updates {
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
                    let betterName = sanitized.name.count > existingDevice.name.count ? sanitized.name : existingDevice.name
                    let mergedConnectionTypes = sanitized.connectionTypes.union(existingDevice.connectionTypes)
                    
                    let updatedDevice = DiscoveredDevice(
                        id: existingDevice.id,
                        name: betterName,
                        ipv4: sanitized.ipv4 ?? existingDevice.ipv4,
                        ipv6: sanitized.ipv6 ?? existingDevice.ipv6,
                        services: Array(Set(sanitized.services + existingDevice.services)),
                        portMap: sanitized.portMap.merging(existingDevice.portMap) { new, _ in new },
                        connectionTypes: mergedConnectionTypes,
                        uniqueIdentifier: sanitized.uniqueIdentifier ?? existingDevice.uniqueIdentifier,
                        signalStrength: sanitized.signalStrength ?? existingDevice.signalStrength,
                        isLocalDevice: false, // 强制非本机
                        deviceId: nil,
                        pubKeyFP: nil,
                        macSet: []
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
            let mergeIndex = await identityResolver.findMergeIndex(in: discoveredDevices, candidate: device, candidateFP: candidateFP)
            
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
                
                let strongMatch =
                    (validId(existingDevice.deviceId) && validId(device.deviceId) && existingDevice.deviceId == device.deviceId) ||
                    (validFP(existingDevice.pubKeyFP) && validFP(device.pubKeyFP) && existingDevice.pubKeyFP == device.pubKeyFP)
                
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
                    let betterName = device.name.count > merged.name.count ? device.name : merged.name
                    merged._updateDisplayNameIfAllowed(betterName)
                    merged.services = Array(Set(device.services + merged.services))
                    merged.portMap = device.portMap.merging(merged.portMap) { new, _ in new }
                    
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
                
                discoveredDevices[index] = merged
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
        for i in self.discoveredDevices.indices {
            let device = self.discoveredDevices[i]
            let isLocal = await identityResolver.resolveIsLocal(device, selfId: selfId)
            self.discoveredDevices[i].setIsLocalDeviceByDiscovery(isLocal)
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
                await removeDiscoveredDeviceAsync(from: result)
            case .changed(old: _, new: let new, flags: _):
                await updateDiscoveredDeviceAsync(from: new, serviceType: serviceType)
            case .identical:
                break
            @unknown default:
                break
            }
        }
    }
    
 /// 异步添加设备（在后台解析网络信息）
    private func addDiscoveredDeviceAsync(from result: NWBrowser.Result, serviceType: String) async {
 // 快速提取基本信息（不阻塞）
        let deviceName = extractDeviceNameQuick(from: result)
        let deviceId = UUID()
        
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
            services: [serviceType],
            portMap: [serviceType: 0],
            connectionTypes: [.wifi], // 网络发现默认为Wi-Fi
            uniqueIdentifier: nil,
            signalStrength: nil,
            isLocalDevice: false // 非SkyBridge服务默认非本机，后续由resolveIsLocal统一判定
        )
        
 // 立即添加到待处理更新（快速显示）
        await MainActor.run(resultType: Void.self) { [weak self] in
            self?.pendingUpdates.insert(tempDevice)
            self?.scheduleFlush()
        }
        
 // 在后台异步解析网络信息
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            let (ipv4, ipv6, port) = await self.extractNetworkInfoAsync(from: result)
            
 // 更新设备信息
            let updatedDevice = DiscoveredDevice(
                id: deviceId,
                name: deviceName,
                ipv4: ipv4,
                ipv6: ipv6,
                services: [serviceType],
                portMap: [serviceType: port],
                connectionTypes: [.wifi],
                uniqueIdentifier: ipv4 ?? ipv6,
                signalStrength: await self.measureLinkQuality(host: ipv4 ?? ipv6, port: port),
                isLocalDevice: false // 后续由 resolveIsLocal 统一判定
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
    
 /// 异步提取网络信息（使用NWConnection而非同步DNS）
    private func extractNetworkInfoAsync(from result: NWBrowser.Result) async -> (ipv4: String?, ipv6: String?, port: Int) {
        var port: Int = 0
        
        if case .service(_, _, let servicePort, _) = result.endpoint {
            port = Int(servicePort) ?? 0
        }
        
 // 使用 NWConnection 异步解析（不阻塞）
        guard case .service = result.endpoint else {
            return (nil, nil, port)
        }
        
 // 从接口快速获取IP（不使用DNS）
        var ipv4: String?
        var ipv6: String?
        
        if !result.interfaces.isEmpty {
            for interface in result.interfaces {
                if let addresses = await getIPAddressesForInterfaceAsync(interface.name) {
                    if ipv4 == nil { ipv4 = addresses.ipv4 }
                    if ipv6 == nil { ipv6 = addresses.ipv6 }
                }
            }
        }
        
        return (ipv4, ipv6, port)
    }

    private func measureLinkQuality(host: String?, port: Int) async -> Double? {
        guard let host = host else { return nil }
 // 🔧 修复：端口为 0 时使用常见端口进行测量
        let effectivePort = port > 0 ? port : 80  // 回退到 HTTP 端口
        let start = DispatchTime.now()
        return await withCheckedContinuation { continuation in
            let tcp = NWProtocolTCP.Options()
            let params = NWParameters(tls: nil, tcp: tcp)
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(effectivePort)))
            let conn = NWConnection(to: endpoint, using: params)
            
 // 🔧 修复：使用线程安全的状态管理类（Swift 6并发安全）
            final class ResumeState: @unchecked Sendable {
                private let lock = NSLock()
                private var _hasResumed = false
                
                var hasResumed: Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    return _hasResumed
                }
                
                func markResumed() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !_hasResumed else { return false }
                    _hasResumed = true
                    return true
                }
            }
            
            let state = ResumeState()
            
            conn.stateUpdateHandler = { connectionState in
                switch connectionState {
                case .ready:
 // 只有第一次调用会返回true
                    guard state.markResumed() else { return }
                    
                    let end = DispatchTime.now()
                    let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
                    let ms = Double(nanos) / 1_000_000.0
                    let clamped = max(0.0, min(200.0, ms))
                    let score = 100.0 - (clamped / 200.0) * 100.0
                    continuation.resume(returning: score)
                    conn.stateUpdateHandler = nil // 清理handler防止后续调用
                    conn.cancel()
                    
                case .failed(_), .cancelled:
 // 只有第一次调用会返回true
                    guard state.markResumed() else { return }
                    
                    continuation.resume(returning: nil)
                    conn.stateUpdateHandler = nil // 清理handler
                    
                default:
                    break
                }
            }
            conn.start(queue: discoveryQueue)
            
 // 🔧 添加超时机制，防止永不resume
            discoveryQueue.asyncAfter(deadline: .now() + 3.0) {
                guard state.markResumed() else { return }
                
                continuation.resume(returning: nil)
                conn.stateUpdateHandler = nil
                conn.cancel()
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
                      String(decoding: Data(bytes: ifa.ifa_name, count: Int(strlen(ifa.ifa_name))), as: UTF8.self) == interfaceName,
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
    
    private func removeDiscoveredDeviceAsync(from result: NWBrowser.Result) async {
 // 精确移除（基于设备名称）
        if case .service(let name, _, _, _) = result.endpoint {
            let cleanName = name.replacingOccurrences(of: "._tcp", with: "")
                               .replacingOccurrences(of: ".local", with: "")
            
            await MainActor.run {
 // 只移除完全匹配的设备
                discoveredDevices.removeAll { device in
                    let deviceCleanName = device.name.filter { $0.isLetter || $0.isNumber }
                    let targetCleanName = cleanName.filter { $0.isLetter || $0.isNumber }
                    return deviceCleanName == targetCleanName && !targetCleanName.isEmpty
                }
            }
        }
    }
    
    private func updateDiscoveredDeviceAsync(from result: NWBrowser.Result, serviceType: String) async {
 // 更新现有设备信息（不添加新设备）
        let deviceName = extractDeviceNameQuick(from: result)
        let (ipv4, ipv6, port) = await extractNetworkInfoAsync(from: result)
        
        await MainActor.run {
 // 查找现有设备
            if let index = discoveredDevices.firstIndex(where: { existingDevice in
                if let existingIPv4 = existingDevice.ipv4, let newIPv4 = ipv4, existingIPv4 == newIPv4 {
                    return true
                }
                let cleanExistingName = existingDevice.name.filter { $0.isLetter || $0.isNumber }
                let cleanNewName = deviceName.filter { $0.isLetter || $0.isNumber }
                return cleanExistingName == cleanNewName && !cleanNewName.isEmpty
            }) {
 // 更新现有设备（重新创建以更新不可变属性）
                let existingDevice = discoveredDevices[index]
                var newServices = existingDevice.services
                var newPortMap = existingDevice.portMap
                
                if !existingDevice.services.contains(serviceType) {
                    newServices.append(serviceType)
                    newPortMap[serviceType] = port
                }
                
                let updatedDevice = DiscoveredDevice(
                    id: existingDevice.id,
                    name: existingDevice.name,
                    ipv4: ipv4 ?? existingDevice.ipv4,
                    ipv6: ipv6 ?? existingDevice.ipv6,
                    services: newServices,
                    portMap: newPortMap,
                    connectionTypes: existingDevice.connectionTypes,
                    uniqueIdentifier: existingDevice.uniqueIdentifier
                )
                discoveredDevices[index] = updatedDevice
                logger.debug("🔄 更新设备: \(deviceName)")
            }
        }
    }
    
    private func handleBrowserStateUpdate(_ state: NWBrowser.State, for serviceType: String) {
 // 异步记录日志，不阻塞
        Task.detached(priority: .background) { [weak self] in
            switch state {
            case .ready:
                self?.logger.info("🔍 浏览器就绪: \(serviceType)")
            case .failed(let error):
                self?.logger.error("❌ 浏览器失败 [\(serviceType)]: \(error)")
            case .cancelled:
                self?.logger.info("⏹️ 浏览器已取消: \(serviceType)")
            default:
                break
            }
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
    
    private func startAdvertising() {
 // 在后台异步启动 Bonjour 广播，避免占用主线程 RunLoop
        logger.info("📡 开始广播")
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
 // 使用统一广播中心，确保同一服务类型只存在一个 NWListener，且运行在全局队列
            do {
                let serviceType = "_skybridge._tcp"
                let port = try await ServiceAdvertiserCenter.shared.startAdvertising(
                    serviceName: self.getDeviceName(),
                    serviceType: serviceType,
                    connectionHandler: { [weak self] connection in
                        Task { @MainActor in self?.handleIncomingConnection(connection) }
                    },
                    stateHandler: { [weak self] state in
                        Task { @MainActor in self?.handleListenerStateUpdate(state) }
                    }
                )
                if port > 0 {
                    self.logger.info("📡 广播服务已启动，端口: \(port, privacy: .public)")
                } else {
                    self.logger.info("📡 广播服务已启动（系统分配端口）")
                }
            } catch {
                self.logger.error("❌ 启动广播服务失败: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

 /// 非隔离后台方法，用于在后台任务环境中启动广播，避免跨 MainActor 调用
    nonisolated func startAdvertisingBackground(serviceType: String) async {
        let bgLogger = Logger(subsystem: "com.skybridge.discovery.optimized", category: "BackgroundAdvertising")
        bgLogger.info("📡 开始广播")
        do {
 // 门闩去重——若同类型广播已在运行则直接返回，避免 stop→start 风暴
            if await ServiceAdvertiserCenter.shared.isAdvertising(serviceType) {
                bgLogger.debug("📡 广播已在运行，忽略重复启动: \(serviceType)")
                return
            }
            let port = try await ServiceAdvertiserCenter.shared.startAdvertising(
                serviceName: Self.resolveDeviceName(),
                serviceType: serviceType,
                connectionHandler: { [weak self] connection in
                    Task { @MainActor in self?.handleIncomingConnection(connection) }
                },
                stateHandler: { [weak self] state in
                    Task { @MainActor in self?.handleListenerStateUpdate(state) }
                }
            )
            if port > 0 {
                bgLogger.info("📡 广播服务已启动，端口: \(port, privacy: .public)")
            } else {
                bgLogger.info("📡 广播服务已启动（系统分配端口）")
            }
        } catch {
            bgLogger.error("❌ 启动广播服务失败: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    private func stopAdvertising() {
        listener?.cancel()
        listener = nil
    }

 // 处理传入连接（统一入口），避免在后台队列直接操作 UI/状态
    @MainActor
    private func handleIncomingConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
    }

 /// 获取设备展示名称（回退到通用名称以保证稳定）
    private func getDeviceName() -> String {
        return Host.current().localizedName ?? "SkyBridge-Device"
    }

 /// 非隔离版本的设备名解析，供后台方法使用
    nonisolated private static func resolveDeviceName() -> String {
        return Host.current().localizedName ?? "SkyBridge-Device"
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
            connection.stateUpdateHandler = { state in
                let shouldResume = resumed.withLock { isResumed -> Bool in
                    guard !isResumed else { return false }
                    switch state {
                    case .ready, .failed:
                        return true
                    default:
                        return false
                    }
                }
                
                guard shouldResume else { return }
                
 // 标记为已恢复，避免重复调用
 // withLock 返回闭包的值，这里闭包返回 Void，不需要返回值
                resumed.withLock { isResumed in
                    isResumed = true
                }
                
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
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
        
 // 🔧 修复：优先级 D - 主机名匹配（用于 Bonjour 发现的本机服务）
 // 当设备没有强身份字段时，通过主机名判定本机
        if let localHostname = Host.current().localizedName {
            let deviceNameLower = device.name.lowercased()
            let hostnameLower = localHostname.lowercased()
 // 检查设备名是否包含本机主机名（如 "Lza的MacBook Pro" 包含 "lza的macbook pro"）
            if deviceNameLower == hostnameLower || 
               deviceNameLower.contains(hostnameLower) ||
               hostnameLower.contains(deviceNameLower) {
 // 额外检查：确保是 SkyBridge 服务或本机 IP
                if device.services.contains(where: { $0.lowercased().contains("skybridge") }) {
                    return true
                }
 // 检查 IP 是否为本机 IP
                if let ipv4 = device.ipv4, isLocalIP(ipv4) {
                    return true
                }
            }
        }
        
        return false
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
