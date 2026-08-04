// DEDUPLICATION TARGET — not inherently macOS-only.
//
// macOS 侧发现编排（依赖 USB/IOKit 与 DeviceDiscoveryManagerOptimized）。iOS 有自己的一份
// （iOS 侧在线设备管理）。采用/合并是阶段 3 的迁移工作，见 Docs/background-wake-capability-ledger.md。
#if os(macOS)
import Foundation
import Combine
import OSLog
import Network

/// 统一的在线设备管理器
///
/// 核心功能:
/// 1. 整合所有设备来源(网络发现、USB、iCloud、历史连接)
/// 2. 智能设备去重和信息合并
/// 3. 设备在线状态管理
/// 4. 设备持久化存储
/// 5. 全局单例,确保所有视图同步
@available(macOS 14.0, *)
@MainActor
public final class UnifiedOnlineDeviceManager: ObservableObject {
    private nonisolated static let controlRouteFreshnessWindow: TimeInterval = 60

 // MARK: - 单例

    public static let shared = UnifiedOnlineDeviceManager()

 // MARK: - 发布属性

 /// 在线设备列表(本机 + 当前在线 + 最近连接)
    @Published public private(set) var onlineDevices: [OnlineDevice] = []

 /// 本机设备
    @Published public private(set) var localDevice: OnlineDevice?

 /// 扫描状态
    @Published public private(set) var isScanning = false

    /// 设备分类统计
    @Published public private(set) var deviceStats: DeviceStats = DeviceStats()

    /// 网络发现层的元数据摘要。
    /// 用于驱动依赖 trusted/discovery 交叉匹配的视图在 metadata 变化时刷新。
    @Published public private(set) var discoveryMetadataSummary: String = ""

 // MARK: - 私有属性

    private let logger = Logger(subsystem: "com.skybridge.unified", category: "OnlineDeviceManager")

 /// 设备去重映射表: 唯一标识符 -> OnlineDevice
    private var deviceMap: [String: OnlineDevice] = [:]

    /// 网络发现层已经用本机稳定身份判定过的结果。强身份结论优先于展示层名称/MAC启发式。
    private var authoritativeNetworkLocalClassifications: [String: Bool] = [:]

 /// 设备持久化存储
    private let storage = DeviceStorage()

 /// 订阅集合
    private var cancellables = Set<AnyCancellable>()

 /// 子管理器
    private let networkDiscovery = DeviceDiscoveryManagerOptimized()
    private let usbDiscovery = USBDeviceDiscoveryManager()
    private var iCloudDiscovery: iCloudDeviceDiscoveryManager?
    private var iCloudDiscoveryCancellable: AnyCancellable?
 /// 本机所有接口的 IPv4/IPv6 地址集合（缓存）
    private var localIPAddresses: Set<String> = []
 /// 本机物理网卡 MAC 地址集合（缓存）
    private var localMacAddresses: Set<String> = []
 /// 当前物理连接的 USB 设备指纹（用于“USB 在线态”判断）
    private var activeUSBPresenceTokens: Set<String> = []
    private var pathMonitor: NWPathMonitor?

 /// 设备清理定时器(移除长时间离线的设备)
    private var cleanupTimer: Timer?
    private var discoveryPresenceRefreshTimer: Timer?

 // MARK: - 初始化

    private init() {
        logger.info("🚀 初始化统一在线设备管理器")
        setupObservers()
        loadPersistedDevices()
        identifyLocalDevice()
        refreshLocalIPs()
        refreshLocalMACs()
        startPathMonitor()
        startCleanupTimer()
    }

 // MARK: - 公开方法

 /// 启动设备发现
    public func startDiscovery() {
        guard !isScanning else { return }

        logger.info("🔍 启动统一设备发现")
 // 启动前同步一次全局设置，确保底层发现模块使用最新开关状态
        applyDiscoverySettingsFromGlobalConfig(restartIfNeeded: false)
        isScanning = true

 // 启动网络发现
        networkDiscovery.startScanning()

 // 启动USB发现
        usbDiscovery.startMonitoring()

 // 启动iCloud发现
        if iCloudDiscovery == nil {
            iCloudDiscovery = iCloudDeviceDiscoveryManager.shared
        }
        ensureICloudDiscoveryObserver()
        Task {
            await iCloudDiscovery?.startDiscovery()
        }
        startDiscoveryPresenceRefreshTimer()
    }

 /// 异步版本的启动接口，供需要 `await` 的调用场景（例如前台分层恢复）
    public func startDiscoveryAsync() async {
        await MainActor.run {
            self.startDiscovery()
        }
    }

 /// 停止设备发现
    public func stopDiscovery() {
        logger.info("⏹️ 停止统一设备发现")

        networkDiscovery.stopScanning()
        usbDiscovery.stopMonitoring()
        iCloudDiscovery?.stopDiscovery()
        stopDiscoveryPresenceRefreshTimer()

        isScanning = false
    }

 /// 刷新设备列表
    public func refreshDevices() {
        // UX fix:
        // A hard stop/start here interrupts ongoing handshakes/transfers and causes repeated reconnect loops.
        // We only do a **soft refresh**: apply settings, ensure discovery is running, and trigger lightweight
        // refresh operations that do not tear down listeners/browsers.
        logger.info("🔄 刷新设备列表（软刷新：不停止/不重启发现服务）")
        applyDiscoverySettingsFromGlobalConfig(restartIfNeeded: false)

        if !isScanning {
            startDiscovery()
            return
        }

        // Lightweight nudges (no stop):
        usbDiscovery.scanUSBDevices()
        if iCloudDiscovery == nil {
            iCloudDiscovery = iCloudDeviceDiscoveryManager.shared
        }
        ensureICloudDiscoveryObserver()
        refreshActiveDiscoveryPresence()
        Task { await iCloudDiscovery?.refreshDevices() }
    }

 /// 根据ID查找设备
    public func device(withId id: UUID) -> OnlineDevice? {
        return onlineDevices.first { $0.id == id }
    }

    /// 根据唯一标识符查找设备
    public func device(withIdentifier identifier: String) -> OnlineDevice? {
        return deviceMap[identifier]
    }

    #if DEBUG || SKYBRIDGE_TESTING
    func replaceDevicesForTesting(_ devices: [OnlineDevice]) {
        onlineDevices = devices
        deviceMap = Dictionary(uniqueKeysWithValues: devices.map { ($0.uniqueIdentifier, $0) })
        authoritativeNetworkLocalClassifications.removeAll()
        updateDeviceStats()
    }

    func replaceNetworkDiscoveredDevicesForTesting(_ devices: [DiscoveredDevice]) {
        networkDiscovery.discoveredDevices = devices
        updateDiscoveryMetadataSummary(from: devices)
    }

    func applyNetworkDeviceUpdateForTesting(_ devices: [DiscoveredDevice]) {
        handleNetworkDevicesUpdate(devices)
    }

    func reloadPersistedDevicesForTesting() {
        onlineDevices.removeAll()
        deviceMap.removeAll()
        loadPersistedDevices()
    }

    func recomputeDeviceStatusesForTesting() {
        updateDevicesList()
    }

    func recomputeLocalFlagsForTesting() {
        recomputeLocalFlagsForAllDevices()
    }
    #endif

    /// Resolve the best live `OnlineDevice` representation for a trusted record.
    /// This keeps trusted-device UI aligned with the same identity and alias policy
    /// used by discovery and connection code instead of relying on brittle name-only matching.
    public func resolvedOnlineDevice(for trustRecord: TrustRecord) -> OnlineDevice? {
        let scoredMatches = onlineDevices
            .filter { !$0.isLocalDevice }
            .compactMap { device -> (score: Int, device: OnlineDevice)? in
                let score = scoreTrustedRecordCandidate(device, trustRecord: trustRecord)
                guard score > 0 else { return nil }
                return (score, device)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.device.connectionStatus.priority != rhs.device.connectionStatus.priority {
                    return lhs.device.connectionStatus.priority > rhs.device.connectionStatus.priority
                }
                if lhs.device.lastSeen != rhs.device.lastSeen {
                    return lhs.device.lastSeen > rhs.device.lastSeen
                }
                return lhs.device.name < rhs.device.name
            }

        if let resolved = scoredMatches.first {
            let targetName = trustRecord.deviceName ?? "-"
            logger.debug(
                "online-state sourceMerge source=trust-record target=\(targetName, privacy: .public) resolved=\(resolved.device.name, privacy: .public) status=\(resolved.device.connectionStatus.rawValue, privacy: .public) score=\(resolved.score, privacy: .public)"
            )
            return resolved.device
        }

        let targetName = trustRecord.deviceName ?? "-"
        logger.debug(
            "online-state sourceMerge source=trust-record target=\(targetName, privacy: .public) resolved=none status=offline score=0"
        )
        return nil
    }

    /// Resolve the best matching trust record for a given online device.
    /// This is the inverse of `resolvedOnlineDevice(for:)` and is useful when UI sections
    /// need to collapse multiple alias-shaped device rows back onto one trusted identity.
    public func resolvedTrustRecord(
        for onlineDevice: OnlineDevice,
        among trustRecords: [TrustRecord]
    ) -> TrustRecord? {
        let scoredMatches = trustRecords
            .compactMap { record -> (score: Int, record: TrustRecord)? in
                let score = scoreTrustedRecordCandidate(onlineDevice, trustRecord: record)
                guard score > 0 else { return nil }
                return (score, record)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.record.updatedAt > rhs.record.updatedAt
            }

        return scoredMatches.first?.record
    }

    /// Resolve the best live/local-discovery row for an iCloud device-chain entry.
    /// iCloud heartbeat state can lag behind Bonjour/P2P discovery, so UI code should
    /// prefer this result when deciding whether a peer is currently reachable.
    public func resolvedOnlineDevice(for cloudDevice: iCloudDevice) -> OnlineDevice? {
        let scoredMatches = onlineDevices
            .filter { !$0.isLocalDevice }
            .compactMap { device -> (score: Int, device: OnlineDevice)? in
                let score = scoreCloudDeviceCandidate(device, cloudDevice: cloudDevice)
                guard score > 0 else { return nil }
                return (score, device)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.device.connectionStatus.priority != rhs.device.connectionStatus.priority {
                    return lhs.device.connectionStatus.priority > rhs.device.connectionStatus.priority
                }
                if lhs.device.lastSeen != rhs.device.lastSeen {
                    return lhs.device.lastSeen > rhs.device.lastSeen
                }
                return lhs.device.name < rhs.device.name
            }

        if let resolved = scoredMatches.first {
            logger.debug(
                "online-state sourceMerge source=cloud-device target=\(cloudDevice.name, privacy: .public) resolved=\(resolved.device.name, privacy: .public) status=\(resolved.device.connectionStatus.rawValue, privacy: .public) score=\(resolved.score, privacy: .public)"
            )
            return resolved.device
        }

        logger.debug(
            "online-state sourceMerge source=cloud-device target=\(cloudDevice.name, privacy: .public) resolved=none status=\(cloudDevice.isOnline ? "online" : "offline", privacy: .public) score=0"
        )
        return nil
    }

    /// Resolve the canonical online row for a raw discovery result.
    /// Dashboard and scan UI should use this instead of inferring online state from IP fields.
    public func resolvedOnlineDevice(for discoveredDevice: DiscoveredDevice) -> OnlineDevice? {
        let scoredMatches = onlineDevices
            .filter { !$0.isLocalDevice }
            .compactMap { onlineDevice -> (score: Int, device: OnlineDevice)? in
                let score = scoreCandidateDevice(
                    discoveredDevice,
                    context: makeCandidateMatchingContext(for: onlineDevice)
                )
                guard score > 0 else { return nil }
                return (score, onlineDevice)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.device.connectionStatus.priority != rhs.device.connectionStatus.priority {
                    return lhs.device.connectionStatus.priority > rhs.device.connectionStatus.priority
                }
                if lhs.device.lastSeen != rhs.device.lastSeen {
                    return lhs.device.lastSeen > rhs.device.lastSeen
                }
                return lhs.device.name < rhs.device.name
            }

        if let resolved = scoredMatches.first {
            logger.debug(
                "online-state sourceMerge source=discovered-device target=\(discoveredDevice.name, privacy: .public) resolved=\(resolved.device.name, privacy: .public) status=\(resolved.device.connectionStatus.rawValue, privacy: .public) score=\(resolved.score, privacy: .public)"
            )
            return resolved.device
        }

        logger.debug(
            "online-state sourceMerge source=discovered-device target=\(discoveredDevice.name, privacy: .public) resolved=none status=offline score=0"
        )
        return nil
    }

    public func resolvedApplePeerMetadata(
        for trustRecord: TrustRecord
    ) -> ApplePeerDeviceMetadataNormalizer.Presentation? {
        resolvedApplePeerMetadata(for: [trustRecord])
    }

    public func resolvedApplePeerMetadata(
        for trustRecords: [TrustRecord]
    ) -> ApplePeerDeviceMetadataNormalizer.Presentation? {
        let validRecords = trustRecords.filter { !$0.isTombstone && !$0.isExpired }
        guard !validRecords.isEmpty else { return nil }

        var presentations: [ApplePeerDeviceMetadataNormalizer.Presentation] = []

        let discoveredCandidates = resolvedDiscoveredCandidates(for: validRecords, limit: 5)

        for discoveredDevice in discoveredCandidates {
            let normalizedDiscovered = ApplePeerDeviceMetadataNormalizer.normalize(
                modelName: discoveredDevice.modelName,
                chip: discoveredDevice.chip,
                platform: discoveredDevice.platformName,
                osVersion: discoveredDevice.osVersion
            )

            if normalizedDiscovered.modelName != nil
                || normalizedDiscovered.chip != nil
                || normalizedDiscovered.platform != nil
                || normalizedDiscovered.osVersion != nil {
                    presentations.append(normalizedDiscovered)
            }
        }

        for record in validRecords {
            if let onlineDevice = resolvedOnlineDevice(for: record) {
                let normalizedOnline = ApplePeerDeviceMetadataNormalizer.normalize(
                    modelName: onlineDevice.modelName,
                    chip: onlineDevice.chip,
                    platform: onlineDevice.platformName,
                    osVersion: onlineDevice.osVersion
                )

                if normalizedOnline.modelName != nil
                    || normalizedOnline.chip != nil
                    || normalizedOnline.platform != nil
                    || normalizedOnline.osVersion != nil {
                    presentations.append(normalizedOnline)
                }
            }
        }

        let merged = ApplePeerDeviceMetadataNormalizer.mergedPresentations(presentations)
        logger.debug(
            "trusted metadata merge: records=\(validRecords.count, privacy: .public) discovered=\(discoveredCandidates.count, privacy: .public) presentations=\(presentations.count, privacy: .public) mergedOS=\(merged?.osVersion ?? "", privacy: .public)"
        )
        return merged
    }

    /// 解析在线设备对应的底层发现记录（用于连接时保留真实 Bonjour/IP 元数据）。
    public func resolvedDiscoveredDevice(for onlineDevice: OnlineDevice) -> DiscoveredDevice? {
        resolvedDiscoveredCandidates(for: onlineDevice, limit: 1).first
    }

    /// 解析在线设备对应的候选发现记录（按可连接性与稳定性降序）。
    public func resolvedDiscoveredCandidates(
        for onlineDevice: OnlineDevice,
        limit: Int = 3
    ) -> [DiscoveredDevice] {
        guard limit > 0 else { return [] }
        let candidates = networkDiscovery.discoveredDevices
        guard !candidates.isEmpty else { return [] }

        let context = makeCandidateMatchingContext(for: onlineDevice)
        let scored = candidates
            .filter { !$0.isLocalDevice }
            .compactMap { candidate -> (score: Int, device: DiscoveredDevice)? in
                let score = scoreCandidateDevice(candidate, context: context)
                guard score > 0 else { return nil }
                return (score, candidate)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.device.name < rhs.device.name
            }

        return scored.prefix(limit).map(\.device)
    }

    /// Resolve only candidates that contain a route the connection layer can dial without
    /// guessing a display name. Strong online identity is still used for matching; routing
    /// must come from a Bonjour instance identifier or a concrete host endpoint.
    public func resolvedConnectableDiscoveredCandidates(
        for onlineDevice: OnlineDevice,
        limit: Int = 3
    ) -> [DiscoveredDevice] {
        guard limit > 0 else { return [] }
        return resolvedDiscoveredCandidates(for: onlineDevice, limit: max(limit * 2, limit))
            .filter(Self.hasResolvedSkyBridgeControlRoute)
            .prefix(limit)
            .map { $0 }
    }

    public func hasUnresolvedLiveSkyBridgeControlRoute(for onlineDevice: OnlineDevice) -> Bool {
        resolvedDiscoveredCandidates(for: onlineDevice, limit: 6)
            .contains { candidate in
                Self.isUnresolvedLiveSkyBridgeControlRoute(candidate, for: onlineDevice)
            }
    }

    private nonisolated static func isUnresolvedLiveSkyBridgeControlRoute(
        _ candidate: DiscoveredDevice,
        for onlineDevice: OnlineDevice
    ) -> Bool {
        guard hasSkyBridgeControlHint(services: candidate.services, portMap: candidate.portMap),
              !hasResolvedSkyBridgeControlRoute(candidate) else {
            return false
        }
        if isAppleMobilePresentation(candidate),
           BonjourInteropContract.normalizedPubKeyFingerprint(candidate.pubKeyFP) == nil {
            return false
        }

        let onlineAliases = normalizedPeerAliases(for: onlineDevice)
        let candidateAliases = normalizedPeerAliases(for: candidate)
        return !onlineAliases.isEmpty && !candidateAliases.isEmpty && !onlineAliases.isDisjoint(with: candidateAliases)
    }

    public func hasResolvedConnectableControlRoute(for onlineDevice: OnlineDevice) -> Bool {
        if !resolvedConnectableDiscoveredCandidates(for: onlineDevice, limit: 1).isEmpty {
            return true
        }
        if hasUnresolvedLiveSkyBridgeControlRoute(for: onlineDevice) {
            return false
        }
        guard onlineDevice.isConnectable || onlineDevice.connectionStatus == .connected else {
            return false
        }
        guard Self.hasRequiredProtocolIdentityForCachedAppleMobileRoute(onlineDevice) else {
            return false
        }
        if Self.hasDirectSkyBridgeControlRoute(onlineDevice) {
            return true
        }
        if Self.isAppleMobilePresentation(onlineDevice),
           !Self.hasPositiveSkyBridgeControlPort(onlineDevice.portMap) {
            return false
        }
        guard !Self.hasExplicitOnlyNonConnectableAddress(onlineDevice) else {
            return false
        }
        if Self.hasBonjourSkyBridgeControlRoute(
            identifier: onlineDevice.uniqueIdentifier,
            services: onlineDevice.services,
            portMap: onlineDevice.portMap,
            routeIdentifiers: onlineDevice.routeIdentifiers
        ) {
            return true
        }
        return false
    }

    public nonisolated static func hasResolvedSkyBridgeControlRoute(_ candidate: DiscoveredDevice) -> Bool {
        guard hasSkyBridgeControlHint(services: candidate.services, portMap: candidate.portMap) else {
            return false
        }
        if isAppleMobilePresentation(candidate) {
            guard BonjourInteropContract.normalizedPubKeyFingerprint(candidate.pubKeyFP) != nil,
                  hasPositiveSkyBridgeControlPort(candidate.portMap) else {
                return false
            }
        }
        if hasConnectableIPAddress(candidate.ipv4) || hasConnectableIPAddress(candidate.ipv6) {
            return hasPositiveSkyBridgeControlPort(candidate.portMap)
        }
        guard !hasExplicitOnlyNonConnectableAddress(ipv4: candidate.ipv4, ipv6: candidate.ipv6) else {
            return false
        }
        return hasBonjourSkyBridgeControlRoute(
            identifier: candidate.uniqueIdentifier,
            services: candidate.services,
            portMap: candidate.portMap,
            routeIdentifiers: candidate.routeIdentifiers
        )
    }

    public nonisolated static func hasDirectSkyBridgeControlRoute(_ device: OnlineDevice) -> Bool {
        guard hasPositiveSkyBridgeControlPort(device.portMap) else {
            return false
        }
        return hasConnectableIPAddress(device.ipv4) || hasConnectableIPAddress(device.ipv6)
    }

    public nonisolated static func hasBonjourSkyBridgeControlRoute(
        identifier: String?,
        services: [String],
        portMap: [String: Int],
        routeIdentifiers: [String] = []
    ) -> Bool {
        guard hasSkyBridgeControlHint(services: services, portMap: portMap) else {
            return false
        }
        return ([identifier].compactMap { $0 } + routeIdentifiers).contains { raw in
            hasUsableBonjourRouteIdentifier(raw)
        }
    }

    private nonisolated static func hasSkyBridgeControlHint(
        services: [String],
        portMap: [String: Int]
    ) -> Bool {
        let normalizedServices = services.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return normalizedServices.contains("_skybridge._tcp")
            || normalizedServices.contains("_skybridge._udp")
            || (portMap["_skybridge._tcp"] ?? 0) > 0
            || (portMap["_skybridge._udp"] ?? 0) > 0
    }

    private nonisolated static func hasPositiveSkyBridgeControlPort(_ portMap: [String: Int]) -> Bool {
        (portMap["_skybridge._tcp"] ?? 0) > 0
            || (portMap["_skybridge._udp"] ?? 0) > 0
    }

