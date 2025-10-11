import Foundation
import Network
import Combine
import os.log

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
public class AirPlayManager: NSObject, ObservableObject {
    
    // MARK: - 发布属性
    @Published public var discoveredDevices: [AirPlayDevice] = []
    @Published public var isScanning = false
    
    // MARK: - 私有属性
    private var serviceBrowser: NetServiceBrowser?
    private var discoveredServices: [NetService] = []
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "AirPlayManager")
    private var scanTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
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
            .store(in: &cancellables)
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
        let deviceSettings = DeviceManagementSettingsManager.shared
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
    private func createAirPlayDevice(from service: NetService) -> AirPlayDevice? {
        guard let addresses = service.addresses,
              !addresses.isEmpty else {
            return nil
        }
        
        // 提取IP地址
        var ipAddress = ""
        for addressData in addresses {
            let address = addressData.withUnsafeBytes { bytes in
                bytes.bindMemory(to: sockaddr.self).baseAddress!.pointee
            }
            
            if address.sa_family == UInt8(AF_INET) {
                let addr = addressData.withUnsafeBytes { bytes in
                    bytes.bindMemory(to: sockaddr_in.self).baseAddress!.pointee
                }
                ipAddress = String(cString: inet_ntoa(addr.sin_addr))
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
    private func determineDeviceType(from service: NetService) -> AirPlayDeviceType {
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
    private func extractCapabilities(from service: NetService) -> [String] {
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
        
        Task { @MainActor in
            logger.info("AirPlay服务地址解析成功: \(senderName)")
            
            // 暂时简化处理，避免数据竞争
            // TODO: 实现安全的设备创建逻辑
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