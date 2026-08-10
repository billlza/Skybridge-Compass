//
// RemoteControlOutboundFramePump.swift
// SkyBridgeCore
//

import Foundation
import Network
import OSLog
import SkyBridgeProtocolCore

// MARK: - 基础模型：消息/事件

/// 远程消息“信封”：所有消息都走它，避免裸 Data 粘包
struct RemoteMessage: Codable, Sendable {
    let type: MessageType
    let payload: Data

    enum MessageType: String, Codable, Sendable {
        case screenData
        case mouseEvent
        case keyboardEvent
        case clipboard
        case streamConfiguration
        case streamConfigurationAck
        case damageReport
        case cursorUpdate
        case overlayUpdate
    }
}

final class RemoteControlVideoPaceClock: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInteractive)
    }

    var isScheduled: Bool {
        lock.lock()
        let scheduled = timer != nil
        lock.unlock()
        return scheduled
    }

    @discardableResult
    func schedule(
        after delay: TimeInterval,
        interval: TimeInterval,
        generation: UInt64,
        handler: @escaping @Sendable (UInt64, Date) async -> Void
    ) -> Bool {
        lock.lock()
        guard timer == nil else {
            lock.unlock()
            return false
        }

        let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer = source
        lock.unlock()

        let nanoseconds = max(0, Int((delay * 1_000_000_000).rounded(.up)))
        let intervalNanoseconds = max(1, Int((interval * 1_000_000_000).rounded(.up)))
        source.schedule(
            deadline: .now() + .nanoseconds(nanoseconds),
            repeating: .nanoseconds(intervalNanoseconds),
            leeway: .nanoseconds(100_000)
        )
        source.setEventHandler { [weak self] in
            let firedAt = Date()
            guard self?.isScheduled == true else { return }
            Task(priority: .high) {
                await handler(generation, firedAt)
            }
        }
        source.resume()
        return true
    }

    func cancel() {
        lock.lock()
        let activeTimer = timer
        timer = nil
        lock.unlock()
        activeTimer?.setEventHandler {}
        activeTimer?.cancel()
    }

}

final class RemoteControlFrameSequenceGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue: UInt64 = 1

    func next() -> UInt64 {
        lock.lock()
        let value = nextValue
        nextValue = value == UInt64.max ? 1 : value + 1
        lock.unlock()
        return value
    }
}

