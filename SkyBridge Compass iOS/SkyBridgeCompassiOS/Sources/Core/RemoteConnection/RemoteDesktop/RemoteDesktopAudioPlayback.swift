import Foundation
@preconcurrency import AVFoundation
import AudioToolbox

@available(iOS 17.0, *)
struct RemoteAudioPlaybackContext: Sendable {
    let generation: UInt64
    let activeTransportModeIsCrossNetwork: Bool
    let nativeAudioReceiveEnabled: Bool
    let remoteAudioTrackHasReceivedFirstPacket: Bool
    let lastInboundScreenTimestamp: TimeInterval?
}

@available(iOS 17.0, *)
private final class RemoteAudioOneShotDecodeFeedState: @unchecked Sendable {
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

@available(iOS 17.0, *)
enum RemoteAudioPlaybackPolicy {
    private static let insufficientPriorityOSStatus = 561_017_449

    static func fallbackUnlockAt(
        activeTransportModeIsCrossNetwork: Bool,
        nativeAudioReceiveEnabled: Bool,
        remoteAudioTrackHasReceivedFirstPacket: Bool,
        currentUnlockAt: Date?,
        now: Date
    ) -> Date? {
        guard activeTransportModeIsCrossNetwork else { return nil }
        guard nativeAudioReceiveEnabled else { return nil }
        guard !remoteAudioTrackHasReceivedFirstPacket else { return nil }
        if let currentUnlockAt, now < currentUnlockAt {
            return currentUnlockAt
        }
        return now.addingTimeInterval(1.25)
    }

    static func retryDelay(for error: NSError) -> TimeInterval {
        if isInsufficientPriority(error) {
            return 5.0
        }
        return 1.0
    }

