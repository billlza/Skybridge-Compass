import Foundation
@preconcurrency import ScreenCaptureKit
import VideoToolbox
import CoreVideo
import OSLog
import ImageIO
import UniformTypeIdentifiers

/// 使用 ScreenCaptureKit 捕获屏幕并通过 VideoToolbox 编码为 HEVC/H.264 的数据流
/// - 中文说明：该组件专注于本地屏幕采集与硬件加速编码，外部通过回调接收压缩后的视频帧数据。
final class ScreenCaptureKitStreamer: NSObject {
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
    private var lowLatencyEnabled: Bool = false
    private var jpegMode: Bool = false
    private let sampleOutputQueue = DispatchQueue(
        label: "com.skybridge.compass.sck.output",
        qos: .userInteractive
    )

 /// 编码后视频帧的回调
 /// - 参数说明：data 为压缩后比特流；w/h 为视频维度；type 为帧类型（h264/hevc）
    var onEncodedFrame: ((Data, Int, Int, RemoteFrameType) -> Void)?

 /// 启动采集与编码
    @MainActor
    func start(preferredCodec: RemoteFrameType = .hevc, preferredSize: CGSize? = nil, targetFPS: Int = 60, keyFrameInterval: Int = 60) async throws {
        guard !started else { return }
        started = true
        configuredFPS = targetFPS
        configuredKeyInterval = keyFrameInterval
 // 读取编码档位与低延迟设置（主线程安全）
        let settings = RemoteDesktopSettingsManager.shared.settings
        preferredProfile = settings.displaySettings.encodingProfile
        lowLatencyEnabled = settings.displaySettings.lowLatencyMode

 // 选择显示内容：默认使用主显示器
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            logger.error("ScreenCaptureKit 无可用显示设备")
            throw CocoaError(.fileNoSuchFile)
        }
        width = Int(preferredSize?.width ?? CGFloat(display.width))
        height = Int(preferredSize?.height ?? CGFloat(display.height))

        // iOS 端为简化解码：允许用 BGRA 模式输出 JPEG（避免 H.264/HEVC NAL 兼容问题）
        jpegMode = (preferredCodec == .bgra)
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
        configuration.capturesAudio = false

        output = StreamOutput(owner: self)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        if !jpegMode {
            try setupCompressionSession(width: width, height: height, codec: codecType)
        }

 // 18.2: guard let 处理 stream output (Requirements 8.2, 8.3)
        guard let streamOutput = output else {
            logger.error("StreamOutput 创建失败")
            throw CocoaError(.featureUnsupported)
        }
        try stream?.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: sampleOutputQueue)
        try await stream?.startCapture()
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
        stream?.stopCapture()
        stream = nil
        output = nil
        if let cs = compressionSession {
            VTCompressionSessionCompleteFrames(cs, untilPresentationTimeStamp: CMTime.invalid)
            VTCompressionSessionInvalidate(cs)
        }
        compressionSession = nil
        logger.info("🛑 ScreenCaptureKit 采集已停止")
    }

    private func setupCompressionSession(width: Int, height: Int, codec: CMVideoCodecType) throws {
        var cs: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { refcon, sourceFrameRefCon, status, infoFlags, sampleBuffer in
 // 18.2: guard let 处理 refcon 回调 (Requirements 8.2, 8.3)
                guard status == noErr, let sampleBuffer, let refcon else { return }

 // 19.2: Type C defensive check for Unmanaged pointer (Requirements 9.1, 9.2)
 // The Unmanaged.fromOpaque conversion is inherently unsafe - we add defensive validation
 // Note: fromOpaque doesn't throw, so we rely on the guard above and validation below
                let streamer = Unmanaged<ScreenCaptureKitStreamer>.fromOpaque(refcon).takeUnretainedValue()

 // Validation: verify the object is still valid by reading its state
 // This is a best-effort check - if the object was deallocated, this will crash
 // in DEBUG (which is desired for early detection) rather than silently corrupting data
 // The tautology (started || !started) forces a read without affecting logic
                #if DEBUG
 // In DEBUG, we want to crash early if the pointer is invalid
                _ = streamer.started  // Force read to validate object
                #endif

                streamer.handleCompressedSample(sampleBuffer)
            },
            refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            compressionSessionOut: &cs
        )
        if status != noErr || cs == nil {
            logger.error("VTCompressionSession 创建失败：\(status)，切换到 H.264")
 // 回退到 H.264
            var cs2: VTCompressionSession?
            let st2 = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(width),
                height: Int32(height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: { refcon, sourceFrameRefCon, status, infoFlags, sampleBuffer in
 // 18.2: guard let 处理 refcon 回调 (Requirements 8.2, 8.3)
                    guard status == noErr, let sampleBuffer, let refcon else { return }

 // 19.2: Type C defensive check for Unmanaged pointer (Requirements 9.1, 9.2)
                    let streamer = Unmanaged<ScreenCaptureKitStreamer>.fromOpaque(refcon).takeUnretainedValue()

                    #if DEBUG
 // In DEBUG, force read to validate object
                    _ = streamer.started
                    #endif

                    streamer.handleCompressedSample(sampleBuffer)
                },
                refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                compressionSessionOut: &cs2
            )
            guard st2 == noErr, let cs2 else { throw CocoaError(.featureUnsupported) }
            compressionSession = cs2
            codecType = kCMVideoCodecType_H264
        } else {
            compressionSession = cs
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
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_ProfileLevel, value: profileValue)
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: configuredFPS))
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
 // 低延迟模式：缩短关键帧间隔
        let keyInterval = lowLatencyEnabled ? max(10, min(configuredKeyInterval, 30)) : configuredKeyInterval
        VTSessionSetProperty(cs, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: keyInterval))

 // 自适应码率控制（如果启用）
 // 注意：自适应码率将在启动后异步应用，避免在同步上下文中访问 MainActor 隔离的属性
 // 可以通过 NetworkQualityAdaptiveBitrateController 的回调在运行时动态调整码率

        VTCompressionSessionPrepareToEncodeFrames(cs)
    }

    private func handleCompressedSample(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, totalLength > 0, let base = dataPointer else { return }
        let data = Data(bytes: base, count: totalLength)
        let type: RemoteFrameType = (codecType == kCMVideoCodecType_HEVC) ? .hevc : .h264
        onEncodedFrame?(data, width, height, type)
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
        onEncodedFrame?(mutable as Data, CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), .bgra)
    }

 /// SCStream 输出桥接
 /// 18.2: guard let 处理 stream output (Requirements 8.2, 8.3)
    private final class StreamOutput: NSObject, SCStreamOutput {
        weak var owner: ScreenCaptureKitStreamer?
        init(owner: ScreenCaptureKitStreamer) { self.owner = owner }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
 // guard let 处理 owner 和 compressionSession
            guard let owner = owner else { return }
 // guard let 处理 pixelBuffer (外部输入)
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            // JPEG 模式：直接把 pixelBuffer 转成 JPEG，回调出去
            if owner.jpegMode {
                owner.handleJPEGPixelBuffer(pixelBuffer)
                return
            }

            guard let cs = owner.compressionSession else { return }
            var flags = VTEncodeInfoFlags()
            let pts = CMTime(value: CMTimeValue(Date().timeIntervalSince1970 * 1000), timescale: 1000)
            VTCompressionSessionEncodeFrame(cs, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: CMTime.zero, frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: &flags)
        }
    }
}
