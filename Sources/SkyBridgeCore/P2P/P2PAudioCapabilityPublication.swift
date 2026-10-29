import Foundation
import Network
import os
import SkyBridgeProtocolCore

/// One current refresh and one coalesced pending notification per connection.
/// A failed unchanged update is reported, never retried in a background loop.
@MainActor
final class P2PAudioCapabilityRefresh {
    private let operation: @MainActor () async throws -> Void
    private let reportFailure: @MainActor (Error) -> Void
    private var pending = false
    private var retired = false
    private var worker: Task<Void, Never>?

    init(operation: @escaping @MainActor () async throws -> Void,
         reportFailure: @escaping @MainActor (Error) -> Void) {
        self.operation = operation; self.reportFailure = reportFailure
    }

    func request() {
        guard !retired else { return }
        pending = true
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { worker = nil }
            while !retired, pending {
                pending = false
                do { try await operation() }
                catch {
                    if retired || Task.isCancelled { return }
                    reportFailure(error)
                }
            }
        }
    }

    func retire() { retired = true; pending = false; worker?.cancel() }
    func waitUntilIdle() async { await worker?.value }
    deinit { worker?.cancel() }
}

enum P2PAudioCapabilityPublicationError: Error, Equatable {
    case missingSubmission, repeatedSubmission, closedPreparation, identityUnavailable
}

/// A native callback may arrive synchronously while the builder still owns the
/// preparation boundary. Its success cannot hide a later preparation failure.
private final class P2PAudioCapabilitySubmission: Sendable {
    private struct State: Sendable {
        var preparing = true
        var submitted = false
        var callbackReceived = false
        var nativeResult: Result<Void, Error>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let completion = AudioStreamingSendCompletion()

    func beginSubmission() throws {
        try state.withLock {
            guard $0.preparing else { throw P2PAudioCapabilityPublicationError.closedPreparation }
            guard !$0.submitted else { throw P2PAudioCapabilityPublicationError.repeatedSubmission }
            guard completion.markSubmitted() else { throw CancellationError() }
            $0.submitted = true
        }
    }

    func requireSubmission() throws {
        guard state.withLock({ $0.submitted }) else { throw P2PAudioCapabilityPublicationError.missingSubmission }
    }

    func nativeCompleted(_ result: Result<Void, Error>) {
        let deliver = state.withLock { value in
            guard !value.callbackReceived else { return false }
            value.callbackReceived = true
            if value.preparing { value.nativeResult = result; return false }
            return true
        }
        if deliver { completion.completeWrite(result) }
    }

    func endPreparation(error: Error? = nil) {
        if let error { completion.finish(.failure(error)) }
        let result = state.withLock { value in
            value.preparing = false
            let result = value.nativeResult
            value.nativeResult = nil
            return result
        }
        if let result { completion.completeWrite(result) }
    }
}

/// The builder runs on the registry's actor and may hold its connection's epoch
/// lock through enqueue. This keeps the current capability read and native send
/// in one synchronous turn, after any asynchronous identity preparation.
@MainActor
enum P2PAudioCapabilityPublication {
    typealias Enqueue = @Sendable (Data) throws -> Void
    typealias Complete = @Sendable (Result<Void, Error>) -> Void
    typealias Submit = @Sendable (Data, @escaping Complete) -> Void
    typealias Authorization = @Sendable () throws -> Void
    typealias AuthorizedEnqueue = @Sendable (Data, @escaping Authorization) throws -> Void
    /// Admission either throws before enqueue or owns the eventual completion.
    typealias AuthorizedSubmit = @Sendable (Data, @escaping Authorization, @escaping Complete) throws -> Void

    static func send(over connection: NWConnection,
                     prepare: @MainActor (@escaping Enqueue) throws -> Void) async throws {
        try await send(submit: { frame, complete in
            connection.send(content: frame, completion: .contentProcessed { error in
                complete(error.map { .failure($0) } ?? .success(()))
            })
        }, cancelTransport: { connection.cancel() }, prepare: prepare)
    }

    /// Substitutable native write completion, not a substitute for authenticated
    /// message construction or a physical connection in integration acceptance.
    static func send(submit: @escaping Submit, cancelTransport: @escaping @Sendable () -> Void,
                     prepare: @MainActor (@escaping Enqueue) throws -> Void) async throws {
        try await sendAuthorized(submit: { frame, _, complete in submit(frame, complete) },
            cancelTransport: cancelTransport, prepare: { enqueue in
                // This legacy entry is for immediate native enqueue while the
                // builder owns its preparation lock, not a deferred USB writer.
                try prepare { frame in try enqueue(frame, {}) }
            })
    }

    static func sendAuthorized(submit: @escaping AuthorizedSubmit,
                               cancelTransport: @escaping @Sendable () -> Void,
                               prepare: @MainActor (@escaping AuthorizedEnqueue) throws -> Void) async throws {
        let submission = P2PAudioCapabilitySubmission()
        let completion = submission.completion
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                do {
                    try Task.checkCancellation()
                    try prepare { frame, authorization in
                        try Task.checkCancellation()
                        try submission.beginSubmission()
                        try submit(frame, {
                            guard completion.isPending else { throw CancellationError() }
                            try authorization()
                        }) { submission.nativeCompleted($0) }
                        completion.startWriteDeadline(cancelTransport: cancelTransport)
                    }
                    try submission.requireSubmission()
                    submission.endPreparation()
                } catch { submission.endPreparation(error: error) }
            }
        } onCancel: {
            // A submitted native write still owns its existing deadline. Merely
            // disabling the receiver must not cancel unrelated MAIN traffic.
            completion.finish(.failure(CancellationError()))
        }
    }
}

extension AppMessage.PairingIdentityExchangePayload {
    /// Changes only the locally-owned audio receiver flags. Existing identity,
    /// KEM, display, video, ports and timestamp remain the prepared publication.
    func replacingAudioReceiveCapabilities(_ current: [String]) -> Self {
        let owned: Set<String> = [AudioStreamingWire.fileReceiveCapability,
            AudioStreamingWire.flacFileReceiveCapability, AudioStreamingWire.alacFileReceiveCapability,
            AudioStreamingWire.captureReceiveCapability,
            AudioStreamingWire.opusReceiveCapability, AudioStreamingWire.bluetoothAttachmentCapability,
            AudioStreamingWire.bufferedOpusFileReceiveCapability,
            AudioStreamingWire.usbFileReceiveCapability]
        let capabilities = (self.capabilities ?? []).filter { !owned.contains($0) } + current
        return .init(deviceId: deviceId, kemPublicKeys: kemPublicKeys,
            protocolIdentityPublicKeys: protocolIdentityPublicKeys, deviceName: deviceName,
            modelName: modelName, platform: platform, osVersion: osVersion, chip: chip,
            accountDisplayName: accountDisplayName, nebulaId: nebulaId, remoteVideoFormats: remoteVideoFormats,
            capabilities: capabilities, fileTransferPort: fileTransferPort,
            remoteControlPort: remoteControlPort, sentAt: sentAt)
    }
}