    private nonisolated static func hasConnectableIPAddress(_ raw: String?) -> Bool {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return false
        }
        if value.hasPrefix("[") && value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        if let scopeIndex = value.firstIndex(of: "%") {
            value = String(value[..<scopeIndex])
        }
        if IPv4Address(value) != nil {
            return isConnectableIPv4Address(value)
        }
        if IPv6Address(value) != nil {
            return isConnectableIPv6Address(value)
        }
        return false
    }

    private nonisolated static func isConnectableIPv4Address(_ value: String) -> Bool {
        !value.hasPrefix("169.254.")
            && !value.hasPrefix("127.")
            && !value.hasPrefix("0.")
            && value != "255.255.255.255"
    }

    private nonisolated static func isConnectableIPv6Address(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard IPv6Address(normalized) != nil else { return false }
        return normalized != "::"
            && normalized != "::1"
            && !normalized.hasPrefix("fe80:")
            && !normalized.hasPrefix("ff")
    }

    private nonisolated static func hasExplicitOnlyNonConnectableAddress(_ device: OnlineDevice) -> Bool {
        hasExplicitOnlyNonConnectableAddress(ipv4: device.ipv4, ipv6: device.ipv6)
    }

    private nonisolated static func hasExplicitOnlyNonConnectableAddress(
        ipv4: String?,
        ipv6: String?
    ) -> Bool {
        let rawAddresses = [ipv4, ipv6]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !rawAddresses.isEmpty else { return false }
        return !rawAddresses.contains { hasConnectableIPAddress($0) }
    }

    private nonisolated static func normalizedIPv4Address(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IPv4Address(value) != nil else { return nil }
        return value
    }

    private nonisolated static func shouldReplaceIPv4Address(
        existing: String?,
        candidate: String?
    ) -> Bool {
        guard let candidate = normalizedIPv4Address(candidate),
              isConnectableIPv4Address(candidate) else {
            return false
        }
        guard let existing = normalizedIPv4Address(existing) else {
            return true
        }
        if !isConnectableIPv4Address(existing) {
            return true
        }
        return false
    }

    private nonisolated static func shouldClearStaleIPv4Address(
        existing: String?,
        candidate: String?
    ) -> Bool {
        guard let existing = normalizedIPv4Address(existing),
              !isConnectableIPv4Address(existing) else {
            return false
        }
        guard let candidate = normalizedIPv4Address(candidate) else {
            return true
        }
        return !isConnectableIPv4Address(candidate)
    }

    public func resolvedDiscoveredCandidates(
        for trustRecords: [TrustRecord],
        limit: Int = 3
    ) -> [DiscoveredDevice] {
        guard limit > 0 else { return [] }
        let validRecords = trustRecords.filter { !$0.isTombstone && !$0.isExpired }
        guard !validRecords.isEmpty else { return [] }

        let candidates = networkDiscovery.discoveredDevices
        guard !candidates.isEmpty else { return [] }

        let scored = candidates
            .filter { !$0.isLocalDevice }
            .compactMap { candidate -> (score: Int, device: DiscoveredDevice)? in
                let baseScore = validRecords.reduce(into: 0) { best, record in
                    best = max(best, scoreDiscoveredTrustRecordCandidate(candidate, trustRecord: record))
                }
                guard baseScore > 0 else { return nil }
                return (baseScore + metadataRichnessScore(for: candidate), candidate)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.device.name < rhs.device.name
            }

        let resolved = scored.prefix(limit).map(\.device)
        if !validRecords.isEmpty {
            let summary = resolved.map {
                "\($0.name)|\($0.deviceId ?? "")|\($0.osVersion ?? "")|\($0.uniqueIdentifier ?? "")"
            }.joined(separator: ";")
            logger.debug(
                "trusted discovered candidates: records=\(validRecords.count, privacy: .public) totalCandidates=\(candidates.count, privacy: .public) matched=\(resolved.count, privacy: .public) summary=\(summary, privacy: .public)"
            )
        }
        return resolved
    }

    private func resolvedDiscoveredDevice(for trustRecord: TrustRecord) -> DiscoveredDevice? {
        resolvedDiscoveredCandidates(for: [trustRecord], limit: 1).first
    }

 /// 标记设备为已连接
    public func markDeviceAsConnected(_ deviceId: UUID) {
        guard let index = onlineDevices.firstIndex(where: { $0.id == deviceId }) else { return }

        var device = onlineDevices[index]
        device.connectionStatus = .connected
        device.lastConnectedAt = Date()
        if device.guardStatus == nil { device.guardStatus = "守护中" }

        onlineDevices[index] = device
        deviceMap[device.uniqueIdentifier] = device

 // 持久化
        storage.saveDevice(device)

        logger.info("✅ 设备标记为已连接: \(device.name)")
    }

    /// 标记设备为已连接（入站连接场景：没有点击“连接”，但握手已完成）
    public func markDeviceAsConnected(
        peerId: String,
        displayName: String,
        cryptoKind: String,
        suite: String,
        guardStatus: String = "守护中"
    ) {
        let normalizedPeerId = Self.normalizedPeerIdentifier(peerId)
        let normalizedRecentIdentifier = "recent:\(normalizedPeerId)"
        let stablePeerAliases = Self.normalizedStableConnectionAliases(for: peerId)
        let peerRouteAliases = Self.normalizedConnectionPeerAliases(for: peerId)
        let peerRouteIdentifiers = Self.routeIdentifiers(from: peerId)

        func applyConnectedStatus(to device: inout OnlineDevice) {
            device.connectionStatus = .connected
            device.lastConnectedAt = Date()
            device.lastCryptoKind = cryptoKind
            device.lastCryptoSuite = suite
            device.guardStatus = guardStatus
            device.lastSeen = Date()
            device.routeIdentifiers = Self.mergedRouteIdentifiers(device.routeIdentifiers, peerRouteIdentifiers)
        }

        if !stablePeerAliases.isEmpty,
           let idx = onlineDevices.firstIndex(where: {
               !Self.normalizedStableConnectionAliases(fromUniqueIdentifier: $0.uniqueIdentifier)
                   .isDisjoint(with: stablePeerAliases)
           }) {
            var device = onlineDevices[idx]
            applyConnectedStatus(to: &device)
            onlineDevices[idx] = device
            deviceMap[device.uniqueIdentifier] = device
            pruneRecentDuplicates(matching: normalizedRecentIdentifier, keep: device.id)
            storage.saveDevice(device)
            updateDevicesList()
            logger.info("✅ 设备标记为已连接(匹配stable-id): \(device.name, privacy: .public)")
            return
        }

        if !peerRouteAliases.isEmpty,
           let idx = onlineDevices.firstIndex(where: {
               !Self.normalizedPeerAliases(for: $0).isDisjoint(with: peerRouteAliases)
           }) {
            var device = onlineDevices[idx]
            applyConnectedStatus(to: &device)
            onlineDevices[idx] = device
            deviceMap[device.uniqueIdentifier] = device
            pruneRecentDuplicates(matching: normalizedRecentIdentifier, keep: device.id)
            storage.saveDevice(device)
            updateDevicesList()
            logger.info("✅ 设备标记为已连接(匹配route-alias): \(device.name, privacy: .public)")
            return
        }

        if let idx = indexOfDeviceMatchingPeerIP(normalizedPeerId) {
            var device = onlineDevices[idx]
            applyConnectedStatus(to: &device)
            onlineDevices[idx] = device
            deviceMap[device.uniqueIdentifier] = device
            pruneRecentDuplicates(matching: normalizedRecentIdentifier, keep: device.id)
            storage.saveDevice(device)
            updateDevicesList()
            logger.info("✅ 设备标记为已连接(IP匹配): \(device.name)")
            return
        }

        guard !Self.isEphemeralConnectionPeerIdentifier(normalizedPeerId) else {
            logger.debug(
                "↪️ 跳过创建recent记录（peerId为会话路由，不是设备身份）: \(peerId, privacy: .public)"
            )
            return
        }

        if !Self.isAppleMobilePresentationName(displayName),
           let idx = onlineDevices.firstIndex(where: {
               $0.name == displayName && !Self.isAppleMobilePresentation($0)
           }) {
            var device = onlineDevices[idx]
            applyConnectedStatus(to: &device)
            onlineDevices[idx] = device
            deviceMap[device.uniqueIdentifier] = device
            pruneRecentDuplicates(matching: normalizedRecentIdentifier, keep: device.id)
            storage.saveDevice(device)
            updateDevicesList()
            logger.info("✅ 设备标记为已连接(匹配name): \(device.name)")
            return
        }

        if let idx = onlineDevices.firstIndex(where: {
            Self.normalizedRecentIdentifier(from: $0.uniqueIdentifier) == normalizedRecentIdentifier
        }) {
            var device = onlineDevices[idx]
            let oldIdentifier = device.uniqueIdentifier
            applyConnectedStatus(to: &device)
            if oldIdentifier.hasPrefix("recent:") && oldIdentifier != normalizedRecentIdentifier {
                device = Self.copyDevice(device, uniqueIdentifier: normalizedRecentIdentifier)
            }
            onlineDevices[idx] = device
            if oldIdentifier != device.uniqueIdentifier {
                deviceMap.removeValue(forKey: oldIdentifier)
            }
            deviceMap[device.uniqueIdentifier] = device
            pruneRecentDuplicates(matching: normalizedRecentIdentifier, keep: device.id)
            storage.saveDevice(device)
            updateDevicesList()
            logger.info("✅ 设备标记为已连接(匹配recent): \(device.name)")
            return
        }

        // Synthetic names like "peer:fe80::..." are unstable and create duplicate noise.
        guard !Self.isSyntheticPeerDisplayName(displayName) else {
            logger.debug("↪️ 跳过创建recent记录（displayName为临时peer）: \(displayName, privacy: .public)")
            return
        }

        let now = Date()
        let newUniqueIdentifier = Self.canonicalStableIdentifierToken(peerId) ?? normalizedRecentIdentifier
        let new = OnlineDevice(
            id: UUID(),
            name: displayName,
            deviceType: .unknown,
            ipv4: nil,
            ipv6: nil,
            macAddress: nil,
            serialNumber: nil,
            connectionTypes: [.wifi],
            services: ["_skybridge._tcp"],
            portMap: [:],
            uniqueIdentifier: newUniqueIdentifier,
            sources: [.skybridgeBonjour],
            discoveredAt: now,
            lastSeen: now,
            connectionStatus: .connected,
            lastConnectedAt: now,
            lastCryptoKind: cryptoKind,
            lastCryptoSuite: suite,
            guardStatus: guardStatus,
            isLocalDevice: false,
            isAuthorized: false
        )
        deviceMap[new.uniqueIdentifier] = new
        onlineDevices.append(new)
        pruneRecentDuplicates(matching: normalizedRecentIdentifier, keep: new.id)
        storage.saveDevice(new)
        updateDevicesList()
        logger.info("✅ 设备标记为已连接(新增recent): \(displayName, privacy: .public)")
    }

    public func markDeviceAsDisconnected(
        peerId: String,
        displayName: String? = nil
    ) {
        let normalizedPeerId = Self.normalizedPeerIdentifier(peerId)
        let normalizedRecentIdentifier = "recent:\(normalizedPeerId)"
        let normalizedDisplayName = displayName.map(normalizeDeviceName) ?? ""
        let stablePeerAliases = Self.normalizedStableConnectionAliases(for: peerId)
        let peerRouteAliases = Self.normalizedConnectionPeerAliases(for: peerId)

        func disconnectStatus(for device: OnlineDevice) -> OnlineDeviceStatus {
            Date().timeIntervalSince(device.lastSeen) < 60 ? .online : .offline
        }

        var updated = false

        for index in onlineDevices.indices {
            let device = onlineDevices[index]
            let matchesRecent =
                Self.normalizedRecentIdentifier(from: device.uniqueIdentifier) == normalizedRecentIdentifier
            let matchesStableId =
                !stablePeerAliases.isEmpty &&
                !Self.normalizedStableConnectionAliases(fromUniqueIdentifier: device.uniqueIdentifier)
                    .isDisjoint(with: stablePeerAliases)
            let matchesIP = indexOfDeviceMatchingPeerIP(normalizedPeerId) == index
            let matchesRouteAlias =
                !peerRouteAliases.isEmpty &&
                !Self.normalizedPeerAliases(for: device).isDisjoint(with: peerRouteAliases)
            let matchesName =
                !normalizedDisplayName.isEmpty &&
                !Self.isAppleMobilePresentationName(displayName ?? "") &&
                !Self.isAppleMobilePresentation(device) &&
                normalizeDeviceName(device.name) == normalizedDisplayName

            guard matchesRecent || matchesStableId || matchesIP || matchesRouteAlias || matchesName else { continue }

            var next = device
            next.connectionStatus = disconnectStatus(for: device)
            next.guardStatus = nil
            onlineDevices[index] = next
            deviceMap[next.uniqueIdentifier] = next
            storage.saveDevice(next)
            updated = true
        }

        if updated {
            updateDevicesList()
            logger.info("⏹️ 设备标记为已断开: \(displayName ?? peerId, privacy: .public)")
        }
    }

 /// 标记设备为已授权(iCloud)
    public func markDeviceAsAuthorized(_ deviceId: UUID) {
        guard let index = onlineDevices.firstIndex(where: { $0.id == deviceId }) else { return }

        var device = onlineDevices[index]
        device.isAuthorized = true
        device.lastConnectedAt = Date()

        onlineDevices[index] = device
        deviceMap[device.uniqueIdentifier] = device

 // 持久化
        storage.saveDevice(device)

        logger.info("✅ 设备标记为已授权: \(device.name)")
    }

    private func pruneRecentDuplicates(matching normalizedRecentIdentifier: String, keep keepId: UUID) {
        let duplicateIds = Set(
            onlineDevices.compactMap { device -> UUID? in
                guard device.id != keepId else { return nil }
                guard let normalized = Self.normalizedRecentIdentifier(from: device.uniqueIdentifier) else { return nil }
                return normalized == normalizedRecentIdentifier ? device.id : nil
            }
        )
        guard !duplicateIds.isEmpty else { return }

        onlineDevices.removeAll { duplicateIds.contains($0.id) }
        deviceMap = deviceMap.filter { _, device in !duplicateIds.contains(device.id) }
    }

    private func indexOfDeviceMatchingPeerIP(_ normalizedPeerId: String) -> Int? {
        let extracted = Self.extractIPComponents(fromNormalizedPeerId: normalizedPeerId)
        if let v6 = extracted.ipv6 {
            return onlineDevices.firstIndex { device in
                guard let existing = device.ipv6 else { return false }
                return Self.normalizeIPAddress(existing) == v6
            }
        }
        if let v4 = extracted.ipv4 {
            return onlineDevices.firstIndex { device in
                guard let existing = device.ipv4 else { return false }
                return Self.normalizeIPAddress(existing) == v4
            }
        }
        return nil
    }

 // MARK: - 私有方法

 /// 设置观察者
    private func setupObservers() {
 // 观察网络设备变化
        networkDiscovery.$discoveredDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                self?.handleNetworkDevicesUpdate(devices)
            }
            .store(in: &cancellables)

 // 观察USB设备变化
        usbDiscovery.$usbDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                self?.handleUSBDevicesUpdate(devices)
            }
            .store(in: &cancellables)

 // 观察安全连接在线态变化，确保连接状态在 UI 上及时刷新
        ConnectionPresenceService.shared.$activeConnections
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateDevicesList()
            }
            .store(in: &cancellables)
    }

    private func ensureICloudDiscoveryObserver() {
        guard iCloudDiscoveryCancellable == nil, let iCloudDiscovery else { return }
        iCloudDiscoveryCancellable = iCloudDiscovery.$discoveredDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                self?.handleiCloudDevicesUpdate(devices)
            }
    }

    private func startDiscoveryPresenceRefreshTimer() {
        discoveryPresenceRefreshTimer?.invalidate()
        discoveryPresenceRefreshTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshActiveDiscoveryPresence()
            }
        }
        discoveryPresenceRefreshTimer?.tolerance = 5.0
    }

    private func stopDiscoveryPresenceRefreshTimer() {
        discoveryPresenceRefreshTimer?.invalidate()
        discoveryPresenceRefreshTimer = nil
    }

    private func refreshActiveDiscoveryPresence() {
        guard isScanning else { return }

        let liveBonjourDevices = networkDiscovery.discoveredDevices
        if !liveBonjourDevices.isEmpty {
            handleNetworkDevicesUpdate(liveBonjourDevices)
        }

        if iCloudDiscovery == nil {
            iCloudDiscovery = iCloudDeviceDiscoveryManager.shared
            ensureICloudDiscoveryObserver()
        }

        Task { await iCloudDiscovery?.refreshDevices() }
    }

 /// 将全局设置同步到网络设备发现器，以保证 UI 开关生效
    public func applyRuntimeDiscoverySettings(restartIfNeeded: Bool = true) {
        applyDiscoverySettingsFromGlobalConfig(restartIfNeeded: restartIfNeeded)
    }

    private func applyDiscoverySettingsFromGlobalConfig(restartIfNeeded: Bool = true) {
        let settings = SettingsManager.shared
        networkDiscovery.applyRuntimeSettings(
            compatibilityMode: settings.enableCompatibilityMode,
            companionLink: settings.enableCompanionLink,
            ipv6Support: settings.enableIPv6Support,
            useNewDiscoveryAlgorithm: settings.useNewDiscoveryAlgorithm,
            enableBonjourDiscovery: settings.enableBonjourDiscovery,
            enableMDNSResolution: settings.enableMDNSResolution,
            scanCustomPorts: settings.scanCustomPorts,
            customServiceTypes: settings.customServiceTypes,
            discoveryTimeout: settings.discoveryTimeout,
            restartIfNeeded: restartIfNeeded
        )
    }

 /// 处理网络设备更新
    private func handleNetworkDevicesUpdate(_ devices: [DiscoveredDevice]) {
        logger.debug("📡 网络设备更新: \(devices.count) 台")
        updateDiscoveryMetadataSummary(from: devices)

        let identifiedDevices = devices.map { device in
            let preferredMAC = preferredMACAddress(from: device.macSet)
            let identifier = generateUniqueIdentifier(
                stableDeviceId: device.deviceId,
                pubKeyFP: device.pubKeyFP,
                macAddress: preferredMAC,
                serialNumber: nil,
                name: device.name,
                ipv4: device.ipv4,
                ipv6: device.ipv6,
                discoveryIdentifier: device.uniqueIdentifier
            )
            return (device: device, preferredMAC: preferredMAC, identifier: identifier)
        }

        var classifications: [String: Bool] = [:]
        for identified in identifiedDevices {
            let keys = Self.authoritativeLocalIdentityKeys(
                identifier: identified.identifier,
                deviceId: identified.device.deviceId,
                protocolFingerprint: identified.device.pubKeyFP
            )
            for key in keys {
                classifications[key] = (classifications[key] == true) || identified.device.isLocalDevice
            }
        }
        authoritativeNetworkLocalClassifications = classifications

        for identified in identifiedDevices {
            let device = identified.device

            mergeOrCreateDevice(
                identifier: identified.identifier,
                name: device.name,
                deviceType: device.deviceType,
                ipv4: device.ipv4,
                ipv6: device.ipv6,
                platformName: device.platformName,
                osVersion: device.osVersion,
                modelName: device.modelName,
                chip: device.chip,
                macAddress: identified.preferredMAC,
                serialNumber: nil,
                connectionTypes: device.connectionTypes,
                services: device.services,
                portMap: device.portMap,
                routeIdentifiers: Self.mergedRouteIdentifiers(
                    device.routeIdentifiers,
                    Self.routeIdentifiers(from: device.uniqueIdentifier)
                ),
                protocolFingerprint: device.pubKeyFP,
                source: DeviceSource.skybridgeBonjour,
                signalStrength: device.signalStrength,
                isConnectable: Self.hasResolvedSkyBridgeControlRoute(device),
                authoritativeIsLocalDevice: device.isLocalDevice
            )
        }

        updateDevicesList()
    }

    private func updateDiscoveryMetadataSummary(from devices: [DiscoveredDevice]) {
        let summary = devices
            .filter { !$0.isLocalDevice }
            .map { device in
                let services = device.services.sorted().joined(separator: ",")
                let ports = device.portMap.keys.sorted().map { key in
                    "\(key)=\(device.portMap[key] ?? 0)"
                }.joined(separator: ",")
                return [
                    device.uniqueIdentifier ?? "",
                    device.deviceId ?? "",
                    device.name,
                    device.pubKeyFP ?? "",
                    device.platformName ?? "",
                    device.osVersion ?? "",
                    device.modelName ?? "",
                    device.chip ?? "",
                    device.ipv4 ?? "",
                    device.ipv6 ?? "",
                    services,
                    ports
                ].joined(separator: "::")
            }
            .sorted()
            .joined(separator: "|")

        if discoveryMetadataSummary != summary {
            discoveryMetadataSummary = summary
        }
    }

