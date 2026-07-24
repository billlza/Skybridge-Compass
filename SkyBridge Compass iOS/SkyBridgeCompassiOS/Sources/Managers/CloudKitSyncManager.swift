import Foundation
import CloudKit
import Darwin
import Network

private enum TrustedDeviceCloudWireLimits {
    static let maximumRecordCount = 2_000
    static let writeBatchSize = 200
    static let maximumDeviceIdentifierLength = 512
    static let maximumDeviceNameLength = 256
    static let maximumIPAddressLength = 128
    static let maximumKnownDeviceIdentifierCount = 64
}

/// CloudKit 同步管理器 - 同步设备列表和信任关系
@MainActor
public class CloudKitSyncManager: ObservableObject {
    public static let instance = CloudKitSyncManager()

    enum TrustedDeviceSyncTrigger: String, Sendable {
        case startup
        case foreground
        case manual
    }
    
    @Published public private(set) var isSyncing: Bool = false
    @Published public private(set) var lastSyncDate: Date?
    @Published public private(set) var lastSyncErrorMessage: String?
    
    private var container: CKContainer?
    private var database: CKDatabase?
    private var didLogEntitlementMissing = false

    private nonisolated static let trustedDeviceRecordType = "SBTrustedDevice"
    private let trustedDeviceResultsLimit = 200
    private let trustedDeviceMaximumRecordCount = TrustedDeviceCloudWireLimits.maximumRecordCount
    private let trustedDeviceWriteBatchSize = TrustedDeviceCloudWireLimits.writeBatchSize
    private let foregroundDeduplicationInterval: TimeInterval = 30
    private var initializationFailureReason: String?
    private var activeInitialization: Task<Void, Never>?
    private var cachedEntitlementCheck: CloudKitEntitlementCheck?
    private var activeTrustedDeviceSync: ActiveTrustedDeviceSync?
    private var lastSuccessfulTrustedDeviceSnapshot: [TrustedDeviceStore.TrustedDevice]?
    private var testingSyncOperation: (@MainActor @Sendable () async throws -> Void)?

    private struct ActiveTrustedDeviceSync {
        let id: UUID
        let task: Task<TrustedDeviceSyncCompletion, Error>
    }

    private struct TrustedDeviceSyncCompletion: Sendable {
        let completedAt: Date
        let localSnapshot: [TrustedDeviceStore.TrustedDevice]
    }

    private enum CloudKitEntitlementCheck: Sendable, Equatable {
        case enabled
        case profileNotEmbedded
        case missing
        case failed(String)
    }

    /// CKRecord is mutable and does not declare Sendable. Each fetched record
    /// page is no longer touched by the actor once wrapped, and the detached
    /// decoder performs read-only field extraction before the wrapper dies.
    private struct ImmutableTrustedDeviceRecordPage: @unchecked Sendable {
        let records: [CKRecord]
    }

    private struct PreparedTrustedDeviceRecordPage {
        let records: [CKRecord]
        let failures: [String]
        let quarantinedRecordNames: Set<String>
        let containsUnboundIdentityFailure: Bool
    }

    private struct DecodedTrustedDeviceRecordPage: Sendable {
        let devices: [TrustedDeviceStore.TrustedDevice]
        let failures: [String]
        let quarantinedRecordNames: Set<String>
        let containsUnboundIdentityFailure: Bool
    }

    private enum TrustedDeviceCloudSyncError: LocalizedError {
        case unavailable(String)
        case invalidRecord(field: String, reason: String)
        case recordIdentityMismatch
        case fetchIncomplete([String])
        case recordLimitExceeded(Int)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason):
                return "CloudKit 无法同步受信任设备：\(reason)"
            case .invalidRecord(let field, let reason):
                return "CloudKit 受信任设备字段 \(field) 无效：\(reason)"
            case .recordIdentityMismatch:
                return "CloudKit 受信任设备记录的 deviceId 与 recordName 不一致"
            case .fetchIncomplete(let failures):
                return "CloudKit 受信任设备读取不完整（\(failures.count) 条）：\(failures.joined(separator: "; "))"
            case .recordLimitExceeded(let limit):
                return "CloudKit 受信任设备记录超过安全上限（\(limit) 条）"
            }
        }
    }

    private struct TrustedDeviceCloudSaveError: LocalizedError {
        let failures: [String]

        var errorDescription: String? {
            "CloudKit 受信任设备保存未完整成功（\(failures.count) 条）：\(failures.joined(separator: "; "))"
        }
    }

    private struct TrustedDeviceCloudRecordFailure {
        let recordID: CKRecord.ID?
        let error: any Error
    }
    
    private init() {
        // 注意：未在 Xcode Signing 中启用 iCloud/CloudKit 能力时，
        // 直接访问 CKContainer(identifier:) 可能触发运行时中断（如你截图所示）。
        // 因此这里不在 init 里触碰 CloudKit；在 initialize() 里按需启用。
    }

#if DEBUG || SKYBRIDGE_TESTING
    init(
        testingSyncOperation: @escaping @MainActor @Sendable () async throws -> Void
    ) {
        self.testingSyncOperation = testingSyncOperation
    }
