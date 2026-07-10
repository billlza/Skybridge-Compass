import Foundation
import CloudKit
import Darwin
import Network

/// CloudKit 同步管理器 - 同步设备列表和信任关系
@MainActor
public class CloudKitSyncManager: ObservableObject {
    public static let instance = CloudKitSyncManager()
    
    @Published public private(set) var isSyncing: Bool = false
    @Published public private(set) var lastSyncDate: Date?
    
    private var container: CKContainer?
    private var database: CKDatabase?
    private var didLogEntitlementMissing = false

    private let trustedDeviceRecordType = "SBTrustedDevice"
    private let trustedDeviceResultsLimit = 200
    
    private init() {
        // 注意：未在 Xcode Signing 中启用 iCloud/CloudKit 能力时，
        // 直接访问 CKContainer(identifier:) 可能触发运行时中断（如你截图所示）。
        // 因此这里不在 init 里触碰 CloudKit；在 initialize() 里按需启用。
    }
    
    public func initialize() async {
        #if targetEnvironment(simulator)
        SkyBridgeLogger.shared.info("ℹ️ 模拟器环境：默认跳过 CloudKit 初始化")
        #else
        guard Self.hasCloudKitEntitlement() else {
            if !didLogEntitlementMissing {
                didLogEntitlementMissing = true
                SkyBridgeLogger.shared.warning("⚠️ CloudKit 未启用：缺少 iCloud/CloudKit entitlement（请在 Xcode -> Signing & Capabilities -> iCloud 勾选 CloudKit，并配置容器）。")
            }
            return
        }

        // 使用 default container（由 entitlements 决定），避免硬编码 container id
        let container = CKContainer.default()
        self.container = container
        self.database = container.privateCloudDatabase

        // 检查 iCloud 状态
        let status = try? await container.accountStatus()
        if status == .available {
            SkyBridgeLogger.shared.info("✅ iCloud 可用")
        } else {
            SkyBridgeLogger.shared.warning("⚠️ iCloud 不可用")
        }
        #endif
    }

    /// 在调用 CKContainer.default() 之前检查 entitlement，避免直接触发运行时中断。
    private static func hasCloudKitEntitlement() -> Bool {
        // 使用 embedded.mobileprovision 解析 entitlements（在 Debug/AdHoc 下通常存在）
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let raw = String(data: data, encoding: .isoLatin1) else {
            return false
        }

        guard let plistStart = raw.range(of: "<plist"),
              let plistEnd = raw.range(of: "</plist>") else {
            return false
        }
        let plistString = String(raw[plistStart.lowerBound..<plistEnd.upperBound])
        guard let plistData = plistString.data(using: .utf8) else { return false }

        guard let obj = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let dict = obj as? [String: Any],
              let ent = dict["Entitlements"] as? [String: Any] else {
            return false
        }

        if let services = ent["com.apple.developer.icloud-services"] as? [String] {
            return services.contains("CloudKit") || services.contains("CloudKit-Anonymous")
        }
        return false
    }
    