#if DEBUG || SKYBRIDGE_TESTING
    public struct SmokeDiscoveryDiagnostic {
        public let name: String
        public let uniqueIdentifier: String?
        public let deviceId: String?
        public let pubKeyFP: String?
        public let ipv4: String?
        public let ipv6: String?
        public let services: [String]
        public let portMap: [String: Int]
        public let routeIdentifiers: [String]
        public let hasResolvedControlRoute: Bool
        public let isLocalDevice: Bool
    }

    public func smokeDiscoveryDiagnostics(limit: Int = 16) -> [SmokeDiscoveryDiagnostic] {
        let boundedLimit = max(0, limit)
        guard boundedLimit > 0 else { return [] }
        return networkDiscovery.discoveredDevices
            .prefix(boundedLimit)
            .map { device in
                SmokeDiscoveryDiagnostic(
                    name: device.name,
                    uniqueIdentifier: device.uniqueIdentifier,
                    deviceId: device.deviceId,
                    pubKeyFP: device.pubKeyFP,
                    ipv4: device.ipv4,
                    ipv6: device.ipv6,
                    services: device.services,
                    portMap: device.portMap,
                    routeIdentifiers: device.routeIdentifiers,
                    hasResolvedControlRoute: Self.hasResolvedSkyBridgeControlRoute(device),
                    isLocalDevice: device.isLocalDevice
                )
            }
    }
