import Foundation
import CloudKit

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
