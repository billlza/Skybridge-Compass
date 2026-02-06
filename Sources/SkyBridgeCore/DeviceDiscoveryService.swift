import Foundation
@preconcurrency import Combine
import Network
import os.log
import Darwin
import AppKit

/// 发现状态结构体
public struct DiscoveryState {
    public var devices: [DiscoveredDevice]
    public var statusDescription: String

    public init(devices: [DiscoveredDevice], statusDescription: String) {
        self.devices = devices
        self.statusDescription = statusDescription
    }
}

/// 设备发现服务，负责在本地网络中扫描和发现可连接的设备
///
/// 🔄 2025年优化：现在使用 DeviceDiscoveryManagerOptimized 作为底层实现
/// - 自动包含网络设备和USB设备
/// - 自动进行设备去重和合并
/// - 支持连接类型标签（Wi-Fi、USB等）
/// - 🆕 真正使用SettingsManager中的网络设置
///
/// ⚡ Swift 6.2.1 改进：使用 actor 模型确保线程安全
@available(macOS 14.0, *)
@MainActor
public final class DeviceDiscoveryService: ObservableObject {
    private let queue = DispatchQueue(label: "skybridge.discovery")
    private var browsers: [String: NWBrowser] = [:]
    private var latestResults: [String: Set<NWBrowser.Result>] = [:]
    private let subject = CurrentValueSubject<DiscoveryState, Never>(.init(devices: [], statusDescription: "初始化扫描"))
    private let log = Logger(subsystem: "com.skybridge.compass", category: "Discovery")

 /// 单例实例，便于UI层直接调用
    public static let shared = DeviceDiscoveryService()

 // MARK: - 功耗控制

 /// 上次扫描结束时间
    private var lastScanEndTime: Date?
 /// 扫描冷却时间（秒），默认 300 秒
    private let scanCooldown: TimeInterval = 300

