import Combine
import Foundation
import os
import SkyBridgeProtocolCore

public enum AudioPlaybackApprovalError: Error, Equatable, Sendable {
    case invalidRequest, busy, rejected, timedOut, ownerReplaced
}

public struct AudioPlaybackApprovalRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let ownerID: UUID
    public let streamID: UUID
    public let membershipID: UUID
    public let sender: AudioProtocolIdentity
    public let source: AudioPlaybackSource
    public let outputEndpointUID: String

    public init(ownerID: UUID, offer: AudioStreamingMessage, membership: AudioAccountMembership,
                outputEndpointUID: String) throws {
        guard ownerID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
              !outputEndpointUID.isEmpty, outputEndpointUID.utf8.count <= 4096 else {
            throw AudioPlaybackApprovalError.invalidRequest
        }
        id = UUID(); self.ownerID = ownerID; streamID = offer.streamID
        membershipID = membership.id; sender = membership.peerIdentity
        source = try AudioPlaybackSource(offer: offer)
        self.outputEndpointUID = outputEndpointUID
    }
}

/// Local, one-stream receiver permission. This is deliberately named approval,
/// not authorization: the effect gate must also require a live account evidence
/// lease and the exact authenticated connection owner. No source/output mutation
/// may reuse this permission. Revocation is safe from native control workers.
public final class AudioPlaybackPermission: Sendable {
    public let request: AudioPlaybackApprovalRequest
    private let revoked = OSAllocatedUnfairLock(initialState: false)
    fileprivate init(request: AudioPlaybackApprovalRequest) { self.request = request }
    public var isApproved: Bool { revoked.withLock { !$0 } }
    public func revoke() { revoked.withLock { $0 = true } }
    public func approves(ownerID: UUID, streamID: UUID, source: AudioPlaybackSource,
                         outputEndpointUID: String) -> Bool {
        request.ownerID == ownerID && request.streamID == streamID && request.source == source
            && request.outputEndpointUID == outputEndpointUID && isApproved
    }
}

/// One bounded prompt. No trust-list or general file-transfer permission can
/// answer it. UI passes back the exact displayed request; stale taps cannot
/// approve a replacement prompt. The caller owns active permission revocation.
@MainActor
public final class AudioPlaybackApprovalService: ObservableObject {
    @Published public private(set) var pendingRequest: AudioPlaybackApprovalRequest?
    private struct Waiter {
        let request: AudioPlaybackApprovalRequest
        let continuation: CheckedContinuation<AudioPlaybackPermission, Error>
        let current: @MainActor () -> Bool
        let deadline: ContinuousClock.Instant
        let timeout: Task<Void, Never>
    }
    private var waiter: Waiter?
    private let decisionTimeout: Duration

    public init(decisionTimeout: Duration = .seconds(60)) throws {
        guard decisionTimeout > .zero, decisionTimeout <= .seconds(60) else {
            throw AudioPlaybackApprovalError.invalidRequest
        }
        self.decisionTimeout = decisionTimeout
    }

    public func requestApproval(
        _ request: AudioPlaybackApprovalRequest,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> AudioPlaybackPermission {
        try Task.checkCancellation()
        guard waiter == nil else { throw AudioPlaybackApprovalError.busy }
        guard isCurrent() else { throw AudioPlaybackApprovalError.ownerReplaced }
        let permission: AudioPlaybackPermission = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AudioPlaybackPermission, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError()); return
                }
                let deadline = ContinuousClock.now.advanced(by: decisionTimeout)
                let timeout = Task<Void, Never> { @MainActor [weak self] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) }
                    catch is CancellationError { return }
                    catch { self?.finish(requestID: request.id, result: .failure(error)); return }
                    self?.finish(requestID: request.id, result: .failure(AudioPlaybackApprovalError.timedOut))
                }
                waiter = Waiter(request: request, continuation: continuation, current: isCurrent,
                                deadline: deadline, timeout: timeout)
                // Install ownership before publishing; an immediate UI response
                // must not be lost or stored in an unbounded early-response map.
                pendingRequest = request
                // @Published emits from willSet. A synchronous subscriber may
                // resolve before the outer assignment completes; do not leave
                // its finished prompt visible after that reentrant assignment.
                if waiter?.request.id != request.id, pendingRequest?.id == request.id {
                    pendingRequest = nil
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.finish(requestID: request.id, result: .failure(CancellationError()))
            }
        }
        do {
            try Task.checkCancellation()
            guard isCurrent() else { throw AudioPlaybackApprovalError.ownerReplaced }
            return permission
        } catch {
            permission.revoke()
            throw error
        }
    }

    @discardableResult
    public func resolve(_ request: AudioPlaybackApprovalRequest, allowOnce: Bool) -> Bool {
        guard let waiter, waiter.request == request else { return false }
        if ContinuousClock.now >= waiter.deadline {
            finish(requestID: request.id, result: .failure(AudioPlaybackApprovalError.timedOut))
        } else if !waiter.current() {
            finish(requestID: request.id, result: .failure(AudioPlaybackApprovalError.ownerReplaced))
        } else if allowOnce {
            finish(requestID: request.id, result: .success(AudioPlaybackPermission(request: request)))
        } else {
            finish(requestID: request.id, result: .failure(AudioPlaybackApprovalError.rejected))
        }
        return true
    }

    public func cancel(ownerID: UUID) {
        guard let waiter, waiter.request.ownerID == ownerID else { return }
        finish(requestID: waiter.request.id, result: .failure(AudioPlaybackApprovalError.ownerReplaced))
    }

    public func dismiss() {
        guard let waiter else { return }
        finish(requestID: waiter.request.id, result: .failure(AudioPlaybackApprovalError.rejected))
    }

    private func finish(requestID: UUID, result: Result<AudioPlaybackPermission, Error>) {
        guard let current = waiter, current.request.id == requestID else { return }
        waiter = nil
        pendingRequest = nil
        current.timeout.cancel()
        current.continuation.resume(with: result)
    }
}
