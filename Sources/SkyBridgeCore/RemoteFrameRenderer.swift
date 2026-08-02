import Foundation
@preconcurrency import Metal
import VideoToolbox
import CoreVideo
import CoreMedia
import os.log

// C-ABI 释放回调：与 CVPixelBufferCreateWithBytes 的回调签名完全匹配
private func SkybridgeReleaseCVPixelBufferBytes(
    _ releaseRefCon: UnsafeMutableRawPointer?,
    _ baseAddress: UnsafeRawPointer?
) {
    if let releaseRefCon {
        Unmanaged<NSData>.fromOpaque(releaseRefCon).release()
    }
}

/// 远程帧类型 - 符合Swift 6.2.1的Sendable要求
public enum RemoteFrameType: UInt, Sendable {
    case bgra = 0
    case h264 = 1
    case hevc = 2
}

public struct RenderMetrics: Sendable {
    public let bandwidthMbps: Double
    public let latencyMilliseconds: Double
}

public enum RemoteH264FrameSubmissionResult: Sendable {
    case awaitingParameterSets
    case awaitingSyncFrame
    case droppedForBackpressure
    case submitted(RenderMetrics)
}

public enum RemoteFrameRenderError: Error, LocalizedError, Sendable {
    case invalidFrameGeometry
    case invalidH264AccessUnit
    case invalidH264FormatDescription(OSStatus)
    case unsupportedH264Dimensions(width: Int32, height: Int32)
    case compressedSampleBufferCreationFailed(OSStatus)
    case videoToolboxDecodeFailed(OSStatus)
    case decodedFrameMissingImageBuffer
    case metalTextureConversionFailed(CVReturn)
    case decoderBackpressure

    public var errorDescription: String? {
        switch self {
        case .invalidFrameGeometry:
            "The remote frame dimensions, stride, or payload size are invalid."
        case .invalidH264AccessUnit:
            "H.264 access unit is malformed or exceeds the configured safety limits."
        case let .invalidH264FormatDescription(status):
            "H.264 parameter sets are invalid (VideoToolbox status \(status))."
        case let .unsupportedH264Dimensions(width, height):
            "H.264 dimensions \(width)×\(height) exceed the supported camera profile."
        case let .compressedSampleBufferCreationFailed(status):
            "Unable to create the H.264 sample buffer (status \(status))."
        case let .videoToolboxDecodeFailed(status):
            "VideoToolbox rejected the H.264 frame (status \(status))."
        case .decodedFrameMissingImageBuffer:
            "VideoToolbox completed a frame without an image buffer."
        case let .metalTextureConversionFailed(status):
            "The decoded camera frame could not be converted to a Metal texture (status \(status))."
        case .decoderBackpressure:
            "The hardware decoder queue reached its bounded in-flight limit."
        }
    }
}

private final class RemoteFrameBacking: @unchecked Sendable {
    let textureRef: CVMetalTexture
    let imageBuffer: CVImageBuffer

    init(textureRef: CVMetalTexture, imageBuffer: CVImageBuffer) {
        self.textureRef = textureRef
        self.imageBuffer = imageBuffer
    }
}

/// Transfers ownership of one immutable VideoToolbox callback image to `renderQueue`.
///
/// The retained Core Video reference keeps its IOSurface alive until texture conversion has
/// completed. Only the serial render queue reads the buffer and this type exposes no mutation,
/// so the unchecked conformance is confined to this explicit one-way delivery boundary.
private final class RemoteDecodedFrameDelivery: @unchecked Sendable {
    let imageBuffer: CVImageBuffer

    init(imageBuffer: CVImageBuffer) {
        self.imageBuffer = imageBuffer
    }
}

private final class RemoteFrameDecompressionCallbackContext {
    private let lock = NSLock()
    weak var renderer: RemoteFrameRenderer?
    private var isActive = true

    init(renderer: RemoteFrameRenderer) {
        self.renderer = renderer
    }

    func deactivate() {
        lock.lock()
        isActive = false
        lock.unlock()
    }

    func activeRenderer() -> RemoteFrameRenderer? {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return nil }
        return renderer
    }
}

