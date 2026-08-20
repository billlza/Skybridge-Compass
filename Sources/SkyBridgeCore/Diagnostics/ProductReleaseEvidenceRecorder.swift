import Foundation
import Network
import OSLog
import SkyBridgeProtocolCore

/// Privacy-safe, process-local evidence emitted by the ordinary shipping product.
///
/// This surface is deliberately observational. It does not enable a feature, alter
/// admission, persist a file, authenticate a session, or authorize a peer. Callers
/// must first prove exact transport ownership and supply an existing `ev1:` reference
/// derived from an authenticated session. The strict-rejection path independently
/// verifies its complete signed MessageA before admitting evidence. The recorder then
/// prevents a stale owner from attributing effects to a replacement incarnation.
@MainActor
public final class ProductReleaseEvidenceRecorder {
    public static let shared = ProductReleaseEvidenceRecorder()
    static let maximumEvidenceLineCountPerSession = 20
    static let maximumRetainedSessionCount = 32
    static let maximumRetainedConnectivityRejectionCount = 32

    private static let logger = Logger(
        subsystem: "com.skybridge.compass.release-evidence",
        category: "ProductSession"
    )

    private struct SessionKey: Hashable {
        let transport: ProductReleaseEvidenceTransport
        let sessionReference: String
        let product: ProductReleaseEvidenceProduct
    }

    private struct SessionState {
        let owner: ProductReleaseEvidenceSessionOwner
        var noticeShown = false
        var pendingPanelPresented = false
        var humanApproved = false
        var noticeApproved = false
        var noticeActive = false
        var noticeTerminal = false
        var noticeHidden = false
        var retiringReason: ProductReleaseEvidenceDisconnectReason?
        var localFrameRecorded = false
        var peerFrameRecorded = false
        var recordedInputEffects = Set<ProductReleaseEvidenceInputEffect>()
        var nextEffectSequence: UInt64 = 1
        var p2pAuthenticated = false
        var webRTCPQCRekeyAuthenticated = false
        var webRTCMediaRole: ProductReleaseEvidenceMediaRole?
        var webRTCMediaStartedAt: ContinuousClock.Instant?
        var webRTCMediaSampleCount = 0
        var lastWebRTCMediaCounters: ProductReleaseEvidenceMediaCounters?
        var fileTransferReference: String?
        var fileTransferDirection: ProductReleaseEvidenceFileDirection?
        var fileTransferCompleted = false
    }

    private var sessionsByGeneration: [UInt64: SessionState] = [:]
    private var currentOwnersBySessionKey:
        [SessionKey: ProductReleaseEvidenceSessionOwner] = [:]
    private var nextOwnerGeneration: UInt64 = 1
    private var nextConnectivityAttemptGeneration: UInt64 = 1
    private var recordedConnectivityRejectionAttemptReferences = Set<String>()
    private let emitLine: @MainActor (String) -> Void

    public init() {
        emitLine = { line in
            Self.logger.notice("\(line, privacy: .public)")
        }
    }

    /// Internal injection point used by dynamic tests. It is not a runtime switch
    /// and cannot be reached from a separately compiled application target.
    init(emitter: @escaping @MainActor (String) -> Void) {
        emitLine = emitter
    }

