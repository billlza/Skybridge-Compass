import Foundation

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

#if canImport(WebRTCAudioDeviceBridge)
import WebRTCAudioDeviceBridge
#endif

#if canImport(WebRTC)
/// Global SSL lifecycle guard for WebRTC.
///
/// `RTCInitializeSSL()` / `RTCCleanupSSL()` manage process-wide OpenSSL state. Calling cleanup per-session can
/// break other live sessions. We therefore retain/release with reference counting and only cleanup when the
/// last session is closed.
enum WebRTCSSL {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var refCount: Int = 0

    static func retain() {
        lock.lock()
        defer { lock.unlock() }
        if refCount == 0 {
            RTCInitializeSSL()
        }
        refCount += 1
    }

    static func release() {
        lock.lock()
        defer { lock.unlock() }
        refCount = max(0, refCount - 1)
        if refCount == 0 {
            RTCCleanupSSL()
        }
    }
}

/// Shared RTCPeerConnectionFactory provider.
///
/// A long-lived factory avoids repeated native stack bring-up/tear-down and prevents
/// edge-case creation failures when short-lived local factories race with session lifecycle.
enum WebRTCPeerConnectionFactoryProvider {
    private static let lock = NSLock()
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

    static func factory(useCustomAudioDevice: Bool) -> RTCPeerConnectionFactory {
        lock.lock()
        defer { lock.unlock() }
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

actor WebRTCOutboundFrameGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}
#endif
