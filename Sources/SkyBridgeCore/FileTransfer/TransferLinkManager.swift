import Combine
import CryptoKit
import Darwin
import Foundation
import os.lock

@MainActor
public final class TransferLinkManager: ObservableObject, Sendable {
    @Published public var activeLinks: [TransferLink] = []
    @Published public var linkRequests: [TransferLinkRequest] = []
    @Published public var isServerRunning = false

    private enum LifecycleState: String {
        case idle
        case starting
        case running
        case stopping
    }

    private struct LinkAccessGrant: Sendable {
        let tokenHash: String
        let linkId: String
        let expiresAt: Date
    }

    private let serverPort: UInt16 = 8888
    private let linkStorage = TransferLinkStorage()
    private var cleanupTimer: AnyCancellable?
    private var httpServer: LocalFileTransferHTTPServer?
    private var lifecycleState: LifecycleState = .idle
    private var accessGrants: [String: LinkAccessGrant] = [:]

    public static let shared = TransferLinkManager()

    private init() {}

    public func start() async throws {
        try await ensureServerRunning()
    }

    public func stop() async {
        guard lifecycleState == .running || lifecycleState == .starting else { return }
        lifecycleState = .stopping
        httpServer?.stop()
        httpServer = nil
        cleanupTimer?.cancel()
        cleanupTimer = nil
        isServerRunning = false
        lifecycleState = .idle
    }

    public func cleanup() async {
        await stop()
        activeLinks.removeAll()
        linkRequests.removeAll()
        accessGrants.removeAll()
    }

    public func createTransferLink(
        for files: [URL],
        expirationTime: TimeInterval = 24 * 60 * 60,
        maxDownloads: Int = 10,
        requiresPassword: Bool = false
    ) async throws -> TransferLink {
        try await validateFiles(files)
        try await ensureServerRunning()

        let linkId = generateLinkId()
        let shareOrigin = try resolvedShareOrigin()
        let sharePath = "/link/\(linkId)"
        let password = requiresPassword ? generatePassword() : nil
        let transferLink = TransferLink(
            id: linkId,
            files: files,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(expirationTime),
            maxDownloads: maxDownloads,
            currentDownloads: 0,
            password: password,
            isActive: true,
            lastAccessedAt: nil,
            shareOrigin: shareOrigin,
            sharePath: sharePath
        )

        try await linkStorage.saveLink(transferLink)
        await syncActiveLinks()
        cleanupExpiredAccessGrants()
        return transferLink
    }

    public func getLink(by linkId: String) async -> TransferLink? {
        cleanupExpiredAccessGrants()
        guard let link = await linkStorage.getLink(by: linkId), link.isActive, !link.isExpired else {
            return nil
        }
        return link
    }

    public func validateLinkAccess(linkId: String, password: String? = nil) async -> Bool {
        guard let link = await getLink(by: linkId) else {
            return false
        }
        guard link.currentDownloads < link.maxDownloads else {
            return false
        }
        if let requiredPassword = link.password {
            return password == requiredPassword
        }
        return true
    }

    public func recordDownload(for linkId: String) async {
        guard var link = await linkStorage.getLink(by: linkId), link.isActive, !link.isExpired else {
            return
        }

        link.currentDownloads += 1
        link.lastAccessedAt = Date()
        if link.currentDownloads >= link.maxDownloads {
            link.isActive = false
        }

        try? await linkStorage.updateLink(link)
        if !link.isActive {
            NotificationCenter.default.post(name: .transferLinkExpired, object: nil, userInfo: ["linkId": link.id])
            revokeAccessGrants(for: link.id)
        }
        await syncActiveLinks()
        await stopServerIfIdle()
    }

    public func deactivateLink(_ linkId: String) async {
        guard var link = await linkStorage.getLink(by: linkId) else { return }
        link.isActive = false
        try? await linkStorage.updateLink(link)
        revokeAccessGrants(for: link.id)
        NotificationCenter.default.post(name: .transferLinkExpired, object: nil, userInfo: ["linkId": link.id])
        await syncActiveLinks()
        await stopServerIfIdle()
    }

    public func deleteLink(_ linkId: String) async {
        revokeAccessGrants(for: linkId)
        await linkStorage.deleteLink(linkId)
        await syncActiveLinks()
        await stopServerIfIdle()
    }

    public func getAllActiveLinks() async -> [TransferLink] {
        await linkStorage.getAllActiveLinks()
    }

