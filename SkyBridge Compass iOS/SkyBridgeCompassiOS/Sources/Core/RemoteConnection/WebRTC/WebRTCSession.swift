import Foundation
import OSLog

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

#if canImport(WebRTC)
/// Global SSL lifecycle guard for WebRTC.
///
/// `RTCInitializeSSL()` / `RTCCleanupSSL()` manage process-wide OpenSSL state. Calling cleanup per-session can
/// break other live sessions. We therefore retain/release with reference counting and only cleanup when the
/// last session is closed.
@available(iOS 17.0, *)
private enum WebRTCSSL {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var refCount: Int = 0

    static func retain() {
        lock.lock()
        defer { lock.unlock() }
        if refCount == 0 {
            RTCInitializeSSL()
        }
        refCount += 1
    }

    static func release() {
        lock.lock()
        defer { lock.unlock() }
        refCount = max(0, refCount - 1)
        if refCount == 0 {
            RTCCleanupSSL()
        }
    }
}
#endif

#if canImport(WebRTC)
@available(iOS 17.0, *)
private enum WebRTCPeerConnectionFactoryProvider {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sharedFactory: RTCPeerConnectionFactory?

    static func factory() -> RTCPeerConnectionFactory {
        lock.lock()
        defer { lock.unlock() }
        if let sharedFactory {
            return sharedFactory
        }
        let factory = RTCPeerConnectionFactory()
        sharedFactory = factory
        return factory
    }
}
#endif

#if canImport(WebRTC)
@available(iOS 17.0, *)
private actor WebRTCOutboundFrameGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}
#endif

#if canImport(WebRTC)
@available(iOS 17.0, *)
extension WebRTCSession {
    struct RemoteInboundVideoStatsSample: Equatable {
        let type: String
        let values: [String: NSObject]
    }

    struct RemoteInboundVideoStatsSnapshot: Equatable {
        let statType: String
        let packetsReceived: Int?
        let bytesReceived: Int?
        let framesReceived: Int?
        let framesDecoded: Int?
        let frameWidth: Int?
        let frameHeight: Int?

        var size: CGSize? {
            guard let frameWidth, let frameHeight,
                  frameWidth > 0, frameHeight > 0 else {
                return nil
            }
            return CGSize(width: frameWidth, height: frameHeight)
        }

        var hasPacketEvidence: Bool {
            (framesDecoded ?? 0) > 0
                || (framesReceived ?? 0) > 0
                || (bytesReceived ?? 0) > 0
                || (packetsReceived ?? 0) > 0
        }

        var hasFrameEvidence: Bool {
            guard size != nil else { return false }
            return hasPacketEvidence
        }

        var summary: String {
            [
                "type=\(statType)",
                "packets=\(packetsReceived.map(String.init) ?? "-")",
                "bytes=\(bytesReceived.map(String.init) ?? "-")",
                "framesReceived=\(framesReceived.map(String.init) ?? "-")",
                "framesDecoded=\(framesDecoded.map(String.init) ?? "-")",
                "size=\(frameWidth.map(String.init) ?? "-")x\(frameHeight.map(String.init) ?? "-")"
            ].joined(separator: " ")
        }
    }

    static func remoteInboundVideoStatsSnapshot(
        from samples: [RemoteInboundVideoStatsSample]
    ) -> RemoteInboundVideoStatsSnapshot? {
        let videoSamples = samples.filter { sample in
            let sampleType = sample.type.lowercased()
            if sampleType == "data-channel"
                || sampleType == "candidate-pair"
                || sampleType == "transport"
                || sampleType == "local-candidate"
                || sampleType == "remote-candidate" {
                return false
            }
            let kind = stringValue(sample.values, key: "kind")?.lowercased()
                ?? stringValue(sample.values, key: "mediaType")?.lowercased()
            if let kind, kind != "video" {
                return false
            }
            return kind == "video"
                || sampleType == "inbound-rtp"
                || sampleType == "track"
                || sampleType == "receiver"
                || sampleType == "media-source"
                || sampleType == "media-playout"
                || sample.values["frameWidth"] != nil
                || sample.values["frameHeight"] != nil
                || sample.values["framesDecoded"] != nil
                || sample.values["framesReceived"] != nil
        }

        guard !videoSamples.isEmpty else { return nil }

        let primaryType = videoSamples
            .max { lhs, rhs in samplePriority(lhs) < samplePriority(rhs) }?
            .type ?? "aggregate"

        var packetsReceived: Int?
        var bytesReceived: Int?
        var framesReceived: Int?
        var framesDecoded: Int?
        var frameWidth: Int?
        var frameHeight: Int?

        for sample in videoSamples {
            packetsReceived = mergeMetric(
                packetsReceived,
                intValue(sample.values, key: "packetsReceived")
            )
            bytesReceived = mergeMetric(
                bytesReceived,
                intValue(sample.values, key: "bytesReceived")
            )
            framesReceived = mergeMetric(
                framesReceived,
                intValue(sample.values, key: "framesReceived")
            )
            framesDecoded = mergeMetric(
                framesDecoded,
                intValue(sample.values, key: "framesDecoded")
            )
            frameWidth = mergeMetric(
                frameWidth,
                intValue(sample.values, key: "frameWidth")
                    ?? intValue(sample.values, key: "width")
            )
            frameHeight = mergeMetric(
                frameHeight,
                intValue(sample.values, key: "frameHeight")
                    ?? intValue(sample.values, key: "height")
            )
        }

        return RemoteInboundVideoStatsSnapshot(
            statType: primaryType,
            packetsReceived: packetsReceived,
            bytesReceived: bytesReceived,
            framesReceived: framesReceived,
            framesDecoded: framesDecoded,
            frameWidth: frameWidth,
            frameHeight: frameHeight
        )
    }

    private static func samplePriority(_ sample: RemoteInboundVideoStatsSample) -> Int {
        var score = 0
        switch sample.type.lowercased() {
        case "inbound-rtp":
            score += 500
        case "track":
            score += 300
        case "media-playout":
            score += 200
        default:
            break
        }
        if intValue(sample.values, key: "framesDecoded") != nil { score += 100 }
        if intValue(sample.values, key: "frameWidth") != nil || intValue(sample.values, key: "width") != nil {
            score += 50
        }
        if intValue(sample.values, key: "frameHeight") != nil || intValue(sample.values, key: "height") != nil {
            score += 50
        }
        return score
    }

    private static func snapshotPriority(_ snapshot: RemoteInboundVideoStatsSnapshot) -> Int {
        var score = 0
        if snapshot.hasFrameEvidence { score += 10_000 }
        score += min(snapshot.framesDecoded ?? 0, 5_000)
        score += min(snapshot.framesReceived ?? 0, 2_500)
        score += min((snapshot.bytesReceived ?? 0) / 1_024, 1_000)
        switch snapshot.statType.lowercased() {
        case "inbound-rtp":
            score += 200
        case "track":
            score += 150
        case "media-playout":
            score += 100
        default:
            break
        }
        return score
    }

    private static func mergeMetric(_ current: Int?, _ candidate: Int?) -> Int? {
        switch (current, candidate) {
        case let (lhs?, rhs?):
            return max(lhs, rhs)
        case (nil, let rhs?):
            return rhs
        default:
            return current
        }
    }

    private static func intValue(_ values: [String: NSObject], key: String) -> Int? {
        guard let raw = values[key] else { return nil }
        if let number = raw as? NSNumber {
            return number.intValue
        }
        if let string = raw as? NSString {
            return Int(string.doubleValue.rounded())
        }
        return nil
    }

