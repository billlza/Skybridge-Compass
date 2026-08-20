import Foundation
import OSLog
import SkyBridgeProtocolCore

/// Privacy-safe release evidence from the ordinary shipping iOS product.
///
/// The recorder is observational only. It cannot select a provider, relax a
/// policy, create a session, or persist an artifact. Its fixed OSLog messages
/// are later captured with process ownership proof and joined to the matching
/// macOS endpoint by fixed opaque attempt, session, transfer, and identity
/// references. It never accepts raw keys, device/account identifiers, paths,
/// network addresses, or user input details.
@MainActor
final class ProductReleaseEvidenceRecorder {
    static let shared = ProductReleaseEvidenceRecorder()
    static let maximumRetainedRejectionCount = 32
    static let maximumRetainedSessionCount = 32
    static let maximumRetainedIdentityCount = 32
    static let maximumEvidenceLineCountPerSession = 20

    private static let logger = Logger(
        subsystem: "com.skybridge.compass.release-evidence",
        category: "ProductSession"
    )

    private var nextAttemptGeneration: UInt64 = 1
    private var recordedRejectionAttemptReferences = Set<String>()
    private var committedIdentityReferences = Set<String>()
    private var restoredIdentityReferences = Set<String>()
    private var authenticatedP2PAttemptSessions: [String: String] = [:]
    private var handshakeBoundSessionReferences = Set<IdentitySessionKey>()
    private struct IdentitySessionKey: Hashable {
        let transport: ProductEvidenceTransport
        let sessionReference: String
    }
    private struct SessionKey: Hashable {
        let transport: ProductEvidenceTransport
        let sessionReference: String
    }

    private struct SessionState {
        let owner: ProductEvidenceSessionOwner
        var emittedLineCount = 1
        var p2pAuthenticated = false
        var webrtcRekeyAuthenticated = false
        var lastMediaSample: ProductEvidenceMediaSample?
        var mediaSampleCount = 0
        var transferReference: String?
        var transferDirection: ProductEvidenceFileDirection?
        var transferCompleted = false
    }

    private var nextSessionGeneration: UInt64 = 1
    private var sessionsByGeneration: [UInt64: SessionState] = [:]
    private var currentSessionOwners: [SessionKey: ProductEvidenceSessionOwner] = [:]
    private let emitLine: @MainActor (String) -> Void

    init() {
        emitLine = { line in
            Self.logger.notice("\(line, privacy: .public)")
        }
    }

    init(emitter: @escaping @MainActor (String) -> Void) {
        emitLine = emitter
    }

    func beginSession(
        transport: ProductEvidenceTransport,
        sessionReference: String,
        routeClass: ProductEvidenceRouteClass? = nil,
        selectedTransport: ProductEvidenceSelectedTransport? = nil
    ) -> ProductEvidenceSessionOwner? {
        guard P2PEvidenceReference.isValid(sessionReference),
              sessionsByGeneration.count < Self.maximumRetainedSessionCount,
              nextSessionGeneration < UInt64.max else {
            return nil
        }
        switch transport {
        case .p2p:
            guard routeClass != nil, selectedTransport == nil else { return nil }
        case .webrtc:
            guard routeClass == nil, selectedTransport != nil else { return nil }
        }
        let key = SessionKey(
            transport: transport,
            sessionReference: sessionReference
        )
        guard currentSessionOwners[key] == nil else { return nil }
        let owner = ProductEvidenceSessionOwner(
            transport: transport,
            sessionReference: sessionReference,
            generation: nextSessionGeneration
        )
        nextSessionGeneration += 1
        sessionsByGeneration[owner.generation] = SessionState(owner: owner)
        currentSessionOwners[key] = owner
        var fields = ownerFields(owner) + ["state=active"]
        if let routeClass {
            fields.append("routeClass=\(routeClass.rawValue)")
        }
        if let selectedTransport {
            fields.append("selectedTransport=\(selectedTransport.rawValue)")
        }
        emit(event: "releaseSessionOwner", fields: fields)
        return owner
    }

