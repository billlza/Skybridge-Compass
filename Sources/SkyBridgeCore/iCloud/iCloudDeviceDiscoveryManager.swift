// macOS-exclusive: built on macOS-only APIs (AppKit / IOKit / ScreenCaptureKit / CoreWLAN /
// MetalFX / ServiceManagement / ApplicationServices / CoreGraphics display services).
// Excluded from other platforms so SkyBridgeCore can be the single shared core for iOS as
// well. No behaviour changes on macOS.
#if os(macOS)
import Foundation
import CloudKit
import Combine
import OSLog
import Network
import Security

/// 🌟 iCloud设备发现管理器 - macOS 26.0 + Swift 6.2最佳实践
///
/// 功能：
/// - 自动发现同一Apple ID下的所有设备
/// - 实时设备在线状态更新
/// - 设备能力协商
/// - 端到端加密
/// - Apple Silicon优化
@available(macOS 14.0, *)
@MainActor
public final class iCloudDeviceDiscoveryManager: ObservableObject, @unchecked Sendable {

    public static let shared = iCloudDeviceDiscoveryManager()

 // MARK: - 生命周期管理

 /// 管理器是否已启动
    @Published public private(set) var isStarted: Bool = false

 // MARK: - 发布属性

 /// 已发现的iCloud设备列表
    @Published public private(set) var discoveredDevices: [iCloudDevice] = []

 /// 设备发现状态
    @Published public private(set) var discoveryStatus: DiscoveryStatus = .idle

 /// 当前设备信息
    @Published public private(set) var currentDevice: iCloudDevice?

 // MARK: - 私有属性

    private let logger = Logger(subsystem: "com.skybridge.icloud", category: "DeviceDiscovery")

 /// 使用NSUbiquitousKeyValueStore代替CloudKit（更简单，无需配置）
    private let kvStore = NSUbiquitousKeyValueStore.default
    private let deviceKeyPrefix = "skybridge.device."

 /// 设备心跳定时器
    private var heartbeatTimer: Timer?

 /// CloudKit订阅
    private var subscriptionID = "skybridge-device-updates"

 /// 设备刷新间隔（秒）
    private let refreshInterval: TimeInterval = 30.0

 /// 设备超时时间（秒）
    private let deviceTimeout: TimeInterval = 120.0

    /// Combine订阅
    private var iCloudCancellables = Set<AnyCancellable>()
    private var kvStoreChangeObserver: NSObjectProtocol?

 // MARK: - 生命周期管理方法

    /// 启动iCloud设备发现管理器
    public func start() async throws {
        await startDiscovery()
    }

 /// 停止iCloud设备发现管理器
    public func stop() async {
        guard isStarted else { return }

        logger.info("⏹️ 停止iCloud设备发现管理器")
        isStarted = false

 // 停止设备发现
        stopDiscovery()
    }

 /// 清理资源
    public func cleanup() async {
        logger.info("🧹 清理iCloud设备发现管理器资源")

 // 停止心跳定时器
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

 // 清理订阅
        iCloudCancellables.removeAll()
        removeiCloudNotifications()

 // 清理设备列表
        discoveredDevices.removeAll()
        currentDevice = nil

 // 重置状态
        discoveryStatus = .idle
        isStarted = false
    }

 // MARK: - 发现状态

    public enum DiscoveryStatus: Sendable, Equatable {
        case idle
        case checking
        case discovering
        case ready(deviceCount: Int)
        case error(String)
    }

 // MARK: - 初始化

    public init() {
        logger.info("🔷 iCloud设备发现管理器初始化（延迟加载CloudKit）")

 // 初始化当前设备信息（不依赖CloudKit）
        setupCurrentDevice()
    }

    deinit {
 // Timer会在视图销毁时自动清理
 // 不需要在deinit中手动处理
    }

 // MARK: - 公共方法