    /// Registers one exact already-authenticated product session.
    ///
    /// A P2P owner must carry the actual local route class; a WebRTC owner must
    /// carry the selected ICE transport. Invalid or duplicate owners emit nothing.
    public func beginSession(
        product: ProductReleaseEvidenceProduct,
        transport: ProductReleaseEvidenceTransport,
        sessionReference: String,
        routeClass: ProductReleaseEvidenceRouteClass? = nil,
        selectedTransport: ProductReleaseEvidenceSelectedTransport? = nil
    ) -> ProductReleaseEvidenceSessionOwner? {
        guard P2PEvidenceReference.isValid(sessionReference) else { return nil }
        switch transport {
        case .p2p:
            guard routeClass != nil, selectedTransport == nil else { return nil }
        case .webrtc:
            guard routeClass == nil, selectedTransport != nil else { return nil }
        }

        let key = SessionKey(
            transport: transport,
            sessionReference: sessionReference,
            product: product
        )
        guard sessionsByGeneration.count < Self.maximumRetainedSessionCount,
              currentOwnersBySessionKey[key] == nil,
              nextOwnerGeneration < UInt64.max else {
            return nil
        }
        let generation = nextOwnerGeneration
        nextOwnerGeneration += 1
        let owner = ProductReleaseEvidenceSessionOwner(
            product: product,
            transport: transport,
            sessionReference: sessionReference,
            generation: generation
        )
        sessionsByGeneration[generation] = SessionState(owner: owner)
        currentOwnersBySessionKey[key] = owner

        var fields = ownerFields(owner)
        fields.append("state=active")
        if let routeClass {
            fields.append("routeClass=\(routeClass.rawValue)")
        }
        if let selectedTransport {
            fields.append("selectedTransport=\(selectedTransport.rawValue)")
        }
        emit(event: "releaseSessionOwner", fields: fields)
        return owner
    }

    public func currentOwner(
        product: ProductReleaseEvidenceProduct,
        transport: ProductReleaseEvidenceTransport,
        sessionReference: String
    ) -> ProductReleaseEvidenceSessionOwner? {
        let key = SessionKey(
            transport: transport,
            sessionReference: sessionReference,
            product: product
        )
        guard let owner = currentOwnersBySessionKey[key],
              let state = sessionsByGeneration[owner.generation],
              state.owner == owner,
              state.retiringReason == nil else {
            return nil
        }
        return owner
    }

    @discardableResult
    public func recordNoticeShown(owner: ProductReleaseEvidenceSessionOwner) -> Bool {
        mutateCurrent(owner) { state in
            guard !state.noticeShown, !state.noticeTerminal else { return nil }
            state.noticeShown = true
            return ("remoteControlNoticeShown", ["phase=awaitingApproval", "result=presented"])
        }
    }

    /// This entry point is called only after the real AppKit panel has been
    /// positioned and ordered on screen.
    @discardableResult
    public func recordPendingNoticePanelPresented(
        owner: ProductReleaseEvidenceSessionOwner
    ) -> Bool {
        mutateCurrent(owner) { state in
            guard state.noticeShown, !state.pendingPanelPresented, !state.noticeTerminal else {
                return nil
            }
            state.pendingPanelPresented = true
            return (
                "remoteControlNoticePanelPresented",
                ["phase=awaitingApproval", "buttons=approve,reject", "result=visible"]
            )
        }
    }

    /// This entry point is reserved for the AppKit Approve button action.
    @discardableResult
    public func recordNoticeHumanApproved(owner: ProductReleaseEvidenceSessionOwner) -> Bool {
        mutateCurrent(owner) { state in
            guard state.pendingPanelPresented, !state.humanApproved, !state.noticeTerminal else {
                return nil
            }
            state.humanApproved = true
            return (
                "remoteControlNoticeHumanApproved",
                ["phase=awaitingApproval", "decisionSource=user", "result=approved"]
            )
        }
    }

    @discardableResult
    public func recordNoticeApproved(owner: ProductReleaseEvidenceSessionOwner) -> Bool {
        mutateCurrent(owner) { state in
            guard state.humanApproved, !state.noticeApproved, !state.noticeTerminal else {
                return nil
            }
            state.noticeApproved = true
            return (
                "remoteControlNoticeApproved",
                ["phase=awaitingApproval", "decisionSource=user", "result=approved"]
            )
        }
    }

    @discardableResult
    public func recordNoticeActive(owner: ProductReleaseEvidenceSessionOwner) -> Bool {
        mutateCurrent(owner) { state in
            guard state.noticeApproved, !state.noticeActive, !state.noticeTerminal else {
                return nil
            }
            state.noticeActive = true
            return ("remoteControlNoticeActive", ["phase=active", "result=active"])
        }
    }

