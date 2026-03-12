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

 // MARK: - 私有属性

    private let logger = Logger(subsystem: "com.skybridge.unified", category: "OnlineDeviceManager")

 /// 设备去重映射表: 唯一标识符 -> OnlineDevice
    private var deviceMap: [String: OnlineDevice] = [:]

 /// 设备持久化存储
    private let storage = DeviceStorage()

 /// 订阅集合
    private var cancellables = Set<AnyCancellable>()

 /// 子管理器
    private let networkDiscovery = DeviceDiscoveryManagerOptimized()
    private let usbDiscovery = USBDeviceDiscoveryManager()
    private var iCloudDiscovery: iCloudDeviceDiscoveryManager?
 /// 本机所有接口的 IPv4/IPv6 地址集合（缓存）
    private var localIPAddresses: Set<String> = []
 /// 本机物理网卡 MAC 地址集合（缓存）
    private var localMacAddresses: Set<String> = []
 /// 当前物理连接的 USB 设备指纹（用于“USB 在线态”判断）
    private var activeUSBPresenceTokens: Set<String> = []
    private var pathMonitor: NWPathMonitor?

 /// 设备清理定时器(移除长时间离线的设备)
    private var cleanupTimer: Timer?

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
        applyDiscoverySettingsFromGlobalConfig()
        isScanning = true

 // 启动网络发现
        networkDiscovery.startScanning()

 // 启动USB发现
        usbDiscovery.startMonitoring()
        usbDiscovery.scanUSBDevices()

 // 启动iCloud发现
        if iCloudDiscovery == nil {
            iCloudDiscovery = iCloudDeviceDiscoveryManager()
        }
        Task {
            await iCloudDiscovery?.startDiscovery()
        }
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

        isScanning = false
    }

 /// 刷新设备列表
    public func refreshDevices() {
        // UX fix:
        // A hard stop/start here interrupts ongoing handshakes/transfers and causes repeated reconnect loops.
        // We only do a **soft refresh**: apply settings, ensure discovery is running, and trigger lightweight
        // refresh operations that do not tear down listeners/browsers.
        logger.info("🔄 刷新设备列表（软刷新：不停止/不重启发现服务）")
        applyDiscoverySettingsFromGlobalConfig()

        if !isScanning {
            startDiscovery()
            return
        }

        // Lightweight nudges (no stop):
        usbDiscovery.scanUSBDevices()
        if iCloudDiscovery == nil {
            iCloudDiscovery = iCloudDeviceDiscoveryManager()
        }
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

        func applyConnectedStatus(to device: inout OnlineDevice) {
            device.connectionStatus = .connected
            device.lastConnectedAt = Date()
            device.lastCryptoKind = cryptoKind
            device.lastCryptoSuite = suite
            device.guardStatus = guardStatus
            device.lastSeen = Date()
        }

        if let idx = onlineDevices.firstIndex(where: { $0.name == displayName }) {
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
            uniqueIdentifier: normalizedRecentIdentifier,
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

 /// 将全局设置同步到网络设备发现器，以保证 UI 开关生效
    private func applyDiscoverySettingsFromGlobalConfig() {
        let settings = SettingsManager.shared
 // 兼容/更多设备发现开关（影响 Bonjour 服务类型集合）
        networkDiscovery.enableCompatibilityMode = settings.enableCompatibilityMode
 // 是否启用 companion‑link 服务类型（Apple Continuity）
        networkDiscovery.enableCompanionLink = settings.enableCompanionLink
    }

 /// 处理网络设备更新
    private func handleNetworkDevicesUpdate(_ devices: [DiscoveredDevice]) {
        logger.debug("📡 网络设备更新: \(devices.count) 台")

        for device in devices {
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

            mergeOrCreateDevice(
                identifier: identifier,
                name: device.name,
                deviceType: device.deviceType,
                ipv4: device.ipv4,
                ipv6: device.ipv6,
                macAddress: preferredMAC,
                serialNumber: nil,
                connectionTypes: device.connectionTypes,
                services: device.services,
                portMap: device.portMap,
                source: DeviceSource.skybridgeBonjour,
                signalStrength: device.signalStrength,
                isConnectable: !device.services.isEmpty || !device.portMap.isEmpty
            )
        }

        updateDevicesList()
    }

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
                stableDeviceId: nil,
                pubKeyFP: nil,
                macAddress: nil,
                serialNumber: device.id,  // 使用id作为序列号
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
                macAddress: nil,
                serialNumber: device.id,
                connectionTypes: [],
                services: [],
                portMap: [:],
                source: DeviceSource.skybridgeCloud,
                signalStrength: nil,
                isConnectable: true,
                isAuthorized: true
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
        macAddress: String?,
        serialNumber: String?,
        connectionTypes: Set<DeviceConnectionType>,
        services: [String],
        portMap: [String: Int],
        source: DeviceSource,
        signalStrength: Double? = nil,
        isConnectable: Bool = true,
        isAuthorized: Bool = false
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
                macAddress: macAddress,
                serialNumber: serialNumber,
                connectionTypes: connectionTypes,
                services: services,
                portMap: portMap,
                uniqueIdentifier: identifier,
                sources: [source],
                discoveredAt: existingDevice.discoveredAt,
                lastSeen: Date(),
                connectionStatus: existingDevice.connectionStatus,
                lastConnectedAt: existingDevice.lastConnectedAt,
                isLocalDevice: false,
                isAuthorized: isAuthorized || existingDevice.isAuthorized,
                signalStrength: signalStrength,
                isConnectable: isConnectable
            ))
            let upgradedIdentifier = preferredIdentifier(current: existingDevice.uniqueIdentifier, incoming: identifier)
            if upgradedIdentifier != existingDevice.uniqueIdentifier {
                existingDevice = Self.copyDevice(existingDevice, uniqueIdentifier: upgradedIdentifier)
            }
 // 合并完成后基于最新来源/MAC/类型重算本机标记
            existingDevice.isLocalDevice = isLocalCandidate(
                identifier: existingDevice.uniqueIdentifier,
                name: existingDevice.name,
                macAddress: existingDevice.macAddress,
                deviceType: existingDevice.deviceType,
                sources: existingDevice.sources
            )

            deviceMap[identifier] = existingDevice
            deviceMap[upgradedIdentifier] = existingDevice

            logger.debug("🔄 合并设备信息: \(name)")
        } else {
 // 尝试通过其他标识符找到相似设备
            if let similarIdentifier = findSimilarDevice(
                name: name,
                ipv4: ipv4,
                ipv6: ipv6,
                macAddress: macAddress,
                serialNumber: serialNumber
            ) {
 // 找到相似设备,合并
                if var existingDevice = deviceMap[similarIdentifier] {
                    existingDevice = mergeDeviceInfo(existing: existingDevice, new: OnlineDevice(
                        id: existingDevice.id,
                        name: name,
                        deviceType: deviceType,
                        ipv4: ipv4,
                        ipv6: ipv6,
                        macAddress: macAddress,
                        serialNumber: serialNumber,
                        connectionTypes: connectionTypes,
                        services: services,
                        portMap: portMap,
                        uniqueIdentifier: identifier,
                        sources: [source],
                        discoveredAt: existingDevice.discoveredAt,
                        lastSeen: Date(),
                        connectionStatus: existingDevice.connectionStatus,
                        lastConnectedAt: existingDevice.lastConnectedAt,
                        isLocalDevice: false,
                        isAuthorized: isAuthorized || existingDevice.isAuthorized,
                        signalStrength: signalStrength,
                        isConnectable: isConnectable
                    ))
                    let upgradedIdentifier = preferredIdentifier(current: existingDevice.uniqueIdentifier, incoming: identifier)
                    if upgradedIdentifier != existingDevice.uniqueIdentifier {
                        existingDevice = Self.copyDevice(existingDevice, uniqueIdentifier: upgradedIdentifier)
                    }
 // 合并完成后基于最新来源/MAC/类型重算本机标记
                    existingDevice.isLocalDevice = isLocalCandidate(
                        identifier: existingDevice.uniqueIdentifier,
                        name: existingDevice.name,
                        macAddress: existingDevice.macAddress,
                        deviceType: existingDevice.deviceType,
                        sources: existingDevice.sources
                    )

 // 更新两个标识符的映射
                    deviceMap[identifier] = existingDevice
                    deviceMap[similarIdentifier] = existingDevice
                    deviceMap[upgradedIdentifier] = existingDevice

                    logger.debug("🔄 发现相似设备并合并: \(name)")
                }
            } else {
 // 创建新设备
                let newDevice = OnlineDevice(
                    id: UUID(),
                    name: name,
                    deviceType: deviceType,
                    ipv4: ipv4,
                    ipv6: ipv6,
                    macAddress: macAddress,
                    serialNumber: serialNumber,
                    connectionTypes: connectionTypes,
                    services: services,
                    portMap: portMap,
                    uniqueIdentifier: identifier,
                    sources: [source],
                    discoveredAt: Date(),
                    lastSeen: Date(),
                    connectionStatus: .online,
                    lastConnectedAt: nil,
                    isLocalDevice: isLocalCandidate(
                        identifier: identifier,
                        name: name,
                        macAddress: macAddress,
                        deviceType: deviceType,
                        sources: [source]
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
        name: String,
        ipv4: String?,
        ipv6: String?,
        macAddress: String?,
        serialNumber: String?
    ) -> String? {
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

 // 使用更详细的名称
        if new.name.count > existing.name.count {
            merged.name = new.name
        }

 // 合并IP地址
        if merged.ipv4 == nil, let newIp = new.ipv4 {
            merged.ipv4 = newIp
        }
        if merged.ipv6 == nil, let newIp6 = new.ipv6 {
            merged.ipv6 = newIp6
        }

 // 合并MAC地址
        if merged.macAddress == nil, let newMac = new.macAddress {
            merged.macAddress = newMac
        }

 // 合并序列号
        if merged.serialNumber == nil, let newSerial = new.serialNumber {
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
        merged.portMap.merge(new.portMap) { current, _ in current }

 // 合并设备来源
        for source in new.sources {
            if !merged.sources.contains(source) {
                merged.sources.append(source)
            }
        }

 // 更新最后发现时间
        merged.lastSeen = Date()

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
        merged.isConnectable = merged.isConnectable || new.isConnectable

        return merged
    }

    private static func copyDevice(_ device: OnlineDevice, uniqueIdentifier: String) -> OnlineDevice {
        OnlineDevice(
            id: device.id,
            name: device.name,
            deviceType: device.deviceType,
            ipv4: device.ipv4,
            ipv6: device.ipv6,
            macAddress: device.macAddress,
            serialNumber: device.serialNumber,
            connectionTypes: device.connectionTypes,
            services: device.services,
            portMap: device.portMap,
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
        return "recent:\(normalizedPeerIdentifier(peerId))"
    }

    private nonisolated static func normalizedPeerIdentifier(_ peerId: String) -> String {
        let trimmed = peerId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("bonjour:") {
            let payload = String(trimmed.dropFirst("bonjour:".count))
            let parts = payload.split(separator: "@", maxSplits: 1).map(String.init)
            let name = parts.first ?? payload
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

        if let stableId = normalizedStableIdentifierPayload(from: device.uniqueIdentifier) {
            aliases.insert(normalizedPeerIdentifier(stableId))
        }

        if device.uniqueIdentifier.hasPrefix("bonjour:") {
            aliases.insert(normalizedPeerIdentifier(device.uniqueIdentifier))
        }

        if device.uniqueIdentifier.hasPrefix("ip:") {
            let payload = String(device.uniqueIdentifier.dropFirst("ip:".count))
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

    private nonisolated static func normalizedStableIdentifierPayload(from uniqueIdentifier: String) -> String? {
        guard uniqueIdentifier.hasPrefix("id:") else { return nil }
        let payload = String(uniqueIdentifier.dropFirst("id:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? nil : payload
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
        uniqueDevices = normalDevices + collapsedRecentDevices

        // Remove deduped-out duplicates from the map so they don't keep resurfacing.
        let retainedIds = Set(uniqueDevices.map(\.id))
        deviceMap = deviceMap.filter { _, device in retainedIds.contains(device.id) }

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

        func normalizedStableIdentifier(from uniqueIdentifier: String) -> String? {
            guard uniqueIdentifier.hasPrefix("id:") else { return nil }
            let payload = String(uniqueIdentifier.dropFirst("id:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return payload.isEmpty ? nil : payload
        }

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

            if let stableId = normalizedStableIdentifier(from: device.uniqueIdentifier),
               (activePeerIds.contains(stableId) ||
                normalizedActivePeerIds.contains(Self.normalizedPeerIdentifier(stableId))) {
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
            let usbAttached = isActivelyAttachedOverUSB(device)
            if usbAttached {
                uniqueDevices[i].lastSeen = now
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
            return true
        }

 // 排序: 本机 > 已连接 > 在线 > 离线
        let sortedDevices = filteredDevices.sorted { lhs, rhs in
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

    private struct CandidateMatchingContext {
        let normalizedOnlineName: String
        let normalizedIPv4: String?
        let normalizedIPv6: String?
        let strongId: String?
        let pubKeyFP: String?
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
            prefersUSB: onlineDevice.connectionTypes.contains(.usb),
            hasStrongIdentityAnchor: strongId != nil || pubKeyFP != nil || onlineDevice.ipv4 != nil || onlineDevice.ipv6 != nil
        )
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
        let nameMatched = {
            guard !context.normalizedOnlineName.isEmpty, !normalizedCandidateName.isEmpty else { return false }
            if normalizedCandidateName == context.normalizedOnlineName { return true }
            let minLength = min(normalizedCandidateName.count, context.normalizedOnlineName.count)
            guard minLength >= 8 else { return false }
            return normalizedCandidateName.contains(context.normalizedOnlineName)
                || context.normalizedOnlineName.contains(normalizedCandidateName)
        }()
        let identityMatched = strongIdMatched || pubKeyMatched || ipv4Matched || ipv6Matched || nameMatched

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

        if ipv4Matched {
            score += 120
        }
        if ipv6Matched {
            score += 110
        }

        if nameMatched {
            score += 60
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
        if context.hasStrongIdentityAnchor, !strongIdMatched && !pubKeyMatched && !ipv4Matched && !ipv6Matched {
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
        if let stable = Self.normalizeStableIdentifier(raw) {
            return "id:\(stable)"
        }
        let normalizedIP = Self.normalizeIPAddress(raw)
        if !normalizedIP.isEmpty, normalizedIP.contains(".") || normalizedIP.contains(":") {
            return "ip:\(normalizedIP)"
        }
        return nil
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

    private nonisolated static func normalizeStableIdentifier(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        guard raw.count >= 8 else { return nil }
        return raw
    }

    private func normalizeFingerprint(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return nil
        }
        guard raw.range(of: "^[0-9a-f]{16,128}$", options: .regularExpression) != nil else { return nil }
        return raw
    }

    private func preferredIdentifier(current: String, incoming: String) -> String {
        let currentScore = Self.identifierStrength(current)
        let incomingScore = Self.identifierStrength(incoming)
        if incomingScore > currentScore {
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
        let hostname = Host.current().localizedName ?? "Mac"
        let identifier = "local:\(hostname)"

        let local = OnlineDevice(
            id: UUID(),
            name: hostname,
            deviceType: .computer,
            ipv4: nil,
            ipv6: nil,
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

 /// 严格版：根据来源/设备类型/MAC/名称综合判定是否为本机候选（避免 DHCP/IP 复用导致误判）
    private func isLocalCandidate(
        identifier: String,
        name: String,
        macAddress: String?,
        deviceType: DeviceClassifier.DeviceType,
        sources: [DeviceSource]
    ) -> Bool {
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
        let hostname = Host.current().localizedName ?? ""
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

 // 移除超时且没有连接历史的设备
        deviceMap = deviceMap.filter { _, device in
            if device.isLocalDevice {
                return true // 保留本机
            }

            if device.lastConnectedAt != nil || device.isAuthorized {
                return true // 保留有历史的设备
            }

            return now.timeIntervalSince(device.lastSeen) < timeout
        }

        updateDevicesList()
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

/// 在线设备
public struct OnlineDevice: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var deviceType: DeviceClassifier.DeviceType
    public var ipv4: String?
    public var ipv6: String?
    public var macAddress: String?
    public var serialNumber: String?
    public var connectionTypes: Set<DeviceConnectionType>
    public var services: [String]
    public var portMap: [String: Int]
    public let uniqueIdentifier: String
    public var sources: [DeviceSource]
    public let discoveredAt: Date
    public var lastSeen: Date
    public var connectionStatus: OnlineDeviceStatus
    public var lastConnectedAt: Date?
    /// Best-effort crypto info for last successful handshake (UI-only).
    public var lastCryptoKind: String?
    public var lastCryptoSuite: String?
    /// UI hint: whether we are actively guarding this connection (keepalive enabled).
    public var guardStatus: String?
    public var isLocalDevice: Bool
    public var isAuthorized: Bool
    public var signalStrength: Double? = nil
    public var isConnectable: Bool = true

    public static func == (lhs: OnlineDevice, rhs: OnlineDevice) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// DeviceSource 定义已移至 Models.swift，此处不再重复定义

/// 在线设备状态（用于UnifiedOnlineDeviceManager）
public enum OnlineDeviceStatus: String, Sendable, Codable {
    case connected = "已连接"
    case online = "在线"
    case offline = "离线"

    var priority: Int {
        switch self {
        case .connected: return 3
        case .online: return 2
        case .offline: return 1
        }
    }
}

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
        var devices = loadDevices()

 // 移除旧版本
        devices.removeAll { $0.id == device.id }

 // 添加新版本
        devices.append(device)

 // 只保留最近100台设备
        if devices.count > 100 {
            devices = Array(devices.suffix(100))
        }

        do {
 // V2 写入使用包装结构，包含 schemaVersion。
            let payload = PersistedDevicesPayload(schemaVersion: schemaVersion, devices: devices)
            let data = try JSONEncoder().encode(payload)
            userDefaults.set(data, forKey: storageKey)
            logger.debug("💾 保存设备: \(device.name)")
        } catch {
            logger.error("❌ 保存设备失败: \(error.localizedDescription)")
        }
    }

    func loadDevices() -> [OnlineDevice] {
        guard let data = userDefaults.data(forKey: storageKey) else {
            return []
        }

 // 优先按 V2 格式解析。
        if let payload = try? JSONDecoder().decode(PersistedDevicesPayload.self, from: data) {
            if payload.schemaVersion == schemaVersion {
                logger.debug("📂 加载设备(V2): \(payload.devices.count) 台")
                return payload.devices
            } else {
 // 检测到非当前版本，直接丢弃以避免结构不兼容。
                logger.warning("检测到旧版设备缓存(schemaVersion=\(payload.schemaVersion))，将清空缓存重建")
                userDefaults.removeObject(forKey: storageKey)
                return []
            }
        }

 // 兼容旧版(V1)——直接存储为 [OnlineDevice] 的情况，成功则迁移为 V2。
        if let legacyDevices = try? JSONDecoder().decode([OnlineDevice].self, from: data) {
            logger.info("📂 检测到旧版设备缓存(V1)，执行一次性迁移: \(legacyDevices.count) 台")
 // 写回为 V2 格式。
            let payload = PersistedDevicesPayload(schemaVersion: schemaVersion, devices: legacyDevices)
            if let encoded = try? JSONEncoder().encode(payload) {
                userDefaults.set(encoded, forKey: storageKey)
                logger.debug("🔄 设备缓存已升级至 V2")
            }
            return legacyDevices
        }

 // 两种格式均解析失败，视为损坏缓存，直接清理。
        logger.warning("加载设备失败：缓存格式不可解析，将清空缓存重建")
        userDefaults.removeObject(forKey: storageKey)
        return []
    }
}

// MARK: - Codable 支持

extension OnlineDevice: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, deviceType, ipv4, ipv6, macAddress, serialNumber
        case connectionTypes, services, portMap, uniqueIdentifier, sources
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
        macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress)
        serialNumber = try container.decodeIfPresent(String.self, forKey: .serialNumber)
        connectionTypes = try container.decode(Set<DeviceConnectionType>.self, forKey: .connectionTypes)
        services = try container.decode([String].self, forKey: .services)
        portMap = try container.decode([String: Int].self, forKey: .portMap)
        uniqueIdentifier = try container.decode(String.self, forKey: .uniqueIdentifier)
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
        try container.encodeIfPresent(macAddress, forKey: .macAddress)
        try container.encodeIfPresent(serialNumber, forKey: .serialNumber)
        try container.encode(connectionTypes, forKey: .connectionTypes)
        try container.encode(services, forKey: .services)
        try container.encode(portMap, forKey: .portMap)
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
