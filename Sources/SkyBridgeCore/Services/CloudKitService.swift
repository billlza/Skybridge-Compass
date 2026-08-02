// DEDUPLICATION TARGET — not inherently macOS-only.
//
// This type is cross-platform in nature, but the iOS app currently ships its own
// parallel implementation (CloudKitSyncManager). Phase 0 of the iOS/SkyBridgeCore unification only
// makes the core *compile* for iOS; adopting it on iOS is a later, deliberate migration
// per type. Excluding it here avoids standing up a second implementation inside one
// binary. The remaining macOS-only pieces are AppKit-based and must be replaced with
// platform-neutral equivalents as part of that migration.
// Tracked in Docs/background-wake-capability-ledger.md.
#if os(macOS)
import Foundation
import CloudKit
import Combine
import os.log
import AppKit
import Security

/// CloudKit 服务 - 负责 Apple ID 设备链的核心逻辑
/// 采用 CloudKit 最佳实践：自定义 Zone、增量同步、后台持久化
@MainActor
public final class CloudKitService: CloudDeviceService {

 // MARK: - 单例

    public static let shared = CloudKitService()

 // MARK: - 属性

 // 使用可选类型以避免在没有 entitlements 的环境下崩溃
 // 注意：CKContainer(identifier:) 在缺少 entitlement 时会直接崩溃，无法 catch
 // 因此在开发环境下，如果遇到 crash，请确保 Xcode 中添加了 iCloud Capability
    private lazy var container: CKContainer? = {
        guard Self.hasCloudKitEntitlement() else {
            logger.fault("缺少 CloudKit entitlements，禁用 CloudKitService")
            return nil
        }
        return CKContainer(identifier: "iCloud.com.skybridge.compass")
    }()

    private lazy var privateDB: CKDatabase? = container?.privateCloudDatabase
    private let logger = Logger(subsystem: "SkyBridgeCore", category: "CloudKitService")

 // 常量
    private let zoneName = "SkyBridgeDeviceZone"
    private let recordType = "SBDevice"

    /// Subscription id this service owns.
    ///
    /// Exposed so `RemoteNotificationRouter` can recognize silent pushes for it. It is the only
    /// identifier that authorizes a background refresh, so it must stay in sync with the
    /// `CKRecordZoneSubscription` created in `subscribeToZoneChanges()`.
    public nonisolated static let deviceChangesSubscriptionID = "skybridge-device-changes"

    private var subscriptionID: String { Self.deviceChangesSubscriptionID }

 // CloudKit 可用性（仅用于快速判断容器是否存在）
    public var isAvailable: Bool { container != nil }

 // 状态发布
    @Published public var accountStatus: CloudKitAccountStatus = .couldNotDetermine
    @Published public var devices: [CloudDevice] = []
    @Published public var isSyncing = false
    @Published public var lastSyncTime: Date?

 // Protocol Conformance
    public var devicesPublisher: AnyPublisher<[CloudDevice], Never> { $devices.eraseToAnyPublisher() }
    public var accountStatusPublisher: AnyPublisher<CloudKitAccountStatus, Never> { $accountStatus.eraseToAnyPublisher() }
    public var isSyncingPublisher: AnyPublisher<Bool, Never> { $isSyncing.eraseToAnyPublisher() }