    public func sync() async throws {
        guard container != nil, let database else {
            SkyBridgeLogger.shared.warning("⚠️ CloudKit 未初始化（可能未开启 iCloud 能力或被禁用）")
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        // 1) 拉取云端可信设备
        let remoteTrusted = try await fetchRemoteTrustedDevices(database: database)

        // 2) 合并到本地（只做并集；不自动删除，避免误删本地信任）
        TrustedDeviceStore.shared.mergeFromCloud(remoteTrusted)

        // 3) 将本地可信设备 upsert 到云端（以 deviceId 为 recordName）
        let localTrusted = TrustedDeviceStore.shared.trustedDevices
        try await upsertTrustedDevices(localTrusted, database: database)

        lastSyncDate = Date()
        SkyBridgeLogger.shared.info("✅ CloudKit 同步完成")
    }

    private func fetchRemoteTrustedDevices(database: CKDatabase) async throws -> [TrustedDeviceStore.TrustedDevice] {
        let query = CKQuery(recordType: trustedDeviceRecordType, predicate: NSPredicate(value: true))
        var cursor: CKQueryOperation.Cursor?
        var results: [TrustedDeviceStore.TrustedDevice] = []

        repeat {
            let response: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)
            if let cursor {
                response = try await database.records(
                    continuingMatchFrom: cursor,
                    desiredKeys: nil,
                    resultsLimit: trustedDeviceResultsLimit
                )
            } else {
                response = try await database.records(
                    matching: query,
                    inZoneWith: nil,
                    desiredKeys: nil,
                    resultsLimit: trustedDeviceResultsLimit
                )
            }

            for (recordID, recordResult) in response.matchResults {
                switch recordResult {
                case .success(let record):
                    if let device = decodeTrustedDevice(record: record) {
                        results.append(device)
                    } else {
                        SkyBridgeLogger.shared.warning("⚠️ CloudKit 可信设备记录无法解析: \(recordID.recordName)")
                    }
                case .failure(let error):
                    SkyBridgeLogger.shared.warning("⚠️ CloudKit 可信设备记录读取失败: \(recordID.recordName) error=\(error.localizedDescription)")
                }
            }

            cursor = response.queryCursor
        } while cursor != nil

        return results
    }

    private func decodeTrustedDevice(record: CKRecord) -> TrustedDeviceStore.TrustedDevice? {
        let id = (record["deviceId"] as? String) ?? record.recordID.recordName
        guard !id.isEmpty else { return nil }

        let name = (record["name"] as? String) ?? "Unknown"
        let platformRaw = (record["platform"] as? String) ?? DevicePlatform.unknown.rawValue
        let platform = DevicePlatform(rawValue: platformRaw) ?? .unknown
        let ipAddress = record["ipAddress"] as? String
        let addedAt = (record["addedAt"] as? Date) ?? Date()

        return TrustedDeviceStore.TrustedDevice(
            id: id,
            name: name,
            platform: platform,
            ipAddress: ipAddress,
            addedAt: addedAt
        )
    }

    private func upsertTrustedDevices(_ devices: [TrustedDeviceStore.TrustedDevice], database: CKDatabase) async throws {
        guard !devices.isEmpty else { return }

        let recordIDs = devices.map { CKRecord.ID(recordName: $0.id) }
        let existing = try await database.records(for: recordIDs, desiredKeys: nil)

        var recordsToSave: [CKRecord] = []
        recordsToSave.reserveCapacity(devices.count)

        let now = Date()

        for device in devices {
            let recordID = CKRecord.ID(recordName: device.id)
            let record: CKRecord
            if let found = existing[recordID], case .success(let existingRecord) = found {
                record = existingRecord
            } else {
                record = CKRecord(recordType: trustedDeviceRecordType, recordID: recordID)
            }

            record["deviceId"] = device.id
            record["name"] = device.name
            record["platform"] = device.platform.rawValue
            if let ip = device.ipAddress, !ip.isEmpty {
                record["ipAddress"] = ip
            } else {
                record["ipAddress"] = nil
            }
            record["addedAt"] = device.addedAt
            record["updatedAt"] = now

            recordsToSave.append(record)
        }

        // best-effort：atomically=false 允许部分成功；逐条记录错误会在结果里体现
        let (saveResults, _) = try await database.modifyRecords(
            saving: recordsToSave,
            deleting: [],
            savePolicy: .changedKeys,
            atomically: false
        )

        for (recordID, result) in saveResults {
            if case .failure(let error) = result {
                SkyBridgeLogger.shared.warning("⚠️ CloudKit 保存可信设备失败: \(recordID.recordName) error=\(error.localizedDescription)")
            }
        }
    }
}