    @discardableResult
    func recordP2PSessionAuthenticated(
        owner: ProductEvidenceSessionOwner,
        role: ProductConnectivityHandshakeRole,
        suite: CryptoSuite
    ) -> Bool {
        guard owner.transport == .p2p, suite == .xwing else { return false }
        return mutateCurrent(owner) { state in
            guard !state.p2pAuthenticated else { return nil }
            state.p2pAuthenticated = true
            return (
                "p2pSessionAuthenticated",
                [
                    "role=\(role.rawValue)",
                    "suite=\(suite.rawValue)",
                    "result=authenticated"
                ]
            )
        }
    }

    @discardableResult
    func recordWebRTCPQCRekeyAuthenticated(
        owner: ProductEvidenceSessionOwner,
        suite: CryptoSuite
    ) -> Bool {
        guard owner.transport == .webrtc, suite == .xwing else { return false }
        return mutateCurrent(owner) { state in
            guard !state.webrtcRekeyAuthenticated else { return nil }
            state.webrtcRekeyAuthenticated = true
            return (
                "webrtcPQCRekeyAuthenticated",
                ["suite=\(suite.rawValue)", "result=authenticated"]
            )
        }
    }

    @discardableResult
    func recordWebRTCMediaSample(
        owner: ProductEvidenceSessionOwner,
        sample: ProductEvidenceMediaSample
    ) -> Bool {
        guard owner.transport == .webrtc else { return false }
        return mutateCurrent(owner) { state in
            guard state.webrtcRekeyAuthenticated,
                  state.mediaSampleCount < 4,
                  sample.sequence == state.mediaSampleCount + 1,
                  sample.isStrictlyAfter(state.lastMediaSample) else {
                return nil
            }
            state.lastMediaSample = sample
            state.mediaSampleCount += 1
            return (
                "webrtcMediaSample",
                [
                    "mediaRole=\(sample.role.rawValue)",
                    "sample_seq=\(sample.sequence)",
                    "elapsed_ms=\(sample.elapsedMilliseconds)",
                    "video_frames=\(sample.videoFrames)",
                    "video_bytes=\(sample.videoBytes)",
                    "audio_units=\(sample.audioUnits)",
                    "audio_bytes=\(sample.audioBytes)",
                    "result=flowing"
                ]
            )
        }
    }