    private func ensureServerRunning() async throws {
        switch lifecycleState {
        case .running:
            return
        case .starting:
            return
        case .stopping:
            await stop()
        case .idle:
            break
        }

        lifecycleState = .starting
        ensureCleanupTimer()

        let callbacks = LocalFileTransferHTTPServer.Callbacks(
            activeLinkCount: { [weak self] in
                await MainActor.run { self?.activeLinks.count ?? 0 }
            },
            lookupLink: { [weak self] linkID in
                await self?.getLink(by: linkID)
            },
            authorizePassword: { [weak self] linkID, password in
                await self?.issueAccessGrant(linkId: linkID, password: password)
            },
            validateAccessToken: { [weak self] linkID, token in
                await self?.validateAccessGrant(linkId: linkID, token: token) ?? false
            },
            recordDownload: { [weak self] linkID in
                await self?.recordDownload(for: linkID)
            }
        )

        for attempt in 0..<3 {
            let server = LocalFileTransferHTTPServer(callbacks: callbacks)
            do {
                try await server.start(port: serverPort)
                httpServer = server
                lifecycleState = .running
                isServerRunning = true
                return
            } catch {
                httpServer = nil
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 75_000_000)
                    continue
                }
                lifecycleState = .idle
                isServerRunning = false
                throw TransferLinkError.serverStartFailed
            }
        }
    }

    private func stopServerIfIdle() async {
        guard activeLinks.isEmpty else { return }
        await stop()
    }

    private func ensureCleanupTimer() {
        guard cleanupTimer == nil else { return }
        cleanupTimer = Timer.publish(every: 300, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.cleanupExpiredLinks()
                }
            }
    }

    private func cleanupExpiredLinks() async {
        cleanupExpiredAccessGrants()
        let allLinks = await linkStorage.getAllLinks()
        let expiredIDs = allLinks.filter { $0.isActive && $0.isExpired }.map(\.id)
        for linkID in expiredIDs {
            await deactivateLink(linkID)
        }
        await syncActiveLinks()
    }

    private func syncActiveLinks() async {
        activeLinks = await linkStorage.getAllActiveLinks().sorted { $0.createdAt > $1.createdAt }
    }

    private func issueAccessGrant(linkId: String, password: String) async -> LocalFileTransferHTTPServer.AccessGrant? {
        guard let link = await getLink(by: linkId),
              let requiredPassword = link.password,
              password == requiredPassword else {
            return nil
        }

        let token = base64URLRandom(bytes: 24)
        let hash = sha256Hex(token)
        let expiresAt = min(link.expiresAt, Date().addingTimeInterval(10 * 60))
        accessGrants[hash] = LinkAccessGrant(tokenHash: hash, linkId: linkId, expiresAt: expiresAt)
        cleanupExpiredAccessGrants()
        return .init(token: token, expiresAt: expiresAt)
    }

    private func validateAccessGrant(linkId: String, token: String) async -> Bool {
        cleanupExpiredAccessGrants()
        let hash = sha256Hex(token)
        guard let grant = accessGrants[hash], grant.linkId == linkId, grant.expiresAt > Date() else {
            return false
        }
        return await getLink(by: linkId) != nil
    }

    private func revokeAccessGrants(for linkId: String) {
        accessGrants = accessGrants.filter { $0.value.linkId != linkId }
    }

    private func cleanupExpiredAccessGrants() {
        let now = Date()
        accessGrants = accessGrants.filter { $0.value.expiresAt > now }
    }

    private func validateFiles(_ files: [URL]) async throws {
        for fileURL in files {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw TransferLinkError.fileNotFound(fileURL.path)
            }
            guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
                throw TransferLinkError.fileNotReadable(fileURL.path)
            }
        }
    }

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

    private func generatePassword() -> String {
        let characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<6).compactMap { _ in characters.randomElement() })
    }

    private func resolvedShareOrigin() throws -> String {
        if let ip = preferredInterfaceHost() {
            return "http://\(urlHost(ip)):\(serverPort)"
        }
        if let hostname = preferredHostname() {
            return "http://\(urlHost(hostname)):\(serverPort)"
        }
        throw TransferLinkError.unavailableShareAddress
    }

    private func preferredInterfaceHost() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ipv4: [String] = []
        var ipv6: [String] = []

        for pointer in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr else { continue }
            let family = address.pointee.sa_family
            if family != UInt8(AF_INET) && family != UInt8(AF_INET6) {
                continue
            }
            let flags = Int32(interface.ifa_flags)
            if (flags & IFF_LOOPBACK) != 0 { continue }
            if (flags & IFF_UP) == 0 { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let candidate = decodeCString(hostname)
            guard isShareableIPAddress(candidate) else { continue }
            if family == UInt8(AF_INET) {
                ipv4.append(candidate)
            } else {
                ipv6.append(candidate)
            }
        }

        return ipv4.first ?? ipv6.first
    }

    private func preferredHostname() -> String? {
        let rawCandidates = [
            ProcessInfo.processInfo.hostName,
            Host.current().name,
            Host.current().localizedName
        ]
        let candidates = rawCandidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for host in candidates {
            for variant in hostnameVariants(for: host) {
                guard isShareableHostname(variant), hostResolvesToShareableAddress(variant) else { continue }
                return variant
            }
        }
        return nil
    }

    private func hostnameVariants(for host: String) -> [String] {
        var variants = [host]
        if !host.contains(".") {
            variants.append("\(host).local")
        }
        return Array(NSOrderedSet(array: variants)) as? [String] ?? variants
    }

    private func isShareableHostname(_ host: String) -> Bool {
        let normalized = host.lowercased()
        guard normalized != "localhost" else { return false }
        guard !normalized.hasPrefix("localhost.") else { return false }
        guard !normalized.contains(" ") else { return false }
        return true
    }

    private func hostResolvesToShareableAddress(_ host: String) -> Bool {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var resultPointer: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &resultPointer)
        guard status == 0, let first = resultPointer else { return false }
        defer { freeaddrinfo(first) }

        for pointer in sequence(first: first, next: { $0.pointee.ai_next }) {
            let family = pointer.pointee.ai_family
            if family == AF_INET {
                var address = UnsafeRawPointer(pointer.pointee.ai_addr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count))
                let candidate = decodeCString(buffer)
                if isShareableIPAddress(candidate) {
                    return true
                }
            } else if family == AF_INET6 {
                var address = UnsafeRawPointer(pointer.pointee.ai_addr).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count))
                let candidate = decodeCString(buffer)
                if isShareableIPAddress(candidate) {
                    return true
                }
            }
        }
        return false
    }

    private func isShareableIPAddress(_ address: String) -> Bool {
        let normalized = address.lowercased()
        guard !normalized.isEmpty else { return false }
        guard normalized != "::1", normalized != "0:0:0:0:0:0:0:1" else { return false }
        guard !normalized.hasPrefix("127.") else { return false }
        guard !normalized.hasPrefix("fe80:") else { return false }
        guard !normalized.contains("%") else { return false }
        return true
    }

    private func urlHost(_ host: String) -> String {
        if host.contains(":"), !host.hasPrefix("[") {
            return "[\(host)]"
        }
        return host
    }

    private func base64URLRandom(bytes: Int) -> String {
        Data((0..<bytes).map { _ in UInt8.random(in: 0...255) })
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func decodeCString(_ buffer: [CChar]) -> String {
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        let bytes = buffer[..<end].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func sha256Hex(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

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
    public let shareOrigin: String
    public let sharePath: String

    public var shareUrl: String {
        "\(shareOrigin)\(sharePath)"
    }

    public var shareURL: URL? {
        URL(string: shareUrl)
    }

    public var isExpired: Bool {
        Date() > expiresAt
    }

    public var remainingDownloads: Int {
        max(0, maxDownloads - currentDownloads)
    }
}

public struct TransferLinkRequest: Codable, Identifiable, Sendable {
    public let id: String
    public let linkId: String
    public let requestedAt: Date
    public let clientIP: String
    public let userAgent: String?
}

public enum TransferLinkError: Error, LocalizedError {
    case fileNotFound(String)
    case fileNotReadable(String)
    case linkExpired
    case linkNotFound
    case serverStartFailed
    case invalidPassword
    case unavailableShareAddress

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
        case .unavailableShareAddress:
            return "当前网络环境无法生成可分享的地址"
        }
    }
}

