import Foundation
import CryptoKit
import Network
import os
import SkyBridgeProtocolCore

/// Published only by the successful, exact-session pairing commit. Discovery and
/// heartbeat presentation metadata must never be used to construct this receipt.
struct IOSAudioPeerSnapshot: Sendable, Equatable {
    let generation: UUID
    let sessionID: String
    let identity: AudioProtocolIdentity
    let capabilities: Set<String>
    let filePort: UInt16?
    let acceptedMaterialDigest: Data

    var trustStoreDeviceID: String? {
        PeerIdentityAliasResolver.authorityBoundPersistentDeviceId(from: identity.deviceID)
    }
}

extension IOSAudioPeerSnapshot {
    init(generation: UUID, sessionID: String, authority: ValidatedPairingIdentityAuthority,
         capabilities: Set<String>, filePort: UInt16?, acceptedMaterialDigest: Data) throws {
        guard let algorithm = SkyBridgeProtocolCore.ProtocolSigningAlgorithm(
            rawValue: authority.protocolSigningAlgorithm.rawValue) else {
            throw AudioMembershipError.invalidIdentity
        }
        let identity = try AudioProtocolIdentity(deviceID: authority.protocolDeviceId,
            algorithm: algorithm, fingerprint: authority.protocolPublicKeyFingerprint)
        self.init(generation: generation, sessionID: sessionID, identity: identity,
            capabilities: capabilities, filePort: filePort, acceptedMaterialDigest: acceptedMaterialDigest)
    }
}

/// Admission precedes the UI and asynchronous durable pairing transaction. The
/// captured ticket cannot be refreshed by an old transaction after a rejection,
/// replacement proposal, trust repair, or handshake restart.
struct IOSAudioAdmission: Sendable {
    struct Proposal: Sendable, Equatable {
        let materialDigest: Data
        let capabilities: Set<String>
        let filePort: UInt16?
    }
    struct Ticket: Sendable, Equatable {
        fileprivate let generation: UUID
        fileprivate let revision: UUID
        fileprivate let proposal: Proposal
    }
    let generation: UUID
    let deviceID: String
    private var revision = UUID()
    private var proposal: Proposal?

    init(generation: UUID, deviceID: String) { self.generation = generation; self.deviceID = deviceID }

    mutating func observe(_ proposed: Proposal) -> Ticket {
        if proposal != proposed { revision = UUID(); proposal = proposed }
        return Ticket(generation: generation, revision: revision, proposal: proposed)
    }
    mutating func invalidate() { revision = UUID(); proposal = nil }
    func permits(_ ticket: Ticket, proposal expected: Proposal) -> Bool {
        ticket.generation == generation && ticket.revision == revision &&
            proposal == expected && ticket.proposal == expected
    }
}

/// The sole MAIN reader decrypts once, then uses this discriminator. A recognized
/// malformed audio envelope is an error, never input to the legacy JSON decoder.
enum IOSAuthenticatedControlPayload: Sendable {
    case audio(AudioStreamingMessage)
    case app(AppMessage)

    static func decode(_ plaintext: Data) throws -> Self {
        if let message = try AudioStreamingLANEnvelope.decodeIfPresent(plaintext) { return .audio(message) }
        return .app(try AppMessage.decodeWireMessage(from: plaintext))
    }
}

private final class IOSAudioEpochValidity: Sendable {
    private let active = OSAllocatedUnfairLock(initialState: true)
    func invalidate() { active.withLock { $0 = false } }
    func requireCurrent() throws {
        guard active.withLock({ $0 }) else { throw AudioStreamingChannelError.staleOwner }
    }
}

enum IOSAudioFileRoute: Sendable, Equatable {
    case network(NWEndpoint)
    case usbReturn
}

/// One native iOS owner of the already encrypted MAIN audio carrier. This type
/// neither obtains account evidence nor grants playback permission. Its caller
/// must supply an effect check for every positive send.
@MainActor
final class IOSAudioSession {
    struct StreamHistory: Sendable { fileprivate let retired: Set<UUID> }
    enum ReceiveDisposition: Equatable { case delivered, retired, unavailable }
    let generation: UUID
    let keys: SessionKeys
    let localIdentity: ProtocolIdentityBinding
    let peer: IOSAudioPeerSnapshot
    let fileRoute: IOSAudioFileRoute?
    private let requireConnection: @MainActor () throws -> Void
    private let sendFrame: @MainActor (Data, AudioStreamingSendCompletion) -> Void
    private let cancelTransport: @Sendable () -> Void
    private let validity = IOSAudioEpochValidity()
    private var mailbox: AudioStreamingMailbox?
    private var firstOffer: AudioStreamingMessage?
    private var retired: Set<UUID>
    private var invalidated = false
    private var usbFileRouteSubmitted = false
    private var fileAccepted = false

