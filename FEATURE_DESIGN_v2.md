# SkyBridge Compass Pro - 新功能技术设计方案
## macOS 26 (Tahoe) + Swift 6.2.3 最佳实践

> 创建日期: 2026-01-10
> 目标平台: macOS 14.0+ (支持 14.x, 15.x, 26.x)
> Swift 版本: 6.2.3 (Strict Concurrency)
> 架构策略: 渐进增强 (Progressive Enhancement)

> **⚠️ 状态说明（2026-06-16 更新）**：本文是 **功能设计方案（design proposal）**，不是已完成功能清单。下方“支持矩阵”的 ✅ 表示**设计目标**，落地程度不一：
> - **已落地**：剪贴板同步（实现为 `ClipboardRedirection`/`ClipboardRedirectionManager`，非本文命名的 `ClipboardSyncManager`）、带宽限速、离线消息队列、多因素审批、网络感知调度。
> - **部分/规划中**：硬件性能监控、云端备份（CKSyncEngine）、ML 异常检测（Foundation Models —— 按既定约束**禁止进入握手/加密/媒体热路径**，仅诊断旁路）。
> 本文档当前的工具链描述（Swift 6.2.3、仅到 macOS 26）已落后于仓库实际（**Swift 6.3 / Xcode 26.5**，并已通过 `#available(... *)` 加性支持 **OS 27**，部署底线仍为 macOS 14 / iOS 17）。引用本文前请以代码与 `Package.swift` 为准；逐功能的真实状态/代码路径应在后续 `ROADMAP.md` 中维护。

---

## 🎯 多版本兼容策略

### 支持矩阵

| 功能 | macOS 14 | macOS 15 | macOS 26 |
|-----|----------|----------|----------|
| 剪贴板同步 | ✅ Combine | ✅ Combine | ✅ Observations |
| 带宽限速 | ✅ 完整 | ✅ 完整 | ✅ 完整 |
| 离线消息队列 | ✅ 完整 | ✅ 完整 | ✅ 完整 |
| 硬件性能监控 | ✅ Metal 3 | ✅ Metal 3 | ✅ Metal 4 |
| 云端备份 | ✅ CKDatabase | ✅ CKDatabase | ✅ CKSyncEngine |
| 多因素审批 | ✅ 完整 | ✅ 完整 | ✅ 完整 |
| 网络感知调度 | ✅ 完整 | ✅ 完整 | ✅ 完整 |
| ML 异常检测 | ⚠️ 简化规则 | ⚠️ 简化规则 | ✅ Foundation Models |

### 核心兼容性模式

```swift
// 1. 运行时版本检查
@available(macOS 26, *)
func useNewAPI() { ... }

func fallbackAPI() { ... }

func myFeature() {
    if #available(macOS 26, *) {
        useNewAPI()
    } else {
        fallbackAPI()
    }
}

// 2. 协议抽象 + 工厂模式
protocol CloudSyncProvider {
    func sync() async throws
    func fetch() async throws -> Data
}

@available(macOS 26, *)
final class CKSyncEngineProvider: CloudSyncProvider { ... }

final class LegacyCKDatabaseProvider: CloudSyncProvider { ... }

final class CloudSyncFactory {
    static func createProvider() -> CloudSyncProvider {
        if #available(macOS 26, *) {
            return CKSyncEngineProvider()
        } else {
            return LegacyCKDatabaseProvider()
        }
    }
}

// 3. Typed Throws 兼容 (Swift 6.0+)
// Swift 6.2 新语法在编译时自动降级
public func fetchData() throws(NetworkError) -> Data {
    // 在 macOS 14/15 上编译为普通 throws
}

// 4. Observations 兼容
// 使用 Perception 2.0 backport 库支持 macOS 14+
#if canImport(Observation)
import Observation
typealias ObservableObject = Observation.Observable
#else
import Perception
typealias ObservableObject = Perception.Perceptible
#endif
```

### 依赖的 Backport 库

```swift
// Package.swift 添加
.package(url: "https://github.com/pointfreeco/swift-perception", from: "2.0.0"),
```

---

## 技术栈升级要点

### Swift 6.2 新特性应用

```swift
// 1. 默认 MainActor 隔离 (Xcode 26 默认设置)
// Build Settings → Default Actor Isolation = MainActor

// 2. Typed Throws - 所有新代码使用
func fetchData() throws(NetworkError) -> Data { ... }

// 3. @concurrent 标记并发函数
@concurrent
func performHeavyComputation() async -> Result { ... }

// 4. Observations AsyncSequence 监听变化
for await state in Observations { clipboard.content } {
    await syncToCloud(state)
}

// 5. nonisolated(nonsending) 继承调用者上下文
nonisolated(nonsending) func processData() async { ... }
```

### macOS 26 新 API 应用

| 框架 | 用途 |
|-----|------|
| Foundation Models | ML 异常检测本地推理 |
| Metal 4 + MTLTensor | GPU 性能监控 |
| CKSyncEngine | 云端同步备份 |
| Observations | 状态变化流式监听 |
| App Intents | Siri/Shortcuts 集成 |

---

## 功能 1: 跨设备剪贴板同步

### 技术架构

```
┌─────────────────┐     ┌─────────────────┐
│   Device A      │     │   Device B      │
│ ┌─────────────┐ │     │ ┌─────────────┐ │
│ │ NSPasteboard│ │     │ │ NSPasteboard│ │
│ └──────┬──────┘ │     │ └──────┬──────┘ │
│        │        │     │        │        │
│ ┌──────▼──────┐ │     │ ┌──────▼──────┐ │
│ │ClipboardMgr │◄├─────┼─►ClipboardMgr │ │
│ └──────┬──────┘ │     │ └──────┬──────┘ │
│        │        │     │        │        │
│ ┌──────▼──────┐ │     │ ┌──────▼──────┐ │
│ │ P2P Channel │◄├─────┼─►P2P Channel  │ │
│ └─────────────┘ │     │ └─────────────┘ │
└─────────────────┘     └─────────────────┘
```

### 核心实现