    /// 启动设备发现（使用iCloud KV Store）
    public func startDiscovery() async {
        if isStarted {
            await sendHeartbeat()
            fetchDevices()
            return
        }

        logger.info("🚀 启动iCloud设备发现（使用KV Store）")
        isStarted = true
        discoveryStatus = .checking

 // 1. 检查iCloud KV Store是否可用
        guard FileManager.default.ubiquityIdentityToken != nil else {
            logger.error("❌ iCloud未登录")
            discoveryStatus = .error("请在系统偏好设置中登录iCloud")
            isStarted = false
            return
        }

        // 1.1 检查是否启用了 iCloud / Ubiquity 相关 entitlement。
        // 若缺失，底层可能会产生类似 “FSFindFolder failed with error=-43” 的日志噪音，
        // 且 KV Store 同步也不会真正工作。
        guard Self.hasUbiquityKVStoreEntitlement() else {
            logger.error("❌ iCloud KV Store 不可用：缺少 iCloud entitlement（请在 Xcode -> Signing & Capabilities -> iCloud 勾选 CloudKit / iCloud Documents，并配置容器）")
            discoveryStatus = .error("iCloud 未启用：缺少 iCloud/CloudKit entitlement（请在 Xcode Signing & Capabilities 中开启 iCloud 能力）")
            isStarted = false
            return
        }

        // 1.2 KV Store 不依赖 iCloud Drive 文档容器。容器缺失只降级提示，
        // 不能阻止在线心跳，否则已开启 KVS 的正式包会被误判为离线。
        if FileManager.default.url(forUbiquityContainerIdentifier: nil) == nil {
            logger.warning("⚠️ iCloud Documents 容器不可用，继续使用 iCloud KV Store 做设备在线心跳")
        }

        discoveryStatus = .discovering

 // 2. 注册当前设备
        do {
            try await refreshCurrentDeviceIdentityHints()
        } catch {
            logger.error(
                "❌ iCloud device discovery identity unavailable: \(error.localizedDescription, privacy: .public)"
            )
            discoveryStatus = .error("本机身份不可用")
            isStarted = false
            return
        }
        registerCurrentDevice()

 // 3. 同步并获取设备列表
        fetchDevices()

 // 4. 启动心跳
        startHeartbeat()

 // 5. 监听iCloud变化
        setupiCloudNotifications()

        logger.info("✅ iCloud设备发现已启动")
    }

    private static func hasUbiquityKVStoreEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let key = "com.apple.developer.ubiquity-kvstore-identifier" as CFString
        let val = SecTaskCopyValueForEntitlement(task, key, nil)
        if let s = val as? String { return !s.isEmpty }
        if let arr = val as? [String] { return !arr.isEmpty }
        if let b = val as? Bool { return b }
        return val != nil
    }

 /// 停止设备发现
    public func stopDiscovery() {
        logger.info("⏹️ 停止iCloud设备发现")
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        removeiCloudNotifications()
        discoveryStatus = .idle
        isStarted = false
    }

 /// 手动刷新设备列表
    public func refreshDevices() async {
        logger.info("🔄 刷新iCloud设备列表")
        fetchDevices() // fetchDevices 是同步方法，不需要 await
    }

 /// 更新本机心跳
    public func updateHeartbeat() async {
        logger.info("💓 手动更新心跳")
        await sendHeartbeat()
    }

 /// 移除已离线的设备
    private func removeOfflineDevices() {
        let now = Date()
        discoveredDevices.removeAll { device in
            now.timeIntervalSince(device.lastSeen) > deviceTimeout
        }
    }

 // MARK: - 私有方法

 /// 设置iCloud通知监听
    private func setupiCloudNotifications() {
        guard kvStoreChangeObserver == nil else { return }
        kvStoreChangeObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.fetchDevices() // fetchDevices 是 @MainActor 方法，需要确保在主线程调用
            }
        }
    }

    private func removeiCloudNotifications() {
        guard let observer = kvStoreChangeObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        kvStoreChangeObserver = nil
    }

 /// 设置当前设备信息
    private func setupCurrentDevice() {
        let localPresentation = LocalDevicePresentation.current()
        let device = iCloudDevice(
            id: getCompatibilityRouteIdentifier(),
            name: localPresentation.deviceName ?? localPresentation.modelName ?? "Mac",
            model: getDeviceModel(),
            osVersion: getOSVersion(),
            appVersion: getAppVersion(),
            lastSeen: Date(),
            capabilities: [.remoteDesktop, .fileTransfer, .clipboard],
            isOnline: true,
            networkType: .wifi,
            ipAddress: getLocalIPAddress()
        )

        currentDevice = device
        logger.info("📱 当前设备: \(device.name) (\(device.model))")
    }

 /// 注册当前设备到iCloud KV Store
    private func registerCurrentDevice() {
        guard let device = currentDevice else {
            logger.error("❌ 当前设备信息未初始化")
            return
        }

 // 编码设备信息为JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let deviceData = try? encoder.encode(device) else {
            logger.error("❌ 编码设备信息失败")
            return
        }

 // 保存到iCloud KV Store
        let key = deviceKeyPrefix + device.id
        kvStore.set(deviceData, forKey: key)
        kvStore.synchronize()

        logger.info("✅ 设备已注册到iCloud KV Store: \(device.name)")
    }

 /// 获取设备列表
    private func fetchDevices() {
 // 同步iCloud数据
        kvStore.synchronize()

        var devices: [iCloudDevice] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

 // 遍历所有键
        let allKeys = kvStore.dictionaryRepresentation.keys
        for key in allKeys where key.hasPrefix(deviceKeyPrefix) {
            guard let deviceData = kvStore.data(forKey: key),
                  let device = try? decoder.decode(iCloudDevice.self, from: deviceData),
                  device.id != currentDevice?.id else {  // 排除当前设备
                continue
            }

 // 检查设备是否最近活跃（1小时内）
            if Date().timeIntervalSince(device.lastSeen) < deviceTimeout {
                devices.append(device)
            } else {
 // 移除过期设备
                kvStore.removeObject(forKey: key)
            }
        }

 // 更新设备列表
        self.discoveredDevices = devices.sorted { $0.lastSeen > $1.lastSeen }
        self.discoveryStatus = .ready(deviceCount: devices.count)

        logger.info("✅ 发现 \(devices.count) 台iCloud设备")
    }

 /// 启动心跳定时器
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()

        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.sendHeartbeat()
                self?.fetchDevices()
            }
        }

        logger.info("💓 心跳定时器已启动，间隔: \(self.refreshInterval)秒")
    }

 /// 发送设备心跳
    private func sendHeartbeat() async {
        guard var device = currentDevice else { return }

 // 更新最后活跃时间
        device.lastSeen = Date()
        device.ipAddress = getLocalIPAddress()
        currentDevice = device
        do {
            try await refreshCurrentDeviceIdentityHints()
        } catch {
            logger.error(
                "❌ iCloud heartbeat identity unavailable: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        registerCurrentDevice()
    }

    private func refreshCurrentDeviceIdentityHints() async throws {
        guard var device = currentDevice else { return }
        let snapshot = try await SelfIdentityProvider.shared
            .snapshotEnsuringProtocolDeviceId(allowCreate: false)
        let stableIdentity = normalizeIdentityHint(snapshot.deviceId)
        let generatedFingerprint = try await SelfIdentityProvider.shared
            .generateRegistrationFingerprint(allowCreate: false)
        let registrationFingerprint = normalizeIdentityHint(generatedFingerprint)

        var changed = false
        if device.stableIdentityDeviceId != stableIdentity {
            device.stableIdentityDeviceId = stableIdentity
            changed = true
        }
        if device.registrationFingerprint != registrationFingerprint {
            device.registrationFingerprint = registrationFingerprint
            changed = true
        }
        if changed {
            currentDevice = device
        }
    }

 // MARK: - 工具方法

    /// Return the legacy KVS routing key used to locate a presence record.
    ///
    /// This value is compatibility metadata only. It must never be promoted to
    /// protocol identity, trust scoring or authenticated peer binding.
    private func getCompatibilityRouteIdentifier() -> String {
 // 使用硬件UUID作为兼容路由键
        if let uuid = getMacSerialNumber() {
            return "mac-\(uuid)"
        }

 // 备选方案：使用持久化的UUID
        let key = "SkyBridgeDeviceUUID"
        if let savedUUID = UserDefaults.standard.string(forKey: key) {
            return savedUUID
        }

        let newUUID = UUID().uuidString
        UserDefaults.standard.set(newUUID, forKey: key)
        return newUUID
    }

    private func normalizeIdentityHint(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }

 /// 获取Mac序列号
    private func getMacSerialNumber() -> String? {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )

        guard platformExpert != 0 else { return nil }

        defer { IOObjectRelease(platformExpert) }

        guard let serialNumber = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformSerialNumberKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String else {
            return nil
        }

        return serialNumber
    }

 /// 获取设备型号
    private func getDeviceModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let data = Data(bytes: model, count: size)
        let trimmed = data.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

 /// 获取系统版本
    private func getOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

 /// 获取应用版本
    private func getAppVersion() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version).\(build)"
    }

 /// 获取本地IP地址
    private func getLocalIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var en0IPv4: String?
        var wifiIPv4: String?
        var otherIPv4: String?
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }

            guard let interface = ptr?.pointee,
                  let addressPtr = interface.ifa_addr,
                  let namePtr = interface.ifa_name else { continue }
            let addrFamily = addressPtr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                let name = decodeCString(namePtr)
                guard let ipAddress = numericHost(from: addressPtr),
                      isAdvertisableRoutableIPv4(ipAddress) else { continue }
                if name == "en0", en0IPv4 == nil {
                    en0IPv4 = ipAddress
                } else if name.hasPrefix("en"), wifiIPv4 == nil {
                    wifiIPv4 = ipAddress
                } else if otherIPv4 == nil {
                    otherIPv4 = ipAddress
                }
            }
        }

        return en0IPv4 ?? wifiIPv4 ?? otherIPv4
    }

    private func numericHost(from address: UnsafePointer<sockaddr>) -> String? {
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &hostname,
            socklen_t(hostname.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { return nil }
        let data = Data(bytes: hostname, count: hostname.count)
        let trimmed = data.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    private func isAdvertisableRoutableIPv4(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IPv4Address(value) != nil else { return false }
        return !value.hasPrefix("169.254.")
            && !value.hasPrefix("127.")
            && !value.hasPrefix("0.")
            && value != "255.255.255.255"
    }
}

// MARK: - 数据模型

/// iCloud设备信息
public struct iCloudDevice: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var model: String
    public var osVersion: String
    public var appVersion: String
    public var lastSeen: Date
    public var capabilities: [DeviceCapability]
    public var isOnline: Bool
    public var networkType: NetworkType
    public var ipAddress: String?
    public var stableIdentityDeviceId: String?
    public var registrationFingerprint: String?
    public var vendorDeviceId: String?
    public var listenerReady: Bool?
    public var controlPort: UInt16?

    public init(
        id: String,
        name: String,
        model: String,
        osVersion: String,
        appVersion: String,
        lastSeen: Date,
        capabilities: [DeviceCapability],
        isOnline: Bool,
        networkType: NetworkType,
        ipAddress: String? = nil,
        stableIdentityDeviceId: String? = nil,
        registrationFingerprint: String? = nil,
        vendorDeviceId: String? = nil,
        listenerReady: Bool? = nil,
        controlPort: UInt16? = nil
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.lastSeen = lastSeen
        self.capabilities = capabilities
        self.isOnline = isOnline
        self.networkType = networkType
        self.ipAddress = ipAddress
        self.stableIdentityDeviceId = stableIdentityDeviceId
        self.registrationFingerprint = registrationFingerprint
        self.vendorDeviceId = vendorDeviceId
        self.listenerReady = listenerReady
        self.controlPort = controlPort
    }

 /// 设备类型图标
    public var iconName: String {
        if model.contains("iPhone") {
            return "iphone"
        } else if model.contains("iPad") {
            return "ipad"
        } else if model.contains("MacBook") {
            return "laptopcomputer"
        } else if model.contains("iMac") || model.contains("Mac") {
            return "desktopcomputer"
        } else {
            return "display"
        }
    }

 /// 在线状态颜色
    public var statusColor: String {
        isOnline ? "green" : "gray"
    }
}

/// 设备能力
public enum DeviceCapability: String, Codable, Sendable {
    case remoteDesktop = "remote_desktop"
    case fileTransfer = "file_transfer"
    case clipboard = "clipboard"
    case notifications = "notifications"
    case calls = "calls"
    case messages = "messages"
}

/// 网络类型
public enum NetworkType: String, Codable, Sendable {
    case wifi = "wifi"
    case ethernet = "ethernet"
    case cellular = "cellular"
    case vpn = "vpn"
    case unknown = "unknown"

    public var displayName: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .ethernet: return "以太网"
        case .cellular: return "蜂窝网络"
        case .vpn: return "VPN"
        case .unknown: return "未知"
        }
    }
}
#endif
