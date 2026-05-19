import CryptoKit
import Foundation
import OSLog
import SkyBridgeProtocolCore
import SkyBridgeRealtimeMedia

@available(macOS 14.0, iOS 17.0, *)
actor WebRTCAudioFallbackSender {
    private let logger = Logger(subsystem: "com.skybridge.connection", category: "WebRTCAudioFallback")
    private let sessionID: String
    private let session: WebRTCSession
    private let keys: SessionKeys
    private let maxBufferedAmountBytes: UInt64
    private var pendingPayloads: [Data] = []
    private var isSending = false
    private var isClosed = false
    private var generation: UInt64 = 0
    private var drainTask: Task<Void, Never>?
    private var lastDropLogAt: Date = .distantPast
    private let maxQueuedPayloads = 6

    init(
        sessionID: String,
        session: WebRTCSession,
        keys: SessionKeys,
        maxBufferedAmountBytes: UInt64
    ) {
        self.sessionID = sessionID
        self.session = session
        self.keys = keys
        self.maxBufferedAmountBytes = maxBufferedAmountBytes
    }

    func submit(_ plaintext: Data) {
        guard !isClosed else { return }
        pendingPayloads.append(plaintext)
        if pendingPayloads.count > maxQueuedPayloads {
            let overflow = pendingPayloads.count - maxQueuedPayloads
            pendingPayloads.removeFirst(overflow)
            logDropIfNeeded(droppedCount: overflow)
        }
        scheduleDrainIfNeeded()
    }

    func close() {
        isClosed = true
        generation &+= 1
        drainTask?.cancel()
        drainTask = nil
        pendingPayloads.removeAll(keepingCapacity: false)
        isSending = false
    }

    private func scheduleDrainIfNeeded() {
        guard !isSending, !pendingPayloads.isEmpty else { return }
        isSending = true
        let generation = generation
        drainTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.drain(generation: generation)
        }
    }

    private func drain(generation: UInt64) async {
        defer {
            if self.generation == generation {
                isSending = false
                drainTask = nil
                if !isClosed, !pendingPayloads.isEmpty {
                    scheduleDrainIfNeeded()
                }
            }
        }
        while !Task.isCancelled,
              self.generation == generation,
              !isClosed,
              !pendingPayloads.isEmpty {
            let plaintext = pendingPayloads.removeFirst()
            do {
                let ciphertext = try encrypt(plaintext, with: keys)
                let padded = TrafficPadding.wrapIfEnabled(ciphertext, label: "tx/webrtc-audio")
                guard self.generation == generation else { break }
                try await session.sendFramedPayloadAsync(
                    padded,
                    maxChunkBytes: 8 * 1024,
                    maxBufferedAmountBytes: maxBufferedAmountBytes,
                    pollInterval: .milliseconds(20),
                    drainTimeout: .milliseconds(250)
                )
                guard self.generation == generation else { break }
            } catch {
                logger.debug(
                    "ℹ️ WebRTC 远控音频块后台发送失败: session=\(self.sessionID, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func encrypt(_ plaintext: Data, with keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.sendKey)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        return sealed.combined ?? Data()
    }

    private func logDropIfNeeded(droppedCount: Int) {
        let now = Date()
        guard now.timeIntervalSince(lastDropLogAt) >= 2 else { return }
        lastDropLogAt = now
        logger.debug(
            "ℹ️ WebRTC 远控音频后台队列已丢弃旧块: session=\(self.sessionID, privacy: .public) dropped=\(droppedCount, privacy: .public)"
        )
    }
}

@available(macOS 14.0, iOS 17.0, *)
struct WebRTCRealtimeAudioEndpointStableKey: Sendable, Equatable {
    let mediaSessionId: String
    let mode: SkyBridgeMediaAudioMode
    let viewerEndpointReady: Bool
    let viewerEndpointHost: String
    let viewerEndpointPort: UInt16

    init?(
        mediaSessionId: String,
        mode: SkyBridgeMediaAudioMode,
        endpoint: SkyBridgeMediaEndpoint?
    ) {
        guard let endpoint else { return nil }
        let normalizedHost = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mediaSessionId = mediaSessionId
        self.mode = mode
        self.viewerEndpointReady = !normalizedHost.isEmpty
        self.viewerEndpointHost = normalizedHost.lowercased()
        self.viewerEndpointPort = endpoint.port
    }
}