```swift
// Sources/SkyBridgeCore/Clipboard/ClipboardSyncManager.swift

import Foundation
import AppKit
import Observation

/// 剪贴板同步错误类型 - Swift 6.2 Typed Throws
public enum ClipboardSyncError: Error, Sendable {
    case encryptionFailed
    case decryptionFailed
    case connectionLost
    case contentTooLarge(size: Int, maxSize: Int)
    case unsupportedType(String)
}

/// 剪贴板内容模型
@Observable
public final class ClipboardContent: Sendable {
    public var text: String?
    public var imageData: Data?
    public var fileURLs: [URL]?
    public var timestamp: Date
    public var sourceDeviceID: String

    public init(sourceDeviceID: String) {
        self.timestamp = Date()
        self.sourceDeviceID = sourceDeviceID
    }
}

/// 跨设备剪贴板同步管理器
@MainActor
public final class ClipboardSyncManager: ObservableObject {

    // MARK: - Published State
    @Published public private(set) var isSyncEnabled: Bool = false
    @Published public private(set) var lastSyncTime: Date?
    @Published public private(set) var connectedDevices: [String] = []

    // MARK: - Private Properties
    private let pasteboard = NSPasteboard.general
    private var changeCount: Int = 0
    private var monitorTask: Task<Void, Never>?
    private let p2pChannel: P2PSecureChannel
    private let encryptor: ClipboardEncryptor
    private let logger = SkyBridgeLogger(category: "ClipboardSync")

    // 配置
    private let maxContentSize = 10 * 1024 * 1024 // 10MB
    private let syncDebounceInterval: Duration = .milliseconds(500)

    // MARK: - Initialization

    public init(p2pChannel: P2PSecureChannel) {
        self.p2pChannel = p2pChannel
        self.encryptor = ClipboardEncryptor()
    }

    // MARK: - Public Methods

    /// 启动剪贴板同步
    public func startSync() throws(ClipboardSyncError) {
        guard !isSyncEnabled else { return }

        isSyncEnabled = true
        startMonitoring()
        startReceiving()

        logger.info("剪贴板同步已启动")
    }

    /// 停止剪贴板同步
    public func stopSync() {
        isSyncEnabled = false
        monitorTask?.cancel()
        monitorTask = nil

        logger.info("剪贴板同步已停止")
    }

    // MARK: - Private Methods

    /// 监听本地剪贴板变化 - 使用 Swift 6.2 Observations
    private func startMonitoring() {
        monitorTask = Task { [weak self] in
            guard let self else { return }

            // 轮询检测剪贴板变化 (macOS 无原生通知)
            while !Task.isCancelled && isSyncEnabled {
                let currentCount = pasteboard.changeCount

                if currentCount != changeCount {
                    changeCount = currentCount
                    await handleLocalClipboardChange()
                }

                try? await Task.sleep(for: syncDebounceInterval)
            }
        }
    }

    /// 处理本地剪贴板变化
    private func handleLocalClipboardChange() async {
        guard let content = readClipboardContent() else { return }

        do {
            // 加密内容
            let encryptedData = try encryptor.encrypt(content)

            // 通过 P2P 通道发送到所有连接的设备
            for deviceID in connectedDevices {
                try await p2pChannel.send(
                    data: encryptedData,
                    to: deviceID,
                    type: .clipboardSync
                )
            }

            lastSyncTime = Date()
            logger.info("剪贴板内容已同步到 \(connectedDevices.count) 台设备")

        } catch let error as ClipboardSyncError {
            logger.error("剪贴板同步失败: \(error)")
        } catch {
            logger.error("未知错误: \(error)")
        }
    }

    /// 接收远程剪贴板内容
    private func startReceiving() {
        Task { [weak self] in
            guard let self else { return }

            // 使用 Swift 6.2 AsyncSequence 监听
            for await message in p2pChannel.messages(ofType: .clipboardSync) {
                guard isSyncEnabled else { break }

                do {
                    let content = try encryptor.decrypt(message.data)
                    await applyRemoteClipboard(content)
                } catch {
                    logger.error("解密远程剪贴板失败: \(error)")
                }
            }
        }
    }

    /// 应用远程剪贴板内容到本地
    private func applyRemoteClipboard(_ content: ClipboardContent) async {
        // 暂时禁用监听避免循环
        let previousCount = pasteboard.changeCount

        pasteboard.clearContents()

        if let text = content.text {
            pasteboard.setString(text, forType: .string)
        }

        if let imageData = content.imageData,
           let image = NSImage(data: imageData) {
            pasteboard.writeObjects([image])
        }

        // 更新 changeCount 避免触发自己的同步
        changeCount = pasteboard.changeCount

        logger.info("已应用来自设备 \(content.sourceDeviceID) 的剪贴板内容")
    }

    /// 读取当前剪贴板内容
    private func readClipboardContent() -> ClipboardContent? {
        let content = ClipboardContent(sourceDeviceID: DeviceIdentity.current.id)

        // 文本
        if let text = pasteboard.string(forType: .string) {
            content.text = text
        }

        // 图片
        if let imageData = pasteboard.data(forType: .tiff) {
            guard imageData.count <= maxContentSize else {
                logger.warning("图片太大，跳过同步: \(imageData.count) bytes")
                return nil
            }
            content.imageData = imageData
        }

        // 如果没有内容则返回 nil
        guard content.text != nil || content.imageData != nil else {
            return nil
        }

        return content
    }
}

/// 剪贴板内容加密器
private final class ClipboardEncryptor: Sendable {

    private let symmetricKey: SymmetricKey

    init() {
        // 使用设备密钥派生
        self.symmetricKey = KeyDerivation.deriveClipboardKey()
    }

    func encrypt(_ content: ClipboardContent) throws(ClipboardSyncError) -> Data {
        do {
            let data = try JSONEncoder().encode(content)
            let sealedBox = try AES.GCM.seal(data, using: symmetricKey)
            return sealedBox.combined ?? Data()
        } catch {
            throw .encryptionFailed
        }
    }

    func decrypt(_ data: Data) throws(ClipboardSyncError) -> ClipboardContent {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            let decryptedData = try AES.GCM.open(sealedBox, using: symmetricKey)
            return try JSONDecoder().decode(ClipboardContent.self, from: decryptedData)
        } catch {
            throw .decryptionFailed
        }
    }
}
```

