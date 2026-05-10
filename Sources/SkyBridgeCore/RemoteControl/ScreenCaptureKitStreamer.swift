import Foundation
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import VideoToolbox
import CoreVideo
import CoreGraphics
import AudioToolbox
import OSLog
import ImageIO
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

/// 使用 ScreenCaptureKit 捕获屏幕并通过 VideoToolbox 编码为 HEVC/H.264 的数据流
/// - 中文说明：该组件专注于本地屏幕采集与硬件加速编码，外部通过回调接收压缩后的视频帧数据。
struct ScreenCaptureTelemetrySnapshot: Sendable, Equatable {
    let interval: TimeInterval
    let capturedSamples: Int
    let meaningfulSamples: Int
    let encodedFrames: Int
    let encodedBytes: Int
    let targetFPS: Int
    let codec: String
    let width: Int
    let height: Int
    let capturesAudio: Bool
    let encodeLatencyP50Ms: Double?
    let encodeLatencyP95Ms: Double?
    let encodeLatencyMaxMs: Double?
    let encodeFailures: Int

    var captureFPS: Double { Double(capturedSamples) / max(interval, 0.001) }
    var meaningfulFPS: Double { Double(meaningfulSamples) / max(interval, 0.001) }
    var encodedFPS: Double { Double(encodedFrames) / max(interval, 0.001) }
}

final class ScreenCaptureKitStreamer: NSObject, @unchecked Sendable {
    enum EncodedBitstreamFormat: Sendable {
        case native
        case annexB
    }