 /// Apple Silicon优化器实例
    @available(macOS 14.0, *)
    private var optimizer: AppleSiliconOptimizer? {
        return AppleSiliconOptimizer.shared
    }
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "DeviceDiscoveryService")

 /// 设备名称解析器
    private var deviceNameResolver: DeviceNameResolver?

 /// 2025年优化：使用统一的设备发现管理器（包含网络+USB+去重）
    private var optimizedManager: DeviceDiscoveryManagerOptimized?
    private var cancellables = Set<AnyCancellable>()
 /// 蓝牙设备最新列表（用于融合信号强度）
    private var latestBluetoothDevices: [BluetoothDevice] = []
 /// 信号强度平滑缓存（EMA）
    private var strengthCache: [UUID: Double] = [:]
 /// mDNS TXT 记录缓存（按服务名/主机名存储键值对）
    private var mdnsTXTCache: [String: [String: String]] = [:]
 /// mDNS 设备ID缓存（便捷映射），用于指纹融合
    private var mdnsDeviceIdCache: [String: String] = [:]
 // 指纹采集器与缓存
    private let ssdpDiscovery = SSDPDiscovery()
    private let netFingerprinting = NetworkFingerprinting()
    private var arpCacheIPv4: [String: String] = [:]
    private var ndpCacheIPv6: [String: String] = [:]
    private var ssdpCache: [(usn: String, location: String)] = []

 /// 🆕 设置管理器引用，用于获取网络设置
    @MainActor
    private var settingsManager: SettingsManager {
        SettingsManager.shared
    }

 /// 已发现的设备列表（直接从优化管理器同步）
    @Published public var discoveredDevices: [DiscoveredDevice] = []
    @Published public var isScanning: Bool = false
    private var activeBrowsers: [NWBrowser] = []

 // MARK: - 性能优化：智能扫描机制
 /// 已扫描的IP地址缓存，避免重复扫描
    private var scannedIPs: Set<String> = []
 /// 最后扫描时间记录，用于控制扫描频率
    private var lastScanTimes: [String: Date] = [:]
 /// 动态扫描间隔（秒），根据网络活跃度调整
    private var scanInterval: TimeInterval = 30.0
 /// 设备发现锁，防止并发添加重复设备
    private let discoveryLock = NSLock()

 // 🔧 性能优化：CPU 使用控制（已放宽限制以提高响应速度）
    private var consecutiveScanCount: Int = 0
    private var lastScanCompletionTime: Date?
    private let maxConsecutiveScans = 10 // 连续扫描10次后休眠（放宽）
    private let scanCooldownPeriod: TimeInterval = 2.0 // 2秒冷却期（缩短）
    private var discoveryTimeoutTask: Task<Void, Never>?

 // 🔧 性能优化：端口扫描缓存
    private var portScanCache: [String: [Int: (isOpen: Bool, timestamp: Date)]] = [:]
    private let portCacheExpiration: TimeInterval = 60.0 // 端口状态缓存1分钟（缩短以更快刷新）

 /// 🚀 新增：外部设备发现功能
    private var usbDeviceManager: USBDeviceDiscoveryManager?
    private var bluetoothManager: BluetoothManager?
 /// Wi‑Fi Aware 被动发现（macOS 26+）
    private var wifiAware: WiFiAwareDiscovery?

 /// 🚀 新增：外部设备列表
    @Published public var externalDevices: [String] = []

 /// 🚀 新增：网络活跃度级别
    private var networkActivityLevel: NetworkActivityLevel = .normal

 // MARK: - 智能设备去重

 /// 智能查找是否存在相似设备
 /// 🔧 优化：基于多个标识符进行智能匹配
    private func findSimilarDevice(name: String, ipv4: String?, ipv6: String?, uniqueIdentifier: String?) -> Int? {
        return discoveredDevices.firstIndex { existing in
 // 1. 检查唯一标识符（最可靠）
            if let uid = uniqueIdentifier, let existingUid = existing.uniqueIdentifier,
               !uid.isEmpty, !existingUid.isEmpty {
                if uid == existingUid {
                    return true
                }
            }

 // 2. 检查 IP 地址匹配
            if let ip = ipv4, let existingIp = existing.ipv4,
               !ip.isEmpty, !existingIp.isEmpty {
                if ip == existingIp {
                    return true
                }
            }

            if let ip6 = ipv6, let existingIp6 = existing.ipv6,
               !ip6.isEmpty, !existingIp6.isEmpty {
                if ip6 == existingIp6 {
                    return true
                }
            }

 // 3. 检查名称相似度（去除常见前缀后比较）
            let normalizedName = normalizeDeviceName(name)
            let normalizedExisting = normalizeDeviceName(existing.name)

            if !normalizedName.isEmpty && normalizedName == normalizedExisting {
                return true
            }

 // 4. 检查名称包含关系（处理长短名称）
            if name.contains(existing.name) || existing.name.contains(name) {
 // 名称有包含关系，且长度差异不大
                let lengthDiff = abs(name.count - existing.name.count)
                if lengthDiff < 20 {  // 允许一定的长度差异
                    return true
                }
            }

            return false
        }
    }

 /// 标准化设备名称（去除常见前缀和后缀）
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
        normalized = normalized.replacingOccurrences(of: " ", with: "")
                                .replacingOccurrences(of: "-", with: "")
                                .replacingOccurrences(of: "_", with: "")

        return normalized
    }

 /// 合并设备信息
    private func mergeDeviceInfo(existingIndex: Int, newDevice: DiscoveredDevice) {
        let existing = discoveredDevices[existingIndex]

 // 合并 IP 地址
        let mergedIPv4 = existing.ipv4 ?? newDevice.ipv4
        let mergedIPv6 = existing.ipv6 ?? newDevice.ipv6

 // 合并服务列表
        var mergedServices = existing.services
        for service in newDevice.services {
            if !mergedServices.contains(service) {
                mergedServices.append(service)
            }
        }

 // 合并端口映射
        var mergedPortMap = existing.portMap
        for (key, value) in newDevice.portMap {
            mergedPortMap[key] = value
        }

 // 合并连接类型
        var mergedConnectionTypes = existing.connectionTypes
        mergedConnectionTypes.formUnion(newDevice.connectionTypes)

 // 更新唯一标识符（如果新的更详细）
        let mergedUniqueId = existing.uniqueIdentifier ?? newDevice.uniqueIdentifier

 // 更新信号强度
        let mergedStrength = newDevice.signalStrength ?? existing.signalStrength

 // 使用更详细的名称
        let mergedName = newDevice.name.count > existing.name.count ? newDevice.name : existing.name

 // 创建新的合并设备对象
        let merged = DiscoveredDevice(
            id: existing.id,  // 保持原有 ID
            name: mergedName,
            ipv4: mergedIPv4,
            ipv6: mergedIPv6,
            services: mergedServices,
            portMap: mergedPortMap,
            connectionTypes: mergedConnectionTypes,
            uniqueIdentifier: mergedUniqueId,
            signalStrength: mergedStrength
        )

        discoveredDevices[existingIndex] = merged
        logger.debug("🔄 合并设备信息: \(merged.name) (IP: \(mergedIPv4 ?? "无"), 服务: \(mergedServices.count)个)")
    }

 /// 网络活跃度等级
    private enum NetworkActivityLevel: CaseIterable, CustomStringConvertible {
        case low    // 低活跃度：扫描间隔60秒
        case normal // 正常活跃度：扫描间隔30秒
        case high   // 高活跃度：扫描间隔15秒

        var scanInterval: TimeInterval {
            switch self {
            case .low: return 60.0
            case .normal: return 30.0
            case .high: return 15.0
            }
        }

 /// 字符串描述
        var description: String {
            switch self {
            case .low: return "低"
            case .normal: return "正常"
            case .high: return "高"
            }
        }
    }

    public var discoveryState: AnyPublisher<DiscoveryState, Never> {
        subject.eraseToAnyPublisher()
    }

    public init() {
        Task { @MainActor in
 // 初始化设备名称解析器
            self.deviceNameResolver = DeviceNameResolver()

 // 🔄 初始化优化的设备发现管理器
            self.optimizedManager = DeviceDiscoveryManagerOptimized()
            self.setupOptimizedManagerBinding()

 // 🚀 初始化外部设备管理器
             self.usbDeviceManager = USBDeviceDiscoveryManager()
             self.bluetoothManager = BluetoothManager()
             self.logger.info("外部设备管理器初始化完成")

 // 订阅蓝牙设备列表，用于融合信号强度
             self.bluetoothManager?.$discoveredDevices
                 .receive(on: DispatchQueue.main)
                 .sink { [weak self] devices in
                     self?.latestBluetoothDevices = devices
                 }
                 .store(in: &self.cancellables)

 // 设置生命周期通知
            self.setupLifecycleNotifications()
        }
    }

    nonisolated deinit {
        SkyBridgeLogger.discovery.traceOnly("🗑 DeviceDiscoveryService 正在销毁，清理资源...")
 // Swift 6.2.1 最佳实践：在 nonisolated deinit 中只清理可以安全访问的资源
 // 移除通知观察者（这是安全的，因为 self 引用本身是可用的）
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
 // 注意：不要在 deinit 中访问 actor-isolated 的属性（如 cancellables）
 // 这些资源会由 ARC 自动释放
    }

 /// 设置应用生命周期通知
    @MainActor
    private func setupLifecycleNotifications() {
 // 应用即将进入活跃状态
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: OperationQueue.main
        ) { [weak self] (notification: Notification) in
            Task { @MainActor in
                guard let self = self else { return }
                // UX fix:
                // Losing/returning focus is extremely common on macOS (switching windows, permission popups, etc).
                // Auto stop/start here causes disruptive churn (re-advertise, reconnect loops, repeated handshakes).
                // Keep discovery running; only do a lightweight refresh if we're currently not scanning.
                SkyBridgeLogger.discovery.debugOnly("🔄 应用恢复活跃（保持设备发现常驻，不重启）")
                if !self.isScanning {
                    await self.start(force: true)
                }
            }
        }

 // 应用即将失去活跃状态
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: OperationQueue.main
        ) { [weak self] (notification: Notification) in
            Task { @MainActor in
                guard self != nil else { return }
                // UX fix:
                // Do NOT stop discovery when app resigns active. This interrupts ongoing handshakes/transfers and
                // leads to reconnect/handshake loops. We keep discovery running in background.
                SkyBridgeLogger.discovery.debugOnly("⏸ 应用失去活跃（保持设备发现常驻，不暂停）")
            }
        }

 // 系统即将休眠
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: OperationQueue.main
        ) { [weak self] (notification: Notification) in
            Task { @MainActor in
                guard let self = self else { return }
                SkyBridgeLogger.discovery.debugOnly("😴 系统即将休眠，完全停止设备发现...")
                self.stop()
                self.stopDiscovery()
                self.stopExternalDeviceScanning()
            }
        }

 // 系统唤醒
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: OperationQueue.main
        ) { [weak self] (notification: Notification) in
            Task { @MainActor in
                guard let self = self else { return }
                SkyBridgeLogger.discovery.debugOnly("🌅 系统已唤醒，延迟重启设备发现...")

 // 延迟重启，等待网络恢复
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3秒

                await self.start()
                self.startExternalDeviceScanning()
            }
        }
    }

 /// 绑定优化管理器的设备列表到本服务
    @MainActor
    private func setupOptimizedManagerBinding() {
        guard let manager = optimizedManager else { return }

 // 使用防抖动机制，结合信号融合与平滑后统一发布到UI
        manager.$discoveredDevices
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                guard let self = self else { return }
                let fused = self.fuseBluetoothStrength(into: devices)
                self.discoveredDevices = fused
                self.subject.send(DiscoveryState(
                    devices: fused,
                    statusDescription: "发现 \(fused.count) 个设备（网络+USB+蓝牙强度）"
                ))
            }
            .store(in: &cancellables)

 // 订阅扫描状态（也添加防抖动）
        manager.$isScanning
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] scanning in
                self?.isScanning = scanning
            }
            .store(in: &cancellables)

 // 🔧 修复：订阅兼容模式开关，同步到 optimizedManager
        self.settingsManager.$enableCompatibilityMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self = self else { return }
                self.optimizedManager?.enableCompatibilityMode = enabled
                self.logger.info("兼容模式开关已同步: \(enabled)")
            }
            .store(in: &cancellables)

 // 🔧 修复：订阅 companion-link 开关，同步到 optimizedManager
        self.settingsManager.$enableCompanionLink
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self = self else { return }
                self.optimizedManager?.enableCompanionLink = enabled
                self.logger.info("Companion Link开关已同步: \(enabled)")
            }
            .store(in: &cancellables)

 // 🔧 修复：初始化时同步当前值，避免首次扫描使用默认 false
        manager.enableCompatibilityMode = self.settingsManager.enableCompatibilityMode
        manager.enableCompanionLink = self.settingsManager.enableCompanionLink
        logger.info("初始开关状态已同步 - 兼容模式: \(self.settingsManager.enableCompatibilityMode), Companion Link: \(self.settingsManager.enableCompanionLink)")

 // 为优化管理器注入外部候选指纹提供者（SSDP/ARP/HTTP）。
        manager.setFingerprintProvider { [weak self] device in
            guard let self = self else { return nil }
            return await self.makeFingerprint(for: device)
        }
    }

 /// 融合蓝牙RSSI并应用强度平滑，输出带有真实强度分值的设备列表
    @MainActor
    private func fuseBluetoothStrength(into devices: [DiscoveredDevice]) -> [DiscoveredDevice] {
        var result: [DiscoveredDevice] = []
        for dev in devices {
            var strength = dev.signalStrength ?? 0.0
            if let bt = matchBluetooth(for: dev) {
                let btStrength = bt.signalStrengthPercentage
                strength = max(strength, btStrength)
            }
            let alpha = min(0.95, max(0.1, SettingsManager.shared.signalStrengthAlpha))
            let smoothed = (strengthCache[dev.id] ?? strength) * alpha + strength * (1.0 - alpha)
            strengthCache[dev.id] = smoothed
            var updated = dev
            updated.signalStrength = smoothed
            result.append(updated)
        }
        return result
    }

 /// 指纹匹配蓝牙设备：优先使用唯一标识/广告数据，其次名称近似匹配，最后按高RSSI选择
    @MainActor
    private func matchBluetooth(for device: DiscoveredDevice) -> BluetoothDevice? {
        let nameTarget = sanitize(device.name)
        let uidTarget = sanitize(device.uniqueIdentifier ?? "")
        var candidates: [BluetoothDevice] = []
        for bt in latestBluetoothDevices {
            let btName = sanitize(bt.name ?? "")
            let adv = bt.advertisementData.values.map { sanitize($0) }
 // 唯一指纹匹配（名称或广告数据包含UID/MAC/BSSID等片段）
            let uidMatched = !uidTarget.isEmpty && (btName.contains(uidTarget) || adv.contains(where: { $0.contains(uidTarget) }))
 // 名称近似匹配
            let nameMatched = !nameTarget.isEmpty && (btName == nameTarget || btName.contains(nameTarget) || nameTarget.contains(btName))
            if uidMatched || nameMatched { candidates.append(bt) }
        }
        if candidates.isEmpty { return nil }
 // 选择RSSI最高的候选作为匹配结果
        return candidates.max(by: { $0.rssi < $1.rssi })
    }

 /// 名称清理（去除非字母数字并小写）
 ///
 /// ⚡ Swift 6.2.1 优化：使用更高效的字符串处理
    @MainActor
    private func sanitize(_ s: String) -> String {
        return s.unicodeScalars
            .lazy
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map { Character($0) }
            .reduce(into: "") { $0.append($1) }
            .lowercased()
    }

    public func start(force: Bool = false) async {
 // 🔋 功耗控制：检查冷却时间
        if !force, let lastEnd = lastScanEndTime {
            let elapsed = Date().timeIntervalSince(lastEnd)
            if elapsed < scanCooldown {
                let remaining = Int(scanCooldown - elapsed)
                logger.info("⏳ 扫描处于冷却期，跳过本次扫描 (剩余 \(remaining) 秒)")
                SkyBridgeLogger.discovery.debugOnly("DeviceDiscoveryService: 扫描冷却中，跳过")
                return
            }
        }

        SkyBridgeLogger.discovery.debugOnly("🔍 DeviceDiscoveryService: 开始设备发现 (强制: \(force))")
        logger.info("开始设备发现")

 // 🔄 仅被动发现：禁止任何主动端口/NWConnection可达性探测
        let passive = SettingsManager.shared.discoveryPassiveMode
        if passive {
            logger.info("被动发现模式已启用：不进行主动端口探测/试连")
        }

 // 🔄 2025年优化：使用优化管理器启动扫描（该管理器应遵守被动模式）
        await MainActor.run {
            optimizedManager?.startScanning()
        }
 // 初始化指纹缓存（ARP/NDP/SSDP），避免阻塞主线程。
        await refreshFingerprintCaches()

 // 保留旧的浏览器启动逻辑（作为备用）
        await withTaskGroup(of: Void.self) { group in
            for (type, browser) in browsers {
                group.addTask { [weak self] in
                    await self?.startBrowser(browser, type: type)
                }
            }
        }

 // 可选：启动 Wi‑Fi Aware 被动发现（macOS 26+ 可用）
        if SettingsManager.shared.enableWiFiAwareDiscovery {
            if wifiAware == nil { wifiAware = WiFiAwareDiscovery() }
 // 合并 Wi‑Fi Aware 发现事件到设备列表（仅被动、无连接）
            wifiAware?.onPeerDiscovered = { [weak self] peer in
                Task { @MainActor in
                    guard let self = self else { return }
 // 基于名称与近邻ID做去重
                    let idx = self.findSimilarDevice(name: peer.name, ipv4: nil, ipv6: nil, uniqueIdentifier: peer.id)
                    let newDevice = DiscoveredDevice(
                        id: idx.flatMap { self.discoveredDevices[$0].id } ?? UUID(),
                        name: peer.name,
                        ipv4: nil,
                        ipv6: nil,
                        services: ["wifi_aware"],
                        portMap: [:],
                        connectionTypes: [.wifi],
                        uniqueIdentifier: peer.id,
                        signalStrength: nil
                    )
                    if let i = idx {
                        self.mergeDeviceInfo(existingIndex: i, newDevice: newDevice)
                    } else {
                        self.discoveredDevices.append(newDevice)
                    }
                }
            }
            wifiAware?.onPeerLost = { [weak self] peerId in
                Task { @MainActor in
                    guard let self = self else { return }
 // 从列表中移除匹配 uniqueIdentifier 的 Aware 设备（仅当没有其它来源支撑时）
                    if let idx = self.discoveredDevices.firstIndex(where: { $0.uniqueIdentifier == peerId && ($0.services == ["wifi_aware"] || $0.services.isEmpty) }) {
                        self.discoveredDevices.remove(at: idx)
                    }
                }
            }
            wifiAware?.start()
        }
    }

    private func startBrowser(_ browser: NWBrowser, type: String) async {
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.logger.debug("浏览器已准备就绪: \(type)")
                case .failed(let error):
                    self.logger.error("浏览器失败: \(type) - \(error)")
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor in
                guard let self = self else { return }
                self.latestResults[type] = results
                self.publishResults()
            }
        }

        browser.start(queue: queue)
    }

    @MainActor
    private func publishResults() {
        var allDevices: [DiscoveredDevice] = []

        for (serviceType, results) in latestResults {
            for result in results {
                if case let .service(name: name, type: _, domain: _, interface: _) = result.endpoint {
                    var resolvedName = name
                    var uniqueId: String? = nil
 // 解析 metadata 的 TXT 记录（使用统一解析器）
                    if case .bonjour(let txtRecord) = result.metadata {
                        let deviceInfo = BonjourTXTParser.extractDeviceInfo(txtRecord)
                        if let devId = deviceInfo.deviceId {
                            uniqueId = devId
                            mdnsDeviceIdCache[resolvedName] = devId
                        }
                        if let host = deviceInfo.hostname ?? deviceInfo.name { resolvedName = host }
                    } else {
 // 回退：尝试 NetService 解析 TXT 记录
                        if case .service(let sName, let sType, _, _) = result.endpoint {
                            let netService = NetService(domain: "local.", type: sType, name: sName)
                            netService.resolve(withTimeout: 0.8)
                            if let data = netService.txtRecordData() {
                                let dict = NetService.dictionary(fromTXTRecord: data)
                                if let devIdData = dict["deviceId"] ?? dict["id"] ?? dict["deviceID"],
                                   let devId = String(data: devIdData, encoding: .utf8) {
                                    uniqueId = devId
                                    mdnsDeviceIdCache[resolvedName] = devId
                                }
                                if let hostData = dict["hostname"] ?? dict["name"],
                                   let host = String(data: hostData, encoding: .utf8) { resolvedName = host }
                            }
                        }
                    }
                    let device = DiscoveredDevice(
                        id: UUID(),
                        name: resolvedName,
                        ipv4: nil,
                        ipv6: nil,
                        services: [serviceType],
                        portMap: [:],
                        connectionTypes: [.wifi],
                        uniqueIdentifier: uniqueId
                    )
                    allDevices.append(device)
                }
            }
        }

 // 将 SSDP 发现结果紧密关联到设备列表，根据 IP 注入唯一标识与服务标签。
        for item in ssdpCache {
            if let host = extractHost(from: item.location), !host.isEmpty {
 // 查找是否已有同 IP 的设备，若有则增强其标识与服务
                if let index = allDevices.firstIndex(where: { $0.ipv4 == host || $0.name.contains(host) }) {
                    let dev = allDevices[index]
                    var services = dev.services
                    if !services.contains("SSDP") { services.append("SSDP") }
                    var ports = dev.portMap
                    ports["SSDP"] = 1900
                    let updated = DiscoveredDevice(
                        id: dev.id,
                        name: dev.name,
                        ipv4: dev.ipv4 ?? host,
                        ipv6: dev.ipv6,
                        services: services,
                        portMap: ports,
                        connectionTypes: dev.connectionTypes.union([.wifi]),
                        uniqueIdentifier: dev.uniqueIdentifier ?? item.usn
                    )
                    allDevices[index] = updated
                } else {
 // 新增基于 SSDP 的网络设备条目
                    let dev = DiscoveredDevice(
                        id: UUID(),
                        name: host,
                        ipv4: host,
                        ipv6: nil,
                        services: ["SSDP"],
                        portMap: ["SSDP": 1900],
                        connectionTypes: [.wifi],
                        uniqueIdentifier: item.usn
                    )
                    allDevices.append(dev)
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.discoveredDevices = allDevices
            self?.subject.send(DiscoveryState(devices: allDevices, statusDescription: "发现 \(allDevices.count) 个设备"))
        }
    }

    public func refresh() {
        logger.debug("刷新设备列表")
        Task {
 // 🔄 2025年优化：重启优化管理器的扫描
            await MainActor.run {
                optimizedManager?.stopScanning()
 // startScanning 内部会检查状态，这里无需额外逻辑
            }
 // 强制重新开始扫描，绕过冷却
            await start(force: true)
        }
    }

    public func stop() {
        SkyBridgeLogger.discovery.debugOnly("⏹️ DeviceDiscoveryService: 停止设备发现")

 // 记录扫描结束时间，用于冷却控制
        lastScanEndTime = Date()

 // 🔄 2025年优化：停止优化管理器
        Task { @MainActor in
            optimizedManager?.stopScanning()
        }

 // 停止 Wi‑Fi Aware 被动发现
        wifiAware?.stop()
        wifiAware = nil

        isScanning = false
        for browser in browsers.values {
            browser.cancel()
        }
        logger.info("设备发现已停止")
    }

    public func startDiscovery() async {
        isScanning = true
        SkyBridgeLogger.discovery.debugOnly("🔍 DeviceDiscoveryService: 开始设备发现扫描")
        logger.info("🔍 开始设备发现")

        let isAppleSilicon = await optimizer?.isAppleSilicon ?? false
        if isAppleSilicon {
            SkyBridgeLogger.discovery.debugOnly("🚀 DeviceDiscoveryService: 检测到Apple Silicon，使用优化发现模式")
            logger.info("🚀 检测到Apple Silicon，使用优化发现模式")
            await startOptimizedDiscovery()
        } else {
            SkyBridgeLogger.discovery.debugOnly("⚡ DeviceDiscoveryService: 使用标准发现模式")
            logger.info("⚡ 使用标准发现模式")
            await startStandardDiscovery()
        }
    }

    private func startOptimizedDiscovery() async {
        logger.info("🚀 使用Apple Silicon优化的设备发现")

        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                let passive = settingsManager.discoveryPassiveMode
                var scanTasks: [(String, TaskType)] = []
                if !passive {
                    scanTasks.append(("网络扫描", .networkRequest))
                    scanTasks.append(("端口扫描", .dataAnalysis))
                }
                scanTasks.append(("Bonjour扫描", .networkRequest))

                 logger.info("📋 启动 \(scanTasks.count) 个并行扫描任务")

                 for (taskName, taskType) in scanTasks {
                     group.addTask { @Sendable [weak self] in
                         guard let self = self else { return }

                        let qos = await self.optimizer?.recommendedQoS(for: taskType) ?? .utility
                         self.logger.info("🎯 启动任务: \(taskName) (QoS: \(String(describing: qos)))")

                         await withCheckedContinuation { continuation in
                             let queue = DispatchQueue.global(qos: qos)
                             queue.async {
                                 switch taskName {
                                 case "网络扫描":
                                     Task { await self.performNetworkScan() }
                                 case "端口扫描":
                                     Task { @MainActor in self.performPortScan() }
                                 case "Bonjour扫描":
                                     Task { @MainActor in self.performBonjourScan() }
                                 default:
                                     break
                                 }
                                 continuation.resume()
                             }
                         }
                     }
                 }
            }
        }
    }

    private func startStandardDiscovery() async {
        logger.info("使用标准设备发现")

        Task { @MainActor in
            performBonjourScan()
            if !settingsManager.discoveryPassiveMode {
                await performNetworkScan()
                performPortScan()
            }

 // 使用SettingsManager中的发现超时设置来自动停止扫描
            let discoveryTimeout = TimeInterval(settingsManager.discoveryTimeout)
            discoveryTimeoutTask = SystemOrchestrator.shared.scheduleMain(after: discoveryTimeout) { [weak self] in
                Task { @MainActor in
                    self?.logger.info("⏰ 发现超时，自动停止扫描")
                    // If we have an active secure session, keep discovery/advertising alive.
                    // Otherwise the peer may treat us as "offline" and tear down the guarded connection.
                    if ConnectionPresenceService.shared.isConnected {
                        self?.logger.info("🛡️ 发现超时：检测到已连接会话，保持发现服务运行（不自动停止）")
                        return
                    }
                    self?.stopDiscovery()
                }
            }
        }
    }

 /// 解析 Bonjour 的 NWTXTRecord（已废弃，请使用 BonjourTXTParser）
    @available(*, deprecated, message: "Use BonjourTXTParser.parse instead")
    @MainActor
    private func parseBonjourTXT(_ txtRecord: NWTXTRecord) -> [String: String] {
        return BonjourTXTParser.parse(txtRecord)
    }

 /// 解析 TXT 记录字符串（已废弃，请使用 BonjourTXTParser）
    @available(*, deprecated, message: "Use BonjourTXTParser.parseWithRegex instead")
    @MainActor
    public func parseBonjourTXTString(_ description: String) -> [String: String] {
        return BonjourTXTParser.parseWithRegex(description)
    }

    @MainActor
    private func scheduleTXTBackoffRetries(serviceType: String, name: String, resolvedName: String) {
        let delays: [Double] = [0.3, 0.6]
        for delay in delays {
            Task { [weak self] in
                _ = SystemOrchestrator.shared.scheduleGlobal(qos: .utility, after: delay) {
                    Task { @MainActor in
                        guard let self = self else { return }
                        let netService = NetService(domain: "local.", type: serviceType, name: name)
                        netService.resolve(withTimeout: 0.8)
                        if let data = netService.txtRecordData() {
                            let dict = NetService.dictionary(fromTXTRecord: data)
                            if let devIdData = dict["deviceId"] ?? dict["id"] ?? dict["deviceID"] ?? dict["serial"] ?? dict["mac"] ?? dict["bssid"],
                               let devId = String(data: devIdData, encoding: .utf8) {
                                self.mdnsDeviceIdCache[resolvedName] = devId
                                if let idx = self.discoveredDevices.firstIndex(where: { $0.name == resolvedName }) {
                                    var d = self.discoveredDevices[idx]
                                    d.uniqueIdentifier = devId
                                    self.discoveredDevices[idx] = d
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func performBonjourScan() {
 // 检查是否启用了Bonjour发现
        Task { @MainActor in
            guard settingsManager.enableBonjourDiscovery else {
                logger.debug("🚫 Bonjour发现已禁用")
                return
            }

            logger.info("🔍 开始Bonjour服务扫描（默认精简 + 按需广域）")

 // 默认仅扫描 SkyBridge，自愿启用 companion-link；兼容模式下再扩展其他类型
            var serviceTypes = ["_skybridge._tcp"]
            if settingsManager.enableCompanionLink {
                serviceTypes.append("_companion-link._tcp")
            }
            if settingsManager.enableCompatibilityMode {
                serviceTypes.append(contentsOf: [
                    "_airplay._tcp",
                    "_raop._tcp",
                    "_http._tcp",
                    "_https._tcp",
                    "_ssh._tcp",
                    "_ftp._tcp",
                    "_smb._tcp",
                    "_afpovertcp._tcp",
                    "_printer._tcp",
                    "_ipp._tcp",
                    "_scanner._tcp",
                    "_rdp._tcp",
                    "_vnc._tcp",
                    "_rfb._tcp",
                    "_apple-mobdev2._tcp",
                    "_homekit._tcp",
                    "_hap._tcp"
                ])
            }

 // 如果启用了自定义端口扫描，添加自定义服务类型
            if settingsManager.scanCustomPorts {
                serviceTypes.append(contentsOf: settingsManager.customServiceTypes)
                serviceTypes.append("_custom._tcp")
            }

            for serviceType in serviceTypes { scanBonjourService(serviceType) }
        }
    }

    private func scanBonjourService(_ serviceType: String) {
 // 启用 AWDL 近距直连以提升近距设备发现覆盖范围。
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: params)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.logger.debugOnly("Bonjour浏览器已准备就绪: \(serviceType)")
                case .failed(let error):
                    self?.logger.error("Bonjour浏览器失败: \(serviceType) - \(error.localizedDescription, privacy: .private)")
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor in
                for result in results {
                    if case let .service(name: name, type: _, domain: _, interface: _) = result.endpoint {
                        Task { @MainActor in
 // 根据设置决定是否解析更友好的主机名
                            var resolvedName = name
                            if let self = self, self.settingsManager.enableMDNSResolution {
                                if let hostname = self.resolveHostname(for: name) {
                                    resolvedName = hostname
                                    self.logger.debug("🔍 mDNS解析成功: \(name) -> \(hostname)")
                                }
                            } else {
                                self?.logger.debug("🚫 mDNS解析已禁用，使用原始名称")
                            }
 // 解析 Bonjour TXT 记录，填充 mdnsDeviceID（使用统一解析器）
                            if case .bonjour(let txtRecord) = result.metadata, let strongSelf = self {
                                let parsed = BonjourTXTParser.parse(txtRecord)
                                if !parsed.isEmpty {
                                    strongSelf.mdnsTXTCache[resolvedName] = parsed
                                    let deviceInfo = BonjourTXTParser.extractDeviceInfo(from: parsed)
                                    if let deviceId = deviceInfo.deviceId {
                                        strongSelf.mdnsDeviceIdCache[resolvedName] = deviceId
                                    }
                                }
                            }
                            let device = DiscoveredDevice(
                                id: UUID(),
                                name: resolvedName,
                                ipv4: nil,
                                ipv6: nil,
                                services: [serviceType],
                                portMap: [:],
                                connectionTypes: [.wifi],
                                uniqueIdentifier: self?.mdnsDeviceIdCache[resolvedName]
                            )

 // 🔧 智能去重：使用新的智能匹配函数
                            if let existingIndex = self?.findSimilarDevice(
                                name: resolvedName,
                                ipv4: nil,
                                ipv6: nil,
                                uniqueIdentifier: self?.mdnsDeviceIdCache[resolvedName]
                            ) {
 // 设备已存在，合并信息
                                self?.mergeDeviceInfo(existingIndex: existingIndex, newDevice: device)
                                self?.logger.debugOnly("🔄 Bonjour: 合并设备 \(resolvedName)")
                            } else {
 // 新设备，添加到列表
                                self?.discoveredDevices.append(device)
                                self?.logger.debugOnly("✅ Bonjour: 发现新设备 \(resolvedName)")
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                                guard let self = self else { return }
                                let netService = NetService(domain: "local.", type: serviceType, name: name)
                                netService.resolve(withTimeout: 0.8)
                                if let data = netService.txtRecordData() {
                                    let dict = NetService.dictionary(fromTXTRecord: data)
                                    if let devIdData = dict["deviceId"] ?? dict["id"] ?? dict["deviceID"],
                                       let devId = String(data: devIdData, encoding: .utf8) {
                                        self.mdnsDeviceIdCache[resolvedName] = devId
                                        if let idx = self.discoveredDevices.firstIndex(where: { $0.name == resolvedName }) {
                                            var d = self.discoveredDevices[idx]
                                            d.uniqueIdentifier = devId
                                            self.discoveredDevices[idx] = d
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        activeBrowsers.append(browser)
        browser.start(queue: queue)
    }

 /// 执行网络扫描
    private func performNetworkScan() async {
        if settingsManager.discoveryPassiveMode { return }
        SkyBridgeLogger.discovery.debugOnly("🌐 DeviceDiscoveryService: 开始网络扫描")
        logger.info("🌐 开始网络扫描")

        guard let localIP = getLocalIPAddress() else {
            SkyBridgeLogger.discovery.debugOnly("❌ DeviceDiscoveryService: 无法获取本地IP地址")
            logger.error("无法获取本地IP地址")
            return
        }

        SkyBridgeLogger.discovery.debugOnly("📍 DeviceDiscoveryService: 本地IP地址: \(localIP)")
        logger.debugOnly("本地IP地址: \(localIP)")

        let subnet = parseSubnet(from: localIP)
        SkyBridgeLogger.discovery.debugOnly("🔍 DeviceDiscoveryService: 扫描网段: \(subnet)")
        logger.debugOnly("扫描网段: \(subnet)")

 // 优化扫描策略：跳过本机IP和广播地址
        let hostLastOctet = Int(localIP.split(separator: ".").last ?? "0") ?? 0

        let coreCount = ProcessInfo.processInfo.processorCount
        SkyBridgeLogger.discovery.debugOnly("💻 DeviceDiscoveryService: 处理器核心数: \(coreCount)")
        logger.debugOnly("处理器核心数: \(coreCount)")

        let isAppleSilicon = await optimizer?.isAppleSilicon ?? false
        if coreCount >= 8 || isAppleSilicon {
            SkyBridgeLogger.discovery.debugOnly("⚡ DeviceDiscoveryService: 使用并行扫描策略")
            logger.info("使用并行扫描策略")
            performParallelNetworkScan(networkBase: subnet, skipOctet: hostLastOctet)
        } else {
            SkyBridgeLogger.discovery.debugOnly("🔄 DeviceDiscoveryService: 使用顺序扫描策略")
            logger.info("使用顺序扫描策略")
            performSequentialNetworkScan(networkBase: subnet, skipOctet: hostLastOctet)
        }
    }

 /// 刷新指纹缓存（ARP/NDP/SSDP）。
    private func refreshFingerprintCaches() async {
        async let arp = netFingerprinting.fetchARPTable()
        async let ndp = netFingerprinting.fetchNDPTable()
        async let ssdp = ssdpDiscovery.searchOnce()
        let (a, n, s) = await (arp, ndp, ssdp)
        arpCacheIPv4 = a
        ndpCacheIPv6 = n
        ssdpCache = s
        logger.info("指纹缓存刷新完成 - ARP: \(a.count), NDP: \(n.count), SSDP: \(s.count)")
    }

 /// 为指定设备生成候选稳定指纹（不阻塞UI）。
    private func makeFingerprint(for device: DiscoveredDevice) async -> IdentityFingerprint? {
        let cached = await IdentityResolver.WeakFingerprintStore.shared.load(for: device)
        let ip4 = device.ipv4
        let ip6 = device.ipv6
        let mac = ip4.flatMap { arpCacheIPv4[$0] } ?? ip6.flatMap { ndpCacheIPv6[$0] } ?? cached?.macAddress
        var httpServer: String? = cached?.httpServer
        if (httpServer == nil || httpServer?.isEmpty == true),
           !settingsManager.discoveryPassiveMode,
           settingsManager.scanCustomPorts,
           let ip4 {
            httpServer = await netFingerprinting.fetchHTTPServerHeader(ip: ip4)
        }
        var usn: String?
        if let ip = ip4 ?? ip6 {
            for item in ssdpCache {
                if let locHost = extractHost(from: item.location), locHost == ip {
                    usn = item.usn
                    break
                }
            }
        }
        let portSpectrum = IdentityResolver.computePortSpectrumHash(from: device.portMap)
        var fp = IdentityFingerprint(
            pairedID: nil,
            macAddress: mac,
            usnUUID: usn ?? cached?.usnUUID,
            usbSerial: device.uniqueIdentifier,
            mdnsDeviceID: nil,
            hostname: device.name,
            model: nil,
            httpServer: httpServer,
            portSpectrumHash: portSpectrum,
            ipv4: device.ipv4,
            ipv6: device.ipv6,
            primaryConnectionType: device.primaryConnectionType.rawValue
        )
        if let cached {
            fp = IdentityFingerprint(
                pairedID: fp.pairedID ?? cached.pairedID,
                macAddress: fp.macAddress ?? cached.macAddress,
                usnUUID: fp.usnUUID ?? cached.usnUUID,
                usbSerial: fp.usbSerial ?? cached.usbSerial,
                mdnsDeviceID: fp.mdnsDeviceID ?? cached.mdnsDeviceID,
                hostname: fp.hostname ?? cached.hostname,
                model: fp.model ?? cached.model,
                httpServer: fp.httpServer ?? cached.httpServer,
                portSpectrumHash: fp.portSpectrumHash ?? cached.portSpectrumHash,
                ipv4: fp.ipv4 ?? cached.ipv4,
                ipv6: fp.ipv6 ?? cached.ipv6,
                primaryConnectionType: fp.primaryConnectionType ?? cached.primaryConnectionType
            )
        }
        await IdentityResolver.WeakFingerprintStore.shared.save(fp, for: device)
        return fp
    }

 /// 从URL中提取主机部分。
    private func extractHost(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        return url.host
    }

    private func parseSubnet(from ip: String) -> String {
        let ipComponents = ip.split(separator: ".").compactMap { Int($0) }
        guard ipComponents.count == 4 else {
            return "192.168.1"
        }
        return "\(ipComponents[0]).\(ipComponents[1]).\(ipComponents[2])"
    }

 /// 并行网络扫描（适用于Apple Silicon设备）
 /// ⚡ Swift 6.2.1 改进：使用 TaskGroup 替代 DispatchSemaphore，避免线程阻塞
    private func performParallelNetworkScan(networkBase: String, skipOctet: Int) {
 // 限制最大并发数以避免系统过载
        let maxConcurrency = min(ProcessInfo.processInfo.processorCount, 16)

        logger.info("🔄 开始并行扫描 \(networkBase).1-254 (跳过 .\(skipOctet))，最大并发: \(maxConcurrency)")

 // 使用纯异步方式执行并行扫描，避免 semaphore.wait() 阻塞
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }

 // 收集需要扫描的 IP 地址
            var ipsToScan: [String] = []
            for i in 1...254 {
                if i == skipOctet || i == 255 || i == 0 {
                    continue
                }
                ipsToScan.append("\(networkBase).\(i)")
            }

 // 使用 TaskGroup 进行并发控制，分批处理
            let batchSize = maxConcurrency
            for batchStart in stride(from: 0, to: ipsToScan.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, ipsToScan.count)
                let batch = Array(ipsToScan[batchStart..<batchEnd])

                await withTaskGroup(of: Void.self) { group in
                    for targetIP in batch {
                        group.addTask {
                            await MainActor.run { [weak self] in
                                guard let self = self, self.isScanning else { return }
                                self.pingHost(targetIP)
                            }
                        }
                    }
                }

 // 批次间短暂延迟，避免网络拥塞
                try? await Task.sleep(nanoseconds: 10_000_000) // 0.01秒
            }

            await MainActor.run { [weak self] in
                self?.logger.info("✅ 并行网络扫描完成")
            }
        }
    }

 /// 顺序网络扫描（适用于标准设备）
 /// 执行顺序网络扫描（优化版：批处理+休眠策略）
 /// 🔧 性能优化：添加批处理、动态延迟和 CPU 休眠机制
 /// ⚡ Swift 6.2.1 改进：使用 .sleep 替代 Thread.sleep，避免线程阻塞
    private func performSequentialNetworkScan(networkBase: String, skipOctet: Int) {
        logger.info("🔄 开始智能顺序扫描 \(networkBase).1-254 (跳过 .\(skipOctet))")

 // 使用纯异步方式执行扫描，避免 Thread.sleep 阻塞
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }

 // 在 MainActor 上获取需要的属性
            let (lastCompletion, cooldownPeriod, consecutiveCount, maxConsecutive, currentActivityLevel) = await MainActor.run {
                (self.lastScanCompletionTime, self.scanCooldownPeriod, self.consecutiveScanCount, self.maxConsecutiveScans, self.networkActivityLevel)
            }

 // 检查是否需要冷却
            if let lastCompletion = lastCompletion {
                let timeSinceLastScan = Date().timeIntervalSince(lastCompletion)
                if timeSinceLastScan < cooldownPeriod && consecutiveCount >= maxConsecutive {
                    await MainActor.run {
                        self.logger.info("😴 扫描冷却中... (\(Int(cooldownPeriod - timeSinceLastScan))秒)")
                    }
 // 使用异步 sleep 替代 Thread.sleep
                    try? await Task.sleep(nanoseconds: UInt64((cooldownPeriod - timeSinceLastScan) * 1_000_000_000))
                    await MainActor.run {
                        self.consecutiveScanCount = 0
                    }
                }
            }

 // 批处理扫描：根据网络活跃度动态调整批大小
            let batchSize: Int
            switch currentActivityLevel {
            case .low:
                batchSize = 10  // 低活跃度：小批次，更多休眠
            case .normal:
                batchSize = 20  // 正常：中等批次
            case .high:
                batchSize = 50  // 高活跃度：大批次，快速扫描
            }

            var scannedCount = 0
            for i in 1...254 {
 // 跳过本机IP、广播地址和常见的保留地址
                if i == skipOctet || i == 255 || i == 0 {
                    continue
                }

                let targetIP = "\(networkBase).\(i)"
                await MainActor.run {
                    guard self.isScanning else { return }
                    self.pingHost(targetIP)
                }

                scannedCount += 1

 // 批处理休眠：每扫描一批后休眠一段时间（优化后的延迟）
                if scannedCount % batchSize == 0 {
                    let batchDelayNs: UInt64
                    switch currentActivityLevel {
                    case .low:
                        batchDelayNs = 100_000_000  // 0.1秒
                    case .normal:
                        batchDelayNs = 50_000_000   // 0.05秒
                    case .high:
                        batchDelayNs = 10_000_000   // 0.01秒
                    }
 // 使用异步 sleep 替代 Thread.sleep
                    try? await Task.sleep(nanoseconds: batchDelayNs)

 // 捕获 scannedCount 到局部常量，避免数据竞争
                    let currentCount = scannedCount
                    await MainActor.run {
                        self.logger.debug("🔄 批处理进度: \(currentCount)/254")
                    }
                } else {
 // 单个扫描间的微小延迟（减少CPU峰值）
                    try? await Task.sleep(nanoseconds: 5_000_000) // 0.005秒
                }
            }

            await MainActor.run {
                self.logger.info("✅ 智能网络扫描完成，共扫描 \(scannedCount) 个地址")
                self.consecutiveScanCount += 1
                self.lastScanCompletionTime = Date()
            }
        }
    }

 /// 执行端口扫描
    private func performPortScan() {
        if settingsManager.discoveryPassiveMode { return }
 // 检查是否启用了自定义端口扫描
        Task { @MainActor in
            guard settingsManager.scanCustomPorts else {
                logger.debug("🚫 自定义端口扫描已禁用")
                return
            }

            let commonPorts = [22, 80, 443, 3389, 5900, 8080]

            for device in discoveredDevices {
                guard let ip = device.ipv4 ?? device.ipv6 else { continue }

 // 检查是否使用优化的并行扫描
                let useOptimizedScan = await optimizer?.isAppleSilicon ?? false
                if useOptimizedScan {
 // 使用优化的并行端口扫描
                    Task {
                        await optimizer?.performParallelComputation(
                            iterations: commonPorts.count,
                            qos: .utility
                        ) { index in
                            let port = commonPorts[index]
                            Task { @MainActor in
                            self.scanPort(ip: ip, port: port)
                            }
                            return port
                        }
                    }
                } else {
 // 标准端口扫描
                    for port in commonPorts {
                        scanPort(ip: ip, port: port)
                    }
                }
            }
        }
    }

 /// 扫描指定端口（优化版：添加缓存）
 /// 🔧 性能优化：检查缓存，避免重复扫描
    private func scanPort(ip: String, port: Int) {
 // 检查缓存
        if let cachedPorts = portScanCache[ip],
           let cachedResult = cachedPorts[port] {
            let age = Date().timeIntervalSince(cachedResult.timestamp)
            if age < portCacheExpiration {
                logger.debug("📦 端口缓存命中: \(ip):\(port) (状态: \(cachedResult.isOpen ? "开放" : "关闭"))")
                return
            }
        }

        let connection = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(integerLiteral: UInt16(port)), using: .tcp)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
 // 端口开放，更新设备信息和缓存
                Task { @MainActor in
                    guard let self = self else { return }

 // 更新缓存
                    if self.portScanCache[ip] == nil {
                        self.portScanCache[ip] = [:]
                    }
                    self.portScanCache[ip]?[port] = (isOpen: true, timestamp: Date())

 // 更新设备信息
                    if let deviceIndex = self.discoveredDevices.firstIndex(where: { $0.ipv4 == ip || $0.ipv6 == ip }) {
                        let serviceType = self.getServiceType(for: port)
                        if !self.discoveredDevices[deviceIndex].services.contains(serviceType) {
                            self.discoveredDevices[deviceIndex].services.append(serviceType)
                            self.discoveredDevices[deviceIndex].portMap[serviceType] = port
                        }
                    }
                }
                connection.cancel()
            case .failed(_):
 // 更新缓存：端口关闭
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if self.portScanCache[ip] == nil {
                        self.portScanCache[ip] = [:]
                    }
                    self.portScanCache[ip]?[port] = (isOpen: false, timestamp: Date())
                }
                connection.cancel()
            default:
                break
            }
        }

        connection.start(queue: queue)

 // 设置超时
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒延迟
            connection.cancel()
        }
    }

 /// 根据端口号获取服务类型
    private func getServiceType(for port: Int) -> String {
        switch port {
        case 22:
            return "SSH"
        case 80:
            return "HTTP"
        case 443:
            return "HTTPS"
        case 3389:
            return "RDP"
        case 5900:
            return "VNC"
        case 8080:
            return "HTTP-Alt"
        default:
            return "未知服务"
        }
    }

 /// 停止设备发现
    public func stopDiscovery() {
        isScanning = false
        discoveryTimeoutTask?.cancel()
        discoveryTimeoutTask = nil

 // 停止所有活动的浏览器
        for browser in activeBrowsers {
            browser.cancel()
        }
        activeBrowsers.removeAll()

 // 清理扫描缓存
        scannedIPs.removeAll()
        lastScanTimes.removeAll()

        logger.info("设备发现已停止，缓存已清理")
    }

 /// 获取本地IP地址
    private func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0 else {
            logger.error("无法获取网络接口信息")
            return nil
        }

        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }

            guard let interface = ptr?.pointee,
                  let addr = interface.ifa_addr else { continue }

            let addrFamily = addr.pointee.sa_family

 // 只处理IPv4地址
            if addrFamily == UInt8(AF_INET) {
 // ⚡ Swift 6.2.1：使用新的内存安全工具进行 C 字符串解码
                let name = Swift621MemorySafety.decodeCString(interface.ifa_name)

 // 检查是否为活跃的网络接口（Wi-Fi或以太网）
                if name.hasPrefix("en") || name == "wifi0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                           &hostname, socklen_t(hostname.count),
                                           nil, socklen_t(0), NI_NUMERICHOST)

                    if result == 0 {
                        let data = Data(bytes: hostname, count: hostname.count)
                        let trimmed = data.prefix { $0 != 0 }
                        let ipString = String(decoding: trimmed, as: UTF8.self)
 // 确保不是回环地址
                        if !ipString.hasPrefix("127.") && !ipString.isEmpty {
                            address = ipString
                            logger.info("获取到本地IP地址: \(ipString) (接口: \(name))")
                            break
                        }
                    }
                }
            }
        }

 // 如果没有找到合适的IP地址，尝试使用默认方法
        if address == nil {
            address = getDefaultLocalIP()
        }

        return address
    }

 /// 获取默认本地IP地址的备用方法
    private func getDefaultLocalIP() -> String? {
 // 使用Socket方法获取本地IP
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(sock) }

        guard sock >= 0 else { return nil }

        var addr = sockaddr_in()
         addr.sin_family = sa_family_t(AF_INET)
         addr.sin_addr.s_addr = inet_addr("8.8.8.8") // Google DNS
         addr.sin_port = UInt16(80).bigEndian

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard result == 0 else { return nil }

        var localAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let getResult = withUnsafeMutablePointer(to: &localAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &addrLen)
            }
        }

        guard getResult == 0 else { return nil }

 // ⚡ Swift 6.2.1：使用新的内存安全工具进行 C 字符串解码
        let ipString = Swift621MemorySafety.decodeCString(inet_ntoa(localAddr.sin_addr))
        logger.info("使用备用方法获取到本地IP地址: \(ipString)")
        return ipString
    }

 /// Ping主机检测
    @MainActor
    private func pingHost(_ ip: String) {
 // 检查是否已经扫描过该IP且在间隔时间内
        if scannedIPs.contains(ip),
           let lastScanTime = lastScanTimes[ip],
           Date().timeIntervalSince(lastScanTime) < scanInterval {
            logger.debug("⏭️ 跳过最近扫描的IP: \(ip)")
            return
        }

 // 使用NWConnection进行连接测试
        let host = NWEndpoint.Host(ip)
        let port = NWEndpoint.Port(integerLiteral: 80) // 使用HTTP端口进行连通性测试

        let connection = NWConnection(host: host, port: port, using: .tcp)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
 // 连接成功，说明主机存在
                Task { @MainActor in
                    self?.logger.debug("📱 发现设备: \(ip)")
                    self?.handleHostFound(ip)
                }
                connection.cancel()

            case .failed(_):
 // 连接失败，尝试其他端口
                Task { @MainActor in
                    self?.logger.debug("🔍 \(ip) 端口80失败，尝试其他端口")
                    self?.tryAlternatePorts(for: ip)
                }
                connection.cancel()

            case .cancelled:
                break

            default:
                break
            }
        }

 // 设置连接超时
        let queue = DispatchQueue(label: "ping.\(ip)")
        connection.start(queue: queue)

 // 使用SettingsManager中的WiFi扫描超时设置
        let timeout = TimeInterval(settingsManager.wifiScanTimeout)
        queue.asyncAfter(deadline: .now() + timeout) {
            if connection.state != .ready && connection.state != .cancelled {
                connection.cancel()
            }
        }
    }

 /// 尝试其他端口来检测主机
    @MainActor
    private func tryAlternatePorts(for ip: String) {
        let commonPorts: [UInt16] = [22, 23, 443, 8080, 3389, 5900]
        let portGroup = DispatchGroup()

 // 使用原子操作来跟踪是否找到开放端口
        let foundOpenPortAtomic = OSAllocatedUnfairLock(initialState: false)

        for port in commonPorts {
            portGroup.enter()

            let host = NWEndpoint.Host(ip)
            let nwPort = NWEndpoint.Port(integerLiteral: port)

            let connection = NWConnection(host: host, port: nwPort, using: .tcp)

            connection.stateUpdateHandler = { [weak self] state in
                defer { portGroup.leave() }

                switch state {
                case .ready:
 // 找到开放端口，主机存在
                    foundOpenPortAtomic.withLock { foundOpenPort in
                        if !foundOpenPort {
                            foundOpenPort = true
                            DispatchQueue.main.async {
                                self?.handleHostFound(ip, openPort: port)
                            }
                        }
                    }
                    connection.cancel()

                case .failed(let error):
 // 记录端口扫描失败的详细信息
                    self?.logger.debug("🔍 \(ip):\(port) 连接失败: \(error.localizedDescription)")
                    connection.cancel()

                case .cancelled:
                    break

                default:
                    break
                }
            }

            let queue = DispatchQueue(label: "port-scan.\(ip).\(port)")
            connection.start(queue: queue)

 // 设置端口扫描超时（较短的超时时间）
            queue.asyncAfter(deadline: .now() + 2.0) {
                if connection.state != .ready && connection.state != .cancelled {
                    connection.cancel()
                }
            }
        }

 // 等待所有端口扫描完成，如果没有找到开放端口，记录日志
        portGroup.notify(queue: .global()) { [weak self] in
            let hasFoundPort = foundOpenPortAtomic.withLock { $0 }

            if !hasFoundPort {
                self?.logger.debug("⚠️ 主机 \(ip) 所有常用端口均不可达")
            }
        }
    }

 /// 处理发现的主机
    private func handleHostFound(_ ip: String, openPort: UInt16? = nil) {
        Task { @MainActor in
 // 🚀 性能优化：使用智能扫描间隔
            let currentScanInterval = networkActivityLevel.scanInterval

 // 检查扫描间隔，避免频繁扫描同一IP
            if let lastScanTime = self.lastScanTimes[ip],
               Date().timeIntervalSince(lastScanTime) < currentScanInterval {
                self.logger.debug("⚠️ 设备 \(ip) 扫描间隔未到（\(currentScanInterval)秒），跳过")
                return
            }

 // 🔄 动态调整网络活跃度
            self.adjustNetworkActivityLevel()

 // 更新最后扫描时间
            self.lastScanTimes[ip] = Date()
            self.scannedIPs.insert(ip)

 // 使用新的设备名称解析器获取设备信息
            var deviceName = "未知设备"
            var deviceType = "网络设备"
            var servicePort: Int?
            var isValidDevice = false

            if let resolver = self.deviceNameResolver,
               let deviceInfo = await resolver.resolveDeviceInfo(for: ip) {
                deviceName = deviceInfo.hostname
                deviceType = deviceInfo.deviceType

 // 检查是否为有效设备（非localhost/bogon等无意义名称）
                isValidDevice = self.isValidDevice(name: deviceName, ip: ip)

                if isValidDevice {
                    SkyBridgeLogger.discovery.debugOnly("✅ DeviceDiscoveryService: 解析到有效设备: \(deviceName) (\(deviceType))")
                    self.logger.info("✅ 解析到有效设备: \(deviceName) (\(deviceType))")
                } else {
                    SkyBridgeLogger.discovery.debugOnly("⚠️ DeviceDiscoveryService: 跳过无效设备: \(deviceName) (\(ip))")
                    self.logger.debug("⚠️ 跳过无效设备: \(deviceName) (\(ip))")
                    return
                }
            } else {
 // 回退到原有的主机名解析方法
                let resolvedName = self.resolveHostname(for: ip) ?? "未知设备"
                deviceName = resolvedName
                servicePort = openPort.map { Int($0) }
                deviceType = servicePort.map { self.getServiceType(for: $0) } ?? "网络设备"

 // 检查回退解析的设备是否有效
                isValidDevice = self.isValidDevice(name: deviceName, ip: ip)

                if !isValidDevice {
                    SkyBridgeLogger.discovery.debugOnly("⚠️ DeviceDiscoveryService: 跳过无效设备: \(deviceName) (\(ip))")
                    self.logger.debug("⚠️ 跳过无效设备: \(deviceName) (\(ip))")
                    return
                }
            }

            let device = DiscoveredDevice(
                id: UUID(),
                name: deviceName,
                ipv4: ip,
                ipv6: nil,
                services: [deviceType],
                portMap: servicePort.map { [deviceType: $0] } ?? [:],
                connectionTypes: [.wifi]
            )

 // 🔧 智能去重：使用智能匹配函数检查是否已存在
            if let existingIndex = self.findSimilarDevice(
                name: deviceName,
                ipv4: ip,
                ipv6: nil,
                uniqueIdentifier: nil
            ) {
 // 设备已存在，合并信息
                self.mergeDeviceInfo(existingIndex: existingIndex, newDevice: device)
                SkyBridgeLogger.discovery.debugOnly("🔄 DeviceDiscoveryService: 合并设备信息: \(deviceName) (\(ip))")
                self.logger.debug("🔄 网络扫描: 合并设备 \(deviceName)")
            } else {
 // 新设备，添加到列表
            self.discoveredDevices.append(device)
            let reportedPort = servicePort ?? 80
            SkyBridgeLogger.discovery.debugOnly("✅ DeviceDiscoveryService: 发现新设备: \(deviceName) (\(ip):\(reportedPort))")
                self.logger.info("✅ 网络扫描: 发现新设备 \(deviceName) (\(ip):\(reportedPort))")
            }

 // 更新发现状态
            let newState = DiscoveryState(
                devices: self.discoveredDevices,
                statusDescription: "已发现 \(self.discoveredDevices.count) 台设备"
            )
            self.subject.send(newState)
        }
    }

 /// 🚀 新增：开始外部设备扫描
    public func startExternalDeviceScanning() {
        logger.info("🔍 开始扫描外部设备")

        Task { @MainActor in
 // 启动USB设备扫描
            self.usbDeviceManager?.startMonitoring()

 // 启动蓝牙设备扫描
            self.bluetoothManager?.startScanning()

            self.logger.info("外部设备扫描已启动")
        }
    }

 /// 🚀 新增：停止外部设备扫描
    public func stopExternalDeviceScanning() {
        logger.info("⏹️ 停止扫描外部设备")

        Task { @MainActor in
 // 停止USB设备扫描
            self.usbDeviceManager?.stopMonitoring()

 // 停止蓝牙设备扫描
            self.bluetoothManager?.stopScanning()

            self.logger.info("外部设备扫描已停止")
        }
    }

 /// 🚀 新增：动态调整网络活跃度
     @MainActor
     private func adjustNetworkActivityLevel() {
        let recentScans = lastScanTimes.values.filter { Date().timeIntervalSince($0) < 60 }
        let scansPerMinute = recentScans.count

        let previousLevel = networkActivityLevel

        if scansPerMinute > 10 {
            networkActivityLevel = .high
        } else if scansPerMinute < 3 {
            networkActivityLevel = .low
        } else {
            networkActivityLevel = .normal
        }

 // 只在活跃度变化时更新扫描间隔和打印日志
         if networkActivityLevel != previousLevel {
             self.scanInterval = self.networkActivityLevel.scanInterval
             self.logger.info("📊 网络活跃度调整: \(previousLevel) -> \(self.networkActivityLevel), 扫描间隔: \(self.scanInterval)秒")
         }
    }

 /// 检查设备是否为有效设备（过滤localhost/bogon等无意义名称）
    private func isValidDevice(name: String, ip: String) -> Bool {
        let lowercaseName = name.lowercased()

 // 无效的设备名称列表
        let invalidNames: Set<String> = [
            "localhost", "bogon", "unknown", "device", "host",
            "未知设备", "unknown device", "local", "router",
            "gateway", "default", "dhcp", "dns", "server",
            "network", "lan", "wan", "wifi", "ethernet"
        ]

 // 检查是否为无效名称
        if invalidNames.contains(lowercaseName) {
            return false
        }

 // 检查是否为纯IP地址格式的名称
        if lowercaseName == ip.lowercased() {
            return false
        }

 // 检查是否为通用格式（如 "192-168-1-1" 等）
        let ipPattern = ip.replacingOccurrences(of: ".", with: "-")
        if lowercaseName.contains(ipPattern.lowercased()) {
            return false
        }

 // 检查是否包含有意义的字符（至少包含字母和数字的组合）
        let hasLetters = lowercaseName.rangeOfCharacter(from: .letters) != nil
        let hasNumbers = lowercaseName.rangeOfCharacter(from: .decimalDigits) != nil

 // 如果只有数字或只有字母，且长度较短，可能不是有效设备名
        if (!hasLetters || !hasNumbers) && lowercaseName.count < 4 {
            return false
        }

 // 检查是否为Apple设备或其他知名品牌设备
        let validPrefixes = ["iphone", "ipad", "macbook", "imac", "apple", "hp", "canon", "epson", "brother", "samsung", "lg", "sony", "dell", "lenovo", "asus", "netgear", "linksys", "dlink", "tplink"]

        for prefix in validPrefixes {
            if lowercaseName.hasPrefix(prefix) {
                return true
            }
        }

 // 如果名称长度合理且包含字母数字组合，认为是有效设备
        return lowercaseName.count >= 3 && lowercaseName.count <= 50 && hasLetters
    }

 /// 解析主机名
    private func resolveHostname(for ip: String) -> String? {
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr(ip)

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size),
                           &hostname, socklen_t(hostname.count),
                           nil, 0, 0)
            }
        }

        if result == 0 {
            let data = Data(bytes: hostname, count: hostname.count)
            let trimmed = data.prefix { $0 != 0 }
            let name = String(decoding: trimmed, as: UTF8.self)
            return name != ip ? name : nil
        }

        return nil
    }
}