#endif
    
    public func initialize() async {
        if testingSyncOperation != nil {
            return
        }

        if database != nil, initializationFailureReason == nil {
            return
        }
        if let activeInitialization {
            await activeInitialization.value
            return
        }

        // The initialization flight owns its own completion bookkeeping. A
        // canceled or discarded lifecycle caller cannot leave a stale active
        // task or publish a partially initialized database.
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performInitialization()
            self.activeInitialization = nil
        }
        activeInitialization = task
        await task.value
    }

    private func performInitialization() async {
        #if targetEnvironment(simulator)
        let reason = "模拟器环境默认不初始化 CloudKit"
        initializationFailureReason = reason
        lastSyncErrorMessage = reason
        if container != nil || database != nil {
            container = nil
            database = nil
        }
        #else
        let entitlementCheck = await resolvedCloudKitEntitlementCheck()
        switch entitlementCheck {
        case .enabled:
            break
        case .profileNotEmbedded:
            // App Store apps intentionally do not contain an embedded profile.
            // Their restricted entitlements are validated during ingestion, so
            // continue with the default container and let CloudKit return its
            // explicit missingEntitlement/badContainer error if signing is wrong.
            SkyBridgeLogger.shared.debug(
                "ℹ️ CloudKit entitlement profile unavailable at runtime; continuing with signed default container"
            )
        case .missing:
            let reason = "缺少 iCloud/CloudKit entitlement"
            initializationFailureReason = reason
            lastSyncErrorMessage = reason
            container = nil
            database = nil
            if !didLogEntitlementMissing {
                didLogEntitlementMissing = true
                SkyBridgeLogger.shared.warning("⚠️ CloudKit 未启用：缺少 iCloud/CloudKit entitlement（请在 Xcode -> Signing & Capabilities -> iCloud 勾选 CloudKit，并配置容器）。")
            }
            return
        case .failed(let detail):
            let reason = "无法校验 iCloud/CloudKit entitlement：\(detail)"
            initializationFailureReason = reason
            lastSyncErrorMessage = reason
            container = nil
            database = nil
            SkyBridgeLogger.shared.error("⛔️ \(reason)")
            return
        }

        // 使用 default container（由 entitlements 决定），避免硬编码 container id
        let candidateContainer = CKContainer.default()

        // 检查 iCloud 状态
        do {
            let status = try await candidateContainer.accountStatus()
            if status == .available {
                container = candidateContainer
                database = candidateContainer.privateCloudDatabase
                initializationFailureReason = nil
                SkyBridgeLogger.shared.info("✅ iCloud 可用")
            } else {
                let reason = "iCloud 账户不可用（状态=\(status.rawValue)）"
                initializationFailureReason = reason
                lastSyncErrorMessage = reason
                container = nil
                database = nil
                SkyBridgeLogger.shared.warning("⚠️ \(reason)")
            }
        } catch {
            let reason = "无法读取 iCloud 账户状态：\(Self.safeErrorSummary(error))"
            initializationFailureReason = reason
            lastSyncErrorMessage = reason
            container = nil
            database = nil
            SkyBridgeLogger.shared.error("⛔️ \(reason)")
        }
        #endif
    }

    private func resolvedCloudKitEntitlementCheck() async -> CloudKitEntitlementCheck {
        if let cachedEntitlementCheck {
            return cachedEntitlementCheck
        }

        let check = await Task.detached(priority: .utility) {
            Self.cloudKitEntitlementCheck()
        }.value
        cachedEntitlementCheck = check
        return check
    }

    /// 在调用 CKContainer.default() 之前检查 entitlement，避免直接触发运行时中断。
    private nonisolated static func cloudKitEntitlementCheck() -> CloudKitEntitlementCheck {
        // 使用 embedded.mobileprovision 解析 entitlements（在 Debug/AdHoc 下通常存在）
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") else {
            return .profileNotEmbedded
        }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            return .failed("无法读取 embedded.mobileprovision")
        }
        return cloudKitEntitlementCheck(profileData: data)
    }

    private nonisolated static func cloudKitEntitlementCheck(
        profileData data: Data
    ) -> CloudKitEntitlementCheck {
        guard let raw = String(data: data, encoding: .isoLatin1) else {
            return .failed("embedded.mobileprovision 不是有效的 ISO-Latin-1 数据")
        }

        guard let plistStart = raw.range(of: "<plist"),
              let plistEnd = raw.range(of: "</plist>") else {
            return .failed("embedded.mobileprovision 缺少 plist")
        }
        let plistString = String(raw[plistStart.lowerBound..<plistEnd.upperBound])
        guard let plistData = plistString.data(using: .utf8) else {
            return .failed("entitlement plist 无法转为 UTF-8")
        }

        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(
                from: plistData,
                options: [],
                format: nil
            )
        } catch {
            return .failed("provisioning profile plist 解析失败")
        }
        guard let dictionary = propertyList as? [String: Any],
              let entitlements = dictionary["Entitlements"] as? [String: Any] else {
            return .failed("provisioning profile 缺少 Entitlements 字典")
        }

        if let services = entitlements["com.apple.developer.icloud-services"] as? [String],
           services.contains("CloudKit") || services.contains("CloudKit-Anonymous") {
            return .enabled
        }
        return .missing
    }

#if DEBUG || SKYBRIDGE_TESTING
    nonisolated static func shouldAttemptCloudKitForTesting(
        profileData: Data?
    ) -> Bool {
        let check = profileData.map { cloudKitEntitlementCheck(profileData: $0) }
            ?? .profileNotEmbedded
        switch check {
        case .enabled, .profileNotEmbedded:
            return true
        case .missing, .failed:
            return false
        }
    }