#endif

    /// 处理USB设备更新
    private func handleUSBDevicesUpdate(_ devices: [USBDevice]) {
        logger.debug("🔌 USB设备更新: \(devices.count) 台")
        activeUSBPresenceTokens = Set(devices.flatMap { usbPresenceTokens(for: $0) })

        for device in devices {
            let identifier = generateUniqueIdentifier(
                stableDeviceId: nil,
                pubKeyFP: nil,
                macAddress: nil,
                serialNumber: device.serialNumber,
                name: device.name,
                ipv4: nil,
                ipv6: nil
            )

            mergeOrCreateDevice(
                identifier: identifier,
                name: device.name,
                deviceType: mapUSBDeviceType(device.deviceType),
                ipv4: nil,
                ipv6: nil,
                platformName: nil,
                osVersion: nil,
                modelName: nil,
                chip: nil,
                macAddress: nil,
                serialNumber: device.serialNumber,
                connectionTypes: [.usb],
                services: [],
                portMap: [:],
                source: DeviceSource.skybridgeUSB,
                signalStrength: nil,
                isConnectable: true
            )
        }

        updateDevicesList()
    }

 /// 处理iCloud设备更新
    private func handleiCloudDevicesUpdate(_ devices: [iCloudDevice]) {
        logger.debug("☁️ iCloud设备更新: \(devices.count) 台")

        for device in devices {
            let identifier = generateUniqueIdentifier(
                stableDeviceId: device.stableIdentityDeviceId,
                pubKeyFP: nil,
                macAddress: nil,
                serialNumber: nil,
                name: device.name,
                ipv4: device.ipAddress,
                ipv6: nil
            )

 // 从model推断设备类型
            let deviceType = inferDeviceTypeFromModel(device.model)

            mergeOrCreateDevice(
                identifier: identifier,
                name: device.name,
                deviceType: deviceType,
                ipv4: device.ipAddress,
                ipv6: nil,
                platformName: nil,
                osVersion: device.osVersion,
                modelName: device.model,
                chip: nil,
                macAddress: nil,
                serialNumber: nil,
                connectionTypes: [],
                services: [],
                portMap: [:],
                routeIdentifiers: [],
                source: DeviceSource.skybridgeCloud,
                signalStrength: nil,
                isConnectable: false,
                isAuthorized: true,
                lastSeen: device.lastSeen,
                initialConnectionStatus: device.isOnline ? .online : .offline
            )
        }

        updateDevicesList()
    }

 /// 从model字符串推断设备类型
    private func inferDeviceTypeFromModel(_ model: String) -> DeviceClassifier.DeviceType {
        let lowercased = model.lowercased()
        if lowercased.contains("iphone") || lowercased.contains("ipad") ||
           lowercased.contains("mac") || lowercased.contains("macbook") {
            return .computer
        } else if lowercased.contains("watch") {
            return .iot
        } else if lowercased.contains("tv") || lowercased.contains("appletv") {
            return .tv
        } else if lowercased.contains("pod") || lowercased.contains("homepod") {
            return .speaker
        } else {
            return .unknown
        }
    }

 /// 合并或创建设备
    private func mergeOrCreateDevice(
        identifier: String,
        name: String,
        deviceType: DeviceClassifier.DeviceType,
        ipv4: String?,
        ipv6: String?,
        platformName: String?,
        osVersion: String?,
        modelName: String?,
        chip: String?,
        macAddress: String?,
        serialNumber: String?,
        connectionTypes: Set<DeviceConnectionType>,
        services: [String],
        portMap: [String: Int],
        routeIdentifiers: [String] = [],
        protocolFingerprint: String? = nil,
        source: DeviceSource,
        signalStrength: Double? = nil,
        isConnectable: Bool = true,
        isAuthorized: Bool = false,
        lastSeen: Date = Date(),
        initialConnectionStatus: OnlineDeviceStatus = .online,
        authoritativeIsLocalDevice: Bool = false
    ) {
 // 检查是否已存在
        if var existingDevice = deviceMap[identifier] {
 // 合并设备信息
            existingDevice = mergeDeviceInfo(existing: existingDevice, new: OnlineDevice(
                id: existingDevice.id,
                name: name,
                deviceType: deviceType,
                ipv4: ipv4,
                ipv6: ipv6,
                platformName: platformName,
                osVersion: osVersion,
                modelName: modelName,
                chip: chip,
                macAddress: macAddress,
                serialNumber: serialNumber,
                connectionTypes: connectionTypes,
                services: services,
                portMap: portMap,
                routeIdentifiers: routeIdentifiers,
                protocolFingerprint: protocolFingerprint,
                uniqueIdentifier: identifier,
                sources: [source],
                discoveredAt: existingDevice.discoveredAt,
                lastSeen: lastSeen,
                connectionStatus: initialConnectionStatus,
                lastConnectedAt: existingDevice.lastConnectedAt,
                isLocalDevice: false,
                isAuthorized: isAuthorized || existingDevice.isAuthorized,
                signalStrength: signalStrength,
                isConnectable: isConnectable
            ))
            let upgradedIdentifier = preferredIdentifier(
                current: existingDevice.uniqueIdentifier,
                incoming: identifier,
                currentProtocolFingerprint: existingDevice.protocolFingerprint,
                incomingProtocolFingerprint: protocolFingerprint
            )
            if upgradedIdentifier != existingDevice.uniqueIdentifier {
                existingDevice = Self.copyDevice(existingDevice, uniqueIdentifier: upgradedIdentifier)
            }
            recordAuthoritativeLocalClassificationIfNeeded(
                authoritativeIsLocalDevice,
                identifier: existingDevice.uniqueIdentifier,
                protocolFingerprint: existingDevice.protocolFingerprint
            )
 // 合并完成后基于最新来源/MAC/类型重算本机标记
            existingDevice.isLocalDevice = isLocalCandidate(
                identifier: existingDevice.uniqueIdentifier,
                protocolFingerprint: existingDevice.protocolFingerprint,
                name: existingDevice.name,
                macAddress: existingDevice.macAddress,
                deviceType: existingDevice.deviceType,
                sources: existingDevice.sources,
                authoritativeIsLocalDevice: authoritativeIsLocalDevice
            )

            deviceMap[identifier] = existingDevice
            deviceMap[upgradedIdentifier] = existingDevice

            logger.debug("🔄 合并设备信息: \(name)")
        } else {
 // 尝试通过其他标识符找到相似设备
            if let similarIdentifier = findSimilarDevice(
                incomingIdentifier: identifier,
                incomingProtocolFingerprint: protocolFingerprint,
                name: name,
                ipv4: ipv4,
                ipv6: ipv6,
                macAddress: macAddress,
                serialNumber: serialNumber,
                source: source
            ) {
 // 找到相似设备,合并
                if var existingDevice = deviceMap[similarIdentifier] {
                    existingDevice = mergeDeviceInfo(existing: existingDevice, new: OnlineDevice(
                        id: existingDevice.id,
                        name: name,
                        deviceType: deviceType,
                        ipv4: ipv4,
                        ipv6: ipv6,
                        platformName: platformName,
                        osVersion: osVersion,
                        modelName: modelName,
                        chip: chip,
                        macAddress: macAddress,
                        serialNumber: serialNumber,
                        connectionTypes: connectionTypes,
                        services: services,
                        portMap: portMap,
                        routeIdentifiers: routeIdentifiers,
                        protocolFingerprint: protocolFingerprint,
                        uniqueIdentifier: identifier,
                        sources: [source],
                        discoveredAt: existingDevice.discoveredAt,
                        lastSeen: lastSeen,
                        connectionStatus: initialConnectionStatus,
                        lastConnectedAt: existingDevice.lastConnectedAt,
                        isLocalDevice: false,
                        isAuthorized: isAuthorized || existingDevice.isAuthorized,
                        signalStrength: signalStrength,
                        isConnectable: isConnectable
                    ))
                    let upgradedIdentifier = preferredIdentifier(
                        current: existingDevice.uniqueIdentifier,
                        incoming: identifier,
                        currentProtocolFingerprint: existingDevice.protocolFingerprint,
                        incomingProtocolFingerprint: protocolFingerprint
                    )
                    if upgradedIdentifier != existingDevice.uniqueIdentifier {
                        existingDevice = Self.copyDevice(existingDevice, uniqueIdentifier: upgradedIdentifier)
                    }
                    recordAuthoritativeLocalClassificationIfNeeded(
                        authoritativeIsLocalDevice,
                        identifier: existingDevice.uniqueIdentifier,
                        protocolFingerprint: existingDevice.protocolFingerprint
                    )
 // 合并完成后基于最新来源/MAC/类型重算本机标记
                    existingDevice.isLocalDevice = isLocalCandidate(
                        identifier: existingDevice.uniqueIdentifier,
                        protocolFingerprint: existingDevice.protocolFingerprint,
                        name: existingDevice.name,
                        macAddress: existingDevice.macAddress,
                        deviceType: existingDevice.deviceType,
                        sources: existingDevice.sources,
                        authoritativeIsLocalDevice: authoritativeIsLocalDevice
                    )

 // 更新两个标识符的映射
                    deviceMap[identifier] = existingDevice
                    deviceMap[similarIdentifier] = existingDevice
                    deviceMap[upgradedIdentifier] = existingDevice

                    logger.debug("🔄 发现相似设备并合并: \(name)")
                }
            } else {
 // 创建新设备
                recordAuthoritativeLocalClassificationIfNeeded(
                    authoritativeIsLocalDevice,
                    identifier: identifier,
                    protocolFingerprint: protocolFingerprint
                )
                let newDevice = OnlineDevice(
                    id: UUID(),
                    name: name,
                    deviceType: deviceType,
                    ipv4: ipv4,
                    ipv6: ipv6,
                    platformName: platformName,
                    osVersion: osVersion,
                    modelName: modelName,
                    chip: chip,
                    macAddress: macAddress,
                    serialNumber: serialNumber,
                    connectionTypes: connectionTypes,
                    services: services,
                    portMap: portMap,
                    routeIdentifiers: routeIdentifiers,
                    protocolFingerprint: protocolFingerprint,
                    uniqueIdentifier: identifier,
                    sources: [source],
                    discoveredAt: Date(),
                    lastSeen: lastSeen,
                    connectionStatus: initialConnectionStatus,
                    lastConnectedAt: nil,
                    isLocalDevice: isLocalCandidate(
                        identifier: identifier,
                        protocolFingerprint: protocolFingerprint,
                        name: name,
                        macAddress: macAddress,
                        deviceType: deviceType,
                        sources: [source],
                        authoritativeIsLocalDevice: authoritativeIsLocalDevice
                    ),
                    isAuthorized: isAuthorized,
                    signalStrength: signalStrength,
                    isConnectable: isConnectable
                )

                deviceMap[identifier] = newDevice

                logger.info("✅ 发现新设备: \(name)")
            }
        }
    }

 /// 智能查找相似设备
    private func findSimilarDevice(
        incomingIdentifier: String,
        incomingProtocolFingerprint: String?,
        name: String,
        ipv4: String?,
        ipv6: String?,
        macAddress: String?,
        serialNumber: String?,
        source: DeviceSource
    ) -> String? {
        let allowsWeakNameMatch = source != .skybridgeCloud
        let incomingHasProtocolIdentity =
            Self.canonicalStableIdentifierToken(incomingIdentifier) != nil ||
            normalizeFingerprint(incomingProtocolFingerprint) != nil

        for (identifier, device) in deviceMap {
 // 禁止将“相似设备”合并到本机条目，避免第三方设备覆盖本机
            if identifier.hasPrefix("local:") || device.isLocalDevice {
                continue
            }
 // 1. MAC地址匹配(最可靠)
            if let mac = macAddress, let existingMac = device.macAddress,
               !mac.isEmpty, !existingMac.isEmpty {
                if mac.lowercased() == existingMac.lowercased() {
                    return identifier
                }
            }

 // 2. 序列号匹配(非常可靠)
            if let serial = serialNumber, let existingSN = device.serialNumber,
               !serial.isEmpty, !existingSN.isEmpty {
                if serial == existingSN {
                    return identifier
                }
            }

 // 3. IP地址匹配(较可靠)
            if let ip = ipv4, let existingIp = device.ipv4,
               !ip.isEmpty, !existingIp.isEmpty {
                if ip == existingIp {
                    return identifier
                }
            }

            if let ip6 = ipv6, let existingIp6 = device.ipv6,
               !ip6.isEmpty, !existingIp6.isEmpty {
                if ip6 == existingIp6 {
                    return identifier
                }
            }

 // 4. 标准化名称匹配
            guard allowsWeakNameMatch else {
                continue
            }
            let existingHasProtocolIdentity =
                Self.canonicalStableIdentifierToken(device.uniqueIdentifier) != nil ||
                normalizeFingerprint(device.protocolFingerprint) != nil
            guard !incomingHasProtocolIdentity, !existingHasProtocolIdentity else {
                continue
            }

            let normalizedName = normalizeDeviceName(name)
            let normalizedExisting = normalizeDeviceName(device.name)

            if !normalizedName.isEmpty && normalizedName == normalizedExisting {
                return identifier
            }

 // 5. 名称包含关系
            if name.contains(device.name) || device.name.contains(name) {
                let lengthDiff = abs(name.count - device.name.count)
                if lengthDiff < 20 {
                    return identifier
                }
            }
        }

        return nil
    }

 /// 合并设备信息
    private func mergeDeviceInfo(existing: OnlineDevice, new: OnlineDevice) -> OnlineDevice {
        var merged = existing

 // 使用更可信的名称，避免路径端点（IP/peer:host）覆盖真实设备名。
        if Self.shouldReplaceDisplayName(existing: existing.name, candidate: new.name) {
            merged.name = new.name
        }

 // 合并IP地址；不要让旧的 169.254/loopback 路由长期压住新的 LAN 地址。
        if Self.shouldReplaceIPv4Address(existing: merged.ipv4, candidate: new.ipv4) {
            merged.ipv4 = new.ipv4?.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if Self.shouldClearStaleIPv4Address(existing: merged.ipv4, candidate: new.ipv4) {
            merged.ipv4 = nil
        }
        if merged.ipv6 == nil, let newIp6 = new.ipv6 {
            merged.ipv6 = newIp6
        }

        if (merged.platformName?.isEmpty ?? true), let platformName = new.platformName, !platformName.isEmpty {
            merged.platformName = platformName
        }
        if shouldReplaceOSVersion(existing: merged.osVersion, candidate: new.osVersion) {
            merged.osVersion = new.osVersion
        }
        if shouldReplaceMetadataValue(existing: merged.modelName, candidate: new.modelName) {
            merged.modelName = new.modelName
        }
        if shouldReplaceMetadataValue(existing: merged.chip, candidate: new.chip) {
            merged.chip = new.chip
        }

 // 合并MAC地址
        if merged.macAddress == nil, let newMac = new.macAddress {
            merged.macAddress = newMac
        }

 // 合并序列号。iCloud device.id 是应用层设备标识，不是真实硬件序列号，不能污染 USB/Bonjour 合并后的硬身份。
        if let newSerial = Self.credibleHardwareSerialNumber(from: new),
           merged.serialNumber == nil || Self.credibleHardwareSerialNumber(from: merged) == nil {
            merged.serialNumber = newSerial
        }

 // 合并连接类型
        merged.connectionTypes.formUnion(new.connectionTypes)

 // 合并服务
        for service in new.services {
            if !merged.services.contains(service) {
                merged.services.append(service)
            }
        }

 // 合并端口映射
        merged.portMap.merge(new.portMap) { current, incoming in
            current > 0 ? current : incoming
        }

        for routeIdentifier in new.routeIdentifiers where !merged.routeIdentifiers.contains(routeIdentifier) {
            merged.routeIdentifiers.append(routeIdentifier)
        }

        if let incomingFingerprint = normalizeFingerprint(new.protocolFingerprint) {
            merged.protocolFingerprint = incomingFingerprint
        }

 // 合并设备来源
        for source in new.sources {
            if !merged.sources.contains(source) {
                merged.sources.append(source)
            }
        }

 // 更新最后发现时间
        merged.lastSeen = max(existing.lastSeen, new.lastSeen)

        // 更新授权状态
        if new.isAuthorized {
            merged.isAuthorized = true
        }

        if let newSignal = new.signalStrength {
            if let existingSignal = merged.signalStrength {
                merged.signalStrength = max(existingSignal, newSignal)
            } else {
                merged.signalStrength = newSignal
            }
        }
        let cloudHeartbeatOnlyRefreshesStaleRoute = Self.isCloudHeartbeatOnly(new)
            && new.lastSeen.timeIntervalSince(existing.lastSeen) >= Self.controlRouteFreshnessWindow

        merged.isConnectable = merged.isConnectable || new.isConnectable
        if cloudHeartbeatOnlyRefreshesStaleRoute {
            merged.isConnectable = false
        }
        if Self.isCloudHeartbeatOnly(merged) {
            merged.isConnectable = false
        }
        merged.name = Self.bestDisplayName(for: [merged])

        return merged
    }

    private nonisolated static func shouldReplaceDisplayName(
        existing: String,
        candidate: String
    ) -> Bool {
        let existing = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return false }
        guard !existing.isEmpty else { return true }

        let existingScore = displayNameQualityScore(existing)
        let candidateScore = displayNameQualityScore(candidate)
        if existingScore != candidateScore {
            return candidateScore > existingScore
        }

        let existingGenericFamily = appleGenericDisplayNameFamily(existing)
        let candidateGenericFamily = appleGenericDisplayNameFamily(candidate)
        if existingGenericFamily != nil,
           candidateGenericFamily == nil,
           appleDeviceFamilyToken(candidate) == existingGenericFamily {
            return true
        }
        if candidateGenericFamily != nil,
           existingGenericFamily == nil,
           appleDeviceFamilyToken(existing) == candidateGenericFamily {
            return false
        }

        return candidate.count > existing.count
    }

    private nonisolated static func bestDisplayName(for devices: [OnlineDevice]) -> String {
        let best = devices
            .flatMap { device -> [String] in
                [device.name, device.modelName].compactMap {
                    LocalDevicePresentation.sanitizedDisplayNameCandidate($0)
                }
            }
            .reduce(nil as String?) { best, candidate in
                guard let best else { return candidate }
                return shouldReplaceDisplayName(existing: best, candidate: candidate) ? candidate : best
            }
        let trimmed = best?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, displayNameQualityScore(trimmed) > 20 {
            return trimmed
        }
        let family = appleDeviceFamilyToken(
            preferredValues: devices.flatMap { [$0.modelName, $0.name, $0.platformName] }
        )
        switch family {
        case "ipad":
            return "iPad"
        case "iphone":
            return "iPhone"
        case "mac":
            return "Mac"
        default:
            return trimmed.isEmpty ? "Unknown Device" : trimmed
        }
    }

    private nonisolated static func displayNameQualityScore(_ raw: String) -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        if LocalDevicePresentation.isIdentifierLikeDisplayName(trimmed) || isEndpointLikeDisplayName(trimmed) {
            return 10
        }
        let normalized = normalizedDedupeName(trimmed)
        if normalized == "unknown" || normalized == "unknowndevice" || normalized == "p2ppeer" || normalized == "未知设备" {
            return 20
        }
        if appleGenericDisplayNameFamily(trimmed) != nil {
            return 40
        }
        if let family = appleDeviceFamilyToken(trimmed) {
            let normalized = normalizedDedupeName(trimmed)
            let isAppleModelName = normalized.hasPrefix("ipad")
                || normalized.hasPrefix("iphone")
                || normalized.hasPrefix("macbook")
                || normalized.hasPrefix("macmini")
                || normalized.hasPrefix("macstudio")
                || normalized.hasPrefix("macpro")
                || normalized.hasPrefix("imac")
            if isAppleModelName {
                return family == "mac" ? 75 : 70
            }
            return 90
        }
        return 100
    }

    private nonisolated static func isEndpointLikeDisplayName(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isSyntheticPeerDisplayName(trimmed) {
            return true
        }
        if peerHostPayload(from: trimmed) != nil {
            return true
        }
        return hasConnectableIPAddress(trimmed)
    }

    private static func copyDevice(_ device: OnlineDevice, uniqueIdentifier: String) -> OnlineDevice {
        OnlineDevice(
            id: device.id,
            name: device.name,
            deviceType: device.deviceType,
            ipv4: device.ipv4,
            ipv6: device.ipv6,
            platformName: device.platformName,
            osVersion: device.osVersion,
            modelName: device.modelName,
            chip: device.chip,
            macAddress: device.macAddress,
            serialNumber: device.serialNumber,
            connectionTypes: device.connectionTypes,
            services: device.services,
            portMap: device.portMap,
            routeIdentifiers: Self.mergedRouteIdentifiers(
                device.routeIdentifiers,
                Self.routeIdentifiers(from: uniqueIdentifier)
            ),
            protocolFingerprint: device.protocolFingerprint,
            uniqueIdentifier: uniqueIdentifier,
            sources: device.sources,
            discoveredAt: device.discoveredAt,
            lastSeen: device.lastSeen,
            connectionStatus: device.connectionStatus,
            lastConnectedAt: device.lastConnectedAt,
            lastCryptoKind: device.lastCryptoKind,
            lastCryptoSuite: device.lastCryptoSuite,
            guardStatus: device.guardStatus,
            isLocalDevice: device.isLocalDevice,
            isAuthorized: device.isAuthorized,
            signalStrength: device.signalStrength,
            isConnectable: device.isConnectable
        )
    }

    private nonisolated static func normalizedRecentIdentifier(from uniqueIdentifier: String) -> String? {
        guard uniqueIdentifier.hasPrefix("recent:") else { return nil }
        let peerId = String(uniqueIdentifier.dropFirst("recent:".count))
        if let stable = normalizeStableIdentifier(peerId) {
            return "recent:\(normalizedPeerIdentifier(stable))"
        }
        return "recent:\(normalizedPeerIdentifier(peerId))"
    }

    private func normalizedPeerAliases(for trustRecord: TrustRecord) -> Set<String> {
        var aliases: Set<String> = []

        for stableId in ([trustRecord.deviceId, trustRecord.currentDeviceId] + trustRecord.knownDeviceIds) {
            if let normalized = Self.normalizeStableIdentifier(stableId) {
                aliases.insert(Self.normalizedPeerIdentifier(normalized))
            }
        }

        if let peerEndpoint = trustRecordCapabilityValue("peerEndpoint", for: trustRecord),
           !peerEndpoint.isEmpty {
            aliases.insert(Self.normalizedPeerIdentifier(peerEndpoint))
        }

        return aliases
    }

    private func normalizedNameTokens(for trustRecord: TrustRecord) -> Set<String> {
        var tokens: Set<String> = []
        let candidates = [
            trustRecord.deviceName,
            trustRecordCapabilityValue("peerEndpoint", for: trustRecord).flatMap(Self.bonjourName)
        ]

        for candidate in candidates {
            guard let candidate else { continue }
            let normalized = Self.normalizedDedupeName(candidate)
            if !normalized.isEmpty {
                tokens.insert(normalized)
            }
        }

        return tokens
    }

    private func trustRecordCapabilityValue(_ key: String, for trustRecord: TrustRecord) -> String? {
        trustRecord.capabilities
            .compactMap { capability -> String? in
                let parts = capability.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0] == key else { return nil }
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            .first
    }

    private nonisolated static func bonjourName(from peerEndpoint: String) -> String? {
        guard peerEndpoint.hasPrefix("bonjour:") else { return nil }
        let payload = peerEndpoint.dropFirst("bonjour:".count)
        let parts = payload.split(separator: "@", maxSplits: 1).map(String.init)
        guard let name = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        return name
    }

    private func normalizedFingerprintPayload(from uniqueIdentifier: String) -> String? {
        guard uniqueIdentifier.hasPrefix("fp:") else { return nil }
        return normalizeFingerprint(String(uniqueIdentifier.dropFirst("fp:".count)))
    }

    private nonisolated static func normalizedPeerIdentifier(_ peerId: String) -> String {
        let trimmed = peerId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("bonjour:") {
            let payload = String(trimmed.dropFirst("bonjour:".count))
            let parts = payload.split(separator: "@", maxSplits: 1).map(String.init)
            let name = (parts.first ?? payload)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let domain = parts.count > 1 ? parts[1].lowercased() : "local."
            return "bonjour:\(name)@\(domain)"
        }

        let raw: String
        if trimmed.hasPrefix("peer:") {
            raw = String(trimmed.dropFirst("peer:".count))
        } else {
            raw = trimmed
        }

        return "peer:\(normalizePeerHostToken(raw))"
    }

    private nonisolated static func normalizePeerHostToken(_ raw: String) -> String {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.hasPrefix("[") && token.hasSuffix("]") {
            token = String(token.dropFirst().dropLast())
        }
        if let pct = token.firstIndex(of: "%") {
            token = String(token[..<pct])
        }

        if token.contains(":"),
           let dot = token.lastIndex(of: "."),
           token[token.index(after: dot)...].allSatisfy({ $0.isNumber }) {
            token = String(token[..<dot])
        } else {
            let parts = token.split(separator: ".")
            if parts.count == 5,
               parts.dropLast().allSatisfy({ Int($0) != nil }),
               let port = Int(parts.last ?? ""), (0...65535).contains(port) {
                token = parts.dropLast().map(String.init).joined(separator: ".")
            }
        }
        return token.lowercased()
    }

    private nonisolated static func normalizeIPAddress(_ raw: String) -> String {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.hasPrefix("[") && token.hasSuffix("]") {
            token = String(token.dropFirst().dropLast())
        }
        if let pct = token.firstIndex(of: "%") {
            token = String(token[..<pct])
        }
        return token.lowercased()
    }

    private func shouldReplaceMetadataValue(existing: String?, candidate: String?) -> Bool {
        guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty else {
            return false
        }

        guard let existing = existing?.trimmingCharacters(in: .whitespacesAndNewlines),
              !existing.isEmpty else {
            return true
        }

        return candidate.count > existing.count
    }

    private func shouldReplaceOSVersion(existing: String?, candidate: String?) -> Bool {
        guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty else {
            return false
        }

        guard let existing = existing?.trimmingCharacters(in: .whitespacesAndNewlines),
              !existing.isEmpty else {
            return true
        }

        let comparison = compareVersionString(candidate, existing)
        if comparison != .orderedSame {
            return comparison == .orderedDescending
        }
        return candidate.count > existing.count
    }

    private func compareVersionString(_ lhs: String, _ rhs: String) -> ComparisonResult {
        guard let lhsComponents = parsedVersionComponents(lhs),
              let rhsComponents = parsedVersionComponents(rhs) else {
            return .orderedSame
        }

        let count = max(lhsComponents.count, rhsComponents.count)
        for index in 0..<count {
            let lhsValue = index < lhsComponents.count ? lhsComponents[index] : 0
            let rhsValue = index < rhsComponents.count ? rhsComponents[index] : 0
            if lhsValue < rhsValue { return .orderedAscending }
            if lhsValue > rhsValue { return .orderedDescending }
        }
        return .orderedSame
    }

    private func parsedVersionComponents(_ raw: String) -> [Int]? {
        guard let range = raw.range(
            of: "[0-9]+(?:\\.[0-9]+)*",
            options: [.regularExpression]
        ) else {
            return nil
        }

        let token = raw[range]
        let components = token.split(separator: ".").compactMap { Int($0) }
        return components.isEmpty ? nil : components
    }

    private func metadataRichnessScore(for candidate: DiscoveredDevice) -> Int {
        var score = 0
        if candidate.osVersion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { score += 220 }
        if candidate.modelName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { score += 160 }
        if candidate.chip?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { score += 120 }
        if candidate.platformName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { score += 90 }
        return score
    }

    private nonisolated static func extractIPComponents(fromNormalizedPeerId peerId: String) -> (ipv4: String?, ipv6: String?) {
        guard peerId.hasPrefix("peer:") else { return (nil, nil) }
        let host = String(peerId.dropFirst("peer:".count))
        if host.contains(":") {
            return (nil, host)
        }
        let segments = host.split(separator: ".")
        if segments.count == 4, segments.allSatisfy({ Int($0) != nil }) {
            return (host, nil)
        }
        return (nil, nil)
    }

    private nonisolated static func isSyntheticPeerDisplayName(_ displayName: String) -> Bool {
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("peer:")
    }

    private nonisolated static func syntheticPeerHost(fromDisplayName displayName: String) -> String? {
        guard isSyntheticPeerDisplayName(displayName) else { return nil }
        let normalizedPeerId = normalizedPeerIdentifier(displayName)
        let extracted = extractIPComponents(fromNormalizedPeerId: normalizedPeerId)
        if let ipv6 = extracted.ipv6 { return normalizeIPAddress(ipv6) }
        if let ipv4 = extracted.ipv4 { return normalizeIPAddress(ipv4) }
        return nil
    }

    private static func preferredRecentDevice(_ lhs: OnlineDevice, _ rhs: OnlineDevice) -> OnlineDevice {
        if lhs.connectionStatus.priority != rhs.connectionStatus.priority {
            return lhs.connectionStatus.priority > rhs.connectionStatus.priority ? lhs : rhs
        }
        let lhsConnected = lhs.lastConnectedAt ?? .distantPast
        let rhsConnected = rhs.lastConnectedAt ?? .distantPast
        if lhsConnected != rhsConnected {
            return lhsConnected > rhsConnected ? lhs : rhs
        }
        return lhs.lastSeen >= rhs.lastSeen ? lhs : rhs
    }

    nonisolated static func shouldCollapseRecentDevice(
        _ recent: OnlineDevice,
        against candidates: [OnlineDevice]
    ) -> Bool {
        guard let normalizedRecent = normalizedRecentIdentifier(from: recent.uniqueIdentifier) else {
            return false
        }
        let recentPeerId = String(normalizedRecent.dropFirst("recent:".count))
        let normalizedRecentName = normalizedDedupeName(recent.name)

        return candidates.contains { candidate in
            guard candidate.id != recent.id else { return false }
            guard normalizedRecentIdentifier(from: candidate.uniqueIdentifier) == nil else { return false }
            guard candidateRepresentsRecentPeer(
                candidate,
                recentPeerId: recentPeerId,
                normalizedRecentName: normalizedRecentName
            ) else {
                return false
            }

            return candidate.isConnectable
                || candidate.connectionStatus != .offline
                || candidate.lastConnectedAt != nil
                || candidate.isAuthorized
                || Self.identifierStrength(candidate.uniqueIdentifier) > Self.identifierStrength(recent.uniqueIdentifier)
        }
    }

    private nonisolated static func candidateRepresentsRecentPeer(
        _ candidate: OnlineDevice,
        recentPeerId: String,
        normalizedRecentName: String
    ) -> Bool {
        let aliases = normalizedPeerAliases(for: candidate)
        if aliases.contains(recentPeerId) {
            return true
        }

        if !normalizedRecentName.isEmpty,
           normalizedDedupeName(candidate.name) == normalizedRecentName,
           Self.identifierStrength(candidate.uniqueIdentifier) >= 440 {
            return true
        }

        return false
    }

    private nonisolated static func normalizedPeerAliases(for device: OnlineDevice) -> Set<String> {
        var aliases: Set<String> = []
        let uniqueIdentifier = stripRecentIdentifierPrefix(from: device.uniqueIdentifier)

        if let stableId = normalizedStableIdentifierPayload(from: device.uniqueIdentifier) {
            aliases.insert(normalizedPeerIdentifier(stableId))
        }

        if uniqueIdentifier.hasPrefix("bonjour:") {
            aliases.insert(normalizedPeerIdentifier(uniqueIdentifier))
        }

        for routeIdentifier in device.routeIdentifiers {
            let trimmed = routeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("bonjour:") || trimmed.hasPrefix("recent:bonjour:") {
                aliases.insert(normalizedPeerIdentifier(trimmed))
            } else if let payload = peerHostPayload(from: trimmed) {
                let normalized = normalizePeerHostToken(payload)
                if !normalized.isEmpty {
                    aliases.insert("peer:\(normalized)")
                }
            }
        }

        if let payload = peerHostPayload(from: uniqueIdentifier) {
            let normalized = normalizePeerHostToken(payload)
            if !normalized.isEmpty {
                aliases.insert("peer:\(normalized)")
            }
        }

        if let ipv4 = device.ipv4 {
            let normalized = normalizePeerHostToken(ipv4)
            if !normalized.isEmpty {
                aliases.insert("peer:\(normalized)")
            }
        }

        if let ipv6 = device.ipv6 {
            let normalized = normalizePeerHostToken(ipv6)
            if !normalized.isEmpty {
                aliases.insert("peer:\(normalized)")
            }
        }

        return aliases
    }

    private nonisolated static func normalizedPeerAliases(for device: DiscoveredDevice) -> Set<String> {
        var aliases: Set<String> = []

        if let stableId = normalizeStableIdentifier(device.deviceId) {
            aliases.insert(normalizedPeerIdentifier(stableId))
        }

        if let uniqueIdentifier = device.uniqueIdentifier {
            let trimmed = stripRecentIdentifierPrefix(from: uniqueIdentifier)
            if trimmed.hasPrefix("bonjour:") {
                aliases.insert(normalizedPeerIdentifier(trimmed))
            } else if let payload = peerHostPayload(from: trimmed) {
                let normalized = normalizePeerHostToken(payload)
                if !normalized.isEmpty {
                    aliases.insert("peer:\(normalized)")
                }
            }
        }

        for routeIdentifier in device.routeIdentifiers {
            let trimmed = routeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("bonjour:") || trimmed.hasPrefix("recent:bonjour:") {
                aliases.insert(normalizedPeerIdentifier(trimmed))
            } else if let payload = peerHostPayload(from: trimmed) {
                let normalized = normalizePeerHostToken(payload)
                if !normalized.isEmpty {
                    aliases.insert("peer:\(normalized)")
                }
            }
        }

        if let ipv4 = device.ipv4 {
            let normalized = normalizePeerHostToken(ipv4)
            if !normalized.isEmpty {
                aliases.insert("peer:\(normalized)")
            }
        }

        if let ipv6 = device.ipv6 {
            let normalized = normalizePeerHostToken(ipv6)
            if !normalized.isEmpty {
                aliases.insert("peer:\(normalized)")
            }
        }

        return aliases
    }

    private nonisolated static func peerHostPayload(from identifier: String) -> String? {
        let identifier = stripRecentIdentifierPrefix(from: identifier)
        for prefix in ["ip:", "host:", "peer:"] where identifier.hasPrefix(prefix) {
            let payload = String(identifier.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return payload.isEmpty ? nil : payload
        }
        return nil
    }

    private nonisolated static func stripRecentIdentifierPrefix(from identifier: String) -> String {
        var value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.lowercased().hasPrefix("recent:") {
            value = String(value.dropFirst("recent:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private nonisolated static func normalizedStableIdentifierPayload(from uniqueIdentifier: String) -> String? {
        let uniqueIdentifier = stripRecentIdentifierPrefix(from: uniqueIdentifier)
        guard uniqueIdentifier.hasPrefix("id:") else { return nil }
        let payload = String(uniqueIdentifier.dropFirst("id:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? nil : payload
    }

    private nonisolated static func routeIdentifiers(from raw: String?) -> [String] {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return []
        }
        guard hasUsableBonjourRouteIdentifier(raw) else {
            return []
        }
        return [raw]
    }

    private nonisolated static func hasUsableBonjourRouteIdentifier(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let normalized = trimmed.lowercased()
        guard normalized.hasPrefix("bonjour:") || normalized.hasPrefix("recent:bonjour:") else {
            return false
        }
        guard let serviceName = P2PDiscoveryBonjourPolicy.extractBonjourServiceName(fromIdentifier: trimmed) else {
            return false
        }
        return !P2PDiscoveryBonjourPolicy.sanitizedBonjourServiceName(serviceName).isEmpty
    }

    private nonisolated static func mergedRouteIdentifiers(
        _ lhs: [String],
        _ rhs: [String]
    ) -> [String] {
        var merged: [String] = []
        var seen = Set<String>()
        for routeIdentifier in lhs + rhs {
            let trimmed = routeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            merged.append(trimmed)
        }
        return merged
    }

    private nonisolated static func normalizedConnectionPeerAliases(for raw: String?) -> Set<String> {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return []
        }

        var aliases = normalizedStableConnectionAliases(for: raw)
        aliases.insert(normalizedPeerIdentifier(raw))

        if let hostPayload = peerHostPayload(from: raw) {
            let normalized = normalizePeerHostToken(hostPayload)
            if !normalized.isEmpty {
                aliases.insert("peer:\(normalized)")
            }
        }

        let extracted = extractIPComponents(fromNormalizedPeerId: normalizedPeerIdentifier(raw))
        if let ipv4 = extracted.ipv4 {
            aliases.insert("peer:\(normalizeIPAddress(ipv4))")
        }
        if let ipv6 = extracted.ipv6 {
            aliases.insert("peer:\(normalizeIPAddress(ipv6))")
        }

        return aliases
    }

    private nonisolated static func normalizedStableConnectionAliases(for raw: String?) -> Set<String> {
        guard let payload = normalizeStableIdentifier(raw) else { return [] }
        return Set(
            [
                "id:\(payload)",
                payload
            ].map(normalizedPeerIdentifier)
        )
    }

    private nonisolated static func normalizedStableConnectionAliases(
        fromUniqueIdentifier uniqueIdentifier: String
    ) -> Set<String> {
        guard let payload = normalizedStableIdentifierPayload(from: uniqueIdentifier) else { return [] }
        return Set(
            [
                "id:\(payload)",
                payload
            ].map(normalizedPeerIdentifier)
        )
    }

    private nonisolated static func normalizedDedupeName(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

 /// 更新设备列表
    private func updateDevicesList() {
        let now = Date()

 // 获取所有唯一设备
        var uniqueDevices: [OnlineDevice] = []
        var processedIds = Set<UUID>()

        for device in deviceMap.values {
            if !processedIds.contains(device.id) {
                uniqueDevices.append(device)
                processedIds.insert(device.id)
            }
        }

        // Collapse noisy "recent:<peer>" duplicates produced by ephemeral endpoint forms.
        var normalDevices: [OnlineDevice] = []
        var recentByNormalizedId: [String: OnlineDevice] = [:]
        for device in uniqueDevices {
            if let normalizedRecentId = Self.normalizedRecentIdentifier(from: device.uniqueIdentifier) {
                if let existing = recentByNormalizedId[normalizedRecentId] {
                    recentByNormalizedId[normalizedRecentId] = Self.preferredRecentDevice(existing, device)
                } else {
                    recentByNormalizedId[normalizedRecentId] = device
                }
            } else {
                normalDevices.append(device)
            }
        }

        let collapsedRecentDevices = recentByNormalizedId.values.filter { recent in
            !Self.shouldCollapseRecentDevice(recent, against: normalDevices)
        }
        let coalesced = coalesceEquivalentPhysicalDevices(normalDevices + collapsedRecentDevices)
        uniqueDevices = coalesced.devices
        uniqueDevices = Self.filterShadowedAppleMobileLinkLocalRoutes(uniqueDevices)

        // Rewrite aliases for coalesced devices back to the winning row. This keeps stale
        // persisted identities from resurfacing as separate "recent" rows on the next refresh.
        deviceMap = deviceMap.reduce(into: [:]) { result, element in
            guard let replacement = coalesced.replacementByOriginalId[element.value.id] else { return }
            result[element.key] = replacement
            result[replacement.uniqueIdentifier] = replacement
        }

        // Update device status:
        // - Preserve "connected" for active secure sessions (ConnectionPresenceService)
        // - Otherwise fall back to lastSeen heuristics
        let activeConnectionSnapshots: [(id: String, displayName: String, address: String?)] = {
            if #available(macOS 14.0, iOS 17.0, *) {
                return ConnectionPresenceService.shared.activeConnections.map { connection in
                    (id: connection.id, displayName: connection.displayName, address: connection.address)
                }
            }
            return []
        }()
        let activePeerIds = Set(activeConnectionSnapshots.map(\.id))
        let normalizedActivePeerIds = Set(activePeerIds.map(Self.normalizedPeerIdentifier))
        let normalizedActiveDisplayNames = Set(
            activeConnectionSnapshots.map { normalizeDeviceName($0.displayName) }.filter { !$0.isEmpty }
        )

        func normalizedPresenceAddress(_ raw: String?) -> String? {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }
            let token = Self.normalizePeerHostToken(raw)
            return token.isEmpty ? nil : token
        }

        let normalizedActiveAddresses = Set(activeConnectionSnapshots.compactMap { connection in
            if let normalizedAddress = normalizedPresenceAddress(connection.address) {
                return normalizedAddress
            }
            let normalizedPeerId = Self.normalizedPeerIdentifier(connection.id)
            let extracted = Self.extractIPComponents(fromNormalizedPeerId: normalizedPeerId)
            if let ipv4 = extracted.ipv4 { return Self.normalizeIPAddress(ipv4) }
            if let ipv6 = extracted.ipv6 { return Self.normalizeIPAddress(ipv6) }
            return nil
        })

        func isActivelyConnected(_ device: OnlineDevice) -> Bool {
            // Our inbound "recently connected" records use uniqueIdentifier: "recent:<peerId>"
            if let normalizedRecent = Self.normalizedRecentIdentifier(from: device.uniqueIdentifier) {
                let peerId = String(normalizedRecent.dropFirst("recent:".count))
                if normalizedActivePeerIds.contains(peerId) {
                    return true
                }
            }

            if device.uniqueIdentifier.hasPrefix("bonjour:"),
               normalizedActivePeerIds.contains(Self.normalizedPeerIdentifier(device.uniqueIdentifier)) {
                return true
            }

            let stableAliases = Self.normalizedStableConnectionAliases(fromUniqueIdentifier: device.uniqueIdentifier)
            if !stableAliases.isEmpty,
               !stableAliases.isDisjoint(with: normalizedActivePeerIds) {
                return true
            }

            let routeAliases = Self.normalizedPeerAliases(for: device)
            if !routeAliases.isEmpty,
               !routeAliases.isDisjoint(with: normalizedActivePeerIds) {
                return true
            }

            let normalizedDeviceAddresses = Set([device.ipv4, device.ipv6].compactMap { normalizedPresenceAddress($0) })
            if !normalizedDeviceAddresses.isEmpty,
               !normalizedDeviceAddresses.isDisjoint(with: normalizedActiveAddresses) {
                return true
            }

            if device.uniqueIdentifier.hasPrefix("ip:") {
                let payload = String(device.uniqueIdentifier.dropFirst("ip:".count))
                let normalizedIdentifierIP = Self.normalizeIPAddress(payload)
                if !normalizedIdentifierIP.isEmpty,
                   normalizedActiveAddresses.contains(normalizedIdentifierIP) {
                    return true
                }
            }

            let normalizedName = normalizeDeviceName(device.name)
            if !normalizedName.isEmpty && normalizedActiveDisplayNames.contains(normalizedName) {
                return true
            }

            return false
        }

        // 更新设备状态（论文口径）:
        // connected 仅由 "活跃会话存在（握手完成）" 驱动，不再使用 UI lease 推断。
        for i in 0..<uniqueDevices.count {
            let device = uniqueDevices[i]
            if Self.isCloudHeartbeatOnly(uniqueDevices[i]) {
                uniqueDevices[i].isConnectable = false
            }
            let usbAttached = isActivelyAttachedOverUSB(device)
            if usbAttached {
                uniqueDevices[i].lastSeen = now
            }
            if uniqueDevices[i].isConnectable,
               !Self.hasFreshConnectableControlRouteSource(uniqueDevices[i], newestSeen: now) {
                uniqueDevices[i].isConnectable = false
            }
            let timeSinceLastSeen = now.timeIntervalSince(uniqueDevices[i].lastSeen)

 // 判断设备状态
            if device.isLocalDevice {
                uniqueDevices[i].connectionStatus = .online
                uniqueDevices[i].lastSeen = now
            } else if isActivelyConnected(device) {
                uniqueDevices[i].connectionStatus = .connected
                uniqueDevices[i].lastSeen = now
                if uniqueDevices[i].lastConnectedAt == nil {
                    uniqueDevices[i].lastConnectedAt = now
                }
                if uniqueDevices[i].guardStatus == nil {
                    uniqueDevices[i].guardStatus = "守护中"
                }
            } else if usbAttached {
                uniqueDevices[i].connectionStatus = .online
            } else if timeSinceLastSeen < 60 {
 // 60秒内有响应,认为在线
                uniqueDevices[i].connectionStatus = .online
            } else if device.sources.contains(.skybridgeCloud), timeSinceLastSeen < 120 {
 // iCloud KVS heartbeat is eventually consistent; keep its online TTL aligned with the KVS discovery timeout.
                uniqueDevices[i].connectionStatus = .online
            } else if device.lastConnectedAt != nil || device.isAuthorized {
 // 有连接历史或已授权,但当前不在线
                uniqueDevices[i].connectionStatus = .offline
            } else {
 // 长时间未见,标记为离线
                uniqueDevices[i].connectionStatus = .offline
            }
        }

        let nonSyntheticHosts: Set<String> = Set(
            uniqueDevices.compactMap { device in
                guard !Self.isSyntheticPeerDisplayName(device.name) else { return nil }
                if let ipv6 = device.ipv6 { return Self.normalizeIPAddress(ipv6) }
                if let ipv4 = device.ipv4 { return Self.normalizeIPAddress(ipv4) }
                return nil
            }
        )
        let settings = SettingsManager.shared

 // 过滤设备:
 // 1. 本机(始终显示)
 // 2. 在线设备
 // 3. 最近60秒内出现的设备
 // 4. 有连接历史的设备
 // 5. 已授权的设备
        let filteredDevices = uniqueDevices.filter { device in
            if Self.isSyntheticPeerDisplayName(device.name) {
                // 历史 peer:* 只在当前确实连接且没有可替代实体时保留，避免列表噪声。
                guard device.connectionStatus == .connected else { return false }
                if let host = Self.syntheticPeerHost(fromDisplayName: device.name),
                   nonSyntheticHosts.contains(host) {
                    return false
                }
            }

            let keepForRecency = device.isLocalDevice ||
                device.connectionStatus == .online ||
                device.connectionStatus == .connected ||
                now.timeIntervalSince(device.lastSeen) < 60 ||
                device.lastConnectedAt != nil ||
                device.isAuthorized

            guard keepForRecency else { return false }
            if settings.hideOfflineDevices, !device.isLocalDevice, device.connectionStatus == .offline {
                return false
            }
            if settings.showConnectableDevicesOnly, !device.isLocalDevice, !device.isConnectable {
                return false
            }
            if let signalStrength = device.signalStrength,
               signalStrength < 0,
               signalStrength < settings.minimumSignalStrength {
                return false
            }
            return true
        }
        let routeShadowFilteredDevices = Self.filterShadowedAppleMobileLinkLocalRoutes(filteredDevices)

 // 排序: 本机 > 已连接 > 在线 > 离线
        let sortedDevices = routeShadowFilteredDevices.sorted { lhs, rhs in
            if lhs.isLocalDevice != rhs.isLocalDevice {
                return lhs.isLocalDevice
            }

            if lhs.connectionStatus != rhs.connectionStatus {
                return lhs.connectionStatus.priority > rhs.connectionStatus.priority
            }

            return lhs.name < rhs.name
        }

        let optimizeMemory = SettingsManager.shared.optimizeMemoryUsage
        onlineDevices = optimizeMemory ? Array(sortedDevices.prefix(120)) : sortedDevices

// 更新统计
        updateDeviceStats()

        logger.debug("📊 设备列表更新: \(self.onlineDevices.count) 台在线")
    }

 /// 更新设备统计
    private func updateDeviceStats() {
        deviceStats = DeviceStats(
            total: onlineDevices.count,
            online: onlineDevices.filter { $0.connectionStatus == .online || $0.connectionStatus == .connected }.count,
            connected: onlineDevices.filter { $0.connectionStatus == .connected }.count,
            authorized: onlineDevices.filter { $0.isAuthorized }.count
        )
    }

    private func coalesceEquivalentPhysicalDevices(
        _ devices: [OnlineDevice]
    ) -> (devices: [OnlineDevice], replacementByOriginalId: [UUID: OnlineDevice]) {
        guard devices.count > 1 else {
            let replacements = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
            return (devices, replacements)
        }

        var parent = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.id) })
        let trustAliasRecords = TrustSyncService.shared.activeTrustRecords.filter { !$0.isTombstone }
        let trustAliasCandidateSets: [Set<String>] = trustAliasRecords.compactMap { record in
            let candidates = Set(
                PeerTrustLookup.recordLookupCandidates(record).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }.filter { !$0.isEmpty }
            )
            return candidates.isEmpty ? nil : candidates
        }
        let deviceTrustCandidatesById = Dictionary(uniqueKeysWithValues: devices.map { device in
            (device.id, Self.deviceTrustLookupCandidates(for: device))
        })
        let hardTokensById = Dictionary(uniqueKeysWithValues: devices.map { device in
            (device.id, Self.hardIdentityTokensByKind(for: device))
        })
        let peerAliasesById = Dictionary(uniqueKeysWithValues: devices.map { device in
            (device.id, Self.normalizedPeerAliases(for: device))
        })

        func find(_ id: UUID) -> UUID {
            var current = id
            while let next = parent[current], next != current {
                current = next
            }
            return current
        }

        func union(_ lhs: UUID, _ rhs: UUID) {
            let lhsRoot = find(lhs)
            let rhsRoot = find(rhs)
            guard lhsRoot != rhsRoot else { return }
            parent[rhsRoot] = lhsRoot
        }

        for lhsIndex in devices.indices {
            let lhsDevice = devices[lhsIndex]
            let lhsHard = hardTokensById[lhsDevice.id] ?? [:]
            let lhsNetwork = peerAliasesById[lhsDevice.id] ?? []
            for rhsIndex in devices.index(after: lhsIndex)..<devices.endIndex {
                let rhsDevice = devices[rhsIndex]
                if Self.shouldCoalesceEquivalentPhysicalDevices(
                    lhsDevice,
                    rhsDevice,
                    lhsHard: lhsHard,
                    rhsHard: hardTokensById[rhsDevice.id] ?? [:],
                    lhsNetwork: lhsNetwork,
                    rhsNetwork: peerAliasesById[rhsDevice.id] ?? []
                )
                    || shouldCoalesceTrustedAliasDevices(
                        lhsDevice,
                        rhsDevice,
                        deviceTrustCandidatesById: deviceTrustCandidatesById,
                        trustRecordCandidateSets: trustAliasCandidateSets
                    ) {
                    union(lhsDevice.id, rhsDevice.id)
                }
            }
        }

        var groups: [UUID: [OnlineDevice]] = [:]
        for device in devices {
            groups[find(device.id), default: []].append(device)
        }

        var replacements: [UUID: OnlineDevice] = [:]
        let mergedDevices = groups.values.map { group in
            let merged = mergeEquivalentDeviceGroup(group)
            for device in group {
                replacements[device.id] = merged
            }
            return merged
        }

        return (mergedDevices, replacements)
    }

    private nonisolated static func filterShadowedAppleMobileLinkLocalRoutes(
        _ devices: [OnlineDevice]
    ) -> [OnlineDevice] {
        guard devices.count > 1 else { return devices }

        return devices.filter { candidate in
            guard !candidate.isLocalDevice,
                  candidate.connectionStatus != .connected,
                  isShadowableAppleMobileStaleRoute(candidate) else {
                return true
            }

            return !devices.contains { other in
                other.id != candidate.id
                    && shouldPreferAppleMobileRoutableRoute(other, over: candidate)
            }
        }
    }

    private nonisolated static func shouldPreferAppleMobileRoutableRoute(
        _ preferred: OnlineDevice,
        over stale: OnlineDevice
    ) -> Bool {
        guard !preferred.isLocalDevice,
              preferred.connectionStatus != .offline,
              hasDirectSkyBridgeControlRoute(preferred),
              appleMobileRouteShadowMetadataMatches(preferred, stale) else {
            return false
        }

        return true
    }

    private nonisolated static func isShadowableAppleMobileStaleRoute(
        _ device: OnlineDevice
    ) -> Bool {
        guard isAppleMobilePresentation(device),
              !hasDirectSkyBridgeControlRoute(device) else {
            return false
        }

        if device.sources.allSatisfy({ $0 == .skybridgeCloud }) {
            return true
        }
        if hasSkyBridgeControlHint(services: device.services, portMap: device.portMap) {
            return true
        }
        return false
    }

    private nonisolated static func appleMobileRouteShadowMetadataMatches(
        _ lhs: OnlineDevice,
        _ rhs: OnlineDevice
    ) -> Bool {
        guard isAppleMobilePresentation(lhs), isAppleMobilePresentation(rhs) else { return false }
        guard appleModelMetadataCompatible(lhs.modelName, rhs.modelName),
              applePlatformMetadataCompatible(lhs.platformName, rhs.platformName) else {
            return false
        }

        let lhsFamily = appleDeviceFamilyToken(preferredValues: [lhs.modelName, lhs.name, lhs.platformName])
        let rhsFamily = appleDeviceFamilyToken(preferredValues: [rhs.modelName, rhs.name, rhs.platformName])
        guard let family = lhsFamily, family == rhsFamily else { return false }

        if hasDirectSkyBridgeControlRoute(lhs),
           hasExplicitOnlyNonConnectableAddress(rhs) {
            return true
        }

        return namesRepresentSameDevice(lhs.name, rhs.name)
            || appleMobileNamesShareFamilyAlias(lhs.name, rhs.name, family: family)
    }

    private func mergeEquivalentDeviceGroup(_ group: [OnlineDevice]) -> OnlineDevice {
        guard var merged = group.sorted(by: shouldPreferCoalescedDevice).first else {
            fatalError("mergeEquivalentDeviceGroup requires at least one device")
        }

        for device in group where device.id != merged.id {
            merged = mergeDeviceInfo(existing: merged, new: device)
        }

        if let strongestIdentifier = group
            .map(\.uniqueIdentifier)
            .max(by: { Self.identifierStrength($0) < Self.identifierStrength($1) }),
           Self.identifierStrength(strongestIdentifier) > Self.identifierStrength(merged.uniqueIdentifier),
           strongestIdentifier != merged.uniqueIdentifier {
            merged = Self.copyDevice(merged, uniqueIdentifier: strongestIdentifier)
        }

        if let liveStableIdentifier = preferredLiveStableIdentifier(for: group) {
            if liveStableIdentifier != merged.uniqueIdentifier {
                merged = Self.copyDevice(merged, uniqueIdentifier: liveStableIdentifier)
            }
        } else if let trustedStableIdentifier = preferredTrustedStableIdentifier(for: group),
                  trustedStableIdentifier != merged.uniqueIdentifier {
            merged = Self.copyDevice(merged, uniqueIdentifier: trustedStableIdentifier)
        }

        if group.contains(where: { $0.connectionStatus == .connected }) {
            merged.connectionStatus = .connected
        } else if group.contains(where: { $0.connectionStatus == .online }) {
            merged.connectionStatus = .online
        } else {
            merged.connectionStatus = .offline
        }

        merged.lastSeen = group.map(\.lastSeen).max() ?? merged.lastSeen
        merged.lastConnectedAt = group.compactMap(\.lastConnectedAt).max()
        merged.isAuthorized = group.contains(where: \.isAuthorized)
        let newestSeen = group.map(\.lastSeen).max() ?? merged.lastSeen
        merged.isConnectable = group.contains { device in
            Self.hasFreshConnectableControlRouteSource(device, newestSeen: newestSeen)
        }
        merged.isLocalDevice = group.contains(where: \.isLocalDevice)

        if let newestCryptoSource = group
            .filter({ $0.lastCryptoKind != nil || $0.lastCryptoSuite != nil || $0.guardStatus != nil })
            .max(by: { ($0.lastConnectedAt ?? $0.lastSeen) < ($1.lastConnectedAt ?? $1.lastSeen) }) {
            merged.lastCryptoKind = newestCryptoSource.lastCryptoKind ?? merged.lastCryptoKind
            merged.lastCryptoSuite = newestCryptoSource.lastCryptoSuite ?? merged.lastCryptoSuite
            merged.guardStatus = newestCryptoSource.guardStatus ?? merged.guardStatus
        }
        merged.name = Self.bestDisplayName(for: group + [merged])

        return merged
    }

    private func preferredTrustedStableIdentifier(for group: [OnlineDevice]) -> String? {
        let groupCandidates = Set(
            group.flatMap { Self.deviceTrustLookupCandidates(for: $0) }
        )
        guard !groupCandidates.isEmpty else { return nil }

        let matchingRecords = TrustSyncService.shared.activeTrustRecords
            .filter { !$0.isTombstone && !$0.isExpired }
            .filter { record in
                let recordCandidates = Set(
                    PeerTrustLookup.recordLookupCandidates(record).map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    }
                )
                return !recordCandidates.isEmpty && !recordCandidates.isDisjoint(with: groupCandidates)
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.deviceId < rhs.deviceId
            }

        for record in matchingRecords {
            if let stable = Self.canonicalStableIdentifierToken(record.currentDeviceIdMetadata)
                ?? Self.canonicalStableIdentifierToken(record.deviceId) {
                return stable
            }
        }
        return nil
    }

    private func preferredLiveStableIdentifier(for group: [OnlineDevice]) -> String? {
        let ranked = group.compactMap { device -> (identifier: String, score: Int, lastSeen: Date)? in
            guard let identifier = Self.canonicalStableIdentifierToken(device.uniqueIdentifier),
                  Self.isProtocolStableIdentifierToken(identifier),
                  !Self.isCloudHeartbeatOnly(device) else {
                return nil
            }

            var score = 0
            if device.connectionStatus == .connected {
                score += 80
            } else if device.connectionStatus == .online {
                score += 60
            }
            if device.isConnectable { score += 20 }
            if device.sources.contains(.skybridgeBonjour) { score += 12 }
            if device.sources.contains(.skybridgeP2P) { score += 10 }
            if device.sources.contains(.skybridgeUSB) { score += 8 }
            if Self.hasDirectSkyBridgeControlRoute(device) { score += 6 }
            if normalizeFingerprint(device.protocolFingerprint) != nil { score += 100 }
            guard score > 0 else { return nil }
            return (identifier, score, device.lastSeen)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
            return lhs.identifier < rhs.identifier
        }

        return ranked.first?.identifier
    }

    private nonisolated static func isProtocolStableIdentifierToken(_ identifier: String) -> Bool {
        guard let payload = normalizedStableIdentifierPayload(from: identifier) else { return false }
        let normalizedPayload = payload.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedPayload.isEmpty else { return false }
        return !normalizedPayload.hasPrefix("serial:")
            && !normalizedPayload.hasPrefix("mac:")
            && !normalizedPayload.hasPrefix("ip:")
            && !normalizedPayload.hasPrefix("name:")
            && !normalizedPayload.hasPrefix("bonjour:")
    }

    private nonisolated static func canonicalStableIdentifierToken(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if value.lowercased().hasPrefix("id:") {
            value = String(value.dropFirst("id:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizeStableIdentifier(value) != nil else { return nil }
            return "id:\(value)"
        }
        guard let stable = normalizeStableIdentifier(value) else { return nil }
        return "id:\(stable)"
    }

    private func shouldCoalesceTrustedAliasDevices(
        _ lhs: OnlineDevice,
        _ rhs: OnlineDevice,
        deviceTrustCandidatesById: [UUID: Set<String>],
        trustRecordCandidateSets: [Set<String>]
    ) -> Bool {
        guard !trustRecordCandidateSets.isEmpty else { return false }
        let lhsCandidates = deviceTrustCandidatesById[lhs.id] ?? []
        let rhsCandidates = deviceTrustCandidatesById[rhs.id] ?? []
        guard !lhsCandidates.isEmpty, !rhsCandidates.isEmpty else { return false }

        for recordCandidates in trustRecordCandidateSets {
            if !lhsCandidates.isDisjoint(with: recordCandidates),
               !rhsCandidates.isDisjoint(with: recordCandidates) {
                return true
            }
        }
        return false
    }

    private nonisolated static func deviceTrustLookupCandidates(for device: OnlineDevice) -> Set<String> {
        var candidates = Set<String>()

        func appendCandidates(from raw: String?) {
            for candidate in PeerTrustLookup.lookupCandidates(for: raw) {
                let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !normalized.isEmpty {
                    candidates.insert(normalized)
                }
            }
        }

        appendCandidates(from: device.uniqueIdentifier)
        appendCandidates(from: device.ipv4)
        appendCandidates(from: device.ipv6)
        appendCandidates(from: device.serialNumber)
        appendCandidates(from: device.macAddress)
        for routeIdentifier in device.routeIdentifiers {
            appendCandidates(from: routeIdentifier)
        }
        return candidates
    }

    private func shouldPreferCoalescedDevice(_ lhs: OnlineDevice, _ rhs: OnlineDevice) -> Bool {
        if lhs.connectionStatus.priority != rhs.connectionStatus.priority {
            return lhs.connectionStatus.priority > rhs.connectionStatus.priority
        }
        let lhsStrength = Self.identifierStrength(lhs.uniqueIdentifier)
        let rhsStrength = Self.identifierStrength(rhs.uniqueIdentifier)
        if lhsStrength != rhsStrength {
            return lhsStrength > rhsStrength
        }
        if lhs.isConnectable != rhs.isConnectable {
            return lhs.isConnectable
        }
        let lhsConnected = lhs.lastConnectedAt ?? .distantPast
        let rhsConnected = rhs.lastConnectedAt ?? .distantPast
        if lhsConnected != rhsConnected {
            return lhsConnected > rhsConnected
        }
        if lhs.lastSeen != rhs.lastSeen {
            return lhs.lastSeen > rhs.lastSeen
        }
        let lhsNameScore = Self.displayNameQualityScore(lhs.name)
        let rhsNameScore = Self.displayNameQualityScore(rhs.name)
        if lhsNameScore != rhsNameScore {
            return lhsNameScore > rhsNameScore
        }
        return lhs.name.count >= rhs.name.count
    }

    nonisolated static func shouldCoalesceEquivalentPhysicalDevices(
        _ lhs: OnlineDevice,
        _ rhs: OnlineDevice
    ) -> Bool {
        guard lhs.id != rhs.id else { return true }
        guard !lhs.isLocalDevice, !rhs.isLocalDevice else { return false }

        return shouldCoalesceEquivalentPhysicalDevices(
            lhs,
            rhs,
            lhsHard: hardIdentityTokensByKind(for: lhs),
            rhsHard: hardIdentityTokensByKind(for: rhs),
            lhsNetwork: normalizedPeerAliases(for: lhs),
            rhsNetwork: normalizedPeerAliases(for: rhs)
        )
    }

    nonisolated static func shouldCoalesceEquivalentPhysicalDevices(
        _ lhs: OnlineDevice,
        _ rhs: OnlineDevice,
        lhsHard: [String: Set<String>],
        rhsHard: [String: Set<String>],
        lhsNetwork: Set<String>,
        rhsNetwork: Set<String>
    ) -> Bool {
        guard lhs.id != rhs.id else { return true }
        guard !lhs.isLocalDevice, !rhs.isLocalDevice else { return false }

        var hasSharedHardIdentityMatch = false
        var hasStableIdentityConflict = false
        for kind in Set(lhsHard.keys).intersection(rhsHard.keys) {
            if lhsHard[kind]?.isDisjoint(with: rhsHard[kind] ?? []) == false {
                hasSharedHardIdentityMatch = true
            } else {
                if kind == "stable" {
                    hasStableIdentityConflict = true
                    continue
                }
                return false
            }
        }
        if hasSharedHardIdentityMatch {
            return true
        }
        if hasStableIdentityConflict,
           shouldCoalesceRouteBoundLiveProtocolIdentity(lhs, rhs) {
            return true
        }
        if hasStableIdentityConflict {
            return false
        }

        let lhsLegacyCloudAliases = legacyCloudStableIdentityAliases(for: lhs)
        let rhsLegacyCloudAliases = legacyCloudStableIdentityAliases(for: rhs)
        if let rhsStable = rhsHard["stable"],
           !lhsLegacyCloudAliases.isEmpty,
           !lhsLegacyCloudAliases.isDisjoint(with: rhsStable) {
            return true
        }
        if let lhsStable = lhsHard["stable"],
           !rhsLegacyCloudAliases.isEmpty,
           !rhsLegacyCloudAliases.isDisjoint(with: lhsStable) {
            return true
        }

        if !lhsNetwork.isEmpty, !lhsNetwork.isDisjoint(with: rhsNetwork) {
            return true
        }

        if shouldAllowAppleMacServiceNameCoalescing(lhs, rhs) {
            return macNamesRepresentSameDevice(lhs.name, rhs.name)
        }

        guard shouldAllowAppleMobileNameCoalescing(lhs, rhs) else { return false }
        return namesRepresentSameDevice(lhs.name, rhs.name)
            || shouldAllowAppleMobileGenericPathAliasCoalescing(lhs, rhs)
    }

    private nonisolated static func shouldCoalesceRouteBoundLiveProtocolIdentity(
        _ lhs: OnlineDevice,
        _ rhs: OnlineDevice
    ) -> Bool {
        let lhsFingerprint = BonjourInteropContract.normalizedPubKeyFingerprint(lhs.protocolFingerprint)
        let rhsFingerprint = BonjourInteropContract.normalizedPubKeyFingerprint(rhs.protocolFingerprint)
        guard lhsFingerprint != nil || rhsFingerprint != nil else { return false }
        guard isAppleMobilePresentation(lhs), isAppleMobilePresentation(rhs) else { return false }
        guard appleModelMetadataCompatible(lhs.modelName, rhs.modelName),
              applePlatformMetadataCompatible(lhs.platformName, rhs.platformName) else {
            return false
        }
        return !routableBonjourRouteAliases(for: lhs).isDisjoint(with: routableBonjourRouteAliases(for: rhs))
    }

    private nonisolated static func routableBonjourRouteAliases(for device: OnlineDevice) -> Set<String> {
        Set(([device.uniqueIdentifier] + device.routeIdentifiers).compactMap { raw in
            guard P2PDiscoveryBonjourPolicy.isRoutableBonjourIdentifier(raw) else {
                return nil
            }
            return P2PDiscoveryBonjourPolicy.normalizeIdentifierForMatching(raw)
        })
    }

    private nonisolated static func hardIdentityTokensByKind(
        for device: OnlineDevice
    ) -> [String: Set<String>] {
        var tokens: [String: Set<String>] = [:]

        func insert(_ value: String?, kind: String) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !value.isEmpty else {
                return
            }
            tokens[kind, default: []].insert(value)
        }

        if let stableId = normalizedStableIdentifierPayload(from: device.uniqueIdentifier) {
            insert(stableId, kind: "stable")
        }
        if device.uniqueIdentifier.hasPrefix("fp:") {
            insert(String(device.uniqueIdentifier.dropFirst("fp:".count)), kind: "fingerprint")
        }
        if device.uniqueIdentifier.hasPrefix("serial:") {
            insert(
                credibleHardwareSerialToken(
                    String(device.uniqueIdentifier.dropFirst("serial:".count)),
                    for: device
                ),
                kind: "serial"
            )
        }
        if device.uniqueIdentifier.hasPrefix("mac:") {
            insert(String(device.uniqueIdentifier.dropFirst("mac:".count)), kind: "mac")
        }

        if let serial = credibleHardwareSerialNumber(from: device) {
            insert(serial, kind: "serial")
        }
        insert(device.macAddress, kind: "mac")
        return tokens
    }

    private nonisolated static func legacyCloudStableIdentityAliases(for device: OnlineDevice) -> Set<String> {
        guard device.sources.allSatisfy({ $0 == .skybridgeCloud }) else { return [] }
        var aliases: Set<String> = []

        func insert(_ raw: String?) {
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !value.isEmpty else {
                return
            }
            aliases.insert(value)
        }

        if device.uniqueIdentifier.hasPrefix("serial:") {
            insert(String(device.uniqueIdentifier.dropFirst("serial:".count)))
        }
        insert(device.serialNumber)
        return aliases
    }

    private nonisolated static func credibleHardwareSerialNumber(from device: OnlineDevice) -> String? {
        guard let serial = device.serialNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
              !serial.isEmpty else {
            return nil
        }
        return credibleHardwareSerialToken(serial, for: device)
    }

    private nonisolated static func credibleHardwareSerialToken(
        _ raw: String?,
        for device: OnlineDevice
    ) -> String? {
        guard let serial = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !serial.isEmpty else {
            return nil
        }
        if looksLikeAppleUSBDeviceIdentifier(serial) {
            return serial
        }
        if device.sources.contains(.skybridgeUSB),
           !device.sources.contains(.skybridgeCloud) {
            return serial
        }
        return nil
    }

    private nonisolated static func shouldAllowAppleMobileNameCoalescing(
        _ lhs: OnlineDevice,
        _ rhs: OnlineDevice
    ) -> Bool {
        guard isAppleMobilePresentation(lhs), isAppleMobilePresentation(rhs) else { return false }
        guard appleModelMetadataCompatible(lhs.modelName, rhs.modelName) else { return false }
        guard applePlatformMetadataCompatible(lhs.platformName, rhs.platformName) else { return false }

        return lhs.lastConnectedAt != nil
            || rhs.lastConnectedAt != nil
            || lhs.isAuthorized
            || rhs.isAuthorized
            || lhs.connectionStatus != .offline
            || rhs.connectionStatus != .offline
    }

    private nonisolated static func shouldAllowAppleMobileGenericPathAliasCoalescing(
        _ lhs: OnlineDevice,
        _ rhs: OnlineDevice
    ) -> Bool {
        let lhsFamily = appleDeviceFamilyToken(preferredValues: [lhs.modelName, lhs.name, lhs.platformName])
        let rhsFamily = appleDeviceFamilyToken(preferredValues: [rhs.modelName, rhs.name, rhs.platformName])
        guard let lhsFamily, lhsFamily == rhsFamily else { return false }

        let lhsGenericFamily = appleGenericDisplayNameFamily(lhs.name)
        let rhsGenericFamily = appleGenericDisplayNameFamily(rhs.name)
        guard lhsGenericFamily == lhsFamily || rhsGenericFamily == lhsFamily else { return false }
        guard appleMobileNamesShareFamilyAlias(lhs.name, rhs.name, family: lhsFamily) else { return false }

        let lhsHasNetworkRoute = hasSkyBridgeNetworkRoute(lhs)
        let rhsHasNetworkRoute = hasSkyBridgeNetworkRoute(rhs)
        let lhsHasNonNetworkPresence = hasAppleMobileNonNetworkPresence(lhs)
        let rhsHasNonNetworkPresence = hasAppleMobileNonNetworkPresence(rhs)

        return (lhsHasNetworkRoute && rhsHasNonNetworkPresence)
            || (rhsHasNetworkRoute && lhsHasNonNetworkPresence)
    }

    private nonisolated static func appleGenericDisplayNameFamily(_ raw: String) -> String? {
        switch normalizedDedupeName(raw) {
        case "ipad", "ipadair", "ipadpro", "ipadmini":
            return "ipad"
        case "iphone", "iphonepro", "iphonepromax", "iphonemini", "iphonese":
            return "iphone"
        default:
            return nil
        }
    }

    private nonisolated static func appleMobileNamesShareFamilyAlias(
        _ lhs: String,
        _ rhs: String,
        family: String
    ) -> Bool {
        let lhsName = normalizedDedupeName(lhs)
        let rhsName = normalizedDedupeName(rhs)
        guard !lhsName.isEmpty, !rhsName.isEmpty else { return false }
        if lhsName == rhsName { return true }
        let lhsGeneric = appleGenericDisplayNameFamily(lhs) == family
        let rhsGeneric = appleGenericDisplayNameFamily(rhs) == family
        guard lhsGeneric || rhsGeneric else { return false }
        return appleDeviceFamilyToken(lhsName) == family
            && appleDeviceFamilyToken(rhsName) == family
    }

    private nonisolated static func hasSkyBridgeNetworkRoute(_ device: OnlineDevice) -> Bool {
        hasDirectSkyBridgeControlRoute(device)
            || hasBonjourSkyBridgeControlRoute(
                identifier: device.uniqueIdentifier,
                services: device.services,
                portMap: device.portMap,
                routeIdentifiers: device.routeIdentifiers
            )
    }

    private nonisolated static func hasAppleMobileNonNetworkPresence(_ device: OnlineDevice) -> Bool {
        device.connectionTypes.contains(.usb)
            || device.sources.contains(.skybridgeUSB)
            || device.sources.contains(.skybridgeCloud)
            || (!hasSkyBridgeNetworkRoute(device) && device.lastConnectedAt != nil)
    }

    private nonisolated static func shouldAllowAppleMacServiceNameCoalescing(
        _ lhs: OnlineDevice,
        _ rhs: OnlineDevice
    ) -> Bool {
        guard isAppleMacPresentation(lhs), isAppleMacPresentation(rhs) else { return false }
        guard appleModelMetadataCompatible(lhs.modelName, rhs.modelName) else { return false }
        guard appleMacPlatformMetadataCompatible(lhs.platformName, rhs.platformName) else { return false }
        guard hasMacServiceRouteEvidence(lhs), hasMacServiceRouteEvidence(rhs) else { return false }

        return lhs.lastConnectedAt != nil
            || rhs.lastConnectedAt != nil
            || lhs.isAuthorized
            || rhs.isAuthorized
            || lhs.connectionStatus != .offline
            || rhs.connectionStatus != .offline
    }

    private nonisolated static func isAppleMobilePresentation(_ device: OnlineDevice) -> Bool {
        let haystack = [
            device.name,
            device.modelName ?? "",
            device.platformName ?? ""
        ]
        .joined(separator: " ")
        .lowercased()
        return haystack.contains("iphone")
            || haystack.contains("ipad")
            || haystack.contains("ios")
            || haystack.contains("ipados")
    }

    private nonisolated static func isAppleMobilePresentation(_ device: DiscoveredDevice) -> Bool {
        let family = appleDeviceFamilyToken(preferredValues: [
            device.modelName,
            device.name,
            device.platformName
        ])
        return family == "ipad" || family == "iphone"
    }

    private nonisolated static func isAppleMobilePresentationName(_ raw: String) -> Bool {
        let family = appleDeviceFamilyToken(raw)
        return family == "ipad" || family == "iphone"
    }

    private nonisolated static func isAppleMacPresentation(_ device: OnlineDevice) -> Bool {
        appleDeviceFamilyToken(preferredValues: [
            device.modelName,
            device.platformName,
            device.name
        ]) == "mac"
    }

    private nonisolated static func hasMacServiceRouteEvidence(_ device: OnlineDevice) -> Bool {
        if hasDirectSkyBridgeControlRoute(device) {
            return true
        }
        if isAppleMobilePresentation(device),
           !hasPositiveSkyBridgeControlPort(device.portMap) {
            return false
        }
        guard !hasExplicitOnlyNonConnectableAddress(device) else {
            return false
        }
        if hasBonjourSkyBridgeControlRoute(
            identifier: device.uniqueIdentifier,
            services: device.services,
            portMap: device.portMap,
            routeIdentifiers: device.routeIdentifiers
        ) {
            return true
        }
        let servicesAndPorts = device.services
            + Array(device.portMap.keys)
            + device.routeIdentifiers
            + [device.uniqueIdentifier]
        if servicesAndPorts.contains(where: { $0.lowercased().contains("skybridge") }) {
            return true
        }
        return hasConnectableIPAddress(device.ipv4) || hasConnectableIPAddress(device.ipv6)
    }

    private nonisolated static func appleModelMetadataCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
        let lhs = normalizedDedupeName(lhs ?? "")
        let rhs = normalizedDedupeName(rhs ?? "")
        guard !lhs.isEmpty, !rhs.isEmpty else { return true }
        if lhs == rhs { return true }
        return appleGenericFamilyModel(lhs, containsDetailedModel: rhs)
            || appleGenericFamilyModel(rhs, containsDetailedModel: lhs)
    }

    private nonisolated static func applePlatformMetadataCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
        let lhs = normalizedDedupeName(lhs ?? "")
        let rhs = normalizedDedupeName(rhs ?? "")
        guard !lhs.isEmpty, !rhs.isEmpty else { return true }
        if lhs == rhs { return true }

        let appleMobilePlatformAliases: Set<String> = ["ios", "ipados"]
        return appleMobilePlatformAliases.contains(lhs) && appleMobilePlatformAliases.contains(rhs)
    }

    private nonisolated static func appleMacPlatformMetadataCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
        let lhs = normalizedDedupeName(lhs ?? "")
        let rhs = normalizedDedupeName(rhs ?? "")
        guard !lhs.isEmpty, !rhs.isEmpty else { return true }
        if lhs == rhs { return true }

        let macPlatformAliases: Set<String> = ["mac", "macos", "osx", "darwin"]
        return macPlatformAliases.contains(lhs) && macPlatformAliases.contains(rhs)
    }

    private nonisolated static func appleGenericFamilyModel(
        _ generic: String,
        containsDetailedModel detailed: String
    ) -> Bool {
        switch generic {
        case "ipad":
            return detailed.hasPrefix("ipad")
        case "iphone":
            return detailed.hasPrefix("iphone")
        case "mac", "macos":
            return detailed.contains("mac")
        case "macbook", "macbookpro", "macbookair", "imac", "macmini", "macstudio", "macpro":
            return detailed.hasPrefix(generic) || detailed.contains(generic)
        default:
            return false
        }
    }

    private nonisolated static func namesRepresentSameDevice(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = normalizedDedupeName(lhs)
        let rhs = normalizedDedupeName(rhs)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        let minLength = min(lhs.count, rhs.count)
        guard minLength >= 8 else { return false }
        return lhs.contains(rhs) || rhs.contains(lhs)
    }

    private nonisolated static func macNamesRepresentSameDevice(_ lhs: String, _ rhs: String) -> Bool {
        if namesRepresentSameDevice(lhs, rhs) {
            return true
        }

        let lhsName = normalizedDedupeName(lhs)
        let rhsName = normalizedDedupeName(rhs)
        let lhsIsModelIdentifier = isAppleMacHardwareModelIdentifier(lhsName)
        let rhsIsModelIdentifier = isAppleMacHardwareModelIdentifier(rhsName)
        guard lhsIsModelIdentifier != rhsIsModelIdentifier else {
            return false
        }

        let presentationName = lhsIsModelIdentifier ? rhsName : lhsName
        return appleDeviceFamilyToken(presentationName) == "mac"
    }

    private nonisolated static func isAppleMacHardwareModelIdentifier(_ normalizedName: String) -> Bool {
        guard normalizedName.contains(","),
              normalizedName.contains(where: { $0.isNumber }) else {
            return false
        }
        return normalizedName.hasPrefix("macbookpro")
            || normalizedName.hasPrefix("macbookair")
            || normalizedName.hasPrefix("macmini")
            || normalizedName.hasPrefix("macstudio")
            || normalizedName.hasPrefix("macpro")
            || normalizedName.hasPrefix("imac")
    }

    private struct CandidateMatchingContext {
        let normalizedOnlineName: String
        let normalizedIPv4: String?
        let normalizedIPv6: String?
        let strongId: String?
        let pubKeyFP: String?
        let peerAliases: Set<String>
        let appleDeviceFamily: String?
        let prefersUSB: Bool
        let hasStrongIdentityAnchor: Bool
    }

    private func makeCandidateMatchingContext(for onlineDevice: OnlineDevice) -> CandidateMatchingContext {
        let strongId: String? = {
            guard onlineDevice.uniqueIdentifier.hasPrefix("id:") else { return nil }
            return String(onlineDevice.uniqueIdentifier.dropFirst("id:".count))
        }()
        let pubKeyFP: String? = {
            guard onlineDevice.uniqueIdentifier.hasPrefix("fp:") else { return nil }
            return String(onlineDevice.uniqueIdentifier.dropFirst("fp:".count)).lowercased()
        }()
        return CandidateMatchingContext(
            normalizedOnlineName: normalizeDeviceName(onlineDevice.name),
            normalizedIPv4: onlineDevice.ipv4.map(Self.normalizeIPAddress),
            normalizedIPv6: onlineDevice.ipv6.map(Self.normalizeIPAddress),
            strongId: strongId,
            pubKeyFP: pubKeyFP,
            peerAliases: Self.normalizedPeerAliases(for: onlineDevice),
            appleDeviceFamily: Self.appleDeviceFamilyToken(
                preferredValues: [onlineDevice.modelName, onlineDevice.name, onlineDevice.platformName]
            ),
            prefersUSB: onlineDevice.connectionTypes.contains(.usb),
            hasStrongIdentityAnchor: strongId != nil
                || pubKeyFP != nil
                || onlineDevice.ipv4 != nil
                || onlineDevice.ipv6 != nil
                || !Self.normalizedPeerAliases(for: onlineDevice).isEmpty
        )
    }

    private func scoreTrustedRecordCandidate(_ device: OnlineDevice, trustRecord: TrustRecord) -> Int {
        var identityScore = 0
        var hasStrongIdentityMatch = false
        let trustFamily = Self.appleDeviceFamilyToken(
            preferredValues: [
                trustRecord.deviceName,
                trustRecordCapabilityValue("peerEndpoint", for: trustRecord).flatMap(Self.bonjourName)
            ]
        )
        let deviceFamily = Self.appleDeviceFamilyToken(
            preferredValues: [device.modelName, device.name, device.platformName]
        )
        if let trustFamily, let deviceFamily, trustFamily != deviceFamily {
            return 0
        }
        let requiresStrongIdentityMatch = trustFamily == "iphone"
            || trustFamily == "ipad"
            || deviceFamily == "iphone"
            || deviceFamily == "ipad"
        let declaredDeviceId = trustRecordCapabilityValue("declaredDeviceId", for: trustRecord)
        let knownStableIDs = Set(
            ([trustRecord.deviceId, trustRecord.currentDeviceId, declaredDeviceId] + trustRecord.knownDeviceIds)
                .compactMap(Self.normalizeStableIdentifier)
        )
        let knownFingerprints = Set(
            [trustRecord.pubKeyFP, trustRecord.currentPathAuthorityFingerprint]
                .compactMap { normalizeFingerprint($0) }
        )
        let trustedPeerAliases = normalizedPeerAliases(for: trustRecord)
        let trustedNameTokens = normalizedNameTokens(for: trustRecord)

        if let stableId = Self.normalizedStableIdentifierPayload(from: device.uniqueIdentifier),
           knownStableIDs.contains(stableId) {
            identityScore += 320
            hasStrongIdentityMatch = true
        }

        if let fingerprint = normalizedFingerprintPayload(from: device.uniqueIdentifier),
           knownFingerprints.contains(fingerprint) {
            identityScore += 260
            hasStrongIdentityMatch = true
        }

        if !trustedPeerAliases.isEmpty,
           !Self.normalizedPeerAliases(for: device).isDisjoint(with: trustedPeerAliases) {
            identityScore += 180
            hasStrongIdentityMatch = true
        }

        let normalizedDeviceName = Self.normalizedDedupeName(device.name)
        if !normalizedDeviceName.isEmpty, trustedNameTokens.contains(normalizedDeviceName) {
            if !requiresStrongIdentityMatch || hasStrongIdentityMatch {
                identityScore += 90
            }
        }

        guard identityScore > 0 else { return 0 }

        var score = identityScore
        if device.connectionStatus == .connected {
            score += 20
        } else if device.connectionStatus == .online {
            score += 10
        }

        if device.isConnectable {
            score += 5
        }

        return score
    }

    private func scoreCloudDeviceCandidate(_ device: OnlineDevice, cloudDevice: iCloudDevice) -> Int {
        let cloudFamily = Self.appleDeviceFamilyToken(preferredValues: [cloudDevice.model, cloudDevice.name])
        let deviceFamily = Self.appleDeviceFamilyToken(preferredValues: [device.modelName, device.name, device.platformName])
        if let cloudFamily, let deviceFamily, cloudFamily != deviceFamily {
            return 0
        }

        var score = 0
        var hasStrongIdentityMatch = false

        let cloudStableIDs = Set(
            [cloudDevice.stableIdentityDeviceId]
                .compactMap(Self.normalizeStableIdentifier)
        )
        let deviceStableIDs = Set(
            ([device.uniqueIdentifier] + device.routeIdentifiers).compactMap { raw in
                Self.normalizedStableIdentifierPayload(from: raw)
                    ?? Self.normalizeStableIdentifier(raw)
            }
        )
        if !cloudStableIDs.isEmpty, !deviceStableIDs.isDisjoint(with: cloudStableIDs) {
            score += 360
            hasStrongIdentityMatch = true
        }

        if let cloudIP = cloudDevice.ipAddress.map(Self.normalizeIPAddress), !cloudIP.isEmpty {
            let deviceIPs = Set([device.ipv4, device.ipv6].compactMap { $0.map(Self.normalizeIPAddress) })
            if deviceIPs.contains(cloudIP) {
                score += 280
                hasStrongIdentityMatch = true
            } else if device.uniqueIdentifier.hasPrefix("ip:") {
                let identifierIP = Self.normalizeIPAddress(String(device.uniqueIdentifier.dropFirst("ip:".count)))
                if identifierIP == cloudIP {
                    score += 260
                    hasStrongIdentityMatch = true
                }
            }
        }

        guard hasStrongIdentityMatch else { return 0 }

        if Self.namesRepresentSameDevice(cloudDevice.name, device.name) {
            score += 120
        }

        let cloudModel = Self.normalizedDedupeName(cloudDevice.model)
        let deviceModel = Self.normalizedDedupeName(device.modelName ?? "")
        if !cloudModel.isEmpty, !deviceModel.isEmpty {
            if cloudModel == deviceModel || cloudModel.contains(deviceModel) || deviceModel.contains(cloudModel) {
                score += 40
            } else {
                score -= 30
            }
        }

        if device.connectionStatus == .connected {
            score += 30
        } else if device.connectionStatus == .online {
            score += 20
        }

        if device.isConnectable {
            score += 10
        }

        return score
    }

    private nonisolated static func appleDeviceFamilyToken(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        if value.contains("ipad") || value.contains("ipados") { return "ipad" }
        if value.contains("iphone") || value.contains("ios") { return "iphone" }
        if value.contains("macbook") || value.contains("imac") || value.contains("macos") || value.contains("mac ") || value == "mac" {
            return "mac"
        }
        return nil
    }

    private nonisolated static func appleDeviceFamilyToken(preferredValues: [String?]) -> String? {
        for raw in preferredValues {
            if let raw, let family = appleDeviceFamilyToken(raw) {
                return family
            }
        }
        return nil
    }

    private func scoreDiscoveredTrustRecordCandidate(
        _ candidate: DiscoveredDevice,
        trustRecord: TrustRecord
    ) -> Int {
        var identityScore = 0
        var hasStrongIdentityMatch = false
        let trustFamily = Self.appleDeviceFamilyToken(
            preferredValues: [
                trustRecord.deviceName,
                trustRecordCapabilityValue("peerEndpoint", for: trustRecord).flatMap(Self.bonjourName)
            ]
        )
        let candidateFamily = Self.appleDeviceFamilyToken(
            preferredValues: [candidate.modelName, candidate.name, candidate.platformName]
        )
        if let trustFamily, let candidateFamily, trustFamily != candidateFamily {
            return 0
        }
        let requiresStrongIdentityMatch = trustFamily == "iphone"
            || trustFamily == "ipad"
            || candidateFamily == "iphone"
            || candidateFamily == "ipad"
        let declaredDeviceId = trustRecordCapabilityValue("declaredDeviceId", for: trustRecord)
        let knownStableIDs = Set(
            ([trustRecord.deviceId, trustRecord.currentDeviceId, declaredDeviceId] + trustRecord.knownDeviceIds)
                .compactMap(Self.normalizeStableIdentifier)
        )
        let knownFingerprints = Set(
            [trustRecord.pubKeyFP, trustRecord.currentPathAuthorityFingerprint]
                .compactMap { normalizeFingerprint($0) }
        )
        let trustedPeerAliases = normalizedPeerAliases(for: trustRecord)
        let trustedNameTokens = normalizedNameTokens(for: trustRecord)

        let candidateStableIDs = Set(
            [candidate.deviceId, candidate.uniqueIdentifier]
                .compactMap { raw -> String? in
                    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !raw.isEmpty else {
                        return nil
                    }
                    if raw.hasPrefix("id:") {
                        return Self.normalizeStableIdentifier(String(raw.dropFirst("id:".count)))
                    }
                    return Self.normalizeStableIdentifier(raw)
                }
        )

        if !candidateStableIDs.isDisjoint(with: knownStableIDs) {
            identityScore += 320
            hasStrongIdentityMatch = true
        }

        if let candidateFingerprint = candidate.pubKeyFP?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           knownFingerprints.contains(candidateFingerprint) {
            identityScore += 260
            hasStrongIdentityMatch = true
        }

        if !trustedPeerAliases.isEmpty,
           !Self.normalizedPeerAliases(for: candidate).isDisjoint(with: trustedPeerAliases) {
            identityScore += 180
            hasStrongIdentityMatch = true
        }

        let normalizedCandidateName = Self.normalizedDedupeName(candidate.name)
        if !normalizedCandidateName.isEmpty, trustedNameTokens.contains(normalizedCandidateName) {
            if !requiresStrongIdentityMatch || hasStrongIdentityMatch {
                identityScore += 90
            }
        }

        guard identityScore > 0 else { return 0 }

        var score = identityScore
        if candidate.services.contains("_skybridge._tcp") || candidate.portMap["_skybridge._tcp"] != nil {
            score += 20
        }

        return score
    }

    private func scoreCandidateDevice(
        _ candidate: DiscoveredDevice,
        context: CandidateMatchingContext
    ) -> Int {
        var score = 0
        let normalizedCandidateName = normalizeDeviceName(candidate.name)
        let candidateIsSyntheticPeer = Self.isSyntheticPeerDisplayName(candidate.name)
        let candidateHasSkyBridgeControlEndpoint =
            candidate.services.contains("_skybridge._tcp")
            || candidate.services.contains("_skybridge._udp")
            || (candidate.portMap["_skybridge._tcp"] ?? 0) > 0
            || (candidate.portMap["_skybridge._udp"] ?? 0) > 0
        let candidateHasAddress = candidate.ipv4 != nil || candidate.ipv6 != nil
        let candidateHasUsablePort = candidate.portMap.values.contains(where: { $0 > 0 })
        let candidateNetworkReachable = candidateHasSkyBridgeControlEndpoint || (candidateHasAddress && candidateHasUsablePort)
        let candidateAppleFamily = Self.appleDeviceFamilyToken(
            preferredValues: [candidate.modelName, candidate.name, candidate.platformName]
        )
        if let onlineFamily = context.appleDeviceFamily,
           let candidateAppleFamily,
           onlineFamily != candidateAppleFamily {
            return 0
        }
        let requiresStrongIdentityMatch = context.appleDeviceFamily == "iphone"
            || context.appleDeviceFamily == "ipad"
            || candidateAppleFamily == "iphone"
            || candidateAppleFamily == "ipad"

        let strongIdMatched = {
            guard let strongId = context.strongId, let candidateId = candidate.deviceId else { return false }
            return candidateId == strongId
        }()
        let pubKeyMatched = {
            guard let pubKeyFP = context.pubKeyFP, let candidateFP = candidate.pubKeyFP?.lowercased() else { return false }
            return candidateFP == pubKeyFP
        }()
        let ipv4Matched = {
            guard let normalizedIPv4 = context.normalizedIPv4,
                  let candidateIPv4 = candidate.ipv4.map(Self.normalizeIPAddress) else { return false }
            return candidateIPv4 == normalizedIPv4
        }()
        let ipv6Matched = {
            guard let normalizedIPv6 = context.normalizedIPv6,
                  let candidateIPv6 = candidate.ipv6.map(Self.normalizeIPAddress) else { return false }
            return candidateIPv6 == normalizedIPv6
        }()
        let peerAliasMatched = !context.peerAliases.isEmpty
            && !Self.normalizedPeerAliases(for: candidate).isDisjoint(with: context.peerAliases)
        let nameMatched = {
            guard !context.normalizedOnlineName.isEmpty, !normalizedCandidateName.isEmpty else { return false }
            if normalizedCandidateName == context.normalizedOnlineName { return true }
            let minLength = min(normalizedCandidateName.count, context.normalizedOnlineName.count)
            guard minLength >= 8 else { return false }
            return normalizedCandidateName.contains(context.normalizedOnlineName)
                || context.normalizedOnlineName.contains(normalizedCandidateName)
        }()
        let strongIdentityMatched = strongIdMatched || pubKeyMatched || peerAliasMatched || ipv4Matched || ipv6Matched
        let identityMatched = strongIdentityMatched || (!requiresStrongIdentityMatch && nameMatched)

        // Never attempt unrelated devices for a selected target; this avoids false-positive candidate lists
        // like "other iPhone / local Mac" showing up under one online device.
        if !identityMatched {
            return 0
        }

        if strongIdMatched {
            score += 200
        }
        if pubKeyMatched {
            score += 180
        }
        if peerAliasMatched {
            score += 140
        }

        if ipv4Matched {
            score += 120
        }
        if ipv6Matched {
            score += 110
        }

        if nameMatched {
            score += strongIdentityMatched ? 60 : 30
        }

        if candidate.services.contains("_skybridge._tcp") {
            score += 50
        }
        if (candidate.portMap["_skybridge._tcp"] ?? 0) > 0 {
            score += 20
        }
        if !candidateNetworkReachable {
            // 避免选中仅 USB / 无可连端口 的候选，防止后续把能力标签误当 Bonjour service type。
            score -= 180
        }
        if candidate.connectionTypes == [.usb], !candidateHasSkyBridgeControlEndpoint {
            score -= 120
        }
        if candidateIsSyntheticPeer {
            // `peer:fe80::...` 这类名称通常是瞬态端点，优先级应低于真实 Bonjour 设备名。
            // 仅在没有 stable id / 公钥指纹时作为最后兜底，避免“同一设备多条离线记录”误绑定。
            if context.strongId == nil, context.pubKeyFP == nil {
                score -= 90
            } else {
                score -= 40
            }
        }
        if context.prefersUSB, candidate.connectionTypes.contains(.usb) {
            score += 10
        }
        if context.hasStrongIdentityAnchor, !strongIdentityMatched {
            score -= 40
        }
        return score
    }

 /// 生成唯一标识符
    private func generateUniqueIdentifier(
        stableDeviceId: String?,
        pubKeyFP: String?,
        macAddress: String?,
        serialNumber: String?,
        name: String,
        ipv4: String?,
        ipv6: String?,
        discoveryIdentifier: String? = nil
    ) -> String {
        // 优先级（强→弱）:
        // deviceId (stable) > pubKeyFP (stable) > Bonjour/IP identity > MAC地址 > 序列号 > IPv4 > IPv6 > 名称
        if let id = stableDeviceId, !id.isEmpty {
            return "id:\(id)"
        }
        if let fp = pubKeyFP, fp.count == 64, fp.allSatisfy({ $0.isHexDigit }) {
            return "fp:\(fp)"
        }
        if let discoveryIdentifier = normalizedDiscoveryIdentifier(discoveryIdentifier) {
            return discoveryIdentifier
        }
        if let normalizedMAC = normalizedMACAddress(macAddress) {
            return "mac:\(normalizedMAC)"
        }

        if let serial = serialNumber, !serial.isEmpty {
            return "serial:\(serial)"
        }

        if let ip = ipv4, !ip.isEmpty {
            return "ip:\(ip)"
        }

        if let ip6 = ipv6, !ip6.isEmpty {
            return "ip:\(ip6)"
        }

        return "name:\(name)"
    }

    private func normalizedDiscoveryIdentifier(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        if raw.hasPrefix("id:"),
           let normalized = Self.normalizeStableIdentifier(String(raw.dropFirst("id:".count))) {
            return "id:\(normalized)"
        }
        if raw.hasPrefix("fp:"),
           let normalized = normalizeFingerprint(String(raw.dropFirst("fp:".count))) {
            return "fp:\(normalized)"
        }
        if raw.hasPrefix("bonjour:") || raw.hasPrefix("recent:bonjour:") {
            return raw
        }
        if raw.hasPrefix("ip:") {
            let payload = String(raw.dropFirst("ip:".count))
            let normalized = Self.normalizeIPAddress(payload)
            return normalized.isEmpty ? nil : "ip:\(normalized)"
        }
        if Self.looksLikeAppleUSBDeviceIdentifier(raw) {
            return "serial:\(raw)"
        }
        if let stable = Self.normalizeStableIdentifier(raw) {
            return "id:\(stable)"
        }
        let normalizedIP = Self.normalizeIPAddress(raw)
        if !normalizedIP.isEmpty, normalizedIP.contains(".") || normalizedIP.contains(":") {
            return "ip:\(normalizedIP)"
        }
        return nil
    }

    private nonisolated static func looksLikeAppleUSBDeviceIdentifier(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        if value.range(
            of: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}$",
            options: .regularExpression
        ) != nil {
            return true
        }
        if value.range(
            of: "^[0-9A-Fa-f]{24,40}$",
            options: .regularExpression
        ) != nil {
            return true
        }
        return false
    }

    private nonisolated static func isCloudHeartbeatOnly(_ device: OnlineDevice) -> Bool {
        device.sources.allSatisfy { $0 == .skybridgeCloud }
            && device.routeIdentifiers.isEmpty
            && device.services.isEmpty
            && device.portMap.isEmpty
            && !device.connectionTypes.contains(.usb)
    }

    private nonisolated static func hasFreshConnectableControlRouteSource(
        _ device: OnlineDevice,
        newestSeen: Date
    ) -> Bool {
        guard device.isConnectable,
              !isCloudHeartbeatOnly(device),
              newestSeen.timeIntervalSince(device.lastSeen) < controlRouteFreshnessWindow else {
            return false
        }
        guard hasRequiredProtocolIdentityForCachedAppleMobileRoute(device) else {
            return false
        }
        if hasDirectSkyBridgeControlRoute(device) {
            return true
        }
        if isAppleMobilePresentation(device),
           !hasPositiveSkyBridgeControlPort(device.portMap) {
            return false
        }
        guard !hasExplicitOnlyNonConnectableAddress(device) else {
            return false
        }
        if hasBonjourSkyBridgeControlRoute(
            identifier: device.uniqueIdentifier,
            services: device.services,
            portMap: device.portMap,
            routeIdentifiers: device.routeIdentifiers
        ) {
            return true
        }
        return false
    }

    private func normalizedMACAddress(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let normalized = raw.replacingOccurrences(of: "-", with: ":").lowercased()
        let pattern = "^([0-9a-f]{2}:){5}[0-9a-f]{2}$"
        guard normalized.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return normalized
    }

    private func preferredMACAddress(from candidates: Set<String>) -> String? {
        for value in candidates {
            if let normalized = normalizedMACAddress(value) {
                return normalized
            }
        }
        return nil
    }

    private nonisolated static func hasRequiredProtocolIdentityForCachedAppleMobileRoute(
        _ device: OnlineDevice
    ) -> Bool {
        guard isAppleMobilePresentation(device) else {
            return true
        }
        return BonjourInteropContract.normalizedPubKeyFingerprint(device.protocolFingerprint) != nil
    }

    private nonisolated static func normalizeStableIdentifier(_ raw: String?) -> String? {
        guard var raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        while raw.hasPrefix("host:") {
            raw = String(raw.dropFirst("host:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if raw.hasPrefix("id:") {
            raw = String(raw.dropFirst("id:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if raw.hasPrefix("peer:") {
            let payload = String(raw.dropFirst("peer:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if payload.range(
                of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                raw = payload
            }
        }

        guard !raw.isEmpty else { return nil }
        let lowercased = raw.lowercased()
        if lowercased.hasPrefix("bonjour:")
            || lowercased.hasPrefix("recent:")
            || lowercased.hasPrefix("cross-network:")
            || lowercased.hasPrefix("webrtc-") {
            return nil
        }

        if raw.range(
            of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return raw.lowercased()
        }

        guard raw.count >= 8 else { return nil }
        return raw
    }

    private nonisolated static func isEphemeralConnectionPeerIdentifier(_ raw: String) -> Bool {
        var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasPrefix("recent:") || normalized.hasPrefix("peer:") {
            if normalized.hasPrefix("recent:") {
                normalized = String(normalized.dropFirst("recent:".count))
            } else if normalized.hasPrefix("peer:") {
                normalized = String(normalized.dropFirst("peer:".count))
            }
        }
        return normalized.hasPrefix("cross-network:")
            || normalized.hasPrefix("webrtc-")
    }

    private func normalizeFingerprint(_ raw: String?) -> String? {
        BonjourInteropContract.normalizedPubKeyFingerprint(raw)
    }

    private func preferredIdentifier(
        current: String,
        incoming: String,
        currentProtocolFingerprint: String?,
        incomingProtocolFingerprint: String?
    ) -> String {
        let currentHasLiveProtocolIdentity = Self.canonicalStableIdentifierToken(current) != nil
            && normalizeFingerprint(currentProtocolFingerprint) != nil
        let incomingHasLiveProtocolIdentity = Self.canonicalStableIdentifierToken(incoming) != nil
            && normalizeFingerprint(incomingProtocolFingerprint) != nil
        if incomingHasLiveProtocolIdentity, !currentHasLiveProtocolIdentity {
            return incoming
        }
        if currentHasLiveProtocolIdentity, !incomingHasLiveProtocolIdentity {
            return current
        }

        let currentScore = Self.identifierStrength(current)
        let incomingScore = Self.identifierStrength(incoming)
        if incomingScore > currentScore {
            return incoming
        }
        if incomingScore == currentScore,
           incomingScore >= 500,
           incoming != current,
           Self.normalizedStableIdentifierPayload(from: current) != nil,
           Self.normalizedStableIdentifierPayload(from: incoming) != nil {
            return incoming
        }
        return current
    }

    private nonisolated static func identifierStrength(_ identifier: String) -> Int {
        if identifier.hasPrefix("id:") { return 600 }
        if identifier.hasPrefix("fp:") { return 550 }
        if identifier.hasPrefix("recent:bonjour:") { return 450 }
        if identifier.hasPrefix("bonjour:") { return 440 }
        if identifier.hasPrefix("serial:") { return 350 }
        if identifier.hasPrefix("mac:") { return 320 }
        if identifier.hasPrefix("ip:") { return 260 }
        if identifier.hasPrefix("recent:peer:") { return 180 }
        if identifier.hasPrefix("name:") { return 100 }
        if Self.normalizeStableIdentifier(identifier) != nil { return 500 }
        if Self.normalizeIPAddress(identifier).contains(".") || Self.normalizeIPAddress(identifier).contains(":") {
            return 240
        }
        return 10
    }

 /// 标准化设备名称
    private func normalizeDeviceName(_ name: String) -> String {
        var normalized = name.lowercased()

 // 去除常见前缀
        let prefixes = ["的", "de", "s-", "i-", "@"]
        for prefix in prefixes {
            if let range = normalized.range(of: prefix) {
                normalized.removeSubrange(range)
            }
        }

 // 去除空格和特殊字符
        normalized = normalized
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        return normalized
    }

    private func usbPresenceTokens(for device: USBDevice) -> [String] {
        var tokens: [String] = []
        if let serial = device.serialNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
           !serial.isEmpty {
            tokens.append("serial:\(serial)")
        }
        let normalizedName = normalizeDeviceName(device.name)
        if !normalizedName.isEmpty {
            tokens.append("name:\(normalizedName)")
        }
        return tokens
    }

    private func usbPresenceTokens(for device: OnlineDevice) -> [String] {
        var tokens: [String] = []
        if let serial = device.serialNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
           !serial.isEmpty {
            tokens.append("serial:\(serial)")
        }
        let normalizedName = normalizeDeviceName(device.name)
        if !normalizedName.isEmpty {
            tokens.append("name:\(normalizedName)")
        }
        return tokens
    }

    private func isActivelyAttachedOverUSB(_ device: OnlineDevice) -> Bool {
        guard device.connectionTypes.contains(.usb) else { return false }
        let tokens = usbPresenceTokens(for: device)
        guard !tokens.isEmpty else { return false }
        return tokens.contains { activeUSBPresenceTokens.contains($0) }
    }

 /// 识别本机设备
    private func identifyLocalDevice() {
        let localPresentation = LocalDevicePresentation.current()
        let hostname = localPresentation.deviceName ?? localPresentation.modelName ?? "Mac"
        let identifier = "local:\(hostname)"

        let local = OnlineDevice(
            id: UUID(),
            name: hostname,
            deviceType: .computer,
            ipv4: nil,
            ipv6: nil,
            platformName: localPresentation.platformName,
            osVersion: localPresentation.osVersion,
            modelName: localPresentation.modelName,
            macAddress: nil,
            serialNumber: nil,
            connectionTypes: [],
            services: [],
            portMap: [:],
            uniqueIdentifier: identifier,
            sources: [DeviceSource.unknown],  // 本机设备使用 unknown 作为来源
            discoveredAt: Date(),
            lastSeen: Date(),
            connectionStatus: .online,
            lastConnectedAt: nil,
            isLocalDevice: true,
            isAuthorized: true
        )

        localDevice = local
        deviceMap[identifier] = local

        updateDevicesList()

        logger.info("✅ 识别本机设备: \(hostname)")
    }

 /// 刷新本机 IPv4/IPv6 地址集合（缓存）
    private func refreshLocalIPs() {
        var set: Set<String> = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee, let sa = interface.ifa_addr else { continue }
                let fam = sa.pointee.sa_family
                if fam == UInt8(AF_INET) || fam == UInt8(AF_INET6) {
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                        let data = Data(bytes: buf, count: buf.count)
                        let trimmed = data.prefix { $0 != 0 }
                        let ip = String(decoding: trimmed, as: UTF8.self)
                        if !ip.isEmpty { set.insert(ip) }
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        self.localIPAddresses = set
        logger.debug("📡 本机IP缓存刷新：\(self.localIPAddresses.count) 条")
    }

 /// 刷新本机 MAC 地址集合（缓存）
    private func refreshLocalMACs() {
        Task(priority: .utility) {
 // 后台线程获取数据（不捕获 self）
            let macs = await NetworkInterfaceInspector.currentPhysicalMACs()
            let normalized = Set(macs.map { $0.lowercased() })
 // 回到主线程再写缓存（此时捕获 self 才安全）
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.localMacAddresses = normalized
                self.logger.debug("📎 本机MAC缓存刷新：\(normalized.count) 条")
            }
        }
    }

 /// 启动网络路径监控，路径变化时刷新本机IP/MAC 集合并重算本机标记
    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                self?.refreshLocalIPs()
                self?.refreshLocalMACs()
                self?.recomputeLocalFlagsForAllDevices()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.skybridge.pathmonitor"))
    }

    private nonisolated static func authoritativeLocalIdentityKeys(
        identifier: String?,
        deviceId: String?,
        protocolFingerprint: String?
    ) -> Set<String> {
        var keys = Set<String>()
        for candidate in [identifier, deviceId] {
            if let persistentDeviceId = PeerTrustLookup.persistentDeviceId(from: candidate) {
                keys.insert("device:\(persistentDeviceId)")
            }
        }
        if let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !identifier.isEmpty {
            keys.insert("discovery:\(identifier.lowercased())")
        }
        if let fingerprint = BonjourInteropContract.normalizedPubKeyFingerprint(protocolFingerprint) {
            keys.insert("fingerprint:\(fingerprint)")
        }
        return keys
    }

    private func recordAuthoritativeLocalClassificationIfNeeded(
        _ isLocalDevice: Bool,
        identifier: String,
        protocolFingerprint: String?
    ) {
        guard isLocalDevice else { return }
        for key in Self.authoritativeLocalIdentityKeys(
            identifier: identifier,
            deviceId: nil,
            protocolFingerprint: protocolFingerprint
        ) {
            authoritativeNetworkLocalClassifications[key] = true
        }
    }

 /// 严格版：强身份结论优先；没有强身份结论时才按来源/类型/MAC/名称判断。
    private func isLocalCandidate(
        identifier: String,
        protocolFingerprint: String?,
        name: String,
        macAddress: String?,
        deviceType: DeviceClassifier.DeviceType,
        sources: [DeviceSource],
        authoritativeIsLocalDevice: Bool = false
    ) -> Bool {
        if authoritativeIsLocalDevice { return true }
        let authoritativeClassifications = Self.authoritativeLocalIdentityKeys(
            identifier: identifier,
            deviceId: nil,
            protocolFingerprint: protocolFingerprint
        ).compactMap { authoritativeNetworkLocalClassifications[$0] }
        if authoritativeClassifications.contains(true) { return true }
        if !authoritativeClassifications.isEmpty { return false }

 // A. 唯一本机条目（local:）直接视为本机
        if identifier.hasPrefix("local:") { return true }

 // B. 仅当计算设备类型为电脑才允许成为本机
        guard deviceType == .computer else { return false }

 // C. 只有 SkyBridge 自有来源才有资格成为本机
        let eligibleSources: Set<DeviceSource> = [
            .skybridgeBonjour, .skybridgeP2P, .skybridgeUSB, .skybridgeCloud
        ]
        guard sources.contains(where: { eligibleSources.contains($0) }) else { return false }

 // D. 首要证据：MAC 与本机物理网卡一致
        if let mac = macAddress?.lowercased(), !mac.isEmpty, localMacAddresses.contains(mac) {
            return true
        }

 // E. 次级证据：名称与本机 hostname 精确归一化后相等（仅在通过 B+C 后允许）
        let hostname = LocalHostName.localizedName ?? ""
        func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: " ", with: "") }
        if !hostname.isEmpty, norm(name) == norm(hostname) {
            return true
        }
        return false
    }

 /// 全量重算所有设备的本机标记（洗掉历史 OR 粘附导致的污染）
    private func recomputeLocalFlagsForAllDevices() {
        var localCount = 0
        for (key, var device) in deviceMap {
            let newFlag = isLocalCandidate(
                identifier: device.uniqueIdentifier,
                protocolFingerprint: device.protocolFingerprint,
                name: device.name,
                macAddress: device.macAddress,
                deviceType: device.deviceType,
                sources: device.sources
            )
            device.isLocalDevice = newFlag
            deviceMap[key] = device
            if newFlag { localCount += 1 }
        }
 // 验证：若出现多个“本机”，记录警告日志供排查
        if localCount > 1 {
            logger.warning("⚠️ 重算后检测到多个本机：\(localCount) 个")
        }
        updateDevicesList()
    }

 /// 加载持久化的设备
    private func loadPersistedDevices() {
        let devices = storage.loadDevices()

        for device in devices {
 // 标记为离线,等待重新发现
            var offlineDevice = device
            offlineDevice.connectionStatus = .offline
 // 启动时按严格规则重算本机标记，清理历史污染
            offlineDevice.isLocalDevice = isLocalCandidate(
                identifier: offlineDevice.uniqueIdentifier,
                protocolFingerprint: offlineDevice.protocolFingerprint,
                name: offlineDevice.name,
                macAddress: offlineDevice.macAddress,
                deviceType: offlineDevice.deviceType,
                sources: offlineDevice.sources
            )

            deviceMap[device.uniqueIdentifier] = offlineDevice
        }

        updateDevicesList()
 // 一次性清洗历史缓存中的本机污染
        recomputeLocalFlagsForAllDevices()

        logger.info("📂 加载历史设备: \(devices.count) 台")
    }

 /// 启动清理定时器
    private func startCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.cleanupOfflineDevices()
            }
        }
    }

 /// 清理长时间离线的设备
    private func cleanupOfflineDevices() {
        let now = Date()
        let timeout: TimeInterval = 300 // 5分钟

 // 移除「非本机、未授权、且已离线超时」的发现设备。
 // 关键修复：不再因「曾经连接过(lastConnectedAt != nil)」而永久保留——一次性连接不应让一台
 // 已离线且未授权的设备永远留在列表里，那正是历史「未知」设备堆积、且无法清理的根因。
 // 已授权(受信/云端)设备始终保留以便重连；当前仍可发现(最近 timeout 内被看到)的设备也保留。
        deviceMap = deviceMap.filter { _, device in
            if device.isLocalDevice {
                return true // 保留本机
            }
            if device.isAuthorized {
                return true // 保留已授权(受信/云端)设备
            }
            if now.timeIntervalSince(device.lastSeen) < timeout {
                return true // 最近仍可发现，保留
            }
            // 离线超时：仅保留「值得记住」的具名重连目标；无名「未知」/从未连接的幽灵在此清理。
            return skybridgeDeviceIsRememberable(device)
        }

        updateDevicesList()
    }

 /// 用户触发的即时清理：移除所有「非本机、未授权、当前离线」的发现设备，并同步清除持久化缓存。
 /// 已授权(受信/云端)设备与当前在线设备保留。返回移除的数量。
    @discardableResult
    public func clearOfflineDevices() -> Int {
        let before = deviceMap.count
        deviceMap = deviceMap.filter { _, device in
            if device.isLocalDevice { return true }
            if device.isAuthorized { return true }
            return device.connectionStatus != .offline
        }
        let removed = before - deviceMap.count
 // 重写持久化缓存：scrub 只保留可持久化的已授权设备，离线幽灵不会再次回灌。
        storage.rewrite(Array(deviceMap.values))
        updateDevicesList()
        logger.info("🧹 用户清理离线/未知设备: 移除 \(removed) 台")
        return removed
    }

 /// 映射USB设备类型
    private func mapUSBDeviceType(_ usbType: USBDeviceType) -> DeviceClassifier.DeviceType {
        switch usbType {
        case .iPhone, .iPad, .androidDevice:
            return .computer
        case .storage:
            return .nas
        case .camera:
            return .camera
        case .keyboard, .mouse:
            return .iot
        case .audio:
            return .speaker
        default:
            return .unknown
        }
    }

 /// 映射设备类型名称
    private func mapDeviceTypeName(_ typeName: String) -> DeviceClassifier.DeviceType {
        switch typeName.lowercased() {
        case "mac", "macbook", "imac":
            return .computer
        case "iphone":
            return .computer
        case "ipad":
            return .computer
        case "apple tv", "appletv":
            return .tv
        case "homepod":
            return .speaker
        case "router":
            return .router
        case "printer":
            return .printer
        case "camera":
            return .camera
        case "nas", "storage":
            return .nas
        default:
            return .unknown
        }
    }
}

