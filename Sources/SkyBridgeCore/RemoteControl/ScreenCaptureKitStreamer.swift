import Foundation
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import VideoToolbox
import CoreVideo
import CoreGraphics
import AudioToolbox
import OSLog
#if canImport(AppKit)
import AppKit
#endif

/// 使用 ScreenCaptureKit 捕获屏幕并通过 VideoToolbox 编码为 HEVC/H.264 的数据流
/// - 中文说明：该组件专注于本地屏幕采集与硬件加速编码，外部通过回调接收压缩后的视频帧数据。
final class ScreenCaptureKitStreamer: NSObject, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "SCKStreamer")
    static let lowLatencyHEVC2K60SingleChunkEncodedPayloadBudgetBytes =
        256 * 1024
        - RemoteDesktopScreenFrameWire.screenChunkHeaderByteCount
        - RemoteControlWireLimits.aesGCMCombinedOverheadBytes
        - RemoteDesktopScreenFrameWire.frameHeaderByteCountV2
    private static let sceneCutKeyFrameRefreshCount = 1
    private static let activeTransitionSceneCutMinimumInterval: TimeInterval = 0.50
    private static let displayParameterSceneCutMinimumInterval: TimeInterval = 0.50
    private static let damageSceneCutMinimumInterval: TimeInterval = 0.75
    private var stream: SCStream?
    private var output: StreamOutput?
    private var compressionSession: VTCompressionSession?
    private let compressionSessionLock = NSLock()
    private var codecType: CMVideoCodecType = kCMVideoCodecType_HEVC
    private var width: Int = 1280
    private var height: Int = 720
    private var visibleWidth: Int = 1280
    private var visibleHeight: Int = 720
    private var started = false
    private var configuredFPS: Int = 60
    private var configuredKeyInterval: Int = 60
    private var preferredProfile: EncodingProfile = .auto
    private var preferredQuality: VideoQuality = .high
    private var preferredCompressionLevelPercent: Int = 50
    private var lowLatencyEnabled: Bool = false
    private var jpegMode: Bool = false
    private var jpegFallbackProfile: WebRTCDegradedFallbackJPEGProfile = .emergency
    private var emitsDegradedFallbackJPEGFrames = false
    private var bitstreamFormat: EncodedBitstreamFormat = .native
    private var failFastOnMediaFallbacks = false
    private var captureCursorInVideo = true
    private var captureVideoOutput = true
    private var captureSystemAudio = false
    private var hasEmittedParameterSets = false
    private var hasEmittedFirstEncodedFrameTrace = false
    private var pendingForcedKeyFrames = 0
    private var pendingParameterSetReannounce = false
    private var firstFrameWatchdogGeneration = 0
    private var configuredLowLatencyRateControlEnabled = false
    private var configuredVideoToolboxMaxFrameDelayCount = 0
    private var configuredVideoToolboxMaximumRealTimeFrameRate = 0
    private var configuredVideoToolboxMaximumRealTimeFrameRateStatus: OSStatus = noErr
    private var configuredVideoToolboxAverageBitRate = 0
    private var configuredVideoToolboxDataRateLimitBytesPerSecond = 0
    private var configuredVideoToolboxDataRateBurstLimitBytes = 0
    private var configuredVideoToolboxDataRateBurstWindowMs = 0
    private var capturedDisplayID: CGDirectDisplayID?
    /// 控制端请求采集的显示器（nil = 主屏）。用于显示选择与拓扑变化判断。
    private var requestedDisplayID: CGDirectDisplayID?
    private var capturedDisplayPixelSize: CGSize = .zero
    private let stateLock = NSLock()
    private var lastSampleBufferAt: Date = .distantPast
    private var lastMeaningfulSampleAt: Date = .distantPast
    private var lastEncodedFrameAt: Date = .distantPast
    private var lastDegradedFallbackJPEGAt: Date = .distantPast
    private var lastSceneCutRecoveryAt: Date = .distantPast
    private var latestVideoPixelBuffer: CVPixelBuffer?
    private var latestVideoPixelBufferGeneration: UInt64 = 0
    private var latestVideoPixelBufferCapturedAtNanos: UInt64 = 0
    private var lastReservedSourceFrameGeneration: UInt64 = 0
    private var consecutiveReservedSourceFrameSubmissions = 0
    private var lastVideoEncodeSubmittedAtNanos: UInt64 = 0
    private var lastVideoPresentationTimeStamp: CMTime?
    private var videoCadenceTimer: DispatchSourceTimer?
    private var captureTelemetryWindowStartedAt = Date()
    private var telemetryCapturedSamples = 0
    private var telemetryMeaningfulSamples = 0
    private var telemetryEncodedFrames = 0
    private var telemetryEncodedBytes = 0
    private var telemetryEncodedFrameBytesMax = 0
    private var telemetryEncodedSyncFrameBytesMax = 0
    private var telemetryOversizedEncodedFrames = 0
    private var telemetryOversizedSyncFrames = 0
    private var telemetryEncodeLatenciesMs: [Double] = []
    private var telemetryActualEncodeLatenciesMs: [Double] = []
    private var telemetryEncodeSubmissionDelayMaxMs: Double = 0
    private var telemetryEncodeSubmissionBacklogMax = 0
    private var telemetryEncodeFailures = 0
    private var telemetryCadenceTimerFires = 0
    private var telemetryCadenceSubmittedFrames = 0
    private var telemetryCadenceCatchUpFrames = 0
    private var telemetryCadenceBatchMax = 0
    private var telemetrySourceFrameRepeatMax = 0
    private var telemetrySourceFrameAgeMaxMs: Double = 0
    private var videoEncodeSubmissionBacklog = 0
    private let sampleOutputQueue = DispatchQueue(
        label: "com.skybridge.compass.sck.output",
        qos: .userInteractive
    )
    private let videoCadenceQueue = DispatchQueue(
        label: "com.skybridge.compass.sck.video-cadence",
        qos: .userInteractive
    )
    private static let videoCadenceQueueKey = DispatchSpecificKey<Bool>()
    private let videoEncodeSubmissionQueue = DispatchQueue(
        label: "com.skybridge.compass.sck.video-encode-submit",
        qos: .userInteractive
    )
    private static let videoEncodeSubmissionQueueKey = DispatchSpecificKey<Bool>()
    private let rawFrameOutputQueue = DispatchQueue(
        label: "com.skybridge.compass.sck.raw-output",
        qos: .userInteractive
    )
    private let audioSampleOutputQueue = DispatchQueue(
        label: "com.skybridge.compass.sck.audio-output",
        qos: .utility
    )
    private var compressionCallbackRefcon: UnsafeMutableRawPointer?
    private var screenParametersObserver: NSObjectProtocol?
    private var activeSpaceObserver: NSObjectProtocol?
    private var activeApplicationObserver: NSObjectProtocol?
    private let targetAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 48_000,
        channels: 2,
        interleaved: true
    )!
    private var audioConverter: AVAudioConverter?
    private var audioConverterInputSignature: String?
    private var requestedAudioEncoding: RemoteDesktopAudioChunkPayload.Encoding = .pcmS16LE
    private var compressedAudioConverter: AVAudioConverter?
    private var compressedAudioFormat: AVAudioFormat?
    private var compressedAudioSignature: String?
    private var didLogAudioCompressionFallback = false
    private var didLogStrictMediaFailure = false
    private var audioSequenceNumber: UInt64 = 0

    override init() {
        super.init()
        videoCadenceQueue.setSpecific(key: Self.videoCadenceQueueKey, value: true)
        videoEncodeSubmissionQueue.setSpecific(key: Self.videoEncodeSubmissionQueueKey, value: true)
    }

