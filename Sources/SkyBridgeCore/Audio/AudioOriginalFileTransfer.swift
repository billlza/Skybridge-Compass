#if os(macOS)
import Foundation
import os
import SkyBridgeProtocolCore

enum AudioOriginalFileTransferError: Error, Equatable, Sendable {
    case unavailable, invalidPermission, metadataMismatch, alreadyClaimed, alreadyWaiting, cancelled
}

/// One private, verified file artifact. The receiver retains the IO handle after its private
/// durable commit; neither a history URL nor a filename can construct this ownership.
actor AudioOriginalFileArtifact {
    private var reader: PreparedOutboundFileReadSession?
    private let io: InboundFileTransferIOActor
    private let handle: InboundFileTransferIOHandle
    private var readerReleased = false
    private var fileReleased = false
    private var diagnostics: [String] = []
    private var closing: Task<AudioOutputCleanupOutcome, Never>?

    init(io: InboundFileTransferIOActor, handle: InboundFileTransferIOHandle) {
        self.io = io; self.handle = handle
    }

    func installReader(_ reader: PreparedOutboundFileReadSession) throws {
        guard self.reader == nil, !readerReleased, !fileReleased else {
            throw AudioOriginalFileTransferError.unavailable
        }
        self.reader = reader
    }

    func verifiedReader() throws -> PreparedOutboundFileReadSession {
        guard let reader, !readerReleased else { throw AudioOriginalFileTransferError.unavailable }
        return reader
    }

    func close() async -> AudioOutputCleanupOutcome {
        if let closing { return await closing.value }
        let task = Task { await self.closeResources() }
        closing = task
        let outcome = await task.value
        closing = nil
        return outcome
    }

    private func closeResources() async -> AudioOutputCleanupOutcome {
        // Keep the verified descriptor pinned until identity-bound unlink completes. A cleanup
        // retry must not rely on an inode number that was freed by closing our last reference.
        if !fileReleased {
            do { try await io.discard(handle); fileReleased = true }
            catch { recordDiagnostic("file_artifact_cleanup:" + String(reflecting: type(of: error))) }
        }
        if fileReleased, !readerReleased {
            do { try await reader?.close(); readerReleased = true }
            catch { recordDiagnostic("file_reader_close:" + String(reflecting: type(of: error))) }
        }
        return .init(state: readerReleased && fileReleased ? .released : .pending,
                     diagnostics: diagnostics, preservedExternalChanges: [])
    }

    private func recordDiagnostic(_ value: String) {
        if !diagnostics.contains(value) { diagnostics.append(value) }
    }
}