// MARK: - 数据模型


// DeviceSource 定义已移至 Models.swift，此处不再重复定义


/// 设备统计
public struct DeviceStats: Sendable {
    public var total: Int = 0
    public var online: Int = 0
    public var connected: Int = 0
    public var authorized: Int = 0

    public init(total: Int = 0, online: Int = 0, connected: Int = 0, authorized: Int = 0) {
        self.total = total
        self.online = online
        self.connected = connected
        self.authorized = authorized
    }
}

// MARK: - 设备记忆策略（持久化 / 清理共用）

/// 名称是否「真实」：排除空名与各种「未知」占位名（这些正是历史堆积的离线幽灵）。
fileprivate func skybridgeDeviceNameIsRememberable(_ rawName: String) -> Bool {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !name.isEmpty else { return false }
    switch name {
    case "unknown", "unknown device", "unknowndevice",
         "未知", "未知设备", "p2ppeer", "p2p peer":
        return false
    default:
        return true
    }
}

/// 设备是否值得「记住」（持久化并在离线时保留为重连目标）：
/// 必须有真实名称，且确有关系——已授权(受信/云端) 或 曾真正连接过。
/// 从未连接的被动发现、以及无名的「未知」设备都不记住，避免「以前发现的设备全算进去」。
fileprivate func skybridgeDeviceIsRememberable(_ device: OnlineDevice) -> Bool {
    skybridgeDeviceNameIsRememberable(device.name)
        && (device.isAuthorized || device.lastConnectedAt != nil)
}

