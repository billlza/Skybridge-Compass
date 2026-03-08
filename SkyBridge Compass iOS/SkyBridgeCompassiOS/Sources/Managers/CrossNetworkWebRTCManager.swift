import Foundation
import CryptoKit
import OSLog
#if canImport(UIKit)
import UIKit
#endif

// MARK: - iOS-local server config (file-local, to avoid target membership issues)

// MARK: - iOS-local crypto helpers (file-local, to avoid target membership issues)

/// Minimal SHA-256 helper used by WebRTC chunking / integrity checks.
@available(iOS 17.0, *)
private enum CrossNetworkCryptoCompat {
    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

/// Deterministic SHA-256 Merkle tree helper for chunk root computation.
@available(iOS 17.0, *)
private enum CrossNetworkMerkleCompat {
    /// Deterministic SHA-256 Merkle root:
    /// - Leaves are per-chunk SHA-256 digests (32B), ordered by chunkIndex.
    /// - Parent = SHA256(left || right)
    /// - Odd count: duplicate last.
    static func root(leaves: [Data]) -> Data? {
        guard !leaves.isEmpty else { return nil }
        guard leaves.allSatisfy({ $0.count == 32 }) else { return nil }

        var level = leaves
        while level.count > 1 {
            var next: [Data] = []
            next.reserveCapacity((level.count + 1) / 2)
            var i = 0
            while i < level.count {
                let left = level[i]
                let right = (i + 1 < level.count) ? level[i + 1] : left
                next.append(CrossNetworkCryptoCompat.sha256(left + right))
                i += 2
            }
            level = next
        }
        return level.first
    }
}

/// Auth helper for Merkle root verification (HMAC over deterministic preimage).
@available(iOS 17.0, *)
private enum CrossNetworkMerkleAuthCompat {
    static let signatureAlgV1 = "hmac-sha256-session-v1"

    // Must match Android MerkleRootAuthV1.preimage
    static func preimage(transferId: String, merkleRoot: Data, fileSha256: Data?) -> Data {
        var out = Data()
        out.append(Data("SkyBridge-MerkleRoot|v1|".utf8))

        let tid = transferId.data(using: .utf8) ?? Data()
        out.append(u16le(tid.count))
        out.append(tid)

        out.append(u16le(merkleRoot.count))
        out.append(merkleRoot)

        let f = fileSha256 ?? Data()
        out.append(u16le(f.count))
        out.append(f)
        return out
    }

    static func hmacSha256(key: Data, data: Data) -> Data {
        let k = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: k)
        return Data(mac)
    }

    private static func u16le(_ v: Int) -> Data {
        var x = UInt16(max(0, min(65535, v))).littleEndian
        return Data(bytes: &x, count: 2)
    }
}

@available(iOS 17.0, *)
private enum CrossNetworkServerConfig {
    private static func environmentValue(_ name: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func environmentValue(_ name: String, default defaultValue: String) -> String {
        guard let value = environmentValue(name), !value.isEmpty else { return defaultValue }
        return value
    }

    private static func environmentList(_ name: String, default defaultValue: [String]) -> [String] {
        guard let raw = ProcessInfo.processInfo.environment[name] else {
            return defaultValue
        }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static var signalingWebSocketURL: String {
        environmentValue("SKYBRIDGE_SIGNALING_WEBSOCKET_URL", default: "wss://api.nebula-technologies.net/ws")
    }

    static var signalingServerURL: String {
        environmentValue("SKYBRIDGE_SIGNALING_SERVER_URL", default: "https://api.nebula-technologies.net")
    }

    static var stunURL: String {
        environmentValue("SKYBRIDGE_STUN_URL", default: "stun:54.92.79.99:3478")
    }

    static var turnURL: String {
        environmentValue("SKYBRIDGE_TURN_URL", default: "turn:54.92.79.99:3478?transport=udp")
    }

    static var turnTLSURL: String {
        environmentValue("SKYBRIDGE_TURN_TLS_URL", default: "turns:54.92.79.99:5349?transport=tcp")
    }

    static var turnURLs: [String] {
        environmentList("SKYBRIDGE_TURN_URLS", default: [turnTLSURL, turnURL])
    }

    static var clientAPIKey: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_CLIENT_API_KEY"] ?? "skybridge-client-v1"
    }

    static func dynamicICEConfig() async -> WebRTCSession.ICEConfig {
        let creds = await CrossNetworkTURNCredentialService.shared.getCredentials()
        let turnUsername = normalizedValue(creds.username)
        let turnPassword = normalizedValue(creds.password)
        let turnURIs = preferredTurnURIs(from: creds.uris, fallback: turnURLs)
        let shouldUseTURN = !turnUsername.isEmpty && !turnPassword.isEmpty && !turnURIs.isEmpty

        return WebRTCSession.ICEConfig(
            stunURL: stunURL,
            turnURLs: shouldUseTURN ? turnURIs : [],
            turnUsername: shouldUseTURN ? turnUsername : "",
            turnPassword: shouldUseTURN ? turnPassword : ""
        )
    }

    private static func normalizedValue(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func normalizedTurnURIs(_ uris: [String]) -> [String] {
        var seen = Set<String>()
        return uris
            .map { normalizedValue($0) }
            .filter { uri in
                let lower = uri.lowercased()
                guard lower.hasPrefix("turn:") || lower.hasPrefix("turns:") else {
                    return false
                }
                if seen.contains(lower) {
                    return false
                }
                seen.insert(lower)
                return true
            }
    }

    fileprivate static func turnPriority(_ uri: String) -> Int {
        let lower = uri.lowercased()
        if lower.hasPrefix("turns:") { return 0 }
        if lower.contains("transport=tcp") { return 1 }
        return 2
    }

    fileprivate static func preferredTurnURIs(from uris: [String], fallback: [String]) -> [String] {
        let candidates = normalizedTurnURIs(uris)
        let effective = candidates.isEmpty ? normalizedTurnURIs(fallback) : candidates
        return effective
            .enumerated()
            .sorted { lhs, rhs in
                let lp = turnPriority(lhs.element)
                let rp = turnPriority(rhs.element)
                if lp == rp { return lhs.offset < rhs.offset }
                return lp < rp
            }
            .map(\.element)
    }
}

@available(iOS 17.0, *)
private actor CrossNetworkTURNCredentialService {
    static let shared = CrossNetworkTURNCredentialService()

    private let logger = Logger(subsystem: "com.skybridge.turn", category: "CrossNetwork-iOS")
    private var cached: TURNCredentials?
    private let buffer: TimeInterval = 300

    struct TURNCredentials: Sendable, Codable {
        let username: String
        let password: String
        let ttl: Int
        let uris: [String]
        let expiresAt: Date

        func isValid(buffer: TimeInterval) -> Bool {
            Date().addingTimeInterval(buffer) < expiresAt
        }
    }

    private struct ServerResponse: Codable {
        let username: String
        let password: String
        let ttl: Int
        let uris: [String]?
        let expiresAt: Int?
        let mode: String?
    }

    func getCredentials() async -> TURNCredentials {
        if let cached, cached.isValid(buffer: buffer) { return cached }
        do {
            let fresh = try await fetchFromServer()
            self.cached = fresh
            return fresh
        } catch {
            logger.warning("⚠️ TURN credentials fetch failed; falling back. err=\(error.localizedDescription, privacy: .public)")
            return fallback()
        }
    }

    private func fetchFromServer() async throws -> TURNCredentials {
        guard let url = URL(string: "\(CrossNetworkServerConfig.signalingServerURL)/api/turn/credentials") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(CrossNetworkServerConfig.clientAPIKey, forHTTPHeaderField: "X-API-Key")
        if let deviceId = resolvedDeviceIdentifier() {
            req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        }
        req.timeoutInterval = 10

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "TURN", code: http.statusCode, userInfo: ["body": body])
        }
        let decoded = try JSONDecoder().decode(ServerResponse.self, from: data)
        let ttl = max(60, decoded.ttl)
        let expiresAt: Date
        if let expiresAtEpoch = decoded.expiresAt, expiresAtEpoch > 0 {
            expiresAt = Date(timeIntervalSince1970: TimeInterval(expiresAtEpoch))
        } else {
            expiresAt = Date().addingTimeInterval(TimeInterval(ttl))
        }
        let uris = CrossNetworkServerConfig.preferredTurnURIs(
            from: decoded.uris ?? [],
            fallback: CrossNetworkServerConfig.turnURLs
        )
        return TURNCredentials(
            username: decoded.username,
            password: decoded.password,
            ttl: ttl,
            uris: uris,
            expiresAt: expiresAt
        )
    }

