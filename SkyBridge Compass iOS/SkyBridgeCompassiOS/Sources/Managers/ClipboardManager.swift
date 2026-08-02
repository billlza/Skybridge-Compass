//
// ClipboardManager.swift
// SkyBridgeCompassiOS
//
// 剪贴板同步管理器 - 支持 iOS 与远程设备的剪贴板同步
//

import Foundation
import CryptoKit
import SkyBridgeProtocolCore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Clipboard Manager

public enum RemoteClipboardApplicationResult: Sendable, Equatable {
    case applied
    case duplicate
    case disabled
    case unsupportedMIMEType
    case contentTooLarge(actual: Int, maximum: Int)
    case invalidContent
}

/// 剪贴板同步管理器
/// 支持双向同步：本地剪贴板 <-> 远程剪贴板
@available(iOS 17.0, *)
@MainActor
public final class ClipboardManager: ObservableObject {
    private enum ActivationSource: Hashable {
        case global
        case session(UUID)
    }

    private struct LocalSubmissionOutcome {
        var attemptedCount = 0
        var succeededCount = 0
        var firstFailure: Error?

        var fullySucceeded: Bool {
            attemptedCount > 0 && attemptedCount == succeededCount
        }
    }

    private struct LocalSubmissionLease {
        let id: UUID
        let contentHash: String
        let pasteboardChangeCount: Int
        let task: Task<LocalSubmissionOutcome, Never>
    }

    private struct ClipboardCheckLease: Equatable {
        let id: UUID
        let pasteboardChangeCount: Int
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
    @Published public var maxContentSizeBytes: Int = P2PControlFramePolicy.maximumInlineClipboardByteCount {
        didSet {
            let normalized = min(
                max(1, maxContentSizeBytes),
                P2PControlFramePolicy.maximumInlineClipboardByteCount
            )
            if normalized != maxContentSizeBytes {
                maxContentSizeBytes = normalized
            }
        }
    }

    /// 历史记录保留条数
    @Published public var historyLimit: Int = 25 {
        didSet { trimHistoryIfNeeded() }
    }