    @discardableResult
    public func recordNoticeTerminated(
        owner: ProductReleaseEvidenceSessionOwner,
        result: ProductReleaseEvidenceNoticeTerminalResult
    ) -> Bool {
        mutateCurrent(owner) { state in
            guard state.noticeShown, !state.noticeTerminal else { return nil }
            state.noticeTerminal = true
            return (
                "remoteControlNotice\(result.eventSuffix)",
                ["phase=terminal", "result=\(result.rawValue)"]
            )
        }
    }

    @discardableResult
    public func recordNoticePanelHidden(owner: ProductReleaseEvidenceSessionOwner) -> Bool {
        guard var state = sessionsByGeneration[owner.generation],
              state.owner == owner,
              state.pendingPanelPresented,
              !state.noticeHidden else {
            return false
        }
        state.noticeHidden = true
        sessionsByGeneration[owner.generation] = state
        emit(
            event: "remoteControlNoticePanelHidden",
            fields: ownerFields(owner) + ["phase=terminal", "result=hidden"]
        )
        if let reason = state.retiringReason {
            finalizeSession(owner: owner, reason: reason, noticeHidden: true)
        }
        return true
    }

    /// Records an inbound frame presented by this process. This observational
    /// event cannot satisfy controlled-host proof for a peer renderer.
    @discardableResult
    public func recordLocalFramePresented(
        owner: ProductReleaseEvidenceSessionOwner,
        bytes: Int,
        width: Int,
        height: Int
    ) -> Bool {
        guard bytes > 0, width > 0, height > 0 else { return false }
        return mutateCurrent(owner) { state in
            guard state.noticeActive, !state.localFrameRecorded else { return nil }
            state.localFrameRecorded = true
            guard let sequence = Self.takeEffectSequence(from: &state) else { return nil }
            return (
                "localFramePresented",
                [
                    "local_frame_seq=\(sequence)",
                    "effect=presented",
                    "proof=local-renderer",
                    "bytes=\(bytes)",
                    "width=\(width)",
                    "height=\(height)"
                ]
            )
        }
    }

    /// Records only an authenticated receipt proving that the peer's ordinary
    /// renderer presented this exact session's outbound frame.
    @discardableResult
    public func recordPeerFramePresented(
        owner: ProductReleaseEvidenceSessionOwner,
        proof: ProductReleaseEvidencePeerFrameProof,
        bytes: Int,
        width: Int,
        height: Int
    ) -> Bool {
        guard bytes > 0, width > 0, height > 0,
              proof.transport == owner.transport else {
            return false
        }
        return mutateCurrent(owner) { state in
            guard state.noticeActive, !state.peerFrameRecorded else { return nil }
            state.peerFrameRecorded = true
            guard let sequence = Self.takeEffectSequence(from: &state) else { return nil }
            return (
                "secureFrameAccepted",
                [
                    "frame_seq=\(sequence)",
                    "effect=presented",
                    "proof=\(proof.rawValue)",
                    "bytes=\(bytes)",
                    "width=\(width)",
                    "height=\(height)"
                ]
            )
        }
    }

    /// Records only a successfully posted HID effect. Event details are
    /// intentionally reduced to a coarse kind; key codes and coordinates are
    /// never accepted by this API.
    @discardableResult
    public func recordRemoteInputApplied(
        owner: ProductReleaseEvidenceSessionOwner,
        effect: ProductReleaseEvidenceInputEffect
    ) -> Bool {
        mutateCurrent(owner) { state in
            guard state.noticeActive,
                  state.recordedInputEffects.insert(effect).inserted else {
                return nil
            }
            guard let sequence = Self.takeEffectSequence(from: &state) else { return nil }
            return (
                "remoteInputApplied",
                [
                    "event_seq=\(sequence)",
                    "effect=\(effect.rawValue)",
                    "applied=1"
                ]
            )
        }
    }