    init(generation: UUID, keys: SessionKeys, localIdentity: ProtocolIdentityBinding,
         peer: IOSAudioPeerSnapshot, fileRoute: IOSAudioFileRoute?, history: StreamHistory? = nil,
         requireConnection: @escaping @MainActor () throws -> Void,
         sendFrame: @escaping @MainActor (Data, AudioStreamingSendCompletion) -> Void,
         cancelTransport: @escaping @Sendable () -> Void) throws {
        guard generation == peer.generation, keys.sessionId == peer.sessionID, peer.acceptedMaterialDigest.count == 32 else {
            throw AudioStreamingChannelError.staleOwner
        }
        guard localIdentity.deviceId != peer.identity.deviceID else { throw AudioMembershipError.selfPlayback }
        self.generation = generation; self.keys = keys; self.localIdentity = localIdentity
        self.peer = peer; self.fileRoute = fileRoute; retired = history?.retired ?? []
        self.requireConnection = requireConnection; self.sendFrame = sendFrame; self.cancelTransport = cancelTransport
        try requireConnection()
    }

    func matches(generation: UUID, keys other: SessionKeys) -> Bool {
        self.generation == generation && keys.sessionId == other.sessionId && keys.role == other.role &&
            keys.negotiatedSuite == other.negotiatedSuite && keys.transcriptHash == other.transcriptHash &&
            keys.sendKey == other.sendKey && keys.receiveKey == other.receiveKey
    }

    var isInvalidated: Bool { invalidated }
    func streamHistory() -> StreamHistory { retireClosedMailbox(); return StreamHistory(retired: retired) }