private final class TransferLinkStorage: Sendable {
    private let storageQueue = DispatchQueue(label: "transfer.link.storage", qos: .utility)
    private let links = OSAllocatedUnfairLock(initialState: [String: TransferLink]())

    func saveLink(_ link: TransferLink) async throws {
        await withCheckedContinuation { continuation in
            storageQueue.async {
                self.links.withLock { $0[link.id] = link }
                continuation.resume()
            }
        }
    }

    func getLink(by id: String) async -> TransferLink? {
        await withCheckedContinuation { continuation in
            storageQueue.async {
                continuation.resume(returning: self.links.withLock { $0[id] })
            }
        }
    }

    func getAllLinks() async -> [TransferLink] {
        await withCheckedContinuation { continuation in
            storageQueue.async {
                continuation.resume(returning: self.links.withLock { Array($0.values) })
            }
        }
    }

    func updateLink(_ link: TransferLink) async throws {
        await withCheckedContinuation { continuation in
            storageQueue.async {
                self.links.withLock { $0[link.id] = link }
                continuation.resume()
            }
        }
    }

    func deleteLink(_ id: String) async {
        await withCheckedContinuation { continuation in
            storageQueue.async {
                self.links.withLock { _ = $0.removeValue(forKey: id) }
                continuation.resume()
            }
        }
    }

    func getAllActiveLinks() async -> [TransferLink] {
        await withCheckedContinuation { continuation in
            storageQueue.async {
                continuation.resume(returning: self.links.withLock {
                    Array($0.values.filter { $0.isActive && !$0.isExpired })
                })
            }
        }
    }
}