    private func fallback() -> TURNCredentials {
        // Safe fallback: do not embed secrets in the app.
        let username = (ProcessInfo.processInfo.environment["SKYBRIDGE_TURN_USERNAME"] ?? "skybridge")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let password = (ProcessInfo.processInfo.environment["SKYBRIDGE_TURN_PASSWORD"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !username.isEmpty, !password.isEmpty else {
            logger.warning("⚠️ TURN fallback credentials incomplete, will use STUN-only.")
            return TURNCredentials(
                username: "",
                password: "",
                ttl: 3600,
                uris: [],
                expiresAt: Date().addingTimeInterval(3600)
            )
        }

        return TURNCredentials(
            username: username,
            password: password,
            ttl: 3600,
            uris: CrossNetworkServerConfig.turnURLs,
            expiresAt: Date().addingTimeInterval(3600)
        )
    }

    private func resolvedDeviceIdentifier() -> String? {
        let envID = ProcessInfo.processInfo.environment["SKYBRIDGE_DEVICE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !envID.isEmpty {
            return envID
        }
        let keychainID = KeychainManager.shared.getOrGenerateDeviceId()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return keychainID.isEmpty ? nil : keychainID
    }
}

/// iOS 跨网连接管理器（WebRTC DataChannel + ICE + WebSocket signaling）
///
/// 目标：让 iPhone 在 P2P/Bonjour 不可用时，仍可通过扫码（skybridge://connect/…）完成跨网连接。
@available(iOS 17.0, *)
@MainActor
public final class CrossNetworkWebRTCManager: ObservableObject {
    
    public enum State: Sendable, Equatable {
        case idle
        case connecting(sessionId: String)
        case connected(sessionId: String)
        case failed(String)
    }

    public enum Readiness: Sendable, Equatable {
        case idle
        case transportReady(sessionId: String)
        case handshakeComplete(sessionId: String, negotiatedSuite: String)
    }
    
    @Published public private(set) var state: State = .idle
    @Published public private(set) var readiness: Readiness = .idle
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastScreenData: ScreenData?
    @Published public private(set) var lastRekeyEvent: String?
    @Published public private(set) var remoteDeviceName: String?
    @Published public private(set) var remoteDeviceId: String?
    @Published public private(set) var localConnectionCode: String?
    private static let shortCodeAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    private static let shortCodeAllowedCharacters = Set(shortCodeAlphabet)
    
    private var signaling: WebSocketSignalingClient?
    private let signalingRetryController = SignalingRetryController()
    private var session: WebRTCSession?
    private var currentSessionId: String?
    private let localDeviceId: String = KeychainManager.shared.getOrGenerateDeviceId()
    private var handshakeDriver: HandshakeDriver?
    private var handshakePeerId: String?
    private var sessionKeys: SessionKeys?
    private var inboundQueue: InboundChunkQueue?
    private var receiveTask: Task<Void, Never>?
    private var currentRole: WebRTCSession.Role?
    private var handshakeStartedSessionIds: Set<String> = []
    private var rekeyInProgressSessionIds: Set<String> = []
    private var rekeyCompletedSessionIds: Set<String> = []
    private var strictPQCRequestedBySessionId: [String: Bool] = [:]
    private var lastPairingIdentityExchangeSentAtByPeerId: [String: Date] = [:]
    private var connectionCodeBootstrapTask: Task<Void, Never>?
    private var latestLocalOfferBySessionId: [String: String] = [:]
    private var latestLocalAnswerBySessionId: [String: String] = [:]
    private var localICECandidatesBySessionId: [String: [WebRTCSignalingEnvelope.Payload]] = [:]
    private var joinHeartbeatTask: Task<Void, Never>?
    private var offerResendTask: Task<Void, Never>?
    private var remoteDesktopHeartbeatTask: Task<Void, Never>?
    
    // File transfer waiters (transferId|op|chunkIndex -> continuation)
    private var fileTransferWaiters: [String: CheckedContinuation<CrossNetworkFileTransferMessage, Error>] = [:]

    private struct InboundFileTransferState {
        let transferId: String
        let fileName: String
        let fileSize: Int64
        let chunkSize: Int
        let totalChunks: Int
        let senderDeviceId: String
        let senderDeviceName: String
        let tempURL: URL
        let finalURL: URL
        let handle: FileHandle
        var receivedBytes: Int64
        var completeRequestedAt: Date? = nil
        var expectedFileSha256: Data? = nil
        var expectedMerkleRoot: Data? = nil
        var expectedMerkleSig: Data? = nil
        var expectedMerkleSigAlg: String? = nil
        var chunkHashes: [Int: Data] = [:]
    }
    private var inboundFileTransfers: [String: InboundFileTransferState] = [:]
    private var inboundFileTransferCompleteTimers: [String: Task<Void, Never>] = [:]
    
    private enum FileTransferWaitError: LocalizedError {
        case timeout
        case cancelled
        
        var errorDescription: String? {
            switch self {
            case .timeout: return "跨网文件传输等待超时"
            case .cancelled: return "跨网文件传输已取消"
            }
        }
    }
    
    public static let instance = CrossNetworkWebRTCManager()
    private init() {}

    public var isTransportReady: Bool {
        switch readiness {
        case .transportReady, .handshakeComplete:
            return true
        case .idle:
            return false
        }
    }

    public var isHandshakeComplete: Bool {
        if case .handshakeComplete = readiness { return true }
        return false
    }
    
    public func connect(fromScannedString string: String) async {
        do {
            let payload = try parseSkybridgeConnectLink(string)
            try await connect(from: payload)
        } catch {
            let msg = error.localizedDescription
            lastError = msg
            state = .failed(msg)
            readiness = .idle
        }
    }
    
    /// 通过 6 位智能连接码连接（与 macOS 侧“智能连接码”保持一致）
    /// - Note: 当前实现直接把 code 当作 WebRTC sessionId（同 signaling room）。
    public func connect(withCode rawCode: String) async {
        do {
            let code = try normalizeConnectionCode(rawCode)
            // 对端会以 sessionId=code 启动 offerer，本端作为 answerer 加入。
            try await connect(
                sessionId: code,
                remoteName: nil,
                remotePeerDeviceId: "webrtc-\(code)",
                role: .answerer
            )
        } catch {
            let msg = error.localizedDescription
            lastError = msg
            state = .failed(msg)
            readiness = .idle
        }
    }

    /// 生成本机连接码并等待对端（例如 macOS）输入连接。
    /// - Returns: 6 位连接码；失败时返回 `nil` 且更新 `state/.failed`。
    @discardableResult
    public func generateConnectionCode() async -> String? {
        if let existing = localConnectionCode,
           currentRole == .offerer,
           case .connecting(let sid) = state, sid == existing {
            return existing
        }
        if let existing = localConnectionCode,
           currentRole == .offerer,
           case .connected(let sid) = state, sid == existing {
            return existing
        }

        let code = Self.generateShortCode()
        localConnectionCode = code
        currentRole = .offerer
        state = .connecting(sessionId: code)
        readiness = .idle
        lastError = nil

        connectionCodeBootstrapTask?.cancel()
        connectionCodeBootstrapTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Ignore stale bootstrap tasks when user regenerated/disconnected.
            guard self.localConnectionCode == code, self.currentRole == .offerer else { return }
            do {
                try await self.connect(sessionId: code, remoteName: nil, remotePeerDeviceId: nil, role: .offerer)
                self.localConnectionCode = code
            } catch is CancellationError {
                // Cancellation is expected during regenerate/disconnect.
            } catch {
                guard self.localConnectionCode == code else { return }
                let msg = error.localizedDescription
                self.lastError = msg
                self.state = .failed(msg)
                self.readiness = .idle
            }
            if self.connectionCodeBootstrapTask?.isCancelled == false {
                self.connectionCodeBootstrapTask = nil
            }
        }

        return code
    }
    
    public func disconnect() async {
        if let signaling {
            await signaling.close()
        }
        signaling = nil
        session?.close()
        session = nil
        currentSessionId = nil
        handshakeDriver = nil
        handshakePeerId = nil
        sessionKeys = nil
        remoteDeviceName = nil
        remoteDeviceId = nil
        localConnectionCode = nil
        currentRole = nil
        connectionCodeBootstrapTask?.cancel()
        connectionCodeBootstrapTask = nil
        joinHeartbeatTask?.cancel()
        joinHeartbeatTask = nil
        offerResendTask?.cancel()
        offerResendTask = nil
        remoteDesktopHeartbeatTask?.cancel()
        remoteDesktopHeartbeatTask = nil
        latestLocalOfferBySessionId.removeAll()
        latestLocalAnswerBySessionId.removeAll()
        localICECandidatesBySessionId.removeAll()
        handshakeStartedSessionIds.removeAll()
        rekeyInProgressSessionIds.removeAll()
        rekeyCompletedSessionIds.removeAll()
        strictPQCRequestedBySessionId.removeAll()
        lastPairingIdentityExchangeSentAtByPeerId.removeAll()
        failAllFileTransferWaiters(FileTransferWaitError.cancelled)
        cleanupInboundFileTransfers()
        if let inboundQueue {
            await inboundQueue.finish()
        }
        inboundQueue = nil
        receiveTask?.cancel()
        receiveTask = nil
        state = .idle
        readiness = .idle
    }

    private func signalingURL() throws -> URL {
        guard let wsURL = SignalingRetryController.validatedWebSocketURL(
            CrossNetworkServerConfig.signalingWebSocketURL
        ) else {
            throw SignalingRetryControllerError.invalidWebSocketURL(
                CrossNetworkServerConfig.signalingWebSocketURL
            )
        }
        return wsURL
    }

    private func ensureSignalingConnected() async throws {
        if signaling == nil {
            let wsURL = try signalingURL()
            let newSignaling = WebSocketSignalingClient(url: wsURL)
            signaling = newSignaling
            await newSignaling.setOnEnvelope { [weak self] env in
                Task { @MainActor in
                    self?.handleEnvelope(env)
                }
            }
            await newSignaling.connect()
            return
        }

        await signaling?.connect()
    }

    private func sendEnvelope(_ envelope: WebRTCSignalingEnvelope, retries: Int = 2) async {
        do {
            try await signalingRetryController.sendWithRetry(
                retries: retries,
                reconnectIfNeeded: { [weak self] in
                    await self?.signaling?.connect()
                },
                send: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.ensureSignalingConnected()
                    guard let signaling = self.signaling else {
                        throw WebSocketSignalingClient.SignalingError.notConnected
                    }
                    try await signaling.send(envelope)
                }
            )
        } catch SignalingRetryControllerError.invalidWebSocketURL {
            lastError = "信令服务 URL 无效"
        } catch SignalingRetryControllerError.attemptTimedOut {
            lastError = "信令发送失败: 请求超时"
        } catch is CancellationError {
            return
        } catch {
            lastError = "信令发送失败: \(error.localizedDescription)"
        }
    }

    private func stopJoinHeartbeat() {
        joinHeartbeatTask?.cancel()
        joinHeartbeatTask = nil
    }

