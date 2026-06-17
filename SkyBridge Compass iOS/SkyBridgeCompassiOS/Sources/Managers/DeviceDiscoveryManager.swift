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
#if canImport(CoreTelephony)
import CoreTelephony
#endif
#if canImport(NetworkExtension)
import NetworkExtension
#endif
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

    /// 运行时可能浏览的全部 Bonjour 服务；Info.plist 的 NSBonjourServices 需要覆盖这份清单。
    public static var requiredBonjourPrivacyDeclarations: [String] {
        allCases.map(\.rawValue)
    }
    
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

enum PeerIdentityAliasResolver {
    static func normalizedIdentifier(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw.lowercased()
    }

    private static func isPlausibleStableDeviceIdentifierPayload(_ raw: String) -> Bool {
        guard raw.count >= 8 else { return false }
        guard !raw.contains(where: \.isWhitespace) else { return false }
        return raw.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_" || character == ".")
        }
    }

    private static func isLiteralIPAddress(_ raw: String) -> Bool {
        let scopedToken = raw.split(separator: "%", maxSplits: 1).first.map(String.init) ?? raw
        return IPv4Address(scopedToken) != nil || IPv6Address(scopedToken) != nil
    }

    static func persistentDeviceId(from raw: String?) -> String? {
        guard let normalized = normalizedIdentifier(raw) else { return nil }
        if normalized.hasPrefix("id:") {
            let payload = String(normalized.dropFirst("id:".count))
            guard isPlausibleStableDeviceIdentifierPayload(payload) else { return nil }
            guard !isLiteralIPAddress(payload) else { return nil }
            return "id:\(payload)"
        }
        if normalized.hasPrefix("host:")
            || normalized.hasPrefix("peer:")
            || normalized.hasPrefix("bonjour:")
            || normalized.hasPrefix("recent:")
            || normalized.contains("@") {
            return nil
        }
        guard isPlausibleStableDeviceIdentifierPayload(normalized) else { return nil }
        guard !isLiteralIPAddress(normalized) else { return nil }
        return "id:\(normalized)"
    }

    static func isEndpointAlias(_ raw: String?) -> Bool {
        guard let normalized = normalizedIdentifier(raw) else { return false }
        if normalized.hasPrefix("recent:") {
            return isEndpointAlias(String(normalized.dropFirst("recent:".count)))
        }
        if normalized.hasPrefix("host:") || normalized.hasPrefix("peer:") {
            return true
        }
        if normalized.hasPrefix("id:") {
            let payload = String(normalized.dropFirst("id:".count))
            return isLiteralIPAddress(payload)
        }
        return isLiteralIPAddress(normalized)
    }

    static func lookupCandidates(for identifier: String?) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        func append(_ raw: String?) {
            guard let normalized = normalizedIdentifier(raw),
                  !normalized.isEmpty,
                  seen.insert(normalized).inserted else {
                return
            }
            ordered.append(normalized)
        }

        func appendDerived(_ raw: String?) {
            guard let normalized = normalizedIdentifier(raw) else { return }
            append(normalized)

            if normalized.hasPrefix("recent:") {
                appendDerived(String(normalized.dropFirst("recent:".count)))
            }

            if normalized.hasPrefix("id:") {
                append(String(normalized.dropFirst("id:".count)))
            } else if let persistent = persistentDeviceId(from: normalized) {
                append(persistent)
            }

            if let alias = hostAlias(from: normalized) {
                append(alias)
            }

            if let alias = hostAlias(fromIPAddress: normalized) {
                append(alias)
            }

            if let alias = bonjourAlias(from: normalized) {
                append(alias)
            }
        }

        appendDerived(identifier)
        return ordered
    }

    static func aliasKeys(for device: DiscoveredDevice) -> [String] {
        var keys = Set<String>()

        let normalizedId = device.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedId.isEmpty {
            keys.insert(normalizedId)
        }

        if let alias = hostAlias(from: device.id) {
            keys.insert(alias)
        }

        if let alias = hostAlias(fromIPAddress: device.ipAddress) {
            keys.insert(alias)
        }

        if let alias = bonjourAlias(
            name: device.bonjourServiceName,
            domain: device.bonjourServiceDomain
        ) {
            keys.insert(alias)
        } else if let alias = bonjourAlias(from: device.id) {
            keys.insert(alias)
        }

        return Array(keys)
    }

    static func resolveDeviceId(
        for endpoint: NWEndpoint,
        endpointKey: String? = nil,
        exactEndpointMap: [String: String],
        aliasMap: [String: String]
    ) -> String? {
        if let endpointKey,
           let exact = exactEndpointMap[endpointKey] {
            return exact
        }

        for alias in candidateAliases(for: endpoint, endpointKey: endpointKey) {
            if let mapped = aliasMap[alias] {
                return mapped
            }
        }

        return nil
    }

    private static func candidateAliases(for endpoint: NWEndpoint, endpointKey: String? = nil) -> [String] {
        var keys = Set<String>()
        if let endpointKey {
            let normalized = endpointKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalized.isEmpty {
                keys.insert(normalized)
            }
        }

        switch endpoint {
        case .service(let name, _, let domain, _):
            if let alias = bonjourAlias(name: name, domain: domain) {
                keys.insert(alias)
            }
        case .hostPort(let host, _):
            if let alias = hostAlias(fromIPAddress: String(describing: host)) {
                keys.insert(alias)
            }
        default:
            break
        }

        return Array(keys)
    }

    private static func hostAlias(from identifier: String) -> String? {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("host:") {
            return hostAlias(fromIPAddress: String(normalized.dropFirst("host:".count)))
        }
        if normalized.hasPrefix("peer:") {
            return hostAlias(fromIPAddress: String(normalized.dropFirst("peer:".count)))
        }
        return nil
    }

    static func hostAlias(fromIPAddress raw: String?) -> String? {
        guard var token = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !token.isEmpty else {
            return nil
        }

        if token.hasPrefix("host:") {
            token = String(token.dropFirst("host:".count))
        } else if token.hasPrefix("peer:") {
            token = String(token.dropFirst("peer:".count))
        }

        if token.hasPrefix("["),
           let closeBracket = token.firstIndex(of: "]"),
           closeBracket > token.startIndex {
            token = String(token[token.index(after: token.startIndex)..<closeBracket])
        }

        if let percent = token.firstIndex(of: "%") {
            token = String(token[..<percent])
        }

        if token.contains(":"),
           let dot = token.lastIndex(of: "."),
           token[token.index(after: dot)...].allSatisfy({ $0.isNumber }) {
            token = String(token[..<dot])
        } else {
            let parts = token.split(separator: ".")
            if parts.count == 5,
               parts.dropLast().allSatisfy({ Int($0) != nil }),
               let port = Int(parts.last ?? ""),
               (0...65535).contains(port) {
                token = parts.dropLast().map(String.init).joined(separator: ".")
            }
        }

        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, isLiteralIPAddress(normalized) else { return nil }
        return "host:\(normalized)"
    }

    private static func bonjourAlias(from identifier: String) -> String? {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.lowercased().hasPrefix("bonjour:") else { return nil }

        let payload = String(normalized.dropFirst("bonjour:".count))
        let parts = payload.split(separator: "@", maxSplits: 1).map(String.init)
        guard let name = parts.first, !name.isEmpty else { return nil }
        let domain = parts.count > 1 ? parts[1] : "local."
        return bonjourAlias(name: name, domain: domain)
    }

    private static func bonjourAlias(name: String?, domain: String?) -> String? {
        guard let rawName = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty else {
            return nil
        }

        let rawDomain = domain?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "local."
        let normalizedDomain: String
        if rawDomain.isEmpty {
            normalizedDomain = "local."
        } else if rawDomain.hasSuffix(".") {
            normalizedDomain = rawDomain.lowercased()
        } else {
            normalizedDomain = "\(rawDomain.lowercased())."
        }

        return "bonjour:\(rawName.lowercased())@\(normalizedDomain)"
    }
}

// MARK: - DeviceDiscoveryManager

/// 跨平台设备发现管理器
/// 支持发现 iOS、iPadOS、macOS、Android、Windows、Linux 设备
@MainActor
public class DeviceDiscoveryManager: ObservableObject {
    public static let instance = DeviceDiscoveryManager()
    nonisolated static let bonjourAuthorizationDNSCode: Int32 = -65555
    
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

    /// 每个浏览器当前仍持有的 endpoint 快照；用于区分“设备静默在线”与“设备已真正离线”。
    private var liveBrowseEndpointKeysByServiceType: [DiscoveryServiceType: Set<String>] = [:]

    /// host/bonjour 等别名 -> 稳定 deviceId，避免入站连接退化成临时 host 身份
    private var identityAliasToDeviceId: [String: String] = [:]