actor RemoteControlOutboundFramePump {
    struct HealthSnapshot: Sendable {
        let lastSentFrameAt: Date
        let waitingForSyncFrame: Bool
        let waitingForSyncSince: Date?
    }

    private enum FrameTransport: Sendable {
        case legacyJSON
        case binaryWire
    }

    private let peerId: String
    private let connection: NWConnection
    private let maxFramedMessageBytes: Int
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "RemoteControl")

    private var frameTransport: FrameTransport = .legacyJSON
    private var usesChunkedScreenFrameWire = false
    private var nextChunkedScreenFrameId: UInt64 = 1
    private var streamingEnabled = false
    private var damageTrackingEnabled = true
    private var allowsInsecureLegacy = false
    private var sessionKeys: SessionKeys?
    private let secureEnvelopeSendSequencer: RemoteControlSecureEnvelopeSendSequencer
    private var frameQueue = RemoteScreenFrameSendQueue()
    private var audioPayloadQueue: [Data] = []
    private var audioPayloadQueuedBytes = 0
    private var latestDamageReport: RemoteDesktopDamageReport?
    private var sending = false
    private var inFlightVideoSends = 0
    private struct PendingVideoSendCompletion: Sendable {
        let id: UInt64
        let startedAt: Date
        let bytes: Int
    }
    private var pendingVideoSendCompletions: [PendingVideoSendCompletion] = []
    private var nextVideoSendCompletionId: UInt64 = 1
    private var videoSendGeneration: UInt64 = 0
    private var videoSendInterval: TimeInterval = 1.0 / 60.0
    private var lastVideoFrameScheduledAt: Date = .distantPast
    private let videoPaceClock = RemoteControlVideoPaceClock(
        label: "com.skybridge.remote.video-pace"
    )
    private var sendingAudio = false
    private var audioDrainGeneration: UInt64 = 0
    private var audioDrainTask: Task<Void, Never>?
    private var closed = false
    private var onNeedsSyncRefresh: (@Sendable () -> Void)?
    private var lastSentFrameAt: Date = .distantPast
    private var waitingForSyncSince: Date?
    private var lastSyncRefreshRequestAt: Date = .distantPast
    private var audioTelemetryWindowStartedAt = Date()
    private var telemetryAudioSubmittedPayloads = 0
    private var telemetryAudioSentPayloads = 0
    private var telemetryAudioFailedPayloads = 0
    private var telemetryAudioSentBytes = 0
    private var telemetryAudioQueuedPayloadsMax = 0
    private var telemetryAudioBacklogWarnings = 0
    private var syncRecoveryTask: Task<Void, Never>?
    private var frameTelemetryWindowStartedAt = Date()
    private var telemetrySubmittedFrames = 0
    private var telemetrySentFrames = 0
    private var telemetryDroppedFrames = 0
    private var telemetryBackpressureEvents = 0
    private var telemetryRawBackpressureEvents = 0
    private var telemetryOrderedThrottleEvents = 0
    private var telemetryQueueBacklogEvents = 0
    private var telemetrySentBytes = 0
    private var telemetryChunkedFrames = 0
    private var telemetrySentChunks = 0
    private var telemetryMaxChunksPerFrame = 0
    private var telemetrySendLatencySamples = 0
    private var telemetrySendLatencyTotalMs: Double = 0
    private var telemetrySendLatencyMaxMs: Double = 0
    private var telemetryQueuedFramesMax = 0
    private var telemetryQueuedFrameAgeMaxMs: Double = 0
    private var telemetryDequeuedFrameAgeMaxMs: Double = 0
    private var telemetryInFlightVideoSendsMax = 0
    private var telemetryContentBacklogBytesMax = 0
    private var telemetryContentBacklogFullEvents = 0
    private var telemetryPaceWakeDrains = 0
    private var telemetryBoundedCadenceCatchUpFrames = 0
    private var telemetryStaleQueueCatchUpFrames = 0
    private var telemetryScheduleBudgetMax = 0
    private var telemetryMissedCadenceSlotsMax = 0
    private var telemetryScheduleGapMaxMs: Double = 0
    private var telemetryScheduleJitterMaxMs: Double = 0
    private var telemetryCompletionGapMaxMs: Double = 0
    private var telemetryContentProcessedCallbackGapMaxMs: Double = 0
    private var telemetryContentProcessedActorHopMaxMs: Double = 0
    private var telemetryEncodedToSubmitMaxMs: Double = 0
    private var telemetrySubmitGapMaxMs: Double = 0
    private var telemetryClockFireToDrainMaxMs: Double = 0
    private var telemetryWireBatchSingleFrames = 0
    private var telemetryWireBatchMultiFrames = 0
    private var telemetryWireSingleUnbatchedFrames = 0
    private var lastVideoFrameSubmitTelemetryAt: Date?
    private var lastVideoFrameScheduleTelemetryAt: Date?
    private var lastVideoFrameCompletionTelemetryAt: Date?
    private var lastVideoFrameContentProcessedCallbackAt: Date?
    private var sessionEvidenceReference = "-"
    private var streamOperationEvidenceReference = "-"
    private static let sendQueueOverflowSyncRefreshMinimumInterval: TimeInterval = 2.0
    private static let waitingForSyncFrameRefreshMinimumInterval: TimeInterval = 2.0
    private static let harmfulBackpressurePendingFrameThreshold = 6
    private static let maxInFlightVideoSends = 3
    private static let maxChunkedContentProcessedBacklogFrames = 18
    private static let maxChunkedContentProcessedBacklogBytes = 12 * 256 * 1024
    private static let maxChunkedScreenFrameMessageBytes = 256 * 1024
    private static let maxChunkedVideoFramesPerDrain = 1
    private static let maxChunkedHighFPSVideoFramesPerDrain = 1
    private static let boundedCadenceCatchUpFrameAgeLimitMs: Double = 50
    private static let videoPaceEarlySendTolerance: TimeInterval = 0.0005
    private static let videoCadenceResetThreshold: TimeInterval = 0.250
    private static let maxAudioPayloadsPerDrain = 4
    private static let audioBacklogWarningPayloads = 120
    private static let maxAudioQueuedPayloads = 240
    private static let maxAudioQueuedBytes = 2 * 1024 * 1024

    private var effectiveMaxContentProcessedBacklogFrames: Int {
        usesChunkedScreenFrameWire ? Self.maxChunkedContentProcessedBacklogFrames : Self.maxInFlightVideoSends
    }

    private var effectiveMaxContentProcessedBacklogBytes: Int {
        usesChunkedScreenFrameWire
            ? Self.maxChunkedContentProcessedBacklogBytes
            : maxFramedMessageBytes * Self.maxInFlightVideoSends
    }

    private var contentProcessedBacklogBytes: Int {
        pendingVideoSendCompletions.reduce(0) { $0 + max(0, $1.bytes) }
    }

    private var isContentProcessedBacklogFull: Bool {
        if inFlightVideoSends >= effectiveMaxContentProcessedBacklogFrames {
            return true
        }
        guard usesChunkedScreenFrameWire else { return false }
        return contentProcessedBacklogBytes >= effectiveMaxContentProcessedBacklogBytes
    }

    private var maxVideoFramesPerDrain: Int {
        guard usesChunkedScreenFrameWire else {
            return effectiveMaxContentProcessedBacklogFrames
        }
        return videoSendInterval <= (1.0 / 55.0)
            ? Self.maxChunkedHighFPSVideoFramesPerDrain
            : Self.maxChunkedVideoFramesPerDrain
    }

    private var effectiveVideoCadenceResetThreshold: TimeInterval {
        usesChunkedScreenFrameWire ? max(videoSendInterval * 2, Self.videoPaceEarlySendTolerance) : Self.videoCadenceResetThreshold
    }

    private struct FrameTelemetrySnapshot: Sendable {
        let interval: TimeInterval
        let submittedFrames: Int
        let sentFrames: Int
        let droppedFrames: Int
        let backpressureEvents: Int
        let rawBackpressureEvents: Int
        let orderedThrottleEvents: Int
        let queueBacklogEvents: Int
        let sentBytes: Int
        let chunkedFrames: Int
        let sentChunks: Int
        let maxChunksPerFrame: Int
        let sendLatencySamples: Int
        let averageSendLatencyMs: Double
        let maxSendLatencyMs: Double
        let transport: String
        let queuedFrames: Int
        let queuedFramesMax: Int
        let queuedFrameAgeMaxMs: Double
        let dequeuedFrameAgeMaxMs: Double
        let inFlightVideoSends: Int
        let inFlightVideoSendsMax: Int
        let inFlightVideoSendLimit: Int
        let contentBacklogBytes: Int
        let contentBacklogBytesMax: Int
        let contentBacklogByteLimit: Int
        let contentBacklogFullEvents: Int
        let oldestContentBacklogMs: Double
        let videoSendIntervalMs: Double
        let maxVideoFramesPerDrain: Int
        let scheduleBudgetMax: Int
        let missedCadenceSlotsMax: Int
        let paceWakeDrains: Int
        let boundedCadenceCatchUpFrames: Int
        let staleQueueCatchUpFrames: Int
        let scheduleGapMaxMs: Double
        let scheduleJitterMaxMs: Double
        let completionGapMaxMs: Double
        let contentProcessedCallbackGapMaxMs: Double
        let contentProcessedActorHopMaxMs: Double
        let encodedToSubmitMaxMs: Double
        let submitGapMaxMs: Double
        let clockFireToDrainMaxMs: Double
        let wireBatchSingleFrames: Int
        let wireBatchMultiFrames: Int
        let wireSingleUnbatchedFrames: Int
        let waitingForSyncFrame: Bool
    }

    private enum FramedMessageSendMode: String, Sendable {
        case empty
        case singleUnbatched = "single-unbatched"
        case batchSingle = "batch-single"
        case batchMulti = "batch-multi"
    }

    init(
        peerId: String,
        connection: NWConnection,
        maxFramedMessageBytes: Int,
        secureEnvelopeSendSequencer: RemoteControlSecureEnvelopeSendSequencer = RemoteControlSecureEnvelopeSendSequencer()
    ) {
        self.peerId = peerId
        self.connection = connection
        self.maxFramedMessageBytes = maxFramedMessageBytes
        self.secureEnvelopeSendSequencer = secureEnvelopeSendSequencer
    }

    func updateTransportState(
        requestedStreamConfiguration: RemoteDesktopStreamConfiguration?,
        sessionKeys: SessionKeys?,
        allowsInsecureLegacy: Bool
    ) {
        sessionEvidenceReference = sessionKeys.flatMap {
            P2PEvidenceReference.sessionIncarnation(
                sessionID: $0.sessionId,
                transcriptHash: $0.transcriptHash
            )
        } ?? "-"
        streamOperationEvidenceReference = requestedStreamConfiguration?
            .streamConfigurationTransaction
            .map { P2PEvidenceReference.transaction($0.id) } ?? "-"
        streamingEnabled = requestedStreamConfiguration.map { !$0.isStopRequest } ?? false
        frameTransport = requestedStreamConfiguration?.screenFrameTransport == "sbrf-v1"
            ? .binaryWire
            : .legacyJSON
        usesChunkedScreenFrameWire = frameTransport == .binaryWire
            && requestedStreamConfiguration?.screenChannelWireFormat
                == RemoteDesktopStreamConfiguration.screenChannelWireFormatSBC2ChunkedV1
        if let requestedFPS = requestedStreamConfiguration?.targetFrameRate,
           requestedFPS > 0 {
            videoSendInterval = 1.0 / Double(max(1, min(requestedFPS, 240)))
        } else {
            videoSendInterval = 1.0 / 60.0
        }
        damageTrackingEnabled = requestedStreamConfiguration?.damageTrackingEnabled ?? true
        self.allowsInsecureLegacy = allowsInsecureLegacy
        secureEnvelopeSendSequencer.resetIfSessionChanged(sessionId: sessionKeys?.sessionId)
        self.sessionKeys = sessionKeys
        if !damageTrackingEnabled {
            latestDamageReport = nil
        }
        if !streamingEnabled {
            noteFrameTelemetry(dropped: frameQueue.pendingFrames.count)
            frameQueue.clear()
            logAudioQueueClearedIfNeeded(reason: "stream-stop")
            clearAudioPayloadQueue(keepingCapacity: true)
            latestDamageReport = nil
            videoSendGeneration &+= 1
            inFlightVideoSends = 0
            pendingVideoSendCompletions.removeAll(keepingCapacity: true)
            lastVideoFrameScheduledAt = .distantPast
            lastVideoFrameSubmitTelemetryAt = nil
            lastVideoFrameScheduleTelemetryAt = nil
            lastVideoFrameCompletionTelemetryAt = nil
            cancelVideoPaceWake()
            waitingForSyncSince = nil
            audioDrainGeneration &+= 1
            audioDrainTask?.cancel()
            audioDrainTask = nil
            sendingAudio = false
            syncRecoveryTask?.cancel()
            syncRecoveryTask = nil
        }
    }

    func submitDamageReport(_ report: RemoteDesktopDamageReport) async {
        guard !closed, streamingEnabled, damageTrackingEnabled else {
            latestDamageReport = nil
            return
        }
        latestDamageReport = report
        if usesChunkedScreenFrameWire {
            scheduleVideoPaceWakeIfNeeded()
            return
        }
        await drainIfNeeded()
    }

    func submitFrame(_ frame: ScreenData) async {
        guard !closed, streamingEnabled else { return }
        let submittedAt = Date()
        noteVideoFrameSubmitted(frame, at: submittedAt)
        if !usesChunkedScreenFrameWire,
           shouldDrainPendingVideoBeforeEnqueue(now: submittedAt) {
            await drainIfNeeded()
        }
        let pendingFramesBeforeEnqueue = frameQueue.pendingFrames.count
        let contentBacklogFull = isContentProcessedBacklogFull
        let queueBacklog = pendingFramesBeforeEnqueue >= Self.harmfulBackpressurePendingFrameThreshold
        let rawBackpressured = pendingFramesBeforeEnqueue > 0 || frameQueue.waitingForSyncFrame || contentBacklogFull
        let enqueueResult = frameQueue.enqueue(frame)
        let orderedThrottle = contentBacklogFull
            && !frameQueue.waitingForSyncFrame
            && !queueBacklog
            && enqueueResult == .enqueued
        let wasBackpressured = frameQueue.waitingForSyncFrame
            || queueBacklog
        noteFrameTelemetry(
            submitted: 1,
            dropped: droppedFrameCount(for: enqueueResult, pendingFramesBeforeEnqueue: pendingFramesBeforeEnqueue),
            backpressure: wasBackpressured || enqueueResult != .enqueued ? 1 : 0,
            rawBackpressure: rawBackpressured || enqueueResult != .enqueued ? 1 : 0,
            orderedThrottle: orderedThrottle ? 1 : 0,
            queueBacklog: queueBacklog ? 1 : 0,
            contentBacklogFull: contentBacklogFull ? 1 : 0
        )
        if enqueueResult == .droppedPredictiveFrameNeedsSyncRefresh {
            requestSyncRefreshIfNeeded(
                reason: "send-queue-overflow",
                minimumInterval: Self.sendQueueOverflowSyncRefreshMinimumInterval
            )
        }
        updateSyncRecoveryState()
        if usesChunkedScreenFrameWire {
            scheduleVideoPaceWakeIfNeeded()
            return
        }
        await drainIfNeeded()
        scheduleVideoPaceWakeIfNeeded()
    }

    func submitAudioPayload(_ plaintext: Data) async {
        guard !closed, streamingEnabled else {
            logAudioQueueClearedIfNeeded(reason: closed ? "closed" : "streaming-disabled")
            return
        }
        guard plaintext.count <= maxFramedMessageBytes else {
            Logger(subsystem: "com.skybridge.compass", category: "RemoteControl")
                .error(
                    "⛔️ 远控音频块超出安全帧上限，已拒绝发送: peer=\(self.peerId, privacy: .public) bytes=\(plaintext.count, privacy: .public) max=\(self.maxFramedMessageBytes, privacy: .public)"
                )
            RemoteControlSmokeStatusWriter.append(
                "mac-remote-audio-tx peer=\(peerId) result=rejected reason=oversize bytes=\(plaintext.count) max=\(maxFramedMessageBytes)"
            )
            return
        }
        let queuedPayloadsAfterAppend = audioPayloadQueue.count + 1
        let queuedBytesAfterAppend = audioPayloadQueuedBytes + plaintext.count
        guard queuedPayloadsAfterAppend <= Self.maxAudioQueuedPayloads,
              queuedBytesAfterAppend <= Self.maxAudioQueuedBytes else {
            Logger(subsystem: "com.skybridge.compass", category: "RemoteControl")
                .error(
                    "⛔️ 远控音频发送队列超过硬上限，已 fail-closed: peer=\(self.peerId, privacy: .public) queued=\(self.audioPayloadQueue.count, privacy: .public) queuedBytes=\(self.audioPayloadQueuedBytes, privacy: .public) nextBytes=\(plaintext.count, privacy: .public) maxQueued=\(Self.maxAudioQueuedPayloads, privacy: .public) maxBytes=\(Self.maxAudioQueuedBytes, privacy: .public)"
                )
            RemoteControlSmokeStatusWriter.append(
                "mac-remote-audio-tx peer=\(peerId) result=failed-closed reason=audio-queue-hard-limit queued=\(audioPayloadQueue.count) queuedBytes=\(audioPayloadQueuedBytes) nextBytes=\(plaintext.count) maxQueued=\(Self.maxAudioQueuedPayloads) maxBytes=\(Self.maxAudioQueuedBytes)"
            )
            closed = true
            audioDrainGeneration &+= 1
            audioDrainTask?.cancel()
            audioDrainTask = nil
            sendingAudio = false
            logAudioQueueClearedIfNeeded(reason: "audio-queue-hard-limit")
            clearAudioPayloadQueue(keepingCapacity: false)
            return
        }
        audioPayloadQueue.append(plaintext)
        audioPayloadQueuedBytes += plaintext.count
        noteAudioTelemetry(submitted: 1)
        noteAudioBacklogIfNeeded()
        scheduleAudioDrainIfNeeded()
    }

    func setSyncRefreshHandler(_ handler: (@Sendable () -> Void)?) {
        onNeedsSyncRefresh = handler
    }

    func close() {
        closed = true
        noteFrameTelemetry(dropped: frameQueue.pendingFrames.count)
        frameQueue.clear()
        logAudioQueueClearedIfNeeded(reason: "pump-close")
        clearAudioPayloadQueue(keepingCapacity: false)
        latestDamageReport = nil
        videoSendGeneration &+= 1
        inFlightVideoSends = 0
        pendingVideoSendCompletions.removeAll(keepingCapacity: false)
            lastVideoFrameScheduledAt = .distantPast
            lastVideoFrameSubmitTelemetryAt = nil
            lastVideoFrameScheduleTelemetryAt = nil
            lastVideoFrameCompletionTelemetryAt = nil
            lastVideoFrameContentProcessedCallbackAt = nil
            cancelVideoPaceWake()
            onNeedsSyncRefresh = nil
            waitingForSyncSince = nil
        audioDrainGeneration &+= 1
        audioDrainTask?.cancel()
        audioDrainTask = nil
        sendingAudio = false
        syncRecoveryTask?.cancel()
        syncRecoveryTask = nil
    }

    func healthSnapshot() -> HealthSnapshot {
        HealthSnapshot(
            lastSentFrameAt: lastSentFrameAt,
            waitingForSyncFrame: frameQueue.waitingForSyncFrame,
            waitingForSyncSince: waitingForSyncSince
        )
    }

    private func droppedFrameCount(
        for result: RemoteScreenFrameQueueEnqueueResult,
        pendingFramesBeforeEnqueue: Int
    ) -> Int {
        switch result {
        case .enqueued:
            return 0
        case .droppedStaleIndependentFrame:
            return max(1, pendingFramesBeforeEnqueue - frameQueue.maxQueuedFrames + 1)
        case .droppedPredictiveFrameWaitingForSync:
            return 1
        case .droppedPredictiveFrameNeedsSyncRefresh:
            return max(1, pendingFramesBeforeEnqueue + 1)
        }
    }

    private func noteFrameTelemetry(
        submitted: Int = 0,
        sent: Int = 0,
        dropped: Int = 0,
        backpressure: Int = 0,
        rawBackpressure: Int = 0,
        orderedThrottle: Int = 0,
        queueBacklog: Int = 0,
        sentBytes: Int = 0,
        chunkedFrames: Int = 0,
        sentChunks: Int = 0,
        maxChunksPerFrame: Int = 0,
        sendLatencyMs: Double? = nil,
        contentBacklogFull: Int = 0,
        staleQueueCatchUp: Int = 0,
        dequeuedFrameAgeMs: Double? = nil,
        sendMode: FramedMessageSendMode? = nil
    ) {
        telemetrySubmittedFrames += max(0, submitted)
        telemetrySentFrames += max(0, sent)
        telemetryDroppedFrames += max(0, dropped)
        telemetryBackpressureEvents += max(0, backpressure)
        telemetryRawBackpressureEvents += max(0, rawBackpressure)
        telemetryOrderedThrottleEvents += max(0, orderedThrottle)
        telemetryQueueBacklogEvents += max(0, queueBacklog)
        telemetrySentBytes += max(0, sentBytes)
        telemetryChunkedFrames += max(0, chunkedFrames)
        telemetrySentChunks += max(0, sentChunks)
        telemetryMaxChunksPerFrame = max(telemetryMaxChunksPerFrame, max(0, maxChunksPerFrame))
        telemetryQueuedFramesMax = max(telemetryQueuedFramesMax, frameQueue.pendingFrames.count)
        telemetryQueuedFrameAgeMaxMs = max(telemetryQueuedFrameAgeMaxMs, queuedFrameAgeMaxMs(now: Date()))
        telemetryInFlightVideoSendsMax = max(telemetryInFlightVideoSendsMax, inFlightVideoSends)
        telemetryContentBacklogBytesMax = max(
            telemetryContentBacklogBytesMax,
            contentProcessedBacklogBytes
        )
        telemetryContentBacklogFullEvents += max(0, contentBacklogFull)
        telemetryStaleQueueCatchUpFrames += max(0, staleQueueCatchUp)
        if let dequeuedFrameAgeMs {
            telemetryDequeuedFrameAgeMaxMs = max(telemetryDequeuedFrameAgeMaxMs, dequeuedFrameAgeMs)
        }
        if sent > 0, let sendMode {
            switch sendMode {
            case .empty:
                break
            case .singleUnbatched:
                telemetryWireSingleUnbatchedFrames += sent
            case .batchSingle:
                telemetryWireBatchSingleFrames += sent
            case .batchMulti:
                telemetryWireBatchMultiFrames += sent
            }
        }
        if let sendLatencyMs {
            telemetrySendLatencySamples += 1
            telemetrySendLatencyTotalMs += max(0, sendLatencyMs)
            telemetrySendLatencyMaxMs = max(telemetrySendLatencyMaxMs, sendLatencyMs)
        }
        emitFrameTelemetryIfNeeded()
    }

    private func emitFrameTelemetryIfNeeded(now: Date = Date()) {
        let interval = now.timeIntervalSince(frameTelemetryWindowStartedAt)
        guard interval >= 1 else { return }
        let averageLatency = telemetrySendLatencySamples > 0
            ? telemetrySendLatencyTotalMs / Double(telemetrySendLatencySamples)
            : 0
        let snapshot = FrameTelemetrySnapshot(
            interval: interval,
            submittedFrames: telemetrySubmittedFrames,
            sentFrames: telemetrySentFrames,
            droppedFrames: telemetryDroppedFrames,
            backpressureEvents: telemetryBackpressureEvents,
            rawBackpressureEvents: telemetryRawBackpressureEvents,
            orderedThrottleEvents: telemetryOrderedThrottleEvents,
            queueBacklogEvents: telemetryQueueBacklogEvents,
            sentBytes: telemetrySentBytes,
            chunkedFrames: telemetryChunkedFrames,
            sentChunks: telemetrySentChunks,
            maxChunksPerFrame: telemetryMaxChunksPerFrame,
            sendLatencySamples: telemetrySendLatencySamples,
            averageSendLatencyMs: averageLatency,
            maxSendLatencyMs: telemetrySendLatencyMaxMs,
            transport: frameTelemetryTransportName,
            queuedFrames: frameQueue.pendingFrames.count,
            queuedFramesMax: telemetryQueuedFramesMax,
            queuedFrameAgeMaxMs: telemetryQueuedFrameAgeMaxMs,
            dequeuedFrameAgeMaxMs: telemetryDequeuedFrameAgeMaxMs,
            inFlightVideoSends: inFlightVideoSends,
            inFlightVideoSendsMax: telemetryInFlightVideoSendsMax,
            inFlightVideoSendLimit: effectiveMaxContentProcessedBacklogFrames,
            contentBacklogBytes: contentProcessedBacklogBytes,
            contentBacklogBytesMax: telemetryContentBacklogBytesMax,
            contentBacklogByteLimit: effectiveMaxContentProcessedBacklogBytes,
            contentBacklogFullEvents: telemetryContentBacklogFullEvents,
            oldestContentBacklogMs: oldestContentProcessedBacklogAgeMs(now: now),
            videoSendIntervalMs: videoSendInterval * 1_000,
            maxVideoFramesPerDrain: maxVideoFramesPerDrain,
            scheduleBudgetMax: telemetryScheduleBudgetMax,
            missedCadenceSlotsMax: telemetryMissedCadenceSlotsMax,
            paceWakeDrains: telemetryPaceWakeDrains,
            boundedCadenceCatchUpFrames: telemetryBoundedCadenceCatchUpFrames,
            staleQueueCatchUpFrames: telemetryStaleQueueCatchUpFrames,
            scheduleGapMaxMs: telemetryScheduleGapMaxMs,
            scheduleJitterMaxMs: telemetryScheduleJitterMaxMs,
            completionGapMaxMs: telemetryCompletionGapMaxMs,
            contentProcessedCallbackGapMaxMs: telemetryContentProcessedCallbackGapMaxMs,
            contentProcessedActorHopMaxMs: telemetryContentProcessedActorHopMaxMs,
            encodedToSubmitMaxMs: telemetryEncodedToSubmitMaxMs,
            submitGapMaxMs: telemetrySubmitGapMaxMs,
            clockFireToDrainMaxMs: telemetryClockFireToDrainMaxMs,
            wireBatchSingleFrames: telemetryWireBatchSingleFrames,
            wireBatchMultiFrames: telemetryWireBatchMultiFrames,
            wireSingleUnbatchedFrames: telemetryWireSingleUnbatchedFrames,
            waitingForSyncFrame: frameQueue.waitingForSyncFrame
        )
        frameTelemetryWindowStartedAt = now
        telemetrySubmittedFrames = 0
        telemetrySentFrames = 0
        telemetryDroppedFrames = 0
        telemetryBackpressureEvents = 0
        telemetryRawBackpressureEvents = 0
        telemetryOrderedThrottleEvents = 0
        telemetryQueueBacklogEvents = 0
        telemetrySentBytes = 0
        telemetryChunkedFrames = 0
        telemetrySentChunks = 0
        telemetryMaxChunksPerFrame = 0
        telemetrySendLatencySamples = 0
        telemetrySendLatencyTotalMs = 0
        telemetrySendLatencyMaxMs = 0
        telemetryQueuedFramesMax = 0
        telemetryQueuedFrameAgeMaxMs = 0
        telemetryDequeuedFrameAgeMaxMs = 0
        telemetryInFlightVideoSendsMax = 0
        telemetryContentBacklogBytesMax = 0
        telemetryContentBacklogFullEvents = 0
        telemetryPaceWakeDrains = 0
        telemetryBoundedCadenceCatchUpFrames = 0
        telemetryStaleQueueCatchUpFrames = 0
        telemetryScheduleBudgetMax = 0
        telemetryMissedCadenceSlotsMax = 0
        telemetryScheduleGapMaxMs = 0
        telemetryScheduleJitterMaxMs = 0
        telemetryCompletionGapMaxMs = 0
        telemetryContentProcessedCallbackGapMaxMs = 0
        telemetryContentProcessedActorHopMaxMs = 0
        telemetryEncodedToSubmitMaxMs = 0
        telemetrySubmitGapMaxMs = 0
        telemetryClockFireToDrainMaxMs = 0
        telemetryWireBatchSingleFrames = 0
        telemetryWireBatchMultiFrames = 0
        telemetryWireSingleUnbatchedFrames = 0
        logFrameTelemetry(snapshot)
    }

    private func noteVideoFrameSubmitted(_ frame: ScreenData, at submittedAt: Date) {
        if let previous = lastVideoFrameSubmitTelemetryAt {
            let gapMs = max(0, submittedAt.timeIntervalSince(previous) * 1_000)
            telemetrySubmitGapMaxMs = max(telemetrySubmitGapMaxMs, gapMs)
        }
        lastVideoFrameSubmitTelemetryAt = submittedAt
        telemetryEncodedToSubmitMaxMs = max(
            telemetryEncodedToSubmitMaxMs,
            frameAgeMs(frame, now: submittedAt)
        )
    }

    private func noteVideoFrameScheduled(at scheduledAt: Date) {
        if let previous = lastVideoFrameScheduleTelemetryAt {
            let gapMs = max(0, scheduledAt.timeIntervalSince(previous) * 1_000)
            telemetryScheduleGapMaxMs = max(telemetryScheduleGapMaxMs, gapMs)
            let expectedMs = videoSendInterval * 1_000
            telemetryScheduleJitterMaxMs = max(telemetryScheduleJitterMaxMs, abs(gapMs - expectedMs))
        }
        lastVideoFrameScheduleTelemetryAt = scheduledAt
    }

    private func noteVideoFrameCompleted(at completedAt: Date, contentProcessedAt: Date) {
        if let previous = lastVideoFrameCompletionTelemetryAt {
            let gapMs = max(0, completedAt.timeIntervalSince(previous) * 1_000)
            telemetryCompletionGapMaxMs = max(telemetryCompletionGapMaxMs, gapMs)
        }
        lastVideoFrameCompletionTelemetryAt = completedAt
        if let previousCallback = lastVideoFrameContentProcessedCallbackAt {
            let gapMs = max(0, contentProcessedAt.timeIntervalSince(previousCallback) * 1_000)
            telemetryContentProcessedCallbackGapMaxMs = max(
                telemetryContentProcessedCallbackGapMaxMs,
                gapMs
            )
        }
        lastVideoFrameContentProcessedCallbackAt = contentProcessedAt
        telemetryContentProcessedActorHopMaxMs = max(
            telemetryContentProcessedActorHopMaxMs,
            max(0, completedAt.timeIntervalSince(contentProcessedAt) * 1_000)
        )
    }

    private func noteVideoPaceClockDrain(firedAt: Date, drainStartedAt: Date) {
        telemetryClockFireToDrainMaxMs = max(
            telemetryClockFireToDrainMaxMs,
            max(0, drainStartedAt.timeIntervalSince(firedAt) * 1_000)
        )
    }

    private func noteVideoScheduleBudget(
        _ budget: Int,
        elapsedCadenceSlots: Int,
        schedulableCadenceSlots: Int? = nil
    ) {
        telemetryScheduleBudgetMax = max(telemetryScheduleBudgetMax, max(0, budget))
        let missedReference = schedulableCadenceSlots ?? elapsedCadenceSlots
        telemetryMissedCadenceSlotsMax = max(
            telemetryMissedCadenceSlotsMax,
            max(0, missedReference - budget)
        )
    }

    private func noteBoundedCadenceCatchUpFrame() {
        telemetryBoundedCadenceCatchUpFrames += 1
    }

    private func queuedFrameAgeMaxMs(now: Date) -> Double {
        frameQueue.pendingFrames.reduce(0) { max($0, frameAgeMs($1, now: now)) }
    }

    private func frameAgeMs(_ frame: ScreenData, now: Date) -> Double {
        guard frame.timestamp > 1_000_000_000 else { return 0 }
        return max(0, (now.timeIntervalSince1970 - frame.timestamp) * 1_000)
    }

    private var frameTelemetryTransportName: String {
        switch frameTransport {
        case .legacyJSON:
            return "legacy-json"
        case .binaryWire:
            return usesChunkedScreenFrameWire
                ? RemoteDesktopStreamConfiguration.screenChannelWireFormatSBC2ChunkedV1
                : "sbrf-v1"
        }
    }

    private func logFrameTelemetry(_ snapshot: FrameTelemetrySnapshot) {
        let interval = max(snapshot.interval, 0.001)
        let sampleMs = Int((snapshot.interval * 1000).rounded())
        let submittedFPS = String(format: "%.1f", Double(snapshot.submittedFrames) / interval)
        let sentFPS = String(format: "%.1f", Double(snapshot.sentFrames) / interval)
        let averageLatency = String(format: "%.1f", snapshot.averageSendLatencyMs)
        let maxLatency = String(format: "%.1f", snapshot.maxSendLatencyMs)
        let paceMs = String(format: "%.2f", snapshot.videoSendIntervalMs)
        let scheduleGapMaxMs = String(format: "%.1f", snapshot.scheduleGapMaxMs)
        let scheduleJitterMaxMs = String(format: "%.1f", snapshot.scheduleJitterMaxMs)
        let completionGapMaxMs = String(format: "%.1f", snapshot.completionGapMaxMs)
        let contentCallbackGapMaxMs = String(format: "%.1f", snapshot.contentProcessedCallbackGapMaxMs)
        let contentActorHopMaxMs = String(format: "%.1f", snapshot.contentProcessedActorHopMaxMs)
        let encodedToSubmitMaxMs = String(format: "%.1f", snapshot.encodedToSubmitMaxMs)
        let submitGapMaxMs = String(format: "%.1f", snapshot.submitGapMaxMs)
        let clockFireToDrainMaxMs = String(format: "%.1f", snapshot.clockFireToDrainMaxMs)
        let chunkSendMode: String
        let sendModeKinds = [
            snapshot.wireSingleUnbatchedFrames,
            snapshot.wireBatchSingleFrames,
            snapshot.wireBatchMultiFrames
        ].filter { $0 > 0 }.count
        if sendModeKinds > 1 {
            chunkSendMode = "batch-mixed"
        } else if snapshot.wireSingleUnbatchedFrames > 0 {
            chunkSendMode = FramedMessageSendMode.singleUnbatched.rawValue
        } else if snapshot.wireBatchMultiFrames > 0 {
            chunkSendMode = FramedMessageSendMode.batchMulti.rawValue
        } else if snapshot.wireBatchSingleFrames > 0 {
            chunkSendMode = FramedMessageSendMode.batchSingle.rawValue
        } else {
            chunkSendMode = FramedMessageSendMode.empty.rawValue
        }
        logger.info(
            """
            📊 Remote frame tx telemetry: peer=\(self.peerId, privacy: .public) \
            transport=\(snapshot.transport, privacy: .public) \
            sampleMs=\(sampleMs, privacy: .public) \
            submittedFPS=\(submittedFPS, privacy: .public) \
            sentFPS=\(sentFPS, privacy: .public) \
            submitted=\(snapshot.submittedFrames, privacy: .public) \
            sent=\(snapshot.sentFrames, privacy: .public) \
            dropped=\(snapshot.droppedFrames, privacy: .public) \
            backpressure=\(snapshot.backpressureEvents, privacy: .public) \
            rawBackpressure=\(snapshot.rawBackpressureEvents, privacy: .public) \
            orderedThrottle=\(snapshot.orderedThrottleEvents, privacy: .public) \
            queueBacklog=\(snapshot.queueBacklogEvents, privacy: .public) \
            bytes=\(snapshot.sentBytes, privacy: .public) \
            chunkCapBytes=\(Self.maxChunkedScreenFrameMessageBytes, privacy: .public) \
            chunkSend=\(chunkSendMode, privacy: .public) \
            wireBatchSingleFrames=\(snapshot.wireBatchSingleFrames, privacy: .public) \
            wireBatchMultiFrames=\(snapshot.wireBatchMultiFrames, privacy: .public) \
            wireSingleUnbatchedFrames=\(snapshot.wireSingleUnbatchedFrames, privacy: .public) \
            chunkedFrames=\(snapshot.chunkedFrames, privacy: .public) \
            sentChunks=\(snapshot.sentChunks, privacy: .public) \
            maxChunksPerFrame=\(snapshot.maxChunksPerFrame, privacy: .public) \
            avgSendMs=\(averageLatency, privacy: .public) \
            maxSendMs=\(maxLatency, privacy: .public) \
            latencySamples=\(snapshot.sendLatencySamples, privacy: .public) \
            paceMs=\(paceMs, privacy: .public) \
            maxFramesPerDrain=\(snapshot.maxVideoFramesPerDrain, privacy: .public) \
            scheduleBudgetMax=\(snapshot.scheduleBudgetMax, privacy: .public) \
            missedCadenceSlotsMax=\(snapshot.missedCadenceSlotsMax, privacy: .public) \
            scheduleGapMaxMs=\(scheduleGapMaxMs, privacy: .public) \
            scheduleJitterMaxMs=\(scheduleJitterMaxMs, privacy: .public) \
            completionGapMaxMs=\(completionGapMaxMs, privacy: .public) \
            contentCallbackGapMaxMs=\(contentCallbackGapMaxMs, privacy: .public) \
            contentActorHopMaxMs=\(contentActorHopMaxMs, privacy: .public) \
            encodedToSubmitMaxMs=\(encodedToSubmitMaxMs, privacy: .public) \
            submitGapMaxMs=\(submitGapMaxMs, privacy: .public) \
            clockFireToDrainMaxMs=\(clockFireToDrainMaxMs, privacy: .public) \
            catchUp=bounded-cadence-catch-up-no-stale \
            cadenceAnchor=strict-deadline-phase-no-stale \
            writerClock=dispatch-source-userinteractive \
            writerClockStrict=1 \
            sendScheduler=dispatch-clock-only \
            paceWake=\(snapshot.paceWakeDrains, privacy: .public) \
            boundedCadenceCatchUp=\(snapshot.boundedCadenceCatchUpFrames, privacy: .public) \
            staleQueueCatchUp=\(snapshot.staleQueueCatchUpFrames, privacy: .public) \
            inFlight=\(snapshot.inFlightVideoSends, privacy: .public) \
            inFlightMax=\(snapshot.inFlightVideoSendsMax, privacy: .public) \
            inFlightLimit=\(snapshot.inFlightVideoSendLimit, privacy: .public) \
            contentBacklog=\(snapshot.inFlightVideoSends, privacy: .public) \
            contentBacklogMax=\(snapshot.inFlightVideoSendsMax, privacy: .public) \
            contentBacklogLimit=\(snapshot.inFlightVideoSendLimit, privacy: .public) \
            contentBacklogBytes=\(snapshot.contentBacklogBytes, privacy: .public) \
            contentBacklogBytesMax=\(snapshot.contentBacklogBytesMax, privacy: .public) \
            contentBacklogByteLimit=\(snapshot.contentBacklogByteLimit, privacy: .public) \
            contentBacklogFull=\(snapshot.contentBacklogFullEvents, privacy: .public) \
            oldestContentBacklogMs=\(String(format: "%.1f", snapshot.oldestContentBacklogMs), privacy: .public) \
            queueAgeMaxMs=\(String(format: "%.1f", snapshot.queuedFrameAgeMaxMs), privacy: .public) \
            dequeuedAgeMaxMs=\(String(format: "%.1f", snapshot.dequeuedFrameAgeMaxMs), privacy: .public) \
            queued=\(snapshot.queuedFrames, privacy: .public) \
            queuedMax=\(snapshot.queuedFramesMax, privacy: .public) \
            waitingForSync=\(String(snapshot.waitingForSyncFrame), privacy: .public)
            """
        )
        RemoteControlSmokeStatusWriter.append(
            """
            mac-remote-frame-tx peer=\(peerId) session_ref=\(sessionEvidenceReference) stream_ref=\(streamOperationEvidenceReference) transport=\(snapshot.transport) \
            source=encoded-direct-pump \
            sampleMs=\(sampleMs) submittedFPS=\(submittedFPS) sentFPS=\(sentFPS) submitted=\(snapshot.submittedFrames) sent=\(snapshot.sentFrames) \
            dropped=\(snapshot.droppedFrames) backpressure=\(snapshot.backpressureEvents) rawBackpressure=\(snapshot.rawBackpressureEvents) \
            orderedThrottle=\(snapshot.orderedThrottleEvents) queueBacklog=\(snapshot.queueBacklogEvents) \
            bytes=\(snapshot.sentBytes) chunkCapBytes=\(Self.maxChunkedScreenFrameMessageBytes) chunkSend=\(chunkSendMode) \
            wireBatchSingleFrames=\(snapshot.wireBatchSingleFrames) wireBatchMultiFrames=\(snapshot.wireBatchMultiFrames) wireSingleUnbatchedFrames=\(snapshot.wireSingleUnbatchedFrames) \
            chunkedFrames=\(snapshot.chunkedFrames) sentChunks=\(snapshot.sentChunks) maxChunksPerFrame=\(snapshot.maxChunksPerFrame) \
            avgSendMs=\(averageLatency) maxSendMs=\(maxLatency) \
            paceMs=\(paceMs) maxFramesPerDrain=\(snapshot.maxVideoFramesPerDrain) scheduleBudgetMax=\(snapshot.scheduleBudgetMax) missedCadenceSlotsMax=\(snapshot.missedCadenceSlotsMax) scheduleGapMaxMs=\(scheduleGapMaxMs) scheduleJitterMaxMs=\(scheduleJitterMaxMs) completionGapMaxMs=\(completionGapMaxMs) \
            contentCallbackGapMaxMs=\(contentCallbackGapMaxMs) contentActorHopMaxMs=\(contentActorHopMaxMs) \
            encodedToSubmitMaxMs=\(encodedToSubmitMaxMs) submitGapMaxMs=\(submitGapMaxMs) \
            clockFireToDrainMaxMs=\(clockFireToDrainMaxMs) \
            catchUp=bounded-cadence-catch-up-no-stale \
            cadenceAnchor=strict-deadline-phase-no-stale \
            writerClock=dispatch-source-userinteractive \
            writerClockStrict=1 \
            sendScheduler=dispatch-clock-only \
            paceWake=\(snapshot.paceWakeDrains) \
            boundedCadenceCatchUp=\(snapshot.boundedCadenceCatchUpFrames) \
            staleQueueCatchUp=\(snapshot.staleQueueCatchUpFrames) \
            inFlight=\(snapshot.inFlightVideoSends) inFlightMax=\(snapshot.inFlightVideoSendsMax) inFlightLimit=\(snapshot.inFlightVideoSendLimit) \
            contentBacklog=\(snapshot.inFlightVideoSends) contentBacklogMax=\(snapshot.inFlightVideoSendsMax) contentBacklogLimit=\(snapshot.inFlightVideoSendLimit) \
            contentBacklogBytes=\(snapshot.contentBacklogBytes) contentBacklogBytesMax=\(snapshot.contentBacklogBytesMax) contentBacklogByteLimit=\(snapshot.contentBacklogByteLimit) \
            contentBacklogFull=\(snapshot.contentBacklogFullEvents) oldestContentBacklogMs=\(String(format: "%.1f", snapshot.oldestContentBacklogMs)) \
            queueAgeMaxMs=\(String(format: "%.1f", snapshot.queuedFrameAgeMaxMs)) dequeuedAgeMaxMs=\(String(format: "%.1f", snapshot.dequeuedFrameAgeMaxMs)) \
            queued=\(snapshot.queuedFrames) queuedMax=\(snapshot.queuedFramesMax) waitingForSync=\(snapshot.waitingForSyncFrame)
            """
        )
    }

    private func oldestContentProcessedBacklogAgeMs(now: Date) -> Double {
        guard let oldest = pendingVideoSendCompletions.min(by: { $0.startedAt < $1.startedAt }) else {
            return 0
        }
        return max(0, now.timeIntervalSince(oldest.startedAt) * 1_000)
    }

    private func drainIfNeeded(maxVideoFramesToSchedule requestedBudget: Int? = nil) async {
        guard streamingEnabled else { return }
        guard !sending else { return }
        sending = true
        defer { sending = false }
        let scheduleBudget = requestedBudget ?? videoScheduleBudget()
        var remainingVideoFrameBudget = max(0, scheduleBudget)
        let boundedCadenceCatchUpBudgetActive = usesChunkedScreenFrameWire && scheduleBudget > 1
        let staleQueueCatchUpBudgetActive = false

        while !closed, remainingVideoFrameBudget > 0 {
            guard streamingEnabled else {
                frameQueue.clear()
                clearAudioPayloadQueue(keepingCapacity: true)
                latestDamageReport = nil
                return
            }

            guard canScheduleVideoFrameSend else { return }
            guard !frameQueue.pendingFrames.isEmpty else { return }
            let isStaleQueueCatchUpFrame = staleQueueCatchUpBudgetActive
                && remainingVideoFrameBudget < scheduleBudget
            let isBoundedCadenceCatchUpFrame = boundedCadenceCatchUpBudgetActive
                && remainingVideoFrameBudget < scheduleBudget
            let now = Date()
            if isBoundedCadenceCatchUpFrame,
               !isNextVideoFrameFreshForBoundedCadenceCatchUp(now: now) {
                scheduleVideoPaceWakeIfNeeded()
                return
            }
            if !isStaleQueueCatchUpFrame, !isBoundedCadenceCatchUpFrame, videoPaceWakeDelay(from: now) > 0 {
                scheduleVideoPaceWakeIfNeeded()
                return
            }
            guard let nextFrame = frameQueue.dequeue() else { return }
            noteFrameTelemetry(dequeuedFrameAgeMs: frameAgeMs(nextFrame, now: Date()))

            do {
                if damageTrackingEnabled,
                   let report = latestDamageReport {
                    latestDamageReport = nil
                try await sendControlPayload(report, type: .damageReport)
                }

                let payload = try makeScreenPayload(for: nextFrame)
                guard payload.count <= maxFramedMessageBytes else {
                    noteFrameTelemetry(dropped: 1)
                    logger.warning(
                        """
                        ⚠️ 已丢弃超限远控屏幕帧: peer=\(self.peerId, privacy: .public) \
                        bytes=\(payload.count, privacy: .public) \
                        max=\(self.maxFramedMessageBytes, privacy: .public) \
                        format=\(nextFrame.format ?? "unknown", privacy: .public) \
                        resolution=\(nextFrame.width, privacy: .public)x\(nextFrame.height, privacy: .public)
                        """
                    )
                    continue
                }

                let payloadBytes = payload.count
                try scheduleVideoFrameSend(
                    payload,
                    payloadBytes: payloadBytes,
                    cadenceAnchorMode: isStaleQueueCatchUpFrame ? .staleQueueCatchUp : .normal
                )
                if isStaleQueueCatchUpFrame {
                    noteFrameTelemetry(staleQueueCatchUp: 1)
                }
                if isBoundedCadenceCatchUpFrame {
                    noteBoundedCadenceCatchUpFrame()
                }
                remainingVideoFrameBudget -= 1
            } catch {
                noteFrameTelemetry(dropped: 1)
                logger.error(
                    "❌ 发送屏幕数据失败: peer=\(self.peerId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                break
            }
        }
    }

    private func isNextVideoFrameFreshForBoundedCadenceCatchUp(now: Date) -> Bool {
        guard usesChunkedScreenFrameWire,
              let nextFrame = frameQueue.pendingFrames.first else {
            return false
        }
        return frameAgeMs(nextFrame, now: now) <= Self.boundedCadenceCatchUpFrameAgeLimitMs
    }

    private enum VideoCadenceAnchorMode {
        case normal
        case staleQueueCatchUp
    }

    private func scheduleVideoFrameSend(
        _ plaintext: Data,
        payloadBytes: Int,
        cadenceAnchorMode: VideoCadenceAnchorMode = .normal
    ) throws {
        let outboundData = try makeOutboundRemoteFrame(plaintext, packetType: .screen)
        let wireMessages = try makeOutboundScreenWireMessages(from: outboundData)
        let usedChunkedScreenWire = usesChunkedScreenFrameWire && frameTransport == .binaryWire
        let sendMode = Self.framedMessageSendMode(
            messageCount: wireMessages.count,
            forceBatch: usedChunkedScreenWire
        )
        let queuedWireBytes = wireMessages.reduce(0) { total, message in
            total + message.count + MemoryLayout<UInt32>.size
        }
        inFlightVideoSends += 1
        let sendCompletionId = nextVideoSendCompletionIdentifier()
        let generation = videoSendGeneration
        let sendStartedAt = Date()
        noteVideoFrameScheduled(at: sendStartedAt)
        pendingVideoSendCompletions.append(
            PendingVideoSendCompletion(
                id: sendCompletionId,
                startedAt: sendStartedAt,
                bytes: queuedWireBytes
            )
        )
        switch cadenceAnchorMode {
        case .normal:
            lastVideoFrameScheduledAt = nextVideoFrameCadenceAnchor(for: sendStartedAt)
        case .staleQueueCatchUp:
            lastVideoFrameScheduledAt = sendStartedAt
        }
        telemetryInFlightVideoSendsMax = max(telemetryInFlightVideoSendsMax, inFlightVideoSends)
        Self.sendFramedMessages(
            wireMessages,
            over: connection,
            mode: sendMode
        ) { [weak self] error in
            let contentProcessedAt = Date()
            Task {
                await self?.completeVideoFrameSend(
                    sendCompletionId: sendCompletionId,
                    generation: generation,
                    payloadBytes: payloadBytes,
                    wireMessageCount: wireMessages.count,
                    usedChunkedScreenWire: usedChunkedScreenWire,
                    sendMode: sendMode,
                    sendStartedAt: sendStartedAt,
                    contentProcessedAt: contentProcessedAt,
                    error: error
                )
            }
        }
    }

    private func nextVideoSendCompletionIdentifier() -> UInt64 {
        let id = nextVideoSendCompletionId
        nextVideoSendCompletionId &+= 1
        if nextVideoSendCompletionId == 0 {
            nextVideoSendCompletionId = 1
        }
        return id
    }

    private func makeOutboundScreenWireMessages(from outboundData: Data) throws -> [Data] {
        guard usesChunkedScreenFrameWire, frameTransport == .binaryWire else {
            return [outboundData]
        }

        let maxPayloadBytes = Self.maxChunkedScreenFrameMessageBytes
            - RemoteDesktopScreenFrameWire.screenChunkHeaderByteCount
        guard maxPayloadBytes > 0 else {
            throw RemoteControlError.invalidMessageLength(Self.maxChunkedScreenFrameMessageBytes)
        }

        let frameId = nextChunkedScreenFrameIdentifier()
        let chunkCount = max(1, (outboundData.count + maxPayloadBytes - 1) / maxPayloadBytes)
        var messages: [Data] = []
        messages.reserveCapacity(chunkCount)

        var offset = 0
        for chunkIndex in 0..<chunkCount {
            let end = min(offset + maxPayloadBytes, outboundData.count)
            let payload = Data(outboundData[offset..<end])
            messages.append(
                try RemoteDesktopScreenFrameWire.encodeChunkEnvelope(
                    frameId: frameId,
                    chunkIndex: chunkIndex,
                    chunkCount: chunkCount,
                    totalBytes: outboundData.count,
                    chunkOffset: offset,
                    payload: payload
                )
            )
            offset = end
        }

        return messages
    }

    private func nextChunkedScreenFrameIdentifier() -> UInt64 {
        let frameId = nextChunkedScreenFrameId
        nextChunkedScreenFrameId &+= 1
        if nextChunkedScreenFrameId == 0 {
            nextChunkedScreenFrameId = 1
        }
        return frameId
    }

    private func completeVideoFrameSend(
        sendCompletionId: UInt64,
        generation: UInt64,
        payloadBytes: Int,
        wireMessageCount: Int,
        usedChunkedScreenWire: Bool,
        sendMode: FramedMessageSendMode,
        sendStartedAt: Date,
        contentProcessedAt: Date,
        error: Error?
    ) async {
        guard generation == videoSendGeneration else { return }
        removePendingVideoSendCompletion(id: sendCompletionId)
        inFlightVideoSends = pendingVideoSendCompletions.count
        if let error {
            noteFrameTelemetry(dropped: 1)
            logger.error(
                "❌ 发送屏幕数据失败: peer=\(self.peerId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return
        }

        let completedAt = Date()
        noteVideoFrameCompleted(at: completedAt, contentProcessedAt: contentProcessedAt)
        let sendLatencyMs = contentProcessedAt.timeIntervalSince(sendStartedAt) * 1_000
        noteFrameTelemetry(
            sent: 1,
            sentBytes: payloadBytes,
            chunkedFrames: usedChunkedScreenWire ? 1 : 0,
            sentChunks: usedChunkedScreenWire ? wireMessageCount : 0,
            maxChunksPerFrame: usedChunkedScreenWire ? wireMessageCount : 0,
            sendLatencyMs: sendLatencyMs,
            sendMode: sendMode
        )
        lastSentFrameAt = completedAt
        updateSyncRecoveryState()
        scheduleVideoPaceWakeIfNeeded()
    }

    private func removePendingVideoSendCompletion(id: UInt64) {
        guard let index = pendingVideoSendCompletions.firstIndex(where: { $0.id == id }) else {
            return
        }
        pendingVideoSendCompletions.remove(at: index)
    }

    private func scheduleVideoPaceWakeIfNeeded() {
        guard !videoPaceClock.isScheduled else { return }
        guard !closed, streamingEnabled, !frameQueue.pendingFrames.isEmpty else { return }
        let generation = videoSendGeneration
        let now = Date()
        let delay = isContentProcessedBacklogFull
            ? max(videoSendInterval, videoPaceWakeDelay(from: now))
            : videoPaceWakeDelay(from: now)
        videoPaceClock.schedule(
            after: delay,
            interval: videoSendInterval,
            generation: generation
        ) { [weak self] generation, firedAt in
            await self?.runVideoPaceWake(generation: generation, firedAt: firedAt)
        }
    }

    private func videoPaceWakeDelay(from now: Date) -> TimeInterval {
        guard lastVideoFrameScheduledAt > .distantPast else { return 0 }
        let nextSendAt = lastVideoFrameScheduledAt.addingTimeInterval(videoSendInterval)
        let delay = nextSendAt.timeIntervalSince(now)
        return delay <= Self.videoPaceEarlySendTolerance ? 0 : delay
    }

    private func elapsedVideoCadenceSlots(now: Date) -> Int {
        guard !frameQueue.pendingFrames.isEmpty else { return 0 }
        guard lastVideoFrameScheduledAt > .distantPast else { return 1 }
        let nextSendAt = lastVideoFrameScheduledAt.addingTimeInterval(videoSendInterval)
        let delay = nextSendAt.timeIntervalSince(now)
        guard delay <= Self.videoPaceEarlySendTolerance else { return 0 }
        let overdueBy = max(0, now.timeIntervalSince(nextSendAt))
        return Int((overdueBy / videoSendInterval).rounded(.down)) + 1
    }

    private func videoScheduleBudget(now: Date = Date()) -> Int {
        guard !frameQueue.pendingFrames.isEmpty else { return 0 }
        let elapsedCadenceSlots = elapsedVideoCadenceSlots(now: now)
        guard !isContentProcessedBacklogFull else {
            if elapsedCadenceSlots > 0 {
                noteVideoScheduleBudget(0, elapsedCadenceSlots: elapsedCadenceSlots)
            }
            return 0
        }
        let maxFramesPerDrain = maxVideoFramesPerDrain
        let availableInFlightSlots = min(
            effectiveMaxContentProcessedBacklogFrames - inFlightVideoSends,
            maxFramesPerDrain
        )
        guard availableInFlightSlots > 0 else { return 0 }
        guard lastVideoFrameScheduledAt > .distantPast else {
            let budget = min(1, frameQueue.pendingFrames.count, availableInFlightSlots)
            noteVideoScheduleBudget(budget, elapsedCadenceSlots: budget)
            return budget
        }

        let nextSendAt = lastVideoFrameScheduledAt.addingTimeInterval(videoSendInterval)
        let delay = nextSendAt.timeIntervalSince(now)
        guard delay <= Self.videoPaceEarlySendTolerance else { return 0 }

        let budget = min(
            max(1, elapsedCadenceSlots),
            frameQueue.pendingFrames.count,
            availableInFlightSlots
        )
        let schedulableCadenceSlots = min(
            elapsedCadenceSlots,
            frameQueue.pendingFrames.count,
            availableInFlightSlots
        )
        noteVideoScheduleBudget(
            budget,
            elapsedCadenceSlots: elapsedCadenceSlots,
            schedulableCadenceSlots: schedulableCadenceSlots
        )
        return budget
    }

    private func runVideoPaceWake(generation: UInt64, firedAt: Date) async {
        guard generation == videoSendGeneration else { return }
        guard !closed, streamingEnabled else { return }
        guard !frameQueue.pendingFrames.isEmpty else { return }
        let drainStartedAt = Date()
        noteVideoPaceClockDrain(firedAt: firedAt, drainStartedAt: drainStartedAt)
        telemetryPaceWakeDrains += 1
        await drainIfNeeded(maxVideoFramesToSchedule: videoScheduleBudget(now: firedAt))
        if closed || !streamingEnabled || frameQueue.pendingFrames.isEmpty {
            cancelVideoPaceWake()
        } else {
            scheduleVideoPaceWakeIfNeeded()
        }
    }

    private func cancelVideoPaceWake() {
        videoPaceClock.cancel()
    }

    private func shouldDrainPendingVideoBeforeEnqueue(now: Date = Date()) -> Bool {
        guard !closed, streamingEnabled else { return false }
        guard !frameQueue.pendingFrames.isEmpty else { return false }
        guard canScheduleVideoFrameSend else { return false }
        return videoPaceWakeDelay(from: now) == 0
    }

    private var canScheduleVideoFrameSend: Bool {
        !isContentProcessedBacklogFull
    }

    private func nextVideoFrameCadenceAnchor(for now: Date) -> Date {
        guard lastVideoFrameScheduledAt > .distantPast else {
            return now
        }

        let nextAnchor = lastVideoFrameScheduledAt.addingTimeInterval(videoSendInterval)
        if now.timeIntervalSince(nextAnchor) > effectiveVideoCadenceResetThreshold {
            return now
        }
        return nextAnchor
    }

    private func scheduleAudioDrainIfNeeded() {
        guard !sendingAudio else { return }
        guard !closed, streamingEnabled, !audioPayloadQueue.isEmpty else { return }
        sendingAudio = true
        let generation = audioDrainGeneration
        audioDrainTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.drainQueuedAudioPayloads(generation: generation)
        }
    }

    private func clearAudioPayloadQueue(keepingCapacity: Bool) {
        audioPayloadQueue.removeAll(keepingCapacity: keepingCapacity)
        audioPayloadQueuedBytes = 0
    }

    private func drainQueuedAudioPayloads(generation: UInt64) async {
        defer {
            if audioDrainGeneration == generation {
                sendingAudio = false
                audioDrainTask = nil
                if !closed, streamingEnabled, !audioPayloadQueue.isEmpty {
                    scheduleAudioDrainIfNeeded()
                }
            }
        }
        var payloadsSentThisDrain = 0
        while !Task.isCancelled,
              audioDrainGeneration == generation,
              !closed,
              streamingEnabled,
              !audioPayloadQueue.isEmpty,
              payloadsSentThisDrain < Self.maxAudioPayloadsPerDrain {
            let payload = audioPayloadQueue.removeFirst()
            audioPayloadQueuedBytes -= payload.count
            do {
                try await sendRemoteFrame(payload, packetType: .audio)
                payloadsSentThisDrain += 1
                noteAudioTelemetry(sent: 1, sentBytes: payload.count)
                guard audioDrainGeneration == generation else { break }
            } catch {
                noteAudioTelemetry(failed: 1)
                Logger(subsystem: "com.skybridge.compass", category: "RemoteControl")
                    .error(
                        "❌ 远控音频块发送失败: peer=\(self.peerId, privacy: .public) queued=\(self.audioPayloadQueue.count, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
                    )
                RemoteControlSmokeStatusWriter.append(
                    "mac-remote-audio-tx peer=\(peerId) result=send-error queued=\(audioPayloadQueue.count) error=\(Self.sanitizeTelemetryToken(error.localizedDescription))"
                )
                break
            }
        }
    }

    private func noteAudioTelemetry(
        submitted: Int = 0,
        sent: Int = 0,
        failed: Int = 0,
        sentBytes: Int = 0,
        now: Date = Date()
    ) {
        telemetryAudioSubmittedPayloads += max(0, submitted)
        telemetryAudioSentPayloads += max(0, sent)
        telemetryAudioFailedPayloads += max(0, failed)
        telemetryAudioSentBytes += max(0, sentBytes)
        telemetryAudioQueuedPayloadsMax = max(telemetryAudioQueuedPayloadsMax, audioPayloadQueue.count)
        emitAudioTelemetryIfNeeded(now: now)
    }

    private func noteAudioBacklogIfNeeded() {
        telemetryAudioQueuedPayloadsMax = max(telemetryAudioQueuedPayloadsMax, audioPayloadQueue.count)
        guard audioPayloadQueue.count >= Self.audioBacklogWarningPayloads else { return }
        telemetryAudioBacklogWarnings += 1
        Logger(subsystem: "com.skybridge.compass", category: "RemoteControl")
            .warning(
                "⚠️ 远控音频发送队列积压: peer=\(self.peerId, privacy: .public) queued=\(self.audioPayloadQueue.count, privacy: .public) threshold=\(Self.audioBacklogWarningPayloads, privacy: .public) videoPending=\(self.frameQueue.pendingFrames.count, privacy: .public) inFlightVideo=\(self.inFlightVideoSends, privacy: .public) waitingForSync=\(String(self.frameQueue.waitingForSyncFrame), privacy: .public)"
            )
    }

    private func emitAudioTelemetryIfNeeded(now: Date = Date()) {
        let interval = now.timeIntervalSince(audioTelemetryWindowStartedAt)
        guard interval >= 1 else { return }
        let sampleMs = Int((interval * 1_000).rounded())
        let submitted = telemetryAudioSubmittedPayloads
        let sent = telemetryAudioSentPayloads
        let failed = telemetryAudioFailedPayloads
        let sentBytes = telemetryAudioSentBytes
        let queuedMax = telemetryAudioQueuedPayloadsMax
        let backlogWarnings = telemetryAudioBacklogWarnings
        audioTelemetryWindowStartedAt = now
        telemetryAudioSubmittedPayloads = 0
        telemetryAudioSentPayloads = 0
        telemetryAudioFailedPayloads = 0
        telemetryAudioSentBytes = 0
        telemetryAudioQueuedPayloadsMax = audioPayloadQueue.count
        telemetryAudioBacklogWarnings = 0

        Logger(subsystem: "com.skybridge.compass", category: "RemoteControl")
            .info(
                """
                🎧 Remote audio tx telemetry: peer=\(self.peerId, privacy: .public) \
                sampleMs=\(sampleMs, privacy: .public) submitted=\(submitted, privacy: .public) \
                sent=\(sent, privacy: .public) failed=\(failed, privacy: .public) \
                queued=\(self.audioPayloadQueue.count, privacy: .public) queuedMax=\(queuedMax, privacy: .public) \
                queuedBytes=\(self.audioPayloadQueuedBytes, privacy: .public) sentBytes=\(sentBytes, privacy: .public) backlogWarnings=\(backlogWarnings, privacy: .public) \
                scheduler=independent-interleaved maxPayloadsPerDrain=\(Self.maxAudioPayloadsPerDrain, privacy: .public) \
                videoPending=\(self.frameQueue.pendingFrames.count, privacy: .public) \
                inFlightVideo=\(self.inFlightVideoSends, privacy: .public) \
                waitingForSync=\(String(self.frameQueue.waitingForSyncFrame), privacy: .public)
                """
            )
        RemoteControlSmokeStatusWriter.append(
            """
            mac-remote-audio-tx peer=\(peerId) sampleMs=\(sampleMs) submitted=\(submitted) sent=\(sent) failed=\(failed) \
            queued=\(audioPayloadQueue.count) queuedMax=\(queuedMax) queuedBytes=\(audioPayloadQueuedBytes) sentBytes=\(sentBytes) backlogWarnings=\(backlogWarnings) \
            scheduler=independent-interleaved maxPayloadsPerDrain=\(Self.maxAudioPayloadsPerDrain) \
            videoPending=\(frameQueue.pendingFrames.count) inFlightVideo=\(inFlightVideoSends) waitingForSync=\(frameQueue.waitingForSyncFrame)
            """
        )
    }

    private func logAudioQueueClearedIfNeeded(reason: String) {
        guard !audioPayloadQueue.isEmpty else { return }
        Logger(subsystem: "com.skybridge.compass", category: "RemoteControl")
            .warning(
                "⚠️ 远控音频队列随会话状态清理: peer=\(self.peerId, privacy: .public) queued=\(self.audioPayloadQueue.count, privacy: .public) reason=\(reason, privacy: .public)"
            )
        RemoteControlSmokeStatusWriter.append(
            "mac-remote-audio-tx peer=\(peerId) result=queue-cleared queued=\(audioPayloadQueue.count) queuedBytes=\(audioPayloadQueuedBytes) reason=\(reason)"
        )
    }

    private static func sanitizeTelemetryToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private func updateSyncRecoveryState() {
        if frameQueue.waitingForSyncFrame {
            if waitingForSyncSince == nil {
                waitingForSyncSince = Date()
            }
            ensureSyncRecoveryTaskRunning()
        } else {
            waitingForSyncSince = nil
            syncRecoveryTask?.cancel()
            syncRecoveryTask = nil
        }
    }

    private func ensureSyncRecoveryTaskRunning() {
        guard syncRecoveryTask == nil else { return }
        syncRecoveryTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                await self.driveSyncRecoveryTick()
            }
        }
    }

    private func driveSyncRecoveryTick() {
        guard !closed else {
            syncRecoveryTask = nil
            return
        }
        guard frameQueue.waitingForSyncFrame else {
            syncRecoveryTask?.cancel()
            syncRecoveryTask = nil
            waitingForSyncSince = nil
            return
        }
        requestSyncRefreshIfNeeded(
            reason: "waiting-for-sync-frame",
            minimumInterval: Self.waitingForSyncFrameRefreshMinimumInterval
        )
    }

    private func requestSyncRefreshIfNeeded(reason: String, minimumInterval: TimeInterval) {
        let now = Date()
        guard now.timeIntervalSince(lastSyncRefreshRequestAt) >= minimumInterval else { return }
        lastSyncRefreshRequestAt = now
        Logger(subsystem: "com.skybridge.compass", category: "RemoteControl")
            .warning("⚠️ 发送队列等待关键帧，已请求刷新: peer=\(self.peerId, privacy: .public) reason=\(reason, privacy: .public)")
        onNeedsSyncRefresh?()
    }

    private func makeScreenPayload(for frame: ScreenData) throws -> Data {
        switch frameTransport {
        case .binaryWire:
            return RemoteDesktopScreenFrameWire.encode(
                width: frame.width,
                height: frame.height,
                imageData: frame.imageData,
                timestamp: frame.timestamp,
                format: frame.format,
                isSyncFrame: frame.isSyncFrame,
                sequenceNumber: frame.sequenceNumber
            )
        case .legacyJSON:
            let encodedScreen = try JSONEncoder().encode(frame)
            let message = RemoteMessage(type: .screenData, payload: encodedScreen)
            return try JSONEncoder().encode(message)
        }
    }

    func sendControlPayload<T: Encodable & Sendable>(
        _ payload: T,
        type: RemoteMessage.MessageType
    ) async throws {
        let encodedPayload = try JSONEncoder().encode(payload)
        let message = RemoteMessage(type: type, payload: encodedPayload)
        let framedMessage = try JSONEncoder().encode(message)
        guard framedMessage.count <= maxFramedMessageBytes else {
            throw RemoteControlError.invalidMessageLength(framedMessage.count)
        }
        try await sendRemoteFrame(framedMessage, packetType: .control)
    }

    func sendRawPayload(_ plaintext: Data) async throws {
        guard plaintext.count <= maxFramedMessageBytes else {
            throw RemoteControlError.invalidMessageLength(plaintext.count)
        }
        try await sendRemoteFrame(plaintext, packetType: .control)
    }

    private func sendRemoteFrame(
        _ plaintext: Data,
        packetType: RemoteControlSecurePacketType
    ) async throws {
        let outboundData = try makeOutboundRemoteFrame(plaintext, packetType: packetType)
        try await Self.sendFramed(outboundData, over: connection)
    }

    private func makeOutboundRemoteFrame(
        _ plaintext: Data,
        packetType: RemoteControlSecurePacketType
    ) throws -> Data {
        let outboundData: Data
        if #available(macOS 14.0, *), let sessionKeys {
            let counter = try secureEnvelopeSendSequencer.nextCounter(for: sessionKeys)
            outboundData = try Self.encryptRemotePayload(
                plaintext,
                with: sessionKeys,
                packetType: packetType,
                counter: counter
            )
        } else if #available(macOS 14.0, *), !allowsInsecureLegacy {
            throw RemoteControlError.handshakeInitializationFailed("secure channel not established")
        } else {
            outboundData = plaintext
        }
        guard outboundData.count <= RemoteControlWireLimits.maxWireMessageBytes(for: maxFramedMessageBytes) else {
            throw RemoteControlError.invalidMessageLength(outboundData.count)
        }
        return outboundData
    }

    @available(macOS 14.0, *)
    private static func encryptRemotePayload(
        _ plaintext: Data,
        with keys: SessionKeys,
        packetType: RemoteControlSecurePacketType,
        counter: UInt64
    ) throws -> Data {
        try RemoteControlSecureEnvelope.seal(
            plaintext,
            keys: keys,
            packetType: packetType,
            counter: counter
        )
    }

    private static func sendFramed(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sendFramed(data, over: connection) { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }

    private static func sendFramed(_ data: Data, over connection: NWConnection, completion: @escaping @Sendable (Error?) -> Void) {
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(data)
        connection.send(content: frame, completion: .contentProcessed(completion))
    }

    private static func sendFramedMessages(
        _ messages: [Data],
        over connection: NWConnection,
        mode: FramedMessageSendMode,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        guard !messages.isEmpty else {
            completion(nil)
            return
        }

        if mode == .singleUnbatched, messages.count == 1 {
            sendFramed(messages[0], over: connection, completion: completion)
            return
        }

        sendFramedMessagesBatchedInOrder(
            messages,
            over: connection,
            completion: completion
        )
    }

    private static func framedMessageSendMode(
        messageCount: Int,
        forceBatch _: Bool
    ) -> FramedMessageSendMode {
        guard messageCount > 0 else { return .empty }
        guard messageCount == 1 else { return .batchMulti }
        return .singleUnbatched
    }

    private static func sendFramedMessagesBatchedInOrder(
        _ messages: [Data],
        over connection: NWConnection,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        let completionState = FramedMessageBatchCompletionState(
            remainingMessages: messages.count,
            completion: completion
        )
        connection.batch {
            for message in messages {
                sendFramed(message, over: connection) { error in
                    completionState.completeOne(error)
                }
            }
        }
    }

    private final class FramedMessageBatchCompletionState: @unchecked Sendable {
        private let lock = NSLock()
        private var remainingMessages: Int
        private var completed = false
        private let completion: @Sendable (Error?) -> Void

        init(
            remainingMessages: Int,
            completion: @escaping @Sendable (Error?) -> Void
        ) {
            self.remainingMessages = remainingMessages
            self.completion = completion
        }

        func completeOne(_ error: Error?) {
            let callback: (@Sendable (Error?) -> Void)?
            let callbackError: Error?
            lock.lock()
            if completed {
                callback = nil
                callbackError = nil
            } else if let error {
                completed = true
                callback = completion
                callbackError = error
            } else {
                remainingMessages -= 1
                if remainingMessages == 0 {
                    completed = true
                    callback = completion
                    callbackError = nil
                } else {
                    callback = nil
                    callbackError = nil
                }
            }
            lock.unlock()

            callback?(callbackError)
        }
    }
}
