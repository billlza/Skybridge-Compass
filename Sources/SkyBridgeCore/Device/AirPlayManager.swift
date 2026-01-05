import Foundation
import Network
import Combine
import os.log
import CryptoKit

/// AirPlay设备信息模型
public struct AirPlayDevice: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let name: String
    public let identifier: String
    public let ipAddress: String
    public let port: Int
    public let deviceType: AirPlayDeviceType
    public let capabilities: [String]
    public let isAvailable: Bool
    public let lastSeen: Date
    
    public init(name: String, identifier: String, ipAddress: String, port: Int, deviceType: AirPlayDeviceType, capabilities: [String], isAvailable: Bool, lastSeen: Date = Date()) {
        self.name = name
        self.identifier = identifier
        self.ipAddress = ipAddress
        self.port = port
        self.deviceType = deviceType
        self.capabilities = capabilities
        self.isAvailable = isAvailable
        self.lastSeen = lastSeen
    }
    
 /// 设备类型描述
    public var deviceTypeDescription: String {
        switch deviceType {
        case .appleTV:
            return "Apple TV"
        case .homePod:
            return "HomePod"
        case .homePodMini:
            return "HomePod mini"
        case .speaker:
            return "扬声器"
        case .display:
            return "显示器"
        case .unknown:
            return "未知设备"
        }
    }
    
 /// 设备状态描述
    public var statusDescription: String {
        return isAvailable ? "可用" : "不可用"
    }
}

/// AirPlay设备类型
public enum AirPlayDeviceType: String, CaseIterable, Sendable {
    case appleTV = "Apple TV"
    case homePod = "HomePod"
    case homePodMini = "HomePod mini"
    case speaker = "扬声器"
    case display = "显示器"
    case unknown = "未知"
    
    public var iconName: String {
        switch self {
        case .appleTV:
            return "appletv"
        case .homePod, .homePodMini:
            return "homepod"
        case .speaker:
            return "speaker.wave.2"
        case .display:
            return "display"
        case .unknown:
            return "questionmark.circle"
        }
    }
}

/// AirPlay管理器 - 负责AirPlay设备的发现和管理
@MainActor
public class AirPlayManager: NSObject, ObservableObject, Sendable {
    
 // MARK: - 发布属性
    @Published public var discoveredDevices: [AirPlayDevice] = []
    @Published public var isScanning = false
    
