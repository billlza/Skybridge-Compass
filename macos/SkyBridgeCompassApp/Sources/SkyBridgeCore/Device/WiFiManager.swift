import Foundation
import CoreWLAN
import CoreLocation
import Combine
import os.log

/// WiFi网络信息模型
public struct WiFiNetwork: Identifiable, Hashable {
    public let id = UUID()
    public let ssid: String
    public let bssid: String
    public let rssi: Int
    public let channel: Int
    public let security: WiFiSecurity
    public let isConnected: Bool
    public let frequency: Double
    
    public init(ssid: String, bssid: String, rssi: Int, channel: Int, security: WiFiSecurity, isConnected: Bool, frequency: Double) {
        self.ssid = ssid
        self.bssid = bssid
        self.rssi = rssi
        self.channel = channel
        self.security = security
        self.isConnected = isConnected
        self.frequency = frequency
    }
    
    /// 信号强度描述
    public var signalStrengthDescription: String {
        switch rssi {
        case -30...0:
            return "优秀"
        case -50...(-30):
            return "良好"
        case -70...(-50):
            return "一般"
        case -90...(-70):
            return "较差"
        default:
            return "很差"
        }
    }
    
    /// 信号强度百分比（0-100）
    public var signalStrengthPercentage: Double {
        // RSSI通常在-100到-30之间，转换为0-100的百分比
        let minRSSI: Double = -100
        let maxRSSI: Double = -30
        let clampedRSSI = max(minRSSI, min(maxRSSI, Double(rssi)))
        return ((clampedRSSI - minRSSI) / (maxRSSI - minRSSI)) * 100
    }
    
    /// 安全类型描述
    public var securityTypeDescription: String {
        switch security {
        case .none:
            return "开放"
        case .wep:
            return "WEP"
        case .wpa:
            return "WPA"
        case .wpa2:
            return "WPA2"
        case .wpa3:
            return "WPA3"
        case .enterprise:
            return "企业级"
        case .unknown:
            return "未知"
        }
    }
}

/// WiFi安全类型
public enum WiFiSecurity: String, CaseIterable {
    case none = "无加密"
    case wep = "WEP"
    case wpa = "WPA"
    case wpa2 = "WPA2"
    case wpa3 = "WPA3"
    case enterprise = "企业级"
    case unknown = "未知"
    
    public var iconName: String {
        switch self {
        case .none:
            return "wifi.slash"
        case .wep, .wpa:
            return "lock.trianglebadge.exclamationmark"
        case .wpa2, .wpa3:
            return "lock.wifi"
        case .enterprise:
            return "building.2.crop.circle"
        case .unknown:
            return "questionmark.circle"
        }
    }
}

/// WiFi接口状态
public enum WiFiInterfaceState {
    case unknown
    case inactive
    case scanning
    case authenticating
    case associating
    case running
}

/// WiFi管理器 - 负责WiFi网络的扫描、连接和管理
/// 使用 Swift 6.2 的 Actor 隔离和并发安全特性
@MainActor
public final class WiFiManager: ObservableObject, Sendable {
    
    // MARK: - 发布属性
    @Published public var availableNetworks: [WiFiNetwork] = []
    @Published public var currentNetwork: WiFiNetwork?
    @Published public var interfaceState: WiFiInterfaceState = .unknown
    @Published public var isScanning = false
    @Published public var hasPermission = false
    
