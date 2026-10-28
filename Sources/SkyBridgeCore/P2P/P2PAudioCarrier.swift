import Foundation
import CryptoKit
import Network
import os
import SkyBridgeProtocolCore
import SkyBridgeAppleTransport

#if os(macOS)
private struct USBOriginalFileAcquisitionFailure: Error, Sendable {
    let primary: any Error
    let cleanup: any Error
}
#endif

/// Shared audio state for both outgoing P2PConnection and the existing MAIN inbound reader.
/// The host publishes Finished and committed pairing evidence; this owner never manufactures it.
/// All mutations and native send enqueue operations linearize on one bounded state lock.
@available(macOS 14.0, iOS 17.0, *)
final class P2PAudioCarrier: Sendable {
    struct StreamHistory: Sendable { fileprivate let retired: Set<UUID> }
    enum ReceiveDisposition: Equatable {
        case nonAudio, audio, unavailable
        case offerNeedsChannel(AudioStreamingMessage)
    }
    private struct Epoch: Sendable {
        let id = UUID()
        let keys: SessionKeys
        let peerBinding: AuthenticatedHandshakePeerBinding
        let localBinding: ProtocolIdentityBinding?
        func matches(_ other: SessionKeys) -> Bool {
            keys.sessionId == other.sessionId && keys.transcriptHash == other.transcriptHash
                && keys.sendKey == other.sendKey && keys.receiveKey == other.receiveKey && keys.role == other.role
                && keys.negotiatedSuite == other.negotiatedSuite
        }
    }
    private struct Peer: Sendable {
        let id = UUID()
        let identity: AudioProtocolIdentity
        let capabilities: Set<String>
    }
    private struct State: Sendable {
        var epoch: Epoch?
        var peer: Peer?
        var mailbox: P2PAudioMailbox?
        var retired: Set<UUID> = []
        var terminal = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let controlTransport: P2PConnection.ControlTransport
    typealias SendAuthorization = @Sendable () throws -> Void
    typealias LogicalFileAcquisition = @Sendable (@escaping SendAuthorization, @escaping SendAuthorization) async throws -> any ClassicFileTransferByteChannel
    private let sendFrame: @Sendable (Data, @escaping SendAuthorization, P2PAudioSendCompletion) -> Void
    private let cancelTransport: @Sendable () -> Void
    private let openUSBFileStream: (@Sendable (UInt16) async throws -> NWConnection)?
    private let acquireLogicalFile: LogicalFileAcquisition?
    private let logicalFileAvailable: @Sendable () -> Bool

    init(controlTransport: P2PConnection.ControlTransport,
         sendFrame: @escaping @Sendable (Data, @escaping SendAuthorization, P2PAudioSendCompletion) -> Void,
         cancelTransport: @escaping @Sendable () -> Void,
         openUSBFileStream: (@Sendable (UInt16) async throws -> NWConnection)? = nil,
         acquireLogicalFile: LogicalFileAcquisition? = nil,
         logicalFileAvailable: @escaping @Sendable () -> Bool = { false }) {
        self.sendFrame = sendFrame; self.cancelTransport = cancelTransport
        self.controlTransport = controlTransport
        self.openUSBFileStream = openUSBFileStream
        self.acquireLogicalFile = acquireLogicalFile; self.logicalFileAvailable = logicalFileAvailable
    }