 // 内部状态
    private var recordZone: CKRecordZone?
    private var serverChangeToken: CKServerChangeToken? {
        get {
            guard let data = UserDefaults.standard.data(forKey: "CKServerChangeToken") else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }
        set {
            if let token = newValue,
               let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: "CKServerChangeToken")
            } else {
                UserDefaults.standard.removeObject(forKey: "CKServerChangeToken")
            }
        }
    }

    private var heartbeatTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private struct ZoneRefreshSummary: Sendable {
        let changedRecordCount: Int
        let deletedRecordCount: Int
        let producedNewData: Bool
    }

    private struct ZoneRefreshOperation {
        let id: UUID
        let task: Task<ZoneRefreshSummary, Error>
    }

    private enum ZoneRefreshError: LocalizedError, Sendable {
        case serviceUnavailable
        case recordModificationFailed(reason: String)
        case changeTokenExpiredAfterFullRetry

        var errorDescription: String? {
            switch self {
            case .serviceUnavailable:
                return "CloudKit private database is unavailable"
            case .recordModificationFailed(let reason):
                return "CloudKit zone contained a record modification failure: \(reason)"
            case .changeTokenExpiredAfterFullRetry:
                return "CloudKit change token expired again after one full retry"
            }
        }
    }

    private enum SubscriptionValidationError: LocalizedError, Sendable {
        case wrongType
        case wrongZone
        case silentPushDisabled

        var errorDescription: String? {
            switch self {
            case .wrongType:
                return "Existing CloudKit subscription has the wrong type"
            case .wrongZone:
                return "Existing CloudKit subscription targets the wrong record zone"
            case .silentPushDisabled:
                return "Existing CloudKit subscription does not request content-available pushes"
            }
        }
    }

    private var inFlightZoneRefresh: ZoneRefreshOperation?

    /// CloudKit 容器 schema 尚未部署到 Production 时，写入/查询会持续返回
    /// `CKError.serverRejectedRequest` (15 / 内部 2000)。这是部署配置问题而非瞬时错误，
    /// 反复重试只会刷屏并空耗电量；命中后置位，停止心跳并仅提示一次。
    private var serverSchemaUnavailable = false

    /// 判断错误是否为「容器 schema/请求被服务端持久拒绝」——此类错误重试无意义。
    private nonisolated static func isPersistentServerRejection(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        switch ckError.code {
        case .serverRejectedRequest, .badContainer, .badDatabase, .managedAccountRestricted:
            return true
        default:
            return false
        }
    }

    /// 命中持久性服务端拒绝时的统一处理：停止心跳、置位、给出可操作的一次性提示。
    private func handlePersistentServerRejection(context: String, error: Error) {
        if !serverSchemaUnavailable {
            serverSchemaUnavailable = true
            logger.info("""
            CloudKit 服务端持久拒绝（\(context)）：\(error.localizedDescription)。\
            这通常表示记录类型 \(self.recordType) 的 schema 尚未部署到 Production 环境\
            （CloudKit Dashboard → Deploy Schema to Production）。已停止心跳，避免无谓重试与耗电。
            """)
        }
        stopHeartbeat()
    }

    /// Presentation cache of the canonical identity used by the latest successful
    /// CloudKit operation. `nil` means authority has not been resolved; it is never
    /// populated from the historical standalone device-ID keychain item.
    @Published public private(set) var currentDeviceId: String?

 // MARK: - 初始化

    private init() {
 // 监听 iCloud 账号状态变化
 // .receive(on: .main)：CloudKit 在自己的后台队列派发 .CKAccountChanged 通知,而本类是 @MainActor、
 // sink 闭包被编译为 MainActor 隔离。Swift 6 / macOS 27 运行时会在闭包入口断言"当前执行器==MainActor",
 // 若在后台队列直接调用即 SIGTRAP(dispatch_assert_queue 失败)。先切回主队列再交给 sink,满足隔离。
        NotificationCenter.default.publisher(for: .CKAccountChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.checkAccountStatus() }
            }
            .store(in: &cancellables)

 // 监听应用进入前台，触发同步
        NotificationCenter.default.publisher(for: NSApplication.willBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.refreshDevices() }
            }
            .store(in: &cancellables)
    }

 // MARK: - 公共方法

 /// 检查 iCloud 账号状态
    public func checkAccountStatus() async {
        guard let container = container else {
            self.accountStatus = .couldNotDetermine
            return
        }

        do {
            let ckStatus = try await container.accountStatus()
            self.accountStatus = CloudKitAccountStatus(rawValue: ckStatus.rawValue) ?? .couldNotDetermine
            logger.info("CloudKit 账号状态: \(ckStatus.rawValue)")

            if ckStatus == .available {
                await setupCloudKitEnvironment()
            } else {
                await stopService()
            }
        } catch {
            logger.error("CloudKit 账号状态检查失败: \(error.localizedDescription)")
            self.accountStatus = .couldNotDetermine
        }
    }

 /// 手动刷新设备列表
    public func refreshDevices() async {
        guard isAvailable, accountStatus == .available else { return }
        do {
            _ = try await fetchZoneChanges()
        } catch {
            if Self.isPersistentServerRejection(error) {
                handlePersistentServerRejection(context: "手动刷新", error: error)
            } else {
                logger.error("CloudKit 手动刷新失败: \(error.localizedDescription)")
            }
        }
    }

    /// Claims ownership of `deviceChangesSubscriptionID` with the remote-notification router.
    ///
    /// Registered alongside the subscription itself so a silent push can never authorize a refresh
    /// for a subscription this process does not actually maintain.
    private func registerRemoteNotificationHandler() async {
        await RemoteNotificationRouter.shared.registerHandler(
            forSubscriptionID: Self.deviceChangesSubscriptionID
        ) { [weak self] in
            guard let self else { return false }
            return try await self.refreshDevicesReportingChange()
        }
    }

    /// Refresh variant that reports whether the fetch actually changed the published device set.
    ///
    /// The remote-notification outcome must reflect reality: reporting `newData` unconditionally
    /// gets the app's background wakeups throttled by the system.
    private func refreshDevicesReportingChange() async throws -> Bool {
        guard isAvailable, accountStatus == .available else { return false }
        return try await fetchZoneChanges().producedNewData
    }

 // MARK: - 环境设置

    private func setupCloudKitEnvironment() async {
        guard isAvailable, let privateDB = privateDB else { return }
        logger.info("正在配置 CloudKit 环境...")

 // 1. 创建自定义 Zone
        let zone = CKRecordZone(zoneName: zoneName)
        self.recordZone = zone

        do {
            _ = try await privateDB.save(zone)
            logger.info("Record Zone 确认就绪")
        } catch {
 // 如果 Zone 已存在，会报错但不影响使用
            logger.debug("Zone 保存结果: \(error.localizedDescription)")
        }

 // 2. 订阅变更
        await subscribeToZoneChanges()

 // 3. 注册当前设备
        do {
            try await registerCurrentDevice()
        } catch {
            if Self.isPersistentServerRejection(error) {
                handlePersistentServerRejection(context: "注册当前设备", error: error)
            } else {
                logger.error(
                    "当前设备 CloudKit 注册已阻止: \(error.localizedDescription, privacy: .public)"
                )
            }
            return
        }

 // 4. 初次同步
        do {
            _ = try await fetchZoneChanges()
        } catch {
            if Self.isPersistentServerRejection(error) {
                handlePersistentServerRejection(context: "初次同步", error: error)
            } else {
                logger.error("CloudKit 初次同步失败: \(error.localizedDescription)")
            }
            return
        }

 // 5. 启动心跳
        startHeartbeat()
    }

    private func subscribeToZoneChanges() async {
        guard isAvailable, let privateDB = privateDB else { return }
        let zoneID = CKRecordZone.ID(
            zoneName: zoneName,
            ownerName: CKCurrentUserDefaultName
        )
        let subscription = CKRecordZoneSubscription(
            zoneID: zoneID,
            subscriptionID: subscriptionID
        )

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true // 静默推送
        subscription.notificationInfo = notificationInfo

        do {
            do {
                let existing = try await privateDB.subscription(for: subscriptionID)
                guard let existingZoneSubscription = existing as? CKRecordZoneSubscription else {
                    throw SubscriptionValidationError.wrongType
                }
                guard existingZoneSubscription.zoneID == zoneID else {
                    throw SubscriptionValidationError.wrongZone
                }
                guard existingZoneSubscription.notificationInfo?.shouldSendContentAvailable == true else {
                    throw SubscriptionValidationError.silentPushDisabled
                }
                logger.debug("已验证并复用既有 CloudKit 变更订阅")
            } catch let ckError as CKError where ckError.code == .unknownItem {
                _ = try await privateDB.save(subscription)
                logger.info("CloudKit 变更订阅创建成功")
            }

            await registerRemoteNotificationHandler()
        } catch let error {
            await RemoteNotificationRouter.shared.unregisterHandler(
                forSubscriptionID: Self.deviceChangesSubscriptionID
            )
            if Self.isPersistentServerRejection(error) {
                handlePersistentServerRejection(context: "变更订阅", error: error)
            }
            logger.error(
                "❌ CloudKit 变更订阅失败，静默推送唤醒不可用: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

 // MARK: - 核心逻辑：设备注册与心跳

 /// 注册/更新当前设备
    private func registerCurrentDevice() async throws {
        guard isAvailable, let privateDB = privateDB else { return }
        let identity = try await authoritativeCurrentIdentity(allowCreate: true)
        let deviceId = identity.deviceId
        logger.info("正在注册当前设备: \(deviceId)")

        let recordID = CKRecord.ID(recordName: deviceId, zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName))

 // 尝试获取现有记录以保留其他字段
        let record: CKRecord
        do {
            record = try await privateDB.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: recordType, recordID: recordID)
        }

 // 更新设备信息
        updateRecordFields(record, identity: identity)

        _ = try await privateDB.save(record)
        logger.info("当前设备注册/更新成功")
    }

    private func updateRecordFields(
        _ record: CKRecord,
        identity: SelfIdentitySnapshot
    ) {
        let localPresentation = LocalDevicePresentation.current()
        record["deviceId"] = identity.deviceId
        record["identityAuthorityVersion"] = 1
        record["deviceName"] = localPresentation.deviceName ?? localPresentation.modelName ?? "Unknown Device"
        record["deviceModel"] = getDeviceModel()
        record["publicKeyFingerprint"] = identity.pubKeyFP
        record["lastSeenAt"] = Date()
        record["capabilities"] = ["remoteDesktop", "fileTransfer"]
 // record["lastKnownEndpoint"] = ...
    }

 /// 更新心跳（轻量级更新）
    private func updateHeartbeatAsync() async {
        guard isAvailable, accountStatus == .available, !serverSchemaUnavailable, let privateDB = privateDB else { return }
        let identity: SelfIdentitySnapshot
        do {
            identity = try await authoritativeCurrentIdentity(allowCreate: false)
        } catch {
            logger.error(
                "CloudKit 心跳已阻止：本机身份 authority 不可用: \(error.localizedDescription, privacy: .public)"
            )
            stopHeartbeat()
            return
        }
        let recordID = CKRecord.ID(recordName: identity.deviceId, zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName))

        do {
            let record = try await privateDB.record(for: recordID)
            record["lastSeenAt"] = Date()
 // 仅保存变更的键
            _ = try await privateDB.save(record)
            logger.debug("心跳更新成功")
        } catch {
            if Self.isPersistentServerRejection(error) {
                handlePersistentServerRejection(context: "心跳更新", error: error)
            } else {
                logger.error("心跳更新失败: \(error.localizedDescription)")
            }
        }
    }

 // MARK: - 核心逻辑：增量同步

    /// 拉取 Zone 变更（增量同步）。并发调用共享同一个真实 fetch，所有等待者都拿到同一结果。
    private func fetchZoneChanges() async throws -> ZoneRefreshSummary {
        if let inFlightZoneRefresh {
            return try await inFlightZoneRefresh.task.value
        }
        guard isAvailable, privateDB != nil else {
            throw ZoneRefreshError.serviceUnavailable
        }

        let operationID = UUID()
        isSyncing = true
        let task = Task { @MainActor [weak self] () throws -> ZoneRefreshSummary in
            guard let self else { throw CancellationError() }
            return try await self.performZoneRefreshWithSingleTokenReset()
        }
        inFlightZoneRefresh = ZoneRefreshOperation(id: operationID, task: task)
        defer {
            if inFlightZoneRefresh?.id == operationID {
                inFlightZoneRefresh = nil
                isSyncing = false
            }
        }
        return try await task.value
    }

    private func performZoneRefreshWithSingleTokenReset() async throws -> ZoneRefreshSummary {
        do {
            return try await performZoneRefresh(since: serverChangeToken)
        } catch let ckError as CKError where ckError.code == .changeTokenExpired {
            logger.info("CloudKit change token 已过期，执行一次完整 Zone 重拉")
            do {
                return try await performZoneRefresh(since: nil)
            } catch let retryError as CKError where retryError.code == .changeTokenExpired {
                throw ZoneRefreshError.changeTokenExpiredAfterFullRetry
            }
        }
    }

    private func performZoneRefresh(
        since initialToken: CKServerChangeToken?
    ) async throws -> ZoneRefreshSummary {
        guard let privateDB else { throw ZoneRefreshError.serviceUnavailable }
        let zoneID = CKRecordZone.ID(
            zoneName: zoneName,
            ownerName: CKCurrentUserDefaultName
        )
        var nextToken = initialToken
        var changedRecordsByID: [CKRecord.ID: CKRecord] = [:]
        var deletedRecordIDsByID: [CKRecord.ID: CKRecord.ID] = [:]
        var moreComing = true

        while moreComing {
            try Task.checkCancellation()
            let page = try await privateDB.recordZoneChanges(
                inZoneWith: zoneID,
                since: nextToken
            )

            for (recordID, result) in page.modificationResultsByID {
                switch result {
                case .success(let modification):
                    changedRecordsByID[recordID] = modification.record
                    deletedRecordIDsByID.removeValue(forKey: recordID)
                case .failure(let error):
                    throw ZoneRefreshError.recordModificationFailed(
                        reason: error.localizedDescription
                    )
                }
            }
            for deletion in page.deletions {
                changedRecordsByID.removeValue(forKey: deletion.recordID)
                deletedRecordIDsByID[deletion.recordID] = deletion.recordID
            }

            nextToken = page.changeToken
            moreComing = page.moreComing
        }

        let before = devices
        let changedRecords = Array(changedRecordsByID.values)
        let deletedRecordIDs = Array(deletedRecordIDsByID.values)
        applyChanges(changed: changedRecords, deleted: deletedRecordIDs)
        serverChangeToken = nextToken
        lastSyncTime = Date()

        let producedNewData = devices != before
        logger.info(
            "同步完成: 更新 \(changedRecords.count), 删除 \(deletedRecordIDs.count), changed=\(producedNewData ? 1 : 0)"
        )
        return ZoneRefreshSummary(
            changedRecordCount: changedRecords.count,
            deletedRecordCount: deletedRecordIDs.count,
            producedNewData: producedNewData
        )
    }

    private func applyChanges(changed: [CKRecord], deleted: [CKRecord.ID]) {
 // 1. 处理删除
        if !deleted.isEmpty {
            let deletedIDs = Set(deleted.map { $0.recordName })
            self.devices.removeAll { deletedIDs.contains($0.id) }
        }

 // 2. 处理更新/新增
        for record in changed {
            if let device = CloudDevice(record: record) {
                if let index = self.devices.firstIndex(where: { $0.id == device.id }) {
                    self.devices[index] = device
                } else {
                    self.devices.append(device)
                }
            }
        }

 // 3. 排序
        self.devices.sort { $0.lastSeenAt > $1.lastSeenAt }
    }

 // MARK: - 辅助方法

    private func authoritativeCurrentIdentity(
        allowCreate: Bool
    ) async throws -> SelfIdentitySnapshot {
        let identity = try await SelfIdentityProvider.shared
            .snapshotEnsuringProtocolDeviceId(allowCreate: allowCreate)
        currentDeviceId = identity.deviceId
        return identity
    }

    private func startHeartbeat() {
        stopHeartbeat()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
 // 60s 基准 + 0~10s 抖动，减少同步唤醒
                let base: UInt64 = 60_000_000_000
                let jitter: UInt64 = UInt64(Int.random(in: 0...10)) * 1_000_000_000
                try? await Task.sleep(nanoseconds: base + jitter)
                guard !Task.isCancelled else { break }
                if let strongSelf = self {
                    await strongSelf.updateHeartbeatAsync()
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func stopService() async {
        stopHeartbeat()
        inFlightZoneRefresh?.task.cancel()
        inFlightZoneRefresh = nil
        isSyncing = false
        await RemoteNotificationRouter.shared.unregisterHandler(
            forSubscriptionID: Self.deviceChangesSubscriptionID
        )
        devices = []
    }

    private static func hasCloudKitEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let key = "com.apple.developer.icloud-services" as CFString
        guard let value = SecTaskCopyValueForEntitlement(task, key, nil) else { return false }
        if let arr = value as? [String] {
            return arr.contains("CloudKit") || arr.contains("CloudKit-Anonymous")
        }
        if let arr = value as? NSArray {
            for item in arr {
                if let s = item as? String, s == "CloudKit" || s == "CloudKit-Anonymous" {
                    return true
                }
            }
        }
        if let str = value as? String {
            return str.contains("CloudKit")
        }
        return false
    }

    private func getDeviceModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &machine, &size, nil, 0)
 // 去除空字符
        let data = Data(bytes: &machine, count: Int(size)).filter { $0 != 0 }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - 数据模型

 // CloudKit 可用性（仅用于快速判断容器是否存在）
#endif