/// A local playback grant awaiting exactly one authenticated classic transfer. Permission and
/// account lifetime are checked independently of content hashes and transport receipts.
actor AudioOriginalFileTransfer {
    nonisolated let ownerID: UUID
    nonisolated let transferID: UUID
    nonisolated let expectedLength: UInt64
    nonisolated let expectedSHA256: Data
    private nonisolated let channel: P2PAudioChannel
    nonisolated var requiresDedicatedFileStream: Bool { channel.usesUSBFileReturn || channel.usesLogicalFileStream }
    private nonisolated let membership: AudioMembershipLease
    private nonisolated let permission: AudioPlaybackPermission
    private nonisolated let source: AudioPlaybackSource
    private nonisolated let streamID: UUID
    private nonisolated let endpoint: String
    private let receiveCleanupTimeout: Duration
    private nonisolated let revoked = OSAllocatedUnfairLock(initialState: false)
    private var claimed = false
    private var waited = false
    private var receiveCancellation: (@Sendable () -> Void)?
    private var waiter: CheckedContinuation<AudioOriginalFileArtifact, Error>?
    private var artifact: AudioOriginalFileArtifact?
    private var delivered = false
    private var receiveActive = false
    private var receiveDrain: CheckedContinuation<Bool, Never>?
    private var receiveDrainTimer: Task<Void, Never>?
    private var receiveDrainDiagnostic = "file_receive_cancel_pending"
    private var closing: Task<AudioOutputCleanupOutcome, Never>?
    private var failure: Error?

    init(channel: P2PAudioChannel, offer: AudioStreamingMessage, membership: AudioMembershipLease,
         permission: AudioPlaybackPermission, endpoint: String,
         receiveCleanupTimeout: Duration = .seconds(5)) throws {
        let source = try AudioPlaybackSource(offer: offer)
        guard case let .originalFile(id, length, digest) = source,
              membership.ownerID == channel.ownerID,
              membership.evidence.peerIdentity == channel.remoteIdentity,
              membership.evidence.localIdentity == (try AudioProtocolIdentity(channel.localIdentityBindingForAccountRequest())),
              permission.request.membershipID == membership.evidence.id,
              receiveCleanupTimeout > .zero, receiveCleanupTimeout <= .seconds(30) else {
            throw AudioOriginalFileTransferError.invalidPermission
        }
        self.channel = channel; self.membership = membership; self.permission = permission
        self.endpoint = endpoint; self.source = source; streamID = offer.streamID
        self.receiveCleanupTimeout = receiveCleanupTimeout
        ownerID = channel.ownerID; transferID = id; expectedLength = length; expectedSHA256 = digest
        try requireAuthorization()
    }

    nonisolated func requireAuthorization() throws {
        try Task.checkCancellation()
        guard !revoked.withLock({ $0 }) else { throw AudioOriginalFileTransferError.cancelled }
        try channel.requireCurrent()
        guard membership.isCurrent else { throw AudioMembershipLeaseFailure.revoked }
        guard permission.approves(ownerID: ownerID, streamID: streamID, source: source,
                                  outputEndpointUID: endpoint) else { throw AudioPlaybackApprovalError.rejected }
    }

    /// The file carrier independently validates the captured MAIN owner. This predicate is
    /// bounded and does not re-enter that peer/channel lock at native dispatch.
    nonisolated func requireWriteAuthorization() throws {
        guard !revoked.withLock({ $0 }) else { throw AudioOriginalFileTransferError.cancelled }
        try membership.requireEffectCurrent()
        guard permission.approves(ownerID: ownerID, streamID: streamID, source: source,
                                  outputEndpointUID: endpoint) else { throw AudioPlaybackApprovalError.rejected }
    }

    func claim(rawTransferID: String, length: Int64, sha256: String, peerID: String?,
               material: ClassicTransferKeyMaterial, cancelReceive: @escaping @Sendable () -> Void) throws {
        try requireAuthorization()
        guard let peerID, UUID(uuidString: rawTransferID) == transferID, length >= 0,
              UInt64(length) == expectedLength,
              sha256.lowercased() == expectedSHA256.map({ String(format: "%02x", $0) }).joined(),
              peerID == channel.remoteIdentity.deviceID else { throw AudioOriginalFileTransferError.metadataMismatch }
        try channel.requireClassicFileTransfer(transferID: rawTransferID, material: material)
        guard !claimed else { throw AudioOriginalFileTransferError.alreadyClaimed }
        claimed = true; receiveActive = true; receiveCancellation = cancelReceive
    }

    /// Retained before the first post-creation await can fail. Close waits for the producer's
    /// terminal acknowledgement before attempting these same resources, including partial files.
    func retainForCleanup(_ artifact: AudioOriginalFileArtifact) throws {
        guard claimed, self.artifact == nil else { throw AudioOriginalFileTransferError.alreadyClaimed }
        self.artifact = artifact
    }

    func endReceive() {
        receiveActive = false; receiveCancellation = nil
        receiveDrainTimer?.cancel(); receiveDrainTimer = nil
        receiveDrain?.resume(returning: true); receiveDrain = nil
    }

    func setReceiveCancellation(_ cancelReceive: @escaping @Sendable () -> Void) {
        if revoked.withLock({ $0 }) || !receiveActive { cancelReceive() }
        else { receiveCancellation = cancelReceive }
    }

    var hasClaimedTransfer: Bool { claimed }

    /// Only verified content may wake the consumer. Resource ownership was retained earlier,
    /// so cancellation or a failed delivery still has an exact cleanup owner.
    func deliver(_ artifact: AudioOriginalFileArtifact) async throws {
        let reader = try await artifact.verifiedReader()
        try requireAuthorization()
        guard claimed, self.artifact === artifact, !delivered, failure == nil,
              reader.metadata.fileSize >= 0,
              UInt64(reader.metadata.fileSize) == expectedLength,
              reader.metadata.contentSHA256 == expectedSHA256 else {
            throw AudioOriginalFileTransferError.metadataMismatch
        }
        delivered = true
        waiter?.resume(returning: artifact); waiter = nil
    }

    func waitForArtifact() async throws -> AudioOriginalFileArtifact {
        // fail() also revokes the grant. A consumer arriving after the producer failed must
        // retain that first cause just like an already-suspended waiter; no artifact is returned.
        if let failure { throw failure }
        try requireAuthorization()
        guard !waited else { throw AudioOriginalFileTransferError.alreadyWaiting }
        waited = true
        if delivered, let artifact { return artifact }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiter = continuation }
            }
        } onCancel: { Task { await self.cancel() } }
    }

    func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error; revoked.withLock { $0 = true }
        receiveCancellation?(); receiveCancellation = nil
        waiter?.resume(throwing: error); waiter = nil
    }

    func cancel() { fail(AudioOriginalFileTransferError.cancelled) }

    func close() async -> AudioOutputCleanupOutcome {
        if let closing { return await closing.value }
        let task = Task { await self.closeReceivedResources() }
        closing = task
        let result = await task.value
        closing = nil
        return result
    }

    private func closeReceivedResources() async -> AudioOutputCleanupOutcome {
        cancel()
        if receiveActive, !(await waitForReceiveToEnd()) {
            return .init(state: .pending, diagnostics: [receiveDrainDiagnostic], preservedExternalChanges: [])
        }
        guard let artifact else { return .noOutput }
        return await artifact.close()
    }

    /// Cancellation cannot forcibly interrupt every scanner/system call. A bounded close reports
    /// pending and retains the producer/registry/resources; only its actual end permits cleanup.
    private func waitForReceiveToEnd() async -> Bool {
        guard receiveActive else { return true }
        let timeout = receiveCleanupTimeout
        return await withCheckedContinuation { continuation in
            receiveDrain = continuation
            receiveDrainTimer = Task { [weak self, timeout] in
                do { try await Task.sleep(for: timeout) }
                catch is CancellationError { return }
                catch {
                    await self?.expireReceiveDrain(diagnostic: "file_receive_wait_failed:" + String(reflecting: type(of: error)))
                    return
                }
                await self?.expireReceiveDrain(diagnostic: "file_receive_cancel_pending")
            }
        }
    }

    private func expireReceiveDrain(diagnostic: String) {
        receiveDrainDiagnostic = diagnostic; receiveDrainTimer = nil
        receiveDrain?.resume(returning: false); receiveDrain = nil
    }
}

