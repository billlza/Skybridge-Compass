#if os(macOS)
import Foundation

enum AudioOriginalFileUSBError: Error, Sendable { case alreadyStarted, unavailable, closeUnconfirmed }

/// Owns one host-initiated Apple USB return socket or admitted Android logical file
/// stream, separately from MAIN and the private artifact. Failed cleanup retains it.
actor AudioOriginalFileUSBReceiver {
    typealias Receive = @Sendable (any ClassicFileTransferByteChannel, FileTransferPeerContext, AudioOriginalFileTransfer) async throws -> Void
    static let receiveUsingFileManager: Receive = { connection, context, transfer in
        try await FileTransferManager.shared.receiveOriginalAudioFile(from: connection, peerContext: context,
            requiring: transfer)
    }
    private let channel: P2PAudioChannel
    private let transfer: AudioOriginalFileTransfer
    private let port: UInt16?
    private let receive: Receive
    private var worker: Task<Void, Never>?
    private var result: Result<Void, Error>?
    private var connection: (any ClassicFileTransferByteChannel)?
    private var closing: Task<AudioOutputCleanupOutcome, Never>?

    init(channel: P2PAudioChannel, transfer: AudioOriginalFileTransfer, port: UInt16? = nil,
         receive: @escaping Receive = AudioOriginalFileUSBReceiver.receiveUsingFileManager) {
        self.channel = channel; self.transfer = transfer; self.port = port; self.receive = receive
    }

    func start() throws {
        guard worker == nil else { throw AudioOriginalFileUSBError.alreadyStarted }
        if let port {
            guard port > 0, channel.usesUSBFileReturn else { throw AudioOriginalFileUSBError.unavailable }
        } else {
            guard channel.usesLogicalFileStream else { throw AudioOriginalFileUSBError.unavailable }
        }
        try transfer.requireAuthorization()
        worker = Task { await self.run() }
    }

    func waitForCompletion() async throws {
        guard let worker else { throw AudioOriginalFileUSBError.unavailable }
        await worker.value
        guard let result else { throw AudioOriginalFileUSBError.unavailable }
        try result.get()
    }

    private func run() async {
        var failure: Error?
        do {
            let transfer = self.transfer
            let value: any ClassicFileTransferByteChannel
            if let port {
                value = NetworkClassicFileTransferByteChannel(try await channel.openOriginalFileReturnStream(port: port,
                    authorize: { try transfer.requireAuthorization() }))
            } else { value = try await channel.acceptOriginalFileStream() }
            connection = value
            try transfer.requireAuthorization()
            try await receive(value, .init(declaredSenderDeviceId: channel.remoteIdentity.deviceID,
                endpointHostOrIP: nil, peerLabel: nil, transferId: transfer.transferID.uuidString), transfer)
            try transfer.requireAuthorization()
        } catch { failure = error }
        let cleanup = await settleNativeConnection()
        if cleanup.state != .released, failure == nil { failure = AudioOriginalFileUSBError.closeUnconfirmed }
        if let failure {
            await transfer.fail(failure)
            result = .failure(failure)
        } else { result = .success(()) }
    }

    /// Cancellation of a caller never cancels the bounded native-close attempt.
    private func settleNativeConnection() async -> AudioOutputCleanupOutcome {
        if let closing { return await closing.value }
        let task = Task { await self.closeNativeConnection() }
        closing = task
        let result = await task.value
        closing = nil
        return result
    }

    private func closeNativeConnection() async -> AudioOutputCleanupOutcome {
        guard let connection else { return .noOutput }
        connection.cancel()
        do { try await connection.closeAndAwait(timeout: .seconds(5)) }
        catch {
            return .init(state: .pending, diagnostics: ["usb_file_close_wait:" + String(reflecting: type(of: error))], preservedExternalChanges: [])
        }
        self.connection = nil
        return .noOutput
    }

    func close() async -> AudioOutputCleanupOutcome {
        worker?.cancel(); connection?.cancel()
        // USB enumeration/dial or logical acceptance already has a finite bound. Keep a finite
        // drain here too; an uncooperative producer remains owned for retry.
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while worker != nil, result == nil {
            guard ContinuousClock.now < deadline else {
                return .init(state: .pending, diagnostics: ["usb_file_worker_drain_pending"], preservedExternalChanges: [])
            }
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch {
                return .init(state: .pending, diagnostics: ["usb_file_worker_drain:" + String(reflecting: type(of: error))], preservedExternalChanges: [])
            }
        }
        return await settleNativeConnection()
    }

    deinit { worker?.cancel(); connection?.cancel() }
}
#endif