---

## 功能 2: 带宽限速 UI

### 技术架构

```
┌────────────────────────────────────────┐
│           BandwidthLimitView           │
│  ┌──────────────────────────────────┐  │
│  │  全局限速: [=====|-----] 50 Mbps │  │
│  │  设备A:    [===|-------] 20 Mbps │  │
│  │  设备B:    [========|--] 80 Mbps │  │
│  └──────────────────────────────────┘  │
│  ┌──────────────────────────────────┐  │
│  │  时段设置:                       │  │
│  │  ☑ 工作时间 (9-18): 30 Mbps     │  │
│  │  ☑ 夜间 (0-6): 无限制           │  │
│  └──────────────────────────────────┘  │
└────────────────────────────────────────┘
          │
          ▼
┌────────────────────────────────────────┐
│       BandwidthThrottleEngine          │
│  ┌─────────────┐  ┌─────────────────┐  │
│  │TokenBucket  │  │ScheduleManager │  │
│  │  Limiter    │  │                 │  │
│  └─────────────┘  └─────────────────┘  │
└────────────────────────────────────────┘
```

### 核心实现

```swift
// Sources/SkyBridgeCore/Network/BandwidthThrottleEngine.swift

import Foundation
import Network

/// 带宽限速配置
public struct BandwidthLimit: Codable, Sendable, Equatable {
    public var globalLimit: Int64?        // bytes/sec, nil = 无限制
    public var perDeviceLimits: [String: Int64] = [:]
    public var schedules: [BandwidthSchedule] = []

    public static let unlimited = BandwidthLimit()

    /// 获取当前生效的限速值
    public func effectiveLimit(for deviceID: String? = nil, at date: Date = Date()) -> Int64? {
        // 检查时段限制
        for schedule in schedules where schedule.isActive(at: date) {
            if let deviceID, let deviceLimit = perDeviceLimits[deviceID] {
                return min(schedule.limit, deviceLimit)
            }
            return schedule.limit
        }

        // 检查设备限制
        if let deviceID, let deviceLimit = perDeviceLimits[deviceID] {
            return deviceLimit
        }

        return globalLimit
    }
}

/// 时段限速配置
public struct BandwidthSchedule: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var startHour: Int
    public var endHour: Int
    public var limit: Int64        // bytes/sec
    public var daysOfWeek: Set<Int> // 1=周日, 2=周一, ...
    public var isEnabled: Bool = true

    public func isActive(at date: Date = Date()) -> Bool {
        guard isEnabled else { return false }

        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let weekday = calendar.component(.weekday, from: date)

        guard daysOfWeek.contains(weekday) else { return false }

        if startHour <= endHour {
            return hour >= startHour && hour < endHour
        } else {
            // 跨夜: 如 22:00 - 06:00
            return hour >= startHour || hour < endHour
        }
    }
}

/// 带宽限速引擎 - 使用令牌桶算法
@MainActor
public final class BandwidthThrottleEngine: ObservableObject {

    // MARK: - Published State
    @Published public var config: BandwidthLimit {
        didSet { saveConfig() }
    }
    @Published public private(set) var currentUsage: [String: Int64] = [:] // 当前使用量

    // MARK: - Private Properties
    private var tokenBuckets: [String: TokenBucket] = [:]
    private let logger = SkyBridgeLogger(category: "Bandwidth")
    private let configKey = "com.skybridge.bandwidth.config"

    // MARK: - Initialization

    public init() {
        self.config = Self.loadConfig() ?? .unlimited
    }

    // MARK: - Public Methods

    /// 请求发送数据的许可
    /// - Returns: 允许发送的字节数
    @concurrent
    public func requestPermission(
        bytes: Int64,
        deviceID: String
    ) async -> Int64 {
        let limit = config.effectiveLimit(for: deviceID)

        guard let limit else {
            // 无限制
            return bytes
        }

        let bucket = await getOrCreateBucket(for: deviceID, limit: limit)
        return await bucket.consume(bytes)
    }

    /// 报告实际使用的带宽
    public func reportUsage(bytes: Int64, deviceID: String) {
        currentUsage[deviceID, default: 0] += bytes
    }

    /// 重置统计
    public func resetStatistics() {
        currentUsage.removeAll()
    }

    // MARK: - Private Methods

    private func getOrCreateBucket(for deviceID: String, limit: Int64) async -> TokenBucket {
        if let bucket = tokenBuckets[deviceID] {
            await bucket.updateLimit(limit)
            return bucket
        }

        let bucket = TokenBucket(bytesPerSecond: limit)
        tokenBuckets[deviceID] = bucket
        return bucket
    }

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: configKey)
        }
    }

    private static func loadConfig() -> BandwidthLimit? {
        guard let data = UserDefaults.standard.data(forKey: "com.skybridge.bandwidth.config"),
              let config = try? JSONDecoder().decode(BandwidthLimit.self, from: data) else {
            return nil
        }
        return config
    }
}

/// 令牌桶限速器
actor TokenBucket {
    private var tokens: Double
    private var lastRefill: Date
    private var bytesPerSecond: Int64

    init(bytesPerSecond: Int64) {
        self.bytesPerSecond = bytesPerSecond
        self.tokens = Double(bytesPerSecond)
        self.lastRefill = Date()
    }

    func updateLimit(_ newLimit: Int64) {
        bytesPerSecond = newLimit
    }

    func consume(_ requested: Int64) -> Int64 {
        refill()

        let available = min(Double(requested), tokens)
        tokens -= available
        return Int64(available)
    }

    private func refill() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        let newTokens = elapsed * Double(bytesPerSecond)

        tokens = min(tokens + newTokens, Double(bytesPerSecond))
        lastRefill = now
    }
}
```

### SwiftUI 界面