 // MARK: - 私有属性
    private var serviceBrowser: NetServiceBrowser?
    private var discoveredServices: [NetService] = []
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "AirPlayManager")
    private var scanTimer: Timer?
    private var airplayCancellables = Set<AnyCancellable>()
 /// 安全管理器（用于信任设备与安全策略校验）
 /// 中文说明：这里独立维护一份安全管理器实例，用于在发现阶段执行“自动信任”等策略；与P2P网络的安全管理器并行存在，不会影响其生命周期。
    private let securityManager = P2PSecurityManager()
    
 // AirPlay服务类型
    private let airplayServiceTypes = [
        "_airplay._tcp.",
        "_raop._tcp.",
        "_companion-link._tcp.",
        "_homekit._tcp."
    ]
    
 // MARK: - 初始化
    public override init() {
        super.init()
        setupServiceBrowser()
        setupSettingsObservers()
        logger.info("📺 AirPlay管理器初始化完成")
    }
    
 // MARK: - 生命周期管理方法
    
 /// 启动AirPlay管理器
    public func start() async throws {
        startScanning()
        logger.info("📺 AirPlay管理器已启动")
    }
    
 /// 停止AirPlay管理器
    public func stop() async {
        stopScanning()
        logger.info("📺 AirPlay管理器已停止")
    }
    
 /// 清理资源
    public func cleanup() {
        stopScanning()
        airplayCancellables.removeAll()
        logger.info("📺 AirPlay管理器资源已清理")
    }
    
 // MARK: - 公共方法
    
 /// 开始扫描AirPlay设备
    public func startScanning() {
        guard !isScanning else { return }
        
        isScanning = true
        discoveredServices.removeAll()
        discoveredDevices.removeAll()
        
 // 为每种服务类型启动扫描
        for serviceType in airplayServiceTypes {
            serviceBrowser?.searchForServices(ofType: serviceType, inDomain: "local.")
        }
        
 // 启动定期扫描
        startPeriodicScanning()
        
        logger.info("AirPlay设备扫描已启动")
    }
    
 /// 停止扫描AirPlay设备
    public func stopScanning() {
        isScanning = false
        serviceBrowser?.stop()
        scanTimer?.invalidate()
        scanTimer = nil
        logger.info("AirPlay设备扫描已停止")
    }
    
 /// 刷新设备列表
    public func refreshDevices() {
        if isScanning {
            stopScanning()
        }
        startScanning()
    }
    
 /// 连接到AirPlay设备
    public func connectToDevice(_ device: AirPlayDevice) async -> Bool {
        logger.info("尝试连接到AirPlay设备: \(device.name)")
        
 // 这里实现实际的AirPlay连接逻辑
 // 由于AirPlay连接需要复杂的协议实现，这里提供基础框架
        
        do {
 // 模拟连接过程
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1秒延迟
            
            logger.info("成功连接到AirPlay设备: \(device.name)")
            return true
        } catch {
            logger.error("连接AirPlay设备失败: \(error.localizedDescription)")
            return false
        }
    }
    
 // MARK: - 私有方法
    
 /// 设置服务浏览器
    private func setupServiceBrowser() {
        serviceBrowser = NetServiceBrowser()
        serviceBrowser?.delegate = self
    }
    
 /// 启动定期扫描
    private func startPeriodicScanning() {
        scanTimer?.invalidate()
        
 // 获取设备管理设置中的扫描间隔
        let deviceSettings = DeviceManagementSettingsManager.shared
        let scanInterval = deviceSettings.airplayScanInterval
        
        scanTimer = Timer.scheduledTimer(withTimeInterval: scanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDevices()
            }
        }
        
        logger.info("AirPlay定期扫描已启动，间隔: \(scanInterval)秒")
    }
    
 /// 设置观察者，监听设置变化
    private func setupSettingsObservers() {
 // 监听AirPlay设置变化的通知
        NotificationCenter.default.publisher(for: NSNotification.Name("AirPlaySettingsChanged"))
            .sink { [weak self] notification in
                Task { @MainActor in
                    await self?.handleSettingsChange(notification)
                }
            }
            .store(in: &airplayCancellables)
    }

 /// 获取本机IPv4地址（用于过滤本机服务，避免误加入）
 /// 中文说明：遍历系统网络接口，读取首个非回环IPv4地址；此方法仅在主线程内调用，避免与底层C API产生竞态。
    private func getLocalIPv4Address() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else {
            return nil
        }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let addr = current.pointee.ifa_addr
            if addr?.pointee.sa_family == sa_family_t(AF_INET) {
 // 排除回环接口
                if let namePtr = current.pointee.ifa_name {
 // 统一使用安全的 UTF8 C 字符串解码，替代已弃用的 String(cString:)
                    let name = decodeCString(namePtr)
                    if name.hasPrefix("lo") { cursor = current.pointee.ifa_next; continue }
                }

 // 转换地址为字符串
                var ipv4 = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard let addr = addr else { cursor = current.pointee.ifa_next; continue }
 // 安全地将通用sockaddr指针重绑定为sockaddr_in读取IPv4地址
                let sin = UnsafePointer<sockaddr_in>(OpaquePointer(addr)).pointee
                var sinAddr = sin.sin_addr
                inet_ntop(AF_INET, &sinAddr, &ipv4, socklen_t(INET_ADDRSTRLEN))
 // String(cString:) 已弃用；按建议截断到首个空字符并以 UTF8 解码
                let bytes = ipv4.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let ip = String(decoding: bytes, as: UTF8.self)
                if !ip.isEmpty { return ip }
            }
            cursor = current.pointee.ifa_next
        }
        return nil
    }
    
 /// 处理设置变化
    @MainActor
    private func handleSettingsChange(_ notification: Notification) async {
        guard let userInfo = notification.userInfo else { return }
        
 // 处理自动发现Apple TV设置
        if let autoDiscoverAppleTV = userInfo["autoDiscoverAppleTV"] as? Bool {
            if autoDiscoverAppleTV && !isScanning {
                startScanning()
                logger.info("自动发现Apple TV已启用")
            }
        }
        
 // 处理显示HomePod设备设置
        if let showHomePodDevices = userInfo["showHomePodDevices"] as? Bool {
 // 重新过滤设备列表
            filterDevicesBySettings()
            logger.info("HomePod设备显示设置已更新: \(showHomePodDevices)")
        }
        
 // 处理显示第三方AirPlay设备设置
        if let showThirdPartyDevices = userInfo["showThirdPartyAirPlayDevices"] as? Bool {
 // 重新过滤设备列表
            filterDevicesBySettings()
            logger.info("第三方AirPlay设备显示设置已更新: \(showThirdPartyDevices)")
        }
    }
    
 /// 根据设置过滤设备
    private func filterDevicesBySettings() {
        let _ = DeviceManagementSettingsManager.shared  // 保留引用但不使用
        let settingsManager = SettingsManager.shared
        
 // 根据设置过滤设备
        let filteredDevices = discoveredDevices.filter { device in
            switch device.deviceType {
            case .homePod, .homePodMini:
                return settingsManager.showHomePodDevices
            case .appleTV:
                return settingsManager.autoDiscoverAppleTV
            case .speaker, .display:
                return settingsManager.showThirdPartyAirPlayDevices
            case .unknown:
                return true // 默认显示未知设备
            }
        }
        
        discoveredDevices = filteredDevices
    }
    
 /// 处理发现的服务
    private func processDiscoveredService(_ service: NetService) {
 // 解析服务以获取详细信息
        service.delegate = self
        service.resolve(withTimeout: 5.0)
    }
    
 /// 从NetService创建AirPlayDevice
    nonisolated private func createAirPlayDevice(from service: NetService) -> AirPlayDevice? {
        guard let addresses = service.addresses,
              !addresses.isEmpty else {
            return nil
        }
        
 // 提取IP地址（使用 inet_ntop 替代 inet_ntoa，避免静态缓冲区与旧API问题）
        var ipAddress = ""
        for addressData in addresses {
            let family = addressData.withUnsafeBytes { bytes -> sa_family_t? in
                guard bytes.count >= MemoryLayout<sockaddr>.size,
                      let ptr = bytes.bindMemory(to: sockaddr.self).baseAddress else {
                    return nil
                }
                return ptr.pointee.sa_family
            }
            guard let family else { continue }
            
            if family == UInt8(AF_INET) {
                let addr = addressData.withUnsafeBytes { bytes -> sockaddr_in? in
                    guard bytes.count >= MemoryLayout<sockaddr_in>.size,
                          let ptr = bytes.bindMemory(to: sockaddr_in.self).baseAddress else {
                        return nil
                    }
                    return ptr.pointee
                }
                guard var addr else { continue }
 // 使用 inet_ntop 将 IPv4 地址写入缓冲区，再以 UTF8 安全解码。
                var ipv4Buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &addr.sin_addr, &ipv4Buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                    continue
                }
                let truncated = ipv4Buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                ipAddress = String(decoding: truncated, as: UTF8.self)
                break
            }
        }
        
        guard !ipAddress.isEmpty else { return nil }
        
 // 根据服务类型和名称判断设备类型
        let deviceType = determineDeviceType(from: service)
        let capabilities = extractCapabilities(from: service)
        
        return AirPlayDevice(
            name: service.name,
            identifier: "\(service.name)_\(ipAddress)_\(service.port)",
            ipAddress: ipAddress,
            port: service.port,
            deviceType: deviceType,
            capabilities: capabilities,
            isAvailable: true,
            lastSeen: Date()
        )
    }
    
 /// 确定设备类型
    nonisolated private func determineDeviceType(from service: NetService) -> AirPlayDeviceType {
        let name = service.name.lowercased()
        
        if name.contains("apple tv") {
            return .appleTV
        } else if name.contains("homepod mini") {
            return .homePodMini
        } else if name.contains("homepod") {
            return .homePod
        } else if service.type.contains("_raop") {
            return .speaker
        } else {
            return .unknown
        }
    }
    
 /// 提取设备功能
    nonisolated private func extractCapabilities(from service: NetService) -> [String] {
        var capabilities: [String] = []
        
 // 根据服务类型推断功能
        if service.type.contains("_airplay") {
            capabilities.append("视频播放")
            capabilities.append("音频播放")
        }
        
        if service.type.contains("_raop") {
            capabilities.append("音频播放")
        }
        
        if service.type.contains("_companion-link") {
            capabilities.append("设备控制")
        }
        
        return capabilities
    }
}

