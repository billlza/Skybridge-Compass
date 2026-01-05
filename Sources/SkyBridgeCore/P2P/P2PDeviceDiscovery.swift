//
// P2PDeviceDiscovery.swift
// SkyBridgeCore
//
// iOS/iPadOS P2P Integration - Device Discovery Extension
// Requirements: 1.1, 1.2, 1.3, 1.4
//
// 扩展设备发现功能：
// 1. 支持 iOS/iPadOS 平台检测
// 2. 注册 _skybridge._udp (QUIC primary) 和 _skybridge._tcp (fallback)
// 3. 解析 TXT 记录获取 deviceId, pubKeyFP, platform, capabilities
// 4. 按 lastSeen 时间排序设备列表
//

import Foundation
import Network
import Combine

// MARK: - P2P Platform Type

/// P2P 平台类型
public enum P2PPlatformType: String, Codable, Sendable {
    case macOS = "macOS"
    case iOS = "iOS"
    case iPadOS = "iPadOS"
    case android = "android"
    case windows = "windows"
    case linux = "linux"
    case unknown = "unknown"
    
 /// 当前平台
    public static var current: P2PPlatformType {
        #if os(macOS)
        return .macOS
        #elseif os(iOS)
 // 区分 iPhone 和 iPad
        #if targetEnvironment(macCatalyst)
        return .macOS
        #else
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .iPadOS
        } else {
            return .iOS
        }
        #endif
        #else
        return .unknown
        #endif
    }
    
 /// 是否为移动平台
    public var isMobile: Bool {
        switch self {
        case .iOS, .iPadOS, .android:
            return true
        case .macOS, .windows, .linux, .unknown:
            return false
        }
    }
    
 /// 转换为 SBPlatformType（用于能力协商）
    public var asSBPlatformType: SBPlatformType {
        switch self {
        case .macOS: return .macOS
        case .iOS: return .iOS
        case .iPadOS: return .iOS  // iPadOS 映射到 iOS
        case .android: return .android
        case .windows: return .windows
        case .linux: return .linux
        case .unknown: return .unknown
        }
    }
    
 /// 从 SBPlatformType 创建
    public init(from sbPlatform: SBPlatformType) {
        switch sbPlatform {
        case .macOS: self = .macOS
        case .iOS: self = .iOS
        case .android: self = .android
        case .windows: self = .windows
        case .linux: self = .linux
        case .web, .unknown: self = .unknown
        }
    }
}

// MARK: - P2P Discovered Device

/// P2P 发现的设备（mDNS 发现）
/// 注意：与 P2PModels.swift 中的 P2PDevice 不同，此结构用于设备发现
public struct P2PDiscoveredDevice: Identifiable, Sendable, Equatable {
 /// 唯一标识符
    public let id: String
    
 /// 设备 ID
    public let deviceId: String
    
 /// 公钥指纹 (SHA-256 hex, 64 chars)
    public let pubKeyFP: String
    
 /// 平台类型
    public let platform: P2PPlatformType
    
 /// 设备能力
    public let capabilities: [String]
    
 /// 设备名称
    public let name: String
    
 /// 协议版本
    public let protocolVersion: String
    
 /// 网络端点
    public let endpoint: NWEndpoint
    
 /// 最后发现时间
    public var lastSeen: Date
    
 /// 是否在线
    public var isOnline: Bool
    
 /// 短 ID（用于 UI 显示）
    public var shortId: String {
        String(pubKeyFP.prefix(P2PConstants.pubKeyFPDisplayLength))
    }
    
    public init(
        deviceId: String,
        pubKeyFP: String,
        platform: P2PPlatformType,
        capabilities: [String],
        name: String,
        protocolVersion: String,
        endpoint: NWEndpoint,
        lastSeen: Date = Date(),
        isOnline: Bool = true
    ) {
        self.id = deviceId
        self.deviceId = deviceId
        self.pubKeyFP = pubKeyFP
        self.platform = platform
        self.capabilities = capabilities
        self.name = name
        self.protocolVersion = protocolVersion
        self.endpoint = endpoint
        self.lastSeen = lastSeen
        self.isOnline = isOnline
    }
    