    /// 从 Bonjour TXT/endpoint 捕获的身份别名；用于保留 link-local IPv6 等不可路由但可认证的来源地址
    private var discoveryIdentityAliasesByDeviceId: [String: Set<String>] = [:]
    
    /// 设备最后活动时间
    private var deviceLastActivity: [String: Date] = [:]
    
    /// 调度队列
    private let queue = DispatchQueue(label: "com.skybridge.discovery", qos: .userInitiated)
    
    /// 设备清理定时器
    private var cleanupTimer: Timer?

    /// 合并高频 Bonjour 浏览事件的去抖任务：避免每个 add/change/remove 都同步触发 O(n²) 去重+重建
    /// （主线程负担、扫描时耗电/卡顿）。在最后一个事件后 ~250ms 统一重算一次。
    private var pendingDiscoveredDevicesUpdateTask: Task<Void, Never>?

    /// 周期性刷新定时器（省电策略：周期 refresh，而不是一直保持浏览器常驻）
    private var periodicRefreshTimer: Timer?
    private var periodicRefreshIntervalSeconds: TimeInterval = 0
    private var lastAlreadyRunningLogAt: Date?
    private var authorizationBlockedServiceTypes = Set<DiscoveryServiceType>()
    private var authorizationRecoveryTasks: [DiscoveryServiceType: Task<Void, Never>] = [:]
    private var authorizationRecoveryAttempts: [DiscoveryServiceType: Int] = [:]
    
    /// 设备超时时间（秒）
    private let deviceTimeout: TimeInterval = 60
    
    /// 新连接回调
    public var onNewConnection: ((NWConnection, String) -> Void)?
    
    /// 本机设备名称
    private var deviceName: String {
        #if canImport(UIKit)
        return AppleMobileDeviceIdentity.currentSnapshot().deviceName
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }
    
    /// 本机平台
    private var localPlatform: DevicePlatform {
        #if os(iOS)
        return AppleMobileDeviceIdentity.currentSnapshot().platform
        #elseif os(macOS)
        return .macOS
        #else
        return .unknown
        #endif
    }
    
    /// 本机 OS 版本
    private var localOSVersion: String {
        #if canImport(UIKit)
        return AppleMobileDeviceIdentity.currentSnapshot().osVersion
        #else
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #endif
    }
    
    /// 本机型号
    private var localModel: String {
        #if canImport(UIKit)
        return AppleMobileDeviceIdentity.currentSnapshot().modelName
        #else
        return "Mac"
        #endif
    }

    /// 本机芯片信息（用于对端 UI 与诊断）
    private var localChip: String? {
        #if canImport(UIKit)
        return AppleMobileDeviceIdentity.currentSnapshot().chip
        #else
        return nil
        #endif
    }

    /// 本机稳定设备 ID（与 stableDeviceId 生成策略对齐）
    private var localStableDeviceId: String? {
        #if canImport(UIKit)
        let raw = AppleMobileDeviceIdentity.currentSnapshot().stableDeviceId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !raw.isEmpty else { return nil }
        return "id:\(raw)"
        #else
        return nil
        #endif
    }
    
    private init() {}

    nonisolated static func declaredBonjourServices(in bundle: Bundle = .main) -> Set<String> {
        let raw = bundle.object(forInfoDictionaryKey: "NSBonjourServices") as? [String] ?? []
        return Set(raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    nonisolated static func hasLocalNetworkUsageDescription(in bundle: Bundle = .main) -> Bool {
        guard let raw = bundle.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String else {
            return false
        }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static func isBonjourAuthorizationError(_ error: NWError) -> Bool {
        if case .dns(let dnsError) = error {
            return dnsError == bonjourAuthorizationDNSCode
        }
        return false
    }

    nonisolated static func shouldAutoRecoverBrowser(after error: NWError) -> Bool {
        !isBonjourAuthorizationError(error)
    }

    nonisolated static func authorizationRecoveryDelay(forAttempt attempt: Int) -> TimeInterval? {
        switch attempt {
        case 1: return 2
        case 2: return 5
        case 3: return 10
        default: return nil
        }
    }
    
    // MARK: - Discovery Control
    
    /// 开始发现设备
    /// - Parameter mode: 发现模式
    public func startDiscovery(mode: DiscoveryMode? = nil) async throws {
        if let mode = mode {
            self.discoveryMode = mode
        }

        if isDiscovering {
            // 这里很容易被重复触发（UI/scenePhase/设置变更），加节流避免日志刷屏与内存压力
            let now = Date()
            if let lastLogAt = lastAlreadyRunningLogAt,
               now.timeIntervalSince(lastLogAt) > 5 {
                lastAlreadyRunningLogAt = now
                SkyBridgeLogger.shared.debug("📡 设备发现已在运行，执行自愈检查")
            } else if lastAlreadyRunningLogAt == nil {
                lastAlreadyRunningLogAt = now
                SkyBridgeLogger.shared.debug("📡 设备发现已在运行，执行自愈检查")
            }

            // 关键修复：即使 isDiscovering=true，也要按当前模式补齐/重建浏览器，
            // 避免网络抖动或系统省电导致 NWBrowser 失效后“手动发现无效”。
            reconcileBrowsersForCurrentMode()
            startCleanupTimer()
            if periodicRefreshIntervalSeconds > 0 {
                startPeriodicRefreshTimer()
            }
            return
        }

        isDiscovering = true
        error = nil

        SkyBridgeLogger.shared.info("🔍 开始设备发现 (模式: \(String(describing: discoveryMode)))")
        reconcileBrowsersForCurrentMode()

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
        liveBrowseEndpointKeysByServiceType.removeAll()
        
        // 停止清理定时器
        cleanupTimer?.invalidate()
        cleanupTimer = nil

        // 停止周期刷新
        periodicRefreshTimer?.invalidate()
        periodicRefreshTimer = nil
        authorizationBlockedServiceTypes.removeAll()
        cancelAuthorizationRecoveryTasks()
        authorizationRecoveryAttempts.removeAll()
        
        isDiscovering = false
        SkyBridgeLogger.shared.info("⏹️ 设备发现已停止")
    }

    func retryAuthorizationBlockedBrowsers() {
        guard !authorizationBlockedServiceTypes.isEmpty else { return }
        let blockedTypes = authorizationBlockedServiceTypes
        authorizationBlockedServiceTypes.removeAll()
        for serviceType in blockedTypes {
            authorizationRecoveryTasks[serviceType]?.cancel()
            authorizationRecoveryTasks.removeValue(forKey: serviceType)
            authorizationRecoveryAttempts.removeValue(forKey: serviceType)
        }
        if isDiscovering {
            reconcileBrowsersForCurrentMode()
        }
    }
    
    /// 刷新设备列表
    public func refresh() async {
        if !isDiscovering {
            deviceCache.removeAll()
            endpointToDeviceId.removeAll()
            identityAliasToDeviceId.removeAll()
            discoveryIdentityAliasesByDeviceId.removeAll()
            deviceLastActivity.removeAll()
            liveBrowseEndpointKeysByServiceType.removeAll()
            updateDiscoveredDevices()
            try? await startDiscovery()
        } else {
            // Soft refresh only.  Keep the current cache alive and let the
            // active browser snapshots decide which devices are still present.
            reconcileBrowsersForCurrentMode()
            cleanupStaleDevices()
            updateDiscoveredDevices()
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
        
        // 创建 TXT 记录。Bonjour `deviceId` must be the same protocol authority
        // identity used by MessageA/PIB; Apple mobile/vendor IDs are aliases only.
        let txtRecord = await createTXTRecord(port: port)
        
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

    private func reconcileBrowsersForCurrentMode() {
        let desiredTypes = Set(discoveryMode.serviceTypes)
        authorizationBlockedServiceTypes.formIntersection(desiredTypes)

        let staleTypes = browsers.keys.filter { !desiredTypes.contains($0) }
        for stale in staleTypes {
            browsers[stale]?.cancel()
            browsers.removeValue(forKey: stale)
            liveBrowseEndpointKeysByServiceType.removeValue(forKey: stale)
            SkyBridgeLogger.shared.debug("⏹️ 停止非当前模式浏览器: \(stale.rawValue)")
        }

        for serviceType in discoveryMode.serviceTypes where browsers[serviceType] == nil {
            guard !authorizationBlockedServiceTypes.contains(serviceType) else {
                SkyBridgeLogger.shared.debug("⏸️ 跳过被授权/隐私策略阻断的浏览器: \(serviceType.rawValue)")
                continue
            }
            startBrowser(for: serviceType)
        }
    }

    private func scheduleBrowserRecovery(for serviceType: DiscoveryServiceType, reason: String) {
        guard isDiscovering else { return }
        guard discoveryMode.serviceTypes.contains(serviceType) else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(900))
            guard self.isDiscovering else { return }
            guard self.discoveryMode.serviceTypes.contains(serviceType) else { return }
            guard self.browsers[serviceType] == nil else { return }

            SkyBridgeLogger.shared.info("🔁 重建浏览器: \(serviceType.rawValue) reason=\(reason)")
            self.startBrowser(for: serviceType)
        }
    }

    private func scheduleAuthorizationRecovery(for serviceType: DiscoveryServiceType) {
        guard isDiscovering else { return }
        guard discoveryMode.serviceTypes.contains(serviceType) else { return }
        guard authorizationBlockedServiceTypes.contains(serviceType) else { return }
        guard browsers[serviceType] == nil else { return }

        let nextAttempt = (authorizationRecoveryAttempts[serviceType] ?? 0) + 1
        guard let delay = Self.authorizationRecoveryDelay(forAttempt: nextAttempt) else {
            SkyBridgeLogger.shared.warning(
                "⏸️ 本地网络授权恢复重试已达上限: \(serviceType.rawValue)"
            )
            return
        }

        authorizationRecoveryAttempts[serviceType] = nextAttempt
        authorizationRecoveryTasks[serviceType]?.cancel()
        authorizationRecoveryTasks[serviceType] = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            guard self.isDiscovering else { return }
            guard self.discoveryMode.serviceTypes.contains(serviceType) else { return }
            guard self.authorizationBlockedServiceTypes.contains(serviceType) else { return }
            guard self.browsers[serviceType] == nil else { return }

            SkyBridgeLogger.shared.info(
                "🔁 本地网络授权恢复重试: \(serviceType.rawValue) attempt=\(nextAttempt)"
            )
            self.authorizationBlockedServiceTypes.remove(serviceType)
            self.startBrowser(for: serviceType)
        }
    }

    private func cancelAuthorizationRecoveryTasks() {
        for task in authorizationRecoveryTasks.values {
            task.cancel()
        }
        authorizationRecoveryTasks.removeAll()
    }

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
            authorizationBlockedServiceTypes.remove(serviceType)
            authorizationRecoveryTasks[serviceType]?.cancel()
            authorizationRecoveryTasks.removeValue(forKey: serviceType)
            authorizationRecoveryAttempts.removeValue(forKey: serviceType)
            SkyBridgeLogger.shared.debug("✅ 浏览器就绪: \(serviceType.rawValue)")
            
        case .failed(let error):
            self.error = error
            browsers.removeValue(forKey: serviceType)
            liveBrowseEndpointKeysByServiceType.removeValue(forKey: serviceType)

            if Self.isBonjourAuthorizationError(error) {
                authorizationBlockedServiceTypes.insert(serviceType)
                let declaredServices = Self.declaredBonjourServices()
                let hasUsageDescription = Self.hasLocalNetworkUsageDescription()
                if !declaredServices.contains(serviceType.rawValue) {
                    SkyBridgeLogger.shared.error(
                        "❌ 浏览器失败 (\(serviceType.rawValue)): NoAuth(-65555)。当前服务类型未声明到 Info.plist 的 NSBonjourServices；iOS 会直接拒绝 DNSServiceBrowse。"
                    )
                } else if !hasUsageDescription {
                    SkyBridgeLogger.shared.error(
                        "❌ 浏览器失败 (\(serviceType.rawValue)): NoAuth(-65555)。Info.plist 缺少 NSLocalNetworkUsageDescription，本地网络授权无法正常申请。"
                    )
                } else {
                    SkyBridgeLogger.shared.error(
                        "❌ 浏览器失败 (\(serviceType.rawValue)): NoAuth(-65555)。本地网络权限当前未授权或已被系统策略拒绝；暂停自动重建，待用户在系统设置授权后再重试。"
                    )
                }
                scheduleAuthorizationRecovery(for: serviceType)
                return
            }

            authorizationBlockedServiceTypes.remove(serviceType)
            authorizationRecoveryTasks[serviceType]?.cancel()
            authorizationRecoveryTasks.removeValue(forKey: serviceType)
            authorizationRecoveryAttempts.removeValue(forKey: serviceType)
            SkyBridgeLogger.shared.error("❌ 浏览器失败 (\(serviceType.rawValue)): \(error.localizedDescription)")
            if Self.shouldAutoRecoverBrowser(after: error) {
                scheduleBrowserRecovery(for: serviceType, reason: "failed")
            }
            
        case .cancelled:
            SkyBridgeLogger.shared.debug("⏹️ 浏览器已取消: \(serviceType.rawValue)")
            browsers.removeValue(forKey: serviceType)
            liveBrowseEndpointKeysByServiceType.removeValue(forKey: serviceType)
            scheduleBrowserRecovery(for: serviceType, reason: "cancelled")
            
        default:
            break
        }
    }
    