/// Lightweight iCloud KVS presence heartbeat shared with the macOS app.
///
/// This is intentionally separate from CloudKit trusted-device sync. Presence must stay on by
/// default so Mac can refresh stale cloud rows as soon as the iPad app is foregrounded.
@MainActor
public final class ICloudDevicePresenceService: ObservableObject {
    public static let shared = ICloudDevicePresenceService()

    public struct ControlListenerReadiness: Equatable, Sendable {
        public let isReady: Bool
        public let controlPort: UInt16?

        public init(isReady: Bool, controlPort: UInt16?) {
            let hasValidPort = controlPort.map { $0 > 0 } == true
            self.isReady = isReady && hasValidPort
            self.controlPort = self.isReady ? controlPort : nil
        }

        public static let unavailable = ControlListenerReadiness(
            isReady: false,
            controlPort: nil
        )
    }

    private let kvStore = NSUbiquitousKeyValueStore.default
    private let deviceKeyPrefix = "skybridge.device."
    private let refreshInterval: TimeInterval = 30
    private var heartbeatTimer: Timer?
    private var didLogUnavailable = false
    private var didLogMissingReadinessProvider = false
    private var lastPublishedReadiness: ControlListenerReadiness?
    private var controlListenerReadinessProvider: (@MainActor () -> ControlListenerReadiness)?

    private init() {}

    public func configureControlListenerReadinessProvider(
        _ provider: @escaping @MainActor () -> ControlListenerReadiness
    ) {
        controlListenerReadinessProvider = provider
        didLogMissingReadinessProvider = false
    }