    public static func == (lhs: P2PDiscoveredDevice, rhs: P2PDiscoveredDevice) -> Bool {
        lhs.deviceId == rhs.deviceId
    }
}

// MARK: - TXT Record Parser

/// P2P TXT 记录解析器
public struct P2PTXTRecordParser {
    
 /// 解析 TXT 记录数据
 /// - Parameter data: TXT 记录数据
 /// - Returns: 解析后的字典
    public static func parse(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        var offset = 0
        
        while offset < data.count {
            let length = Int(data[offset])
            offset += 1
            
            guard offset + length <= data.count else { break }
            
            let entryData = data.subdata(in: offset..<offset+length)
            offset += length
            
            if let entry = String(data: entryData, encoding: .utf8),
               let separatorIndex = entry.firstIndex(of: "=") {
                let key = String(entry[..<separatorIndex])
                let value = String(entry[entry.index(after: separatorIndex)...])
                result[key] = value
            }
        }
        
        return result
    }
    
 /// 从 TXT 记录创建 P2PDiscoveredDevice
 /// - Parameters:
 /// - txtRecord: TXT 记录字典
 /// - endpoint: 网络端点
 /// - Returns: P2PDiscoveredDevice 或 nil
    public static func createDevice(
        from txtRecord: [String: String],
        endpoint: NWEndpoint
    ) -> P2PDiscoveredDevice? {
 // 必需字段
        guard let deviceId = txtRecord["deviceId"], !deviceId.isEmpty,
              let pubKeyFP = txtRecord["pubKeyFP"], !pubKeyFP.isEmpty else {
            return nil
        }
        
 // 可选字段
        let platformStr = txtRecord["platform"] ?? "unknown"
        let platform = P2PPlatformType(rawValue: platformStr) ?? .unknown
        
        let capabilitiesStr = txtRecord["capabilities"] ?? ""
        let capabilities = capabilitiesStr.isEmpty ? [] : capabilitiesStr.split(separator: ",").map(String.init)
        
        let name = txtRecord["name"] ?? "Unknown Device"
        let version = txtRecord["version"] ?? "1.0"
        
        return P2PDiscoveredDevice(
            deviceId: deviceId,
            pubKeyFP: pubKeyFP,
            platform: platform,
            capabilities: capabilities,
            name: name,
            protocolVersion: version,
            endpoint: endpoint
        )
    }
    
 /// 验证 TXT 记录是否包含所有必需字段
 /// - Parameter txtRecord: TXT 记录字典
 /// - Returns: 验证结果
    public static func validate(_ txtRecord: [String: String]) -> P2PTXTValidationResult {
        var missingFields: [String] = []
        var invalidFields: [String] = []
        
 // 必需字段
        let requiredFields = ["deviceId", "pubKeyFP"]
        for field in requiredFields {
            if let value = txtRecord[field] {
                if value.isEmpty {
                    invalidFields.append("\(field): cannot be empty")
                }
            } else {
                missingFields.append(field)
            }
        }
        
 // 验证 pubKeyFP 格式
        if let pubKeyFP = txtRecord["pubKeyFP"], !pubKeyFP.isEmpty {
 // 应为 hex 小写，长度 64
            let hexPattern = "^[0-9a-f]{64}$"
            if pubKeyFP.range(of: hexPattern, options: .regularExpression) == nil {
                invalidFields.append("pubKeyFP: should be 64 hex lowercase characters")
            }
        }
        
        if missingFields.isEmpty && invalidFields.isEmpty {
            return .valid
        } else {
            return .invalid(missing: missingFields, invalid: invalidFields)
        }
    }
}

/// TXT 记录验证结果
public enum P2PTXTValidationResult: Equatable, Sendable {
    case valid
    case invalid(missing: [String], invalid: [String])
    