/// 编码后视频帧的回调
 /// - 参数说明：data 为压缩后比特流；w/h 为视频维度；type 为帧类型（h264/hevc）
    var onEncodedFrame: ((Data, Int, Int, RemoteFrameType, Bool) -> Void)?
    var onRawFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onDamageReport: ((RemoteDesktopDamageReport) -> Void)?
    var onCapturedPCM16AudioChunk: ((RemoteDesktopAudioChunkPayload) -> Void)?
    var onCapturedAudioChunk: ((RemoteDesktopAudioChunkPayload) -> Void)?
    var onCaptureIssue: ((String) -> Void)?
    var onCaptureTelemetry: ((ScreenCaptureTelemetrySnapshot) -> Void)?

 /// 启动采集与编码
    @MainActor
    func start(
        preferredCodec: RemoteFrameType = .hevc,
        preferredSize: CGSize? = nil,
        targetFPS: Int = 60,
        keyFrameInterval: Int = 60,
        captureCursorInVideo: Bool = true,
        captureVideoOutput: Bool = true,
        captureSystemAudio: Bool = false,
        audioEncoding: RemoteDesktopAudioChunkPayload.Encoding = .pcmS16LE,
        degradedFallbackJPEGProfile: WebRTCDegradedFallbackJPEGProfile? = nil,
        failFastOnMediaFallbacks: Bool = false,
        preserveExactVisibleSize: Bool = false,
        lowLatencyMode: Bool? = nil,
        videoCompressionLevelPercent: Int? = nil,
        bitstreamFormat: EncodedBitstreamFormat = .native,
        preferredDisplayID: CGDirectDisplayID? = nil
    ) async throws {
        guard !started else { return }
        started = true
        requestedDisplayID = preferredDisplayID
        configuredFPS = max(1, targetFPS)
        configuredKeyInterval = keyFrameInterval
        self.captureCursorInVideo = captureCursorInVideo
        self.captureVideoOutput = captureVideoOutput
        self.captureSystemAudio = captureSystemAudio
        self.requestedAudioEncoding = audioEncoding
        jpegFallbackProfile = degradedFallbackJPEGProfile ?? .emergency
        emitsDegradedFallbackJPEGFrames = degradedFallbackJPEGProfile != nil && preferredCodec != .bgra
        self.failFastOnMediaFallbacks = failFastOnMediaFallbacks
        self.bitstreamFormat = bitstreamFormat
        hasEmittedParameterSets = false
        hasEmittedFirstEncodedFrameTrace = false
        pendingForcedKeyFrames = 2
        pendingParameterSetReannounce = false
        configuredLowLatencyRateControlEnabled = false
        audioConverter = nil
        audioConverterInputSignature = nil
        compressedAudioConverter = nil
        compressedAudioFormat = nil
        compressedAudioSignature = nil
        clearLatestVideoPixelBuffer()
        didLogAudioCompressionFallback = false
        didLogStrictMediaFailure = false
        audioSequenceNumber = 0
        resetCaptureTelemetry()
// 读取编码档位与低延迟设置（主线程安全）
        let settings = RemoteDesktopSettingsManager.shared.settings
        preferredProfile = settings.displaySettings.encodingProfile
        preferredQuality = settings.displaySettings.videoQuality
        preferredCompressionLevelPercent = videoCompressionLevelPercent
            .map { Self.boundedVideoCompressionLevelPercent($0) }
            ?? settings.displaySettings.boundedCompressionLevelPercent
        lowLatencyEnabled = lowLatencyMode ?? settings.displaySettings.lowLatencyMode

 // 选择显示内容：控制端所选显示器 → 主显示器 → 第一个可用（所选显示器被拔出时安全回退，避免无源）。
        let content = try await SCShareableContent.current
        let mainDisplayID = CGMainDisplayID()
        let display: SCDisplay
        if let requestedDisplayID,
           let chosen = content.displays.first(where: { $0.displayID == requestedDisplayID }) {
            display = chosen
        } else if let main = content.displays.first(where: { $0.displayID == mainDisplayID }) {
            display = main
        } else if let first = content.displays.first {
            display = first
        } else {
            logger.error("ScreenCaptureKit 无可用显示设备")
            throw CocoaError(.fileNoSuchFile)
        }
        capturedDisplayID = display.displayID
        capturedDisplayPixelSize = displayPixelSize(
            for: display.displayID,
            fallback: CGSize(width: display.width, height: display.height)
        )
        let requestedSize = CGSize(
            width: preferredSize?.width ?? CGFloat(display.width),
            height: preferredSize?.height ?? CGFloat(display.height)
        )

        // iOS 端为简化解码：允许用 BGRA 模式输出 JPEG（避免 H.264/HEVC NAL 兼容问题）
        jpegMode = (preferredCodec == .bgra)
        let captureSize = jpegMode
            ? jpegFallbackProfile.constrainedSize(for: requestedSize)
            : requestedSize
        let visibleSize = RemoteControlCaptureCompatibility.normalizedCaptureSize(
            captureSize,
            for: preferredCodec,
            preserveExactVisibleSize: preserveExactVisibleSize
        )
        let encodedBackingSize = RemoteControlCaptureCompatibility.encodedBackingCaptureSize(
            visibleSize,
            for: preferredCodec,
            preserveExactVisibleSize: preserveExactVisibleSize
        )
        visibleWidth = Int(visibleSize.width)
        visibleHeight = Int(visibleSize.height)
        // 发布鼠标注入坐标映射的单一真相：控制端坐标位于「可见帧像素空间」(visibleWidth×visibleHeight)，
        // 注入侧据此 + 实际采集显示器的 CGDisplayBounds 还原为全局点坐标（含非主屏原点偏移）。
        // 仅视频采集流参与；音频专用流 (captureVideoOutput == false) 不发布，避免覆盖视频流映射。
        if captureVideoOutput {
            RemoteControlInjectionMappingStore.publish(
                RemoteControlInjectionMapping(
                    displayID: display.displayID,
                    visibleSize: CGSize(width: visibleWidth, height: visibleHeight)
                )
            )
        }
        width = Int(encodedBackingSize.width)
        height = Int(encodedBackingSize.height)
        let selectedQueueDepth = Self.captureQueueDepth(
            lowLatencyEnabled: lowLatencyEnabled,
            targetFPS: configuredFPS,
            width: width,
            height: height
        )
        if Int(requestedSize.width.rounded(.down)) != width
            || Int(requestedSize.height.rounded(.down)) != height
            || visibleWidth != width
            || visibleHeight != height {
            logger.info(
                """
                🎚️ 已调整远控采集尺寸以匹配编码器约束: requested=\(Int(requestedSize.width.rounded(.down)))x\(Int(requestedSize.height.rounded(.down))) \
                visible=\(self.visibleWidth)x\(self.visibleHeight) encoded=\(self.width)x\(self.height) codec=\(preferredCodec.rawValue, privacy: .public)
                """
            )
        }
        RemoteControlSmokeStatusWriter.append(
            """
            \(Self.startSmokeStatusPrefix(captureVideoOutput: captureVideoOutput, requestedSystemAudio: captureSystemAudio)) \
            targetFPS=\(configuredFPS) codec=\(preferredCodec == .h264 ? "h264" : (preferredCodec == .hevc ? "hevc" : "bgra")) \
            requestedGOP=\(configuredKeyInterval) lowLatency=\(lowLatencyEnabled) \
            requested=\(Int(requestedSize.width.rounded(.down)))x\(Int(requestedSize.height.rounded(.down))) \
            encoded=\(width)x\(height) visible=\(visibleWidth)x\(visibleHeight) bitstream=\(bitstreamFormat == .annexB ? "annexB" : "native") \
            queueDepth=\(selectedQueueDepth) videoOutput=\(captureVideoOutput) capturesAudio=\(captureSystemAudio)
            """
        )
        if !jpegMode {
            // 映射编码类型
            codecType = (preferredCodec == .h264) ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
        }

 // 创建输出对象与流配置
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA // 原始帧，后续由VTCompressionSession进行压缩
        configuration.minimumFrameInterval = Self.screenCaptureMinimumFrameInterval(forConfiguredFPS: configuredFPS)
        configuration.queueDepth = selectedQueueDepth
        let requestedSystemAudio = captureSystemAudio
        configuration.capturesAudio = requestedSystemAudio
        if requestedSystemAudio {
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.excludesCurrentProcessAudio = true
        }
        configuration.showsCursor = captureCursorInVideo

        output = StreamOutput(owner: self)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        if captureVideoOutput && !jpegMode && onEncodedFrame != nil {
            try setupCompressionSession(width: width, height: height, codec: codecType)
        }

 // 18.2: guard let 处理 stream output (Requirements 8.2, 8.3)
        guard let streamOutput = output else {
            logger.error("StreamOutput 创建失败")
            throw CocoaError(.featureUnsupported)
        }
        if Self.shouldRegisterScreenOutput(
            captureVideoOutput: captureVideoOutput,
            requestedSystemAudio: requestedSystemAudio
        ) {
            try stream?.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: sampleOutputQueue)
        }
        if requestedSystemAudio {
            do {
                try stream?.addStreamOutput(streamOutput, type: .audio, sampleHandlerQueue: audioSampleOutputQueue)
            } catch {
                if failFastOnMediaFallbacks {
                    reportStrictMediaFailure(
                        issue: "strict-audio-output-unavailable",
                        detail: error.localizedDescription
                    )
                    throw error
                }
                self.captureSystemAudio = false
                logger.warning(
                    "⚠️ 系统音频采集输出不可用，远控将降级为仅视频: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        do {
            try await stream?.startCapture()
        } catch {
            if requestedSystemAudio {
                if failFastOnMediaFallbacks {
                    reportStrictMediaFailure(
                        issue: "strict-audio-start-failed",
                        detail: error.localizedDescription
                    )
                    throw error
                }
                logger.warning(
                    "⚠️ 启动含系统音频的采集失败，重试仅视频采集: \(error.localizedDescription, privacy: .public)"
                )
                resetPipelineAfterFailedStart()
                started = false
                try await start(
                    preferredCodec: preferredCodec,
                    preferredSize: preferredSize,
                    targetFPS: targetFPS,
                    keyFrameInterval: keyFrameInterval,
                    captureCursorInVideo: captureCursorInVideo,
                    captureVideoOutput: captureVideoOutput,
                    captureSystemAudio: false,
                    audioEncoding: audioEncoding,
                    degradedFallbackJPEGProfile: degradedFallbackJPEGProfile,
                    failFastOnMediaFallbacks: failFastOnMediaFallbacks,
                    preserveExactVisibleSize: preserveExactVisibleSize,
                    lowLatencyMode: lowLatencyMode,
                    videoCompressionLevelPercent: videoCompressionLevelPercent,
                    bitstreamFormat: bitstreamFormat
                )
                return
            }
            throw error
        }
        startVideoCadenceTimerIfNeeded(captureVideoOutput: captureVideoOutput)
        armFirstEncodedFrameWatchdogIfNeeded(captureVideoOutput: captureVideoOutput)
        registerDisplayObservers()
        if !captureVideoOutput {
            logger.info("🎧 ScreenCaptureKit 系统音频采集启动：audio-only")
        } else if jpegMode {
            logger.info("🎥 ScreenCaptureKit 采集启动：\(self.width)x\(self.height), codec=JPEG(BGRA)")
        } else if emitsDegradedFallbackJPEGFrames {
            logger.info(
                """
                🎥 ScreenCaptureKit 采集启动：\(self.width)x\(self.height), \
                codec=\(preferredCodec == .h264 ? "H.264" : "HEVC"), degradedJPEGFallback=enabled \
                fallbackFPS=\(self.jpegFallbackProfile.targetFrameRate, privacy: .public) \
                fallbackMaxBytes=\(self.jpegFallbackProfile.maxEncodedFrameBytes, privacy: .public)
                """
            )
        } else {
            logger.info("🎥 ScreenCaptureKit 采集启动：\(self.width)x\(self.height), codec=\(preferredCodec == .h264 ? "H.264" : "HEVC")")
        }
    }

    @MainActor
    private func resetPipelineAfterFailedStart() {
        stopVideoCadenceTimer()
        drainVideoCadenceQueueIfNeeded()
        drainVideoEncodeSubmissionQueueIfNeeded()
        stream?.stopCapture()
        stream = nil
        output = nil
        unregisterDisplayObservers()
        deactivateCompressionCallbackContext()
        if let cs = takeCompressionSessionForInvalidation() {
            VTCompressionSessionCompleteFrames(cs, untilPresentationTimeStamp: CMTime.invalid)
            VTCompressionSessionInvalidate(cs)
        }
        releaseCompressionCallbackContext()
        hasEmittedParameterSets = false
        hasEmittedFirstEncodedFrameTrace = false
        pendingForcedKeyFrames = 0
        pendingParameterSetReannounce = false
        cancelFirstEncodedFrameWatchdog()
        configuredLowLatencyRateControlEnabled = false
        captureSystemAudio = false
        audioConverter = nil
        audioConverterInputSignature = nil
        compressedAudioConverter = nil
        compressedAudioFormat = nil
        compressedAudioSignature = nil
        didLogAudioCompressionFallback = false
        didLogStrictMediaFailure = false
        audioSequenceNumber = 0
        resetVideoCadenceState()
        captureVideoOutput = true
    }

 /// 停止采集与编码
    @MainActor
    func stop() {
        guard started else { return }
        started = false
        // 清除注入坐标映射（仅视频采集流；在下方把 captureVideoOutput 复位为 true 之前读取本会话的真实值）。
        if captureVideoOutput {
            RemoteControlInjectionMappingStore.publish(nil)
        }
        stateLock.lock()
        lastSampleBufferAt = .distantPast
        lastMeaningfulSampleAt = .distantPast
        lastEncodedFrameAt = .distantPast
        stateLock.unlock()
        stopVideoCadenceTimer()
        drainVideoCadenceQueueIfNeeded()
        drainVideoEncodeSubmissionQueueIfNeeded()
        stream?.stopCapture()
        stream = nil
        output = nil
        unregisterDisplayObservers()
        deactivateCompressionCallbackContext()
        if let cs = takeCompressionSessionForInvalidation() {
            VTCompressionSessionCompleteFrames(cs, untilPresentationTimeStamp: CMTime.invalid)
            VTCompressionSessionInvalidate(cs)
        }
        releaseCompressionCallbackContext()
        hasEmittedParameterSets = false
        pendingForcedKeyFrames = 0
        pendingParameterSetReannounce = false
        cancelFirstEncodedFrameWatchdog()
        configuredLowLatencyRateControlEnabled = false
        captureCursorInVideo = true
        captureVideoOutput = true
        captureSystemAudio = false
        emitsDegradedFallbackJPEGFrames = false
        capturedDisplayID = nil
        capturedDisplayPixelSize = .zero
        lastSceneCutRecoveryAt = .distantPast
        audioConverter = nil
        audioConverterInputSignature = nil
        compressedAudioConverter = nil
        compressedAudioFormat = nil
        compressedAudioSignature = nil
        clearLatestVideoPixelBuffer()
        resetVideoCadenceState()
        didLogAudioCompressionFallback = false
        didLogStrictMediaFailure = false
        audioSequenceNumber = 0
        logger.info("🛑 ScreenCaptureKit 采集已停止")
    }

    @MainActor
    func requestKeyFrameRefresh(
        reason: String,
        count: Int = 2,
        reannounceParameterSets: Bool = true
    ) {
        let clampedCount = max(1, min(count, 4))
        stateLock.lock()
        pendingForcedKeyFrames = max(pendingForcedKeyFrames, clampedCount)
        if reannounceParameterSets {
            pendingParameterSetReannounce = true
        }
        stateLock.unlock()
        logger.info("🪄 请求关键帧刷新并重宣告参数集: \(reason, privacy: .public)")
    }

    @MainActor
    private func requestSceneCutRecovery(reason: String) {
        guard started else { return }
        let now = Date()
        var shouldTrigger = false
        let minimumInterval = Self.sceneCutRecoveryMinimumInterval(for: reason)
        stateLock.lock()
        if now.timeIntervalSince(lastSceneCutRecoveryAt) >= minimumInterval {
            lastSceneCutRecoveryAt = now
            pendingParameterSetReannounce = true
            shouldTrigger = true
        }
        stateLock.unlock()
        guard shouldTrigger else { return }
        requestKeyFrameRefresh(reason: "scene-cut-\(reason)", count: Self.sceneCutKeyFrameRefreshCount)
        logger.info("🎬 检测到场景切换，已强制请求单个 IDR 与参数集重宣告: \(reason, privacy: .public)")
    }

    private static func sceneCutRecoveryMinimumInterval(for reason: String) -> TimeInterval {
        if reason.contains("active-application") || reason.contains("active-space") {
            return activeTransitionSceneCutMinimumInterval
        }
        if reason.contains("display-parameters") {
            return displayParameterSceneCutMinimumInterval
        }
        return damageSceneCutMinimumInterval
    }

    @MainActor
    private func registerDisplayObservers() {
        unregisterDisplayObservers()
#if canImport(AppKit)
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDisplayConfigurationChange()
            }
        }
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.started else { return }
                self.requestSceneCutRecovery(reason: "active-space-changed")
            }
        }
        activeApplicationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let activatedBundleIdentifier = (
                notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            )?.bundleIdentifier
            Task { @MainActor [weak self] in
                guard let self, self.started else { return }
                if let bundleIdentifier = activatedBundleIdentifier,
                   !bundleIdentifier.isEmpty {
                    self.requestSceneCutRecovery(reason: "active-application-\(bundleIdentifier)")
                } else {
                    self.requestSceneCutRecovery(reason: "active-application-changed")
                }
            }
        }
#endif
    }

    @MainActor
    private func unregisterDisplayObservers() {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
#if canImport(AppKit)
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
            self.activeSpaceObserver = nil
        }
        if let activeApplicationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeApplicationObserver)
            self.activeApplicationObserver = nil
        }
