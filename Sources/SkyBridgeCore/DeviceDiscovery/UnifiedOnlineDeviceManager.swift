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
        logger.info("🔄 刷新设备列表")
 // 刷新前同步一次设置，确保下一次启动使用最新开关状态
        applyDiscoverySettingsFromGlobalConfig()
        
        stopDiscovery()
        
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            startDiscovery()
        }
    }
    
 /// 根据ID查找设备
    public func device(withId id: UUID) -> OnlineDevice? {
        return onlineDevices.first { $0.id == id }
    }
    
 /// 根据唯一标识符查找设备
    public func device(withIdentifier identifier: String) -> OnlineDevice? {
        return deviceMap[identifier]
    }
    
 /// 标记设备为已连接
    public func markDeviceAsConnected(_ deviceId: UUID) {
        guard let index = onlineDevices.firstIndex(where: { $0.id == deviceId }) else { return }
        
        var device = onlineDevices[index]
        device.connectionStatus = .connected
        device.lastConnectedAt = Date()
        
        onlineDevices[index] = device
        deviceMap[device.uniqueIdentifier] = device
        
 // 持久化
        storage.saveDevice(device)
        
        logger.info("✅ 设备标记为已连接: \(device.name)")
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
            let identifier = generateUniqueIdentifier(
                macAddress: device.uniqueIdentifier,
                serialNumber: nil,
                name: device.name,
                ipv4: device.ipv4,
                ipv6: device.ipv6
            )
            
            mergeOrCreateDevice(
                identifier: identifier,
                name: device.name,
                deviceType: device.deviceType,
                ipv4: device.ipv4,
                ipv6: device.ipv6,
                macAddress: device.uniqueIdentifier,
                serialNumber: nil,
                connectionTypes: device.connectionTypes,
                services: device.services,
                portMap: device.portMap,
                source: DeviceSource.skybridgeBonjour
            )
        }
        
        updateDevicesList()
    }
    
 /// 处理USB设备更新
    private func handleUSBDevicesUpdate(_ devices: [USBDevice]) {
        logger.debug("🔌 USB设备更新: \(devices.count) 台")
        
        for device in devices {
            let identifier = generateUniqueIdentifier(
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
                source: DeviceSource.skybridgeUSB
            )
        }
        
        updateDevicesList()
    }
    
 /// 处理iCloud设备更新
    private func handleiCloudDevicesUpdate(_ devices: [iCloudDevice]) {
        logger.debug("☁️ iCloud设备更新: \(devices.count) 台")
        
        for device in devices {
            let identifier = generateUniqueIdentifier(
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
                isAuthorized: isAuthorized || existingDevice.isAuthorized
            ))
 // 合并完成后基于最新来源/MAC/类型重算本机标记
            existingDevice.isLocalDevice = isLocalCandidate(
                identifier: existingDevice.uniqueIdentifier,
                name: existingDevice.name,
                macAddress: existingDevice.macAddress,
                deviceType: existingDevice.deviceType,
                sources: existingDevice.sources
            )
            
            deviceMap[identifier] = existingDevice
            
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
                        isAuthorized: isAuthorized || existingDevice.isAuthorized
                    ))
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
                    isAuthorized: isAuthorized
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
        
        return merged
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
        
 // 更新设备状态
        for i in 0..<uniqueDevices.count {
            let device = uniqueDevices[i]
            let timeSinceLastSeen = now.timeIntervalSince(device.lastSeen)
            
 // 判断设备状态
            if device.isLocalDevice {
                uniqueDevices[i].connectionStatus = .connected
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
        
 // 过滤设备:
 // 1. 本机(始终显示)
 // 2. 在线设备
 // 3. 最近60秒内出现的设备
 // 4. 有连接历史的设备
 // 5. 已授权的设备
        let filteredDevices = uniqueDevices.filter { device in
            device.isLocalDevice ||
            device.connectionStatus == .online ||
            device.connectionStatus == .connected ||
            now.timeIntervalSince(device.lastSeen) < 60 ||
            device.lastConnectedAt != nil ||
            device.isAuthorized
        }
        
 // 排序: 本机 > 已连接 > 在线 > 离线
        onlineDevices = filteredDevices.sorted { lhs, rhs in
            if lhs.isLocalDevice != rhs.isLocalDevice {
                return lhs.isLocalDevice
            }
            
            if lhs.connectionStatus != rhs.connectionStatus {
                return lhs.connectionStatus.priority > rhs.connectionStatus.priority
            }
            
            return lhs.name < rhs.name
        }
        
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
    
 /// 生成唯一标识符
    private func generateUniqueIdentifier(
        macAddress: String?,
        serialNumber: String?,
        name: String,
        ipv4: String?,
        ipv6: String?
    ) -> String {
 // 优先级: MAC地址 > 序列号 > IPv4 > IPv6 > 名称
        if let mac = macAddress, !mac.isEmpty {
            return "mac:\(mac.lowercased())"
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
            connectionStatus: .connected,
            lastConnectedAt: Date(),
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
    public var isLocalDevice: Bool
    public var isAuthorized: Bool
    
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
        case isLocalDevice, isAuthorized
    }
}