```swift
// Sources/SkyBridgeUI/Settings/BandwidthSettingsView.swift

import SwiftUI

struct BandwidthSettingsView: View {
    @ObservedObject var engine: BandwidthThrottleEngine
    @State private var showScheduleEditor = false

    var body: some View {
        Form {
            Section("全局限速") {
                BandwidthSlider(
                    value: Binding(
                        get: { engine.config.globalLimit },
                        set: { engine.config.globalLimit = $0 }
                    ),
                    range: 0...1_000_000_000
                )
            }

            Section("设备限速") {
                ForEach(Array(engine.config.perDeviceLimits.keys), id: \.self) { deviceID in
                    DeviceBandwidthRow(
                        deviceID: deviceID,
                        limit: Binding(
                            get: { engine.config.perDeviceLimits[deviceID] },
                            set: { engine.config.perDeviceLimits[deviceID] = $0 }
                        )
                    )
                }
            }

            Section("时段限速") {
                ForEach(engine.config.schedules) { schedule in
                    ScheduleRow(schedule: schedule)
                }

                Button("添加时段") {
                    showScheduleEditor = true
                }
            }

            Section("当前使用") {
                ForEach(Array(engine.currentUsage.keys), id: \.self) { deviceID in
                    HStack {
                        Text(deviceID)
                        Spacer()
                        Text(formatBytes(engine.currentUsage[deviceID] ?? 0))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .sheet(isPresented: $showScheduleEditor) {
            ScheduleEditorView(engine: engine)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary) + "/s"
    }
}

struct BandwidthSlider: View {
    @Binding var value: Int64?
    let range: ClosedRange<Int64>

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("限制:")
                Spacer()
                Text(value.map { formatBandwidth($0) } ?? "无限制")
                    .foregroundColor(.secondary)
            }

            Slider(
                value: Binding(
                    get: { Double(value ?? 0) },
                    set: { value = $0 > 0 ? Int64($0) : nil }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
        }
    }

    private func formatBandwidth(_ bps: Int64) -> String {
        let mbps = Double(bps) / 1_000_000
        return String(format: "%.1f Mbps", mbps)
    }
}
```

---

## 功能 3: 离线消息队列

### 技术架构

```
┌─────────────────────────────────────────────────────┐
│                OfflineMessageQueue                  │
│  ┌───────────────────────────────────────────────┐  │
│  │ SQLite 持久化存储                             │  │
│  │  ┌─────────┬─────────┬─────────┬───────────┐  │  │
│  │  │ msg_id  │device_id│ payload │  status   │  │  │
│  │  ├─────────┼─────────┼─────────┼───────────┤  │  │
│  │  │ uuid1   │ dev_a   │ {...}   │ pending   │  │  │
│  │  │ uuid2   │ dev_a   │ {...}   │ sent      │  │  │
│  │  │ uuid3   │ dev_b   │ {...}   │ pending   │  │  │
│  │  └─────────┴─────────┴─────────┴───────────┘  │  │
│  └───────────────────────────────────────────────┘  │
│                        │                            │
│  ┌─────────────────────▼─────────────────────────┐  │
│  │            ConnectionWatcher                  │  │
│  │  监听设备上线 → 触发队列投递                  │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

### 核心实现

```swift
// Sources/SkyBridgeCore/Messaging/OfflineMessageQueue.swift

import Foundation
import SQLite3

/// 离线消息状态
public enum MessageStatus: String, Codable, Sendable {
    case pending    // 等待发送
    case sending    // 发送中
    case sent       // 已发送
    case delivered  // 已送达
    case failed     // 发送失败
    case expired    // 已过期
}

/// 离线消息
public struct OfflineMessage: Identifiable, Codable, Sendable {
    public let id: UUID
    public let targetDeviceID: String
    public let messageType: String
    public let payload: Data
    public let createdAt: Date
    public var status: MessageStatus
    public var retryCount: Int
    public var lastAttempt: Date?
    public var expiresAt: Date?

    public init(
        targetDeviceID: String,
        messageType: String,
        payload: Data,
        ttl: TimeInterval = 86400 * 7 // 7天过期
    ) {
        self.id = UUID()
        self.targetDeviceID = targetDeviceID
        self.messageType = messageType
        self.payload = payload
        self.createdAt = Date()
        self.status = .pending
        self.retryCount = 0
        self.expiresAt = Date().addingTimeInterval(ttl)
    }
}

/// 离线消息队列管理器
@MainActor
public final class OfflineMessageQueueManager: ObservableObject {

    // MARK: - Published State
    @Published public private(set) var pendingCount: Int = 0
    @Published public private(set) var isProcessing: Bool = false

    // MARK: - Private Properties
    private let storage: MessageStorage
    private let connectionMonitor: ConnectionMonitor
    private let p2pChannel: P2PSecureChannel
    private let logger = SkyBridgeLogger(category: "OfflineQueue")

    private let maxRetries = 5
    private let retryDelays: [Duration] = [.seconds(5), .seconds(30), .minutes(2), .minutes(10), .hours(1)]

    // MARK: - Initialization

    public init(
        connectionMonitor: ConnectionMonitor,
        p2pChannel: P2PSecureChannel
    ) throws(MessageQueueError) {
        self.storage = try MessageStorage()
        self.connectionMonitor = connectionMonitor
        self.p2pChannel = p2pChannel

        Task { await startConnectionWatcher() }
    }

    // MARK: - Public Methods

    /// 将消息加入离线队列
    public func enqueue(_ message: OfflineMessage) throws(MessageQueueError) {
        try storage.save(message)
        pendingCount = try storage.pendingCount()

        logger.info("消息已加入队列: \(message.id) → \(message.targetDeviceID)")

        // 如果目标设备在线，立即尝试发送
        if connectionMonitor.isDeviceOnline(message.targetDeviceID) {
            Task { await deliverPendingMessages(to: message.targetDeviceID) }
        }
    }

    /// 获取设备的待发送消息
    public func pendingMessages(for deviceID: String) throws(MessageQueueError) -> [OfflineMessage] {
        try storage.fetchPending(for: deviceID)
    }