    @discardableResult
    public func recordP2PSessionAuthenticated(
        owner: ProductReleaseEvidenceSessionOwner,
        role: ProductReleaseEvidenceHandshakeRole,
        negotiatedSuite: CryptoSuite
    ) -> Bool {
        mutateCurrent(owner) { state in
            guard owner.transport == .p2p,
                  negotiatedSuite == .xwingMLDSA,
                  !state.p2pAuthenticated else {
                return nil
            }
            state.p2pAuthenticated = true
            return (
                "p2pSessionAuthenticated",
                ["role=\(role.rawValue)", "suite=X-Wing", "result=authenticated"]
            )
        }
    }

    @discardableResult
    public func recordWebRTCPQCRekeyAuthenticated(
        owner: ProductReleaseEvidenceSessionOwner,
        negotiatedSuite: CryptoSuite
    ) -> Bool {
        mutateCurrent(owner) { state in
            guard owner.transport == .webrtc,
                  negotiatedSuite == .xwingMLDSA,
                  !state.webRTCPQCRekeyAuthenticated else {
                return nil
            }
            state.webRTCPQCRekeyAuthenticated = true
            return (
                "webrtcPQCRekeyAuthenticated",
                ["suite=X-Wing", "result=authenticated"]
            )
        }
    }

    @discardableResult
    public func recordWebRTCMediaSample(
        owner: ProductReleaseEvidenceSessionOwner,
        role: ProductReleaseEvidenceMediaRole,
        counters: ProductReleaseEvidenceMediaCounters,
        now: ContinuousClock.Instant = .now
    ) -> Bool {
        mutateCurrent(owner) { state in
            guard owner.transport == .webrtc,
                  state.webRTCPQCRekeyAuthenticated,
                  state.webRTCMediaSampleCount < 4,
                  counters.hasFlow,
                  state.webRTCMediaRole.map({ $0 == role }) ?? true,
                  state.lastWebRTCMediaCounters.map({ counters.strictlyExceeds($0) }) ?? true else {
                return nil
            }
            let startedAt = state.webRTCMediaStartedAt ?? now
            let elapsed = startedAt.duration(to: now)
            let seconds = max(0, elapsed.components.seconds)
            let attoseconds = max(0, elapsed.components.attoseconds)
            let elapsedMilliseconds = min(
                UInt64.max,
                UInt64(seconds) * 1_000 + UInt64(attoseconds / 1_000_000_000_000_000)
            )
            state.webRTCMediaStartedAt = startedAt
            state.webRTCMediaRole = role
            state.webRTCMediaSampleCount += 1
            state.lastWebRTCMediaCounters = counters
            return (
                "webrtcMediaSample",
                [
                    "mediaRole=\(role.rawValue)",
                    "sample_seq=\(state.webRTCMediaSampleCount)",
                    "elapsed_ms=\(elapsedMilliseconds)",
                    "video_frames=\(counters.videoFrames)",
                    "video_bytes=\(counters.videoBytes)",
                    "audio_units=\(counters.audioUnits)",
                    "audio_bytes=\(counters.audioBytes)",
                    "result=flowing"
                ]
            )
        }
    }

    /// Starts one exact normal-product handshake observation. The attempt
    /// reference comes from the signed SOA MessageA attempt ID; it contains no
    /// peer identity or network address.
    public func beginConnectivityAttempt(
        attemptReference: String,
        role: ProductConnectivityHandshakeRole,
        localProfile: ProductConnectivityEndpointProfile,
        offeredSuites: [CryptoSuite],
        requirePQC: Bool,
        allowClassicFallback: Bool
    ) -> ProductConnectivityAttemptOwner? {
        guard nextConnectivityAttemptGeneration < UInt64.max,
              let output = ProductConnectivityEvidenceFormatter.beginAttempt(
                product: .macOSApp,
                attemptReference: attemptReference,
                generation: nextConnectivityAttemptGeneration,
                role: role,
                localProfile: localProfile,
                offeredSuiteWireIDs: offeredSuites.map(\.wireId),
                requirePQC: requirePQC,
                allowClassicFallback: allowClassicFallback
              ) else {
            return nil
        }
        nextConnectivityAttemptGeneration += 1
        emitLine(output.line)
        return output.owner
    }