    private static func stringValue(_ values: [String: NSObject], key: String) -> String? {
        guard let raw = values[key] else { return nil }
        if let string = raw as? NSString {
            let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return String(describing: raw)
    }
}
#endif

@available(iOS 17.0, *)
public final class WebRTCSession: NSObject, @unchecked Sendable {
    public struct SelectedICECandidateEvidence: Equatable, Sendable {
        public let route: String
        public let localCandidateType: String
        public let remoteCandidateType: String
        public let networkProtocol: String
    }
    public enum Role: Sendable { case offerer, answerer }
    
    public struct ICEConfig: Sendable {
        public var stunURL: String
        public var turnURLs: [String]
        public var turnUsername: String
        public var turnPassword: String

        public var turnURL: String {
            get { turnURLs.first ?? "" }
            set { turnURLs = [newValue] }
        }

        public init(stunURL: String, turnURLs: [String], turnUsername: String, turnPassword: String) {
            self.stunURL = stunURL
            self.turnURLs = turnURLs
            self.turnUsername = turnUsername
            self.turnPassword = turnPassword
        }
        
        public init(stunURL: String, turnURL: String, turnUsername: String, turnPassword: String) {
            self.stunURL = stunURL
            self.turnURLs = turnURL.isEmpty ? [] : [turnURL]
            self.turnUsername = turnUsername
            self.turnPassword = turnPassword
        }
    }
    
    public enum WebRTCError: Error, LocalizedError, Sendable {
        case webRTCNotAvailable
        case peerConnectionCreationFailed
        case dataChannelNotReady
        case dataChannelNotOpen
        case dataChannelSendFailed
        case alreadyClosed
        
        public var errorDescription: String? {
            switch self {
            case .webRTCNotAvailable: return "WebRTC 模块不可用（请确认已添加 WebRTC 依赖）"
            case .peerConnectionCreationFailed: return "创建 RTCPeerConnection 失败"
            case .dataChannelNotReady: return "DataChannel 未就绪"
            case .dataChannelNotOpen: return "DataChannel 未打开"
            case .dataChannelSendFailed: return "DataChannel 发送失败"
            case .alreadyClosed: return "WebRTCSession 已关闭"
            }
        }
    }
    
    private let logger = Logger(subsystem: "com.skybridge.compass.ios", category: "WebRTCSession")
    private static let publicFallbackSTUNURL = "stun:stun.l.google.com:19302"
    private static let controlChannelLabel = "skybridge"
    private static let screenChannelLabel = "skybridge-screen"
    
    public let sessionId: String
    public let localDeviceId: String
    public let role: Role
    public let ice: ICEConfig
    
    public var onLocalOffer: (@Sendable (String) -> Void)?
    public var onLocalAnswer: (@Sendable (String) -> Void)?
    public var onLocalICECandidate: (@Sendable (WebRTCSignalingEnvelope.Payload) -> Void)?
    public var onData: (@Sendable (Data) -> Void)? {
        didSet {
            flushPendingInboundDataIfNeeded()
        }
    }
    public var onScreenData: (@Sendable (Data) -> Void)? {
        didSet {
            flushPendingInboundScreenDataIfNeeded()
        }
    }
#if canImport(WebRTC)
    public var onRemoteVideoTrack: ((RTCVideoTrack?) -> Void)?
#endif
    public var onRemoteVideoFrameEvidence: (@Sendable (CGSize, String) -> Void)?
    public var onRemoteVideoFirstPacket: (@Sendable () -> Void)?
    public var onReady: (@Sendable () -> Void)?
    public var onDisconnected: (@Sendable (String) -> Void)?
    public var onTrace: (@Sendable (String) -> Void)?
    
#if canImport(WebRTC)
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var screenDataChannel: RTCDataChannel?
    private var remoteVideoTrack: RTCVideoTrack?
    private var remoteVideoReceiver: RTCRtpReceiver?
    private var videoTransceiver: RTCRtpTransceiver?
    private var remoteVideoTrackInspectionTask: Task<Void, Never>?
    private var remoteVideoFrameEvidenceTask: Task<Void, Never>?
    private var didEmitRemoteVideoFrameEvidence = false
    private var pendingRemoteICECandidates: [RTCIceCandidate] = []
    private var seenRemoteICECandidateKeys: Set<String> = []
#endif
    
	    private var isClosed = false
	    private var sslHeld = false
	    private var didNotifyDisconnected = false
	    private var didNotifyReady = false
    private var hasRemoteDescription = false
    private var isSettingRemoteDescription = false
    private var lastEmittedLocalSDP: String?
    private let inboundDataLock = NSLock()
    private let inboundScreenDataLock = NSLock()
    private let outboundFrameLock = NSLock()
    private let outboundScreenFrameLock = NSLock()
    private let outboundFrameGate = WebRTCOutboundFrameGate()
    private let outboundScreenFrameGate = WebRTCOutboundFrameGate()
    private var pendingInboundDataBuffers: [Data] = []
    private var pendingInboundScreenDataBuffers: [Data] = []
    
    public init(sessionId: String, localDeviceId: String, role: Role, ice: ICEConfig) {
        self.sessionId = sessionId
        self.localDeviceId = localDeviceId
        self.role = role
        self.ice = ice
        super.init()
    }
    
    /// 关闭 WebRTC 会话并释放所有资源（PeerConnection / DataChannel / SSL）。
    ///
    /// 符合 IEEE TDSC 安全生命周期管理要求：
    /// - 主动关闭 DataChannel 防止数据残留
    /// - 关闭 PeerConnection 终止 ICE / DTLS-SRTP 会话
    /// - 调用 RTCCleanupSSL() 释放 OpenSSL 上下文
    public func close() {
        guard !isClosed else { return }
        onTrace?("close session=\(sessionId)")
        isClosed = true
	        didNotifyDisconnected = true
	        didNotifyReady = false
	        hasRemoteDescription = false
	        isSettingRemoteDescription = false
        lastEmittedLocalSDP = nil
	        onDisconnected = nil
#if canImport(WebRTC)
        pendingRemoteICECandidates.removeAll(keepingCapacity: false)
        seenRemoteICECandidateKeys.removeAll(keepingCapacity: false)
        dataChannel?.close()
        dataChannel = nil
        screenDataChannel?.close()
        screenDataChannel = nil
        remoteVideoTrack = nil
        remoteVideoReceiver?.delegate = nil
        remoteVideoReceiver = nil
        videoTransceiver = nil
        remoteVideoTrackInspectionTask?.cancel()
        remoteVideoTrackInspectionTask = nil
        remoteVideoFrameEvidenceTask?.cancel()
        remoteVideoFrameEvidenceTask = nil
        didEmitRemoteVideoFrameEvidence = false
        peerConnection?.close()
        peerConnection = nil
        if sslHeld {
            sslHeld = false
            WebRTCSSL.release()
        }
#endif
        onLocalOffer = nil
        onLocalAnswer = nil
        onLocalICECandidate = nil
        inboundDataLock.lock()
        pendingInboundDataBuffers.removeAll(keepingCapacity: false)
        inboundDataLock.unlock()
        inboundScreenDataLock.lock()
        pendingInboundScreenDataBuffers.removeAll(keepingCapacity: false)
        inboundScreenDataLock.unlock()
        onData = nil
        onScreenData = nil
#if canImport(WebRTC)
        onRemoteVideoTrack = nil
#endif
        onReady = nil
        logger.info("⏹️ WebRTCSession closed sessionId=\(self.sessionId, privacy: .public)")
    }
    