    private func startJoinHeartbeat(sessionId: String, localId: String, attempts: Int = 30) {
        stopJoinHeartbeat()
        joinHeartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining = max(0, attempts)
            while remaining > 0, !Task.isCancelled, self.currentSessionId == sessionId {
                await self.sendEnvelope(
                    WebRTCSignalingEnvelope(sessionId: sessionId, from: localId, type: .join, payload: nil),
                    retries: 2
                )
                remaining -= 1
                if remaining == 0 { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopOfferResendLoop() {
        offerResendTask?.cancel()
        offerResendTask = nil
    }

    private func resendCachedOfferIfNeeded(sessionId: String, localId: String, reason: String) async {
        guard let sdp = latestLocalOfferBySessionId[sessionId] else { return }
        await sendEnvelope(
            WebRTCSignalingEnvelope(
                sessionId: sessionId,
                from: localId,
                type: .offer,
                payload: WebRTCSignalingEnvelope.Payload(sdp: sdp)
            ),
            retries: 2
        )
        if reason != "periodic" {
            lastError = nil
        }
    }

    private func startOfferResendLoop(sessionId: String, localId: String, attempts: Int = 40) {
        stopOfferResendLoop()
        offerResendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining = max(0, attempts)
            while remaining > 0, !Task.isCancelled, self.currentSessionId == sessionId {
                if case .connected = self.state { break }
                await self.resendCachedOfferIfNeeded(sessionId: sessionId, localId: localId, reason: "periodic")
                remaining -= 1
                if remaining == 0 { break }
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    private func cacheLocalICECandidate(_ payload: WebRTCSignalingEnvelope.Payload, for sessionId: String) {
        guard let candidate = payload.candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty else {
            return
        }

        var cached = localICECandidatesBySessionId[sessionId] ?? []
        if let existingIndex = cached.firstIndex(where: {
            $0.candidate == candidate &&
            $0.sdpMid == payload.sdpMid &&
            $0.sdpMLineIndex == payload.sdpMLineIndex
        }) {
            cached[existingIndex] = payload
        } else {
            cached.append(payload)
            let maxCachedCandidates = 32
            if cached.count > maxCachedCandidates {
                cached.removeFirst(cached.count - maxCachedCandidates)
            }
        }
        localICECandidatesBySessionId[sessionId] = cached
    }

    private func resendCachedAnswerIfNeeded(sessionId: String, localId: String) async {
        guard let sdp = latestLocalAnswerBySessionId[sessionId] else { return }
        let env = WebRTCSignalingEnvelope(
            sessionId: sessionId,
            from: localId,
            type: .answer,
            payload: WebRTCSignalingEnvelope.Payload(sdp: sdp)
        )
        await sendEnvelope(env, retries: 2)
    }

    private func resendCachedLocalICECandidatesIfNeeded(sessionId: String, localId: String) async {
        guard let candidates = localICECandidatesBySessionId[sessionId], !candidates.isEmpty else { return }
        for payload in candidates {
            let env = WebRTCSignalingEnvelope(
                sessionId: sessionId,
                from: localId,
                type: .iceCandidate,
                payload: payload
            )
            await sendEnvelope(env, retries: 2)
        }
    }
    
    /// 发送远程桌面消息（鼠标/键盘/屏幕）到 macOS（通过已建立的 WebRTC DataChannel + 会话密钥）
    public func sendRemoteDesktopMessage(_ message: RemoteMessage) async throws {
        guard let session, let keys = sessionKeys else { throw RemoteDesktopError.disconnected }
        let data = try JSONEncoder().encode(message)
        let encrypted = try encrypt(plaintext: data, with: keys)
        let padded = TrafficPadding.wrapIfEnabled(encrypted, label: "tx/webrtc-remote")
        try await sendFramed(padded, over: session)
    }

    public func startRemoteDesktopHeartbeat() {
        remoteDesktopHeartbeatTask?.cancel()
        remoteDesktopHeartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let session = self.session,
                      let sessionId = self.currentSessionId,
                      case .connected(let activeSessionId) = self.state,
                      activeSessionId == sessionId
                else { break }

                if self.rekeyInProgressSessionIds.contains(sessionId) {
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch {
                        break
                    }
                    continue
                }

                let strictPQCRequested = self.strictPQCRequestedBySessionId[sessionId] ?? false
                let pqcReady = self.rekeyCompletedSessionIds.contains(sessionId)
                    || self.sessionKeys?.negotiatedSuite.isPQCGroup == true
                if strictPQCRequested && !pqcReady {
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch {
                        break
                    }
                    continue
                }

                #if canImport(UIKit)
                let localName = UIDevice.current.name
                let localModel = UIDevice.current.model
                #else
                let localName: String? = nil
                let localModel: String? = nil
                #endif

                let heartbeat = AppMessage.heartbeat(.init(
                    sentAt: Date(),
                    deviceId: self.localDeviceId,
                    deviceName: localName,
                    modelName: localModel,
                    platform: "iOS",
                    osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    chip: nil
                ))

                do {
                    try await self.sendAppMessageOverWebRTC(
                        heartbeat,
                        sessionId: sessionId,
                        session: session,
                        label: "tx/webrtc-heartbeat"
                    )
                } catch {
                    SkyBridgeLogger.shared.debug("ℹ️ WebRTC heartbeat send failed: \(error.localizedDescription)")
                    break
                }

                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    break
                }
            }
        }
    }

    public func stopRemoteDesktopHeartbeat() {
        remoteDesktopHeartbeatTask?.cancel()
        remoteDesktopHeartbeatTask = nil
    }

    private func cleanupInboundFileTransfers() {
        for (_, st) in inboundFileTransfers {
            try? st.handle.close()
            try? FileManager.default.removeItem(at: st.tempURL)
        }
        inboundFileTransfers.removeAll()
    }
    
    // MARK: - Internals
    
    private struct DynamicQRCodeData: Codable {
        let version: Int
        let sessionID: String
        let deviceName: String
        let deviceFingerprint: String
        let publicKey: Data
        let signingPublicKey: Data?
        let signature: Data?
        let signatureTimestamp: Double?
        let iceServers: [String]
        let expiresAt: Date
    }
    
    private enum ConnectLinkError: LocalizedError {
        case invalidFormat
        case invalidBase64
        case expired
        
        var errorDescription: String? {
            switch self {
            case .invalidFormat: return "二维码格式无效"
            case .invalidBase64: return "二维码内容损坏"
            case .expired: return "二维码已过期"
            }
        }
    }
    
    private enum ConnectionCodeError: LocalizedError {
        case invalid
        
        var errorDescription: String? {
            switch self {
            case .invalid:
                return "连接码无效（需要 6 位字母数字）"
            }
        }
    }
    
    private func normalizeConnectionCode(_ raw: String) throws -> String {
        let code = String(
            raw
                .uppercased()
                .filter { Self.shortCodeAllowedCharacters.contains($0) }
        )
        guard code.count == 6 else { throw ConnectionCodeError.invalid }
        return code
    }

    private static func generateShortCode() -> String {
        String((0..<6).compactMap { _ in shortCodeAlphabet.randomElement() })
    }
    
    private func parseSkybridgeConnectLink(_ string: String) throws -> DynamicQRCodeData {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = extractConnectPayload(from: trimmed) else {
            throw ConnectLinkError.invalidFormat
        }

        guard let jsonData = decodeConnectPayload(payload) else {
            throw ConnectLinkError.invalidBase64
        }
        let qr = try JSONDecoder().decode(DynamicQRCodeData.self, from: jsonData)
        guard qr.expiresAt > Date() else { throw ConnectLinkError.expired }
        return qr
    }

    private func extractConnectPayload(from raw: String) -> String? {
        let prefix = "skybridge://connect/"
        if raw.hasPrefix(prefix) {
            return String(raw.dropFirst(prefix.count))
        }

        guard let url = URL(string: raw), url.scheme == "skybridge", url.host == "connect" else {
            return nil
        }
        let pathPayload = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !pathPayload.isEmpty {
            return pathPayload
        }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryPayload = components.queryItems?.first(where: { $0.name == "data" })?.value,
           !queryPayload.isEmpty {
            return queryPayload
        }
        return nil
    }

    private func decodeConnectPayload(_ rawPayload: String) -> Data? {
        var candidates: [String] = []
        candidates.append(rawPayload)
        if let decoded = rawPayload.removingPercentEncoding, !decoded.isEmpty {
            candidates.append(decoded)
        }

        for candidate in candidates {
            if let data = Data(base64Encoded: candidate, options: [.ignoreUnknownCharacters]) {
                return data
            }

            let urlSafe = candidate
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let padded = urlSafe + String(repeating: "=", count: (4 - (urlSafe.count % 4)) % 4)
            if let data = Data(base64Encoded: padded, options: [.ignoreUnknownCharacters]) {
                return data
            }
        }
        return nil
    }
    
    private func connect(from qr: DynamicQRCodeData) async throws {
        try await connect(
            sessionId: qr.sessionID,
            remoteName: qr.deviceName,
            remotePeerDeviceId: qr.deviceFingerprint,
            role: .answerer
        )
    }
    
    private func connect(
        sessionId: String,
        remoteName: String?,
        remotePeerDeviceId: String?,
        role: WebRTCSession.Role
    ) async throws {
        if signaling != nil || session != nil || currentSessionId != nil {
            await disconnect()
        }

        currentSessionId = sessionId
        state = .connecting(sessionId: sessionId)
        readiness = .idle
        lastError = nil
        handshakePeerId = remotePeerDeviceId ?? "webrtc-\(sessionId)"
        remoteDeviceName = remoteName
        remoteDeviceId = remotePeerDeviceId
        currentRole = role
        if role != .offerer {
            localConnectionCode = nil
        }
        
        // 1) WebSocket signaling
        let wsURL: URL
        do {
            wsURL = try signalingURL()
        } catch {
            state = .failed("信令服务 URL 无效")
            readiness = .idle
            throw error
        }

        let signaling = WebSocketSignalingClient(url: wsURL)
        self.signaling = signaling
        
        await signaling.setOnEnvelope { [weak self] env in
            Task { @MainActor in
                self?.handleEnvelope(env)
            }
        }
        
        await signaling.connect()
        
        // 2) WebRTC session (offerer / answerer)
        let localId = localDeviceId

        // SECURITY: Never hardcode TURN credentials in the client app.
        // Use short-lived TURN REST credentials fetched from backend (with safe fallback).
        let ice = await CrossNetworkServerConfig.dynamicICEConfig()
        
        let s = WebRTCSession(sessionId: sessionId, localDeviceId: localId, role: role, ice: ice)
        self.session = s

        s.onLocalOffer = { [weak self] (sdp: String) in
            guard let self else { return }
            Task {
                await MainActor.run {
                    self.latestLocalOfferBySessionId[sessionId] = sdp
                }
                let env = WebRTCSignalingEnvelope(
                    sessionId: sessionId,
                    from: localId,
                    type: .offer,
                    payload: WebRTCSignalingEnvelope.Payload(sdp: sdp)
                )
                await self.sendEnvelope(env, retries: 2)
            }
        }
        
        s.onLocalAnswer = { [weak self] (sdp: String) in
            guard let self else { return }
            Task { @MainActor in
                self.latestLocalAnswerBySessionId[sessionId] = sdp
                let env = WebRTCSignalingEnvelope(
                    sessionId: sessionId,
                    from: localId,
                    type: .answer,
                    payload: WebRTCSignalingEnvelope.Payload(sdp: sdp)
                )
                await self.sendEnvelope(env, retries: 2)
            }
        }
        
        s.onLocalICECandidate = { [weak self] (payload: WebRTCSignalingEnvelope.Payload) in
            guard let self else { return }
            Task { @MainActor in
                self.cacheLocalICECandidate(payload, for: sessionId)
                let env = WebRTCSignalingEnvelope(
                    sessionId: sessionId,
                    from: localId,
                    type: .iceCandidate,
                    payload: payload
                )
                await self.sendEnvelope(env, retries: 1)
            }
        }

        // Inbound frames from DataChannel
        let inbound = InboundChunkQueue()
        self.inboundQueue = inbound
        s.onData = { data in
            Task { @MainActor [weak self] in
                if let self, self.rekeyInProgressSessionIds.contains(sessionId) {
                    self.lastRekeyEvent = "chunk bytes=\(data.count)"
                    self.appendSmokeTrace("rx chunk bytes=\(data.count)")
                    if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                        print("🧪 WebRTC rekey rx chunk bytes=\(data.count)")
                    }
                }
                await inbound.push(data)
            }
        }

        s.onDisconnected = { [weak self] reason in
            Task { @MainActor in
                guard let self else { return }
                guard self.currentSessionId == sessionId else { return }
                let msg = "WebRTC 传输已断开: \(reason)"
                self.lastError = msg
                await self.disconnect()
                self.lastError = msg
                self.state = .failed(msg)
                self.readiness = .idle
            }
        }
        
        s.onReady = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.currentSessionId == sessionId else { return }
                self.stopJoinHeartbeat()
                self.stopOfferResendLoop()
                self.readiness = .transportReady(sessionId: sessionId)
                SkyBridgeLogger.shared.info("✅ WebRTC transport ready: session=\(sessionId), role=\(String(describing: role))")

                // DataChannel opened; start handshake once per session.
                if !self.handshakeStartedSessionIds.contains(sessionId) {
                    self.handshakeStartedSessionIds.insert(sessionId)
                    let peerDeviceId = self.remoteDeviceId ?? self.handshakePeerId ?? "webrtc-\(sessionId)"
                    Task {
                        await self.startHandshakeOverWebRTC(
                            sessionId: sessionId,
                            peerDeviceId: peerDeviceId,
                            session: s,
                            inbound: inbound
                        )
                    }
                } else {
                    SkyBridgeLogger.shared.debug("ℹ️ skip duplicate WebRTC handshake start: session=\(sessionId)")
                }
            }
        }
        