    /// Preserve tombstones for a failed rekey's same-epoch rollback; every old
    /// channel remains terminal. A replacement connection starts its own history.
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true; validity.invalidate(); retireMailbox(.staleOwner)
    }

    func open(requiringFingerprint fingerprint: String) throws -> IOSAudioChannel {
        try requireSession()
        guard peer.identity.fingerprint == fingerprint else { throw AudioStreamingChannelError.staleOwner }
        retireClosedMailbox()
        guard mailbox == nil else { throw AudioStreamingChannelError.alreadyRegistered }
        guard retired.count < 64 else { throw AudioStreamingChannelError.epochCapacity }
        let box = AudioStreamingMailbox(); mailbox = box; firstOffer = nil
        let validity = self.validity
        return IOSAudioChannel(mailbox: box, localIdentity: localIdentity, remoteIdentity: peer.identity,
            peerCapabilities: peer.capabilities, fileRoute: fileRoute,
            validateMessages: { try validity.requireCurrent() },
            requireCurrent: { [weak self] in
                guard let self else { throw AudioStreamingChannelError.staleOwner }
                try self.requireCurrent(box)
            }, send: { [weak self] message, authorize in
                guard let self else { throw AudioStreamingChannelError.staleOwner }
                try await self.send(message, mailbox: box, authorize: authorize)
            }, fileAuthority: { [weak self] rawTransferID in
                guard let self else { throw AudioStreamingChannelError.staleOwner }
                try self.requireCurrent(box)
                guard case let .fileOffer(id, length, digest)? = self.firstOffer?.body,
                      UUID(uuidString: rawTransferID) == id, let route = self.fileRoute else {
                    throw AudioStreamingChannelError.fileTransferMismatch
                }
                let material = P2PConnectionManager.ClassicFileTransferKeyMaterial(sessionKeys: self.keys,
                    transferId: rawTransferID, connectionGeneration: self.generation,
                    approvalCapability: self.peer.capabilities.contains("classic_approval_v1"))
                return IOSAudioFileAuthority(route: route, material: material,
                    offeredLength: length, offeredSHA256: digest)
            }, prepareBluetooth: { [weak self] in
                guard let self else { throw AudioStreamingChannelError.staleOwner }
                try self.requireCurrent(box)
                let binding = try box.takeBluetoothBinding()
                let secret = try AudioBluetoothAttachmentSecret(binding: binding, sendKey: self.keys.sendKey,
                    receiveKey: self.keys.receiveKey, transcriptHash: self.keys.transcriptHash,
                    suite: self.keys.negotiatedSuite.wireId)
                return AudioBluetoothAttachment(binding: binding, secret: secret, requireParentCurrent: {
                    try validity.requireCurrent()
                    try box.requireBluetoothBindingCurrent()
                })
            }, close: { [weak self] in
                if let self, self.mailbox === box { self.retireMailbox(.closed) }
                else { box.finish(.closed) }
            })
    }

    func receive(_ message: AudioStreamingMessage) throws -> ReceiveDisposition {
        try requireSession(); retireClosedMailbox()
        if retired.contains(message.streamID) { return .retired }
        guard let mailbox, firstOffer != nil else { return .unavailable }
        do { try mailbox.receive(message) }
        catch let failure as AudioStreamingChannelError {
            // A recognized stream violation retires audio and wakes its consumer.
            // It cannot authorize a new stream or tear down unrelated MAIN work.
            retireMailbox(failure)
            return .retired
        }
        if case .fileOffer? = firstOffer?.body, case .accept(receiveWindowBytes: 0) = message.body {
            fileAccepted = true
        }
        return .delivered
    }

    private func requireSession() throws {
        try validity.requireCurrent()
        do { try requireConnection() }
        catch { invalidate(); throw error }
    }
    private func requireCurrent(_ box: AudioStreamingMailbox) throws {
        try requireSession(); try box.requireActive()
        guard mailbox === box else { throw AudioStreamingChannelError.staleOwner }
    }
    private func retireClosedMailbox() {
        if mailbox?.isTerminal == true { retireMailbox(.closed) }
    }
    private func retireMailbox(_ error: AudioStreamingChannelError) {
        if let stream = mailbox?.streamID { retired.insert(stream) }
        mailbox?.finish(error); mailbox = nil; firstOffer = nil; usbFileRouteSubmitted = false; fileAccepted = false
    }

    private func send(_ message: AudioStreamingMessage, mailbox box: AudioStreamingMailbox,
                      authorize: (@MainActor () throws -> Void)?) async throws {
        try Task.checkCancellation(); try requireCurrent(box)
        if case .fileOffer = message.body {
            switch fileRoute {
            case .network(let endpoint):
                guard let port = peer.filePort, port > 0,
                      case let .hostPort(_, endpointPort) = endpoint, endpointPort.rawValue == port else {
                    throw AudioStreamingChannelError.unavailable
                }
            case .usbReturn:
                guard peer.capabilities.contains(AudioStreamingWire.usbFileReceiveCapability),
                      peer.capabilities.contains("classic_approval_v1") else {
                    throw AudioStreamingChannelError.unsupportedPeer
                }
            case nil: throw AudioStreamingChannelError.unavailable
            }
        }
        if case .usbFileRoute = message.body {
            guard fileRoute == .usbReturn, fileAccepted, !usbFileRouteSubmitted,
                  case .fileOffer? = firstOffer?.body else { throw AudioStreamingChannelError.fileTransferMismatch }
        }
        let payload = try AudioStreamingLANEnvelope.encode(message)
        let sealed = try AES.GCM.seal(payload, using: SymmetricKey(data: keys.sendKey))
        guard let ciphertext = sealed.combined else { throw AudioStreamingChannelError.unavailable }
        let frame = try P2PControlFramePolicy.frame(body: TrafficPadding.wrapForP2PControlFrame(ciphertext, label: "audio"))
        let completion = AudioStreamingSendCompletion()
        defer { box.finishSend(completion) }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    completion.install(continuation)
                    do {
                        guard completion.isPending else { return }
                        try requireCurrent(box)
                        try authorize?() // Same MainActor turn as the actual NW send enqueue below.
                        try requireCurrent(box)
                        guard !retired.contains(message.streamID) else { throw AudioStreamingChannelError.unexpectedStream }
                        try box.prepareSend(message, peerCapabilities: peer.capabilities, completion: completion)
                        if firstOffer == nil { firstOffer = message }
                        guard completion.markSubmitted() else { return }
                        if case .usbFileRoute = message.body { usbFileRouteSubmitted = true }
                        sendFrame(frame, completion)
                        completion.startWriteDeadline(cancelTransport: cancelTransport)
                    } catch { completion.finish(.failure(error)) }
                }
                try Task.checkCancellation(); try requireCurrent(box)
                // A queued frame is not a completed negotiation. Publish the
                // binding only after the native write and exact-owner recheck.
                try box.commitSent(message)
            } onCancel: {
                if completion.finish(.failure(CancellationError())) { box.finish(.closed) }
            }
        } catch {
            switch error as? AudioStreamingChannelError {
            case .unsupportedPeer, .sendInProgress, .unexpectedStream, .offerRequired: break
            default: if mailbox === box { retireMailbox(.closed) }
            }
            throw error
        }
    }

    deinit { validity.invalidate(); mailbox?.finish(.staleOwner) }
}

struct IOSAudioFileAuthority: Sendable {
    let route: IOSAudioFileRoute
    let material: P2PConnectionManager.ClassicFileTransferKeyMaterial
    let offeredLength: UInt64
    let offeredSHA256: Data
}

