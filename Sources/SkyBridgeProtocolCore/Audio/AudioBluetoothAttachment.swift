import CryptoKit
import Foundation
import os

/// A route received inside the authenticated MAIN audio exchange. It locates a CoC service;
/// neither its UUIDs nor an OS Bluetooth pairing establish account or playback authority.
public struct AudioBluetoothRoute: Equatable, Sendable {
    public let serviceID: UUID
    public let publicationID: UUID
    public let psm: UInt16

    public init(serviceID: UUID, publicationID: UUID, psm: UInt16) throws {
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        guard serviceID != zero, publicationID != zero, (1...255).contains(psm) else {
            throw AudioBluetoothAttachmentError.invalidBinding
        }
        self.serviceID = serviceID; self.publicationID = publicationID; self.psm = psm
    }
}

public enum AudioBluetoothAttachmentError: Error, Equatable, Sendable {
    case invalidBinding, unexpectedMessage, notReady, alreadyIssued, closed, expired
    case invalidNonce, authenticationFailed
    case recordLimit, recordOrder, malformedRecord, unsupportedMediaRole
}

public enum AudioBluetoothRole: UInt8, Sendable {
    case source = 1, sink = 2
    public var peer: Self { self == .source ? .sink : .source }
}

public struct AudioBluetoothBinding: Sendable {
    public let role: AudioBluetoothRole
    public let offer: AudioStreamingMessage
    public let route: AudioStreamingMessage
}

/// Synchronous state confined to the existing carrier owner lock. MAIN carries preparation only:
/// one source offer, one sink route and Stop. Encoded media must use the confirmed CoC channel.
public struct AudioBluetoothNegotiation: Sendable {
    public let role: AudioBluetoothRole
    private let streamID: UUID
    private var offer: AudioStreamingMessage?
    private var route: AudioStreamingMessage?
    private var offerCommitted = false
    private var routeCommitted = false
    private var issued = false
    private var stopped = false

    public init(role: AudioBluetoothRole, streamID: UUID) {
        self.role = role; self.streamID = streamID
    }

    public mutating func prepareSend(_ message: AudioStreamingMessage) throws { try record(message, incoming: false) }
    public mutating func receive(_ message: AudioStreamingMessage) throws { try record(message, incoming: true) }

    /// Called only after actual frame completion and another exact-owner check.
    public mutating func commitSend(_ message: AudioStreamingMessage) throws {
        if message.streamID == streamID, case .stop = message.body { return }
        guard !stopped, message.streamID == streamID else { throw AudioBluetoothAttachmentError.closed }
        if role == .source, message == offer { offerCommitted = true }
        else if role == .sink, message == route { routeCommitted = true }
        else { throw AudioBluetoothAttachmentError.unexpectedMessage }
    }

    public mutating func takeBinding() throws -> AudioBluetoothBinding {
        guard !stopped else { throw AudioBluetoothAttachmentError.closed }
        guard !issued else { throw AudioBluetoothAttachmentError.alreadyIssued }
        guard let offer, let route, offerCommitted, routeCommitted else { throw AudioBluetoothAttachmentError.notReady }
        issued = true
        return .init(role: role, offer: offer, route: route)
    }

    /// A previously issued child remains subordinate to this exact MAIN exchange.
    /// Stop retires it immediately, independently of asynchronous transport cleanup.
    public func requireIssuedBindingCurrent() throws {
        guard !stopped else { throw AudioBluetoothAttachmentError.closed }
        guard issued else { throw AudioBluetoothAttachmentError.notReady }
    }

    private mutating func record(_ message: AudioStreamingMessage, incoming: Bool) throws {
        guard !stopped else { throw AudioBluetoothAttachmentError.closed }
        guard message.streamID == streamID else { throw AudioBluetoothAttachmentError.invalidBinding }
        switch message.body {
        case .opusOffer, .bufferedOpusFileOffer:
            guard offer == nil, incoming == (role == .sink) else { throw AudioBluetoothAttachmentError.unexpectedMessage }
            offer = message; offerCommitted = incoming
        case .bluetoothRoute:
            guard offer != nil, route == nil, incoming == (role == .source) else { throw AudioBluetoothAttachmentError.unexpectedMessage }
            route = message; routeCommitted = incoming
        case .stop: stopped = true
        default: throw AudioBluetoothAttachmentError.unexpectedMessage
        }
    }
}

/// HKDF/HMAC building block, not a trusted-session constructor. Production callers obtain it only
/// through a Finished-verified, committed-pairing carrier and a completed negotiation snapshot.
/// No MAIN traffic key is returned or reused directly on the Bluetooth connection.
public struct AudioBluetoothAttachmentSecret: Sendable {
    private let key: SymmetricKey
    private let context: Data