    struct CaptureContextSnapshot: Sendable, Equatable {
        let displayID: CGDirectDisplayID
        let displayPixelSize: CGSize
        let streamSize: CGSize
        let captureCursorInVideo: Bool
    }

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "SCKStreamer")
    private var stream: SCStream?
    private var output: StreamOutput?
    private var compressionSession: VTCompressionSession?
    private var codecType: CMVideoCodecType = kCMVideoCodecType_HEVC
    private var width: Int = 1280
    private var height: Int = 720
    private var started = false
    private var configuredFPS: Int = 60
    private var configuredKeyInterval: Int = 60
    private var preferredProfile: EncodingProfile = .auto
    private var preferredQuality: VideoQuality = .high
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
    private var pendingForcedKeyFrames = 0
    private var pendingParameterSetReannounce = false
    private var capturedDisplayID: CGDirectDisplayID?
    private var capturedDisplayPixelSize: CGSize = .zero
    private let stateLock = NSLock()
    private var lastSampleBufferAt: Date = .distantPast
    private var lastMeaningfulSampleAt: Date = .distantPast
    private var lastEncodedFrameAt: Date = .distantPast
    private var lastDegradedFallbackJPEGAt: Date = .distantPast
    private var lastSceneCutRecoveryAt: Date = .distantPast
    private var latestVideoPixelBuffer: CVPixelBuffer?
    private var lastVideoEncodeSubmittedAtNanos: UInt64 = 0
    private var lastVideoPresentationTimeStamp: CMTime?
    private var videoCadenceTimer: DispatchSourceTimer?
    private var captureTelemetryWindowStartedAt = Date()
    private var telemetryCapturedSamples = 0
    private var telemetryMeaningfulSamples = 0
    private var telemetryEncodedFrames = 0
    private var telemetryEncodedBytes = 0
    private var telemetryEncodeLatenciesMs: [Double] = []
    private var telemetryEncodeFailures = 0
    private let sampleOutputQueue = DispatchQueue(
        label: "com.skybridge.compass.sck.output",
        qos: .userInteractive
    )
    private let videoCadenceQueue = DispatchQueue(
        label: "com.skybridge.compass.sck.video-cadence",
        qos: .userInteractive
    )
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

    private struct RawFrameDelivery: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let presentationTime: CMTime
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

    private final class CompressionCallbackContext {
        private let lock = NSLock()
        weak var streamer: ScreenCaptureKitStreamer?
        private var isActive = true

        init(streamer: ScreenCaptureKitStreamer) {
            self.streamer = streamer
        }

        func deactivate() {
            lock.lock()
            isActive = false
            lock.unlock()
        }

        func activeStreamer() -> ScreenCaptureKitStreamer? {
            lock.lock()
            defer { lock.unlock() }
            guard isActive else { return nil }
            return streamer
        }
    }

    private final class EncodeFrameTiming {
        let submittedAtUptimeNanoseconds: UInt64

        init(submittedAtUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
            self.submittedAtUptimeNanoseconds = submittedAtUptimeNanoseconds
        }
    }

    private final class AudioConversionInputState: @unchecked Sendable {
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
        bitstreamFormat: EncodedBitstreamFormat = .native
    ) async throws {
        guard !started else { return }
        started = true
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
        pendingForcedKeyFrames = 2
        pendingParameterSetReannounce = false
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
        lowLatencyEnabled = lowLatencyMode ?? settings.displaySettings.lowLatencyMode

 // 选择显示内容：优先使用当前主显示器，避免外接屏/切主屏后继续抓错源
        let content = try await SCShareableContent.current
        let mainDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first else {
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
        let normalizedSize = RemoteControlCaptureCompatibility.normalizedCaptureSize(
            captureSize,
            for: preferredCodec,
            preserveExactVisibleSize: preserveExactVisibleSize
        )
        width = Int(normalizedSize.width)
        height = Int(normalizedSize.height)
        if Int(requestedSize.width.rounded(.down)) != width || Int(requestedSize.height.rounded(.down)) != height {
            logger.info(
                """
                🎚️ 已调整远控采集尺寸以匹配编码器约束: requested=\(Int(requestedSize.width.rounded(.down)))x\(Int(requestedSize.height.rounded(.down))) \
                normalized=\(self.width)x\(self.height) codec=\(preferredCodec.rawValue, privacy: .public)
                """
            )
        }
        if !jpegMode {
            // 映射编码类型
            codecType = (preferredCodec == .h264) ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
        }

 // 创建输出对象与流配置
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA // 原始帧，后续由VTCompressionSession进行压缩
        configuration.minimumFrameInterval = Self.encodeFrameDuration(forConfiguredFPS: configuredFPS)
        configuration.queueDepth = Self.captureQueueDepth(
            lowLatencyEnabled: lowLatencyEnabled,
            targetFPS: configuredFPS,
            width: width,
            height: height
        )
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
                    bitstreamFormat: bitstreamFormat
                )
                return
            }
            throw error
        }
        startVideoCadenceTimerIfNeeded(captureVideoOutput: captureVideoOutput)
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
        stream?.stopCapture()
        stream = nil
        output = nil
        unregisterDisplayObservers()
        deactivateCompressionCallbackContext()
        if let cs = compressionSession {
            VTCompressionSessionCompleteFrames(cs, untilPresentationTimeStamp: CMTime.invalid)
            VTCompressionSessionInvalidate(cs)
        }
        compressionSession = nil
        releaseCompressionCallbackContext()
        hasEmittedParameterSets = false
        pendingForcedKeyFrames = 0
        pendingParameterSetReannounce = false
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
        stateLock.lock()
        lastSampleBufferAt = .distantPast
        lastMeaningfulSampleAt = .distantPast
        lastEncodedFrameAt = .distantPast
        stateLock.unlock()
        stopVideoCadenceTimer()
        stream?.stopCapture()
        stream = nil
        output = nil
        unregisterDisplayObservers()
        deactivateCompressionCallbackContext()
        if let cs = compressionSession {
            VTCompressionSessionCompleteFrames(cs, untilPresentationTimeStamp: CMTime.invalid)
            VTCompressionSessionInvalidate(cs)
        }
        compressionSession = nil
        releaseCompressionCallbackContext()
        hasEmittedParameterSets = false
        pendingForcedKeyFrames = 0
        pendingParameterSetReannounce = false
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
    func requestKeyFrameRefresh(reason: String, count: Int = 2) {
        let clampedCount = max(1, min(count, 4))
        stateLock.lock()
        pendingForcedKeyFrames = max(pendingForcedKeyFrames, clampedCount)
        stateLock.unlock()
        logger.info("🪄 请求关键帧刷新: \(reason, privacy: .public)")
    }

    @MainActor
    private func requestSceneCutRecovery(reason: String, count: Int = 3) {
        guard started else { return }
        let now = Date()
        var shouldTrigger = false
        let minimumInterval: TimeInterval = {
            if reason.contains("active-application") || reason.contains("active-space") {
                return 0.12
            }
            if reason.contains("display-parameters") {
                return 0.20
            }
            return 0.35
        }()
        stateLock.lock()
        if now.timeIntervalSince(lastSceneCutRecoveryAt) >= minimumInterval {
            lastSceneCutRecoveryAt = now
            pendingParameterSetReannounce = true
            shouldTrigger = true
        }
        stateLock.unlock()
        guard shouldTrigger else { return }
        requestKeyFrameRefresh(reason: "scene-cut-\(reason)", count: count)
        logger.info("🎬 检测到场景切换，已强制请求 IDR 与参数集重宣告: \(reason, privacy: .public)")
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
                    self.requestSceneCutRecovery(reason: "active-application-\(bundleIdentifier)", count: 4)
                } else {
                    self.requestSceneCutRecovery(reason: "active-application-changed", count: 4)
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
        }
        onCaptureIssue?(issue)
    }

    @MainActor
    private func handleDisplayConfigurationChange() {
        guard started else { return }

        let currentMainDisplayID = CGMainDisplayID()
        let currentPixelSize = displayPixelSize(for: currentMainDisplayID, fallback: .zero)

        if currentMainDisplayID != capturedDisplayID || currentPixelSize != capturedDisplayPixelSize {
            logger.info(
                "🔁 检测到主显示器/分辨率变化，准备重启采集: oldDisplay=\(String(self.capturedDisplayID ?? 0), privacy: .public) newDisplay=\(String(currentMainDisplayID), privacy: .public)"
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
            if failFastOnMediaFallbacks {
                reportStrictMediaFailure(
                    issue: "strict-video-codec-fallback-forbidden",
                    detail: "VTCompressionSessionCreate status \(createdSession.status)"
                )
                throw NSError(
                    domain: "com.skybridge.screencapturekit",
                    code: Int(createdSession.status),
                    userInfo: [
                        NSLocalizedDescriptionKey: "VTCompressionSessionCreate failed in strict media mode: \(createdSession.status)"
                    ]
                )
            }
            logger.error("VTCompressionSession 创建失败：\(createdSession.status)，切换到 H.264")
	 // 回退到 H.264
            let fallbackSession = makeCompressionSession(
                width: width,
                height: height,
                codec: kCMVideoCodecType_H264,
                encoderSpecification: Self.videoEncoderSpecification(
                    codec: kCMVideoCodecType_H264,
                    lowLatencyMode: lowLatencyEnabled,
                    requiresHardwareEncoder: false,
                    preferredProfile: preferredProfile
                )
            )
            guard fallbackSession.status == noErr, let cs2 = fallbackSession.session else {
                Self.releaseCompressionCallbackRefcon(fallbackSession.callbackRefcon)
                throw CocoaError(.featureUnsupported)
            }
            compressionSession = cs2
            compressionCallbackRefcon = fallbackSession.callbackRefcon
            codecType = kCMVideoCodecType_H264
        } else {
            compressionSession = createdSession.session
            compressionCallbackRefcon = createdSession.callbackRefcon
        }

        guard let cs = compressionSession else { throw CocoaError(.featureUnsupported) }

 // 编码参数：实时、低延迟、目标帧率
 // 根据设置的编码档位选择 ProfileLevel（使用在 start 中捕获的值）
        let profile = preferredProfile
        let lowLatencyRateControlEnabled = Self.shouldEnableLowLatencyRateControl(
            codec: codecType,
            lowLatencyMode: lowLatencyEnabled,
            preferredProfile: profile
        )
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
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(
            cs,
            key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            value: prioritizeEncodingSpeed ? kCFBooleanTrue : kCFBooleanFalse
        )
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 1))
        if codecType == kCMVideoCodecType_H264 {
            VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
        }
 // 低延迟模式：缩短关键帧间隔
        let keyInterval = lowLatencyEnabled ? max(10, min(configuredKeyInterval, 30)) : configuredKeyInterval
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: keyInterval))
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: lowLatencyEnabled ? 0.5 : 1.0))
        VTSessionSetProperty(
            cs,
            key: kVTCompressionPropertyKey_Quality,
            value: NSNumber(
                value: effectiveCompressionQuality(
                    width: width,
                    height: height,
                    fps: configuredFPS,
                    prioritizeEncodingSpeed: prioritizeEncodingSpeed
                )
            )
        )
        let averageBitRate = targetAverageBitRate(codec: codecType, width: width, height: height, fps: configuredFPS)
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: averageBitRate))
        let hardLimitBytesPerSecond = max(Int(Double(averageBitRate) * 1.35 / 8.0), 512_000)
        VTSessionSetProperty(
            cs,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: [NSNumber(value: hardLimitBytesPerSecond), NSNumber(value: 1)] as CFArray
        )

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
                    sampleBuffer: sampleBuffer
                )
            },
            refcon: callbackRefcon,
            compressionSessionOut: &session
        )
        return (status, session, callbackRefcon)
    }

    static func videoEncoderSpecification(
        codec: CMVideoCodecType,
        lowLatencyMode: Bool,
        requiresHardwareEncoder: Bool,
        preferredProfile: EncodingProfile
    ) -> CFDictionary? {
        var specification: [String: Any] = [:]
        if requiresHardwareEncoder {
            specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] = kCFBooleanTrue
        }
        if shouldEnableLowLatencyRateControl(
            codec: codec,
            lowLatencyMode: lowLatencyMode,
            preferredProfile: preferredProfile
        ) {
            specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String] = kCFBooleanTrue
        }
        return specification.isEmpty ? nil : specification as CFDictionary
    }

    static func shouldEnableLowLatencyRateControl(
        codec: CMVideoCodecType,
        lowLatencyMode: Bool,
        preferredProfile: EncodingProfile
    ) -> Bool {
        guard codec == kCMVideoCodecType_H264,
              lowLatencyMode else {
            return false
        }
        switch preferredProfile {
        case .auto, .h264High:
            return true
        case .h264Baseline, .h264Main, .hevcMain:
            return false
        }
    }

    private func compressionQualityValue() -> Float {
        switch preferredQuality {
        case .low: return 0.45
        case .medium: return 0.6
        case .high: return 0.78
        case .ultra: return 0.92
        }
    }

    private func effectiveCompressionQuality(
        width: Int,
        height: Int,
        fps: Int,
        prioritizeEncodingSpeed: Bool
    ) -> Float {
        var quality = compressionQualityValue()
        let megapixels = Double(max(width * height, 1)) / 1_000_000.0

        if prioritizeEncodingSpeed {
            if megapixels >= 2.5 || fps >= 60 {
                quality = min(quality, 0.52)
            } else {
                quality = min(quality, 0.60)
            }
        } else if megapixels >= 4.0 {
            quality = min(quality, 0.68)
        }

        return quality
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

        let rawBitRate = Int((pixelsPerSecond * bitsPerPixelPerFrame).rounded())
        let minimum = codec == kCMVideoCodecType_HEVC ? 6_000_000 : 10_000_000
        let maximum = codec == kCMVideoCodecType_HEVC ? 55_000_000 : 80_000_000
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

    private static func makeEncodeFrameTimingRefcon() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(Unmanaged.passRetained(EncodeFrameTiming()).toOpaque())
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

    private static func handleCompressionCallback(
        refcon: UnsafeMutableRawPointer?,
        sourceFrameRefCon: UnsafeMutableRawPointer?,
        status: OSStatus,
        sampleBuffer: CMSampleBuffer?
    ) {
        let timing = consumeEncodeFrameTimingRefcon(sourceFrameRefCon)
        let encodeLatencyMs = encodeLatencyMilliseconds(from: timing)
        guard let refcon else { return }
        let unmanaged = Unmanaged<CompressionCallbackContext>.fromOpaque(refcon)
        _ = unmanaged.retain()
        let context = unmanaged.takeUnretainedValue()
        defer { unmanaged.release() }
        guard let streamer = context.activeStreamer() else { return }
        guard status == noErr, let sampleBuffer else {
            streamer.noteEncodeFrameFailed()
            return
        }
        autoreleasepool {
            streamer.handleCompressedSample(sampleBuffer, encodeLatencyMs: encodeLatencyMs)
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

    static func encodePresentationTimeStamp(from sampleBuffer: CMSampleBuffer) -> CMTime {
        CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    }

    static func encodeFrameDuration(forConfiguredFPS fps: Int) -> CMTime {
        CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
    }

    static func captureQueueDepth(
        lowLatencyEnabled: Bool,
        targetFPS: Int,
        width: Int,
        height: Int
    ) -> Int {
        let pixelCount = max(width, 1) * max(height, 1)
        let highFrameRate = targetFPS >= 55
        let highResolution = pixelCount >= 2_000_000
        let depth: Int
        if highFrameRate && highResolution {
            depth = lowLatencyEnabled ? 6 : 7
        } else if highFrameRate {
            depth = lowLatencyEnabled ? 4 : 5
        } else {
            depth = lowLatencyEnabled ? 3 : 5
        }
        return min(8, max(1, depth))
    }

    static func shouldRunDisplayCadenceEncoder(
        jpegMode: Bool,
        hasEncodedFrameSink: Bool,
        targetFPS: Int
    ) -> Bool {
        !jpegMode && hasEncodedFrameSink && targetFPS >= 55
    }

    static func shouldRegisterScreenOutput(
        captureVideoOutput: Bool,
        requestedSystemAudio: Bool
    ) -> Bool {
        // ScreenCaptureKit still drives a display stream for audio capture. Register a
        // screen output for audio-only streams so SCK does not drop internal video queue frames.
        captureVideoOutput || requestedSystemAudio
    }

    static func presentationTimeFromUptimeNanoseconds(_ nanoseconds: UInt64) -> CMTime {
        let clamped = min(nanoseconds, UInt64(Int64.max))
        return CMTime(value: CMTimeValue(clamped), timescale: 1_000_000_000)
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
        encodeLatencyMs: Double? = nil
    ) {
        let now = Date()
        let snapshot: ScreenCaptureTelemetrySnapshot?
        stateLock.lock()
        lastEncodedFrameAt = now
        if countForTelemetry {
            telemetryEncodedFrames += 1
            telemetryEncodedBytes += max(0, encodedBytes)
            if let encodeLatencyMs {
                telemetryEncodeLatenciesMs.append(max(0, encodeLatencyMs))
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
        telemetryEncodeLatenciesMs = []
        telemetryEncodeFailures = 0
        stateLock.unlock()
    }

    private func resetVideoCadenceState() {
        stateLock.lock()
        lastVideoEncodeSubmittedAtNanos = 0
        lastVideoPresentationTimeStamp = nil
        stateLock.unlock()
    }

    private func rememberLatestVideoPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        stateLock.lock()
        latestVideoPixelBuffer = pixelBuffer
        stateLock.unlock()
    }

    private func latestVideoPixelBufferForCadence() -> CVPixelBuffer? {
        stateLock.lock()
        let pixelBuffer = latestVideoPixelBuffer
        stateLock.unlock()
        return pixelBuffer
    }

    private func clearLatestVideoPixelBuffer() {
        stateLock.lock()
        latestVideoPixelBuffer = nil
        stateLock.unlock()
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
              compressionSession != nil else {
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

    private func scheduleDisplayCadenceEncode() {
        videoCadenceQueue.async { [weak self] in
            self?.encodeDisplayCadenceFrameIfDue()
        }
    }

    private static func frameIntervalNanoseconds(forConfiguredFPS fps: Int) -> UInt64 {
        max(1, 1_000_000_000 / UInt64(max(1, fps)))
    }

    static func cadenceTimerIntervalNanoseconds(forConfiguredFPS fps: Int) -> UInt64 {
        let frameInterval = frameIntervalNanoseconds(forConfiguredFPS: fps)
        return fps >= 55 ? max(1, frameInterval / 2) : frameInterval
    }

    private func encodeDisplayCadenceFrameIfDue() {
        guard shouldUseDisplayCadenceEncoder,
              compressionSession != nil,
              let pixelBuffer = latestVideoPixelBufferForCadence() else {
            return
        }
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        let submissionTargets = cadenceSubmissionTargetUptimes(nowNanos: nowNanos)
        guard !submissionTargets.isEmpty else { return }
        for submissionTarget in submissionTargets {
            encodeVideoPixelBuffer(
                pixelBuffer,
                presentationTimeStamp: Self.presentationTimeFromUptimeNanoseconds(submissionTarget),
                duration: Self.encodeFrameDuration(forConfiguredFPS: configuredFPS),
                submittedAtUptimeNanoseconds: submissionTarget
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
            maxCatchUpFrames: configuredFPS >= 55 ? 3 : 1
        )
    }

    static func cadenceSubmissionTargetUptimes(
        lastSubmittedAt: UInt64,
        nowNanos: UInt64,
        configuredFPS fps: Int,
        maxCatchUpFrames: Int
    ) -> [UInt64] {
        _ = maxCatchUpFrames
        guard lastSubmittedAt > 0 else { return [nowNanos] }
        guard nowNanos >= lastSubmittedAt else { return [] }
        let frameIntervalNanos = frameIntervalNanoseconds(forConfiguredFPS: fps)
        let elapsed = nowNanos - lastSubmittedAt
        guard elapsed >= frameIntervalNanos else { return [] }
        let dueFrames = max(1, Int(elapsed / frameIntervalNanos))
        let latestDueFrame = lastSubmittedAt + (UInt64(dueFrames) * frameIntervalNanos)
        return [min(latestDueFrame, nowNanos)]
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

    private func captureTelemetrySnapshotIfNeeded(now: Date) -> ScreenCaptureTelemetrySnapshot? {
        let interval = now.timeIntervalSince(captureTelemetryWindowStartedAt)
        guard interval >= 1 else { return nil }
        let encodeLatencyPercentiles = Self.encodeLatencyPercentiles(telemetryEncodeLatenciesMs)
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
            capturesAudio: captureSystemAudio,
            encodeLatencyP50Ms: encodeLatencyPercentiles.p50,
            encodeLatencyP95Ms: encodeLatencyPercentiles.p95,
            encodeLatencyMaxMs: encodeLatencyPercentiles.max,
            encodeFailures: telemetryEncodeFailures
        )
        captureTelemetryWindowStartedAt = now
        telemetryCapturedSamples = 0
        telemetryMeaningfulSamples = 0
        telemetryEncodedFrames = 0
        telemetryEncodedBytes = 0
        telemetryEncodeLatenciesMs = []
        telemetryEncodeFailures = 0
        return snapshot
    }

    static func encodeLatencyPercentiles(_ values: [Double]) -> (
        p50: Double?,
        p95: Double?,
        max: Double?
    ) {
        guard !values.isEmpty else {
            return (nil, nil, nil)
        }
        let sorted = values.sorted()
        func value(at percentile: Double) -> Double {
            let clamped = min(max(percentile, 0), 1)
            let rawIndex = (Double(sorted.count - 1) * clamped).rounded(.up)
            let index = min(sorted.count - 1, max(0, Int(rawIndex)))
            return sorted[index]
        }
        return (value(at: 0.50), value(at: 0.95), sorted[sorted.count - 1])
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
        let encodeLatencyP50 = snapshot.encodeLatencyP50Ms.map { String(format: "%.2f", $0) } ?? "n/a"
        let encodeLatencyP95 = snapshot.encodeLatencyP95Ms.map { String(format: "%.2f", $0) } ?? "n/a"
        let encodeLatencyMax = snapshot.encodeLatencyMaxMs.map { String(format: "%.2f", $0) } ?? "n/a"
        logger.info(
            """
            📊 SCK tx telemetry: targetFPS=\(snapshot.targetFPS, privacy: .public) \
            codec=\(snapshot.codec, privacy: .public) \
            size=\(snapshot.width, privacy: .public)x\(snapshot.height, privacy: .public) \
            capturesAudio=\(String(snapshot.capturesAudio), privacy: .public) \
            captureFPS=\(captureFPS, privacy: .public) \
            meaningfulFPS=\(meaningfulFPS, privacy: .public) \
            encodedFPS=\(encodedFPS, privacy: .public) \
            encodedBytes=\(snapshot.encodedBytes, privacy: .public) \
            encodeLatencyP50Ms=\(encodeLatencyP50, privacy: .public) \
            encodeLatencyP95Ms=\(encodeLatencyP95, privacy: .public) \
            encodeLatencyMaxMs=\(encodeLatencyMax, privacy: .public) \
            encodeFailures=\(snapshot.encodeFailures, privacy: .public)
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
        submittedAtUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        guard let cs = compressionSession else { return }
        var flags = VTEncodeInfoFlags()
        let encodeTimingRefcon = Self.makeEncodeFrameTimingRefcon()
        let normalizedPresentationTimeStamp = nextVideoPresentationTimeStamp(
            preferred: presentationTimeStamp,
            duration: duration,
            submittedAtUptimeNanoseconds: submittedAtUptimeNanoseconds
        )
        let status = VTCompressionSessionEncodeFrame(
            cs,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: normalizedPresentationTimeStamp,
            duration: duration,
            frameProperties: nextFramePropertiesForEncode(),
            sourceFrameRefcon: encodeTimingRefcon,
            infoFlagsOut: &flags
        )
        if status != noErr {
            _ = Self.consumeEncodeFrameTimingRefcon(encodeTimingRefcon)
            noteEncodeFrameFailed()
            logger.error("❌ VTCompressionSessionEncodeFrame failed: status=\(status, privacy: .public)")
            onCaptureIssue?("encode-status-\(status)")
        }
    }

    private func encodeCadenceFrameIfAvailable(from sampleBuffer: CMSampleBuffer) -> Bool {
        guard shouldEmitIdleVideoFrames,
              let pixelBuffer = latestVideoPixelBufferForCadence() else {
            return false
        }
        let submissionTargets = cadenceSubmissionTargetUptimes(nowNanos: DispatchTime.now().uptimeNanoseconds)
        guard let submissionTarget = submissionTargets.first else { return false }
        encodeVideoPixelBuffer(
            pixelBuffer,
            presentationTimeStamp: Self.encodePresentationTimeStamp(from: sampleBuffer),
            duration: Self.encodeFrameDuration(forConfiguredFPS: configuredFPS),
            submittedAtUptimeNanoseconds: submissionTarget
        )
        return true
    }

    private func handleCompressedSample(_ sampleBuffer: CMSampleBuffer, encodeLatencyMs: Double?) {
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
        noteEncodedFrameEmitted(encodedBytes: payload.count, encodeLatencyMs: encodeLatencyMs)
        onEncodedFrame?(payload, width, height, type, isSyncSample(sampleBuffer))
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

        let shouldPrependParameterSets =
            isSyncSample(sampleBuffer)
            || !hasEmittedParameterSets
            || consumePendingParameterSetReannounce()
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

    static func encodeDegradedFallbackJPEG(
        from cgImage: CGImage,
        profile: WebRTCDegradedFallbackJPEGProfile = .emergency
    ) -> (image: CGImage, data: Data, quality: CGFloat)? {
        let primary = scaledImageForDegradedJPEG(
            cgImage,
            maxLongEdge: profile.maxLongEdge
        ) ?? cgImage
        let candidateImages: [CGImage]
        if profile.maxLongEdge > WebRTCDegradedFallbackJPEGProfile.secondaryLongEdge,
           max(primary.width, primary.height) > WebRTCDegradedFallbackJPEGProfile.secondaryLongEdge,
           let secondary = scaledImageForDegradedJPEG(
                primary,
                maxLongEdge: WebRTCDegradedFallbackJPEGProfile.secondaryLongEdge
           ) {
            candidateImages = [primary, secondary]
        } else {
            candidateImages = [primary]
        }

        for candidate in candidateImages {
            for quality in profile.qualityLadder {
                guard let data = jpegData(from: candidate, quality: quality) else { continue }
                if data.count <= profile.maxEncodedFrameBytes {
                    return (image: candidate, data: data, quality: quality)
                }
            }
        }
        return nil
    }

    static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(
            dest,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func scaledImageForDegradedJPEG(_ image: CGImage, maxLongEdge: Int) -> CGImage? {
        func evenDimension(_ value: Int) -> Int {
            let clamped = max(2, value)
            return clamped.isMultiple(of: 2) ? clamped : clamped - 1
        }
        guard maxLongEdge > 0 else { return image }
        let sourceMaxEdge = max(image.width, image.height)
        guard sourceMaxEdge > maxLongEdge else { return image }
        let scale = CGFloat(maxLongEdge) / CGFloat(sourceMaxEdge)
        let width = evenDimension(Int((CGFloat(image.width) * scale).rounded()))
        let height = evenDimension(Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
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
        noteEncodedFrameEmitted(encodedBytes: encoded.data.count)
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
                reason: report.fullFrameFallback ? "full-frame-damage" : "damage-surge",
                count: report.fullFrameFallback ? 4 : 3
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

    static func shouldProcessFrame(
        with status: SCFrameStatus?,
        includeIdleFrames: Bool = false
    ) -> Bool {
        guard let status else { return true }
        switch status {
        case .idle:
            return includeIdleFrames
        case .blank, .suspended, .stopped:
            return false
        case .started, .complete:
            return true
        @unknown default:
            return false
        }
    }

    static func shouldReuseLatestFrameForCadence(with status: SCFrameStatus?) -> Bool {
        status == .idle
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
                    owner.rememberLatestVideoPixelBuffer(pixelBuffer)
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
                        duration: ScreenCaptureKitStreamer.encodeFrameDuration(forConfiguredFPS: owner.configuredFPS)
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