    /// 剪贴板轮询间隔（秒）
    @Published public var pollIntervalSeconds: Double = 1.0 {
        didSet {
            guard isEnabled else { return }
            // 轮询间隔变化需要重启 timer 才能生效
            startMonitoringLocalClipboard(resetObservedGeneration: false)
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
    private var activeLocalSubmission: LocalSubmissionLease?
    private var activeClipboardCheck: ClipboardCheckLease?
    private var deliveryConvergence = P2PClipboardDeliveryConvergence()

    private static let historyStore = CodablePersistenceStore<[ClipboardHistoryEntry]>(
        location: .protectedApplicationSupport(
            path: "Clipboard/history.json",
            legacyUserDefaultsKey: "clipboard.history.v1"
        )
    )
    
    // MARK: - Callbacks
    
    /// 剪贴板数据回调（发送到远程）
    public typealias LocalClipboardSubmitter = @MainActor @Sendable (
        _ data: Data,
        _ mimeType: String
    ) async throws -> Void

    public var onLocalClipboardChanged: LocalClipboardSubmitter?
    private var localClipboardListeners: [UUID: LocalClipboardSubmitter] = [:]
    
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
        _ listener: @escaping LocalClipboardSubmitter
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
    @discardableResult
    public func setRemoteClipboard(
        data: Data,
        mimeType: String
    ) -> RemoteClipboardApplicationResult {
        setRemoteClipboard(data: data, mimeType: mimeType, fromDeviceId: nil)
    }

    @discardableResult
    public func setRemoteClipboard(
        data: Data,
        mimeType: String,
        fromDeviceId: String?
    ) -> RemoteClipboardApplicationResult {
        guard isEnabled else { return .disabled }
        guard let canonicalMIMEType = P2PClipboardMIMEPolicy.canonicalWireValue(for: mimeType),
              isAllowed(mimeType: canonicalMIMEType) else {
            return .unsupportedMIMEType
        }
        let maximumBytes = min(
            maxContentSizeBytes,
            P2PControlFramePolicy.maximumInlineClipboardByteCount
        )
        guard data.count <= maximumBytes else {
            SkyBridgeLogger.shared.warning("⚠️ 远程剪贴板内容过大，已忽略：\(data.count) bytes")
            return .contentTooLarge(actual: data.count, maximum: maximumBytes)
        }
        
        let hash = hashData(data)
        guard hash != lastRemoteClipboardHash else { return .duplicate }
        
        #if canImport(UIKit)
        let pasteboard = UIPasteboard.general
        
        switch canonicalMIMEType {
        case P2PClipboardMIMEPolicy.plainText, P2PClipboardMIMEPolicy.utf8PlainText:
            guard let text = String(data: data, encoding: .utf8) else {
                return .invalidContent
            }
            pasteboard.string = text
            SkyBridgeLogger.shared.debug("📋 远程剪贴板文本已设置: bytes=\(data.count)")
            
        case P2PClipboardMIMEPolicy.png:
            guard let image = UIImage(data: data) else {
                return .invalidContent
            }
            pasteboard.image = image
            SkyBridgeLogger.shared.debug("📋 远程剪贴板图片已设置 (PNG)")
            
        case P2PClipboardMIMEPolicy.jpeg:
            guard let image = UIImage(data: data) else {
                return .invalidContent
            }
            pasteboard.image = image
            SkyBridgeLogger.shared.debug("📋 远程剪贴板图片已设置 (JPEG)")
            
        case P2PClipboardMIMEPolicy.uriList:
            guard let urlString = String(data: data, encoding: .utf8),
                  let url = URL(string: urlString) else {
                return .invalidContent
            }
            pasteboard.url = url
            SkyBridgeLogger.shared.debug("📋 远程剪贴板 URL 已设置")
            
        default:
            return .unsupportedMIMEType
        }
        #else
        return .unsupportedMIMEType
        #endif

        lastRemoteClipboardHash = hash
        lastLocalClipboardHash = hash // 避免回环
        // A newly applied inbound value owns the visible state. An older local
        // submission completion must not overwrite it after an actor reentry.
        activeClipboardCheck = nil
        revokeActiveLocalSubmission()
        deliveryConvergence.authoritativeInboundApplied(
            generation: currentPasteboardChangeCount(),
            now: ContinuousClock.now
        )
        
        lastSyncTime = Date()
        syncStatus = .synced

        recordHistory(
            direction: .incoming,
            deviceId: fromDeviceId,
            mimeType: canonicalMIMEType,
            data: data
        )
        return .applied
    }
    
    /// 获取当前剪贴板内容
    /// - Returns: (data, mimeType)
    public func getCurrentClipboardContent() -> (Data, String)? {
        #if canImport(UIKit)
        let pasteboard = UIPasteboard.general
        let maximumBytes = min(
            maxContentSizeBytes,
            P2PControlFramePolicy.maximumInlineClipboardByteCount
        )
        
        // 优先获取文本
        if let text = pasteboard.string, !text.isEmpty {
            let data = text.data(using: .utf8) ?? Data()
            guard data.count <= maximumBytes else { return nil }
            return (data, P2PClipboardMIMEPolicy.plainText)
        }
        
        // 尝试获取图片
        if syncImages, let image = pasteboard.image,
           let pngData = image.pngData() {
            guard pngData.count <= maximumBytes else { return nil }
            return (pngData, P2PClipboardMIMEPolicy.png)
        }
        
        // 尝试获取 URL
        if syncFileURLs, let url = pasteboard.url {
            let data = url.absoluteString.data(using: .utf8) ?? Data()
            guard data.count <= maximumBytes else { return nil }
            return (data, P2PClipboardMIMEPolicy.uriList)
        }
        #endif
        
        return nil
    }
    
    /// 强制同步到远程
    public func syncToRemote() {
        Task { @MainActor [weak self] in
            guard let self, self.isEnabled else {
                return
            }
            let snapshotRead = P2PClipboardSnapshotPolicy.read(
                changeCount: { self.currentPasteboardChangeCount() },
                value: { self.getCurrentClipboardContent() }
            )
            guard case .stable(let content, let changeCount) = snapshotRead,
                  let (data, mimeType) = content else {
                return
            }
            let hash = self.hashData(data)
            guard self.deliveryConvergence.requiresSubmission(
                contentHash: hash,
                committedHash: self.lastLocalClipboardHash,
                remoteOriginHash: self.lastRemoteClipboardHash
            ) else {
                return
            }
            guard self.activeLocalSubmission?.contentHash != hash
                    || self.activeLocalSubmission?.pasteboardChangeCount != changeCount else {
                return
            }
            self.activeClipboardCheck = nil
            self.revokeActiveLocalSubmission()
            guard self.isEnabled,
                  self.currentPasteboardChangeCount() == changeCount else {
                return
            }
            guard self.isSendIntervalElapsed() else {
                self.syncStatus = .active
                return
            }
            _ = await self.submitLocalClipboard(
                data: data,
                mimeType: mimeType,
                hash: hash,
                pasteboardChangeCount: changeCount
            )
        }
    }
    
    // MARK: - Private Methods
    
    /// 开始监听本地剪贴板变化
    private func startMonitoringLocalClipboard(resetObservedGeneration: Bool) {
        stopMonitoringLocalClipboard()
        
        #if canImport(UIKit)
        if resetObservedGeneration {
            lastChangeCount = UIPasteboard.general.changeCount
        }
        #endif
        
        // 使用定时器轮询（iOS 没有剪贴板变化通知）
        let interval = max(0.3, pollIntervalSeconds)
        clipboardMonitorTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkClipboardChange()
            }
        }
    }
    