    /// Publishes endpoint evidence only after the caller has committed the exact
    /// authenticated session incarnation and durable protocol authority.
    @discardableResult
    public func authenticateConnectivityAttempt(
        owner: ProductConnectivityAttemptOwner,
        sessionReference: String,
        negotiatedSuite: CryptoSuite
    ) -> Bool {
        guard let lines = ProductConnectivityEvidenceFormatter.authenticateAttempt(
            owner: owner,
            sessionReference: sessionReference,
            negotiatedSuite: negotiatedSuite
        ) else {
            return false
        }
        lines.forEach(emitLine)
        return true
    }

    /// Atomically admits evidence for the one expected strict-policy rejection.
    ///
    /// The complete MessageA is required so this recorder, rather than a caller
    /// assertion, verifies that the classic offer and its SOA attempt ID were
    /// covered by the peer's Ed25519 protocol signature. Invalid, replayed, or
    /// non-SOA inputs emit neither a started line nor a rejection line.
    @discardableResult
    public func recordStrictPQCClassicOfferRejection(
        peerMessageA: HandshakeMessageA,
        localProfile: ProductConnectivityEndpointProfile,
        offeredSuites: [CryptoSuite]
    ) async -> Bool {
        guard let attemptID = peerMessageA.soaExtension?.attemptId,
              let attemptReference = ProductConnectivityAttemptReference.make(
                from: attemptID
              ),
              await ProductConnectivitySignedOfferVerifier
                .isValidClassicOnlyOffer(peerMessageA),
              recordedConnectivityRejectionAttemptReferences.count
                < Self.maximumRetainedConnectivityRejectionCount,
              !recordedConnectivityRejectionAttemptReferences.contains(
                attemptReference
              ),
              nextConnectivityAttemptGeneration < UInt64.max,
              let started = ProductConnectivityEvidenceFormatter.beginAttempt(
                product: .macOSApp,
                attemptReference: attemptReference,
                generation: nextConnectivityAttemptGeneration,
                role: .responder,
                localProfile: localProfile,
                offeredSuiteWireIDs: offeredSuites.map(\.wireId),
                requirePQC: true,
                allowClassicFallback: false
              ),
              let rejected = ProductConnectivityEvidenceFormatter.rejectAttempt(
                owner: started.owner,
                peerOfferedSuiteWireIDs: peerMessageA.supportedSuites.map(\.wireId),
                reason: .strictPQCRejectsClassic
              ) else {
            return false
        }
        recordedConnectivityRejectionAttemptReferences.insert(attemptReference)
        nextConnectivityAttemptGeneration += 1
        emitLine(started.line)
        emitLine(rejected)
        return true
    }

    @discardableResult
    public func failConnectivityAttempt(
        owner: ProductConnectivityAttemptOwner,
        reason: ProductConnectivityAttemptFailureReason
    ) -> Bool {
        guard let line = ProductConnectivityEvidenceFormatter.failAttempt(
            owner: owner,
            reason: reason
        ) else {
            return false
        }
        emitLine(line)
        return true
    }

    @discardableResult
    public func recordFileTransferStarted(
        owner: ProductReleaseEvidenceSessionOwner,
        transferReference: String,
        direction: ProductReleaseEvidenceFileDirection
    ) -> Bool {
        guard P2PEvidenceReference.isValid(transferReference) else { return false }
        return mutateCurrent(owner) { state in
            guard state.fileTransferReference == nil else { return nil }
            state.fileTransferReference = transferReference
            state.fileTransferDirection = direction
            return (
                "fileTransferStarted",
                [
                    "transfer_ref=\(transferReference)",
                    "direction=\(direction.rawValue)",
                    "interaction=\(direction.interaction)",
                    "payload=nonempty",
                    "result=started"
                ]
            )
        }
    }

