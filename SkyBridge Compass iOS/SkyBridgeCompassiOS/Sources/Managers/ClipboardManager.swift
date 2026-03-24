//
// ClipboardManager.swift
// SkyBridgeCompassiOS
//
// 剪贴板同步管理器 - 支持 iOS 与远程设备的剪贴板同步
//

import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Clipboard Manager

/// 剪贴板同步管理器
/// 支持双向同步：本地剪贴板 <-> 远程剪贴板
@available(iOS 17.0, *)
@MainActor
public final class ClipboardManager: ObservableObject {
    private enum ActivationSource: Hashable {
        case global
        case session(UUID)
    }
    
    public static let shared = ClipboardManager()
    
    // MARK: - Published Properties
    
    /// 是否启用剪贴板同步
    @Published public var isEnabled: Bool = false
    
    /// 最后同步时间
    @Published public private(set) var lastSyncTime: Date?
    
    /// 同步状态
    @Published public private(set) var syncStatus: SyncStatus = .idle
    
    // MARK: - Configuration (align with macOS)

    /// 是否同步图片
    @Published public var syncImages: Bool = false {
        didSet {
            // 当配置变更时，尽量不中断用户：仅在轮询间隔变化时重启监控
        }
    }

    /// 是否同步文件 URL（iOS 通常表现为 url）
    @Published public var syncFileURLs: Bool = true

    /// 最大内容大小（字节）
    @Published public var maxContentSizeBytes: Int = 1 * 1024 * 1024

    /// 历史记录保留条数
    @Published public var historyLimit: Int = 25 {
        didSet { trimHistoryIfNeeded() }
    }

    /// 剪贴板轮询间隔（秒）
    @Published public var pollIntervalSeconds: Double = 1.0 {
        didSet {
            guard isEnabled else { return }
            // 轮询间隔变化需要重启 timer 才能生效
            startMonitoringLocalClipboard()
        }
    }

    /// 最小发送间隔（秒），用于“限速/降噪”
    @Published public var minSendIntervalSeconds: Double = 0.8

    /// 历史记录（持久化到受保护的本地状态文件）
    @Published public private(set) var history: [ClipboardHistoryEntry] = []

    /// 按设备的最近同步信息（用于“按设备状态面板”）
    @Published public private(set) var deviceLastSync: [String: Date] = [:]
    @Published public private(set) var deviceLastMimeType: [String: String] = [:]
    @Published public private(set) var deviceLastBytes: [String: Int] = [:]
    
    // MARK: - Private Properties
    
    /// 当前会话 ID
    private var activeSessionId: UUID?
    private var activeSources: Set<ActivationSource> = []
    
    /// 剪贴板变化观察者
    private var clipboardMonitorTimer: Timer?
    
    /// 上次剪贴板变化计数
    #if canImport(UIKit)
    private var lastChangeCount: Int = UIPasteboard.general.changeCount
    #endif
    
    /// 远程剪贴板数据缓存（避免循环同步）
    private var lastRemoteClipboardHash: String?
    
    /// 本地剪贴板数据缓存
    private var lastLocalClipboardHash: String?

    private var lastSendAt: Date?

    private static let historyStore = CodablePersistenceStore<[ClipboardHistoryEntry]>(
        location: .protectedApplicationSupport(
            path: "Clipboard/history.json",
            legacyUserDefaultsKey: "clipboard.history.v1"
        )
    )
    
    // MARK: - Callbacks
    
    /// 剪贴板数据回调（发送到远程）
    public var onLocalClipboardChanged: ((Data, String) -> Void)?
    private var localClipboardListeners: [UUID: @Sendable (Data, String) -> Void] = [:]
    
    /// 远程剪贴板数据接收回调
    public var onRemoteClipboardReceived: ((Data, String) -> Void)?
    
    // MARK: - Initialization
    
    private init() {}

    public func loadHistory() {
        history = Self.historyStore.load() ?? []
        trimHistoryIfNeeded()
    }

    public func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    public func recordDeviceSync(deviceId: String, mimeType: String, bytes: Int, at: Date = Date()) {
        deviceLastSync[deviceId] = at
        deviceLastMimeType[deviceId] = mimeType
        deviceLastBytes[deviceId] = bytes
    }

    private func saveHistory() {
        try? Self.historyStore.save(history)
    }

    /// 便捷启用（不关心 sessionId 的场景，例如 Settings 中的全局启用）
    public func enable() {
        activate(source: .global, sessionId: nil)
    }
    
    // MARK: - Public Methods
    
    /// 启用剪贴板重定向
    /// - Parameter sessionId: 会话 ID
    public func enable(for sessionId: UUID) {
        activate(source: .session(sessionId), sessionId: sessionId)
    }
    
    /// 禁用剪贴板重定向
    public func disable() {
        deactivate(source: .global, sessionId: nil)
    }

    public func disable(for sessionId: UUID) {
        deactivate(source: .session(sessionId), sessionId: sessionId)
    }

    public func addLocalClipboardListener(
        _ listener: @escaping @Sendable (Data, String) -> Void
    ) -> UUID {
        let token = UUID()
        localClipboardListeners[token] = listener
        return token
    }

