import Foundation
import Network
import CryptoKit
import Combine
import os.lock

/// 传输链接管理器 - 负责创建、管理和验证文件传输链接
/// 采用Swift 6.2最佳实践和Apple Silicon优化
@MainActor
public final class TransferLinkManager: ObservableObject, Sendable {
    
 // MARK: - 发布属性
    
    @Published public var activeLinks: [TransferLink] = []
    @Published public var linkRequests: [TransferLinkRequest] = []
    @Published public var isServerRunning = false
    
 // MARK: - 私有属性
    
    private var httpServer: NWListener?
    private let serverPort: UInt16 = 8888
    private let linkStorage = TransferLinkStorage()
    private var transferLinkCancellables = Set<AnyCancellable>()
    
 /// 使用Swift 6.2的并发安全队列进行网络操作
    private let networkQueue = DispatchQueue(label: "transfer.link.network", qos: .userInitiated, attributes: .concurrent)
    
 // MARK: - 生命周期管理属性
    private var isStarted = false
    
 // MARK: - 单例
    
    public static let shared = TransferLinkManager()
    
    private init() {
        setupLinkCleanupTimer()
    }
    
 // MARK: - 生命周期管理方法
    
 /// 启动传输链接管理器
 /// 初始化HTTP服务器和链接清理定时器
    public func start() async throws {
        guard !isStarted else {
            SkyBridgeLogger.network.debugOnly("⚠️ TransferLinkManager 已经启动")
            return
        }
        
        SkyBridgeLogger.network.debugOnly("🚀 启动 TransferLinkManager")
        
 // 启动HTTP服务器
        try await startHttpServer()
        
 // 设置链接清理定时器
        setupLinkCleanupTimer()
        
 // 标记为已启动
        isStarted = true
        
        SkyBridgeLogger.network.debugOnly("✅ TransferLinkManager 启动完成")
    }
    
 /// 停止传输链接管理器
 /// 停止HTTP服务器并清理资源
    public func stop() async {
        guard isStarted else {
            SkyBridgeLogger.network.debugOnly("⚠️ TransferLinkManager 尚未启动")
            return
        }
        
        SkyBridgeLogger.network.debugOnly("🛑 停止 TransferLinkManager")
        
 // 停止HTTP服务器
        httpServer?.cancel()
        httpServer = nil
        isServerRunning = false
        
 // 清理取消订阅
        transferLinkCancellables.removeAll()
        
 // 标记为已停止
        isStarted = false
        
        SkyBridgeLogger.network.debugOnly("✅ TransferLinkManager 停止完成")
    }
    
 /// 清理传输链接管理器
 /// 清理所有活跃链接和请求
    public func cleanup() async {
        SkyBridgeLogger.network.debugOnly("🧹 清理 TransferLinkManager")
        
 // 停止管理器
        if isStarted {
            await stop()
        }
        
 // 清理所有活跃链接
        activeLinks.removeAll()
        linkRequests.removeAll()
        
        SkyBridgeLogger.network.debugOnly("✅ TransferLinkManager 清理完成")
    }
    
 // MARK: - 公共方法
    
 /// 创建传输链接
 /// - Parameters:
 /// - files: 要分享的文件URL数组
 /// - expirationTime: 链接过期时间（默认24小时）
 /// - maxDownloads: 最大下载次数（默认10次）
 /// - requiresPassword: 是否需要密码保护
 /// - Returns: 生成的传输链接
    public func createTransferLink(
        for files: [URL],
        expirationTime: TimeInterval = 24 * 60 * 60, // 24小时
        maxDownloads: Int = 10,
        requiresPassword: Bool = false
    ) async throws -> TransferLink {
        
 // 验证文件是否存在且可访问
        try await validateFiles(files)
        
 // 生成唯一链接ID
        let linkId = generateLinkId()
        
 // 生成访问密码（如果需要）
        let password = requiresPassword ? generatePassword() : nil
        
 // 创建传输链接对象
        let transferLink = TransferLink(
            id: linkId,
            files: files,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(expirationTime),
            maxDownloads: maxDownloads,
            currentDownloads: 0,
            password: password,
            isActive: true
        )
        
 // 保存链接到存储
        try await linkStorage.saveLink(transferLink)
        
 // 添加到活跃链接列表
        activeLinks.append(transferLink)
        
 // 启动HTTP服务器（如果尚未启动）
        if !isServerRunning {
            try await startHttpServer()
        }
        
        SkyBridgeLogger.network.debugOnly("✅ 创建传输链接成功: \(transferLink.shareUrl)")
        return transferLink
    }
    
