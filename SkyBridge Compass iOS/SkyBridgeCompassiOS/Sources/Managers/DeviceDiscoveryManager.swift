//
// DeviceDiscoveryManager.swift
// SkyBridgeCompassiOS
//
// 跨平台设备发现管理器
// 使用 Bonjour/mDNS/DNS-SD 发现 iOS、macOS、Android、Windows、Linux 设备
//
// 最佳实践参考：
// - Apple Developer Documentation: Network.framework, NWBrowser
// - RFC 6762 (mDNS) 和 RFC 6763 (DNS-SD)
// - 跨平台兼容：统一服务类型 + TXT 记录格式
//

import Foundation
import Darwin
import Network
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Service Types

/// 跨平台服务类型定义
public enum DiscoveryServiceType: String, CaseIterable, Sendable {
    /// SkyBridge 主服务（所有平台）
    case skybridge = "_skybridge._tcp"
    
    /// SkyBridge QUIC 服务（高性能传输）
    case skybridgeQUIC = "_skybridge._udp"

    /// SkyBridge 文件传输服务
    case skybridgeTransfer = "_skybridge-transfer._tcp"

    /// SkyBridge 远程桌面/远控服务
    case skybridgeRemote = "_skybridge-remote._tcp"
    
    /// Apple Companion Link（Apple 设备间）
    case companionLink = "_companion-link._tcp"
    
    /// AirDrop 服务（Apple 设备）
    case airdrop = "_airdrop._tcp"
    
    /// SFTP/SSH 服务（开发者设备）
    case sftp = "_sftp-ssh._tcp"
    
    /// SMB 文件共享（Windows/Linux/macOS）
    case smb = "_smb._tcp"
    
    /// HTTP 服务（通用 Web 服务）
    case http = "_http._tcp"
    
    /// 远程桌面（RDP 协议）
    case rdp = "_rdlink._tcp"
    
    /// 自定义 Android 服务（如果 Android 客户端使用）
    case androidShare = "_androidshare._tcp"
    
    /// 服务的显示名称
    public var displayName: String {
        switch self {
        case .skybridge: return "SkyBridge"
        case .skybridgeQUIC: return "SkyBridge QUIC"
        case .skybridgeTransfer: return "File Transfer"
        case .skybridgeRemote: return "Remote Control"
        case .companionLink: return "Companion Link"
        case .airdrop: return "AirDrop"
        case .sftp: return "SFTP"
        case .smb: return "SMB Share"
        case .http: return "HTTP"
        case .rdp: return "Remote Desktop"
        case .androidShare: return "Android Share"
        }
    }
    
    /// 是否是 SkyBridge 核心服务
    public var isSkyBridgeService: Bool {
        self == .skybridge || self == .skybridgeQUIC || self == .skybridgeTransfer || self == .skybridgeRemote
    }
}

// MARK: - Discovery Mode

/// 发现模式
public enum DiscoveryMode: Sendable {
    /// 仅 SkyBridge 服务（默认，节能）
    case skybridgeOnly
    
    /// 扩展模式（包含常见服务）
    case extended
    
    /// 完整模式（所有支持的服务）
    case full
    
    /// 自定义服务类型
    case custom([DiscoveryServiceType])
    
    var serviceTypes: [DiscoveryServiceType] {
        switch self {
        case .skybridgeOnly:
            return [.skybridge, .skybridgeQUIC, .skybridgeTransfer, .skybridgeRemote]
        case .extended:
            return [.skybridge, .skybridgeQUIC, .skybridgeTransfer, .skybridgeRemote, .companionLink, .smb, .sftp]
        case .full:
            return DiscoveryServiceType.allCases
        case .custom(let types):
            return types
        }
    }
}

// MARK: - DeviceDiscoveryManager

/// 跨平台设备发现管理器
/// 支持发现 iOS、iPadOS、macOS、Android、Windows、Linux 设备
@MainActor
public class DeviceDiscoveryManager: ObservableObject {
    public static let instance = DeviceDiscoveryManager()
    
    // MARK: - Published Properties
    
    /// 发现的设备列表
    @Published public private(set) var discoveredDevices: [DiscoveredDevice] = []
    
    /// 按平台分组的设备
    @Published public private(set) var devicesByPlatform: [DevicePlatform: [DiscoveredDevice]] = [:]
    
    /// 是否正在发现
    @Published public private(set) var isDiscovering: Bool = false
    
    /// 是否正在广播
    @Published public private(set) var isAdvertising: Bool = false
    
    /// 最后一次错误
    @Published public private(set) var error: Error?
    
    /// 当前发现模式
    @Published public var discoveryMode: DiscoveryMode = .skybridgeOnly
    
    // MARK: - Private Properties
    
    /// Bonjour 浏览器（每种服务类型一个）
    private var browsers: [DiscoveryServiceType: NWBrowser] = [:]
    
    /// Bonjour 监听器（广播用）
    private var listener: NWListener?
    
    /// 设备缓存
    private var deviceCache: [String: DiscoveredDevice] = [:]

    /// endpoint debugDescription -> stable deviceId（用于处理 removed 事件时定位缓存项）
    private var endpointToDeviceId: [String: String] = [:]
    
    /// 设备最后活动时间
    private var deviceLastActivity: [String: Date] = [:]
    
    /// 调度队列
    private let queue = DispatchQueue(label: "com.skybridge.discovery", qos: .userInitiated)
    