    public func removeLocalClipboardListener(_ token: UUID) {
        localClipboardListeners.removeValue(forKey: token)
    }
    
    /// 设置远程剪贴板内容
    /// - Parameters:
    ///   - data: 剪贴板数据
    ///   - mimeType: MIME 类型
    public func setRemoteClipboard(data: Data, mimeType: String) {
        setRemoteClipboard(data: data, mimeType: mimeType, fromDeviceId: nil)
    }

    public func setRemoteClipboard(data: Data, mimeType: String, fromDeviceId: String?) {
        guard isEnabled else { return }
        guard isAllowed(mimeType: mimeType) else { return }
        guard data.count <= maxContentSizeBytes else {
            SkyBridgeLogger.shared.warning("⚠️ 远程剪贴板内容过大，已忽略：\(data.count) bytes")
            return
        }
        
        let hash = hashData(data)
        guard hash != lastRemoteClipboardHash else { return }
        lastRemoteClipboardHash = hash
        lastLocalClipboardHash = hash // 避免回环
        
        #if canImport(UIKit)
        let pasteboard = UIPasteboard.general
        
        switch mimeType {
        case "text/plain", "text/plain;charset=utf-8":
            if let text = String(data: data, encoding: .utf8) {
                pasteboard.string = text
                SkyBridgeLogger.shared.debug("📋 远程剪贴板文本已设置: \(text.prefix(50))")
            }
            
        case "image/png":
            if let image = UIImage(data: data) {
                pasteboard.image = image
                SkyBridgeLogger.shared.debug("📋 远程剪贴板图片已设置 (PNG)")
            }
            
        case "image/jpeg":
            if let image = UIImage(data: data) {
                pasteboard.image = image
                SkyBridgeLogger.shared.debug("📋 远程剪贴板图片已设置 (JPEG)")
            }
            
        case "text/uri-list":
            if let urlString = String(data: data, encoding: .utf8),
               let url = URL(string: urlString) {
                pasteboard.url = url
                SkyBridgeLogger.shared.debug("📋 远程剪贴板 URL 已设置: \(urlString)")
            }
            
        default:
            SkyBridgeLogger.shared.warning("⚠️ 不支持的剪贴板 MIME 类型: \(mimeType)")
        }
        #endif
        
        lastSyncTime = Date()
        syncStatus = .synced

        recordHistory(direction: .incoming, deviceId: fromDeviceId, mimeType: mimeType, data: data)
    }
    
    /// 获取当前剪贴板内容
    /// - Returns: (data, mimeType)
    public func getCurrentClipboardContent() -> (Data, String)? {
        #if canImport(UIKit)
        let pasteboard = UIPasteboard.general
        
        // 优先获取文本
        if let text = pasteboard.string, !text.isEmpty {
            let data = text.data(using: .utf8) ?? Data()
            guard data.count <= maxContentSizeBytes else { return nil }
            return (data, "text/plain")
        }
        
        // 尝试获取图片
        if syncImages, let image = pasteboard.image,
           let pngData = image.pngData() {
            guard pngData.count <= maxContentSizeBytes else { return nil }
            return (pngData, "image/png")
        }
        
        // 尝试获取 URL
        if syncFileURLs, let url = pasteboard.url {
            let data = url.absoluteString.data(using: .utf8) ?? Data()
            guard data.count <= maxContentSizeBytes else { return nil }
            return (data, "text/uri-list")
        }
        #endif
        
        return nil
    }
    