    public init(binding: AudioBluetoothBinding, sendKey: Data, receiveKey: Data,
                transcriptHash: Data, suite: UInt16) throws {
        guard sendKey.count == 32, receiveKey.count == 32, sendKey != receiveKey, transcriptHash.count == 32,
              binding.offer.streamID == binding.route.streamID,
              binding.offer.body.opusOfferParameters != nil, case .bluetoothRoute = binding.route.body else {
            throw AudioBluetoothAttachmentError.invalidBinding
        }
        var transcript = Data("SkyBridge-Audio-Bluetooth-Binding-v1|".utf8)
        transcript.append(UInt8(suite >> 8)); transcript.append(UInt8(suite & 255))
        transcript.append(transcriptHash)
        transcript.append(try AudioStreamingWire.encode(binding.offer))
        transcript.append(try AudioStreamingWire.encode(binding.route))
        context = Data(SHA256.hash(data: transcript))
        let material = binding.role == .source ? sendKey + receiveKey : receiveKey + sendKey
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: transcriptHash,
            info: Data("SkyBridge-Audio-Bluetooth-Attachment-v1|".utf8) + context, outputByteCount: 32)
    }

    public func confirmation(role: AudioBluetoothRole, sourceNonce: Data, sinkNonce: Data) throws -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: try confirmationInput(role, sourceNonce, sinkNonce), using: key))
    }

    public func verify(_ proof: Data, role: AudioBluetoothRole, sourceNonce: Data, sinkNonce: Data) throws {
        guard proof.count == 32,
              HMAC<SHA256>.isValidAuthenticationCode(proof,
                authenticating: try confirmationInput(role, sourceNonce, sinkNonce), using: key) else {
            throw AudioBluetoothAttachmentError.authenticationFailed
        }
    }

    private func confirmationInput(_ role: AudioBluetoothRole, _ source: Data, _ sink: Data) throws -> Data {
        guard source.count == 32, sink.count == 32, source != sink else { throw AudioBluetoothAttachmentError.invalidNonce }
        return Data("SkyBridge-Audio-Bluetooth-Confirm-v1|".utf8) + context + Data([role.rawValue]) + source + sink
    }

    func helloProof(_ source: Data) throws -> Data {
        guard source.count == 32 else { throw AudioBluetoothAttachmentError.invalidNonce }
        return tag(domain: "SkyBridge-Audio-Bluetooth-Hello-v1|", payload: source)
    }

    func verifyHello(_ proof: Data, source: Data) throws {
        guard source.count == 32, proof.count == 32,
              HMAC<SHA256>.isValidAuthenticationCode(proof,
                authenticating: Data("SkyBridge-Audio-Bluetooth-Hello-v1|".utf8) + context + source, using: key) else {
            throw AudioBluetoothAttachmentError.authenticationFailed
        }
    }

    func readyProof(source: Data, sink: Data) throws -> Data {
        guard source.count == 32, sink.count == 32, source != sink else { throw AudioBluetoothAttachmentError.invalidNonce }
        return tag(domain: "SkyBridge-Audio-Bluetooth-Ready-v1|", payload: source + sink)
    }

    func verifyReady(_ proof: Data, source: Data, sink: Data) throws {
        guard source.count == 32, sink.count == 32, source != sink, proof.count == 32,
              HMAC<SHA256>.isValidAuthenticationCode(proof,
                authenticating: Data("SkyBridge-Audio-Bluetooth-Ready-v1|".utf8) + context + source + sink, using: key) else {
            throw AudioBluetoothAttachmentError.authenticationFailed
        }
    }

    func traffic(role: AudioBluetoothRole, source: Data, sink: Data) throws -> AudioBluetoothTrafficMaterial {
        guard source.count == 32, sink.count == 32, source != sink else { throw AudioBluetoothAttachmentError.invalidNonce }
        let sessionContext = Data(SHA256.hash(data: Data("SkyBridge-Audio-Bluetooth-Session-v1|".utf8) + context + source + sink))
        func derive(_ role: AudioBluetoothRole) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: sessionContext,
                info: Data("SkyBridge-Audio-Bluetooth-Traffic-v1|".utf8) + Data([role.rawValue]), outputByteCount: 32)
        }
        return .init(context: sessionContext, sendKey: derive(role), receiveKey: derive(role.peer))
    }

    private func tag(domain: String, payload: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(domain.utf8) + context + payload, using: key))
    }
}

/// A short-lived preparation handle. Each proof operation still requires the exact parent owner;
/// successful key confirmation is not account membership, consent, or permission to output sound.
public final class AudioBluetoothAttachment: Sendable {
    private struct State: Sendable {
        var secret: AudioBluetoothAttachmentSecret?
        var claimed = false, established = false, closed = false
    }
    public let binding: AudioBluetoothBinding
    private let state: OSAllocatedUnfairLock<State>
    private let requireParentCurrent: @Sendable () throws -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    private let deadline: ContinuousClock.Instant

    public init(binding: AudioBluetoothBinding, secret: AudioBluetoothAttachmentSecret,
                requireParentCurrent: @escaping @Sendable () throws -> Void,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.binding = binding; self.state = .init(initialState: State(secret: secret))
        self.requireParentCurrent = requireParentCurrent; self.now = now
        deadline = now().advanced(by: .seconds(30))
    }