 /// 获取链接信息
 /// - Parameter linkId: 链接ID
 /// - Returns: 传输链接对象
    public func getLink(by linkId: String) async -> TransferLink? {
        return await linkStorage.getLink(by: linkId)
    }
    
 /// 验证链接访问
 /// - Parameters:
 /// - linkId: 链接ID
 /// - password: 访问密码（可选）
 /// - Returns: 是否验证成功
    public func validateLinkAccess(linkId: String, password: String? = nil) async -> Bool {
        guard let link = await getLink(by: linkId) else {
            return false
        }
        
 // 检查链接是否过期
        if link.isExpired {
            return false
        }
        
 // 检查下载次数是否超限
        if link.currentDownloads >= link.maxDownloads {
            return false
        }
        
 // 检查密码（如果需要）
        if let requiredPassword = link.password {
            return password == requiredPassword
        }
        
        return true
    }
    
 /// 记录下载访问
 /// - Parameter linkId: 链接ID
    public func recordDownload(for linkId: String) async {
        guard let linkIndex = activeLinks.firstIndex(where: { $0.id == linkId }) else {
            return
        }
        
        activeLinks[linkIndex].currentDownloads += 1
        activeLinks[linkIndex].lastAccessedAt = Date()
        
 // 更新存储
        try? await linkStorage.updateLink(activeLinks[linkIndex])
        
 // 检查是否达到最大下载次数
        if activeLinks[linkIndex].currentDownloads >= activeLinks[linkIndex].maxDownloads {
            await deactivateLink(linkId)
        }
    }
    
 /// 停用链接
 /// - Parameter linkId: 链接ID
    public func deactivateLink(_ linkId: String) async {
        guard let linkIndex = activeLinks.firstIndex(where: { $0.id == linkId }) else {
            return
        }
        
        activeLinks[linkIndex].isActive = false
        
 // 更新存储
        try? await linkStorage.updateLink(activeLinks[linkIndex])
        
 // 从活跃列表中移除
        activeLinks.remove(at: linkIndex)
    }
    
 /// 删除链接
 /// - Parameter linkId: 链接ID
    public func deleteLink(_ linkId: String) async {
        await deactivateLink(linkId)
        await linkStorage.deleteLink(linkId)
    }
    
 /// 获取所有活跃链接
    public func getAllActiveLinks() async -> [TransferLink] {
        return await linkStorage.getAllActiveLinks()
    }
    
 // MARK: - 私有方法
    
 /// 验证文件是否存在且可访问
    private func validateFiles(_ files: [URL]) async throws {
        for fileUrl in files {
            guard FileManager.default.fileExists(atPath: fileUrl.path) else {
                throw TransferLinkError.fileNotFound(fileUrl.path)
            }
            
            guard FileManager.default.isReadableFile(atPath: fileUrl.path) else {
                throw TransferLinkError.fileNotReadable(fileUrl.path)
            }
        }
    }
    
 /// 生成唯一链接ID
    private func generateLinkId() -> String {
        let uuid = UUID().uuidString
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let randomBytes = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        let randomString = randomBytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        
        return "\(timestamp)-\(randomString)-\(uuid.prefix(8))"
    }
    