    private func handleBrowseResults(
        _ results: Set<NWBrowser.Result>,
        changes: Set<NWBrowser.Result.Change>,
        serviceType: DiscoveryServiceType
    ) async {
        liveBrowseEndpointKeysByServiceType[serviceType] = Set(
            results.map { $0.endpoint.debugDescription }
        )
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
        
        // 过滤自己（同名同平台 / 本机稳定 ID / loopback 地址）
        if isSelfDevice(device) {
            return
        }
        
        // 同一物理设备可能同时广播多个 SkyBridge 服务（p2p/传输/远控）：这里合并能力/端口/系统信息
        if let existing = deviceCache[device.id] {
            deviceCache[device.id] = merge(existing: existing, update: device)
        } else {
            deviceCache[device.id] = device
        }
        endpointToDeviceId[result.endpoint.debugDescription] = device.id
        discoveryIdentityAliasesByDeviceId[device.id, default: []]
            .formUnion(identityAliases(from: result, txtRecord: extractTXTRecord(from: result)))
        deviceLastActivity[device.id] = Date()
        scheduleDiscoveredDevicesUpdate()

        SkyBridgeLogger.shared.info("➕ 发现设备: \(device.name) [\(device.platform.rawValue)] via \(serviceType.displayName)")
    }
    