    deinit {
        close()
    }

    private static func normalizedICEURL(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("stun:") || value.hasPrefix("turn:") || value.hasPrefix("turns:") {
            return value
        }
        return nil
    }

    private static func normalizedCredential(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

#if canImport(WebRTC)
    private static var shouldForceRelayOnlyForSmoke: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil &&
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_FORCE_RELAY_ICE"] == "1"
    }

    private func buildIceServers() -> [RTCIceServer] {
        var servers: [RTCIceServer] = []

        if let stunURL = Self.normalizedICEURL(ice.stunURL), stunURL.hasPrefix("stun:") {
            servers.append(RTCIceServer(urlStrings: [stunURL]))
        } else {
            logger.warning("⚠️ Invalid STUN URL. sessionId=\(self.sessionId, privacy: .public)")
        }

        let turnURLs = ice.turnURLs.compactMap(Self.normalizedICEURL)
        let validTurnURLs = Array(Set(turnURLs)).sorted { lhs, rhs in
            let lhsLower = lhs.lowercased()
            let rhsLower = rhs.lowercased()
            if lhsLower.hasPrefix("turns:") == rhsLower.hasPrefix("turns:") {
                return lhs < rhs
            }
            return lhsLower.hasPrefix("turns:")
        }
        let turnUsername = Self.normalizedCredential(ice.turnUsername)
        let turnPassword = Self.normalizedCredential(ice.turnPassword)

        if !validTurnURLs.isEmpty {
            if !turnUsername.isEmpty, !turnPassword.isEmpty {
                servers.append(RTCIceServer(urlStrings: validTurnURLs, username: turnUsername, credential: turnPassword))
            } else {
                logger.warning("⚠️ TURN credentials missing, degraded to STUN-only. sessionId=\(self.sessionId, privacy: .public)")
            }
        } else if !ice.turnURLs.isEmpty {
            logger.warning("⚠️ Invalid TURN URLs. sessionId=\(self.sessionId, privacy: .public)")
        }

        if servers.isEmpty {
            servers.append(RTCIceServer(urlStrings: [Self.publicFallbackSTUNURL]))
            logger.warning("⚠️ No valid ICE servers, fallback to public STUN. sessionId=\(self.sessionId, privacy: .public)")
        }

        return servers
    }
#endif
    
    public func start() throws {
        guard !isClosed else { throw WebRTCError.alreadyClosed }
        didNotifyDisconnected = false
        didNotifyReady = false
        hasRemoteDescription = false
        lastEmittedLocalSDP = nil
#if canImport(WebRTC)
        pendingRemoteICECandidates.removeAll(keepingCapacity: false)
        seenRemoteICECandidateKeys.removeAll(keepingCapacity: false)
        WebRTCSSL.retain()
        sslHeld = true
        let factory = WebRTCPeerConnectionFactoryProvider.factory()
        
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        if Self.shouldForceRelayOnlyForSmoke {
            config.iceTransportPolicy = .relay
            config.continualGatheringPolicy = .gatherOnce
        } else {
            config.continualGatheringPolicy = .gatherContinually
        }
        config.iceServers = buildIceServers()
        
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            logger.error("❌ RTCPeerConnection creation failed: sessionId=\(self.sessionId, privacy: .public) iceServerCount=\(config.iceServers.count, privacy: .public)")
            sslHeld = false
            WebRTCSSL.release()
            throw WebRTCError.peerConnectionCreationFailed
        }
        self.peerConnection = pc
        configureIncomingScreenVideoIfNeeded(peerConnection: pc)
        
        if role == .offerer {
            let dcConfig = RTCDataChannelConfiguration()
            dcConfig.isOrdered = true
            dcConfig.isNegotiated = false
            let dc = pc.dataChannel(forLabel: Self.controlChannelLabel, configuration: dcConfig)
            dc?.delegate = self
            self.dataChannel = dc
            onTrace?("start-offerer session=\(sessionId) iceServers=\(config.iceServers.count)")
            createOffer()
        } else {
            onTrace?("start-answerer session=\(sessionId) iceServers=\(config.iceServers.count)")
        }
        
        logger.info("✅ WebRTCSession started role=\(String(describing: self.role), privacy: .public) sessionId=\(self.sessionId, privacy: .public)")
#else
        throw WebRTCError.webRTCNotAvailable
#endif
    }

    private func notifyDisconnectedIfNeeded(reason: String) {
        guard !didNotifyDisconnected else { return }
        didNotifyDisconnected = true
        onDisconnected?(reason)
    }

    private func notifyReadyIfNeeded() {
        guard !didNotifyReady else { return }
        didNotifyReady = true
        onReady?()
    }

    private func flushPendingInboundDataIfNeeded() {
        let handler: (@Sendable (Data) -> Void)?
        var buffered: [Data] = []
        inboundDataLock.lock()
        handler = onData
        if handler != nil, !pendingInboundDataBuffers.isEmpty {
            buffered = pendingInboundDataBuffers
            pendingInboundDataBuffers.removeAll(keepingCapacity: false)
        }
        inboundDataLock.unlock()

        guard let handler else { return }
        buffered.forEach(handler)
    }

    private func flushPendingInboundScreenDataIfNeeded() {
        let handler: (@Sendable (Data) -> Void)?
        var buffered: [Data] = []
        inboundScreenDataLock.lock()
        handler = onScreenData
        if handler != nil, !pendingInboundScreenDataBuffers.isEmpty {
            buffered = pendingInboundScreenDataBuffers
            pendingInboundScreenDataBuffers.removeAll(keepingCapacity: false)
        }
        inboundScreenDataLock.unlock()

        guard let handler else { return }
        buffered.forEach(handler)
    }

    private func deliverInboundData(_ data: Data) {
        let handler: (@Sendable (Data) -> Void)?
        var buffered: [Data] = []
        inboundDataLock.lock()
        if let activeHandler = onData {
            handler = activeHandler
            if !pendingInboundDataBuffers.isEmpty {
                buffered = pendingInboundDataBuffers
                pendingInboundDataBuffers.removeAll(keepingCapacity: false)
            }
        } else {
            pendingInboundDataBuffers.append(data)
            handler = nil
        }
        inboundDataLock.unlock()

        guard let handler else { return }
        buffered.forEach(handler)
        handler(data)
    }

    private func deliverInboundScreenData(_ data: Data) {
        let handler: (@Sendable (Data) -> Void)?
        var buffered: [Data] = []
        inboundScreenDataLock.lock()
        if let activeHandler = onScreenData {
            handler = activeHandler
            if !pendingInboundScreenDataBuffers.isEmpty {
                buffered = pendingInboundScreenDataBuffers
                pendingInboundScreenDataBuffers.removeAll(keepingCapacity: false)
            }
        } else {
            pendingInboundScreenDataBuffers.append(data)
            handler = nil
        }
        inboundScreenDataLock.unlock()

        guard let handler else { return }
        buffered.forEach(handler)
        handler(data)
    }

    private func isScreenChannel(_ dataChannel: RTCDataChannel) -> Bool {
#if canImport(WebRTC)
        dataChannel.label == Self.screenChannelLabel
#else
        false
#endif
    }

    private func isControlChannel(_ dataChannel: RTCDataChannel) -> Bool {
#if canImport(WebRTC)
        dataChannel.label == Self.controlChannelLabel || dataChannel.label.isEmpty
#else
        false
#endif
    }
    