    // MARK: - 私有属性
    private let wifiClient: CWWiFiClient
    private var wifiInterface: CWInterface?
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "WiFiManager")
    private var scanTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    /// 使用 Swift 6.2 的并发安全队列进行 WiFi 操作
    private let wifiQueue = DispatchQueue(label: "com.skybridge.wifi-manager", qos: .userInitiated, attributes: .concurrent)
    
    // MARK: - 初始化
    public init() {
        self.wifiClient = CWWiFiClient.shared()
        self.setupWiFiInterface()
        self.checkPermissions()
        self.setupSettingsObservers()
    }
    
    // MARK: - 公共方法
    
    /// 检查WiFi权限
    public func checkPermissions() {
        // 在macOS中，WiFi访问需要用户授权和位置权限
        // 首先检查位置权限
        let locationManager = CLLocationManager()
        let locationStatus = locationManager.authorizationStatus
        
        if locationStatus == .denied || locationStatus == .restricted {
            hasPermission = false
            logger.error("位置权限被拒绝，WiFi扫描需要位置权限")
            return
        }
        
        // 如果位置权限未确定，请求权限
        if locationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
            hasPermission = false
            logger.info("正在请求位置权限以支持WiFi扫描")
            return
        }
        
        // 检查WiFi接口权限
        do {
            // 尝试获取接口信息来检查权限
            if let interface = wifiInterface {
                _ = try interface.scanForNetworks(withSSID: nil)
                hasPermission = true
                logger.info("WiFi权限已获得")
            } else {
                hasPermission = false
                logger.error("WiFi接口不可用")
            }
        } catch {
            hasPermission = false
            logger.error("WiFi权限检查失败: \(error.localizedDescription)")
            
            // 如果是权限错误，提示用户
            if error.localizedDescription.contains("Operation not permitted") {
                logger.error("WiFi扫描需要位置权限，请在系统偏好设置中授权")
            }
        }
    }
    
    /// 开始扫描WiFi网络
    /// 使用 Swift 6.2 的并发安全特性
    public func startScanning() async {
        guard hasPermission else {
            logger.warning("没有WiFi权限，无法扫描")
            return
        }
        
        guard let interface = wifiInterface else {
            logger.error("WiFi接口不可用")
            return
        }
        
        logger.info("开始扫描WiFi网络")
        isScanning = true
        updateInterfaceState()
        
        do {
            // 直接在主线程上执行扫描，避免数据竞争
            let networks = try interface.scanForNetworks(withSSID: nil)
            await processScannedNetworks(networks)
            
            // 启动定期扫描（使用设置管理器中的间隔）
            startPeriodicScanning()
            
            logger.info("WiFi扫描完成，发现 \(networks.count) 个网络")
        } catch {
            logger.error("WiFi扫描失败: \(error.localizedDescription)")
            isScanning = false
        }
    }
    
    /// 停止扫描WiFi网络
    public func stopScanning() {
        isScanning = false
        scanTimer?.invalidate()
        scanTimer = nil
        logger.info("WiFi扫描已停止")
    }
    
    /// 连接到指定WiFi网络
    public func connect(to network: WiFiNetwork, password: String? = nil) async -> Bool {
        guard let interface = wifiInterface else {
            logger.error("WiFi接口不可用")
            return false
        }
        
        do {
            // 查找对应的CWNetwork对象
            let networks = try interface.scanForNetworks(withSSID: Data(network.ssid.utf8))
            guard let targetNetwork = networks.first(where: { $0.ssid == network.ssid }) else {
                logger.error("未找到目标网络: \(network.ssid)")
                return false
            }
            
            // 执行连接
            if let password = password, !password.isEmpty {
                try interface.associate(to: targetNetwork, password: password)
            } else {
                try interface.associate(to: targetNetwork, password: nil)
            }
            
            // 更新当前网络状态
            await updateCurrentNetwork()
            
            logger.info("成功连接到WiFi网络: \(network.ssid)")
            return true
            
        } catch {
            logger.error("连接WiFi网络失败: \(error.localizedDescription)")
            return false
        }
    }
    
    /// 断开当前WiFi连接
    public func disconnect() {
        wifiInterface?.disassociate()
        currentNetwork = nil
        logger.info("已断开WiFi连接")
    }
    
    /// 刷新网络列表
    public func refreshNetworks() async {
        await startScanning()
    }
    
    // MARK: - 私有方法
    
    /// 设置WiFi接口
    private func setupWiFiInterface() {
        // 获取默认WiFi接口
        if let interfaceName = wifiClient.interfaceNames()?.first {
            wifiInterface = wifiClient.interface(withName: interfaceName)
            logger.info("WiFi接口已设置: \(interfaceName)")
        } else {
            logger.error("未找到WiFi接口")
        }
    }
    
    /// 更新接口状态
    private func updateInterfaceState() {
        guard let interface = wifiInterface else {
            interfaceState = .unknown
            return
        }
        
        // 通过检查接口属性来判断状态
        if interface.powerOn() {
            if interface.ssid() != nil {
                interfaceState = .running
            } else {
                interfaceState = .inactive
            }
        } else {
            interfaceState = .inactive
        }
    }
    
    /// 处理扫描到的网络
    private func processScannedNetworks(_ networks: Set<CWNetwork>) async {
        let currentSSID = wifiInterface?.ssid()
        
        let wifiNetworks = networks.compactMap { network -> WiFiNetwork? in
            guard let ssid = network.ssid, !ssid.isEmpty else { return nil }
            
            let security = mapSecurityType(network)
            let isConnected = ssid == currentSSID
            
            return WiFiNetwork(
                ssid: ssid,
                bssid: network.bssid ?? "",
                rssi: network.rssiValue,
                channel: network.wlanChannel?.channelNumber ?? 0,
                security: security,
                isConnected: isConnected,
                frequency: Double(network.wlanChannel?.channelBand.rawValue ?? 0)
            )
        }
        
        // 按信号强度排序
        availableNetworks = wifiNetworks.sorted { $0.rssi > $1.rssi }
        
        // 更新当前连接的网络
        if let connectedNetwork = wifiNetworks.first(where: { $0.isConnected }) {
            currentNetwork = connectedNetwork
        }
    }
    
    /// 映射安全类型
    private func mapSecurityType(_ network: CWNetwork) -> WiFiSecurity {
        if network.supportsSecurity(.none) {
            return .none
        } else if network.supportsSecurity(.WEP) {
            return .wep
        } else if network.supportsSecurity(.wpaPersonal) || network.supportsSecurity(.wpaPersonalMixed) {
            return .wpa
        } else if network.supportsSecurity(.wpa2Personal) {
            return .wpa2
        } else if network.supportsSecurity(.wpa3Personal) || network.supportsSecurity(.wpa3Transition) {
            return .wpa3
        } else if network.supportsSecurity(.wpaEnterprise) || network.supportsSecurity(.wpa2Enterprise) || network.supportsSecurity(.wpa3Enterprise) || network.supportsSecurity(.wpaEnterpriseMixed) {
            return .enterprise
        } else {
            return .unknown
        }
    }
    
    /// 更新当前网络信息
    private func updateCurrentNetwork() async {
        guard let interface = wifiInterface,
              let ssid = interface.ssid() else {
            currentNetwork = nil
            return
        }
        
        do {
            let networks = try interface.scanForNetworks(withSSID: Data(ssid.utf8))
            if let network = networks.first {
                let security = mapSecurityType(network)
                currentNetwork = WiFiNetwork(
                    ssid: ssid,
                    bssid: network.bssid ?? "",
                    rssi: network.rssiValue,
                    channel: network.wlanChannel?.channelNumber ?? 0,
                    security: security,
                    isConnected: true,
                    frequency: Double(network.wlanChannel?.channelBand.rawValue ?? 0)
                )
            }
        } catch {
            logger.error("更新当前网络信息失败: \(error.localizedDescription)")
        }
    }
    
    /// 启动定期扫描
    private func startPeriodicScanning() {
        scanTimer?.invalidate()
        
        // 获取设备管理设置中的扫描间隔
        let deviceSettings = DeviceManagementSettingsManager.shared
        let scanInterval = deviceSettings.wifiScanInterval
        
        scanTimer = Timer.scheduledTimer(withTimeInterval: scanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshNetworks()
            }
        }
        
        logger.info("WiFi定期扫描已启动，间隔: \(scanInterval)秒")
    }
    
    /// 设置观察者，监听设置变化
    private func setupSettingsObservers() {
        // 监听WiFi设置变化的通知
        NotificationCenter.default.publisher(for: NSNotification.Name("WiFiSettingsChanged"))
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
        
        // 处理自动扫描设置变化
        if let autoScan = userInfo["autoScan"] as? Bool {
            let deviceSettings = DeviceManagementSettingsManager.shared
            if autoScan && !isScanning && deviceSettings.autoScanWiFi {
                await startScanning()
                logger.info("自动WiFi扫描已启用")
            } else if !autoScan && isScanning {
                stopScanning()
                logger.info("自动WiFi扫描已禁用")
            }
        }
        
        // 处理扫描间隔变化
        if let _ = userInfo["scanInterval"] as? Double {
            if isScanning {
                // 重新启动定期扫描以应用新间隔
                startPeriodicScanning()
                logger.info("WiFi扫描间隔已更新")
            }
        }
    }
}

// MARK: - 扩展方法
extension WiFiManager {
    
    /// 获取WiFi统计信息
    public var wifiStats: WiFiStats {
        WiFiStats(
            availableNetworksCount: availableNetworks.count,
            connectedNetwork: currentNetwork?.ssid,
            signalStrength: currentNetwork?.rssi ?? -100,
            interfaceState: interfaceState
        )
    }
    
    /// WiFi统计信息结构
    public struct WiFiStats {
        public let availableNetworksCount: Int
        public let connectedNetwork: String?
        public let signalStrength: Int
        public let interfaceState: WiFiInterfaceState
    }
}