public final class RemoteFrameRenderer: @unchecked Sendable {
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var decompressionSession: VTDecompressionSession?
    private var decompressionCallbackRefcon: UnsafeMutableRawPointer?
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSessionFormatDescription: CMVideoFormatDescription?
    private var currentCodec: RemoteFrameType?
    private var h264ParameterSetState = H264ParameterSetTransitionState()
    private let decodeStateLock = NSLock()
    private var decodeSubmissionState = RemoteDecodeSubmissionState()
    private let maximumInFlightDecodeCount = 3
    private var previousFrameTimestamp: DispatchTime?
    private let log = Logger(subsystem: "com.skybridge.compass", category: "MetalRenderer")
    private let renderQueue = DispatchQueue(label: "com.skybridge.compass.metal.render")
    private let renderQueueKey = DispatchSpecificKey<UInt8>()
    private let frameDeliveryLock = NSLock()
    private var isFrameDeliveryActive = true
    private var storedFrameHandler: ((MTLTexture, AnyObject?) -> Void)?
    private var storedFailureHandler: (@Sendable (RemoteFrameRenderError) -> Void)?

    public var frameHandler: ((MTLTexture, AnyObject?) -> Void)? {
        get {
            frameDeliveryLock.lock()
            defer { frameDeliveryLock.unlock() }
            return storedFrameHandler
        }
        set {
            frameDeliveryLock.lock()
            storedFrameHandler = isFrameDeliveryActive ? newValue : nil
            frameDeliveryLock.unlock()
        }
    }

    public var failureHandler: (@Sendable (RemoteFrameRenderError) -> Void)? {
        get {
            frameDeliveryLock.lock()
            defer { frameDeliveryLock.unlock() }
            return storedFailureHandler
        }
        set {
            frameDeliveryLock.lock()
            storedFailureHandler = isFrameDeliveryActive ? newValue : nil
            frameDeliveryLock.unlock()
        }
    }