    /// 停止监听本地剪贴板变化
    private func stopMonitoringLocalClipboard() {
        clipboardMonitorTimer?.invalidate()
        clipboardMonitorTimer = nil
    }
    
    /// 检查剪贴板变化
    private func checkClipboardChange() async {
        guard isEnabled else { return }
        
        #if canImport(UIKit)
        let pasteboard = UIPasteboard.general
        let currentChangeCount = pasteboard.changeCount

        if let activeClipboardCheck {
            guard activeClipboardCheck.pasteboardChangeCount != currentChangeCount else {
                return
            }
            // A newer generation revokes both the old check and its network
            // lease. The old continuation can no longer publish when it resumes.
            self.activeClipboardCheck = nil
            revokeActiveLocalSubmission()
        }

        guard currentChangeCount != lastChangeCount else { return }
        if activeLocalSubmission?.pasteboardChangeCount == currentChangeCount {
            // A manual submission already owns this exact pasteboard value.
            return
        }

        let checkLease = ClipboardCheckLease(
            id: UUID(),
            pasteboardChangeCount: currentChangeCount
        )
        activeClipboardCheck = checkLease
        revokeActiveLocalSubmission()

        let consumed: Bool
        if isEnabled, pasteboard.changeCount == currentChangeCount {
            consumed = await handleLocalClipboardChange(
                pasteboardChangeCount: currentChangeCount
            )
        } else {
            consumed = true
        }

        guard activeClipboardCheck == checkLease else { return }
        if consumed {
            lastChangeCount = currentChangeCount
        }
        activeClipboardCheck = nil
        #endif
    }
    
    /// 处理本地剪贴板变化
    private func handleLocalClipboardChange(pasteboardChangeCount: Int) async -> Bool {
        // Observing a new local generation supersedes every older network
        // operation before any unreadable/disallowed/duplicate early return.
        revokeActiveLocalSubmission()
        let snapshotRead = P2PClipboardSnapshotPolicy.read(
            changeCount: { currentPasteboardChangeCount() },
            value: { getCurrentClipboardContent() }
        )
        guard case .stable(let content, let observedChangeCount) = snapshotRead,
              observedChangeCount == pasteboardChangeCount else {
            return false
        }
        // A failed generation remains unconsumed, but retries are paced by an
        // explicit capped backoff. A different generation clears this deadline
        // here and can therefore preempt immediately.
        guard deliveryConvergence.mayAttempt(
            generation: pasteboardChangeCount,
            now: ContinuousClock.now
        ) else {
            syncStatus = .active
            return false
        }
        guard let (data, mimeType) = content else {
            deliveryConvergence.generationWasHandled(pasteboardChangeCount)
            syncStatus = .error
            return true
        }
        guard isAllowed(mimeType: mimeType) else {
            deliveryConvergence.generationWasHandled(pasteboardChangeCount)
            syncStatus = .active
            return true
        }
        
        let hash = hashData(data)
        
        // 避免重复同步
        guard deliveryConvergence.requiresSubmission(
            contentHash: hash,
            committedHash: lastLocalClipboardHash,
            remoteOriginHash: lastRemoteClipboardHash
        ) else {
            deliveryConvergence.generationWasHandled(pasteboardChangeCount)
            syncStatus = .active
            return true
        }

        // Do not consume changeCount while rate-limited. The next poll retries
        // the newest pasteboard value instead of permanently losing it.
        guard isSendIntervalElapsed() else {
            syncStatus = .active
            return false
        }

        return await submitLocalClipboard(
            data: data,
            mimeType: mimeType,
            hash: hash,
            pasteboardChangeCount: pasteboardChangeCount
        )
    }
    
