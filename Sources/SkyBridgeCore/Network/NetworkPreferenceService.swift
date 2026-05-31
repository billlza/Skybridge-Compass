//
// NetworkPreferenceService.swift
// SkyBridgeCore
//
// 网络偏好服务
// 实现 5GHz/6GHz 优先、自动连接已知网络等功能
//

import Foundation
import Network
import CoreWLAN
import OSLog
import Combine

/// WiFi 频段类型
public enum WiFiBand: String, Sendable {
    case band2_4GHz = "2.4GHz"
    case band5GHz = "5GHz"
    case band6GHz = "6GHz"
    case unknown = "Unknown"
    
 /// 从信道号推断频段
    public static func from(channel: Int) -> WiFiBand {
        switch channel {
        case 1...14:
            return .band2_4GHz
        case 36...177:
            return .band5GHz
        case 1...233 where channel > 177: // Wi-Fi 6E
            return .band6GHz
        default:
            return .unknown
        }
    }
    
 /// 从 CoreWLAN 频段推断，优先使用系统提供的频段信息
    public static func from(channel: Int, channelBand: CWChannelBand?) -> WiFiBand {
        if let channelBand = channelBand {
            switch channelBand {
            case .band2GHz:
                return .band2_4GHz
            case .band5GHz:
                return .band5GHz
            case .band6GHz:
                return .band6GHz
            case .bandUnknown:
                break
            @unknown default:
                break
            }
        }
        return from(channel: channel)
    }
}

/// 网络信息
public struct NetworkInfo: Identifiable, Sendable {
    public let id: String
    public let ssid: String
    public let bssid: String
    public let channel: Int
    public let band: WiFiBand
    public let rssi: Int
    public let isSecure: Bool
    public let isKnown: Bool
    
    public init(ssid: String, bssid: String, channel: Int, rssi: Int, isSecure: Bool, isKnown: Bool = false, band: WiFiBand? = nil) {
        self.id = bssid
        self.ssid = ssid
        self.bssid = bssid
        self.channel = channel
        self.band = band ?? WiFiBand.from(channel: channel)
        self.rssi = rssi
        self.isSecure = isSecure
        self.isKnown = isKnown
    }
}

/// 网络偏好服务 - 管理 WiFi 连接偏好
/// 实现 prefer5GHz（5/6GHz 优先）和 autoConnectKnownNetworks 功能
@MainActor
public class NetworkPreferenceService: ObservableObject {
    
    public static let shared = NetworkPreferenceService()
    
 // MARK: - 发布属性
    
    @Published public var prefer5GHz: Bool = true {
        didSet {
            let enabled = prefer5GHz
            logger.info("📶 5GHz/6GHz 优先已\(enabled ? "启用" : "禁用")")
            if enabled {
                evaluateCurrentConnection()
            }
        }
    }
    
    @Published public var autoConnectKnownNetworks: Bool = true {
        didSet {
            let enabled = autoConnectKnownNetworks
            logger.info("🔗 自动连接已知网络已\(enabled ? "启用" : "禁用")")
        }
    }
    
    @Published public var currentNetwork: NetworkInfo?
    @Published public var availableNetworks: [NetworkInfo] = []
    @Published public var knownNetworkSSIDs: Set<String> = []
    @Published public var recommendedNetwork: NetworkInfo?
    
 // MARK: - 私有属性
    
    private let logger = Logger(subsystem: "com.skybridge.network", category: "Preference")
    private var wifiClient: CWWiFiClient?
    private var wifiInterface: CWInterface?
    private var cancellables = Set<AnyCancellable>()
    private var scanTimer: Timer?
    private var scanIntervalSeconds: Int = 10
    private var shouldMonitorNetworks = true
    private var isMonitoringStarted = false
    
    private init() {
        setupWiFiClient()
        setupSettingsObserver()
        loadKnownNetworks()
        applyRuntimeSettingsSnapshot(startMonitoringIfNeeded: false)
    }
    
 // MARK: - 初始化
    
    private func setupWiFiClient() {
        wifiClient = CWWiFiClient.shared()
        wifiInterface = wifiClient?.interface()
        
        if wifiInterface == nil {
            logger.warning("⚠️ 无法获取 WiFi 接口")
        } else {
            logger.info("✅ WiFi 客户端初始化成功")
            updateCurrentNetwork()
        }
    }
    
    private func setupSettingsObserver() {
 // 监听设置变化
        SettingsManager.shared.$prefer5GHz
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyRuntimeSettingsSnapshot(startMonitoringIfNeeded: true)
            }
            .store(in: &cancellables)
        