    public var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}


// MARK: - P2P Device Discovery Service

/// P2P 设备发现服务
///
/// 负责发现局域网内的 SkyBridge 设备，支持：
/// - mDNS/Bonjour 服务发现
/// - UDP (QUIC primary) 和 TCP (fallback) 服务类型
/// - 自动设备列表管理和排序
@available(macOS 14.0, iOS 17.0, *)
@MainActor
public final class P2PDeviceDiscoveryService: ObservableObject {
    
 // MARK: - Published Properties
    
 /// 发现的设备列表（按 lastSeen 降序排序）
    @Published public private(set) var devices: [P2PDiscoveredDevice] = []
    
 /// 是否正在扫描
    @Published public private(set) var isScanning: Bool = false
    
 /// 最后一次错误
    @Published public private(set) var lastError: Error?
    
 // MARK: - Private Properties
    
 /// UDP 服务浏览器
    private var udpBrowser: NWBrowser?
    
 /// TCP 服务浏览器
    private var tcpBrowser: NWBrowser?
    
 /// 设备缓存（deviceId -> P2PDiscoveredDevice）
    private var deviceCache: [String: P2PDiscoveredDevice] = [:]
    
 /// 离线检测定时器
    private var offlineCheckTimer: Timer?
    
 /// 离线阈值（秒）
    private let offlineThreshold: TimeInterval
    
 // MARK: - Initialization
    
    public init(offlineThreshold: TimeInterval = P2PConstants.deviceOfflineThresholdSeconds) {
        self.offlineThreshold = offlineThreshold
    }
    
    deinit {
 // 直接取消浏览器，避免 MainActor 隔离问题
 // 注意：NWBrowser.cancel() 是线程安全的
        udpBrowser?.cancel()
        tcpBrowser?.cancel()
 // Timer 会在 RunLoop 中自动清理，无需在 deinit 中 invalidate
    }
    
 // MARK: - Public Methods
    
 /// 开始扫描设备
    public func startScanning() {
        guard !isScanning else { return }
        
        isScanning = true
        lastError = nil
        
 // 启动 UDP 浏览器 (QUIC primary)
        startBrowser(serviceType: P2PConstants.bonjourServiceTypeUDP, isUDP: true)
        
 // 启动 TCP 浏览器 (fallback)
        startBrowser(serviceType: P2PConstants.bonjourServiceTypeTCP, isUDP: false)
        
 // 启动离线检测定时器
        startOfflineCheckTimer()
        
        SkyBridgeLogger.p2p.info("Started P2P device discovery")
    }
    
 /// 停止扫描设备
    public func stopScanning() {
        udpBrowser?.cancel()
        udpBrowser = nil
        
        tcpBrowser?.cancel()
        tcpBrowser = nil
        
        offlineCheckTimer?.invalidate()
        offlineCheckTimer = nil
        
        isScanning = false
        
        SkyBridgeLogger.p2p.info("Stopped P2P device discovery")
    }
    
 /// 刷新设备列表
    public func refresh() {
        stopScanning()
        deviceCache.removeAll()
        devices.removeAll()
        startScanning()
    }
    
 /// 获取指定设备
 /// - Parameter deviceId: 设备 ID
 /// - Returns: P2PDiscoveredDevice 或 nil
    public func getDevice(by deviceId: String) -> P2PDiscoveredDevice? {
        deviceCache[deviceId]
    }
    
 // MARK: - Private Methods
    