#endif

    /// Log only bounded error categories. CloudKit localized descriptions may
    /// contain record names, device identifiers, account metadata, or attacker-
    /// controlled field values and therefore must not be copied to logs.
    nonisolated static func safeErrorSummary(_ error: Error) -> String {
        if let cloudError = error as? CKError {
            return "CKError(code=\(cloudError.code.rawValue))"
        }
        if let syncError = error as? TrustedDeviceCloudSyncError {
            return syncError.localizedDescription
        }
        if let saveError = error as? TrustedDeviceCloudSaveError {
            return saveError.localizedDescription
        }
        if error is CancellationError {
            return "CancellationError"
        }
        return String(reflecting: type(of: error))
    }
    
    public func sync() async throws {
        if let activeTrustedDeviceSync {
            _ = try await activeTrustedDeviceSync.task.value
            return
        }

        let id = UUID()
        let task = Task { @MainActor [weak self] () throws -> TrustedDeviceSyncCompletion in
            guard let self else { throw CancellationError() }
            do {
                let localSnapshot = try await self.performTrustedDeviceSync()
                let completion = TrustedDeviceSyncCompletion(
                    completedAt: Date(),
                    localSnapshot: localSnapshot
                )
                completeTrustedDeviceSync(
                    id: id,
                    result: .success(completion)
                )
                return completion
            } catch {
                completeTrustedDeviceSync(id: id, result: .failure(error))
                throw error
            }
        }

        // This assignment happens before the new MainActor task can execute.
        // Completion is owned by the flight itself, not by whichever caller
        // happened to create or await it first.
        activeTrustedDeviceSync = ActiveTrustedDeviceSync(id: id, task: task)
        isSyncing = true
        _ = try await task.value
    }

    func refreshTrustedDevices(trigger: TrustedDeviceSyncTrigger) async throws {
        if trigger == .foreground, shouldDeduplicateForegroundRefresh() {
            SkyBridgeLogger.shared.debug("ℹ️ 跳过重复 CloudKit 前台同步：最近快照未变化")
            return
        }
        await initialize()
        try await sync()
        SkyBridgeLogger.shared.info(
            "✅ CloudKit 受信任设备同步完成: trigger=\(trigger.rawValue)"
        )
    }

    private func shouldDeduplicateForegroundRefresh(now: Date = Date()) -> Bool {
        guard activeTrustedDeviceSync == nil,
              lastSyncErrorMessage == nil,
              let lastSyncDate,
              now.timeIntervalSince(lastSyncDate) >= 0,
              now.timeIntervalSince(lastSyncDate) < foregroundDeduplicationInterval,
              lastSuccessfulTrustedDeviceSnapshot == TrustedDeviceStore.shared.trustedDevices else {
            return false
        }
        return true
    }

    private func performTrustedDeviceSync() async throws -> [TrustedDeviceStore.TrustedDevice] {
        if let testingSyncOperation {
            try await testingSyncOperation()
            return TrustedDeviceStore.shared.trustedDevices
        }

        if let initializationFailureReason {
            throw TrustedDeviceCloudSyncError.unavailable(initializationFailureReason)
        }
        guard container != nil, let database else {
            throw TrustedDeviceCloudSyncError.unavailable("尚未初始化")
        }

        // 1) 拉取云端可信设备
        let remoteTrusted = try await fetchRemoteTrustedDevices(database: database)

        // 2) 按生命周期代次合并；撤销 tombstone 不物理删除
        try await TrustedDeviceStore.shared.mergeFromCloudWithoutBlockingMainActor(remoteTrusted)

        // 3) 将本地可信设备 upsert 到云端（以 deviceId 为 recordName）
        let localTrusted = TrustedDeviceStore.shared.trustedDevices
        try await upsertTrustedDevices(
            localTrusted,
            database: database
        )
        return TrustedDeviceStore.shared.trustedDevices
    }

    private func completeTrustedDeviceSync(
        id: UUID,
        result: Result<TrustedDeviceSyncCompletion, Error>
    ) {
        guard activeTrustedDeviceSync?.id == id else { return }
        activeTrustedDeviceSync = nil
        isSyncing = false

        switch result {
        case .success(let completion):
            lastSyncDate = completion.completedAt
            lastSuccessfulTrustedDeviceSnapshot = completion.localSnapshot
            lastSyncErrorMessage = nil
        case .failure(let error):
            lastSyncErrorMessage = error.localizedDescription
            SkyBridgeLogger.shared.error(
                "⛔️ CloudKit 受信任设备同步失败：\(Self.safeErrorSummary(error))"
            )
        }
    }

    private func fetchRemoteTrustedDevices(database: CKDatabase) async throws -> [TrustedDeviceStore.TrustedDevice] {
        let query = CKQuery(
            recordType: Self.trustedDeviceRecordType,
            predicate: NSPredicate(value: true)
        )
        var cursor: CKQueryOperation.Cursor?
        var results: [TrustedDeviceStore.TrustedDevice] = []
        var fetchedRecordCount = 0

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

            let preparedPage = Self.prepareTrustedDeviceRecordPage(
                response.matchResults
            )
            var pageFailures = preparedPage.failures
            for failure in preparedPage.failures {
                SkyBridgeLogger.shared.error("⛔️ CloudKit 可信设备记录读取失败: \(failure)")
            }

            let immutablePage = ImmutableTrustedDeviceRecordPage(records: preparedPage.records)
            let decodedPage = await Task.detached(priority: .utility) {
                Self.decodeTrustedDevicePage(immutablePage)
            }.value
            fetchedRecordCount += response.matchResults.count
            let observedDevices = results + decodedPage.devices
            try await Self.failClosedIfTrustedDeviceFetchLimitExceeded(
                fetchedRecordCount: fetchedRecordCount,
                maximumRecordCount: trustedDeviceMaximumRecordCount,
                observedDevices: observedDevices,
                decodedPage: decodedPage,
                trustedDeviceStore: TrustedDeviceStore.shared
            )
            results = observedDevices
            pageFailures.append(contentsOf: decodedPage.failures)

            guard pageFailures.isEmpty else {
                try await Self.commitIncompleteFetchAuthorities(
                    observedDevices: results,
                    decodedPage: decodedPage,
                    additionalQuarantinedRecordNames: preparedPage.quarantinedRecordNames,
                    containsAdditionalUnboundIdentityFailure:
                        preparedPage.containsUnboundIdentityFailure,
                    trustedDeviceStore: TrustedDeviceStore.shared
                )
                throw TrustedDeviceCloudSyncError.fetchIncomplete(pageFailures.sorted())
            }

            cursor = response.queryCursor
        } while cursor != nil

        return results
    }

    /// CloudKit returns both a declared match-result key and a mutable record.
    /// The key is the query response binding; never discard it or accept a
    /// record whose identity/type differs from that binding.
    private static func prepareTrustedDeviceRecordPage(
        _ matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)]
    ) -> PreparedTrustedDeviceRecordPage {
        var records: [CKRecord] = []
        var failures: [String] = []
        var quarantinedRecordNames = Set<String>()
        var containsUnboundIdentityFailure = false
        records.reserveCapacity(matchResults.count)

        for (recordIndex, matchResult) in matchResults.enumerated() {
            let declaredRecordID = matchResult.0
            switch matchResult.1 {
            case .success(let record):
                guard record.recordID == declaredRecordID,
                      record.recordType == Self.trustedDeviceRecordType else {
                    failures.append(
                        "记录序号 \(recordIndex): CloudKit 返回记录身份绑定不一致"
                    )
                    if let recordName = canonicalTrustedDeviceRecordName(declaredRecordID) {
                        quarantinedRecordNames.insert(recordName)
                    } else {
                        containsUnboundIdentityFailure = true
                    }
                    continue
                }
                records.append(record)
            case .failure(let error):
                failures.append(
                    "记录序号 \(recordIndex): \(safeErrorSummary(error))"
                )
                if let recordName = canonicalTrustedDeviceRecordName(declaredRecordID) {
                    quarantinedRecordNames.insert(recordName)
                } else {
                    containsUnboundIdentityFailure = true
                }
            }
        }

        return PreparedTrustedDeviceRecordPage(
            records: records,
            failures: failures,
            quarantinedRecordNames: quarantinedRecordNames,
            containsUnboundIdentityFailure: containsUnboundIdentityFailure
        )
    }

    private nonisolated static func decodeTrustedDevicePage(
        _ page: ImmutableTrustedDeviceRecordPage
    ) -> DecodedTrustedDeviceRecordPage {
        var devices: [TrustedDeviceStore.TrustedDevice] = []
        var failures: [String] = []
        var quarantinedRecordNames = Set<String>()
        var containsUnboundIdentityFailure = false
        devices.reserveCapacity(page.records.count)

        for (recordIndex, record) in page.records.enumerated() {
            do {
                devices.append(try decodeTrustedDevice(record: record))
            } catch {
                if let recordName = canonicalTrustedDeviceRecordName(record.recordID) {
                    quarantinedRecordNames.insert(recordName)
                } else {
                    containsUnboundIdentityFailure = true
                }
                failures.append(
                    "记录序号 \(recordIndex): \(safeErrorSummary(error))"
                )
            }
        }
        return DecodedTrustedDeviceRecordPage(
            devices: devices,
            failures: failures,
            quarantinedRecordNames: quarantinedRecordNames,
            containsUnboundIdentityFailure: containsUnboundIdentityFailure
        )
    }

    private nonisolated static func canonicalTrustedDeviceRecordName(
        _ recordID: CKRecord.ID
    ) -> String? {
        let recordName = recordID.recordName
        let normalizedRecordName = recordName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRecordName.isEmpty,
              normalizedRecordName == recordName,
              normalizedRecordName.count
                <= TrustedDeviceCloudWireLimits.maximumDeviceIdentifierLength else {
            return nil
        }
        return normalizedRecordName
    }

    /// An incomplete CloudKit page must never discard already-observed negative
    /// lifecycle authority. Canonically bound malformed rows quarantine only
    /// their matching local authority. An unbindable record name is equivalent
    /// to the ambiguous-batch CAS case and quarantines the current local batch.
    /// Positive `active` rows are intentionally not committed from a partial
    /// snapshot because a later, unavailable page may carry their revocation.
    private static func commitIncompleteFetchAuthorities(
        observedDevices: [TrustedDeviceStore.TrustedDevice],
        decodedPage: DecodedTrustedDeviceRecordPage,
        additionalQuarantinedRecordNames: Set<String> = [],
        containsAdditionalUnboundIdentityFailure: Bool = false,
        trustedDeviceStore: TrustedDeviceStore
    ) async throws {
        let observedFailClosedAuthorities = observedDevices.filter { device in
            switch device.currentPathLifecycleState ?? .active {
            case .active:
                return false
            case .reverificationRequired, .quarantined, .revoked:
                return true
            }
        }
        if !observedFailClosedAuthorities.isEmpty {
            try await trustedDeviceStore.mergeFromCloudWithoutBlockingMainActor(
                observedFailClosedAuthorities
            )
        }

        var quarantinedDeviceIDs = decodedPage.quarantinedRecordNames
        quarantinedDeviceIDs.formUnion(additionalQuarantinedRecordNames)
        if decodedPage.containsUnboundIdentityFailure
            || containsAdditionalUnboundIdentityFailure {
            quarantinedDeviceIDs.formUnion(trustedDeviceStore.trustedDevices.map(\.id))
        }
        if !quarantinedDeviceIDs.isEmpty {
            try trustedDeviceStore.quarantineCloudConflictAuthorities(
                deviceIds: Array(quarantinedDeviceIDs).sorted()
            )
        }
    }

    private static func failClosedIfTrustedDeviceFetchLimitExceeded(
        fetchedRecordCount: Int,
        maximumRecordCount: Int,
        observedDevices: [TrustedDeviceStore.TrustedDevice],
        decodedPage: DecodedTrustedDeviceRecordPage,
        trustedDeviceStore: TrustedDeviceStore
    ) async throws {
        guard fetchedRecordCount > maximumRecordCount else { return }
        try await commitIncompleteFetchAuthorities(
            observedDevices: observedDevices,
            decodedPage: decodedPage,
            containsAdditionalUnboundIdentityFailure: true,
            trustedDeviceStore: trustedDeviceStore
        )
        throw TrustedDeviceCloudSyncError.recordLimitExceeded(maximumRecordCount)
    }

    private nonisolated static func decodeTrustedDevice(record: CKRecord) throws -> TrustedDeviceStore.TrustedDevice {
        func optionalString(_ field: String, maximumLength: Int) throws -> String? {
            guard let rawValue = record[field] else { return nil }
            guard let value = rawValue as? String else {
                throw TrustedDeviceCloudSyncError.invalidRecord(
                    field: field,
                    reason: "类型不是字符串"
                )
            }
            guard value.count <= maximumLength else {
                throw TrustedDeviceCloudSyncError.invalidRecord(
                    field: field,
                    reason: "长度超过上限"
                )
            }
            return value
        }

        guard record.recordType == Self.trustedDeviceRecordType else {
            throw TrustedDeviceCloudSyncError.invalidRecord(
                field: "recordType",
                reason: "不是受信任设备记录类型"
            )
        }
        guard let normalizedRecordName = canonicalTrustedDeviceRecordName(record.recordID) else {
            throw TrustedDeviceCloudSyncError.invalidRecord(
                field: "recordName",
                reason: "值为空、包含边界空白或长度超过上限"
            )
        }

        let id: String
        if let payloadDeviceID = try optionalString(
            "deviceId",
            maximumLength: TrustedDeviceCloudWireLimits.maximumDeviceIdentifierLength
        ) {
            let normalizedPayloadDeviceID = payloadDeviceID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard normalizedPayloadDeviceID == normalizedRecordName else {
                throw TrustedDeviceCloudSyncError.recordIdentityMismatch
            }
            id = normalizedPayloadDeviceID
        } else {
            // Legacy rows may omit the redundant payload field. `recordName`
            // remains the sole identity authority for those records.
            id = normalizedRecordName
        }

        let name = try optionalString(
            "name",
            maximumLength: TrustedDeviceCloudWireLimits.maximumDeviceNameLength
        ) ?? "Unknown"
        let platformRaw = try optionalString(
            "platform",
            maximumLength: 64
        ) ?? DevicePlatform.unknown.rawValue
        let platform = DevicePlatform(rawValue: platformRaw) ?? .unknown
        let ipAddress = try optionalString(
            "ipAddress",
            maximumLength: TrustedDeviceCloudWireLimits.maximumIPAddressLength
        )

        let addedAt: Date
        if let rawAddedAt = record["addedAt"] {
            guard let decodedAddedAt = rawAddedAt as? Date else {
                throw TrustedDeviceCloudSyncError.invalidRecord(
                    field: "addedAt",
                    reason: "类型不是日期"
                )
            }
            addedAt = decodedAddedAt
        } else {
            addedAt = Date()
        }

        let lifecycleState: TrustedDeviceStore.CurrentPathLifecycleState?
        if let rawLifecycleState = try optionalString(
            "lifecycleState",
            maximumLength: 64
        ) {
            guard let decodedLifecycleState = TrustedDeviceStore.CurrentPathLifecycleState(
                rawValue: rawLifecycleState
            ) else {
                throw TrustedDeviceCloudSyncError.invalidRecord(
                    field: "lifecycleState",
                    reason: "未知状态值"
                )
            }
            lifecycleState = decodedLifecycleState
        } else {
            // Missing state is the only accepted legacy representation of an
            // active record. Malformed present values fail the whole sync.
            lifecycleState = nil
        }

        let lifecycleGeneration: Int64?
        if let rawLifecycleGeneration = record["lifecycleGeneration"] {
            guard let number = rawLifecycleGeneration as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.rounded(.towardZero) == number.doubleValue,
                  number.int64Value >= 0 else {
                throw TrustedDeviceCloudSyncError.invalidRecord(
                    field: "lifecycleGeneration",
                    reason: "必须是非负整数"
                )
            }
            lifecycleGeneration = number.int64Value
        } else {
            lifecycleGeneration = nil
        }
        guard lifecycleState != nil || lifecycleGeneration == nil else {
            throw TrustedDeviceCloudSyncError.invalidRecord(
                field: "lifecycleGeneration",
                reason: "缺少 lifecycleState 的旧记录不得携带代次"
            )
        }

        let currentDeviceId: String?
        if let rawCurrentDeviceId = try optionalString(
            "currentDeviceId",
            maximumLength: TrustedDeviceCloudWireLimits.maximumDeviceIdentifierLength
        ) {
            let normalizedCurrentDeviceId = rawCurrentDeviceId.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !normalizedCurrentDeviceId.isEmpty else {
                throw TrustedDeviceCloudSyncError.invalidRecord(
                    field: "currentDeviceId",
                    reason: "值为空"
                )
            }
            currentDeviceId = normalizedCurrentDeviceId
        } else {
            currentDeviceId = nil
        }
        let knownDeviceIds: [String]?
        if let rawKnownDeviceIds = record["knownDeviceIds"] {
            guard let decodedKnownDeviceIds = rawKnownDeviceIds as? [String] else {
                throw TrustedDeviceCloudSyncError.invalidRecord(
                    field: "knownDeviceIds",
                    reason: "类型不是字符串数组"
                )
            }
            guard decodedKnownDeviceIds.count
                    <= TrustedDeviceCloudWireLimits.maximumKnownDeviceIdentifierCount else {
                throw TrustedDeviceCloudSyncError.invalidRecord(
                    field: "knownDeviceIds",
                    reason: "数量超过上限"
                )
            }
            let normalizedKnownDeviceIds = decodedKnownDeviceIds.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard normalizedKnownDeviceIds.allSatisfy({
                !$0.isEmpty
                    && $0.count <= TrustedDeviceCloudWireLimits.maximumDeviceIdentifierLength
            }) else {
                throw TrustedDeviceCloudSyncError.invalidRecord(
                    field: "knownDeviceIds",
                    reason: "包含空值或超长值"
                )
            }
            knownDeviceIds = Array(Set(normalizedKnownDeviceIds)).sorted()
        } else {
            knownDeviceIds = nil
        }

        return TrustedDeviceStore.TrustedDevice(
            id: id,
            name: name,
            platform: platform,
            ipAddress: ipAddress,
            addedAt: addedAt,
            currentDeviceId: currentDeviceId,
            knownDeviceIds: knownDeviceIds,
            currentPathLifecycleState: lifecycleState,
            currentPathLifecycleGeneration: lifecycleGeneration
        )
    }

    /// A point read precedes an `.ifServerRecordUnchanged` write. Bind that
    /// read to the exact requested identity before its lifecycle can influence
    /// the local winner. An ambiguous identity is persisted as quarantined so
    /// the ensuing sync error cannot leave stale positive trust usable.
    private static func decodeTrustedDeviceForCloudPointRead(
        record: CKRecord,
        expectedRecordID: CKRecord.ID,
        trustedDeviceStore: TrustedDeviceStore
    ) throws -> TrustedDeviceStore.TrustedDevice {
        do {
            guard record.recordID == expectedRecordID,
                  record.recordType == Self.trustedDeviceRecordType else {
                throw TrustedDeviceCloudSyncError.recordIdentityMismatch
            }
            return try decodeTrustedDevice(record: record)
        } catch let error as TrustedDeviceCloudSyncError {
            try trustedDeviceStore.quarantineCloudConflictAuthorities(
                deviceIds: [expectedRecordID.recordName]
            )
            throw error
        }
    }