    private func handleDeviceRemoved(_ result: NWBrowser.Result, serviceType: DiscoveryServiceType) async {
        let endpointKey = result.endpoint.debugDescription
        let deviceId = endpointToDeviceId[endpointKey] ?? endpointKey
        let protectedIdentifiers = P2PConnectionManager.instance.protectedDiscoveryIdentifiers
        let activeIdentifiers = P2PConnectionManager.instance.activeDiscoveryIdentifiers
        let removalAliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: deviceId))
        let shouldPreserve = protectedIdentifiers.contains(deviceId) || !removalAliases.isDisjoint(with: protectedIdentifiers)
        let shouldMarkConnected = activeIdentifiers.contains(deviceId) || !removalAliases.isDisjoint(with: activeIdentifiers)

        guard var existing = deviceCache[deviceId] else {
            deviceCache.removeValue(forKey: deviceId)
            deviceLastActivity.removeValue(forKey: deviceId)
            endpointToDeviceId.removeValue(forKey: endpointKey)
            scheduleDiscoveredDevicesUpdate()
            return
        }

        if shouldPreserve {
            existing.lastSeen = Date()
            existing.isConnected = shouldMarkConnected
            deviceCache[deviceId] = existing
            deviceLastActivity[deviceId] = Date()
            endpointToDeviceId.removeValue(forKey: endpointKey)
            scheduleDiscoveredDevicesUpdate()
            SkyBridgeLogger.shared.debug("ℹ️ 活跃对等端仍受保护，保留服务元数据: \(existing.name) via \(serviceType.displayName)")
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
        if deviceCache[deviceId] == nil {
            discoveryIdentityAliasesByDeviceId.removeValue(forKey: deviceId)
        }
        scheduleDiscoveredDevicesUpdate()
    }
    
    private func handleDeviceChanged(_ result: NWBrowser.Result, serviceType: DiscoveryServiceType) async {
        let device = await createDevice(from: result, serviceType: serviceType)

        if let existing = deviceCache[device.id] {
            deviceCache[device.id] = merge(existing: existing, update: device)
        } else {
            deviceCache[device.id] = device
        }

        endpointToDeviceId[result.endpoint.debugDescription] = device.id
        discoveryIdentityAliasesByDeviceId[device.id, default: []]
            .formUnion(identityAliases(from: result, txtRecord: extractTXTRecord(from: result)))
        deviceLastActivity[device.id] = Date()
        scheduleDiscoveredDevicesUpdate()
    }

    /// 从 NWBrowser.Result 创建设备对象
    private func createDevice(from result: NWBrowser.Result, serviceType: DiscoveryServiceType) async -> DiscoveredDevice {
        let endpoint = result.endpoint
        
        // Bonjour 实例名（连接用）。只接受真实服务实例名，避免 id:/host:/UUID/IP 被伪装成 SOA 身份。
        let rawBonjourName = extractDeviceName(from: endpoint)
        let bonjourName = BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName(rawBonjourName)
        let displayBonjourName = bonjourName ?? "Unknown Device"
        // TXT 记录（用于系统信息/能力/端口展示）
        let txtRecord = extractTXTRecord(from: result)
        // 设备主键：使用“物理身份 key”（忽略 serviceType），避免同一设备多服务重复展示
        let id = stableDeviceId(from: endpoint, txtRecord: txtRecord, sanitizedBonjourName: bonjourName)
        
        // 解析 TXT 记录
        let platform = detectPlatform(from: txtRecord, serviceType: serviceType, name: displayBonjourName)
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
        ) ?? detectModelFromName(displayBonjourName, platform: platform)

        // 显示名称：优先可信 TXT name，其次可信 Bonjour name，再回落到型号。
        let txtDisplayName = BonjourServiceIdentitySanitizer.sanitizedDisplayNameCandidate(
            txtValue(txtRecord, "name")
        )
        let bonjourDisplayName = BonjourServiceIdentitySanitizer.sanitizedDisplayNameCandidate(displayBonjourName)
        let displayName = txtDisplayName
            ?? AppleMobileDeviceIdentity.displayDeviceName(
                rawDeviceName: bonjourDisplayName,
                platform: platform,
                modelName: modelName
            )
        
        // 提取 Bonjour service 信息 / IP 地址
        let ipAddress = extractIPAddress(from: endpoint, txtRecord: txtRecord)
        let (bonjourType, bonjourDomain) = extractBonjourService(from: endpoint, fallbackServiceType: serviceType)
        
        // 提取 PQC 支持信息（当前仅解析，后续可用于 UI 展示/能力协商）
        _ = txtRecord["pqc"] ?? "unknown"
        
        let isTrusted = TrustedDeviceStore.shared.isTrusted(deviceId: id)

        // 能力解析：TXT capabilities + 由 serviceType 推断
        let advertisedCaps = parseCapabilities(from: txtRecord)
        var unionCaps = Set(advertisedCaps)
        unionCaps.formUnion(capabilitiesInferred(from: serviceType))
        if (txtRecord["hs_soa"] ?? txtRecord["HS_SOA"]) == "1" {
            unionCaps.insert("hs_soa")
        }

        // 端口：优先 TXT 端口字段（便于 UI 展示）；连接时可直接使用 .service 不依赖端口
        var portMap: [String: UInt16] = [:]
        if let p = parsePort(for: serviceType, from: txtRecord) {
            portMap[serviceType.rawValue] = p
        } else if case .service(_, _, let servicePort, _) = endpoint,
                  let parsedPort = UInt16(servicePort),
                  parsedPort > 0 {
            portMap[serviceType.rawValue] = parsedPort
        }
        if let transferPort = parseUInt16(txtValue(txtRecord, "transferPort", "fileTransferPort", "file_transfer_port")) {
            portMap[DiscoveredDevice.fileTransferServiceType] = transferPort
        }
        if let remotePort = parseUInt16(txtValue(txtRecord, "remotePort", "remoteControlPort", "remote_port")) {
            portMap[DiscoveredDevice.remoteControlServiceType] = remotePort
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

    private func isLoopbackAddress(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()
        return normalized == "127.0.0.1"
            || normalized == "::1"
            || normalized == "0:0:0:0:0:0:0:1"
            || normalized == "::ffff:127.0.0.1"
    }

    private func isLoopbackEndpoint(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }

        switch host {
        case .ipv4(let address):
            return isLoopbackAddress("\(address)")
        case .ipv6(let address):
            return isLoopbackAddress("\(address)")
        default:
            return false
        }
    }

    private func isSelfDevice(_ device: DiscoveredDevice) -> Bool {
        if let localStableDeviceId,
           device.id.caseInsensitiveCompare(localStableDeviceId) == .orderedSame {
            return true
        }

        if let ipAddress = device.ipAddress,
           isLoopbackAddress(ipAddress) {
            return true
        }

        return device.name == deviceName && device.platform == localPlatform
    }

    /// 生成尽可能稳定的设备 id：
    /// - 使用 Bonjour 实例名 + domain（忽略 serviceType），确保同一设备多个服务只展示一次
    private func stableDeviceId(
        from endpoint: NWEndpoint,
        txtRecord: [String: String],
        sanitizedBonjourName: String?
    ) -> String {
        if let strongId = txtValue(
            txtRecord,
            "deviceId", "deviceID", "device_id",
            "uniqueId", "unique_id",
            "uuid", "id"
        ), let persistent = PeerIdentityAliasResolver.persistentDeviceId(from: strongId) {
            return persistent
        }

        if case .service(let name, _, let domain, _) = endpoint {
            guard let sanitizedName = sanitizedBonjourName
                    ?? BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName(name) else {
                return "endpoint:\(endpoint.debugDescription)"
            }
            let d = domain.isEmpty ? "local." : domain
            return "bonjour:\(sanitizedName)@\(d)"
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

    private func identityAliases(from result: NWBrowser.Result, txtRecord: [String: String]) -> Set<String> {
        var aliases = Set<String>()

        func appendHost(_ raw: String?) {
            guard let alias = PeerIdentityAliasResolver.hostAlias(fromIPAddress: raw) else { return }
            aliases.insert(alias)
        }

        func appendBonjour(name: String?, domain: String?) {
            guard let name = BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName(name) else { return }
            let trimmedDomain = domain?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedDomain: String
            if let trimmedDomain, !trimmedDomain.isEmpty {
                resolvedDomain = trimmedDomain
            } else {
                resolvedDomain = "local."
            }
            for candidate in PeerIdentityAliasResolver.lookupCandidates(for: "bonjour:\(name)@\(resolvedDomain)") {
                aliases.insert(candidate)
            }
        }

        switch result.endpoint {
        case .hostPort(let host, _):
            appendHost(String(describing: host))
        case .service(let name, _, let domain, _):
            appendBonjour(name: name, domain: domain)
        default:
            break
        }

        let hostFields = [
            "lanHost", "lanIPv4", "lanIPv6",
            "host", "ip", "ipv4", "ipv6", "address", "hostAddress"
        ]
        for key in hostFields {
            appendHost(txtValue(txtRecord, key))
        }

        return aliases
    }

    // MARK: - Merge / Capabilities helpers

    private func merge(existing: DiscoveredDevice, update: DiscoveredDevice) -> DiscoveredDevice {
        var merged = existing

        // name：只接受可展示的人类可读名称/型号，不让 UUID、IP、peer/host 路由覆盖。
        if shouldReplaceDisplayName(existing: merged.name, candidate: update.name) {
            merged.name = update.name
        }

        if merged.bonjourServiceName == nil || merged.bonjourServiceName?.isEmpty == true {
            merged.bonjourServiceName = BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName(update.bonjourServiceName)
        }

        // platform/osVersion/model：尽量补齐（避免 Unknown 覆盖有效值）
        if merged.platform == .unknown && update.platform != .unknown {
            merged.platform = update.platform
        } else if merged.platform == .iOS,
                  update.platform == .iPadOS,
                  isIPadPresentation(update) {
            merged.platform = .iPadOS
        }
        if isUnknownValue(merged.osVersion) && !isUnknownValue(update.osVersion) { merged.osVersion = update.osVersion }
        if isUnknownValue(merged.modelName) && !isUnknownValue(update.modelName) {
            merged.modelName = update.modelName
        } else if discoveryGenericModel(normalizedDiscoveryName(merged.modelName), containsDetailedModel: normalizedDiscoveryName(update.modelName)) {
            merged.modelName = update.modelName
        }

        // 最新 IP / Bonjour type/domain（优先保留可路由 LAN 地址，避免 Bonjour service 解析退回 link-local）。
        if let bestAddress = ConnectableAddressCanonicalizer.bestLANAddress([
            merged.ipAddress,
            update.ipAddress
        ]) {
            merged.ipAddress = bestAddress
        }
        if merged.bonjourServiceType == nil
            || update.bonjourServiceType == DiscoveryServiceType.skybridge.rawValue {
            merged.bonjourServiceType = update.bonjourServiceType
        }
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

    private func shouldReplaceDisplayName(existing: String, candidate: String) -> Bool {
        let existingScore = displayNameQualityScore(existing)
        let candidateScore = displayNameQualityScore(candidate)
        if candidateScore != existingScore {
            return candidateScore > existingScore
        }
        return candidate.count > existing.count
    }

    private func displayNameQualityScore(_ raw: String) -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        if BonjourServiceIdentitySanitizer.isIdentifierLikeDisplayName(trimmed) { return 10 }
        let normalized = normalizedDiscoveryName(trimmed)
        if normalized == "unknowndevice" || normalized == "unknown" || normalized == "未知设备" {
            return 20
        }
        if normalized == "ipad" || normalized == "iphone" {
            return 40
        }
        if normalized.hasPrefix("ipad") || normalized.hasPrefix("iphone") || normalized.contains("mac") {
            return 70
        }
        if normalized.contains("ipad") || normalized.contains("iphone") {
            return 90
        }
        return 100
    }

    private func aliasPriority(for device: DiscoveredDevice) -> Int {
        var score = 0
        if device.id.lowercased().hasPrefix("id:") {
            score += 300
        }
        if device.services.contains(DiscoveryServiceType.skybridge.rawValue) {
            score += 120
        }
        if device.bonjourServiceType == DiscoveryServiceType.skybridge.rawValue {
            score += 80
        }
        if device.bonjourServiceName?.isEmpty == false {
            score += 30
        }
        if device.ipAddress?.isEmpty == false {
            score += 20
        }
        return score
    }

    private func rebuildIdentityAliasIndex() {
        var aliasMap: [String: String] = [:]
        var ownerScores: [String: Int] = [:]

        for device in deviceCache.values.sorted(by: { $0.lastSeen > $1.lastSeen }) {
            let score = aliasPriority(for: device)
            let aliases = Set(PeerIdentityAliasResolver.aliasKeys(for: device))
                .union(discoveryIdentityAliasesByDeviceId[device.id] ?? [])
            for alias in aliases {
                let existingScore = ownerScores[alias] ?? Int.min
                if aliasMap[alias] == nil || score >= existingScore {
                    aliasMap[alias] = device.id
                    ownerScores[alias] = score
                }
            }
        }

        identityAliasToDeviceId = aliasMap
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
        switch serviceType {
        case .skybridge, .skybridgeQUIC:
            return parseUInt16(txtValue(txt, "port"))
                ?? parseUInt16(txtValue(txt, "skybridgePort"))
                ?? parseUInt16(txtValue(txt, "p2pPort"))
                ?? parseUInt16(txtValue(txt, "controlPort"))
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

    private func parseUInt16(_ s: String?) -> UInt16? {
        guard let s, !s.isEmpty else { return nil }
        return UInt16(s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))
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
    private func extractIPAddress(from endpoint: NWEndpoint, txtRecord: [String: String]) -> String? {
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
            return ConnectableAddressCanonicalizer.bestLANAddress([
                txtValue(txtRecord, "lanHost", "host", "ip", "ipv4", "address", "hostAddress"),
                txtValue(txtRecord, "lanIPv4"),
                txtValue(txtRecord, "lanIPv6", "ipv6")
            ]).flatMap {
                ConnectableAddressCanonicalizer.isRoutableLANAddress($0) ? $0 : nil
            }
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
        let endpointDescription = connection.endpoint.debugDescription

        if isLoopbackEndpoint(connection.endpoint) {
            SkyBridgeLogger.shared.warning("⚠️ 已忽略回环地址入站连接: \(endpointDescription)")
            SkyBridgeSmokeTraceWriter.appendStatus(
                "p2p-listener inbound-ignored reason=loopback endpoint=\(Self.smokeSanitize(endpointDescription))"
            )
            connection.cancel()
            return
        }

        SkyBridgeLogger.shared.info("📞 收到新连接: \(endpointDescription)")
        SkyBridgeSmokeTraceWriter.appendStatus(
            "p2p-listener inbound-new endpoint=\(Self.smokeSanitize(endpointDescription))"
        )

        let peerId = extractPeerId(from: connection)
        if let localStableDeviceId,
           peerId.caseInsensitiveCompare(localStableDeviceId) == .orderedSame {
            SkyBridgeLogger.shared.warning("⚠️ 已忽略疑似自连接入站连接: \(peerId)")
            SkyBridgeSmokeTraceWriter.appendStatus(
                "p2p-listener inbound-ignored reason=self peer=\(Self.smokeSanitize(peerId))"
            )
            connection.cancel()
            return
        }

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    SkyBridgeLogger.shared.info("✅ 入站连接就绪: \(peerId)")
                    SkyBridgeSmokeTraceWriter.appendStatus(
                        "p2p-listener inbound-ready peer=\(Self.smokeSanitize(peerId))"
                    )
                    self?.onNewConnection?(connection, peerId)

                case .failed(let error):
                    SkyBridgeLogger.shared.error("❌ 入站连接失败: \(error.localizedDescription)")
                    SkyBridgeSmokeTraceWriter.appendStatus(
                        "p2p-listener inbound-failed peer=\(Self.smokeSanitize(peerId)) error=\(Self.smokeSanitize(error.localizedDescription))"
                    )

                case .cancelled:
                    SkyBridgeLogger.shared.info("⏹️ 入站连接已取消")
                    SkyBridgeSmokeTraceWriter.appendStatus(
                        "p2p-listener inbound-cancelled peer=\(Self.smokeSanitize(peerId))"
                    )

                default:
                    break
                }
            }
        }

        connection.start(queue: queue)
    }

    private nonisolated static func smokeSanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func extractPeerId(from connection: NWConnection) -> String {
        // Prefer mapping back to an already-discovered stable device id if possible.
        // This is critical for UI refresh: the device list is keyed by `DiscoveredDevice.id` (stableDeviceId),
        // while inbound NWConnection endpoints often arrive as hostPort (IP) and would otherwise mismatch.
        let endpointKey = connection.endpoint.debugDescription
        if let mapped = PeerIdentityAliasResolver.resolveDeviceId(
            for: connection.endpoint,
            endpointKey: endpointKey,
            exactEndpointMap: endpointToDeviceId,
            aliasMap: identityAliasToDeviceId
        ) {
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

    func canonicalDiscoveredDevice(for device: DiscoveredDevice) -> DiscoveredDevice? {
        var candidateIds: [String] = []
        var seen = Set<String>()

        func append(_ raw: String?) {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  seen.insert(raw).inserted else {
                return
            }
            candidateIds.append(raw)
        }

        append(device.id)
        for alias in PeerIdentityAliasResolver.lookupCandidates(for: device.id) {
            append(identityAliasToDeviceId[alias])
        }
        for alias in PeerIdentityAliasResolver.aliasKeys(for: device) {
            append(identityAliasToDeviceId[alias])
        }
        if let ipAddress = device.ipAddress,
           let alias = PeerIdentityAliasResolver.hostAlias(fromIPAddress: ipAddress) {
            append(identityAliasToDeviceId[alias])
        }
        if let bonjourServiceName = BonjourServiceIdentitySanitizer.sanitizedServiceInstanceName(device.bonjourServiceName),
           let alias = PeerIdentityAliasResolver.lookupCandidates(
                for: "bonjour:\(bonjourServiceName)@\(device.bonjourServiceDomain ?? "local.")"
           ).first {
            append(identityAliasToDeviceId[alias])
        }

        for candidateId in candidateIds {
            if let cached = deviceCache[candidateId] {
                return cached
            }
            if let discovered = discoveredDevices.first(where: { $0.id == candidateId }) {
                return discovered
            }
        }
        return nil
    }
    
    // MARK: - Private Methods - TXT Record
    
    /// 创建 TXT 记录（用于广播）
    private func createTXTRecord(port: UInt16) async -> NWTXTRecord {
        var record = NWTXTRecord()
        
        // 平台信息
        record["platform"] = localPlatform.rawValue
        record["osVersion"] = localOSVersion
        record["model"] = localModel
        record["modelName"] = localModel
        if let localChip, !localChip.isEmpty {
            record["chip"] = localChip
        }
        
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
        record["kemRefreshVersion"] = "1"
        record["hs_soa"] = "1"
        record["name"] = deviceName
        if port > 0 {
            record["port"] = String(port)
            record["skybridgePort"] = String(port)
        }
        
        // 设备 ID（用于与 macOS 端对齐的稳定主键；不要截断，避免碰撞）
        #if canImport(UIKit)
        let mobileSnapshot = AppleMobileDeviceIdentity.currentSnapshot()
        let protocolDeviceId = ProtocolDeviceIdentity.stableDeviceId()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mobileStableId = mobileSnapshot.stableDeviceId
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let advertisedDeviceId = protocolDeviceId.isEmpty ? mobileStableId : protocolDeviceId

        if !advertisedDeviceId.isEmpty {
            record["deviceId"] = advertisedDeviceId
            record["uuid"] = advertisedDeviceId
            record["uniqueId"] = advertisedDeviceId
        }
        if let protocolFingerprint = await localProtocolIdentityFingerprintForAdvertisement() {
            record["pubKeyFP"] = protocolFingerprint
            record["identityFingerprint"] = protocolFingerprint
        }
        if !mobileStableId.isEmpty, mobileStableId != advertisedDeviceId {
            record["legacyDeviceId"] = mobileStableId
            record["appleMobileStableId"] = mobileStableId
        }
        if let vendorDeviceId = mobileSnapshot.vendorDeviceId, !vendorDeviceId.isEmpty {
            record["vendorDeviceId"] = vendorDeviceId
        }
        #endif

        let networkFields = await currentNetworkLinkAdvertisementFields()
        for (key, value) in networkFields {
            record[key] = value
        }
        
        return record
    }

    private enum LocalNetworkInterfaceKind: Hashable {
        case wifi
        case cellular
        case ethernet
    }

    private func currentNetworkLinkAdvertisementFields() async -> [String: String] {
        let interfaceKinds = Self.activeNetworkInterfaceKinds()

        if interfaceKinds.contains(.wifi) {
            var fields: [String: String] = [
                "linkKind": "wifi",
                "networkType": "wifi"
            ]
            if let signalStrength = await Self.currentWiFiSignalStrength() {
                fields["signalStrength"] = Self.formatSignalFraction(signalStrength)
                fields["signalUnit"] = "fraction"
            }
            return fields
        }

        if interfaceKinds.contains(.cellular) {
            var fields: [String: String] = [
                "linkKind": "cellular",
                "networkType": "cellular"
            ]
            if let radioAccessTechnology = Self.currentCellularRadioAccessTechnology() {
                fields["radioAccessTechnology"] = radioAccessTechnology
                fields["cellularTechnology"] = radioAccessTechnology
            }
            return fields
        }

        if interfaceKinds.contains(.ethernet) {
            return [
                "linkKind": "ethernet",
                "networkType": "ethernet"
            ]
        }

        return [:]
    }

    nonisolated private static func activeNetworkInterfaceKinds() -> Set<LocalNetworkInterfaceKind> {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return []
        }
        defer { freeifaddrs(interfaces) }

        var kinds = Set<LocalNetworkInterfaceKind>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstInterface

        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }

            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let address = current.pointee.ifa_addr else {
                continue
            }

            let family = address.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6),
                  let namePointer = current.pointee.ifa_name else {
                continue
            }

            let name = String(cString: namePointer).lowercased()
            if name == "en0" {
                kinds.insert(.wifi)
            } else if name.hasPrefix("pdp_ip") {
                kinds.insert(.cellular)
            } else if name.hasPrefix("en") || name.hasPrefix("bridge") {
                kinds.insert(.ethernet)
            }
        }

        return kinds
    }

    nonisolated private static func currentWiFiSignalStrength() async -> Double? {
        #if canImport(NetworkExtension)
        guard #available(iOS 14.0, *) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.signalStrength)
            }
        }
        #else
        return nil
        #endif
    }

    nonisolated private static func currentCellularRadioAccessTechnology() -> String? {
        #if canImport(CoreTelephony)
        let networkInfo = CTTelephonyNetworkInfo()
        var technologies: [String] = []
        if let serviceTechnologies = networkInfo.serviceCurrentRadioAccessTechnology {
            technologies.append(contentsOf: serviceTechnologies.values)
        }

        let ranked = technologies
            .compactMap(Self.cellularRadioAccessTechnologyLabel)
            .max { Self.radioAccessTechnologyRank($0) < Self.radioAccessTechnologyRank($1) }

        return ranked
        #else
        return nil
        #endif
    }

    nonisolated private static func cellularRadioAccessTechnologyLabel(_ technology: String) -> String? {
        #if canImport(CoreTelephony)
        if technology == CTRadioAccessTechnologyLTE {
            return "LTE"
        }
        if #available(iOS 14.1, *) {
            if technology == CTRadioAccessTechnologyNR || technology == CTRadioAccessTechnologyNRNSA {
                return "5G"
            }
        }
        switch technology {
        case CTRadioAccessTechnologyWCDMA,
            CTRadioAccessTechnologyHSDPA,
            CTRadioAccessTechnologyHSUPA,
            CTRadioAccessTechnologyCDMAEVDORev0,
            CTRadioAccessTechnologyCDMAEVDORevA,
            CTRadioAccessTechnologyCDMAEVDORevB,
            CTRadioAccessTechnologyeHRPD:
            return "3G"
        case CTRadioAccessTechnologyGPRS,
            CTRadioAccessTechnologyEdge,
            CTRadioAccessTechnologyCDMA1x:
            return "2G"
        default:
            return nil
        }
        #else
        return nil
        #endif
    }

    nonisolated private static func radioAccessTechnologyRank(_ label: String) -> Int {
        switch label.uppercased() {
        case "5GUW", "5G UW":
            return 6
        case "5G":
            return 5
        case "LTE":
            return 4
        case "4G":
            return 3
        case "3G":
            return 2
        case "2G":
            return 1
        default:
            return 0
        }
    }

    nonisolated private static func formatSignalFraction(_ value: Double) -> String {
        String(format: "%.3f", min(1.0, max(0.0, value)))
    }

    private func localProtocolIdentityFingerprintForAdvertisement() async -> String? {
        do {
            try await SkyBridgeiOSCore.shared.initialize(policy: .requirePQC)
            for algorithm in [ProtocolSigningAlgorithm.mlDSA65, .ed25519] {
                let publicKey = try await SkyBridgeiOSCore.shared.getProtocolSigningPublicKey(for: algorithm)
                let keyInfo = AppMessage.ProtocolIdentityPublicKeyInfo(
                    protocolSigningAlgorithm: algorithm.rawValue,
                    publicKey: publicKey
                )
                if let fingerprint = keyInfo.authoritativeFingerprint?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased(),
                   fingerprint.count == 64,
                   fingerprint.allSatisfy(\.isHexDigit) {
                    return fingerprint
                }
            }
        } catch {
            SkyBridgeLogger.shared.debug(
                "ℹ️ Bonjour protocol identity fingerprint unavailable: \(error.localizedDescription)"
            )
        }

        return nil
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
        cleanupTimer?.tolerance = 6 // 允许系统合并唤醒（省电）
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
        let protectedIdentifiers = P2PConnectionManager.instance.protectedDiscoveryIdentifiers
        let activeIdentifiers = P2PConnectionManager.instance.activeDiscoveryIdentifiers
        
        for (deviceId, lastActivity) in deviceLastActivity {
            let deviceAliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: deviceId))
            let isProtected = protectedIdentifiers.contains(deviceId) || !deviceAliases.isDisjoint(with: protectedIdentifiers)
            let isActivelyConnected = activeIdentifiers.contains(deviceId) || !deviceAliases.isDisjoint(with: activeIdentifiers)
            let hasLiveEndpoint = hasLiveBrowseEndpoint(for: deviceId)
            if isProtected || hasLiveEndpoint {
                deviceLastActivity[deviceId] = now
                if var device = deviceCache[deviceId] {
                    device.lastSeen = now
                    device.isConnected = isActivelyConnected
                    deviceCache[deviceId] = device
                }
                continue
            }
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

    private func hasLiveBrowseEndpoint(for deviceId: String) -> Bool {
        let targetAliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: deviceId))
        guard !targetAliases.isEmpty else { return false }

        for endpointKeys in liveBrowseEndpointKeysByServiceType.values {
            for endpointKey in endpointKeys {
                guard let mappedDeviceId = endpointToDeviceId[endpointKey] else { continue }
                let mappedAliases = Set(PeerIdentityAliasResolver.lookupCandidates(for: mappedDeviceId))
                if !targetAliases.isDisjoint(with: mappedAliases) {
                    return true
                }
            }
        }

        return false
    }
    
    /// 更新发现的设备列表
    private func updateDiscoveredDevices() {
        coalesceEquivalentCachedDevices()
        rebuildIdentityAliasIndex()

        // 按最后活动时间排序
        discoveredDevices = Array(deviceCache.values).sorted { $0.lastSeen > $1.lastSeen }
        
        // 按平台分组
        var grouped: [DevicePlatform: [DiscoveredDevice]] = [:]
        for device in discoveredDevices {
            grouped[device.platform, default: []].append(device)
        }
        devicesByPlatform = grouped
    }

    /// 去抖触发 updateDiscoveredDevices()：合并高频浏览事件突发，避免每个事件都同步跑 O(n²) 去重。
    /// 缓存的增删改是廉价同步操作（已在调用处完成）；昂贵的合并/重建/发布推迟到突发结束后一次完成。
    private func scheduleDiscoveredDevicesUpdate() {
        pendingDiscoveredDevicesUpdateTask?.cancel()
        pendingDiscoveredDevicesUpdateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.pendingDiscoveredDevicesUpdateTask = nil
            self?.updateDiscoveredDevices()
        }
    }

    private func coalesceEquivalentCachedDevices() {
        let devices = Array(deviceCache.values)
        guard devices.count > 1 else { return }

        var parent = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.id) })

        func find(_ id: String) -> String {
            var current = id
            while let next = parent[current], next != current {
                current = next
            }
            return current
        }

        func union(_ lhs: String, _ rhs: String) {
            let lhsRoot = find(lhs)
            let rhsRoot = find(rhs)
            guard lhsRoot != rhsRoot else { return }
            parent[rhsRoot] = lhsRoot
        }

        for lhsIndex in devices.indices {
            for rhsIndex in devices.index(after: lhsIndex)..<devices.endIndex {
                if shouldCoalesceDiscoveryDevices(devices[lhsIndex], devices[rhsIndex]) {
                    union(devices[lhsIndex].id, devices[rhsIndex].id)
                }
            }
        }

        var groups: [String: [DiscoveredDevice]] = [:]
        for device in devices {
            groups[find(device.id), default: []].append(device)
        }

        guard groups.values.contains(where: { $0.count > 1 }) else { return }

        var replacementByOriginalId: [String: String] = [:]
        var nextCache: [String: DiscoveredDevice] = [:]
        var nextLastActivity: [String: Date] = [:]

        for group in groups.values {
            let merged = mergeEquivalentDiscoveryGroup(group)
            nextCache[merged.id] = merged
            nextLastActivity[merged.id] = group
                .compactMap { deviceLastActivity[$0.id] }
                .max()
                ?? group.map(\.lastSeen).max()
                ?? Date()
            for device in group {
                replacementByOriginalId[device.id] = merged.id
            }
        }

        deviceCache = nextCache
        deviceLastActivity = nextLastActivity
        endpointToDeviceId = endpointToDeviceId.reduce(into: [:]) { result, element in
            result[element.key] = replacementByOriginalId[element.value] ?? element.value
        }
        discoveryIdentityAliasesByDeviceId = discoveryIdentityAliasesByDeviceId.reduce(into: [:]) { result, element in
            let replacementId = replacementByOriginalId[element.key] ?? element.key
            result[replacementId, default: []].formUnion(element.value)
        }
    }

    private func shouldCoalesceDiscoveryDevices(_ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice) -> Bool {
        guard lhs.id != rhs.id else { return true }

        let lhsPersistent = PeerIdentityAliasResolver.persistentDeviceId(from: lhs.id)
        let rhsPersistent = PeerIdentityAliasResolver.persistentDeviceId(from: rhs.id)
        if let lhsPersistent, let rhsPersistent, lhsPersistent != rhsPersistent {
            return false
        }

        let lhsAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: lhs))
            .union(PeerIdentityAliasResolver.lookupCandidates(for: lhs.id))
        let rhsAliases = Set(PeerIdentityAliasResolver.aliasKeys(for: rhs))
            .union(PeerIdentityAliasResolver.lookupCandidates(for: rhs.id))
        if !lhsAliases.isEmpty, !lhsAliases.isDisjoint(with: rhsAliases) {
            return true
        }

        guard discoveryModelsCompatible(lhs.modelName, rhs.modelName) else { return false }
        guard discoveryPlatformsCompatible(lhs.platform, rhs.platform) else { return false }
        guard discoveryCandidateAddressesCompatible(lhs, rhs) else { return false }
        guard hasAuthoritativeDiscoveryAnchor(lhs, rhs) else { return false }
        guard hasEndpointDiscoveryRoute(lhs, rhs) else { return false }

        if discoveryNamesRepresentSameDevice(lhs.name, rhs.name) {
            return true
        }

        return discoveryMacNamesRepresentSameDevice(lhs.name, rhs.name)
            && isAppleMacPresentation(lhs)
            && isAppleMacPresentation(rhs)
            && hasSkyBridgeDiscoveryRouteEvidence(lhs)
            && hasSkyBridgeDiscoveryRouteEvidence(rhs)
    }

    private func mergeEquivalentDiscoveryGroup(_ group: [DiscoveredDevice]) -> DiscoveredDevice {
        guard var merged = group.sorted(by: shouldPreferDiscoveryDevice).first else {
            fatalError("mergeEquivalentDiscoveryGroup requires at least one device")
        }

        for device in group where device.id != merged.id {
            merged = merge(existing: merged, update: device)
        }

        if let preferredId = group.map(\.id).max(by: { identifierPriority($0) < identifierPriority($1) }),
           preferredId != merged.id {
            merged = copyDiscoveryDevice(merged, id: preferredId)
        }

        merged.lastSeen = group.map(\.lastSeen).max() ?? merged.lastSeen
        merged.isConnected = group.contains(where: \.isConnected)
        merged.isTrusted = group.contains(where: \.isTrusted)
        return merged
    }

    private func copyDiscoveryDevice(_ device: DiscoveredDevice, id: String) -> DiscoveredDevice {
        DiscoveredDevice(
            id: id,
            name: device.name,
            bonjourServiceName: device.bonjourServiceName,
            modelName: device.modelName,
            platform: device.platform,
            osVersion: device.osVersion,
            ipAddress: device.ipAddress,
            bonjourServiceType: device.bonjourServiceType,
            bonjourServiceDomain: device.bonjourServiceDomain,
            services: device.services,
            portMap: device.portMap,
            signalStrength: device.signalStrength,
            lastSeen: device.lastSeen,
            isConnected: device.isConnected,
            isTrusted: device.isTrusted,
            publicKey: device.publicKey,
            advertisedCapabilities: device.advertisedCapabilities,
            capabilities: device.capabilities
        )
    }

    private func shouldPreferDiscoveryDevice(_ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice) -> Bool {
        let lhsPriority = identifierPriority(lhs.id)
        let rhsPriority = identifierPriority(rhs.id)
        if lhsPriority != rhsPriority {
            return lhsPriority > rhsPriority
        }
        if hasBonjourRoute(lhs) != hasBonjourRoute(rhs) {
            return hasBonjourRoute(lhs)
        }
        if lhs.ipAddress != nil, rhs.ipAddress == nil { return true }
        if lhs.ipAddress == nil, rhs.ipAddress != nil { return false }
        return lhs.lastSeen > rhs.lastSeen
    }

    private func identifierPriority(_ id: String) -> Int {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("id:") { return 500 }
        if normalized.hasPrefix("bonjour:") { return 320 }
        if normalized.hasPrefix("host:") { return 220 }
        if normalized.hasPrefix("endpoint:") { return 120 }
        return 80
    }

    private func isStrongDiscoveryIdentifier(_ id: String) -> Bool {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("id:")
    }

    private func hasBonjourRoute(_ device: DiscoveredDevice) -> Bool {
        device.bonjourServiceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || device.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("bonjour:")
    }

    private func hasAuthoritativeDiscoveryAnchor(_ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice) -> Bool {
        authoritativeDiscoveryAnchor(lhs) || authoritativeDiscoveryAnchor(rhs)
    }

    private func authoritativeDiscoveryAnchor(_ device: DiscoveredDevice) -> Bool {
        isStrongDiscoveryIdentifier(device.id) && (device.isTrusted || device.isConnected)
    }

    private func hasEndpointDiscoveryRoute(_ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice) -> Bool {
        hasEndpointDiscoveryRoute(lhs) || hasEndpointDiscoveryRoute(rhs)
    }

    private func hasEndpointDiscoveryRoute(_ device: DiscoveredDevice) -> Bool {
        !isStrongDiscoveryIdentifier(device.id) && hasSkyBridgeDiscoveryRouteEvidence(device)
    }

    private func discoveryCandidateAddressesCompatible(_ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice) -> Bool {
        guard let lhsIP = normalizedDiscoveryAddress(lhs.ipAddress),
              let rhsIP = normalizedDiscoveryAddress(rhs.ipAddress) else {
            return true
        }
        return lhsIP == rhsIP
    }

    private func normalizedDiscoveryAddress(_ raw: String?) -> String? {
        guard var token = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !token.isEmpty else {
            return nil
        }
        if let percent = token.firstIndex(of: "%") {
            token = String(token[..<percent])
        }
        return token
    }

    private func isIPadPresentation(_ device: DiscoveredDevice) -> Bool {
        [
            device.name,
            device.modelName,
            device.platform.rawValue
        ]
        .joined(separator: " ")
        .lowercased()
        .contains("ipad")
    }

    private func discoveryNamesRepresentSameDevice(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = normalizedDiscoveryName(lhs)
        let rhs = normalizedDiscoveryName(rhs)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        let minLength = min(lhs.count, rhs.count)
        guard minLength >= 8 else { return false }
        return lhs.contains(rhs) || rhs.contains(lhs)
    }

    private func discoveryMacNamesRepresentSameDevice(_ lhs: String, _ rhs: String) -> Bool {
        let lhsName = normalizedDiscoveryName(lhs)
        let rhsName = normalizedDiscoveryName(rhs)
        let lhsIsModelIdentifier = isAppleMacHardwareModelIdentifier(lhsName)
        let rhsIsModelIdentifier = isAppleMacHardwareModelIdentifier(rhsName)
        guard lhsIsModelIdentifier != rhsIsModelIdentifier else {
            return false
        }

        let presentationName = lhsIsModelIdentifier ? rhsName : lhsName
        return discoveryAppleDeviceFamilyToken(presentationName) == "mac"
    }

    private func isAppleMacHardwareModelIdentifier(_ normalizedName: String) -> Bool {
        guard normalizedName.contains(where: { $0.isNumber }) else { return false }
        return normalizedName.hasPrefix("macbookpro")
            || normalizedName.hasPrefix("macbookair")
            || normalizedName.hasPrefix("macmini")
            || normalizedName.hasPrefix("macstudio")
            || normalizedName.hasPrefix("macpro")
            || normalizedName.hasPrefix("imac")
    }

    private func isAppleMacPresentation(_ device: DiscoveredDevice) -> Bool {
        if device.platform == .macOS { return true }
        return discoveryAppleDeviceFamilyToken(
            [
                device.modelName,
                device.name,
                device.platform.rawValue
            ].joined(separator: " ")
        ) == "mac"
    }

    private func discoveryAppleDeviceFamilyToken(_ raw: String) -> String? {
        let normalized = normalizedDiscoveryName(raw)
        guard !normalized.isEmpty else { return nil }
        if normalized.contains("ipad") { return "ipad" }
        if normalized.contains("iphone") || normalized.contains("ios") { return "iphone" }
        if normalized.contains("macbook")
            || normalized.contains("macmini")
            || normalized.contains("macstudio")
            || normalized.contains("macpro")
            || normalized.contains("imac")
            || normalized == "mac"
            || normalized == "macos" {
            return "mac"
        }
        return nil
    }

    private func hasSkyBridgeDiscoveryRouteEvidence(_ device: DiscoveredDevice) -> Bool {
        if hasBonjourRoute(device) || device.ipAddress != nil {
            return true
        }

        let routeHints = device.services
            + Array(device.portMap.keys)
            + [device.bonjourServiceType, device.id].compactMap { $0 }
        return routeHints.contains { hint in
            hint.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .contains("skybridge")
        }
    }

    private func discoveryModelsCompatible(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = normalizedDiscoveryName(lhs)
        let rhs = normalizedDiscoveryName(rhs)
        guard !lhs.isEmpty, !rhs.isEmpty else { return true }
        if lhs == rhs { return true }
        return discoveryGenericModel(lhs, containsDetailedModel: rhs)
            || discoveryGenericModel(rhs, containsDetailedModel: lhs)
    }

    private func discoveryGenericModel(_ generic: String, containsDetailedModel detailed: String) -> Bool {
        switch generic {
        case "ipad":
            return detailed.hasPrefix("ipad")
        case "iphone":
            return detailed.hasPrefix("iphone")
        case "mac":
            return detailed.hasPrefix("mac")
        default:
            return false
        }
    }

    private func discoveryPlatformsCompatible(_ lhs: DevicePlatform, _ rhs: DevicePlatform) -> Bool {
        if lhs == .unknown || rhs == .unknown || lhs == rhs {
            return true
        }
        let mobile: Set<DevicePlatform> = [.iOS, .iPadOS]
        return mobile.contains(lhs) && mobile.contains(rhs)
    }

    private func normalizedDiscoveryName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
    
    // MARK: - Public Helpers
    
    /// 获取特定平台的设备
    public func devices(for platform: DevicePlatform) -> [DiscoveredDevice] {
        devicesByPlatform[platform] ?? []
    }

