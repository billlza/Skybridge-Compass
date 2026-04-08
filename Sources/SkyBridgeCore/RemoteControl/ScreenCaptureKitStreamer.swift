import Foundation
@preconcurrency import ScreenCaptureKit
import VideoToolbox
import CoreVideo
import CoreGraphics
import OSLog
import ImageIO
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

/// 使用 ScreenCaptureKit 捕获屏幕并通过 VideoToolbox 编码为 HEVC/H.264 的数据流
/// - 中文说明：该组件专注于本地屏幕采集与硬件加速编码，外部通过回调接收压缩后的视频帧数据。
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
    private var bitstreamFormat: EncodedBitstreamFormat = .native
    private var captureCursorInVideo = true
    private var hasEmittedParameterSets = false
    private var pendingForcedKeyFrames = 0
    private var pendingParameterSetReannounce = false
    private var capturedDisplayID: CGDirectDisplayID?
    private var capturedDisplayPixelSize: CGSize = .zero
    private let stateLock = NSLock()
    private var lastSampleBufferAt: Date = .distantPast
    private var lastMeaningfulSampleAt: Date = .distantPast
    private var lastEncodedFrameAt: Date = .distantPast
    private var lastSceneCutRecoveryAt: Date = .distantPast
    private let sampleOutputQueue = DispatchQueue(
        label: "com.skybridge.compass.sck.output",
        qos: .userInteractive
    )
    private var compressionCallbackRefcon: UnsafeMutableRawPointer?
    private var screenParametersObserver: NSObjectProtocol?
    private var activeSpaceObserver: NSObjectProtocol?
    private var activeApplicationObserver: NSObjectProtocol?