// MARK: - 设备存储

/// 设备持久化存储
private class DeviceStorage {
    private let userDefaults = UserDefaults.standard
    private let storageKey = "skybridge.persistedDevices"
    private let logger = Logger(subsystem: "com.skybridge.storage", category: "DeviceStorage")
 // 为设备缓存增加 schemaVersion，用于区分不同版本的持久化格式。
 // 当前版本采用 V2：使用 JSON 包装结构 { schemaVersion, devices }。
    private let schemaVersion = 2
    private struct PersistedDevicesPayload: Codable {
        let schemaVersion: Int
        let devices: [OnlineDevice]
    }

    func saveDevice(_ device: OnlineDevice) {
        guard let persistableDevice = Self.scrubPersistedDevice(device) else {
            logger.debug("↪️ 跳过保存临时会话路由设备: \(device.uniqueIdentifier, privacy: .public)")
            return
        }
        var devices = loadDevices()

 // 移除旧版本
        devices.removeAll { $0.id == persistableDevice.id }

 // 添加新版本
        devices.append(persistableDevice)

 // 只保留最近100台设备
        if devices.count > 100 {
            devices = Array(devices.suffix(100))
        }

        replaceDevices(devices)
        logger.debug("💾 保存设备: \(persistableDevice.name)")
    }

