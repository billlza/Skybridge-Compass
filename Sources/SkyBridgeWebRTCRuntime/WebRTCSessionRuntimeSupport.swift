import Foundation

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

#if canImport(WebRTCAudioDeviceBridge)
import WebRTCAudioDeviceBridge
#endif

#if canImport(WebRTC)
public enum WebRTCRuntimeLifecycleError: Error, LocalizedError, Equatable, Sendable {
    case sslInitializationFailed

    public var errorDescription: String? {
        switch self {
        case .sslInitializationFailed:
            return "WebRTC process-wide SSL initialization failed"
        }
    }
}

/// Owns WebRTC's process-wide SSL initialization state.
///
/// The native peer-connection factories below are process-lifetime singletons. SSL must
/// therefore remain initialized for at least as long as those factories exist. This owner
/// deliberately has no session-level release operation: a session closing is not a valid
/// process shutdown boundary, and this product does not currently have a reliable point at
/// which every native factory has been destroyed. The OS reclaims this process-global state
/// at process exit.
public final class WebRTCProcessRuntimeLifecycle: @unchecked Sendable {
    public typealias SSLInitializer = @Sendable () -> Bool

    private enum State {
        case uninitialized
        case initialized
        case initializationFailed
    }

    private let lock = NSLock()
    private let initializeSSL: SSLInitializer
    private var state: State = .uninitialized

    public init(initializeSSL: @escaping SSLInitializer) {
        self.initializeSSL = initializeSSL
    }

    public func ensureInitialized() throws(WebRTCRuntimeLifecycleError) {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .initialized:
            return
        case .initializationFailed:
            throw .sslInitializationFailed
        case .uninitialized:
            guard initializeSSL() else {
                state = .initializationFailed
                throw .sslInitializationFailed
            }
            state = .initialized
        }
    }
}

/// Shared RTCPeerConnectionFactory provider.
///
/// A long-lived factory avoids repeated native stack bring-up/tear-down and prevents
/// edge-case creation failures when short-lived local factories race with session lifecycle.
public enum WebRTCPeerConnectionFactoryProvider {
    private static let lock = NSLock()
    private static let processRuntime = WebRTCProcessRuntimeLifecycle {
        RTCInitializeSSL()
    }
    nonisolated(unsafe) private static var sharedFactory: RTCPeerConnectionFactory?
    nonisolated(unsafe) private static var sharedFactoryWithCustomAudioDevice: RTCPeerConnectionFactory?

    private static func makeDefaultFactory() -> RTCPeerConnectionFactory {
        // Do NOT pin `encoderFactory.preferredCodec` here. The negotiated outgoing
        // screen-video stream is H264, but `preferredHardwareVideoEncoderCodec()`
        // resolves to HEVC — pinning it to HEVC for an H264 stream contributed to the
        // macOS-host VideoToolbox encoder never starting (framesEncoded=0). SDP
        // codec-preference reordering (see WebRTCNativeScreenVideoValuePolicy
        // .codecPreferences) already controls negotiation, and the custom-audio bridge
        // factory (SBWebRTCPeerConnectionFactoryBridge) likewise sets no preferredCodec.
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        return RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }

    public static func factory(
        useCustomAudioDevice: Bool
    ) throws(WebRTCRuntimeLifecycleError) -> RTCPeerConnectionFactory {
        lock.lock()
        defer { lock.unlock() }
        try processRuntime.ensureInitialized()
        if useCustomAudioDevice {
            #if os(macOS)
            if let sharedFactoryWithCustomAudioDevice {
                return sharedFactoryWithCustomAudioDevice
            }
            let factory = SBWebRTCPeerConnectionFactoryBridge.makePeerConnectionFactoryWithSystemAudioDevice()
            sharedFactoryWithCustomAudioDevice = factory
            return factory
            #endif
        }
        if let sharedFactory {
            return sharedFactory
        }
        let factory = makeDefaultFactory()
        sharedFactory = factory
        return factory
    }
}

public actor WebRTCOutboundFrameGate {
    public enum GateError: LocalizedError, Equatable, Sendable {
        case waiterLimitExceeded(maximum: Int)

        public var errorDescription: String? {
            switch self {
            case .waiterLimitExceeded(let maximum):
                return "WebRTC outbound frame waiter limit exceeded: maximum=\(maximum)"
            }
        }
    }

    private struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<UUID, Error>
    }

    private let maximumWaiters: Int
    private var ownerToken: UUID?
    private var waiters: [Waiter] = []

    public init(maximumWaiters: Int = 64) {
        precondition(maximumWaiters >= 0, "maximumWaiters must not be negative")
        self.maximumWaiters = maximumWaiters
    }

    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        let token = try await acquire()
        defer { release(token: token) }
        try Task.checkCancellation()
        return try await operation()
    }

    /// Internal diagnostics used by concurrency tests and release telemetry.
    public var pendingWaiterCount: Int { waiters.count }

    private func acquire() async throws -> UUID {
        try Task.checkCancellation()
        let token = UUID()
        if ownerToken == nil {
            ownerToken = token
            return token
        }

        guard waiters.count < maximumWaiters else {
            try Task.checkCancellation()
            throw GateError.waiterLimitExceeded(maximum: maximumWaiters)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(token: token, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(token: token) }
        }
    }

    private func cancelWaiter(token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(token: UUID) {
        precondition(ownerToken == token, "Only the active WebRTC frame-gate owner may release it")
        if waiters.isEmpty {
            ownerToken = nil
            return
        }
        let next = waiters.removeFirst()
        ownerToken = next.token
        next.continuation.resume(returning: next.token)
    }
}
#endif