    /// 设备清理定时器
    private var cleanupTimer: Timer?

    /// 周期性刷新定时器（省电策略：周期 refresh，而不是一直保持浏览器常驻）
    private var periodicRefreshTimer: Timer?
    private var periodicRefreshIntervalSeconds: TimeInterval = 0
    private var lastAlreadyRunningLogAt: Date?
    
    /// 设备超时时间（秒）
    private let deviceTimeout: TimeInterval = 60
    
    /// 新连接回调
    public var onNewConnection: ((NWConnection, String) -> Void)?
    
    /// 本机设备名称
    private var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }
    
    /// 本机平台
    private var localPlatform: DevicePlatform {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .iPadOS
        }
        return .iOS
        #elseif os(macOS)
        return .macOS
        #else
        return .unknown
        #endif
    }
    
    /// 本机 OS 版本
    private var localOSVersion: String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #endif
    }
    
    /// 本机型号
    private var localModel: String {
        #if canImport(UIKit)
        return UIDevice.current.model
        #else
        return "Mac"
        #endif
    }
    
    private init() {}
    
    // MARK: - Discovery Control
    
    /// 开始发现设备
    /// - Parameter mode: 发现模式
    public func startDiscovery(mode: DiscoveryMode? = nil) async throws {
        if let mode = mode {
            self.discoveryMode = mode
        }
        
        guard !isDiscovering else {
            // 这里很容易被重复触发（UI/scenePhase/设置变更），加节流避免日志刷屏与内存压力
            let now = Date()
            if lastAlreadyRunningLogAt == nil || now.timeIntervalSince(lastAlreadyRunningLogAt!) > 5 {
                lastAlreadyRunningLogAt = now
                SkyBridgeLogger.shared.debug("📡 设备发现已在运行")
            }
            return
        }
        
        isDiscovering = true
        error = nil
        
        SkyBridgeLogger.shared.info("🔍 开始设备发现 (模式: \(String(describing: discoveryMode)))")
        
        // 为每种服务类型创建浏览器
        for serviceType in discoveryMode.serviceTypes {
            startBrowser(for: serviceType)
        }
        
        // 启动设备清理定时器
        startCleanupTimer()

        // 如果配置了周期刷新，则启动（否则为持续发现）
        if periodicRefreshIntervalSeconds > 0 {
            startPeriodicRefreshTimer()
        }
    }
    
    /// 停止发现设备
    public func stopDiscovery() {
        guard isDiscovering else { return }
        
        // 取消所有浏览器
        for (serviceType, browser) in browsers {
            browser.cancel()
            SkyBridgeLogger.shared.debug("⏹️ 停止浏览器: \(serviceType.rawValue)")
        }
        browsers.removeAll()
        
        // 停止清理定时器
        cleanupTimer?.invalidate()
        cleanupTimer = nil

        // 停止周期刷新
        periodicRefreshTimer?.invalidate()
        periodicRefreshTimer = nil
        
        isDiscovering = false
        SkyBridgeLogger.shared.info("⏹️ 设备发现已停止")
    }
    
    /// 刷新设备列表
    public func refresh() async {
        // UX fix:
        // Do NOT hard stop/start NWBrowser instances as a "refresh". It causes stop/start storms,
        // breaks ongoing handshakes/transfers, and leads to reconnect loops.
        // Instead, do a soft refresh: clear caches and let existing browsers continue delivering results.
        deviceCache.removeAll()
        endpointToDeviceId.removeAll()
        deviceLastActivity.removeAll()
        updateDiscoveredDevices()
        
        if !isDiscovering {
            try? await startDiscovery()
        }
    }

    /// 设置周期性刷新扫描间隔（秒）
    /// - 0 表示关闭（持续发现）
    public func setPeriodicRefreshInterval(seconds: Double) {
        // Guardrail: extremely small intervals create stop/start storms (NWBrowser churn) and can blow memory.
        // 0 = continuous discovery (no periodic refresh).
        let clamped: Double
        if seconds <= 0 {
            clamped = 0
        } else {
            clamped = max(5.0, seconds)
        }
        periodicRefreshIntervalSeconds = clamped

        periodicRefreshTimer?.invalidate()
        periodicRefreshTimer = nil

        guard isDiscovering, periodicRefreshIntervalSeconds > 0 else { return }
        startPeriodicRefreshTimer()
    }
    
    // MARK: - Advertising Control
    
    /// 开始广播服务（让其他平台发现我们）
    /// - Parameter port: 监听端口
    public func startAdvertising(port: UInt16 = 9527) async throws {
        guard !isAdvertising else {
            SkyBridgeLogger.shared.debug("📡 广播已在运行")
            return
        }
        
        // 创建 TXT 记录
        let txtRecord = createTXTRecord()
        
        // 创建监听器参数
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 15
            tcp.keepaliveCount = 4
        }
        
        do {
            if port > 0 {
                guard let boundPort = NWEndpoint.Port(rawValue: port) else {
                    throw NSError(
                        domain: "DeviceDiscoveryManager",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "无效监听端口: \(port)"]
                    )
                }
                // Bind on port only (no fixed host), so the listener can accept both IPv4/IPv6.
                listener = try NWListener(using: parameters, on: boundPort)
            } else {
                listener = try NWListener(using: parameters)
            }
        } catch {
            SkyBridgeLogger.shared.error("❌ 创建监听器失败: \(error.localizedDescription)")
            self.error = error
            throw error
        }
        
        // 设置 Bonjour 服务广播
        listener?.service = NWListener.Service(
            name: deviceName,
            type: DiscoveryServiceType.skybridge.rawValue,
            txtRecord: txtRecord
        )
        
        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                await self?.handleListenerStateChange(state)
            }
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                await self?.handleNewIncomingConnection(connection)
            }
        }
        
        listener?.start(queue: queue)
        isAdvertising = true
        
        SkyBridgeLogger.shared.info("📡 开始广播服务: \(deviceName) (\(DiscoveryServiceType.skybridge.rawValue))")
    }
    
    /// 停止广播服务
    public func stopAdvertising() {
        guard isAdvertising else { return }
        
        listener?.cancel()
        listener = nil
        isAdvertising = false
        
        SkyBridgeLogger.shared.info("📡 停止广播服务")
    }
    
    // MARK: - Private Methods - Browser
    
    /// 启动特定服务类型的浏览器
    private func startBrowser(for serviceType: DiscoveryServiceType) {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        let browser = NWBrowser(
            // 关键：必须使用 bonjourWithTXTRecord 才能在 Result.metadata 中拿到 TXT，
            // 否则 osVersion/modelName 等字段会长期显示为 "Unknown"（即使 macOS 端已正确广播）。
            for: .bonjourWithTXTRecord(type: serviceType.rawValue, domain: nil),
            using: parameters
        )
        
        browser.stateUpdateHandler = { [weak self, serviceType] state in
            Task { @MainActor in
                await self?.handleBrowserStateChange(state, for: serviceType)
            }
        }
        
        browser.browseResultsChangedHandler = { [weak self, serviceType] results, changes in
            Task { @MainActor in
                await self?.handleBrowseResults(results, changes: changes, serviceType: serviceType)
            }
        }
        
        browser.start(queue: queue)
        browsers[serviceType] = browser
        
        SkyBridgeLogger.shared.debug("🔍 启动浏览器: \(serviceType.rawValue)")
    }
    
    private func handleBrowserStateChange(_ state: NWBrowser.State, for serviceType: DiscoveryServiceType) async {
        switch state {
        case .ready:
            SkyBridgeLogger.shared.debug("✅ 浏览器就绪: \(serviceType.rawValue)")
            
        case .failed(let error):
            if case .dns(let dnsError) = error, dnsError == -65555 {
                SkyBridgeLogger.shared.error("❌ 浏览器失败 (\(serviceType.rawValue)): NoAuth(-65555)。请确认已允许「本地网络」权限，且 Info.plist 包含 NSLocalNetworkUsageDescription + NSBonjourServices。")
            } else {
                SkyBridgeLogger.shared.error("❌ 浏览器失败 (\(serviceType.rawValue)): \(error.localizedDescription)")
            }
            self.error = error
            
        case .cancelled:
            SkyBridgeLogger.shared.debug("⏹️ 浏览器已取消: \(serviceType.rawValue)")
            
        default:
            break
        }
    }
    
    private func handleBrowseResults(
        _ results: Set<NWBrowser.Result>,
        changes: Set<NWBrowser.Result.Change>,
        serviceType: DiscoveryServiceType
    ) async {
        for change in changes {
            switch change {
            case .added(let result):
                await handleDeviceAdded(result, serviceType: serviceType)
                
            case .removed(let result):
                await handleDeviceRemoved(result, serviceType: serviceType)
                
            case .changed(old: _, new: let result, flags: _):
                await handleDeviceChanged(result, serviceType: serviceType)
                
            case .identical:
                break
                
            @unknown default:
                break
            }
        }
    }
    
    // MARK: - Private Methods - Device Handling
    
    private func handleDeviceAdded(_ result: NWBrowser.Result, serviceType: DiscoveryServiceType) async {
        let device = await createDevice(from: result, serviceType: serviceType)
        
        // 过滤自己
        if device.name == deviceName && device.platform == localPlatform {
            return
        }
        
        // 同一物理设备可能同时广播多个 SkyBridge 服务（p2p/传输/远控）：这里合并能力/端口/系统信息
        if let existing = deviceCache[device.id] {
            deviceCache[device.id] = merge(existing: existing, update: device)
        } else {
            deviceCache[device.id] = device
        }
        endpointToDeviceId[result.endpoint.debugDescription] = device.id
        deviceLastActivity[device.id] = Date()
        updateDiscoveredDevices()
        
        SkyBridgeLogger.shared.info("➕ 发现设备: \(device.name) [\(device.platform.rawValue)] via \(serviceType.displayName)")
    }
    
    private func handleDeviceRemoved(_ result: NWBrowser.Result, serviceType: DiscoveryServiceType) async {
        let endpointKey = result.endpoint.debugDescription
        let deviceId = endpointToDeviceId[endpointKey] ?? endpointKey

        guard var existing = deviceCache[deviceId] else {
            deviceCache.removeValue(forKey: deviceId)
            deviceLastActivity.removeValue(forKey: deviceId)
            endpointToDeviceId.removeValue(forKey: endpointKey)
            updateDiscoveredDevices()
            return
        }

        // 只移除该 serviceType 对应的“服务存在性”，避免一个 service 离线导致整机从列表消失
        existing.services.removeAll { $0 == serviceType.rawValue }
        existing.portMap.removeValue(forKey: serviceType.rawValue)
        existing.capabilities = recomputeCapabilities(existing: existing)

        if existing.services.isEmpty {
            deviceCache.removeValue(forKey: deviceId)
            deviceLastActivity.removeValue(forKey: deviceId)
        } else {
            deviceCache[deviceId] = existing
            deviceLastActivity[deviceId] = Date()
        }

        endpointToDeviceId.removeValue(forKey: endpointKey)
        updateDiscoveredDevices()
    }
    
    private func handleDeviceChanged(_ result: NWBrowser.Result, serviceType: DiscoveryServiceType) async {
        let device = await createDevice(from: result, serviceType: serviceType)

        if let existing = deviceCache[device.id] {
            deviceCache[device.id] = merge(existing: existing, update: device)
        } else {
            deviceCache[device.id] = device
        }

        endpointToDeviceId[result.endpoint.debugDescription] = device.id
        deviceLastActivity[device.id] = Date()
        updateDiscoveredDevices()
    }
    
    /// 从 NWBrowser.Result 创建设备对象
    private func createDevice(from result: NWBrowser.Result, serviceType: DiscoveryServiceType) async -> DiscoveredDevice {
        let endpoint = result.endpoint
        
        // Bonjour 实例名（连接用）
        let bonjourName = extractDeviceName(from: endpoint)
        // TXT 记录（用于系统信息/能力/端口展示）
        let txtRecord = extractTXTRecord(from: result)
        // 设备主键：使用“物理身份 key”（忽略 serviceType），避免同一设备多服务重复展示
        let id = stableDeviceId(from: endpoint)
        
        // 解析 TXT 记录
        let platform = detectPlatform(from: txtRecord, serviceType: serviceType, name: bonjourName)
        // macOS 端的 TXT 记录字段可能不同：兼容更多常见键名
        let osVersion = txtValue(
            txtRecord,
            "osVersion",
            "os_version",
            "platformVersion",
            "platform_version",
            "systemVersion",
            "systemversion",
            "os"
        ) ?? "Unknown"
        let modelName = txtValue(
            txtRecord,
            "model",
            "hardwareModel",
            "hardwaremodel",
            "hwModel",
            "hwmodel"
        ) ?? detectModelFromName(bonjourName, platform: platform)

        // 显示名称：优先 TXT 的 name，其次 Bonjour name
        let displayName = txtValue(txtRecord, "name") ?? bonjourName
        
        // 提取 Bonjour service 信息 / IP 地址
        let ipAddress = extractIPAddress(from: endpoint)
        let (bonjourType, bonjourDomain) = extractBonjourService(from: endpoint, fallbackServiceType: serviceType)
        
        // 提取 PQC 支持信息（当前仅解析，后续可用于 UI 展示/能力协商）
        _ = txtRecord["pqc"] ?? "unknown"
        
        let isTrusted = TrustedDeviceStore.shared.isTrusted(deviceId: id)

        // 能力解析：TXT capabilities + 由 serviceType 推断
        let advertisedCaps = parseCapabilities(from: txtRecord)
        var unionCaps = Set(advertisedCaps)
        unionCaps.formUnion(capabilitiesInferred(from: serviceType))

        // 端口：优先 TXT 端口字段（便于 UI 展示）；连接时可直接使用 .service 不依赖端口
        var portMap: [String: UInt16] = [:]
        if let p = parsePort(for: serviceType, from: txtRecord) {
            portMap[serviceType.rawValue] = p
        }

        let signalStrength = resolveSignalStrength(from: txtRecord, endpoint: endpoint)

        return DiscoveredDevice(
            id: id,
            name: displayName,
            bonjourServiceName: bonjourName,
            modelName: modelName,
            platform: platform,
            osVersion: osVersion,
            ipAddress: ipAddress,
            bonjourServiceType: bonjourType,
            bonjourServiceDomain: bonjourDomain,
            services: [serviceType.rawValue],
            portMap: portMap,
            signalStrength: signalStrength,
            lastSeen: Date(),
            isConnected: false,
            isTrusted: isTrusted,
            publicKey: nil,
            advertisedCapabilities: advertisedCaps,
            capabilities: Array(unionCaps).sorted()
        )
    }
    
    private func isUnknownValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.lowercased() == "unknown"
    }

    private func txtValue(_ txt: [String: String], _ keys: String...) -> String? {
        for key in keys {
            if let v = txt[key], !v.isEmpty { return v.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
            let lower = key.lowercased()
            if let v = txt[lower], !v.isEmpty { return v.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
        }
        return nil
    }

    /// 生成尽可能稳定的设备 id：
    /// - 使用 Bonjour 实例名 + domain（忽略 serviceType），确保同一设备多个服务只展示一次
    private func stableDeviceId(from endpoint: NWEndpoint) -> String {
        if case .service(let name, _, let domain, _) = endpoint {
            let d = domain.isEmpty ? "local." : domain
            return "bonjour:\(name)@\(d)"
        }

        if case .hostPort(let host, _) = endpoint {
            return "host:\(host)"
        }

        return endpoint.debugDescription
    }
    
    /// 从 endpoint 提取设备名称
    private func extractDeviceName(from endpoint: NWEndpoint) -> String {
        if case .service(let name, _, _, _) = endpoint {
            return name
        }
        return "Unknown Device"
    }
    
    /// 提取 TXT 记录
    private func extractTXTRecord(from result: NWBrowser.Result) -> [String: String] {
        guard case .bonjour(let txtRecord) = result.metadata else { return [:] }

        // fallback：使用我们自定义的 NWTXTRecord.dictionary（枚举常见键）
        guard let dict = txtRecord.dictionary else { return [:] }
        var record: [String: String] = [:]
        record.reserveCapacity(dict.count * 2)
        for (key, value) in dict {
            let trimmed = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            record[key] = trimmed
            record[key.lowercased()] = trimmed
        }
        return record
    }

    // MARK: - Merge / Capabilities helpers

    private func merge(existing: DiscoveredDevice, update: DiscoveredDevice) -> DiscoveredDevice {
        var merged = existing

        // name：优先保留“非 Unknown/非空”的更友好字段
        if merged.name.isEmpty || merged.name == "Unknown Device" || merged.name == "未知设备" {
            merged.name = update.name
        }

        if merged.bonjourServiceName == nil || merged.bonjourServiceName?.isEmpty == true {
            merged.bonjourServiceName = update.bonjourServiceName
        }

        // platform/osVersion/model：尽量补齐（避免 Unknown 覆盖有效值）
        if merged.platform == .unknown && update.platform != .unknown { merged.platform = update.platform }
        if isUnknownValue(merged.osVersion) && !isUnknownValue(update.osVersion) { merged.osVersion = update.osVersion }
        if isUnknownValue(merged.modelName) && !isUnknownValue(update.modelName) { merged.modelName = update.modelName }

        // 最新 IP / Bonjour type/domain（优先保留已有的主服务类型，缺省时补齐）
        if merged.ipAddress == nil { merged.ipAddress = update.ipAddress }
        if merged.bonjourServiceType == nil { merged.bonjourServiceType = update.bonjourServiceType }
        if merged.bonjourServiceDomain == nil { merged.bonjourServiceDomain = update.bonjourServiceDomain }

        // 合并 services / portMap
        for s in update.services where !merged.services.contains(s) { merged.services.append(s) }
        for (k, v) in update.portMap { merged.portMap[k] = v }

        // 信号强度：Bonjour 不一定能拿到“真实 RSSI”，但如果 TXT/启发式有新值，优先采用最新值
        merged.signalStrength = update.signalStrength

        // 合并 advertisedCapabilities（TXT）
        let txtUnion = Set(merged.advertisedCapabilities).union(update.advertisedCapabilities)
        merged.advertisedCapabilities = Array(txtUnion).sorted()

        // 合并 capabilities（TXT + inferred）
        merged.capabilities = recomputeCapabilities(existing: merged)

        // 时间戳
        merged.lastSeen = Date()

        return merged
    }

    private func capabilitiesInferred(from serviceType: DiscoveryServiceType) -> Set<String> {
        switch serviceType {
        case .skybridgeTransfer:
            return ["file_transfer"]
        case .skybridgeRemote:
            return ["remote_desktop"]
        default:
            return []
        }
    }

    private func recomputeCapabilities(existing: DiscoveredDevice) -> [String] {
        var caps = Set(existing.advertisedCapabilities)
        for s in existing.services {
            if s == DiscoveryServiceType.skybridgeTransfer.rawValue { caps.insert("file_transfer") }
            if s == DiscoveryServiceType.skybridgeRemote.rawValue { caps.insert("remote_desktop") }
        }
        return Array(caps).sorted()
    }

    private func parseCapabilities(from txtRecord: [String: String]) -> [String] {
        guard let raw = txtValue(txtRecord, "capabilities") else { return [] }
        // 支持 “a,b,c” / “a; b; c” / “a b c”
        let separators = CharacterSet(charactersIn: ",; ")
        return raw
            .lowercased()
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { normalizeCapability($0) }
    }

    private func normalizeCapability(_ cap: String) -> String {
        // 兼容不同命名：file-transfer -> file_transfer
        cap.replacingOccurrences(of: "-", with: "_")
    }

    private func parsePort(for serviceType: DiscoveryServiceType, from txt: [String: String]) -> UInt16? {
        func parseUInt16(_ s: String?) -> UInt16? {
            guard let s, !s.isEmpty else { return nil }
            return UInt16(s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))
        }

        switch serviceType {
        case .skybridgeTransfer:
            return parseUInt16(txtValue(txt, "transferPort"))
                ?? parseUInt16(txtValue(txt, "fileTransferPort"))
                ?? parseUInt16(txtValue(txt, "file_transfer_port"))
                ?? parseUInt16(txtValue(txt, "port"))
        case .skybridgeRemote:
            return parseUInt16(txtValue(txt, "remotePort"))
                ?? parseUInt16(txtValue(txt, "remoteControlPort"))
                ?? parseUInt16(txtValue(txt, "remote_port"))
                ?? parseUInt16(txtValue(txt, "port"))
        default:
            return nil
        }
    }

    // MARK: - Signal strength (RSSI)

    /// 尝试从 TXT 记录提取 RSSI；若不存在，则根据网络接口类型给出一个稳定的启发式默认值。
    ///
    /// 说明：
    /// - Bonjour/mDNS 本身不携带 RSSI；若需要“真实 RSSI”，需由发布方把 `rssi` 写入 TXT 记录，
    ///   或使用更底层的无线扫描 API（iOS 上通常不可行/受限）。
    private func resolveSignalStrength(from txtRecord: [String: String], endpoint: NWEndpoint) -> Int {
        if let raw = txtValue(txtRecord, "rssi", "signalStrength", "signal_strength", "signal"),
           let parsed = parseRSSI(raw) {
            return parsed
        }
        return defaultSignalStrength(for: endpoint)
    }

    private func parseRSSI(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 常见形式："-65" / "-65.2" / "-65 dBm"
        let cleaned = trimmed
            .replacingOccurrences(of: "dbm", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        if let v = Int(cleaned) { return v }
        if let d = Double(cleaned) { return Int(d.rounded()) }

        // 兜底：提取数字部分
        let numeric = cleaned.filter { "-0123456789.".contains($0) }
        if let d = Double(numeric) { return Int(d.rounded()) }
        return nil
    }

    private func defaultSignalStrength(for endpoint: NWEndpoint) -> Int {
        if case .service(_, _, _, let interface) = endpoint, let interface {
            // AWDL（AirDrop/点对点）一般信号更好一些
            if interface.name == "awdl0" { return -45 }
            switch interface.type {
            case .wifi: return -50
            case .wiredEthernet: return -35
            case .cellular: return -85
            case .loopback: return -10
            case .other: return -65
            @unknown default: return -60
            }
        }
        return -60
    }
    
    /// 检测平台
    private func detectPlatform(
        from txtRecord: [String: String],
        serviceType: DiscoveryServiceType,
        name: String
    ) -> DevicePlatform {
        // 1. 优先从 TXT 记录获取
        if let platformStr = txtValue(txtRecord, "platform", "os")?.lowercased() {
            switch platformStr {
            case "ios": return .iOS
            case "ipados": return .iPadOS
            case "macos", "mac": return .macOS
            case "android": return .android
            case "windows", "win": return .windows
            case "linux": return .linux
            default: break
            }
        }
        
        // 2. 根据服务类型推断
        switch serviceType {
        case .airdrop, .companionLink:
            // Apple 专属服务
            if name.lowercased().contains("iphone") {
                return .iOS
            } else if name.lowercased().contains("ipad") {
                return .iPadOS
            } else if name.lowercased().contains("mac") {
                return .macOS
            }
            return .macOS // 默认 Apple 设备
            
        case .androidShare:
            return .android
            
        case .rdp:
            // RDP 通常是 Windows
            return .windows
            
        default:
            break
        }
        
        // 3. 根据设备名称推断
        let nameLower = name.lowercased()
        if nameLower.contains("iphone") {
            return .iOS
        } else if nameLower.contains("ipad") {
            return .iPadOS
        } else if nameLower.contains("mac") || nameLower.contains("imac") || nameLower.contains("macbook") {
            return .macOS
        } else if nameLower.contains("pixel") || nameLower.contains("samsung") || nameLower.contains("xiaomi") || nameLower.contains("android") {
            return .android
        } else if nameLower.contains("windows") || nameLower.contains("desktop-") || nameLower.contains("laptop-") {
            return .windows
        } else if nameLower.contains("linux") || nameLower.contains("ubuntu") || nameLower.contains("fedora") || nameLower.contains("debian") {
            return .linux
        }
        
        return .unknown
    }
    
    /// 根据名称推断型号
    private func detectModelFromName(_ name: String, platform: DevicePlatform) -> String {
        let nameLower = name.lowercased()
        
        switch platform {
        case .iOS:
            if nameLower.contains("iphone") {
                return "iPhone"
            }
            return "iOS Device"
            
        case .iPadOS:
            if nameLower.contains("ipad pro") {
                return "iPad Pro"
            } else if nameLower.contains("ipad air") {
                return "iPad Air"
            } else if nameLower.contains("ipad mini") {
                return "iPad mini"
            }
            return "iPad"
            
        case .macOS:
            if nameLower.contains("macbook pro") {
                return "MacBook Pro"
            } else if nameLower.contains("macbook air") {
                return "MacBook Air"
            } else if nameLower.contains("imac") {
                return "iMac"
            } else if nameLower.contains("mac mini") {
                return "Mac mini"
            } else if nameLower.contains("mac studio") {
                return "Mac Studio"
            } else if nameLower.contains("mac pro") {
                return "Mac Pro"
            }
            return "Mac"
            
        case .android:
            if nameLower.contains("pixel") {
                return "Google Pixel"
            } else if nameLower.contains("samsung") || nameLower.contains("galaxy") {
                return "Samsung Galaxy"
            } else if nameLower.contains("xiaomi") {
                return "Xiaomi"
            } else if nameLower.contains("oneplus") {
                return "OnePlus"
            }
            return "Android Device"
            
        case .windows:
            return "Windows PC"
            
        case .linux:
            return "Linux PC"
            
        case .unknown:
            return "Unknown"
        }
    }
    
    /// 提取 IP 地址
    private func extractIPAddress(from endpoint: NWEndpoint) -> String? {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let address):
                return "\(address)"
            case .ipv6(let address):
                return "\(address)"
            default:
                return nil
            }
        case .service(_, _, _, _):
            // 服务端点需要解析才能获取 IP
            return nil
        default:
            return nil
        }
    }

    /// 提取 Bonjour Service (type/domain)，用于后续直接通过 NWEndpoint.service 连接（无需解析出 IP）
    private func extractBonjourService(
        from endpoint: NWEndpoint,
        fallbackServiceType: DiscoveryServiceType
    ) -> (type: String?, domain: String?) {
        if case .service(_, let type, let domain, _) = endpoint {
            return (type, domain)
        }
        // 兜底：至少保存本次发现的 serviceType（domain 通常为 local.）
        return (fallbackServiceType.rawValue, "local.")
    }
    
    // MARK: - Private Methods - Listener
    
    private func handleListenerStateChange(_ state: NWListener.State) async {
        switch state {
        case .ready:
            if let port = listener?.port {
                SkyBridgeLogger.shared.info("✅ 监听器就绪，端口: \(port)")
            } else {
                SkyBridgeLogger.shared.info("✅ 监听器就绪")
            }

        case .failed(let error):
            SkyBridgeLogger.shared.error("❌ 监听器失败: \(error.localizedDescription)")
            self.error = error
            isAdvertising = false

        case .cancelled:
            SkyBridgeLogger.shared.info("⏹️ 监听器已取消")
            isAdvertising = false
            
        default:
            break
        }
    }
    
    private func handleNewIncomingConnection(_ connection: NWConnection) async {
        SkyBridgeLogger.shared.info("📞 收到新连接")
        
        let peerId = extractPeerId(from: connection)
        
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    SkyBridgeLogger.shared.info("✅ 入站连接就绪: \(peerId)")
                    self?.onNewConnection?(connection, peerId)
                    
                case .failed(let error):
                    SkyBridgeLogger.shared.error("❌ 入站连接失败: \(error.localizedDescription)")
                    
                case .cancelled:
                    SkyBridgeLogger.shared.info("⏹️ 入站连接已取消")
                    
                default:
                    break
                }
            }
        }
        
        connection.start(queue: queue)
    }
    
    private func extractPeerId(from connection: NWConnection) -> String {
        // Prefer mapping back to an already-discovered stable device id if possible.
        // This is critical for UI refresh: the device list is keyed by `DiscoveredDevice.id` (stableDeviceId),
        // while inbound NWConnection endpoints often arrive as hostPort (IP) and would otherwise mismatch.
        let endpointKey = connection.endpoint.debugDescription
        if let mapped = endpointToDeviceId[endpointKey] {
            return mapped
        }

        // Fall back to a stable host-based id (matches stableDeviceId(from:) for hostPort endpoints).
        if case .hostPort(let host, _) = connection.endpoint {
            switch host {
            case .ipv4(let addr):
                return "host:\(addr)"
            case .ipv6(let addr):
                return "host:\(addr)"
            default:
                break
            }
        }

        return endpointKey
    }
    
    // MARK: - Private Methods - TXT Record
    
    /// 创建 TXT 记录（用于广播）
    private func createTXTRecord() -> NWTXTRecord {
        var record = NWTXTRecord()
        
        // 平台信息
        record["platform"] = localPlatform.rawValue
        record["osVersion"] = localOSVersion
        record["model"] = localModel
        
        // PQC 支持状态
        if #available(iOS 17.0, *) {
            let capability = CryptoProviderFactory.detectCapability()
            if capability.hasApplePQC {
                record["pqc"] = "native"
            } else if capability.hasLiboqs {
                record["pqc"] = "liboqs"
            } else {
                record["pqc"] = "classic"
            }
        } else {
            record["pqc"] = "classic"
        }
        
        // 协议版本
        record["version"] = "1"
        
        // 设备 ID（用于与 macOS 端对齐的稳定主键；不要截断，避免碰撞）
        #if canImport(UIKit)
        if let uuid = UIDevice.current.identifierForVendor?.uuidString {
            record["deviceId"] = uuid
            record["uuid"] = uuid
        }
        #endif
        
        return record
    }
    
    // MARK: - Private Methods - Cleanup
    
    /// 启动设备清理定时器
    private func startCleanupTimer() {
        cleanupTimer?.invalidate()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.cleanupStaleDevices()
            }
        }
    }

    private func startPeriodicRefreshTimer() {
        periodicRefreshTimer?.invalidate()
        periodicRefreshTimer = nil

        guard periodicRefreshIntervalSeconds > 0 else { return }

        periodicRefreshTimer = Timer.scheduledTimer(withTimeInterval: periodicRefreshIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Soft refresh only (see `refresh()`).
                await self?.refresh()
            }
        }
        SkyBridgeLogger.shared.debug("🔁 设备发现周期刷新已启用：\(periodicRefreshIntervalSeconds)s")
    }
    
    /// 清理过期设备
    private func cleanupStaleDevices() {
        let now = Date()
        var removedCount = 0
        
        for (deviceId, lastActivity) in deviceLastActivity {
            if now.timeIntervalSince(lastActivity) > deviceTimeout {
                deviceCache.removeValue(forKey: deviceId)
                deviceLastActivity.removeValue(forKey: deviceId)
                removedCount += 1
            }
        }
        
        if removedCount > 0 {
            updateDiscoveredDevices()
            SkyBridgeLogger.shared.debug("🧹 清理了 \(removedCount) 个过期设备")
        }
    }
    
    /// 更新发现的设备列表
    private func updateDiscoveredDevices() {
        // 按最后活动时间排序
        discoveredDevices = Array(deviceCache.values).sorted { $0.lastSeen > $1.lastSeen }
        
        // 按平台分组
        var grouped: [DevicePlatform: [DiscoveredDevice]] = [:]
        for device in discoveredDevices {
            grouped[device.platform, default: []].append(device)
        }
        devicesByPlatform = grouped
    }
    
    // MARK: - Public Helpers
    
    /// 获取特定平台的设备
    public func devices(for platform: DevicePlatform) -> [DiscoveredDevice] {
        devicesByPlatform[platform] ?? []
    }
    
    /// 获取 SkyBridge 兼容设备（支持 PQC 握手）
    public func skybridgeCompatibleDevices() -> [DiscoveredDevice] {
        // 目前所有发现的设备都可能兼容
        // 后续可以根据 TXT 记录中的 pqc 字段过滤
        discoveredDevices
    }
    
    /// 解析服务端点以获取 IP 地址
    public func resolveEndpoint(_ device: DiscoveredDevice) async -> String? {
        // 如果已经有 IP 地址，直接返回
        if let ip = device.ipAddress {
            return ip
        }

        guard let name = device.bonjourServiceName,
              let type = device.bonjourServiceType,
              let domain = device.bonjourServiceDomain else {
            return nil
        }

        // Bonjour service -> IP：优先用 NetService 做 DNS-SD 解析（不需要真的建立 TCP 连接）
        let resolved = await resolveBonjourServiceIPAddress(
            name: name,
            type: type,
            domain: domain,
            timeout: 2.0
        )

        if let resolved, var cached = deviceCache[device.id] {
            cached.ipAddress = resolved
            cached.lastSeen = Date()
            deviceCache[device.id] = cached
            updateDiscoveredDevices()
        }

        return resolved
    }

    private func resolveBonjourServiceIPAddress(
        name: String,
        type: String,
        domain: String,
        timeout: TimeInterval
    ) async -> String? {
        let normalizedType = type.hasSuffix(".") ? type : (type + ".")
        let d = domain.isEmpty ? "local." : domain
        let normalizedDomain = d.hasSuffix(".") ? d : (d + ".")

        let service = NetService(domain: normalizedDomain, type: normalizedType, name: name)
        let resolver = BonjourNetServiceResolver(service: service, timeout: timeout)
        return await resolver.resolve()
    }
}