#if DEBUG || SKYBRIDGE_TESTING
    func decodeTrustedDeviceForTesting(
        record: CKRecord
    ) throws -> TrustedDeviceStore.TrustedDevice {
        try Self.decodeTrustedDevice(record: record)
    }

    func decodeTrustedDevicePageForTesting(
        records: [CKRecord],
        trustedDeviceStore: TrustedDeviceStore
    ) async throws -> [TrustedDeviceStore.TrustedDevice] {
        try await decodeTrustedDeviceFetchResultsForTesting(
            matchResults: records.map { ($0.recordID, .success($0)) },
            trustedDeviceStore: trustedDeviceStore
        )
    }

    func decodeTrustedDeviceFetchResultsForTesting(
        matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)],
        trustedDeviceStore: TrustedDeviceStore
    ) async throws -> [TrustedDeviceStore.TrustedDevice] {
        let preparedPage = Self.prepareTrustedDeviceRecordPage(matchResults)
        let decodedPage = Self.decodeTrustedDevicePage(
            ImmutableTrustedDeviceRecordPage(records: preparedPage.records)
        )
        let failures = preparedPage.failures + decodedPage.failures
        guard failures.isEmpty else {
            try await Self.commitIncompleteFetchAuthorities(
                observedDevices: decodedPage.devices,
                decodedPage: decodedPage,
                additionalQuarantinedRecordNames: preparedPage.quarantinedRecordNames,
                containsAdditionalUnboundIdentityFailure:
                    preparedPage.containsUnboundIdentityFailure,
                trustedDeviceStore: trustedDeviceStore
            )
            throw TrustedDeviceCloudSyncError.fetchIncomplete(failures.sorted())
        }
        return decodedPage.devices
    }

    static func decodeTrustedDevicePointReadForTesting(
        record: CKRecord,
        expectedRecordID: CKRecord.ID,
        trustedDeviceStore: TrustedDeviceStore
    ) throws -> TrustedDeviceStore.TrustedDevice {
        try decodeTrustedDeviceForCloudPointRead(
            record: record,
            expectedRecordID: expectedRecordID,
            trustedDeviceStore: trustedDeviceStore
        )
    }

    static func failClosedForTrustedDeviceFetchLimitForTesting(
        fetchedRecordCount: Int,
        maximumRecordCount: Int,
        observedDevices: [TrustedDeviceStore.TrustedDevice],
        trustedDeviceStore: TrustedDeviceStore
    ) async throws {
        try await failClosedIfTrustedDeviceFetchLimitExceeded(
            fetchedRecordCount: fetchedRecordCount,
            maximumRecordCount: maximumRecordCount,
            observedDevices: observedDevices,
            decodedPage: DecodedTrustedDeviceRecordPage(
                devices: [],
                failures: [],
                quarantinedRecordNames: [],
                containsUnboundIdentityFailure: false
            ),
            trustedDeviceStore: trustedDeviceStore
        )
    }
