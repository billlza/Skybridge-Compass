//
// RemoteDesktopManager.swift
// SkyBridgeCompassiOS
//
// 远程桌面管理器 - iOS 作为查看器/控制端
// 支持查看和控制 macOS、Windows、Linux 设备的屏幕
//
// iOS 限制说明：
// - iOS 不能作为被控端（系统限制，无法注入输入事件）
// - iOS 可以使用 ReplayKit 进行屏幕广播，但只能用于直播
// - iOS 主要作为远程桌面的查看器/控制端
//

import Foundation
import Network
@preconcurrency import AVFoundation
import AudioToolbox
import ImageIO
import CoreImage
import Combine
import SkyBridgeRealtimeMedia
#if canImport(UIKit)
import UIKit
#endif

@available(iOS 17.0, *)
private struct LANSecureReceiveContext: @unchecked Sendable {
    let connectionID: ObjectIdentifier
    let generation: UInt64
    let keys: SessionKeys
    let pipeline: LANRemoteSecureReceivePipeline
}

@available(iOS 17.0, *)
private struct LANSecureReceiveLoopContext: @unchecked Sendable {
    let receiveContext: LANSecureReceiveContext
    let scheduler: LANSecureReceiveScheduler
}

@available(iOS 17.0, *)
private final class LANSecureReceiveScheduler: @unchecked Sendable {
    typealias Completion = @Sendable (
        Result<LANRemoteSecureReceiveResult, Error>,
        ObjectIdentifier,
        UInt64
    ) async -> Void

    private let lock = NSLock()
    private var tailTask: Task<Void, Never>?
    private var epoch: UInt64 = 0

    func cancel() {
        lock.lock()
        epoch &+= 1
        let task = tailTask
        tailTask = nil
        lock.unlock()
        task?.cancel()
    }

    func scheduleChunk(
        _ chunk: Data,
        receivedAt: Date,
        context: LANSecureReceiveContext,
        maxCompleteScreenFrames: Int,
        maxDrainBudgetMs: Double,
        completion: @escaping Completion
    ) {
        let scheduledEpoch = currentEpoch()
        let parseTaskScheduledAt = Date()
        enqueue(
            context: context,
            expectedEpoch: scheduledEpoch,
            maxCompleteScreenFrames: maxCompleteScreenFrames,
            maxDrainBudgetMs: maxDrainBudgetMs,
            completion: completion
        ) {
            let parseTaskStartedAt = Date()
            return try await context.pipeline.appendAndDrain(
                chunk: chunk,
                receivedAt: receivedAt,
                keys: context.keys,
                maxCompleteScreenFrames: maxCompleteScreenFrames,
                maxDrainBudgetMs: maxDrainBudgetMs,
                parseTaskScheduledAt: parseTaskScheduledAt,
                parseTaskStartedAt: parseTaskStartedAt
            )
        }
    }

    private func scheduleDrain(
        context: LANSecureReceiveContext,
        expectedEpoch: UInt64,
        maxCompleteScreenFrames: Int,
        maxDrainBudgetMs: Double,
        completion: @escaping Completion
    ) {
        enqueue(
            context: context,
            expectedEpoch: expectedEpoch,
            maxCompleteScreenFrames: maxCompleteScreenFrames,
            maxDrainBudgetMs: maxDrainBudgetMs,
            completion: completion
        ) {
            try await context.pipeline.drain(
                keys: context.keys,
                maxCompleteScreenFrames: maxCompleteScreenFrames,
                maxDrainBudgetMs: maxDrainBudgetMs
            )
        }
    }

    private func enqueue(
        context: LANSecureReceiveContext,
        expectedEpoch: UInt64,
        maxCompleteScreenFrames: Int,
        maxDrainBudgetMs: Double,
        completion: @escaping Completion,
        work: @escaping @Sendable () async throws -> LANRemoteSecureReceiveResult
    ) {
        lock.lock()
        guard epoch == expectedEpoch else {
            lock.unlock()
            return
        }
        let previous = tailTask
        let task = Task.detached(priority: .high) { [weak self, previous] in
            await previous?.value
            guard !Task.isCancelled,
                  self?.isCurrentEpoch(expectedEpoch) == true else { return }

            do {
                let result = try await work()
                guard !Task.isCancelled,
                      self?.isCurrentEpoch(expectedEpoch) == true else { return }
                await completion(.success(result), context.connectionID, context.generation)
                guard !Task.isCancelled,
                      self?.isCurrentEpoch(expectedEpoch) == true else { return }
                if result.hasCompletePayloadPending {
                    self?.scheduleDrain(
                        context: context,
                        expectedEpoch: expectedEpoch,
                        maxCompleteScreenFrames: maxCompleteScreenFrames,
                        maxDrainBudgetMs: maxDrainBudgetMs,
                        completion: completion
                    )
                }
            } catch {
                guard self?.isCurrentEpoch(expectedEpoch) == true else { return }
                await completion(.failure(error), context.connectionID, context.generation)
            }
        }
        tailTask = task
        lock.unlock()
    }

    private func currentEpoch() -> UInt64 {
        lock.lock()
        let value = epoch
        lock.unlock()
        return value
    }

    private func isCurrentEpoch(_ expectedEpoch: UInt64) -> Bool {
        lock.lock()
        let isCurrent = epoch == expectedEpoch
        lock.unlock()
        return isCurrent
    }
}

// MARK: - RemoteDesktopManager

/// 远程桌面管理器 - iOS 作为查看器/控制端
@available(iOS 17.0, *)
@MainActor
public class RemoteDesktopManager: ObservableObject {
    public static let instance = RemoteDesktopManager()
    public static let crossNetworkDeviceCapability = "cross_network_remote"
    private typealias MetalDisplayCadenceSnapshot = (
        displayedFramesInStream: Int,
        displayedFramesInWindow: Int,
        lastDisplayedFrameTime: Date?,
        frameAgeMaxInWindowMs: Int?
    )

    // MARK: - Published Properties

    /// 是否正在流媒体
    @Published public private(set) var isStreaming: Bool = false

    /// 当前连接
    @Published public private(set) var currentConnection: Connection?
    private var pendingConnectionTarget: DiscoveredDevice?

    /// 连接状态
    @Published public private(set) var state: RemoteDesktopState = .disconnected

    /// 当前帧图像
    @Published public private(set) var currentFrame: CGImage?
    private var lastGoodFrozenFrame: CGImage?
    let videoFrameFeed = RemoteVideoFrameFeed()
    let metalVideoFrameFeed = RemoteMetalVideoFrameFeed()

    /// 帧率
    @Published public private(set) var frameRate: Double = 0

    /// 延迟（毫秒）
    @Published public private(set) var latency: Double = 0

    /// 分辨率
    @Published public private(set) var resolution: CGSize = .zero

    /// 当前传输方式（用于 UI 提示）
    @Published public private(set) var transportStatusText: String?
    @Published public private(set) var renderPipelineStatus: RemoteDesktopRenderPipeline = .waiting
    @Published public private(set) var renderOrientationStatus: RemoteDesktopRenderOrientation = .unknown
    @Published public private(set) var isUsingCrossNetworkTransport = false
    @Published public private(set) var lastDamageRectCount: Int = 0
    @Published public private(set) var lastDamageUsesFullFrameFallback: Bool = false
    @Published private(set) var currentCursorPayload: RemoteDesktopCursorPayload?
    @Published private(set) var currentOverlayPayload: RemoteDesktopOverlayPayload?
#if canImport(UIKit)
    @Published private(set) var currentCursorImage: UIImage?
#endif

    /// 是否全屏
    @Published public var isFullscreen: Bool = false

    /// 画质设置
    @Published public var quality: StreamQuality = .auto
    @Published public var viewerSettings: RemoteDesktopViewerSettings = .init() {
        didSet {
            if oldValue.audioRedirectionEnabled && !viewerSettings.audioRedirectionEnabled {
                teardownRemoteAudioPlayback()
            }
            persistViewerSettings()
            scheduleViewerSettingsUpdate()
        }
    }

    // MARK: - Private Properties

    private let skyBridgeCore = SkyBridgeiOSCore.shared
    private var networkConnection: NWConnection?
    private var lanHandshakeTransport: NWConnectionTransport?
    private var lanHandshakeDriver: HandshakeDriver?
    private var lanSessionKeys: SessionKeys?
    private var lanReceiveLoopConnectionID: ObjectIdentifier?
    private var lanSOAPairKey: Data?
    private var lanSecureReplayWindow = RemoteControlSecureReplayWindow()
    private var lanHandshakePeerId: String?
    private var lanReceiveBuffer = Data()
    private var lanReceiveBufferNewestArrivalAt: Date?
    private var lanReceiveBufferArrivalMarkers: [(endOffset: Int, receivedAt: Date)] = []
    private lazy var lanScreenChunkReassembler = RemoteDesktopScreenFrameWire.ChunkedPayloadReassembler(
        maxFrameBytes: maxLANWireMessageBytes
    )
    private lazy var lanSecureReceivePipeline = LANRemoteSecureReceivePipeline(
        maxWireMessageBytes: maxLANWireMessageBytes
    )
    private let lanSecureReceiveScheduler = LANSecureReceiveScheduler()
    private var lanSecureReceiveApplyChain: Task<Void, Never>?
    private var lanSecureReceiveGeneration: UInt64 = 0
    private var lanSecureSendCounter: UInt64 = 0
    private var isProcessingLANReceiveBuffer = false
    private var needsLANReceiveBufferDrain = false
    private var activeTransportMode: ActiveTransportMode = .none
    private let decoder = VideoDecoder()
    private let queue = DispatchQueue(label: "com.skybridge.remotedesktop", qos: .userInitiated)
    private let fallbackImageContext = CIContext(options: [.cacheIntermediates: false])
    private let remoteAudioPlayback = RemoteAudioPlaybackController()
    private var remoteAudioPlaybackGeneration: UInt64 = 0

    private var heartbeatTimer: Timer?
    private var frameCount: Int = 0
    private var lastFrameTime: Date?
    private var lastRenderedFrameTime: Date?
    private var lastSmokeFrameRateSampleAt: Date?
    private var lastSmokeFrameRateSampleReceivedFrames: Int = 0
    private var lastSmokeFrameRateSampleValue: Double = 0
    private var consecutiveDecodeMisses: Int = 0
    private var lastDecoderResetTime: Date?
    private var lastHeartbeatTime: Date?
    private var firstFrameWatchdogTask: Task<Void, Never>?
    private var hasReceivedFrameInCurrentStream: Bool = false

    private let maxMessageBytes: Int = 8_000_000
    private let maxEncryptedLANMessageOverheadBytes: Int = RemoteControlSecureEnvelope.overheadBytes
    // H.264/HEVC reference frames enter one VTDecompressionSession in wire order, with bounded callbacks in flight.
    private let maxConcurrentVideoDecodes: Int = RemoteDesktopManagerRuntimeLimits.maxPredictiveVideoDecodeInFlight
    private let sampleBufferNoEnqueueWindowThreshold: Int = 3
    private let sampleBufferDisplayStallRecoveryThreshold: Int = 3
    private var inFlightDecodeCount: Int = 0
    private var decodeGeneration: UInt64 = 0
    private var nextDecodeSubmissionOrder: UInt64 = 0
    private var nextDecodeCompletionOrder: UInt64 = 0
    private var pendingDecodeCompletions: [UInt64: PendingDecodeCompletion] = [:]
    private var isDrainingDecodeCompletions = false
    private var decodeSubmissionChain: Task<Void, Never>?
    private var decodeCompletionGapStartedAt: Date?
    private var decodeCompletionGapWatchdogTask: Task<Void, Never>?
    private var decodeCompletionGapWatchdogMissingOrder: UInt64?
    private var pendingFrames: [ScreenData] = []
    private var decodeQueueWaitingForSyncFrame = false
    private let metalFeedDeliveryMaxDelayMs: Double = 100.0
    private let metalFeedBackpressureRetryDelayNs: UInt64 = 4_000_000
    private let metalFeedBackpressureMaxRetries: Int = 12
    private var lastInboundVideoFrameSequence: UInt64?
    private var lastInboundVideoSyncFrameSequence: UInt64?
    private var lastDecodeQueueOverflowLogTime: Date = .distantPast
    private var lastDecodeQueuePressureLogTime: Date = .distantPast
    private var lastVideoSequenceGapLogTime: Date = .distantPast
    private var lastDecodeQueueProgressAt: Date = Date()
    private let connectionManager = P2PConnectionManager.instance
    private let crossNetwork = CrossNetworkWebRTCManager.instance
    private var clipboardSessionId: UUID?
    private var clipboardListenerToken: UUID?
    private var pendingViewerSettingsTask: Task<Void, Never>?
    private var lastSentStreamConfiguration: RemoteDesktopStreamConfigurationPayload?
    private var realtimeMediaAudioReceiver: SkyBridgeUDPRealtimeMediaReceiver?
    private var realtimeMediaAudioRelayTransport: SkyBridgeUDPRealtimeMediaTransport?
    private var realtimeMediaAudioRenderer: IOSRealtimeMediaAudioReceiver?
    private var realtimeMediaAudioReceiverSessionId: String?
    private var realtimeMediaAudioEndpoint: SkyBridgeMediaEndpoint?
    private var realtimeMediaAudioReceiverStartTask: Task<Void, Never>?
    private var realtimeMediaAudioReceiverStartGeneration: UInt64 = 0
    private var realtimeMediaAudioReceiverStartPhase: RealtimeMediaAudioReceiverStartPhase?
    private var realtimeMediaAudioRelayBindState: OptimisticRelayBindState = .idle
    private var realtimeMediaAudioRelayBindGraceTask: Task<Void, Never>?
    private var realtimeMediaAudioRelayRenewalTask: Task<Void, Never>?
    private var realtimeMediaAudioNoTrafficRecoveryTask: Task<Void, Never>?
    private var realtimeMediaAudioNoTrafficRecoveryAttemptsBySessionId: [String: Int] = [:]
    private var streamConfigurationAckTask: Task<Void, Never>?
    private var streamConfigurationAckGeneration: UInt64 = 0
    private var streamConfigurationAckSatisfied: Bool = false
    private var lastAcknowledgedMediaAudioEndpointPresent: Bool = false
    private var lastHandledSessionAuthorityLostStreamEpoch: UInt64?
    private var lastCrossNetworkNativeReadyAnnouncementAt: Date?
    private var lastIncomingStreamSignature: IncomingStreamSignature?
    private var lastStreamTopologyChangeAt: Date = .distantPast
    private var streamTopologyFlapSuppressedUntil: Date = .distantPast
    private var streamTopologyFlapCount: Int = 0
    private var lastStreamTopologyRefreshSignature: IncomingStreamSignature?
    private var streamRefreshTokenCounter: UInt64 = 0
    private var lastRefreshRequestAt: Date?
    private var lastRequestedStreamRefreshToken: UInt64?
    private var lastRequestedStreamRefreshReason: String?
    private var lastRequestedStreamRefreshAt: Date?
    private var lastRefreshRequestFailureDescription: String?
    private var hevcDisableRefreshSuppressedUntil: Date?
    private var hevcDisableRefreshTokenInFlight: UInt64?
    private var lastWaitingSyncDiagnosticLogTime: Date = .distantPast
    private var lastNativePrimaryIgnoredFallbackDiagnosticAt: Date = .distantPast
    private var lastNativeWarmupNonJPEGFallbackDropDiagnosticAt: Date = .distantPast
    private let lanStreamRefreshMinimumInterval: TimeInterval = 2.0
    private let streamDecodeStallRefreshMinimumInterval: TimeInterval = 3.0
    private var codecGovernance = RemoteDesktopCodecGovernance()
    private var decodedVideoRendererPreference: DecodedVideoRendererPreference = .metal
    private var streamEpoch: UInt64 = 0
    private var lastFrameArrivalAt: Date?
    private var lastDecodedFrameTime: Date?
    private var lastAcceptedDecodedPresentationTimeStamp: CMTime?
    private var lastVideoRendererEnqueueAt: Date?
    private var lastDisplayedFrameTime: Date?
    private let latencyPublishInterval: TimeInterval = 0.25
    private var lastLatencyPublishAt: Date = .distantPast
    private var metalAwaitingFirstDisplaySince: Date?
    private var receivedFrameCountInCurrentStream: Int = 0
    private var displayedFrameCountInCurrentStream: Int = 0
    private var receivedFrameTimesInCurrentStream: [Date] = []
    private var lanInboundSourceFrameTimesInCurrentStream: [TimeInterval] = []
    private var lanInboundMetalDeliveryTimesInCurrentStream: [Date] = []
    private var displayedFrameTimesInCurrentStream: [Date] = []
    private let metalDisplaySmokeCadence = MetalDisplaySmokeCadenceTracker()
    private static let smokeRollingFrameWindowSeconds: TimeInterval =
        RemoteDesktopManagerRuntimeLimits.smokeRollingFrameWindowSeconds
    private var statsWindowStartTime: Date?
    private var receivedFramesInStatsWindow: Int = 0
    private var decodedFramesInStatsWindow: Int = 0
    private var rendererEnqueuedFramesInStatsWindow: Int = 0
    private var displayedFramesInStatsWindow: Int = 0
    private var lanInboundTelemetryWindowStartedAt = Date()
    private var lanInboundScreenFramesInWindow: Int = 0
    private var lanInboundScreenBytesInWindow: Int = 0
    private var lanInboundChunkedScreenFramesInWindow: Int = 0
    private var lanInboundScreenChunksInWindow: Int = 0
    private var lanInboundScreenWireFormat: String = "length-framed"
    private var lanInboundReceiveParserMode: String = "mainactor-bootstrap"
    private var lanInboundMainHopSamples: Int = 0
    private var lanInboundMainHopTotalMs: Double = 0
    private var lanInboundMainHopMaxMs: Double = 0
    private var lanInboundRawChunkGapMaxMs: Double = 0
    private var lanInboundRawChunkMainHopMaxMs: Double = 0
    private var lanInboundRawChunksInWindow: Int = 0
    private var lanInboundParseQueueDelayMaxMs: Double = 0
    private var lanInboundParserActorHopMaxMs: Double = 0
    private var lanInboundParserDrainMaxMs: Double = 0
    private var lanInboundParserStageMaxName: String = "none"
    private var lanInboundParserStageMaxMs: Double = 0
    private var lanInboundParserStagePayloadBytesMax: Int = 0
    private var lanInboundParserStageReceiveBufferBytesMax: Int = 0
    private var lanInboundParserBudgetHitsInWindow: Int = 0
    private var lanInboundPayloadsPerDrainMax: Int = 0
    private var lanInboundCompleteFramesPerDrainMax: Int = 0
    private var lanInboundBootstrapParserDrainMaxMs: Double = 0
    private var lanInboundBootstrapParserBudgetHitsInWindow: Int = 0
    private var lanInboundApplyQueueDelayMaxMs: Double = 0
    private var lanInboundScreenApplyMaxMs: Double = 0
    private var lanInboundLastRawChunkAt: Date?
    private var lanInboundInterFrameGapMaxMs: Double = 0
    private var lanInboundLastScreenFrameReadAt: Date?
    private var lanInboundLastSourceTimestamp: TimeInterval?
    private var lanInboundSourceGapMaxMs: Double = 0
    private var lanInboundSourceToReadSamples: Int = 0
    private var lanInboundSourceToReadTotalMs: Double = 0
    private var lanInboundSourceToReadMaxMs: Double = 0
    private var lanInboundScreenDeliveryAttemptedInWindow: Int = 0
    private var lanInboundScreenDeliveryBackpressureInWindow: Int = 0
    private var lanInboundScreenDeliveryQueueDepthMax: Int = 0
    private var lanInboundScreenDeliveryDelayMaxMs: Double = 0
    private var lanInboundScreenDeliveryDeliveredInWindow: Int = 0
    private var lanInboundDecodeFeedAttemptedInWindow: Int = 0
    private var lanInboundDecodeFeedAcceptedInWindow: Int = 0
    private var lanInboundDecodeFeedDroppedInWindow: Int = 0
    private var lanInboundSocketToDecodeFeedSamples: Int = 0
    private var lanInboundSocketToDecodeFeedMaxMs: Double = 0
    private var lanInboundSocketToApplyEndSamples: Int = 0
    private var lanInboundSocketToApplyEndMaxMs: Double = 0
    private var lanInboundDecodePendingFramesMax: Int = 0
    private var lanInboundDecodeInFlightMax: Int = 0
    private var lanInboundDecodeWaitingSyncSamples: Int = 0
    private var lanInboundDecodeResetCountInWindow: Int = 0
    private var consecutiveSampleBufferNoEnqueueWindows: Int = 0
    private var consecutiveSampleBufferDisplayStalls: Int = 0
    private var lastInboundScreenTimestamp: TimeInterval?
    private var lastViewerInteractionAt: Date?
    private var lastContinuityRecoveryAt: Date?
    private var lastDeferredMetalContinuityStallClassification: String?
    private var lastMetalContinuityFailFastDisplayedTotal: Int = 0
    private var lastMetalContinuityFailFastSmokeDisplayedTotal: Int = 0
    private var streamContinuityWatchdogTask: Task<Void, Never>?
    private var firstFrameContinuityTask: Task<Void, Never>?
    private var interactionContinuityTask: Task<Void, Never>?
    private var lastMetalFallbackAt: Date?
    private let metalFallbackRestoreCooldown: TimeInterval = 0.75
    private let metalFallbackStableFrameRestoreThreshold = 2
    private let metalFallbackPersistentFailureThreshold = 3
    private let metalFallbackPersistentFailureCooldown: TimeInterval = 6
    private let metalFallbackExpectedRestoreWindow: TimeInterval = 2
    private var metalRestoreFailureCount: Int = 0
    private var metalRestoreSuppressedUntil: Date?
    private var metalFallbackReason: String?
    private var stableSampleBufferFramesSinceMetalFallback: Int = 0
    private var crossNetworkFrameSubscriptionTask: Task<Void, Never>?
    private var crossNetworkFrameSubscriptionSessionId: String?
    private var activePresentationOwnerTokens: Set<UUID> = []

    private init() {
        viewerSettings = Self.loadViewerSettings()
        crossNetwork.nativeAudioReceiveEnabled = RemoteDesktopManagerRuntimeConfig.crossNetworkNativeAudioReceiveEnabled
    }

    private func invalidateDecodePipelineState() {
        noteLANDecodePipelineReset()
        decodeGeneration &+= 1
        inFlightDecodeCount = 0
        resetDecodeCompletionOrdering()
        lastDecodedFrameTime = nil
        lastDecodeQueueProgressAt = Date()
        lastAcceptedDecodedPresentationTimeStamp = nil
        resetMetalFeedDeliveryState()
    }

    private func resetFrameTelemetry() {
        frameCount = 0
        lastFrameTime = nil
        lastRenderedFrameTime = nil
        lastSmokeFrameRateSampleAt = nil
        lastSmokeFrameRateSampleReceivedFrames = 0
        lastSmokeFrameRateSampleValue = 0
        frameRate = 0
        lastFrameArrivalAt = nil
        lastDecodedFrameTime = nil
        lastVideoRendererEnqueueAt = nil
        lastDisplayedFrameTime = nil
        lastAcceptedDecodedPresentationTimeStamp = nil
        receivedFrameCountInCurrentStream = 0
        displayedFrameCountInCurrentStream = 0
        lastMetalContinuityFailFastDisplayedTotal = 0
        lastMetalContinuityFailFastSmokeDisplayedTotal = 0
        receivedFrameTimesInCurrentStream.removeAll(keepingCapacity: true)
        lanInboundSourceFrameTimesInCurrentStream.removeAll(keepingCapacity: true)
        lanInboundMetalDeliveryTimesInCurrentStream.removeAll(keepingCapacity: true)
        displayedFrameTimesInCurrentStream.removeAll(keepingCapacity: true)
        metalDisplaySmokeCadence.reset()
        resetDecodeCompletionOrdering()
        statsWindowStartTime = nil
        receivedFramesInStatsWindow = 0
        decodedFramesInStatsWindow = 0
        rendererEnqueuedFramesInStatsWindow = 0
        displayedFramesInStatsWindow = 0
        lanInboundTelemetryWindowStartedAt = Date()
        lanInboundScreenFramesInWindow = 0
        lanInboundScreenBytesInWindow = 0
        lanInboundChunkedScreenFramesInWindow = 0
        lanInboundScreenChunksInWindow = 0
        lanInboundScreenWireFormat = "length-framed"
        lanInboundReceiveParserMode = "mainactor-bootstrap"
        lanInboundMainHopSamples = 0
        lanInboundMainHopTotalMs = 0
        lanInboundMainHopMaxMs = 0
        lanInboundRawChunkGapMaxMs = 0
        lanInboundRawChunkMainHopMaxMs = 0
        lanInboundRawChunksInWindow = 0
        lanInboundParseQueueDelayMaxMs = 0
        lanInboundParserActorHopMaxMs = 0
        lanInboundParserDrainMaxMs = 0
        lanInboundParserStageMaxName = "none"
        lanInboundParserStageMaxMs = 0
        lanInboundParserStagePayloadBytesMax = 0
        lanInboundParserStageReceiveBufferBytesMax = 0
        lanInboundParserBudgetHitsInWindow = 0
        lanInboundPayloadsPerDrainMax = 0
        lanInboundCompleteFramesPerDrainMax = 0
        lanInboundBootstrapParserDrainMaxMs = 0
        lanInboundBootstrapParserBudgetHitsInWindow = 0
        lanInboundApplyQueueDelayMaxMs = 0
        lanInboundScreenApplyMaxMs = 0
        lanInboundLastRawChunkAt = nil
        lanInboundInterFrameGapMaxMs = 0
        lanInboundLastScreenFrameReadAt = nil
        lanInboundLastSourceTimestamp = nil
        lanInboundSourceGapMaxMs = 0
        lanInboundSourceToReadSamples = 0
        lanInboundSourceToReadTotalMs = 0
        lanInboundSourceToReadMaxMs = 0
        lanInboundScreenDeliveryAttemptedInWindow = 0
        lanInboundScreenDeliveryBackpressureInWindow = 0
        lanInboundScreenDeliveryQueueDepthMax = 0
        lanInboundScreenDeliveryDelayMaxMs = 0
        lanInboundScreenDeliveryDeliveredInWindow = 0
        lanInboundSocketToDecodeFeedSamples = 0
        lanInboundSocketToDecodeFeedMaxMs = 0
        lanInboundSocketToApplyEndSamples = 0
        lanInboundSocketToApplyEndMaxMs = 0
        consecutiveSampleBufferNoEnqueueWindows = 0
        consecutiveSampleBufferDisplayStalls = 0
        lastInboundScreenTimestamp = nil
        lastCrossNetworkNativeReadyAnnouncementAt = nil
        lastNativePrimaryIgnoredFallbackDiagnosticAt = .distantPast
        lastNativeWarmupNonJPEGFallbackDropDiagnosticAt = .distantPast
        lastMetalFallbackAt = nil
        metalFallbackReason = nil
        stableSampleBufferFramesSinceMetalFallback = 0
        decodedVideoRendererPreference = preferredDecodedVideoRenderer()
        renderOrientationStatus = .unknown
        metalAwaitingFirstDisplaySince = nil
        invalidateDecodePipelineState()
    }

    private func resetLANReceiveParserState(keepingCapacity: Bool = true) {
        lanReceiveBuffer.removeAll(keepingCapacity: keepingCapacity)
        lanReceiveBufferNewestArrivalAt = nil
        lanReceiveBufferArrivalMarkers.removeAll(keepingCapacity: keepingCapacity)
        lanScreenChunkReassembler.reset()
        resetLANSecureReceivePipelineState(keepingCapacity: keepingCapacity)
        isProcessingLANReceiveBuffer = false
        needsLANReceiveBufferDrain = false
    }

    private func resetLANSecureReceivePipelineState(keepingCapacity: Bool = true) {
        lanSecureReceiveGeneration &+= 1
        lanSecureReceivePipeline = LANRemoteSecureReceivePipeline(maxWireMessageBytes: maxLANWireMessageBytes)
        lanSecureReceiveScheduler.cancel()
        lanSecureReceiveApplyChain?.cancel()
        lanSecureReceiveApplyChain = nil
        resetMetalFeedDeliveryState(keepingCapacity: keepingCapacity)
    }

    private var shouldContinueLANBootstrapFramingHandoff: Bool {
        isProcessingLANReceiveBuffer || needsLANReceiveBufferDrain || !lanReceiveBuffer.isEmpty
    }

    private func resetMetalFeedDeliveryState(keepingCapacity: Bool = true) {
        _ = keepingCapacity
        lanInboundScreenDeliveryAttemptedInWindow = 0
        lanInboundScreenDeliveryBackpressureInWindow = 0
        lanInboundScreenDeliveryQueueDepthMax = 0
        lanInboundScreenDeliveryDelayMaxMs = 0
        lanInboundScreenDeliveryDeliveredInWindow = 0
    }

    private func updateLastGoodFrozenFrame(_ image: CGImage?) {
        guard let image else { return }
        lastGoodFrozenFrame = image
    }

    private var maxLANWireMessageBytes: Int {
        maxMessageBytes + maxEncryptedLANMessageOverheadBytes
    }

    public func smokeDiagnosticSnapshot() async -> RemoteDesktopSmokeDiagnosticSnapshot {
        let now = Date()
        trimSmokeFrameTimes(&receivedFrameTimesInCurrentStream, at: now)
        trimSmokeFrameTimes(&lanInboundMetalDeliveryTimesInCurrentStream, at: now)
        trimSmokeFrameTimes(&displayedFrameTimesInCurrentStream, at: now)
        let sourceCadenceIsFresh = lastFrameArrivalAt
            .map { now.timeIntervalSince($0) <= Self.smokeRollingFrameWindowSeconds }
            ?? false
        let sourceCadenceFrameCount = sourceCadenceIsFresh
            ? lanInboundSourceFrameTimesInCurrentStream.count
            : 0
        let metalDeliveryFrameCount = lanInboundMetalDeliveryTimesInCurrentStream.count
        let socketArrivalFrameCount = receivedFrameTimesInCurrentStream.count
        let lanReceivedFramesInLastWindow = min(
            sourceCadenceFrameCount > 0 ? sourceCadenceFrameCount : socketArrivalFrameCount,
            metalDeliveryFrameCount > 0 ? metalDeliveryFrameCount : socketArrivalFrameCount
        )
        let receivedFrameRate = smokeReceivedFrameRateSample(at: now)
        let audioSnapshot = await realtimeMediaAudioRenderer?.smokeDiagnosticSnapshot()
        let metalDisplaySnapshot = metalDisplayContinuitySnapshot(at: now)
        let useMetalDisplayCadence = renderPipelineStatus == .metalRenderer
            && metalDisplaySnapshot.displayedFramesInStream > 0
        let displayedFramesForSmoke = useMetalDisplayCadence
            ? max(displayedFrameCountInCurrentStream, metalDisplaySnapshot.displayedFramesInStream)
            : displayedFrameCountInCurrentStream
        let displayedFramesInLastWindowForSmoke = useMetalDisplayCadence
            ? max(displayedFrameTimesInCurrentStream.count, metalDisplaySnapshot.displayedFramesInWindow)
            : displayedFrameTimesInCurrentStream.count
        let lastDisplayedFrameTimeForSmoke: Date? = {
            guard useMetalDisplayCadence else { return lastDisplayedFrameTime }
            guard let metalLast = metalDisplaySnapshot.lastDisplayedFrameTime else {
                return lastDisplayedFrameTime
            }
            guard let managerLast = lastDisplayedFrameTime else {
                return metalLast
            }
            return metalLast > managerLast ? metalLast : managerLast
        }()
        return RemoteDesktopSmokeDiagnosticSnapshot(
            stateDescription: String(describing: state),
            isStreaming: isStreaming,
            isUsingCrossNetworkTransport: isUsingCrossNetworkTransport,
            transportStatusText: transportStatusText,
            presentationOwnerCount: activePresentationOwnerTokens.count,
            frameRate: frameRate,
            receivedFrameRate: receivedFrameRate,
            latencyMilliseconds: latency,
            resolutionWidth: Int(resolution.width),
            resolutionHeight: Int(resolution.height),
            renderPipeline: renderPipelineStatus,
            renderOrientation: renderOrientationStatus,
            receivedFramesInStream: receivedFrameCountInCurrentStream,
            displayedFramesInStream: displayedFramesForSmoke,
            receivedFrameClock: activeTransportMode == .lan
                ? "source-cadence+metal-delivery"
                : "mainactor-observed",
            receivedFramesInLastTwoSeconds: activeTransportMode == .lan
                ? lanReceivedFramesInLastWindow
                : socketArrivalFrameCount,
            socketArrivalFramesInLastTwoSeconds: socketArrivalFrameCount,
            sourceCadenceFramesInLastTwoSeconds: sourceCadenceFrameCount,
            metalDeliveryFramesInLastTwoSeconds: metalDeliveryFrameCount,
            displayedFramesInLastTwoSeconds: displayedFramesInLastWindowForSmoke,
            lastFrameArrivalAgeSeconds: lastFrameArrivalAt.map { now.timeIntervalSince($0) },
            lastDisplayedFrameAgeSeconds: lastDisplayedFrameTimeForSmoke.map { now.timeIntervalSince($0) },
            metalFrameAgeMaxInLastTwoSecondsMs: useMetalDisplayCadence
                ? metalDisplaySnapshot.frameAgeMaxInWindowMs
                : nil,
            realtimeAudio: audioSnapshot,
            audioChannelCount: lastSentStreamConfiguration?.audioChannelCount
        )
    }

    private func smokeReceivedFrameRateSample(at now: Date) -> Double {
        let currentFrames = receivedFrameCountInCurrentStream
        guard let sampleAt = lastSmokeFrameRateSampleAt else {
            lastSmokeFrameRateSampleAt = now
            lastSmokeFrameRateSampleReceivedFrames = currentFrames
            return 0
        }

        let elapsed = now.timeIntervalSince(sampleAt)
        guard elapsed >= 0.5 else { return lastSmokeFrameRateSampleValue }
        let delta = max(0, currentFrames - lastSmokeFrameRateSampleReceivedFrames)
        lastSmokeFrameRateSampleAt = now
        lastSmokeFrameRateSampleReceivedFrames = currentFrames
        lastSmokeFrameRateSampleValue = Double(delta) / elapsed
        return lastSmokeFrameRateSampleValue
    }

    private func trimSmokeFrameTimes(_ times: inout [Date], at now: Date) {
        let cutoff = now.addingTimeInterval(-Self.smokeRollingFrameWindowSeconds)
        guard let firstLiveIndex = times.firstIndex(where: { $0 >= cutoff }) else {
            times.removeAll(keepingCapacity: true)
            return
        }
        if firstLiveIndex > 0 {
            times.removeFirst(firstLiveIndex)
        }
    }

    private func appendLANSourceFrameTimestamp(_ sourceTimestamp: TimeInterval) {
        guard activeTransportMode == .lan, sourceTimestamp > 1_000_000_000 else { return }
        lanInboundSourceFrameTimesInCurrentStream.append(sourceTimestamp)
        trimLANSourceFrameTimes(at: sourceTimestamp)
    }

    private func trimLANSourceFrameTimes(at latestSourceTimestamp: TimeInterval) {
        let cutoff = latestSourceTimestamp - Self.smokeRollingFrameWindowSeconds
        guard let firstLiveIndex = lanInboundSourceFrameTimesInCurrentStream.firstIndex(where: { $0 >= cutoff }) else {
            lanInboundSourceFrameTimesInCurrentStream.removeAll(keepingCapacity: true)
            return
        }
        if firstLiveIndex > 0 {
            lanInboundSourceFrameTimesInCurrentStream.removeFirst(firstLiveIndex)
        }
    }

    // MARK: - Public Methods