    /// 清理过期消息
    public func cleanupExpired() throws(MessageQueueError) {
        let removed = try storage.removeExpired()
        pendingCount = try storage.pendingCount()

        if removed > 0 {
            logger.info("已清理 \(removed) 条过期消息")
        }
    }

    // MARK: - Private Methods

    /// 监听设备连接状态变化
    private func startConnectionWatcher() async {
        // 使用 Swift 6.2 Observations 监听连接状态变化
        for await event in connectionMonitor.connectionEvents {
            switch event {
            case .deviceConnected(let deviceID):
                logger.info("设备上线: \(deviceID), 开始投递离线消息")
                await deliverPendingMessages(to: deviceID)

            case .deviceDisconnected:
                break
            }
        }
    }

    /// 投递待发送消息到指定设备
    private func deliverPendingMessages(to deviceID: String) async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        do {
            let messages = try storage.fetchPending(for: deviceID)

            for var message in messages {
                // 检查是否过期
                if let expiresAt = message.expiresAt, Date() > expiresAt {
                    message.status = .expired
                    try? storage.update(message)
                    continue
                }

                // 检查重试次数
                if message.retryCount >= maxRetries {
                    message.status = .failed
                    try? storage.update(message)
                    continue
                }

                // 尝试发送
                message.status = .sending
                message.lastAttempt = Date()
                try? storage.update(message)

                do {
                    try await p2pChannel.send(
                        data: message.payload,
                        to: deviceID,
                        type: P2PMessageType(rawValue: message.messageType) ?? .command
                    )

                    message.status = .sent
                    logger.info("消息投递成功: \(message.id)")

                } catch {
                    message.status = .pending
                    message.retryCount += 1
                    logger.warning("消息投递失败: \(message.id), 重试 \(message.retryCount)/\(maxRetries)")

                    // 安排重试
                    if message.retryCount < maxRetries {
                        let delay = retryDelays[min(message.retryCount, retryDelays.count - 1)]
                        Task {
                            try? await Task.sleep(for: delay)
                            await deliverPendingMessages(to: deviceID)
                        }
                    }
                }

                try? storage.update(message)
            }

            pendingCount = try storage.pendingCount()

        } catch {
            logger.error("投递消息失败: \(error)")
        }
    }
}