#endif

    private nonisolated static func validateTrustedDeviceForCloudUpload(
        _ device: TrustedDeviceStore.TrustedDevice
    ) throws {
        let normalizedID = device.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty,
              normalizedID == device.id,
              normalizedID.count <= TrustedDeviceCloudWireLimits.maximumDeviceIdentifierLength else {
            throw TrustedDeviceCloudSyncError.invalidRecord(
                field: "deviceId",
                reason: "本地值为空、包含边界空白或长度超过上限"
            )
        }
        guard device.name.count <= TrustedDeviceCloudWireLimits.maximumDeviceNameLength else {
            throw TrustedDeviceCloudSyncError.invalidRecord(
                field: "name",
                reason: "本地值长度超过上限"
            )
        }
        if let ipAddress = device.ipAddress {
            guard ipAddress.count <= TrustedDeviceCloudWireLimits.maximumIPAddressLength else {
                throw TrustedDeviceCloudSyncError.invalidRecord(
                    field: "ipAddress",
                    reason: "本地值长度超过上限"
                )
            }
        }
        if let currentDeviceId = device.currentDeviceId {
            let normalizedCurrentDeviceId = currentDeviceId.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !normalizedCurrentDeviceId.isEmpty,
                  normalizedCurrentDeviceId == currentDeviceId,
                  normalizedCurrentDeviceId.count
                    <= TrustedDeviceCloudWireLimits.maximumDeviceIdentifierLength else {
                throw TrustedDeviceCloudSyncError.invalidRecord(
                    field: "currentDeviceId",
                    reason: "本地值为空、包含边界空白或长度超过上限"
                )
            }
        }
        let knownDeviceIds = device.knownDeviceIds ?? []
        guard knownDeviceIds.count
                <= TrustedDeviceCloudWireLimits.maximumKnownDeviceIdentifierCount,
              knownDeviceIds.allSatisfy({ value in
                  let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                  return !normalized.isEmpty
                      && normalized == value
                      && normalized.count
                        <= TrustedDeviceCloudWireLimits.maximumDeviceIdentifierLength
              }) else {
            throw TrustedDeviceCloudSyncError.invalidRecord(
                field: "knownDeviceIds",
                reason: "本地数组超限或包含无效值"
            )
        }
        if let generation = device.currentPathLifecycleGeneration, generation < 0 {
            throw TrustedDeviceCloudSyncError.invalidRecord(
                field: "lifecycleGeneration",
                reason: "本地值必须是非负整数"
            )
        }
    }

    nonisolated static func validateTrustedDeviceUploadCount(_ count: Int) throws {
        guard count >= 0,
              count <= TrustedDeviceCloudWireLimits.maximumRecordCount else {
            throw TrustedDeviceCloudSyncError.recordLimitExceeded(
                TrustedDeviceCloudWireLimits.maximumRecordCount
            )
        }
    }

    /// Select only lifecycle authority from the latest CloudKit value. Device
    /// metadata continues to come from the local snapshot; CloudKit is not a
    /// source of cryptographic pins or endpoint truth.
    nonisolated static func trustedDeviceForCloudUpsert(
        local: TrustedDeviceStore.TrustedDevice,
        existing: TrustedDeviceStore.TrustedDevice?
    ) throws -> TrustedDeviceStore.TrustedDevice {
        var resolved = local
        if let existing {
            let localGeneration = max(local.currentPathLifecycleGeneration ?? 0, 0)
            let existingGeneration = max(existing.currentPathLifecycleGeneration ?? 0, 0)
            let localPrecedence = lifecyclePrecedence(local.currentPathLifecycleState)
            let existingPrecedence = lifecyclePrecedence(existing.currentPathLifecycleState)
            let existingWins = existingGeneration > localGeneration
                || (existingGeneration == localGeneration
                    && existingPrecedence > localPrecedence)

            if existingWins {
                resolved.currentPathLifecycleState = existing.currentPathLifecycleState ?? .active
                resolved.currentPathLifecycleGeneration = existingGeneration
            }
        }

        if (resolved.currentPathLifecycleState ?? .active) == .revoked {
            guard let tombstone = TrustedDeviceStore.sanitizedRevokedTombstone(resolved) else {
                throw TrustedDeviceCloudSyncError.invalidRecord(
                    field: "deviceId",
                    reason: "撤销 tombstone 缺少稳定设备标识"
                )
            }
            return tombstone
        }
        return resolved
    }

    private nonisolated static func lifecyclePrecedence(
        _ state: TrustedDeviceStore.CurrentPathLifecycleState?
    ) -> Int {
        switch state ?? .active {
        case .active:
            return 0
        case .reverificationRequired:
            return 1
        case .quarantined:
            return 2
        case .revoked:
            return 3
        }
    }

    /// A lifecycle winner observed by the pre-save CloudKit point read is
    /// already remote authority. Persist it locally before attempting the
    /// upload so a save conflict or partial failure cannot resurrect stale
    /// active trust. The upload error is still propagated unchanged.
    @discardableResult
    static func withObservedLifecycleAuthorityCommitted<Result>(
        _ observedWinners: [TrustedDeviceStore.TrustedDevice],
        perform operation: () async throws -> Result
    ) async throws -> Result {
        if !observedWinners.isEmpty {
            try await TrustedDeviceStore.shared.mergeFromCloudWithoutBlockingMainActor(
                observedWinners
            )
        }
        return try await operation()
    }

    /// Extract per-record errors from CloudKit's top-level partial-failure
    /// envelope while preserving the record ID as an integrity binding hint.
    private static func flattenedCloudSaveFailures(
        from error: any Error,
        hintedRecordID: CKRecord.ID? = nil
    ) -> [TrustedDeviceCloudRecordFailure] {
        guard let cloudError = error as? CKError,
              cloudError.code == .partialFailure,
              let partialErrors = cloudError.partialErrorsByItemID,
              !partialErrors.isEmpty else {
            return [
                TrustedDeviceCloudRecordFailure(
                    recordID: hintedRecordID,
                    error: error
                )
            ]
        }

        return partialErrors.flatMap { itemID, itemError in
            let recordID = itemID.base as? CKRecord.ID ?? hintedRecordID
            return flattenedCloudSaveFailures(
                from: itemError,
                hintedRecordID: recordID
            )
        }
    }

    /// Commits lifecycle authority carried by `serverRecordChanged` before the
    /// original save failure is propagated. Only an exact record-ID/type/wire
    /// binding is accepted. Missing or mismatched conflict identity causes the
    /// implicated local authority (or the whole ambiguous batch) to be
    /// persistently quarantined instead of leaving stale active trust usable.
    private static func commitServerConflictLifecycleAuthorities(
        from failures: [TrustedDeviceCloudRecordFailure],
        expectedDevicesByRecordID: [CKRecord.ID: TrustedDeviceStore.TrustedDevice]
    ) async throws {
        guard !failures.isEmpty, !expectedDevicesByRecordID.isEmpty else { return }

        var observedWinners: [TrustedDeviceStore.TrustedDevice] = []
        var quarantinedDeviceIds = Set<String>()
        var quarantineWholeBatch = false

        for failure in failures {
            guard let cloudError = failure.error as? CKError,
                  cloudError.code == .serverRecordChanged else {
                continue
            }

            let serverRecord = cloudError.serverRecord
            let declaredRecordIDs = [
                failure.recordID,
                cloudError.clientRecord?.recordID,
                serverRecord?.recordID,
            ].compactMap { $0 }
            let associatedExpectedRecordIDs = Set(
                declaredRecordIDs.filter { expectedDevicesByRecordID[$0] != nil }
            )

            guard associatedExpectedRecordIDs.count == 1,
                  let expectedRecordID = associatedExpectedRecordIDs.first,
                  let expectedDevice = expectedDevicesByRecordID[expectedRecordID] else {
                if associatedExpectedRecordIDs.isEmpty {
                    quarantineWholeBatch = true
                } else {
                    quarantinedDeviceIds.formUnion(
                        associatedExpectedRecordIDs.compactMap {
                            expectedDevicesByRecordID[$0]?.id
                        }
                    )
                }
                continue
            }

            let hasExactRecordBinding = !declaredRecordIDs.isEmpty
                && declaredRecordIDs.allSatisfy { $0 == expectedRecordID }
            guard hasExactRecordBinding,
                  let serverRecord,
                  serverRecord.recordType == Self.trustedDeviceRecordType else {
                quarantinedDeviceIds.insert(expectedDevice.id)
                continue
            }

            do {
                let serverDevice = try decodeTrustedDevice(record: serverRecord)
                guard serverDevice.id == expectedRecordID.recordName else {
                    throw TrustedDeviceCloudSyncError.invalidRecord(
                        field: "deviceId",
                        reason: "与 CloudKit recordName 不一致"
                    )
                }
                let winner = try trustedDeviceForCloudUpsert(
                    local: expectedDevice,
                    existing: serverDevice
                )
                try validateTrustedDeviceForCloudUpload(winner)
                observedWinners.append(winner)
            } catch {
                // The original CKError remains the externally observable save
                // failure. This branch records only the fail-closed authority
                // transition and never trusts fields from the malformed record.
                quarantinedDeviceIds.insert(expectedDevice.id)
            }
        }

        if !observedWinners.isEmpty {
            try await TrustedDeviceStore.shared.mergeFromCloudWithoutBlockingMainActor(
                observedWinners
            )
        }
        if quarantineWholeBatch {
            quarantinedDeviceIds.formUnion(
                expectedDevicesByRecordID.values.map(\.id)
            )
        }
        if !quarantinedDeviceIds.isEmpty {
            try TrustedDeviceStore.shared.quarantineCloudConflictAuthorities(
                deviceIds: Array(quarantinedDeviceIds).sorted()
            )
        }
    }