    /// 连接到远程桌面
    /// - Parameter device: 目标设备
    public func connect(to device: DiscoveredDevice) async throws {
        let deviceResolver = makeDeviceResolutionCoordinator()
        let resolvedDevice = shouldUseCrossNetworkTransport(for: device)
            ? device
            : deviceResolver.resolveLatestDevice(from: device)
        if let pendingTarget = pendingConnectionTarget,
           state == .connecting,
           areEquivalentRemoteDesktopDevices(pendingTarget, resolvedDevice) {
            SkyBridgeLogger.shared.info(
                "ℹ️ 远程桌面连接已在进行中，复用待建连目标: \(resolvedDevice.id)"
            )
            return
        }
        if let current = currentConnection,
           areEquivalentRemoteDesktopDevices(current.device, resolvedDevice) {
            switch state {
            case .streaming:
                await pushViewerStreamConfiguration(force: true)
                return
            case .connected:
                let hasReusableTransport = activeTransportMode == .crossNetwork
                    || (activeTransportMode == .lan && networkConnection != nil)
                if hasReusableTransport {
                    try await startStreaming()
                    return
                }
            case .connecting:
                SkyBridgeLogger.shared.info(
                    "ℹ️ 远程桌面连接已在进行中，复用当前建连目标: \(resolvedDevice.id)"
                )
                return
            case .disconnected, .error:
                break
            }
        }
        if !shouldUseCrossNetworkTransport(for: resolvedDevice),
           !(await deviceResolver.canResolveLANEndpoint(for: resolvedDevice)) {
            state = .error("设备未发现可用远程桌面端点")
            throw RemoteDesktopError.notSupported("设备未发现可用远程桌面端点")
        }
        if resolvedDevice.id != device.id {
            SkyBridgeLogger.shared.info("ℹ️ 远程桌面连接设备已解析: \(device.id) -> \(resolvedDevice.id)")
        }
        SkyBridgeLogger.shared.info("📺 连接到远程桌面: \(resolvedDevice.name)")

        pendingConnectionTarget = resolvedDevice
        defer {
            if let pending = pendingConnectionTarget,
               areEquivalentRemoteDesktopDevices(pending, resolvedDevice) {
                pendingConnectionTarget = nil
            }
        }
        state = .connecting

        do {
            // 仅当目标设备就是跨网会话对端时才走 DataChannel。
            // 避免“跨网已连接”误伤局域网远控（会导致画面/输入走错通道）。
            if shouldUseCrossNetworkTransport(for: resolvedDevice) {
                await clearLANSecureChannelState()
                networkConnection?.cancel()
                networkConnection = nil
                activeTransportMode = .crossNetwork
                isUsingCrossNetworkTransport = true
                decodedVideoRendererPreference = preferredDecodedVideoRenderer()
                transportStatusText = currentTransportStatusText()
                currentConnection = Connection(device: resolvedDevice, status: .connected)
                state = .connected
                hasReceivedFrameInCurrentStream = false
                resetStreamConfigurationAckState()
                lastLatencyPublishAt = .distantPast
                beginRemoteAudioPlaybackSession()
                isStreaming = true
                state = .streaming
                crossNetwork.startRemoteDesktopHeartbeat()
                configureSessionClipboardSync()

                if let sessionId = crossNetwork.activeRemoteDesktopSessionId {
                    subscribeToCrossNetworkFrames(sessionId: sessionId)
                } else {
                    cancelCrossNetworkFrameSubscription()
                }

                SkyBridgeLogger.shared.info("✅ 远程桌面已切换到 WebRTC 传输（控制走 DataChannel，视频优先原生轨）")
                lastRequestedStreamRefreshReason = "cross-network-startup"
                await pushViewerStreamConfiguration(force: true, refreshStream: true)
                return
            }

            crossNetwork.stopRemoteDesktopHeartbeat()
            cancelCrossNetworkFrameSubscription()
            // Tear down any prior LAN socket before we install a new one.
            // Otherwise stale callbacks from the previous NWConnection can
            // race in later and incorrectly tear down the fresh session.
            networkConnection?.stateUpdateHandler = nil
            networkConnection?.cancel()
            networkConnection = nil
            resetLANReceiveParserState()
            await clearLANSecureChannelState()
            try await ensureLANRemoteControlTrustBootstrap(for: resolvedDevice)
            let refreshedLANDevice = deviceResolver.resolveLatestDevice(from: resolvedDevice)
            if refreshedLANDevice.id != resolvedDevice.id
                || refreshedLANDevice.ipAddress != resolvedDevice.ipAddress
                || refreshedLANDevice.remoteControlPort != resolvedDevice.remoteControlPort {
                SkyBridgeLogger.shared.info(
                    "ℹ️ LAN 远控 bootstrap 后重新解析目标: \(resolvedDevice.id) -> \(refreshedLANDevice.id)"
                )
            }
            // 建立连接：优先 Bonjour service（不依赖 IP/默认端口），失败时回退到等价 IP/会话地址。
            let endpoints = try await deviceResolver.makeEndpointCandidates(for: refreshedLANDevice)

            let connection = try await createConnection(toAnyOf: endpoints)
            networkConnection = connection
            connection.stateUpdateHandler = { [weak self] connectionState in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.isCurrentLANConnection(connection) else {
                        SkyBridgeLogger.shared.debug("ℹ️ 忽略过期 LAN 连接状态回调: \(String(describing: connectionState))")
                        return
                    }
                    switch connectionState {
                    case .failed(let error):
                        await self.handleTransportFailure(error.localizedDescription)
                    case .cancelled:
                        await self.handleTransportFailure(
                            RemoteDesktopError.disconnected.errorDescription ?? "连接已断开"
                        )
                    default:
                        break
                    }
                }
            }
            activeTransportMode = .lan
            isUsingCrossNetworkTransport = false
            decodedVideoRendererPreference = preferredDecodedVideoRenderer()
            transportStatusText = currentTransportStatusText()

            // 创建 Connection 对象
            currentConnection = Connection(device: refreshedLANDevice, status: .connected)
            NotificationManager.beginRemoteDesktopSession(
                sessionId: refreshedLANDevice.id,
                transport: "lan",
                role: "viewer"
            )
            state = .connected

            try await establishLANSecureChannel(for: refreshedLANDevice, over: connection)
            try ensureLANBootstrapStillActive(for: connection)

            // 在进入 streaming 前先主动发送一次 viewer 能力，避免 Mac 端首个会话默认退回到 JPEG。
            await pushViewerStreamConfiguration(force: true)
            try ensureLANBootstrapStillActive(for: connection)

            // 直接进入 streaming（macOS 端无需 connect/heartbeat 握手）
            try await startStreaming()
            try ensureLANBootstrapStillActive(for: connection)

            SkyBridgeLogger.shared.info("ℹ️ LAN 远控安全通道和流配置已建立，等待媒体主路径验证")

        } catch {
            networkConnection?.stateUpdateHandler = nil
            networkConnection?.cancel()
            networkConnection = nil
            resetLANReceiveParserState()
            await clearLANSecureChannelState()
            currentConnection = nil
            activeTransportMode = .none
            isUsingCrossNetworkTransport = false
            transportStatusText = currentTransportStatusText()
            state = .error(error.localizedDescription)
            throw error
        }
    }

    /// 开始流媒体
    public func startStreaming() async throws {
        if state == .streaming {
            await pushViewerStreamConfiguration(force: true)
            guard activeTransportMode != .lan || networkConnection != nil else {
                throw RemoteDesktopError.disconnected
            }
            return
        }
        guard state == .connected else {
            throw RemoteDesktopError.connectionFailed("未连接")
        }

        SkyBridgeLogger.shared.info("📺 开始远程桌面流")
        SkyBridgeLogger.shared.info("🧾 远控 viewer build fingerprint: \(RemoteDesktopManagerRuntimeConfig.remoteDesktopBuildFingerprint)")

        isStreaming = true
        beginRemoteAudioPlaybackSession()
        crossNetwork.disarmIdleConnectionReminder(clearPrompt: true)
        state = .streaming
        streamEpoch &+= 1
        lastHandledSessionAuthorityLostStreamEpoch = nil
        consecutiveDecodeMisses = 0
        hasReceivedFrameInCurrentStream = false
        resetStreamConfigurationAckState()
        lastLatencyPublishAt = .distantPast
        configureSessionClipboardSync()
        lastDecoderResetTime = nil
        lastIncomingStreamSignature = nil
        resetRefreshDiagnostics()
        codecGovernance = .init()
        resetFrameTelemetry()
        lastViewerInteractionAt = nil
        lastContinuityRecoveryAt = nil
        pendingFrames.removeAll(keepingCapacity: true)
        decodeQueueWaitingForSyncFrame = true
        resetDecodeSequenceTracking()
        currentFrame = nil
        lastGoodFrozenFrame = nil
        flushRenderedVideoFeeds()
        renderPipelineStatus = .waiting
        renderOrientationStatus = .unknown
        lastDamageRectCount = 0
        lastDamageUsesFullFrameFallback = false
        currentCursorPayload = nil
        currentOverlayPayload = nil
#if canImport(UIKit)
        currentCursorImage = nil
#endif
        firstFrameWatchdogTask?.cancel()
        firstFrameContinuityTask?.cancel()
        interactionContinuityTask?.cancel()
        streamContinuityWatchdogTask?.cancel()
        startStreamContinuityWatchdog(for: streamEpoch)
        if activeTransportMode == .crossNetwork {
            if let sessionId = crossNetwork.activeRemoteDesktopSessionId {
                subscribeToCrossNetworkFrames(sessionId: sessionId)
            } else {
                cancelCrossNetworkFrameSubscription()
            }
            lastRequestedStreamRefreshReason = "cross-network-startup"
        }
        await pushViewerStreamConfiguration(
            force: true,
            refreshStream: activeTransportMode == .crossNetwork
        )
        scheduleFirstFrameWatchdog(for: streamEpoch)
        guard activeTransportMode != .lan || networkConnection != nil else {
            firstFrameWatchdogTask?.cancel()
            firstFrameWatchdogTask = nil
            isStreaming = false
            throw RemoteDesktopError.disconnected
        }
    }

    private func scheduleFirstFrameWatchdog(for epoch: UInt64) {
        firstFrameWatchdogTask?.cancel()
        firstFrameWatchdogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard self.streamEpoch == epoch,
                  self.state == .streaming,
                  !self.hasReceivedFrameInCurrentStream else { return }
            guard !self.handleCrossNetworkSessionAuthorityLostIfNeeded(source: "first-frame-watchdog") else {
                return
            }
            await self.requestStreamRefreshIfNeeded(reason: "first-frame-timeout", minimumInterval: 0)
            SkyBridgeLogger.shared.warning("⚠️ 远程桌面已发送流配置但 5 秒内未收到屏幕帧，已主动请求流刷新；若仍无画面，请检查 Mac 端录屏权限与采集状态")
        }
    }

    /// 便捷入口：从 Connection 启动远程桌面（UI 侧直接调用）
    public func startStreaming(from connection: Connection) async throws {
        if ProcessInfo.processInfo.arguments.contains("UITEST_SCENARIO_REMOTE") {
            currentConnection = connection
            activeTransportMode = .none
            isUsingCrossNetworkTransport = false
            hasReceivedFrameInCurrentStream = false
            isStreaming = true
            state = .streaming
            transportStatusText = "UITest Fixture"
            frameRate = 30
            latency = 12
            resolution = CGSize(width: 1440, height: 900)
            renderPipelineStatus = .stillImageFallback
            lastDamageRectCount = 0
            lastDamageUsesFullFrameFallback = false
            currentFrame = nil
            lastGoodFrozenFrame = nil
            flushRenderedVideoFeeds()
            configureSessionClipboardSync()
            return
        }

        if currentConnection?.device.id == connection.device.id, state == .streaming {
            await pushViewerStreamConfiguration(force: true)
            return
        }
        let matchesCurrentConnection = currentConnection.map { existing in
            areEquivalentRemoteDesktopDevices(existing.device, connection.device)
        } ?? false

        if matchesCurrentConnection {
            switch state {
            case .streaming:
                await pushViewerStreamConfiguration(force: true)
                return
            case .connecting:
                SkyBridgeLogger.shared.info(
                    "ℹ️ 远程桌面连接进行中，复用现有建连: \(currentConnection?.device.id ?? connection.device.id)"
                )
                return
            case .connected:
                try await startStreaming()
                return
            case .disconnected, .error:
                break
            }
        }

        // 若当前不是该设备的连接，或现有会话已失效，则建立新连接。
        switch state {
        case .disconnected, .error:
            try await connect(to: connection.device)
            return
        case .connecting, .connected, .streaming:
            break
        }

        if currentConnection == nil || matchesCurrentConnection == false {
            try await connect(to: connection.device)
            return
        }

        try await startStreaming()
    }

    /// 停止流媒体
    public func stopStreaming() async {
        SkyBridgeLogger.shared.info("⏹️ 停止远程桌面流")

        await sendViewerStreamStopConfigurationIfNeeded()
        isStreaming = false
        crossNetwork.stopRemoteDesktopHeartbeat()
        cancelCrossNetworkFrameSubscription()
        teardownRemoteAudioPlayback()
        realtimeMediaAudioReceiverStartTask?.cancel()
        realtimeMediaAudioReceiverStartTask = nil
        stopRealtimeMediaAudioReceiver(reason: "viewer-stop-streaming")
        resetStreamConfigurationAckState()
        configureSessionClipboardSync()
        lastSentStreamConfiguration = nil
        lastIncomingStreamSignature = nil
        resetRefreshDiagnostics()
        codecGovernance = .init()
        currentFrame = nil
        lastGoodFrozenFrame = nil
        flushRenderedVideoFeeds()
        pendingFrames.removeAll(keepingCapacity: true)
        decodeQueueWaitingForSyncFrame = false
        resetDecodeSequenceTracking()
        resetFrameTelemetry()
        renderPipelineStatus = .waiting
        lastDamageRectCount = 0
        lastDamageUsesFullFrameFallback = false
        currentCursorPayload = nil
        currentOverlayPayload = nil
#if canImport(UIKit)
        currentCursorImage = nil
#endif
        firstFrameWatchdogTask?.cancel()
        firstFrameContinuityTask?.cancel()
        interactionContinuityTask?.cancel()
        streamContinuityWatchdogTask?.cancel()
        firstFrameWatchdogTask = nil
        firstFrameContinuityTask = nil
        interactionContinuityTask = nil
        streamContinuityWatchdogTask = nil
        if state == .streaming {
            state = .connected
        }
    }

    /// 断开远程桌面流。
    /// - Parameter tearDownTransport: 为 `true` 时连带关闭底层跨网会话；默认仅停止视频/控制流，保留连接。
    public func disconnect(tearDownTransport: Bool = false) async {
        SkyBridgeLogger.shared.info(
            tearDownTransport ? "🔌 断开远程桌面连接" : "⏹️ 停止远程桌面流（保留连接）"
        )
        let wasCrossNetworkTransport = activeTransportMode == .crossNetwork
        let shouldDisconnectCrossNetworkSession = tearDownTransport && activeTransportMode == .crossNetwork
        let terminalConnection = currentConnection
        let shouldNotifyLANSessionEnd = tearDownTransport && activeTransportMode == .lan
        await sendViewerStreamStopConfigurationIfNeeded()
        crossNetwork.stopRemoteDesktopHeartbeat()
        cancelCrossNetworkFrameSubscription()
        firstFrameWatchdogTask?.cancel()
        firstFrameContinuityTask?.cancel()
        interactionContinuityTask?.cancel()
        streamContinuityWatchdogTask?.cancel()
        firstFrameWatchdogTask = nil
        firstFrameContinuityTask = nil
        interactionContinuityTask = nil
        streamContinuityWatchdogTask = nil
        lastSentStreamConfiguration = nil
        lastIncomingStreamSignature = nil
        resetRefreshDiagnostics()
        codecGovernance = .init()
        isStreaming = false
        teardownRemoteAudioPlayback()
        realtimeMediaAudioReceiverStartTask?.cancel()
        realtimeMediaAudioReceiverStartTask = nil
        stopRealtimeMediaAudioReceiver(reason: tearDownTransport ? "viewer-disconnect-transport" : "viewer-disconnect-stream")
        resetStreamConfigurationAckState()
        configureSessionClipboardSync()

        if !tearDownTransport {
            await decoder.cleanup()

            currentFrame = nil
            lastGoodFrozenFrame = nil
            flushRenderedVideoFeeds()
            renderPipelineStatus = .waiting
            lastDamageRectCount = 0
            lastDamageUsesFullFrameFallback = false
            currentCursorPayload = nil
            currentOverlayPayload = nil
#if canImport(UIKit)
            currentCursorImage = nil
#endif
            latency = 0
            resolution = .zero
            pendingFrames.removeAll()
            decodeQueueWaitingForSyncFrame = false
            resetDecodeSequenceTracking()
            resetFrameTelemetry()
            lastViewerInteractionAt = nil
            lastContinuityRecoveryAt = nil
            transportStatusText = currentTransportStatusText()

            let hasPreservedTransport = currentConnection != nil && activeTransportMode != .none
            state = hasPreservedTransport ? .connected : .disconnected

            if wasCrossNetworkTransport && hasPreservedTransport {
                crossNetwork.armIdleConnectionReminderIfNeeded()
            }
            return
        }

        // 关闭连接
        networkConnection?.stateUpdateHandler = nil
        networkConnection?.cancel()
        networkConnection = nil
        resetLANReceiveParserState(keepingCapacity: false)
        await clearLANSecureChannelState()
        activeTransportMode = .none
        isUsingCrossNetworkTransport = false
        transportStatusText = currentTransportStatusText()

        if shouldNotifyLANSessionEnd, let terminalConnection {
            await NotificationManager.sendRemoteDesktopTerminalNotificationIfNeeded(
                sessionId: terminalConnection.device.id,
                deviceName: terminalConnection.device.name,
                transport: "lan",
                role: "viewer",
                kind: .normal,
                reason: "viewer_disconnect_transport"
            )
        }

        if shouldDisconnectCrossNetworkSession {
            await crossNetwork.disconnect(clearSnapshot: true)
        }

        // 清理解码器
        await decoder.cleanup()

        // 重置状态
        currentConnection = nil
        currentFrame = nil
        lastGoodFrozenFrame = nil
        flushRenderedVideoFeeds()
        renderPipelineStatus = .waiting
        lastDamageRectCount = 0
        lastDamageUsesFullFrameFallback = false
        currentCursorPayload = nil
        currentOverlayPayload = nil
#if canImport(UIKit)
        currentCursorImage = nil
#endif
        state = .disconnected
        latency = 0
        resolution = .zero
        pendingFrames.removeAll()
        decodeQueueWaitingForSyncFrame = false
        resetDecodeSequenceTracking()
        resetFrameTelemetry()
        lastViewerInteractionAt = nil
        lastContinuityRecoveryAt = nil

        if wasCrossNetworkTransport && !shouldDisconnectCrossNetworkSession {
            crossNetwork.armIdleConnectionReminderIfNeeded()
        }
    }

    public func registerPresentationOwner(_ token: UUID) {
        activePresentationOwnerTokens.insert(token)
    }

    @discardableResult
    public func unregisterPresentationOwner(_ token: UUID) -> Bool {
        activePresentationOwnerTokens.remove(token)
        return activePresentationOwnerTokens.isEmpty
    }

    private func subscribeToCrossNetworkFrames(sessionId: String) {
        let normalizedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionId.isEmpty else {
            cancelCrossNetworkFrameSubscription()
            return
        }

        if crossNetworkFrameSubscriptionSessionId == normalizedSessionId,
           crossNetworkFrameSubscriptionTask != nil {
            return
        }

        cancelCrossNetworkFrameSubscription()
        crossNetworkFrameSubscriptionSessionId = normalizedSessionId
        crossNetworkFrameSubscriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await notification in NotificationCenter.default.notifications(named: .crossNetworkScreenDataUpdated) {
                guard !Task.isCancelled else { return }
                guard let updateSessionId = notification.userInfo?[CrossNetworkNotificationUserInfoKey.sessionId] as? String,
                      let screenData = notification.userInfo?[CrossNetworkNotificationUserInfoKey.screenData] as? ScreenData else {
                    continue
                }
                guard Self.shouldProcessCrossNetworkFrameNotification(
                    isStreaming: self.isStreaming,
                    subscribedSessionId: self.crossNetworkFrameSubscriptionSessionId,
                    expectedSessionId: normalizedSessionId,
                    updateSessionId: updateSessionId
                ) else {
                    continue
                }
                await self.handleScreenData(screenData)
            }
        }
    }

    private func cancelCrossNetworkFrameSubscription() {
        crossNetworkFrameSubscriptionTask?.cancel()
        crossNetworkFrameSubscriptionTask = nil
        crossNetworkFrameSubscriptionSessionId = nil
    }

    private func currentTransportStatusText() -> String? {
        switch activeTransportMode {
        case .none:
            return nil
        case .lan:
            if let lanSessionKeys {
                return "P2P / LAN · \(lanSessionKeys.negotiatedSuite.rawValue)"
            }
            return "P2P / LAN"
        case .crossNetwork:
            if case .handshakeComplete(_, let negotiatedSuite) = crossNetwork.readiness {
                return "WebRTC · \(negotiatedSuite)"
            }
            return "WebRTC"
        }
    }

    @MainActor
    func updateCrossNetworkNativeVideoResolution(_ size: CGSize) {
        guard activeTransportMode == .crossNetwork else { return }
        guard isStreaming else { return }
        guard size.width > 0, size.height > 0 else { return }
        let visibleSize = normalizedCrossNetworkNativeVideoVisibleFrameSize(forCodedSize: size)
        resolution = visibleSize
        crossNetwork.noteRemoteVideoTrackResolutionAvailable(
            visibleSize,
            source: "remote-desktop-resolution"
        )
    }

    @MainActor
    private func normalizedCrossNetworkNativeVideoVisibleFrameSize(forCodedSize codedSize: CGSize) -> CGSize {
        guard let expectedVisibleSize = expectedCrossNetworkNativeVideoVisibleFrameSize() else {
            return codedSize
        }
        let expectedWidth = Int(expectedVisibleSize.width)
        let expectedHeight = Int(expectedVisibleSize.height)
        let codedWidth = Int(codedSize.width)
        let codedHeight = Int(codedSize.height)
        let expectedCodedWidth = Self.evenNativeVideoBackingDimension(expectedWidth)
        let expectedCodedHeight = Self.evenNativeVideoBackingDimension(expectedHeight)
        if codedWidth == expectedCodedWidth, codedHeight == expectedCodedHeight {
            return expectedVisibleSize
        }
        if codedWidth == expectedWidth, codedHeight == expectedHeight {
            return expectedVisibleSize
        }
        return codedSize
    }

    private static func evenNativeVideoBackingDimension(_ visibleDimension: Int) -> Int {
        let sanitized = max(1, visibleDimension)
        return sanitized.isMultiple(of: 2) ? sanitized : sanitized + 1
    }

    @MainActor
    func expectedCrossNetworkNativeVideoVisibleFrameSize() -> CGSize? {
        guard activeTransportMode == .crossNetwork else { return nil }
        guard let payload = lastSentStreamConfiguration,
              payload.adaptiveResolutionEnabled != true,
              let width = payload.width,
              let height = payload.height,
              width > 0,
              height > 0 else {
            return nil
        }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    @MainActor
    func noteCrossNetworkNativeVideoFrame(_ size: CGSize) {
        guard activeTransportMode == .crossNetwork else { return }
        guard isStreaming else { return }
        let now = Date()
        if size.width > 0, size.height > 0 {
            resolution = size
        }
        hasReceivedFrameInCurrentStream = true
        noteReceivedFrame(at: now)
        noteDecodedFrame(at: now)
        noteDisplayedFrame(at: now)
        updateRenderPipeline(.webrtcNativeVideo)
        announceCrossNetworkNativeVideoReadyIfNeeded(force: false, now: now)
    }

    @MainActor
    private func announceCrossNetworkNativeVideoReadyIfNeeded(force: Bool, now: Date = Date()) {
        guard isStreaming else { return }
        let hasRenderedNativeFrame = crossNetwork.remoteVideoTrackHasRenderedFrame
        let shouldAnnounce = Self.shouldAnnounceCrossNetworkNativeVideoReady(
            activeTransportModeIsCrossNetwork: activeTransportMode == .crossNetwork,
            hasCurrentConnection: currentConnection != nil,
            hasRenderedNativeFrame: hasRenderedNativeFrame,
            lastSentNativeVideoTrackReady: lastSentStreamConfiguration?.nativeVideoTrackReady == true,
            force: force,
            lastAnnouncementAt: lastCrossNetworkNativeReadyAnnouncementAt,
            now: now
        )
        guard shouldAnnounce else { return }
        lastCrossNetworkNativeReadyAnnouncementAt = now
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.pushViewerStreamConfiguration(force: true)
        }
    }

    func canPresentRemoteDesktopOption(for device: DiscoveredDevice) -> Bool {
        if isCrossNetworkDevice(device) {
            return true
        }

        let deviceResolver = makeDeviceResolutionCoordinator()
        let resolved = deviceResolver.resolveLatestDevice(from: device)
        if deviceResolver.hasPeerAddressBackedFallback(for: resolved)
            || deviceResolver.hasPeerAddressBackedFallback(for: device) {
            return true
        }

        if resolved.platform == .macOS,
           resolved.isConnected,
           resolved.isTrusted {
            return true
        }

        if deviceResolver.hasReachableLANEndpoint(resolved)
            || resolved.supportsRemoteControl
            || deviceResolver.preferredServiceName(for: resolved) != nil {
            return true
        }

        return false
    }

    private func isCurrentLANConnection(_ connection: NWConnection) -> Bool {
        guard let current = networkConnection else { return false }
        return current === connection
    }

    private func isCurrentLANConnectionID(_ connectionID: ObjectIdentifier) -> Bool {
        guard let current = networkConnection else { return false }
        return ObjectIdentifier(current) == connectionID
    }

    private func ensureLANBootstrapStillActive(for connection: NWConnection) throws {
        guard Self.shouldContinueLANBootstrap(
            activeTransportModeIsLAN: activeTransportMode == .lan,
            isCurrentLANConnection: isCurrentLANConnection(connection),
            state: state
        ) else {
            throw RemoteDesktopError.disconnected
        }
    }

    private func handleTransportFailure(_ reason: String) async {
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let errorMessage = normalizedReason.isEmpty
            ? (RemoteDesktopError.disconnected.errorDescription ?? "连接已断开")
            : normalizedReason
        let failedTransport = transportStatusText ?? currentTransportStatusText() ?? "unknown"
        let failedConnection = currentConnection
        let failedConnectionId = failedConnection?.device.id ?? "-"
        let shouldDisconnectCrossNetworkSession = activeTransportMode == .crossNetwork

        SkyBridgeLogger.shared.error(
            "❌ 远程桌面传输失败: device=\(failedConnectionId) transport=\(failedTransport) reason=\(errorMessage)"
        )

        if activeTransportMode == .lan, let failedConnection {
            await NotificationManager.sendRemoteDesktopTerminalNotificationIfNeeded(
                sessionId: failedConnection.device.id,
                deviceName: failedConnection.device.name,
                transport: "lan",
                role: "viewer",
                kind: .interrupted,
                reason: errorMessage
            )
        } else if shouldDisconnectCrossNetworkSession {
            await crossNetwork.notifyRemoteDesktopInterruptedForActiveSession(reason: errorMessage)
        }

        crossNetwork.stopRemoteDesktopHeartbeat()
        firstFrameWatchdogTask?.cancel()
        firstFrameContinuityTask?.cancel()
        interactionContinuityTask?.cancel()
        streamContinuityWatchdogTask?.cancel()
        firstFrameWatchdogTask = nil
        firstFrameContinuityTask = nil
        interactionContinuityTask = nil
        streamContinuityWatchdogTask = nil
        networkConnection?.stateUpdateHandler = nil
        networkConnection?.cancel()
        networkConnection = nil
        resetLANReceiveParserState(keepingCapacity: false)
        await clearLANSecureChannelState()
        activeTransportMode = .none
        isUsingCrossNetworkTransport = false
        transportStatusText = currentTransportStatusText()
        lastSentStreamConfiguration = nil
        lastIncomingStreamSignature = nil
        resetRefreshDiagnostics()
        codecGovernance = .init()
        isStreaming = false
        teardownRemoteAudioPlayback()
        stopRealtimeMediaAudioReceiver(reason: "transport-failure:\(errorMessage)")
        configureSessionClipboardSync()
        if shouldDisconnectCrossNetworkSession {
            await crossNetwork.disconnect(clearSnapshot: true)
        }
        await decoder.cleanup()
        currentFrame = nil
        lastGoodFrozenFrame = nil
        flushRenderedVideoFeeds()
        renderPipelineStatus = .waiting
        lastDamageRectCount = 0
        lastDamageUsesFullFrameFallback = false
        currentCursorPayload = nil
        currentOverlayPayload = nil
#if canImport(UIKit)
        currentCursorImage = nil
#endif
        currentConnection = nil
        frameCount = 0
        lastFrameTime = nil
        lastRenderedFrameTime = nil
        consecutiveDecodeMisses = 0
        lastDecoderResetTime = nil
        hasReceivedFrameInCurrentStream = false
        lastViewerInteractionAt = nil
        lastContinuityRecoveryAt = nil
        latency = 0
        resolution = .zero
        pendingFrames.removeAll()
        decodeQueueWaitingForSyncFrame = false
        resetFrameTelemetry()
        state = .error(errorMessage)
    }

    private func effectiveSupportedRemoteVideoFormats(at now: Date = Date()) -> [String] {
        codecGovernance.effectiveSupportedFormats(from: Self.supportedRemoteVideoFormats(), at: now)
    }

    public func handleInboundRemoteClipboard(
        data: Data,
        mimeType: String,
        fromDeviceId: String? = nil
    ) {
        guard viewerSettings.clipboardSyncEnabled else { return }
        configureSessionClipboardSync()
        ClipboardManager.shared.setRemoteClipboard(
            data: data,
            mimeType: mimeType,
            fromDeviceId: fromDeviceId
        )
    }

    func handleInboundRemoteAudioChunk(_ payload: RemoteDesktopAudioChunkPayload) {
        guard viewerSettings.audioRedirectionEnabled, isStreaming else { return }
        guard acceptsLegacyRemoteAudioChunks else {
            SkyBridgeLogger.shared.debug("ℹ️ 已丢弃 legacy 远控音频块：当前会话要求 PQC media plane")
            return
        }
        let context = RemoteAudioPlaybackContext(
            generation: remoteAudioPlaybackGeneration,
            activeTransportModeIsCrossNetwork: activeTransportMode == .crossNetwork,
            nativeAudioReceiveEnabled: RemoteDesktopManagerRuntimeConfig.crossNetworkNativeAudioReceiveEnabled,
            remoteAudioTrackHasReceivedFirstPacket: crossNetwork.remoteAudioTrackHasReceivedFirstPacket,
            lastInboundScreenTimestamp: lastInboundScreenTimestamp
        )
        Task.detached(priority: .utility) { [remoteAudioPlayback] in
            await remoteAudioPlayback.handle(payload, context: context)
        }
    }

    var acceptsLegacyRemoteAudioChunks: Bool {
        guard lastSentStreamConfiguration?.audioRedirectionEnabled == true else { return false }
        let transport = lastSentStreamConfiguration?.audioTransport?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return lastSentStreamConfiguration?.compatibilityAudioFallbackEnabled == true
            || transport == "legacy-chunk-v1"
    }

    private var strictCrossNetworkMediaValidationActive: Bool {
        guard activeTransportMode == .crossNetwork else { return false }
        let mode = lastSentStreamConfiguration?.performanceValidationMode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let fallbackPolicy = lastSentStreamConfiguration?.mediaFallbackPolicy?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return mode == "extreme"
            || mode == "strict"
            || fallbackPolicy == "fail-fast"
            || fallbackPolicy == "disabled"
            || fallbackPolicy == "forbidden"
    }

    private func beginRemoteAudioPlaybackSession() {
        remoteAudioPlaybackGeneration &+= 1
    }

    private func teardownRemoteAudioPlayback(
        deactivateSession: Bool = true,
        resetFailureState: Bool = true
    ) {
        let generation = remoteAudioPlaybackGeneration
        remoteAudioPlaybackGeneration &+= 1
        Task.detached(priority: .utility) { [remoteAudioPlayback] in
            await remoteAudioPlayback.invalidate(
                upTo: generation,
                deactivateSession: deactivateSession,
                resetFailureState: resetFailureState
            )
        }
    }

    func handleInboundDamageReport(_ report: RemoteDesktopDamageReportPayload) {
        lastDamageRectCount = report.rects.count
        lastDamageUsesFullFrameFallback = report.fullFrameFallback
    }

    func handleInboundCursorUpdate(_ payload: RemoteDesktopCursorPayload) {
        currentCursorPayload = payload
#if canImport(UIKit)
        if let imageData = payload.imageData,
           let image = UIImage(data: imageData, scale: 1.0) {
            currentCursorImage = image
        }
#endif
    }

    func handleInboundOverlayUpdate(_ payload: RemoteDesktopOverlayPayload) {
        currentOverlayPayload = payload
    }

    private func scheduleViewerSettingsUpdate() {
        pendingViewerSettingsTask?.cancel()
        pendingViewerSettingsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self.configureSessionClipboardSync()
            await self.pushViewerStreamConfiguration(force: false)
        }
    }

    func handleCrossNetworkNativeVideoTrackRenderedFirstFrame() {
        announceCrossNetworkNativeVideoReadyIfNeeded(force: true)
    }

    @MainActor
    func handleCrossNetworkNativeVideoWarmupEvidence(reason: String) {
        guard activeTransportMode == .crossNetwork,
              isStreaming,
              currentConnection != nil,
              !crossNetwork.remoteVideoTrackHasRenderedFrame else {
            return
        }
        let now = Date()
        let canRequest = lastRefreshRequestAt.map { now.timeIntervalSince($0) >= 0.5 } ?? true
        guard canRequest else { return }
        lastRefreshRequestAt = now
        lastRequestedStreamRefreshReason = reason
        Task { @MainActor [weak self] in
            await self?.pushViewerStreamConfiguration(force: true, refreshStream: true)
        }
    }

    func handleCrossNetworkNativeVideoTrackPromotionReady() {
        SkyBridgeLogger.shared.debug("ℹ️ WebRTC 原生视频轨 promotion-ready 仅作诊断，nativeReady 等待真实渲染帧")
    }

    func handleCrossNetworkNativeAudioTrackReceivedFirstPacket() {
        teardownRemoteAudioPlayback(deactivateSession: false)
    }

    private func configureSessionClipboardSync() {
        let clipboard = ClipboardManager.shared
        let shouldEnable = viewerSettings.clipboardSyncEnabled
            && isStreaming
            && hasReceivedFrameInCurrentStream

        if shouldEnable {
            if clipboardSessionId == nil {
                clipboardSessionId = UUID()
            }
            if let clipboardSessionId {
                clipboard.enable(for: clipboardSessionId)
            }
            if clipboardListenerToken == nil {
                clipboardListenerToken = clipboard.addLocalClipboardListener { [weak self] data, mimeType in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.handleLocalClipboardChange(data: data, mimeType: mimeType)
                    }
                }
            }
        } else {
            if let token = clipboardListenerToken {
                clipboard.removeLocalClipboardListener(token)
                clipboardListenerToken = nil
            }
            if let clipboardSessionId {
                clipboard.disable(for: clipboardSessionId)
                self.clipboardSessionId = nil
            }
        }
    }

    private func handleLocalClipboardChange(data: Data, mimeType: String) async {
        guard viewerSettings.clipboardSyncEnabled, isStreaming else { return }
        do {
            let payload = RemoteClipboardMessagePayload(mimeType: mimeType, data: data)
            let encoded = try JSONEncoder().encode(payload)
            let message = RemoteMessage(type: .clipboard, payload: encoded)
            try await sendMessage(message)
        } catch {
            SkyBridgeLogger.shared.error("❌ 发送会话剪贴板失败: \(error.localizedDescription)")
        }
    }

    private func prepareRealtimeMediaAudioReceiverIfNeeded(
        mode: SkyBridgeMediaAudioMode,
        startGeneration: UInt64? = nil,
        startTime: Date = Date()
    ) async -> (endpoint: SkyBridgeMediaEndpoint, mediaSessionId: String)? {
        guard viewerSettings.audioRedirectionEnabled, isStreaming else {
            stopRealtimeMediaAudioReceiver(cancelPendingStart: false, reason: "audio-disabled-or-stream-not-active")
            return nil
        }
        guard isCurrentRealtimeMediaAudioReceiverStart(startGeneration) else { return nil }

        let snapshot: RemoteRealtimeMediaKeySnapshot?
        switch activeTransportMode {
        case .lan:
            snapshot = lanRealtimeMediaKeySnapshot()
        case .crossNetwork:
            snapshot = crossNetwork.realtimeMediaKeySnapshot()
        case .none:
            snapshot = nil
        }
        guard let snapshot else {
            SkyBridgeLogger.shared.info(
                "🎧 PQC media audio receiver skipped: transport=\(activeTransportModeLabel()) reason=missingMediaKeys"
            )
            stopRealtimeMediaAudioReceiver(cancelPendingStart: false, reason: "missing-media-keys")
            return nil
        }

        if (realtimeMediaAudioReceiver != nil || realtimeMediaAudioRelayTransport != nil),
           realtimeMediaAudioRenderer != nil,
           realtimeMediaAudioReceiverSessionId == snapshot.sessionId,
           let endpoint = realtimeMediaAudioEndpoint,
           Self.isUsableRealtimeMediaAudioEndpoint(endpoint) {
            return (endpoint, snapshot.sessionId)
        }
        guard isCurrentRealtimeMediaAudioReceiverStart(startGeneration) else { return nil }

        do {
            let renderer: IOSRealtimeMediaAudioReceiver
            let endpoint: SkyBridgeMediaEndpoint
            switch activeTransportMode {
            case .crossNetwork:
                updateRealtimeMediaAudioReceiverStartPhase(.lease, generation: startGeneration)
                SkyBridgeLogger.shared.info(
                    "🎧 PQC media relay lease request: session=\(snapshot.sessionId) mode=\(mode.rawValue) transport=\(activeTransportModeLabel())"
                )
                let leaseTimeoutTask = scheduleRealtimeMediaAudioReceiverStageTimeout(
                    phase: .lease,
                    mode: mode,
                    generation: startGeneration,
                    startTime: startTime
                )
                let relayEndpointPair: CrossNetworkWebRTCManager.RealtimeMediaRelayEndpointPair?
                do {
                    relayEndpointPair = try await crossNetwork.requestRealtimeMediaRelayEndpointForActiveSession()
                } catch {
                    leaseTimeoutTask?.cancel()
                    throw error
                }
                leaseTimeoutTask?.cancel()
                guard let relayEndpointPair else {
                    let reason = crossNetwork.mediaRelayLeaseDiagnosticForActiveSession() ?? "unknown"
                    SkyBridgeLogger.shared.info("🎧 PQC media relay lease unavailable; keeping WebRTC video-only reason=\(reason)")
                    return nil
                }
                let relayEndpoint = relayEndpointPair.localEndpoint
                guard isCurrentRealtimeMediaAudioReceiverStart(startGeneration) else { return nil }
                SkyBridgeLogger.shared.info(
                    "🎧 PQC media audio receiver lease ready: event=leaseReady session=\(snapshot.sessionId) role=\(relayEndpointPair.localRole) relay=\(relayEndpoint.host):\(relayEndpoint.port) token=\(relayEndpoint.relayToken == nil ? "missing" : "present") transport=\(activeTransportModeLabel())"
                )
                stopRealtimeMediaAudioReceiver(cancelPendingStart: false, reason: "replace-receiver-for-cross-network-endpoint")
                renderer = try IOSRealtimeMediaAudioReceiver(snapshot: snapshot, mode: mode)
                realtimeMediaAudioRenderer = renderer
                realtimeMediaAudioReceiverSessionId = snapshot.sessionId
                realtimeMediaAudioEndpoint = relayEndpoint
                let strictRelayBindRequired = Self.shouldRequestExtremeMediaValidation(
                    activeTransportModeIsCrossNetwork: activeTransportMode == .crossNetwork,
                    viewerSettings: viewerSettings
                )
                let relayBindPolicy: SkyBridgeRealtimeMediaRelayBindPolicy =
                    strictRelayBindRequired ? .requireAcknowledgement : .optimisticAfterSend
                let relayTransport = SkyBridgeUDPRealtimeMediaTransport(
                    endpoint: relayEndpoint,
                    receiveHandler: { [renderer] datagram in
                        Task.detached(priority: .utility) {
                            await renderer.handle(datagram: datagram)
                        }
                    },
                    relayBindPolicy: relayBindPolicy,
                    startEventHandler: { [weak self] event in
                        Task { @MainActor [weak self] in
                            self?.handleRealtimeMediaAudioRelayTransportEvent(
                                event,
                                sessionId: snapshot.sessionId,
                                endpoint: relayEndpoint,
                                generation: startGeneration
                            )
                        }
                    }
                )
                updateRealtimeMediaAudioReceiverStartPhase(.udpConnection, generation: startGeneration)
                SkyBridgeLogger.shared.info(
                    "🎧 PQC media audio receiver UDP connection started: event=udpConnectionStarted session=\(snapshot.sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port) transport=\(activeTransportModeLabel())"
                )
                let udpBindTimeoutTask = scheduleRealtimeMediaAudioReceiverStageTimeout(
                    phase: .udpConnection,
                    mode: mode,
                    generation: startGeneration,
                    startTime: startTime
                )
                do {
                    try await relayTransport.start()
                } catch {
                    udpBindTimeoutTask?.cancel()
                    throw error
                }
                udpBindTimeoutTask?.cancel()
                updateRealtimeMediaAudioReceiverStartPhase(.receiverReady, generation: startGeneration)
                SkyBridgeLogger.shared.info(
                    "🎧 PQC media audio receiver UDP path ready: event=udpPathReady session=\(snapshot.sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port) transport=\(activeTransportModeLabel())"
                )
                guard isCurrentRealtimeMediaAudioReceiverStart(startGeneration) else {
                    await relayTransport.stop()
                    await renderer.close(reason: "stale-receiver-start-generation-after-cross-network-bind")
                    return nil
                }
                realtimeMediaAudioRelayTransport = relayTransport
                endpoint = relayEndpoint
                SkyBridgeLogger.shared.info(
                    "🎧 PQC media audio endpoint published after relay bind policy satisfied: event=audioEndpointPrepared session=\(snapshot.sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port) token=\(relayEndpoint.relayToken == nil ? "missing" : "present") transport=\(activeTransportModeLabel())"
                )
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx endpointPrepared session=\(snapshot.sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port)"
                )
                SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                    [
                        "kind": "audioRxEndpointPrepared",
                        "session": snapshot.sessionId,
                        "session_id": snapshot.sessionId,
                        "relay": "\(relayEndpoint.host):\(relayEndpoint.port)",
                        "role": relayEndpointPair.localRole,
                        "relayTokenPresent": relayEndpoint.relayToken != nil
                    ]
                )
                await pushViewerStreamConfiguration(force: false, refreshStream: false)
            case .lan:
                updateRealtimeMediaAudioReceiverStartPhase(.lease, generation: startGeneration)
                SkyBridgeLogger.shared.info(
                    "🎧 PQC media audio receiver lease ready: event=leaseReady session=\(snapshot.sessionId) transport=\(activeTransportModeLabel()) source=lan-session-keys"
                )
                guard isCurrentRealtimeMediaAudioReceiverStart(startGeneration) else { return nil }
                stopRealtimeMediaAudioReceiver(cancelPendingStart: false, reason: "replace-receiver-for-lan-endpoint")
                renderer = try IOSRealtimeMediaAudioReceiver(snapshot: snapshot, mode: mode)
                let receiver = SkyBridgeUDPRealtimeMediaReceiver()
                updateRealtimeMediaAudioReceiverStartPhase(.udpConnection, generation: startGeneration)
                SkyBridgeLogger.shared.info(
                    "🎧 PQC media audio receiver UDP bind started: event=udpBindStarted session=\(snapshot.sessionId) transport=\(activeTransportModeLabel())"
                )
                let udpBindTimeoutTask = scheduleRealtimeMediaAudioReceiverStageTimeout(
                    phase: .udpConnection,
                    mode: mode,
                    generation: startGeneration,
                    startTime: startTime
                )
                do {
                    endpoint = try await receiver.start { [renderer] datagram in
                        Task.detached(priority: .utility) {
                            await renderer.handle(datagram: datagram)
                        }
                    }
                } catch {
                    udpBindTimeoutTask?.cancel()
                    throw error
                }
                udpBindTimeoutTask?.cancel()
                guard isCurrentRealtimeMediaAudioReceiverStart(startGeneration) else {
                    receiver.stop()
                    await renderer.close(reason: "stale-receiver-start-generation-after-lan-bind")
                    return nil
                }
                realtimeMediaAudioReceiver = receiver
            case .none:
                return nil
            }
            guard isCurrentRealtimeMediaAudioReceiverStart(startGeneration) else { return nil }
            realtimeMediaAudioRenderer = renderer
            realtimeMediaAudioReceiverSessionId = snapshot.sessionId
            realtimeMediaAudioEndpoint = endpoint
            scheduleRealtimeMediaAudioEndpointRenewal(
                sessionId: snapshot.sessionId,
                endpoint: endpoint,
                mode: mode
            )
            scheduleRealtimeMediaAudioNoTrafficRecovery(
                sessionId: snapshot.sessionId,
                endpoint: endpoint,
                renderer: renderer,
                mode: mode
            )
            SkyBridgeLogger.shared.info(
                "🎧 PQC media audio receiver ready: session=\(snapshot.sessionId) port=\(endpoint.port) mode=\(mode.rawValue) transport=\(activeTransportModeLabel()) codec=opus audioPath=pqc-opus-source-node-ring relayToken=\(endpoint.relayToken == nil ? "missing" : "present") legacyFallback=false"
            )
            Task.detached(priority: .utility) { [renderer, sessionId = snapshot.sessionId, endpoint, mode] in
                try? await Task.sleep(for: .seconds(3))
                let snapshot = await renderer.startupDiagnosticSnapshot()
                if snapshot.received == 0 {
                    let probable: String = {
                        if snapshot.datagramsSeen == 0 {
                            return "host-not-sending-or-relay-blocked"
                        }
                        if snapshot.sessionHashRejected > 0 {
                            return "session-hash-rejected"
                        }
                        if snapshot.authRejected > 0 {
                            return "auth-decrypt-rejected"
                        }
                        if snapshot.sourceRejected > 0 {
                            return "source-rejected"
                        }
                        if snapshot.replayRejected > 0 {
                            return "replay-rejected"
                        }
                        return "rx-not-accepted"
                    }()
                    SkyBridgeLogger.shared.warning(
                        "🎧 PQC media audio rx startup stalled: session=\(sessionId) relay=\(endpoint.host):\(endpoint.port) mode=\(mode.rawValue) audioRxDatagrams=\(snapshot.datagramsSeen) audioRxRecv=0 audioRxDecoded=\(snapshot.decoded) audioRxPlayed=\(snapshot.played) rejected=\(snapshot.rejected) authRejected=\(snapshot.authRejected) sessionHashRejected=\(snapshot.sessionHashRejected) replayRejected=\(snapshot.replayRejected) sourceReject=\(snapshot.sourceRejected) sourceMigrate=\(snapshot.sourceMigrated) probable=\(probable)"
                    )
                    SkyBridgeSmokeTraceWriter.append(
                        "audio-rx session=\(sessionId) audioRxDatagrams=\(snapshot.datagramsSeen) audioRxRecv=0 audioRxDecoded=\(snapshot.decoded) audioRxPlayed=\(snapshot.played) recvTotal=\(snapshot.received) decodeTotal=\(snapshot.decoded) playTotal=\(snapshot.played) rejected=\(snapshot.rejected) authRejected=\(snapshot.authRejected) sessionHashRejected=\(snapshot.sessionHashRejected) replayRejected=\(snapshot.replayRejected) sourceReject=\(snapshot.sourceRejected) sourceMigrate=\(snapshot.sourceMigrated) relay=\(endpoint.host):\(endpoint.port) mode=\(mode.rawValue) probable=\(probable)"
                    )
                    SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                        [
                            "kind": "audioRxStartup",
                            "session": sessionId,
                            "session_id": sessionId,
                            "audioRxDatagrams": snapshot.datagramsSeen,
                            "audioRxRecv": UInt64(0),
                            "audioRxDecoded": snapshot.decoded,
                            "audioRxPlayed": snapshot.played,
                            "recvTotal": snapshot.received,
                            "decodeTotal": snapshot.decoded,
                            "playTotal": snapshot.played,
                            "rejected": snapshot.rejected,
                            "authRejected": snapshot.authRejected,
                            "sessionHashRejected": snapshot.sessionHashRejected,
                            "replayRejected": snapshot.replayRejected,
                            "sourceReject": snapshot.sourceRejected,
                            "sourceMigrate": snapshot.sourceMigrated,
                            "relay": "\(endpoint.host):\(endpoint.port)",
                            "mode": mode.rawValue,
                            "probable": probable
                        ]
                    )
                }
            }
            return (endpoint, snapshot.sessionId)
        } catch {
            guard isCurrentRealtimeMediaAudioReceiverStart(startGeneration) else { return nil }
            SkyBridgeLogger.shared.warning(
                "⚠️ PQC media audio receiver unavailable; keeping video-only: \(error.localizedDescription)"
            )
            stopRealtimeMediaAudioReceiver(cancelPendingStart: false, reason: "receiver-start-failed:\(error.localizedDescription)")
            return nil
        }
    }

    private func isCurrentRealtimeMediaAudioReceiverStart(_ generation: UInt64?) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let generation else { return true }
        return realtimeMediaAudioReceiverStartGeneration == generation
    }

    private func lanRealtimeMediaKeySnapshot() -> RemoteRealtimeMediaKeySnapshot? {
        guard activeTransportMode == .lan,
              let keys = lanSessionKeys else {
            return nil
        }
        return RemoteRealtimeMediaKeySnapshot(
            sessionId: Self.lanRealtimeMediaSessionId(for: keys),
            sendKey: keys.sendKey,
            receiveKey: keys.receiveKey,
            localRole: keys.role,
            transcriptHash: keys.transcriptHash,
            mediaAdmissionToken: nil
        )
    }

    private func stopRealtimeMediaAudioReceiver(
        cancelPendingStart: Bool = true,
        reason: String = "unspecified"
    ) {
        let receiverSessionId = realtimeMediaAudioReceiverSessionId ?? "-"
        let endpointLabel = realtimeMediaAudioEndpoint.map { "\($0.host):\($0.port)" } ?? "-"
        if realtimeMediaAudioReceiver != nil
            || realtimeMediaAudioRelayTransport != nil
            || realtimeMediaAudioRenderer != nil
            || realtimeMediaAudioReceiverStartTask != nil {
            let line =
                "audioRxStop session=\(receiverSessionId) reason=\(reason) " +
                "transport=\(activeTransportModeLabel()) endpoint=\(endpointLabel) cancelPendingStart=\(cancelPendingStart)"
            SkyBridgeLogger.shared.info("🎧 \(line)")
            SkyBridgeSmokeTraceWriter.appendStatus(line)
        }
        if cancelPendingStart {
            realtimeMediaAudioReceiverStartGeneration &+= 1
            realtimeMediaAudioReceiverStartTask?.cancel()
            realtimeMediaAudioReceiverStartTask = nil
            realtimeMediaAudioReceiverStartPhase = nil
        }
        realtimeMediaAudioRelayBindGraceTask?.cancel()
        realtimeMediaAudioRelayBindGraceTask = nil
        realtimeMediaAudioRelayRenewalTask?.cancel()
        realtimeMediaAudioRelayRenewalTask = nil
        realtimeMediaAudioNoTrafficRecoveryTask?.cancel()
        realtimeMediaAudioNoTrafficRecoveryTask = nil
        realtimeMediaAudioRelayBindState = .idle
        realtimeMediaAudioReceiver?.stop()
        if let relayTransport = realtimeMediaAudioRelayTransport {
            Task(priority: .utility) {
                await relayTransport.stop()
            }
        }
        if let renderer = realtimeMediaAudioRenderer {
            Task(priority: .utility) { [reason] in
                await renderer.close(reason: reason)
            }
        }
        realtimeMediaAudioReceiver = nil
        realtimeMediaAudioRelayTransport = nil
        realtimeMediaAudioRenderer = nil
        realtimeMediaAudioReceiverSessionId = nil
        realtimeMediaAudioEndpoint = nil
    }

    private func pushViewerStreamConfiguration(force: Bool, refreshStream: Bool = false) async {
        guard isStreaming else { return }
        guard !handleCrossNetworkSessionAuthorityLostIfNeeded(source: "stream-config") else { return }
        let mediaAudioMode = preferredRealtimeMediaAudioMode()
        let mediaAudioBinding = currentRealtimeMediaAudioBindingIfUsable()
        let preparationPlan = RemoteDesktopViewerStreamConfigurationPushPolicy.prepare(
            activeTransportMode: activeTransportMode,
            hasCurrentConnection: currentConnection != nil,
            hasLANConnection: networkConnection != nil,
            audioRedirectionEnabled: viewerSettings.audioRedirectionEnabled,
            hasUsableMediaAudioBinding: mediaAudioBinding != nil,
            refreshStream: refreshStream,
            lastSentMediaAudioEndpointPresent: lastSentStreamConfiguration?.mediaAudioEndpoint != nil,
            lastAcknowledgedMediaAudioEndpointPresent: lastAcknowledgedMediaAudioEndpointPresent
        )
        guard preparationPlan.canSend else { return }
        if preparationPlan.shouldStartRealtimeMediaAudioReceiver {
            ensureRealtimeMediaAudioReceiverStartedIfNeeded(mode: mediaAudioMode)
        } else if preparationPlan.shouldStopRealtimeMediaAudioReceiver {
            realtimeMediaAudioReceiverStartTask?.cancel()
            realtimeMediaAudioReceiverStartTask = nil
            stopRealtimeMediaAudioReceiver(reason: "stream-config-plan-stop-audio")
        }
        let payload = makeViewerStreamConfigurationPayload(
            refreshStream: refreshStream,
            mediaAudioEndpoint: preparationPlan.includeAudioEndpointInStreamConfig ? mediaAudioBinding?.endpoint : nil,
            mediaSessionId: preparationPlan.includeAudioEndpointInStreamConfig ? mediaAudioBinding?.mediaSessionId : nil
        )
        guard validateViewerStreamConfigurationNoticeIdentity(payload) else { return }
        guard RemoteDesktopViewerStreamConfigurationPushPolicy.shouldSendPayload(
            force: force,
            payloadMatchesLastSent: payload == lastSentStreamConfiguration
        ) else { return }
        do {
            try await sendViewerStreamConfigurationPayload(payload, retryAttempt: nil)
            lastSentStreamConfiguration = payload
            if payload.mediaAudioEndpoint != nil {
                lastAcknowledgedMediaAudioEndpointPresent = false
            }
            if preparationPlan.includeAudioEndpointInStreamConfig, payload.mediaAudioEndpoint != nil {
                SkyBridgeLogger.shared.info(
                    "🎧 PQC media audio-present config sent: event=audioPresentConfigSent refreshStream=\(payload.streamRefreshToken != nil) mediaSession=\(payload.mediaSessionId ?? "-") audioRelayToken=\(payload.mediaAudioEndpoint?.relayToken == nil ? "missing" : "present") transport=\(activeTransportModeLabel())"
                )
            }
            if let token = payload.streamRefreshToken {
                let now = Date()
                lastRequestedStreamRefreshToken = token
                lastRequestedStreamRefreshAt = now
                lastRefreshRequestFailureDescription = nil
                lastWaitingSyncDiagnosticLogTime = .distantPast
                SkyBridgeLogger.shared.info(
                    "🪄 viewer 已发送关键帧刷新请求: refreshTokenState=present reason=\(lastRequestedStreamRefreshReason ?? "unspecified") transport=\(activeTransportModeLabel()) summary=\(crossNetwork.remoteDesktopRecoveryDebugSummary())"
                )
            }
            scheduleStreamConfigurationAckRetryIfNeeded(for: payload)
        } catch {
            if payload.streamRefreshToken != nil {
                lastRefreshRequestFailureDescription = error.localizedDescription
                SkyBridgeLogger.shared.error(
                    "❌ viewer 关键帧刷新请求发送失败: refreshTokenState=present reason=\(lastRequestedStreamRefreshReason ?? "unspecified") err=\(error.localizedDescription) transport=\(activeTransportModeLabel()) summary=\(crossNetwork.remoteDesktopRecoveryDebugSummary())"
                )
            }
            SkyBridgeLogger.shared.error("❌ 发送远控流配置失败: \(error.localizedDescription)")
        }
    }

    private func sendViewerStreamConfigurationPayload(
        _ payload: RemoteDesktopStreamConfigurationPayload,
        retryAttempt: Int?
    ) async throws {
        guard validateViewerStreamConfigurationNoticeIdentity(payload) else {
            throw RemoteDesktopError.streamingFailed("missing viewer remote-control notice identity")
        }
        let encoded = try JSONEncoder().encode(payload)
        let message = RemoteMessage(type: .streamConfiguration, payload: encoded)
        try await sendMessage(message)
        let retrySuffix = retryAttempt.map { " retryAttempt=\($0)" } ?? ""
        let noticeIdentity = payload.remoteControlSecurityIdentity
        let streamConfigLine = "event=streamConfigSent\(retrySuffix) preset=\(viewerSettings.activePreset.displayName), preferred=\(payload.preferredCodec ?? "auto"), formats=\(payload.supportedVideoFormats.joined(separator: ",")), fps=\(payload.targetFrameRate), jitter=\(payload.jitterBufferFrames ?? 0), lowLatency=\(payload.lowLatencyMode) damage=\(payload.damageTrackingEnabled == true) audioMode=\(payload.audioMode ?? "nil") perf=\(payload.performanceValidationMode ?? "normal") refresh=\(payload.streamRefreshToken != nil) refreshTokenState=\(Self.streamRefreshTokenLogState(payload.streamRefreshToken)) transport=\(payload.screenFrameTransport ?? "legacy") screenChannel=\(payload.screenDataChannelEnabled == true) screenWire=\(payload.screenChannelWireFormat ?? "length-framed") nativeReady=\(payload.nativeVideoTrackReady == true) streamConfigIncludesAudio=\(payload.mediaAudioEndpoint != nil) audioEndpointAck=\(lastAcknowledgedMediaAudioEndpointPresent) audioTransport=\(payload.audioTransport ?? "nil") mediaSession=\(payload.mediaSessionId ?? "-") audioRelayToken=\(payload.mediaAudioEndpoint?.relayToken == nil ? "missing" : "present") noticeAccount=\(Self.noticeIdentityValuePresent(noticeIdentity?.accountDisplayName) ? "present" : "missing") noticeNebula=\(Self.noticeIdentityValuePresent(noticeIdentity?.nebulaId) ? "present" : "missing")"
        SkyBridgeSmokeTraceWriter.appendStatus(streamConfigLine)
        SkyBridgeLogger.shared.info("📤 已发送远控流配置: \(streamConfigLine)")
    }

    private func validateViewerStreamConfigurationNoticeIdentity(
        _ payload: RemoteDesktopStreamConfigurationPayload
    ) -> Bool {
        guard Self.requiresNoticeIdentity(payload) else { return true }

        let identity = payload.remoteControlSecurityIdentity
        var missing: [String] = []
        if !Self.noticeIdentityValuePresent(identity?.accountDisplayName) {
            missing.append("account")
        }
        if !Self.noticeIdentityValuePresent(identity?.nebulaId) {
            missing.append("nebula")
        }
        guard missing.isEmpty else {
            let missingList = missing.joined(separator: ",")
            let reason = "missing_viewer_notice_identity"
            SkyBridgeSmokeTraceWriter.appendStatus(
                "failed stage=remote-control phase=notice-identity reason=\(reason) missing=\(missingList) transport=\(activeTransportModeLabel())"
            )
            SkyBridgeLogger.shared.error(
                "⛔️ 远控安全身份不完整，拒绝发送 viewer 流配置: missing=\(missingList) transport=\(activeTransportModeLabel())"
            )
            state = .error("远控安全身份不完整: \(missingList)")
            isStreaming = false
            return false
        }
        return true
    }

    private static func requiresNoticeIdentity(_ payload: RemoteDesktopStreamConfigurationPayload) -> Bool {
        if payload.targetFrameRate <= 0 { return false }
        let refreshStrategy = payload.refreshStrategy?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if refreshStrategy == "stop" { return false }
        let transport = payload.screenFrameTransport?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return transport != "stopped"
    }

    private static func noticeIdentityValuePresent(_ value: String?) -> Bool {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return false
        }
        return trimmed != "-" && trimmed.lowercased() != "missing"
    }

    private static func streamRefreshTokenLogState(_ token: UInt64?) -> String {
        token == nil ? "missing" : "present"
    }

	    private func scheduleStreamConfigurationAckRetryIfNeeded(
	        for payload: RemoteDesktopStreamConfigurationPayload
	    ) {
	        // Retry only video/main configs. A startup refresh token is resent as
	        // the same stable payload, so this does not allocate new keyframes.
	        guard RemoteDesktopViewerStreamConfigurationPushPolicy.shouldScheduleAckRetry(
	            activeTransportMode: activeTransportMode,
	            isStreaming: isStreaming,
	            hasReceivedFrameInCurrentStream: hasReceivedFrameInCurrentStream,
	            payloadIncludesAudioEndpoint: payload.mediaAudioEndpoint != nil
	        ) else {
	            return
	        }
        streamConfigurationAckSatisfied = false
        streamConfigurationAckGeneration &+= 1
        let generation = streamConfigurationAckGeneration
        streamConfigurationAckTask?.cancel()
        streamConfigurationAckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let delays = [1, 2, 4]
            for (index, delay) in delays.enumerated() {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard self.streamConfigurationAckGeneration == generation,
                      self.isStreaming,
                      self.activeTransportMode == .crossNetwork,
                      !self.hasReceivedFrameInCurrentStream,
                      !self.streamConfigurationAckSatisfied else {
                    return
                }
                guard !self.handleCrossNetworkSessionAuthorityLostIfNeeded(source: "stream-config-ack-retry") else {
                    return
                }
                do {
                    try await self.sendViewerStreamConfigurationPayload(payload, retryAttempt: index + 1)
                } catch {
                    SkyBridgeLogger.shared.warning("⚠️ streamConfigurationAck 等待期间重发远控流配置失败: attempt=\(index + 1) err=\(error.localizedDescription)")
                }
            }
        }
    }

    public func handleStreamConfigurationAck(_ ack: RemoteDesktopStreamConfigurationAckPayload) {
        guard isStreaming else { return }
        streamConfigurationAckSatisfied = true
        streamConfigurationAckTask?.cancel()
        streamConfigurationAckTask = nil
        lastAcknowledgedMediaAudioEndpointPresent = ack.audioEndpointPresent
        SkyBridgeLogger.shared.info(
            "✅ 收到远控流配置 ACK: event=streamConfigAck refreshTokenState=\(Self.streamRefreshTokenLogState(ack.streamRefreshToken)) audioEndpoint=\(ack.audioEndpointPresent) transport=\(ack.screenFrameTransport ?? "legacy")"
        )
    }

    private func sendViewerStreamStopConfigurationIfNeeded() async {
        let canSendOverWebRTC = activeTransportMode == .crossNetwork && currentConnection != nil
        let canSendOverLAN = activeTransportMode == .lan && networkConnection != nil
        guard canSendOverWebRTC || canSendOverLAN else { return }

        let payload = makeViewerStreamStopConfigurationPayload()
        do {
            let encoded = try JSONEncoder().encode(payload)
            let message = RemoteMessage(type: .streamConfiguration, payload: encoded)
            try await sendMessage(message)
            lastSentStreamConfiguration = payload
            lastAcknowledgedMediaAudioEndpointPresent = false
            SkyBridgeLogger.shared.info("📤 已发送远控停止流配置: transport=\(activeTransportModeLabel())")
        } catch {
            SkyBridgeLogger.shared.error("❌ 发送远控停止流配置失败: \(error.localizedDescription)")
        }
    }

    private func makeViewerStreamStopConfigurationPayload() -> RemoteDesktopStreamConfigurationPayload {
        RemoteDesktopViewerStreamConfigurationFactory.stopPayload()
    }

    func makeViewerStreamConfigurationPayload() -> RemoteDesktopStreamConfigurationPayload {
        makeViewerStreamConfigurationPayload(refreshStream: false)
    }

    func makeViewerStreamConfigurationPayload(
        refreshStream: Bool,
        mediaAudioEndpoint: SkyBridgeMediaEndpoint? = nil,
        mediaSessionId: String? = nil
    ) -> RemoteDesktopStreamConfigurationPayload {
        let now = Date()
        let strictMediaValidationEnabled = Self.shouldRequestExtremeMediaValidation(
            activeTransportModeIsCrossNetwork: activeTransportMode == .crossNetwork,
            viewerSettings: viewerSettings
        )
        let supportedFormats = effectiveSupportedRemoteVideoFormats(at: now)
            .filter { $0 != "jpeg" && $0 != "jpg" && $0 != "bgra" }
        let preferredCodec = codecGovernance.effectivePreferredCodec(
            userPreference: viewerSettings.preferredCodec,
            supportedFormats: supportedFormats,
            at: now
        )
        let smokeDimensions = RemoteDesktopSmokeStreamOverrides.requestedDimensions()
        let smokeTargetFrameRate = RemoteDesktopSmokeStreamOverrides.targetFrameRate()
        let realtimeMediaAudioMode = preferredRealtimeMediaAudioMode()
        let streamRefreshToken = refreshStream ? nextStreamRefreshToken() : nil
        let localDeviceSnapshot = AppleMobileDeviceIdentity.currentSnapshot()
        let securityIdentityMetadata = AuthenticationManager.instance.remoteControlSecurityIdentityMetadata
        let securityIdentity = RemoteDesktopSecurityIdentityPayload(
            accountDisplayName: securityIdentityMetadata.accountDisplayName,
            nebulaId: securityIdentityMetadata.nebulaId,
            deviceId: localDeviceSnapshot.stableDeviceId,
            deviceName: localDeviceSnapshot.deviceName
        )

        return RemoteDesktopViewerStreamConfigurationFactory.makePayload(
            .init(
                viewerSettings: viewerSettings,
                supportedVideoFormats: supportedFormats,
                preferredCodec: preferredCodec,
                activeTransportMode: activeTransportMode,
                strictMediaValidationEnabled: strictMediaValidationEnabled,
                hasRenderedCrossNetworkNativeFrame: crossNetwork.remoteVideoTrackHasRenderedFrame,
                nativeAudioReceiveEnabled: RemoteDesktopManagerRuntimeConfig.crossNetworkNativeAudioReceiveEnabled,
                realtimeMediaAudioMode: realtimeMediaAudioMode,
                mediaAudioEndpoint: mediaAudioEndpoint,
                mediaSessionId: mediaSessionId,
                streamRefreshToken: streamRefreshToken,
                securityIdentity: securityIdentity,
                smokeDimensions: smokeDimensions,
                smokeTargetFrameRate: smokeTargetFrameRate
            )
        )
    }

    private func preferredRealtimeMediaAudioMode() -> SkyBridgeMediaAudioMode {
        viewerSettings.lowLatencyMode ? .lowLatency : .highFidelity
    }

    private func nextStreamRefreshToken() -> UInt64 {
        streamRefreshTokenCounter &+= 1
        if streamRefreshTokenCounter == 0 {
            streamRefreshTokenCounter = 1
        }
        return streamRefreshTokenCounter
    }

    private func resetRefreshDiagnostics() {
        lastRefreshRequestAt = nil
        lastRequestedStreamRefreshToken = nil
        lastRequestedStreamRefreshReason = nil
        lastRequestedStreamRefreshAt = nil
        lastRefreshRequestFailureDescription = nil
        hevcDisableRefreshSuppressedUntil = nil
        hevcDisableRefreshTokenInFlight = nil
        lastWaitingSyncDiagnosticLogTime = .distantPast
    }

    private func resetStreamConfigurationAckState() {
        streamConfigurationAckGeneration &+= 1
        streamConfigurationAckTask?.cancel()
        streamConfigurationAckTask = nil
        streamConfigurationAckSatisfied = false
        lastAcknowledgedMediaAudioEndpointPresent = false
    }

    private var crossNetworkSessionAuthorityLost: Bool {
        guard activeTransportMode == .crossNetwork else { return false }
        if case .failed(let message) = crossNetwork.state {
            return message == "sessionAuthorityLost"
        }
        return false
    }

    @discardableResult
    private func handleCrossNetworkSessionAuthorityLostIfNeeded(source: String) -> Bool {
        guard crossNetworkSessionAuthorityLost else { return false }
        resetStreamConfigurationAckState()
        firstFrameWatchdogTask?.cancel()
        firstFrameWatchdogTask = nil
        firstFrameContinuityTask?.cancel()
        firstFrameContinuityTask = nil
        realtimeMediaAudioReceiverStartGeneration &+= 1
        realtimeMediaAudioReceiverStartTask?.cancel()
        realtimeMediaAudioReceiverStartTask = nil
        realtimeMediaAudioReceiverStartPhase = nil
        realtimeMediaAudioRelayBindGraceTask?.cancel()
        realtimeMediaAudioRelayBindGraceTask = nil
        realtimeMediaAudioRelayBindState = .idle
        stopRealtimeMediaAudioReceiver(cancelPendingStart: false, reason: "session-authority-lost:\(source)")
        isStreaming = false
        state = .error("sessionAuthorityLost")
        renderPipelineStatus = .waiting
        if lastHandledSessionAuthorityLostStreamEpoch != streamEpoch {
            lastHandledSessionAuthorityLostStreamEpoch = streamEpoch
            SkyBridgeLogger.shared.warning(
                "🎧 远控流停止等待完整 WebRTC rejoin: event=sessionAuthorityLost source=\(source) transport=\(activeTransportModeLabel()) summary=\(crossNetwork.remoteDesktopRecoveryDebugSummary())"
            )
        }
        return true
    }

    private func currentRealtimeMediaAudioBindingIfUsable() -> (endpoint: SkyBridgeMediaEndpoint, mediaSessionId: String)? {
        guard let endpoint = realtimeMediaAudioEndpoint,
              let mediaSessionId = realtimeMediaAudioReceiverSessionId,
              realtimeMediaAudioRenderer != nil,
              Self.isUsableRealtimeMediaAudioEndpoint(endpoint) else {
            return nil
        }
        return (endpoint, mediaSessionId)
    }

    private func scheduleRealtimeMediaAudioNoTrafficRecovery(
        sessionId: String,
        endpoint: SkyBridgeMediaEndpoint,
        renderer: IOSRealtimeMediaAudioReceiver,
        mode: SkyBridgeMediaAudioMode
    ) {
        realtimeMediaAudioNoTrafficRecoveryTask?.cancel()
        realtimeMediaAudioNoTrafficRecoveryTask = nil
        let expectedTransportMode = activeTransportMode
        guard expectedTransportMode == .crossNetwork || expectedTransportMode == .lan else { return }
        realtimeMediaAudioNoTrafficRecoveryTask = Task { @MainActor [weak self, renderer] in
            do {
                try await Task.sleep(for: RemoteDesktopManagerRuntimeConfig.realtimeMediaAudioNoTrafficRecoveryDelay)
            } catch {
                return
            }
            guard let self,
                  self.activeTransportMode == expectedTransportMode,
                  self.isStreaming,
                  self.viewerSettings.audioRedirectionEnabled,
                  self.realtimeMediaAudioReceiverSessionId == sessionId,
                  self.realtimeMediaAudioEndpoint == endpoint,
                  self.realtimeMediaAudioRenderer != nil else {
                return
            }
            let snapshot = await renderer.startupDiagnosticSnapshot()
            if snapshot.datagramsSeen > 0 || snapshot.received > 0 {
                self.realtimeMediaAudioNoTrafficRecoveryAttemptsBySessionId.removeValue(forKey: sessionId)
                return
            }

            let attempt = (self.realtimeMediaAudioNoTrafficRecoveryAttemptsBySessionId[sessionId] ?? 0) + 1
            self.realtimeMediaAudioNoTrafficRecoveryAttemptsBySessionId[sessionId] = attempt
            let endpointLabel = "\(endpoint.host):\(endpoint.port)"
            let eventName = expectedTransportMode == .crossNetwork
                ? "relayNoTrafficRecovery"
                : "lanNoTrafficRecovery"
            let exhaustedEventName = expectedTransportMode == .crossNetwork
                ? "relayNoTrafficRecoveryExhausted"
                : "lanNoTrafficRecoveryExhausted"
            let probable = expectedTransportMode == .crossNetwork
                ? "relay-bound-but-no-datagrams"
                : "lan-endpoint-published-but-no-datagrams"
            guard attempt <= RemoteDesktopManagerRuntimeConfig.realtimeMediaAudioNoTrafficRecoveryMaxAttempts else {
                SkyBridgeLogger.shared.warning(
                    "🎧 PQC media audio no-traffic recovery exhausted: event=\(exhaustedEventName) session=\(sessionId) endpoint=\(endpointLabel) attempts=\(attempt - 1) action=doctor-fail transport=\(self.activeTransportModeLabel())"
                )
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx \(exhaustedEventName) session=\(sessionId) endpoint=\(endpointLabel) attempts=\(attempt - 1) action=doctor-fail probable=\(probable)"
                )
                SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                    [
                        "kind": "audioRxNoTrafficRecovery",
                        "session": sessionId,
                        "session_id": sessionId,
                        "endpoint": endpointLabel,
                        "attempt": attempt - 1,
                        "action": "doctor-fail",
                        "transport": self.activeTransportModeLabel(),
                        "probable": probable
                    ]
                )
                return
            }

            if expectedTransportMode == .crossNetwork {
                SkyBridgeLogger.shared.warning(
                    "🎧 PQC media audio relay accepted but delivered no datagrams: event=\(eventName) session=\(sessionId) endpoint=\(endpointLabel) attempt=\(attempt) action=lease-refresh transport=\(self.activeTransportModeLabel())"
                )
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx \(eventName) session=\(sessionId) endpoint=\(endpointLabel) attempt=\(attempt) action=lease-refresh probable=\(probable)"
                )
                SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                    [
                        "kind": "audioRxNoTrafficRecovery",
                        "session": sessionId,
                        "session_id": sessionId,
                        "endpoint": endpointLabel,
                        "attempt": attempt,
                        "action": "lease-refresh",
                        "transport": self.activeTransportModeLabel(),
                        "probable": probable
                    ]
                )
                self.crossNetwork.clearCachedRealtimeMediaRelayEndpointForActiveSession(
                    reason: "relayNoTrafficAfterBindAccepted"
                )
                self.stopRealtimeMediaAudioReceiver(cancelPendingStart: false, reason: "relay-no-traffic-after-bind-accepted")
                self.ensureRealtimeMediaAudioReceiverStartedIfNeeded(mode: mode)
                return
            }

            if attempt >= RemoteDesktopManagerRuntimeConfig.realtimeMediaAudioNoTrafficRecoveryMaxAttempts {
                SkyBridgeLogger.shared.warning(
                    "🎧 PQC media audio LAN endpoint still delivered no datagrams after republish: event=\(eventName) session=\(sessionId) endpoint=\(endpointLabel) attempt=\(attempt) action=receiver-rebind transport=\(self.activeTransportModeLabel())"
                )
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx \(eventName) session=\(sessionId) endpoint=\(endpointLabel) attempt=\(attempt) action=receiver-rebind probable=\(probable)"
                )
                SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                    [
                        "kind": "audioRxNoTrafficRecovery",
                        "session": sessionId,
                        "session_id": sessionId,
                        "endpoint": endpointLabel,
                        "attempt": attempt,
                        "action": "receiver-rebind",
                        "transport": self.activeTransportModeLabel(),
                        "probable": probable
                    ]
                )
                self.stopRealtimeMediaAudioReceiver(
                    cancelPendingStart: false,
                    reason: "lan-no-traffic-after-republish"
                )
                self.ensureRealtimeMediaAudioReceiverStartedIfNeeded(mode: mode)
                return
            }

            SkyBridgeLogger.shared.warning(
                "🎧 PQC media audio LAN endpoint delivered no datagrams: event=\(eventName) session=\(sessionId) endpoint=\(endpointLabel) attempt=\(attempt) action=stream-config-republish transport=\(self.activeTransportModeLabel())"
            )
            SkyBridgeSmokeTraceWriter.append(
                "audio-rx \(eventName) session=\(sessionId) endpoint=\(endpointLabel) attempt=\(attempt) action=stream-config-republish probable=\(probable)"
            )
            SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                [
                    "kind": "audioRxNoTrafficRecovery",
                    "session": sessionId,
                    "session_id": sessionId,
                    "endpoint": endpointLabel,
                    "attempt": attempt,
                    "action": "stream-config-republish",
                    "transport": self.activeTransportModeLabel(),
                    "probable": probable
                ]
            )
            await self.pushViewerStreamConfiguration(force: true, refreshStream: false)
            self.scheduleRealtimeMediaAudioNoTrafficRecovery(
                sessionId: sessionId,
                endpoint: endpoint,
                renderer: renderer,
                mode: mode
            )
        }
    }

    private func scheduleRealtimeMediaAudioEndpointRenewal(
        sessionId: String,
        endpoint: SkyBridgeMediaEndpoint,
        mode: SkyBridgeMediaAudioMode
    ) {
        realtimeMediaAudioRelayRenewalTask?.cancel()
        realtimeMediaAudioRelayRenewalTask = nil
        guard activeTransportMode == .crossNetwork,
              let expiresAt = endpoint.expiresAt else {
            return
        }
        let nowSeconds = Date().timeIntervalSince1970
        let renewalLeadTime = strictCrossNetworkMediaValidationActive
            ? max(RemoteDesktopManagerRuntimeConfig.realtimeMediaAudioEndpointRenewalLeadTime, 35)
            : RemoteDesktopManagerRuntimeConfig.realtimeMediaAudioEndpointRenewalLeadTime
        let delaySeconds = max(1, expiresAt - nowSeconds - renewalLeadTime)
        let delayNanos = UInt64(delaySeconds * 1_000_000_000)
        let delayMs = Int((delaySeconds * 1000).rounded())
        let expiresInMs = Int(((expiresAt - nowSeconds) * 1000).rounded())
        SkyBridgeLogger.shared.info(
            "🎧 PQC media audio relay renewal scheduled: event=relayLeaseRenewalScheduled session=\(sessionId) relay=\(endpoint.host):\(endpoint.port) delayMs=\(delayMs) expiresInMs=\(expiresInMs) transport=\(activeTransportModeLabel())"
        )
        SkyBridgeSmokeTraceWriter.append(
            "audio-rx relayLeaseRenewalScheduled session=\(sessionId) delayMs=\(delayMs) relay=\(endpoint.host):\(endpoint.port)"
        )
        SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
            [
                "kind": "audioRxEndpointRenewalScheduled",
                "session": sessionId,
                "session_id": sessionId,
                "relay": "\(endpoint.host):\(endpoint.port)",
                "delayMs": delayMs,
                "expiresInMs": expiresInMs
            ]
        )
        realtimeMediaAudioRelayRenewalTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanos)
            } catch {
                return
            }
            guard let self,
                  self.activeTransportMode == .crossNetwork,
                  self.isStreaming,
                  self.viewerSettings.audioRedirectionEnabled,
                  self.realtimeMediaAudioReceiverSessionId == sessionId,
                  self.realtimeMediaAudioEndpoint == endpoint else {
                return
            }
            await self.renewRealtimeMediaAudioRelayEndpoint(
                sessionId: sessionId,
                currentEndpoint: endpoint,
                mode: mode
            )
        }
    }

    private func renewRealtimeMediaAudioRelayEndpoint(
        sessionId: String,
        currentEndpoint: SkyBridgeMediaEndpoint,
        mode: SkyBridgeMediaAudioMode
    ) async {
        guard activeTransportMode == .crossNetwork,
              isStreaming,
              viewerSettings.audioRedirectionEnabled,
              realtimeMediaAudioReceiverSessionId == sessionId,
              realtimeMediaAudioEndpoint == currentEndpoint,
              let renderer = realtimeMediaAudioRenderer else {
            return
        }
        SkyBridgeLogger.shared.info(
            "🎧 PQC media audio relay renewal started: event=relayLeaseRenewalStart session=\(sessionId) oldRelay=\(currentEndpoint.host):\(currentEndpoint.port) transport=\(activeTransportModeLabel())"
        )
        crossNetwork.clearCachedRealtimeMediaRelayEndpointForActiveSession(reason: "lease-renewal")
        let relayEndpointPair: CrossNetworkWebRTCManager.RealtimeMediaRelayEndpointPair?
        do {
            relayEndpointPair = try await crossNetwork.requestRealtimeMediaRelayEndpointForActiveSession()
        } catch {
            SkyBridgeLogger.shared.warning(
                "⚠️ PQC media audio relay renewal lease request failed: session=\(sessionId) error=\(error.localizedDescription)"
            )
            scheduleRealtimeMediaAudioEndpointRenewal(sessionId: sessionId, endpoint: currentEndpoint, mode: mode)
            return
        }
        guard let relayEndpointPair else {
            let reason = crossNetwork.mediaRelayLeaseDiagnosticForActiveSession() ?? "unknown"
            SkyBridgeLogger.shared.warning(
                "⚠️ PQC media audio relay renewal lease unavailable: session=\(sessionId) reason=\(reason)"
            )
            scheduleRealtimeMediaAudioEndpointRenewal(sessionId: sessionId, endpoint: currentEndpoint, mode: mode)
            return
        }
        let relayEndpoint = relayEndpointPair.localEndpoint
        let relayBindPolicy: SkyBridgeRealtimeMediaRelayBindPolicy =
            strictCrossNetworkMediaValidationActive ? .requireAcknowledgement : .optimisticAfterSend
        let sameRelayAddress = Self.isSameRealtimeMediaRelayAddress(currentEndpoint, relayEndpoint)
        let strictRenewalRequiresRollover = strictCrossNetworkMediaValidationActive && sameRelayAddress
        if !strictRenewalRequiresRollover,
           sameRelayAddress,
           let relayToken = relayEndpoint.relayToken,
           let currentTransport = realtimeMediaAudioRelayTransport {
            do {
                try await currentTransport.rebindRelayToken(
                    relayToken,
                    relayBindPolicy: relayBindPolicy
                )
                realtimeMediaAudioEndpoint = relayEndpoint
                realtimeMediaAudioRelayBindState = relayBindPolicy == .requireAcknowledgement
                    ? .accepted(sessionId: sessionId, endpoint: relayEndpoint)
                    : .ackPending(sessionId: sessionId, endpoint: relayEndpoint)
                SkyBridgeLogger.shared.info(
                    "🎧 PQC media audio relay renewed in place: event=relayLeaseRenewed session=\(sessionId) role=\(relayEndpointPair.localRole) relay=\(relayEndpoint.host):\(relayEndpoint.port) token=present transport=\(activeTransportModeLabel())"
                )
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx relayLeaseRenewed session=\(sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port) mode=in-place"
                )
                SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                    [
                        "kind": "audioRxEndpointRenewed",
                        "session": sessionId,
                        "session_id": sessionId,
                        "relay": "\(relayEndpoint.host):\(relayEndpoint.port)",
                        "role": relayEndpointPair.localRole,
                        "relayTokenPresent": true,
                        "probable": "relay-lease-renewed-in-place"
                    ]
                )
                scheduleRealtimeMediaAudioEndpointRenewal(sessionId: sessionId, endpoint: relayEndpoint, mode: mode)
                return
            } catch {
                SkyBridgeLogger.shared.warning(
                    "⚠️ PQC media audio in-place relay renewal failed; falling back to transport rollover: session=\(sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port) error=\(error.localizedDescription)"
                )
            }
        }
        if strictRenewalRequiresRollover {
            SkyBridgeLogger.shared.info(
                "🎧 PQC media audio relay renewal using make-before-break: event=relayLeaseRenewalRollover session=\(sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port) reason=strict-make-before-break transport=\(activeTransportModeLabel())"
            )
            SkyBridgeSmokeTraceWriter.append(
                "audio-rx relayLeaseRenewalRollover session=\(sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port) reason=strict-make-before-break"
            )
            SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                [
                    "kind": "audioRxEndpointRenewalRollover",
                    "session": sessionId,
                    "session_id": sessionId,
                    "relay": "\(relayEndpoint.host):\(relayEndpoint.port)",
                    "role": relayEndpointPair.localRole,
                    "relayTokenPresent": relayEndpoint.relayToken != nil,
                    "probable": "strict-make-before-break"
                ]
            )
        }
        let renewalTrafficCounter = RealtimeMediaAudioRelayTrafficCounter()
        let relayTransport = SkyBridgeUDPRealtimeMediaTransport(
            endpoint: relayEndpoint,
            receiveHandler: { [renderer, renewalTrafficCounter] datagram in
                renewalTrafficCounter.increment()
                Task.detached(priority: .utility) {
                    await renderer.handle(datagram: datagram)
                }
            },
            relayBindPolicy: relayBindPolicy,
            startEventHandler: { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleRealtimeMediaAudioRelayTransportEvent(
                        event,
                        sessionId: sessionId,
                        endpoint: relayEndpoint,
                        generation: nil
                    )
                }
            }
        )
        do {
            try await relayTransport.start()
        } catch {
            SkyBridgeLogger.shared.warning(
                "⚠️ PQC media audio relay renewal UDP start failed: session=\(sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port) error=\(error.localizedDescription)"
            )
            crossNetwork.markRealtimeMediaRelayEndpointUnusableForActiveSession(reason: "renewalStartFailed")
            scheduleRealtimeMediaAudioEndpointRenewal(sessionId: sessionId, endpoint: currentEndpoint, mode: mode)
            return
        }
        guard activeTransportMode == .crossNetwork,
              isStreaming,
              viewerSettings.audioRedirectionEnabled,
              realtimeMediaAudioReceiverSessionId == sessionId,
              realtimeMediaAudioEndpoint == currentEndpoint else {
            await relayTransport.stop()
            return
        }
        let payload = makeViewerStreamConfigurationPayload(
            refreshStream: false,
            mediaAudioEndpoint: relayEndpoint,
            mediaSessionId: sessionId
        )
        do {
            try await sendViewerStreamConfigurationPayload(payload, retryAttempt: nil)
            lastSentStreamConfiguration = payload
            SkyBridgeLogger.shared.info(
                "🎧 PQC media audio renewal config sent: event=audioRenewalConfigSent session=\(sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port) audioRelayToken=\(relayEndpoint.relayToken == nil ? "missing" : "present") transport=\(activeTransportModeLabel())"
            )
            SkyBridgeSmokeTraceWriter.append(
                "stream-config audioRenewalSent session=\(sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port)"
            )
        } catch {
            SkyBridgeLogger.shared.warning(
                "⚠️ PQC media audio relay renewal stream config failed: session=\(sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port) error=\(error.localizedDescription)"
            )
            await relayTransport.stop()
            scheduleRealtimeMediaAudioEndpointRenewal(sessionId: sessionId, endpoint: currentEndpoint, mode: mode)
            return
        }

        let observedTotal = await waitForRealtimeMediaAudioRelayTraffic(
            renewalTrafficCounter,
            sessionId: sessionId,
            relayEndpoint: relayEndpoint
        )
        guard activeTransportMode == .crossNetwork,
              isStreaming,
              viewerSettings.audioRedirectionEnabled,
              realtimeMediaAudioReceiverSessionId == sessionId,
              realtimeMediaAudioEndpoint == currentEndpoint else {
            await relayTransport.stop()
            return
        }
        guard observedTotal >= RemoteDesktopManagerRuntimeConfig.realtimeMediaAudioRelayRolloverMinimumObservedPackets else {
            SkyBridgeLogger.shared.warning(
                "⚠️ PQC media audio relay renewal held old transport: event=relayLeaseRenewalTrafficMissing session=\(sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port) newTransportRecvTotal=\(observedTotal) transport=\(activeTransportModeLabel())"
            )
            SkyBridgeSmokeTraceWriter.append(
                "audio-rx relayLeaseRenewalTrafficMissing session=\(sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port) newTransportRecvTotal=\(observedTotal)"
            )
            SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                [
                    "kind": "audioRxEndpointRenewalTrafficMissing",
                    "session": sessionId,
                    "session_id": sessionId,
                    "relay": "\(relayEndpoint.host):\(relayEndpoint.port)",
                    "newTransportRecvTotal": observedTotal,
                    "probable": "relay-renewal-no-post-renewal-rx"
                ]
            )
            await relayTransport.stop()
            scheduleRealtimeMediaAudioEndpointRenewal(sessionId: sessionId, endpoint: currentEndpoint, mode: mode)
            return
        }

        let oldTransport = realtimeMediaAudioRelayTransport
        realtimeMediaAudioRelayTransport = relayTransport
        realtimeMediaAudioEndpoint = relayEndpoint
        realtimeMediaAudioRelayBindState = .idle
        SkyBridgeLogger.shared.info(
            "🎧 PQC media audio relay renewed after traffic: event=relayLeaseRenewed session=\(sessionId) role=\(relayEndpointPair.localRole) relay=\(relayEndpoint.host):\(relayEndpoint.port) token=\(relayEndpoint.relayToken == nil ? "missing" : "present") newTransportRecvTotal=\(observedTotal) transport=\(activeTransportModeLabel())"
        )
        SkyBridgeSmokeTraceWriter.append(
            "audio-rx relayLeaseRenewed session=\(sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port) newTransportRecvTotal=\(observedTotal)"
        )
        SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
            [
                "kind": "audioRxEndpointRenewed",
                "session": sessionId,
                "session_id": sessionId,
                "relay": "\(relayEndpoint.host):\(relayEndpoint.port)",
                "role": relayEndpointPair.localRole,
                "relayTokenPresent": relayEndpoint.relayToken != nil,
                "newTransportRecvTotal": observedTotal,
                "probable": "relay-lease-renewed-after-traffic"
            ]
        )
        scheduleRealtimeMediaAudioEndpointRenewal(sessionId: sessionId, endpoint: relayEndpoint, mode: mode)
        if let oldTransport {
            Task(priority: .utility) {
                try? await Task.sleep(for: RemoteDesktopManagerRuntimeConfig.realtimeMediaAudioRelayRolloverGraceDelay)
                await oldTransport.stop()
            }
        }
    }

    private func waitForRealtimeMediaAudioRelayTraffic(
        _ trafficCounter: RealtimeMediaAudioRelayTrafficCounter,
        sessionId: String,
        relayEndpoint: SkyBridgeMediaEndpoint
    ) async -> UInt64 {
        let deadline = Date().addingTimeInterval(RemoteDesktopManagerRuntimeConfig.realtimeMediaAudioRelayRolloverTrafficObservationTimeout)
        var observedTotal = trafficCounter.snapshot()
        while Date() < deadline {
            observedTotal = trafficCounter.snapshot()
            if observedTotal >= RemoteDesktopManagerRuntimeConfig.realtimeMediaAudioRelayRolloverMinimumObservedPackets {
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx relayLeaseRenewalTrafficObserved session=\(sessionId) relay=\(relayEndpoint.host):\(relayEndpoint.port) newTransportRecvTotal=\(observedTotal)"
                )
                SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                    [
                        "kind": "audioRxEndpointRenewalTrafficObserved",
                        "session": sessionId,
                        "session_id": sessionId,
                        "relay": "\(relayEndpoint.host):\(relayEndpoint.port)",
                        "newTransportRecvTotal": observedTotal
                    ]
                )
                return observedTotal
            }
            try? await Task.sleep(for: RemoteDesktopManagerRuntimeConfig.realtimeMediaAudioRelayRolloverTrafficObservationPoll)
        }
        return observedTotal
    }

    private func handleRealtimeMediaAudioRelayBindFailure(
        reason: String,
        sessionId: String,
        endpoint: SkyBridgeMediaEndpoint
    ) {
        let endpointMatches = realtimeMediaAudioEndpoint == endpoint
        guard realtimeMediaAudioReceiverSessionId == sessionId,
              endpointMatches else {
            let currentRelayLabel = realtimeMediaAudioEndpoint.map { "\($0.host):\($0.port)" } ?? "-"
            SkyBridgeLogger.shared.debug(
                "ℹ️ ignore stale PQC media relay bind failure: session=\(sessionId) relay=\(endpoint.host):\(endpoint.port) reason=\(reason) currentSession=\(realtimeMediaAudioReceiverSessionId ?? "-") currentRelay=\(currentRelayLabel)"
            )
            return
        }
        realtimeMediaAudioRelayBindGraceTask?.cancel()
        realtimeMediaAudioRelayBindGraceTask = nil
        realtimeMediaAudioRelayBindState = .failed(sessionId: sessionId, endpoint: endpoint, reason: reason)
        crossNetwork.markRealtimeMediaRelayEndpointUnusableForActiveSession(reason: reason)
        stopRealtimeMediaAudioReceiver(cancelPendingStart: false, reason: "relay-bind-failed:\(reason)")
        realtimeMediaAudioRelayBindState = .failed(sessionId: sessionId, endpoint: endpoint, reason: reason)
        Task { @MainActor [weak self] in
            await self?.pushViewerStreamConfiguration(force: false, refreshStream: false)
        }
    }

    private func scheduleRealtimeMediaAudioRelayBindGrace(
        sessionId: String,
        endpoint: SkyBridgeMediaEndpoint
    ) {
        realtimeMediaAudioRelayBindGraceTask?.cancel()
        realtimeMediaAudioRelayBindGraceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: RemoteDesktopManagerRuntimeConfig.realtimeMediaAudioRelayBindAckGraceDelay)
            } catch {
                return
            }
            guard let self else { return }
            guard self.realtimeMediaAudioReceiverSessionId == sessionId,
                  self.realtimeMediaAudioEndpoint == endpoint,
                  let renderer = self.realtimeMediaAudioRenderer else {
                return
            }
            let snapshot = await renderer.startupDiagnosticSnapshot()
            if snapshot.received > 0 {
                self.realtimeMediaAudioRelayBindState = .trafficObserved(
                    sessionId: sessionId,
                    endpoint: endpoint
                )
                SkyBridgeLogger.shared.info(
                    "🎧 PQC media audio relay bind ack timeout tolerated: event=relayBindAckGraceTrafficObserved session=\(sessionId) relay=\(endpoint.host):\(endpoint.port) audioRxDatagrams=\(snapshot.datagramsSeen) audioRxRecv=\(snapshot.received) transport=\(self.activeTransportModeLabel())"
                )
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx relayBindAckGraceTrafficObserved session=\(sessionId) relay=\(endpoint.host):\(endpoint.port) audioRxDatagrams=\(snapshot.datagramsSeen) audioRxRecv=\(snapshot.received)"
                )
                return
            }
            if snapshot.datagramsSeen > 0 {
                SkyBridgeLogger.shared.warning(
                    "🎧 PQC media audio relay bind grace saw only rejected traffic: event=relayBindGraceUnauthenticatedTraffic session=\(sessionId) relay=\(endpoint.host):\(endpoint.port) audioRxDatagrams=\(snapshot.datagramsSeen) audioRxRecv=0 rejected=\(snapshot.rejected) authRejected=\(snapshot.authRejected) sessionHashRejected=\(snapshot.sessionHashRejected) replayRejected=\(snapshot.replayRejected) action=endpoint-backoff transport=\(self.activeTransportModeLabel())"
                )
                self.handleRealtimeMediaAudioRelayBindFailure(
                    reason: "relayBindAckTimedOutNoAuthenticatedTraffic",
                    sessionId: sessionId,
                    endpoint: endpoint
                )
                return
            }
            SkyBridgeLogger.shared.warning(
                "🎧 PQC media audio relay bind grace expired with no traffic: event=relayBindAckGraceTimedOut session=\(sessionId) relay=\(endpoint.host):\(endpoint.port) action=endpoint-backoff transport=\(self.activeTransportModeLabel())"
            )
            self.handleRealtimeMediaAudioRelayBindFailure(
                reason: "relayBindAckTimedOutNoTraffic",
                sessionId: sessionId,
                endpoint: endpoint
            )
        }
    }

    private func handleRealtimeMediaAudioRelayTransportEvent(
        _ event: SkyBridgeRealtimeMediaTransportEvent,
        sessionId: String,
        endpoint: SkyBridgeMediaEndpoint,
        generation: UInt64?
    ) {
        guard isCurrentRealtimeMediaAudioReceiverStart(generation)
                || realtimeMediaAudioReceiverSessionId == sessionId else {
            return
        }
        let relay = "\(endpoint.host):\(endpoint.port)"
        switch event {
        case .udpConnectionReady:
            updateRealtimeMediaAudioReceiverStartPhase(.relayBindAck, generation: generation)
            SkyBridgeLogger.shared.info(
                "🎧 PQC media audio receiver UDP connection ready: event=udpConnectionReady session=\(sessionId) relay=\(relay) transport=\(activeTransportModeLabel())"
            )
            SkyBridgeSmokeTraceWriter.append("audio-rx udpConnectionReady session=\(sessionId) relay=\(relay)")
            SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                [
                    "kind": "audioRxRelayBind",
                    "session": sessionId,
                    "session_id": sessionId,
                    "stage": "udpConnectionReady",
                    "relay": relay,
                    "probable": "relay-bind-pending"
                ]
            )
        case .relayBindSent:
            updateRealtimeMediaAudioReceiverStartPhase(.relayBindAck, generation: generation)
            realtimeMediaAudioRelayBindState = .ackPending(sessionId: sessionId, endpoint: endpoint)
            SkyBridgeLogger.shared.info(
                "🎧 PQC media audio relay bind sent: event=relayBindSent session=\(sessionId) relay=\(relay) transport=\(activeTransportModeLabel())"
            )
            SkyBridgeSmokeTraceWriter.append("audio-rx relayBindSent session=\(sessionId) relay=\(relay)")
            SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                [
                    "kind": "audioRxRelayBind",
                    "session": sessionId,
                    "session_id": sessionId,
                    "stage": "relayBindSent",
                    "relay": relay,
                    "probable": "relay-bind-pending"
                ]
            )
        case .relayBindAccepted:
            updateRealtimeMediaAudioReceiverStartPhase(.receiverReady, generation: generation)
            realtimeMediaAudioRelayBindGraceTask?.cancel()
            realtimeMediaAudioRelayBindGraceTask = nil
            realtimeMediaAudioRelayBindState = .accepted(sessionId: sessionId, endpoint: endpoint)
            SkyBridgeLogger.shared.info(
                "🎧 PQC media audio relay bind accepted: event=relayBindAccepted session=\(sessionId) relay=\(relay) transport=\(activeTransportModeLabel())"
            )
            SkyBridgeSmokeTraceWriter.append("audio-rx relayBindAccepted session=\(sessionId) relay=\(relay)")
            SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                [
                    "kind": "audioRxRelayBind",
                    "session": sessionId,
                    "session_id": sessionId,
                    "stage": "relayBindAccepted",
                    "relay": relay,
                    "probable": "relay-bind-ok"
                ]
            )
        case .relayBindAckTimedOut:
            realtimeMediaAudioRelayBindState = .ackPending(sessionId: sessionId, endpoint: endpoint)
            scheduleRealtimeMediaAudioRelayBindGrace(sessionId: sessionId, endpoint: endpoint)
            SkyBridgeLogger.shared.warning(
                "🎧 PQC media audio relay bind ack pending: event=relayBindAckTimedOut session=\(sessionId) relay=\(relay) action=optimistic-grace probable=ack-lost-or-relay-late transport=\(activeTransportModeLabel())"
            )
            SkyBridgeSmokeTraceWriter.append(
                "audio-rx relayBindAckTimedOut session=\(sessionId) relay=\(relay) action=optimistic-grace probable=ack-lost-or-relay-late"
            )
            SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                [
                    "kind": "audioRxRelayBind",
                    "session": sessionId,
                    "session_id": sessionId,
                    "stage": "relayBindAckTimedOut",
                    "relay": relay,
                    "probable": "ack-lost-or-relay-late",
                    "action": "optimistic-grace"
                ]
            )
        case .relayBindRejected(let reason):
            handleRealtimeMediaAudioRelayBindFailure(
                reason: "relayBindRejected:\(reason)",
                sessionId: sessionId,
                endpoint: endpoint
            )
            SkyBridgeLogger.shared.warning(
                "🎧 PQC media audio relay bind rejected: event=relayBindRejected session=\(sessionId) relay=\(relay) reason=\(reason) transport=\(activeTransportModeLabel())"
            )
            SkyBridgeSmokeTraceWriter.append(
                "audio-rx relayBindRejected session=\(sessionId) relay=\(relay) reason=\(reason)"
            )
            SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                [
                    "kind": "audioRxRelayBind",
                    "session": sessionId,
                    "session_id": sessionId,
                    "stage": "relayBindRejected",
                    "relay": relay,
                    "reason": reason,
                    "probable": "relay-token-rejected"
                ]
            )
        case .relayBindMalformed:
            handleRealtimeMediaAudioRelayBindFailure(
                reason: "relayBindMalformed",
                sessionId: sessionId,
                endpoint: endpoint
            )
            SkyBridgeLogger.shared.warning(
                "🎧 PQC media audio relay bind malformed: event=relayBindMalformed session=\(sessionId) relay=\(relay) transport=\(activeTransportModeLabel())"
            )
            SkyBridgeSmokeTraceWriter.append("audio-rx relayBindMalformed session=\(sessionId) relay=\(relay)")
            SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
                [
                    "kind": "audioRxRelayBind",
                    "session": sessionId,
                    "session_id": sessionId,
                    "stage": "relayBindMalformed",
                    "relay": relay,
                    "probable": "relay-control-protocol-mismatch"
                ]
            )
        }
    }

    private func updateRealtimeMediaAudioReceiverStartPhase(
        _ phase: RealtimeMediaAudioReceiverStartPhase,
        generation: UInt64?
    ) {
        guard let generation else {
            realtimeMediaAudioReceiverStartPhase = phase
            return
        }
        guard realtimeMediaAudioReceiverStartGeneration == generation,
              realtimeMediaAudioReceiverStartTask != nil else {
            return
        }
        realtimeMediaAudioReceiverStartPhase = phase
    }

    private func scheduleRealtimeMediaAudioReceiverStageTimeout(
        phase: RealtimeMediaAudioReceiverStartPhase,
        mode: SkyBridgeMediaAudioMode,
        generation: UInt64?,
        startTime: Date
    ) -> Task<Void, Never>? {
        scheduleRealtimeMediaAudioReceiverTimeoutDiagnostic(
            delay: RemoteDesktopManagerRuntimeConfig.realtimeMediaAudioReceiverStageTimeout,
            reason: .stageTimeout,
            expectedPhase: phase,
            mode: mode,
            generation: generation,
            startTime: startTime
        )
    }

    private func scheduleRealtimeMediaAudioReceiverTimeoutDiagnostic(
        delay: Duration,
        reason: RealtimeMediaAudioReceiverStartFailureReason,
        expectedPhase: RealtimeMediaAudioReceiverStartPhase?,
        mode: SkyBridgeMediaAudioMode,
        generation: UInt64?,
        startTime: Date
    ) -> Task<Void, Never>? {
        guard let generation else { return nil }
        return Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  self.realtimeMediaAudioReceiverStartGeneration == generation,
                  self.realtimeMediaAudioReceiverStartTask != nil,
                  self.currentRealtimeMediaAudioBindingIfUsable() == nil else {
                return
            }
            if let expectedPhase,
               self.realtimeMediaAudioReceiverStartPhase != expectedPhase {
                return
            }
            self.markRealtimeMediaAudioReceiverStartupFailed(
                generation: generation,
                mode: mode,
                reason: reason,
                phase: expectedPhase ?? self.realtimeMediaAudioReceiverStartPhase,
                startTime: startTime
            )
        }
    }

    private func markRealtimeMediaAudioReceiverStartupFailed(
        generation: UInt64,
        mode: SkyBridgeMediaAudioMode,
        reason: RealtimeMediaAudioReceiverStartFailureReason,
        phase: RealtimeMediaAudioReceiverStartPhase?,
        startTime: Date
    ) {
        guard realtimeMediaAudioReceiverStartGeneration == generation,
              realtimeMediaAudioReceiverStartTask != nil,
              currentRealtimeMediaAudioBindingIfUsable() == nil else {
            return
        }
        let elapsedMs = Int((Date().timeIntervalSince(startTime) * 1000).rounded())
        let stage = phase?.rawValue ?? realtimeMediaAudioReceiverStartPhase?.rawValue ?? "unknown"
        SkyBridgeLogger.shared.warning(
            "🎧 PQC media audio receiver start failed: event=receiverStartFailed reason=\(reason.rawValue) stage=\(stage) mode=\(mode.rawValue) elapsedMs=\(elapsedMs) transport=\(activeTransportModeLabel())"
        )
        let sessionId = realtimeMediaAudioReceiverSessionId ?? "-"
        let transport = activeTransportModeLabel()
        SkyBridgeSmokeTraceWriter.appendStatus(
            "audio-rx event=audioRxReceiverStartFailed session=\(sessionId) reason=\(reason.rawValue) stage=\(stage) mode=\(mode.rawValue) elapsedMs=\(elapsedMs) transport=\(transport) probable=receiver-start-failed"
        )
        SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
            [
                "kind": "audioRxReceiverStartFailed",
                "session": sessionId,
                "session_id": sessionId,
                "reason": reason.rawValue,
                "stage": stage,
                "mode": mode.rawValue,
                "elapsedMs": elapsedMs,
                "transport": transport,
                "probable": "receiver-start-failed"
            ]
        )
        let failedTask = realtimeMediaAudioReceiverStartTask
        realtimeMediaAudioReceiverStartGeneration &+= 1
        realtimeMediaAudioReceiverStartTask = nil
        realtimeMediaAudioReceiverStartPhase = nil
        failedTask?.cancel()
        stopRealtimeMediaAudioReceiver(cancelPendingStart: false, reason: "receiver-start-timeout:\(reason.rawValue)")
    }

    private func ensureRealtimeMediaAudioReceiverStartedIfNeeded(mode: SkyBridgeMediaAudioMode) {
        guard !handleCrossNetworkSessionAuthorityLostIfNeeded(source: "audio-receiver-start") else {
            return
        }
        guard viewerSettings.audioRedirectionEnabled, isStreaming else {
            realtimeMediaAudioReceiverStartTask?.cancel()
            realtimeMediaAudioReceiverStartTask = nil
            stopRealtimeMediaAudioReceiver(reason: "stream-config-audio-disabled")
            return
        }
        guard currentRealtimeMediaAudioBindingIfUsable() == nil else { return }
        guard realtimeMediaAudioReceiverStartTask == nil else { return }

        let startTime = Date()
        SkyBridgeLogger.shared.info("🎧 PQC media audio receiver start pending: event=receiverStartPending mode=\(mode.rawValue) transport=\(activeTransportModeLabel())")
        realtimeMediaAudioReceiverStartGeneration &+= 1
        let generation = realtimeMediaAudioReceiverStartGeneration
        let streamGeneration = streamEpoch
        realtimeMediaAudioReceiverStartPhase = .pending
        realtimeMediaAudioReceiverStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let slowDiagnosticTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: RemoteDesktopManagerRuntimeConfig.realtimeMediaAudioReceiverSlowDiagnosticDelay)
                } catch {
                    return
                }
                guard let self,
                      self.realtimeMediaAudioReceiverStartGeneration == generation,
                      self.streamEpoch == streamGeneration,
                      self.realtimeMediaAudioReceiverStartTask != nil,
                      self.currentRealtimeMediaAudioBindingIfUsable() == nil else {
                    return
                }
                let elapsedMs = Int((Date().timeIntervalSince(startTime) * 1000).rounded())
                let phase = self.realtimeMediaAudioReceiverStartPhase?.rawValue ?? "unknown"
                SkyBridgeLogger.shared.warning("🎧 PQC media audio receiver start slow: event=receiverStartSlow phase=\(phase) mode=\(mode.rawValue) elapsedMs=\(elapsedMs) transport=\(self.activeTransportModeLabel())")
            }
            let totalTimeoutTask = self.scheduleRealtimeMediaAudioReceiverTimeoutDiagnostic(
                delay: RemoteDesktopManagerRuntimeConfig.realtimeMediaAudioReceiverTotalTimeout,
                reason: .totalTimeout,
                expectedPhase: nil,
                mode: mode,
                generation: generation,
                startTime: startTime
            )
            let binding = await self.prepareRealtimeMediaAudioReceiverIfNeeded(
                mode: mode,
                startGeneration: generation,
                startTime: startTime
            )
            slowDiagnosticTask.cancel()
            totalTimeoutTask?.cancel()
            guard self.realtimeMediaAudioReceiverStartGeneration == generation else {
                if binding != nil {
                    self.stopRealtimeMediaAudioReceiver(cancelPendingStart: false, reason: "stale-receiver-start-generation")
                }
                return
            }
            let finalPhase = self.realtimeMediaAudioReceiverStartPhase?.rawValue ?? "unknown"
            self.realtimeMediaAudioReceiverStartTask = nil
            self.realtimeMediaAudioReceiverStartPhase = nil
            guard self.streamEpoch == streamGeneration, self.isStreaming else {
                if binding != nil {
                    self.stopRealtimeMediaAudioReceiver(cancelPendingStart: false, reason: "receiver-start-completed-after-stream-stopped")
                }
                return
            }
            if let binding {
                SkyBridgeLogger.shared.info("🎧 PQC media audio receiver started: event=receiverStarted session=\(binding.mediaSessionId) relay=\(binding.endpoint.host):\(binding.endpoint.port) token=\(binding.endpoint.relayToken == nil ? "missing" : "present")")
                SkyBridgeSmokeTraceWriter.append(
                    "audio-rx receiverStarted session=\(binding.mediaSessionId) relay=\(binding.endpoint.host):\(binding.endpoint.port)"
                )
                await self.pushViewerStreamConfiguration(force: false, refreshStream: false)
            } else {
                SkyBridgeLogger.shared.info("🎧 PQC media audio receiver start failed: event=receiverStartFailed reason=unavailable stage=\(finalPhase) transport=\(self.activeTransportModeLabel())")
            }
        }
    }

    private func activeTransportModeLabel() -> String {
        switch activeTransportMode {
        case .none:
            return "none"
        case .lan:
            return "lan"
        case .crossNetwork:
            return "cross_network"
        }
    }

    private func preferredDecodedVideoRenderer() -> DecodedVideoRendererPreference {
        return .metal
    }

    private func persistViewerSettings() {
        try? RemoteDesktopManagerRuntimeConfig.viewerSettingsStore.save(viewerSettings)
    }

    private static func loadViewerSettings() -> RemoteDesktopViewerSettings {
        guard let settings = RemoteDesktopManagerRuntimeConfig.viewerSettingsStore.load() else {
            return RemoteDesktopViewerSettings()
        }
        var migrated = settings
        if migrated.preferredCodec == .jpeg {
            migrated.preferredCodec = .hevc
        }
        return migrated
    }

    private func updateRenderPipeline(_ pipeline: RemoteDesktopRenderPipeline) {
        if activeTransportMode == .crossNetwork,
           crossNetwork.remoteVideoTrackHasRenderedFrame,
           renderPipelineStatus == .webrtcNativeVideo,
           pipeline != .webrtcNativeVideo {
            return
        }
        guard renderPipelineStatus != pipeline else { return }
        renderPipelineStatus = pipeline
        switch pipeline {
        case .waiting:
            break
        case .webrtcNativeVideo:
            SkyBridgeLogger.shared.info("🎬 远控渲染管线已切换到 WebRTC 原生视频轨")
        case .metalRenderer:
            SkyBridgeLogger.shared.info("🎬 远控渲染管线已切换到 Metal Renderer")
        case .sampleBufferDisplayLayer:
            SkyBridgeLogger.shared.info("🎬 远控渲染管线已切换到 AVSampleBufferDisplayLayer")
        case .stillImageFallback:
            SkyBridgeLogger.shared.info("🖼️ 远控渲染管线已切换到静态帧回退")
        }
    }

    private func flushRenderedVideoFeeds(removeDisplayedImage: Bool = true) {
        videoFrameFeed.flush(removeDisplayedImage: removeDisplayedImage)
        flushMetalVideoFrameFeed(removeDisplayedImage: removeDisplayedImage)
    }

    private func flushMetalVideoFrameFeed(removeDisplayedImage: Bool = true) {
        resetMetalFeedDeliveryState()
        metalVideoFrameFeed.flush(removeDisplayedImage: removeDisplayedImage)
    }

    private func resetDecodeSequenceTracking() {
        lastInboundVideoFrameSequence = nil
        lastInboundVideoSyncFrameSequence = nil
        lastVideoSequenceGapLogTime = .distantPast
    }

    private func resetDecodeCompletionOrdering() {
        decodeSubmissionChain?.cancel()
        decodeSubmissionChain = nil
        nextDecodeSubmissionOrder = 0
        nextDecodeCompletionOrder = 0
        pendingDecodeCompletions.removeAll(keepingCapacity: true)
        isDrainingDecodeCompletions = false
        decodeCompletionGapStartedAt = nil
        cancelDecodeCompletionGapWatchdog()
    }

    private func cancelDecodeCompletionGapWatchdog() {
        decodeCompletionGapWatchdogTask?.cancel()
        decodeCompletionGapWatchdogTask = nil
        decodeCompletionGapWatchdogMissingOrder = nil
    }

    private func isDecodeGenerationCurrent(_ generation: UInt64) -> Bool {
        generation == decodeGeneration
    }

    func handleVideoRendererDidFailToDecode(_ errorDescription: String?) async {
        let reason = (errorDescription ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReason = reason.isEmpty ? "video-renderer-decode-failed" : reason
        let now = Date()
        let format = lastIncomingStreamSignature?.format ?? ""
        pendingFrames.removeAll(keepingCapacity: true)
        decodeQueueWaitingForSyncFrame = RemoteDesktopDecodeQueuePolicy.isPredictiveVideoFormat(format)
        await decoder.resetPreservingLastFrame()
        let governanceEvent = codecGovernance.noteDecodeFailure(
            format: format,
            reason: normalizedReason,
            at: now
        )
        let governanceHandled = await handleCodecGovernanceEvent(governanceEvent, at: now)
        if !governanceHandled {
            await requestStreamRefreshIfNeeded(reason: "sample-buffer-decode-failed", minimumInterval: 0.25)
        }
        SkyBridgeLogger.shared.warning("⚠️ AVSampleBufferDisplayLayer 解码失败: \(normalizedReason)")
    }

    func handleVideoRendererRequiresFlushToResumeDecoding() async {
        flushRenderedVideoFeeds(removeDisplayedImage: false)
        pendingFrames.removeAll(keepingCapacity: true)
        decodeQueueWaitingForSyncFrame = RemoteDesktopDecodeQueuePolicy.isPredictiveVideoFormat(
            lastIncomingStreamSignature?.format
        )
        await decoder.resetPreservingLastFrame()
        let now = Date()
        let format = lastIncomingStreamSignature?.format ?? ""
        let governanceEvent = codecGovernance.noteDecodeFailure(
            format: format,
            reason: "renderer-requires-flush",
            at: now
        )
        let governanceHandled = await handleCodecGovernanceEvent(governanceEvent, at: now)
        if !governanceHandled {
            await requestStreamRefreshIfNeeded(reason: "renderer-flush-required", minimumInterval: 0.25)
        }
        SkyBridgeLogger.shared.warning("⚠️ AVSampleBufferDisplayLayer 需要 flush 后才能继续解码，已请求关键帧刷新")
    }

    // MARK: - Input Events

    /// 发送鼠标/触控事件
    public func sendMouseEvent(_ event: MouseEvent) async {
        guard isStreaming else { return }

        do {
            let data = try JSONEncoder().encode(event)
            let message = RemoteMessage(type: .mouseEvent, payload: data)
            try await sendMessage(message)
            noteViewerInteraction(kind: "mouse")
        } catch {
            SkyBridgeLogger.shared.error("❌ 发送鼠标事件失败: \(error.localizedDescription)")
        }
    }

    /// 发送键盘事件
    public func sendKeyboardEvent(_ event: KeyboardEvent) async {
        guard isStreaming else { return }

        do {
            let data = try JSONEncoder().encode(event)
            let message = RemoteMessage(type: .keyboardEvent, payload: data)
            try await sendMessage(message)
            noteViewerInteraction(kind: "keyboard")
        } catch {
            SkyBridgeLogger.shared.error("❌ 发送键盘事件失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Methods - Device Resolution

    private func makeDeviceResolutionCoordinator() -> RemoteDesktopDeviceResolutionCoordinator {
        RemoteDesktopDeviceResolutionCoordinator(
            manager: self,
            connectionManager: connectionManager,
            discoveryManager: DeviceDiscoveryManager.instance,
            crossNetworkCapability: Self.crossNetworkDeviceCapability
        )
    }

    private func shouldUseCrossNetworkTransport(for device: DiscoveredDevice) -> Bool {
        RemoteDesktopTransportSelectionPolicy.shouldUseCrossNetworkTransport(
            for: device,
            crossNetworkState: crossNetwork.state,
            remoteDeviceId: crossNetwork.remoteDeviceId,
            remoteDeviceName: crossNetwork.remoteDeviceName,
            capability: Self.crossNetworkDeviceCapability
        )
    }

    private func isCrossNetworkDevice(_ device: DiscoveredDevice) -> Bool {
        RemoteDesktopTransportSelectionPolicy.isCrossNetworkDevice(
            device,
            capability: Self.crossNetworkDeviceCapability
        )
    }

    private func clearLANSecureChannelState() async {
        if let lanHandshakeTransport, let lanHandshakePeerId {
            await lanHandshakeTransport.removeConnection(for: lanHandshakePeerId)
        }
        if let lanSOAPairKey {
            await PeerSessionArbiter.shared.clearEstablished(pairKey: lanSOAPairKey)
            await PeerSessionArbiter.shared.clearOutgoing(pairKey: lanSOAPairKey, attemptId: nil)
        }
        lanHandshakeDriver = nil
        lanSessionKeys = nil
        lanReceiveLoopConnectionID = nil
        lanSOAPairKey = nil
        lanSecureReplayWindow = RemoteControlSecureReplayWindow()
        lanSecureSendCounter = 0
        lanHandshakePeerId = nil
        lanHandshakeTransport = nil
        resetLANReceiveParserState()
    }

    private func ensureLANRemoteControlTrustBootstrap(
        for device: DiscoveredDevice
    ) async throws {
        guard !shouldUseCrossNetworkTransport(for: device) else {
            return
        }

        let resolvedDevice = connectionManager.resolvedPeerDevice(for: device)
        let deviceResolver = makeDeviceResolutionCoordinator()
        let bootstrapDevice = deviceResolver.activeP2PBootstrapDevice(for: device)
            ?? deviceResolver.activeP2PBootstrapDevice(for: resolvedDevice)
            ?? resolvedDevice
        let bootstrapPeerId = bootstrapDevice.id
        let bootstrapStatus = connectionManager.resolvedConnectionStatus(for: bootstrapDevice)

        if bootstrapStatus != .connected {
            SkyBridgeLogger.shared.info(
                "🧩 LAN 远控前置 bootstrap：先建立通用 P2P 会话以同步 authority peer=\(bootstrapPeerId)"
            )
            try await connectionManager.connect(to: bootstrapDevice)
        }

        let resolvedBootstrapPeer = connectionManager.resolvedPeerDevice(for: bootstrapDevice)
        let observedAt = Date()
        try await connectionManager.sendPairingIdentityExchange(to: resolvedBootstrapPeer.id)

        let observedReply = await connectionManager.waitForPairingIdentityExchangeActivity(
            with: resolvedBootstrapPeer.id,
            since: observedAt,
            timeout: .seconds(8)
        )
        let bootstrapReady = await connectionManager.waitForPairingIdentityExchangeBootstrapReadiness(
            with: resolvedBootstrapPeer.id,
            since: observedAt,
            timeout: .seconds(8)
        )
        if bootstrapReady {
            SkyBridgeLogger.shared.info(
                "🧩 LAN 远控前置 bootstrap 完成：reply=\(observedReply) ready=\(bootstrapReady) peer=\(resolvedBootstrapPeer.id)"
            )
            return
        }

        if let reason = Self.lanRemoteControlTrustBootstrapFailureReason(
            observedReply: observedReply,
            bootstrapReady: bootstrapReady
        ) {
            SkyBridgeLogger.shared.error(
                "⛔️ LAN 远控前置 bootstrap fail-fast: peer=\(resolvedBootstrapPeer.id) \(reason)"
            )
            throw RemoteDesktopError.connectionFailed(reason)
        }
    }

    private func establishLANSecureChannel(
        for device: DiscoveredDevice,
        over connection: NWConnection
    ) async throws {
        let trustedDevices = TrustedDeviceStore.shared.trustedDevices
        let trustedPeerId = try RemoteDesktopLANHandshakeTrust.resolveTrustedLANPeerIdentifier(
            for: device,
            trustedDevices: trustedDevices
        )
        let trustedAuthority = try await RemoteDesktopLANHandshakeTrust.resolveTrustedRemoteAuthority(
            for: device,
            trustedPeerId: trustedPeerId,
            trustedDevices: trustedDevices
        )
        let trustProvider = LANRemoteControlHandshakeTrustProvider(
            expectedRemoteAuthority: trustedAuthority
        )

        try await skyBridgeCore.initialize(policy: .requirePQC)

        let transport = NWConnectionTransport()
        await transport.setConnection(connection, for: trustedPeerId)
        lanHandshakeTransport = transport
        lanHandshakePeerId = trustedPeerId
        lanSessionKeys = nil
        lanReceiveLoopConnectionID = nil
        lanSecureReplayWindow = RemoteControlSecureReplayWindow()
        lanSecureSendCounter = 0
        lanHandshakeDriver = nil

        let localDeviceId = resolvedLocalRemoteControlDeviceId()
        guard let localSOAPeerId = RemoteDesktopLANHandshakeTrust.remoteControlSOAPeerId(for: localDeviceId),
              let expectedRemoteSOAPeerId = RemoteDesktopLANHandshakeTrust.remoteControlSOAPeerId(for: trustedPeerId),
              let soaMetadata = try? HandshakeSOAMetadata(
                initiatorPeerId: localSOAPeerId,
                targetPeerId: expectedRemoteSOAPeerId,
                attemptId: RemoteDesktopLANHandshakeTrust.randomRemoteControlAttemptId()
              ) else {
            throw RemoteDesktopError.connectionFailed("LAN 远控缺少稳定身份，无法建立安全通道")
        }
        let pairKey = PeerSessionArbiter.pairKey(
            localPeerId: localSOAPeerId,
            remotePeerId: expectedRemoteSOAPeerId,
            scope: .remoteControl
        )
        lanSOAPairKey = pairKey

        let connectionID = ObjectIdentifier(connection)
        let keys = try await skyBridgeCore.performHandshake(
            deviceId: trustedPeerId,
            transport: transport,
            preferPQC: true,
            soaMetadata: soaMetadata,
            localSOAPeerId: localSOAPeerId,
            expectedRemoteSOAPeerId: expectedRemoteSOAPeerId,
            trustProvider: trustProvider,
            soaSessionScope: .remoteControl,
            onDriverCreated: { driver in
                await MainActor.run {
                    RemoteDesktopManager.instance.installLANHandshakeDriver(
                        driver,
                        forConnectionID: connectionID,
                        peerId: trustedPeerId
                    )
                    RemoteDesktopManager.instance.startReceiving()
                }
            }
        )

        try ensureLANBootstrapStillActive(for: connection)
        try installLANSecureSessionKeys(keys, peerId: trustedPeerId, source: "performHandshake-return")
    }

    private func installLANHandshakeDriver(
        _ driver: HandshakeDriver,
        forConnectionID connectionID: ObjectIdentifier,
        peerId: String
    ) {
        guard let current = networkConnection,
              ObjectIdentifier(current) == connectionID else {
            return
        }
        lanHandshakeDriver = driver
        lanHandshakePeerId = peerId
    }

    private func installLANSecureSessionKeys(
        _ keys: SessionKeys,
        peerId: String,
        source: String
    ) throws {
        if let existing = lanSessionKeys {
            if Self.isSameLANSecureSession(existing, keys) {
                lanHandshakeDriver = nil
                transportStatusText = currentTransportStatusText()
                SkyBridgeLogger.shared.debug(
                    "ℹ️ 已忽略重复 LAN 远控安全通道安装: peer=\(peerId) session=\(keys.sessionId) source=\(source)"
                )
                return
            }

            let reason = "LAN 远控安全通道已处于活跃 session，拒绝替换 session: peer=\(peerId) existing=\(existing.sessionId) incoming=\(keys.sessionId) source=\(source)"
            SkyBridgeLogger.shared.error("⛔️ \(reason)")
            throw RemoteDesktopError.connectionFailed(reason)
        }

        let shouldDrainBootstrapAfterInstall = shouldContinueLANBootstrapFramingHandoff
        if shouldDrainBootstrapAfterInstall {
            resetLANSecureReceivePipelineState()
            needsLANReceiveBufferDrain = true
        } else {
            resetLANReceiveParserState()
        }
        lanSecureReplayWindow = RemoteControlSecureReplayWindow()
        lanSecureSendCounter = 0
        lanSessionKeys = keys
        lanHandshakeDriver = nil
        transportStatusText = currentTransportStatusText()
        SkyBridgeLogger.shared.info(
            "🔐 LAN 远控安全通道已建立: peer=\(peerId) suite=\(keys.negotiatedSuite.rawValue) source=\(source)"
        )
        if shouldDrainBootstrapAfterInstall,
           let connection = networkConnection,
           !isProcessingLANReceiveBuffer {
            Task { @MainActor [weak self] in
                await self?.processLANReceiveBuffer(from: connection)
            }
        }
    }

    private static func isSameLANSecureSession(_ lhs: SessionKeys, _ rhs: SessionKeys) -> Bool {
        lhs.sessionId == rhs.sessionId
            && lhs.negotiatedSuite.rawValue == rhs.negotiatedSuite.rawValue
            && lhs.role.rawValue == rhs.role.rawValue
            && lhs.transcriptHash == rhs.transcriptHash
            && lhs.sendKey == rhs.sendKey
            && lhs.receiveKey == rhs.receiveKey
    }

    private func isCurrentLANHandshakeDriver(_ driver: HandshakeDriver) -> Bool {
        guard let current = lanHandshakeDriver else { return false }
        return ObjectIdentifier(current) == ObjectIdentifier(driver)
    }

    private func syncLANSecureChannelState(
        after driver: HandshakeDriver,
        forConnectionID connectionID: ObjectIdentifier
    ) async throws {
        guard let current = networkConnection,
              ObjectIdentifier(current) == connectionID else {
            return
        }
        guard isCurrentLANHandshakeDriver(driver) else {
            SkyBridgeLogger.shared.debug("ℹ️ 已忽略过期 LAN 远控握手驱动器状态: source=handshake-driver-established")
            return
        }

        switch await driver.getCurrentState() {
        case .established(let keys):
            try installLANSecureSessionKeys(
                keys,
                peerId: lanHandshakePeerId ?? "-",
                source: "handshake-driver-established"
            )
        case .failed(let reason):
            throw RemoteDesktopError.connectionFailed("LAN 远控握手失败: \(String(describing: reason))")
        default:
            break
        }
    }

    private func unwrapLANInboundPayload(
        _ data: Data,
        from connection: NWConnection
    ) async throws -> Data? {
        guard activeTransportMode == .lan else { return data }

        if let lanSessionKeys {
            return try decryptLANPayload(data, with: lanSessionKeys)
        }

        guard let lanHandshakeDriver, let lanHandshakePeerId else {
            throw RemoteDesktopError.connectionFailed("收到未认证的 LAN 远控帧")
        }

        await lanHandshakeDriver.handleMessage(data, from: PeerIdentifier(deviceId: lanHandshakePeerId))
        try await syncLANSecureChannelState(
            after: lanHandshakeDriver,
            forConnectionID: ObjectIdentifier(connection)
        )
        return nil
    }

    private func encryptLANPayload(
        _ plaintext: Data,
        with keys: SessionKeys,
        packetType: RemoteControlSecurePacketType
    ) throws -> Data {
        guard lanSecureSendCounter < UInt64.max else {
            throw RemoteDesktopError.connectionFailed("LAN secure envelope counter exhausted")
        }
        lanSecureSendCounter += 1
        return try RemoteControlSecureEnvelope.seal(
            plaintext,
            keys: keys,
            packetType: packetType,
            counter: lanSecureSendCounter
        )
    }

    private func decryptLANPayload(_ ciphertext: Data, with keys: SessionKeys) throws -> Data {
        let openedPayload = try RemoteControlSecureEnvelope.open(
            ciphertext,
            keys: keys,
            allowedPacketTypes: [.control, .screen, .audio]
        )
        try lanSecureReplayWindow.validateAndRecord(openedPayload)
        return openedPayload.payload
    }

    private func resolvedLocalRemoteControlDeviceId() -> String {
        ProtocolDeviceIdentity.stablePersistentDeviceId()
    }

    // MARK: - Private Methods - Connection

    private func createConnection(toAnyOf endpoints: [NWEndpoint]) async throws -> NWConnection {
        guard !endpoints.isEmpty else {
            throw RemoteDesktopError.connectionFailed("设备缺少可连接地址（Bonjour/IP）")
        }

        var lastError: Error?
        let perEndpointTimeout: TimeInterval
        if endpoints.count > 1 {
            perEndpointTimeout = RemoteDesktopConstants.candidateConnectionTimeout
        } else {
            perEndpointTimeout = RemoteDesktopConstants.connectionTimeout
        }

        for (index, endpoint) in endpoints.enumerated() {
            let endpointDescription = String(describing: endpoint)
            let addressClass = RemoteDesktopLANRoutePolicy.routeAddressClass(for: endpoint)
            let peerToPeer = RemoteDesktopLANRoutePolicy.shouldIncludePeerToPeer(for: endpoint)
            SkyBridgeLogger.shared.info(
                "🔗 LAN 远控连接候选[\(index + 1)/\(endpoints.count)]: endpoint=\(endpointDescription) addressClass=\(addressClass) peerToPeer=\(peerToPeer)"
            )
            let routeLine = "ios-lan-remote-route candidate=\(index + 1)/\(endpoints.count) addressClass=\(addressClass) peerToPeer=\(peerToPeer) endpoint=\(RemoteDesktopLANRoutePolicy.statusToken(endpointDescription))"
            SkyBridgeLogger.shared.info(routeLine)
            SkyBridgeSmokeTraceWriter.appendStatus(routeLine)
            SkyBridgeSmokeTraceWriter.append(routeLine)

            do {
                let connection = try await createConnection(to: endpoint, timeout: perEndpointTimeout)
                SkyBridgeLogger.shared.info(
                    "✅ LAN 远控连接就绪: endpoint=\(endpointDescription)"
                )
                return connection
            } catch {
                lastError = error
                SkyBridgeLogger.shared.warning(
                    "⚠️ LAN 远控候选连接失败[\(index + 1)/\(endpoints.count)]: endpoint=\(endpointDescription) error=\(error.localizedDescription)"
                )
            }
        }

        if let lastError {
            throw lastError
        }
        throw RemoteDesktopError.connectionFailed("所有 LAN 远控端点均不可用")
    }

    private func createConnection(
        to endpoint: NWEndpoint,
        timeout: TimeInterval = RemoteDesktopConstants.connectionTimeout
    ) async throws -> NWConnection {
        let endpointDescription = String(describing: endpoint)
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = RemoteDesktopLANRoutePolicy.shouldIncludePeerToPeer(for: endpoint)
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 15
            tcp.keepaliveCount = 4
        }

        let connection = NWConnection(to: endpoint, using: parameters)

        final class ContinuationGate: @unchecked Sendable {
            private let lock = NSLock()
            private var didResume = false
            func runOnce(_ body: () -> Void) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                body()
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let resolvedEndpoint = connection.currentPath?.remoteEndpoint
                    let routeReadyLine = "ios-lan-remote-route-ready requestedAddressClass=\(RemoteDesktopLANRoutePolicy.routeAddressClass(for: endpoint)) resolvedAddressClass=\(RemoteDesktopLANRoutePolicy.routeAddressClass(for: resolvedEndpoint)) resolvedPeerToPeer=\(RemoteDesktopLANRoutePolicy.routePrefersPeerToPeer(for: resolvedEndpoint)) requested=\(RemoteDesktopLANRoutePolicy.statusToken(endpointDescription)) resolved=\(RemoteDesktopLANRoutePolicy.statusToken(RemoteDesktopLANRoutePolicy.routeDescription(for: resolvedEndpoint)))"
                    SkyBridgeLogger.shared.info(routeReadyLine)
                    SkyBridgeSmokeTraceWriter.appendStatus(routeReadyLine)
                    SkyBridgeSmokeTraceWriter.append(routeReadyLine)
                    if let rejection = RemoteDesktopLANRoutePolicy.resolvedRouteRejection(
                        requestedEndpoint: endpoint,
                        resolvedEndpoint: resolvedEndpoint
                    ) {
                        gate.runOnce {
                            connection.stateUpdateHandler = nil
                            connection.cancel()
                            continuation.resume(throwing: RemoteDesktopError.connectionFailed(rejection))
                        }
                        return
                    }
                    gate.runOnce { continuation.resume(returning: connection) }
                case .waiting(let error):
                    SkyBridgeLogger.shared.warning(
                        "⏳ LAN 远控连接等待: endpoint=\(endpointDescription) error=\(error.localizedDescription)"
                    )
                case .failed(let error):
                    gate.runOnce {
                        continuation.resume(throwing: RemoteDesktopError.connectionFailed(error.localizedDescription))
                    }
                case .cancelled:
                    gate.runOnce { continuation.resume(throwing: RemoteDesktopError.disconnected) }
                default:
                    break
                }
            }

            connection.start(queue: queue)

            // 超时处理
            queue.asyncAfter(deadline: .now() + timeout) {
                gate.runOnce {
                    connection.stateUpdateHandler = nil
                    SkyBridgeLogger.shared.error(
                        "❌ LAN 远控连接超时: endpoint=\(endpointDescription) timeout=\(Int(timeout))s"
                    )
                    connection.cancel()
                    continuation.resume(throwing: RemoteDesktopError.timeout)
                }
            }
        }
    }

    private func sendMessage(_ message: RemoteMessage) async throws {
        // WebRTC DataChannel path
        if activeTransportMode == .crossNetwork {
            try await crossNetwork.sendRemoteDesktopMessage(message)
            return
        }

        // NWConnection path (LAN)
        guard let connection = networkConnection else {
            if activeTransportMode == .none, case .connected = crossNetwork.state {
                // 兼容旧状态：transport 尚未设置但 DataChannel 已连上时，回退走 WebRTC。
                try await crossNetwork.sendRemoteDesktopMessage(message)
                return
            }
            throw RemoteDesktopError.disconnected
        }

        let plaintext = try JSONEncoder().encode(message)
        if plaintext.count > maxMessageBytes {
            throw RemoteDesktopError.streamingFailed("消息过大：\(plaintext.count) bytes")
        }
        guard let lanSessionKeys else {
            throw RemoteDesktopError.connectionFailed("LAN 远控安全通道尚未建立")
        }
        let payload = try encryptLANPayload(plaintext, with: lanSessionKeys, packetType: .control)
        if payload.count > maxLANWireMessageBytes {
            throw RemoteDesktopError.streamingFailed("加密后的消息过大：\(payload.count) bytes")
        }

        var length = UInt32(payload.count).bigEndian
        var framedData = Data(bytes: &length, count: 4)
        framedData.append(payload)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: framedData, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: RemoteDesktopError.streamingFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // MARK: - Private Methods - Receiving

    private func startReceiving() {
        guard let connection = networkConnection else { return }
        let connectionID = ObjectIdentifier(connection)
        guard lanReceiveLoopConnectionID != connectionID else {
            SkyBridgeLogger.shared.debug("ℹ️ LAN receive loop 已在当前连接上运行，跳过重复启动")
            return
        }
        lanReceiveLoopConnectionID = connectionID
        if lanSessionKeys == nil {
            resetLANReceiveParserState()
        } else {
            SkyBridgeLogger.shared.debug("ℹ️ LAN secure session 已存在，保留接收管线状态并启动接收循环")
        }
        receiveNextLANChunk(from: connection, secureContext: makeLANSecureReceiveContextIfAvailable(for: connection))
    }

    private func makeLANSecureReceiveContextIfAvailable(for connection: NWConnection) -> LANSecureReceiveLoopContext? {
        guard isCurrentLANConnection(connection),
              let keys = lanSessionKeys,
              !shouldContinueLANBootstrapFramingHandoff else {
            return nil
        }
        return LANSecureReceiveLoopContext(
            receiveContext: LANSecureReceiveContext(
                connectionID: ObjectIdentifier(connection),
                generation: lanSecureReceiveGeneration,
                keys: keys,
                pipeline: lanSecureReceivePipeline
            ),
            scheduler: lanSecureReceiveScheduler
        )
    }

    private nonisolated func receiveNextLANChunk(
        from connection: NWConnection,
        secureContext: LANSecureReceiveLoopContext? = nil
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: RemoteDesktopManagerRuntimeLimits.lanReceiveChunkMaxBytes
        ) { [weak self] data, _, isComplete, error in
            let receivedAt = Date()
            if let secureContext {
                let receiveContext = secureContext.receiveContext
                let shouldContinueReceiving = error == nil && !isComplete

                if let error {
                    Task { @MainActor [weak self] in
                        guard let self, self.isCurrentLANConnectionID(receiveContext.connectionID) else { return }
                        await self.handleTransportFailure(error.localizedDescription)
                    }
                    return
                }

                if let chunk = data, !chunk.isEmpty {
                    secureContext.scheduler.scheduleChunk(
                        chunk,
                        receivedAt: receivedAt,
                        context: receiveContext,
                        maxCompleteScreenFrames: RemoteDesktopManagerRuntimeLimits.maxLANScreenFramesPerParserDrain,
                        maxDrainBudgetMs: RemoteDesktopManagerRuntimeLimits.maxLANParserDrainBudgetMs,
                        completion: { [weak self] result, connectionID, generation in
                            await self?.handleScheduledSecureLANReceiveResult(
                                result,
                                connectionID: connectionID,
                                generation: generation
                            )
                        }
                    )
                }

                if shouldContinueReceiving {
                    self?.receiveNextLANChunk(from: connection, secureContext: secureContext)
                }

                if isComplete {
                    Task { @MainActor [weak self] in
                        guard let self, self.isCurrentLANConnectionID(receiveContext.connectionID) else { return }
                        await self.handleTransportFailure(
                            RemoteDesktopError.disconnected.errorDescription ?? "连接已断开"
                        )
                    }
                }
                return
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isCurrentLANConnection(connection) else { return }
                let shouldContinueReceiving = error == nil && !isComplete

                if let error = error {
                    await self.handleTransportFailure(error.localizedDescription)
                    return
                }

                if let chunk = data, !chunk.isEmpty {
                    if let keys = self.lanSessionKeys,
                       !self.shouldContinueLANBootstrapFramingHandoff {
                        self.processSecureLANReceiveChunk(
                            chunk,
                            receivedAt: receivedAt,
                            from: connection,
                            keys: keys
                        )
                    } else {
                        self.noteLANRawChunkReceived(receivedAt: receivedAt, handlingStartedAt: Date())
                        self.lanReceiveBuffer.append(chunk)
                        self.lanReceiveBufferNewestArrivalAt = receivedAt
                        self.lanReceiveBufferArrivalMarkers.append(
                            (endOffset: self.lanReceiveBuffer.count, receivedAt: receivedAt)
                        )
                        await self.processLANReceiveBuffer(from: connection)
                    }
                }

                if isComplete {
                    await self.handleTransportFailure(
                        RemoteDesktopError.disconnected.errorDescription ?? "连接已断开"
                    )
                    return
                }

                if shouldContinueReceiving,
                   self.isCurrentLANConnection(connection) {
                    self.receiveNextLANChunk(
                        from: connection,
                        secureContext: self.makeLANSecureReceiveContextIfAvailable(for: connection)
                    )
                }
            }
        }
    }

    private func processSecureLANReceiveChunk(
        _ chunk: Data,
        receivedAt: Date,
        from connection: NWConnection,
        keys: SessionKeys
    ) {
        let connectionID = ObjectIdentifier(connection)
        let generation = lanSecureReceiveGeneration
        let context = LANSecureReceiveContext(
            connectionID: connectionID,
            generation: generation,
            keys: keys,
            pipeline: lanSecureReceivePipeline
        )
        lanSecureReceiveScheduler.scheduleChunk(
            chunk,
            receivedAt: receivedAt,
            context: context,
            maxCompleteScreenFrames: RemoteDesktopManagerRuntimeLimits.maxLANScreenFramesPerParserDrain,
            maxDrainBudgetMs: RemoteDesktopManagerRuntimeLimits.maxLANParserDrainBudgetMs,
            completion: { [weak self] result, connectionID, generation in
                await self?.handleScheduledSecureLANReceiveResult(
                    result,
                    connectionID: connectionID,
                    generation: generation
                )
            }
        )
    }

    private func handleScheduledSecureLANReceiveResult(
        _ result: Result<LANRemoteSecureReceiveResult, Error>,
        connectionID: ObjectIdentifier,
        generation: UInt64
    ) async {
        switch result {
        case .success(let receiveResult):
            scheduleSecureLANReceiveApply(
                receiveResult,
                connectionID: connectionID,
                generation: generation
            )
        case .failure(let error):
            await handleSecureLANReceiveFailure(
                error,
                connectionID: connectionID,
                generation: generation
            )
        }
    }

    private func scheduleSecureLANReceiveApply(
        _ result: LANRemoteSecureReceiveResult,
        connectionID: ObjectIdentifier,
        generation: UInt64
    ) {
        guard generation == lanSecureReceiveGeneration else { return }
        let previousApply = lanSecureReceiveApplyChain
        let applyScheduledAt = Date()
        let task = Task(priority: .high) { [weak self, previousApply, result, connectionID, generation, applyScheduledAt] in
            await previousApply?.value
            guard !Task.isCancelled else { return }
            let applyStartedAt = Date()
            await self?.applySecureLANReceiveResult(
                result,
                connectionID: connectionID,
                generation: generation,
                applyScheduledAt: applyScheduledAt,
                applyStartedAt: applyStartedAt
            )
        }
        lanSecureReceiveApplyChain = task
    }

    private func applySecureLANReceiveResult(
        _ result: LANRemoteSecureReceiveResult,
        connectionID: ObjectIdentifier,
        generation: UInt64,
        applyScheduledAt: Date,
        applyStartedAt: Date
    ) async {
        guard isCurrentLANConnectionID(connectionID),
              generation == lanSecureReceiveGeneration,
              activeTransportMode == .lan else {
            return
        }
        noteLANSecureApplyQueueDelay(scheduledAt: applyScheduledAt, startedAt: applyStartedAt)

        if let rawChunk = result.rawChunk {
            noteLANRawChunkReceived(
                receivedAt: rawChunk.receivedAt,
                handlingStartedAt: rawChunk.handlingStartedAt,
                parseTaskScheduledAt: rawChunk.parseTaskScheduledAt,
                parseTaskStartedAt: rawChunk.parseTaskStartedAt
            )
        }
        if result.sbc2Chunks > 0 {
            lanInboundScreenWireFormat = "sbc2-chunked-v1"
            lanInboundScreenChunksInWindow += result.sbc2Chunks
        }
        if result.payloads > 0 || result.sbc2Chunks > 0 || !result.events.isEmpty {
            lanInboundReceiveParserMode = "secure-off-main-actor"
        }
        if result.sbc2Frames > 0 {
            lanInboundChunkedScreenFramesInWindow += result.sbc2Frames
        }
        if !result.secureReplayDrops.isEmpty {
            logLANSecureReplayDrops(result.secureReplayDrops)
        }
        if !result.sbc2Drops.isEmpty {
            await handleLANSBC2FrameDrops(result.sbc2Drops)
        }
        noteLANParserDrain(
            payloads: result.payloads,
            completeFrames: result.completeFrames,
            startedAt: result.parserDrainStartedAt,
            endedAt: result.parserDrainEndedAt,
            parserTimeBudgetHit: result.parserTimeBudgetHit,
            stageTelemetry: result.parserStageTelemetry
        )
        logLANSecureParserSlowDrainIfNeeded(
            result,
            applyScheduledAt: applyScheduledAt,
            applyStartedAt: applyStartedAt
        )

        for event in result.events {
            guard isCurrentLANConnectionID(connectionID) else { return }
            switch event {
            case .audio(let audioChunk):
                handleInboundRemoteAudioChunk(audioChunk)
            case .screen(let screenData, let payloadBytes, let bodyReceivedAt):
                let screenApplyStartedAt = Date()
                noteLANInboundScreenFrameRead(
                    payloadBytes: payloadBytes,
                    bodyReceivedAt: bodyReceivedAt,
                    sourceTimestamp: screenData.timestamp
                )
                await handleScreenData(screenData, receivedAt: bodyReceivedAt)
                let screenApplyEndedAt = Date()
                noteLANSecureScreenApplyDuration(startedAt: screenApplyStartedAt, endedAt: screenApplyEndedAt)
                noteLANSocketToApplyEnd(bodyReceivedAt: bodyReceivedAt, endedAt: screenApplyEndedAt)
            case .control(let message, let payloadBytes, let bodyReceivedAt):
                do {
                    _ = try await handleInboundLANRemoteMessage(
                        message,
                        payloadBytes: payloadBytes,
                        bodyReceivedAt: bodyReceivedAt
                    )
                } catch {
                    await handleSecureLANReceiveFailure(
                        error,
                        connectionID: connectionID,
                        generation: generation
                    )
                    return
                }
            }
        }
    }

    private func handleSecureLANReceiveFailure(
        _ error: Error,
        connectionID: ObjectIdentifier,
        generation: UInt64
    ) async {
        guard isCurrentLANConnectionID(connectionID),
              generation == lanSecureReceiveGeneration else {
            SkyBridgeLogger.shared.debug(
                "ℹ️ Ignored stale LAN secure receive failure: generation=\(generation) current=\(lanSecureReceiveGeneration)"
            )
            return
        }
        let reason: String
        if let remoteError = error as? RemoteDesktopError {
            reason = remoteError.errorDescription ?? String(describing: remoteError)
        } else {
            reason = error.localizedDescription
        }
        SkyBridgeLogger.shared.error("❌ LAN secure receive pipeline failed: \(reason)")
        await handleTransportFailure(reason)
    }

    private func processLANReceiveBuffer(from connection: NWConnection) async {
        guard !isProcessingLANReceiveBuffer else {
            needsLANReceiveBufferDrain = true
            return
        }
        isProcessingLANReceiveBuffer = true
        let drainStartedAt = Date()
        var payloadsInDrain = 0
        var completeFramesInDrain = 0
        var parserTimeBudgetHitInDrain = false
        defer {
            noteLANBootstrapParserDrain(
                payloads: payloadsInDrain,
                completeFrames: completeFramesInDrain,
                startedAt: drainStartedAt,
                endedAt: Date(),
                parserTimeBudgetHit: parserTimeBudgetHitInDrain
            )
            isProcessingLANReceiveBuffer = false
            let shouldDrainAgain = needsLANReceiveBufferDrain || hasCompleteLANFramedPayloadPending()
            needsLANReceiveBufferDrain = false
            if shouldDrainAgain, isCurrentLANConnection(connection) {
                Task { @MainActor [weak self] in
                    await self?.processLANReceiveBuffer(from: connection)
                }
            }
        }

        do {
            while isCurrentLANConnection(connection) {
                guard let nextPayload = try nextLANFramedPayloadFromReceiveBuffer() else { return }
                payloadsInDrain += 1
                let data = nextPayload.payload
                let bodyReceivedAt = nextPayload.receivedAt ?? drainStartedAt
                if let keys = lanSessionKeys {
                    let framedPayload = Self.lanLengthPrefixedFrame(for: data)
                    processSecureLANReceiveChunk(
                        framedPayload,
                        receivedAt: bodyReceivedAt,
                        from: connection,
                        keys: keys
                    )
                    if payloadsInDrain > 0,
                       Date().timeIntervalSince(drainStartedAt) * 1_000 >= RemoteDesktopManagerRuntimeLimits.maxLANParserDrainBudgetMs {
                        parserTimeBudgetHitInDrain = true
                        needsLANReceiveBufferDrain = hasCompleteLANFramedPayloadPending()
                        return
                    }
                    continue
                }
                let chunkedPayloadResult = try unwrapLANChunkedPayloadIfNeeded(
                    data,
                    receivedAt: bodyReceivedAt
                )
                let completeWirePayload: Data
                switch chunkedPayloadResult {
                case .waiting:
                    continue
                case .complete(let payload):
                    completeWirePayload = payload
                case .mediaDrop(let drop):
                    await handleLANSBC2FrameDrops([drop])
                    continue
                }
                let payload = try await unwrapLANInboundPayload(completeWirePayload, from: connection)
                guard let payload else { continue }
                let payloadKind = try await handleInboundLANPayload(
                    payload,
                    bodyReceivedAt: bodyReceivedAt
                )
                if payloadKind == .screen {
                    completeFramesInDrain += 1
                    if completeFramesInDrain >= RemoteDesktopManagerRuntimeLimits.maxLANScreenFramesPerParserDrain {
                        needsLANReceiveBufferDrain = hasCompleteLANFramedPayloadPending()
                        return
                    }
                }
                if payloadsInDrain > 0,
                   Date().timeIntervalSince(drainStartedAt) * 1_000 >= RemoteDesktopManagerRuntimeLimits.maxLANParserDrainBudgetMs {
                    parserTimeBudgetHitInDrain = true
                    needsLANReceiveBufferDrain = hasCompleteLANFramedPayloadPending()
                    return
                }
            }
        } catch let error as RemoteDesktopError {
            await handleTransportFailure(error.localizedDescription)
        } catch {
            SkyBridgeLogger.shared.error("❌ 解析消息失败: \(error.localizedDescription)")
        }
    }

    private enum LANChunkedPayloadUnwrapResult {
        case complete(Data)
        case waiting
        case mediaDrop(LANRemoteSecureReceiveResult.SBC2FrameDrop)
    }

    private func unwrapLANChunkedPayloadIfNeeded(
        _ data: Data,
        receivedAt: Date
    ) throws -> LANChunkedPayloadUnwrapResult {
        guard RemoteDesktopScreenFrameWire.startsWithChunkMagic(data) else {
            return .complete(data)
        }

        guard let envelope = RemoteDesktopScreenFrameWire.decodeChunkEnvelopeIfPresent(data) else {
            return .mediaDrop(
                .init(
                    reason: "sbc2-chunk-decode-failed",
                    frameId: nil,
                    bodyReceivedAt: receivedAt,
                    suppressed: false
                )
            )
        }
        lanInboundScreenWireFormat = "sbc2-chunked-v1"
        lanInboundScreenChunksInWindow += 1

        switch lanScreenChunkReassembler.append(envelope, now: receivedAt) {
        case .waiting:
            return .waiting
        case .complete(_, let payload):
            lanInboundChunkedScreenFramesInWindow += 1
            return .complete(payload)
        case .dropped(let reason, let frameId):
            return .mediaDrop(
                .init(
                    reason: reason,
                    frameId: frameId,
                    bodyReceivedAt: receivedAt,
                    suppressed: false
                )
            )
        case .suppressed(let frameId, let reason):
            return .mediaDrop(
                .init(
                    reason: reason,
                    frameId: frameId,
                    bodyReceivedAt: receivedAt,
                    suppressed: true
                )
            )
        }
    }

    private func nextLANFramedPayloadFromReceiveBuffer() throws -> (payload: Data, receivedAt: Date?)? {
        guard lanReceiveBuffer.count >= 4 else { return nil }
        let length = Int(lanReceiveBuffer.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian
        })
        if length <= 0 || length > maxLANWireMessageBytes {
            throw RemoteDesktopError.streamingFailed("消息长度异常：\(length) bytes")
        }

        let totalLength = 4 + length
        guard lanReceiveBuffer.count >= totalLength else { return nil }
        let receivedAt = lanReceiveBufferArrivalTime(forPayloadEndingAt: totalLength)
        let payloadStart = lanReceiveBuffer.index(lanReceiveBuffer.startIndex, offsetBy: 4)
        let payloadEnd = lanReceiveBuffer.index(payloadStart, offsetBy: length)
        let payload = Data(lanReceiveBuffer[payloadStart..<payloadEnd])
        lanReceiveBuffer.removeSubrange(lanReceiveBuffer.startIndex..<payloadEnd)
        consumeLANReceiveBufferBytes(totalLength)
        return (payload, receivedAt)
    }

    private static func lanLengthPrefixedFrame(for payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(payload)
        return framed
    }

    private func lanReceiveBufferArrivalTime(forPayloadEndingAt endOffset: Int) -> Date? {
        lanReceiveBufferArrivalMarkers.first(where: { $0.endOffset >= endOffset })?.receivedAt
            ?? lanReceiveBufferNewestArrivalAt
    }

    private func consumeLANReceiveBufferBytes(_ byteCount: Int) {
        guard byteCount > 0 else { return }
        lanReceiveBufferArrivalMarkers = lanReceiveBufferArrivalMarkers.compactMap { marker in
            let adjustedEndOffset = marker.endOffset - byteCount
            guard adjustedEndOffset > 0 else { return nil }
            return (endOffset: adjustedEndOffset, receivedAt: marker.receivedAt)
        }
        lanReceiveBufferNewestArrivalAt = lanReceiveBufferArrivalMarkers.last?.receivedAt
    }

    private func hasCompleteLANFramedPayloadPending() -> Bool {
        guard lanReceiveBuffer.count >= 4 else { return false }
        let length = Int(lanReceiveBuffer.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian
        })
        guard length > 0, length <= maxLANWireMessageBytes else { return true }
        return lanReceiveBuffer.count >= 4 + length
    }

    private func receiveNextMessage(from connection: NWConnection) {
        // 兼容旧的整帧 receive 入口；LAN 主路径使用 receiveNextLANChunk 持续 armed socket。
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isCurrentLANConnection(connection) else { return }

                if let error = error {
                    await self.handleTransportFailure(error.localizedDescription)
                    return
                }

                guard let lengthData = data, lengthData.count == 4 else {
                    if isComplete {
                        await self.handleTransportFailure(
                            RemoteDesktopError.disconnected.errorDescription ?? "连接已断开"
                        )
                        return
                    }
                    self.receiveNextMessage(from: connection)
                    return
                }

                let length = Int(lengthData.withUnsafeBytes { raw -> UInt32 in
                    raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian
                })
                if length <= 0 || length > self.maxLANWireMessageBytes {
                    await self.handleTransportFailure("消息长度异常：\(length) bytes")
                    return
                }

                self.receiveMessageBody(of: length, from: connection)
            }
        }
    }

    private func receiveMessageBody(of length: Int, from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] messageData, _, isComplete, error in
            let bodyReceivedAt = Date()
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isCurrentLANConnection(connection) else { return }

                if let error = error {
                    await self.handleTransportFailure(error.localizedDescription)
                    return
                }

                guard let data = messageData else {
                    if isComplete {
                        await self.handleTransportFailure(
                            RemoteDesktopError.disconnected.errorDescription ?? "连接已断开"
                        )
                    } else {
                        self.receiveMessageBody(of: length, from: connection)
                    }
                    return
                }

                do {
                    let chunkedPayloadResult = try self.unwrapLANChunkedPayloadIfNeeded(
                        data,
                        receivedAt: bodyReceivedAt
                    )
                    let completeWirePayload: Data
                    switch chunkedPayloadResult {
                    case .waiting:
                        self.receiveNextMessage(from: connection)
                        return
                    case .complete(let payload):
                        completeWirePayload = payload
                    case .mediaDrop(let drop):
                        await self.handleLANSBC2FrameDrops([drop])
                        self.receiveNextMessage(from: connection)
                        return
                    }
                    let payload = try await self.unwrapLANInboundPayload(completeWirePayload, from: connection)
                    guard let payload else {
                        self.receiveNextMessage(from: connection)
                        return
                    }

                    self.receiveNextMessage(from: connection)
                    _ = try await self.handleInboundLANPayload(
                        payload,
                        bodyReceivedAt: bodyReceivedAt
                    )
                } catch let error as RemoteDesktopError {
                    await self.handleTransportFailure(error.localizedDescription)
                    return
                } catch {
                    SkyBridgeLogger.shared.error("❌ 解析消息失败: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handleInboundLANPayload(
        _ payload: Data,
        bodyReceivedAt: Date
    ) async throws -> LANInboundPayloadKind {
        if let audioChunk = RemoteDesktopAudioChunkWire.decodeIfPresent(payload) {
            handleInboundRemoteAudioChunk(audioChunk)
            return .audio
        } else if let screenData = RemoteDesktopScreenFrameWire.decodeIfPresent(payload) {
            noteLANInboundScreenFrameRead(
                payloadBytes: payload.count,
                bodyReceivedAt: bodyReceivedAt,
                sourceTimestamp: screenData.timestamp
            )
            await handleScreenData(screenData, receivedAt: bodyReceivedAt)
            return .screen
        } else {
            let message = try JSONDecoder().decode(RemoteMessage.self, from: payload)
            return try await handleInboundLANRemoteMessage(
                message,
                payloadBytes: payload.count,
                bodyReceivedAt: bodyReceivedAt
            )
        }
    }

    private func handleInboundLANRemoteMessage(
        _ message: RemoteMessage,
        payloadBytes: Int,
        bodyReceivedAt: Date
    ) async throws -> LANInboundPayloadKind {
        switch message.type {
        case .screenData:
            let screenData = try JSONDecoder().decode(ScreenData.self, from: message.payload)
            noteLANInboundScreenFrameRead(
                payloadBytes: payloadBytes,
                bodyReceivedAt: bodyReceivedAt,
                sourceTimestamp: screenData.timestamp
            )
            await handleScreenData(screenData, receivedAt: bodyReceivedAt)
            return .screen
        case .clipboard:
            let payload = try JSONDecoder().decode(RemoteClipboardMessagePayload.self, from: message.payload)
            handleInboundRemoteClipboard(
                data: payload.data,
                mimeType: payload.mimeType,
                fromDeviceId: currentConnection?.device.id
            )
        case .damageReport:
            let report = try JSONDecoder().decode(RemoteDesktopDamageReportPayload.self, from: message.payload)
            handleInboundDamageReport(report)
        case .cursorUpdate:
            let payload = try JSONDecoder().decode(RemoteDesktopCursorPayload.self, from: message.payload)
            handleInboundCursorUpdate(payload)
        case .overlayUpdate:
            let payload = try JSONDecoder().decode(RemoteDesktopOverlayPayload.self, from: message.payload)
            handleInboundOverlayUpdate(payload)
        case .streamConfigurationAck:
            let ack = try JSONDecoder().decode(RemoteDesktopStreamConfigurationAckPayload.self, from: message.payload)
            handleStreamConfigurationAck(ack)
        case .mouseEvent, .keyboardEvent, .streamConfiguration:
            break
        }
        return .control
    }

    private func handleScreenData(_ screenData: ScreenData, receivedAt: Date? = nil) async {
        guard isStreaming, state == .streaming else {
            SkyBridgeLogger.shared.debug(
                "ℹ️ 丢弃 streaming 启动前到达的远控屏幕帧: \(screenData.width)x\(screenData.height) format=\(screenData.format ?? "unknown") dropReason=pre-streaming-frame"
            )
            SkyBridgeSmokeTraceWriter.appendStatus(
                "screen-drop session=\(crossNetwork.activeRemoteDesktopSessionId ?? "-") dropReason=pre-streaming-frame format=\(screenData.format ?? "unknown") size=\(screenData.width)x\(screenData.height)"
            )
            return
        }
        let hasRemoteNativeVideoTrack: Bool
#if canImport(WebRTC)
        hasRemoteNativeVideoTrack = crossNetwork.remoteVideoTrack != nil
#else
        hasRemoteNativeVideoTrack = false
#endif
        let allowsNativeWarmupJPEGFallback = Self.shouldAllowNativeWarmupJPEGFallbackFrame(
            activeTransportModeIsCrossNetwork: activeTransportMode == .crossNetwork,
            hasRemoteNativeVideoTrack: hasRemoteNativeVideoTrack,
            nativeVideoTrackHasRenderedFrame: crossNetwork.remoteVideoTrackHasRenderedFrame,
            format: screenData.format
        )
        if strictCrossNetworkMediaValidationActive && !allowsNativeWarmupJPEGFallback {
            let reason = "strict media validation failed: fallback screen frame received"
            SkyBridgeLogger.shared.error(
                "⛔️ WebRTC strict media validation failed on viewer: reason=fallback-screen-frame-received size=\(screenData.width)x\(screenData.height) format=\(screenData.format ?? "unknown")"
            )
            SkyBridgeSmokeTraceWriter.appendStatus(
                "strict-media-failed session=\(crossNetwork.activeRemoteDesktopSessionId ?? "-") reason=fallback-screen-frame-received format=\(screenData.format ?? "unknown") size=\(screenData.width)x\(screenData.height)"
            )
            await handleTransportFailure(reason)
            return
        }
        if Self.shouldDropNativeWarmupNonJPEGFallbackFrame(
            activeTransportModeIsCrossNetwork: activeTransportMode == .crossNetwork,
            hasRemoteNativeVideoTrack: hasRemoteNativeVideoTrack,
            nativeVideoTrackHasRenderedFrame: crossNetwork.remoteVideoTrackHasRenderedFrame,
            format: screenData.format
        ) {
            let now = Date()
            if now.timeIntervalSince(lastNativeWarmupNonJPEGFallbackDropDiagnosticAt) >= 1.0 {
                lastNativeWarmupNonJPEGFallbackDropDiagnosticAt = now
                SkyBridgeLogger.shared.warning(
                    "⚠️ WebRTC native warmup dropped non-JPEG fallback before viewer topology/decode: \(screenData.width)x\(screenData.height) format=\(screenData.format ?? "unknown") dropReason=native-warmup-non-jpeg-fallback"
                )
                SkyBridgeSmokeTraceWriter.appendStatus(
                    "screen-drop session=\(crossNetwork.activeRemoteDesktopSessionId ?? "-") dropReason=native-warmup-non-jpeg-fallback format=\(screenData.format ?? "unknown") size=\(screenData.width)x\(screenData.height)"
                )
            }
            return
        }
        if Self.shouldIgnoreFallbackFrameAfterNativeVideoRendered(
            activeTransportModeIsCrossNetwork: activeTransportMode == .crossNetwork,
            nativeVideoTrackHasRenderedFrame: crossNetwork.remoteVideoTrackHasRenderedFrame
        ) {
            let now = Date()
            noteReceivedFrame(at: receivedAt ?? now)
            if now.timeIntervalSince(lastNativePrimaryIgnoredFallbackDiagnosticAt) >= 1.0 {
                lastNativePrimaryIgnoredFallbackDiagnosticAt = now
                SkyBridgeLogger.shared.debug(
                    "ℹ️ 忽略 native WebRTC 主链期间的 fallback screen frame: \(screenData.width)x\(screenData.height) format=\(screenData.format ?? "unknown")"
                )
            }
            return
        }
        let now = Date()
        let receiveAccountingAt = receivedAt ?? now
        let isFirstFrameInStream = !hasReceivedFrameInCurrentStream
        noteReceivedFrame(at: receiveAccountingAt)
        lastInboundScreenTimestamp = screenData.timestamp
        if isFirstFrameInStream {
            hasReceivedFrameInCurrentStream = true
            streamConfigurationAckSatisfied = true
            streamConfigurationAckTask?.cancel()
            streamConfigurationAckTask = nil
            configureSessionClipboardSync()
            SkyBridgeLogger.shared.info(
                "✅ 收到首帧: \(screenData.width)x\(screenData.height), format=\(screenData.format ?? "unknown"), bytes=\(screenData.imageData.count)"
            )
            scheduleFirstFrameContinuityCheck(for: streamEpoch, firstFrameAt: receiveAccountingAt)
        } else {
            firstFrameContinuityTask?.cancel()
            firstFrameContinuityTask = nil
        }
        await handleIncomingStreamTopologyChangeIfNeeded(for: screenData)
        let frameResolution = CGSize(width: screenData.width, height: screenData.height)
        let didChangeResolution = resolution != frameResolution
        if didChangeResolution {
            resolution = frameResolution
        }
        if activeTransportMode == .crossNetwork, isFirstFrameInStream || didChangeResolution {
            crossNetwork.noteRemoteVideoTrackResolutionAvailable(
                frameResolution,
                source: "fallback-screen-data"
            )
        }

        if isFirstFrameInStream || now.timeIntervalSince(lastLatencyPublishAt) >= latencyPublishInterval {
            latency = (now.timeIntervalSince1970 - screenData.timestamp) * 1000
            lastLatencyPublishAt = now
        }

        enqueueFrameForDecode(screenData, receivedAt: receivedAt)
    }

    private func handleIncomingStreamTopologyChangeIfNeeded(for screenData: ScreenData) async {
        let normalizedFormat = (screenData.format ?? "").lowercased()
        let newSignature = IncomingStreamSignature(
            format: normalizedFormat,
            width: screenData.width,
            height: screenData.height
        )

        guard let previousSignature = lastIncomingStreamSignature else {
            lastIncomingStreamSignature = newSignature
            lastStreamTopologyRefreshSignature = nil
            streamTopologyFlapCount = 0
            streamTopologyFlapSuppressedUntil = .distantPast
            return
        }

        guard previousSignature != newSignature else { return }
        lastIncomingStreamSignature = newSignature
        let now = Date()
        let recentTopologyChange = now.timeIntervalSince(lastStreamTopologyChangeAt) < 2.0
        let isFallbackProducerFormatSwap =
            (previousSignature.format == "jpeg" && newSignature.format == "hevc")
            || (previousSignature.format == "hevc" && newSignature.format == "jpeg")
            || (previousSignature.format == "jpeg" && newSignature.format == "h264")
            || (previousSignature.format == "h264" && newSignature.format == "jpeg")
        let nearlySameDimensions =
            abs(previousSignature.width - newSignature.width) <= 2
            && abs(previousSignature.height - newSignature.height) <= 2
        let isFallbackProducerFlap = isFallbackProducerFormatSwap
            && (recentTopologyChange || nearlySameDimensions || now < streamTopologyFlapSuppressedUntil)
        lastStreamTopologyChangeAt = now

        if isFallbackProducerFlap {
            streamTopologyFlapCount += 1
            streamTopologyFlapSuppressedUntil = now.addingTimeInterval(10)
        } else if now >= streamTopologyFlapSuppressedUntil {
            streamTopologyFlapCount = 0
        }

        let incomingFrameHasDecoderBootstrap = screenData.isDecoderBootstrapFrame
        let lightweightFlapTransition = isFallbackProducerFlap && incomingFrameHasDecoderBootstrap

        pendingFrames.removeAll(keepingCapacity: true)
        decodeQueueWaitingForSyncFrame = RemoteDesktopDecodeQueuePolicy.isPredictiveVideoFormat(normalizedFormat)
            && !incomingFrameHasDecoderBootstrap
        resetDecodeSequenceTracking()
        consecutiveDecodeMisses = 0
        lastDamageRectCount = 0
        lastDamageUsesFullFrameFallback = false

        if lightweightFlapTransition {
            SkyBridgeLogger.shared.warning(
                "⚠️ WebRTC fallback producer flap suppressed: \(previousSignature.format) \(previousSignature.width)x\(previousSignature.height) -> \(newSignature.format) \(newSignature.width)x\(newSignature.height) count=\(streamTopologyFlapCount)"
            )
        } else {
            invalidateDecodePipelineState()
            decodedVideoRendererPreference = preferredDecodedVideoRenderer()
            frameRate = 0
            lastRenderedFrameTime = nil
            metalAwaitingFirstDisplaySince = nil
            flushRenderedVideoFeeds()
            updateRenderPipeline(.waiting)
            await decoder.markStreamDisrupted(
                format: normalizedFormat,
                width: screenData.width,
                height: screenData.height
            )
        }

        let canRequestRefresh = lastRefreshRequestAt.map { now.timeIntervalSince($0) >= 2.0 } ?? true
        let topologyRefreshSuppressed = isFallbackProducerFlap
            || now < streamTopologyFlapSuppressedUntil
            || lastStreamTopologyRefreshSignature == newSignature
        if canRequestRefresh && !topologyRefreshSuppressed {
            lastRefreshRequestAt = now
            lastStreamTopologyRefreshSignature = newSignature
            lastRequestedStreamRefreshReason = "stream-topology-changed"
            await pushViewerStreamConfiguration(force: true, refreshStream: true)
        }

        if lightweightFlapTransition {
            SkyBridgeLogger.shared.info(
                "🔄 WebRTC fallback producer transition: \(previousSignature.format) \(previousSignature.width)x\(previousSignature.height) -> \(newSignature.format) \(newSignature.width)x\(newSignature.height) decoderReset=false refresh=false"
            )
        } else {
            SkyBridgeLogger.shared.info(
                "🔄 远控视频流拓扑变化: \(previousSignature.format) \(previousSignature.width)x\(previousSignature.height) -> \(newSignature.format) \(newSignature.width)x\(newSignature.height)"
            )
        }
    }

    private func acceptFrameSequenceForDecode(_ screenData: ScreenData, now: Date) -> Bool {
        let isPredictiveVideo = RemoteDesktopDecodeQueuePolicy.isPredictiveVideoFormat(screenData.format)
        let isIndependentFrame = screenData.isIndependentlyDecodableFrame
        let result = RemoteDesktopDecodeQueuePolicy.validatePredictiveSequence(
            previous: lastInboundVideoFrameSequence,
            current: screenData.sequenceNumber,
            isPredictiveVideo: isPredictiveVideo,
            isIndependentFrame: isIndependentFrame
        )

        switch result {
        case .accepted:
            if isPredictiveVideo, let sequenceNumber = screenData.sequenceNumber {
                lastInboundVideoFrameSequence = sequenceNumber
                if isIndependentFrame {
                    lastInboundVideoSyncFrameSequence = sequenceNumber
                }
            }
            return true
        case .duplicateOrReordered(let previous, let current):
            pendingFrames.removeAll(keepingCapacity: true)
            decodeQueueWaitingForSyncFrame = true
            if now.timeIntervalSince(lastVideoSequenceGapLogTime) >= 1.0 {
                lastVideoSequenceGapLogTime = now
                SkyBridgeLogger.shared.error(
                    "⛔️ 远控视频序号回退，拒绝把断链预测帧送入解码器: previous=\(previous) current=\(current) format=\(screenData.format ?? "unknown")"
                )
                SkyBridgeSmokeTraceWriter.appendStatus(
                    "video-sequence-gap previous=\(previous) current=\(current) missing=unknown action=wait-for-sync reason=duplicate-or-reordered format=\(screenData.format ?? "unknown")"
                )
            }
            Task { @MainActor [weak self] in
                await self?.requestStreamRefreshIfNeeded(reason: "decode-sequence-reordered", minimumInterval: 0.25)
            }
            return false
        case .gapRequiresSync(let previous, let current, let missing):
            lastInboundVideoFrameSequence = current
            pendingFrames.removeAll(keepingCapacity: true)
            decodeQueueWaitingForSyncFrame = true
            if now.timeIntervalSince(lastVideoSequenceGapLogTime) >= 1.0 {
                lastVideoSequenceGapLogTime = now
                SkyBridgeLogger.shared.error(
                    "⛔️ 远控视频预测链缺帧，拒绝把断链预测帧送入解码器: previous=\(previous) current=\(current) missing=\(missing) format=\(screenData.format ?? "unknown")"
                )
                SkyBridgeSmokeTraceWriter.appendStatus(
                    "video-sequence-gap previous=\(previous) current=\(current) missing=\(missing) action=wait-for-sync reason=sender-drop-or-missing-reference format=\(screenData.format ?? "unknown")"
                )
            }
            Task { @MainActor [weak self] in
                await self?.requestStreamRefreshIfNeeded(reason: "decode-sequence-gap", minimumInterval: 0.25)
            }
            return false
        }
    }

    private func enqueueFrameForDecode(_ screenData: ScreenData, receivedAt: Date? = nil) {
        let now = Date()
        noteLANSocketToDecodeFeed(receivedAt: receivedAt, feedStartedAt: now)
        noteLANDecodeFeedAttempt()
        guard acceptFrameSequenceForDecode(screenData, now: now) else {
            noteLANDecodeFeedDropped()
            return
        }
        let progressAge = now.timeIntervalSince(lastDecodeQueueProgressAt)
        let maxConcurrentDecodeTasks = maxConcurrentDecodeTasks(for: screenData)
        let pendingBeforeEnqueue = pendingFrames.count
        let decoderProgressStalled = RemoteDesktopDecodeQueuePolicy.isPredictiveVideoFormat(screenData.format)
            && inFlightDecodeCount >= maxConcurrentDecodeTasks
            && progressAge >= RemoteDesktopDecodeQueuePolicy.progressStallThresholdSeconds
        let enqueueResult = RemoteDesktopDecodeQueuePolicy.enqueue(
            screenData,
            into: &pendingFrames,
            waitingForSyncFrame: &decodeQueueWaitingForSyncFrame,
            decoderProgressStalled: decoderProgressStalled
        )
        switch enqueueResult {
        case .droppedIncomingPredictiveFrame, .enteredWaitingForSync:
            noteLANDecodeFeedDropped()
        default:
            noteLANDecodeFeedAccepted()
        }
        if enqueueResult == .enteredWaitingForSync {
            if now.timeIntervalSince(lastDecodeQueueOverflowLogTime) >= 1.0 {
                lastDecodeQueueOverflowLogTime = now
                SkyBridgeLogger.shared.warning(
                    "⚠️ 视频解码队列拥塞，已清空预测帧并等待关键帧恢复: pendingBefore=\(pendingBeforeEnqueue) inflight=\(inFlightDecodeCount) progressAgeMs=\(Int(progressAge * 1000)) stalled=\(decoderProgressStalled)"
                )
            }
            Task { @MainActor [weak self] in
                await self?.requestStreamRefreshIfNeeded(reason: "decode-queue-overflow", minimumInterval: 0.25)
            }
        } else if enqueueResult == .droppedIncomingPredictiveFrame {
            if now.timeIntervalSince(lastDecodeQueueOverflowLogTime) >= 1.0 {
                lastDecodeQueueOverflowLogTime = now
                SkyBridgeLogger.shared.info(
                    "ℹ️ 视频解码队列正在等待关键帧，已暂时丢弃预测帧"
                )
            }
            Task { @MainActor [weak self] in
                await self?.requestStreamRefreshIfNeeded(reason: "decode-waiting-for-sync", minimumInterval: 0.25)
            }
        } else if enqueueResult == .enqueuedAboveSoftLimit {
            if now.timeIntervalSince(lastDecodeQueuePressureLogTime) >= 1.0 {
                lastDecodeQueuePressureLogTime = now
                SkyBridgeLogger.shared.info(
                    "📈 视频解码队列吸收短时 burst: pending=\(pendingFrames.count) softMax=\(RemoteDesktopDecodeQueuePolicy.maxPredictiveVideoFrames) hardMax=\(RemoteDesktopDecodeQueuePolicy.hardMaxPredictiveVideoFrames) inflight=\(inFlightDecodeCount) progressAgeMs=\(Int(progressAge * 1000))"
                )
            }
        } else if enqueueResult == .recoveredWithIndependentFrame {
            if lastRequestedStreamRefreshToken != nil,
               let requestedAt = lastRequestedStreamRefreshAt {
                let waitMs = Int((Date().timeIntervalSince(requestedAt) * 1000).rounded())
                SkyBridgeLogger.shared.info(
                    "♻️ viewer 已收到恢复关键帧: refreshTokenState=present reason=\(lastRequestedStreamRefreshReason ?? "unspecified") waitMs=\(waitMs) transport=\(activeTransportModeLabel())"
                )
                lastRequestedStreamRefreshToken = nil
                lastRequestedStreamRefreshReason = nil
                lastRequestedStreamRefreshAt = nil
                lastRefreshRequestFailureDescription = nil
                hevcDisableRefreshTokenInFlight = nil
                lastWaitingSyncDiagnosticLogTime = .distantPast
            }
            SkyBridgeLogger.shared.info("♻️ 视频解码队列已收到关键帧，恢复连续解码")
        }
        startDecodeLoopIfNeeded()
    }

    private func requestStreamRefreshIfNeeded(
        reason: String = "unspecified",
        minimumInterval: TimeInterval = 0.5
    ) async {
        guard !handleCrossNetworkSessionAuthorityLostIfNeeded(source: "stream-refresh:\(reason)") else {
            return
        }
        let now = Date()
        let effectiveMinimumInterval = activeTransportMode == .lan
            ? max(minimumInterval, lanStreamRefreshMinimumInterval)
            : minimumInterval
        let canRequestRefresh = lastRefreshRequestAt.map {
            now.timeIntervalSince($0) >= effectiveMinimumInterval
        } ?? true
        guard canRequestRefresh else { return }
        lastRefreshRequestAt = now
        lastRequestedStreamRefreshReason = reason
        await pushViewerStreamConfiguration(force: true, refreshStream: true)
    }

    private func handleCodecGovernanceEvent(
        _ event: RemoteDesktopCodecGovernanceEvent,
        at now: Date
    ) async -> Bool {
        switch event {
        case .none:
            return false
        case .requestRefresh:
            await requestStreamRefreshIfNeeded(reason: "codec-governance-request")
            return false
        case .failFastHEVC(let reason):
            hevcDisableRefreshSuppressedUntil = nil
            hevcDisableRefreshTokenInFlight = nil
            SkyBridgeLogger.shared.warning(
                "⚠️ HEVC 主路径连续失败，fail-fast 保留传输并请求同步帧: reason=\(reason)"
            )
            await failFastRemoteDesktopRenderMainPath(
                reason: "hevc-main-path-failed: \(reason)",
                attemptedFallback: "codecGovernance",
                at: now,
                forceSyncFrameWait: true
            )
            return true
        case .reenableHEVCProbe:
            hevcDisableRefreshSuppressedUntil = nil
            hevcDisableRefreshTokenInFlight = nil
            await requestStreamRefreshIfNeeded(reason: "codec-governance-reenable-hevc", minimumInterval: 1.0)
            SkyBridgeLogger.shared.info("♻️ HEVC 主路径探测条件恢复，准备重新请求关键帧")
            return false
        }
    }

    private func noteFrameProgress(at now: Date, frames: Int = 1) {
        lastRenderedFrameTime = now
        let frameDelta = max(1, frames)
        if let lastFrameTime {
            frameCount += frameDelta
            let elapsed = now.timeIntervalSince(lastFrameTime)
            if elapsed >= 1.0 {
                frameRate = Double(frameCount) / elapsed
                frameCount = 0
                self.lastFrameTime = now
            }
        } else {
            frameCount = 1
            lastFrameTime = now
            frameRate = 0
        }
    }

    private func noteReceivedFrame(at now: Date) {
        lastFrameArrivalAt = now
        receivedFrameCountInCurrentStream += 1
        receivedFrameTimesInCurrentStream.append(now)
        trimSmokeFrameTimes(&receivedFrameTimesInCurrentStream, at: now)
        receivedFramesInStatsWindow += 1
        logRemoteDesktopPipelineStatsIfNeeded(at: now)
    }

    private func noteLANInboundScreenFrameRead(
        payloadBytes: Int,
        bodyReceivedAt: Date,
        handlingStartedAt: Date = Date(),
        sourceTimestamp: TimeInterval? = nil
    ) {
        guard activeTransportMode == .lan else { return }
        let mainHopMs = max(0, handlingStartedAt.timeIntervalSince(bodyReceivedAt) * 1_000)
        if let previousReadAt = lanInboundLastScreenFrameReadAt {
            let gapMs = max(0, bodyReceivedAt.timeIntervalSince(previousReadAt) * 1_000)
            lanInboundInterFrameGapMaxMs = max(lanInboundInterFrameGapMaxMs, gapMs)
        }
        lanInboundLastScreenFrameReadAt = bodyReceivedAt
        if let sourceTimestamp, sourceTimestamp > 1_000_000_000 {
            if let previousSourceTimestamp = lanInboundLastSourceTimestamp {
                let sourceGapMs = max(0, (sourceTimestamp - previousSourceTimestamp) * 1_000)
                lanInboundSourceGapMaxMs = max(lanInboundSourceGapMaxMs, sourceGapMs)
            }
            lanInboundLastSourceTimestamp = sourceTimestamp
            appendLANSourceFrameTimestamp(sourceTimestamp)
            let sourceToReadMs = max(0, (bodyReceivedAt.timeIntervalSince1970 - sourceTimestamp) * 1_000)
            lanInboundSourceToReadSamples += 1
            lanInboundSourceToReadTotalMs += sourceToReadMs
            lanInboundSourceToReadMaxMs = max(lanInboundSourceToReadMaxMs, sourceToReadMs)
        }
        lanInboundScreenFramesInWindow += 1
        lanInboundScreenBytesInWindow += max(0, payloadBytes)
        lanInboundMainHopSamples += 1
        lanInboundMainHopTotalMs += mainHopMs
        lanInboundMainHopMaxMs = max(lanInboundMainHopMaxMs, mainHopMs)
    }

    private func enqueueMetalFrameForDisplay(
        _ frame: DecodedPixelBufferFrame,
        generation: UInt64,
        decodedAt: Date
    ) async -> Bool {
        guard activeTransportMode == .lan else {
            let deliveryResult = metalVideoFrameFeed.enqueue(frame: frame)
            if deliveryResult.acceptedByRenderer {
                noteMetalRendererEnqueuedFrame(at: decodedAt)
            }
            return true
        }

        guard generation == decodeGeneration else { return false }

        let deliveredAt = Date()
        let deliveryDelayMs = max(0, deliveredAt.timeIntervalSince(decodedAt) * 1_000)
        lanInboundScreenDeliveryAttemptedInWindow += 1
        lanInboundScreenDeliveryQueueDepthMax = max(
            lanInboundScreenDeliveryQueueDepthMax,
            1
        )
        lanInboundScreenDeliveryDelayMaxMs = max(
            lanInboundScreenDeliveryDelayMaxMs,
            deliveryDelayMs
        )
        guard deliveryDelayMs <= metalFeedDeliveryMaxDelayMs else {
            let reason = "metal-feed-delivery-delay-exceeded delayMs=\(String(format: "%.1f", deliveryDelayMs)) maxMs=\(String(format: "%.1f", metalFeedDeliveryMaxDelayMs)) mode=direct"
            await recoverLANMetalFeedDeliveryDelay(reason: reason, at: deliveredAt)
            return false
        }
        var deliveryResult = metalVideoFrameFeed.enqueue(frame: frame)
        if !deliveryResult.acceptedByRenderer,
           deliveryResult.activeConsumerCount > 0,
           deliveryResult.hasQueueBackpressureRejection {
            lanInboundScreenDeliveryBackpressureInWindow += 1
            deliveryResult = await retryMetalFrameDeliveryAfterRendererBackpressure(
                initialResult: deliveryResult,
                frame: frame,
                decodedAt: decodedAt
            )
        }
        let finalDeliveryDelayMs = max(0, Date().timeIntervalSince(decodedAt) * 1_000)
        lanInboundScreenDeliveryDelayMaxMs = max(
            lanInboundScreenDeliveryDelayMaxMs,
            finalDeliveryDelayMs
        )
        guard finalDeliveryDelayMs <= metalFeedDeliveryMaxDelayMs else {
            let reason = "metal-feed-delivery-delay-exceeded delayMs=\(String(format: "%.1f", finalDeliveryDelayMs)) maxMs=\(String(format: "%.1f", metalFeedDeliveryMaxDelayMs)) rendererReason=\(deliveryResult.rejectionSummary) mode=direct"
            await recoverLANMetalFeedDeliveryDelay(reason: reason, at: Date())
            return false
        }
        guard deliveryResult.acceptedByRenderer else {
            if deliveryResult.activeConsumerCount == 0 {
                SkyBridgeSmokeTraceWriter.appendStatus(
                    "metal-feed-awaiting-renderer-consumer consumers=\(deliveryResult.consumerCount) stale=\(deliveryResult.staleConsumerCount) version=\(deliveryResult.frameVersion) mode=direct"
                )
                return true
            }
            let reason = "metal-feed-renderer-rejected consumers=\(deliveryResult.consumerCount) active=\(deliveryResult.activeConsumerCount) stale=\(deliveryResult.staleConsumerCount) accepted=\(deliveryResult.acceptedConsumerCount) rejected=\(deliveryResult.rejectedConsumerCount) rendererReason=\(deliveryResult.rejectionSummary) version=\(deliveryResult.frameVersion) mode=direct"
            SkyBridgeLogger.shared.error("⛔️ LAN 远控 Metal feed 被 renderer 拒收，fail-fast 保留传输并请求同步帧: \(reason)")
            SkyBridgeSmokeTraceWriter.appendStatus(
                "failed stage=remote-desktop phase=metal_feed_not_accepted detail=\"\(reason)\" transportAction=preserve audioAction=preserve"
            )
            await failFastRemoteDesktopRenderMainPath(
                reason: reason,
                attemptedFallback: "metalVideoFrameFeed",
                at: Date(),
                forceSyncFrameWait: true
            )
            return false
        }
        lanInboundScreenDeliveryDeliveredInWindow += 1
        let acceptedAt = Date()
        lanInboundMetalDeliveryTimesInCurrentStream.append(acceptedAt)
        trimSmokeFrameTimes(&lanInboundMetalDeliveryTimesInCurrentStream, at: acceptedAt)
        noteMetalRendererEnqueuedFrame(at: acceptedAt)
        logLANInboundFrameTelemetryIfNeeded(at: acceptedAt)
        return true
    }

    private func retryMetalFrameDeliveryAfterRendererBackpressure(
        initialResult: RemoteMetalVideoFrameFeed.DeliveryResult,
        frame: DecodedPixelBufferFrame,
        decodedAt: Date
    ) async -> RemoteMetalVideoFrameFeed.DeliveryResult {
        var result = initialResult
        for attempt in 1...metalFeedBackpressureMaxRetries {
            let elapsedMs = max(0, Date().timeIntervalSince(decodedAt) * 1_000)
            guard elapsedMs < metalFeedDeliveryMaxDelayMs else { return result }
            SkyBridgeSmokeTraceWriter.appendStatus(
                "metal-feed-backpressure attempt=\(attempt) waitMs=\(String(format: "%.1f", elapsedMs)) reason=\"\(result.rejectionSummary)\" mode=direct"
            )
            do {
                try await Task.sleep(nanoseconds: metalFeedBackpressureRetryDelayNs)
            } catch {
                return result
            }
            result = metalVideoFrameFeed.enqueue(frame: frame)
            if result.acceptedByRenderer
                || result.activeConsumerCount == 0
                || !result.hasQueueBackpressureRejection {
                return result
            }
        }
        return result
    }

    private func recoverLANMetalFeedDeliveryDelay(reason: String, at now: Date) async {
        lastContinuityRecoveryAt = now
        zeroMeasuredFrameRate(at: now)
        invalidateDecodePipelineState()
        pendingFrames.removeAll(keepingCapacity: true)
        decodeQueueWaitingForSyncFrame = RemoteDesktopDecodeQueuePolicy.isPredictiveVideoFormat(
            lastIncomingStreamSignature?.format
        )
        await decoder.resetPreservingLastFrame()
        lastDecoderResetTime = now
        consecutiveDecodeMisses = 0
        let message =
            "render-continuity-deferred session=\(crossNetwork.activeRemoteDesktopSessionId ?? "-") " +
            "reason=metal-feed-delivery-delay-exceeded classification=main-hop-or-delivery-stall " +
            "detail=\"\(reason)\" attemptedFallback=none fallbackResult=not-attempted action=request-sync"
        if crossNetwork.activeRemoteDesktopSessionId == nil {
            SkyBridgeLogger.shared.info("ℹ️ \(message)")
        } else {
            SkyBridgeLogger.shared.warning("⚠️ \(message)")
        }
        SkyBridgeSmokeTraceWriter.appendStatus(message)
        await requestStreamRefreshIfNeeded(
            reason: "metal-feed-delivery-delay-exceeded",
            minimumInterval: 0.25
        )
    }

    private func noteLANRawChunkReceived(
        receivedAt: Date,
        handlingStartedAt: Date,
        parseTaskScheduledAt: Date? = nil,
        parseTaskStartedAt: Date? = nil
    ) {
        guard activeTransportMode == .lan else { return }
        if let previousRawChunkAt = lanInboundLastRawChunkAt {
            let gapMs = max(0, receivedAt.timeIntervalSince(previousRawChunkAt) * 1_000)
            lanInboundRawChunkGapMaxMs = max(lanInboundRawChunkGapMaxMs, gapMs)
        }
        lanInboundLastRawChunkAt = receivedAt
        lanInboundRawChunksInWindow += 1
        let mainHopMs = max(0, handlingStartedAt.timeIntervalSince(receivedAt) * 1_000)
        lanInboundRawChunkMainHopMaxMs = max(lanInboundRawChunkMainHopMaxMs, mainHopMs)
        if let parseTaskScheduledAt, let parseTaskStartedAt {
            let queueDelayMs = max(0, parseTaskStartedAt.timeIntervalSince(parseTaskScheduledAt) * 1_000)
            lanInboundParseQueueDelayMaxMs = max(lanInboundParseQueueDelayMaxMs, queueDelayMs)
            let actorHopMs = max(0, handlingStartedAt.timeIntervalSince(parseTaskStartedAt) * 1_000)
            lanInboundParserActorHopMaxMs = max(lanInboundParserActorHopMaxMs, actorHopMs)
        }
    }

    private func noteLANSecureApplyQueueDelay(scheduledAt: Date, startedAt: Date) {
        guard activeTransportMode == .lan else { return }
        let delayMs = max(0, startedAt.timeIntervalSince(scheduledAt) * 1_000)
        lanInboundApplyQueueDelayMaxMs = max(lanInboundApplyQueueDelayMaxMs, delayMs)
    }

    private func noteLANSecureScreenApplyDuration(startedAt: Date, endedAt: Date) {
        guard activeTransportMode == .lan else { return }
        let durationMs = max(0, endedAt.timeIntervalSince(startedAt) * 1_000)
        lanInboundScreenApplyMaxMs = max(lanInboundScreenApplyMaxMs, durationMs)
    }

    private func noteLANSocketToDecodeFeed(receivedAt: Date?, feedStartedAt: Date) {
        guard activeTransportMode == .lan, let receivedAt else { return }
        let durationMs = max(0, feedStartedAt.timeIntervalSince(receivedAt) * 1_000)
        lanInboundSocketToDecodeFeedSamples += 1
        lanInboundSocketToDecodeFeedMaxMs = max(lanInboundSocketToDecodeFeedMaxMs, durationMs)
    }

    private func noteLANSocketToApplyEnd(bodyReceivedAt: Date, endedAt: Date) {
        guard activeTransportMode == .lan else { return }
        let durationMs = max(0, endedAt.timeIntervalSince(bodyReceivedAt) * 1_000)
        lanInboundSocketToApplyEndSamples += 1
        lanInboundSocketToApplyEndMaxMs = max(lanInboundSocketToApplyEndMaxMs, durationMs)
    }

    private func noteLANDecodeFeedAttempt() {
        guard activeTransportMode == .lan else { return }
        lanInboundDecodeFeedAttemptedInWindow += 1
        noteLANDecodeQueueWatermark()
    }

    private func noteLANDecodeFeedAccepted() {
        guard activeTransportMode == .lan else { return }
        lanInboundDecodeFeedAcceptedInWindow += 1
        noteLANDecodeQueueWatermark()
    }

    private func noteLANDecodeFeedDropped() {
        guard activeTransportMode == .lan else { return }
        lanInboundDecodeFeedDroppedInWindow += 1
        noteLANDecodeQueueWatermark()
    }

    private func noteLANDecodePipelineReset() {
        guard activeTransportMode == .lan else { return }
        lanInboundDecodeResetCountInWindow += 1
        noteLANDecodeQueueWatermark()
    }

    private func noteLANDecodeQueueWatermark() {
        guard activeTransportMode == .lan else { return }
        lanInboundDecodePendingFramesMax = max(lanInboundDecodePendingFramesMax, pendingFrames.count)
        lanInboundDecodeInFlightMax = max(lanInboundDecodeInFlightMax, inFlightDecodeCount)
        if decodeQueueWaitingForSyncFrame {
            lanInboundDecodeWaitingSyncSamples += 1
        }
    }

    private func noteLANBootstrapParserDrain(
        payloads: Int,
        completeFrames: Int,
        startedAt: Date,
        endedAt: Date,
        parserTimeBudgetHit: Bool
    ) {
        guard activeTransportMode == .lan, payloads > 0 || completeFrames > 0 else { return }
        let drainMs = max(0, endedAt.timeIntervalSince(startedAt) * 1_000)
        lanInboundBootstrapParserDrainMaxMs = max(lanInboundBootstrapParserDrainMaxMs, drainMs)
        if parserTimeBudgetHit {
            lanInboundBootstrapParserBudgetHitsInWindow += 1
        }
    }

    private func noteLANParserDrain(
        payloads: Int,
        completeFrames: Int,
        startedAt: Date,
        endedAt: Date,
        parserTimeBudgetHit: Bool,
        stageTelemetry: LANRemoteSecureReceiveResult.ParserStageTelemetry? = nil
    ) {
        guard activeTransportMode == .lan, payloads > 0 || completeFrames > 0 else { return }
        let drainMs = max(0, endedAt.timeIntervalSince(startedAt) * 1_000)
        lanInboundParserDrainMaxMs = max(lanInboundParserDrainMaxMs, drainMs)
        if let stageTelemetry {
            if stageTelemetry.durationMs > lanInboundParserStageMaxMs {
                lanInboundParserStageMaxName = stageTelemetry.stageName
                lanInboundParserStageMaxMs = stageTelemetry.durationMs
            }
            lanInboundParserStagePayloadBytesMax = max(
                lanInboundParserStagePayloadBytesMax,
                stageTelemetry.payloadBytes
            )
            lanInboundParserStageReceiveBufferBytesMax = max(
                lanInboundParserStageReceiveBufferBytesMax,
                stageTelemetry.receiveBufferBytes
            )
        }
        if parserTimeBudgetHit {
            lanInboundParserBudgetHitsInWindow += 1
        }
        lanInboundPayloadsPerDrainMax = max(lanInboundPayloadsPerDrainMax, payloads)
        lanInboundCompleteFramesPerDrainMax = max(lanInboundCompleteFramesPerDrainMax, completeFrames)
    }

    private func logLANSecureReplayDrops(_ drops: [LANRemoteSecureReceiveResult.SecureReplayDrop]) {
        for drop in drops {
            let message = """
            lan-secure-replay-drop packetType=\(drop.packetType.rawValue) counter=\(drop.counter) \
            highestCounter=\(drop.highestCounter) reason=\(drop.reason.rawValue) action=drop-authenticated-replay \
            transport=lan session=\(realtimeMediaAudioReceiverSessionId ?? crossNetwork.activeRemoteDesktopSessionId ?? "-")
            """
            SkyBridgeLogger.shared.info("\(message)")
            SkyBridgeSmokeTraceWriter.appendStatus(message)
        }
    }

    private func handleLANSBC2FrameDrops(_ drops: [LANRemoteSecureReceiveResult.SBC2FrameDrop]) async {
        guard !drops.isEmpty else { return }
        let actionableDrop = drops.first { !$0.suppressed }
        for drop in drops {
            let message = """
            lan-sbc2-frame-drop reason=\(drop.reason) frameId=\(drop.frameId.map(String.init) ?? "-") \
            suppressed=\(drop.suppressed) action=\(drop.suppressed ? "drop-orphan" : "request-sync") \
            transport=lan session=\(realtimeMediaAudioReceiverSessionId ?? crossNetwork.activeRemoteDesktopSessionId ?? "-")
            """
            SkyBridgeLogger.shared.info("\(message)")
            SkyBridgeSmokeTraceWriter.appendStatus(message)
        }
        guard let actionableDrop else { return }
        pendingFrames.removeAll(keepingCapacity: true)
        decodeQueueWaitingForSyncFrame = true
        await requestStreamRefreshIfNeeded(
            reason: "sbc2-reassembly-\(actionableDrop.reason)",
            minimumInterval: 0.25
        )
    }

    private func logLANSecureParserSlowDrainIfNeeded(
        _ result: LANRemoteSecureReceiveResult,
        applyScheduledAt: Date,
        applyStartedAt: Date
    ) {
        guard activeTransportMode == .lan else { return }
        guard result.payloads > 0 || result.completeFrames > 0 || result.sbc2Chunks > 0 else { return }

        let budgetMs = RemoteDesktopManagerRuntimeLimits.maxLANParserDrainBudgetMs
        let drainMs = max(
            0,
            result.parserDrainEndedAt.timeIntervalSince(result.parserDrainStartedAt) * 1_000
        )
        guard drainMs > budgetMs || result.parserTimeBudgetHit else { return }

        let rawChunk = result.rawChunk
        let rawChunkMainHopMs = rawChunk.map {
            max(0, $0.handlingStartedAt.timeIntervalSince($0.receivedAt) * 1_000)
        } ?? 0
        let parseQueueDelayMs: Double = {
            guard let scheduledAt = rawChunk?.parseTaskScheduledAt,
                  let startedAt = rawChunk?.parseTaskStartedAt else {
                return 0
            }
            return max(0, startedAt.timeIntervalSince(scheduledAt) * 1_000)
        }()
        let parserActorHopMs: Double = {
            guard let startedAt = rawChunk?.parseTaskStartedAt,
                  let handlingStartedAt = rawChunk?.handlingStartedAt else {
                return 0
            }
            return max(0, handlingStartedAt.timeIntervalSince(startedAt) * 1_000)
        }()
        let applyQueueDelayMs = max(0, applyStartedAt.timeIntervalSince(applyScheduledAt) * 1_000)
        let stageTelemetry = result.parserStageTelemetry
        let message = """
        ios-lan-parser-slow session=\(realtimeMediaAudioReceiverSessionId ?? crossNetwork.activeRemoteDesktopSessionId ?? "-") \
        transport=lan drainMs=\(String(format: "%.2f", drainMs)) budgetMs=\(String(format: "%.1f", budgetMs)) \
        budgetHit=\(result.parserTimeBudgetHit ? 1 : 0) pending=\(result.hasCompletePayloadPending ? 1 : 0) \
        payloads=\(result.payloads) completeFrames=\(result.completeFrames) sbc2Chunks=\(result.sbc2Chunks) sbc2Frames=\(result.sbc2Frames) \
        rawChunkBytes=\(rawChunk?.chunkBytes ?? 0) receiveBufferBytesAfterDrain=\(result.receiveBufferBytesAfterDrain) \
        rawChunkMainHopMs=\(String(format: "%.2f", rawChunkMainHopMs)) parseQueueDelayMs=\(String(format: "%.2f", parseQueueDelayMs)) \
        parserActorHopMs=\(String(format: "%.2f", parserActorHopMs)) applyQueueDelayMs=\(String(format: "%.2f", applyQueueDelayMs)) \
        parserStageMax=\(stageTelemetry?.stageName ?? "none") parserStageMaxMs=\(String(format: "%.2f", stageTelemetry?.durationMs ?? 0)) \
        parserStagePayloadBytes=\(stageTelemetry?.payloadBytes ?? 0) parserStageBufferBytes=\(stageTelemetry?.receiveBufferBytes ?? 0)
        """
        SkyBridgeLogger.shared.warning("⚠️ \(message)")
        SkyBridgeSmokeTraceWriter.appendStatus(message)
    }

    private func logLANInboundFrameTelemetryIfNeeded(at now: Date) {
        let elapsed = now.timeIntervalSince(lanInboundTelemetryWindowStartedAt)
        guard elapsed >= 1.0 else { return }
        let sampleMs = Int((elapsed * 1_000).rounded())
        let screenFPS = Double(lanInboundScreenFramesInWindow) / max(elapsed, 0.001)
        let averageMainHopMs = lanInboundMainHopSamples > 0
            ? lanInboundMainHopTotalMs / Double(lanInboundMainHopSamples)
            : 0
        let averageSourceToReadMs = lanInboundSourceToReadSamples > 0
            ? lanInboundSourceToReadTotalMs / Double(lanInboundSourceToReadSamples)
            : 0
        let telemetryLine = """
        ios-lan-remote-rx sampleMs=\(sampleMs) screenFrames=\(lanInboundScreenFramesInWindow) \
        screenFPS=\(String(format: "%.1f", screenFPS)) bytes=\(lanInboundScreenBytesInWindow) \
        screenWire=\(lanInboundScreenWireFormat) sbc2Frames=\(lanInboundChunkedScreenFramesInWindow) sbc2Chunks=\(lanInboundScreenChunksInWindow) \
        parser=\(lanInboundReceiveParserMode) \
        maxGapMs=\(String(format: "%.1f", lanInboundInterFrameGapMaxMs)) \
        sourceSamples=\(lanInboundSourceToReadSamples) sourceGapMaxMs=\(String(format: "%.1f", lanInboundSourceGapMaxMs)) \
        sourceToReadAvgMs=\(String(format: "%.2f", averageSourceToReadMs)) sourceToReadMaxMs=\(String(format: "%.2f", lanInboundSourceToReadMaxMs)) \
        sourceToReadClock=remote-wall-clock-unsynced \
        avgMainHopMs=\(String(format: "%.2f", averageMainHopMs)) \
        maxMainHopMs=\(String(format: "%.2f", lanInboundMainHopMaxMs)) \
        rawChunks=\(lanInboundRawChunksInWindow) rawChunkGapMaxMs=\(String(format: "%.1f", lanInboundRawChunkGapMaxMs)) \
        rawChunkMainHopMaxMs=\(String(format: "%.2f", lanInboundRawChunkMainHopMaxMs)) \
        parseQueueDelayMaxMs=\(String(format: "%.2f", lanInboundParseQueueDelayMaxMs)) \
        parserActorHopMaxMs=\(String(format: "%.2f", lanInboundParserActorHopMaxMs)) \
        parserDrainMaxMs=\(String(format: "%.2f", lanInboundParserDrainMaxMs)) parserBudgetMs=\(String(format: "%.1f", RemoteDesktopManagerRuntimeLimits.maxLANParserDrainBudgetMs)) parserBudgetHits=\(lanInboundParserBudgetHitsInWindow) payloadsPerDrainMax=\(lanInboundPayloadsPerDrainMax) \
        completeFramesPerDrainMax=\(lanInboundCompleteFramesPerDrainMax) \
        parserStageMax=\(lanInboundParserStageMaxName) parserStageMaxMs=\(String(format: "%.2f", lanInboundParserStageMaxMs)) \
        parserStagePayloadBytesMax=\(lanInboundParserStagePayloadBytesMax) parserStageBufferBytesMax=\(lanInboundParserStageReceiveBufferBytesMax) \
        bootstrapParserDrainMaxMs=\(String(format: "%.2f", lanInboundBootstrapParserDrainMaxMs)) \
        bootstrapParserBudgetHits=\(lanInboundBootstrapParserBudgetHitsInWindow) \
        applyQueueDelayMaxMs=\(String(format: "%.2f", lanInboundApplyQueueDelayMaxMs)) \
        screenApplyMaxMs=\(String(format: "%.2f", lanInboundScreenApplyMaxMs)) \
        screenDelivery=immediate-decode-metal-feed-direct screenDeliveryAttempted=\(lanInboundScreenDeliveryAttemptedInWindow) \
        screenDeliveryDelivered=\(lanInboundScreenDeliveryDeliveredInWindow) \
        screenDeliveryBackpressure=\(lanInboundScreenDeliveryBackpressureInWindow) \
        screenDeliveryQueueDepthMax=\(lanInboundScreenDeliveryQueueDepthMax) \
        screenDeliveryDelayMaxMs=\(String(format: "%.2f", lanInboundScreenDeliveryDelayMaxMs)) \
        decodeFeed=ordered-vt-decode-metal-direct \
        socketMetricClock=local-socket-arrival \
        socketToDecodeFeedSamples=\(lanInboundSocketToDecodeFeedSamples) \
        socketToDecodeFeedMaxMs=\(String(format: "%.2f", lanInboundSocketToDecodeFeedMaxMs)) \
        socketToApplyEndSamples=\(lanInboundSocketToApplyEndSamples) \
        socketToApplyEndMaxMs=\(String(format: "%.2f", lanInboundSocketToApplyEndMaxMs)) \
        decodeAttempted=\(lanInboundDecodeFeedAttemptedInWindow) \
        decodeAccepted=\(lanInboundDecodeFeedAcceptedInWindow) \
        decodeDropped=\(lanInboundDecodeFeedDroppedInWindow) \
        decodePendingMax=\(lanInboundDecodePendingFramesMax) \
        decodeInFlightMax=\(lanInboundDecodeInFlightMax) \
        decodeWaitingSyncSamples=\(lanInboundDecodeWaitingSyncSamples) \
        decodeResets=\(lanInboundDecodeResetCountInWindow) \
        readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget rxFrameClock=socket-arrival
        """
        SkyBridgeLogger.shared.debug("📈 \(telemetryLine)")
        SkyBridgeSmokeTraceWriter.appendStatus(telemetryLine)
        lanInboundTelemetryWindowStartedAt = now
        lanInboundScreenFramesInWindow = 0
        lanInboundScreenBytesInWindow = 0
        lanInboundChunkedScreenFramesInWindow = 0
        lanInboundScreenChunksInWindow = 0
        lanInboundScreenWireFormat = "length-framed"
        lanInboundReceiveParserMode = "mainactor-bootstrap"
        lanInboundMainHopSamples = 0
        lanInboundMainHopTotalMs = 0
        lanInboundMainHopMaxMs = 0
        lanInboundRawChunkGapMaxMs = 0
        lanInboundRawChunkMainHopMaxMs = 0
        lanInboundRawChunksInWindow = 0
        lanInboundParseQueueDelayMaxMs = 0
        lanInboundParserActorHopMaxMs = 0
        lanInboundParserDrainMaxMs = 0
        lanInboundParserStageMaxName = "none"
        lanInboundParserStageMaxMs = 0
        lanInboundParserStagePayloadBytesMax = 0
        lanInboundParserStageReceiveBufferBytesMax = 0
        lanInboundParserBudgetHitsInWindow = 0
        lanInboundPayloadsPerDrainMax = 0
        lanInboundCompleteFramesPerDrainMax = 0
        lanInboundBootstrapParserDrainMaxMs = 0
        lanInboundBootstrapParserBudgetHitsInWindow = 0
        lanInboundApplyQueueDelayMaxMs = 0
        lanInboundScreenApplyMaxMs = 0
        lanInboundInterFrameGapMaxMs = 0
        lanInboundSourceGapMaxMs = 0
        lanInboundSourceToReadSamples = 0
        lanInboundSourceToReadTotalMs = 0
        lanInboundSourceToReadMaxMs = 0
        lanInboundScreenDeliveryAttemptedInWindow = 0
        lanInboundScreenDeliveryBackpressureInWindow = 0
        lanInboundScreenDeliveryQueueDepthMax = 0
        lanInboundScreenDeliveryDelayMaxMs = 0
        lanInboundScreenDeliveryDeliveredInWindow = 0
        lanInboundSocketToDecodeFeedSamples = 0
        lanInboundSocketToDecodeFeedMaxMs = 0
        lanInboundSocketToApplyEndSamples = 0
        lanInboundSocketToApplyEndMaxMs = 0
        lanInboundDecodeFeedAttemptedInWindow = 0
        lanInboundDecodeFeedAcceptedInWindow = 0
        lanInboundDecodeFeedDroppedInWindow = 0
        lanInboundDecodePendingFramesMax = 0
        lanInboundDecodeInFlightMax = 0
        lanInboundDecodeWaitingSyncSamples = 0
        lanInboundDecodeResetCountInWindow = 0
    }

    private func noteDecodedFrame(at now: Date) {
        lastDecodedFrameTime = now
        lastDecodeQueueProgressAt = now
        decodedFramesInStatsWindow += 1
        logRemoteDesktopPipelineStatsIfNeeded(at: now)
    }

    private func noteVideoRendererEnqueuedFrame(at now: Date) {
        lastVideoRendererEnqueueAt = now
        rendererEnqueuedFramesInStatsWindow += 1
        if renderPipelineStatus == .sampleBufferDisplayLayer {
            consecutiveSampleBufferNoEnqueueWindows = 0
            consecutiveSampleBufferDisplayStalls = 0
        }
        noteFrameProgress(at: now)
    }

    private func noteMetalRendererEnqueuedFrame(at now: Date) {
        lastVideoRendererEnqueueAt = now
        rendererEnqueuedFramesInStatsWindow += 1
        logRemoteDesktopPipelineStatsIfNeeded(at: now)
    }

    private func noteDisplayedFrame(at now: Date) {
        noteDisplayedFrames(count: 1, at: now)
    }

    private func noteDisplayedFrames(count: Int, at now: Date) {
        let frameDelta = max(1, count)
        lastDisplayedFrameTime = now
        displayedFrameCountInCurrentStream += frameDelta
        displayedFrameTimesInCurrentStream.append(contentsOf: Array(repeating: now, count: frameDelta))
        trimSmokeFrameTimes(&displayedFrameTimesInCurrentStream, at: now)
        displayedFramesInStatsWindow += frameDelta
        logRemoteDesktopPipelineStatsIfNeeded(at: now)
        noteFrameProgress(at: now, frames: frameDelta)
    }

    private func logRemoteDesktopPipelineStatsIfNeeded(at now: Date) {
        guard state == .streaming else { return }
        guard let statsWindowStartTime else {
            self.statsWindowStartTime = now
            return
        }
        let elapsed = now.timeIntervalSince(statsWindowStartTime)
        guard elapsed >= 1.0 else { return }
        if decodeQueueWaitingForSyncFrame,
           lastRequestedStreamRefreshToken != nil,
           let requestedAt = lastRequestedStreamRefreshAt,
           now.timeIntervalSince(requestedAt) >= 1.0,
           now.timeIntervalSince(lastWaitingSyncDiagnosticLogTime) >= 1.0 {
            lastWaitingSyncDiagnosticLogTime = now
            let waitMs = Int((now.timeIntervalSince(requestedAt) * 1000).rounded())
            let failureSuffix = lastRefreshRequestFailureDescription.map { " refreshErr=\($0)" } ?? ""
            SkyBridgeLogger.shared.warning(
                "⚠️ viewer 关键帧恢复仍在等待: refreshTokenState=present reason=\(lastRequestedStreamRefreshReason ?? "unspecified") waitMs=\(waitMs) recv=\(receivedFramesInStatsWindow) decode=\(decodedFramesInStatsWindow) display=\(displayedFramesInStatsWindow) probable=missing-keyframe transport=\(activeTransportModeLabel()) summary=\(crossNetwork.remoteDesktopRecoveryDebugSummary())\(failureSuffix)"
            )
        }
        if renderPipelineStatus == .sampleBufferDisplayLayer,
           decodedFramesInStatsWindow > 0 {
            if rendererEnqueuedFramesInStatsWindow == 0 {
                consecutiveSampleBufferNoEnqueueWindows += 1
                Task { @MainActor [weak self] in
                    await self?.handleStreamContinuityStall(reason: "sample-buffer-no-enqueue")
                }
            } else {
                consecutiveSampleBufferNoEnqueueWindows = 0
            }
        }
        let videoRenderAgeMs = lastInboundScreenTimestamp.map {
            Int(max(0, now.timeIntervalSince1970 - $0) * 1_000)
        }
        SkyBridgeLogger.shared.debug(
            "📈 远控链路统计: recv=\(receivedFramesInStatsWindow) decode=\(decodedFramesInStatsWindow) enqueue=\(rendererEnqueuedFramesInStatsWindow) display=\(displayedFramesInStatsWindow) pending=\(pendingFrames.count) inflight=\(inFlightDecodeCount) waitingSync=\(decodeQueueWaitingForSyncFrame) pipeline=\(renderPipelineStatus.rawValue) videoRenderAgeMs=\(videoRenderAgeMs.map(String.init) ?? "-")"
        )
        self.statsWindowStartTime = now
        receivedFramesInStatsWindow = 0
        decodedFramesInStatsWindow = 0
        rendererEnqueuedFramesInStatsWindow = 0
        displayedFramesInStatsWindow = 0
    }

    private func shouldAcceptDecodedFrame(presentationTimeStamp: CMTime) -> Bool {
        guard presentationTimeStamp.flags.contains(.valid) else { return true }
        if let lastAcceptedDecodedPresentationTimeStamp,
           lastAcceptedDecodedPresentationTimeStamp.flags.contains(.valid),
           CMTimeCompare(presentationTimeStamp, lastAcceptedDecodedPresentationTimeStamp) <= 0 {
            return false
        }
        lastAcceptedDecodedPresentationTimeStamp = presentationTimeStamp
        return true
    }

    private func completeDecodeTask(for generation: UInt64) {
        guard generation == decodeGeneration else { return }
        inFlightDecodeCount = max(0, inFlightDecodeCount - 1)
        noteLANDecodeQueueWatermark()
    }

    private func maxConcurrentDecodeTasks(for screenData: ScreenData) -> Int {
        RemoteDesktopDecodeQueuePolicy.isPredictiveVideoFormat(screenData.format)
            ? maxConcurrentVideoDecodes
            : 1
    }

    private func activateSampleBufferFallbackForDecodedVideo(reason: String) {
        guard !remoteDesktopRenderFallbackForbidden else {
            SkyBridgeLogger.shared.error(
                "⛔️ 远控渲染主路径失败，已拒绝 AVSampleBufferDisplayLayer fallback: reason=\(reason)"
            )
            SkyBridgeSmokeTraceWriter.appendStatus(
                "render-main-path-failed session=\(crossNetwork.activeRemoteDesktopSessionId ?? "-") reason=\(reason) attemptedFallback=sampleBufferDisplayLayer fallbackResult=forbidden"
            )
            Task { @MainActor [weak self] in
                await self?.failFastRemoteDesktopRenderMainPath(
                    reason: reason,
                    attemptedFallback: "sampleBufferDisplayLayer"
                )
            }
            return
        }
        guard decodedVideoRendererPreference != .sampleBuffer else { return }
        let now = Date()
        if let lastMetalFallbackAt, now.timeIntervalSince(lastMetalFallbackAt) < 5 {
            metalRestoreFailureCount += 1
        } else {
            metalRestoreFailureCount = 1
        }
        if metalRestoreFailureCount >= metalFallbackPersistentFailureThreshold {
            metalRestoreSuppressedUntil = now.addingTimeInterval(metalFallbackPersistentFailureCooldown)
            let cooldownMs = Int(metalFallbackPersistentFailureCooldown * 1000)
            SkyBridgeLogger.shared.warning(
                "⚠️ Metal restore repeated failures suppressed: reason=\(reason) failures=\(metalRestoreFailureCount) cooldownMs=\(cooldownMs)"
            )
        }
        decodedVideoRendererPreference = .sampleBuffer
        metalAwaitingFirstDisplaySince = nil
        lastMetalFallbackAt = now
        metalFallbackReason = reason
        stableSampleBufferFramesSinceMetalFallback = 0
        consecutiveSampleBufferNoEnqueueWindows = 0
        consecutiveSampleBufferDisplayStalls = 0
        flushMetalVideoFrameFeed(removeDisplayedImage: false)
        if currentFrame == nil, let lastGoodFrozenFrame {
            currentFrame = lastGoodFrozenFrame
        }
        updateRenderPipeline(.sampleBufferDisplayLayer)
        SkyBridgeLogger.shared.warning(
            "⚠️ Metal 渲染未消费新帧，已立即回退到 AVSampleBufferDisplayLayer: reason=\(reason) restoreProbeMs=\(Int(metalFallbackRestoreCooldown * 1000)) expectedRestoreMs=\(Int(metalFallbackExpectedRestoreWindow * 1000)) failures=\(metalRestoreFailureCount)"
        )
    }

    private func activateCGImageFallbackForDecodedVideo() {
        guard !remoteDesktopRenderFallbackForbidden else {
            SkyBridgeLogger.shared.error("⛔️ 远控渲染主路径失败，已拒绝 CGImage fallback")
            SkyBridgeSmokeTraceWriter.appendStatus(
                "render-main-path-failed session=\(crossNetwork.activeRemoteDesktopSessionId ?? "-") reason=cgimage-fallback-forbidden attemptedFallback=stillImageFallback fallbackResult=forbidden"
            )
            Task { @MainActor [weak self] in
                await self?.failFastRemoteDesktopRenderMainPath(
                    reason: "cgimage-fallback-forbidden",
                    attemptedFallback: "stillImageFallback"
                )
            }
            return
        }
        guard decodedVideoRendererPreference != .cgImage else { return }
        decodedVideoRendererPreference = .cgImage
        metalAwaitingFirstDisplaySince = nil
        lastMetalFallbackAt = nil
        metalFallbackReason = nil
        stableSampleBufferFramesSinceMetalFallback = 0
        consecutiveSampleBufferNoEnqueueWindows = 0
        consecutiveSampleBufferDisplayStalls = 0
        flushRenderedVideoFeeds(removeDisplayedImage: true)
        if let lastGoodFrozenFrame {
            currentFrame = lastGoodFrozenFrame
        }
        updateRenderPipeline(.stillImageFallback)
        SkyBridgeLogger.shared.warning("⚠️ 视频渲染层未消费新帧，已回退到逐帧 CGImage 渲染")
    }

    private func maybeRestoreMetalRendererAfterStableSampleBuffer(at now: Date) async {
        guard preferredDecodedVideoRenderer() == .metal else { return }
        guard decodedVideoRendererPreference == .sampleBuffer else { return }
        guard renderPipelineStatus == .sampleBufferDisplayLayer else { return }
        guard RemoteDesktopDecodeQueuePolicy.isPredictiveVideoFormat(lastIncomingStreamSignature?.format) else {
            return
        }
        guard let lastMetalFallbackAt else { return }
        guard now.timeIntervalSince(lastMetalFallbackAt) >= metalFallbackRestoreCooldown else { return }
        if let suppressedUntil = metalRestoreSuppressedUntil,
           now < suppressedUntil {
            let cooldownMs = Int(suppressedUntil.timeIntervalSince(now) * 1000)
            SkyBridgeLogger.shared.debug(
                "Metal restore probe suppressed: reason=\(metalFallbackReason ?? "unknown") cooldownMs=\(cooldownMs)"
            )
            return
        }

        stableSampleBufferFramesSinceMetalFallback += 1
        guard stableSampleBufferFramesSinceMetalFallback >= metalFallbackStableFrameRestoreThreshold else { return }

        decodedVideoRendererPreference = .metal
        stableSampleBufferFramesSinceMetalFallback = 0
        self.lastMetalFallbackAt = nil
        metalAwaitingFirstDisplaySince = nil
        let restoreReason = metalFallbackReason ?? "unknown"
        metalFallbackReason = nil
        await requestStreamRefreshIfNeeded(
            reason: "sample-buffer-stable-restore-metal",
            minimumInterval: metalFallbackRestoreCooldown
        )
        SkyBridgeLogger.shared.info(
            "♻️ AVSampleBufferDisplayLayer 已稳定，准备恢复 Metal Renderer: transport=\(activeTransportModeLabel()) reason=\(restoreReason) elapsedMs=\(Int(now.timeIntervalSince(lastMetalFallbackAt) * 1000)) expectedMs=\(Int(metalFallbackExpectedRestoreWindow * 1000)) cooldownMs=\(Int(metalFallbackRestoreCooldown * 1000)) stableFrames=\(metalFallbackStableFrameRestoreThreshold)"
        )
    }

    private func makeCGImage(from pixelBufferFrame: DecodedPixelBufferFrame) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBufferFrame.pixelBuffer)
        let rect = CGRect(x: 0, y: 0, width: pixelBufferFrame.width, height: pixelBufferFrame.height)
        return fallbackImageContext.createCGImage(image, from: rect)
    }

    private func zeroMeasuredFrameRate(at now: Date) {
        guard frameRate != 0 || frameCount != 0 else { return }
        frameRate = 0
        frameCount = 0
        lastFrameTime = now
    }

    private var remoteDesktopRenderFallbackForbidden: Bool {
        switch lastSentStreamConfiguration?.mediaFallbackPolicy?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "fail-fast", "forbidden":
            return true
        default:
            return false
        }
    }

    private func failFastRemoteDesktopRenderMainPath(
        reason: String,
        attemptedFallback: String,
        at now: Date = Date(),
        forceSyncFrameWait: Bool = false
    ) async {
        let failureContext = renderMainPathFailureContext(
            reason: reason,
            attemptedFallback: attemptedFallback,
            at: now
        )
        lastContinuityRecoveryAt = now
        metalAwaitingFirstDisplaySince = nil
        zeroMeasuredFrameRate(at: now)
        invalidateDecodePipelineState()
        flushRenderedVideoFeeds(removeDisplayedImage: false)
        pendingFrames.removeAll(keepingCapacity: true)
        decodeQueueWaitingForSyncFrame = forceSyncFrameWait
            || RemoteDesktopDecodeQueuePolicy.isPredictiveVideoFormat(lastIncomingStreamSignature?.format)
        await decoder.resetPreservingLastFrame()
        lastDecoderResetTime = now
        consecutiveDecodeMisses = 0
        lastRequestedStreamRefreshReason = "render-main-path-fail-fast"
        SkyBridgeLogger.shared.error(
            "⛔️ 远控渲染主路径失败，fail-fast 保留传输并请求同步帧: \(failureContext)"
        )
        SkyBridgeSmokeTraceWriter.appendStatus(
            "render-main-path-failed \(failureContext)"
        )
        SkyBridgeSmokeTraceWriter.appendStatus(
            "failed stage=remote-desktop phase=render_main_path detail=\"\(reason)\" attemptedFallback=\(attemptedFallback) fallbackResult=forbidden transportAction=preserve audioAction=preserve"
        )
        await requestStreamRefreshIfNeeded(
            reason: "render-main-path-fail-fast-\(reason)",
            minimumInterval: 0.25
        )
    }

    private func renderMainPathFailureContext(
        reason: String,
        attemptedFallback: String,
        at now: Date
    ) -> String {
        let metalDisplaySnapshot = metalDisplayContinuitySnapshot(at: now)
        let rates = continuityWindowRates(at: now, metalDisplaySnapshot: metalDisplaySnapshot)
        let arrivalAgeMs = lastFrameArrivalAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
        let displayAgeMs = lastDisplayedFrameTime.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
        let metalDisplayAgeMs = metalDisplaySnapshot.lastDisplayedFrameTime.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
        let decodedAgeMs = lastDecodedFrameTime.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
        let enqueueAgeMs = lastVideoRendererEnqueueAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
        let inputFailureThresholdFPS = metalContinuityInputFailureThresholdFPS()
        let audioSession = realtimeMediaAudioReceiverSessionId ?? "-"
        let audioEndpoint = realtimeMediaAudioEndpoint.map { "\($0.host):\($0.port)" } ?? "-"
        return
            "session=\(crossNetwork.activeRemoteDesktopSessionId ?? "-") " +
            "device=\(currentConnection?.device.id ?? "-") transport=\(activeTransportModeLabel()) " +
            "reason=\(reason) attemptedFallback=\(attemptedFallback) fallbackResult=forbidden " +
            "inputFPS=\(String(format: "%.1f", rates.inputFPS)) displayFPS=\(String(format: "%.1f", rates.displayFPS)) " +
            "inputFailureThresholdFPS=\(String(format: "%.1f", inputFailureThresholdFPS)) " +
            "decodedWindow=\(decodedFramesInStatsWindow) enqueuedWindow=\(rendererEnqueuedFramesInStatsWindow) " +
            "displayedWindow=\(displayedFramesInStatsWindow) displayedTotal=\(displayedFrameCountInCurrentStream) " +
            "metalDisplayedWindow=\(metalDisplaySnapshot.displayedFramesInWindow) " +
            "metalDisplayedTotal=\(metalDisplaySnapshot.displayedFramesInStream) " +
            "metalDisplayAgeMs=\(metalDisplayAgeMs) metalFrameAgeMaxMs=\(metalDisplaySnapshot.frameAgeMaxInWindowMs ?? -1) " +
            "arrivalAgeMs=\(arrivalAgeMs) displayAgeMs=\(displayAgeMs) decodedAgeMs=\(decodedAgeMs) enqueueAgeMs=\(enqueueAgeMs) " +
            "transportAction=preserve audioAction=preserve audioSession=\(audioSession) audioEndpoint=\(audioEndpoint)"
    }

    private func startStreamContinuityWatchdog(for epoch: UInt64) {
        streamContinuityWatchdogTask?.cancel()
        streamContinuityWatchdogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                guard self.streamEpoch == epoch else { return }
                guard self.state == .streaming else { continue }
                let now = Date()
                let metalDisplaySnapshot = self.metalDisplayContinuitySnapshot(at: now)
                let effectiveLastDisplayedFrameTime = self.newerDisplayTime(
                    self.lastDisplayedFrameTime,
                    metalDisplaySnapshot.lastDisplayedFrameTime
                )
                let lastProgressAt = effectiveLastDisplayedFrameTime
                    ?? self.lastVideoRendererEnqueueAt
                    ?? self.lastRenderedFrameTime
                    ?? self.lastFrameArrivalAt
                if let lastProgressAt,
                   now.timeIntervalSince(lastProgressAt) >= 1.0 {
                    self.zeroMeasuredFrameRate(at: now)
                }
                // 修复：增加 Metal 首帧超时阈值到 2.5 秒，给 MTKView 更多时间完成首帧渲染
                // 原代码 1.0 秒在设备热启动或 GPU 繁忙时过于激进
                if self.renderPipelineStatus == .metalRenderer,
                   effectiveLastDisplayedFrameTime == nil,
                   let firstAwaitingDisplayAt = self.metalAwaitingFirstDisplaySince,
                   now.timeIntervalSince(firstAwaitingDisplayAt) >= 2.5 {
                    await self.handleStreamContinuityStall(reason: "metal-first-display-timeout")
                    continue
                }
                if let lastFrameArrivalAt = self.lastFrameArrivalAt,
                   let effectiveLastDisplayedFrameTime,
                   lastFrameArrivalAt > effectiveLastDisplayedFrameTime,
                   now.timeIntervalSince(effectiveLastDisplayedFrameTime) >= 1.0 {
                    await self.handleStreamContinuityStall(reason: "frames-arriving-without-display")
                    continue
                }
                if self.renderPipelineStatus == .metalRenderer,
                   let lastDecodedFrameTime = self.lastDecodedFrameTime,
                   let effectiveLastDisplayedFrameTime,
                   lastDecodedFrameTime > effectiveLastDisplayedFrameTime,
                   now.timeIntervalSince(effectiveLastDisplayedFrameTime) >= 1.0 {
                    await self.handleStreamContinuityStall(reason: "frames-decoding-without-display")
                    continue
                }
                if let lastFrameArrivalAt = self.lastFrameArrivalAt,
                   let lastDecodedFrameTime = self.lastDecodedFrameTime,
                   lastFrameArrivalAt > lastDecodedFrameTime,
                   now.timeIntervalSince(lastDecodedFrameTime) >= 1.0 {
                    await self.handleStreamContinuityStall(reason: "frames-arriving-without-decode")
                }
            }
        }
    }

    private func scheduleFirstFrameContinuityCheck(for epoch: UInt64, firstFrameAt: Date) {
        firstFrameContinuityTask?.cancel()
        firstFrameContinuityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(1.2))
            } catch {
                return
            }
            guard self.streamEpoch == epoch else { return }
            guard self.state == .streaming else { return }
            guard self.receivedFrameCountInCurrentStream <= 1 else { return }
            guard self.lastFrameArrivalAt == firstFrameAt else { return }
            await self.handleStreamContinuityStall(reason: "first-frame-only-freeze")
        }
    }

    private func noteViewerInteraction(kind: String) {
        let interactionAt = Date()
        lastViewerInteractionAt = interactionAt
        let epoch = streamEpoch
        interactionContinuityTask?.cancel()
        interactionContinuityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }
            guard self.streamEpoch == epoch else { return }
            guard self.state == .streaming else { return }
            guard self.hasReceivedFrameInCurrentStream else { return }
            guard let lastFrameArrivalAt = self.lastFrameArrivalAt,
                  lastFrameArrivalAt <= interactionAt else { return }
            await self.handleStreamContinuityStall(reason: "post-\(kind)-no-frame")
        }
    }

    private func shouldEscalateSampleBufferStall(reason: String) -> Bool {
        switch reason {
        case "sample-buffer-no-enqueue":
            return consecutiveSampleBufferNoEnqueueWindows >= sampleBufferNoEnqueueWindowThreshold
        case "frames-arriving-without-display", "frames-decoding-without-display":
            consecutiveSampleBufferDisplayStalls += 1
            return consecutiveSampleBufferDisplayStalls >= sampleBufferDisplayStallRecoveryThreshold
        default:
            return false
        }
    }

    private func recoverSampleBufferPipeline(reason: String, at now: Date) async {
        lastContinuityRecoveryAt = now
        metalAwaitingFirstDisplaySince = nil
        zeroMeasuredFrameRate(at: now)
        invalidateDecodePipelineState()
        flushRenderedVideoFeeds(removeDisplayedImage: false)
        pendingFrames.removeAll(keepingCapacity: true)
        decodeQueueWaitingForSyncFrame = RemoteDesktopDecodeQueuePolicy.isPredictiveVideoFormat(
            lastIncomingStreamSignature?.format
        )
        await decoder.resetPreservingLastFrame()
        lastDecoderResetTime = now
        consecutiveDecodeMisses = 0
        await requestStreamRefreshIfNeeded(reason: reason, minimumInterval: 0.25)
        SkyBridgeLogger.shared.warning(
            "⚠️ AVSampleBufferDisplayLayer 连续性异常: \(reason)，已刷新解码管线并暂缓静态帧降级"
        )
    }

    private func continuityWindowRates(
        at now: Date,
        metalDisplaySnapshot: MetalDisplayCadenceSnapshot? = nil
    ) -> (inputFPS: Double, displayFPS: Double) {
        guard let statsWindowStartTime else { return (0, 0) }
        let elapsed = max(0.001, now.timeIntervalSince(statsWindowStartTime))
        let displayedFrames = max(
            displayedFramesInStatsWindow,
            metalDisplaySnapshot?.displayedFramesInWindow ?? 0
        )
        return (
            Double(receivedFramesInStatsWindow) / elapsed,
            Double(displayedFrames) / elapsed
        )
    }

    private func metalContinuityInputFailureThresholdFPS() -> Double {
        let targetFrameRate = Double(max(
            1,
            lastSentStreamConfiguration?.targetFrameRate ?? viewerSettings.targetFrameRate
        ))
        return max(20.0, targetFrameRate - 3.0)
    }

    private func metalDisplayContinuitySnapshot(at now: Date) -> MetalDisplayCadenceSnapshot {
        metalDisplaySmokeCadence.snapshot(
            at: now,
            windowSeconds: Self.smokeRollingFrameWindowSeconds
        )
    }

    private func newerDisplayTime(_ lhs: Date?, _ rhs: Date?) -> Date? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return rhs > lhs ? rhs : lhs
    }

    private func logDeferredMetalContinuityStall(
        reason: String,
        classification: String,
        at now: Date
    ) {
        lastDeferredMetalContinuityStallClassification = classification
        let metalDisplaySnapshot = metalDisplayContinuitySnapshot(at: now)
        let rates = continuityWindowRates(at: now, metalDisplaySnapshot: metalDisplaySnapshot)
        let arrivalAgeMs = lastFrameArrivalAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
        let displayAgeMs = lastDisplayedFrameTime.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
        let metalDisplayAgeMs = metalDisplaySnapshot.lastDisplayedFrameTime.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
        let decodedAgeMs = lastDecodedFrameTime.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
        let enqueueAgeMs = lastVideoRendererEnqueueAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
        let presentationOwners = activePresentationOwnerTokens.count
        let metalConsumers = metalVideoFrameFeed.activeConsumerCount
        let inputFailureThresholdFPS = metalContinuityInputFailureThresholdFPS()
        let message =
            "render-continuity-deferred session=\(crossNetwork.activeRemoteDesktopSessionId ?? "-") " +
            "reason=\(reason) classification=\(classification) " +
            "inputFPS=\(String(format: "%.1f", rates.inputFPS)) displayFPS=\(String(format: "%.1f", rates.displayFPS)) " +
            "inputFailureThresholdFPS=\(String(format: "%.1f", inputFailureThresholdFPS)) " +
            "decodedWindow=\(decodedFramesInStatsWindow) enqueuedWindow=\(rendererEnqueuedFramesInStatsWindow) " +
            "displayedWindow=\(displayedFramesInStatsWindow) displayedTotal=\(displayedFrameCountInCurrentStream) " +
            "metalDisplayedWindow=\(metalDisplaySnapshot.displayedFramesInWindow) " +
            "metalDisplayedTotal=\(metalDisplaySnapshot.displayedFramesInStream) " +
            "metalDisplayAgeMs=\(metalDisplayAgeMs) metalFrameAgeMaxMs=\(metalDisplaySnapshot.frameAgeMaxInWindowMs ?? -1) " +
            "arrivalAgeMs=\(arrivalAgeMs) displayAgeMs=\(displayAgeMs) decodedAgeMs=\(decodedAgeMs) enqueueAgeMs=\(enqueueAgeMs) " +
            "presentationOwners=\(presentationOwners) metalConsumers=\(metalConsumers) " +
            "attemptedFallback=none fallbackResult=not-attempted"
        SkyBridgeLogger.shared.info("ℹ️ \(message)")
        SkyBridgeSmokeTraceWriter.appendStatus(message)
    }

    private func shouldRequestStreamRefreshForDeferredMetalContinuityStall(
        classification: String?
    ) -> Bool {
        switch classification {
        case "decoded-without-renderer-enqueue",
             "arrived-without-renderer-enqueue",
             "startup-no-renderer-enqueue",
             "no-renderer-input-evidence":
            return true
        case "display-progress-present",
             "post-first-display-not-renderer-failure",
             "input-cadence-below-display-failure-threshold",
             "startup-input-cadence-below-display-failure-threshold",
             "input-cadence-window-reset-below-display-failure-threshold",
             "startup-input-cadence-window-reset-below-display-failure-threshold",
             "display-total-progress-present",
             "remote-view-not-presented",
             "metal-consumer-not-active",
             "display-stale-window-not-expired",
             "startup-renderer-input-not-stale":
            return false
        default:
            return false
        }
    }

    private func shouldFailFastMetalContinuityStall(reason: String, at now: Date) -> Bool {
        lastDeferredMetalContinuityStallClassification = nil

        let metalDisplaySnapshot = metalDisplayContinuitySnapshot(at: now)
        let rates = continuityWindowRates(at: now, metalDisplaySnapshot: metalDisplaySnapshot)

        let result = RemoteDesktopMetalContinuityStallPolicy.evaluate(
            RemoteDesktopMetalContinuityStallPolicyInput(
                reason: reason,
                isMetalRenderer: renderPipelineStatus == .metalRenderer,
                hasPresentationOwner: !activePresentationOwnerTokens.isEmpty,
                activeMetalConsumerCount: metalVideoFrameFeed.activeConsumerCount,
                displayedFramesInStatsWindow: displayedFramesInStatsWindow,
                displayedFramesInCurrentStream: displayedFrameCountInCurrentStream,
                observedDisplayedFramesWatermark: lastMetalContinuityFailFastDisplayedTotal,
                metalDisplayedFramesInWindow: metalDisplaySnapshot.displayedFramesInWindow,
                metalDisplayedFramesInStream: metalDisplaySnapshot.displayedFramesInStream,
                observedMetalDisplayedFramesWatermark: lastMetalContinuityFailFastSmokeDisplayedTotal,
                displayedAgeSeconds: lastDisplayedFrameTime.map { now.timeIntervalSince($0) },
                metalDisplayedAgeSeconds: metalDisplaySnapshot.lastDisplayedFrameTime.map { now.timeIntervalSince($0) },
                arrivalAgeSeconds: lastFrameArrivalAt.map { now.timeIntervalSince($0) },
                decodedAgeSeconds: lastDecodedFrameTime.map { now.timeIntervalSince($0) },
                enqueueAgeSeconds: lastVideoRendererEnqueueAt.map { now.timeIntervalSince($0) },
                decodedFramesInStatsWindow: decodedFramesInStatsWindow,
                rendererEnqueuedFramesInStatsWindow: rendererEnqueuedFramesInStatsWindow,
                inputFPS: rates.inputFPS,
                inputFailureThresholdFPS: metalContinuityInputFailureThresholdFPS()
            )
        )
        lastMetalContinuityFailFastDisplayedTotal = result.observedDisplayedFramesWatermark
        lastMetalContinuityFailFastSmokeDisplayedTotal = result.observedMetalDisplayedFramesWatermark

        switch result.decision {
        case .failFast:
            return true
        case .deferStall(let classification):
            logDeferredMetalContinuityStall(
                reason: reason,
                classification: classification,
                at: now
            )
            return false
        }
    }

    private func handleStreamContinuityStall(reason: String) async {
        let now = Date()
        if let lastContinuityRecoveryAt,
           now.timeIntervalSince(lastContinuityRecoveryAt) < 0.75 {
            return
        }
        if (reason == "frames-arriving-without-display"
            || reason == "frames-decoding-without-display"
            || reason == "metal-first-display-timeout"),
           renderPipelineStatus == .metalRenderer {
            guard shouldFailFastMetalContinuityStall(reason: reason, at: now) else {
                lastContinuityRecoveryAt = now
                let classification = lastDeferredMetalContinuityStallClassification ?? "unknown"
                if shouldRequestStreamRefreshForDeferredMetalContinuityStall(
                    classification: classification
                ) {
                    SkyBridgeSmokeTraceWriter.appendStatus(
                        "render-continuity-deferred-action reason=\(reason) classification=\(classification) attemptedFallback=none fallbackResult=not-attempted streamRefresh=requested"
                    )
                    await requestStreamRefreshIfNeeded(
                        reason: "metal-continuity-deferred-\(reason)",
                        minimumInterval: 0.25
                    )
                } else {
                    SkyBridgeSmokeTraceWriter.appendStatus(
                        "render-continuity-deferred-action reason=\(reason) classification=\(classification) attemptedFallback=none fallbackResult=not-attempted streamRefresh=suppressed"
                    )
                }
                return
            }
            if remoteDesktopRenderFallbackForbidden {
                await failFastRemoteDesktopRenderMainPath(
                    reason: reason,
                    attemptedFallback: "sampleBufferDisplayLayer",
                    at: now
                )
                return
            }
            lastContinuityRecoveryAt = now
            zeroMeasuredFrameRate(at: now)
            activateSampleBufferFallbackForDecodedVideo(reason: reason)
            return
        }
        if (reason == "frames-arriving-without-display"
            || reason == "frames-decoding-without-display"
            || reason == "sample-buffer-no-enqueue"),
           renderPipelineStatus == .sampleBufferDisplayLayer {
            if shouldEscalateSampleBufferStall(reason: reason) {
                if remoteDesktopRenderFallbackForbidden {
                    await failFastRemoteDesktopRenderMainPath(
                        reason: reason,
                        attemptedFallback: "stillImageFallback",
                        at: now
                    )
                    return
                }
                lastContinuityRecoveryAt = now
                zeroMeasuredFrameRate(at: now)
                activateCGImageFallbackForDecodedVideo()
                return
            }
            await recoverSampleBufferPipeline(reason: reason, at: now)
            return
        }
        lastContinuityRecoveryAt = now
        metalAwaitingFirstDisplaySince = nil
        zeroMeasuredFrameRate(at: now)
        if renderPipelineStatus == .sampleBufferDisplayLayer || renderPipelineStatus == .metalRenderer {
            invalidateDecodePipelineState()
            flushRenderedVideoFeeds(removeDisplayedImage: false)
            pendingFrames.removeAll(keepingCapacity: true)
            decodeQueueWaitingForSyncFrame = RemoteDesktopDecodeQueuePolicy.isPredictiveVideoFormat(
                lastIncomingStreamSignature?.format
            )
            await decoder.resetPreservingLastFrame()
            lastDecoderResetTime = now
            consecutiveDecodeMisses = 0
        }
        let format = lastIncomingStreamSignature?.format ?? ""
        let governanceEvent = codecGovernance.noteDecodeFailure(
            format: format,
            reason: reason,
            at: now
        )
        let governanceHandled = await handleCodecGovernanceEvent(governanceEvent, at: now)
        guard !governanceHandled else { return }
        await requestStreamRefreshIfNeeded(reason: reason, minimumInterval: 0.25)
        SkyBridgeLogger.shared.warning("⚠️ 检测到远控视频连续性异常: \(reason)，已请求关键帧刷新")
    }

    func handleVideoRendererDidEnqueueFrame(
        presentationTimeStamp _: CMTime,
        remainingQueueDepth _: Int
    ) async {
        let now = Date()
        videoFrameFeed.markDisplayedFrame()
        noteVideoRendererEnqueuedFrame(at: now)
        noteDisplayedFrame(at: now)
        await maybeRestoreMetalRendererAfterStableSampleBuffer(at: now)
    }

    func handleMetalRendererDidDisplayFrames(
        presentationTimeStamp _: CMTime,
        displayedFrameCount: Int,
        completedAt: Date
    ) async {
        metalAwaitingFirstDisplaySince = nil
        lastMetalFallbackAt = nil
        metalFallbackReason = nil
        metalRestoreFailureCount = 0
        metalRestoreSuppressedUntil = nil
        stableSampleBufferFramesSinceMetalFallback = 0
        metalVideoFrameFeed.markDisplayedFrame()
        noteDisplayedFrames(count: displayedFrameCount, at: completedAt)
    }

    nonisolated func recordMetalRendererDisplayedFramesForSmoke(
        displayedFrameCount: Int,
        completedAt: Date,
        frameAgeMs: Int?
    ) {
        metalDisplaySmokeCadence.record(
            displayedFrameCount: displayedFrameCount,
            completedAt: completedAt,
            windowSeconds: RemoteDesktopManagerRuntimeLimits.smokeRollingFrameWindowSeconds,
            frameAgeMs: frameAgeMs
        )
    }

    func handleMetalRendererOrientation(_ orientation: RemoteDesktopRenderOrientation) {
        guard renderOrientationStatus != orientation else { return }
        renderOrientationStatus = orientation
    }

    @MainActor
    private func applyDecodedOutput(
        _ decoded: DecodeOutput,
        sourceFrame: ScreenData,
        format: String,
        decoder: VideoDecoder,
        generation: UInt64,
        now: Date
    ) async -> Bool {
        guard generation == decodeGeneration else { return false }

        switch decoded {
        case .image(let frame):
            guard !remoteDesktopRenderFallbackForbidden else {
                await failFastRemoteDesktopRenderMainPath(
                    reason: "static-image-fallback-forbidden",
                    attemptedFallback: "stillImageFallback",
                    at: now
                )
                return false
            }
            metalAwaitingFirstDisplaySince = nil
            flushRenderedVideoFeeds()
            currentFrame = frame.image
            updateLastGoodFrozenFrame(frame.image)
            updateRenderPipeline(.stillImageFallback)
            noteDecodedFrame(at: now)
            noteDisplayedFrame(at: now)
        case .pixelBuffer(let frame):
            guard shouldAcceptDecodedFrame(presentationTimeStamp: frame.presentationTimeStamp) else {
                return false
            }
            let independentlyDecodableFrame = sourceFrame.isIndependentlyDecodableFrame
            let shouldCacheFrozenFrame = independentlyDecodableFrame && !remoteDesktopRenderFallbackForbidden
            let frozenCandidate = shouldCacheFrozenFrame ? makeCGImage(from: frame) : nil
            if shouldCacheFrozenFrame {
                updateLastGoodFrozenFrame(frozenCandidate)
            }
            if currentFrame != nil {
                currentFrame = nil
            }
            switch decodedVideoRendererPreference {
            case .metal:
                if lastDisplayedFrameTime == nil {
                    metalAwaitingFirstDisplaySince = metalAwaitingFirstDisplaySince ?? now
                } else {
                    metalAwaitingFirstDisplaySince = nil
                }
                if renderPipelineStatus != .metalRenderer {
                    videoFrameFeed.flush(removeDisplayedImage: false)
                }
                guard await enqueueMetalFrameForDisplay(
                    frame,
                    generation: generation,
                    decodedAt: now
                ) else {
                    return false
                }
                updateRenderPipeline(.metalRenderer)
            case .sampleBuffer:
                guard !remoteDesktopRenderFallbackForbidden else {
                    await failFastRemoteDesktopRenderMainPath(
                        reason: "samplebuffer-pixelbuffer-fallback-forbidden",
                        attemptedFallback: "sampleBufferDisplayLayer",
                        at: now
                    )
                    return false
                }
                metalAwaitingFirstDisplaySince = nil
                if let displayFrame = await decoder.makeDisplaySampleBufferFrame(
                    from: frame,
                    format: format
                ) {
                    if renderPipelineStatus != .sampleBufferDisplayLayer {
                        flushMetalVideoFrameFeed(removeDisplayedImage: true)
                    }
                    videoFrameFeed.enqueue(frame: displayFrame)
                    updateRenderPipeline(.sampleBufferDisplayLayer)
                } else {
                    if renderPipelineStatus != .metalRenderer {
                        videoFrameFeed.flush(removeDisplayedImage: false)
                    }
                    guard await enqueueMetalFrameForDisplay(
                        frame,
                        generation: generation,
                        decodedAt: now
                    ) else {
                        return false
                    }
                    updateRenderPipeline(.metalRenderer)
                }
            case .cgImage:
                guard !remoteDesktopRenderFallbackForbidden else {
                    await failFastRemoteDesktopRenderMainPath(
                        reason: "cgimage-pixelbuffer-fallback-forbidden",
                        attemptedFallback: "stillImageFallback",
                        at: now
                    )
                    return false
                }
                metalAwaitingFirstDisplaySince = nil
                if independentlyDecodableFrame,
                   let image = frozenCandidate {
                    flushRenderedVideoFeeds(removeDisplayedImage: true)
                    currentFrame = image
                    updateLastGoodFrozenFrame(image)
                    updateRenderPipeline(.stillImageFallback)
                    noteDisplayedFrame(at: now)
                } else {
                    if let lastGoodFrozenFrame {
                        currentFrame = lastGoodFrozenFrame
                    }
                    updateRenderPipeline(.stillImageFallback)
                }
            }
            noteDecodedFrame(at: now)
        case .sampleBuffer(let frame):
            guard !remoteDesktopRenderFallbackForbidden else {
                await failFastRemoteDesktopRenderMainPath(
                    reason: "samplebuffer-displaylayer-fallback-forbidden",
                    attemptedFallback: "sampleBufferDisplayLayer",
                    at: now
                )
                return false
            }
            guard shouldAcceptDecodedFrame(presentationTimeStamp: frame.presentationTimeStamp) else {
                return false
            }
            if sourceFrame.isIndependentlyDecodableFrame {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer) else {
                    SkyBridgeLogger.shared.error("❌ 解码器输出缺少图像缓冲，已丢弃该 sampleBuffer 帧")
                    return false
                }
                updateLastGoodFrozenFrame(
                    makeCGImage(
                        from: DecodedPixelBufferFrame(
                            pixelBuffer: pixelBuffer,
                            width: frame.width,
                            height: frame.height,
                            presentationTimeStamp: frame.presentationTimeStamp
                        )
                    )
                )
            }
            metalAwaitingFirstDisplaySince = nil
            if currentFrame != nil {
                currentFrame = nil
            }
            if renderPipelineStatus != .sampleBufferDisplayLayer {
                flushMetalVideoFrameFeed(removeDisplayedImage: true)
            }
            videoFrameFeed.enqueue(frame: frame)
            updateRenderPipeline(.sampleBufferDisplayLayer)
            noteDecodedFrame(at: now)
        }

        consecutiveDecodeMisses = 0
        return true
    }

    private func startDecodeLoopIfNeeded() {
        while let next = pendingFrames.first {
            let maxConcurrentDecodeTasks = maxConcurrentDecodeTasks(for: next)
            guard inFlightDecodeCount < maxConcurrentDecodeTasks else { return }
            guard let screenData = RemoteDesktopDecodeQueuePolicy.dequeueNext(from: &pendingFrames) else { return }
            inFlightDecodeCount += 1
            noteLANDecodeQueueWatermark()

            let decoder = self.decoder
            let decodeGeneration = self.decodeGeneration
            let decodeOrder = nextDecodeSubmissionOrder
            nextDecodeSubmissionOrder &+= 1

            scheduleDecodeSubmission(
                screenData,
                decoder: decoder,
                generation: decodeGeneration,
                decodeOrder: decodeOrder
            )
        }
    }

    private func scheduleDecodeSubmission(
        _ screenData: ScreenData,
        decoder: VideoDecoder,
        generation decodeGeneration: UInt64,
        decodeOrder: UInt64
    ) {
        let previousSubmission = decodeSubmissionChain
        let task = Task.detached(priority: .high) { [weak self, previousSubmission, decoder, screenData, decodeGeneration, decodeOrder] in
            await previousSubmission?.value
            guard !Task.isCancelled else { return }
            guard await self?.isDecodeGenerationCurrent(decodeGeneration) == true else { return }

            let format = (screenData.format ?? "").lowercased()
            let isStillImageFrame = decoder.isStillImageFormat(format)
            let submission: VideoDecodeSubmission
            do {
                submission = try await decoder.submit(screenData: screenData)
            } catch {
                await self?.finishDecodeTask(
                    decoded: nil,
                    decodeFailureReason: error.localizedDescription,
                    isStillImageFrame: isStillImageFrame,
                    sourceFrame: screenData,
                    format: format,
                    decoder: decoder,
                    generation: decodeGeneration,
                    decodeOrder: decodeOrder
                )
                return
            }

            switch submission.output {
            case .completed(let decoded):
                await self?.finishDecodeTask(
                    decoded: decoded,
                    decodeFailureReason: submission.failureReason,
                    isStillImageFrame: isStillImageFrame,
                    sourceFrame: screenData,
                    format: format,
                    decoder: decoder,
                    generation: decodeGeneration,
                    decodeOrder: decodeOrder
                )
            case .pending(let handle):
                Task.detached(priority: .high) { [weak self, handle, screenData, format, decoder, decodeGeneration, decodeOrder, isStillImageFrame] in
                    let decoded: DecodeOutput?
                    let decodeFailureReason: String?
                    do {
                        decoded = try await handle.wait()
                        decodeFailureReason = nil
                    } catch {
                        decoded = nil
                        decodeFailureReason = error.localizedDescription
                    }
                    await self?.finishDecodeTask(
                        decoded: decoded,
                        decodeFailureReason: decodeFailureReason,
                        isStillImageFrame: isStillImageFrame,
                        sourceFrame: screenData,
                        format: format,
                        decoder: decoder,
                        generation: decodeGeneration,
                        decodeOrder: decodeOrder
                    )
                }
            }
        }
        decodeSubmissionChain = task
    }

    private func decodeFailureReasonWithFrameSequence(
        _ reason: String?,
        sourceFrame screenData: ScreenData
    ) -> String? {
        var parts: [String] = []
        let normalizedReason = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedReason.isEmpty {
            parts.append(normalizedReason)
        }
        if let sequenceNumber = screenData.sequenceNumber {
            parts.append("frameSeq=\(sequenceNumber)")
        }
        if let lastSync = lastInboundVideoSyncFrameSequence {
            parts.append("lastSyncSeq=\(lastSync)")
        }
        return parts.isEmpty ? reason : parts.joined(separator: " ")
    }

    @MainActor
    private func finishDecodeTask(
        decoded: DecodeOutput?,
        decodeFailureReason: String?,
        isStillImageFrame: Bool,
        sourceFrame screenData: ScreenData,
        format: String,
        decoder: VideoDecoder,
        generation decodeGeneration: UInt64,
        decodeOrder: UInt64
    ) async {
        guard decodeGeneration == self.decodeGeneration else { return }
        pendingDecodeCompletions[decodeOrder] = PendingDecodeCompletion(
            decoded: decoded,
            decodeFailureReason: decodeFailureReason,
            isStillImageFrame: isStillImageFrame,
            sourceFrame: screenData,
            format: format,
            decoder: decoder,
            generation: decodeGeneration
        )
        completeDecodeTask(for: decodeGeneration)
        startDecodeLoopIfNeeded()
        if await resetDecodePipelineIfCompletionGapExceeded(decoder: decoder, at: Date()) {
            return
        }
        await drainDecodeCompletionsIfNeeded()
    }

    @MainActor
    private func resetDecodePipelineIfCompletionGapExceeded(
        decoder: VideoDecoder,
        at now: Date
    ) async -> Bool {
        guard !pendingDecodeCompletions.isEmpty,
              pendingDecodeCompletions[nextDecodeCompletionOrder] == nil else {
            decodeCompletionGapStartedAt = nil
            cancelDecodeCompletionGapWatchdog()
            return false
        }

        let gapStartedAt = decodeCompletionGapStartedAt ?? now
        decodeCompletionGapStartedAt = gapStartedAt
        let gapMs = Int(now.timeIntervalSince(gapStartedAt) * 1_000)
        let backlog = pendingDecodeCompletions.count
        let missingOrder = nextDecodeCompletionOrder
        scheduleDecodeCompletionGapWatchdog(
            decoder: decoder,
            generation: decodeGeneration,
            missingOrder: missingOrder,
            startedAt: gapStartedAt
        )
        guard backlog > RemoteDesktopManagerRuntimeLimits.maxPendingDecodeCompletionBacklog || gapMs >= 500 else {
            return false
        }

        SkyBridgeLogger.shared.warning(
            "⚠️ VT decode callback order gap exceeded bounds: missingOrder=\(missingOrder) backlog=\(backlog) gapMs=\(gapMs) action=reset-and-request-sync"
        )
        SkyBridgeSmokeTraceWriter.appendStatus(
            "decode-completion-gap-reset session=\(crossNetwork.activeRemoteDesktopSessionId ?? "-") missingOrder=\(missingOrder) backlog=\(backlog) gapMs=\(gapMs) action=reset-and-request-sync"
        )
        invalidateDecodePipelineState()
        pendingFrames.removeAll(keepingCapacity: true)
        decodeQueueWaitingForSyncFrame = true
        await decoder.resetPreservingLastFrame()
        await requestStreamRefreshIfNeeded(reason: "decode-completion-gap", minimumInterval: 0.25)
        return true
    }

    @MainActor
    private func scheduleDecodeCompletionGapWatchdog(
        decoder: VideoDecoder,
        generation: UInt64,
        missingOrder: UInt64,
        startedAt: Date
    ) {
        guard decodeCompletionGapWatchdogMissingOrder != missingOrder else { return }
        cancelDecodeCompletionGapWatchdog()
        decodeCompletionGapWatchdogMissingOrder = missingOrder
        decodeCompletionGapWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: RemoteDesktopManagerRuntimeLimits.decodeCompletionGapWatchdogDelay)
            } catch {
                return
            }
            guard let self,
                  self.decodeGeneration == generation,
                  self.nextDecodeCompletionOrder == missingOrder,
                  self.pendingDecodeCompletions[missingOrder] == nil,
                  self.decodeCompletionGapStartedAt == startedAt else {
                return
            }
            _ = await self.resetDecodePipelineIfCompletionGapExceeded(decoder: decoder, at: Date())
        }
    }

    @MainActor
    private func drainDecodeCompletionsIfNeeded() async {
        guard !isDrainingDecodeCompletions else { return }
        isDrainingDecodeCompletions = true
        defer { isDrainingDecodeCompletions = false }

        while let completion = pendingDecodeCompletions.removeValue(forKey: nextDecodeCompletionOrder) {
            nextDecodeCompletionOrder &+= 1
            decodeCompletionGapStartedAt = nil
            cancelDecodeCompletionGapWatchdog()
            await applyDecodeCompletion(completion)
            guard completion.generation == decodeGeneration else {
                pendingDecodeCompletions.removeAll(keepingCapacity: true)
                return
            }
        }
    }

    @MainActor
    private func applyDecodeCompletion(_ completion: PendingDecodeCompletion) async {
        guard completion.generation == decodeGeneration else { return }

        if let decoded = completion.decoded {
            let now = Date()
            let applied = await applyDecodedOutput(
                decoded,
                sourceFrame: completion.sourceFrame,
                format: completion.format,
                decoder: completion.decoder,
                generation: completion.generation,
                now: now
            )
            guard applied else { return }
            let governanceEvent = codecGovernance.noteDecodeSuccess(format: completion.format, at: now)
            _ = await handleCodecGovernanceEvent(governanceEvent, at: now)
            return
        }

        consecutiveDecodeMisses += 1
        let now = Date()
        if let lastRenderedFrameTime,
           now.timeIntervalSince(lastRenderedFrameTime) >= 1.0 {
            frameRate = 0
        }
        if completion.isStillImageFrame {
            consecutiveDecodeMisses = 0
            return
        }
        let sequencedDecodeFailureReason = decodeFailureReasonWithFrameSequence(
            completion.decodeFailureReason,
            sourceFrame: completion.sourceFrame
        )
        let governanceEvent = codecGovernance.noteDecodeFailure(
            format: completion.format,
            reason: sequencedDecodeFailureReason,
            at: now
        )
        let governanceHandled = await handleCodecGovernanceEvent(governanceEvent, at: now)
        if governanceHandled {
            return
        }
        let canResetDecoder = lastDecoderResetTime.map { now.timeIntervalSince($0) >= 1.0 } ?? true
        if consecutiveDecodeMisses >= 6, canResetDecoder {
            invalidateDecodePipelineState()
            pendingFrames.removeAll(keepingCapacity: true)
            decodeQueueWaitingForSyncFrame = RemoteDesktopDecodeQueuePolicy.isPredictiveVideoFormat(completion.format)
            await completion.decoder.resetPreservingLastFrame()
            lastDecoderResetTime = now
            consecutiveDecodeMisses = 0
            await requestStreamRefreshIfNeeded(
                reason: "decode-stall-reset",
                        minimumInterval: self.streamDecodeStallRefreshMinimumInterval
            )
            SkyBridgeLogger.shared.warning("⚠️ 检测到远控视频解码停滞，已自动重置解码器")
        }
    }
}