    @discardableResult
    public func recordFileTransferCompleted(
        owner: ProductReleaseEvidenceSessionOwner,
        transferReference: String,
        direction: ProductReleaseEvidenceFileDirection,
        uiEffectVisible: Bool
    ) -> Bool {
        guard P2PEvidenceReference.isValid(transferReference), uiEffectVisible else {
            return false
        }
        return mutateCurrent(owner) { state in
            guard state.fileTransferReference == transferReference,
                  state.fileTransferDirection == direction,
                  !state.fileTransferCompleted else {
                return nil
            }
            state.fileTransferCompleted = true
            return (
                "fileTransferCompleted",
                [
                    "transfer_ref=\(transferReference)",
                    "direction=\(direction.rawValue)",
                    "interaction=\(direction.interaction)",
                    "payload=nonempty",
                    "integrity=verified",
                    "receipt=authenticated",
                    "result=success",
                    "uiEffect=completed"
                ]
            )
        }
    }

    /// Retires an exact owner. Once retirement begins, all further product
    /// effects are rejected. If a real notice panel was shown, final evidence is
    /// delayed until its actual AppKit hide callback arrives.
    @discardableResult
    public func endSession(
        owner: ProductReleaseEvidenceSessionOwner,
        reason: ProductReleaseEvidenceDisconnectReason
    ) -> Bool {
        guard var state = sessionsByGeneration[owner.generation],
              state.owner == owner,
              state.retiringReason == nil else {
            return false
        }
        state.retiringReason = reason
        sessionsByGeneration[owner.generation] = state
        let sessionKey = key(for: owner)
        if currentOwnersBySessionKey[sessionKey] == owner {
            currentOwnersBySessionKey.removeValue(forKey: sessionKey)
        }
        if !state.pendingPanelPresented || state.noticeHidden {
            finalizeSession(owner: owner, reason: reason, noticeHidden: state.noticeHidden)
        }
        return true
    }

    private func mutateCurrent(
        _ owner: ProductReleaseEvidenceSessionOwner,
        mutation: (inout SessionState) -> (event: String, fields: [String])?
    ) -> Bool {
        guard var state = sessionsByGeneration[owner.generation],
              state.owner == owner,
              state.retiringReason == nil,
              !state.noticeTerminal,
              let output = mutation(&state) else {
            return false
        }
        sessionsByGeneration[owner.generation] = state
        emit(event: output.event, fields: ownerFields(owner) + output.fields)
        return true
    }

    private func finalizeSession(
        owner: ProductReleaseEvidenceSessionOwner,
        reason: ProductReleaseEvidenceDisconnectReason,
        noticeHidden: Bool
    ) {
        guard let state = sessionsByGeneration[owner.generation],
              state.owner == owner else { return }
        sessionsByGeneration.removeValue(forKey: owner.generation)
        let sessionKey = key(for: owner)
        if currentOwnersBySessionKey[sessionKey] == owner {
            currentOwnersBySessionKey.removeValue(forKey: sessionKey)
        }
        emit(
            event: "releaseSessionDisconnected",
            fields: ownerFields(owner) + [
                "noticeHidden=\(noticeHidden ? "1" : "not-applicable")",
                "reason=\(reason.rawValue)",
                "result=disconnected"
            ]
        )
    }

    private func key(for owner: ProductReleaseEvidenceSessionOwner) -> SessionKey {
        SessionKey(
            transport: owner.transport,
            sessionReference: owner.sessionReference,
            product: owner.product
        )
    }

    private func ownerFields(_ owner: ProductReleaseEvidenceSessionOwner) -> [String] {
        [
            "transport=\(owner.transport.rawValue)",
            "session_ref=\(owner.sessionReference)",
            "owner=\(owner.product.rawValue)",
            "generation=\(owner.generation)"
        ]
    }

    private func emit(event: String, fields: [String]) {
        emitLine(([event] + fields).joined(separator: " "))
    }

    private static func takeEffectSequence(from state: inout SessionState) -> UInt64? {
        guard state.nextEffectSequence < UInt64.max else { return nil }
        let sequence = state.nextEffectSequence
        state.nextEffectSequence += 1
        return sequence
    }
}