/// 消息持久化存储
private final class MessageStorage: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.skybridge.messageStorage", qos: .utility)

    init() throws(MessageQueueError) {
        let dbPath = Self.databasePath()

        guard sqlite3_open(dbPath.path, &db) == SQLITE_OK else {
            throw .databaseError("无法打开数据库")
        }

        try createTable()
    }

    deinit {
        sqlite3_close(db)
    }

    func save(_ message: OfflineMessage) throws(MessageQueueError) {
        let sql = """
            INSERT INTO offline_messages
            (id, target_device_id, message_type, payload, created_at, status, retry_count, expires_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw .databaseError("SQL 准备失败")
        }

        sqlite3_bind_text(stmt, 1, message.id.uuidString, -1, nil)
        sqlite3_bind_text(stmt, 2, message.targetDeviceID, -1, nil)
        sqlite3_bind_text(stmt, 3, message.messageType, -1, nil)
        sqlite3_bind_blob(stmt, 4, [UInt8](message.payload), Int32(message.payload.count), nil)
        sqlite3_bind_double(stmt, 5, message.createdAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 6, message.status.rawValue, -1, nil)
        sqlite3_bind_int(stmt, 7, Int32(message.retryCount))
        sqlite3_bind_double(stmt, 8, message.expiresAt?.timeIntervalSince1970 ?? 0)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw .databaseError("插入失败")
        }
    }

    func fetchPending(for deviceID: String) throws(MessageQueueError) -> [OfflineMessage] {
        // 实现省略...
        []
    }

    func update(_ message: OfflineMessage) throws(MessageQueueError) {
        // 实现省略...
    }

    func pendingCount() throws(MessageQueueError) -> Int {
        // 实现省略...
        0
    }

    func removeExpired() throws(MessageQueueError) -> Int {
        // 实现省略...
        0
    }

    private func createTable() throws(MessageQueueError) {
        let sql = """
            CREATE TABLE IF NOT EXISTS offline_messages (
                id TEXT PRIMARY KEY,
                target_device_id TEXT NOT NULL,
                message_type TEXT NOT NULL,
                payload BLOB NOT NULL,
                created_at REAL NOT NULL,
                status TEXT NOT NULL,
                retry_count INTEGER DEFAULT 0,
                last_attempt REAL,
                expires_at REAL,
                CONSTRAINT idx_device_status UNIQUE (target_device_id, status)
            )
            """

        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw .databaseError("创建表失败")
        }
    }

    private static func databasePath() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SkyBridge")
            .appendingPathComponent("offline_messages.db")
    }
}

public enum MessageQueueError: Error, Sendable {
    case databaseError(String)
    case encodingError
    case decodingError
}
```

---

## 功能 4: 硬件性能仪表盘

### 技术架构 (Metal 4)

```
┌─────────────────────────────────────────────────────────┐
│              HardwarePerformanceDashboard               │
│  ┌───────────────────────────────────────────────────┐  │
│  │  CPU: ████████░░ 78%    GPU: ██████░░░░ 56%      │  │
│  │  MEM: ██████████ 95%    Neural: ████░░░░░░ 40%   │  │
│  └───────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────┐  │
│  │          实时图表 (60fps Metal 渲染)             │  │
│  │  ╭──────────────────────────────────────────╮    │  │
│  │  │    ╱╲    ╱╲                              │    │  │
│  │  │   ╱  ╲  ╱  ╲   ╱╲                       │    │  │
│  │  │  ╱    ╲╱    ╲ ╱  ╲                      │    │  │
│  │  │ ╱           ╲╱    ╲─────────────────    │    │  │
│  │  ╰──────────────────────────────────────────╯    │  │
│  └───────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────┐  │
│  │  编码效率: 45.2 fps   GPU内存: 2.1/8.0 GB        │  │
│  │  热节流: 无           功耗: 12.3W                │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

### 核心实现

```swift
// Sources/SkyBridgeCore/Performance/HardwarePerformanceMonitor.swift

import Foundation
import Metal
import MetalPerformanceShaders
import IOKit

/// 硬件性能指标
@Observable
public final class HardwareMetrics: Sendable {
    // CPU
    public var cpuUsage: Double = 0
    public var cpuTemperature: Double?
    public var cpuFrequency: Double?

    // GPU (Metal 4)
    public var gpuUsage: Double = 0
    public var gpuMemoryUsed: UInt64 = 0
    public var gpuMemoryTotal: UInt64 = 0
    public var gpuTemperature: Double?

    // Neural Engine
    public var neuralEngineUsage: Double?

    // 内存
    public var memoryUsed: UInt64 = 0
    public var memoryTotal: UInt64 = 0
    public var memoryPressure: MemoryPressureLevel = .nominal

    // 编码性能
    public var encodingFPS: Double = 0
    public var encodingLatency: TimeInterval = 0

    // 功耗
    public var powerConsumption: Double?
    public var thermalState: ProcessInfo.ThermalState = .nominal

    public enum MemoryPressureLevel: String, Sendable {
        case nominal, warning, critical
    }
}

/// 硬件性能监控器 - 使用 Metal 4 API
@MainActor
public final class HardwarePerformanceMonitor: ObservableObject {

    // MARK: - Published State
    @Published public private(set) var metrics = HardwareMetrics()
    @Published public private(set) var history: [HardwareMetrics] = []

    // MARK: - Private Properties
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var monitorTask: Task<Void, Never>?
    private let logger = SkyBridgeLogger(category: "HardwareMonitor")

    private let historyMaxSize = 300 // 5分钟 @ 1Hz
    private let sampleInterval: Duration = .seconds(1)

    // MARK: - Initialization

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return nil
        }

        self.device = device
        self.commandQueue = queue
    }

    // MARK: - Public Methods

    public func startMonitoring() {
        monitorTask?.cancel()

        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleMetrics()
                try? await Task.sleep(for: self?.sampleInterval ?? .seconds(1))
            }
        }

        logger.info("硬件性能监控已启动")
    }

    public func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil

        logger.info("硬件性能监控已停止")
    }

    // MARK: - Private Methods

    @concurrent
    private func sampleMetrics() async {
        let newMetrics = HardwareMetrics()

        // CPU 使用率
        newMetrics.cpuUsage = await sampleCPUUsage()

        // GPU 使用率 (Metal 4)
        await sampleGPUMetrics(into: newMetrics)

        // 内存
        await sampleMemoryMetrics(into: newMetrics)

        // 热状态
        newMetrics.thermalState = ProcessInfo.processInfo.thermalState

        // 功耗 (Apple Silicon)
        newMetrics.powerConsumption = await samplePowerConsumption()

        // 更新到主线程
        await MainActor.run {
            self.metrics = newMetrics
            self.history.append(newMetrics)

            // 限制历史记录大小
            if self.history.count > historyMaxSize {
                self.history.removeFirst(self.history.count - historyMaxSize)
            }
        }
    }

    private func sampleCPUUsage() async -> Double {
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        var numCpus: natural_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCpus,
            &cpuInfo,
            &numCpuInfo
        )

        guard result == KERN_SUCCESS, let cpuInfo else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(numCpuInfo))
        }

        var totalUsage: Double = 0

        for i in 0..<Int32(numCpus) {
            let offset = Int(i) * Int(CPU_STATE_MAX)
            let user = Double(cpuInfo[offset + Int(CPU_STATE_USER)])
            let system = Double(cpuInfo[offset + Int(CPU_STATE_SYSTEM)])
            let idle = Double(cpuInfo[offset + Int(CPU_STATE_IDLE)])
            let nice = Double(cpuInfo[offset + Int(CPU_STATE_NICE)])

            let total = user + system + idle + nice
            let usage = (user + system + nice) / total
            totalUsage += usage
        }

        return (totalUsage / Double(numCpus)) * 100
    }

    private func sampleGPUMetrics(into metrics: HardwareMetrics) async {
        // Metal 4 GPU 内存查询
        metrics.gpuMemoryUsed = UInt64(device.currentAllocatedSize)

        // 获取推荐的最大工作集大小
        if #available(macOS 26, *) {
            metrics.gpuMemoryTotal = UInt64(device.recommendedMaxWorkingSetSize)
        }

        // GPU 使用率需要通过 IOKit 或 powermetrics 获取
        // 这里使用简化的估算
        let usageRatio = Double(metrics.gpuMemoryUsed) / Double(max(metrics.gpuMemoryTotal, 1))
        metrics.gpuUsage = min(usageRatio * 100, 100)
    }

    private func sampleMemoryMetrics(into metrics: HardwareMetrics) async {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return }

        let pageSize = UInt64(vm_page_size)

        metrics.memoryUsed = (UInt64(stats.active_count) + UInt64(stats.wire_count)) * pageSize
        metrics.memoryTotal = ProcessInfo.processInfo.physicalMemory

        // 内存压力
        let usageRatio = Double(metrics.memoryUsed) / Double(metrics.memoryTotal)
        if usageRatio > 0.9 {
            metrics.memoryPressure = .critical
        } else if usageRatio > 0.75 {
            metrics.memoryPressure = .warning
        } else {
            metrics.memoryPressure = .nominal
        }
    }

    private func samplePowerConsumption() async -> Double? {
        // 通过 powermetrics 或 IOKit 获取功耗
        // 简化实现
        nil
    }
}
```

---

## 功能 5: 加密云端备份

### 技术架构 (CKSyncEngine)

```
┌─────────────────────────────────────────────────────────┐
│                   CloudBackupManager                    │
│  ┌───────────────────────────────────────────────────┐  │
│  │              本地加密层                           │  │
│  │  ┌─────────────┐    ┌─────────────────────────┐   │  │
│  │  │ Trust Store │───►│ AES-256-GCM 加密        │   │  │
│  │  │ Device Keys │    │ + HKDF 密钥派生         │   │  │
│  │  │ Settings    │    └───────────┬─────────────┘   │  │
│  │  └─────────────┘                │                 │  │
│  └─────────────────────────────────┼─────────────────┘  │
│                                    │                    │
│  ┌─────────────────────────────────▼─────────────────┐  │
│  │            CKSyncEngine                           │  │
│  │  ┌─────────────────────────────────────────────┐  │  │
│  │  │ 自动同步 + 冲突解决 + 离线支持              │  │  │
│  │  └─────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────┘  │
│                          │                              │
│                          ▼                              │
│  ┌───────────────────────────────────────────────────┐  │
│  │                   iCloud                          │  │
│  │  Private Database (端到端加密)                    │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

### 核心实现

```swift
// Sources/SkyBridgeCore/Backup/CloudBackupManager.swift

import Foundation
import CloudKit
import CryptoKit

/// 云端备份错误 - Swift 6.2 Typed Throws
public enum CloudBackupError: Error, Sendable {
    case notSignedIn
    case encryptionFailed
    case decryptionFailed
    case syncFailed(underlying: Error)
    case dataCorrupted
    case quotaExceeded
}

/// 备份数据类型
public enum BackupDataType: String, CaseIterable, Sendable {
    case trustedDevices = "TrustedDevices"
    case connectionHistory = "ConnectionHistory"
    case userPreferences = "UserPreferences"
    case clipboardHistory = "ClipboardHistory"
}

/// 云端备份管理器
@MainActor
public final class CloudBackupManager: ObservableObject {

    // MARK: - Published State
    @Published public private(set) var isBackupEnabled: Bool = false
    @Published public private(set) var lastBackupDate: Date?
    @Published public private(set) var syncStatus: SyncStatus = .idle

    public enum SyncStatus: Sendable {
        case idle
        case syncing
        case error(String)
    }

    // MARK: - Private Properties
    private let container: CKContainer
    private let database: CKDatabase
    private var syncEngine: CKSyncEngine?
    private let encryptor: BackupEncryptor
    private let logger = SkyBridgeLogger(category: "CloudBackup")

    private let recordZone = CKRecordZone(zoneName: "SkyBridgeBackup")

    // MARK: - Initialization

    public init() {
        self.container = CKContainer(identifier: "iCloud.com.skybridge.compass")
        self.database = container.privateCloudDatabase
        self.encryptor = BackupEncryptor()
    }

    // MARK: - Public Methods

    /// 启用云端备份
    public func enableBackup() async throws(CloudBackupError) {
        // 检查 iCloud 登录状态
        let status = try await container.accountStatus()
        guard status == .available else {
            throw .notSignedIn
        }

        // 创建记录区域
        try await createRecordZoneIfNeeded()

        // 初始化 CKSyncEngine
        try await setupSyncEngine()

        isBackupEnabled = true
        logger.info("云端备份已启用")
    }

    /// 禁用云端备份
    public func disableBackup() {
        syncEngine = nil
        isBackupEnabled = false
        logger.info("云端备份已禁用")
    }

    /// 立即备份
    public func backupNow() async throws(CloudBackupError) {
        guard isBackupEnabled else { return }

        syncStatus = .syncing

        do {
            // 备份所有数据类型
            for dataType in BackupDataType.allCases {
                try await backupData(type: dataType)
            }

            lastBackupDate = Date()
            syncStatus = .idle
            logger.info("备份完成")

        } catch {
            syncStatus = .error(error.localizedDescription)
            throw .syncFailed(underlying: error)
        }
    }

    /// 恢复备份
    public func restore(types: Set<BackupDataType> = Set(BackupDataType.allCases)) async throws(CloudBackupError) {
        guard isBackupEnabled else { throw .notSignedIn }

        syncStatus = .syncing

        for dataType in types {
            try await restoreData(type: dataType)
        }

        syncStatus = .idle
        logger.info("恢复完成")
    }

    // MARK: - Private Methods

    private func createRecordZoneIfNeeded() async throws {
        do {
            _ = try await database.save(recordZone)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // 区域已存在，忽略
        }
    }

    private func setupSyncEngine() async throws {
        let configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: loadSyncState(),
            delegate: self
        )

        syncEngine = CKSyncEngine(configuration)
    }

    private func backupData(type: BackupDataType) async throws(CloudBackupError) {
        // 读取本地数据
        let localData = try readLocalData(type: type)

        // 加密数据
        let encryptedData = try encryptor.encrypt(localData)

        // 创建 CloudKit 记录
        let recordID = CKRecord.ID(recordName: type.rawValue, zoneID: recordZone.zoneID)
        let record = CKRecord(recordType: "BackupData", recordID: recordID)
        record["data"] = encryptedData as CKRecordValue
        record["timestamp"] = Date() as CKRecordValue
        record["version"] = 1 as CKRecordValue

        // 保存到 CloudKit
        do {
            _ = try await database.save(record)
        } catch {
            throw .syncFailed(underlying: error)
        }
    }

    private func restoreData(type: BackupDataType) async throws(CloudBackupError) {
        let recordID = CKRecord.ID(recordName: type.rawValue, zoneID: recordZone.zoneID)

        do {
            let record = try await database.record(for: recordID)

            guard let encryptedData = record["data"] as? Data else {
                throw CloudBackupError.dataCorrupted
            }

            // 解密数据
            let decryptedData = try encryptor.decrypt(encryptedData)

            // 写入本地
            try writeLocalData(decryptedData, type: type)

        } catch let error as CKError where error.code == .unknownItem {
            // 没有备份数据，忽略
            logger.info("无 \(type.rawValue) 备份数据")
        } catch {
            throw .syncFailed(underlying: error)
        }
    }

    private func readLocalData(type: BackupDataType) throws(CloudBackupError) -> Data {
        // 根据类型读取不同的本地数据
        // 实现省略...
        Data()
    }

    private func writeLocalData(_ data: Data, type: BackupDataType) throws(CloudBackupError) {
        // 根据类型写入不同的本地数据
        // 实现省略...
    }

    private func loadSyncState() -> CKSyncEngine.State.Serialization? {
        guard let data = UserDefaults.standard.data(forKey: "com.skybridge.backup.syncState") else {
            return nil
        }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudBackupManager: CKSyncEngineDelegate {
    nonisolated public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let stateUpdate):
            // 保存同步状态
            if let data = try? JSONEncoder().encode(stateUpdate.stateSerialization) {
                UserDefaults.standard.set(data, forKey: "com.skybridge.backup.syncState")
            }

        case .accountChange(let accountChange):
            await MainActor.run {
                if accountChange.changeType == .signedOut {
                    self.disableBackup()
                }
            }

        case .fetchedDatabaseChanges(let changes):
            // 处理远程变更
            for modification in changes.modifications {
                // 处理记录更新
            }

        case .sentDatabaseChanges(let changes):
            await MainActor.run {
                self.lastBackupDate = Date()
            }

        default:
            break
        }
    }

    nonisolated public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        nil
    }
}

/// 备份数据加密器
private final class BackupEncryptor: Sendable {

    private let masterKey: SymmetricKey

    init() {
        // 从 Keychain 获取或生成主密钥
        self.masterKey = KeychainManager.shared.getOrCreateBackupKey()
    }

    func encrypt(_ data: Data) throws(CloudBackupError) -> Data {
        do {
            // 生成随机 nonce
            let nonce = AES.GCM.Nonce()

            // 使用 HKDF 派生加密密钥
            let encryptionKey = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: masterKey,
                salt: Data(nonce),
                info: "SkyBridge.Backup.Encryption".data(using: .utf8)!,
                outputByteCount: 32
            )

            // AES-256-GCM 加密
            let sealedBox = try AES.GCM.seal(data, using: encryptionKey, nonce: nonce)

            // 组合 nonce + ciphertext + tag
            return sealedBox.combined ?? Data()

        } catch {
            throw .encryptionFailed
        }
    }

    func decrypt(_ data: Data) throws(CloudBackupError) -> Data {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)

            // 使用 HKDF 派生解密密钥
            let decryptionKey = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: masterKey,
                salt: Data(sealedBox.nonce),
                info: "SkyBridge.Backup.Encryption".data(using: .utf8)!,
                outputByteCount: 32
            )

            return try AES.GCM.open(sealedBox, using: decryptionKey)

        } catch {
            throw .decryptionFailed
        }
    }
}
```

---

## 功能 6-8: 简要设计

### 功能 6: 多因素连接审批

```swift
// 核心思路
// 1. 连接请求时生成 TOTP 或推送通知到第二设备
// 2. 使用现有 PAKE 基础设施扩展
// 3. 支持 App Intents 快捷指令审批

public struct ConnectionApprovalRequest: Sendable {
    let requestID: UUID
    let sourceDevice: DeviceIdentity
    let targetDevice: DeviceIdentity
    let timestamp: Date
    let expiresAt: Date
    let approvalCode: String  // 6位数字
}

@MainActor
public final class MultiFactorApprovalManager {
    // 生成审批请求
    func requestApproval(for connection: PendingConnection) async throws(ApprovalError)

    // 验证审批码
    func verify(code: String, requestID: UUID) async throws(ApprovalError) -> Bool

    // 推送通知到审批设备
    private func sendApprovalNotification(_ request: ConnectionApprovalRequest) async
}
```

### 功能 7: 网络感知传输调度

```swift
// 核心思路
// 1. 使用 NWPathMonitor 监听网络状态
// 2. 根据信号质量动态调整传输策略
// 3. 与带宽限速引擎集成

public struct NetworkQuality: Sendable {
    let signalStrength: Double     // 0-1
    let latency: TimeInterval      // ms
    let bandwidth: Int64           // bytes/sec
    let isExpensive: Bool          // 蜂窝网络
    let isConstrained: Bool        // 低数据模式
}

@MainActor
public final class NetworkAwareScheduler {
    @Published var currentQuality: NetworkQuality

    // 根据网络质量决定是否传输
    func shouldTransfer(size: Int64) -> TransferDecision

    // 调整传输参数
    func optimizedParameters(for quality: NetworkQuality) -> TransferParameters
}
```

### 功能 8: ML 异常检测 (Foundation Models)

```swift
// 核心思路
// 1. 使用 macOS 26 Foundation Models 框架
// 2. 本地推理，保护隐私
// 3. 检测异常连接模式

import FoundationModels

@Generable
public struct ConnectionPattern: Sendable {
    let deviceID: String
    let connectionFrequency: Int
    let dataTransferVolume: Int64
    let timeOfDay: Int
    let connectionDuration: TimeInterval
}

@MainActor
public final class AnomalyDetector {
    private let model: LanguageModel

    func analyze(patterns: [ConnectionPattern]) async -> AnomalyReport {
        let session = model.makeSession()

        let prompt = """
            分析以下设备连接模式，识别异常行为：
            \(patterns.map { $0.description }.joined(separator: "\n"))
            """

        let response = try await session.respond(to: prompt)
        return parseAnomalyReport(from: response)
    }
}
```

---

## 开发优先级

| 优先级 | 功能 | 预计工作量 | 依赖 |
|-------|------|----------|-----|
| P0 | 跨设备剪贴板同步 | 3天 | P2P Channel |
| P0 | 硬件性能仪表盘 | 2天 | Metal 4 |
| P1 | 带宽限速 UI | 2天 | 无 |
| P1 | 离线消息队列 | 3天 | SQLite |
| P2 | 加密云端备份 | 4天 | CKSyncEngine |
| P2 | 网络感知传输调度 | 2天 | NWPathMonitor |
| P3 | 多因素连接审批 | 3天 | PAKE |
| P3 | ML 异常检测 | 4天 | Foundation Models |

---

## 技术规范清单

- [ ] Swift 6.2 Strict Concurrency
- [ ] Typed Throws 所有错误类型
- [ ] @MainActor 默认隔离
- [ ] @concurrent 并发函数标记
- [ ] Observations AsyncSequence
- [ ] Metal 4 GPU 监控
- [ ] CKSyncEngine 云端同步
- [ ] Foundation Models 本地推理
- [ ] App Intents 快捷指令集成