// MARK: - NWTXTRecord Extension

extension NWTXTRecord {
    /// 获取字典形式的 TXT 记录
    var dictionary: [String: String]? {
        var result: [String: String] = [:]
        
        // NWTXTRecord 支持下标访问
        // 但我们需要遍历已知的键
        let knownKeys = [
            // identity
            "deviceId", "deviceID", "device_id", "uuid", "id", "uniqueId", "unique_id", "pubKeyFP", "pubKeyFp",
            // system
            "platform", "osVersion", "os_version", "platformVersion", "platform_version", "os", "systemVersion",
            "model", "hardwareModel", "hwModel", "name",
            // features
            "capabilities", "pqc", "version",
            // signal
            "rssi", "signalStrength", "signal_strength", "signal",
            // ports (for UI)
            "transferPort", "fileTransferPort", "file_transfer_port",
            "remotePort", "remoteControlPort", "remote_port",
            "port"
        ]
        
        for key in knownKeys {
            if let value = self[key] ?? self[key.lowercased()] {
                result[key] = value
                result[key.lowercased()] = value
            }
        }
        
        return result.isEmpty ? nil : result
    }
}

// MARK: - Bonjour resolver (NetService)

/// 将 Bonjour service (name/type/domain) 解析为一个可展示/可连接的 IP 字符串。
///
/// Swift 6 严格并发说明：
/// - `NetService` 不是 Sendable，delegate 回调可能发生在任意线程；因此 delegate 方法标记为 `nonisolated`
/// - 回调中只提取 `Data`（Sendable）后切回 `@MainActor` 完成收尾与 continuation
@MainActor
private final class BonjourNetServiceResolver: NSObject, NetServiceDelegate {
    private let service: NetService
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<String?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    init(service: NetService, timeout: TimeInterval) {
        self.service = service
        self.timeout = timeout
        super.init()
    }