    public func start() {
        guard heartbeatTimer == nil else {
            refreshNow()
            return
        }

        refreshNow()
        let timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshNow()
            }
        }
        // 允许系统合并唤醒（省电）：心跳无需精确到秒，给 ~30% 容差让 iOS 对齐其它定时器。
        timer.tolerance = refreshInterval * 0.3
        heartbeatTimer = timer
        SkyBridgeLogger.shared.info("💓 iCloud KVS 在线心跳已启动")
    }

    public func stop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        publishPresence(readiness: .unavailable, reason: "listener-stopped")
    }

    public func refreshNow() {
        let readiness: ControlListenerReadiness
        if let controlListenerReadinessProvider {
            readiness = controlListenerReadinessProvider()
        } else {
            readiness = .unavailable
            if !didLogMissingReadinessProvider {
                didLogMissingReadinessProvider = true
                SkyBridgeLogger.shared.warning(
                    "⚠️ iCloud KVS 在线心跳按离线发布：未配置 P2P 控制监听器 readiness provider"
                )
            }
        }
        publishPresence(readiness: readiness, reason: "heartbeat")
    }

    private func publishPresence(
        readiness: ControlListenerReadiness,
        reason: String
    ) {
        guard FileManager.default.ubiquityIdentityToken != nil else {
            if !didLogUnavailable {
                didLogUnavailable = true
                SkyBridgeLogger.shared.warning("⚠️ iCloud KVS 在线心跳未发布：当前设备未登录 iCloud")
            }
            return
        }

        let identity = AppleMobileDeviceIdentity.currentSnapshot()
        let endpoint = Self.localNetworkEndpoint()
        let device = PresenceDevice(
            id: identity.stableDeviceId,
            name: identity.deviceName,
            model: identity.modelName,
            osVersion: identity.osVersion,
            appVersion: Self.appVersion(),
            lastSeen: Date(),
            capabilities: readiness.isReady
                ? ["remote_desktop", "file_transfer", "clipboard"]
                : [],
            isOnline: readiness.isReady,
            networkType: endpoint.networkType,
            ipAddress: endpoint.ipAddress,
            stableIdentityDeviceId: identity.stableDeviceId,
            vendorDeviceId: identity.vendorDeviceId,
            listenerReady: readiness.isReady,
            controlPort: readiness.controlPort
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(device)
            kvStore.set(data, forKey: deviceKeyPrefix + device.id)
            kvStore.synchronize()
            didLogUnavailable = false
            if readiness.isReady {
                SkyBridgeLogger.shared.debug(
                    "💓 iCloud KVS 在线心跳已发布: \(device.name) controlPort=\(readiness.controlPort.map(String.init) ?? "-") listenerReady=1"
                )
            } else if lastPublishedReadiness != readiness {
                SkyBridgeLogger.shared.info(
                    "💤 iCloud KVS 离线状态已发布: \(device.name) reason=\(reason) listenerReady=0"
                )
            }
            lastPublishedReadiness = readiness
        } catch {
            SkyBridgeLogger.shared.warning("⚠️ iCloud KVS 在线心跳编码失败: \(error.localizedDescription)")
        }
    }

    private struct PresenceDevice: Codable {
        let id: String
        let name: String
        let model: String
        let osVersion: String
        let appVersion: String
        let lastSeen: Date
        let capabilities: [String]
        let isOnline: Bool
        let networkType: String
        let ipAddress: String?
        let stableIdentityDeviceId: String
        let vendorDeviceId: String?
        let listenerReady: Bool
        let controlPort: UInt16?
    }

    private static func appVersion() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        guard let build, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }

    private static func localNetworkEndpoint() -> (ipAddress: String?, networkType: String) {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return (nil, "unknown")
        }
        defer { freeifaddrs(interfaces) }

        var en0IPv4: (ipAddress: String, networkType: String)?
        var wifiIPv4: (ipAddress: String, networkType: String)?
        var otherIPv4: (ipAddress: String, networkType: String)?
        var ipv6Fallback: (ipAddress: String, networkType: String)?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }

            guard let address = current.pointee.ifa_addr else { continue }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }

            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            let interfaceName = String(cString: current.pointee.ifa_name)
            guard let ip = numericHost(from: address) else { continue }
            let endpoint = (ipAddress: ip, networkType: networkType(for: interfaceName))

            if family == AF_INET {
                guard isAdvertisableRoutableIPv4(ip) else { continue }
                if interfaceName == "en0", en0IPv4 == nil {
                    en0IPv4 = endpoint
                } else if endpoint.networkType == "wifi", wifiIPv4 == nil {
                    wifiIPv4 = endpoint
                } else if otherIPv4 == nil {
                    otherIPv4 = endpoint
                }
            } else if ipv6Fallback == nil, isAdvertisableIPv6(ip) {
                ipv6Fallback = endpoint
            }
        }

        if let en0IPv4 { return (en0IPv4.ipAddress, en0IPv4.networkType) }
        if let wifiIPv4 { return (wifiIPv4.ipAddress, wifiIPv4.networkType) }
        if let otherIPv4 { return (otherIPv4.ipAddress, otherIPv4.networkType) }
        return ipv6Fallback.map { ($0.ipAddress, $0.networkType) } ?? (nil, "unknown")
    }

    private static func numericHost(from address: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { return nil }
        let byteCount = host.firstIndex(of: 0) ?? host.count
        let bytes = host[..<byteCount].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func networkType(for interfaceName: String) -> String {
        if interfaceName.hasPrefix("pdp_ip") { return "cellular" }
        if interfaceName == "en0" || interfaceName.hasPrefix("awdl") { return "wifi" }
        return "unknown"
    }

    private static func isAdvertisableRoutableIPv4(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IPv4Address(value) != nil else { return false }
        return !value.hasPrefix("169.254.")
            && !value.hasPrefix("127.")
            && !value.hasPrefix("0.")
            && value != "255.255.255.255"
    }

    private static func isAdvertisableIPv6(_ raw: String) -> Bool {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("[") && value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        if let scopeIndex = value.firstIndex(of: "%") {
            value = String(value[..<scopeIndex])
        }
        guard IPv6Address(value) != nil else { return false }
        return value != "::1" && !value.hasPrefix("fe80:")
    }
}