        try s.start()

        // 3) Join room + heartbeat to mask websocket timing jitters.
        await sendEnvelope(WebRTCSignalingEnvelope(sessionId: sessionId, from: localId, type: .join, payload: nil), retries: 2)
        startJoinHeartbeat(sessionId: sessionId, localId: localId)
        if role == .offerer {
            startOfferResendLoop(sessionId: sessionId, localId: localId)
        }
    }
    
    private func handleEnvelope(_ env: WebRTCSignalingEnvelope) {
        guard env.sessionId == currentSessionId else { return }
        // Ignore self-echo
        let localId = localDeviceId
        if env.from == localId { return }
        
        // If we don't know the remote id yet (e.g., code mode), learn it from signaling.
        if remoteDeviceId == nil || remoteDeviceId?.hasPrefix("webrtc-") == true {
            remoteDeviceId = env.from
            handshakePeerId = env.from
        }
        
        switch env.type {
        case .offer:
            stopJoinHeartbeat()
            if let sdp = env.payload?.sdp {
                session?.setRemoteOffer(sdp)
            }
            let localId = localDeviceId
            Task { @MainActor [weak self] in
                await self?.resendCachedAnswerIfNeeded(sessionId: env.sessionId, localId: localId)
                await self?.resendCachedLocalICECandidatesIfNeeded(sessionId: env.sessionId, localId: localId)
            }
        case .answer:
            stopJoinHeartbeat()
            stopOfferResendLoop()
            if let sdp = env.payload?.sdp {
                session?.setRemoteAnswer(sdp)
            }
            let localId = localDeviceId
            Task { @MainActor [weak self] in
                await self?.resendCachedLocalICECandidatesIfNeeded(sessionId: env.sessionId, localId: localId)
            }
        case .iceCandidate:
            if let p = env.payload, let c = p.candidate {
                session?.addRemoteICECandidate(candidate: c, sdpMid: p.sdpMid, sdpMLineIndex: p.sdpMLineIndex)
            }
        case .join:
            if currentRole == .offerer, let sid = currentSessionId, sid == env.sessionId {
                let localId = localDeviceId
                Task { @MainActor [weak self] in
                    await self?.resendCachedOfferIfNeeded(sessionId: sid, localId: localId, reason: "remote-join")
                    await self?.resendCachedAnswerIfNeeded(sessionId: sid, localId: localId)
                    await self?.resendCachedLocalICECandidatesIfNeeded(sessionId: sid, localId: localId)
                }
            }
        case .leave:
            stopJoinHeartbeat()
            stopOfferResendLoop()
        }
    }
}

// MARK: - WebRTC file transfer helpers (iOS)

@available(iOS 17.0, *)
public extension CrossNetworkWebRTCManager {
    func sendFileTransferMessage(_ message: CrossNetworkFileTransferMessage) async throws {
        guard let session, let keys = sessionKeys else { throw RemoteDesktopError.disconnected }
        let data = try JSONEncoder().encode(message)
        let encrypted = try encrypt(plaintext: data, with: keys)
        let padded = TrafficPadding.wrapIfEnabled(encrypted, label: "tx/webrtc-file")
        try await sendFramed(padded, over: session)
    }
    
    func waitForFileTransferAck(
        transferId: String,
        op: CrossNetworkFileTransferOp,
        chunkIndex: Int? = nil,
        timeoutSeconds: TimeInterval = 20
    ) async throws -> CrossNetworkFileTransferMessage {
        let key = fileTransferWaiterKey(transferId: transferId, op: op, chunkIndex: chunkIndex)
        if fileTransferWaiters[key] != nil {
            // Prevent accidental double-waits on the same key.
            throw FileTransferWaitError.cancelled
        }
        
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<CrossNetworkFileTransferMessage, Error>) in
            fileTransferWaiters[key] = c
            
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                } catch {
                    return
                }
                // Timeout: if still pending, resume with error.
                if let pending = self.fileTransferWaiters.removeValue(forKey: key) {
                    pending.resume(throwing: FileTransferWaitError.timeout)
                }
            }
        }
    }
}

@available(iOS 17.0, *)
private extension CrossNetworkWebRTCManager {
    func fileTransferWaiterKey(transferId: String, op: CrossNetworkFileTransferOp, chunkIndex: Int?) -> String {
        let idx = chunkIndex ?? -1
        return "\(transferId)|\(op.rawValue)|\(idx)"
    }
    
    func handleInboundFileTransferWire(_ msg: CrossNetworkFileTransferMessage) {
        // Resume any waiter matching (transferId, op, chunkIndex).
        let key = fileTransferWaiterKey(transferId: msg.transferId, op: msg.op, chunkIndex: msg.chunkIndex)
        if let waiter = fileTransferWaiters.removeValue(forKey: key) {
            waiter.resume(returning: msg)
            return
        }
        
        // Also allow acks without chunkIndex to be awaited.
        let keyNoIdx = fileTransferWaiterKey(transferId: msg.transferId, op: msg.op, chunkIndex: nil)
        if let waiter = fileTransferWaiters.removeValue(forKey: keyNoIdx) {
            waiter.resume(returning: msg)
            return
        }
    }
    
    func failAllFileTransferWaiters(_ error: Error) {
        let waiters = fileTransferWaiters
        fileTransferWaiters.removeAll()
        for (_, c) in waiters {
            c.resume(throwing: error)
        }
    }

    func failFileTransferWaiters(transferId: String, message: String) {
        let keys = fileTransferWaiters.keys.filter { $0.hasPrefix("\(transferId)|") }
        for key in keys {
            if let waiter = fileTransferWaiters.removeValue(forKey: key) {
                waiter.resume(throwing: FileTransferError.transferFailed(message))
            }
        }
    }
    
    // MARK: - Inbound file transfer (macOS -> iOS)
    
