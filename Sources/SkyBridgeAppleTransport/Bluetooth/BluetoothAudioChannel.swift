import Foundation
import SkyBridgeProtocolCore

public enum BluetoothAudioChannelError: Error, Sendable {
    case alreadyStarted, notReady, sendInProgress, readInProgress
    case cleanupFailed(primary: any Error, cleanup: any Error)
}

/// Own before awaiting authenticate(). A sink borrows its pending attachment until Hello proves
/// possession of the parent's key. No discovery, account lease or playback permission is granted.
public actor BluetoothAudioChannel {
    private enum Phase: Sendable { case idle, authenticating, ready, closed }
    public let binding: AudioBluetoothBinding
    private let transport: BluetoothControlFrameTransport
    private let attachment: AudioBluetoothAttachment
    private var phase = Phase.idle
    private var ownsAttachment = false
    private var cipher: AudioBluetoothRecordCipher?
    private var sending = false, receiving = false

    public init(transport: BluetoothControlFrameTransport, attachment: AudioBluetoothAttachment) {
        self.transport = transport; self.attachment = attachment; binding = attachment.binding
    }

    deinit {
        transport.close()
        cipher?.close()
        if ownsAttachment { attachment.close() }
    }

    public func authenticate(initialHelloTimeout: Duration = .seconds(3),
                             requireEffectAuthorization: @escaping @Sendable () throws -> Void) async throws {
        guard phase == .idle else { throw BluetoothAudioChannelError.alreadyStarted }
        guard initialHelloTimeout > .zero, initialHelloTimeout <= .seconds(30) else { throw BluetoothControlStreamError.invalidTimeout }
        phase = .authenticating
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try requireEffectAuthorization()
                let hello: Data?
                if binding.role == .sink {
                    hello = try await transport.readFrame(maximumBytes: AudioBluetoothHandshake.maximumFrameBytes,
                                                          timeout: min(initialHelloTimeout, attachment.handshakeRemainingTime()))
                } else { hello = nil }
                try Task.checkCancellation()
                try requireEffectAuthorization()
                guard phase == .authenticating else { throw BluetoothAudioChannelError.notReady }
                let attempt = try attachment.beginHandshake(initialHello: hello)
                ownsAttachment = true
                let first = try attempt.initialFrame()
                try await writeHandshake(first, authorize: requireEffectAuthorization)
                try attempt.didSend(first)
                let incoming = try await readHandshake(authorize: requireEffectAuthorization)
                guard let reply = try attempt.receive(incoming) else { throw AudioBluetoothAttachmentError.unexpectedMessage }
                try await writeHandshake(reply, authorize: requireEffectAuthorization)
                try attempt.didSend(reply)
                if binding.role == .source {
                    let ready = try await readHandshake(authorize: requireEffectAuthorization)
                    guard try attempt.receive(ready) == nil else { throw AudioBluetoothAttachmentError.unexpectedMessage }
                }
                try Task.checkCancellation()
                try requireEffectAuthorization()
                guard phase == .authenticating, !transport.isClosed else { throw BluetoothAudioChannelError.notReady }
                cipher = try attempt.takeRecordCipher()
                phase = .ready
            } onCancel: { [transport] in transport.close() }
        } catch { throw await cleanedFailure(error) }
    }

    public func send(_ message: AudioStreamingMessage, timeout: Duration = .seconds(5),
                     requireEffectAuthorization: @escaping @Sendable () throws -> Void) async throws {
        let cipher = try currentCipher()
        guard !sending else { throw BluetoothAudioChannelError.sendInProgress }
        try Task.checkCancellation()
        sending = true
        defer { sending = false }
        do {
            try attachment.requireEstablishedCurrent()
            try requireEffectAuthorization()
            let record = try cipher.seal(message)
            try await withTaskCancellationHandler {
                try await transport.writeFrame(record, timeout: timeout, requireEffectAuthorization: { [attachment] in
                    try attachment.requireEstablishedCurrent()
                    try requireEffectAuthorization()
                })
            } onCancel: { [transport] in transport.close() }
            try Task.checkCancellation()
            _ = try currentCipher()
            try attachment.requireEstablishedCurrent()
            try requireEffectAuthorization()
        } catch { throw await cleanedFailure(error) }
    }

    public func receive(timeout: Duration = .seconds(5),
                        requireEffectAuthorization: @escaping @Sendable () throws -> Void) async throws -> AudioStreamingMessage {
        let cipher = try currentCipher()
        guard !receiving else { throw BluetoothAudioChannelError.readInProgress }
        try Task.checkCancellation()
        receiving = true
        defer { receiving = false }
        do {
            try attachment.requireEstablishedCurrent()
            try requireEffectAuthorization()
            let record = try await withTaskCancellationHandler {
                try await transport.readFrame(maximumBytes: AudioBluetoothRecordCipher.maximumRecordBytes, timeout: timeout)
            } onCancel: { [transport] in transport.close() }
            try Task.checkCancellation()
            _ = try currentCipher()
            try attachment.requireEstablishedCurrent()
            try requireEffectAuthorization()
            let message = try cipher.open(record)
            try requireEffectAuthorization()
            return message
        } catch { throw await cleanedFailure(error) }
    }

    public func close() {
        phase = .closed
        transport.close(); cipher?.close(); cipher = nil
        if ownsAttachment { attachment.close() }
    }

    /// Keep this owner after an unconfirmed cleanup so the same native worker can be checked again.
    public func closeAndAwait() async throws {
        close()
        try await transport.closeAndAwait()
    }

    private func currentCipher() throws -> AudioBluetoothRecordCipher {
        guard phase == .ready, !transport.isClosed, let cipher else { throw BluetoothAudioChannelError.notReady }
        return cipher
    }
    private func writeHandshake(_ data: Data, authorize: @escaping @Sendable () throws -> Void) async throws {
        try authorize()
        try await transport.writeFrame(data, timeout: attachment.handshakeRemainingTime(), requireEffectAuthorization: { [attachment] in
            _ = try attachment.handshakeRemainingTime()
            try authorize()
        })
        try Task.checkCancellation(); try authorize()
        guard phase == .authenticating else { throw BluetoothAudioChannelError.notReady }
    }
    private func readHandshake(authorize: @Sendable () throws -> Void) async throws -> Data {
        try authorize()
        let data = try await transport.readFrame(maximumBytes: AudioBluetoothHandshake.maximumFrameBytes,
                                                  timeout: attachment.handshakeRemainingTime())
        try Task.checkCancellation(); try authorize()
        guard phase == .authenticating else { throw BluetoothAudioChannelError.notReady }
        return data
    }
    private func cleanedFailure(_ primary: any Error) async -> any Error {
        close()
        do { try await transport.closeAndAwait(); return primary }
        catch { return BluetoothAudioChannelError.cleanupFailed(primary: primary, cleanup: error) }
    }
}