    convenience init(connection: NWConnection, controlTransport: P2PConnection.ControlTransport,
                     usbDeviceID: String? = nil) {
        let open: (@Sendable (UInt16) async throws -> NWConnection)?
        #if os(macOS)
        if let usbDeviceID { open = { port in try await USBMultiplexTransport.open(udid: usbDeviceID, port: port) } }
        else { open = nil }
        #else
        open = nil
        #endif
        self.init(controlTransport: controlTransport, sendFrame: { frame, _, completion in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { completion.completeWrite(.failure(error)) }
                else { completion.completeWrite(.success(())) }
            })
        }, cancelTransport: { connection.cancel() }, openUSBFileStream: open)
    }

    #if os(macOS)
    convenience init(usbControl: USBHostControlFrameTransport, fileConnection: USBHostMultiplexConnection? = nil) {
        let available: @Sendable () -> Bool = {
            guard let fileConnection else { return false }
            return usbControl.belongs(to: fileConnection) && usbControl.isReady &&
                fileConnection.terminalFailure == nil && fileConnection.epochSnapshot?.phase == .ready
        }
        let acquire: LogicalFileAcquisition?
        if let fileConnection {
            acquire = { current, nativeEffect in
                try current()
                guard available() else { throw P2PAudioTransportError.unavailable }
                let stream = try await fileConnection.acceptStream(timeout: .seconds(5), priority: .bulk)
                do {
                    return try USBClassicFileTransferByteChannel(connection: fileConnection, stream: stream,
                        requireParentCurrent: current, requireParentWriteAuthorization: nativeEffect)
                } catch {
                    let primary = error
                    do { try await stream.closeAndAwait(timeout: .seconds(5)) }
                    catch {
                        // The runtime retains the parent and its native cleanup obligation.
                        // An unconfirmed child release cannot admit another file owner.
                        fileConnection.close()
                        throw USBOriginalFileAcquisitionFailure(primary: primary, cleanup: error)
                    }
                    throw primary
                }
            }
        } else { acquire = nil }
        self.init(controlTransport: .usb, sendFrame: { frame, authorization, completion in
            do {
                try usbControl.enqueueFramedBytes(frame, requireEffectAuthorization: authorization) {
                    completion.completeWrite($0)
                }
            } catch { completion.completeWrite(.failure(error)) }
        }, cancelTransport: { usbControl.close() }, acquireLogicalFile: acquire, logicalFileAvailable: available)
    }
    #endif

    /// A replacement epoch retires every old channel. Rollback can restore only stream history,
    /// never an old mailbox or pairing grant; a new committed exchange is required to open again.
    @discardableResult
    func publishFinished(keys: SessionKeys, peerBinding: AuthenticatedHandshakePeerBinding,
                         localBinding: ProtocolIdentityBinding?, restoring history: StreamHistory? = nil) -> Bool {
        state.withLock {
            guard !$0.terminal else { return false }
            let sameEpoch = $0.epoch?.matches(keys) == true
            Self.retire(&$0, failure: .staleOwner)
            if let history { $0.retired = history.retired }
            else if !sameEpoch { $0.retired.removeAll() }
            $0.epoch = Epoch(keys: keys, peerBinding: peerBinding, localBinding: localBinding)
            $0.peer = nil
            return true
        }
    }

    func streamHistory() -> StreamHistory { state.withLock { StreamHistory(retired: $0.retired) } }

    func invalidate(resetStreamHistory: Bool = false) {
        state.withLock {
            Self.retire(&$0, failure: .staleOwner)
            $0.epoch = nil; $0.peer = nil
            if resetStreamHistory { $0.retired.removeAll() }
        }
    }

    func finish() {
        state.withLock {
            Self.retire(&$0, failure: .staleOwner)
            $0.terminal = true; $0.epoch = nil; $0.peer = nil
        }
    }

    /// Handler removal concerns audio only; it must not cancel the MAIN socket.
    func closeCurrentChannel() { state.withLock { Self.retire(&$0, failure: .closed) } }

    func withdrawChangedPairing(deviceID: String, capabilities: Set<String>) {
        state.withLock {
            if let peer = $0.peer, peer.identity.deviceID != deviceID || peer.capabilities != capabilities {
                Self.retire(&$0, failure: .staleOwner); $0.peer = nil
            }
        }
    }

    /// Call synchronously at the host's successful PairingCommit publication boundary.
    /// A legacy epoch with no proven local binding remains a valid MAIN connection, without audio.
    @discardableResult
    func acceptCommittedPairing(deviceID: String, capabilities: Set<String>, keys: SessionKeys,
                                authority: AuthenticatedRemoteAuthority) throws -> Bool {
        try state.withLock {
            guard !$0.terminal, let epoch = $0.epoch, epoch.matches(keys),
                  epoch.peerBinding.authority == authority else { throw P2PAudioTransportError.staleOwner }
            guard epoch.localBinding != nil else { return false }
            let identity = try AudioProtocolIdentity(deviceID: deviceID, algorithm: authority.protocolSigningAlgorithm,
                                                      fingerprint: authority.protocolPublicKeyFingerprint)
            if let peer = $0.peer, peer.identity == identity, peer.capabilities == capabilities { return true }
            Self.retire(&$0, failure: .staleOwner)
            $0.peer = Peer(identity: identity, capabilities: capabilities)
            return true
        }
    }

    var hasCommittedPeer: Bool { state.withLock { !$0.terminal && $0.peer != nil } }

    /// Only positive capability publications need this witness. An empty
    /// advertisement cannot confer a receiver capability after a later install.
    func capturePublicationAuthorization() -> SendAuthorization {
        let captured = state.withLock { ($0.epoch?.id, $0.peer?.id) }
        return { [state] in
            try state.withLock {
                guard !$0.terminal, $0.epoch?.id == captured.0, $0.peer?.id == captured.1 else {
                    throw P2PAudioTransportError.staleOwner
                }
            }
        }
    }

    var canReceiveFileOverUSB: Bool {
        openUSBFileStream != nil && state.withLock {
            !$0.terminal && $0.peer?.capabilities.contains(AudioStreamingWire.usbFileSendCapability) == true &&
                $0.peer?.capabilities.contains(ClassicTransferApprovalContract.capability) == true
        }
    }

    var canReceiveLogicalFileOverUSB: Bool {
        acquireLogicalFile != nil && logicalFileAvailable() && state.withLock {
            !$0.terminal && $0.peer?.capabilities.contains(AudioStreamingWire.usbStreamFileSendCapability) == true &&
                $0.peer?.capabilities.contains(ClassicTransferApprovalContract.capability) == true
        }
    }

    private struct Registration {
        let epoch: Epoch
        let peer: Peer
        let mailbox: P2PAudioMailbox
        let local: ProtocolIdentityBinding
    }

    func open(requiringRemoteProtocolFingerprint fingerprint: String? = nil) throws -> P2PAudioChannel {
        guard let registration = try register(fingerprint: fingerprint, firstOffer: nil) else {
            throw P2PAudioTransportError.unavailable
        }
        return makeChannel(registration)
    }

    /// Atomically binds the first offer before exposing a new channel to the consumer. If a
    /// handler installation already opened a mailbox, deliver there without creating a second
    /// consumer. A retired offer is ignored and can never create another mailbox.
    func openIncomingOffer(_ message: AudioStreamingMessage, keys: SessionKeys) throws -> P2PAudioChannel? {
        switch message.body {
        case .fileOffer, .captureOffer, .opusOffer, .bufferedOpusFileOffer: break
        default: throw P2PAudioTransportError.offerRequired
        }
        return try register(fingerprint: nil, firstOffer: (message, keys)).map(makeChannel)
    }

    private func register(fingerprint: String?, firstOffer: (AudioStreamingMessage, SessionKeys)?) throws -> Registration? {
        try state.withLock { value in
            guard !value.terminal, let epoch = value.epoch, let peer = value.peer,
                  let local = epoch.localBinding else { throw P2PAudioTransportError.unavailable }
            if let fingerprint, peer.identity.fingerprint != fingerprint { throw P2PAudioTransportError.staleOwner }
            if let firstOffer, !epoch.matches(firstOffer.1) { throw P2PAudioTransportError.staleOwner }
            if let existing = value.mailbox, existing.isTerminal { Self.retire(&value, failure: .closed) }
            if let firstOffer, value.retired.contains(firstOffer.0.streamID) { return nil }
            if let existing = value.mailbox {
                guard let firstOffer else { throw P2PAudioTransportError.alreadyRegistered }
                do { try existing.receive(firstOffer.0) }
                catch { Self.retire(&value, failure: .closed); throw error }
                return nil
            }
            guard value.retired.count < 64 else { throw P2PAudioTransportError.epochCapacity }
            let mailbox = P2PAudioMailbox(); value.mailbox = mailbox
            if let firstOffer {
                do { try mailbox.receive(firstOffer.0) }
                catch { Self.retire(&value, failure: .closed); throw error }
            }
            return Registration(epoch: epoch, peer: peer, mailbox: mailbox, local: local)
        }
    }

    private func makeChannel(_ registration: Registration) -> P2PAudioChannel {
        let epoch = registration.epoch, peer = registration.peer, mailbox = registration.mailbox
        let acceptLogical: (@Sendable () async throws -> any ClassicFileTransferByteChannel)?
        if let acquireLogicalFile, logicalFileAvailable(),
           peer.capabilities.contains(AudioStreamingWire.usbStreamFileSendCapability),
           peer.capabilities.contains(ClassicTransferApprovalContract.capability) {
            acceptLogical = { [weak self] in
                guard let self else { throw P2PAudioTransportError.staleOwner }
                return try await acquireLogicalFile({ [weak self] in
                    guard let self else { throw P2PAudioTransportError.staleOwner }
                    try self.requireCurrent(epoch: epoch, peer: peer, mailbox: mailbox)
                }, {
                    // Epoch/pairing retirement synchronously finishes this exact mailbox.
                    // Native dispatch must not re-enter the carrier/MAIN ownership lock.
                    try mailbox.requireActive()
                })
            }
        } else { acceptLogical = nil }
        let openUSB: (@Sendable (UInt16) async throws -> NWConnection)?
        if let open = openUSBFileStream, peer.capabilities.contains(AudioStreamingWire.usbFileSendCapability),
           peer.capabilities.contains(ClassicTransferApprovalContract.capability) {
            openUSB = { [weak self] port in
                guard let self else { throw P2PAudioTransportError.staleOwner }
                try self.requireCurrent(epoch: epoch, peer: peer, mailbox: mailbox)
                let connection = try await open(port)
                do { try self.requireCurrent(epoch: epoch, peer: peer, mailbox: mailbox); return connection }
                catch { connection.cancel(); throw error }
            }
        } else { openUSB = nil }
        return P2PAudioChannel(mailbox: mailbox, remoteIdentity: peer.identity, localIdentityBinding: registration.local,
            controlTransport: controlTransport,
            peerCapabilities: peer.capabilities,
            validateOwner: { [weak self] in
                guard let self else { throw P2PAudioTransportError.staleOwner }
                try self.requireCurrent(epoch: epoch, peer: peer, mailbox: mailbox)
            }, validateClassicFileTransfer: { [weak self] transferID, material in
                guard let self else { throw P2PAudioTransportError.staleOwner }
                try self.state.withLock { value in
                    try Self.requireCurrent(value, epoch: epoch, peer: peer, mailbox: mailbox)
                    let expected = ClassicTransferKeyMaterial(sessionKeys: epoch.keys, transferId: transferID)
                    guard expected.matches(material) else { throw P2PAudioTransportError.fileTransferMismatch }
                }
            }, prepareBluetooth: { [weak self] in
                guard let self else { throw P2PAudioTransportError.staleOwner }
                return try self.state.withLock { value in
                    try Self.requireCurrent(value, epoch: epoch, peer: peer, mailbox: mailbox)
                    let binding = try mailbox.takeBluetoothBinding()
                    let secret = try AudioBluetoothAttachmentSecret(binding: binding, sendKey: epoch.keys.sendKey,
                        receiveKey: epoch.keys.receiveKey, transcriptHash: epoch.keys.transcriptHash,
                        suite: epoch.keys.negotiatedSuite.wireId)
                    return AudioBluetoothAttachment(binding: binding, secret: secret, requireParentCurrent: { [weak self] in
                        guard let self else { throw P2PAudioTransportError.staleOwner }
                        try self.requireCurrent(epoch: epoch, peer: peer, mailbox: mailbox)
                        try mailbox.requireBluetoothBindingCurrent()
                    })
                }
            }, openUSBFileStream: openUSB, acceptLogicalFileStream: acceptLogical, send: { [weak self] message, effectAuthorization in
                guard let self else { throw P2PAudioTransportError.staleOwner }
                try await self.send(message, epoch: epoch, peer: peer, mailbox: mailbox, effectAuthorization: effectAuthorization)
            }, close: { [weak self] in self?.close(mailbox) })
    }

    /// The actual plaintext demultiplexer used by both MAIN readers. An unavailable consumer
    /// rejects only audio, so handler removal or late offers cannot tear down the MAIN socket;
    /// malformed recognized SBAU is an error and can never fall back to JSON.
    func receiveAuthenticatedPlaintext(_ plaintext: Data, keys: SessionKeys) throws -> ReceiveDisposition {
        guard let message = try AudioStreamingLANEnvelope.decodeIfPresent(plaintext) else { return .nonAudio }
        return try state.withLock { value in
            guard !value.terminal, let epoch = value.epoch, epoch.matches(keys) else { throw P2PAudioTransportError.staleOwner }
            if value.retired.contains(message.streamID) { return .audio }
            guard let peer = value.peer else { return .unavailable }
            guard let mailbox = value.mailbox else {
                switch message.body {
                case .fileOffer, .captureOffer, .opusOffer, .bufferedOpusFileOffer: return .offerNeedsChannel(message)
                default: return .unavailable
                }
            }
            try Self.requireCurrent(value, epoch: epoch, peer: peer, mailbox: mailbox)
            do { try mailbox.receive(message) }
            catch let error as P2PAudioTransportError where error == .queueOverflow || error == .closed {
                Self.retire(&value, failure: error)
            }
            return .audio
        }
    }

    private static func retire(_ value: inout State, failure: P2PAudioTransportError) {
        if let id = value.mailbox?.streamID { value.retired.insert(id) }
        value.mailbox?.finish(failure); value.mailbox = nil
    }

    private static func requireCurrent(_ value: State, epoch: Epoch, peer: Peer, mailbox: P2PAudioMailbox) throws {
        guard !value.terminal, value.epoch?.id == epoch.id, value.peer?.id == peer.id,
              value.mailbox === mailbox else { throw P2PAudioTransportError.staleOwner }
        try mailbox.requireActive()
    }

    private func requireCurrent(epoch: Epoch, peer: Peer, mailbox: P2PAudioMailbox) throws {
        try state.withLock { try Self.requireCurrent($0, epoch: epoch, peer: peer, mailbox: mailbox) }
    }

    private func close(_ mailbox: P2PAudioMailbox) {
        state.withLock {
            mailbox.finish(.closed)
            if $0.mailbox === mailbox { Self.retire(&$0, failure: .closed) }
        }
    }

    private func send(_ message: AudioStreamingMessage, epoch: Epoch, peer: Peer, mailbox: P2PAudioMailbox,
                      effectAuthorization: P2PAudioChannel.EffectAuthorization?) async throws {
        let plaintext = try AudioStreamingLANEnvelope.encode(message)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: epoch.keys.sendKey))
        guard let ciphertext = sealed.combined else { throw AuthenticatedAppPayloadCryptoError.combinedCiphertextUnavailable }
        let padded = try TrafficPadding.wrapForP2PControlFrame(ciphertext, label: "audio")
        let frame = try P2PControlFramePolicy.frame(body: padded)
        let completion = P2PAudioSendCompletion()
        defer { mailbox.finishSend(completion) }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    completion.install(continuation)
                    do {
                        try state.withLock { value in
                            guard completion.isPending else { return }
                            try Self.requireCurrent(value, epoch: epoch, peer: peer, mailbox: mailbox)
                            try effectAuthorization?()
                            guard !value.retired.contains(message.streamID) else { throw P2PAudioTransportError.unexpectedStream }
                            try mailbox.prepareSend(message, peerCapabilities: peer.capabilities, completion: completion)
                            guard completion.markSubmitted() else { return }
                            sendFrame(frame, { [weak self] in
                                guard let self else { throw P2PAudioTransportError.staleOwner }
                                guard completion.isPending else { throw CancellationError() }
                                try self.state.withLock { current in
                                    try Self.requireCurrent(current, epoch: epoch, peer: peer, mailbox: mailbox)
                                    try effectAuthorization?()
                                    guard !current.retired.contains(message.streamID) else {
                                        throw P2PAudioTransportError.unexpectedStream
                                    }
                                }
                            }, completion)
                            completion.startWriteDeadline(cancelTransport: cancelTransport)
                        }
                    } catch { completion.finish(.failure(error)) }
                }
                try state.withLock {
                    try Self.requireCurrent($0, epoch: epoch, peer: peer, mailbox: mailbox)
                    try mailbox.commitSent(message)
                }
            } onCancel: {
                if completion.finish(.failure(CancellationError())) { self.close(mailbox) }
            }
        } catch {
            switch error as? P2PAudioTransportError {
            case .sendInProgress, .unsupportedPeer, .unexpectedStream, .offerRequired: break
            default: close(mailbox)
            }
            throw error
        }
    }
}