    /// 计算数据哈希
    private func hashData(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func isAllowed(mimeType: String) -> Bool {
        guard let canonical = P2PClipboardMIMEPolicy.canonicalWireValue(for: mimeType) else {
            return false
        }
        switch canonical {
        case P2PClipboardMIMEPolicy.plainText,
             P2PClipboardMIMEPolicy.utf8PlainText:
            return true
        case P2PClipboardMIMEPolicy.png,
             P2PClipboardMIMEPolicy.jpeg:
            return syncImages
        case P2PClipboardMIMEPolicy.uriList:
            return syncFileURLs
        default:
            return false
        }
    }

    private func isSendIntervalElapsed() -> Bool {
        let minInterval = max(0, minSendIntervalSeconds)
        if minInterval == 0 { return true }
        let now = Date()
        if let lastSendAt, now.timeIntervalSince(lastSendAt) < minInterval {
            return false
        }
        return true
    }

    private func submitLocalClipboard(
        data: Data,
        mimeType: String,
        hash: String,
        pasteboardChangeCount: Int
    ) async -> Bool {
        do {
            try P2PControlFramePolicy.validateInlineClipboardByteCount(data.count)
        } catch {
            deliveryConvergence.generationWasHandled(pasteboardChangeCount)
            syncStatus = .error
            SkyBridgeLogger.shared.warning(
                "⛔️ 本地剪贴板超过内联控制帧上限: bytes=\(data.count)"
            )
            return true
        }

        let submissionID = UUID()
        syncStatus = .syncing
        let submissionTask = Task { @MainActor [weak self] in
            guard let self else {
                var outcome = LocalSubmissionOutcome()
                outcome.firstFailure = CancellationError()
                return outcome
            }
            return await self.notifyLocalClipboardChanged(
                data: data,
                mimeType: mimeType,
                submissionID: submissionID,
                pasteboardChangeCount: pasteboardChangeCount
            )
        }
        activeLocalSubmission = LocalSubmissionLease(
            id: submissionID,
            contentHash: hash,
            pasteboardChangeCount: pasteboardChangeCount,
            task: submissionTask
        )
        let outcome = await submissionTask.value

        guard localSubmissionIsCurrent(
            submissionID: submissionID,
            pasteboardChangeCount: pasteboardChangeCount
        ) else {
            return false
        }
        guard outcome.fullySucceeded else {
            clearActiveLocalSubmissionOwner(submissionID: submissionID)
            deliveryConvergence.recordFailure(
                generation: pasteboardChangeCount,
                now: ContinuousClock.now
            )
            syncStatus = .error
            let failure = outcome.firstFailure.map { String(describing: type(of: $0)) }
                ?? "no_authenticated_recipient"
            SkyBridgeLogger.shared.warning(
                "⛔️ 本地剪贴板未完成提交: attempted=\(outcome.attemptedCount) succeeded=\(outcome.succeededCount) reason=\(failure)"
            )
            return false
        }

        let shouldRecordHistory = lastLocalClipboardHash != hash
        lastLocalClipboardHash = hash
        lastSendAt = Date()
        lastSyncTime = Date()
        let convergenceAchieved = deliveryConvergence.fullySubmitted(
            generation: pasteboardChangeCount,
            now: ContinuousClock.now
        )
        if convergenceAchieved {
            lastChangeCount = pasteboardChangeCount
        }
        clearActiveLocalSubmissionOwner(submissionID: submissionID)
        syncStatus = convergenceAchieved ? .submitted : .active
        if shouldRecordHistory {
            recordHistory(direction: .outgoing, deviceId: nil, mimeType: mimeType, data: data)
        }
        SkyBridgeLogger.shared.debug(
            "📋 本地剪贴板已提交到所有活动路由: routes=\(outcome.succeededCount) bytes=\(data.count)"
        )
        return convergenceAchieved
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
            startMonitoringLocalClipboard(resetObservedGeneration: true)
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
            revokeActiveLocalSubmission()
            activeClipboardCheck = nil
            isEnabled = false
            stopMonitoringLocalClipboard()
            activeSessionId = nil
            lastRemoteClipboardHash = nil
            lastLocalClipboardHash = nil
            deliveryConvergence = P2PClipboardDeliveryConvergence()
            syncStatus = .idle
            saveHistory()
        } else {
            syncStatus = .active
        }

        let scope = sessionId?.uuidString ?? "global"
        SkyBridgeLogger.shared.info("🛑 剪贴板同步已禁用: scope=\(scope)")
    }