// MARK: - NetServiceBrowserDelegate
extension AirPlayManager: NetServiceBrowserDelegate {
    
    nonisolated public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let serviceName = service.name
        let serviceType = service.type
        
        Task { @MainActor in
            logger.info("发现AirPlay服务: \(serviceName) - \(serviceType)")
            
 // 避免重复添加
            if !discoveredServices.contains(where: { $0.name == serviceName && $0.type == serviceType }) {
 // 注意：这里不能直接添加service对象，因为会导致数据竞争
 // 我们需要在主线程上重新获取或创建服务对象
                logger.info("新发现AirPlay服务: \(serviceName)")
            }
            
            if !moreComing {
                logger.info("AirPlay服务发现完成")
            }
        }
    }
    
    nonisolated public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let serviceName = service.name
        let serviceType = service.type
        
        Task { @MainActor in
            logger.info("AirPlay服务离线: \(serviceName)")
            
 // 从服务列表中移除
            discoveredServices.removeAll { $0.name == serviceName && $0.type == serviceType }
            
 // 从设备列表中移除对应设备
            let serviceIdentifier = "\(serviceName)_"
            discoveredDevices.removeAll { $0.identifier.hasPrefix(serviceIdentifier) }
        }
    }
    
    nonisolated public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        Task { @MainActor in
            logger.error("AirPlay设备搜索失败: \(errorDict)")
            isScanning = false
        }
    }
}