    public init() {
        renderQueue.setSpecific(key: renderQueueKey, value: 1)
        device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        if let device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        }
    }

    public func teardown() {
        invalidateFrameDelivery()
        deactivateDecompressionCallbackContext()
        if let decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
            VTDecompressionSessionInvalidate(decompressionSession)
        }
        // VT callbacks may already have queued texture conversion work. Drain that work before
        // releasing textureCache; otherwise teardown races the render queue.
        if DispatchQueue.getSpecific(key: renderQueueKey) == nil {
            renderQueue.sync {}
        }
        decompressionSession = nil
        releaseDecompressionCallbackContext()
        formatDescription = nil
        decompressionSessionFormatDescription = nil
        textureCache = nil
        currentCodec = nil
        h264ParameterSetState.reset()
        decodeStateLock.lock()
        decodeSubmissionState.reset(waitingForSyncFrame: true)
        decodeStateLock.unlock()
    }

    public func processFrame(data: Data,
                              width: Int,
                              height: Int,
                              stride: Int,
                              type: RemoteFrameType) -> RenderMetrics {
        let start = DispatchTime.now()
        let metrics: RenderMetrics
        switch type {
        case .bgra:
            metrics = renderBGRAFrame(data: data, width: width, height: height, stride: stride)
        case .h264, .hevc:
            metrics = renderCompressedFrame(data: data, width: width, height: height, codec: type)
        }
        let end = DispatchTime.now()
        let elapsed = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
        previousFrameTimestamp = end
        return RenderMetrics(
            bandwidthMbps: metrics.bandwidthMbps,
            latencyMilliseconds: max(metrics.latencyMilliseconds, elapsed)
        )
    }

    /// 提交 CameraKit 产出的单个 Annex-B H.264 access unit。
    /// 调用方必须在后台串行执行；该方法不会在缺少参数集/IDR 时伪装成已渲染。
    public func processH264AnnexBAccessUnit(
        data: Data
    ) throws -> RemoteH264FrameSubmissionResult {
        let accessUnit: H264AnnexBAccessUnit
        do {
            accessUnit = try H264AnnexBAccessUnit.parse(data)
        } catch {
            throw RemoteFrameRenderError.invalidH264AccessUnit
        }

        h264ParameterSetState.stage(
            sequenceParameterSet: accessUnit.sequenceParameterSet,
            pictureParameterSet: accessUnit.pictureParameterSet
        )

        // Parameter sets can arrive in separate access units. Never combine a new SPS with an
        // old PPS (or vice versa); switch only on an IDR after a complete pair validates.
        if let candidate = h264ParameterSetState.candidateForIDR(
            carriesSequenceParameterSet: accessUnit.sequenceParameterSet != nil,
            carriesPictureParameterSet: accessUnit.pictureParameterSet != nil,
            containsIDR: accessUnit.containsIDR
        ) {
            let nextFormatDescription = try makeH264FormatDescription(
                sequenceParameterSet: candidate.sequenceParameterSet,
                pictureParameterSet: candidate.pictureParameterSet
            )
            h264ParameterSetState.commit(candidate)
            formatDescription = nextFormatDescription
            currentCodec = .h264
            markWaitingForSyncFrame()
        }

        guard formatDescription != nil else { return .awaitingParameterSets }

        guard !isWaitingForSyncFrameSnapshot() || accessUnit.containsIDR else {
            return .awaitingSyncFrame
        }

        let sampleData: Data
        do {
            sampleData = try accessUnit.makeAVCCSampleData()
        } catch H264AnnexBAccessUnitError.missingRenderableNALUnit {
            return isWaitingForSyncFrameSnapshot() ? .awaitingSyncFrame : .awaitingParameterSets
        } catch {
            throw RemoteFrameRenderError.invalidH264AccessUnit
        }

        guard let formatDescription else {
            return .awaitingParameterSets
        }
        ensureDecompressionSession(formatDescription: formatDescription, codec: .h264)
        guard let decompressionSession else {
            throw RemoteFrameRenderError.videoToolboxDecodeFailed(kVTInvalidSessionErr)
        }

        let sampleBuffer = try makeCompressedSampleBuffer(
            data: sampleData,
            formatDescription: formatDescription,
            isSyncFrame: accessUnit.containsIDR
        )
        guard beginDecodeSubmission() else {
            markWaitingForSyncFrame()
            return .droppedForBackpressure
        }
        if accessUnit.containsIDR {
            clearWaitingForSyncFrame()
        }
        var outputFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: ._EnableAsynchronousDecompression,
            frameRefcon: nil,
            infoFlagsOut: &outputFlags
        )
        guard decodeStatus == noErr else {
            completeDecodeSubmission(status: decodeStatus)
            throw RemoteFrameRenderError.videoToolboxDecodeFailed(decodeStatus)
        }

        let delta = interFrameInterval()
        return .submitted(RenderMetrics(
            bandwidthMbps: calculateBandwidth(bytes: data.count, delta: delta),
            latencyMilliseconds: delta * 1_000
        ))
    }

    private func renderBGRAFrame(data: Data, width: Int, height: Int, stride: Int) -> RenderMetrics {
        guard width > 0, height > 0 else {
            return RenderMetrics(bandwidthMbps: 0, latencyMilliseconds: 0)
        }
        let byteCount = data.count
        let delta = interFrameInterval()
        let baselineBandwidth = calculateBandwidth(bytes: byteCount, delta: delta)
        guard let textureCache, let _ = device else {
            log.error("Metal device unavailable; BGRA frame fallback active")
            return RenderMetrics(bandwidthMbps: baselineBandwidth, latencyMilliseconds: delta * 1000)
        }

        let frame = BGRAFrame(data: data, width: width, height: height, stride: stride)
        let buffer: CVPixelBuffer
        do {
            buffer = try BGRAFrameBuilder.buildPixelBuffer(from: frame, mode: .safeCopy)
        } catch {
            log.error("Failed to build BGRA pixel buffer: \(String(describing: error))")
            reportFailure(.invalidFrameGeometry)
            return RenderMetrics(bandwidthMbps: baselineBandwidth, latencyMilliseconds: delta * 1000)
        }
        let effectiveDelta = max(delta, 0.001)
        let bandwidthEffective = calculateBandwidth(bytes: byteCount, delta: effectiveDelta)

        guard let commandQueue, let commandBuffer = commandQueue.makeCommandBuffer() else {
            log.error("Unable to create Metal command buffer")
            return RenderMetrics(bandwidthMbps: bandwidthEffective, latencyMilliseconds: effectiveDelta * 1000)
        }

        var textureRef: CVMetalTexture?
        let textureStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            buffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &textureRef
        )

        if textureStatus != kCVReturnSuccess {
            log.error("Failed to create Metal texture from BGRA frame: \(textureStatus)")
            return RenderMetrics(bandwidthMbps: bandwidthEffective, latencyMilliseconds: effectiveDelta * 1000)
        }

        if let textureRef, let texture = CVMetalTextureGetTexture(textureRef) {
            let backing = RemoteFrameBacking(textureRef: textureRef, imageBuffer: buffer)
            renderQueue.async { [weak self] in
                self?.deliverFrame(texture: texture, backing: backing)
            }
        }
        commandBuffer.commit()
        return RenderMetrics(bandwidthMbps: bandwidthEffective, latencyMilliseconds: effectiveDelta * 1000)
    }

    private func renderCompressedFrame(data: Data, width: Int, height: Int, codec: RemoteFrameType) -> RenderMetrics {
        guard width > 0,
              height > 0,
              width <= BGRAFrameBuilder.maximumWidth,
              height <= BGRAFrameBuilder.maximumHeight,
              width <= Int(Int32.max),
              height <= Int(Int32.max) else {
            return RenderMetrics(bandwidthMbps: 0, latencyMilliseconds: 0)
        }
        configureFormatDescriptionIfNeeded(width: width, height: height, codec: codec)
        guard let formatDescription else {
            log.error("Missing format description; cannot decode codec \(String(describing: codec))")
            return RenderMetrics(bandwidthMbps: 0, latencyMilliseconds: 0)
        }
        ensureDecompressionSession(formatDescription: formatDescription, codec: codec)
        let delta = interFrameInterval()
        let bandwidth = calculateBandwidth(bytes: data.count, delta: delta)

        guard let decompressionSession else {
            log.error("No decompression session available for codec \(String(describing: codec))")
            return RenderMetrics(bandwidthMbps: bandwidth, latencyMilliseconds: delta * 1000)
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == kCMBlockBufferNoErr, let block = blockBuffer else {
            log.error("Failed to create CMBlockBuffer: \(status)")
            return RenderMetrics(bandwidthMbps: bandwidth, latencyMilliseconds: delta * 1000)
        }

        data.withUnsafeBytes { pointer in
            if let baseAddress = pointer.baseAddress {
                CMBlockBufferReplaceDataBytes(
                    with: baseAddress,
                    blockBuffer: block,
                    offsetIntoDestination: 0,
                    dataLength: data.count
                )
            }
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSizes = [data.count]
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizes,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sample = sampleBuffer else {
            log.error("Unable to create sample buffer for decoding: \(status)")
            return RenderMetrics(bandwidthMbps: bandwidth, latencyMilliseconds: delta * 1000)
        }

        guard beginDecodeSubmission() else {
            reportFailure(.decoderBackpressure)
            return RenderMetrics(bandwidthMbps: bandwidth, latencyMilliseconds: delta * 1000)
        }
        let decodeFlags = VTDecodeFrameFlags._EnableAsynchronousDecompression
        var outputFlags = VTDecodeInfoFlags()
        status = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sample,
            flags: decodeFlags,
            frameRefcon: nil,
            infoFlagsOut: &outputFlags
        )

        if status != noErr {
            completeDecodeSubmission(status: status)
            log.error("VideoToolbox decode error for codec \(String(describing: codec)) status \(status)")
        }

        return RenderMetrics(bandwidthMbps: bandwidth, latencyMilliseconds: delta * 1000)
    }

    private func configureFormatDescriptionIfNeeded(width: Int, height: Int, codec: RemoteFrameType) {
        guard codec != .bgra,
              width > 0,
              height > 0,
              width <= BGRAFrameBuilder.maximumWidth,
              height <= BGRAFrameBuilder.maximumHeight,
              width <= Int(Int32.max),
              height <= Int(Int32.max) else { return }

        var requiresNewDescription = formatDescription == nil || currentCodec != codec
        if let description = formatDescription, !requiresNewDescription {
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            requiresNewDescription = dimensions.width != width || dimensions.height != height
        }

        guard requiresNewDescription else { return }

        formatDescription = nil
        currentCodec = nil

        let codecType: CMVideoCodecType = (codec == .h264) ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC

        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: Int32(width),
            height: Int32(height),
            extensions: nil,
            formatDescriptionOut: &description
        )
        if status == noErr, let description {
            formatDescription = description
            currentCodec = codec
        } else {
            log.error("Failed to create CMVideoFormatDescription for codec \(String(describing: codec)) status \(status)")
        }
    }

    private func makeH264FormatDescription(
        sequenceParameterSet: Data,
        pictureParameterSet: Data
    ) throws -> CMVideoFormatDescription {
        var description: CMFormatDescription?
        let status = sequenceParameterSet.withUnsafeBytes { sequenceRaw -> OSStatus in
            guard let sequenceBase = sequenceRaw.baseAddress else { return kCMFormatDescriptionError_InvalidParameter }
            return pictureParameterSet.withUnsafeBytes { pictureRaw -> OSStatus in
                guard let pictureBase = pictureRaw.baseAddress else { return kCMFormatDescriptionError_InvalidParameter }
                let pointers: [UnsafePointer<UInt8>] = [
                    sequenceBase.assumingMemoryBound(to: UInt8.self),
                    pictureBase.assumingMemoryBound(to: UInt8.self)
                ]
                let sizes = [sequenceParameterSet.count, pictureParameterSet.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        guard let pointerBase = pointerBuffer.baseAddress,
                              let sizeBase = sizeBuffer.baseAddress else {
                            return kCMFormatDescriptionError_InvalidParameter
                        }
                        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: pointerBuffer.count,
                            parameterSetPointers: pointerBase,
                            parameterSetSizes: sizeBase,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description
                        )
                    }
                }
            }
        }
        guard status == noErr, let description else {
            throw RemoteFrameRenderError.invalidH264FormatDescription(status)
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        guard dimensions.width > 0,
              dimensions.height > 0,
              dimensions.width <= 3_840,
              dimensions.height <= 2_160 else {
            throw RemoteFrameRenderError.unsupportedH264Dimensions(
                width: dimensions.width,
                height: dimensions.height
            )
        }
        return description
    }

    private func makeCompressedSampleBuffer(
        data: Data,
        formatDescription: CMVideoFormatDescription,
        isSyncFrame: Bool
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw RemoteFrameRenderError.compressedSampleBufferCreationFailed(status)
        }
        status = data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return kCMFormatDescriptionError_InvalidParameter
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw RemoteFrameRenderError.compressedSampleBufferCreationFailed(status)
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = data.count
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw RemoteFrameRenderError.compressedSampleBufferCreationFailed(status)
        }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(isSyncFrame ? kCFBooleanFalse : kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }

    private func ensureDecompressionSession(formatDescription: CMVideoFormatDescription, codec: RemoteFrameType) {
        if let existing = decompressionSession {
            if let currentDescription = decompressionSessionFormatDescription,
               CMFormatDescriptionEqual(currentDescription, otherFormatDescription: formatDescription) {
                return
            }
            deactivateDecompressionCallbackContext()
            VTDecompressionSessionWaitForAsynchronousFrames(existing)
            VTDecompressionSessionInvalidate(existing)
            if DispatchQueue.getSpecific(key: renderQueueKey) == nil {
                renderQueue.sync {}
            }
            releaseDecompressionCallbackContext()
            decompressionSession = nil
            decompressionSessionFormatDescription = nil
            resetDecodeSubmissionState(waitingForSyncFrame: true)
        }

        var newSession: VTDecompressionSession?
        let callbackRefcon = makeDecompressionCallbackRefcon()
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { decompressionOutputRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration in
                RemoteFrameRenderer.decompressionCallback(
                    decompressionOutputRefCon: decompressionOutputRefCon,
                    sourceFrameRefCon: sourceFrameRefCon,
                    status: status,
                    infoFlags: infoFlags,
                    imageBuffer: imageBuffer,
                    presentationTimeStamp: presentationTimeStamp,
                    presentationDuration: presentationDuration
                )
            },
            decompressionOutputRefCon: callbackRefcon
        )

        let destinationAttributes: [NSString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
 // 允许通过 IOSurface 零拷贝地将解码后的像素缓冲暴露给 Metal
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        var decoderSpecification: CFDictionary?
        if codec == .hevc {
            decoderSpecification = [
                kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
                kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: false
            ] as CFDictionary
        }

        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpecification,
            imageBufferAttributes: destinationAttributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &newSession
        )

        if status == noErr {
            let realtimeStatus = newSession.map {
                VTSessionSetProperty($0, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            } ?? kVTInvalidSessionErr
            guard realtimeStatus == noErr else {
                if let newSession {
                    VTDecompressionSessionInvalidate(newSession)
                }
                Self.releaseDecompressionCallbackRefcon(callbackRefcon)
                decompressionSession = nil
                decompressionSessionFormatDescription = nil
                reportFailure(.videoToolboxDecodeFailed(realtimeStatus))
                return
            }
            decompressionSession = newSession
            decompressionSessionFormatDescription = formatDescription
            decompressionCallbackRefcon = callbackRefcon
        } else {
            Self.releaseDecompressionCallbackRefcon(callbackRefcon)
            decompressionSession = nil
            decompressionSessionFormatDescription = nil
            log.error("Failed to create VTDecompressionSession for codec \(String(describing: codec)) status \(status)")
        }
    }

 // 回调实现已在文件顶层以 C-ABI 函数形式提供（SkybridgeReleaseCVPixelBufferBytes）

    private static func decompressionCallback(
        decompressionOutputRefCon: UnsafeMutableRawPointer?,
        sourceFrameRefCon: UnsafeMutableRawPointer?,
        status: OSStatus,
        infoFlags: VTDecodeInfoFlags,
        imageBuffer: CVImageBuffer?,
        presentationTimeStamp: CMTime,
        presentationDuration: CMTime
    ) {
        guard let decompressionOutputRefCon else { return }
        let unmanaged = Unmanaged<RemoteFrameDecompressionCallbackContext>.fromOpaque(decompressionOutputRefCon)
        _ = unmanaged.retain()
        let context = unmanaged.takeUnretainedValue()
        defer { unmanaged.release() }
        guard let renderer = context.activeRenderer() else { return }
        renderer.completeDecodeSubmission(status: status)
        if status != noErr {
            renderer.log.error("Decompression callback error: \(status), flags \(infoFlags.rawValue)")
            renderer.reportFailure(.videoToolboxDecodeFailed(status))
        } else if let imageBuffer {
            renderer.handleDecompressedFrame(imageBuffer: imageBuffer, presentationTimeStamp: presentationTimeStamp)
        } else {
            renderer.reportFailure(.decodedFrameMissingImageBuffer)
        }
    }

    private func makeDecompressionCallbackRefcon() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(Unmanaged.passRetained(RemoteFrameDecompressionCallbackContext(renderer: self)).toOpaque())
    }

    private func deactivateDecompressionCallbackContext() {
        guard let decompressionCallbackRefcon else { return }
        let context = Unmanaged<RemoteFrameDecompressionCallbackContext>
            .fromOpaque(decompressionCallbackRefcon)
            .takeUnretainedValue()
        context.deactivate()
    }

    private func releaseDecompressionCallbackContext() {
        guard let decompressionCallbackRefcon else { return }
        Self.releaseDecompressionCallbackRefcon(decompressionCallbackRefcon)
        self.decompressionCallbackRefcon = nil
    }

    private static func releaseDecompressionCallbackRefcon(_ refcon: UnsafeMutableRawPointer) {
        Unmanaged<RemoteFrameDecompressionCallbackContext>.fromOpaque(refcon).release()
    }

    private func handleDecompressedFrame(imageBuffer: CVImageBuffer, presentationTimeStamp: CMTime) {
        let delivery = RemoteDecodedFrameDelivery(imageBuffer: imageBuffer)
        renderQueue.async { [weak self] in
            guard let self else { return }
            let imageBuffer = delivery.imageBuffer
            guard let textureCache else {
                self.log.error("Missing texture cache; cannot convert decoded frame to Metal texture")
                self.reportFailure(.metalTextureConversionFailed(kCVReturnInvalidArgument))
                return
            }
            let width = CVPixelBufferGetWidth(imageBuffer)
            let height = CVPixelBufferGetHeight(imageBuffer)
            var textureRef: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                imageBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &textureRef
            )
            if status == kCVReturnSuccess, let textureRef, let texture = CVMetalTextureGetTexture(textureRef) {
                let backing = RemoteFrameBacking(textureRef: textureRef, imageBuffer: imageBuffer)
                self.deliverFrame(texture: texture, backing: backing)
            } else {
                self.log.error("Failed to create Metal texture from decoded frame: \(status)")
                self.reportFailure(.metalTextureConversionFailed(status))
            }
        }
    }

    private func interFrameInterval() -> Double {
        guard let previous = previousFrameTimestamp else {
            previousFrameTimestamp = DispatchTime.now()
            return 0.016
        }
        let now = DispatchTime.now()
        let delta = Double(now.uptimeNanoseconds - previous.uptimeNanoseconds) / 1_000_000_000.0
        previousFrameTimestamp = now
        return max(delta, 0.001)
    }

    private func calculateBandwidth(bytes: Int, delta: Double) -> Double {
        guard delta > 0 else { return 0 }
        return (Double(bytes) * 8.0) / (delta * 1_000_000.0)
    }

    private func invalidateFrameDelivery() {
        frameDeliveryLock.lock()
        isFrameDeliveryActive = false
        storedFrameHandler = nil
        storedFailureHandler = nil
        frameDeliveryLock.unlock()
    }

    private func deliverFrame(texture: MTLTexture, backing: AnyObject?) {
        frameDeliveryLock.lock()
        guard isFrameDeliveryActive, let handler = storedFrameHandler else {
            frameDeliveryLock.unlock()
            return
        }
        // 与 teardown 串行化：teardown 返回后，不会再有迟到帧进入已失效会话的 feed。
        handler(texture, backing)
        frameDeliveryLock.unlock()
    }

    private func beginDecodeSubmission() -> Bool {
        decodeStateLock.lock()
        defer { decodeStateLock.unlock() }
        return decodeSubmissionState.begin(
            maximumInFlightCount: maximumInFlightDecodeCount
        )
    }

    private func completeDecodeSubmission(status: OSStatus) {
        decodeStateLock.lock()
        decodeSubmissionState.complete(succeeded: status == noErr)
        decodeStateLock.unlock()
    }

    private func isWaitingForSyncFrameSnapshot() -> Bool {
        decodeStateLock.lock()
        defer { decodeStateLock.unlock() }
        return decodeSubmissionState.isWaitingForSyncFrame
    }

    private func markWaitingForSyncFrame() {
        decodeStateLock.lock()
        decodeSubmissionState.markWaitingForSyncFrame()
        decodeStateLock.unlock()
    }

    private func clearWaitingForSyncFrame() {
        decodeStateLock.lock()
        decodeSubmissionState.clearWaitingForSyncFrame()
        decodeStateLock.unlock()
    }

    private func resetDecodeSubmissionState(waitingForSyncFrame: Bool) {
        decodeStateLock.lock()
        decodeSubmissionState.reset(waitingForSyncFrame: waitingForSyncFrame)
        decodeStateLock.unlock()
    }

    private func reportFailure(_ error: RemoteFrameRenderError) {
        frameDeliveryLock.lock()
        let handler = isFrameDeliveryActive ? storedFailureHandler : nil
        frameDeliveryLock.unlock()
        handler?(error)
    }
}