    /// 强制同步到远程
    public func syncToRemote() {
        guard isEnabled else { return }
        
        if let (data, mimeType) = getCurrentClipboardContent() {
            let hash = hashData(data)
            guard hash != lastLocalClipboardHash else { return }
            lastLocalClipboardHash = hash

            guard shouldSendNow() else { return }
            
            notifyLocalClipboardChanged(data: data, mimeType: mimeType)
            lastSyncTime = Date()
            syncStatus = .syncing
            
            // 短暂延迟后标记为已同步
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.syncStatus = .synced
            }
        }
    }
    
    // MARK: - Private Methods
    
    /// 开始监听本地剪贴板变化
    private func startMonitoringLocalClipboard() {
        stopMonitoringLocalClipboard()
        
        #if canImport(UIKit)
        lastChangeCount = UIPasteboard.general.changeCount
        #endif
        
        // 使用定时器轮询（iOS 没有剪贴板变化通知）
        let interval = max(0.3, pollIntervalSeconds)
        clipboardMonitorTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkClipboardChange()
            }
        }
    }
    
    /// 停止监听本地剪贴板变化
    private func stopMonitoringLocalClipboard() {
        clipboardMonitorTimer?.invalidate()
        clipboardMonitorTimer = nil
    }
    
    /// 检查剪贴板变化
    private func checkClipboardChange() {
        guard isEnabled else { return }
        
        #if canImport(UIKit)
        let pasteboard = UIPasteboard.general
        let currentChangeCount = pasteboard.changeCount
        
        if currentChangeCount != lastChangeCount {
            lastChangeCount = currentChangeCount
            handleLocalClipboardChange()
        }
        #endif
    }
    
    /// 处理本地剪贴板变化
    private func handleLocalClipboardChange() {
        guard let (data, mimeType) = getCurrentClipboardContent() else { return }
        guard isAllowed(mimeType: mimeType) else { return }
        
        let hash = hashData(data)
        
        // 避免重复同步
        guard hash != lastRemoteClipboardHash && hash != lastLocalClipboardHash else { return }
        lastLocalClipboardHash = hash

        guard shouldSendNow() else { return }
        
        notifyLocalClipboardChanged(data: data, mimeType: mimeType)
        lastSyncTime = Date()
        syncStatus = .syncing

        recordHistory(direction: .outgoing, deviceId: nil, mimeType: mimeType, data: data)
        
        SkyBridgeLogger.shared.debug("📋 本地剪贴板变化已同步")
        
        // 短暂延迟后标记为已同步
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.syncStatus = .synced
        }
    }
    
    /// 计算数据哈希
    private func hashData(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func isAllowed(mimeType: String) -> Bool {
        if mimeType.hasPrefix("text/") { return true }
        if mimeType == "image/png" || mimeType == "image/jpeg" { return syncImages }
        if mimeType == "text/uri-list" { return syncFileURLs }
        return false
    }

    private func shouldSendNow() -> Bool {
        let minInterval = max(0, minSendIntervalSeconds)
        if minInterval == 0 { return true }
        let now = Date()
        if let lastSendAt, now.timeIntervalSince(lastSendAt) < minInterval {
            return false
        }
        self.lastSendAt = now
        return true
    }

    private func recordHistory(direction: ClipboardHistoryDirection, deviceId: String?, mimeType: String, data: Data) {
        let entry = ClipboardHistoryEntry(
            direction: direction,
            deviceId: deviceId,
            mimeType: mimeType,
            sizeBytes: data.count,
            textPreview: mimeType.hasPrefix("text/") ? String(data: data, encoding: .utf8)?.prefix(120).description : nil,
            createdAt: Date()
        )
        history.append(entry)
        trimHistoryIfNeeded()
        saveHistory()
    }

    private func trimHistoryIfNeeded() {
        let limit = max(0, historyLimit)
        guard limit > 0 else {
            history.removeAll()
            saveHistory()
            return
        }
        if history.count > limit {
            history.removeFirst(history.count - limit)
        }
    }

    private func activate(source: ActivationSource, sessionId: UUID?) {
        let wasEnabled = isEnabled
        let (inserted, _) = activeSources.insert(source)
        guard inserted else { return }

        isEnabled = true
        if let sessionId {
            activeSessionId = sessionId
        }
        syncStatus = .active

        if !wasEnabled {
            startMonitoringLocalClipboard()
            loadHistory()
        }

        let scope = sessionId?.uuidString ?? "global"
        SkyBridgeLogger.shared.info("✅ 剪贴板同步已启用: scope=\(scope)")
    }

    private func deactivate(source: ActivationSource, sessionId: UUID?) {
        guard activeSources.remove(source) != nil else { return }

        if case .session(let token) = source, activeSessionId == token {
            activeSessionId = nil
        }

        if activeSources.isEmpty {
            isEnabled = false
            stopMonitoringLocalClipboard()
            activeSessionId = nil
            lastRemoteClipboardHash = nil
            lastLocalClipboardHash = nil
            syncStatus = .idle
            saveHistory()
        } else {
            syncStatus = .active
        }

        let scope = sessionId?.uuidString ?? "global"
        SkyBridgeLogger.shared.info("🛑 剪贴板同步已禁用: scope=\(scope)")
    }

    private func notifyLocalClipboardChanged(data: Data, mimeType: String) {
        onLocalClipboardChanged?(data, mimeType)
        for listener in localClipboardListeners.values {
            listener(data, mimeType)
        }
    }
}

// MARK: - Clipboard History

public enum ClipboardHistoryDirection: String, Codable, Sendable, Equatable {
    case outgoing
    case incoming
}

public struct ClipboardHistoryEntry: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let direction: ClipboardHistoryDirection
    public let deviceId: String?
    public let mimeType: String
    public let sizeBytes: Int
    public let textPreview: String?
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        direction: ClipboardHistoryDirection,
        deviceId: String?,
        mimeType: String,
        sizeBytes: Int,
        textPreview: String?,
        createdAt: Date
    ) {
        self.id = id
        self.direction = direction
        self.deviceId = deviceId
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.textPreview = textPreview
        self.createdAt = createdAt
    }
}

// MARK: - Sync Status

/// 同步状态
public enum SyncStatus: String, Sendable {
    case idle = "idle"
    case active = "active"
    case syncing = "syncing"
    case synced = "synced"
    case error = "error"
    
    public var displayName: String {
        switch self {
        case .idle: return "未启用"
        case .active: return "已启用"
        case .syncing: return "同步中"
        case .synced: return "已同步"
        case .error: return "错误"
        }
    }
    
    public var iconName: String {
        switch self {
        case .idle: return "clipboard"
        case .active: return "clipboard.fill"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .synced: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}
