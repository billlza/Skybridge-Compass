// DEDUPLICATION TARGET — not inherently macOS-only.
//
// This type is cross-platform in nature, but the iOS app currently ships its own
// parallel implementation (ClipboardManager / ClipboardSyncService). Phase 0 of the iOS/SkyBridgeCore unification only
// makes the core *compile* for iOS; adopting it on iOS is a later, deliberate migration
// per type. Excluding it here avoids standing up a second implementation inside one
// binary. The remaining macOS-only pieces are AppKit-based and must be replaced with
// platform-neutral equivalents as part of that migration.
// Tracked in Docs/background-wake-capability-ledger.md.
#if os(macOS)
//
// ClipboardSyncService.swift
// SkyBridgeCore
//
// 跨设备剪贴板同步服务
// 支持 macOS 14.0+, 渐进增强支持 macOS 15.x 和 26.x
//
// 兼容策略:
// - macOS 14/15: 使用 Combine + Timer 监听剪贴板变化
// - macOS 26+: 使用 Observations AsyncSequence (未来)
//

import Foundation
import AppKit
import CryptoKit
import Combine
import OSLog
import SkyBridgeProtocolCore

// MARK: - 剪贴板同步服务协议

/// 剪贴板同步服务协议（用于依赖注入和测试）
@MainActor
public protocol ClipboardSyncServiceProtocol: AnyObject {
    var isEnabled: Bool { get }
    var syncState: ClipboardSyncState { get }
    var connectedDevices: [DeviceClipboardStatus] { get }
    var history: [ClipboardHistoryEntry] { get }

    func enable() async throws
    func disable()
    func syncNow() async throws
    func clearHistory()
}

// MARK: - 剪贴板同步服务

/// 跨设备剪贴板同步服务
/// 通过 P2P 通道实现设备间剪贴板内容的安全同步
@MainActor
public final class ClipboardSyncService: ObservableObject, ClipboardSyncServiceProtocol {
    private struct LocalSubmissionLease {
        let id: UUID
        let contentHash: String
        let pasteboardChangeCount: Int
        let task: Task<Void, Error>
    }

    // MARK: - Singleton

    public static let shared = ClipboardSyncService()

    // MARK: - Published Properties

    /// 是否启用同步
    @Published public private(set) var isEnabled: Bool = false

    /// 当前同步状态
    @Published public private(set) var syncState: ClipboardSyncState = .disabled

    /// 已连接的设备状态
    @Published public private(set) var connectedDevices: [DeviceClipboardStatus] = []

    /// 同步历史记录
    @Published public private(set) var history: [ClipboardHistoryEntry] = []

    /// 最后同步时间
    @Published public private(set) var lastSyncTime: Date?

    /// 配置
    @Published public var configuration: ClipboardSyncConfiguration {
        didSet {
            let normalizedMaximum = min(
                max(1, configuration.maxContentSize),
                P2PControlFramePolicy.maximumInlineClipboardByteCount
            )
            guard normalizedMaximum == configuration.maxContentSize else {
                configuration.maxContentSize = normalizedMaximum
                clipboardContentSizeWasMigrated = true
                return
            }
            saveConfiguration()
        }
    }

    @Published public private(set) var clipboardContentSizeWasMigrated: Bool

