//
// AudioRedirection.swift
// SkyBridge Compass Pro
//
// 远程桌面音频播放管理器（macOS viewer）
//

import Foundation
@preconcurrency import AVFoundation
import AudioToolbox
import OSLog
import Combine
import SkyBridgeRealtimeMedia

private struct DecodedRemoteAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

private final class OneShotDecodeFeedState: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false

    func takeIfAvailable() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { return false }
        consumed = true
        return true
    }
}

private actor RemoteAudioDecodeWorker {
    private let log = Logger(subsystem: "com.skybridge.compass", category: "AudioRedirection")
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 48_000,
        channels: 2,
        interleaved: true
    )!

    private var audioDecodeConverter: AVAudioConverter?
    private var audioDecodeFormatSignature: String?

    func reset() {
        audioDecodeConverter = nil
        audioDecodeFormatSignature = nil
    }

    func decode(_ chunk: RemoteDesktopAudioChunkPayload) -> DecodedRemoteAudioBuffer? {
        let buffer: AVAudioPCMBuffer?
        switch chunk.encoding {
        case .pcmS16LE:
            buffer = makePCMBuffer(from: chunk)
        case .aacLC:
            buffer = decodeAACChunk(chunk)
        }
        guard let buffer else { return nil }
        return DecodedRemoteAudioBuffer(buffer: buffer)
    }

    private func makePCMBuffer(from chunk: RemoteDesktopAudioChunkPayload) -> AVAudioPCMBuffer? {
        guard chunk.sampleRate == Int(playbackFormat.sampleRate.rounded()),
              chunk.channelCount == Int(playbackFormat.channelCount),
              chunk.frameCount > 0 else {
            return nil
        }

        let bytesPerFrame = Int(playbackFormat.streamDescription.pointee.mBytesPerFrame)
        let expectedByteCount = chunk.frameCount * bytesPerFrame
        guard chunk.data.count == expectedByteCount else { return nil }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: playbackFormat,
            frameCapacity: AVAudioFrameCount(chunk.frameCount)
        ) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(chunk.frameCount)

        guard let samplePointer = buffer.int16ChannelData?.pointee else { return nil }
        chunk.data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            memcpy(samplePointer, baseAddress, chunk.data.count)
        }
        return buffer
    }

    private func decodeAACChunk(_ chunk: RemoteDesktopAudioChunkPayload) -> AVAudioPCMBuffer? {
        guard let packetCount = chunk.packetCount, packetCount > 0 else { return nil }
        guard let inputFormat = AVAudioFormat(
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: chunk.sampleRate,
                AVNumberOfChannelsKey: chunk.channelCount
            ]
        ) else {
            return nil
        }

        let converterSignature = "aac-\(chunk.sampleRate)-\(chunk.channelCount)"
        if audioDecodeConverter == nil || audioDecodeFormatSignature != converterSignature {
            audioDecodeConverter = AVAudioConverter(from: inputFormat, to: playbackFormat)
            audioDecodeConverter?.primeMethod = .none
            audioDecodeFormatSignature = converterSignature
        }
        guard let audioDecodeConverter else { return nil }
        if let magicCookie = chunk.magicCookie {
            audioDecodeConverter.magicCookie = magicCookie
        }

        let maximumPacketSize = max(
            chunk.packetDescriptions?.map { Int($0.dataByteSize) }.max() ?? 0,
            chunk.data.count
        )
        let compressedBuffer = AVAudioCompressedBuffer(
            format: inputFormat,
            packetCapacity: AVAudioPacketCount(packetCount),
            maximumPacketSize: max(1, maximumPacketSize)
        )
        compressedBuffer.packetCount = AVAudioPacketCount(packetCount)
        compressedBuffer.byteLength = UInt32(chunk.data.count)
        chunk.data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            memcpy(compressedBuffer.data, baseAddress, chunk.data.count)
        }

        if let packetDescriptions = chunk.packetDescriptions,
           let packetDescriptionsPointer = compressedBuffer.packetDescriptions,
           packetDescriptions.count == packetCount {
            for (index, packetDescription) in packetDescriptions.enumerated() {
                packetDescriptionsPointer[index] = AudioStreamPacketDescription(
                    mStartOffset: Int64(packetDescription.startOffset),
                    mVariableFramesInPacket: packetDescription.variableFramesInPacket,
                    mDataByteSize: packetDescription.dataByteSize
                )
            }
        }

        let outputCapacity = AVAudioFrameCount(max(chunk.frameCount + 256, 2048))
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: playbackFormat,
            frameCapacity: outputCapacity
        ) else {
            return nil
        }

        let inputState = OneShotDecodeFeedState()
        var decodeError: NSError?
        let status = audioDecodeConverter.convert(to: outputBuffer, error: &decodeError) { _, outStatus in
            if !inputState.takeIfAvailable() {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return compressedBuffer
        }

        guard decodeError == nil else {
            log.debug("AAC 解码失败: \(decodeError?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }
        guard status == .haveData || status == .inputRanDry else { return nil }
        guard outputBuffer.frameLength > 0 else { return nil }
        return outputBuffer
    }
}

@MainActor
public final class AudioRedirectionManager: ObservableObject, @unchecked Sendable {
    public static let shared = AudioRedirectionManager()
    public nonisolated static let isFeatureAvailable = true

    private struct BufferedRemoteAudioChunk {
        let sequenceNumber: UInt64
        let sentAt: TimeInterval
        let enqueuedAt: Date
        let frameLength: AVAudioFrameCount
        let buffer: AVAudioPCMBuffer
    }

    private let log = Logger(subsystem: "com.skybridge.compass", category: "AudioRedirection")
    private let decodeWorker = RemoteAudioDecodeWorker()
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 48_000,
        channels: 2,
        interleaved: true
    )!
    private let maxAdaptiveQueuedFrames: AVAudioFrameCount = 48_000 / 2
    private let hardResetQueuedFrames: AVAudioFrameCount = 48_000

    @Published public private(set) var isEnabled: Bool = false

    private var activeSessionId: UUID?
    private let realtimePlaybackOwnership = SkyBridgeRealtimeMediaPlaybackOwnership()
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var queuedFrameCount: AVAudioFrameCount = 0
    private var lastRemoteVideoTimestamp: TimeInterval?
    private var bufferedChunks: [UInt64: BufferedRemoteAudioChunk] = [:]
    private var bufferedChunkOrder: [UInt64] = []
    private var bufferedFrameCount: AVAudioFrameCount = 0
    private var expectedSequenceNumber: UInt64?
    private var lastArrivalAt: Date?
    private var lastSentAt: TimeInterval?
    private var arrivalJitter: TimeInterval = 0
    private var lastChunkDuration: TimeInterval = 0.02
    private var audioDecodeGeneration: UInt64 = 0
    private var pendingDecodeCount = 0
    private var lastDecodeBackpressureLogAt: Date = .distantPast
    private var lastPlaybackBackpressureLogAt: Date = .distantPast
    private let maxPendingDecodeCount = 12

    private init() {}

    public func enable(for sessionId: UUID) throws {
        if isEnabled, activeSessionId == sessionId, let engine = audioEngine, engine.isRunning {
            return
        }

        realtimePlaybackOwnership.retireCurrentOwnerAndClear()
        teardownAudioPipeline()

        try startAudioPipeline(activeSessionId: sessionId)

        log.info("✅ 远控音频播放已启用: sessionId=\(sessionId.uuidString, privacy: .public)")
    }

    @discardableResult
    public func enable(
        for owner: SkyBridgeRealtimeMediaReceiverLifecycle
    ) throws -> Bool {
        let claim = realtimePlaybackOwnership.claim(owner)
        guard claim.isAccepted else { return false }
        if claim == .alreadyOwned,
           isEnabled,
           activeSessionId == nil,
           let engine = audioEngine,
           engine.isRunning {
            return true
        }

        // A newly acquired owner must never inherit queued PCM/decoder state
        // from a retired realtime receiver or the legacy playback path.
        teardownAudioPipeline()
        guard realtimePlaybackOwnership.isOwned(by: owner) else { return false }
        do {
            try startAudioPipeline(activeSessionId: nil)
            return true
        } catch {
            realtimePlaybackOwnership.release(ifOwnedBy: owner)
            throw error
        }
    }

    private func startAudioPipeline(activeSessionId: UUID?) throws {

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
        try engine.start()
        playerNode.play()

        audioEngine = engine
        self.playerNode = playerNode
        self.activeSessionId = activeSessionId
        queuedFrameCount = 0
        audioDecodeGeneration &+= 1
        pendingDecodeCount = 0
        Task.detached(priority: .utility) { [decodeWorker] in
            await decodeWorker.reset()
        }
        resetBufferedAudioState()
        isEnabled = true
    }

    public func disable() {
        let retiredRealtimeOwner = realtimePlaybackOwnership.retireCurrentOwnerAndClear()
        guard isEnabled || audioEngine != nil || playerNode != nil || activeSessionId != nil
                || retiredRealtimeOwner else {
            return
        }

        teardownAudioPipeline()
        log.info("🛑 远控音频播放已禁用")
    }

    /// Tears down playback only when the caller still owns the active audio
    /// session. A delayed close from a superseded realtime-media receiver must
    /// never stop its replacement.
    @discardableResult
    public func disable(for sessionId: UUID) -> Bool {
        guard activeSessionId == sessionId else { return false }
        disable()
        return true
    }

    @discardableResult
    public func disable(
        ifOwnedBy owner: SkyBridgeRealtimeMediaReceiverLifecycle
    ) -> Bool {
        guard realtimePlaybackOwnership.release(ifOwnedBy: owner) else { return false }
        teardownAudioPipeline()
        return true
    }

    public func updateRemoteVideoTimestamp(_ timestamp: TimeInterval?) {
        lastRemoteVideoTimestamp = timestamp
    }

    @discardableResult
    public func updateRemoteVideoTimestamp(
        _ timestamp: TimeInterval?,
        ifOwnedBy owner: SkyBridgeRealtimeMediaReceiverLifecycle
    ) -> Bool {
        guard realtimePlaybackOwnership.isOwned(by: owner) else { return false }
        lastRemoteVideoTimestamp = timestamp
        return true
    }

    public func playRemoteAudioChunk(_ chunk: RemoteDesktopAudioChunkPayload) {
        enqueueRemoteAudioChunk(chunk, owner: nil)
    }

    @discardableResult
    public func playRemoteAudioChunk(
        _ chunk: RemoteDesktopAudioChunkPayload,
        ifOwnedBy owner: SkyBridgeRealtimeMediaReceiverLifecycle
    ) -> Bool {
        guard realtimePlaybackOwnership.isOwned(by: owner) else { return false }
        enqueueRemoteAudioChunk(chunk, owner: owner)
        return true
    }

    private func enqueueRemoteAudioChunk(
        _ chunk: RemoteDesktopAudioChunkPayload,
        owner: SkyBridgeRealtimeMediaReceiverLifecycle?
    ) {
        guard isEnabled, let engine = audioEngine, engine.isRunning else { return }
        guard playerNode != nil else { return }

        let now = Date()
        if isChunkTooFarBehindVideo(chunk.sentAt) {
            log.debug("已丢弃落后视频时间轴的远控音频块: seq=\(chunk.sequenceNumber, privacy: .public)")
            return
        }
        noteArrival(of: chunk, at: now)
        guard pendingDecodeCount < maxPendingDecodeCount else {
            logDecodeBackpressureIfNeeded()
            return
        }
        pendingDecodeCount += 1
        let generation = audioDecodeGeneration
        Task.detached(priority: .utility) { [weak self, decodeWorker, chunk, generation, owner] in
            let decoded = await decodeWorker.decode(chunk)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pendingDecodeCount = max(0, self.pendingDecodeCount - 1)
                if let owner,
                   !self.realtimePlaybackOwnership.isOwned(by: owner) {
                    return
                }
                guard self.audioDecodeGeneration == generation,
                      self.isEnabled,
                      let engine = self.audioEngine,
                      engine.isRunning,
                      let playerNode = self.playerNode,
                      let decoded else {
                    return
                }
                let enqueueTime = Date()
                guard self.insertBufferedChunk(decoded.buffer, for: chunk, at: enqueueTime) else {
                    return
                }
                self.drainBufferedChunks(on: playerNode, now: enqueueTime)
            }
        }
    }

    private func teardownAudioPipeline() {
        playerNode?.stop()
        playerNode?.reset()
        audioEngine?.stop()

        playerNode = nil
        audioEngine = nil
        activeSessionId = nil
        audioDecodeGeneration &+= 1
        pendingDecodeCount = 0
        Task.detached(priority: .utility) { [decodeWorker] in
            await decodeWorker.reset()
        }
        queuedFrameCount = 0
        lastRemoteVideoTimestamp = nil
        resetBufferedAudioState()
        isEnabled = false
    }

    private func resetBufferedAudioState() {
        bufferedChunks.removeAll(keepingCapacity: false)
        bufferedChunkOrder.removeAll(keepingCapacity: false)
        bufferedFrameCount = 0
        expectedSequenceNumber = nil
        lastArrivalAt = nil
        lastSentAt = nil
        arrivalJitter = 0
        lastChunkDuration = 0.02
        lastPlaybackBackpressureLogAt = .distantPast
    }

    private func noteArrival(of chunk: RemoteDesktopAudioChunkPayload, at now: Date) {
        let chunkDuration = TimeInterval(chunk.frameCount) / max(Double(chunk.sampleRate), 1)
        if let lastArrivalAt, let lastSentAt {
            let arrivalDelta = now.timeIntervalSince(lastArrivalAt)
            let sentDelta = max(0, chunk.sentAt - lastSentAt)
            let transitDelta = arrivalDelta - sentDelta
            arrivalJitter = (arrivalJitter * 0.875) + (abs(transitDelta) * 0.125)
        }
        lastArrivalAt = now
        self.lastSentAt = chunk.sentAt
        lastChunkDuration = chunkDuration.isFinite && chunkDuration > 0 ? chunkDuration : 0.02
    }

    private func insertBufferedChunk(
        _ buffer: AVAudioPCMBuffer,
        for chunk: RemoteDesktopAudioChunkPayload,
        at now: Date
    ) -> Bool {
        guard bufferedChunks[chunk.sequenceNumber] == nil else {
            return false
        }

        let bufferedChunk = BufferedRemoteAudioChunk(
            sequenceNumber: chunk.sequenceNumber,
            sentAt: chunk.sentAt,
            enqueuedAt: now,
            frameLength: buffer.frameLength,
            buffer: buffer
        )
        bufferedChunks[chunk.sequenceNumber] = bufferedChunk
        bufferedChunkOrder.append(chunk.sequenceNumber)
        bufferedChunkOrder.sort()
        bufferedFrameCount += buffer.frameLength
        if expectedSequenceNumber == nil {
            expectedSequenceNumber = bufferedChunkOrder.first
        }
        return true
    }

    private func drainBufferedChunks(on playerNode: AVAudioPlayerNode, now: Date) {
        normalizeBufferedStateIfNeeded()

        while let firstSequenceNumber = bufferedChunkOrder.first {
            if shouldHoldForStartup(firstSequenceNumber: firstSequenceNumber, now: now) {
                break
            }

            if expectedSequenceNumber == nil {
                expectedSequenceNumber = firstSequenceNumber
            }
            guard let expectedSequenceNumber else { break }

            if let chunk = bufferedChunks[expectedSequenceNumber] {
                removeBufferedChunk(sequenceNumber: expectedSequenceNumber)

                if isChunkTooFarBehindVideo(chunk.sentAt) {
                    continue
                }

                if queuedFrameCount > currentHardResetQueuedFrames {
                    resetPlayerQueue(on: playerNode, reason: "queued-audio-runaway")
                    continue
                }

                if queuedFrameCount + chunk.frameLength > currentMaxQueuedFrames {
                    logPlaybackBackpressureIfNeeded(
                        queuedFrames: queuedFrameCount,
                        droppedFrames: chunk.frameLength
                    )
                    continue
                }

                scheduleBufferedChunk(chunk, on: playerNode)
                self.expectedSequenceNumber = expectedSequenceNumber &+ 1
                continue
            }

            if firstSequenceNumber < expectedSequenceNumber {
                removeBufferedChunk(sequenceNumber: firstSequenceNumber)
                continue
            }

            let oldestWait = bufferedChunks[firstSequenceNumber].map { now.timeIntervalSince($0.enqueuedAt) } ?? 0
            if bufferedChunkOrder.count >= 3 || oldestWait >= 0.035 {
                self.expectedSequenceNumber = firstSequenceNumber
                continue
            }
            break
        }
    }

    private func shouldHoldForStartup(firstSequenceNumber: UInt64, now: Date) -> Bool {
        guard queuedFrameCount == 0 else { return false }
        guard bufferedFrameCount > 0 else { return false }
        guard bufferedFrameCount < currentStartupTargetFrames else { return false }
        guard let firstChunk = bufferedChunks[firstSequenceNumber] else { return false }
        return now.timeIntervalSince(firstChunk.enqueuedAt) < 0.03
    }

    private func scheduleBufferedChunk(_ chunk: BufferedRemoteAudioChunk, on playerNode: AVAudioPlayerNode) {
        let scheduledFrameLength = chunk.frameLength
        queuedFrameCount += scheduledFrameLength
        playerNode.scheduleBuffer(chunk.buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.queuedFrameCount = self.queuedFrameCount > scheduledFrameLength
                    ? self.queuedFrameCount - scheduledFrameLength
                    : 0
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func removeBufferedChunk(sequenceNumber: UInt64) {
        guard let chunk = bufferedChunks.removeValue(forKey: sequenceNumber) else { return }
        bufferedChunkOrder.removeAll { $0 == sequenceNumber }
        bufferedFrameCount = bufferedFrameCount > chunk.frameLength
            ? bufferedFrameCount - chunk.frameLength
            : 0
    }

    private func normalizeBufferedStateIfNeeded() {
        while bufferedChunkOrder.count > 8 {
            guard let firstSequenceNumber = bufferedChunkOrder.first else { break }
            removeBufferedChunk(sequenceNumber: firstSequenceNumber)
            expectedSequenceNumber = bufferedChunkOrder.first
        }
    }

    private func resetPlayerQueue(on playerNode: AVAudioPlayerNode, reason: String) {
        playerNode.stop()
        playerNode.reset()
        playerNode.play()
        queuedFrameCount = 0
        log.debug("已重置远控音频播放队列: reason=\(reason, privacy: .public)")
    }

    private func logPlaybackBackpressureIfNeeded(
        queuedFrames: AVAudioFrameCount,
        droppedFrames: AVAudioFrameCount
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastPlaybackBackpressureLogAt) >= 2 else { return }
        lastPlaybackBackpressureLogAt = now
        log.debug(
            """
            已丢弃远控音频块：播放队列背压 queuedFrames=\(queuedFrames, privacy: .public) \
            droppedFrames=\(droppedFrames, privacy: .public)
            """
        )
    }

    private func logDecodeBackpressureIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastDecodeBackpressureLogAt) >= 2 else { return }
        lastDecodeBackpressureLogAt = now
        log.debug("已丢弃远控音频块：解码队列繁忙")
    }

    private func isChunkTooFarBehindVideo(_ sentAt: TimeInterval) -> Bool {
        guard let lastRemoteVideoTimestamp else { return false }
        let allowedBehind = max(0.12, currentTargetBufferedDuration + 0.05)
        return sentAt + allowedBehind < lastRemoteVideoTimestamp
    }

    private var currentStartupTargetFrames: AVAudioFrameCount {
        frames(for: min(currentTargetBufferedDuration, 0.08))
    }

    private var currentMaxQueuedFrames: AVAudioFrameCount {
        frames(for: min(0.45, currentTargetBufferedDuration + 0.18))
    }

    private var currentHardResetQueuedFrames: AVAudioFrameCount {
        hardResetQueuedFrames
    }

    private var currentTargetBufferedDuration: TimeInterval {
        let adaptive = min(0.06, max(0, arrivalJitter * 2.5))
        return min(0.12, max(0.04, (lastChunkDuration * 2.0) + adaptive))
    }

    private func frames(for duration: TimeInterval) -> AVAudioFrameCount {
        AVAudioFrameCount(
            max(
                1,
                min(
                    Double(maxAdaptiveQueuedFrames),
                    (playbackFormat.sampleRate * max(duration, 0)).rounded()
                )
            )
        )
    }

    deinit {
        playerNode?.stop()
        playerNode?.reset()
        audioEngine?.stop()
    }
}

public enum AudioRedirectionError: LocalizedError, Sendable {
    case featureUnavailable

    public var errorDescription: String? {
        switch self {
        case .featureUnavailable:
            return "Audio redirection is unavailable in this build."
        }
    }
}