    func resolve() async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            self.continuation = cont
            service.delegate = self
            service.resolve(withTimeout: timeout)

            // 兜底超时：确保 continuation 一定会被 resume
            timeoutTask?.cancel()
            timeoutTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let nanos = UInt64((timeout + 0.2) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                self.finish(nil)
            }
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let ip = preferredIPAddress(from: sender.addresses)
        Task { @MainActor in
            self.finish(ip)
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        _ = errorDict
        Task { @MainActor in
            self.finish(nil)
        }
    }

    private func finish(_ ip: String?) {
        guard !finished else { return }
        finished = true

        timeoutTask?.cancel()
        timeoutTask = nil

        service.stop()
        service.delegate = nil

        continuation?.resume(returning: ip)
        continuation = nil
    }
}

private func preferredIPAddress(from addresses: [Data]?) -> String? {
    guard let addresses, !addresses.isEmpty else { return nil }

    var ipv6Candidate: String?
    for data in addresses {
        guard let ip = ipString(from: data) else { continue }
        // 优先返回 IPv4（更易用于 UI 展示与后续连接）
        if ip.contains(".") { return ip }
        if ipv6Candidate == nil { ipv6Candidate = ip }
    }
    return ipv6Candidate
}

private func ipString(from addressData: Data) -> String? {
    addressData.withUnsafeBytes { rawBuffer -> String? in
        guard let base = rawBuffer.baseAddress else { return nil }
        let sockaddrPtr = base.assumingMemoryBound(to: sockaddr.self)

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            sockaddrPtr,
            socklen_t(addressData.count),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
	        )
	        guard result == 0 else { return nil }
	        return host.withUnsafeBufferPointer { buffer in
	            guard let base = buffer.baseAddress else { return nil }
	            return String(cString: base)
	        }
	    }
	}
