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
        didSet { saveConfiguration() }
    }

    // MARK: - Private Properties

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "ClipboardSync")
    private let pasteboard = NSPasteboard.general
    private var changeCount: Int = 0
    private var lastContentHash: String?

    // 监听器
    private var monitorTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // 加密
    private let encryptor = ClipboardEncryptor()

    // P2P 通道回调
    public var onSendToDevice: ((_ data: Data, _ deviceID: String) async throws -> Void)?
    public var onBroadcast: ((_ data: Data) async throws -> Void)?

    // 持久化 Key
    private let configKey = "com.skybridge.clipboard.config"
    private let historyKey = "com.skybridge.clipboard.history"

    // MARK: - Initialization

    private init() {
        self.configuration = Self.loadConfiguration() ?? .default
        self.history = Self.loadHistory()

        logger.info("📋 剪贴板同步服务已初始化")
    }

    // MARK: - Public Methods

    /// 启用剪贴板同步
    public func enable() async throws {
        guard !isEnabled else { return }

        isEnabled = true
        syncState = .idle
        changeCount = pasteboard.changeCount

        startMonitoring()

        logger.info("✅ 剪贴板同步已启用")
    }

    /// 禁用剪贴板同步
    public func disable() {
        guard isEnabled else { return }

        isEnabled = false
        syncState = .disabled

        stopMonitoring()

        logger.info("🛑 剪贴板同步已禁用")
    }

    /// 立即同步当前剪贴板内容
    public func syncNow() async throws {
        guard isEnabled else { return }
        guard syncState != .syncing else { return }

        syncState = .syncing
        defer { syncState = .idle }

        if let content = readLocalClipboard() {
            try await broadcastContent(content)
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
        guard currentChangeCount != changeCount else { return }
        changeCount = currentChangeCount

        // 读取剪贴板内容
        guard let content = readLocalClipboard() else { return }

        // 检查是否重复（避免循环同步）
        guard content.contentHash != lastContentHash else { return }
        lastContentHash = content.contentHash

        // 广播到所有连接的设备
        do {
            try await broadcastContent(content)
        } catch {
            logger.error("📋 广播剪贴板内容失败: \(error.localizedDescription)")
            syncState = .error(error.localizedDescription)
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
    private func applyRemoteContent(_ content: ClipboardContent) {
        // 更新 hash 避免触发自己的同步
        lastContentHash = content.contentHash

        pasteboard.clearContents()

        switch content.type {
        case .text:
            if let text = String(data: content.data, encoding: .utf8) {
                pasteboard.setString(text, forType: .string)
                logger.debug("📋 已应用远程文本: \(text.prefix(50))")
            }

        case .image:
            if let image = NSImage(data: content.data) {
                pasteboard.writeObjects([image])
                logger.debug("📋 已应用远程图片")
            }

        case .fileURL:
            if let path = String(data: content.data, encoding: .utf8) {
                pasteboard.setString(path, forType: .string)
                logger.debug("📋 已应用远程文件路径: \(path)")
            }

        case .richText:
            pasteboard.setData(content.data, forType: .rtf)
            logger.debug("📋 已应用远程 RTF 内容")

        case .html:
            pasteboard.setData(content.data, forType: .html)
            logger.debug("📋 已应用远程 HTML 内容")
        }

        // 更新 changeCount
        changeCount = pasteboard.changeCount
    }

    // MARK: - Private Methods - Network

    /// 广播内容到所有设备
    private func broadcastContent(_ content: ClipboardContent) async throws {
        let message = try createSyncMessage(for: content)
        let messageData = try JSONEncoder().encode(message)

        // 使用回调发送
        if let broadcast = onBroadcast {
            try await broadcast(messageData)
        }

        // 记录历史
        let deviceIDs = connectedDevices.map { $0.deviceID }
        let entry = ClipboardHistoryEntry(
            content: content,
            direction: .outgoing,
            targetDeviceIDs: deviceIDs
        )
        addToHistory(entry)

        lastSyncTime = Date()
        logger.info("📋 已广播剪贴板内容到 \(deviceIDs.count) 台设备")
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

        // 应用到本地剪贴板
        applyRemoteContent(content)

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
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: configKey)
        }
    }

    private static func loadConfiguration() -> ClipboardSyncConfiguration? {
        guard let data = UserDefaults.standard.data(forKey: "com.skybridge.clipboard.config"),
              let config = try? JSONDecoder().decode(ClipboardSyncConfiguration.self, from: data) else {
            return nil
        }
        return config
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    private static func loadHistory() -> [ClipboardHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: "com.skybridge.clipboard.history"),
              let history = try? JSONDecoder().decode([ClipboardHistoryEntry].self, from: data) else {
            return []
        }
        return history
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
