import Foundation
import Network
import SkyBridgeProtocolCore

typealias P2PAudioTransportError = AudioStreamingChannelError
typealias P2PAudioMailbox = AudioStreamingMailbox
typealias P2PAudioSendCompletion = AudioStreamingSendCompletion
typealias P2PAudioMessages = AudioStreamingMessages

/// One bounded stream on an authenticated connection. This carries messages only:
/// account membership, receive permission, window/offset validation and output
/// admission remain the audio consumer's responsibility.
final class P2PAudioChannel: Sendable {
    let ownerID: UUID
    let remoteIdentity: AudioProtocolIdentity
    /// Captured from this authenticated carrier, never from device discovery or
    /// a later connection to the same peer. This describes control, not Bluetooth media.
    let controlTransport: P2PConnection.ControlTransport
    /// Snapshot from this exact authenticated peer incarnation, retired with its owner.
    let peerCapabilities: Set<String>
    let messages: P2PAudioMessages
    typealias EffectAuthorization = @Sendable () throws -> Void
    private let sendOperation: @Sendable (AudioStreamingMessage, EffectAuthorization?) async throws -> Void
    private let closeOperation: @Sendable () -> Void
    private let localIdentityBinding: ProtocolIdentityBinding
    private let validateOwner: @Sendable () throws -> Void
    private let validateClassicFileTransfer: (@Sendable (String, ClassicTransferKeyMaterial) throws -> Void)?
    private let prepareBluetooth: (@Sendable () throws -> AudioBluetoothAttachment)?
    private let openUSBFileStream: (@Sendable (UInt16) async throws -> NWConnection)?
    var usesUSBFileReturn: Bool { openUSBFileStream != nil }
    private let acceptLogicalFileStream: (@Sendable () async throws -> any ClassicFileTransferByteChannel)?
    var usesLogicalFileStream: Bool { acceptLogicalFileStream != nil }
    private let mailbox: P2PAudioMailbox

    init(mailbox: P2PAudioMailbox, remoteIdentity: AudioProtocolIdentity,
         localIdentityBinding: ProtocolIdentityBinding,
         controlTransport: P2PConnection.ControlTransport,
         peerCapabilities: Set<String> = [],
         validateOwner: @escaping @Sendable () throws -> Void,
         validateClassicFileTransfer: (@Sendable (String, ClassicTransferKeyMaterial) throws -> Void)? = nil,
         prepareBluetooth: (@Sendable () throws -> AudioBluetoothAttachment)? = nil,
         openUSBFileStream: (@Sendable (UInt16) async throws -> NWConnection)? = nil,
         acceptLogicalFileStream: (@Sendable () async throws -> any ClassicFileTransferByteChannel)? = nil,
         send: @escaping @Sendable (AudioStreamingMessage, EffectAuthorization?) async throws -> Void,
         close: @escaping @Sendable () -> Void) {
        ownerID = mailbox.id
        self.remoteIdentity = remoteIdentity
        self.controlTransport = controlTransport
        self.peerCapabilities = peerCapabilities
        self.localIdentityBinding = localIdentityBinding
        self.validateOwner = validateOwner
        self.validateClassicFileTransfer = validateClassicFileTransfer
        self.prepareBluetooth = prepareBluetooth
        self.openUSBFileStream = openUSBFileStream
        self.acceptLogicalFileStream = acceptLogicalFileStream
        self.mailbox = mailbox
        messages = P2PAudioMessages(mailbox: mailbox, validateOwner: validateOwner)
        sendOperation = send
        closeOperation = close
    }

    /// Only this exact Finished-verified epoch may authorize the caller identity in a fresh
    /// account GET. The request owner must recheck requireCurrent() after every await.
    func localIdentityBindingForAccountRequest() throws -> ProtocolIdentityBinding {
        try requireCurrent()
        return localIdentityBinding
    }

    func requireCurrent() throws {
        try mailbox.requireActive()
        try validateOwner()
    }

    func openOriginalFileReturnStream(port: UInt16, authorize: EffectAuthorization) async throws -> NWConnection {
        guard port > 0, let openUSBFileStream else { throw P2PAudioTransportError.unavailable }
        try requireCurrent(); try authorize()
        let connection = try await openUSBFileStream(port)
        do { try requireCurrent(); try authorize(); return connection }
        catch { connection.cancel(); throw error }
    }

    /// The receiver retains the acquired byte owner before checking authorization again,
    /// including when cleanup must be retried. Acquisition alone is never a playback grant.
    func acceptOriginalFileStream() async throws -> any ClassicFileTransferByteChannel {
        try requireCurrent()
        guard let acceptLogicalFileStream else { throw P2PAudioTransportError.unavailable }
        return try await acceptLogicalFileStream()
    }

    /// One preparation credential from the exact completed Opus/route exchange. No account,
    /// playback permission, media transport, or independent lifetime is granted by this handle.
    func prepareBluetoothAttachment() throws -> AudioBluetoothAttachment {
        try requireCurrent()
        guard let prepareBluetooth else { throw P2PAudioTransportError.unavailable }
        let attachment = try prepareBluetooth()
        try requireCurrent()
        return attachment
    }

    /// Bind a separately authenticated classic file transfer to this exact MAIN owner.
    /// `transferID` is the authenticated metadata spelling: its UTF-8 bytes are KDF input,
    /// so UUID equality must never be implemented by normalizing this string first.
    /// This proves session authority only; the consumer must also match the offer's UUID,
    /// length and digest and recheck its account lease and one-stream permission.
    func requireClassicFileTransfer(transferID: String, material: ClassicTransferKeyMaterial) throws {
        try requireCurrent()
        guard let validateClassicFileTransfer else { throw P2PAudioTransportError.unavailable }
        guard let id = UUID(uuidString: transferID), id != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            throw P2PAudioTransportError.fileTransferMismatch
        }
        try validateClassicFileTransfer(transferID, material)
        try requireCurrent()
    }

    func send(_ message: AudioStreamingMessage) async throws {
        try Task.checkCancellation()
        try await sendOperation(message, nil)
    }

    /// Rechecked inside the carrier's exact owner lock, before native submission.
    /// Must be bounded and non-reentrant: no channel calls or account storage/actor access.
    func send(_ message: AudioStreamingMessage, requireEffectAuthorization: @escaping EffectAuthorization) async throws {
        try Task.checkCancellation()
        try await sendOperation(message, requireEffectAuthorization)
    }

    func close() { closeOperation() }
    deinit { closeOperation() }
}