    public func confirmation(sourceNonce: Data, sinkNonce: Data) throws -> Data {
        try perform { try $0.confirmation(role: binding.role, sourceNonce: sourceNonce, sinkNonce: sinkNonce) }
    }

    public func verifyPeer(_ proof: Data, sourceNonce: Data, sinkNonce: Data) throws {
        try perform { try $0.verify(proof, role: binding.role.peer, sourceNonce: sourceNonce, sinkNonce: sinkNonce) }
    }

    /// A sink must supply the incoming Hello. Its MAC is checked before claiming this pending
    /// grant, so malformed or competing candidates cannot revoke the legitimate owner.
    public func beginHandshake(initialHello: Data? = nil) throws -> AudioBluetoothHandshake {
        let nonce = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return try beginHandshake(initialHello: initialHello, localNonce: nonce)
    }

    func beginHandshake(initialHello: Data?, localNonce: Data) throws -> AudioBluetoothHandshake {
        try requireParentCurrent()
        let claimed = try state.withLock { value -> (AudioBluetoothAttachmentSecret, Data) in
            guard !value.closed, !value.claimed, let secret = value.secret else { throw AudioBluetoothAttachmentError.alreadyIssued }
            guard now() < deadline else { throw AudioBluetoothAttachmentError.expired }
            guard localNonce.count == 32 else { throw AudioBluetoothAttachmentError.invalidNonce }
            let source: Data
            if binding.role == .sink {
                guard let initialHello else { throw AudioBluetoothAttachmentError.invalidBinding }
                let body = try AudioBluetoothHandshakeWire.body(initialHello, kind: 1, streamID: binding.offer.streamID, size: 64)
                source = Data(body.prefix(32))
                try secret.verifyHello(Data(body.suffix(32)), source: source)
                guard source != localNonce else { throw AudioBluetoothAttachmentError.invalidNonce }
            } else {
                guard initialHello == nil else { throw AudioBluetoothAttachmentError.invalidBinding }
                source = localNonce
            }
            value.claimed = true
            return (secret, source)
        }
        do {
            try requireHandshakeCurrent()
            return AudioBluetoothHandshake(owner: self, secret: claimed.0, localNonce: localNonce, sourceNonce: claimed.1)
        } catch { close(); throw error }
    }

    public func handshakeRemainingTime() throws -> Duration {
        try requireParentCurrent()
        return try state.withLock {
            guard !$0.closed, !$0.established else { throw AudioBluetoothAttachmentError.closed }
            let instant = now()
            guard instant < deadline else { throw AudioBluetoothAttachmentError.expired }
            return instant.duration(to: deadline)
        }
    }

    /// Lifetime observation across the handshake-to-established transition. This
    /// does not grant media access; media still requires requireEstablishedCurrent.
    public func requireLifetimeCurrent() throws {
        try requireParentCurrent()
        try state.withLock {
            guard !$0.closed else { throw AudioBluetoothAttachmentError.closed }
            if !$0.established, now() >= deadline { throw AudioBluetoothAttachmentError.expired }
        }
    }

    func requireHandshakeCurrent() throws {
        try requireParentCurrent()
        try state.withLock {
            guard !$0.closed, $0.claimed, !$0.established else { throw AudioBluetoothAttachmentError.closed }
            guard now() < deadline else { throw AudioBluetoothAttachmentError.expired }
        }
    }

    func commitHandshake() throws {
        try requireHandshakeCurrent()
        try state.withLock {
            guard !$0.closed, $0.claimed, !$0.established, now() < deadline else { throw AudioBluetoothAttachmentError.closed }
            $0.established = true; $0.secret = nil
        }
    }

    public func requireEstablishedCurrent() throws {
        try state.withLock {
            guard !$0.closed, $0.established else { throw AudioBluetoothAttachmentError.closed }
        }
        // Preparation expiry does not cap playback at 30 seconds. The exact MAIN owner still
        // has to be live; independent media/account lifetime is a separate admission boundary.
        try requireParentCurrent()
    }

    public func close() { state.withLock { $0.closed = true; $0.secret = nil } }

    private func perform<T: Sendable>(_ operation: @Sendable (AudioBluetoothAttachmentSecret) throws -> T) throws -> T {
        try requireParentCurrent()
        let value = try state.withLock { value in
            guard now() < deadline else { value.closed = true; value.secret = nil; throw AudioBluetoothAttachmentError.expired }
            guard !value.closed, let secret = value.secret else { throw AudioBluetoothAttachmentError.closed }
            guard !value.claimed else { throw AudioBluetoothAttachmentError.alreadyIssued }
            return try operation(secret)
        }
        try requireParentCurrent()
        guard now() < deadline else { close(); throw AudioBluetoothAttachmentError.expired }
        return value
    }
}
