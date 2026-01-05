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
    private let subscriptionID = "skybridge-device-changes"
    
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
    
 // 当前设备 ID (懒加载)
    public lazy var currentDeviceId: String = {
        return KeychainManager.shared.getOrGenerateDeviceId()
    }()
    
 // MARK: - 初始化
    
    private init() {
 // 监听 iCloud 账号状态变化
        NotificationCenter.default.publisher(for: .CKAccountChanged)
            .sink { [weak self] _ in
                Task { await self?.checkAccountStatus() }
            }
            .store(in: &cancellables)
        
 // 监听应用进入前台，触发同步
        NotificationCenter.default.publisher(for: NSApplication.willBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { await self?.refreshDevices() }
            }
            .store(in: &cancellables)
    }
    
 // MARK: - 公共方法
    
 /// 检查 iCloud 账号状态
    public func checkAccountStatus() async {
        guard let container = container else {
            logger.error("CloudKit container 未初始化 (可能缺少 entitlements)")
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
                stopService()
            }
        } catch {
            logger.error("CloudKit 账号状态检查失败: \(error.localizedDescription)")
            self.accountStatus = .couldNotDetermine
        }
    }
    
 /// 手动刷新设备列表
    public func refreshDevices() async {
        guard isAvailable, accountStatus == .available else { return }
        await fetchZoneChanges()
    }
    
 // MARK: - 环境设置
    
    private func setupCloudKitEnvironment() async {
        guard isAvailable, let privateDB = privateDB else { return }
        logger.info("正在配置 CloudKit 环境...")
        
 // 1. 创建自定义 Zone
        let zone = CKRecordZone(zoneName: zoneName)
        self.recordZone = zone
        
        do {
            try await privateDB.save(zone)
            logger.info("Record Zone 确认就绪")
        } catch {
 // 如果 Zone 已存在，会报错但不影响使用
            logger.debug("Zone 保存结果: \(error.localizedDescription)")
        }
        
 // 2. 订阅变更
        await subscribeToZoneChanges()
        
 // 3. 注册当前设备
        await registerCurrentDevice()
        
 // 4. 初次同步
        await fetchZoneChanges()
        
 // 5. 启动心跳
        startHeartbeat()
    }
    
    private func subscribeToZoneChanges() async {
        guard isAvailable, let privateDB = privateDB else { return }
        let subscription = CKRecordZoneSubscription(zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName), subscriptionID: subscriptionID)
        
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true // 静默推送
        subscription.notificationInfo = notificationInfo
        
        do {
            _ = try await privateDB.save(subscription)
            logger.info("变更订阅成功")
        } catch {
 // 忽略重复订阅错误
            logger.debug("订阅结果: \(error.localizedDescription)")
        }
    }
    
 // MARK: - 核心逻辑：设备注册与心跳
    
 /// 注册/更新当前设备
    private func registerCurrentDevice() async {
        guard isAvailable, let privateDB = privateDB else { return }
        let deviceId = currentDeviceId
        logger.info("正在注册当前设备: \(deviceId)")
        
        let recordID = CKRecord.ID(recordName: deviceId, zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName))
        
        do {
 // 尝试获取现有记录以保留其他字段
            let record: CKRecord
            do {
                record = try await privateDB.record(for: recordID)
            } catch {
                record = CKRecord(recordType: recordType, recordID: recordID)
            }
            
 // 更新设备信息
            await updateRecordFields(record)
            
            _ = try await privateDB.save(record)
            logger.info("当前设备注册/更新成功")
        } catch {
            logger.error("注册当前设备失败: \(error.localizedDescription)")
        }
    }
    
    private func updateRecordFields(_ record: CKRecord) async {
        record["deviceId"] = currentDeviceId
        record["deviceName"] = Host.current().localizedName ?? "Unknown Device"
        record["deviceModel"] = getDeviceModel()
 // 写入真实公钥指纹（若可用）
        let selfId = await SelfIdentityProvider.shared.snapshot()
        if !selfId.pubKeyFP.isEmpty {
            record["publicKeyFingerprint"] = selfId.pubKeyFP
        } else {
            logger.warning("⚠️ 本机公钥指纹为空，publicKeyFingerprint 未写入")
        }
        record["lastSeenAt"] = Date()
        record["capabilities"] = ["remoteDesktop", "fileTransfer"]
 // record["lastKnownEndpoint"] = ...
    }
    
 /// 更新心跳（轻量级更新）
    private func updateHeartbeatAsync() async {
        guard isAvailable, accountStatus == .available, let privateDB = privateDB else { return }
        let recordID = CKRecord.ID(recordName: currentDeviceId, zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName))
        
        do {
            let record = try await privateDB.record(for: recordID)
            record["lastSeenAt"] = Date()
 // 仅保存变更的键
            _ = try await privateDB.save(record)
            logger.debug("心跳更新成功")
        } catch {
            logger.error("心跳更新失败: \(error.localizedDescription)")
        }
    }
    
 // MARK: - 核心逻辑：增量同步
    
 /// 拉取 Zone 变更（增量同步）
    private func fetchZoneChanges() async {
        guard isAvailable, !isSyncing, let privateDB = privateDB else { return }
        isSyncing = true
        
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        var configurations = [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration]()
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = serverChangeToken
        configurations[zoneID] = config
        
 // 使用 Operation 进行更细粒度的控制
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID], configurationsByRecordZoneID: configurations)
        
        var changedRecords = [CKRecord]()
        var deletedRecordIDs = [CKRecord.ID]()
        
        operation.recordWasChangedBlock = { recordID, result in
            if let record = try? result.get() {
                changedRecords.append(record)
            }
        }
        
        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            deletedRecordIDs.append(recordID)
        }
        
        operation.recordZoneChangeTokensUpdatedBlock = { zoneID, token, _ in
            self.serverChangeToken = token
        }
        
        operation.recordZoneFetchResultBlock = { zoneID, result in
            if let (token, _, _) = try? result.get() {
                self.serverChangeToken = token
            }
        }
        
        operation.fetchRecordZoneChangesResultBlock = { result in
            Task { @MainActor in
                self.isSyncing = false
                
                switch result {
                case .success:
                    self.applyChanges(changed: changedRecords, deleted: deletedRecordIDs)
                    self.lastSyncTime = Date()
                    self.logger.info("同步完成: 更新 \(changedRecords.count), 删除 \(deletedRecordIDs.count)")
                case .failure(let error):
                    self.logger.error("同步失败: \(error.localizedDescription)")
 // 处理 ChangeToken 过期的情况
                    if let ckError = error as? CKError, ckError.code == .changeTokenExpired {
                        self.serverChangeToken = nil
                        await self.fetchZoneChanges() // 重试全量
                    }
                }
            }
        }
        
 // 必须在非 MainActor 上运行 Operation
        let db = privateDB
        Task.detached {
            db.add(operation)
        }
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
    
    private func stopService() {
        stopHeartbeat()
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

public struct CloudDevice: Identifiable, Equatable, Codable {
    public let id: String
    public let deviceName: String
    public let deviceModel: String
    public let publicKey: String
    public let lastSeenAt: Date
    public let lastKnownEndpoint: String?
    public let capabilities: [String]
    
    public var isOnline: Bool {
 // 假设 5 分钟内有心跳视为在线
        return Date().timeIntervalSince(lastSeenAt) < 5 * 60
    }
    
 // 兼容 UI 的辅助属性
    public var name: String { deviceName }
    public var lastSeen: Date { lastSeenAt }
    public var type: DeviceType {
        if deviceModel.contains("Mac") { return .mac }
        if deviceModel.contains("iPhone") { return .iPhone }
        if deviceModel.contains("iPad") { return .iPad }
        return .mac // Default
    }
    
    public enum DeviceType: String, Codable {
        case mac, iPhone, iPad
    }
    
    public enum DeviceCapability: String, Codable {
        case remoteDesktop, fileTransfer, screenMirroring
    }
    
    public var deviceCapabilities: [DeviceCapability] {
        return capabilities.compactMap { DeviceCapability(rawValue: $0) }
    }
    
    init?(record: CKRecord) {
        guard let deviceId = record["deviceId"] as? String,
              let deviceName = record["deviceName"] as? String,
              let lastSeenAt = record["lastSeenAt"] as? Date else {
            return nil
        }
        let publicKey = (record["publicKeyFingerprint"] as? String) ?? (record["publicKey"] as? String) ?? ""
        
        self.id = deviceId
        self.deviceName = deviceName
        self.deviceModel = record["deviceModel"] as? String ?? "Unknown"
        self.publicKey = publicKey
        self.lastSeenAt = lastSeenAt
        self.lastKnownEndpoint = record["lastKnownEndpoint"] as? String
        self.capabilities = record["capabilities"] as? [String] ?? []
    }
    
 // 为了兼容 CrossNetworkConnectionManager 的初始化
    public init(id: String, name: String, type: DeviceType, lastSeen: Date, capabilities: [DeviceCapability]) {
        self.id = id
        self.deviceName = name
        self.deviceModel = type == .mac ? "Mac" : (type == .iPhone ? "iPhone" : "iPad")
        self.publicKey = ""
        self.lastSeenAt = lastSeen
        self.lastKnownEndpoint = nil
        self.capabilities = capabilities.map { $0.rawValue }
    }
}
 // CloudKit 可用性（仅用于快速判断容器是否存在）