public struct ProductReleaseEvidenceSessionOwner: Hashable, Sendable {
    public let product: ProductReleaseEvidenceProduct
    public let transport: ProductReleaseEvidenceTransport
    public let sessionReference: String
    public let generation: UInt64

    fileprivate init(
        product: ProductReleaseEvidenceProduct,
        transport: ProductReleaseEvidenceTransport,
        sessionReference: String,
        generation: UInt64
    ) {
        self.product = product
        self.transport = transport
        self.sessionReference = sessionReference
        self.generation = generation
    }
}

public enum ProductReleaseEvidenceProduct: String, Sendable, Hashable {
    case macOSApp = "SkyBridgeCompassApp"
    case iOSApp = "SkyBridgeCompassiOS"
}

public enum ProductReleaseEvidenceTransport: String, Sendable, Hashable {
    case p2p
    case webrtc
}

public enum ProductReleaseEvidenceHandshakeRole: String, Sendable {
    case initiator
    case responder
}

public enum ProductReleaseEvidenceMediaRole: String, Sendable {
    case sender
    case receiver
}

public struct ProductReleaseEvidenceMediaCounters: Sendable, Equatable {
    public let videoFrames: UInt64
    public let videoBytes: UInt64
    public let audioUnits: UInt64
    public let audioBytes: UInt64

    public init(
        videoFrames: UInt64,
        videoBytes: UInt64,
        audioUnits: UInt64,
        audioBytes: UInt64
    ) {
        self.videoFrames = videoFrames
        self.videoBytes = videoBytes
        self.audioUnits = audioUnits
        self.audioBytes = audioBytes
    }

    fileprivate var hasFlow: Bool {
        videoFrames > 0 && videoBytes > 0 && audioUnits > 0 && audioBytes > 0
    }

    fileprivate func strictlyExceeds(
        _ previous: ProductReleaseEvidenceMediaCounters
    ) -> Bool {
        videoFrames > previous.videoFrames
            && videoBytes > previous.videoBytes
            && audioUnits > previous.audioUnits
            && audioBytes > previous.audioBytes
    }
}

public enum ProductReleaseEvidenceRouteClass: String, Sendable {
    case wifi
    case awdl

    static func current(for connection: NWConnection) -> Self? {
        guard let path = connection.currentPath else { return nil }
        if path.availableInterfaces.contains(where: {
            $0.name.lowercased().hasPrefix("awdl")
        }) {
            return .awdl
        }
        if path.usesInterfaceType(.wifi) {
            return .wifi
        }
        return nil
    }
}

public enum ProductReleaseEvidenceSelectedTransport: String, Sendable {
    case direct
    case relay
}

public enum ProductReleaseEvidenceInputEffect: String, Sendable, Hashable {
    case pointer
    case keyboard
    case scroll
}

public enum ProductReleaseEvidencePeerFrameProof: String, Sendable {
    case p2pRendererAcknowledgement = "p2p-renderer-ack"
    case webrtcRendererReceipt = "webrtc-renderer-receipt"

    fileprivate var transport: ProductReleaseEvidenceTransport {
        switch self {
        case .p2pRendererAcknowledgement: .p2p
        case .webrtcRendererReceipt: .webrtc
        }
    }
}

public enum ProductReleaseEvidenceFileDirection: String, Sendable {
    case send
    case receive

    fileprivate var interaction: String {
        switch self {
        case .send: "send-ui"
        case .receive: "accept-ui"
        }
    }
}

public enum ProductReleaseEvidenceDisconnectReason: String, Sendable {
    case user
    case peer
    case trustInvalidated = "trust-invalidated"
    case sessionReplaced = "session-replaced"
    case protocolFailure = "protocol-failure"
}

public enum ProductReleaseEvidenceNoticeTerminalResult: String, Sendable {
    case rejected
    case timedOut = "timed-out"
    case disconnected

    fileprivate var eventSuffix: String {
        switch self {
        case .rejected: "Rejected"
        case .timedOut: "TimedOut"
        case .disconnected: "Disconnected"
        }
    }
}