// MARK: - NetServiceDelegate
extension AirPlayManager: NetServiceDelegate {

    nonisolated public func netServiceDidResolveAddress(_ sender: NetService) {
        let senderName = sender.name
 // 在当前（nonisolated）上下文中先解析出设备，避免跨actor传递非Sendable的NetService对象导致数据竞争。
        let parsedDevice = createAirPlayDevice(from: sender)

        Task { @MainActor in
            logger.info("AirPlay服务地址解析成功: \(senderName)")
            
 // 中文说明：从解析结果安全地创建设备对象，并进行本机过滤、设置过滤与安全策略处理。
            guard let newDevice = parsedDevice else {
                logger.error("无法从服务创建设备: \(senderName)")
                return
            }

 // 过滤本机设备（通过IP与主机名双重判定）
            if let localIP = getLocalIPv4Address(), newDevice.ipAddress == localIP {
                logger.info("🛑 过滤本机设备（IP匹配）: \(senderName) @ \(newDevice.ipAddress)")
                return
            }
            let localHostName = Host.current().localizedName ?? Host.current().name ?? ""
            if !localHostName.isEmpty {
                let loweredServiceName = senderName.lowercased()
                let loweredLocalName = localHostName.lowercased()
                if loweredServiceName == loweredLocalName || loweredServiceName.contains(loweredLocalName) {
                    logger.info("🛑 过滤本机设备（名称匹配）: \(senderName) ≈ \(localHostName)")
                    return
                }
            }

 // 根据设置执行设备类型过滤，避免列表抖动
            let settings = SettingsManager.shared
            switch newDevice.deviceType {
            case .homePod, .homePodMini:
                guard settings.showHomePodDevices else {
                    logger.info("按设置隐藏HomePod设备: \(newDevice.name)")
                    return
                }
            case .appleTV:
                guard settings.autoDiscoverAppleTV else {
                    logger.info("按设置隐藏Apple TV设备: \(newDevice.name)")
                    return
                }
            case .speaker, .display:
                guard settings.showThirdPartyAirPlayDevices else {
                    logger.info("按设置隐藏第三方AirPlay设备: \(newDevice.name)")
                    return
                }
            case .unknown:
                break
            }

 // 去重：若已存在则更新最后一次出现时间与能力信息
            if let existingIndex = discoveredDevices.firstIndex(where: { $0.identifier == newDevice.identifier }) {
                var updated = discoveredDevices[existingIndex]
 // 中文说明：保持原有可用状态，更新能力与时间戳
                updated = AirPlayDevice(
                    name: newDevice.name,
                    identifier: newDevice.identifier,
                    ipAddress: newDevice.ipAddress,
                    port: newDevice.port,
                    deviceType: newDevice.deviceType,
                    capabilities: newDevice.capabilities,
                    isAvailable: true,
                    lastSeen: Date()
                )
                discoveredDevices[existingIndex] = updated
                logger.info("更新已存在的AirPlay设备: \(updated.name)")
            } else {
 // 安全策略：自动信任同一网络环境下的已发现设备（受策略控制）
                if securityManager.policyAutoTrustEnabled {
                    securityManager.addTrustedDevice(newDevice.identifier)
                    logger.info("已添加信任设备ID: \(newDevice.identifier)")
                }
                discoveredDevices.append(newDevice)
                logger.info("新加入AirPlay设备: \(newDevice.name)")
            }
            
            logger.info("AirPlay设备解析完成: \(senderName)")
        }
    }
    
    nonisolated public func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        let senderName = sender.name
        Task { @MainActor in
            logger.error("AirPlay设备解析失败: \(senderName) - \(errorDict)")
        }
    }
}

// MARK: - 扩展方法
extension AirPlayManager {
    
 /// 获取AirPlay统计信息
    public var airPlayStats: AirPlayStats {
        AirPlayStats(
            discoveredDevicesCount: discoveredDevices.count,
            availableDevicesCount: discoveredDevices.filter { $0.isAvailable }.count,
            deviceTypes: Set(discoveredDevices.map { $0.deviceType }),
            isScanning: isScanning
        )
    }
    
 /// AirPlay统计信息结构
    public struct AirPlayStats {
        public let discoveredDevicesCount: Int
        public let availableDevicesCount: Int
        public let deviceTypes: Set<AirPlayDeviceType>
        public let isScanning: Bool
    }
}