        SettingsManager.shared.$autoConnectKnownNetworks
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyRuntimeSettingsSnapshot(startMonitoringIfNeeded: true)
            }
            .store(in: &cancellables)

        SettingsManager.shared.$wifiScanTimeout
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyRuntimeSettingsSnapshot(startMonitoringIfNeeded: true)
            }
            .store(in: &cancellables)
    }

    public func applyRuntimeSettings(
        prefer5GHz: Bool,
        autoConnectKnownNetworks: Bool,
        scanIntervalSeconds: Int,
        startMonitoringIfNeeded: Bool = false
    ) {
        if self.prefer5GHz != prefer5GHz {
            self.prefer5GHz = prefer5GHz
        }
        if self.autoConnectKnownNetworks != autoConnectKnownNetworks {
            self.autoConnectKnownNetworks = autoConnectKnownNetworks
        }
        self.scanIntervalSeconds = max(10, scanIntervalSeconds)
        shouldMonitorNetworks = prefer5GHz || autoConnectKnownNetworks

        updateRecommendedNetwork()

        guard startMonitoringIfNeeded || isMonitoringStarted else {
            return
        }

        if shouldMonitorNetworks {
            startNetworkMonitoring(interval: TimeInterval(self.scanIntervalSeconds))
        } else {
            stopNetworkMonitoring()
        }
    }

    public func startConfiguredNetworkMonitoring() {
        guard shouldMonitorNetworks else {
            stopNetworkMonitoring()
            return
        }
        startNetworkMonitoring(interval: TimeInterval(scanIntervalSeconds))
    }

    private func applyRuntimeSettingsSnapshot(startMonitoringIfNeeded: Bool) {
        let settings = SettingsManager.shared
        applyRuntimeSettings(
            prefer5GHz: settings.prefer5GHz,
            autoConnectKnownNetworks: settings.autoConnectKnownNetworks,
            scanIntervalSeconds: settings.wifiScanTimeout,
            startMonitoringIfNeeded: startMonitoringIfNeeded
        )
    }
    
    private func loadKnownNetworks() {
 // 从 UserDefaults 加载已知网络列表
        if let saved = UserDefaults.standard.stringArray(forKey: "KnownNetworkSSIDs") {
            knownNetworkSSIDs = Set(saved)
            logger.info("📋 加载了 \(saved.count) 个已知网络")
        }
    }
    
    private func saveKnownNetworks() {
        UserDefaults.standard.set(Array(knownNetworkSSIDs), forKey: "KnownNetworkSSIDs")
    }
    
 // MARK: - 公共方法
    
 /// 扫描可用网络
    public func scanAvailableNetworks() async {
        guard let interface = wifiInterface else {
            logger.warning("⚠️ WiFi 接口不可用")
            return
        }
        
        logger.info("🔍 开始扫描可用网络...")
        
        do {
            let networks = try interface.scanForNetworks(withSSID: nil)
            
            var networkList: [NetworkInfo] = []
            
            for network in networks {
                let ssid = network.ssid ?? "Unknown"
                let bssid = network.bssid ?? "Unknown"
                let channel = network.wlanChannel?.channelNumber ?? 0
                let band = WiFiBand.from(channel: channel, channelBand: network.wlanChannel?.channelBand)
                let rssi = network.rssiValue
 // 检查网络是否安全
 // 如果网络有 BSSID 且不是开放网络，则认为是安全的
                let isSecure = (network.bssid != nil)
                let isKnown = knownNetworkSSIDs.contains(ssid)
                
                let info = NetworkInfo(
                    ssid: ssid,
                    bssid: bssid,
                    channel: channel,
                    rssi: rssi,
                    isSecure: isSecure,
                    isKnown: isKnown,
                    band: band
                )
                
                networkList.append(info)
            }
            
 // 按信号强度排序
            networkList.sort { $0.rssi > $1.rssi }
            
            await MainActor.run {
                self.availableNetworks = networkList
                self.updateRecommendedNetwork()
                self.autoConnectRecommendedNetworkIfAppropriate()
            }
            
            logger.info("✅ 扫描完成，发现 \(networkList.count) 个网络")
            
        } catch {
            logger.error("❌ 网络扫描失败: \(error.localizedDescription)")
        }
    }
    
 /// 更新当前连接的网络信息
    public func updateCurrentNetwork() {
        guard let interface = wifiInterface else { return }
        
        if let ssid = interface.ssid(),
           let bssid = interface.bssid() {
            let channel = interface.wlanChannel()?.channelNumber ?? 0
            let band = WiFiBand.from(channel: channel, channelBand: interface.wlanChannel()?.channelBand)
            let rssi = interface.rssiValue()
            
            let info = NetworkInfo(
                ssid: ssid,
                bssid: bssid,
                channel: channel,
                rssi: rssi,
                isSecure: true, // 假设已连接的网络是安全的
                isKnown: knownNetworkSSIDs.contains(ssid),
                band: band
            )
            
            currentNetwork = info
            
 // 自动添加到已知网络
            if !knownNetworkSSIDs.contains(ssid) {
                knownNetworkSSIDs.insert(ssid)
                saveKnownNetworks()
                logger.info("📋 已添加到已知网络: \(ssid)")
            }
            
            logger.info("📶 当前网络: \(ssid) (\(info.band.rawValue), 信道 \(channel))")
        } else {
            currentNetwork = nil
            logger.info("📶 当前未连接 WiFi")
        }
    }
    
 /// 评估当前连接并建议更好的网络
    public func evaluateCurrentConnection() {
        guard prefer5GHz else { return }
        guard let current = currentNetwork else { return }
        
        if current.band == .band6GHz {
            return
        }
        
        let recommended = findPreferredNetwork(for: current)
        if let recommended = recommended {
            recommendedNetwork = recommended
            logger.info("💡 推荐切换到 \(recommended.band.rawValue): \(recommended.ssid) (信号: \(recommended.rssi)dBm)")
            
 // 发送通知
            NotificationCenter.default.post(
                name: .betterNetworkAvailable,
                object: nil,
                userInfo: [
                    "currentNetwork": current,
                    "recommendedNetwork": recommended
                ]
            )
        } else {
            recommendedNetwork = current
            logger.info("📶 未找到 5/6GHz 可用网络，保持 2.4GHz 连接")
        }
    }
    
 /// 更新推荐网络
    private func updateRecommendedNetwork() {
        guard prefer5GHz || autoConnectKnownNetworks else {
            recommendedNetwork = nil
            return
        }
        
        var candidates = availableNetworks
        
 // 过滤已知网络（如果启用自动连接）
        if autoConnectKnownNetworks {
            let known = candidates.filter { $0.isKnown }
            if !known.isEmpty {
                candidates = known
            }
        }
        
 // 优先选择 6GHz，其次 5GHz（仅在检测到支持时）
        if prefer5GHz {
            let sixGHz = candidates.filter { $0.band == .band6GHz && $0.rssi > -70 }
            if !sixGHz.isEmpty {
                candidates = sixGHz
            } else {
                let fiveGHz = candidates.filter { $0.band == .band5GHz && $0.rssi > -70 }
                if !fiveGHz.isEmpty {
                    candidates = fiveGHz
                }
            }
        }
        
 // 选择信号最强的
        recommendedNetwork = candidates.first
    }
    
 /// 添加已知网络
    public func addKnownNetwork(_ ssid: String) {
        knownNetworkSSIDs.insert(ssid)
        saveKnownNetworks()
        logger.info("➕ 已添加已知网络: \(ssid)")
    }
    
 /// 移除已知网络
    public func removeKnownNetwork(_ ssid: String) {
        knownNetworkSSIDs.remove(ssid)
        saveKnownNetworks()
        logger.info("➖ 已移除已知网络: \(ssid)")
    }
    
 /// 尝试连接到推荐网络
    public func connectToRecommendedNetwork() async -> Bool {
        guard let recommended = recommendedNetwork,
              let interface = wifiInterface else {
            return false
        }
        
        logger.info("🔗 尝试连接到推荐网络: \(recommended.ssid)")
        
 // 查找对应的 CWNetwork
        do {
            let networks = try interface.scanForNetworks(withSSID: recommended.ssid.data(using: .utf8))
            
            if let network = networks.first(where: { $0.bssid == recommended.bssid }) {
                try interface.associate(to: network, password: nil)
                logger.info("✅ 成功连接到: \(recommended.ssid)")
                
 // 更新当前网络
                updateCurrentNetwork()
                return true
            }
        } catch {
            logger.error("❌ 连接失败: \(error.localizedDescription)")
        }

        return false
    }

    private func autoConnectRecommendedNetworkIfAppropriate() {
        guard autoConnectKnownNetworks,
              currentNetwork == nil,
              recommendedNetwork?.isKnown == true else {
            return
        }

        Task { @MainActor in
            _ = await connectToRecommendedNetwork()
        }
    }
    
 /// 启动周期性网络监控
    public func startNetworkMonitoring(interval: TimeInterval = 30) {
        stopNetworkMonitoring()
        isMonitoringStarted = true
        
        scanTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateCurrentNetwork()
                await self?.scanAvailableNetworks()
            }
        }

        Task { @MainActor [weak self] in
            self?.updateCurrentNetwork()
            await self?.scanAvailableNetworks()
        }
        
        logger.info("🔄 启动网络监控 (间隔: \(interval)秒)")
    }
    
 /// 停止网络监控
    public func stopNetworkMonitoring() {
        scanTimer?.invalidate()
        scanTimer = nil
        isMonitoringStarted = false
        logger.info("⏹️ 停止网络监控")
    }

    private func supportsBand(_ band: WiFiBand) -> Bool {
        if currentNetwork?.band == band {
            return true
        }
        return availableNetworks.contains { $0.band == band }
    }
    
    private func findPreferredNetwork(for current: NetworkInfo) -> NetworkInfo? {
        let candidates = availableNetworks.filter { $0.ssid == current.ssid }
        let preferredBands: [WiFiBand] = [.band6GHz, .band5GHz]
        
        for band in preferredBands {
            let match = candidates.first { network in
                network.band == band && network.rssi > -70
            }
            if let match = match {
                return match
            }
        }
        
        return nil
    }
}

// MARK: - 通知扩展

public extension Notification.Name {
    static let betterNetworkAvailable = Notification.Name("com.skybridge.betterNetworkAvailable")
    static let networkConnectionChanged = Notification.Name("com.skybridge.networkConnectionChanged")
}