    public func setRemoteOffer(_ sdp: String) {
#if canImport(WebRTC)
        onTrace?("set-remote-offer session=\(sessionId) bytes=\(sdp.utf8.count)")
        let normalizedOffer = Self.normalizedRemoteSDP(sdp)
        if hasRemoteDescription || isSettingRemoteDescription {
            absorbRemoteICECandidatesFromSDP(normalizedOffer.sdp, traceLabel: "duplicate-offer")
            logger.debug("ℹ️ ignore duplicate remote offer. sessionId=\(self.sessionId, privacy: .public)")
            onTrace?("set-remote-offer ignored duplicate session=\(sessionId)")
            return
        }
        guard let pc = peerConnection else { return }
        if pc.remoteDescription != nil {
            hasRemoteDescription = true
            absorbRemoteICECandidatesFromSDP(normalizedOffer.sdp, traceLabel: "existing-offer")
            flushPendingRemoteICECandidates()
            logger.debug("ℹ️ remote offer already applied; ignore. sessionId=\(self.sessionId, privacy: .public)")
            onTrace?("set-remote-offer ignored existing session=\(sessionId)")
            return
        }
        if normalizedOffer.droppedSessionLevelCandidateLines > 0 || normalizedOffer.deduplicatedCandidateLines > 0 {
            onTrace?(
                "normalize-remote-offer session=\(sessionId) droppedSessionCandidates=\(normalizedOffer.droppedSessionLevelCandidateLines) dedupedCandidates=\(normalizedOffer.deduplicatedCandidateLines)"
            )
        }
        let desc = RTCSessionDescription(type: .offer, sdp: normalizedOffer.sdp)
        isSettingRemoteDescription = true
        pc.setRemoteDescription(desc) { [weak self] error in
            guard let self else { return }
            self.isSettingRemoteDescription = false
            if let error {
                self.logger.error("❌ setRemoteOffer failed: \(error.localizedDescription, privacy: .public)")
                self.onTrace?("set-remote-offer failed session=\(self.sessionId) error=\(error.localizedDescription)")
                return
            }
            self.hasRemoteDescription = true
            self.flushPendingRemoteICECandidates()
            self.inspectRemoteVideoTrackIfAvailable(peerConnection: pc)
            self.scheduleRemoteVideoTrackInspection(peerConnection: pc, reason: "set-remote-offer")
            self.onTrace?("set-remote-offer applied session=\(self.sessionId)")
            self.createAnswer()
        }
#endif
    }
    
    public func setRemoteAnswer(_ sdp: String) {
#if canImport(WebRTC)
        onTrace?("set-remote-answer session=\(sessionId) bytes=\(sdp.utf8.count)")
        guard let pc = peerConnection else { return }
        let normalizedAnswer = Self.normalizedRemoteSDP(sdp)
        if hasRemoteDescription || isSettingRemoteDescription || pc.remoteDescription != nil {
            hasRemoteDescription = true
            absorbRemoteICECandidatesFromSDP(normalizedAnswer.sdp, traceLabel: "duplicate-answer")
            flushPendingRemoteICECandidates()
            logger.debug("ℹ️ ignore duplicate remote answer. sessionId=\(self.sessionId, privacy: .public)")
            onTrace?("set-remote-answer ignored duplicate session=\(sessionId)")
            return
        }
        if normalizedAnswer.droppedSessionLevelCandidateLines > 0 || normalizedAnswer.deduplicatedCandidateLines > 0 {
            onTrace?(
                "normalize-remote-answer session=\(sessionId) droppedSessionCandidates=\(normalizedAnswer.droppedSessionLevelCandidateLines) dedupedCandidates=\(normalizedAnswer.deduplicatedCandidateLines)"
            )
        }
        let desc = RTCSessionDescription(type: .answer, sdp: normalizedAnswer.sdp)
        isSettingRemoteDescription = true
        pc.setRemoteDescription(desc) { [weak self] error in
            guard let self else { return }
            self.isSettingRemoteDescription = false
            if let error {
	                // When the peer resends the same answer before our first callback returns,
	                // WebRTC may already be stable and reject the duplicate call.
                if pc.signalingState == .stable || pc.remoteDescription != nil {
                    self.hasRemoteDescription = true
                    self.flushPendingRemoteICECandidates()
                    self.inspectRemoteVideoTrackIfAvailable(peerConnection: pc)
                    self.scheduleRemoteVideoTrackInspection(peerConnection: pc, reason: "set-remote-answer-stable")
                    self.logger.debug("ℹ️ remote answer already applied; ignore. sessionId=\(self.sessionId, privacy: .public)")
                    self.onTrace?("set-remote-answer ignored stable session=\(self.sessionId)")
                    return
                }
                self.logger.error("❌ setRemoteAnswer failed: \(error.localizedDescription, privacy: .public)")
                self.onTrace?("set-remote-answer failed session=\(self.sessionId) error=\(error.localizedDescription)")
                return
            }
            self.hasRemoteDescription = true
            self.flushPendingRemoteICECandidates()
            self.inspectRemoteVideoTrackIfAvailable(peerConnection: pc)
            self.scheduleRemoteVideoTrackInspection(peerConnection: pc, reason: "set-remote-answer")
            self.onTrace?("set-remote-answer applied session=\(self.sessionId)")
        }
#endif
    }
    
    public func addRemoteICECandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int32?) {
#if canImport(WebRTC)
        let cand = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex ?? 0, sdpMid: sdpMid)
        guard trackRemoteICECandidateIfNeeded(cand) else { return }
        guard hasRemoteDescription else {
            pendingRemoteICECandidates.append(cand)
            logger.debug("⏳ queue remote ICE candidate until remote description is set. sessionId=\(self.sessionId, privacy: .public) pending=\(self.pendingRemoteICECandidates.count, privacy: .public)")
            onTrace?("queue-remote-ice session=\(sessionId) pending=\(pendingRemoteICECandidates.count)")
            return
        }
        onTrace?("apply-remote-ice session=\(sessionId)")
        addRemoteICECandidateInternal(cand)
#endif
    }