/// This exact demultiplexer is called by DiscoveryService's sole initial-inbound read loop.
/// Tests can exercise its real owner admission and JSON preservation without opening a socket.
@available(macOS 14.0, iOS 17.0, *)
enum P2PInboundControlPayload {
    case audio
    case audioUnavailable
    case audioOfferNeedsChannel(AudioStreamingMessage)
    case appMessage(AppMessage)

    static func decode(_ plaintext: Data, keys: SessionKeys, audioCarrier: P2PAudioCarrier) throws -> Self {
        switch try audioCarrier.receiveAuthenticatedPlaintext(plaintext, keys: keys) {
        case .audio: return .audio
        case .unavailable: return .audioUnavailable
        case .offerNeedsChannel(let message): return .audioOfferNeedsChannel(message)
        case .nonAudio: return .appMessage(try AppMessage.decodeWireMessage(from: plaintext))
        }
    }
}

/// One installation owner for receive channels on either connection direction.
/// Removal closes the exact delivered channels, including queued callbacks whose
/// connections are not yet published, and never closes another channel or MAIN.
@MainActor
@available(macOS 14.0, iOS 17.0, *)
final class P2PAudioIncomingChannelRegistry {
    enum OriginalFileSupport: Equatable, Sendable {
        case unavailable, wave, waveAndFlac, waveFlacAndAlac
        var flac: Bool { self == .waveAndFlac || self == .waveFlacAndAlac }
        var alac: Bool { self == .waveFlacAndAlac }
    }
    static let maximumDeliveredChannels = 8
    private final class WeakChannel {
        weak var value: P2PAudioChannel?
        init(_ value: P2PAudioChannel) { self.value = value }
    }
    private var handler: (id: UUID, captureReady: Bool, fileSupport: OriginalFileSupport, bluetoothReady: Bool,
                          fileOutputProgressReady: Bool, receive: @Sendable (P2PAudioChannel) -> Void)?
    private var delivered: [UUID: WeakChannel] = [:]
    private let publicationGeneration = OSAllocatedUnfairLock(initialState: UUID())