    func downloadsDirectoryURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    func sanitizeFileName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "SkyBridgeFile" : trimmed
    }
    
    func makeUniqueDestinationURL(baseDir: URL, fileName: String) -> URL {
        let safe = sanitizeFileName(fileName)
        let ext = (safe as NSString).pathExtension
        let stem = (safe as NSString).deletingPathExtension
        
        var candidate = baseDir.appendingPathComponent(safe)
        var idx = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let altName: String
            if ext.isEmpty {
                altName = "\(stem) (\(idx))"
            } else {
                altName = "\(stem) (\(idx)).\(ext)"
            }
            candidate = baseDir.appendingPathComponent(altName)
            idx += 1
        }
        return candidate
    }
    
    func handleInboundFileTransferFromMac(_ msg: CrossNetworkFileTransferMessage) async {
	        guard let keys = sessionKeys else { return }

	        func sha256File(_ url: URL) -> Data? {
	            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
	            defer { try? handle.close() }
	            var hasher = SHA256()
	            while true {
                let chunk = handle.readData(ofLength: 256 * 1024)
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            return Data(hasher.finalize())
        }
        
        func sendAck(_ ack: CrossNetworkFileTransferMessage, label: String) async {
            do {
                try await sendFileTransferMessage(ack)
            } catch {
                // Best-effort; ignore.
                _ = label
                _ = keys
            }
        }
        
        switch msg.op {
        case .metadata:
            // Idempotent: allow re-sending metadata for the same transferId (resume).
            if inboundFileTransfers[msg.transferId] != nil {
                await sendAck(.init(op: .metadataAck, transferId: msg.transferId), label: "metaAck")
                return
            }

            guard
                let fileName = msg.fileName,
                let fileSize = msg.fileSize,
                let chunkSize = msg.chunkSize,
                let totalChunks = msg.totalChunks
            else {
                await sendAck(.init(op: .error, transferId: msg.transferId, message: "Invalid metadata"), label: "metaError")
                return
            }
            
            // Prepare paths
            let baseDir = downloadsDirectoryURL()
            let finalURL = makeUniqueDestinationURL(baseDir: baseDir, fileName: fileName)
            let tempURL = baseDir.appendingPathComponent(".skybridge-\(msg.transferId).partial")
            _ = FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            
            do {
                let handle = try FileHandle(forWritingTo: tempURL)
                let senderId = msg.senderDeviceId ?? (remoteDeviceId ?? "mac")
                let senderName = msg.senderDeviceName ?? (remoteDeviceName ?? "macOS")
                
                inboundFileTransfers[msg.transferId] = InboundFileTransferState(
                    transferId: msg.transferId,
                    fileName: fileName,
                    fileSize: fileSize,
                    chunkSize: chunkSize,
                    totalChunks: totalChunks,
                    senderDeviceId: senderId,
                    senderDeviceName: senderName,
                    tempURL: tempURL,
                    finalURL: finalURL,
                    handle: handle,
                    receivedBytes: 0
                )
                
                // UI record
                FileTransferManager.instance.beginExternalInboundTransfer(
                    transferId: msg.transferId,
                    fileName: fileName,
                    fileSize: fileSize,
                    fromPeerName: senderName,
                    destinationURL: finalURL
                )
                
                await sendAck(.init(op: .metadataAck, transferId: msg.transferId), label: "metaAck")
            } catch {
                await sendAck(.init(op: .error, transferId: msg.transferId, message: "Open temp file failed"), label: "metaError")
            }
            
        case .chunk:
            guard let idx = msg.chunkIndex, let data = msg.chunkData else { return }
            guard var st = inboundFileTransfers[msg.transferId] else {
                await sendAck(.init(op: .error, transferId: msg.transferId, message: "Unknown transferId"), label: "chunkError")
                return
            }
            
            do {
                let actualHash = CrossNetworkCryptoCompat.sha256(data)
                if let expected = msg.chunkSha256, actualHash != expected {
                    // Backward compatible: only enforce if hash provided.
                    // Don't ACK corrupted chunk; sender will timeout/retry as appropriate.
                    await sendAck(.init(op: .error, transferId: msg.transferId, chunkIndex: idx, message: "chunk hash mismatch"), label: "chunkHashMismatch")
                    return
                }

                st.chunkHashes[idx] = actualHash

                let rawSize = msg.rawSize ?? data.count
                let offset = Int64(idx) * Int64(st.chunkSize)
                try st.handle.seek(toOffset: UInt64(max(0, offset)))
                try st.handle.write(contentsOf: data)
                
                st.receivedBytes = min(st.fileSize, max(st.receivedBytes, offset + Int64(rawSize)))
                inboundFileTransfers[msg.transferId] = st
                
                FileTransferManager.instance.updateExternalInboundProgress(
                    transferId: st.transferId,
                    transferredBytes: st.receivedBytes,
                    totalBytes: st.fileSize
                )
                
                // If complete was already requested earlier, finalize once we have enough.
                if st.completeRequestedAt != nil && st.receivedBytes >= st.fileSize {
                    do { try st.handle.close() } catch {}
                    do {
                        if let expectedMerkle = st.expectedMerkleRoot {
                            let leaves: [Data] = (0..<st.totalChunks).compactMap { st.chunkHashes[$0] }
                            if leaves.count != st.totalChunks || CrossNetworkMerkleCompat.root(leaves: leaves) != expectedMerkle {
                                FileTransferManager.instance.completeExternalInboundTransfer(
                                    transferId: st.transferId,
                                    success: false,
                                    error: "merkle root mismatch"
                                )
                                try? FileManager.default.removeItem(at: st.tempURL)
                                inboundFileTransfers.removeValue(forKey: st.transferId)
                                inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                await sendAck(.init(op: .error, transferId: st.transferId, message: "merkle root mismatch"), label: "completeError")
                                return
                            }

                            if let sig = st.expectedMerkleSig {
                                if st.expectedMerkleSigAlg != CrossNetworkMerkleAuthCompat.signatureAlgV1 {
                                    FileTransferManager.instance.completeExternalInboundTransfer(
                                        transferId: st.transferId,
                                        success: false,
                                        error: "unknown merkle sig alg"
                                    )
                                    try? FileManager.default.removeItem(at: st.tempURL)
                                    inboundFileTransfers.removeValue(forKey: st.transferId)
                                    inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                    inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                    await sendAck(.init(op: .error, transferId: st.transferId, message: "unknown merkle sig alg"), label: "completeError")
                                    return
                                }
                                let pre = CrossNetworkMerkleAuthCompat.preimage(
                                    transferId: st.transferId,
                                    merkleRoot: expectedMerkle,
                                    fileSha256: st.expectedFileSha256
                                )
                                let expectSig = CrossNetworkMerkleAuthCompat.hmacSha256(key: keys.receiveKey, data: pre)
                                if sig != expectSig {
                                    FileTransferManager.instance.completeExternalInboundTransfer(
                                        transferId: st.transferId,
                                        success: false,
                                        error: "merkle signature mismatch"
                                    )
                                    try? FileManager.default.removeItem(at: st.tempURL)
                                    inboundFileTransfers.removeValue(forKey: st.transferId)
                                    inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                    inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                    await sendAck(.init(op: .error, transferId: st.transferId, message: "merkle signature mismatch"), label: "completeError")
                                    return
                                }
                            }
                        }

                        if let expected = st.expectedFileSha256, let actual = sha256File(st.tempURL), actual != expected {
                            FileTransferManager.instance.completeExternalInboundTransfer(
                                transferId: st.transferId,
                                success: false,
                                error: "file sha256 mismatch"
                            )
                            try? FileManager.default.removeItem(at: st.tempURL)
                            inboundFileTransfers.removeValue(forKey: st.transferId)
                            inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                            inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                            await sendAck(.init(op: .error, transferId: st.transferId, message: "file sha256 mismatch"), label: "completeError")
                            return
                        }
                        if FileManager.default.fileExists(atPath: st.finalURL.path) {
                            try? FileManager.default.removeItem(at: st.finalURL)
                        }
                        try FileManager.default.moveItem(at: st.tempURL, to: st.finalURL)
                        FileTransferManager.instance.completeExternalInboundTransfer(
                            transferId: st.transferId,
                            success: true,
                            destinationURL: st.finalURL
                        )
                        inboundFileTransfers.removeValue(forKey: st.transferId)
                        inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                        inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                        await sendAck(.init(op: .completeAck, transferId: st.transferId), label: "completeAck")
                        return
                    } catch {
                        FileTransferManager.instance.completeExternalInboundTransfer(
                            transferId: st.transferId,
                            success: false,
                            error: "Save failed"
                        )
                        try? FileManager.default.removeItem(at: st.tempURL)
                        inboundFileTransfers.removeValue(forKey: st.transferId)
                        inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                        inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                        await sendAck(.init(op: .error, transferId: st.transferId, message: "Save failed"), label: "completeError")
                        return
                    }
                }
                
                await sendAck(
                    .init(op: .chunkAck, transferId: st.transferId, chunkIndex: idx, receivedBytes: st.receivedBytes),
                    label: "chunkAck"
                )
            } catch {
                FileTransferManager.instance.completeExternalInboundTransfer(
                    transferId: msg.transferId,
                    success: false,
                    error: error.localizedDescription
                )
                try? st.handle.close()
                try? FileManager.default.removeItem(at: st.tempURL)
                inboundFileTransfers.removeValue(forKey: msg.transferId)
                await sendAck(.init(op: .error, transferId: msg.transferId, message: "Write failed"), label: "chunkError")
            }
            
        case .complete:
            guard var st = inboundFileTransfers[msg.transferId] else { return }

            // Capture expected full-file hash (optional, backward compatible).
            if st.expectedFileSha256 == nil { st.expectedFileSha256 = msg.fileSha256 }
            if st.expectedMerkleRoot == nil { st.expectedMerkleRoot = msg.merkleRoot }
            if st.expectedMerkleSig == nil { st.expectedMerkleSig = msg.merkleRootSignature }
            if st.expectedMerkleSigAlg == nil { st.expectedMerkleSigAlg = msg.merkleRootSignatureAlg }
            
            if st.receivedBytes < st.fileSize {
                // Optional NACK: request missing chunks (backward compatible).
                let missing = (0..<st.totalChunks).filter { st.chunkHashes[$0] == nil }
                if !missing.isEmpty {
                    await sendAck(.init(op: .chunkAck, transferId: st.transferId, missingChunks: Array(missing.prefix(512)), message: "missingChunks"), label: "missingChunks")
                }

                // Don't fail immediately; mark complete requested and wait for retransmits.
                if st.completeRequestedAt == nil { st.completeRequestedAt = Date() }
                inboundFileTransfers[st.transferId] = st
                
                if inboundFileTransferCompleteTimers[st.transferId] == nil {
                    inboundFileTransferCompleteTimers[st.transferId] = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(10))
                        guard let self else { return }
                        if let cur = self.inboundFileTransfers[st.transferId], cur.receivedBytes < cur.fileSize {
                            do { try cur.handle.close() } catch {}
                            try? FileManager.default.removeItem(at: cur.tempURL)
                            self.inboundFileTransfers.removeValue(forKey: cur.transferId)
                            self.inboundFileTransferCompleteTimers[cur.transferId]?.cancel()
                            self.inboundFileTransferCompleteTimers.removeValue(forKey: cur.transferId)
                            FileTransferManager.instance.completeExternalInboundTransfer(
                                transferId: cur.transferId,
                                success: false,
                                error: "Incomplete file (timeout)"
                            )
                        }
                    }
                }
                return
            }
            
            do { try st.handle.close() } catch {}
            
            do {
                if let expectedMerkle = st.expectedMerkleRoot {
                    let leaves: [Data] = (0..<st.totalChunks).compactMap { st.chunkHashes[$0] }
                    if leaves.count != st.totalChunks || CrossNetworkMerkleCompat.root(leaves: leaves) != expectedMerkle {
                        FileTransferManager.instance.completeExternalInboundTransfer(
                            transferId: st.transferId,
                            success: false,
                            error: "merkle root mismatch"
                        )
                        try? FileManager.default.removeItem(at: st.tempURL)
                        inboundFileTransfers.removeValue(forKey: st.transferId)
                        inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                        inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                        await sendAck(.init(op: .error, transferId: st.transferId, message: "merkle root mismatch"), label: "completeError")
                        return
                    }

                    if let sig = st.expectedMerkleSig {
                        if st.expectedMerkleSigAlg != CrossNetworkMerkleAuthCompat.signatureAlgV1 {
                            FileTransferManager.instance.completeExternalInboundTransfer(
                                transferId: st.transferId,
                                success: false,
                                error: "unknown merkle sig alg"
                            )
                            try? FileManager.default.removeItem(at: st.tempURL)
                            inboundFileTransfers.removeValue(forKey: st.transferId)
                            inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                            inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                            await sendAck(.init(op: .error, transferId: st.transferId, message: "unknown merkle sig alg"), label: "completeError")
                            return
                        }
                        let pre = CrossNetworkMerkleAuthCompat.preimage(
                            transferId: st.transferId,
                            merkleRoot: expectedMerkle,
                            fileSha256: st.expectedFileSha256
                        )
                        let expectSig = CrossNetworkMerkleAuthCompat.hmacSha256(key: keys.receiveKey, data: pre)
                        if sig != expectSig {
                            FileTransferManager.instance.completeExternalInboundTransfer(
                                transferId: st.transferId,
                                success: false,
                                error: "merkle signature mismatch"
                            )
                            try? FileManager.default.removeItem(at: st.tempURL)
                            inboundFileTransfers.removeValue(forKey: st.transferId)
                            inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                            inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                            await sendAck(.init(op: .error, transferId: st.transferId, message: "merkle signature mismatch"), label: "completeError")
                            return
                        }
                    }
                }

                if let expected = st.expectedFileSha256, let actual = sha256File(st.tempURL), actual != expected {
                    FileTransferManager.instance.completeExternalInboundTransfer(
                        transferId: st.transferId,
                        success: false,
                        error: "file sha256 mismatch"
                    )
                    try? FileManager.default.removeItem(at: st.tempURL)
                    inboundFileTransfers.removeValue(forKey: st.transferId)
                    inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                    inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                    await sendAck(.init(op: .error, transferId: st.transferId, message: "file sha256 mismatch"), label: "completeError")
                    return
                }
                if FileManager.default.fileExists(atPath: st.finalURL.path) {
                    try? FileManager.default.removeItem(at: st.finalURL)
                }
                try FileManager.default.moveItem(at: st.tempURL, to: st.finalURL)
                
                FileTransferManager.instance.completeExternalInboundTransfer(
                    transferId: st.transferId,
                    success: true,
                    destinationURL: st.finalURL
                )
                inboundFileTransfers.removeValue(forKey: st.transferId)
                inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                
                await sendAck(.init(op: .completeAck, transferId: st.transferId), label: "completeAck")
            } catch {
                FileTransferManager.instance.completeExternalInboundTransfer(
                    transferId: st.transferId,
                    success: false,
                    error: "Save failed"
                )
                try? FileManager.default.removeItem(at: st.tempURL)
                inboundFileTransfers.removeValue(forKey: st.transferId)
                inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                await sendAck(.init(op: .error, transferId: st.transferId, message: "Save failed"), label: "completeError")
            }
            
        case .cancel:
            if let st = inboundFileTransfers[msg.transferId] {
                try? st.handle.close()
                try? FileManager.default.removeItem(at: st.tempURL)
                inboundFileTransfers.removeValue(forKey: msg.transferId)
                FileTransferManager.instance.completeExternalInboundTransfer(
                    transferId: msg.transferId,
                    success: false,
                    error: msg.message ?? "Cancelled"
                )
            }
            
        case .metadataAck, .chunkAck, .completeAck:
            // These are acks for iOS->macOS sending.
            handleInboundFileTransferWire(msg)
            
        case .error:
            // Fail any pending iOS->macOS sender waits for this transfer immediately.
            failFileTransferWaiters(
                transferId: msg.transferId,
                message: msg.message ?? "remote error"
            )
        }
    }
}