#if canImport(WebRTC)
    private func trackRemoteICECandidateIfNeeded(_ candidate: RTCIceCandidate) -> Bool {
        let normalizedSDP: String
        if candidate.sdp.hasPrefix("a=") {
            normalizedSDP = String(candidate.sdp.dropFirst(2))
        } else {
            normalizedSDP = candidate.sdp
        }
        let mid = candidate.sdpMid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = "\(candidate.sdpMLineIndex)|\(mid)|\(normalizedSDP)"
        return seenRemoteICECandidateKeys.insert(key).inserted
    }

    private func addRemoteICECandidateInternal(_ candidate: RTCIceCandidate) {
        guard let pc = peerConnection else { return }
        pc.add(candidate) { [weak self] error in
            guard let self else { return }
            if let error {
                self.logger.error("⚠️ addIceCandidate failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func flushPendingRemoteICECandidates() {
        guard hasRemoteDescription else { return }
        guard !pendingRemoteICECandidates.isEmpty else { return }

        let pending = pendingRemoteICECandidates
        pendingRemoteICECandidates.removeAll(keepingCapacity: false)
        logger.info("🔄 applying queued remote ICE candidates. sessionId=\(self.sessionId, privacy: .public) count=\(pending.count, privacy: .public)")
        for candidate in pending {
            addRemoteICECandidateInternal(candidate)
        }
    }

    private func absorbRemoteICECandidatesFromSDP(_ sdp: String, traceLabel: String) {
        let extracted = Self.extractRemoteICECandidates(from: sdp)
        guard !extracted.isEmpty else { return }

        var absorbed = 0
        for candidate in extracted where trackRemoteICECandidateIfNeeded(candidate) {
            absorbed += 1
            if hasRemoteDescription {
                addRemoteICECandidateInternal(candidate)
            } else {
                pendingRemoteICECandidates.append(candidate)
            }
        }

        guard absorbed > 0 else { return }
        logger.info("🔄 absorbed ICE candidates from duplicate SDP. sessionId=\(self.sessionId, privacy: .public) count=\(absorbed, privacy: .public)")
        onTrace?("absorb-remote-ice session=\(sessionId) source=\(traceLabel) count=\(absorbed)")
    }

    private func configureIncomingScreenVideoIfNeeded(peerConnection: RTCPeerConnection) {
        guard videoTransceiver == nil else { return }
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .recvOnly
        transceiverInit.streamIds = ["screen-\(sessionId)"]
        videoTransceiver = peerConnection.addTransceiver(of: .video, init: transceiverInit)
    }

    private func captureRemoteVideoTrack(_ track: RTCVideoTrack?, receiver: RTCRtpReceiver? = nil) {
        if let receiver {
            if remoteVideoReceiver?.isEqual(receiver) == false {
                remoteVideoReceiver?.delegate = nil
            }
            remoteVideoReceiver = receiver
            remoteVideoReceiver?.delegate = self
        }
        guard remoteVideoTrack !== track else {
            if track != nil,
               remoteVideoFrameEvidenceTask == nil,
               !didEmitRemoteVideoFrameEvidence {
                startRemoteVideoFrameEvidenceObservation()
            }
            return
        }
        let previousTrackId = remoteVideoTrack?.trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingTrackId = track?.trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        let isTrackRebind =
            (previousTrackId?.isEmpty == false)
            && previousTrackId == incomingTrackId
            && track != nil
        if let incomingTrackId,
           !incomingTrackId.isEmpty,
           isTrackRebind {
            logger.info(
                "🔁 rebind remote native video track after receiver replaced backing instance. sessionId=\(self.sessionId, privacy: .public) trackId=\(incomingTrackId, privacy: .public)"
            )
            onTrace?("remote-video-track rebind session=\(sessionId) trackId=\(incomingTrackId)")
        }
        remoteVideoFrameEvidenceTask?.cancel()
        remoteVideoFrameEvidenceTask = nil
        didEmitRemoteVideoFrameEvidence = isTrackRebind ? didEmitRemoteVideoFrameEvidence : false
        remoteVideoTrack = track
        if track != nil {
            logger.info("🎬 detected remote native video track. sessionId=\(self.sessionId, privacy: .public)")
            remoteVideoTrackInspectionTask?.cancel()
            remoteVideoTrackInspectionTask = nil
            startRemoteVideoFrameEvidenceObservation()
        } else {
            didEmitRemoteVideoFrameEvidence = false
            remoteVideoReceiver = nil
        }
        onTrace?("remote-video-track session=\(sessionId) ready=\(track != nil ? 1 : 0)")
        onRemoteVideoTrack?(track)
    }

    private func startRemoteVideoFrameEvidenceObservation() {
        guard !didEmitRemoteVideoFrameEvidence else { return }
        remoteVideoFrameEvidenceTask?.cancel()
        remoteVideoFrameEvidenceTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            var lastProbeLogAt = Date.distantPast
            var didEmitPacketEvidence = false
            while !Task.isCancelled {
                if attempt > 0 {
                    let delay: Duration = attempt < 8 ? .milliseconds(250) : .seconds(1)
                    try? await Task.sleep(for: delay)
                }
                attempt += 1
                guard !Task.isCancelled else { return }
                guard self.peerConnection != nil, self.remoteVideoTrack != nil else { return }
                let receiverSamples: [RemoteInboundVideoStatsSample]
                if let receiver = self.resolveRemoteVideoReceiver() {
                    receiverSamples = await self.remoteInboundVideoStatsSamples(for: receiver)
                    guard !Task.isCancelled else { return }
                } else {
                    receiverSamples = []
                }

                var snapshots: [RemoteInboundVideoStatsSnapshot] = []
                if let receiverSnapshot = Self.remoteInboundVideoStatsSnapshot(from: receiverSamples) {
                    snapshots.append(receiverSnapshot)
                }
                if snapshots.isEmpty || !snapshots.contains(where: \.hasFrameEvidence) {
                    let peerSamples = await self.allPeerConnectionVideoStatsSamples()
                    guard !Task.isCancelled else { return }
                    if let peerSnapshot = Self.remoteInboundVideoStatsSnapshot(from: peerSamples) {
                        snapshots.append(peerSnapshot)
                    }
                }

                guard let snapshot = snapshots.max(
                    by: { lhs, rhs in Self.snapshotPriority(lhs) < Self.snapshotPriority(rhs) }
                ) else {
                    continue
                }

                let now = Date()
                if now.timeIntervalSince(lastProbeLogAt) >= 1.0 {
                    lastProbeLogAt = now
                    self.logger.debug(
                        "📈 remote native video receiver stats probe. sessionId=\(self.sessionId, privacy: .public) \(snapshot.summary, privacy: .public)"
                    )
                    self.onTrace?(
                        "remote-video-stats session=\(self.sessionId) \(snapshot.summary)"
                    )
                }

                if snapshot.hasPacketEvidence, !didEmitPacketEvidence {
                    didEmitPacketEvidence = true
                    self.onRemoteVideoFirstPacket?()
                }

                guard snapshot.hasFrameEvidence, let size = snapshot.size else {
                    continue
                }
                guard !self.didEmitRemoteVideoFrameEvidence else { return }
                self.didEmitRemoteVideoFrameEvidence = true
                self.remoteVideoFrameEvidenceTask = nil
                self.logger.info(
                    "🎬 remote native video receiver stats confirmed first frame. sessionId=\(self.sessionId, privacy: .public) \(snapshot.summary, privacy: .public)"
                )
                self.onTrace?(
                    "remote-video-frame-evidence session=\(self.sessionId) source=receiver-stats \(snapshot.summary)"
                )
                self.onRemoteVideoFrameEvidence?(size, "receiver-stats")
                return
            }
        }
    }

    private func remoteInboundVideoStatsSamples(
        for receiver: RTCRtpReceiver
    ) async -> [RemoteInboundVideoStatsSample] {
        await withCheckedContinuation { continuation in
            guard let peerConnection else {
                continuation.resume(returning: [])
                return
            }
            peerConnection.statistics(for: receiver) { report in
                let samples = report.statistics.values.map { statistic in
                    RemoteInboundVideoStatsSample(type: statistic.type, values: statistic.values)
                }
                continuation.resume(returning: samples)
            }
        }
    }

    private func allPeerConnectionVideoStatsSamples() async -> [RemoteInboundVideoStatsSample] {
        await withCheckedContinuation { continuation in
            guard let peerConnection else {
                continuation.resume(returning: [])
                return
            }
            peerConnection.statistics { report in
                let samples = report.statistics.values.map { statistic in
                    RemoteInboundVideoStatsSample(type: statistic.type, values: statistic.values)
                }
                continuation.resume(returning: samples)
            }
        }
    }

    public func selectedICECandidateEvidence() async -> SelectedICECandidateEvidence? {
        let statistics: [String: RTCStatistics] = await withCheckedContinuation { continuation in
            guard let peerConnection else {
                continuation.resume(returning: [:])
                return
            }
            peerConnection.statistics { report in
                continuation.resume(returning: report.statistics)
            }
        }
        let selectedPairIDs = statistics.values.compactMap { statistic -> String? in
            guard statistic.type == "transport" else { return nil }
            return Self.statisticsString(statistic.values["selectedCandidatePairId"])
        }
        guard Set(selectedPairIDs).count == 1,
              let selectedPairID = selectedPairIDs.first,
              let pair = statistics[selectedPairID],
              pair.type == "candidate-pair",
              Self.statisticsString(pair.values["state"]) == "succeeded",
              let localID = Self.statisticsString(pair.values["localCandidateId"]),
              let remoteID = Self.statisticsString(pair.values["remoteCandidateId"]),
              let local = statistics[localID],
              let remote = statistics[remoteID],
              local.type == "local-candidate",
              remote.type == "remote-candidate",
              let localType = Self.canonicalCandidateType(
                Self.statisticsString(local.values["candidateType"])
              ),
              let remoteType = Self.canonicalCandidateType(
                Self.statisticsString(remote.values["candidateType"])
              ) else {
            return nil
        }
        let route = localType == "relay" || remoteType == "relay" ? "relay" : "direct"
        let networkProtocol = Self.statisticsString(local.values["protocol"])?
            .lowercased() ?? "unknown"
        guard networkProtocol == "udp" || networkProtocol == "tcp" else { return nil }
        return SelectedICECandidateEvidence(
            route: route,
            localCandidateType: localType,
            remoteCandidateType: remoteType,
            networkProtocol: networkProtocol
        )
    }

    private static func statisticsString(_ value: NSObject?) -> String? {
        guard let raw = value as? NSString else { return nil }
        let string = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }

    private static func canonicalCandidateType(_ value: String?) -> String? {
        guard let value = value?.lowercased(),
              ["host", "srflx", "prflx", "relay"].contains(value) else {
            return nil
        }
        return value
    }

    private func resolveRemoteVideoReceiver() -> RTCRtpReceiver? {
        if let remoteVideoReceiver {
            remoteVideoReceiver.delegate = self
            return remoteVideoReceiver
        }
        if let receiver = videoTransceiver?.receiver {
            remoteVideoReceiver = receiver
            remoteVideoReceiver?.delegate = self
            return receiver
        }
        guard let peerConnection else { return nil }
        for transceiver in peerConnection.transceivers where transceiver.mediaType == .video {
            remoteVideoReceiver = transceiver.receiver
            remoteVideoReceiver?.delegate = self
            return transceiver.receiver
        }
        for receiver in peerConnection.receivers where receiver.track is RTCVideoTrack {
            remoteVideoReceiver = receiver
            remoteVideoReceiver?.delegate = self
            return receiver
        }
        return nil
    }

    private func inspectRemoteVideoTrackIfAvailable(peerConnection: RTCPeerConnection) {
        for transceiver in peerConnection.transceivers where transceiver.mediaType == .video {
            if let track = transceiver.receiver.track as? RTCVideoTrack {
                captureRemoteVideoTrack(track, receiver: transceiver.receiver)
                return
            }
        }
    }

    private func scheduleRemoteVideoTrackInspection(
        peerConnection: RTCPeerConnection,
        reason: String
    ) {
        guard remoteVideoTrack == nil else { return }
        remoteVideoTrackInspectionTask?.cancel()
        remoteVideoTrackInspectionTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 1...15 {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                self.inspectRemoteVideoTrackIfAvailable(peerConnection: peerConnection)
                if self.remoteVideoTrack != nil {
                    self.onTrace?("remote-video-track inspection-success session=\(self.sessionId) reason=\(reason) attempt=\(attempt)")
                    return
                }
            }
            self.logger.debug("ℹ️ remote native video track still unavailable after inspection. sessionId=\(self.sessionId, privacy: .public) reason=\(reason, privacy: .public)")
            self.onTrace?("remote-video-track inspection-timeout session=\(self.sessionId) reason=\(reason)")
        }
    }
#endif
    
    public func ensureScreenDataChannel() throws {
        guard !isClosed else { throw WebRTCError.alreadyClosed }
#if canImport(WebRTC)
        guard let pc = peerConnection else { throw WebRTCError.peerConnectionCreationFailed }
        if let screenDataChannel {
            screenDataChannel.delegate = self
            return
        }
        let configuration = RTCDataChannelConfiguration()
        configuration.isOrdered = true
        configuration.isNegotiated = false
        configuration.`protocol` = "screen-frame-v1"
        let channel = pc.dataChannel(forLabel: Self.screenChannelLabel, configuration: configuration)
        guard let channel else { throw WebRTCError.dataChannelNotReady }
        channel.delegate = self
        screenDataChannel = channel
#else
        throw WebRTCError.webRTCNotAvailable
#endif
    }

    public func send(_ data: Data) throws {
        try send(data, preferScreenChannel: false, fallbackToControlChannel: false)
    }

    public func sendScreen(_ data: Data) throws {
        try send(data, preferScreenChannel: true, fallbackToControlChannel: false)
    }

    private func send(
        _ data: Data,
        preferScreenChannel: Bool,
        fallbackToControlChannel: Bool
    ) throws {
        guard !isClosed else { throw WebRTCError.alreadyClosed }
#if canImport(WebRTC)
        let channel = try resolvedDataChannel(
            preferScreenChannel: preferScreenChannel,
            fallbackToControlChannel: fallbackToControlChannel
        )
        try send(data, over: channel)
#else
        throw WebRTCError.webRTCNotAvailable
#endif
    }

    public func sendFramedPayload(_ payload: Data, maxChunkBytes: Int = 8 * 1024) throws {
        try sendFramedPayload(
            payload,
            maxChunkBytes: maxChunkBytes,
            preferScreenChannel: false,
            fallbackToControlChannel: false,
            lock: outboundFrameLock
        )
    }

    public func sendScreenFramedPayload(_ payload: Data, maxChunkBytes: Int = 8 * 1024) throws {
        try sendFramedPayload(
            payload,
            maxChunkBytes: maxChunkBytes,
            preferScreenChannel: true,
            fallbackToControlChannel: false,
            lock: outboundScreenFrameLock
        )
    }

    private func sendFramedPayload(
        _ payload: Data,
        maxChunkBytes: Int,
        preferScreenChannel: Bool,
        fallbackToControlChannel: Bool,
        lock: NSLock
    ) throws {
        precondition(maxChunkBytes > 0, "maxChunkBytes must be greater than zero")

        lock.lock()
        defer { lock.unlock() }

        var framed = Data()
        var length = UInt32(payload.count).bigEndian
        framed.append(Data(bytes: &length, count: 4))
        framed.append(payload)
        let channel = try resolvedDataChannel(
            preferScreenChannel: preferScreenChannel,
            fallbackToControlChannel: fallbackToControlChannel
        )

        var offset = 0
        while offset < framed.count {
            let end = min(offset + maxChunkBytes, framed.count)
            let chunk = Data(framed[offset..<end])
            try send(chunk, over: channel)
            offset = end
        }
    }

    public func sendFramedPayloadAsync(
        _ payload: Data,
        maxChunkBytes: Int = 8 * 1024,
        maxBufferedAmountBytes: UInt64 = 16 * 1024,
        pollInterval: Duration = .milliseconds(10),
        drainTimeout: Duration = .seconds(5)
    ) async throws {
        try await sendFramedPayloadAsync(
            payload,
            maxChunkBytes: maxChunkBytes,
            maxBufferedAmountBytes: maxBufferedAmountBytes,
            pollInterval: pollInterval,
            drainTimeout: drainTimeout,
            preferScreenChannel: false,
            fallbackToControlChannel: false,
            gate: outboundFrameGate
        )
    }

    public func sendScreenFramedPayloadAsync(
        _ payload: Data,
        maxChunkBytes: Int = 8 * 1024,
        maxBufferedAmountBytes: UInt64 = 16 * 1024,
        pollInterval: Duration = .milliseconds(10),
        drainTimeout: Duration = .seconds(5)
    ) async throws {
        try await sendFramedPayloadAsync(
            payload,
            maxChunkBytes: maxChunkBytes,
            maxBufferedAmountBytes: maxBufferedAmountBytes,
            pollInterval: pollInterval,
            drainTimeout: drainTimeout,
            preferScreenChannel: true,
            fallbackToControlChannel: false,
            gate: outboundScreenFrameGate
        )
    }

    private func sendFramedPayloadAsync(
        _ payload: Data,
        maxChunkBytes: Int,
        maxBufferedAmountBytes: UInt64,
        pollInterval: Duration,
        drainTimeout: Duration,
        preferScreenChannel: Bool,
        fallbackToControlChannel: Bool,
        gate: WebRTCOutboundFrameGate
    ) async throws {
        precondition(maxChunkBytes > 0, "maxChunkBytes must be greater than zero")

        try await gate.run {
            try Task.checkCancellation()
            var framed = Data()
            var length = UInt32(payload.count).bigEndian
            framed.append(Data(bytes: &length, count: 4))
            framed.append(payload)
            let channel = try resolvedDataChannel(
                preferScreenChannel: preferScreenChannel,
                fallbackToControlChannel: fallbackToControlChannel
            )

            var offset = 0
            while offset < framed.count {
                try await waitForBufferedAmountBelow(
                    maxBufferedAmountBytes,
                    pollInterval: pollInterval,
                    timeout: drainTimeout,
                    channel: channel
                )
                try Task.checkCancellation()
                let end = min(offset + maxChunkBytes, framed.count)
                let chunk = Data(framed[offset..<end])
                try send(chunk, over: channel)
                offset = end
            }

            try await waitForBufferedAmountBelow(
                maxBufferedAmountBytes,
                pollInterval: pollInterval,
                timeout: drainTimeout,
                channel: channel
            )
            try Task.checkCancellation()
        }
    }

    public func dataChannelBufferedAmountBytes() -> UInt64 {
        dataChannelBufferedAmountBytes(preferScreenChannel: false, fallbackToControlChannel: false)
    }

    public func screenDataChannelBufferedAmountBytes() -> UInt64 {
        dataChannelBufferedAmountBytes(preferScreenChannel: true, fallbackToControlChannel: true)
    }

    private func dataChannelBufferedAmountBytes(
        preferScreenChannel: Bool,
        fallbackToControlChannel: Bool
    ) -> UInt64 {
#if canImport(WebRTC)
        if preferScreenChannel,
           let screenDataChannel,
           screenDataChannel.readyState == .open {
            return screenDataChannel.bufferedAmount
        }
        if fallbackToControlChannel || !preferScreenChannel {
            return dataChannel?.bufferedAmount ?? 0
        }
        return screenDataChannel?.bufferedAmount ?? 0
#else
        return 0
#endif
    }

    private func dataChannelBufferedAmountBytes(for channel: RTCDataChannel) -> UInt64 {
#if canImport(WebRTC)
        channel.bufferedAmount
#else
        0
#endif
    }

    public func hasOpenScreenDataChannel() -> Bool {
#if canImport(WebRTC)
        guard let screenDataChannel else { return false }
        return screenDataChannel.readyState == .open
#else
        return false
#endif
    }

    private func waitForBufferedAmountBelow(
        _ threshold: UInt64,
        pollInterval: Duration,
        timeout: Duration,
        channel: RTCDataChannel
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while dataChannelBufferedAmountBytes(for: channel) > threshold {
            if clock.now >= deadline {
                throw WebRTCError.dataChannelSendFailed
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    private func resolvedDataChannel(
        preferScreenChannel: Bool,
        fallbackToControlChannel: Bool
    ) throws -> RTCDataChannel {
#if canImport(WebRTC)
        let channel: RTCDataChannel?
        if preferScreenChannel,
           let screenDataChannel,
           screenDataChannel.readyState == .open {
            channel = screenDataChannel
        } else if fallbackToControlChannel || !preferScreenChannel {
            channel = dataChannel
        } else {
            channel = screenDataChannel
        }
        guard let channel else { throw WebRTCError.dataChannelNotReady }
        guard channel.readyState == .open else { throw WebRTCError.dataChannelNotOpen }
        return channel
#else
        throw WebRTCError.webRTCNotAvailable
#endif
    }

    private func send(_ data: Data, over channel: RTCDataChannel) throws {
#if canImport(WebRTC)
        guard channel.readyState == .open else { throw WebRTCError.dataChannelNotOpen }
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        guard channel.sendData(buffer) else { throw WebRTCError.dataChannelSendFailed }
#else
        throw WebRTCError.webRTCNotAvailable
#endif
    }
    
#if canImport(WebRTC)
    private func createOffer() {
        guard let pc = peerConnection else { return }
        onTrace?("create-offer session=\(sessionId)")
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "false",
                "OfferToReceiveVideo": videoTransceiver == nil ? "false" : "true",
            ],
            optionalConstraints: nil
        )
        pc.offer(for: constraints) { [weak self] sdp, error in
            guard let self else { return }
            if let error {
                self.logger.error("❌ offer failed: \(error.localizedDescription, privacy: .public)")
                self.onTrace?("create-offer failed session=\(self.sessionId) error=\(error.localizedDescription)")
                return
            }
            guard let sdp else { return }
            let sdpString = sdp.sdp
            pc.setLocalDescription(sdp) { [weak self] err in
                guard let self else { return }
                if let err {
                    self.logger.error("❌ setLocalDescription(offer) failed: \(err.localizedDescription, privacy: .public)")
                    self.onTrace?("set-local-offer failed session=\(self.sessionId) error=\(err.localizedDescription)")
                    return
                }
                self.lastEmittedLocalSDP = sdpString
                self.onTrace?("local-offer-ready session=\(self.sessionId) bytes=\(sdpString.utf8.count)")
                self.onLocalOffer?(sdpString)
            }
        }
    }
    
    private func createAnswer() {
        guard let pc = peerConnection else { return }
        onTrace?("create-answer session=\(sessionId)")
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "false",
                "OfferToReceiveVideo": videoTransceiver == nil ? "false" : "true",
            ],
            optionalConstraints: nil
        )
        pc.answer(for: constraints) { [weak self] sdp, error in
            guard let self else { return }
            if let error {
                self.logger.error("❌ answer failed: \(error.localizedDescription, privacy: .public)")
                self.onTrace?("create-answer failed session=\(self.sessionId) error=\(error.localizedDescription)")
                return
            }
            guard let sdp else { return }
            let sdpString = sdp.sdp
            pc.setLocalDescription(sdp) { [weak self] err in
                guard let self else { return }
                if let err {
                    self.logger.error("❌ setLocalDescription(answer) failed: \(err.localizedDescription, privacy: .public)")
                    self.onTrace?("set-local-answer failed session=\(self.sessionId) error=\(err.localizedDescription)")
                    return
                }
                self.lastEmittedLocalSDP = sdpString
                self.onTrace?("local-answer-ready session=\(self.sessionId) bytes=\(sdpString.utf8.count)")
                self.onLocalAnswer?(sdpString)
            }
        }
    }

    private func emitCompletedLocalDescriptionIfNeeded() {
#if canImport(WebRTC)
        guard let localDescription = peerConnection?.localDescription else { return }
        let sdp = localDescription.sdp
        guard !sdp.isEmpty, sdp != lastEmittedLocalSDP else { return }
        lastEmittedLocalSDP = sdp
        logger.info("🔁 emitting gathered local description. sessionId=\(self.sessionId, privacy: .public) role=\(String(describing: self.role), privacy: .public)")
        onTrace?("emit-complete-local-description session=\(sessionId) role=\(String(describing: role)) bytes=\(sdp.utf8.count)")
        switch role {
        case .offerer:
            onLocalOffer?(sdp)
        case .answerer:
            onLocalAnswer?(sdp)
        }
#endif
    }

    private struct NormalizedRemoteSDP {
        let sdp: String
        let droppedSessionLevelCandidateLines: Int
        let deduplicatedCandidateLines: Int
    }

    private static func normalizedRemoteSDP(_ sdp: String) -> NormalizedRemoteSDP {
        let normalizedNewlines = sdp.replacingOccurrences(of: "\r\n", with: "\n")
        let rawLines = normalizedNewlines
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var prefix: [String] = []
        var sections: [[String]] = []
        var currentSection: [String]? = nil
        var droppedSessionLevelCandidateLines = 0
        var deduplicatedCandidateLines = 0

        for line in rawLines {
            if line.hasPrefix("m=") {
                if let currentSection {
                    sections.append(currentSection)
                }
                currentSection = [line]
                continue
            }

            if currentSection != nil {
                currentSection?.append(line)
                continue
            }

            if line.hasPrefix("a=candidate:") || line == "a=end-of-candidates" {
                droppedSessionLevelCandidateLines += 1
                continue
            }
            if !line.isEmpty {
                prefix.append(line)
            }
        }

        if let currentSection {
            sections.append(currentSection)
        }

        var cleanedSections: [[String]] = []
        cleanedSections.reserveCapacity(sections.count)
        for section in sections {
            var seenCandidateLines = Set<String>()
            var cleanedSection: [String] = []
            cleanedSection.reserveCapacity(section.count)

            for line in section {
                guard !line.isEmpty else { continue }
                if line.hasPrefix("a=candidate:") {
                    if !seenCandidateLines.insert(line).inserted {
                        deduplicatedCandidateLines += 1
                        continue
                    }
                }
                if line == "a=end-of-candidates",
                   cleanedSection.last == "a=end-of-candidates" {
                    deduplicatedCandidateLines += 1
                    continue
                }
                cleanedSection.append(line)
            }
            cleanedSections.append(cleanedSection)
        }

        var flattened = prefix
        for section in cleanedSections {
            flattened.append(contentsOf: section)
        }

        let rendered = flattened.joined(separator: "\r\n") + "\r\n"
        return NormalizedRemoteSDP(
            sdp: rendered,
            droppedSessionLevelCandidateLines: droppedSessionLevelCandidateLines,
            deduplicatedCandidateLines: deduplicatedCandidateLines
        )
    }

    private static func extractRemoteICECandidates(from sdp: String) -> [RTCIceCandidate] {
        let normalizedLines = sdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var candidates: [RTCIceCandidate] = []
        var currentMid: String?
        var currentMLineIndex: Int32 = -1

        for line in normalizedLines {
            if line.hasPrefix("m=") {
                currentMLineIndex += 1
                currentMid = nil
                continue
            }
            if line.hasPrefix("a=mid:") {
                currentMid = String(line.dropFirst(6))
                continue
            }
            if line.hasPrefix("a=candidate:"), currentMLineIndex >= 0 {
                let candidateSDP = String(line.dropFirst(2))
                candidates.append(
                    RTCIceCandidate(
                        sdp: candidateSDP,
                        sdpMLineIndex: currentMLineIndex,
                        sdpMid: currentMid
                    )
                )
            }
        }

        return candidates
    }