    private func notifyLocalClipboardChanged(
        data: Data,
        mimeType: String,
        submissionID: UUID,
        pasteboardChangeCount: Int
    ) async -> LocalSubmissionOutcome {
        var submitters = Array(localClipboardListeners.values)
        if let onLocalClipboardChanged {
            submitters.insert(onLocalClipboardChanged, at: 0)
        }

        var outcome = LocalSubmissionOutcome()
        for submitter in submitters {
            guard localSubmissionIsCurrent(
                submissionID: submissionID,
                pasteboardChangeCount: pasteboardChangeCount
            ) else {
                if outcome.firstFailure == nil {
                    outcome.firstFailure = CancellationError()
                }
                break
            }
            outcome.attemptedCount += 1
            do {
                try Task.checkCancellation()
                try await deliveryConvergence.attemptRoute {
                    try await submitter(data, mimeType)
                }
                try Task.checkCancellation()
                guard localSubmissionIsCurrent(
                    submissionID: submissionID,
                    pasteboardChangeCount: pasteboardChangeCount
                ) else {
                    throw CancellationError()
                }
                outcome.succeededCount += 1
            } catch is CancellationError {
                if outcome.firstFailure == nil {
                    outcome.firstFailure = CancellationError()
                }
                break
            } catch {
                if outcome.firstFailure == nil {
                    outcome.firstFailure = error
                }
            }
        }
        return outcome
    }

    private func currentPasteboardChangeCount() -> Int {
        #if canImport(UIKit)
        UIPasteboard.general.changeCount
        #else
        0
        #endif
    }

    private func localSubmissionIsCurrent(
        submissionID: UUID,
        pasteboardChangeCount: Int
    ) -> Bool {
        activeLocalSubmission?.id == submissionID
            && activeLocalSubmission?.pasteboardChangeCount == pasteboardChangeCount
            && currentPasteboardChangeCount() == pasteboardChangeCount
    }

    private func revokeActiveLocalSubmission() {
        activeLocalSubmission?.task.cancel()
        activeLocalSubmission = nil
    }

    private func clearActiveLocalSubmissionOwner(submissionID: UUID) {
        guard activeLocalSubmission?.id == submissionID else { return }
        activeLocalSubmission = nil
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
    case submitted = "submitted"
    case synced = "synced"
    case error = "error"
    
    public var displayName: String {
        switch self {
        case .idle: return "未启用"
        case .active: return "已启用"
        case .syncing: return "同步中"
        case .submitted: return "已提交"
        case .synced: return "已同步"
        case .error: return "错误"
        }
    }
    
    public var iconName: String {
        switch self {
        case .idle: return "clipboard"
        case .active: return "clipboard.fill"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .submitted: return "paperplane.circle.fill"
        case .synced: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}
