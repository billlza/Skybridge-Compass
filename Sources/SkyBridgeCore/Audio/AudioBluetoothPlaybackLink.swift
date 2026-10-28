#if os(macOS)
import Foundation
import SkyBridgeAppleTransport
import SkyBridgeProtocolCore

/// One owned route and authenticated child. Allocate this owner before the first await and
/// retain it until closeAndAwait succeeds. It never creates account or playback authority.
protocol AudioBluetoothPlaybackLink: Sendable {
    func publish() async throws -> AudioBluetoothRoute
    func establish(_ attachment: AudioBluetoothAttachment) async throws
    func send(_ message: AudioStreamingMessage,
              requireEffect: @escaping @Sendable () throws -> Void) async throws
    func receive(requireEffect: @escaping @Sendable () throws -> Void) async throws -> AudioStreamingMessage
    func closeAndAwait() async throws
}

actor NativeAudioBluetoothPlaybackLink: AudioBluetoothPlaybackLink {
    private let streamID: UUID
    private let requireCurrent: @Sendable () throws -> Void
    private var listener: BluetoothAudioListener?
    private var child: BluetoothAudioChannel?
    private var started = false, closed = false

    init(streamID: UUID, requireCurrent: @escaping @Sendable () throws -> Void) {
        self.streamID = streamID; self.requireCurrent = requireCurrent
    }
    func publish() async throws -> AudioBluetoothRoute {
        guard !started, !closed else { throw BluetoothAudioListenerError.alreadyStarted }
        started = true
        try Task.checkCancellation(); try requireCurrent()
        // Listener initialization performs no native effects. This actor already owns setup,
        // and records the listener before its publish() can allocate platform resources.
        let listener = await MainActor.run { BluetoothAudioListener(streamID: streamID, requireCurrent: requireCurrent) }
        self.listener = listener
        try Task.checkCancellation(); try requireCurrent()
        guard !closed else { throw BluetoothAudioListenerError.closed }
        let route = try await listener.publish()
        try Task.checkCancellation(); try requireCurrent()
        guard !closed else { throw BluetoothAudioListenerError.closed }
        return route
    }
    func establish(_ attachment: AudioBluetoothAttachment) async throws {
        guard !closed, child == nil, let listener else { throw BluetoothAudioListenerError.notReady }
        try Task.checkCancellation(); try requireCurrent()
        try await listener.accept(attachment)
        try Task.checkCancellation(); try requireCurrent()
        guard !closed else { throw BluetoothAudioListenerError.closed }
        let established = try await listener.channel
        try Task.checkCancellation(); try requireCurrent()
        guard !closed else { throw BluetoothAudioListenerError.closed }
        child = established
    }
    func send(_ message: AudioStreamingMessage, requireEffect: @escaping @Sendable () throws -> Void) async throws {
        guard !closed, let child else { throw BluetoothAudioChannelError.notReady }
        try await child.send(message, requireEffectAuthorization: requireEffect)
    }
    func receive(requireEffect: @escaping @Sendable () throws -> Void) async throws -> AudioStreamingMessage {
        guard !closed, let child else { throw BluetoothAudioChannelError.notReady }
        return try await child.receive(requireEffectAuthorization: requireEffect)
    }
    func closeAndAwait() async throws {
        closed = true
        // A late publishing/accepting operation still owns this same listener. Its caller must
        // cancel and join that operation before relying on the final cleanup observation.
        if let listener { try await listener.closeAndAwait() }
        child = nil; listener = nil
    }
}

struct AudioBluetoothPlaybackDependencies: Sendable {
    let makeLink: @Sendable (UUID, @escaping @Sendable () throws -> Void) -> any AudioBluetoothPlaybackLink
    let makeOutput: @Sendable (UUID, AudioStreamingOpusBuffering, @escaping @Sendable () throws -> Void) throws -> CoreAudioOpusOutput

    static let live = Self(makeLink: { NativeAudioBluetoothPlaybackLink(streamID: $0, requireCurrent: $1) },
        makeOutput: { try CoreAudioOpusOutput(ownerID: $0, buffering: $1, requireAuthorization: $2) })
}
#endif