 /// 启动服务浏览器
    private func startBrowser(serviceType: String, isUDP: Bool) {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        let browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: P2PConstants.bonjourServiceDomain),
            using: parameters
        )
        
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleBrowserState(state, serviceType: serviceType)
            }
        }
        
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor in
                self?.handleBrowseResults(results, changes: changes, isUDP: isUDP)
            }
        }
        
        browser.start(queue: .main)
        
        if isUDP {
            udpBrowser = browser
        } else {
            tcpBrowser = browser
        }
    }
    
 /// 处理浏览器状态变化
    private func handleBrowserState(_ state: NWBrowser.State, serviceType: String) {
        switch state {
        case .ready:
            SkyBridgeLogger.p2p.debug("Browser ready for \(serviceType)")
        case .failed(let error):
            SkyBridgeLogger.p2p.error("Browser failed for \(serviceType): \(error.localizedDescription)")
            lastError = error
        case .cancelled:
            SkyBridgeLogger.p2p.debug("Browser cancelled for \(serviceType)")
        default:
            break
        }
    }
    
 /// 处理浏览结果变化
    private func handleBrowseResults(
        _ results: Set<NWBrowser.Result>,
        changes: Set<NWBrowser.Result.Change>,
        isUDP: Bool
    ) {
        for change in changes {
            switch change {
            case .added(let result):
                handleDeviceAdded(result, isUDP: isUDP)
            case .removed(let result):
                handleDeviceRemoved(result)
            case .changed(old: _, new: let newResult, flags: _):
                handleDeviceAdded(newResult, isUDP: isUDP)
            case .identical:
                break
            @unknown default:
                break
            }
        }
    }
    
 /// 处理设备添加
    private func handleDeviceAdded(_ result: NWBrowser.Result, isUDP: Bool) {
 // 解析 TXT 记录
        guard case .bonjour(let txtRecord) = result.metadata else {
            return
        }
        
 // 将 NWTXTRecord 转换为字典
        var txtDict: [String: String] = [:]
        for key in txtRecord.dictionary.keys {
            if let value = txtRecord.dictionary[key] {
                txtDict[key] = value
            }
        }
        
 // 创建设备
        guard let device = P2PTXTRecordParser.createDevice(
            from: txtDict,
            endpoint: result.endpoint
        ) else {
            SkyBridgeLogger.p2p.warning("Failed to parse device from TXT record")
            return
        }
        
 // 更新缓存
        var updatedDevice = device
        if let existing = deviceCache[device.deviceId] {
 // 保留 UDP 端点（优先）
            if !isUDP && existing.isOnline {
                updatedDevice = P2PDiscoveredDevice(
                    deviceId: device.deviceId,
                    pubKeyFP: device.pubKeyFP,
                    platform: device.platform,
                    capabilities: device.capabilities,
                    name: device.name,
                    protocolVersion: device.protocolVersion,
                    endpoint: existing.endpoint, // 保留 UDP 端点
                    lastSeen: Date(),
                    isOnline: true
                )
            }
        }
        
        deviceCache[device.deviceId] = updatedDevice
        updateDeviceList()
        
        SkyBridgeLogger.p2p.debug("Device discovered: \(device.name) (\(device.shortId))")
    }
    
 /// 处理设备移除
    private func handleDeviceRemoved(_ result: NWBrowser.Result) {
 // 解析 TXT 记录获取 deviceId
        guard case .bonjour(let txtRecord) = result.metadata,
              let deviceId = txtRecord.dictionary["deviceId"] else {
            return
        }
        
 // 标记为离线
        if var device = deviceCache[deviceId] {
            device.isOnline = false
            deviceCache[deviceId] = device
            updateDeviceList()
            
            SkyBridgeLogger.p2p.debug("Device went offline: \(device.name)")
        }
    }
    
 /// 启动离线检测定时器
    private func startOfflineCheckTimer() {
        offlineCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkOfflineDevices()
            }
        }
    }
    
 /// 检查离线设备
    private func checkOfflineDevices() {
        let now = Date()
        var hasChanges = false
        
        for (deviceId, device) in deviceCache {
            if device.isOnline && now.timeIntervalSince(device.lastSeen) > offlineThreshold {
                var updatedDevice = device
                updatedDevice.isOnline = false
                deviceCache[deviceId] = updatedDevice
                hasChanges = true
                
                SkyBridgeLogger.p2p.debug("Device offline (timeout): \(device.name)")
            }
        }
        
 // 移除长时间离线的设备
        let removalThreshold = offlineThreshold * 2
        deviceCache = deviceCache.filter { _, device in
            device.isOnline || now.timeIntervalSince(device.lastSeen) < removalThreshold
        }
        
        if hasChanges {
            updateDeviceList()
        }
    }
    
 /// 更新设备列表（按 lastSeen 降序排序）
    private func updateDeviceList() {
        devices = deviceCache.values
            .filter { $0.isOnline }
            .sorted { $0.lastSeen > $1.lastSeen }
    }
}