/// 编码后视频帧的回调
 /// - 参数说明：data 为压缩后比特流；w/h 为视频维度；type 为帧类型（h264/hevc）
    var onEncodedFrame: ((Data, Int, Int, RemoteFrameType, Bool) -> Void)?
    var onRawFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onDamageReport: ((RemoteDesktopDamageReport) -> Void)?
    var onCaptureIssue: ((String) -> Void)?

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

 /// 启动采集与编码
    @MainActor
    func start(
        preferredCodec: RemoteFrameType = .hevc,
        preferredSize: CGSize? = nil,
        targetFPS: Int = 60,
        keyFrameInterval: Int = 60,
        captureCursorInVideo: Bool = true,
        bitstreamFormat: EncodedBitstreamFormat = .native
    ) async throws {
        guard !started else { return }
        started = true
        configuredFPS = targetFPS
        configuredKeyInterval = keyFrameInterval
        self.captureCursorInVideo = captureCursorInVideo
        self.bitstreamFormat = bitstreamFormat
        hasEmittedParameterSets = false
        pendingForcedKeyFrames = 2
        pendingParameterSetReannounce = false
// 读取编码档位与低延迟设置（主线程安全）
        let settings = RemoteDesktopSettingsManager.shared.settings
        preferredProfile = settings.displaySettings.encodingProfile
        preferredQuality = settings.displaySettings.videoQuality
        lowLatencyEnabled = settings.displaySettings.lowLatencyMode

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
        let normalizedSize = RemoteControlCaptureCompatibility.normalizedCaptureSize(
            requestedSize,
            for: preferredCodec
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
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuredFPS))
        configuration.queueDepth = lowLatencyEnabled ? 3 : 5
        configuration.capturesAudio = false
        configuration.showsCursor = captureCursorInVideo

        output = StreamOutput(owner: self)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        if !jpegMode && onEncodedFrame != nil {
            try setupCompressionSession(width: width, height: height, codec: codecType)
        }

 // 18.2: guard let 处理 stream output (Requirements 8.2, 8.3)
        guard let streamOutput = output else {
            logger.error("StreamOutput 创建失败")
            throw CocoaError(.featureUnsupported)
        }
        try stream?.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: sampleOutputQueue)
        try await stream?.startCapture()
        registerDisplayObservers()
        if jpegMode {
            logger.info("🎥 ScreenCaptureKit 采集启动：\(self.width)x\(self.height), codec=JPEG(BGRA)")
        } else {
            logger.info("🎥 ScreenCaptureKit 采集启动：\(self.width)x\(self.height), codec=\(preferredCodec == .h264 ? "H.264" : "HEVC")")
        }
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
        capturedDisplayID = nil
        capturedDisplayPixelSize = .zero
        lastSceneCutRecoveryAt = .distantPast
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
        var cs: VTCompressionSession?
        let callbackRefcon = makeCompressionCallbackRefcon()
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { refcon, sourceFrameRefCon, status, infoFlags, sampleBuffer in
                ScreenCaptureKitStreamer.handleCompressionCallback(
                    refcon: refcon,
                    status: status,
                    sampleBuffer: sampleBuffer
                )
            },
            refcon: callbackRefcon,
            compressionSessionOut: &cs
        )
        if status != noErr || cs == nil {
            Self.releaseCompressionCallbackRefcon(callbackRefcon)
            logger.error("VTCompressionSession 创建失败：\(status)，切换到 H.264")
 // 回退到 H.264
            var cs2: VTCompressionSession?
            let callbackRefcon2 = makeCompressionCallbackRefcon()
            let st2 = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(width),
                height: Int32(height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: { refcon, sourceFrameRefCon, status, infoFlags, sampleBuffer in
                    ScreenCaptureKitStreamer.handleCompressionCallback(
                        refcon: refcon,
                        status: status,
                        sampleBuffer: sampleBuffer
                    )
                },
                refcon: callbackRefcon2,
                compressionSessionOut: &cs2
            )
            guard st2 == noErr, let cs2 else {
                Self.releaseCompressionCallbackRefcon(callbackRefcon2)
                throw CocoaError(.featureUnsupported)
            }
            compressionSession = cs2
            compressionCallbackRefcon = callbackRefcon2
            codecType = kCMVideoCodecType_H264
        } else {
            compressionSession = cs
            compressionCallbackRefcon = callbackRefcon
        }

        guard let cs = compressionSession else { throw CocoaError(.featureUnsupported) }

 // 编码参数：实时、低延迟、目标帧率
 // 根据设置的编码档位选择 ProfileLevel（使用在 start 中捕获的值）
        let profile = preferredProfile
        let profileValue: CFString = {
            switch (codecType, profile) {
            case (kCMVideoCodecType_HEVC, .hevcMain): return kVTProfileLevel_HEVC_Main_AutoLevel
            case (kCMVideoCodecType_HEVC, _): return kVTProfileLevel_HEVC_Main_AutoLevel
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

    private static func handleCompressionCallback(
        refcon: UnsafeMutableRawPointer?,
        status: OSStatus,
        sampleBuffer: CMSampleBuffer?
    ) {
        guard let refcon, status == noErr, let sampleBuffer else { return }
        let unmanaged = Unmanaged<CompressionCallbackContext>.fromOpaque(refcon)
        _ = unmanaged.retain()
        let context = unmanaged.takeUnretainedValue()
        defer { unmanaged.release() }
        guard let streamer = context.activeStreamer() else { return }
        autoreleasepool {
            streamer.handleCompressedSample(sampleBuffer)
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
        stateLock.lock()
        lastSampleBufferAt = Date()
        stateLock.unlock()
    }

    private func noteMeaningfulSampleReceived() {
        stateLock.lock()
        lastMeaningfulSampleAt = Date()
        stateLock.unlock()
    }

    private func noteEncodedFrameEmitted() {
        stateLock.lock()
        lastEncodedFrameAt = Date()
        stateLock.unlock()
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

    private func handleCompressedSample(_ sampleBuffer: CMSampleBuffer) {
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
        noteEncodedFrameEmitted()
        onEncodedFrame?(payload, width, height, type, isSyncSample(sampleBuffer))
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

    private func handleJPEGPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        var cgImage: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        guard status == noErr, let cgImage else { return }

        let mutable = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutable, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.65
        ]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }

        // 复用 onEncodedFrame：frameType 用 .bgra 标记“非 H26x”，上层可按 magic 判断是否 JPEG
        noteEncodedFrameEmitted()
        onEncodedFrame?(
            mutable as Data,
            CVPixelBufferGetWidth(pixelBuffer),
            CVPixelBufferGetHeight(pixelBuffer),
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
            return true
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

    static func shouldProcessFrame(with status: SCFrameStatus?) -> Bool {
        guard let status else { return true }
        switch status {
        case .idle, .blank, .suspended, .stopped:
            return false
        case .started, .complete:
            return true
        @unknown default:
            return false
        }
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
    // guard let 处理 owner 和 compressionSession
                guard let owner = owner else { return }
                owner.noteSampleBufferReceived()
    // guard let 处理 pixelBuffer (外部输入)
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                owner.emitDamageReportIfAvailable(sampleBuffer: sampleBuffer, pixelBuffer: pixelBuffer)

                let frameStatus = owner.frameStatus(from: sampleBuffer)
                guard ScreenCaptureKitStreamer.shouldProcessFrame(with: frameStatus) else {
                    return
                }
                // `.started` 帧已经带着可用 pixelBuffer；继续丢弃会让 native/raw 与 encoded/fallback 两条送帧链一起饿死。
                owner.noteMeaningfulSampleReceived()

                // JPEG 模式：直接把 pixelBuffer 转成 JPEG，回调出去
                if owner.jpegMode {
                    owner.handleJPEGPixelBuffer(pixelBuffer)
                    return
                }

                if let onRawFrame = owner.onRawFrame {
                    owner.noteEncodedFrameEmitted()
                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    onRawFrame(pixelBuffer, pts)
                }

                guard let cs = owner.compressionSession else { return }
                var flags = VTEncodeInfoFlags()
                let pts = CMTime(value: CMTimeValue(Date().timeIntervalSince1970 * 1000), timescale: 1000)
                let status = VTCompressionSessionEncodeFrame(
                    cs,
                    imageBuffer: pixelBuffer,
                    presentationTimeStamp: pts,
                    duration: CMTime.zero,
                    frameProperties: owner.nextFramePropertiesForEncode(),
                    sourceFrameRefcon: nil,
                    infoFlagsOut: &flags
                )
                if status != noErr {
                    owner.logger.error("❌ VTCompressionSessionEncodeFrame failed: status=\(status, privacy: .public)")
                    owner.onCaptureIssue?("encode-status-\(status)")
                }
            }
        }
    }
}