    // MARK: - Private Properties

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "ClipboardSync")
    private let pasteboard = NSPasteboard.general
    private var changeCount: Int = 0
    private var lastContentHash: String?
    private var activeLocalSubmission: LocalSubmissionLease?
    private var deliveryConvergence = P2PClipboardDeliveryConvergence()

    // 监听器
    private var monitorTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // 加密
    private let encryptor = ClipboardEncryptor()

    // P2P 通道回调
    public var onSendToDevice: ((_ data: Data, _ deviceID: String) async throws -> Void)?
    public var onBroadcast: ((_ data: Data) async throws -> Void)?

    /// 本地剪贴板发生变化时回调，提供原始内容（mimeType + 原始字节），由集成方封装为
    /// AppMessage.clipboard 经 P2P 会话加密发送（不再叠加本服务自带的信封加密）。
    public var onLocalContentChanged: (
        @MainActor @Sendable (_ mimeType: String, _ data: Data) async throws -> Void
    )?

    /// ClipboardContentType ↔ MIME 类型映射（与 AppMessage.ClipboardPayload.mimeType 对齐）。
    private static func mimeType(for type: ClipboardContentType) -> String {
        switch type {
        case .text: return P2PClipboardMIMEPolicy.plainText
        case .image: return P2PClipboardMIMEPolicy.png
        case .fileURL: return P2PClipboardMIMEPolicy.uriList
        case .richText: return P2PClipboardMIMEPolicy.richText
        case .html: return P2PClipboardMIMEPolicy.html
        }
    }

    private static func contentType(forMIME mime: String) -> ClipboardContentType? {
        guard let canonical = P2PClipboardMIMEPolicy.canonicalWireValue(for: mime) else {
            return nil
        }
        switch canonical {
        case P2PClipboardMIMEPolicy.plainText,
             P2PClipboardMIMEPolicy.utf8PlainText:
            return .text
        case P2PClipboardMIMEPolicy.png,
             P2PClipboardMIMEPolicy.jpeg:
            return .image
        case P2PClipboardMIMEPolicy.uriList:
            return .fileURL
        case P2PClipboardMIMEPolicy.richText:
            return .richText
        case P2PClipboardMIMEPolicy.html:
            return .html
        default: return nil
        }
    }

    private static let configurationStore = CodablePersistenceStore<ClipboardSyncConfiguration>(
        location: .protectedApplicationSupport(
            path: "Clipboard/configuration.json",
            legacyUserDefaultsKey: "com.skybridge.clipboard.config"
        )
    )
    private static let historyStore = CodablePersistenceStore<[ClipboardHistoryEntry]>(
        location: .protectedApplicationSupport(
            path: "Clipboard/history.json",
            legacyUserDefaultsKey: "com.skybridge.clipboard.history"
        )
    )

    // MARK: - Initialization

    private init() {
        var loadedConfiguration = Self.loadConfiguration() ?? .default
        let storedMaximum = loadedConfiguration.maxContentSize
        loadedConfiguration.maxContentSize = min(
            max(1, storedMaximum),
            P2PControlFramePolicy.maximumInlineClipboardByteCount
        )
        self.configuration = loadedConfiguration
        self.clipboardContentSizeWasMigrated = loadedConfiguration.maxContentSize != storedMaximum
        self.history = Self.loadHistory()

        if clipboardContentSizeWasMigrated {
            do {
                try Self.configurationStore.save(loadedConfiguration)
            } catch {
                logger.error(
                    "📋 剪贴板大小迁移持久化失败: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        logger.info("📋 剪贴板同步服务已初始化")
    }

    // MARK: - Public Methods

    /// 启用剪贴板同步
    public func enable() async throws {
        guard !isEnabled else { return }

        isEnabled = true
        syncState = .idle
        changeCount = pasteboard.changeCount
        if !configuration.isEnabled { configuration.isEnabled = true } // 持久化用户意图（didSet 保存）

        startMonitoring()

        logger.info("✅ 剪贴板同步已启用")
    }

    /// 禁用剪贴板同步
    public func disable() {
        guard isEnabled else { return }

        revokeActiveLocalSubmission()
        deliveryConvergence = P2PClipboardDeliveryConvergence()
        isEnabled = false
        syncState = .disabled
        if configuration.isEnabled { configuration.isEnabled = false } // 持久化用户意图（didSet 保存）

        stopMonitoring()

        logger.info("🛑 剪贴板同步已禁用")
    }

    /// 立即同步当前剪贴板内容
    public func syncNow() async throws {
        guard isEnabled else { return }
        guard syncState != .syncing else { return }

        let snapshotRead = P2PClipboardSnapshotPolicy.read(
            changeCount: { pasteboard.changeCount },
            value: { readLocalClipboard() }
        )
        guard case .stable(let snapshot, let pasteboardChangeCount) = snapshotRead else {
            syncState = .idle
            return
        }
        guard let content = snapshot else {
            syncState = .idle
            return
        }
        let submissionID = UUID()
        syncState = .syncing
        do {
            try await runLocalSubmission(
                content,
                submissionID: submissionID,
                pasteboardChangeCount: pasteboardChangeCount
            )
            guard activeLocalSubmission?.id == submissionID else { return }
            lastContentHash = content.contentHash
            let convergenceAchieved = deliveryConvergence.fullySubmitted(
                generation: pasteboardChangeCount,
                now: ContinuousClock.now
            )
            if convergenceAchieved {
                changeCount = pasteboardChangeCount
            }
            clearActiveLocalSubmissionOwner(submissionID: submissionID)
            syncState = .idle
        } catch {
            if activeLocalSubmission?.id == submissionID {
                clearActiveLocalSubmissionOwner(submissionID: submissionID)
                if isEnabled, pasteboard.changeCount == pasteboardChangeCount {
                    deliveryConvergence.recordFailure(
                        generation: pasteboardChangeCount,
                        now: ContinuousClock.now
                    )
                }
                syncState = .error(error.localizedDescription)
            }
            throw error
        }
    }

    /// 清除历史记录
    public func clearHistory() {
        history.removeAll()
        saveHistory()
        logger.info("📋 剪贴板历史已清除")
    }

    /// 接收远程剪贴板数据
    /// - Parameters:
    ///   - data: 加密的消息数据
    ///   - fromDeviceID: 来源设备 ID
    public func receiveRemoteData(_ data: Data, fromDeviceID: String) async {
        do {
            // 解码消息
            let message = try JSONDecoder().decode(ClipboardSyncMessage.self, from: data)

            switch message.messageType {
            case .content:
                try await handleContentMessage(message, fromDeviceID: fromDeviceID)

            case .ack:
                logger.debug("📋 收到设备 \(fromDeviceID) 的确认")

            case .request:
                // 响应内容请求
                if let content = readLocalClipboard() {
                    try await sendContent(content, to: fromDeviceID)
                }

            case .ping:
                logger.debug("📋 收到设备 \(fromDeviceID) 的心跳")
            }

        } catch {
            logger.error("📋 处理远程数据失败: \(error.localizedDescription)")
        }
    }

    /// 更新设备状态
    public func updateDeviceStatus(_ status: DeviceClipboardStatus) {
        if let index = connectedDevices.firstIndex(where: { $0.deviceID == status.deviceID }) {
            connectedDevices[index] = status
        } else {
            connectedDevices.append(status)
        }
    }

    /// 移除设备
    public func removeDevice(_ deviceID: String) {
        connectedDevices.removeAll { $0.deviceID == deviceID }
    }

    // MARK: - Private Methods - Monitoring

    /// 开始监听本地剪贴板变化
    private func startMonitoring() {
        stopMonitoring()

        // 使用 Timer 轮询 (兼容 macOS 14+)
        // macOS 没有剪贴板变化通知，只能轮询 changeCount
        monitorTimer = Timer.scheduledTimer(
            withTimeInterval: configuration.syncInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkClipboardChange()
            }
        }

        logger.debug("📋 开始监听剪贴板变化")
    }

    /// 停止监听
    private func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    /// 检查剪贴板变化
    private func checkClipboardChange() async {
        guard isEnabled else { return }

        let currentChangeCount = pasteboard.changeCount
        if let activeLocalSubmission {
            guard activeLocalSubmission.pasteboardChangeCount != currentChangeCount else {
                return
            }
            revokeActiveLocalSubmission()
        }

        guard currentChangeCount != changeCount else { return }
        guard deliveryConvergence.mayAttempt(
            generation: currentChangeCount,
            now: ContinuousClock.now
        ) else {
            return
        }

        let snapshotRead = P2PClipboardSnapshotPolicy.read(
            changeCount: { pasteboard.changeCount },
            value: { readLocalClipboard() }
        )
        guard case .stable(let snapshot, let observedChangeCount) = snapshotRead,
              observedChangeCount == currentChangeCount else {
            return
        }
        guard let content = snapshot else {
            changeCount = currentChangeCount
            deliveryConvergence.generationWasHandled(currentChangeCount)
            syncState = .idle
            return
        }

        // 检查是否重复（避免循环同步）
        guard deliveryConvergence.requiresSubmission(
            contentHash: content.contentHash,
            committedHash: lastContentHash
        ) else {
            changeCount = currentChangeCount
            deliveryConvergence.generationWasHandled(currentChangeCount)
            syncState = .idle
            return
        }

        // Submit through every configured route; only commit the local hash and
        // history after all routes report actual network submission.
        let submissionID = UUID()
        syncState = .syncing
        do {
            try await runLocalSubmission(
                content,
                submissionID: submissionID,
                pasteboardChangeCount: currentChangeCount
            )
            guard activeLocalSubmission?.id == submissionID else { return }
            lastContentHash = content.contentHash
            let convergenceAchieved = deliveryConvergence.fullySubmitted(
                generation: currentChangeCount,
                now: ContinuousClock.now
            )
            if convergenceAchieved {
                changeCount = currentChangeCount
            }
            clearActiveLocalSubmissionOwner(submissionID: submissionID)
            syncState = .idle
        } catch is CancellationError {
            if activeLocalSubmission?.id == submissionID {
                clearActiveLocalSubmissionOwner(submissionID: submissionID)
                if isEnabled, pasteboard.changeCount == currentChangeCount {
                    deliveryConvergence.recordFailure(
                        generation: currentChangeCount,
                        now: ContinuousClock.now
                    )
                }
                syncState = .idle
            }
        } catch {
            if activeLocalSubmission?.id == submissionID {
                clearActiveLocalSubmissionOwner(submissionID: submissionID)
                if isEnabled, pasteboard.changeCount == currentChangeCount {
                    deliveryConvergence.recordFailure(
                        generation: currentChangeCount,
                        now: ContinuousClock.now
                    )
                }
                logger.error("📋 广播剪贴板内容失败: \(error.localizedDescription)")
                syncState = .error(error.localizedDescription)
            }
        }
    }

    /// 摄入来自远端的原始剪贴板内容（经 P2P AppMessage.clipboard 解出），应用到本地并落历史。
    /// applyRemoteContent 会把 lastContentHash 设为该内容哈希，从而避免被本地监听再次回播形成环路。
    /// - Parameters:
    ///   - mimeType: 内容 MIME 类型
    ///   - data: 原始内容字节
    ///   - fromDeviceID: 来源设备 ID
    public func ingestRemoteContent(
        mimeType: String,
        data: Data,
        fromDeviceID: String
    ) async throws {
        guard isEnabled else { return }
        try P2PControlFramePolicy.validateInlineClipboardByteCount(data.count)
        guard data.count <= configuration.maxContentSize else {
            throw ClipboardSyncError.contentTooLarge(
                size: data.count,
                maxSize: configuration.maxContentSize
            )
        }
        guard let type = Self.contentType(forMIME: mimeType) else {
            throw ClipboardSyncError.unsupportedType(mimeType)
        }
        let content = ClipboardContent(type: type, data: data, sourceDeviceID: fromDeviceID)
        guard content.contentHash != lastContentHash else {
            logger.debug("📋 忽略重复的远端剪贴板内容")
            return
        }
        try applyAuthoritativeInboundContent(content)
        let entry = ClipboardHistoryEntry(content: content, direction: .incoming, targetDeviceIDs: [])
        addToHistory(entry)
        lastSyncTime = Date()
        logger.info("📋 已应用来自 \(fromDeviceID, privacy: .public) 的远端剪贴板内容")
    }

    /// 把本服务接入 P2P 传输（本地剪贴板变化时向所有活动 P2P 会话广播 AppMessage.clipboard），
    /// 并按持久化配置恢复启用状态。应在 App 启动后调用一次。
    public func attachP2PTransportAndRestore() async {
        onLocalContentChanged = { mimeType, data in
            try P2PControlFramePolicy.validateInlineClipboardByteCount(data.count)
            guard let canonicalMIMEType = P2PClipboardMIMEPolicy.canonicalWireValue(for: mimeType),
                  canonicalMIMEType == P2PClipboardMIMEPolicy.plainText
                    || canonicalMIMEType == P2PClipboardMIMEPolicy.utf8PlainText
                    || canonicalMIMEType == P2PClipboardMIMEPolicy.png
                    || canonicalMIMEType == P2PClipboardMIMEPolicy.jpeg
                    || canonicalMIMEType == P2PClipboardMIMEPolicy.uriList else {
                throw ClipboardSyncError.unsupportedType(mimeType)
            }
            let payload = AppMessage.ClipboardPayload(
                mimeType: canonicalMIMEType,
                dataBase64: data.base64EncodedString()
            )
            // 在主线程快照当前活动连接（P2PConnection 为 @unchecked Sendable，可跨域传递），再逐个发送。
            let connections = await MainActor.run { Array(P2PNetworkManager.shared.activeConnections.values) }
            guard !connections.isEmpty else {
                throw ClipboardSyncError.noConnectedDevices
            }
            var firstFailure: Error?
            for connection in connections {
                do {
                    try Task.checkCancellation()
                    try await connection.sendAppMessage(.clipboard(payload))
                    try Task.checkCancellation()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if firstFailure == nil {
                        firstFailure = error
                    }
                }
            }
            if let firstFailure {
                throw firstFailure
            }
        }
        if configuration.isEnabled {
            do {
                try await enable()
            } catch {
                syncState = .error(error.localizedDescription)
                logger.error("📋 恢复剪贴板同步失败: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Private Methods - Content Handling

    /// 读取本地剪贴板内容
    private func readLocalClipboard() -> ClipboardContent? {
        let deviceID = getLocalDeviceID()

        // 优先文本
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let data = text.data(using: .utf8) ?? Data()

            // 检查大小限制
            guard data.count <= configuration.maxContentSize else {
                logger.warning("📋 文本内容过大: \(data.count) 字节")
                return nil
            }

            return ClipboardContent(type: .text, data: data, sourceDeviceID: deviceID)
        }

        // 图片
        if configuration.syncImages {
            if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
                guard let tiffData = image.tiffRepresentation,
                      let bitmapRep = NSBitmapImageRep(data: tiffData),
                      let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                    return nil
                }

                // 检查大小限制
                guard pngData.count <= configuration.maxContentSize else {
                    logger.warning("📋 图片内容过大: \(pngData.count) 字节")
                    return nil
                }

                return ClipboardContent(type: .image, data: pngData, sourceDeviceID: deviceID)
            }
        }

        // 文件 URL
        if configuration.syncFileURLs {
            if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
               let firstURL = fileURLs.first {
                let pathData = firstURL.path.data(using: .utf8) ?? Data()
                return ClipboardContent(type: .fileURL, data: pathData, sourceDeviceID: deviceID)
            }
        }

        // RTF
        if let rtfData = pasteboard.data(forType: .rtf) {
            guard rtfData.count <= configuration.maxContentSize else {
                return nil
            }
            return ClipboardContent(type: .richText, data: rtfData, sourceDeviceID: deviceID)
        }

        // HTML
        if let htmlData = pasteboard.data(forType: .html) {
            guard htmlData.count <= configuration.maxContentSize else {
                return nil
            }
            return ClipboardContent(type: .html, data: htmlData, sourceDeviceID: deviceID)
        }

        return nil
    }

    /// 应用远程剪贴板内容到本地
    private func applyRemoteContent(_ content: ClipboardContent) throws -> Int {
        let applied: Bool
        switch content.type {
        case .text:
            guard let text = String(data: content.data, encoding: .utf8) else {
                throw ClipboardSyncError.decodingFailed
            }
            pasteboard.clearContents()
            applied = pasteboard.setString(text, forType: .string)

        case .image:
            guard let image = NSImage(data: content.data) else {
                throw ClipboardSyncError.decodingFailed
            }
            pasteboard.clearContents()
            applied = pasteboard.writeObjects([image])

        case .fileURL:
            guard let path = String(data: content.data, encoding: .utf8),
                  !path.isEmpty else {
                throw ClipboardSyncError.decodingFailed
            }
            pasteboard.clearContents()
            applied = pasteboard.setString(path, forType: .string)

        case .richText:
            guard !content.data.isEmpty else {
                throw ClipboardSyncError.decodingFailed
            }
            pasteboard.clearContents()
            applied = pasteboard.setData(content.data, forType: .rtf)

        case .html:
            guard !content.data.isEmpty else {
                throw ClipboardSyncError.decodingFailed
            }
            pasteboard.clearContents()
            applied = pasteboard.setData(content.data, forType: .html)
        }

        guard applied else {
            throw ClipboardSyncError.decodingFailed
        }

        // Update the loop-prevention hash only after the pasteboard accepted
        // the content. Invalid data must remain retryable and observable.
        lastContentHash = content.contentHash

        return pasteboard.changeCount
    }

    private func applyAuthoritativeInboundContent(_ content: ClipboardContent) throws {
        let inboundGeneration = try applyRemoteContent(content)
        revokeActiveLocalSubmission()
        let requiresCompensation = deliveryConvergence.authoritativeInboundApplied(
            generation: inboundGeneration,
            now: ContinuousClock.now
        )
        if !requiresCompensation {
            changeCount = inboundGeneration
        }
        syncState = .idle
    }

    // MARK: - Private Methods - Network

    private func runLocalSubmission(
        _ content: ClipboardContent,
        submissionID: UUID,
        pasteboardChangeCount: Int
    ) async throws {
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.submitLocalContent(content, submissionID: submissionID)
        }
        activeLocalSubmission = LocalSubmissionLease(
            id: submissionID,
            contentHash: content.contentHash,
            pasteboardChangeCount: pasteboardChangeCount,
            task: task
        )
        try await task.value
    }

    private func requireActiveLocalSubmission(submissionID: UUID) throws {
        try Task.checkCancellation()
        guard let activeLocalSubmission,
              activeLocalSubmission.id == submissionID,
              pasteboard.changeCount == activeLocalSubmission.pasteboardChangeCount else {
            throw CancellationError()
        }
    }

    private func revokeActiveLocalSubmission() {
        activeLocalSubmission?.task.cancel()
        activeLocalSubmission = nil
    }

    private func clearActiveLocalSubmissionOwner(submissionID: UUID) {
        guard activeLocalSubmission?.id == submissionID else { return }
        activeLocalSubmission = nil
    }

    /// Submits a local clipboard value through every configured transport.
    /// History and timestamps are committed only after every attempted route
    /// reports successful network submission.
    private func submitLocalContent(
        _ content: ClipboardContent,
        submissionID: UUID
    ) async throws {
        try P2PControlFramePolicy.validateInlineClipboardByteCount(content.data.count)
        try requireActiveLocalSubmission(submissionID: submissionID)

        var attemptedRouteCount = 0
        var firstFailure: Error?

        if let broadcast = onBroadcast {
            try requireActiveLocalSubmission(submissionID: submissionID)
            attemptedRouteCount += 1
            do {
                let message = try createSyncMessage(for: content)
                let messageData = try JSONEncoder().encode(message)
                try await deliveryConvergence.attemptRoute {
                    try await broadcast(messageData)
                }
                try requireActiveLocalSubmission(submissionID: submissionID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstFailure = error
            }
        }

        if let onLocalContentChanged {
            try requireActiveLocalSubmission(submissionID: submissionID)
            attemptedRouteCount += 1
            do {
                try await deliveryConvergence.attemptRoute {
                    try await onLocalContentChanged(
                        Self.mimeType(for: content.type),
                        content.data
                    )
                }
                try requireActiveLocalSubmission(submissionID: submissionID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if firstFailure == nil {
                    firstFailure = error
                }
            }
        }

        guard attemptedRouteCount > 0 else {
            throw ClipboardSyncError.noConnectedDevices
        }
        if let firstFailure {
            throw firstFailure
        }
        try requireActiveLocalSubmission(submissionID: submissionID)

        // 记录历史
        let deviceIDs = connectedDevices.map { $0.deviceID }
        let entry = ClipboardHistoryEntry(
            content: content,
            direction: .outgoing,
            targetDeviceIDs: deviceIDs
        )
        addToHistory(entry)

        lastSyncTime = Date()
        logger.info("📋 剪贴板已提交到 \(attemptedRouteCount) 条活动路由")
    }

    /// 发送内容到特定设备
    private func sendContent(_ content: ClipboardContent, to deviceID: String) async throws {
        let message = try createSyncMessage(for: content)
        let messageData = try JSONEncoder().encode(message)

        if let send = onSendToDevice {
            try await send(messageData, deviceID)
        }

        logger.debug("📋 已发送剪贴板内容到设备: \(deviceID)")
    }

    /// 处理内容消息
    private func handleContentMessage(_ message: ClipboardSyncMessage, fromDeviceID: String) async throws {
        guard let encryptedContent = message.encryptedContent,
              let metadata = message.metadata else {
            throw ClipboardSyncError.decodingFailed
        }

        // 检查是否重复
        guard metadata.contentHash != lastContentHash else {
            logger.debug("📋 忽略重复内容")
            return
        }

        // 解密内容
        let contentData = try encryptor.decrypt(encryptedContent)

        // 解码内容
        let content = try JSONDecoder().decode(ClipboardContent.self, from: contentData)

        // Only a successfully applied inbound value supersedes an in-flight
        // local submission. Invalid inbound data must leave the local owner and
        // its visible state intact.
        try applyAuthoritativeInboundContent(content)

        // 记录历史
        let entry = ClipboardHistoryEntry(
            content: content,
            direction: .incoming,
            targetDeviceIDs: [fromDeviceID]
        )
        addToHistory(entry)

        lastSyncTime = Date()

        // 发送确认
        let ackMessage = ClipboardSyncMessage(messageType: .ack)
        let ackData = try JSONEncoder().encode(ackMessage)
        if let send = onSendToDevice {
            try await send(ackData, fromDeviceID)
        }

        logger.info("📋 已接收来自设备 \(fromDeviceID) 的剪贴板内容")
    }

    /// 创建同步消息
    private func createSyncMessage(for content: ClipboardContent) throws -> ClipboardSyncMessage {
        // 编码内容
        let contentData = try JSONEncoder().encode(content)

        // 加密内容
        let encryptedContent = try encryptor.encrypt(contentData)

        // 创建消息
        return ClipboardSyncMessage(
            messageType: .content,
            encryptedContent: encryptedContent,
            metadata: ClipboardSyncMessage.Metadata(content: content)
        )
    }

    // MARK: - Private Methods - History

    /// 添加到历史记录
    private func addToHistory(_ entry: ClipboardHistoryEntry) {
        history.insert(entry, at: 0)

        // 限制数量
        if history.count > configuration.historyLimit {
            history = Array(history.prefix(configuration.historyLimit))
        }

        // 移除过期记录
        let cutoffDate = Date().addingTimeInterval(-configuration.historyRetentionDuration)
        history.removeAll { $0.syncedAt < cutoffDate }

        saveHistory()
    }

    // MARK: - Private Methods - Persistence

    private func saveConfiguration() {
        try? Self.configurationStore.save(configuration)
    }

    private static func loadConfiguration() -> ClipboardSyncConfiguration? {
        Self.configurationStore.load()
    }

    private func saveHistory() {
        try? Self.historyStore.save(history)
    }

    private static func loadHistory() -> [ClipboardHistoryEntry] {
        Self.historyStore.load() ?? []
    }

    // MARK: - Private Methods - Utilities

    private func getLocalDeviceID() -> String {
        // 使用设备标识符
        if let deviceID = UserDefaults.standard.string(forKey: "com.skybridge.deviceID") {
            return deviceID
        }

        // 生成新的设备 ID
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: "com.skybridge.deviceID")
        return newID
    }
}

// MARK: - 剪贴板加密器

/// 剪贴板内容加密器
private final class ClipboardEncryptor: @unchecked Sendable {

    private let symmetricKey: SymmetricKey

    init() {
        // 从 Keychain 获取或生成密钥
        if let existingKey = Self.loadKeyFromKeychain() {
            self.symmetricKey = existingKey
        } else {
            let newKey = SymmetricKey(size: .bits256)
            Self.saveKeyToKeychain(newKey)
            self.symmetricKey = newKey
        }
    }

    /// 加密数据
    func encrypt(_ data: Data) throws -> Data {
        do {
            let sealedBox = try AES.GCM.seal(data, using: symmetricKey)
            guard let combined = sealedBox.combined else {
                throw ClipboardSyncError.encryptionFailed("无法组合加密数据")
            }
            return combined
        } catch let error as ClipboardSyncError {
            throw error
        } catch {
            throw ClipboardSyncError.encryptionFailed(error.localizedDescription)
        }
    }

    /// 解密数据
    func decrypt(_ data: Data) throws -> Data {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealedBox, using: symmetricKey)
        } catch {
            throw ClipboardSyncError.decryptionFailed(error.localizedDescription)
        }
    }

    // MARK: - Keychain

    private static let keychainKey = "com.skybridge.clipboard.encryptionKey"

    private static func loadKeyFromKeychain() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let keyData = result as? Data else {
            return nil
        }

        return SymmetricKey(data: keyData)
    }

    private static func saveKeyToKeychain(_ key: SymmetricKey) {
        let keyData = key.withUnsafeBytes { Data($0) }

        // 先删除旧的
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // 添加新的
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        SecItemAdd(addQuery as CFDictionary, nil)
    }
}
#endif