    func capturePublicationAuthorization() -> @Sendable () throws -> Void {
        let generation = publicationGeneration
        let captured = generation.withLock { $0 }
        return {
            guard generation.withLock({ $0 == captured }) else { throw P2PAudioTransportError.staleOwner }
        }
    }

    var advertisedReceiveCapabilities: [String] {
        receiveCapabilities(originalFileRouteReady: true)
    }

    /// The running consumer and the actual carrier must both support files.
    /// A USB MAIN stream alone does not provide the separate classic file route.
    func receiveCapabilities(originalFileRouteReady: Bool, usbFileReturnReady: Bool = false,
                             usbLogicalFileReady: Bool = false) -> [String] {
        guard let handler else { return [] }
        var capabilities: [String] = []
        if handler.captureReady { capabilities.append(AudioStreamingWire.captureReceiveCapability) }
        if originalFileRouteReady, handler.fileSupport != .unavailable { capabilities.append(AudioStreamingWire.fileReceiveCapability) }
        if originalFileRouteReady, handler.fileSupport.flac { capabilities.append(AudioStreamingWire.flacFileReceiveCapability) }
        if originalFileRouteReady, handler.fileSupport.alac { capabilities.append(AudioStreamingWire.alacFileReceiveCapability) }
        if originalFileRouteReady, handler.fileSupport != .unavailable, handler.fileOutputProgressReady {
            capabilities.append(AudioStreamingWire.fileOutputProgressReportCapability)
        }
        if originalFileRouteReady, usbFileReturnReady, handler.fileSupport != .unavailable {
            capabilities.append(AudioStreamingWire.usbFileReceiveCapability)
        }
        if originalFileRouteReady, usbLogicalFileReady, handler.fileSupport != .unavailable {
            capabilities.append(AudioStreamingWire.usbStreamFileReceiveCapability)
        }
        if handler.bluetoothReady {
            capabilities += [AudioStreamingWire.opusReceiveCapability, AudioStreamingWire.bluetoothAttachmentCapability,
                             AudioStreamingWire.bufferedOpusFileReceiveCapability]
        }
        return capabilities
    }

