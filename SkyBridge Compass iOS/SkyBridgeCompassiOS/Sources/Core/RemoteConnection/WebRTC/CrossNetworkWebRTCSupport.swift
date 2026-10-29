import Foundation

extension Notification.Name {
    static let crossNetworkScreenDataUpdated = Notification.Name("CrossNetworkScreenDataUpdated")
}

enum CrossNetworkNotificationUserInfoKey {
    static let sessionId = "sessionId"
    static let screenData = "screenData"
}

enum CrossNetworkWebRTCHandshakeLimits {
    /// Legacy padding target: a small handshake plus the 4-byte stream prefix
    /// fits one 8 KiB DataChannel message. A larger bounded ML-DSA-87 frame is
    /// not truncated; `sendFramedPayloadAsync` fragments it below.
    static let maxPaddedPayloadBytes = (8 * 1024) - 4
    /// Per-message control-channel limit. Both peers stream-reassemble the
    /// 4-byte length-prefixed payload, including a 16 KiB-bounded MessageA.
    static let maxControlFrameChunkBytes = maxPaddedPayloadBytes + 4
    static let maxBufferedAmountBytes: UInt64 = 256 * 1024
    static let strictPQCClassicBootstrapTimeoutSeconds: TimeInterval = 30.0
    static let strictPQCClassicBootstrapMaxGraceSeconds: TimeInterval = 120.0
}

@available(iOS 17.0, *)
struct CurrentPathWebRTCHandshakeTransportCompat: DiscoveryTransport {
    let sendFramed: @Sendable (Data) async throws -> Void

    func send(to peer: PeerIdentifier, data: Data) async throws {
        try await sendFramed(data)
    }
}

enum SignalingSessionHealth: String, Sendable, Equatable {
    case healthy
    case degradedRecoverable = "degraded_recoverable"
    case degradedFatal = "degraded_fatal"
}


@MainActor
final class CrossNetworkWebRTCLifecycleGate {
    struct TeardownLease: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    enum WaitError: Error, Equatable, Sendable {
        case waiterCapacityExceeded(limit: Int)
    }

    private enum WaitResolution: Sendable {
        case generationFinished
        case cancelled
        case failed(WaitError)
    }

    private let maxWaiters: Int
    private var lastGeneration: UInt64 = 0
    private var activeLease: TeardownLease?
    private var teardownCompletionWaiters: [
        UUID: CheckedContinuation<WaitResolution, Never>
    ] = [:]

    init(maxWaiters: Int = 64) {
        precondition(maxWaiters > 0, "lifecycle waiter capacity must be positive")
        self.maxWaiters = maxWaiters
    }

    var isTeardownInProgress: Bool {
        activeLease != nil
    }

    var registeredWaiterCount: Int {
        teardownCompletionWaiters.count
    }

    func beginTeardown() -> TeardownLease? {
        guard activeLease == nil else { return nil }
        let increment = lastGeneration.addingReportingOverflow(1)
        precondition(!increment.overflow, "lifecycle teardown generation exhausted")
        lastGeneration = increment.partialValue
        let lease = TeardownLease(generation: lastGeneration)
        activeLease = lease
        return lease
    }

    func waitForTeardownCompletion() async throws {
        while true {
            try Task.checkCancellation()
            guard let activeLease else { return }

            switch await waitForGenerationChange(activeLease.generation) {
            case .generationFinished:
                continue
            case .cancelled:
                throw CancellationError()
            case .failed(let error):
                throw error
            }
        }
    }

    func finishTeardown(_ lease: TeardownLease) {
        precondition(activeLease == lease, "only the active teardown lease may finish")
        activeLease = nil
        let waiters = Array(teardownCompletionWaiters.values)
        teardownCompletionWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: .generationFinished)
        }
    }

    private func waitForGenerationChange(_ expectedGeneration: UInt64) async -> WaitResolution {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                guard activeLease?.generation == expectedGeneration else {
                    continuation.resume(returning: .generationFinished)
                    return
                }
                guard teardownCompletionWaiters.count < maxWaiters else {
                    continuation.resume(
                        returning: .failed(.waiterCapacityExceeded(limit: maxWaiters))
                    )
                    return
                }
                teardownCompletionWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelWaiter(waiterID)
            }
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        teardownCompletionWaiters.removeValue(forKey: waiterID)?
            .resume(returning: .cancelled)
    }
}