#endif
    }

    private func reportStrictMediaFailure(issue: String, detail: String) {
        if !didLogStrictMediaFailure {
            didLogStrictMediaFailure = true
            logger.error(
                "⛔️ strict WebRTC media validation failed: issue=\(issue, privacy: .public) detail=\(detail, privacy: .public)"
            )
            RemoteControlSmokeStatusWriter.append(
                """
                failed stage=remote-desktop phase=\(Self.smokeStatusField(issue)) \
                issue=\(Self.smokeStatusField(issue)) detail=\(Self.smokeStatusField(detail))
                """
            )
        }
        onCaptureIssue?(issue)
    }

    private static func smokeStatusField(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ")
            .joined(separator: "_")
    }

    @MainActor
    private func handleDisplayConfigurationChange() {
        guard started else { return }

        // 以「实际正在采集的显示器」为基准（控制端可能选择了非主屏）；否则采集非主屏时会把
        // CGMainDisplayID() 误判为拓扑变化而不停重启。requestedDisplayID 为 nil 时仍跟随主屏。
        let referenceDisplayID = requestedDisplayID ?? CGMainDisplayID()
        let currentPixelSize = displayPixelSize(for: referenceDisplayID, fallback: capturedDisplayPixelSize)

        if referenceDisplayID != capturedDisplayID || currentPixelSize != capturedDisplayPixelSize {
            logger.info(
                "🔁 检测到显示器/分辨率变化，准备重启采集: oldDisplay=\(String(self.capturedDisplayID ?? 0), privacy: .public) newDisplay=\(String(referenceDisplayID), privacy: .public)"
            )
            onCaptureIssue?("display-topology-changed")
            return
        }

        requestSceneCutRecovery(reason: "display-parameters-changed")
    }

    private func displayPixelSize(for displayID: CGDirectDisplayID, fallback: CGSize) -> CGSize {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return fallback }
        return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
    }

    private func setupCompressionSession(width: Int, height: Int, codec: CMVideoCodecType) throws {
        let createdSession = makeCompressionSession(
            width: width,
            height: height,
            codec: codec,
            encoderSpecification: Self.videoEncoderSpecification(
                codec: codec,
                lowLatencyMode: lowLatencyEnabled,
                requiresHardwareEncoder: failFastOnMediaFallbacks,
                preferredProfile: preferredProfile
            )
        )
        if createdSession.status != noErr || createdSession.session == nil {
            Self.releaseCompressionCallbackRefcon(createdSession.callbackRefcon)
            let issue = failFastOnMediaFallbacks
                ? "strict-video-codec-fallback-forbidden"
                : "video-codec-session-create-failed"
            reportStrictMediaFailure(
                issue: issue,
                detail: "VTCompressionSessionCreate status \(createdSession.status)"
            )
            throw NSError(
                domain: "com.skybridge.screencapturekit",
                code: Int(createdSession.status),
                userInfo: [
                    NSLocalizedDescriptionKey: "VTCompressionSessionCreate failed for requested codec \(codec): \(createdSession.status)"
                ]
            )
        } else {
            installCompressionSession(createdSession.session)
            compressionCallbackRefcon = createdSession.callbackRefcon
        }

        guard let cs = currentCompressionSession() else { throw CocoaError(.featureUnsupported) }

 // 编码参数：实时、低延迟、目标帧率
 // 根据设置的编码档位选择 ProfileLevel（使用在 start 中捕获的值）
        let profile = preferredProfile
        let lowLatencyRateControlEnabled = Self.shouldEnableLowLatencyRateControl(
            codec: codecType,
            lowLatencyMode: lowLatencyEnabled,
            preferredProfile: profile
        )
        stateLock.lock()
        configuredLowLatencyRateControlEnabled = lowLatencyRateControlEnabled
        stateLock.unlock()
        let profileValue: CFString = {
            switch (codecType, profile) {
            case (kCMVideoCodecType_HEVC, .hevcMain): return kVTProfileLevel_HEVC_Main_AutoLevel
            case (kCMVideoCodecType_HEVC, _): return kVTProfileLevel_HEVC_Main_AutoLevel
            case (kCMVideoCodecType_H264, _) where lowLatencyRateControlEnabled: return kVTProfileLevel_H264_High_AutoLevel
            case (kCMVideoCodecType_H264, .h264Baseline): return kVTProfileLevel_H264_Baseline_AutoLevel
            case (kCMVideoCodecType_H264, .h264Main): return kVTProfileLevel_H264_Main_AutoLevel
            case (kCMVideoCodecType_H264, .h264High): return kVTProfileLevel_H264_High_AutoLevel
            default: return kVTProfileLevel_H264_High_AutoLevel
            }
        }()
        let prioritizeEncodingSpeed = lowLatencyEnabled || configuredFPS >= 60 || (width * height) >= 2_000_000

        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_ProfileLevel, value: profileValue)
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: configuredFPS))
        let maximumRealTimeFrameRate = Self.videoToolboxMaximumRealTimeFrameRate(
            codec: codecType,
            width: width,
            height: height,
            fps: configuredFPS,
            lowLatencyEnabled: lowLatencyEnabled
        )
        let maximumRealTimeFrameRateStatus: OSStatus
        if #available(macOS 15.0, iOS 18.0, *) {
            maximumRealTimeFrameRateStatus = VTSessionSetProperty(
                cs,
                key: kVTCompressionPropertyKey_MaximumRealTimeFrameRate,
                value: NSNumber(value: maximumRealTimeFrameRate)
            )
        } else {
            maximumRealTimeFrameRateStatus = kVTPropertyNotSupportedErr
        }
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(
            cs,
            key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            value: prioritizeEncodingSpeed ? kCFBooleanTrue : kCFBooleanFalse
        )
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)
        let maxFrameDelayCount = Self.videoToolboxMaxFrameDelayCount(
            codec: codecType,
            width: width,
            height: height,
            fps: configuredFPS,
            lowLatencyEnabled: lowLatencyEnabled
        )
        VTSessionSetProperty(
            cs,
            key: kVTCompressionPropertyKey_MaxFrameDelayCount,
            value: NSNumber(value: maxFrameDelayCount)
        )
        if codecType == kCMVideoCodecType_H264 {
            VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
        }
        let keyInterval = Self.videoToolboxKeyFrameInterval(
            configuredKeyInterval: configuredKeyInterval,
            configuredFPS: configuredFPS,
            lowLatencyEnabled: lowLatencyEnabled,
            codec: codecType
        )
        let keyIntervalDuration = Self.videoToolboxKeyFrameIntervalDuration(
            configuredKeyInterval: configuredKeyInterval,
            configuredFPS: configuredFPS,
            lowLatencyEnabled: lowLatencyEnabled,
            codec: codecType
        )
        let compressionQuality = effectiveCompressionQuality(
            width: width,
            height: height,
            fps: configuredFPS,
            prioritizeEncodingSpeed: prioritizeEncodingSpeed
        )
        let averageBitRate = targetAverageBitRate(codec: codecType, width: width, height: height, fps: configuredFPS)
        let dataRateLimits = Self.videoToolboxDataRateLimits(
            codec: codecType,
            averageBitRate: averageBitRate,
            width: width,
            height: height,
            fps: configuredFPS,
            lowLatencyEnabled: lowLatencyEnabled
        )
        let hardLimitBytesPerSecond = dataRateLimits.hardLimitBytesPerSecond
        let burstLimitBytes = dataRateLimits.burstLimitBytes ?? 0
        let burstWindowMs = Int(((dataRateLimits.burstWindowSeconds ?? 0) * 1_000).rounded())
        stateLock.lock()
        configuredVideoToolboxMaxFrameDelayCount = maxFrameDelayCount
        configuredVideoToolboxMaximumRealTimeFrameRate = maximumRealTimeFrameRate
        configuredVideoToolboxMaximumRealTimeFrameRateStatus = maximumRealTimeFrameRateStatus
        configuredVideoToolboxAverageBitRate = averageBitRate
        configuredVideoToolboxDataRateLimitBytesPerSecond = hardLimitBytesPerSecond
        configuredVideoToolboxDataRateBurstLimitBytes = burstLimitBytes
        configuredVideoToolboxDataRateBurstWindowMs = burstWindowMs
        stateLock.unlock()
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: keyInterval))
        VTSessionSetProperty(
            cs,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: NSNumber(value: keyIntervalDuration)
        )
        VTSessionSetProperty(
            cs,
            key: kVTCompressionPropertyKey_Quality,
            value: NSNumber(value: compressionQuality)
        )
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: averageBitRate))
        let dataRateLimitsStatus = VTSessionSetProperty(
            cs,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: dataRateLimits.limits as CFArray
        )
        var copiedDataRateLimits: CFTypeRef?
        let dataRateLimitsReadbackStatus = withUnsafeMutablePointer(to: &copiedDataRateLimits) { pointer in
            VTSessionCopyProperty(
                cs,
                key: kVTCompressionPropertyKey_DataRateLimits,
                allocator: kCFAllocatorDefault,
                valueOut: UnsafeMutableRawPointer(pointer)
            )
        }
        let readbackDataRateLimits = Self.videoToolboxDataRateLimitsReadback(from: copiedDataRateLimits)
        let readbackBurstLimitBytes = readbackDataRateLimits.count >= 3
            ? readbackDataRateLimits[2].intValue
            : 0
        let readbackBurstWindowMs = readbackDataRateLimits.count >= 4
            ? Int((readbackDataRateLimits[3].doubleValue * 1_000).rounded())
            : 0
        let dataRateLimitsApplied = dataRateLimitsStatus == noErr
            && dataRateLimitsReadbackStatus == noErr
            && readbackDataRateLimits.count == dataRateLimits.limits.count
            && readbackDataRateLimits.enumerated().allSatisfy { index, value in
                abs(value.doubleValue - dataRateLimits.limits[index].doubleValue) < 0.0001
            }
        RemoteControlSmokeStatusWriter.append(
            """
            mac-sck-encoder targetFPS=\(configuredFPS) codec=\(codecType == kCMVideoCodecType_HEVC ? "hevc" : "h264") \
            requestedGOP=\(configuredKeyInterval) keyInterval=\(keyInterval) keyDurationMs=\(Int((keyIntervalDuration * 1000).rounded())) \
            cadenceCatchUpLimit=\(Self.cadenceCatchUpFrameLimit(forConfiguredFPS: configuredFPS)) \
            maxFrameDelayCount=\(maxFrameDelayCount) maximumRealTimeFrameRate=\(maximumRealTimeFrameRate) maximumRealTimeFrameRateStatus=\(maximumRealTimeFrameRateStatus) lowLatency=\(lowLatencyEnabled) lowLatencyRateControl=\(lowLatencyRateControlEnabled) displayCompressionLevel=\(preferredCompressionLevelPercent) quality=\(String(format: "%.2f", compressionQuality)) averageBitRate=\(averageBitRate) dataRateLimitBytesPerSecond=\(hardLimitBytesPerSecond) \
            dataRateBurstLimitBytes=\(burstLimitBytes) dataRateBurstWindowMs=\(burstWindowMs) singleChunkHEVCBudgetBytes=\(Self.lowLatencyHEVC2K60SingleChunkEncodedPayloadBudgetBytes) \
            dataRateLimitsStatus=\(dataRateLimitsStatus) dataRateLimitsReadbackStatus=\(dataRateLimitsReadbackStatus) dataRateLimitsApplied=\(dataRateLimitsApplied ? 1 : 0) \
            dataRateReadbackBurstLimitBytes=\(readbackBurstLimitBytes) dataRateReadbackBurstWindowMs=\(readbackBurstWindowMs) \
            videoOutput=\(captureVideoOutput) capturesAudio=\(captureSystemAudio)
            """
        )
        if failFastOnMediaFallbacks,
           codecType == kCMVideoCodecType_HEVC,
           lowLatencyEnabled,
           burstLimitBytes > 0,
           !dataRateLimitsApplied {
            reportStrictMediaFailure(
                issue: "strict-video-rate-limit-unapplied",
                detail: "DataRateLimits status=\(dataRateLimitsStatus) readbackStatus=\(dataRateLimitsReadbackStatus)"
            )
            throw NSError(
                domain: "com.skybridge.screencapturekit",
                code: Int(dataRateLimitsStatus == noErr ? dataRateLimitsReadbackStatus : dataRateLimitsStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: "VTCompressionSession DataRateLimits were not applied in strict media mode"
                ]
            )
        }

 // 自适应码率控制（如果启用）
 // 注意：自适应码率将在启动后异步应用，避免在同步上下文中访问 MainActor 隔离的属性
 // 可以通过 NetworkQualityAdaptiveBitrateController 的回调在运行时动态调整码率

        VTCompressionSessionPrepareToEncodeFrames(cs)
    }

    private func makeCompressionSession(
        width: Int,
        height: Int,
        codec: CMVideoCodecType,
        encoderSpecification: CFDictionary?
    ) -> (status: OSStatus, session: VTCompressionSession?, callbackRefcon: UnsafeMutableRawPointer) {
        var session: VTCompressionSession?
        let callbackRefcon = makeCompressionCallbackRefcon()
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { refcon, sourceFrameRefCon, status, infoFlags, sampleBuffer in
                ScreenCaptureKitStreamer.handleCompressionCallback(
                    refcon: refcon,
                    sourceFrameRefCon: sourceFrameRefCon,
                    status: status,
                    infoFlags: infoFlags,
                    sampleBuffer: sampleBuffer
                )
            },
            refcon: callbackRefcon,
            compressionSessionOut: &session
        )
        return (status, session, callbackRefcon)
    }

    private func compressionQualityValue() -> Float {
        switch preferredQuality {
        case .low: return 0.45
        case .medium: return 0.6
        case .high: return 0.78
        case .ultra: return 0.92
        }
    }

    private static func boundedVideoCompressionLevelPercent(_ value: Int) -> Int {
        max(0, min(value, 100))
    }

    private func compressionLevelRateScale() -> Float {
        let normalized = (Float(Self.boundedVideoCompressionLevelPercent(preferredCompressionLevelPercent)) - 50.0) / 50.0
        return max(0.65, min(1.25, 1.0 - normalized * 0.35))
    }

    private func effectiveCompressionQuality(
        width: Int,
        height: Int,
        fps: Int,
        prioritizeEncodingSpeed: Bool
    ) -> Float {
        var quality = compressionQualityValue() * compressionLevelRateScale()
        let megapixels = Double(max(width * height, 1)) / 1_000_000.0

        if prioritizeEncodingSpeed {
            if megapixels >= 2.5 || fps >= 60 {
                quality = min(quality, 0.30)
            } else {
                quality = min(quality, 0.60)
            }
        } else if megapixels >= 4.0 {
            quality = min(quality, 0.68)
        }

        return max(0.10, min(quality, 0.98))
    }

    private func targetAverageBitRate(codec: CMVideoCodecType, width: Int, height: Int, fps: Int) -> Int {
        let pixelsPerSecond = Double(max(width * height * max(fps, 1), 1))
        let bitsPerPixelPerFrame: Double
        switch preferredQuality {
        case .low:
            bitsPerPixelPerFrame = codec == kCMVideoCodecType_HEVC ? 0.10 : 0.14
        case .medium:
            bitsPerPixelPerFrame = codec == kCMVideoCodecType_HEVC ? 0.14 : 0.20
        case .high:
            bitsPerPixelPerFrame = codec == kCMVideoCodecType_HEVC ? 0.24 : 0.42
        case .ultra:
            bitsPerPixelPerFrame = codec == kCMVideoCodecType_HEVC ? 0.32 : 0.56
        }

        let compressionScale = Double(compressionLevelRateScale())
        let rawBitRate = Int((pixelsPerSecond * bitsPerPixelPerFrame * compressionScale).rounded())
        let baseMinimum = codec == kCMVideoCodecType_HEVC ? 6_000_000 : 10_000_000
        let minimum = Int((Double(baseMinimum) * min(1.0, max(0.75, compressionScale))).rounded())
        let maximum: Int
        if codec == kCMVideoCodecType_HEVC, fps >= 55, width * height >= 2_500_000 {
            maximum = 12_000_000
        } else {
            maximum = codec == kCMVideoCodecType_HEVC ? 55_000_000 : 80_000_000
        }
        return min(max(rawBitRate, minimum), maximum)
    }

    private func makeCompressionCallbackRefcon() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(Unmanaged.passRetained(CompressionCallbackContext(streamer: self)).toOpaque())
    }

    private func deactivateCompressionCallbackContext() {
        guard let compressionCallbackRefcon else { return }
        let context = Unmanaged<CompressionCallbackContext>
            .fromOpaque(compressionCallbackRefcon)
            .takeUnretainedValue()
        context.deactivate()
    }

    private func releaseCompressionCallbackContext() {
        guard let compressionCallbackRefcon else { return }
        Self.releaseCompressionCallbackRefcon(compressionCallbackRefcon)
        self.compressionCallbackRefcon = nil
    }

    private static func releaseCompressionCallbackRefcon(_ refcon: UnsafeMutableRawPointer) {
        Unmanaged<CompressionCallbackContext>.fromOpaque(refcon).release()
    }

    private static func makeEncodeFrameTimingRefcon(
        submittedAtUptimeNanoseconds: UInt64,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        sourceFrameGeneration: UInt64,
        sourceFrameRepeatCount: Int,
        sourceFrameAgeMsAtSubmission: Double,
        forcedKeyFrame: Bool
    ) -> UnsafeMutableRawPointer {
        let timing = EncodeFrameTiming(
            submittedAtUptimeNanoseconds: submittedAtUptimeNanoseconds,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            sourceFrameGeneration: sourceFrameGeneration,
            sourceFrameRepeatCount: sourceFrameRepeatCount,
            sourceFrameAgeMsAtSubmission: sourceFrameAgeMsAtSubmission,
            forcedKeyFrame: forcedKeyFrame
        )
        return UnsafeMutableRawPointer(Unmanaged.passRetained(timing).toOpaque())
    }

    private static func consumeEncodeFrameTimingRefcon(
        _ refcon: UnsafeMutableRawPointer?
    ) -> EncodeFrameTiming? {
        guard let refcon else { return nil }
        return Unmanaged<EncodeFrameTiming>.fromOpaque(refcon).takeRetainedValue()
    }

    private static func encodeLatencyMilliseconds(from timing: EncodeFrameTiming?) -> Double? {
        guard let timing else { return nil }
        let completedAt = DispatchTime.now().uptimeNanoseconds
        guard completedAt >= timing.submittedAtUptimeNanoseconds else { return nil }
        return Double(completedAt - timing.submittedAtUptimeNanoseconds) / 1_000_000.0
    }

    private static func actualEncodeLatencyMilliseconds(from timing: EncodeFrameTiming?) -> Double? {
        guard let timing else { return nil }
        let completedAt = DispatchTime.now().uptimeNanoseconds
        guard completedAt >= timing.actualSubmittedAtUptimeNanoseconds else { return nil }
        return Double(completedAt - timing.actualSubmittedAtUptimeNanoseconds) / 1_000_000.0
    }

    private static func encodeTimingSmokeFields(_ timing: EncodeFrameTiming?) -> String {
        guard let timing else {
            return "ptsValue=- ptsScale=- durationValue=- durationScale=- submittedAtUptimeNs=- actualSubmittedAtUptimeNs=- sourceFrameGeneration=0 sourceFrameRepeatCount=0 sourceFrameAgeMs=- forcedKeyFrame=0"
        }
        let sourceAge = String(format: "%.2f", timing.sourceFrameAgeMsAtSubmission)
        return "ptsValue=\(timing.presentationTimeStamp.value) ptsScale=\(timing.presentationTimeStamp.timescale) "
            + "durationValue=\(timing.duration.value) durationScale=\(timing.duration.timescale) "
            + "submittedAtUptimeNs=\(timing.submittedAtUptimeNanoseconds) actualSubmittedAtUptimeNs=\(timing.actualSubmittedAtUptimeNanoseconds) "
            + "sourceFrameGeneration=\(timing.sourceFrameGeneration) sourceFrameRepeatCount=\(timing.sourceFrameRepeatCount) "
            + "sourceFrameAgeMs=\(sourceAge) forcedKeyFrame=\(timing.forcedKeyFrame ? 1 : 0)"
    }

    private static func handleCompressionCallback(
        refcon: UnsafeMutableRawPointer?,
        sourceFrameRefCon: UnsafeMutableRawPointer?,
        status: OSStatus,
        infoFlags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?
    ) {
        let timing = consumeEncodeFrameTimingRefcon(sourceFrameRefCon)
        let encodeLatencyMs = encodeLatencyMilliseconds(from: timing)
        let actualEncodeLatencyMs = actualEncodeLatencyMilliseconds(from: timing)
        guard let refcon else { return }
        let unmanaged = Unmanaged<CompressionCallbackContext>.fromOpaque(refcon)
        _ = unmanaged.retain()
        let context = unmanaged.takeUnretainedValue()
        defer { unmanaged.release() }
        guard let streamer = context.activeStreamer() else { return }
        guard status == noErr, let sampleBuffer else {
            streamer.handleEncodeCallbackFailure(
                status: status,
                infoFlags: infoFlags,
                sampleBufferPresent: sampleBuffer != nil,
                encodeLatencyMs: encodeLatencyMs,
                timing: timing
            )
            return
        }
        autoreleasepool {
            streamer.handleCompressedSample(
                sampleBuffer,
                encodeLatencyMs: encodeLatencyMs,
                actualEncodeLatencyMs: actualEncodeLatencyMs
            )
        }
    }

    func healthSnapshot() -> (
        lastSampleBufferAt: Date,
        lastMeaningfulSampleAt: Date,
        lastEncodedFrameAt: Date
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (lastSampleBufferAt, lastMeaningfulSampleAt, lastEncodedFrameAt)
    }

    @MainActor
    func captureContextSnapshot() -> CaptureContextSnapshot? {
        guard started,
              let capturedDisplayID,
              capturedDisplayPixelSize.width > 0,
              capturedDisplayPixelSize.height > 0,
              width > 0,
              height > 0 else {
            return nil
        }

        return CaptureContextSnapshot(
            displayID: capturedDisplayID,
            displayPixelSize: capturedDisplayPixelSize,
            streamSize: CGSize(width: width, height: height),
            captureCursorInVideo: captureCursorInVideo
        )
    }

    private func noteSampleBufferReceived() {
        let now = Date()
        let snapshot: ScreenCaptureTelemetrySnapshot?
        stateLock.lock()
        lastSampleBufferAt = now
        telemetryCapturedSamples += 1
        snapshot = captureTelemetrySnapshotIfNeeded(now: now)
        stateLock.unlock()
        logCaptureTelemetryIfNeeded(snapshot)
    }

    private func noteMeaningfulSampleReceived() {
        let now = Date()
        let snapshot: ScreenCaptureTelemetrySnapshot?
        stateLock.lock()
        lastMeaningfulSampleAt = now
        telemetryMeaningfulSamples += 1
        snapshot = captureTelemetrySnapshotIfNeeded(now: now)
        stateLock.unlock()
        logCaptureTelemetryIfNeeded(snapshot)
    }

    private func noteEncodedFrameEmitted(
        encodedBytes: Int = 0,
        countForTelemetry: Bool = true,
        isSyncFrame: Bool = false,
        encodeLatencyMs: Double? = nil,
        actualEncodeLatencyMs: Double? = nil
    ) {
        let now = Date()
        let snapshot: ScreenCaptureTelemetrySnapshot?
        stateLock.lock()
        lastEncodedFrameAt = now
        if countForTelemetry {
            telemetryEncodedFrames += 1
            telemetryEncodedBytes += max(0, encodedBytes)
            telemetryEncodedFrameBytesMax = max(telemetryEncodedFrameBytesMax, max(0, encodedBytes))
            if isSyncFrame {
                telemetryEncodedSyncFrameBytesMax = max(telemetryEncodedSyncFrameBytesMax, max(0, encodedBytes))
            }
            if encodedBytes > Self.lowLatencyHEVC2K60SingleChunkEncodedPayloadBudgetBytes {
                telemetryOversizedEncodedFrames += 1
                if isSyncFrame {
                    telemetryOversizedSyncFrames += 1
                }
            }
            if let encodeLatencyMs {
                telemetryEncodeLatenciesMs.append(max(0, encodeLatencyMs))
            }
            if let actualEncodeLatencyMs {
                telemetryActualEncodeLatenciesMs.append(max(0, actualEncodeLatencyMs))
            }
        }
        snapshot = captureTelemetrySnapshotIfNeeded(now: now)
        stateLock.unlock()
        logCaptureTelemetryIfNeeded(snapshot)
    }

    private func noteEncodeFrameFailed() {
        let now = Date()
        let snapshot: ScreenCaptureTelemetrySnapshot?
        stateLock.lock()
        telemetryEncodeFailures += 1
        snapshot = captureTelemetrySnapshotIfNeeded(now: now)
        stateLock.unlock()
        logCaptureTelemetryIfNeeded(snapshot)
    }

    private func handleEncodeCallbackFailure(
        status: OSStatus,
        infoFlags: VTEncodeInfoFlags,
        sampleBufferPresent: Bool,
        encodeLatencyMs: Double?,
        timing: EncodeFrameTiming?
    ) {
        noteEncodeFrameFailed()
        let statusCode = Int(status)
        let latency = encodeLatencyMs.map { String(format: "%.2f", $0) } ?? "n/a"
        let actualLatency = Self.actualEncodeLatencyMilliseconds(from: timing)
            .map { String(format: "%.2f", $0) } ?? "n/a"
        let frameDropped = infoFlags.contains(.frameDropped) ? 1 : 0
        let timingFields = Self.encodeTimingSmokeFields(timing)
        let encoderFields = encoderFailureContextSmokeFields()
        RemoteControlSmokeStatusWriter.append(
            """
            mac-sck-encode-failed stage=callback targetFPS=\(configuredFPS) codec=\(codecType == kCMVideoCodecType_HEVC ? "hevc" : "h264") \
            status=\(statusCode) flags=\(infoFlags.rawValue) frameDropped=\(frameDropped) sampleBufferPresent=\(sampleBufferPresent ? 1 : 0) encodeLatencyMs=\(latency) actualEncodeLatencyMs=\(actualLatency) \(timingFields) \
            \(encoderFields) videoOutput=\(captureVideoOutput) capturesAudio=\(captureSystemAudio)
            """
        )
        logger.error(
            "❌ VTCompressionSession callback failed: status=\(status, privacy: .public) flags=\(infoFlags.rawValue, privacy: .public) sampleBufferPresent=\(String(sampleBufferPresent), privacy: .public)"
        )
        if failFastOnMediaFallbacks,
           captureVideoOutput,
           codecType == kCMVideoCodecType_HEVC {
            let missingSample = sampleBufferPresent ? 0 : 1
            reportStrictMediaFailure(
                issue: "strict-video-encode-failed",
                detail: "VTCompressionSession callback status=\(statusCode),flags=\(infoFlags.rawValue),frameDropped=\(frameDropped),missingSample=\(missingSample),\(timingFields),\(encoderFields)"
            )
        } else {
            onCaptureIssue?("encode-callback-status-\(statusCode)")
        }
    }

    private func encoderFailureContextSmokeFields() -> String {
        stateLock.lock()
        let maxFrameDelayCount = configuredVideoToolboxMaxFrameDelayCount
        let maximumRealTimeFrameRate = configuredVideoToolboxMaximumRealTimeFrameRate
        let maximumRealTimeFrameRateStatus = configuredVideoToolboxMaximumRealTimeFrameRateStatus
        let averageBitRate = configuredVideoToolboxAverageBitRate
        let dataRateLimitBytesPerSecond = configuredVideoToolboxDataRateLimitBytesPerSecond
        let dataRateBurstLimitBytes = configuredVideoToolboxDataRateBurstLimitBytes
        let dataRateBurstWindowMs = configuredVideoToolboxDataRateBurstWindowMs
        let submissionBacklog = videoEncodeSubmissionBacklog
        let sourceFrameRepeatMax = telemetrySourceFrameRepeatMax
        let sourceFrameAgeMaxMs = telemetrySourceFrameAgeMaxMs
        stateLock.unlock()
        return "maxFrameDelayCount=\(maxFrameDelayCount) maximumRealTimeFrameRate=\(maximumRealTimeFrameRate) "
            + "maximumRealTimeFrameRateStatus=\(maximumRealTimeFrameRateStatus) averageBitRate=\(averageBitRate) "
            + "dataRateLimitBytesPerSecond=\(dataRateLimitBytesPerSecond) dataRateBurstLimitBytes=\(dataRateBurstLimitBytes) "
            + "dataRateBurstWindowMs=\(dataRateBurstWindowMs) "
            + "singleChunkHEVCBudgetBytes=\(Self.lowLatencyHEVC2K60SingleChunkEncodedPayloadBudgetBytes) "
            + "encodeSubmissionBacklog=\(submissionBacklog) "
            + "sourceFrameRepeatWindowMax=\(sourceFrameRepeatMax) sourceFrameAgeWindowMaxMs=\(String(format: "%.2f", sourceFrameAgeMaxMs))"
    }

    private func resetCaptureTelemetry() {
        stateLock.lock()
        lastSampleBufferAt = .distantPast
        lastMeaningfulSampleAt = .distantPast
        lastEncodedFrameAt = .distantPast
        lastDegradedFallbackJPEGAt = .distantPast
        captureTelemetryWindowStartedAt = Date()
        telemetryCapturedSamples = 0
        telemetryMeaningfulSamples = 0
        telemetryEncodedFrames = 0
        telemetryEncodedBytes = 0
        telemetryEncodedFrameBytesMax = 0
        telemetryEncodedSyncFrameBytesMax = 0
        telemetryOversizedEncodedFrames = 0
        telemetryOversizedSyncFrames = 0
        telemetryEncodeLatenciesMs = []
        telemetryActualEncodeLatenciesMs = []
        telemetryEncodeSubmissionDelayMaxMs = 0
        telemetryEncodeSubmissionBacklogMax = videoEncodeSubmissionBacklog
        telemetryEncodeFailures = 0
        telemetryCadenceTimerFires = 0
        telemetryCadenceSubmittedFrames = 0
        telemetryCadenceCatchUpFrames = 0
        telemetryCadenceBatchMax = 0
        stateLock.unlock()
    }

    private func resetVideoCadenceState() {
        stateLock.lock()
        lastVideoEncodeSubmittedAtNanos = 0
        lastVideoPresentationTimeStamp = nil
        videoEncodeSubmissionBacklog = 0
        lastReservedSourceFrameGeneration = 0
        consecutiveReservedSourceFrameSubmissions = 0
        stateLock.unlock()
    }

    @discardableResult
    private func rememberLatestVideoPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> UInt64 {
        stateLock.lock()
        latestVideoPixelBufferGeneration &+= 1
        if latestVideoPixelBufferGeneration == 0 {
            latestVideoPixelBufferGeneration = 1
        }
        let generation = latestVideoPixelBufferGeneration
        latestVideoPixelBuffer = pixelBuffer
        latestVideoPixelBufferCapturedAtNanos = DispatchTime.now().uptimeNanoseconds
        stateLock.unlock()
        return generation
    }

    private func latestVideoPixelBufferSnapshotForCadence() -> (pixelBuffer: CVPixelBuffer, generation: UInt64)? {
        stateLock.lock()
        guard let pixelBuffer = latestVideoPixelBuffer else {
            stateLock.unlock()
            return nil
        }
        let generation = latestVideoPixelBufferGeneration
        stateLock.unlock()
        return (pixelBuffer, generation)
    }

    private func clearLatestVideoPixelBuffer() {
        stateLock.lock()
        latestVideoPixelBuffer = nil
        latestVideoPixelBufferGeneration = 0
        latestVideoPixelBufferCapturedAtNanos = 0
        lastReservedSourceFrameGeneration = 0
        consecutiveReservedSourceFrameSubmissions = 0
        stateLock.unlock()
    }

    private func currentCompressionSession() -> VTCompressionSession? {
        compressionSessionLock.lock()
        let session = compressionSession
        compressionSessionLock.unlock()
        return session
    }

    private func installCompressionSession(_ session: VTCompressionSession?) {
        compressionSessionLock.lock()
        compressionSession = session
        compressionSessionLock.unlock()
    }

    private func takeCompressionSessionForInvalidation() -> VTCompressionSession? {
        compressionSessionLock.lock()
        let session = compressionSession
        compressionSession = nil
        compressionSessionLock.unlock()
        return session
    }

    private func drainVideoCadenceQueueIfNeeded() {
        guard DispatchQueue.getSpecific(key: Self.videoCadenceQueueKey) != true else { return }
        videoCadenceQueue.sync {}
    }

    private func drainVideoEncodeSubmissionQueueIfNeeded() {
        guard DispatchQueue.getSpecific(key: Self.videoEncodeSubmissionQueueKey) != true else { return }
        videoEncodeSubmissionQueue.sync {}
    }

    private var shouldUseDisplayCadenceEncoder: Bool {
        Self.shouldRunDisplayCadenceEncoder(
            jpegMode: jpegMode,
            hasEncodedFrameSink: onEncodedFrame != nil,
            targetFPS: configuredFPS
        )
    }

    private func startVideoCadenceTimerIfNeeded(captureVideoOutput: Bool) {
        stopVideoCadenceTimer()
        guard captureVideoOutput,
              shouldUseDisplayCadenceEncoder,
              currentCompressionSession() != nil else {
            return
        }
        let timerIntervalNanos = Self.cadenceTimerIntervalNanoseconds(forConfiguredFPS: configuredFPS)
        let timer = DispatchSource.makeTimerSource(queue: videoCadenceQueue)
        timer.schedule(
            deadline: .now() + .nanoseconds(Int(timerIntervalNanos)),
            repeating: .nanoseconds(Int(timerIntervalNanos)),
            leeway: .microseconds(configuredFPS >= 55 ? 100 : 500)
        )
        timer.setEventHandler { [weak self] in
            self?.encodeDisplayCadenceFrameIfDue()
        }
        videoCadenceTimer = timer
        timer.resume()
        logger.info(
            "🕒 SCK display cadence encoder enabled: targetFPS=\(self.configuredFPS, privacy: .public)"
        )
    }

    private func stopVideoCadenceTimer() {
        videoCadenceTimer?.setEventHandler {}
        videoCadenceTimer?.cancel()
        videoCadenceTimer = nil
    }

    private func armFirstEncodedFrameWatchdogIfNeeded(captureVideoOutput: Bool) {
        guard captureVideoOutput, !jpegMode, onEncodedFrame != nil else { return }
        let timeout = Self.firstEncodedFrameTimeoutSeconds(
            targetFPS: configuredFPS,
            width: width,
            height: height
        )
        stateLock.lock()
        firstFrameWatchdogGeneration += 1
        let generation = firstFrameWatchdogGeneration
        stateLock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(Int((timeout * 1000).rounded()))
        ) { [weak self] in
            self?.evaluateFirstEncodedFrameWatchdog(generation: generation, timeout: timeout)
        }
    }

    private func cancelFirstEncodedFrameWatchdog() {
        stateLock.lock()
        firstFrameWatchdogGeneration += 1
        stateLock.unlock()
    }

    private func evaluateFirstEncodedFrameWatchdog(generation: Int, timeout: TimeInterval) {
        let now = Date()
        stateLock.lock()
        guard generation == firstFrameWatchdogGeneration,
              !hasEmittedFirstEncodedFrameTrace else {
            stateLock.unlock()
            return
        }
        let capturedSamples = telemetryCapturedSamples
        let meaningfulSamples = telemetryMeaningfulSamples
        let encodedFrames = telemetryEncodedFrames
        let encodeFailures = telemetryEncodeFailures
        let cadenceTimerFires = telemetryCadenceTimerFires
        let cadenceSubmittedFrames = telemetryCadenceSubmittedFrames
        let lowLatencyRateControl = configuredLowLatencyRateControlEnabled
        let lastSampleAgeMs = Self.ageMilliseconds(since: lastSampleBufferAt, now: now)
        let lastMeaningfulAgeMs = Self.ageMilliseconds(since: lastMeaningfulSampleAt, now: now)
        let lastEncodedAgeMs = Self.ageMilliseconds(since: lastEncodedFrameAt, now: now)
        stateLock.unlock()

        let detail = "timeoutMs=\(Int((timeout * 1000).rounded())),capturedSamples=\(capturedSamples),meaningfulSamples=\(meaningfulSamples),encodedFrames=\(encodedFrames),encodeFailures=\(encodeFailures),cadenceTimerFires=\(cadenceTimerFires),cadenceSubmitted=\(cadenceSubmittedFrames),lowLatencyRateControl=\(lowLatencyRateControl),lastSampleAgeMs=\(lastSampleAgeMs),lastMeaningfulAgeMs=\(lastMeaningfulAgeMs),lastEncodedAgeMs=\(lastEncodedAgeMs)"
        if failFastOnMediaFallbacks {
            reportStrictMediaFailure(issue: "strict-video-first-frame-timeout", detail: detail)
        } else {
            RemoteControlSmokeStatusWriter.append(
                """
                mac-sck-first-frame-timeout targetFPS=\(configuredFPS) codec=\(captureTelemetryCodecName) \
                \(detail)
                """
            )
            onCaptureIssue?("video-first-frame-timeout")
        }
    }

    private static func ageMilliseconds(since date: Date, now: Date) -> Int {
        guard date > .distantPast else { return -1 }
        return max(0, Int((now.timeIntervalSince(date) * 1000).rounded()))
    }

    private func scheduleDisplayCadenceEncode() {
        videoCadenceQueue.async { [weak self] in
            self?.encodeDisplayCadenceFrameIfDue()
        }
    }

    private func encodeDisplayCadenceFrameIfDue() {
        guard shouldUseDisplayCadenceEncoder,
              currentCompressionSession() != nil,
              let pixelBufferSnapshot = latestVideoPixelBufferSnapshotForCadence() else {
            return
        }
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        let submissionTargets = cadenceSubmissionTargetUptimes(nowNanos: nowNanos)
        noteDisplayCadenceTimerFire(submittedFrames: submissionTargets.count)
        guard !submissionTargets.isEmpty else { return }
        for submissionTarget in submissionTargets {
            encodeVideoPixelBuffer(
                pixelBufferSnapshot.pixelBuffer,
                presentationTimeStamp: Self.presentationTimeFromUptimeNanoseconds(submissionTarget),
                duration: Self.encodeFrameDuration(forConfiguredFPS: configuredFPS),
                submittedAtUptimeNanoseconds: submissionTarget,
                sourceFrameGeneration: pixelBufferSnapshot.generation
            )
        }
    }

    private func cadenceSubmissionTargetUptimes(nowNanos: UInt64) -> [UInt64] {
        stateLock.lock()
        let lastSubmittedAt = lastVideoEncodeSubmittedAtNanos
        let hasPendingForcedKeyFrame = pendingForcedKeyFrames > 0
        stateLock.unlock()
        guard !hasPendingForcedKeyFrame else { return [nowNanos] }
        return Self.cadenceSubmissionTargetUptimes(
            lastSubmittedAt: lastSubmittedAt,
            nowNanos: nowNanos,
            configuredFPS: configuredFPS,
            maxCatchUpFrames: Self.cadenceCatchUpFrameLimit(forConfiguredFPS: configuredFPS)
        )
    }

    private func nextVideoPresentationTimeStamp(
        preferred preferredPTS: CMTime,
        duration: CMTime,
        submittedAtUptimeNanoseconds: UInt64
    ) -> CMTime {
        let fallbackPTS = Self.presentationTimeFromUptimeNanoseconds(DispatchTime.now().uptimeNanoseconds)
        let sanitizedPreferred = preferredPTS.isValid && !preferredPTS.isIndefinite
            ? preferredPTS
            : fallbackPTS
        stateLock.lock()
        defer { stateLock.unlock() }
        let nextPTS: CMTime
        if let lastPTS = lastVideoPresentationTimeStamp,
           CMTimeCompare(sanitizedPreferred, lastPTS) <= 0 {
            nextPTS = CMTimeAdd(lastPTS, duration)
        } else {
            nextPTS = sanitizedPreferred
        }
        lastVideoPresentationTimeStamp = nextPTS
        lastVideoEncodeSubmittedAtNanos = submittedAtUptimeNanoseconds
        return nextPTS
    }

    private func noteDisplayCadenceTimerFire(submittedFrames: Int) {
        noteDisplayCadenceSubmissionEvent(submittedFrames: submittedFrames, countTimerFire: true)
    }

    private func noteDisplayCadenceSubmissionEvent(submittedFrames: Int, countTimerFire: Bool) {
        stateLock.lock()
        if countTimerFire {
            telemetryCadenceTimerFires += 1
        }
        let submittedFrames = max(0, submittedFrames)
        telemetryCadenceSubmittedFrames += submittedFrames
        telemetryCadenceCatchUpFrames += max(0, submittedFrames - 1)
        telemetryCadenceBatchMax = max(telemetryCadenceBatchMax, submittedFrames)
        stateLock.unlock()
    }

    private func captureTelemetrySnapshotIfNeeded(now: Date) -> ScreenCaptureTelemetrySnapshot? {
        let interval = now.timeIntervalSince(captureTelemetryWindowStartedAt)
        guard interval >= 1 else { return nil }
        let encodeLatencyPercentiles = Self.encodeLatencyPercentiles(telemetryEncodeLatenciesMs)
        let actualEncodeLatencyPercentiles = Self.encodeLatencyPercentiles(telemetryActualEncodeLatenciesMs)
        let snapshot = ScreenCaptureTelemetrySnapshot(
            interval: interval,
            capturedSamples: telemetryCapturedSamples,
            meaningfulSamples: telemetryMeaningfulSamples,
            encodedFrames: telemetryEncodedFrames,
            encodedBytes: telemetryEncodedBytes,
            targetFPS: configuredFPS,
            codec: captureTelemetryCodecName,
            width: width,
            height: height,
            visibleWidth: visibleWidth,
            visibleHeight: visibleHeight,
            capturesAudio: captureSystemAudio,
            encodeLatencyP50Ms: encodeLatencyPercentiles.p50,
            encodeLatencyP95Ms: encodeLatencyPercentiles.p95,
            encodeLatencyMaxMs: encodeLatencyPercentiles.max,
            actualEncodeLatencyP50Ms: actualEncodeLatencyPercentiles.p50,
            actualEncodeLatencyP95Ms: actualEncodeLatencyPercentiles.p95,
            actualEncodeLatencyMaxMs: actualEncodeLatencyPercentiles.max,
            encodeSubmissionDelayMaxMs: telemetryEncodeSubmissionDelayMaxMs,
            encodeSubmissionBacklogMax: telemetryEncodeSubmissionBacklogMax,
            encodeFailures: telemetryEncodeFailures,
            cadenceTimerFires: telemetryCadenceTimerFires,
            cadenceSubmittedFrames: telemetryCadenceSubmittedFrames,
            cadenceCatchUpFrames: telemetryCadenceCatchUpFrames,
            cadenceBatchMax: telemetryCadenceBatchMax,
            sourceFrameRepeatMax: telemetrySourceFrameRepeatMax,
            sourceFrameAgeMaxMs: telemetrySourceFrameAgeMaxMs,
            encodedFrameBytesMax: telemetryEncodedFrameBytesMax,
            encodedSyncFrameBytesMax: telemetryEncodedSyncFrameBytesMax,
            oversizedEncodedFrames: telemetryOversizedEncodedFrames,
            oversizedSyncFrames: telemetryOversizedSyncFrames
        )
        captureTelemetryWindowStartedAt = now
        telemetryCapturedSamples = 0
        telemetryMeaningfulSamples = 0
        telemetryEncodedFrames = 0
        telemetryEncodedBytes = 0
        telemetryEncodedFrameBytesMax = 0
        telemetryEncodedSyncFrameBytesMax = 0
        telemetryOversizedEncodedFrames = 0
        telemetryOversizedSyncFrames = 0
        telemetryEncodeLatenciesMs = []
        telemetryActualEncodeLatenciesMs = []
        telemetryEncodeSubmissionDelayMaxMs = 0
        telemetryEncodeSubmissionBacklogMax = videoEncodeSubmissionBacklog
        telemetryEncodeFailures = 0
        telemetryCadenceTimerFires = 0
        telemetryCadenceSubmittedFrames = 0
        telemetryCadenceCatchUpFrames = 0
        telemetryCadenceBatchMax = 0
        telemetrySourceFrameRepeatMax = max(0, consecutiveReservedSourceFrameSubmissions)
        telemetrySourceFrameAgeMaxMs = 0
        return snapshot
    }

    private var captureTelemetryCodecName: String {
        if jpegMode { return "jpeg" }
        let suffix = emitsDegradedFallbackJPEGFrames ? "+jpeg-fallback" : ""
        switch codecType {
        case kCMVideoCodecType_H264:
            return "h264\(suffix)"
        case kCMVideoCodecType_HEVC:
            return "hevc\(suffix)"
        default:
            return "\(codecType)\(suffix)"
        }
    }

    private func logCaptureTelemetryIfNeeded(_ snapshot: ScreenCaptureTelemetrySnapshot?) {
        guard let snapshot else { return }
        let captureFPS = String(format: "%.1f", snapshot.captureFPS)
        let meaningfulFPS = String(format: "%.1f", snapshot.meaningfulFPS)
        let encodedFPS = String(format: "%.1f", snapshot.encodedFPS)
        let sampleMs = Int((snapshot.interval * 1000).rounded())
        let encodeLatencyP50 = snapshot.encodeLatencyP50Ms.map { String(format: "%.2f", $0) } ?? "n/a"
        let encodeLatencyP95 = snapshot.encodeLatencyP95Ms.map { String(format: "%.2f", $0) } ?? "n/a"
        let encodeLatencyMax = snapshot.encodeLatencyMaxMs.map { String(format: "%.2f", $0) } ?? "n/a"
        let actualEncodeLatencyP50 = snapshot.actualEncodeLatencyP50Ms.map { String(format: "%.2f", $0) } ?? "n/a"
        let actualEncodeLatencyP95 = snapshot.actualEncodeLatencyP95Ms.map { String(format: "%.2f", $0) } ?? "n/a"
        let actualEncodeLatencyMax = snapshot.actualEncodeLatencyMaxMs.map { String(format: "%.2f", $0) } ?? "n/a"
        let encodeSubmissionDelayMax = String(format: "%.2f", snapshot.encodeSubmissionDelayMaxMs)
        let sourceFrameAgeMax = String(format: "%.2f", snapshot.sourceFrameAgeMaxMs)
        let singleChunkBudget = Self.lowLatencyHEVC2K60SingleChunkEncodedPayloadBudgetBytes
        logger.info(
            """
            📊 SCK tx telemetry: targetFPS=\(snapshot.targetFPS, privacy: .public) \
            codec=\(snapshot.codec, privacy: .public) \
            size=\(snapshot.width, privacy: .public)x\(snapshot.height, privacy: .public) \
            visible=\(snapshot.visibleWidth, privacy: .public)x\(snapshot.visibleHeight, privacy: .public) \
            capturesAudio=\(String(snapshot.capturesAudio), privacy: .public) \
            sampleMs=\(sampleMs, privacy: .public) \
            captureFPS=\(captureFPS, privacy: .public) \
            meaningfulFPS=\(meaningfulFPS, privacy: .public) \
            encodedFPS=\(encodedFPS, privacy: .public) \
            captured=\(snapshot.capturedSamples, privacy: .public) \
            meaningful=\(snapshot.meaningfulSamples, privacy: .public) \
            encoded=\(snapshot.encodedFrames, privacy: .public) \
            encodedBytes=\(snapshot.encodedBytes, privacy: .public) \
            encodedFrameBytesMax=\(snapshot.encodedFrameBytesMax, privacy: .public) \
            encodedSyncFrameBytesMax=\(snapshot.encodedSyncFrameBytesMax, privacy: .public) \
            singleChunkHEVCBudgetBytes=\(singleChunkBudget, privacy: .public) \
            oversizedEncodedFrames=\(snapshot.oversizedEncodedFrames, privacy: .public) \
            oversizedSyncFrames=\(snapshot.oversizedSyncFrames, privacy: .public) \
            encodeLatencyP50Ms=\(encodeLatencyP50, privacy: .public) \
            encodeLatencyP95Ms=\(encodeLatencyP95, privacy: .public) \
            encodeLatencyMaxMs=\(encodeLatencyMax, privacy: .public) \
            actualEncodeLatencyP50Ms=\(actualEncodeLatencyP50, privacy: .public) \
            actualEncodeLatencyP95Ms=\(actualEncodeLatencyP95, privacy: .public) \
            actualEncodeLatencyMaxMs=\(actualEncodeLatencyMax, privacy: .public) \
            encodeSubmissionDelayMaxMs=\(encodeSubmissionDelayMax, privacy: .public) \
            encodeSubmissionBacklogMax=\(snapshot.encodeSubmissionBacklogMax, privacy: .public) \
            encodeFailures=\(snapshot.encodeFailures, privacy: .public) \
            cadenceTimerFires=\(snapshot.cadenceTimerFires, privacy: .public) \
            cadenceSubmitted=\(snapshot.cadenceSubmittedFrames, privacy: .public) \
            cadenceCatchUpFrames=\(snapshot.cadenceCatchUpFrames, privacy: .public) \
            cadenceBatchMax=\(snapshot.cadenceBatchMax, privacy: .public) \
            sourceFrameRepeatMax=\(snapshot.sourceFrameRepeatMax, privacy: .public) \
            sourceFrameAgeMaxMs=\(sourceFrameAgeMax, privacy: .public)
            """
        )
        RemoteControlSmokeStatusWriter.append(
            """
            mac-sck-tx targetFPS=\(snapshot.targetFPS) codec=\(snapshot.codec) \
            size=\(snapshot.width)x\(snapshot.height) visible=\(snapshot.visibleWidth)x\(snapshot.visibleHeight) capturesAudio=\(snapshot.capturesAudio) \
            sampleMs=\(sampleMs) captureFPS=\(captureFPS) meaningfulFPS=\(meaningfulFPS) encodedFPS=\(encodedFPS) \
            captured=\(snapshot.capturedSamples) meaningful=\(snapshot.meaningfulSamples) encoded=\(snapshot.encodedFrames) \
            encodedBytes=\(snapshot.encodedBytes) encodedFrameBytesMax=\(snapshot.encodedFrameBytesMax) \
            encodedSyncFrameBytesMax=\(snapshot.encodedSyncFrameBytesMax) singleChunkHEVCBudgetBytes=\(singleChunkBudget) \
            oversizedEncodedFrames=\(snapshot.oversizedEncodedFrames) oversizedSyncFrames=\(snapshot.oversizedSyncFrames) \
            encodeLatencyP50Ms=\(encodeLatencyP50) \
            encodeLatencyP95Ms=\(encodeLatencyP95) encodeLatencyMaxMs=\(encodeLatencyMax) \
            actualEncodeLatencyP50Ms=\(actualEncodeLatencyP50) actualEncodeLatencyP95Ms=\(actualEncodeLatencyP95) actualEncodeLatencyMaxMs=\(actualEncodeLatencyMax) \
            encodeSubmissionDelayMaxMs=\(encodeSubmissionDelayMax) encodeSubmissionBacklogMax=\(snapshot.encodeSubmissionBacklogMax) \
            encodeFailures=\(snapshot.encodeFailures) \
            cadenceTimerFires=\(snapshot.cadenceTimerFires) cadenceSubmitted=\(snapshot.cadenceSubmittedFrames) \
            cadenceCatchUpFrames=\(snapshot.cadenceCatchUpFrames) cadenceBatchMax=\(snapshot.cadenceBatchMax) \
            sourceFrameRepeatMax=\(snapshot.sourceFrameRepeatMax) sourceFrameAgeMaxMs=\(sourceFrameAgeMax)
            """
        )
        onCaptureTelemetry?(snapshot)
    }

    private func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard captureSystemAudio else { return }
        let shouldEmitPCMChunks = onCapturedPCM16AudioChunk != nil
        let shouldEmitTransportChunks = onCapturedAudioChunk != nil
        guard shouldEmitPCMChunks || shouldEmitTransportChunks else { return }
        guard let inputBuffer = makeAudioPCMBuffer(from: sampleBuffer) else { return }
        let inputFormat = inputBuffer.format
        let inputSignature = audioInputSignature(for: inputFormat)
        if audioConverter == nil || audioConverterInputSignature != inputSignature {
            audioConverter = AVAudioConverter(from: inputFormat, to: targetAudioFormat)
            audioConverterInputSignature = inputSignature
        }
        guard let audioConverter else { return }

        let resampleRatio = targetAudioFormat.sampleRate / max(inputFormat.sampleRate, 1)
        let outputCapacity = AVAudioFrameCount(
            max(
                1,
                Int((Double(inputBuffer.frameLength) * resampleRatio).rounded(.up)) + 32
            )
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetAudioFormat,
            frameCapacity: outputCapacity
        ) else {
            return
        }

        let inputState = AudioConversionInputState()
        var conversionError: NSError?
        let status = audioConverter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if !inputState.takeIfAvailable() {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard conversionError == nil else {
            logger.debug(
                "ℹ️ 系统音频转换失败: \(conversionError?.localizedDescription ?? "unknown", privacy: .public)"
            )
            if failFastOnMediaFallbacks {
                reportStrictMediaFailure(
                    issue: "strict-audio-conversion-failed",
                    detail: conversionError?.localizedDescription ?? "unknown"
                )
            }
            return
        }
        guard status == .haveData || status == .inputRanDry else { return }
        guard outputBuffer.frameLength > 0 else { return }

        let nextSequenceNumber = audioSequenceNumber &+ 1
        let nativePCMChunk = shouldEmitPCMChunks
            ? makePCM16AudioChunk(from: outputBuffer, sequenceNumber: nextSequenceNumber)
            : nil
        if let nativePCMChunk {
            audioSequenceNumber = nativePCMChunk.sequenceNumber
            onCapturedPCM16AudioChunk?(nativePCMChunk)
        }

        if requestedAudioEncoding == .aacLC,
           let onCapturedAudioChunk,
           let compressedChunk = makeCompressedAudioChunk(
                from: outputBuffer,
                encoding: .aacLC,
                sequenceNumber: nextSequenceNumber
           ) {
            audioSequenceNumber = compressedChunk.sequenceNumber
            onCapturedAudioChunk(compressedChunk)
            return
        }

        if requestedAudioEncoding == .aacLC,
           shouldEmitTransportChunks,
           !didLogAudioCompressionFallback {
            didLogAudioCompressionFallback = true
            if failFastOnMediaFallbacks {
                reportStrictMediaFailure(
                    issue: "strict-aac-encode-failed",
                    detail: "AAC encoder returned no payload"
                )
            } else {
                logger.warning("⚠️ 系统音频 AAC 编码失败，已丢弃该音频块以保护远控视频帧率")
            }
        }

        if requestedAudioEncoding == .aacLC {
            return
        }

        let pcmChunk = nativePCMChunk ?? makePCM16AudioChunk(from: outputBuffer, sequenceNumber: nextSequenceNumber)
        guard let onCapturedAudioChunk, let pcmChunk else { return }
        audioSequenceNumber = pcmChunk.sequenceNumber
        onCapturedAudioChunk(pcmChunk)
    }

    private func makeAudioPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameLength > 0 else { return nil }

        var bufferListSizeNeeded = 0
        var retainedBlockBuffer: CMBlockBuffer?
        let probeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlockBuffer
        )
        guard probeStatus == noErr, bufferListSizeNeeded > 0 else { return nil }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        let audioBufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)

        let copyStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: audioBufferList,
            bufferListSize: bufferListSizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlockBuffer
        )
        guard copyStatus == noErr else {
            rawBufferList.deallocate()
            return nil
        }

        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            bufferListNoCopy: audioBufferList,
            deallocator: { _ in
                _ = retainedBlockBuffer
                rawBufferList.deallocate()
            }
        ) else {
            rawBufferList.deallocate()
            return nil
        }
        pcmBuffer.frameLength = frameLength
        return pcmBuffer
    }

    private func audioInputSignature(for format: AVAudioFormat) -> String {
        let commonFormatRaw = UInt(format.commonFormat.rawValue)
        return "\(format.sampleRate)-\(format.channelCount)-\(commonFormatRaw)-\(format.isInterleaved)"
    }

    private func makePCM16AudioChunk(
        from buffer: AVAudioPCMBuffer,
        sequenceNumber: UInt64
    ) -> RemoteDesktopAudioChunkPayload? {
        RemotePCM16AudioChunkBuilder.makeChunk(
            from: buffer,
            sequenceNumber: sequenceNumber
        )
    }

    private func makeCompressedAudioChunk(
        from buffer: AVAudioPCMBuffer,
        encoding: RemoteDesktopAudioChunkPayload.Encoding,
        sequenceNumber: UInt64
    ) -> RemoteDesktopAudioChunkPayload? {
        guard let (converter, outputFormat) = ensureCompressedAudioConverter(
            for: buffer.format,
            encoding: encoding
        ) else {
            return nil
        }

        let packetCapacity = AVAudioPacketCount(
            max(1, Int((Double(buffer.frameLength) / 1024.0).rounded(.up)) + 1)
        )
        let maximumPacketSize = max(1, converter.maximumOutputPacketSize)
        let compressedBuffer = AVAudioCompressedBuffer(
            format: outputFormat,
            packetCapacity: packetCapacity,
            maximumPacketSize: maximumPacketSize
        )

        let inputState = AudioConversionInputState()
        var conversionError: NSError?
        let status = converter.convert(to: compressedBuffer, error: &conversionError) { _, outStatus in
            if !inputState.takeIfAvailable() {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return buffer
        }

        guard conversionError == nil else {
            logger.debug(
                "ℹ️ 系统音频压缩失败: \(conversionError?.localizedDescription ?? "unknown", privacy: .public)"
            )
            return nil
        }
        guard status == .haveData || status == .inputRanDry else { return nil }
        guard compressedBuffer.packetCount > 0, compressedBuffer.byteLength > 0 else { return nil }

        let packetDescriptions: [RemoteDesktopAudioChunkPayload.PacketDescription]? = {
            guard let descriptionsPointer = compressedBuffer.packetDescriptions else { return nil }
            return (0..<Int(compressedBuffer.packetCount)).map { index in
                let description = descriptionsPointer[index]
                return RemoteDesktopAudioChunkPayload.PacketDescription(
                    startOffset: Int(description.mStartOffset),
                    variableFramesInPacket: description.mVariableFramesInPacket,
                    dataByteSize: description.mDataByteSize
                )
            }
        }()

        let encodedData = Data(bytes: compressedBuffer.data, count: Int(compressedBuffer.byteLength))
        return RemoteDesktopAudioChunkPayload(
            encoding: encoding,
            sampleRate: Int(buffer.format.sampleRate.rounded()),
            channelCount: Int(buffer.format.channelCount),
            frameCount: Int(buffer.frameLength),
            packetCount: Int(compressedBuffer.packetCount),
            packetDescriptions: packetDescriptions,
            magicCookie: converter.magicCookie,
            sequenceNumber: sequenceNumber,
            data: encodedData
        )
    }

    private func ensureCompressedAudioConverter(
        for inputFormat: AVAudioFormat,
        encoding: RemoteDesktopAudioChunkPayload.Encoding
    ) -> (AVAudioConverter, AVAudioFormat)? {
        guard encoding == .aacLC else { return nil }

        let converterSignature = "\(inputFormat.sampleRate)-\(inputFormat.channelCount)-\(encoding.rawValue)"
        if let compressedAudioConverter,
           let compressedAudioFormat,
           compressedAudioSignature == converterSignature {
            return (compressedAudioConverter, compressedAudioFormat)
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: Int(inputFormat.channelCount),
            AVEncoderBitRateKey: 160_000
        ]
        guard let outputFormat = AVAudioFormat(settings: outputSettings),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }

        converter.primeMethod = .none
        converter.bitRate = 160_000
        compressedAudioConverter = converter
        compressedAudioFormat = outputFormat
        compressedAudioSignature = converterSignature
        return (converter, outputFormat)
    }

    private func nextFramePropertiesForEncode() -> CFDictionary? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard pendingForcedKeyFrames > 0 else { return nil }
        pendingForcedKeyFrames -= 1
        return [kVTEncodeFrameOptionKey_ForceKeyFrame as String: kCFBooleanTrue as Any] as CFDictionary
    }

    private func consumePendingParameterSetReannounce() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard pendingParameterSetReannounce else { return false }
        pendingParameterSetReannounce = false
        return true
    }

    private func encodeVideoPixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        submittedAtUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        sourceFrameGeneration: UInt64 = 0
    ) {
        let request = reserveVideoEncodeRequest(
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            submittedAtUptimeNanoseconds: submittedAtUptimeNanoseconds,
            sourceFrameGeneration: sourceFrameGeneration
        )
        enqueueVideoEncodeRequest(request)
    }

    private func reserveVideoEncodeRequest(
        pixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        submittedAtUptimeNanoseconds: UInt64,
        sourceFrameGeneration: UInt64
    ) -> VideoEncodeRequest {
        let fallbackPTS = Self.presentationTimeFromUptimeNanoseconds(submittedAtUptimeNanoseconds)
        let sanitizedPreferred = presentationTimeStamp.isValid && !presentationTimeStamp.isIndefinite
            ? presentationTimeStamp
            : fallbackPTS
        let reservationNanos = DispatchTime.now().uptimeNanoseconds
        stateLock.lock()
        let normalizedPresentationTimeStamp: CMTime
        if let lastPTS = lastVideoPresentationTimeStamp,
           CMTimeCompare(sanitizedPreferred, lastPTS) <= 0 {
            normalizedPresentationTimeStamp = CMTimeAdd(lastPTS, duration)
        } else {
            normalizedPresentationTimeStamp = sanitizedPreferred
        }
        lastVideoPresentationTimeStamp = normalizedPresentationTimeStamp
        lastVideoEncodeSubmittedAtNanos = submittedAtUptimeNanoseconds
        let sourceFrameRepeatCount: Int
        if sourceFrameGeneration > 0,
           sourceFrameGeneration == lastReservedSourceFrameGeneration {
            consecutiveReservedSourceFrameSubmissions += 1
            sourceFrameRepeatCount = consecutiveReservedSourceFrameSubmissions
        } else {
            lastReservedSourceFrameGeneration = sourceFrameGeneration
            consecutiveReservedSourceFrameSubmissions = 1
            sourceFrameRepeatCount = 1
        }
        let sourceFrameAgeMsAtSubmission: Double
        if sourceFrameGeneration > 0,
           sourceFrameGeneration == latestVideoPixelBufferGeneration,
           latestVideoPixelBufferCapturedAtNanos > 0,
           reservationNanos >= latestVideoPixelBufferCapturedAtNanos {
            sourceFrameAgeMsAtSubmission = Double(reservationNanos - latestVideoPixelBufferCapturedAtNanos) / 1_000_000.0
        } else {
            sourceFrameAgeMsAtSubmission = 0
        }
        telemetrySourceFrameRepeatMax = max(telemetrySourceFrameRepeatMax, sourceFrameRepeatCount)
        telemetrySourceFrameAgeMaxMs = max(telemetrySourceFrameAgeMaxMs, sourceFrameAgeMsAtSubmission)
        let forcedKeyFrame = pendingForcedKeyFrames > 0
        if forcedKeyFrame {
            pendingForcedKeyFrames -= 1
        }
        stateLock.unlock()
        return VideoEncodeRequest(
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: normalizedPresentationTimeStamp,
            duration: duration,
            submittedAtUptimeNanoseconds: submittedAtUptimeNanoseconds,
            sourceFrameGeneration: sourceFrameGeneration,
            sourceFrameRepeatCount: sourceFrameRepeatCount,
            sourceFrameAgeMsAtSubmission: sourceFrameAgeMsAtSubmission,
            forcedKeyFrame: forcedKeyFrame
        )
    }

    private func enqueueVideoEncodeRequest(_ request: VideoEncodeRequest) {
        noteVideoEncodeSubmissionQueued()
        videoEncodeSubmissionQueue.async { [weak self, request] in
            self?.encodePreparedVideoPixelBuffer(request)
        }
    }

    private func noteVideoEncodeSubmissionQueued() {
        stateLock.lock()
        videoEncodeSubmissionBacklog += 1
        telemetryEncodeSubmissionBacklogMax = max(
            telemetryEncodeSubmissionBacklogMax,
            videoEncodeSubmissionBacklog
        )
        stateLock.unlock()
    }

    private func noteVideoEncodeSubmissionStarted(submittedAtUptimeNanoseconds: UInt64) {
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        let delayMs = nowNanos >= submittedAtUptimeNanoseconds
            ? Double(nowNanos - submittedAtUptimeNanoseconds) / 1_000_000.0
            : 0
        stateLock.lock()
        telemetryEncodeSubmissionDelayMaxMs = max(
            telemetryEncodeSubmissionDelayMaxMs,
            delayMs
        )
        stateLock.unlock()
    }

    private func noteVideoEncodeSubmissionFinished() {
        stateLock.lock()
        videoEncodeSubmissionBacklog = max(0, videoEncodeSubmissionBacklog - 1)
        stateLock.unlock()
    }

    private func encodePreparedVideoPixelBuffer(_ request: VideoEncodeRequest) {
        noteVideoEncodeSubmissionStarted(
            submittedAtUptimeNanoseconds: request.submittedAtUptimeNanoseconds
        )
        defer {
            noteVideoEncodeSubmissionFinished()
        }

        var flags = VTEncodeInfoFlags()
        let frameProperties: CFDictionary? = request.forcedKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: kCFBooleanTrue as Any] as CFDictionary
            : nil
        let encodeTimingRefcon = Self.makeEncodeFrameTimingRefcon(
            submittedAtUptimeNanoseconds: request.submittedAtUptimeNanoseconds,
            presentationTimeStamp: request.presentationTimeStamp,
            duration: request.duration,
            sourceFrameGeneration: request.sourceFrameGeneration,
            sourceFrameRepeatCount: request.sourceFrameRepeatCount,
            sourceFrameAgeMsAtSubmission: request.sourceFrameAgeMsAtSubmission,
            forcedKeyFrame: request.forcedKeyFrame
        )
        compressionSessionLock.lock()
        guard let cs = compressionSession else {
            compressionSessionLock.unlock()
            _ = Self.consumeEncodeFrameTimingRefcon(encodeTimingRefcon)
            return
        }
        let status = VTCompressionSessionEncodeFrame(
            cs,
            imageBuffer: request.pixelBuffer,
            presentationTimeStamp: request.presentationTimeStamp,
            duration: request.duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: encodeTimingRefcon,
            infoFlagsOut: &flags
        )
        compressionSessionLock.unlock()
        if status != noErr {
            let timing = Self.consumeEncodeFrameTimingRefcon(encodeTimingRefcon)
            noteEncodeFrameFailed()
            let statusCode = Int(status)
            let issue = "encode-status-\(statusCode)"
            let encoderFields = encoderFailureContextSmokeFields()
            RemoteControlSmokeStatusWriter.append(
                """
                mac-sck-encode-failed targetFPS=\(configuredFPS) codec=\(codecType == kCMVideoCodecType_HEVC ? "hevc" : "h264") \
                status=\(statusCode) flags=\(flags.rawValue) \(Self.encodeTimingSmokeFields(timing)) \
                \(encoderFields) videoOutput=\(captureVideoOutput) capturesAudio=\(captureSystemAudio)
                """
            )
            logger.error(
                "❌ VTCompressionSessionEncodeFrame failed: status=\(status, privacy: .public) flags=\(flags.rawValue, privacy: .public)"
            )
            if failFastOnMediaFallbacks,
               captureVideoOutput,
               codecType == kCMVideoCodecType_HEVC {
                reportStrictMediaFailure(
                    issue: "strict-video-encode-failed",
                    detail: "VTCompressionSessionEncodeFrame status=\(statusCode),\(Self.encodeTimingSmokeFields(timing)),\(encoderFields)"
                )
            } else {
                onCaptureIssue?(issue)
            }
        }
    }

    private func encodeCadenceFrameIfAvailable(from _: CMSampleBuffer) -> Bool {
        guard shouldEmitIdleVideoFrames,
              let pixelBufferSnapshot = latestVideoPixelBufferSnapshotForCadence() else {
            return false
        }
        let submissionTargets = cadenceSubmissionTargetUptimes(nowNanos: DispatchTime.now().uptimeNanoseconds)
        noteDisplayCadenceSubmissionEvent(submittedFrames: submissionTargets.count, countTimerFire: false)
        guard !submissionTargets.isEmpty else { return false }
        for submissionTarget in submissionTargets {
            encodeVideoPixelBuffer(
                pixelBufferSnapshot.pixelBuffer,
                presentationTimeStamp: Self.presentationTimeFromUptimeNanoseconds(submissionTarget),
                duration: Self.encodeFrameDuration(forConfiguredFPS: configuredFPS),
                submittedAtUptimeNanoseconds: submissionTarget,
                sourceFrameGeneration: pixelBufferSnapshot.generation
            )
        }
        return true
    }

    private func handleCompressedSample(
        _ sampleBuffer: CMSampleBuffer,
        encodeLatencyMs: Double?,
        actualEncodeLatencyMs: Double?
    ) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let totalLength = CMBlockBufferGetDataLength(dataBuffer)
        guard totalLength > 0 else { return }

        var payload = Data(count: totalLength)
        let copyStatus = payload.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                return kCMBlockBufferBadCustomBlockSourceErr
            }
            return CMBlockBufferCopyDataBytes(
                dataBuffer,
                atOffset: 0,
                dataLength: totalLength,
                destination: base
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        if bitstreamFormat == .annexB {
            guard let annexBPayload = annexBPayload(from: sampleBuffer, payload: payload) else {
                return
            }
            payload = annexBPayload
        }

        let type: RemoteFrameType = (codecType == kCMVideoCodecType_HEVC) ? .hevc : .h264
        let format = Self.wireFormatName(for: type)
        let vtAdvertisedSync = isSyncSample(sampleBuffer)
        let verifiedSync = RemoteDesktopScreenFrameWire.containsSyncFrame(
            format: format,
            imageData: payload,
            advertisedSyncFrame: vtAdvertisedSync
        )
        emitFirstEncodedFrameTraceIfNeeded(
            format: format,
            payloadBytes: payload.count,
            vtAdvertisedSync: vtAdvertisedSync,
            verifiedSync: verifiedSync
        )
        noteEncodedFrameEmitted(
            encodedBytes: payload.count,
            isSyncFrame: verifiedSync,
            encodeLatencyMs: encodeLatencyMs,
            actualEncodeLatencyMs: actualEncodeLatencyMs
        )
        onEncodedFrame?(payload, visibleWidth, visibleHeight, type, verifiedSync)
    }

    private static func wireFormatName(for type: RemoteFrameType) -> String {
        switch type {
        case .hevc: return "hevc"
        case .h264: return "h264"
        case .bgra: return "bgra"
        }
    }

    private func emitFirstEncodedFrameTraceIfNeeded(
        format: String,
        payloadBytes: Int,
        vtAdvertisedSync: Bool,
        verifiedSync: Bool
    ) {
        stateLock.lock()
        guard !hasEmittedFirstEncodedFrameTrace else {
            stateLock.unlock()
            return
        }
        hasEmittedFirstEncodedFrameTrace = true
        firstFrameWatchdogGeneration += 1
        let encodedWidth = width
        let encodedHeight = height
        let frameVisibleWidth = visibleWidth
        let frameVisibleHeight = visibleHeight
        stateLock.unlock()

        RemoteControlSmokeStatusWriter.append(
            """
            mac-sck-first-frame codec=\(format) encoded=\(encodedWidth)x\(encodedHeight) \
            visible=\(frameVisibleWidth)x\(frameVisibleHeight) bytes=\(payloadBytes) \
            vtSync=\(vtAdvertisedSync) verifiedSync=\(verifiedSync)
            """
        )
    }

    private func shouldEmitDegradedFallbackJPEG(now: Date = Date()) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let minimumInterval = 1.0 / Double(max(1, jpegFallbackProfile.targetFrameRate))
        guard now.timeIntervalSince(lastDegradedFallbackJPEGAt) >= minimumInterval else {
            return false
        }
        lastDegradedFallbackJPEGAt = now
        return true
    }

    private func annexBPayload(from sampleBuffer: CMSampleBuffer, payload: Data) -> Data? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        let headerLength = max(1, nalUnitHeaderLength(from: formatDescription))
        guard headerLength <= 4 else { return nil }

        let pendingParameterSetReannounce = consumePendingParameterSetReannounce()
        let shouldPrependParameterSets =
            isSyncSample(sampleBuffer)
            || !hasEmittedParameterSets
            || pendingParameterSetReannounce
        var output = Data()
        if shouldPrependParameterSets,
           let parameterSets = parameterSetsAnnexB(from: formatDescription),
           !parameterSets.isEmpty {
            output.append(parameterSets)
            hasEmittedParameterSets = true
        }

        var offset = 0
        while offset + headerLength <= payload.count {
            var nalLength = 0
            for byte in payload[offset..<(offset + headerLength)] {
                nalLength = (nalLength << 8) | Int(byte)
            }
            offset += headerLength
            guard nalLength > 0, offset + nalLength <= payload.count else {
                return output.isEmpty ? nil : output
            }
            output.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            output.append(payload[offset..<(offset + nalLength)])
            offset += nalLength
        }

        guard offset == payload.count, !output.isEmpty else {
            return nil
        }
        return output
    }

    private func nalUnitHeaderLength(from formatDescription: CMFormatDescription) -> Int {
        switch codecType {
        case kCMVideoCodecType_H264:
            var nalUnitHeaderLength: Int32 = 4
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: &nalUnitHeaderLength
            )
            return status == noErr ? Int(nalUnitHeaderLength) : 4
        case kCMVideoCodecType_HEVC:
            var nalUnitHeaderLength: Int32 = 4
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: &nalUnitHeaderLength
            )
            return status == noErr ? Int(nalUnitHeaderLength) : 4
        default:
            return 4
        }
    }

    private func parameterSetsAnnexB(from formatDescription: CMFormatDescription) -> Data? {
        switch codecType {
        case kCMVideoCodecType_H264:
            return h264ParameterSetsAnnexB(from: formatDescription)
        case kCMVideoCodecType_HEVC:
            return hevcParameterSetsAnnexB(from: formatDescription)
        default:
            return nil
        }
    }

    private func h264ParameterSetsAnnexB(from formatDescription: CMFormatDescription) -> Data? {
        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 4
        let countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        guard countStatus == noErr, parameterSetCount > 0 else { return nil }

        var output = Data()
        for index in 0..<parameterSetCount {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer, size > 0 else { continue }
            output.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            output.append(pointer, count: size)
        }
        return output.isEmpty ? nil : output
    }

    private func hevcParameterSetsAnnexB(from formatDescription: CMFormatDescription) -> Data? {
        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 4
        let countStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        guard countStatus == noErr, parameterSetCount > 0 else { return nil }

        var output = Data()
        for index in 0..<parameterSetCount {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer, size > 0 else { continue }
            output.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            output.append(pointer, count: size)
        }
        return output.isEmpty ? nil : output
    }

    private func isSyncSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]],
        let firstAttachment = attachments.first else {
            return true
        }
        let notSync = (firstAttachment[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        return !notSync
    }

    private func handleJPEGPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        var cgImage: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        guard status == noErr, let cgImage else { return }
        guard let encoded = Self.encodeDegradedFallbackJPEG(
            from: cgImage,
            profile: jpegFallbackProfile
        ) else { return }

        // 复用 onEncodedFrame：frameType 用 .bgra 标记“非 H26x”，上层可按 magic 判断是否 JPEG
        noteEncodedFrameEmitted(encodedBytes: encoded.data.count, isSyncFrame: true)
        onEncodedFrame?(
            encoded.data,
            encoded.image.width,
            encoded.image.height,
            .bgra,
            true
        )
    }

    private func emitDamageReportIfAvailable(
        sampleBuffer: CMSampleBuffer,
        pixelBuffer: CVPixelBuffer
    ) {
        guard let report = damageReport(from: sampleBuffer, pixelBuffer: pixelBuffer) else { return }
        onDamageReport?(report)
        guard shouldTreatDamageAsSceneCut(report, pixelBuffer: pixelBuffer) else { return }
        Task { @MainActor [weak self] in
            self?.requestSceneCutRecovery(
                reason: report.fullFrameFallback ? "full-frame-damage" : "damage-surge"
            )
        }
    }

    private func shouldTreatDamageAsSceneCut(
        _ report: RemoteDesktopDamageReport,
        pixelBuffer: CVPixelBuffer
    ) -> Bool {
        if report.fullFrameFallback {
            return false
        }

        let totalArea = Double(max(CVPixelBufferGetWidth(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer), 1))
        let dirtyArea = min(
            totalArea,
            report.rects.reduce(0.0) { partial, rect in
                partial + max(rect.width, 0) * max(rect.height, 0)
            }
        )
        let dirtyCoverage = dirtyArea / totalArea
        return dirtyCoverage >= 0.45 || report.rects.count >= 18
    }

    private func damageReport(
        from sampleBuffer: CMSampleBuffer,
        pixelBuffer: CVPixelBuffer
    ) -> RemoteDesktopDamageReport? {
        guard let attachments = sampleAttachments(from: sampleBuffer) else {
            return fallbackDamageReport(for: pixelBuffer)
        }

        if let statusNumber = attachments[SCStreamFrameInfo.status] as? NSNumber,
           let status = SCFrameStatus(rawValue: statusNumber.intValue) {
            switch status {
            case .idle, .blank, .suspended, .stopped:
                return nil
            case .started:
                return fallbackDamageReport(for: pixelBuffer)
            case .complete:
                break
            @unknown default:
                break
            }
        }

        if let dirtyValues = attachments[SCStreamFrameInfo.dirtyRects] as? [NSValue] {
            let pixelBounds = CGRect(
                x: 0,
                y: 0,
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
            let rects = normalizedDamageRects(
                dirtyValues.map { $0.rectValue },
                pixelBounds: pixelBounds
            )
            if !rects.isEmpty {
                return RemoteDesktopDamageReport(rects: rects.map(Self.damageRect(from:)))
            }
        }

        if let rectValue = attachments[SCStreamFrameInfo.boundingRect] as? NSValue
            ?? attachments[SCStreamFrameInfo.contentRect] as? NSValue {
            let pixelBounds = CGRect(
                x: 0,
                y: 0,
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
            let rect = rectValue.rectValue.intersection(pixelBounds).integral
            if !rect.isNull, !rect.isEmpty {
                return RemoteDesktopDamageReport(rects: [Self.damageRect(from: rect)])
            }
        }

        return fallbackDamageReport(for: pixelBuffer)
    }

    private func sampleAttachments(from sampleBuffer: CMSampleBuffer) -> [SCStreamFrameInfo: Any]? {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]] else {
            return nil
        }
        return array.first
    }

    private func frameStatus(from sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = sampleAttachments(from: sampleBuffer),
              let statusNumber = attachments[SCStreamFrameInfo.status] as? NSNumber else {
            return nil
        }
        return SCFrameStatus(rawValue: statusNumber.intValue)
    }

    private var shouldEmitIdleVideoFrames: Bool {
        !jpegMode && onEncodedFrame != nil && configuredFPS >= 30
    }

    private func fallbackDamageReport(for pixelBuffer: CVPixelBuffer) -> RemoteDesktopDamageReport {
        let rect = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        return RemoteDesktopDamageReport(
            rects: [Self.damageRect(from: rect)],
            fullFrameFallback: true
        )
    }

    private func normalizedDamageRects(
        _ rects: [CGRect],
        pixelBounds: CGRect
    ) -> [CGRect] {
        let normalized = rects
            .map { $0.intersection(pixelBounds).integral }
            .filter { !$0.isNull && !$0.isEmpty && $0.width >= 1 && $0.height >= 1 }

        guard !normalized.isEmpty else { return [] }
        if normalized.count <= 12 {
            return normalized
        }
        return [normalized.reduce(normalized[0]) { $0.union($1) }]
    }

    private static func damageRect(from rect: CGRect) -> RemoteDesktopDamageRect {
        RemoteDesktopDamageRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.width,
            height: rect.height
        )
    }

 /// SCStream 输出桥接
 /// 18.2: guard let 处理 stream output (Requirements 8.2, 8.3)
    private final class StreamOutput: NSObject, SCStreamOutput {
        weak var owner: ScreenCaptureKitStreamer?
        init(owner: ScreenCaptureKitStreamer) { self.owner = owner }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
            autoreleasepool {
                guard let owner = owner else { return }
                switch outputType {
                case .screen:
                    guard owner.captureVideoOutput else { return }
                    owner.noteSampleBufferReceived()
                    let frameStatus = owner.frameStatus(from: sampleBuffer)
                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                        if ScreenCaptureKitStreamer.shouldReuseLatestFrameForCadence(with: frameStatus) {
                            _ = owner.encodeCadenceFrameIfAvailable(from: sampleBuffer)
                        }
                        return
                    }
                    guard ScreenCaptureKitStreamer.shouldProcessFrame(
                        with: frameStatus,
                        includeIdleFrames: owner.shouldEmitIdleVideoFrames
                    ) else {
                        if ScreenCaptureKitStreamer.shouldReuseLatestFrameForCadence(with: frameStatus) {
                            _ = owner.encodeCadenceFrameIfAvailable(from: sampleBuffer)
                        }
                        return
                    }
                    owner.noteMeaningfulSampleReceived()
                    let sourceFrameGeneration = owner.rememberLatestVideoPixelBuffer(pixelBuffer)
                    owner.emitDamageReportIfAvailable(sampleBuffer: sampleBuffer, pixelBuffer: pixelBuffer)
                    if owner.shouldUseDisplayCadenceEncoder {
                        owner.scheduleDisplayCadenceEncode()
                        return
                    }

                    if owner.onRawFrame != nil {
                        owner.noteEncodedFrameEmitted(countForTelemetry: false)
                        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        let delivery = RawFrameDelivery(pixelBuffer: pixelBuffer, presentationTime: pts)
                        owner.rawFrameOutputQueue.async { [weak owner, delivery] in
                            guard let owner, let onRawFrame = owner.onRawFrame else { return }
                            autoreleasepool {
                                onRawFrame(delivery.pixelBuffer, delivery.presentationTime)
                            }
                        }
                    }

                    if owner.emitsDegradedFallbackJPEGFrames,
                       owner.shouldEmitDegradedFallbackJPEG() {
                        owner.handleJPEGPixelBuffer(pixelBuffer)
                    }

                    if owner.jpegMode {
                        owner.handleJPEGPixelBuffer(pixelBuffer)
                        return
                    }

                    owner.encodeVideoPixelBuffer(
                        pixelBuffer,
                        presentationTimeStamp: ScreenCaptureKitStreamer.encodePresentationTimeStamp(from: sampleBuffer),
                        duration: ScreenCaptureKitStreamer.encodeFrameDuration(forConfiguredFPS: owner.configuredFPS),
                        sourceFrameGeneration: sourceFrameGeneration
                    )
                case .audio:
                    owner.handleAudioSampleBuffer(sampleBuffer)
                case .microphone:
                    return
                @unknown default:
                    return
                }
            }
        }
    }
}