#if DEBUG || SKYBRIDGE_TESTING
    static func commitServerConflictLifecycleAuthorityForTesting(
        error: any Error,
        expectedDevice: TrustedDeviceStore.TrustedDevice
    ) async throws {
        let recordID = CKRecord.ID(recordName: expectedDevice.id)
        try await commitServerConflictLifecycleAuthorities(
            from: flattenedCloudSaveFailures(
                from: error,
                hintedRecordID: recordID
            ),
            expectedDevicesByRecordID: [recordID: expectedDevice]
        )
    }
#endif

    private func upsertTrustedDevices(
        _ devices: [TrustedDeviceStore.TrustedDevice],
        database: CKDatabase
    ) async throws {
        guard !devices.isEmpty else { return }
        try Self.validateTrustedDeviceUploadCount(devices.count)

        var failures: [String] = []
        var batchStart = 0
        while batchStart < devices.count {
            let batchEnd = min(batchStart + trustedDeviceWriteBatchSize, devices.count)
            let batch = Array(devices[batchStart..<batchEnd])
            try batch.forEach(Self.validateTrustedDeviceForCloudUpload)
            let recordIDs = batch.map { CKRecord.ID(recordName: $0.id) }
            let existing = try await database.records(for: recordIDs, desiredKeys: nil)

            var recordsToSave: [CKRecord] = []
            recordsToSave.reserveCapacity(batch.count)
            var batchWinners: [TrustedDeviceStore.TrustedDevice] = []
            batchWinners.reserveCapacity(batch.count)
            let now = Date()

            for (recordIndex, device) in batch.enumerated() {
                let recordID = recordIDs[recordIndex]
                let record: CKRecord
                let existingDevice: TrustedDeviceStore.TrustedDevice?
                if let found = existing[recordID] {
                    switch found {
                    case .success(let existingRecord):
                        record = existingRecord
                        existingDevice = try Self.decodeTrustedDeviceForCloudPointRead(
                            record: existingRecord,
                            expectedRecordID: recordID,
                            trustedDeviceStore: TrustedDeviceStore.shared
                        )
                    case .failure(let error as CKError) where error.code == .unknownItem:
                        record = CKRecord(
                            recordType: Self.trustedDeviceRecordType,
                            recordID: recordID
                        )
                        existingDevice = nil
                    case .failure(let error):
                        failures.append(
                            "批次 \(batchStart / trustedDeviceWriteBatchSize) 读取序号 \(recordIndex): \(Self.safeErrorSummary(error))"
                        )
                        continue
                    }
                } else {
                    failures.append(
                        "批次 \(batchStart / trustedDeviceWriteBatchSize) 读取序号 \(recordIndex): CloudKit 未返回结果"
                    )
                    continue
                }

                let uploadDevice = try Self.trustedDeviceForCloudUpsert(
                    local: device,
                    existing: existingDevice
                )
                try Self.validateTrustedDeviceForCloudUpload(uploadDevice)

                record["deviceId"] = uploadDevice.id
                record["name"] = uploadDevice.name
                record["platform"] = uploadDevice.platform.rawValue
                if let ip = uploadDevice.ipAddress, !ip.isEmpty {
                    record["ipAddress"] = ip
                } else {
                    record["ipAddress"] = nil
                }
                record["addedAt"] = uploadDevice.addedAt
                record["lifecycleState"] = (uploadDevice.currentPathLifecycleState ?? .active).rawValue
                record["lifecycleGeneration"] = NSNumber(
                    value: max(uploadDevice.currentPathLifecycleGeneration ?? 0, 0)
                )
                record["currentDeviceId"] = uploadDevice.currentDeviceId
                record["knownDeviceIds"] = uploadDevice.knownDeviceIds
                record["updatedAt"] = now
                recordsToSave.append(record)
                batchWinners.append(uploadDevice)
            }

            let expectedDevicesByRecordID = Dictionary(
                uniqueKeysWithValues: zip(recordsToSave, batchWinners).map {
                    ($0.recordID, $1)
                }
            )
            let saveResults: [CKRecord.ID: Result<CKRecord, any Error>]
            do {
                (saveResults, _) = try await Self.withObservedLifecycleAuthorityCommitted(
                    batchWinners
                ) {
                    guard failures.isEmpty else {
                        throw TrustedDeviceCloudSaveError(failures: failures.sorted())
                    }

                    // `atomically=false` lets CloudKit make progress, but this method
                    // still throws if any authority record failed so callers cannot
                    // report a partially uploaded revocation set as successful.
                    return try await database.modifyRecords(
                        saving: recordsToSave,
                        deleting: [],
                        savePolicy: .ifServerRecordUnchanged,
                        atomically: false
                    )
                }
            } catch {
                try await Self.commitServerConflictLifecycleAuthorities(
                    from: Self.flattenedCloudSaveFailures(from: error),
                    expectedDevicesByRecordID: expectedDevicesByRecordID
                )
                throw error
            }

            var returnedSaveFailures: [TrustedDeviceCloudRecordFailure] = []
            for (recordIndex, record) in recordsToSave.enumerated() {
                guard let saveResult = saveResults[record.recordID] else {
                    failures.append(
                        "批次 \(batchStart / trustedDeviceWriteBatchSize) 保存序号 \(recordIndex): CloudKit 未返回结果"
                    )
                    continue
                }
                if case .failure(let error) = saveResult {
                    returnedSaveFailures.append(
                        TrustedDeviceCloudRecordFailure(
                            recordID: record.recordID,
                            error: error
                        )
                    )
                    failures.append(
                        "批次 \(batchStart / trustedDeviceWriteBatchSize) 保存序号 \(recordIndex): \(Self.safeErrorSummary(error))"
                    )
                }
            }
            try await Self.commitServerConflictLifecycleAuthorities(
                from: returnedSaveFailures.flatMap {
                    Self.flattenedCloudSaveFailures(
                        from: $0.error,
                        hintedRecordID: $0.recordID
                    )
                },
                expectedDevicesByRecordID: expectedDevicesByRecordID
            )
            if !failures.isEmpty {
                throw TrustedDeviceCloudSaveError(failures: failures.sorted())
            }

            batchStart = batchEnd
            await Task.yield()
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

        let protocolIdentity: ProtocolIdentitySnapshot
        do {
            protocolIdentity = try SkyBridgeiOSCore.shared.requireCurrentProtocolIdentitySnapshot()
        } catch {
            if !didLogUnavailable {
                didLogUnavailable = true
                SkyBridgeLogger.shared.warning(
                    "⚠️ iCloud KVS 在线心跳未发布：协议身份 authority 不可用 (\(error.localizedDescription))"
                )
            }
            return
        }

        let mobileIdentity = AppleMobileDeviceIdentity.currentSnapshot()
        let endpoint = Self.localNetworkEndpoint()
        let device = PresenceDevice(
            id: protocolIdentity.deviceId,
            name: mobileIdentity.deviceName,
            model: mobileIdentity.modelName,
            osVersion: mobileIdentity.osVersion,
            appVersion: Self.appVersion(),
            lastSeen: Date(),
            capabilities: readiness.isReady
                ? ["remote_desktop", "file_transfer", "clipboard"]
                : [],
            isOnline: readiness.isReady,
            networkType: endpoint.networkType,
            ipAddress: endpoint.ipAddress,
            stableIdentityDeviceId: protocolIdentity.deviceId,
            vendorDeviceId: mobileIdentity.vendorDeviceId,
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