    func loadDevices() -> [OnlineDevice] {
        guard let data = userDefaults.data(forKey: storageKey) else {
            return []
        }

 // 优先按 V2 格式解析。
        if let payload = try? JSONDecoder().decode(PersistedDevicesPayload.self, from: data) {
            if payload.schemaVersion == schemaVersion {
                let scrubbedDevices = Self.scrubPersistedDevices(payload.devices)
                if Self.persistedDeviceScrubChanged(original: payload.devices, scrubbed: scrubbedDevices) {
                    replaceDevices(scrubbedDevices)
                    logger.info("🧹 清理临时会话路由历史设备: before=\(payload.devices.count) after=\(scrubbedDevices.count)")
                }
                logger.debug("📂 加载设备(V2): \(scrubbedDevices.count) 台")
                return scrubbedDevices
            } else {
 // 检测到非当前版本，直接丢弃以避免结构不兼容。
                logger.warning("检测到旧版设备缓存(schemaVersion=\(payload.schemaVersion))，将清空缓存重建")
                userDefaults.removeObject(forKey: storageKey)
                return []
            }
        }

 // 兼容旧版(V1)——直接存储为 [OnlineDevice] 的情况，成功则迁移为 V2。
        if let legacyDevices = try? JSONDecoder().decode([OnlineDevice].self, from: data) {
            let scrubbedDevices = Self.scrubPersistedDevices(legacyDevices)
            logger.info("📂 检测到旧版设备缓存(V1)，执行一次性迁移: \(legacyDevices.count) 台")
            replaceDevices(scrubbedDevices)
            return scrubbedDevices
        }

 // 两种格式均解析失败，视为损坏缓存，直接清理。
        logger.warning("加载设备失败：缓存格式不可解析，将清空缓存重建")
        userDefaults.removeObject(forKey: storageKey)
        return []
    }