    func install(advertiseCapture: Bool = false, originalFileSupport: OriginalFileSupport = .unavailable,
                 advertiseBluetoothOpus: Bool = false,
                 advertiseFileOutputProgress: Bool = false,
                 _ receive: @escaping @Sendable (P2PAudioChannel) -> Void) throws -> UUID {
        guard handler == nil else { throw P2PAudioTransportError.alreadyRegistered }
        let id = UUID()
        publicationGeneration.withLock { $0 = id }
        handler = (id, advertiseCapture, originalFileSupport, advertiseBluetoothOpus, advertiseFileOutputProgress, receive)
        return id
    }

    func remove(ifOwnedBy id: UUID) {
        guard handler?.id == id else { return }
        publicationGeneration.withLock { $0 = UUID() }
        handler = nil
        let owned = delivered.values.compactMap(\.value)
        delivered.removeAll()
        for channel in owned { channel.close() }
    }

    /// One delivery attempt per incoming offer. The handler check happens before any
    /// registration, so an absent consumer cannot accidentally admit an audio stream.
    @discardableResult
    func deliverIncomingOffer(_ message: AudioStreamingMessage, keys: SessionKeys, carrier: P2PAudioCarrier,
                              originalFileRouteReady: Bool = true) throws -> Bool {
        guard let handler, carrier.hasCommittedPeer else { return false }
        if case .fileOffer = message.body, !originalFileRouteReady { return false }
        if message.body.opusOfferParameters != nil, !handler.bluetoothReady { return false }
        if let channel = try carrier.openIncomingOffer(message, keys: keys) {
            try deliver(channel, to: handler.receive)
        }
        return true
    }

    @discardableResult
    func deliver(_ carrier: P2PAudioCarrier) throws -> Bool {
        guard let handler, carrier.hasCommittedPeer else { return false }
        try deliver(carrier.open(), to: handler.receive)
        return true
    }

    private func deliver(_ channel: P2PAudioChannel, to receive: @Sendable (P2PAudioChannel) -> Void) throws {
        delivered = delivered.filter { $0.value.value != nil }
        guard delivered.count < Self.maximumDeliveredChannels else {
            channel.close()
            throw P2PAudioTransportError.queueOverflow
        }
        // Record before invoking the callback: immediate removal/reentrancy must
        // still retire this exact channel. The registry does not retain consumers.
        delivered[channel.ownerID] = WeakChannel(channel)
        receive(channel)
    }
}