// MARK: - P2P Service Advertiser

/// P2P 服务广播器
///
/// 负责广播本机的 SkyBridge 服务
@available(macOS 14.0, iOS 17.0, *)
public actor P2PServiceAdvertiser {
    
 // MARK: - Properties
    
 /// UDP 监听器
    private var udpListener: NWListener?
    
 /// TCP 监听器
    private var tcpListener: NWListener?
    
 /// 是否正在广播
    public private(set) var isAdvertising: Bool = false
    
 /// 分配的 UDP 端口
    public private(set) var udpPort: UInt16 = 0
    
 /// 分配的 TCP 端口
    public private(set) var tcpPort: UInt16 = 0
    
 // MARK: - Initialization
    
    public init() {}
    
 // MARK: - Public Methods
    
 /// 开始广播服务
 /// - Parameters:
 /// - deviceId: 设备 ID
 /// - pubKeyFP: 公钥指纹
 /// - name: 设备名称
 /// - capabilities: 设备能力
    public func startAdvertising(
        deviceId: String,
        pubKeyFP: String,
        name: String,
        capabilities: [String]
    ) async throws {
        guard !isAdvertising else { return }
        
 // 构建 TXT 记录
        let txtRecord: [String: String] = [
            "deviceId": deviceId,
            "pubKeyFP": pubKeyFP,
            "platform": P2PPlatformType.current.rawValue,
            "capabilities": capabilities.joined(separator: ","),
            "name": name,
            "version": "v\(P2PProtocolVersion.current.rawValue)"
        ]
        
 // 启动 UDP 服务 (QUIC primary)
        udpPort = try await startListener(
            serviceType: P2PConstants.bonjourServiceTypeUDP,
            txtRecord: txtRecord,
            useUDP: true
        )
        
 // 启动 TCP 服务 (fallback)
        tcpPort = try await startListener(
            serviceType: P2PConstants.bonjourServiceTypeTCP,
            txtRecord: txtRecord,
            useUDP: false
        )
        
        isAdvertising = true
        
        SkyBridgeLogger.p2p.info("Started advertising P2P service: UDP=\(self.udpPort), TCP=\(self.tcpPort)")
    }
    
 /// 停止广播服务
    public func stopAdvertising() {
        udpListener?.cancel()
        udpListener = nil
        
        tcpListener?.cancel()
        tcpListener = nil
        
        isAdvertising = false
        udpPort = 0
        tcpPort = 0
        
        SkyBridgeLogger.p2p.info("Stopped advertising P2P service")
    }
    
 // MARK: - Private Methods
    
 /// 启动监听器
    private func startListener(
        serviceType: String,
        txtRecord: [String: String],
        useUDP: Bool
    ) async throws -> UInt16 {
        let parameters = useUDP ? NWParameters.udp : NWParameters.tcp
        parameters.includePeerToPeer = true
        
        let listener = try NWListener(using: parameters)
        
 // 设置服务
        let txtData = NWTXTRecord(txtRecord)
        listener.service = NWListener.Service(
            name: txtRecord["name"] ?? "SkyBridge",
            type: serviceType,
            txtRecord: txtData
        )
        
 // 启动监听
        listener.start(queue: .global(qos: .utility))
        
 // 等待端口分配
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        let port = listener.port?.rawValue ?? 0
        
        if useUDP {
            udpListener = listener
        } else {
            tcpListener = listener
        }
        
        return UInt16(port)
    }
}