 /// 生成访问密码
    private func generatePassword() -> String {
        let characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<6).map { _ in characters.randomElement()! })
    }
    
 /// 启动HTTP服务器
    private func startHttpServer() async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        httpServer = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: serverPort))
        
        httpServer?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                await self?.handleNewConnection(connection)
            }
        }
        
        httpServer?.start(queue: .global(qos: .utility))
        isServerRunning = true
        
        SkyBridgeLogger.network.debugOnly("🌐 传输链接HTTP服务器已启动，端口: \(serverPort)")
    }
    
 /// 处理新的HTTP连接
    private func handleNewConnection(_ connection: NWConnection) async {
        connection.start(queue: .global())
        
 // 接收HTTP请求
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                if let data = data, !data.isEmpty {
                    await self?.processHttpRequest(data, connection: connection)
                }
                
                if isComplete || error != nil {
                    connection.cancel()
                }
            }
        }
    }
    
 /// 处理HTTP请求
    private func processHttpRequest(_ data: Data, connection: NWConnection) async {
        guard let requestString = String(data: data, encoding: .utf8) else {
            await sendHttpResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }
        
 // 解析HTTP请求
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            await sendHttpResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }
        
        let components = requestLine.components(separatedBy: " ")
        guard components.count >= 2 else {
            await sendHttpResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }
        
        let method = components[0]
        let path = components[1]
        
 // 处理不同的请求路径
        if method == "GET" && path.hasPrefix("/link/") {
            let linkId = String(path.dropFirst(6)) // 移除 "/link/" 前缀
            await handleLinkRequest(linkId: linkId, connection: connection)
        } else if method == "GET" && path == "/status" {
            await handleStatusRequest(connection: connection)
        } else {
            await sendHttpResponse(connection: connection, statusCode: 404, body: "Not Found")
        }
    }
    
 /// 处理链接请求
    private func handleLinkRequest(linkId: String, connection: NWConnection) async {
        guard let link = await getLink(by: linkId) else {
            await sendHttpResponse(connection: connection, statusCode: 404, body: "Link not found")
            return
        }
        
 // 验证链接访问权限
        let isValid = await validateLinkAccess(linkId: linkId)
        guard isValid else {
            await sendHttpResponse(connection: connection, statusCode: 403, body: "Link expired or access denied")
            return
        }
        
 // 生成文件列表HTML
        let html = generateFileListHtml(for: link)
        await sendHttpResponse(connection: connection, statusCode: 200, body: html, contentType: "text/html")
        
 // 记录访问
        await recordDownload(for: linkId)
    }
    
 /// 处理状态请求
    private func handleStatusRequest(connection: NWConnection) async {
        let status: [String: Any] = [
            "server": "SkyBridge Transfer Link Server",
            "version": "1.0.0",
            "active_links": activeLinks.count,
            "uptime": Int(Date().timeIntervalSince1970)
        ]
        
        let jsonData = try? JSONSerialization.data(withJSONObject: status)
        let jsonString = jsonData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        
        await sendHttpResponse(connection: connection, statusCode: 200, body: jsonString, contentType: "application/json")
    }
    
 /// 发送HTTP响应
    private func sendHttpResponse(connection: NWConnection, statusCode: Int, body: String, contentType: String = "text/plain") async {
        let statusText = getHttpStatusText(statusCode)
        let response = """
        HTTP/1.1 \(statusCode) \(statusText)\r
        Content-Type: \(contentType); charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        
        if let responseData = response.data(using: .utf8) {
            connection.send(content: responseData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
    
 /// 获取HTTP状态文本
    private func getHttpStatusText(_ statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
    
 /// 生成文件列表HTML
    private func generateFileListHtml(for link: TransferLink) -> String {
        let fileListItems = link.files.map { fileUrl in
            let fileName = fileUrl.lastPathComponent
            let fileSize = getFileSize(fileUrl)
            return """
            <li class="file-item">
                <div class="file-info">
                    <span class="file-name">\(fileName)</span>
                    <span class="file-size">\(formatFileSize(fileSize))</span>
                </div>
                <a href="/download/\(link.id)/\(fileName)" class="download-btn">下载</a>
            </li>
            """
        }.joined()
        
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>SkyBridge 文件传输</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 0; padding: 20px; background: #f5f5f7; }
                .container { max-width: 600px; margin: 0 auto; background: white; border-radius: 12px; padding: 30px; box-shadow: 0 4px 20px rgba(0,0,0,0.1); }
                .header { text-align: center; margin-bottom: 30px; }
                .title { color: #1d1d1f; font-size: 28px; font-weight: 600; margin: 0; }
                .subtitle { color: #86868b; font-size: 16px; margin: 10px 0 0 0; }
                .file-list { list-style: none; padding: 0; margin: 0; }
                .file-item { display: flex; justify-content: space-between; align-items: center; padding: 15px 0; border-bottom: 1px solid #f0f0f0; }
                .file-item:last-child { border-bottom: none; }
                .file-info { flex: 1; }
                .file-name { display: block; font-weight: 500; color: #1d1d1f; margin-bottom: 4px; }
                .file-size { font-size: 14px; color: #86868b; }
                .download-btn { background: #007aff; color: white; text-decoration: none; padding: 8px 16px; border-radius: 6px; font-size: 14px; font-weight: 500; }
                .download-btn:hover { background: #0056cc; }
                .info { background: #f0f8ff; padding: 15px; border-radius: 8px; margin-top: 20px; font-size: 14px; color: #666; }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="header">
                    <h1 class="title">文件传输</h1>
                    <p class="subtitle">点击下载按钮获取文件</p>
                </div>
                <ul class="file-list">
                    \(fileListItems)
                </ul>
                <div class="info">
                    <p>📱 此链接由 SkyBridge Compass Pro 生成</p>
                    <p>⏰ 过期时间: \(formatDate(link.expiresAt))</p>
                    <p>📊 剩余下载次数: \(link.maxDownloads - link.currentDownloads)</p>
                </div>
            </div>
        </body>
        </html>
        """
    }
    
 /// 获取文件大小
    private func getFileSize(_ url: URL) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
    
 /// 格式化文件大小
    private func formatFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
    
 /// 格式化日期
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }
    
 /// 设置链接清理定时器
    private func setupLinkCleanupTimer() {
        Timer.publish(every: 300, on: .main, in: .common) // 每5分钟检查一次
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.cleanupExpiredLinks()
                }
            }
            .store(in: &transferLinkCancellables)
    }
    
 /// 清理过期链接
    private func cleanupExpiredLinks() async {
        let expiredLinks = activeLinks.filter { $0.isExpired }
        
        for link in expiredLinks {
            await deactivateLink(link.id)
        }
        
        if !expiredLinks.isEmpty {
            SkyBridgeLogger.network.debugOnly("🧹 清理了 \(expiredLinks.count) 个过期链接")
        }
    }
}

