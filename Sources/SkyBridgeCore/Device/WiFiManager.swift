// macOS-exclusive: this file is built on frameworks that exist only on macOS
// (AppKit / IOKit / ScreenCaptureKit / CoreWLAN / MetalFX / ServiceManagement /
// ApplicationServices). It is excluded from other platforms so SkyBridgeCore can be
// the single shared core for iOS as well. No behaviour changes on macOS.
#if os(macOS)
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
public enum WiFiSecurity: String, CaseIterable, Sendable {
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
public final class WiFiManager: BaseManager {
    private final class LocationAuthorizationDelegateProxy: NSObject, CLLocationManagerDelegate {
        private let notificationName = Notification.Name("WiFiManager.LocationAuthorizationChanged")

        nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            _ = manager
            NotificationCenter.default.post(name: notificationName, object: nil)
        }

        nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
            _ = manager
            _ = status
            NotificationCenter.default.post(name: notificationName, object: nil)
        }
    }
    
 // MARK: - 发布属性
    @Published public var availableNetworks: [WiFiNetwork] = []
    @Published public var currentNetwork: WiFiNetwork?
    @Published public var interfaceState: WiFiInterfaceState = .unknown
    @Published public var isScanning = false
    @Published public var hasPermission = false

    private static let locationAuthorizationChangedNotification = Notification.Name("WiFiManager.LocationAuthorizationChanged")
    
 // MARK: - 私有属性
    private let radio: any WiFiRadioAccess
    private var scanTask: Task<Void, Never>?
    private var permissionTask: Task<Bool, Never>?
    private var connectionTask: Task<Bool, Never>?
    private var disconnectTask: Task<Void, Never>?
    private var scanGeneration = UUID()
    private var scanTimer: Timer?
    private var wifiCancellables = Set<AnyCancellable>()
    private var runtimeScanInterval: TimeInterval?
    private let locationManager = CLLocationManager()
    private let locationAuthorizationDelegate = LocationAuthorizationDelegateProxy()
    
 // MARK: - 初始化
    public convenience init() {
        self.init(radio: CoreWLANClient.shared)
    }

    init(radio: any WiFiRadioAccess, observeSystemChanges: Bool = true) {
        self.radio = radio
        super.init(category: "WiFiManager")
        if observeSystemChanges {
            locationManager.delegate = locationAuthorizationDelegate
            NotificationCenter.default.publisher(for: Self.locationAuthorizationChangedNotification)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.handleLocationAuthorizationChange()
                    }
                }
                .store(in: &wifiCancellables)
        }
        logger.info("📶 WiFi管理器初始化完成")
    }
    
 // MARK: - BaseManager重写方法
    
    override public func performInitialization() async {
        await super.performInitialization()
        setupSettingsObservers()
        do {
            updateInterfaceState(try await radio.connection())
        } catch {
            interfaceState = .unknown
            logger.error("WiFi 接口初始化失败: \(error.localizedDescription)")
        }
    }
    
    override public func performStart() async throws {
        try await super.performStart()
        let generation = scanGeneration
        let granted = await refreshPermission()
        guard granted, scanGeneration == generation else { return }
        await startScanning()
    }
    
    override public func performStop() async {
        await super.performStop()
        stopScanning()
    }
    
    override public func cleanup() {
         super.cleanup()
         stopScanning()
         connectionTask?.cancel()
         wifiCancellables.removeAll()
     }
    
 // MARK: - 公共方法
    
 /// 检查WiFi权限
    public func checkPermissions() {
        let generation = scanGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let granted = await self.refreshPermission()
            guard self.scanGeneration == generation, self.status.isActive else { return }
            if granted {
                if !self.isScanning { await self.startScanning() }
            } else {
                self.stopScanning()
            }
        }
    }

    private func refreshPermission() async -> Bool {
        let locationStatus = locationManager.authorizationStatus
        if locationStatus == .denied || locationStatus == .restricted {
            permissionTask?.cancel()
            hasPermission = false
            logger.error("位置权限被拒绝，WiFi扫描需要位置权限")
            return false
        }
        if locationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
            hasPermission = false
            logger.info("正在请求位置权限以支持WiFi扫描")
            return false
        }
        if let permissionTask { return await permissionTask.value }
        let generation = scanGeneration
        let task = Task { [weak self, radio] in
            defer { self?.permissionTask = nil }
            do {
                _ = try await radio.scan()
                guard let self, !Task.isCancelled, self.scanGeneration == generation else { return false }
                self.hasPermission = true
                self.logger.info("WiFi权限已获得")
                return true
            } catch is CancellationError {
                self?.logger.debug("WiFi 权限探测已取消")
            } catch {
                guard let self, self.scanGeneration == generation else { return false }
                self.hasPermission = false
                self.logger.error("WiFi权限检查失败: \(error.localizedDescription)")
            }
            return false
        }
        permissionTask = task
        return await task.value
    }
    
 /// 开始扫描WiFi网络
 /// 使用 Swift 6.2 的并发安全特性
    public func startScanning() async {
        guard hasPermission else {
            logger.warning("没有WiFi权限，无法扫描")
            return
        }
        let generation = scanGeneration
        while let scanTask {
            let wasCancelled = scanTask.isCancelled
            await scanTask.value
            guard wasCancelled, !Task.isCancelled, scanGeneration == generation else { return }
        }
        guard !Task.isCancelled, hasPermission else { return }
        isScanning = true
        let task = Task { [weak self, radio] in
            defer { self?.scanTask = nil }
            do {
                let snapshot = try await radio.scan()
                guard let self, !Task.isCancelled, self.scanGeneration == generation else { return }
                self.updateInterfaceState(snapshot.connection)
                self.processScannedNetworks(snapshot)
                self.startPeriodicScanning()
                self.logger.info("WiFi扫描完成，发现 \(snapshot.networks.count) 个网络")
            } catch is CancellationError {
                self?.logger.debug("WiFi 扫描已取消，丢弃过期结果")
            } catch {
                guard let self, self.scanGeneration == generation else { return }
                self.logger.error("WiFi扫描失败: \(error.localizedDescription)")
                self.isScanning = false
            }
        }
        scanTask = task
        await task.value
    }

 /// 停止扫描WiFi网络
    public func stopScanning() {
        isScanning = false
        scanTimer?.invalidate()
        scanTimer = nil
        scanGeneration = UUID()
        // A CoreWLAN scan cannot be interrupted. Retain its slot until it finishes.
        scanTask?.cancel()
        permissionTask?.cancel()
        logger.info("WiFi扫描已停止")
    }

 /// 连接到指定WiFi网络
    public func connect(to network: WiFiNetwork, password: String? = nil) async -> Bool {
        guard connectionTask == nil, disconnectTask == nil else {
            logger.warning("已有 WiFi 连接操作正在进行")
            return false
        }
        let task = Task { [weak self, radio] in
            defer { self?.connectionTask = nil }
            do {
                let snapshot = try await radio.connect(
                    ssid: network.ssid, bssid: nil,
                    password: password?.isEmpty == false ? password : nil
                )
                guard let self, !Task.isCancelled else { return false }
                self.updateInterfaceState(snapshot.connection)
                if let connected = self.wifiNetworks(from: snapshot).first(where: { $0.isConnected }) {
                    self.currentNetwork = connected
                }
                self.logger.info("成功连接到WiFi网络: \(network.ssid)")
                return true
            } catch is CancellationError {
                self?.logger.debug("WiFi 连接请求已取消")
            } catch {
                self?.logger.error("连接WiFi网络失败: \(error.localizedDescription)")
            }
            return false
        }
        connectionTask = task
        return await task.value
    }
    
 /// 断开当前WiFi连接
    public func disconnect() {
        guard disconnectTask == nil else { return }
        scanGeneration = UUID()
        scanTask?.cancel()
        permissionTask?.cancel()
        connectionTask?.cancel()
        disconnectTask = Task { [weak self, radio] in
            defer { self?.disconnectTask = nil }
            do {
                try await radio.disconnect()
                self?.currentNetwork = nil
                self?.interfaceState = .inactive
                self?.logger.info("已断开WiFi连接")
            } catch {
                self?.logger.error("断开 WiFi 连接失败: \(error.localizedDescription)")
            }
        }
    }
    
 /// 刷新网络列表
    public func refreshNetworks() async {
        await startScanning()
    }
    
 // MARK: - 私有方法
    
 /// 更新接口状态；同步系统属性已由后台 CoreWLAN 客户端读取。
    private func updateInterfaceState(_ connection: WiFiRadioConnection) {
        interfaceState = connection.powerOn && connection.ssid != nil ? .running : .inactive
    }

    private func wifiNetworks(from snapshot: WiFiRadioScan) -> [WiFiNetwork] {
        let includeHiddenNetworks = SettingsManager.shared.showHiddenNetworks
        return snapshot.networks.compactMap { network -> WiFiNetwork? in
            let rawSSID = network.ssid?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isHidden = rawSSID == nil || rawSSID?.isEmpty == true
            guard includeHiddenNetworks || !isHidden else { return nil }
            let ssid: String
            if let rawSSID, !rawSSID.isEmpty {
                ssid = rawSSID
            } else {
                ssid = "Hidden Network (\(network.bssid ?? "unknown"))"
            }
            return WiFiNetwork(
                ssid: ssid, bssid: network.bssid ?? "", rssi: network.rssi,
                channel: network.channel, security: network.security,
                isConnected: ssid == snapshot.connection.ssid, frequency: network.frequency
            )
        }.sorted { $0.rssi > $1.rssi }
    }

    private func processScannedNetworks(_ snapshot: WiFiRadioScan) {
        availableNetworks = wifiNetworks(from: snapshot)
        currentNetwork = availableNetworks.first(where: { $0.isConnected })
    }

 /// 启动定期扫描
    private func startPeriodicScanning() {
        scanTimer?.invalidate()
        
 // 获取设备管理设置中的扫描间隔
        let deviceSettings = DeviceManagementSettingsManager.shared
        let scanInterval = runtimeScanInterval ?? deviceSettings.wifiScanInterval
        
        scanTimer = Timer.scheduledTimer(withTimeInterval: scanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // A failed refresh clears isScanning but the existing monitor
                // still retries on its next tick. stopScanning removes the timer.
                guard let self, self.scanTimer != nil, self.scanTask == nil else { return }
                await self.refreshNetworks()
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
            .store(in: &wifiCancellables)
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
        if let scanInterval = userInfo["scanInterval"] as? Double {
            runtimeScanInterval = max(5.0, scanInterval)
            if isScanning {
 // 重新启动定期扫描以应用新间隔
                startPeriodicScanning()
                logger.info("WiFi扫描间隔已更新")
            }
        }

        if userInfo["showHiddenNetworks"] != nil, isScanning {
            await refreshNetworks()
            logger.info("WiFi隐藏网络显示设置已更新")
        }
    }

    private func handleLocationAuthorizationChange() {
        checkPermissions()
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
#endif