#if DEBUG
    func injectDiscoveredDevicesForTesting(_ devices: [DiscoveredDevice]) {
        discoveredDevices = devices
        devicesByPlatform = Dictionary(grouping: devices, by: \.platform)
    }
#endif
    
    /// 获取 SkyBridge 兼容设备（支持 PQC 握手）
    public func skybridgeCompatibleDevices() -> [DiscoveredDevice] {
        // 目前所有发现的设备都可能兼容
        // 后续可以根据 TXT 记录中的 pqc 字段过滤
        discoveredDevices
    }

    struct DebugState {
        let deviceCache: [String: DiscoveredDevice]
        let endpointToDeviceId: [String: String]
        let liveBrowseEndpointKeysByServiceType: [DiscoveryServiceType: Set<String>]
        let deviceLastActivity: [String: Date]
        let isDiscovering: Bool
        let authorizationBlockedServiceTypes: Set<DiscoveryServiceType>
        let authorizationRecoveryAttempts: [DiscoveryServiceType: Int]
    }

    static func debugMakeIsolatedInstance() -> DeviceDiscoveryManager {
        DeviceDiscoveryManager()
    }

    func debugCaptureState() -> DebugState {
        DebugState(
            deviceCache: deviceCache,
            endpointToDeviceId: endpointToDeviceId,
            liveBrowseEndpointKeysByServiceType: liveBrowseEndpointKeysByServiceType,
            deviceLastActivity: deviceLastActivity,
            isDiscovering: isDiscovering,
            authorizationBlockedServiceTypes: authorizationBlockedServiceTypes,
            authorizationRecoveryAttempts: authorizationRecoveryAttempts
        )
    }

    func debugRestoreState(_ state: DebugState) {
        deviceCache = state.deviceCache
        endpointToDeviceId = state.endpointToDeviceId
        liveBrowseEndpointKeysByServiceType = state.liveBrowseEndpointKeysByServiceType
        deviceLastActivity = state.deviceLastActivity
        isDiscovering = state.isDiscovering
        authorizationBlockedServiceTypes = state.authorizationBlockedServiceTypes
        authorizationRecoveryAttempts = state.authorizationRecoveryAttempts
        updateDiscoveredDevices()
    }

    func debugSeedDiscoveryState(
        devices: [DiscoveredDevice],
        lastActivity: Date,
        endpointToDeviceId: [String: String],
        liveBrowseEndpointKeysByServiceType: [DiscoveryServiceType: Set<String>],
        isDiscovering: Bool = false
    ) {
        deviceCache = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        deviceLastActivity = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, lastActivity) })
        self.endpointToDeviceId = endpointToDeviceId
        self.liveBrowseEndpointKeysByServiceType = liveBrowseEndpointKeysByServiceType
        self.isDiscovering = isDiscovering
        updateDiscoveredDevices()
    }

    func debugRunCleanupStaleDevices() {
        cleanupStaleDevices()
    }

    var debugCachedDeviceIds: Set<String> {
        Set(deviceCache.keys)
    }

    func debugSeedAuthorizationRecoveryState(
        blockedServiceTypes: Set<DiscoveryServiceType>,
        attempts: [DiscoveryServiceType: Int],
        isDiscovering: Bool
    ) {
        authorizationBlockedServiceTypes = blockedServiceTypes
        authorizationRecoveryAttempts = attempts
        self.isDiscovering = isDiscovering
    }

    var debugAuthorizationBlockedServiceTypes: Set<DiscoveryServiceType> {
        authorizationBlockedServiceTypes
    }

    var debugAuthorizationRecoveryAttempts: [DiscoveryServiceType: Int] {
        authorizationRecoveryAttempts
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

    public func setConnectionLiveness(for device: DiscoveredDevice, isConnected: Bool) {
        var candidateIds: Set<String> = []

        func append(_ raw: String?) {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                return
            }
            candidateIds.insert(raw)
        }

        append(device.id)
        for alias in PeerIdentityAliasResolver.lookupCandidates(for: device.id) {
            append(identityAliasToDeviceId[alias])
        }
        for alias in PeerIdentityAliasResolver.aliasKeys(for: device) {
            append(identityAliasToDeviceId[alias])
        }
        if let canonical = canonicalDiscoveredDevice(for: device) {
            append(canonical.id)
        }

        let timestamp = Date()
        var updated = false
        for candidateId in candidateIds {
            guard var cached = deviceCache[candidateId] else { continue }
            cached.isConnected = isConnected
            cached.lastSeen = timestamp
            deviceCache[candidateId] = cached
            deviceLastActivity[candidateId] = timestamp
            updated = true
        }

        if updated {
            updateDiscoveredDevices()
        }
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
            "deviceId", "deviceID", "device_id", "uuid", "id", "uniqueId", "unique_id",
            "pubKeyFP", "pubKeyFp", "pub_key_fp", "identityFingerprint",
            // system
            "platform", "osVersion", "os_version", "platformVersion", "platform_version", "os", "systemVersion",
            "model", "hardwareModel", "hwModel", "name",
            // features
            "capabilities", "pqc", "version", "kemRefreshVersion", "kemKeyDigest", "hs_soa", "HS_SOA",
            // signal
            "rssi", "signalStrength", "signal_strength", "signal",
            // ports (for UI)
            "skybridgePort", "p2pPort", "controlPort", "controlPortSource",
            "transferPort", "fileTransferPort", "file_transfer_port",
            "remotePort", "remoteControlPort", "remote_port",
            "port",
            // routable LAN route hints advertised by macOS listeners
            "lanHost", "lanIPv4", "lanIPv6", "host", "ip", "ipv4", "ipv6", "address", "hostAddress"
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