/// One Mac playback consumer owns admission. The file listener may only claim an already
/// approved offer, after its own metadata MAC validation; missing registrations grant nothing.
@MainActor
final class AudioOriginalFileTransferRegistry {
    static let shared = AudioOriginalFileTransferRegistry()
    private var current: AudioOriginalFileTransfer?

    func register(_ transfer: AudioOriginalFileTransfer) throws {
        guard current == nil else { throw AudioPlaybackApprovalError.busy }
        try transfer.requireAuthorization()
        current = transfer
    }

    func remove(ownerID: UUID) {
        guard current?.ownerID == ownerID else { return }
        current = nil
    }

    func claimIfOffered(rawTransferID: String, length: Int64, sha256: String, peerID: String?,
                        material: ClassicTransferKeyMaterial,
                        requiring expected: AudioOriginalFileTransfer? = nil,
                        cancelReceive: @escaping @Sendable () -> Void) async throws -> AudioOriginalFileTransfer? {
        // A dedicated return stream must not select a replacement grant or fall
        // through to ordinary file reception, even when its UUID is reused.
        if let expected {
            guard current === expected else { throw AudioOriginalFileTransferError.unavailable }
            guard UUID(uuidString: rawTransferID) == expected.transferID else {
                throw AudioOriginalFileTransferError.metadataMismatch
            }
        }
        guard let current, UUID(uuidString: rawTransferID) == current.transferID else { return nil }
        guard !current.requiresDedicatedFileStream || expected != nil else {
            throw AudioOriginalFileTransferError.metadataMismatch
        }
        try await current.claim(rawTransferID: rawTransferID, length: length, sha256: sha256,
            peerID: peerID, material: material, cancelReceive: cancelReceive)
        // Claim can suspend. A retired registry must never hand its owner to a new receive.
        guard self.current === current else {
            await current.cancel(); await current.endReceive()
            throw AudioOriginalFileTransferError.cancelled
        }
        return current
    }
}
#endif