@MainActor
final class IOSAudioChannel {
    let ownerID: UUID
    let remoteIdentity: AudioProtocolIdentity
    let peerCapabilities: Set<String>
    let fileRoute: IOSAudioFileRoute?
    let messages: AudioStreamingMessages
    /// A fixed mailbox/epoch predicate for the synchronous shared lease. Actual
    /// effects still call the full MainActor requireCurrent() on this carrier.
    let isCurrentForMembership: @Sendable () -> Bool
    private let localIdentity: ProtocolIdentityBinding
    private let mailbox: AudioStreamingMailbox
    private let validate: @MainActor () throws -> Void
    private let sendOperation: @MainActor (AudioStreamingMessage, (@MainActor () throws -> Void)?) async throws -> Void
    private let fileAuthority: @MainActor (String) throws -> IOSAudioFileAuthority
    private let prepareBluetooth: @MainActor () throws -> AudioBluetoothAttachment
    private let closeOperation: @MainActor () -> Void
    private var operationOwner: UUID?

    fileprivate init(mailbox: AudioStreamingMailbox, localIdentity: ProtocolIdentityBinding,
        remoteIdentity: AudioProtocolIdentity, peerCapabilities: Set<String>, fileRoute: IOSAudioFileRoute?,
        validateMessages: @escaping @Sendable () throws -> Void,
        requireCurrent: @escaping @MainActor () throws -> Void,
        send: @escaping @MainActor (AudioStreamingMessage, (@MainActor () throws -> Void)?) async throws -> Void,
        fileAuthority: @escaping @MainActor (String) throws -> IOSAudioFileAuthority,
        prepareBluetooth: @escaping @MainActor () throws -> AudioBluetoothAttachment,
        close: @escaping @MainActor () -> Void) {
        self.mailbox = mailbox; ownerID = mailbox.id; self.localIdentity = localIdentity
        self.remoteIdentity = remoteIdentity; self.peerCapabilities = peerCapabilities; self.fileRoute = fileRoute; validate = requireCurrent
        sendOperation = send; self.fileAuthority = fileAuthority; closeOperation = close
        self.prepareBluetooth = prepareBluetooth
        messages = AudioStreamingMessages(mailbox: mailbox, validateOwner: validateMessages)
        isCurrentForMembership = {
            do { try validateMessages(); try mailbox.requireActive(); return true }
            catch { return false } // A terminal owner cannot be replaced by a discovery lookup.
        }
    }
    func requireCurrent() throws { try validate() }
    /// Capture/file orchestration claims a channel once, before any await. A
    /// failed competing operation must leave this channel with its prior owner.
    func claimOperation(_ owner: UUID) throws {
        try requireCurrent()
        guard operationOwner == nil, mailbox.streamID == nil else { throw AudioStreamingChannelError.alreadyRegistered }
        operationOwner = owner
    }
    func localIdentityBindingForAccountRequest() throws -> ProtocolIdentityBinding {
        try requireCurrent(); return localIdentity
    }
    func send(_ message: AudioStreamingMessage, requireEffectAuthorization: @escaping @MainActor () throws -> Void) async throws {
        try await sendOperation(message, requireEffectAuthorization)
    }
    /// A negative terminal control grants no playback. It still uses this exact
    /// live connection/channel; a closed or never-offered channel cannot send it.
    func sendStop(_ reason: AudioStreamingStopReason) async throws {
        try requireCurrent()
        guard let id = mailbox.streamID else { throw AudioStreamingChannelError.offerRequired }
        try await sendOperation(.init(streamID: id, body: .stop(reason)), nil)
    }
    func classicFileAuthority(transferID: String) throws -> IOSAudioFileAuthority { try fileAuthority(transferID) }

    /// A single child binding from the completed Opus/route exchange. It carries
    /// the captured parent's identity lifetime, not account or playback approval.
    func prepareBluetoothAttachment() throws -> AudioBluetoothAttachment {
        try Task.checkCancellation(); try requireCurrent()
        let attachment = try prepareBluetooth()
        do {
            try Task.checkCancellation(); try requireCurrent()
            return attachment
        } catch { attachment.close(); throw error }
    }
    func announceUSBFileReturn(port: UInt16, transferID: String,
                               requireEffectAuthorization: @escaping @MainActor () throws -> Void) async throws {
        let authority = try classicFileAuthority(transferID: transferID)
        guard authority.route == .usbReturn, let stream = mailbox.streamID else {
            throw AudioStreamingChannelError.fileTransferMismatch
        }
        try await sendOperation(.init(streamID: stream, body: .usbFileRoute(port: port)), requireEffectAuthorization)
    }
    func close() { closeOperation() }
    deinit { mailbox.finish(.closed) }
}
