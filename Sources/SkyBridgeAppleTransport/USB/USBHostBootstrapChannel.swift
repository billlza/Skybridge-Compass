#if os(macOS)
import Foundation
import os
import SkyBridgeProtocolCore

public enum USBHostBootstrapError: Error, Equatable, Sendable {
    case invalidConfiguration, exchangeInProgress, retired, trailingResponseBytes
}
public struct USBHostBootstrapCleanupFailure: Error, Sendable {
    public let primary: (any Error)?
    public let cleanup: any Error
}

/// Sequential MAIN bootstrap exchanges on one externally owned physical USB
/// generation. Each request gets a fresh logical stream. No socket endpoint,
/// identity, account grant or fallback is inferred from an attachment nonce.
public final class USBHostBootstrapChannel: Sendable {
    public struct Response: Sendable {
        public let body: Data
        public let streamID: UInt32
        public let openingDuration: Duration
    }
    public let attachmentNonce: UUID
    private let connection: USBHostMultiplexConnection
    private let requireCurrent: @Sendable () throws -> Void
    private struct State: Sendable {
        var active = false
        var retired = false
        var cleaning = false
        var retained: USBHostMultiplexConnection.Stream?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(connection: USBHostMultiplexConnection, attachmentNonce: UUID,
                requireAttachmentCurrent: @escaping @Sendable () throws -> Void) throws {
        guard attachmentNonce != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            throw USBHostBootstrapError.invalidConfiguration
        }
        self.connection = connection; self.attachmentNonce = attachmentNonce; requireCurrent = requireAttachmentCurrent
    }

    public var cleanupRequired: Bool { state.withLock { $0.retained != nil } }
    public func checkCurrent() throws {
        try Task.checkCancellation()
        guard !state.withLock({ $0.retired }) else { throw USBHostBootstrapError.retired }
        if let failure = connection.terminalFailure { throw failure }
        try requireCurrent()
    }

    /// One whole deadline includes stream ACK, write, response and graceful FIN.
    /// The requester's half remains open while the responder obtains consent.
    /// After one complete response, finish our half and require peer EOF before
    /// releasing the stream; RST must not discard the response before it is read.
    public func exchange(_ request: Data, timeout: Duration) async throws -> Response {
        guard !request.isEmpty && request.count <= 64 * 1024 else { throw USBHostControlFrameError.invalidFrame }
        let budget = try USBMultiplexBudget(timeout)
        try state.withLock { value in
            guard !value.retired && value.retained == nil else { throw USBHostBootstrapError.retired }
            guard !value.active && !value.cleaning else { throw USBHostBootstrapError.exchangeInProgress }
            value.active = true
        }
        defer { state.withLock { $0.active = false } }
        try checkCurrent()
        let openingStarted = ContinuousClock.now
        let stream = try await connection.openStream(timeout: min(.seconds(5), budget.remaining()))
        let openingDuration = openingStarted.duration(to: .now)
        let result: Result<Data, any Error>
        do {
            result = .success(try await withTaskCancellationHandler {
                try checkCurrent()
                try await stream.writeFrame(request, timeout: min(.seconds(5), budget.remaining()),
                    requireEffectAuthorization: requireCurrent)
                let response = try await stream.readFrame(maximumBytes: 64 * 1024, timeout: budget.remaining())
                try checkCurrent()
                try await stream.finishSending(timeout: min(.seconds(5), budget.remaining()))
                switch try await stream.readBytes(maximumBytes: 1, timeout: min(.seconds(5), budget.remaining())) {
                case .end: break
                case .bytes: throw USBHostBootstrapError.trailingResponseBytes
                }
                try checkCurrent()
                return response
            } onCancel: { stream.close() })
        } catch { result = .failure(error) }
        do { try await stream.closeAndAwait() }
        catch {
            // Never lose a logical owner just because its bounded observer timed
            // out. No new bootstrap may run on this channel after uncertain cleanup.
            state.withLock { $0.retained = stream; $0.retired = true }
            let primary: (any Error)? = if case .failure(let failure) = result { failure } else { nil }
            throw USBHostBootstrapCleanupFailure(primary: primary, cleanup: error)
        }
        return Response(body: try result.get(), streamID: stream.id, openingDuration: openingDuration)
    }

    /// Only retries cleanup of the same retained stream, never its request.
    public func finishCleanup(timeout: Duration = .seconds(2)) async throws {
        let stream = try state.withLock { value -> USBHostMultiplexConnection.Stream? in
            guard !value.active && !value.cleaning else { throw USBHostBootstrapError.exchangeInProgress }
            value.cleaning = true; return value.retained
        }
        defer { state.withLock { $0.cleaning = false } }
        guard let stream else { return }
        try await stream.closeAndAwait(timeout: timeout)
        state.withLock { $0.retained = nil }
    }
}
#endif