    @discardableResult
    func recordFileTransferStarted(
        owner: ProductEvidenceSessionOwner,
        transferReference: String,
        direction: ProductEvidenceFileDirection
    ) -> Bool {
        guard owner.transport == .p2p,
              P2PEvidenceReference.isValid(transferReference) else {
            return false
        }
        return mutateCurrent(owner) { state in
            guard state.p2pAuthenticated,
                  state.transferReference == nil else { return nil }
            state.transferReference = transferReference
            state.transferDirection = direction
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
    func recordFileTransferCompleted(
        owner: ProductEvidenceSessionOwner,
        transferReference: String,
        direction: ProductEvidenceFileDirection,
        authenticatedReceipt: Bool,
        integrityVerified: Bool,
        uiEffectVisible: Bool
    ) -> Bool {
        guard authenticatedReceipt, integrityVerified, uiEffectVisible else {
            return false
        }
        return mutateCurrent(owner) { state in
            guard state.transferReference == transferReference,
                  state.transferDirection == direction,
                  !state.transferCompleted else { return nil }
            state.transferCompleted = true
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

    @discardableResult
    func endSession(
        owner: ProductEvidenceSessionOwner,
        reason: ProductEvidenceDisconnectReason
    ) -> Bool {
        guard let state = sessionsByGeneration[owner.generation],
              state.owner == owner,
              state.emittedLineCount < Self.maximumEvidenceLineCountPerSession else {
            return false
        }
        sessionsByGeneration.removeValue(forKey: owner.generation)
        let key = SessionKey(
            transport: owner.transport,
            sessionReference: owner.sessionReference
        )
        if currentSessionOwners[key] == owner {
            currentSessionOwners.removeValue(forKey: key)
        }
        emit(
            event: "releaseSessionDisconnected",
            fields: ownerFields(owner) + [
                "reason=\(reason.rawValue)",
                "noticeHidden=not-applicable",
                "result=disconnected"
            ]
        )
        return true
    }

    func beginAttempt(
        attemptReference: String,
        role: ProductConnectivityHandshakeRole,
        localProfile: ProductConnectivityEndpointProfile,
        offeredSuites: [CryptoSuite],
        requirePQC: Bool,
        allowClassicFallback: Bool
    ) -> ProductConnectivityAttemptOwner? {
        guard nextAttemptGeneration < UInt64.max,
              let output = ProductConnectivityEvidenceFormatter.beginAttempt(
                product: .iOSApp,
                attemptReference: attemptReference,
                generation: nextAttemptGeneration,
                role: role,
                localProfile: localProfile,
                offeredSuiteWireIDs: offeredSuites.map(\.wireId),
                requirePQC: requirePQC,
                allowClassicFallback: allowClassicFallback
              ) else {
            return nil
        }
        nextAttemptGeneration += 1
        emitLine(output.line)
        return output.owner
    }

    @discardableResult
    func authenticate(
        owner: ProductConnectivityAttemptOwner,
        sessionReference: String,
        negotiatedSuite: CryptoSuite
    ) -> Bool {
        let sharedSuite = SkyBridgeProtocolCore.CryptoSuite(
            wireId: negotiatedSuite.wireId
        )
        guard let lines = ProductConnectivityEvidenceFormatter.authenticateAttempt(
            owner: owner,
            sessionReference: sessionReference,
            negotiatedSuite: sharedSuite
        ) else {
            return false
        }
        lines.forEach(emitLine)
        if authenticatedP2PAttemptSessions.count
            < Self.maximumRetainedIdentityCount {
            authenticatedP2PAttemptSessions[owner.attemptReference] = sessionReference
        }
        return true
    }

    /// Records the identity binding only after the caller has reloaded the
    /// current authority at the authenticated publication terminal and proven
    /// that its raw algorithm/protection/public-key tuple equals the immutable
    /// tuple captured by this exact driver.
    @discardableResult
    func recordProductionIdentityHandshakeBound(
        descriptor: ProductIdentityEvidenceDescriptor,
        sessionReference: String,
        attemptOwner: ProductConnectivityAttemptOwner
    ) -> Bool {
        let key = IdentitySessionKey(
            transport: .p2p,
            sessionReference: sessionReference
        )
        guard descriptor.isFormalProductionIdentity,
              P2PEvidenceReference.isValid(sessionReference),
              authenticatedP2PAttemptSessions[attemptOwner.attemptReference]
                == sessionReference,
              restoredIdentityReferences.contains(descriptor.identityReference),
              handshakeBoundSessionReferences.count
                < Self.maximumRetainedIdentityCount,
              handshakeBoundSessionReferences.insert(key).inserted else {
            return false
        }
        emitLine(Self.productionIdentityHandshakeBoundLine(
            descriptor: descriptor,
            transport: .p2p,
            sessionReference: sessionReference,
            attemptReference: attemptOwner.attemptReference
        ))
        return true
    }

    /// Records a generic shipping-session identity terminal only after the
    /// recorder itself observed the matching authenticated session terminal.
    /// WebRTC has no SOA attempt identifier, so its fixed schema explicitly
    /// uses `attempt_ref=not-applicable` rather than inventing one.
    @discardableResult
    func recordProductionIdentityHandshakeBound(
        descriptor: ProductIdentityEvidenceDescriptor,
        sessionOwner: ProductEvidenceSessionOwner,
        attemptReference: String? = nil
    ) -> Bool {
        let key = IdentitySessionKey(
            transport: sessionOwner.transport,
            sessionReference: sessionOwner.sessionReference
        )
        let sessionKey = SessionKey(
            transport: sessionOwner.transport,
            sessionReference: sessionOwner.sessionReference
        )
        guard descriptor.isFormalProductionIdentity,
              restoredIdentityReferences.contains(descriptor.identityReference),
              var state = sessionsByGeneration[sessionOwner.generation],
              state.owner == sessionOwner,
              currentSessionOwners[sessionKey] == sessionOwner,
              Self.sessionIsAuthenticatedForIdentityBinding(state),
              state.emittedLineCount
                < Self.maximumEvidenceLineCountPerSession,
              Self.isValidAttemptReference(
                attemptReference,
                for: sessionOwner.transport
              ),
              handshakeBoundSessionReferences.count
                < Self.maximumRetainedIdentityCount,
              handshakeBoundSessionReferences.insert(key).inserted else {
            return false
        }
        state.emittedLineCount += 1
        sessionsByGeneration[sessionOwner.generation] = state
        emitLine(Self.productionIdentityHandshakeBoundLine(
            descriptor: descriptor,
            transport: sessionOwner.transport,
            sessionReference: sessionOwner.sessionReference,
            attemptReference: attemptReference ?? "not-applicable"
        ))
        return true
    }

    /// Records only the exact user-initiated identity that won both immutable
    /// Keychain slots and was published after the authenticated current-path
    /// rotation receipt.  A reconciled or pre-existing slot must not call this.
    @discardableResult
    func recordProductionIdentityCommitted(
        _ descriptor: ProductIdentityEvidenceDescriptor
    ) -> Bool {
        guard descriptor.isFormalProductionIdentity,
              committedIdentityReferences.count
                < Self.maximumRetainedIdentityCount,
              committedIdentityReferences.insert(
                descriptor.identityReference
              ).inserted else {
            return false
        }
        emitLine((["productionIdentityCommitted"]
            + Self.identityFields(descriptor)
            + [
                "persistence=keychain-authority",
                "created=1",
                "result=success"
            ]).joined(separator: " "))
        return true
    }

    /// Records only a slot whose immutable key and authority existed before
    /// this process resolved it and whose restored Secure Enclave handle passed
    /// the real signing verification performed by `SkyBridgeiOSCore`.
    @discardableResult
    func recordProductionIdentityRestored(
        _ descriptor: ProductIdentityEvidenceDescriptor
    ) -> Bool {
        guard descriptor.isFormalProductionIdentity,
              !committedIdentityReferences.contains(
                descriptor.identityReference
              ),
              restoredIdentityReferences.count
                < Self.maximumRetainedIdentityCount,
              restoredIdentityReferences.insert(
                descriptor.identityReference
              ).inserted else {
            return false
        }
        emitLine((["productionIdentityRestored"]
            + Self.identityFields(descriptor)
            + [
                "persistence=keychain-authority",
                "selfTest=verified",
                "result=success"
            ]).joined(separator: " "))
        return true
    }

    private static func productionIdentityHandshakeBoundLine(
        descriptor: ProductIdentityEvidenceDescriptor,
        transport: ProductEvidenceTransport,
        sessionReference: String,
        attemptReference: String
    ) -> String {
        (["productionIdentityHandshakeBound", "transport=\(transport.rawValue)"]
            + [
                "session_ref=\(sessionReference)",
                "attempt_ref=\(attemptReference)"
            ]
            + identityFields(descriptor)
            + [
                "localSignature=used",
                "peerVerification=authenticated-finished",
                "currentPathAuthority=verified",
                "result=success"
            ]).joined(separator: " ")
    }

    private static func sessionIsAuthenticatedForIdentityBinding(
        _ state: SessionState
    ) -> Bool {
        switch state.owner.transport {
        case .p2p:
            return state.p2pAuthenticated
        case .webrtc:
            return state.webrtcRekeyAuthenticated
        }
    }

    private static func isValidAttemptReference(
        _ reference: String?,
        for transport: ProductEvidenceTransport
    ) -> Bool {
        switch transport {
        case .p2p:
            return reference.map(ProductConnectivityAttemptReference.isValid) == true
        case .webrtc:
            return reference == nil
        }
    }

    private static func identityFields(
        _ descriptor: ProductIdentityEvidenceDescriptor
    ) -> [String] {
        [
            "identity_ref=\(descriptor.identityReference)",
            "algorithm=\(descriptor.algorithm.rawValue)",
            "protection=\(descriptor.protection.rawValue)"
        ]
    }

    private func mutateCurrent(
        _ owner: ProductEvidenceSessionOwner,
        mutation: (inout SessionState) -> (String, [String])?
    ) -> Bool {
        let key = SessionKey(
            transport: owner.transport,
            sessionReference: owner.sessionReference
        )
        guard currentSessionOwners[key] == owner,
              var state = sessionsByGeneration[owner.generation],
              state.owner == owner,
              state.emittedLineCount < Self.maximumEvidenceLineCountPerSession,
              let (event, fields) = mutation(&state) else {
            return false
        }
        state.emittedLineCount += 1
        sessionsByGeneration[owner.generation] = state
        emit(event: event, fields: ownerFields(owner) + fields)
        return true
    }

    private func ownerFields(_ owner: ProductEvidenceSessionOwner) -> [String] {
        [
            "transport=\(owner.transport.rawValue)",
            "session_ref=\(owner.sessionReference)",
            "owner=SkyBridgeCompassiOS",
            "generation=\(owner.generation)"
        ]
    }

    private func emit(event: String, fields: [String]) {
        emitLine(([event] + fields).joined(separator: " "))
    }

    /// Verifies and records a strict classic-offer rejection as one atomic
    /// observation. The caller cannot substitute a Boolean "verified" claim or
    /// a detached suite list for the signed MessageA.
    @discardableResult
    func recordStrictPQCClassicOfferRejection(
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
              recordedRejectionAttemptReferences.count
                < Self.maximumRetainedRejectionCount,
              !recordedRejectionAttemptReferences.contains(attemptReference),
              nextAttemptGeneration < UInt64.max,
              let started = ProductConnectivityEvidenceFormatter.beginAttempt(
                product: .iOSApp,
                attemptReference: attemptReference,
                generation: nextAttemptGeneration,
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
        recordedRejectionAttemptReferences.insert(attemptReference)
        nextAttemptGeneration += 1
        emitLine(started.line)
        emitLine(rejected)
        return true
    }

    @discardableResult
    func fail(
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
}

enum ProductEvidenceTransport: String, Sendable, Hashable {
    case p2p
    case webrtc
}

enum ProductEvidenceRouteClass: String, Sendable {
    case wifi
    case awdl
}

enum ProductEvidenceSelectedTransport: String, Sendable {
    case direct
    case relay
}

struct ProductEvidenceSessionOwner: Sendable, Hashable {
    let transport: ProductEvidenceTransport
    let sessionReference: String
    let generation: UInt64
}

enum ProductEvidenceMediaRole: String, Sendable {
    case sender
    case receiver
}

struct ProductEvidenceMediaSample: Sendable, Equatable {
    let role: ProductEvidenceMediaRole
    let sequence: Int
    let elapsedMilliseconds: UInt64
    let videoFrames: UInt64
    let videoBytes: UInt64
    let audioUnits: UInt64
    let audioBytes: UInt64

    init?(
        role: ProductEvidenceMediaRole,
        sequence: Int,
        elapsedMilliseconds: UInt64,
        videoFrames: UInt64,
        videoBytes: UInt64,
        audioUnits: UInt64,
        audioBytes: UInt64
    ) {
        guard (1...4).contains(sequence),
              elapsedMilliseconds <= 120_000,
              videoFrames > 0,
              videoBytes > 0,
              audioUnits > 0,
              audioBytes > 0 else {
            return nil
        }
        self.role = role
        self.sequence = sequence
        self.elapsedMilliseconds = elapsedMilliseconds
        self.videoFrames = videoFrames
        self.videoBytes = videoBytes
        self.audioUnits = audioUnits
        self.audioBytes = audioBytes
    }

    fileprivate func isStrictlyAfter(_ previous: Self?) -> Bool {
        guard let previous else {
            return sequence == 1 && elapsedMilliseconds <= 5_000
        }
        return role == previous.role
            && sequence == previous.sequence + 1
            && elapsedMilliseconds > previous.elapsedMilliseconds
            && videoFrames > previous.videoFrames
            && videoBytes > previous.videoBytes
            && audioUnits > previous.audioUnits
            && audioBytes > previous.audioBytes
    }
}

enum ProductEvidenceFileDirection: String, Sendable {
    case send
    case receive

    fileprivate var interaction: String {
        switch self {
        case .send: "send-ui"
        case .receive: "accept-ui"
        }
    }
}

enum ProductEvidenceDisconnectReason: String, Sendable {
    case user
    case peer
    case trustInvalidated = "trust-invalidated"
    case sessionReplaced = "session-replaced"
    case protocolFailure = "protocol-failure"
}