    static func isInsufficientPriority(_ error: NSError) -> Bool {
        error.domain == NSOSStatusErrorDomain && error.code == insufficientPriorityOSStatus
    }
}

@available(iOS 17.0, *)
actor RemoteAudioPlaybackController {
    private struct BufferedChunk {
        let sequenceNumber: UInt64
        let sentAt: TimeInterval
        let enqueuedAt: Date
        let frameLength: AVAudioFrameCount
        let buffer: AVAudioPCMBuffer
    }

    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!
    private let maxAdaptiveQueuedFrames: AVAudioFrameCount = 48_000
    private let hardResetQueuedFrames: AVAudioFrameCount = 48_000 * 2

    private var minimumAcceptedGeneration: UInt64 = 0
    private var activatedSession: AVAudioSession?
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var decodeConverter: AVAudioConverter?
    private var decodeFormatSignature: String?
    private var queuedFrames: AVAudioFrameCount = 0
    private var bufferedChunks: [UInt64: BufferedChunk] = [:]
    private var bufferedChunkOrder: [UInt64] = []
    private var bufferedFrames: AVAudioFrameCount = 0
    private var expectedSequenceNumber: UInt64?
    private var lastArrivalAt: Date?
    private var lastSentAt: TimeInterval?
    private var arrivalJitter: TimeInterval = 0
    private var lastChunkDuration: TimeInterval = 0.02
    private var fallbackUnlockAt: Date?
    private var playbackRetryNotBefore: Date?
    private var lastFailureDescription: String?
    private var lastFailureLogAt: Date?
    private var lastPlaybackBackpressureLogAt: Date = .distantPast

    func handle(_ payload: RemoteDesktopAudioChunkPayload, context: RemoteAudioPlaybackContext) {
        guard context.generation >= minimumAcceptedGeneration else { return }
        if context.activeTransportModeIsCrossNetwork,
           context.nativeAudioReceiveEnabled,
           context.remoteAudioTrackHasReceivedFirstPacket {
            return
        }

        let now = Date()
        if shouldDelayFallbackPlayback(context: context, now: now) {
            return
        }
        if let retryNotBefore = playbackRetryNotBefore, now < retryNotBefore {
            return
        }
        if isChunkTooFarBehindVideo(payload.sentAt, lastScreenTimestamp: context.lastInboundScreenTimestamp) {
            return
        }

        do {
            try ensurePlaybackPipeline()
            playbackRetryNotBefore = nil
            lastFailureDescription = nil
            lastFailureLogAt = nil
        } catch {
            notePlaybackFailure(error, at: now)
            return
        }

        guard let playerNode else { return }
        noteArrival(payload, at: now)
        let buffer: AVAudioPCMBuffer?
        switch payload.encoding {
        case .pcmS16LE:
            buffer = makePCMPlaybackBuffer(from: payload)
        case .aacLC:
            buffer = decodeAACPlaybackBuffer(from: payload)
        }
        guard let buffer else { return }

        guard insertBufferedChunk(buffer, payload: payload, at: now) else { return }
        drainBufferedChunks(on: playerNode, now: now, lastScreenTimestamp: context.lastInboundScreenTimestamp)
    }

    func invalidate(upTo generation: UInt64, deactivateSession: Bool = true, resetFailureState: Bool = true) {
        let nextMinimum = generation == UInt64.max ? UInt64.max : generation + 1
        if nextMinimum > minimumAcceptedGeneration {
            minimumAcceptedGeneration = nextMinimum
        }
        teardown(deactivateSession: deactivateSession, resetFailureState: resetFailureState)
    }

    private func makePCMPlaybackBuffer(from payload: RemoteDesktopAudioChunkPayload) -> AVAudioPCMBuffer? {
        guard payload.sampleRate == Int(playbackFormat.sampleRate.rounded()),
              payload.channelCount == Int(playbackFormat.channelCount),
              payload.frameCount > 0 else {
            return nil
        }

        let bytesPerFrame = payload.channelCount * MemoryLayout<Int16>.size
        let expectedByteCount = payload.frameCount * bytesPerFrame
        guard payload.data.count == expectedByteCount else { return nil }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: playbackFormat,
            frameCapacity: AVAudioFrameCount(payload.frameCount)
        ) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(payload.frameCount)

        guard let channelData = buffer.floatChannelData else { return nil }
        let leftChannel = channelData[0]
        let rightChannel = channelData[1]
        payload.data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            guard samples.count == payload.frameCount * payload.channelCount else { return }
            for frame in 0..<payload.frameCount {
                let leftSample = Float(Int16(littleEndian: samples[frame * payload.channelCount]))
                leftChannel[frame] = leftSample / Float(Int16.max)
                let rightSample = Float(Int16(littleEndian: samples[(frame * payload.channelCount) + 1]))
                rightChannel[frame] = rightSample / Float(Int16.max)
            }
        }
        return buffer
    }

    private func decodeAACPlaybackBuffer(from payload: RemoteDesktopAudioChunkPayload) -> AVAudioPCMBuffer? {
        guard let packetCount = payload.packetCount, packetCount > 0 else { return nil }
        guard let inputFormat = AVAudioFormat(
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: payload.sampleRate,
                AVNumberOfChannelsKey: payload.channelCount
            ]
        ) else {
            return nil
        }

        let converterSignature = "aac-\(payload.sampleRate)-\(payload.channelCount)"
        if decodeConverter == nil || decodeFormatSignature != converterSignature {
            decodeConverter = AVAudioConverter(from: inputFormat, to: playbackFormat)
            decodeConverter?.primeMethod = .none
            decodeFormatSignature = converterSignature
        }
        guard let decodeConverter else { return nil }
        if let magicCookie = payload.magicCookie {
            decodeConverter.magicCookie = magicCookie
        }

        let maximumPacketSize = max(
            payload.packetDescriptions?.map { Int($0.dataByteSize) }.max() ?? 0,
            payload.data.count
        )
        let compressedBuffer = AVAudioCompressedBuffer(
            format: inputFormat,
            packetCapacity: AVAudioPacketCount(packetCount),
            maximumPacketSize: max(1, maximumPacketSize)
        )
        compressedBuffer.packetCount = AVAudioPacketCount(packetCount)
        compressedBuffer.byteLength = UInt32(payload.data.count)
        payload.data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            memcpy(compressedBuffer.data, baseAddress, payload.data.count)
        }

        if let packetDescriptions = payload.packetDescriptions,
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

        let outputCapacity = AVAudioFrameCount(max(payload.frameCount + 256, 2048))
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: playbackFormat,
            frameCapacity: outputCapacity
        ) else {
            return nil
        }

        let inputState = RemoteAudioOneShotDecodeFeedState()
        var decodeError: NSError?
        let status = decodeConverter.convert(to: outputBuffer, error: &decodeError) { _, outStatus in
            if !inputState.takeIfAvailable() {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return compressedBuffer
        }

        guard decodeError == nil else {
            SkyBridgeLogger.shared.debug("ℹ️ 远端 AAC 音频解码失败: \(decodeError?.localizedDescription ?? "unknown")")
            return nil
        }
        guard status == .haveData || status == .inputRanDry else { return nil }
        guard outputBuffer.frameLength > 0 else { return nil }
        return outputBuffer
    }

    private func shouldDelayFallbackPlayback(context: RemoteAudioPlaybackContext, now: Date) -> Bool {
        guard let unlockAt = RemoteAudioPlaybackPolicy.fallbackUnlockAt(
            activeTransportModeIsCrossNetwork: context.activeTransportModeIsCrossNetwork,
            nativeAudioReceiveEnabled: context.nativeAudioReceiveEnabled,
            remoteAudioTrackHasReceivedFirstPacket: context.remoteAudioTrackHasReceivedFirstPacket,
            currentUnlockAt: fallbackUnlockAt,
            now: now
        ) else {
            fallbackUnlockAt = nil
            return false
        }
        fallbackUnlockAt = unlockAt
        return now < unlockAt
    }

    private func notePlaybackFailure(_ error: Error, at now: Date) {
        let nsError = error as NSError
        playbackRetryNotBefore = now.addingTimeInterval(Self.retryDelay(for: nsError))
        let description = "\(error.localizedDescription) [domain=\(nsError.domain) code=\(nsError.code)]"
        let shouldLog: Bool
        if let lastFailureDescription,
           let lastFailureLogAt,
           lastFailureDescription == description,
           now.timeIntervalSince(lastFailureLogAt) < 2.0 {
            shouldLog = false
        } else {
            shouldLog = true
        }

        if shouldLog {
            SkyBridgeLogger.shared.error("❌ 初始化远端音频播放失败: \(description)")
            lastFailureDescription = description
            lastFailureLogAt = now
        }
    }

    private static func retryDelay(for error: NSError) -> TimeInterval {
        RemoteAudioPlaybackPolicy.retryDelay(for: error)
    }

    private func setSessionPreferences(_ session: AVAudioSession) {
        do {
            try session.setPreferredSampleRate(playbackFormat.sampleRate)
        } catch {
            SkyBridgeLogger.shared.debug("ℹ️ 远端音频播放采样率偏好未生效: \(error.localizedDescription)")
        }

        do {
            try session.setPreferredIOBufferDuration(0.02)
        } catch {
            SkyBridgeLogger.shared.debug("ℹ️ 远端音频播放 I/O 缓冲偏好未生效: \(error.localizedDescription)")
        }
    }

    private func configureSession(_ session: AVAudioSession) throws {
        do {
            do {
                try session.setCategory(
                    .playback,
                    mode: .default,
                    options: [.mixWithOthers]
                )
            } catch {
                let nsError = error as NSError
                SkyBridgeLogger.shared.warning(
                    "⚠️ 远端音频阶段失败 stage=playback_set_category domain=\(nsError.domain) code=\(nsError.code) err=\(error.localizedDescription)"
                )
                throw error
            }
            setSessionPreferences(session)
            do {
                try session.setActive(true)
            } catch {
                let nsError = error as NSError
                SkyBridgeLogger.shared.warning(
                    "⚠️ 远端音频阶段失败 stage=playback_set_active domain=\(nsError.domain) code=\(nsError.code) err=\(error.localizedDescription)"
                )
                throw error
            }
            return
        } catch {
            let nsError = error as NSError
            SkyBridgeLogger.shared.warning(
                "⚠️ 远端音频 playback mixed 会话初始化失败: domain=\(nsError.domain) code=\(nsError.code) err=\(error.localizedDescription)"
            )
            guard RemoteAudioPlaybackPolicy.isInsufficientPriority(nsError)
                    || (nsError.domain == NSOSStatusErrorDomain && nsError.code == -50) else {
                throw error
            }

            SkyBridgeLogger.shared.warning(
                "⚠️ 远端音频尝试 ambient fallback: \(error.localizedDescription)"
            )
        }

        do {
            try session.setCategory(
                .ambient,
                mode: .default,
                options: []
            )
        } catch {
            let nsError = error as NSError
            SkyBridgeLogger.shared.warning(
                "⚠️ 远端音频阶段失败 stage=ambient_set_category domain=\(nsError.domain) code=\(nsError.code) err=\(error.localizedDescription)"
            )
            throw error
        }
        setSessionPreferences(session)
        do {
            try session.setActive(true)
        } catch {
            let nsError = error as NSError
            SkyBridgeLogger.shared.warning(
                "⚠️ 远端音频阶段失败 stage=ambient_set_active domain=\(nsError.domain) code=\(nsError.code) err=\(error.localizedDescription)"
            )
            throw error
        }
    }

    private func ensurePlaybackPipeline() throws {
        if let engine, engine.isRunning, playerNode != nil {
            return
        }

        teardown(deactivateSession: false, resetFailureState: false)

        let session = AVAudioSession.sharedInstance()
        try configureSession(session)
        activatedSession = session

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
        engine.prepare()
        self.engine = engine
        self.playerNode = playerNode
        do {
            try engine.start()
        } catch {
            let nsError = error as NSError
            teardown(deactivateSession: true, resetFailureState: false)
            SkyBridgeLogger.shared.warning(
                "⚠️ 远端音频阶段失败 stage=engine_start domain=\(nsError.domain) code=\(nsError.code) err=\(error.localizedDescription)"
            )
            throw error
        }
        playerNode.play()

        decodeConverter = nil
        decodeFormatSignature = nil
        queuedFrames = 0
        resetBufferedState()
    }

    private func teardown(deactivateSession: Bool, resetFailureState: Bool) {
        let oldPlayerNode = playerNode
        let oldEngine = engine

        playerNode = nil
        engine = nil
        decodeConverter = nil
        decodeFormatSignature = nil
        queuedFrames = 0
        fallbackUnlockAt = nil
        if resetFailureState {
            playbackRetryNotBefore = nil
            lastFailureDescription = nil
            lastFailureLogAt = nil
        }
        resetBufferedState()

        oldPlayerNode?.stop()
        oldPlayerNode?.reset()
        oldEngine?.stop()
        if deactivateSession, let activatedSession {
            do {
                try activatedSession.setActive(
                    false,
                    options: [.notifyOthersOnDeactivation]
                )
                self.activatedSession = nil
            } catch {
                let nsError = error as NSError
                SkyBridgeLogger.shared.warning(
                    "⚠️ 远端音频阶段失败 stage=session_deactivate domain=\(nsError.domain) code=\(nsError.code)"
                )
            }
        }
    }

    private func resetBufferedState() {
        bufferedChunks.removeAll(keepingCapacity: false)
        bufferedChunkOrder.removeAll(keepingCapacity: false)
        bufferedFrames = 0
        expectedSequenceNumber = nil
        lastArrivalAt = nil
        lastSentAt = nil
        arrivalJitter = 0
        lastChunkDuration = 0.02
        lastPlaybackBackpressureLogAt = .distantPast
    }

    private func noteArrival(_ payload: RemoteDesktopAudioChunkPayload, at now: Date) {
        let chunkDuration = TimeInterval(payload.frameCount) / max(Double(payload.sampleRate), 1)
        if let lastArrivalAt, let lastSentAt {
            let arrivalDelta = now.timeIntervalSince(lastArrivalAt)
            let sentDelta = max(0, payload.sentAt - lastSentAt)
            let transitDelta = arrivalDelta - sentDelta
            arrivalJitter = (arrivalJitter * 0.875) + (abs(transitDelta) * 0.125)
        }
        lastArrivalAt = now
        lastSentAt = payload.sentAt
        lastChunkDuration = chunkDuration.isFinite && chunkDuration > 0 ? chunkDuration : 0.02
    }

    private func insertBufferedChunk(
        _ buffer: AVAudioPCMBuffer,
        payload: RemoteDesktopAudioChunkPayload,
        at now: Date
    ) -> Bool {
        guard bufferedChunks[payload.sequenceNumber] == nil else { return false }
        let chunk = BufferedChunk(
            sequenceNumber: payload.sequenceNumber,
            sentAt: payload.sentAt,
            enqueuedAt: now,
            frameLength: buffer.frameLength,
            buffer: buffer
        )
        bufferedChunks[payload.sequenceNumber] = chunk
        bufferedChunkOrder.append(payload.sequenceNumber)
        bufferedChunkOrder.sort()
        bufferedFrames += chunk.frameLength
        if expectedSequenceNumber == nil {
            expectedSequenceNumber = bufferedChunkOrder.first
        }
        return true
    }

    private func drainBufferedChunks(
        on playerNode: AVAudioPlayerNode,
        now: Date,
        lastScreenTimestamp: TimeInterval?
    ) {
        normalizeBufferedStateIfNeeded()

        while let firstSequenceNumber = bufferedChunkOrder.first {
            if shouldHoldBufferedAudioForStartup(firstSequenceNumber: firstSequenceNumber, now: now) {
                break
            }

            if expectedSequenceNumber == nil {
                expectedSequenceNumber = firstSequenceNumber
            }
            guard let expectedSequenceNumber else { break }

            if let chunk = bufferedChunks[expectedSequenceNumber] {
                removeBufferedChunk(sequenceNumber: expectedSequenceNumber)

                if isChunkTooFarBehindVideo(chunk.sentAt, lastScreenTimestamp: lastScreenTimestamp) {
                    continue
                }

                if queuedFrames > currentHardResetQueuedFrames {
                    resetPlayerQueue(on: playerNode, reason: "queued-audio-runaway")
                    continue
                }

                if queuedFrames + chunk.frameLength > currentMaxQueuedFrames {
                    logPlaybackBackpressureIfNeeded(
                        queuedFrames: queuedFrames,
                        droppedFrames: chunk.frameLength,
                        now: now
                    )
                    self.expectedSequenceNumber = expectedSequenceNumber &+ 1
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
            if bufferedChunkOrder.count >= 10 || oldestWait >= 0.20 {
                self.expectedSequenceNumber = firstSequenceNumber
                continue
            }
            break
        }
    }

    private func shouldHoldBufferedAudioForStartup(firstSequenceNumber: UInt64, now: Date) -> Bool {
        guard queuedFrames == 0 else { return false }
        guard bufferedFrames > 0 else { return false }
        guard bufferedFrames < currentStartupQueuedFrames else { return false }
        guard let firstChunk = bufferedChunks[firstSequenceNumber] else { return false }
        return now.timeIntervalSince(firstChunk.enqueuedAt) < 0.22
    }

    private func scheduleBufferedChunk(_ chunk: BufferedChunk, on playerNode: AVAudioPlayerNode) {
        let scheduledFrameLength = chunk.frameLength
        queuedFrames += scheduledFrameLength
        playerNode.scheduleBuffer(chunk.buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { [weak self] in
                await self?.decrementQueuedFrames(by: scheduledFrameLength)
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func decrementQueuedFrames(by frameLength: AVAudioFrameCount) {
        queuedFrames = queuedFrames > frameLength ? queuedFrames - frameLength : 0
    }

    private func removeBufferedChunk(sequenceNumber: UInt64) {
        guard let chunk = bufferedChunks.removeValue(forKey: sequenceNumber) else { return }
        bufferedChunkOrder.removeAll { $0 == sequenceNumber }
        bufferedFrames = bufferedFrames > chunk.frameLength ? bufferedFrames - chunk.frameLength : 0
    }

    private func normalizeBufferedStateIfNeeded() {
        while bufferedChunkOrder.count > 16 {
            guard let firstSequenceNumber = bufferedChunkOrder.first else { break }
            removeBufferedChunk(sequenceNumber: firstSequenceNumber)
            expectedSequenceNumber = bufferedChunkOrder.first
        }
    }

    private func resetPlayerQueue(on playerNode: AVAudioPlayerNode, reason: String) {
        playerNode.stop()
        playerNode.reset()
        playerNode.play()
        queuedFrames = 0
        resetBufferedState()
        SkyBridgeLogger.shared.debug("ℹ️ 已重置远端音频播放队列: \(reason)")
    }

    private func logPlaybackBackpressureIfNeeded(
        queuedFrames: AVAudioFrameCount,
        droppedFrames: AVAudioFrameCount,
        now: Date
    ) {
        guard now.timeIntervalSince(lastPlaybackBackpressureLogAt) >= 2.0 else { return }
        lastPlaybackBackpressureLogAt = now
        let queuedMs = Int((Double(queuedFrames) / playbackFormat.sampleRate) * 1_000)
        let droppedMs = Int((Double(droppedFrames) / playbackFormat.sampleRate) * 1_000)
        SkyBridgeLogger.shared.debug(
            "ℹ️ 远端音频播放队列背压: queuedMs=\(queuedMs) droppedMs=\(droppedMs)"
        )
    }

    private func isChunkTooFarBehindVideo(_ sentAt: TimeInterval, lastScreenTimestamp: TimeInterval?) -> Bool {
        guard let lastScreenTimestamp else { return false }
        let allowedBehind = max(0.25, currentTargetBufferedDuration + 0.18)
        return sentAt + allowedBehind < lastScreenTimestamp
    }

    private var currentStartupQueuedFrames: AVAudioFrameCount {
        frames(for: min(max(currentTargetBufferedDuration, 0.20), 0.32))
    }

    private var currentMaxQueuedFrames: AVAudioFrameCount {
        frames(for: min(0.75, currentTargetBufferedDuration + 0.35))
    }

    private var currentHardResetQueuedFrames: AVAudioFrameCount {
        hardResetQueuedFrames
    }

    private var currentTargetBufferedDuration: TimeInterval {
        let adaptive = min(0.24, max(0, arrivalJitter * 4.0))
        return min(0.42, max(0.16, (lastChunkDuration * 6.0) + adaptive))
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
}