// MARK: - 传输链接数据模型

/// 传输链接结构体 - 符合Swift 6.2 Sendable协议
public struct TransferLink: Codable, Identifiable, Sendable {
    public let id: String
    public let files: [URL]
    public let createdAt: Date
    public let expiresAt: Date
    public let maxDownloads: Int
    public var currentDownloads: Int
    public let password: String?
    public var isActive: Bool
    public var lastAccessedAt: Date?
    
 /// 分享链接URL
    public var shareUrl: String {
        return "http://localhost:8888/link/\(id)"
    }
    
 /// 检查链接是否过期
    public var isExpired: Bool {
        return Date() > expiresAt
    }
    
 /// 剩余下载次数
    public var remainingDownloads: Int {
        return max(0, maxDownloads - currentDownloads)
    }
}

/// 传输链接请求结构体 - 符合Swift 6.2 Sendable协议
public struct TransferLinkRequest: Codable, Identifiable, Sendable {
    public let id: String
    public let linkId: String
    public let requestedAt: Date
    public let clientIP: String
    public let userAgent: String?
}

/// 传输链接错误
public enum TransferLinkError: Error, LocalizedError {
    case fileNotFound(String)
    case fileNotReadable(String)
    case linkExpired
    case linkNotFound
    case serverStartFailed
    case invalidPassword
    
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "文件未找到: \(path)"
        case .fileNotReadable(let path):
            return "文件不可读: \(path)"
        case .linkExpired:
            return "链接已过期"
        case .linkNotFound:
            return "链接不存在"
        case .serverStartFailed:
            return "服务器启动失败"
        case .invalidPassword:
            return "密码错误"
        }
    }
}

// MARK: - 传输链接存储

/// 传输链接存储类 - 负责链接的持久化存储
/// 采用Swift 6.2并发安全设计
private final class TransferLinkStorage: Sendable {
    private let storageQueue = DispatchQueue(label: "transfer.link.storage", qos: .utility)
    private let links = OSAllocatedUnfairLock(initialState: [String: TransferLink]())
    
 /// 保存链接到存储
    func saveLink(_ link: TransferLink) async throws {
        await withCheckedContinuation { continuation in
            storageQueue.async {
                self.links.withLock { links in
                    links[link.id] = link
                }
                continuation.resume()
            }
        }
    }
    
 /// 根据ID获取链接
    func getLink(by id: String) async -> TransferLink? {
        return await withCheckedContinuation { continuation in
            storageQueue.async {
                let link = self.links.withLock { links in
                    return links[id]
                }
                continuation.resume(returning: link)
            }
        }
    }
    
 /// 更新链接信息
    func updateLink(_ link: TransferLink) async throws {
        await withCheckedContinuation { continuation in
            storageQueue.async {
                self.links.withLock { links in
                    links[link.id] = link
                }
                continuation.resume()
            }
        }
    }
    
 /// 删除链接
    func deleteLink(_ id: String) async {
        await withCheckedContinuation { continuation in
            storageQueue.async {
                self.links.withLock { links in
                    _ = links.removeValue(forKey: id)
                }
                continuation.resume()
            }
        }
    }
    
 /// 获取所有活跃链接
    func getAllActiveLinks() async -> [TransferLink] {
        return await withCheckedContinuation { continuation in
            storageQueue.async {
                let activeLinks = self.links.withLock { links in
                    return Array(links.values.filter { $0.isActive && !$0.isExpired })
                }
                continuation.resume(returning: activeLinks)
            }
        }
    }
}