#endif
}

#if canImport(WebRTC)
@available(iOS 17.0, *)
extension WebRTCSession: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        logger.info("ICE connection state: \(String(describing: newState), privacy: .public)")
        onTrace?("ice-connection-state session=\(sessionId) state=\(String(describing: newState))")
        if newState == .connected || newState == .completed {
            inspectRemoteVideoTrackIfAvailable(peerConnection: peerConnection)
            scheduleRemoteVideoTrackInspection(peerConnection: peerConnection, reason: "ice-connected")
        }
        switch newState {
        case .failed:
            notifyDisconnectedIfNeeded(reason: "ice_failed")
        case .closed:
            notifyDisconnectedIfNeeded(reason: "ice_closed")
        default:
            break
        }
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        logger.info("ICE gathering state: \(String(describing: newState), privacy: .public)")
        onTrace?("ice-gathering-state session=\(sessionId) state=\(String(describing: newState))")
        if newState == .complete {
            emitCompletedLocalDescriptionIfNeeded()
        }
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onTrace?("did-generate-local-ice session=\(sessionId)")
        onLocalICECandidate?(.init(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex))
    }
    public func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didStartReceivingOn transceiver: RTCRtpTransceiver
    ) {
        guard transceiver.mediaType == .video else { return }
        captureRemoteVideoTrack(transceiver.receiver.track as? RTCVideoTrack, receiver: transceiver.receiver)
    }
    public func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        captureRemoteVideoTrack(rtpReceiver.track as? RTCVideoTrack, receiver: rtpReceiver)
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        if isScreenChannel(dataChannel) {
            self.screenDataChannel = dataChannel
        } else {
            self.dataChannel = dataChannel
        }
        dataChannel.delegate = self
        inspectRemoteVideoTrackIfAvailable(peerConnection: peerConnection)
        scheduleRemoteVideoTrackInspection(peerConnection: peerConnection, reason: "data-channel-open")
        onTrace?("did-open-data-channel session=\(sessionId) label=\(dataChannel.label)")
        if isControlChannel(dataChannel) {
            notifyReadyIfNeeded()
        }
    }
}