// MARK: - WebRTC framed handshake (iOS)

@available(iOS 17.0, *)
private actor InboundChunkQueue {
    private var pending: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var finished = false
    
    enum QueueError: Error { case finished }
    
    func push(_ data: Data) {
        guard !finished else { return }
        if let w = waiters.first {
            waiters.removeFirst()
            w.resume(returning: data)
            return
        }
        pending.append(data)
    }
    
    func finish() {
        finished = true
        let ws = waiters
        waiters.removeAll()
        ws.forEach { $0.resume(throwing: QueueError.finished) }
    }
    
    func next() async throws -> Data {
        if let first = pending.first {
            pending.removeFirst()
            return first
        }
        if finished { throw QueueError.finished }
        return try await withCheckedThrowingContinuation { c in
            waiters.append(c)
        }
    }

    func next(max: Int) async throws -> Data {
        precondition(max > 0, "max must be greater than zero")
        let chunk = try await next()
        if chunk.count <= max {
            return chunk
        }
        let head = Data(chunk.prefix(max))
        let tail = Data(chunk.dropFirst(max))
        pending.insert(tail, at: 0)
        return head
    }
}

@available(iOS 17.0, *)
private extension CrossNetworkWebRTCManager {
    func startHandshakeOverWebRTC(
        sessionId: String,
        peerDeviceId: String,
        session: WebRTCSession,
        inbound: InboundChunkQueue
    ) async {
        let webRTCHandshakeMaxChunkBytes = 1024
        let webRTCHandshakeMaxPaddedPayloadBytes = (8 * 1024) - 4

        struct FramedWebRTCTransport: DiscoveryTransport {
            let sendFramed: @Sendable (Data) async throws -> Void
            func send(to peer: PeerIdentifier, data: Data) async throws { try await sendFramed(data) }
        }
        
        @Sendable func sendFramed(_ data: Data) async throws {
            let rawHandshake = HandshakePadding.unwrapIfNeeded(data, label: "tx/webrtc")
            let tunedHandshake = HandshakePadding.wrapIfEnabled(
                rawHandshake,
                label: "tx/webrtc",
                maxTotalBytes: webRTCHandshakeMaxPaddedPayloadBytes
            )
            if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                if let messageA = try? HandshakeMessageA.decode(from: rawHandshake) {
                    let suites = messageA.supportedSuites.map(\.rawValue).joined(separator: ",")
                    if let identity = try? messageA.decodedIdentityPublicKeys() {
                        self.appendSmokeTrace(
                            "tx messageA suites=\(suites) alg=\(identity.protocolAlgorithm.rawValue) pk=\(identity.protocolPublicKey.count)"
                        )
                    } else {
                        self.appendSmokeTrace("tx messageA suites=\(suites) alg=unknown pk=0")
                    }
                    print("🧪 WebRTC rekey tx MessageA raw=\(rawHandshake.count) padded=\(tunedHandshake.count) suites=\(suites)")
                } else if (try? HandshakeFinished.decode(from: rawHandshake)) != nil {
                    print("🧪 WebRTC rekey tx Finished raw=\(rawHandshake.count) padded=\(tunedHandshake.count)")
                }
            }
            try await session.sendFramedPayloadAsync(
                tunedHandshake,
                maxChunkBytes: webRTCHandshakeMaxChunkBytes,
                maxBufferedAmountBytes: 0
            )
        }
        
