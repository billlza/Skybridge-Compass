import Foundation
import Metal
import VideoToolbox
import CoreVideo
import CoreMedia
import os.log

public enum RemoteFrameType: UInt {
    case bgra = 0
    case h264 = 1
    case hevc = 2
}

public struct RenderMetrics {
    public let bandwidthMbps: Double
    public let latencyMilliseconds: Double
}

public final class RemoteFrameRenderer {
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var currentCodec: RemoteFrameType?
    private var previousFrameTimestamp: DispatchTime?
    private let log = Logger(subsystem: "com.skybridge.compass", category: "MetalRenderer")

    public init() {
        device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        if let device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        }
    }

    public func teardown() {
        if let decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
            VTDecompressionSessionInvalidate(decompressionSession)
        }
        decompressionSession = nil
        formatDescription = nil
        textureCache = nil
        currentCodec = nil
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

    private func renderBGRAFrame(data: Data, width: Int, height: Int, stride: Int) -> RenderMetrics {
        guard width > 0, height > 0 else {
            return RenderMetrics(bandwidthMbps: 0, latencyMilliseconds: 0)
        }
        let byteCount = data.count
        let delta = interFrameInterval()
        let bandwidth = calculateBandwidth(bytes: byteCount, delta: delta)
        guard let textureCache, let device else {
            log.error("Metal device unavailable; BGRA frame fallback active")
            return RenderMetrics(bandwidthMbps: bandwidth, latencyMilliseconds: delta * 1000)
        }

        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferBytesPerRowAlignmentKey: stride
        ]

        let status = CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            UnsafeMutableRawPointer(mutating: (data as NSData).bytes),
            stride,
            nil,
            nil,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            log.error("Failed to build CVPixelBuffer for BGRA frame: %{public}d", status)
            return RenderMetrics(bandwidthMbps: bandwidth, latencyMilliseconds: delta * 1000)
        }

        guard let commandQueue, let commandBuffer = commandQueue.makeCommandBuffer() else {
            log.error("Unable to create Metal command buffer")
            return RenderMetrics(bandwidthMbps: bandwidth, latencyMilliseconds: delta * 1000)
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
            log.error("Failed to create Metal texture from BGRA frame: %{public}d", textureStatus)
            return RenderMetrics(bandwidthMbps: bandwidth, latencyMilliseconds: delta * 1000)
        }

        commandBuffer.commit()
        return RenderMetrics(bandwidthMbps: bandwidth, latencyMilliseconds: delta * 1000)
    }

    private func renderCompressedFrame(data: Data, width: Int, height: Int, codec: RemoteFrameType) -> RenderMetrics {
        guard width > 0, height > 0 else {
            return RenderMetrics(bandwidthMbps: 0, latencyMilliseconds: 0)
        }
        configureFormatDescriptionIfNeeded(width: width, height: height, codec: codec)
        guard let formatDescription else {
            log.error("Missing format description; cannot decode codec %{public}@", String(describing: codec))
            return RenderMetrics(bandwidthMbps: 0, latencyMilliseconds: 0)
        }
        ensureDecompressionSession(formatDescription: formatDescription, codec: codec)
        let delta = interFrameInterval()
        let bandwidth = calculateBandwidth(bytes: data.count, delta: delta)

        guard let decompressionSession else {
            log.error("No decompression session available for codec %{public}@", String(describing: codec))
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
            log.error("Failed to create CMBlockBuffer: %{public}d", status)
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
            log.error("Unable to create sample buffer for decoding: %{public}d", status)
            return RenderMetrics(bandwidthMbps: bandwidth, latencyMilliseconds: delta * 1000)
        }

        let decodeFlags = VTDecodeFrameFlags._EnableAsynchronousDecompression
        var outputFlags = VTDecodeInfoFlags()
        status = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sample,
            decodeFlags,
            nil,
            &outputFlags
        )

        if status != noErr {
            log.error("VideoToolbox decode error for codec %{public}@ status %{public}d", String(describing: codec), status)
        }

        return RenderMetrics(bandwidthMbps: bandwidth, latencyMilliseconds: delta * 1000)
    }

    private func configureFormatDescriptionIfNeeded(width: Int, height: Int, codec: RemoteFrameType) {
        guard codec != .bgra else { return }

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
            log.error("Failed to create CMVideoFormatDescription for codec %{public}@ status %{public}d", String(describing: codec), status)
        }
    }

    private func ensureDecompressionSession(formatDescription: CMVideoFormatDescription, codec: RemoteFrameType) {
        if let existing = decompressionSession {
            let currentFormat = VTDecompressionSessionGetFormatDescription(existing)
            if CMFormatDescriptionEqual(currentFormat, formatDescription) {
                return
            }
            VTDecompressionSessionWaitForAsynchronousFrames(existing)
            VTDecompressionSessionInvalidate(existing)
        }

        var newSession: VTDecompressionSession?
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: RemoteFrameRenderer.decompressionCallback,
            decompressionOutputRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        let destinationAttributes: [NSString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true
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
            decompressionSession = newSession
        } else {
            decompressionSession = nil
            log.error("Failed to create VTDecompressionSession for codec %{public}@ status %{public}d", String(describing: codec), status)
        }
    }

    private static func decompressionCallback(
        decompressionOutputRefCon: UnsafeMutableRawPointer?,
        sourceFrameRefCon: UnsafeMutableRawPointer?,
        status: OSStatus,
        infoFlags: VTDecodeInfoFlags,
        imageBuffer: CVImageBuffer?
    ) {
        guard let decompressionOutputRefCon else { return }
        let renderer = Unmanaged<RemoteFrameRenderer>.fromOpaque(decompressionOutputRefCon).takeUnretainedValue()
        if status != noErr {
            renderer.log.error("Decompression callback error: %{public}d, flags %{public}d", status, infoFlags.rawValue)
        } else if imageBuffer != nil {
            renderer.log.debug("Decompression callback delivered frame")
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
}