@available(iOS 17.0, *)
extension WebRTCSession: RTCRtpReceiverDelegate {
    public func rtpReceiver(
        _ rtpReceiver: RTCRtpReceiver,
        didReceiveFirstPacketFor mediaType: RTCRtpMediaType
    ) {
        guard mediaType == .video else { return }
        logger.info("📡 remote native video receiver got first RTP packet. sessionId=\(self.sessionId, privacy: .public)")
        onTrace?("remote-video-first-packet session=\(sessionId)")
        onRemoteVideoFirstPacket?()
    }
}

@available(iOS 17.0, *)
extension WebRTCSession: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        logger.info("DataChannel state: \(String(describing: dataChannel.readyState), privacy: .public) label=\(dataChannel.label, privacy: .public)")
        onTrace?("data-channel-state session=\(sessionId) label=\(dataChannel.label) state=\(String(describing: dataChannel.readyState))")
        if dataChannel.readyState == .open, isControlChannel(dataChannel) {
            notifyReadyIfNeeded()
        } else if dataChannel.readyState == .closed, isControlChannel(dataChannel) {
            notifyDisconnectedIfNeeded(reason: "data_channel_closed")
        } else if dataChannel.readyState == .closed, isScreenChannel(dataChannel) {
            if screenDataChannel === dataChannel {
                screenDataChannel = nil
            }
        }
    }
    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        if isScreenChannel(dataChannel) {
            deliverInboundScreenData(buffer.data)
        } else {
            deliverInboundData(buffer.data)
        }
    }
}
#endif