        do {
            let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
            let strictPQCRequested = shouldRequestStrictPQC(compatibilityModeEnabled: compatibilityModeEnabled)
            strictPQCRequestedBySessionId[sessionId] = strictPQCRequested
            let capability = CryptoProviderFactory.detectCapability()
            var peerIdCandidates: [String] = []
            for raw in [peerDeviceId, remoteDeviceId, handshakePeerId] {
                guard let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { continue }
                if !peerIdCandidates.contains(id) {
                    peerIdCandidates.append(id)
                }
            }
            if peerIdCandidates.isEmpty {
                peerIdCandidates = [peerDeviceId]
            }

            var trustedPeerKEMKeys: [CryptoSuite: Data] = [:]
            var trustLookupPeerId = peerDeviceId
            for candidate in peerIdCandidates {
                let keys = await KEMTrustStore.shared.kemPublicKeys(for: candidate)
                guard !keys.isEmpty else { continue }
                trustedPeerKEMKeys = keys
                trustLookupPeerId = candidate
                break
            }
            let hasTrustedPeerKEMKey = !trustedPeerKEMKeys.isEmpty
            let selection: CryptoProviderFactory.SelectionPolicy
            if !hasTrustedPeerKEMKey {
                selection = .classicOnly
                if strictPQCRequested {
                    SkyBridgeLogger.shared.warning(
                        "⚠️ WebRTC strictPQC requested but peer KEM trust key missing; " +
                        "fallback to classic bootstrap. peer=\(peerDeviceId)"
                    )
                }
            } else if strictPQCRequested {
                if capability.hasApplePQC || capability.hasLiboqs {
                    selection = .requirePQC
                } else {
                    selection = .preferPQC
                    SkyBridgeLogger.shared.warning(
                        "⚠️ WebRTC strictPQC requested but local PQC provider unavailable; fallback to preferPQC. " +
                        "hasApplePQC=\(capability.hasApplePQC), hasLiboqs=\(capability.hasLiboqs)"
                    )
                }
            } else {
                selection = .preferPQC
            }
            SkyBridgeLogger.shared.info(
                "🤝 WebRTC handshake bootstrap: session=\(sessionId), policy=\(selection.rawValue), " +
                "compatMode=\(compatibilityModeEnabled), hasApplePQC=\(capability.hasApplePQC), hasLiboqs=\(capability.hasLiboqs), " +
                "peer=\(peerDeviceId), trustedKEM=\(hasTrustedPeerKEMKey), trustPeer=\(trustLookupPeerId)"
            )
            let transport = FramedWebRTCTransport(sendFramed: { data in try await sendFramed(data) })
            let peer = PeerIdentifier(deviceId: peerDeviceId)

            // Start a single long-lived receive loop (handshake + post-handshake remote desktop).
            receiveTask?.cancel()
            receiveTask = Task {
                await self.receiveLoop(
                    sessionId: sessionId,
                    session: session,
                    inbound: inbound,
                    peer: peer,
                    strictPQCRequested: strictPQCRequested
                )
            }

            func attemptInitialHandshake(
                selection: CryptoProviderFactory.SelectionPolicy,
                bootstrapMode: String
            ) async throws -> SessionKeys {
                try await SkyBridgeiOSCore.shared.initialize(policy: selection)
                let driver = try SkyBridgeiOSCore.shared.createHandshakeDriver(transport: transport)
                self.handshakeDriver = driver
                SkyBridgeLogger.shared.info(
                    "🤝 WebRTC initiating handshake: session=\(sessionId), peer=\(peerDeviceId), mode=\(bootstrapMode), policy=\(selection.rawValue)"
                )
                return try await driver.initiateHandshake(with: peer)
            }

            let keys: SessionKeys
            do {
                keys = try await attemptInitialHandshake(
                    selection: selection,
                    bootstrapMode: hasTrustedPeerKEMKey ? "trusted_kem" : "classic_bootstrap"
                )
            } catch {
                self.handshakeDriver = nil
                if hasTrustedPeerKEMKey,
                   selection != .classicOnly,
                   Self.shouldRetryClassicBootstrap(after: error) {
                    for candidate in peerIdCandidates {
                        await KEMTrustStore.shared.clear(deviceId: candidate)
                    }
                    self.appendSmokeTrace("bootstrap retry classic peer=\(peerDeviceId)")
                    SkyBridgeLogger.shared.warning(
                        "⚠️ WebRTC trusted KEM bootstrap failed; cleared cached peer KEM keys and retrying classic bootstrap. " +
                        "session=\(sessionId), peer=\(peerDeviceId), error=\(Self.describeHandshakeError(error))"
                    )
                    keys = try await attemptInitialHandshake(
                        selection: .classicOnly,
                        bootstrapMode: "classic_retry_after_stale_kem"
                    )
                } else {
                    throw error
                }
            }

            self.sessionKeys = keys
            self.handshakeDriver = nil
            if self.currentSessionId == sessionId {
                // Paper-aligned contract:
                // WebRTC DataChannel ready is only transportReady; connected must wait for handshakeComplete.
                self.state = .connected(sessionId: sessionId)
                self.readiness = .handshakeComplete(
                    sessionId: sessionId,
                    negotiatedSuite: keys.negotiatedSuite.rawValue
                )
            }
            SkyBridgeLogger.shared.info(
                "✅ WebRTC 握手完成（DataChannel） session=\(sessionId) suite=\(keys.negotiatedSuite.rawValue)"
            )

            do {
                try await sendPairingIdentityExchangeOverWebRTC(
                    sessionId: sessionId,
                    peerDeviceId: peerDeviceId,
                    session: session,
                    force: true
                )
            } catch {
                SkyBridgeLogger.shared.warning(
                    "⚠️ WebRTC pairingIdentityExchange send failed: session=\(sessionId) peer=\(peerDeviceId) err=\(error.localizedDescription)"
                )
            }

            await maybeStartPQCRekeyOverWebRTC(
                sessionId: sessionId,
                peerDeviceId: peerDeviceId,
                session: session,
                strictPQCRequested: strictPQCRequested,
                trigger: "post_bootstrap"
            )
        } catch {
            let reason: String
            if let hs = error as? HandshakeError {
                switch hs {
                case .alreadyInProgress:
                    reason = "alreadyInProgress"
                case .noSigningCapability:
                    reason = "noSigningCapability"
                case .failed(let failure):
                    reason = String(describing: failure)
                case .emptyOfferedSuites:
                    reason = "emptyOfferedSuites"
                case .homogeneityViolation(let message):
                    reason = "homogeneityViolation(\(message))"
                case .providerAlgorithmMismatch(let provider, let algorithm):
                    reason = "providerAlgorithmMismatch(provider=\(provider), algorithm=\(algorithm))"
                case .signatureAlgorithmMismatch(let algorithm, let keyHandleType):
                    reason = "signatureAlgorithmMismatch(algorithm=\(algorithm), keyHandle=\(keyHandleType))"
                case .contextZeroized:
                    reason = "contextZeroized"
                }
            } else {
                reason = error.localizedDescription
            }
            SkyBridgeLogger.shared.error("❌ WebRTC 握手失败（DataChannel） session=\(sessionId): \(reason)")
            await MainActor.run {
                self.lastError = "WebRTC 握手失败: \(reason)"
                self.state = .failed(self.lastError ?? "WebRTC handshake failed")
                self.readiness = .idle
                self.handshakeDriver = nil
                self.sessionKeys = nil
                self.handshakeStartedSessionIds.remove(sessionId)
                self.rekeyInProgressSessionIds.remove(sessionId)
                self.rekeyCompletedSessionIds.remove(sessionId)
                self.strictPQCRequestedBySessionId.removeValue(forKey: sessionId)
            }
        }
    }

    func shouldRequestStrictPQC(compatibilityModeEnabled: Bool) -> Bool {
        if compatibilityModeEnabled { return false }
        if #available(iOS 26.0, *) { return true }
        return false
    }

    private static func shouldRetryClassicBootstrap(after error: Error) -> Bool {
        if let handshakeError = error as? HandshakeError {
            if case .failed(let reason) = handshakeError,
               case .cryptoError = reason {
                return true
            }
            return false
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("cryptokit")
    }

    private static func describeHandshakeError(_ error: Error) -> String {
        if let hs = error as? HandshakeError {
            switch hs {
            case .alreadyInProgress:
                return "alreadyInProgress"
            case .noSigningCapability:
                return "noSigningCapability"
            case .failed(let failure):
                return String(describing: failure)
            case .emptyOfferedSuites:
                return "emptyOfferedSuites"
            case .homogeneityViolation(let message):
                return "homogeneityViolation(\(message))"
            case .providerAlgorithmMismatch(let provider, let algorithm):
                return "providerAlgorithmMismatch(provider=\(provider), algorithm=\(algorithm))"
            case .signatureAlgorithmMismatch(let algorithm, let keyHandleType):
                return "signatureAlgorithmMismatch(algorithm=\(algorithm), keyHandle=\(keyHandleType))"
            case .contextZeroized:
                return "contextZeroized"
            }
        }
        return error.localizedDescription
    }

    func sendAppMessageOverWebRTC(
        _ message: AppMessage,
        sessionId: String,
        session: WebRTCSession,
        label: String
    ) async throws {
        guard currentSessionId == sessionId else { return }
        guard let keys = sessionKeys else { throw RemoteDesktopError.disconnected }
        let payload = try JSONEncoder().encode(message)
        let ciphertext = try encrypt(plaintext: payload, with: keys)
        let padded = TrafficPadding.wrapIfEnabled(ciphertext, label: label)
        try await sendFramed(padded, over: session)
    }

    func sendPairingIdentityExchangeOverWebRTC(
        sessionId: String,
        peerDeviceId: String,
        session: WebRTCSession,
        force: Bool = false
    ) async throws {
        guard currentSessionId == sessionId else { return }
        if !force,
           let last = lastPairingIdentityExchangeSentAtByPeerId[peerDeviceId],
           Date().timeIntervalSince(last) < 10 {
            return
        }

        let kemKeys = try await P2PKEMIdentityKeyStore.shared.getOrCreateBootstrapPublicKeys()
        guard !kemKeys.isEmpty else { return }

        let message = AppMessage.pairingIdentityExchange(.init(
            deviceId: localDeviceId,
            kemPublicKeys: kemKeys,
            deviceName: nil,
            modelName: nil,
            platform: "iOS",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            chip: nil
        ))
        try await sendAppMessageOverWebRTC(
            message,
            sessionId: sessionId,
            session: session,
            label: "tx/webrtc-bootstrap"
        )
        lastPairingIdentityExchangeSentAtByPeerId[peerDeviceId] = Date()
        SkyBridgeLogger.shared.info(
            "📤 WebRTC pairingIdentityExchange sent: session=\(sessionId), peer=\(peerDeviceId), keys=\(kemKeys.count)"
        )
    }

    func handleInboundAppMessageOverWebRTC(
        _ message: AppMessage,
        sessionId: String,
        peerDeviceId: String,
        session: WebRTCSession,
        strictPQCRequested: Bool
    ) async {
        switch message {
        case .pairingIdentityExchange(let payload):
            await KEMTrustStore.shared.upsert(deviceId: payload.deviceId, kemPublicKeys: payload.kemPublicKeys)
            await KEMTrustStore.shared.upsert(deviceId: peerDeviceId, kemPublicKeys: payload.kemPublicKeys)
            if remoteDeviceId == nil || remoteDeviceId?.hasPrefix("webrtc-") == true {
                remoteDeviceId = payload.deviceId
            }
            if handshakePeerId == nil || handshakePeerId?.hasPrefix("webrtc-") == true {
                handshakePeerId = payload.deviceId
            }
            SkyBridgeLogger.shared.info(
                "🔑 WebRTC bootstrap KEM cache updated: peer=\(peerDeviceId), declared=\(payload.deviceId), keys=\(payload.kemPublicKeys.count)"
            )

            do {
                try await sendPairingIdentityExchangeOverWebRTC(
                    sessionId: sessionId,
                    peerDeviceId: peerDeviceId,
                    session: session,
                    force: false
                )
            } catch {
                SkyBridgeLogger.shared.debug("ℹ️ pairingIdentityExchange reply failed (ignored): \(error.localizedDescription)")
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.maybeStartPQCRekeyOverWebRTC(
                    sessionId: sessionId,
                    peerDeviceId: peerDeviceId,
                    session: session,
                    strictPQCRequested: strictPQCRequested,
                    trigger: "pairing_exchange"
                )
            }
        case .ping(let payload):
            do {
                try await sendAppMessageOverWebRTC(
                    .pong(.init(id: payload.id)),
                    sessionId: sessionId,
                    session: session,
                    label: "tx/webrtc-pong"
                )
            } catch {
                // Best-effort reply.
            }
        case .clipboard, .heartbeat, .pong:
            break
        }
    }

    func maybeStartPQCRekeyOverWebRTC(
        sessionId: String,
        peerDeviceId: String,
        session: WebRTCSession,
        strictPQCRequested: Bool,
        trigger: String
    ) async {
        guard currentSessionId == sessionId else { return }
        guard strictPQCRequested else { return }
        guard let establishedKeys = sessionKeys else { return }
        guard !establishedKeys.negotiatedSuite.isPQCGroup else { return }
        guard !rekeyInProgressSessionIds.contains(sessionId) else { return }
        guard !rekeyCompletedSessionIds.contains(sessionId) else { return }

        let capability = CryptoProviderFactory.detectCapability()
        let selection: CryptoProviderFactory.SelectionPolicy
        if capability.hasApplePQC || capability.hasLiboqs {
            selection = .requirePQC
        } else {
            SkyBridgeLogger.shared.warning(
                "⚠️ skip WebRTC rekey: strictPQC requested but local PQC provider unavailable. " +
                "session=\(sessionId), trigger=\(trigger), hasApplePQC=\(capability.hasApplePQC), hasLiboqs=\(capability.hasLiboqs)"
            )
            return
        }

        var candidateIds: [String] = []
        for raw in [peerDeviceId, remoteDeviceId, handshakePeerId] {
            guard let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { continue }
            if !candidateIds.contains(id) {
                candidateIds.append(id)
            }
        }
        if candidateIds.isEmpty { return }

        let provider = CryptoProviderFactory.make(policy: selection)
        let requiredSuites = provider.supportedSuites.filter { $0.isPQCGroup }
        guard !requiredSuites.isEmpty else { return }

        var selectedPeerId = peerDeviceId
        var trustedPeerKEM: [CryptoSuite: Data] = [:]
        for candidate in candidateIds {
            let keys = await KEMTrustStore.shared.kemPublicKeys(for: candidate)
            guard !keys.isEmpty else { continue }
            if trustedPeerKEM.isEmpty {
                selectedPeerId = candidate
                trustedPeerKEM = keys
            }
            let missing = requiredSuites.filter { keys[$0] == nil }
            if missing.isEmpty {
                selectedPeerId = candidate
                trustedPeerKEM = keys
                break
            }
        }

        let missingSuites = requiredSuites.filter { trustedPeerKEM[$0] == nil }
        guard missingSuites.isEmpty else {
            let missing = missingSuites.map(\.rawValue).joined(separator: ",")
            lastRekeyEvent = "waiting peer=\(selectedPeerId) missing=\(missing)"
            SkyBridgeLogger.shared.info(
                "⏳ WebRTC rekey waiting for peer KEM keys: session=\(sessionId), peer=\(selectedPeerId), missing=\(missing)"
            )
            return
        }

        struct FramedWebRTCTransport: DiscoveryTransport {
            let sendFramed: @Sendable (Data) async throws -> Void
            func send(to peer: PeerIdentifier, data: Data) async throws { try await sendFramed(data) }
        }

        @Sendable func sendFramed(_ data: Data) async throws {
            try await self.sendFramed(data, over: session)
        }

        rekeyInProgressSessionIds.insert(sessionId)
        defer {
            rekeyInProgressSessionIds.remove(sessionId)
            handshakeDriver = nil
        }

        do {
            try await SkyBridgeiOSCore.shared.initialize(policy: selection)
            let transport = FramedWebRTCTransport(sendFramed: { data in try await sendFramed(data) })
            let peer = PeerIdentifier(deviceId: selectedPeerId)
            let driver = try SkyBridgeiOSCore.shared.createHandshakeDriver(transport: transport)
            handshakeDriver = driver

            lastRekeyEvent = "start peer=\(selectedPeerId) policy=\(selection.rawValue)"
            SkyBridgeLogger.shared.info(
                "🔁 WebRTC rekey start: session=\(sessionId), trigger=\(trigger), peer=\(selectedPeerId), policy=\(selection.rawValue)"
            )
            let rekeyed = try await driver.initiateHandshake(with: peer)
            sessionKeys = rekeyed
            rekeyCompletedSessionIds.insert(sessionId)
            lastRekeyEvent = "complete suite=\(rekeyed.negotiatedSuite.rawValue)"

            if currentSessionId == sessionId {
                state = .connected(sessionId: sessionId)
                readiness = .handshakeComplete(
                    sessionId: sessionId,
                    negotiatedSuite: rekeyed.negotiatedSuite.rawValue
                )
            }

            SkyBridgeLogger.shared.info(
                "✅ WebRTC rekey complete: session=\(sessionId), suite=\(rekeyed.negotiatedSuite.rawValue)"
            )
        } catch {
            lastRekeyEvent = "failed error=\(error.localizedDescription)"
            SkyBridgeLogger.shared.error(
                "❌ WebRTC rekey failed: session=\(sessionId), trigger=\(trigger), err=\(error.localizedDescription)"
            )
        }
    }
}