    private func replaceDevices(_ devices: [OnlineDevice]) {
        guard !devices.isEmpty else {
            userDefaults.removeObject(forKey: storageKey)
            return
        }
        do {
 // V2 写入使用包装结构，包含 schemaVersion。
            let payload = PersistedDevicesPayload(schemaVersion: schemaVersion, devices: devices)
            let data = try JSONEncoder().encode(payload)
            userDefaults.set(data, forKey: storageKey)
        } catch {
            logger.error("❌ 保存设备失败: \(error.localizedDescription)")
        }
    }

    private static func scrubPersistedDevices(_ devices: [OnlineDevice]) -> [OnlineDevice] {
        devices.compactMap(scrubPersistedDevice)
    }

    private static func persistedDeviceScrubChanged(
        original: [OnlineDevice],
        scrubbed: [OnlineDevice]
    ) -> Bool {
        guard original.count == scrubbed.count else { return true }
        return zip(original, scrubbed).contains { before, after in
            before.id != after.id
                || before.uniqueIdentifier != after.uniqueIdentifier
                || before.routeIdentifiers != after.routeIdentifiers
        }
    }

    /// 用当前内存中的设备整体重写持久化缓存（scrub 只保留可持久化的已授权设备）。
    func rewrite(_ devices: [OnlineDevice]) {
        replaceDevices(Self.scrubPersistedDevices(devices))
    }

    private static func scrubPersistedDevice(_ device: OnlineDevice) -> OnlineDevice? {
        guard !isEphemeralConnectionIdentifier(device.uniqueIdentifier) else {
            return nil
        }
        // 仅持久化「值得记住」的设备（真实名称 + 已授权或曾连接）。无名的「未知」设备、以及从未连接的
        // 被动发现不写入缓存，避免它们在下次启动时作为离线幽灵重新加载、让历史发现的设备「全算进去」。
        // 本守卫同时会在加载旧缓存时一次性清洗掉历史遗留的此类设备（loadDevices 检测到 scrub 后数量
        // 变化即重写缓存）。受信/云端/曾连接的具名设备仍会保留，便于重连。
        guard skybridgeDeviceIsRememberable(device) else {
            return nil
        }
        var scrubbedDevice = device
        scrubbedDevice.routeIdentifiers.removeAll { isEphemeralConnectionIdentifier($0) }
        return scrubbedDevice
    }

    private static func isEphemeralConnectionIdentifier(_ raw: String) -> Bool {
        var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasPrefix("recent:") || normalized.hasPrefix("peer:") {
            if normalized.hasPrefix("recent:") {
                normalized = String(normalized.dropFirst("recent:".count))
            } else if normalized.hasPrefix("peer:") {
                normalized = String(normalized.dropFirst("peer:".count))
            }
        }
        return normalized.hasPrefix("cross-network:")
            || normalized.hasPrefix("webrtc-")
    }
}

// MARK: - Codable 支持

extension OnlineDevice: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, deviceType, ipv4, ipv6, platformName, osVersion, modelName, chip, macAddress, serialNumber
        case connectionTypes, services, portMap, routeIdentifiers, uniqueIdentifier, sources
        case discoveredAt, lastSeen, connectionStatus, lastConnectedAt
        case lastCryptoKind, lastCryptoSuite, guardStatus
        case isLocalDevice, isAuthorized, signalStrength, isConnectable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        deviceType = try container.decode(DeviceClassifier.DeviceType.self, forKey: .deviceType)
        ipv4 = try container.decodeIfPresent(String.self, forKey: .ipv4)
        ipv6 = try container.decodeIfPresent(String.self, forKey: .ipv6)
        platformName = try container.decodeIfPresent(String.self, forKey: .platformName)
        osVersion = try container.decodeIfPresent(String.self, forKey: .osVersion)
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        chip = try container.decodeIfPresent(String.self, forKey: .chip)
        macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress)
        serialNumber = try container.decodeIfPresent(String.self, forKey: .serialNumber)
        connectionTypes = try container.decode(Set<DeviceConnectionType>.self, forKey: .connectionTypes)
        services = try container.decode([String].self, forKey: .services)
        portMap = try container.decode([String: Int].self, forKey: .portMap)
        routeIdentifiers = try container.decodeIfPresent([String].self, forKey: .routeIdentifiers) ?? []
        uniqueIdentifier = try container.decode(String.self, forKey: .uniqueIdentifier)
        if routeIdentifiers.isEmpty {
            let normalized = uniqueIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.hasPrefix("bonjour:") || normalized.hasPrefix("recent:bonjour:") {
                routeIdentifiers = [uniqueIdentifier]
            }
        }
        sources = try container.decode([DeviceSource].self, forKey: .sources)
        discoveredAt = try container.decode(Date.self, forKey: .discoveredAt)
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        connectionStatus = try container.decode(OnlineDeviceStatus.self, forKey: .connectionStatus)
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        lastCryptoKind = try container.decodeIfPresent(String.self, forKey: .lastCryptoKind)
        lastCryptoSuite = try container.decodeIfPresent(String.self, forKey: .lastCryptoSuite)
        guardStatus = try container.decodeIfPresent(String.self, forKey: .guardStatus)
        isLocalDevice = try container.decode(Bool.self, forKey: .isLocalDevice)
        isAuthorized = try container.decode(Bool.self, forKey: .isAuthorized)
        signalStrength = try container.decodeIfPresent(Double.self, forKey: .signalStrength)
        isConnectable = try container.decodeIfPresent(Bool.self, forKey: .isConnectable) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(deviceType, forKey: .deviceType)
        try container.encodeIfPresent(ipv4, forKey: .ipv4)
        try container.encodeIfPresent(ipv6, forKey: .ipv6)
        try container.encodeIfPresent(platformName, forKey: .platformName)
        try container.encodeIfPresent(osVersion, forKey: .osVersion)
        try container.encodeIfPresent(modelName, forKey: .modelName)
        try container.encodeIfPresent(chip, forKey: .chip)
        try container.encodeIfPresent(macAddress, forKey: .macAddress)
        try container.encodeIfPresent(serialNumber, forKey: .serialNumber)
        try container.encode(connectionTypes, forKey: .connectionTypes)
        try container.encode(services, forKey: .services)
        try container.encode(portMap, forKey: .portMap)
        try container.encode(routeIdentifiers, forKey: .routeIdentifiers)
        try container.encode(uniqueIdentifier, forKey: .uniqueIdentifier)
        try container.encode(sources, forKey: .sources)
        try container.encode(discoveredAt, forKey: .discoveredAt)
        try container.encode(lastSeen, forKey: .lastSeen)
        try container.encode(connectionStatus, forKey: .connectionStatus)
        try container.encodeIfPresent(lastConnectedAt, forKey: .lastConnectedAt)
        try container.encodeIfPresent(lastCryptoKind, forKey: .lastCryptoKind)
        try container.encodeIfPresent(lastCryptoSuite, forKey: .lastCryptoSuite)
        try container.encodeIfPresent(guardStatus, forKey: .guardStatus)
        try container.encode(isLocalDevice, forKey: .isLocalDevice)
        try container.encode(isAuthorized, forKey: .isAuthorized)
        try container.encodeIfPresent(signalStrength, forKey: .signalStrength)
        try container.encode(isConnectable, forKey: .isConnectable)
    }
}
#endif