@available(iOS 17.0, *)
private extension CrossNetworkWebRTCManager {
    func receiveLoop(
        sessionId: String,
        session: WebRTCSession,
        inbound: InboundChunkQueue,
        peer: PeerIdentifier,
        strictPQCRequested: Bool
    ) async {
        let maxInboundFrameBytes = 8_000_000
        do {
                self.appendSmokeTrace("receiveLoop start session=\(sessionId)")
	            var buffer = Data()
	            var readOffset = 0
	            while !Task.isCancelled {
	                // pull chunk
	                let chunk = try await inbound.next()
	                buffer.append(chunk)
	                
	                while buffer.count - readOffset >= 4 {
	                    let length: Int = buffer.withUnsafeBytes { ptr in
	                        let b0 = ptr.load(fromByteOffset: readOffset, as: UInt8.self)
	                        let b1 = ptr.load(fromByteOffset: readOffset + 1, as: UInt8.self)
	                        let b2 = ptr.load(fromByteOffset: readOffset + 2, as: UInt8.self)
	                        let b3 = ptr.load(fromByteOffset: readOffset + 3, as: UInt8.self)
	                        return (Int(b0) << 24) | (Int(b1) << 16) | (Int(b2) << 8) | Int(b3)
	                    }
	                    guard length > 0 && length < maxInboundFrameBytes else {
	                        SkyBridgeLogger.shared.warning(
	                            "⚠️ drop invalid WebRTC frame length: len=\(length) max=\(maxInboundFrameBytes) session=\(sessionId)"
	                        )
	                        buffer.removeAll(keepingCapacity: true)
	                        readOffset = 0
	                        break
	                    }
	                    guard buffer.count - readOffset >= 4 + length else { break }
	                    
	                    let start = readOffset + 4
	                    let end = start + length
	                    let payload = buffer.subdata(in: start ..< end)
	                    readOffset = end
	                    if readOffset == buffer.count || readOffset > maxInboundFrameBytes {
	                        buffer.removeSubrange(0 ..< readOffset)
	                        readOffset = 0
	                    }
	                    
	                    let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx/webrtc")
                        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                            print("🧪 WebRTC rekey rx frame len=\(length)")
                        }
                        self.appendSmokeTrace(
                            "rx frame len=\(length) rekey=\(self.rekeyInProgressSessionIds.contains(sessionId)) driver=\(self.handshakeDriver != nil) keys=\(self.sessionKeys != nil)"
                        )
	                    
	                    if let keys = self.sessionKeys {
	                        // Business payload: decrypt and route RemoteDesktop messages.
                        do {
                            let plaintext = try decrypt(ciphertext: trafficUnwrapped, with: keys)

                            if let appMessage = try? JSONDecoder().decode(AppMessage.self, from: plaintext) {
                                await handleInboundAppMessageOverWebRTC(
                                    appMessage,
                                    sessionId: sessionId,
                                    peerDeviceId: peer.deviceId,
                                    session: session,
                                    strictPQCRequested: strictPQCRequested
                                )
                                continue
                            }
                            
                            // Cross-network file transfer (acks/errors or inbound transfers from macOS)
                            if let ft = try? JSONDecoder().decode(CrossNetworkFileTransferMessage.self, from: plaintext),
                               ft.version == 1 {
                                await self.handleInboundFileTransferFromMac(ft)
                                continue
                            }
                            
                            if let msg = try? JSONDecoder().decode(RemoteMessage.self, from: plaintext) {
                                if msg.type == .screenData,
                                   let sd = try? JSONDecoder().decode(ScreenData.self, from: msg.payload) {
                                    await MainActor.run {
                                        self.lastScreenData = sd
                                        NotificationCenter.default.post(name: Notification.Name("CrossNetworkScreenDataUpdated"), object: nil)
                                    }
                                }
                            }
                        } catch {
                            // If it isn't decryptable business data, it might still be a handshake control frame; fall through.
                            if let driver = self.handshakeDriver {
                                if let messageB = try? HandshakeMessageB.decode(from: trafficUnwrapped) {
                                    self.lastRekeyEvent = "messageB suite=\(messageB.selectedSuite.rawValue)"
                                    self.appendSmokeTrace("rx messageB raw=\(trafficUnwrapped.count) suite=\(messageB.selectedSuite.rawValue)")
                                    if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                                        print("🧪 WebRTC rekey rx MessageB raw=\(trafficUnwrapped.count) suite=\(messageB.selectedSuite.rawValue)")
                                    }
                                } else if (try? HandshakeFinished.decode(from: trafficUnwrapped)) != nil {
                                    self.lastRekeyEvent = "finished"
                                    self.appendSmokeTrace("rx finished raw=\(trafficUnwrapped.count)")
                                    if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                                        print("🧪 WebRTC rekey rx Finished raw=\(trafficUnwrapped.count)")
                                    }
                                }
                                await driver.handleMessage(trafficUnwrapped, from: peer)
                            }
                        }
                    } else {
                        if let driver = self.handshakeDriver {
                            if let messageB = try? HandshakeMessageB.decode(from: trafficUnwrapped) {
                                self.lastRekeyEvent = "messageB suite=\(messageB.selectedSuite.rawValue)"
                                self.appendSmokeTrace("rx messageB raw=\(trafficUnwrapped.count) suite=\(messageB.selectedSuite.rawValue)")
                                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                                    print("🧪 WebRTC rekey rx MessageB raw=\(trafficUnwrapped.count) suite=\(messageB.selectedSuite.rawValue)")
                                }
                            } else if (try? HandshakeFinished.decode(from: trafficUnwrapped)) != nil {
                                self.lastRekeyEvent = "finished"
                                self.appendSmokeTrace("rx finished raw=\(trafficUnwrapped.count)")
                                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                                    print("🧪 WebRTC rekey rx Finished raw=\(trafficUnwrapped.count)")
                                }
                            }
                            await driver.handleMessage(trafficUnwrapped, from: peer)
                        }
                    }
                }
            }
        } catch {
            self.appendSmokeTrace("receiveLoop ended error=\(error.localizedDescription)")
        }
    }
    
    func sendFramed(_ data: Data, over session: WebRTCSession) async throws {
        try session.sendFramedPayload(data)
    }
    
    func encrypt(plaintext: Data, with keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.sendKey)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        return sealed.combined ?? Data()
    }
    
    func decrypt(ciphertext: Data, with keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.receiveKey)
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    nonisolated func appendSmokeTrace(_ line: String) {
        guard ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil else { return }
        let fileName = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_BASENAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "skybridge-smoke-status.log"
        guard !fileName.isEmpty,
              let baseCaches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }
        let url = baseCaches.appendingPathComponent("\(fileName).trace.log")
        let formatted = "[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n"
        guard let data = formatted.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
