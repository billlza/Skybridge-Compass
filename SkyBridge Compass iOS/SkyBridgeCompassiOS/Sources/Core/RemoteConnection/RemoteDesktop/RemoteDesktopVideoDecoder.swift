import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import VideoToolbox

private func RemoteDesktopReleasePixelBufferBytes(
    _ releaseRefCon: UnsafeMutableRawPointer?,
    _ baseAddress: UnsafeRawPointer?
) {
    guard let releaseRefCon else { return }
    Unmanaged<NSData>.fromOpaque(releaseRefCon).release()
}

@available(iOS 17.0, *)
final class VideoDecodeResultHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<DecodeOutput?, Error>?
    private var continuations: [CheckedContinuation<DecodeOutput?, Error>] = []

    func complete(_ result: Result<DecodeOutput?, Error>) {
        let waiters: [CheckedContinuation<DecodeOutput?, Error>]
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        waiters = continuations
        continuations.removeAll(keepingCapacity: false)
        lock.unlock()

        for continuation in waiters {
            continuation.resume(with: result)
        }
    }

    func wait() async throws -> DecodeOutput? {
        try await withCheckedThrowingContinuation { continuation in
            let completed: Result<DecodeOutput?, Error>?
            lock.lock()
            completed = result
            if completed == nil {
                continuations.append(continuation)
            }
            lock.unlock()

            if let completed {
                continuation.resume(with: completed)
            }
        }
    }
}

@available(iOS 17.0, *)
enum VideoDecodeSubmittedOutput: Sendable {
    case completed(DecodeOutput?)
    case pending(VideoDecodeResultHandle)
}

@available(iOS 17.0, *)
struct VideoDecodeSubmission: Sendable {
    let output: VideoDecodeSubmittedOutput
    let failureReason: String?
}

// MARK: - Video Decoder

/// 视频解码器
@available(iOS 17.0, *)
actor VideoDecoder {
    private enum Codec: Sendable {
        case h264
        case hevc
    }
    private let nominalPresentationStep = CMTime(value: 1, timescale: 60)
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var activeCodec: Codec?
    private var h264SPS: Data?
    private var h264PPS: Data?
    private var hevcVPS: Data?
    private var hevcSPS: Data?
    private var hevcPPS: Data?
    private var activeVideoDimensions: CGSize?
    private var waitingForSyncFrame = false
    private var lastPresentationTimeStamp: CMTime?
    private var lastDecodeFailureLogTime: Date = .distantPast
    private var lastDecodeFailureReason: String?
    private var hasLoggedFirstVideoAccessUnit = false
    private let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .priorityRequestLow: false
    ])

    /// 解码 H.264/HEVC 帧
    func decode(screenData: ScreenData) async throws -> DecodeOutput? {
        let submission = try await submit(screenData: screenData)
        switch submission.output {
        case .completed(let output):
            return output
        case .pending(let handle):
            return try await handle.wait()
        }
    }

    /// Submit a frame to the decoder in actor order without waiting for an
    /// asynchronous VideoToolbox callback. Callers must await the returned
    /// handle separately so the next access unit can enter the VT session in
    /// wire order while prior callbacks are still in flight.
    func submit(screenData: ScreenData) async throws -> VideoDecodeSubmission {
        lastDecodeFailureReason = nil
        let format = (screenData.format ?? "").lowercased()
        let payload = screenData.imageData

        if format.isEmpty {
            return VideoDecodeSubmission(
                output: .completed(decodeStaticImage(payload)),
                failureReason: lastDecodeFailureReason
            )
        }

        switch format {
        case "jpeg", "jpg":
            return VideoDecodeSubmission(
                output: .completed(decodeJPEG(payload)),
                failureReason: lastDecodeFailureReason
            )
        case "h264":
            return try submitVideoFrame(
                payload,
                codec: .h264,
                width: screenData.width,
                height: screenData.height,
                isSyncFrame: screenData.isSyncFrame
            )
        case "hevc":
            return try submitVideoFrame(
                payload,
                codec: .hevc,
                width: screenData.width,
                height: screenData.height,
                isSyncFrame: screenData.isSyncFrame
            )
        case "bgra":
            return VideoDecodeSubmission(
                output: .completed(decodeBGRA(payload, width: screenData.width, height: screenData.height)),
                failureReason: lastDecodeFailureReason
            )
        default:
            return VideoDecodeSubmission(
                output: .completed(decodeStaticImage(payload)),
                failureReason: lastDecodeFailureReason
            )
        }
    }

    private func decodeJPEG(_ data: Data) -> DecodeOutput? {
        decodeStaticImage(data)
    }

    private func decodeStaticImage(_ data: Data) -> DecodeOutput? {
        if let pixelBufferFrame = makeStillImagePixelBufferFrame(from: data) {
            return .pixelBuffer(pixelBufferFrame)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return .image(DecodedImageFrame(image: image))
    }

    private func decodeBGRA(_ data: Data, width: Int, height: Int) -> DecodeOutput? {
        guard width > 0, height > 0 else { return nil }
        let expectedMinBytes = width * height * 4
        guard data.count >= expectedMinBytes else { return nil }

        if let pixelBuffer = makeBGRAFramePixelBuffer(data: data, width: width, height: height) {
            let pixelBufferFrame = DecodedPixelBufferFrame(
                pixelBuffer: pixelBuffer,
                width: width,
                height: height,
                presentationTimeStamp: nextDecodePresentationTimeStamp()
            )
            return .pixelBuffer(pixelBufferFrame)
        }

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            return nil
        }
        return .image(DecodedImageFrame(image: image))
    }

    nonisolated func isStillImageFormat(_ format: String) -> Bool {
        switch format {
        case "", "jpeg", "jpg", "bgra":
            return true
        default:
            return false
        }
    }

    func markStreamDisrupted(format: String, width: Int, height: Int) {
        let normalized = format.lowercased()
        guard !isStillImageFormat(normalized) else {
            resetDecoderState(keepLastFrame: true)
            activeCodec = nil
            activeVideoDimensions = nil
            waitingForSyncFrame = false
            clearVideoParameterSets()
            return
        }

        guard let codec = codec(for: normalized) else { return }
        resetDecoderState(keepLastFrame: true)
        activeCodec = codec
        activeVideoDimensions = CGSize(width: width, height: height)
        waitingForSyncFrame = true
        clearVideoParameterSets()
    }

    private func decodeVideoFrame(
        _ data: Data,
        codec: Codec,
        width: Int,
        height: Int,
        isSyncFrame: Bool?
    ) async throws -> DecodeOutput? {
        let submission = try submitVideoFrame(
            data,
            codec: codec,
            width: width,
            height: height,
            isSyncFrame: isSyncFrame
        )
        switch submission.output {
        case .completed(let output):
            return output
        case .pending(let handle):
            return try await handle.wait()
        }
    }

    private func submitVideoFrame(
        _ data: Data,
        codec: Codec,
        width: Int,
        height: Int,
        isSyncFrame: Bool?
    ) throws -> VideoDecodeSubmission {
        let dimensions = CGSize(width: width, height: height)
        let streamChanged = activeCodec != codec || activeVideoDimensions != dimensions
        if streamChanged {
            resetDecoderState(keepLastFrame: true)
            activeCodec = codec
            activeVideoDimensions = dimensions
            waitingForSyncFrame = true
            clearVideoParameterSets()
        }

        let nalus = parseNALUnits(from: data)
        let accessUnitSummary = videoAccessUnitSummary(codec: codec, nalus: nalus)
        let requiresReset = updateParameterSetsIfPresent(from: data, codec: codec, nalus: nalus)
        if requiresReset {
            resetDecoderState(keepLastFrame: true)
            waitingForSyncFrame = true
        }

        let containsSyncFrame = containsSyncFrame(in: nalus, codec: codec)
        if waitingForSyncFrame, !containsSyncFrame {
            logDecodeFailureIfNeeded(
                codec: codec,
                dataSize: data.count,
                reason: "waiting-for-sync-frame \(accessUnitSummary)"
            )
            return VideoDecodeSubmission(
                output: .completed(nil),
                failureReason: lastDecodeFailureReason
            )
        }

        if formatDescription == nil {
            try buildFormatDescriptionIfPossible(codec: codec)
        }
        guard let formatDescription else {
            if waitingForSyncFrame {
                logDecodeFailureIfNeeded(
                    codec: codec,
                    dataSize: data.count,
                    reason: "missing-parameter-sets"
                )
                return VideoDecodeSubmission(
                    output: .completed(nil),
                    failureReason: lastDecodeFailureReason
                )
            }
            return VideoDecodeSubmission(output: .completed(nil), failureReason: lastDecodeFailureReason)
        }

        guard let sampleData = makeDecoderSampleData(from: data, codec: codec) else {
            return VideoDecodeSubmission(output: .completed(nil), failureReason: lastDecodeFailureReason)
        }

        let sampleBuffer = try makeSampleBuffer(
            naluData: sampleData,
            formatDescription: formatDescription,
            presentationTimeStamp: nextDecodePresentationTimeStamp(),
            isSyncFrame: containsSyncFrame
        )
        logFirstVideoAccessUnitIfNeeded(
            codec: codec,
            nalus: nalus,
            sourceBytes: data.count,
            sampleBytes: sampleData.count,
            advertisedSyncFrame: isSyncFrame,
            verifiedSyncFrame: containsSyncFrame
        )
        let handle = try submitPixelBufferDecode(
            sampleBuffer,
            codec: codec,
            width: width,
            height: height,
            accessUnitSummary: accessUnitSummary
        )

        activeVideoDimensions = dimensions
        waitingForSyncFrame = false
        return VideoDecodeSubmission(output: .pending(handle), failureReason: lastDecodeFailureReason)
    }

    private func resetDecoderState(keepLastFrame: Bool) {
        _ = keepLastFrame
        if let decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
            VTDecompressionSessionInvalidate(decompressionSession)
        }
        decompressionSession = nil
        formatDescription = nil
        hasLoggedFirstVideoAccessUnit = false
    }

    private func updateParameterSetsIfPresent(from data: Data, codec: Codec, nalus: [Data]? = nil) -> Bool {
        var didChange = false

        func update(_ current: inout Data?, new: Data) {
            if current != new {
                current = new
                didChange = true
            }
        }

        let units = nalus ?? parseNALUnits(from: data)
        for nalu in units {
            guard let first = nalu.first else { continue }
            switch codec {
            case .h264:
                let type = Int(first & 0x1F)
                switch type {
                case 7: update(&h264SPS, new: nalu)
                case 8: update(&h264PPS, new: nalu)
                default: break
                }
            case .hevc:
                let type = Int((first >> 1) & 0x3F)
                switch type {
                case 32: update(&hevcVPS, new: nalu)
                case 33: update(&hevcSPS, new: nalu)
                case 34: update(&hevcPPS, new: nalu)
                default: break
                }
            }
        }

        return didChange
    }

    private func containsSyncFrame(in nalus: [Data], codec: Codec) -> Bool {
        for nalu in nalus {
            guard let first = nalu.first else { continue }
            switch codec {
            case .h264:
                let type = Int(first & 0x1F)
                if type == 5 {
                    return true
                }
            case .hevc:
                let type = Int((first >> 1) & 0x3F)
                if (16...21).contains(type) {
                    return true
                }
            }
        }
        return false
    }

    private func videoAccessUnitSummary(codec: Codec, nalus: [Data]) -> String {
        let naluTypes = nalus
            .prefix(16)
            .map { nalu -> String in
                guard let first = nalu.first else { return "empty" }
                switch codec {
                case .h264:
                    return String(Int(first & 0x1F))
                case .hevc:
                    return String(Int((first >> 1) & 0x3F))
                }
            }
            .joined(separator: ",")
        let parameterSetCount = nalus.filter { isParameterSetNALU($0, codec: codec) }.count
        let renderableCount = nalus.filter { isRenderableNALU($0, codec: codec) }.count
        return "auNalCount=\(nalus.count) auTypes=\(naluTypes) auParameterSets=\(parameterSetCount) auRenderable=\(renderableCount)"
    }

    private func clearVideoParameterSets() {
        h264SPS = nil
        h264PPS = nil
        hevcVPS = nil
        hevcSPS = nil
        hevcPPS = nil
    }

    private func codec(for format: String) -> Codec? {
        switch format {
        case "h264":
            return .h264
        case "hevc":
            return .hevc
        default:
            return nil
        }
    }

    private func buildFormatDescriptionIfPossible(codec: Codec) throws {
        switch codec {
        case .h264:
            guard let sps = h264SPS, let pps = h264PPS else { return }
            var out: CMFormatDescription?
            let status = sps.withUnsafeBytes { spsRaw -> OSStatus in
                guard let spsBase = spsRaw.baseAddress else { return -1 }
                return pps.withUnsafeBytes { ppsRaw -> OSStatus in
                    guard let ppsBase = ppsRaw.baseAddress else { return -1 }
	                    let pointers: [UnsafePointer<UInt8>] = [
	                        spsBase.assumingMemoryBound(to: UInt8.self),
	                        ppsBase.assumingMemoryBound(to: UInt8.self)
	                    ]
	                    let sizes: [Int] = [sps.count, pps.count]
		                    return pointers.withUnsafeBufferPointer { ptrs in
		                        sizes.withUnsafeBufferPointer { sz in
	                                guard let parameterSetPointers = ptrs.baseAddress,
	                                      let parameterSetSizes = sz.baseAddress else {
	                                    return -1
	                                }
		                            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
		                                allocator: kCFAllocatorDefault,
		                                parameterSetCount: ptrs.count,
		                                parameterSetPointers: parameterSetPointers,
		                                parameterSetSizes: parameterSetSizes,
	                                nalUnitHeaderLength: 4,
	                                formatDescriptionOut: &out
	                            )
                        }
                    }
                }
            }
            guard status == noErr, let desc = out else {
                throw RemoteDesktopError.decodingFailed("Failed to build H.264 format description (status=\(status))")
            }
            formatDescription = desc

        case .hevc:
            guard let vps = hevcVPS, let sps = hevcSPS, let pps = hevcPPS else { return }
            var out: CMFormatDescription?
            let status = vps.withUnsafeBytes { vpsRaw -> OSStatus in
                guard let vpsBase = vpsRaw.baseAddress else { return -1 }
                return sps.withUnsafeBytes { spsRaw -> OSStatus in
                    guard let spsBase = spsRaw.baseAddress else { return -1 }
                    return pps.withUnsafeBytes { ppsRaw -> OSStatus in
                        guard let ppsBase = ppsRaw.baseAddress else { return -1 }
                        let pointers: [UnsafePointer<UInt8>] = [
                            vpsBase.assumingMemoryBound(to: UInt8.self),
                            spsBase.assumingMemoryBound(to: UInt8.self),
                            ppsBase.assumingMemoryBound(to: UInt8.self)
	                        ]
	                        let sizes: [Int] = [vps.count, sps.count, pps.count]
		                        return pointers.withUnsafeBufferPointer { ptrs in
		                            sizes.withUnsafeBufferPointer { sz in
	                                    guard let parameterSetPointers = ptrs.baseAddress,
	                                          let parameterSetSizes = sz.baseAddress else {
	                                        return -1
	                                    }
		                                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
		                                    allocator: kCFAllocatorDefault,
		                                    parameterSetCount: ptrs.count,
		                                    parameterSetPointers: parameterSetPointers,
		                                    parameterSetSizes: parameterSetSizes,
	                                    nalUnitHeaderLength: 4,
	                                    extensions: nil,
	                                    formatDescriptionOut: &out
                                )
                            }
                        }
                    }
                }
            }
            guard status == noErr, let desc = out else {
                throw RemoteDesktopError.decodingFailed("Failed to build HEVC format description (status=\(status))")
            }
            formatDescription = desc
        }
    }

    private func ensureDecompressionSession(
        codec: Codec,
        formatDescription: CMVideoFormatDescription
    ) throws {
        if decompressionSession != nil,
           let activeDescription = self.formatDescription,
           CMFormatDescriptionEqual(activeDescription, otherFormatDescription: formatDescription) {
            _ = codec
            return
        }

        if let decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
            VTDecompressionSessionInvalidate(decompressionSession)
            self.decompressionSession = nil
        }

        let decoderSpecification: CFDictionary = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true
        ] as CFDictionary

        let destinationAttributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpecification,
            imageBufferAttributes: destinationAttributes,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw RemoteDesktopError.decodingFailed(
                "Failed to create decompression session (status=\(status))"
            )
        }
        let realtimeStatus = VTSessionSetProperty(
            session,
            key: kVTDecompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )
        guard realtimeStatus == noErr else {
            throw RemoteDesktopError.decodingFailed(
                "Failed to enable realtime hardware decode (status=\(realtimeStatus))"
            )
        }
        decompressionSession = session
    }

    private func decodeToPixelBufferFrame(
        _ sampleBuffer: CMSampleBuffer,
        codec: Codec,
        width: Int,
        height: Int,
        accessUnitSummary: String
    ) async throws -> DecodedPixelBufferFrame? {
        let output = try await submitPixelBufferDecode(
            sampleBuffer,
            codec: codec,
            width: width,
            height: height,
            accessUnitSummary: accessUnitSummary
        ).wait()
        guard case .pixelBuffer(let frame) = output else { return nil }
        return frame
    }

    private func submitPixelBufferDecode(
        _ sampleBuffer: CMSampleBuffer,
        codec: Codec,
        width: Int,
        height: Int,
        accessUnitSummary: String
    ) throws -> VideoDecodeResultHandle {
        guard let formatDescription else {
            let handle = VideoDecodeResultHandle()
            handle.complete(.success(nil))
            return handle
        }
        try ensureDecompressionSession(codec: codec, formatDescription: formatDescription)
        guard let decompressionSession else {
            let handle = VideoDecodeResultHandle()
            handle.complete(.success(nil))
            return handle
        }

        let handle = VideoDecodeResultHandle()
        var decodeInfoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &decodeInfoFlags
        ) { status, _, imageBuffer, presentationTimeStamp, _ in
            guard status == noErr else {
                handle.complete(
                    .failure(
                        RemoteDesktopError.decodingFailed(
                            "VideoToolbox callback status=\(status) \(accessUnitSummary)"
                        )
                    )
                )
                return
            }
            guard let imageBuffer else {
                handle.complete(.failure(RemoteDesktopError.decodingFailed("callback-no-image")))
                return
            }
            let pixelBuffer = imageBuffer as CVPixelBuffer
            handle.complete(
                .success(
                    .pixelBuffer(
                        DecodedPixelBufferFrame(
                        pixelBuffer: pixelBuffer,
                        width: width,
                        height: height,
                        presentationTimeStamp: presentationTimeStamp
                        )
                    )
                )
            )
        }

        if status != noErr {
            handle.complete(
                .failure(
                    RemoteDesktopError.decodingFailed(
                        "VideoToolbox decode failed (status=\(status))"
                    )
                )
            )
        }
        return handle
    }

    private func makeSampleBuffer(
        naluData: Data,
        formatDescription: CMVideoFormatDescription,
        presentationTimeStamp: CMTime,
        isSyncFrame: Bool
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: naluData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: naluData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw RemoteDesktopError.decodingFailed("CMBlockBufferCreateWithMemoryBlock failed (status=\(status))")
        }

        let replaceStatus = naluData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: naluData.count)
        }
        guard replaceStatus == kCMBlockBufferNoErr else {
            throw RemoteDesktopError.decodingFailed("CMBlockBufferReplaceDataBytes failed (status=\(replaceStatus))")
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = naluData.count
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sampleBuffer else {
            throw RemoteDesktopError.decodingFailed("CMSampleBufferCreate failed (status=\(sbStatus))")
        }
        setDecoderSampleAttachments(on: sampleBuffer, isSyncFrame: isSyncFrame)
        return sampleBuffer
    }

    private func setDecoderSampleAttachments(on sampleBuffer: CMSampleBuffer, isSyncFrame: Bool) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) else {
            return
        }
        guard CFArrayGetCount(attachments) > 0 else { return }
        let dictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
            Unmanaged.passUnretained(isSyncFrame ? kCFBooleanFalse : kCFBooleanTrue).toOpaque()
        )
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque(),
            Unmanaged.passUnretained(isSyncFrame ? kCFBooleanFalse : kCFBooleanTrue).toOpaque()
        )
    }

    private func logFirstVideoAccessUnitIfNeeded(
        codec: Codec,
        nalus: [Data],
        sourceBytes: Int,
        sampleBytes: Int,
        advertisedSyncFrame: Bool?,
        verifiedSyncFrame: Bool
    ) {
        guard !hasLoggedFirstVideoAccessUnit else { return }
        hasLoggedFirstVideoAccessUnit = true
        let typeSummary = nalus
            .prefix(12)
            .map { nalu -> String in
                guard let first = nalu.first else { return "empty" }
                switch codec {
                case .h264:
                    return String(Int(first & 0x1F))
                case .hevc:
                    return String(Int((first >> 1) & 0x3F))
                }
            }
            .joined(separator: ",")
        let parameterSetCount = nalus.filter { isParameterSetNALU($0, codec: codec) }.count
        let renderableCount = nalus.filter { isRenderableNALU($0, codec: codec) }.count
        let codecName: String
        switch codec {
        case .h264: codecName = "h264"
        case .hevc: codecName = "hevc"
        }
        let line = """
        video-decode-first-au codec=\(codecName) sourceBytes=\(sourceBytes) \
        sampleBytes=\(sampleBytes) nalus=\(nalus.count) naluTypes=\(typeSummary) \
        parameterSets=\(parameterSetCount) renderable=\(renderableCount) \
        advertisedSync=\(advertisedSyncFrame == true ? "true" : (advertisedSyncFrame == false ? "false" : "nil")) \
        verifiedSync=\(verifiedSyncFrame)
        """
        SkyBridgeLogger.shared.info("🧪 \(line)")
        SkyBridgeSmokeTraceWriter.appendStatus(line)
    }

    private func nextDecodePresentationTimeStamp() -> CMTime {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if let lastPresentationTimeStamp {
            let minimumNext = CMTimeAdd(lastPresentationTimeStamp, nominalPresentationStep)
            if now < minimumNext {
                self.lastPresentationTimeStamp = minimumNext
                return minimumNext
            }
        }
        lastPresentationTimeStamp = now
        return now
    }

    private func makeStillImagePixelBufferFrame(from data: Data) -> DecodedPixelBufferFrame? {
        guard let ciImage = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        let extent = ciImage.extent.integral
        guard extent.width > 0, extent.height > 0,
              let pixelBuffer = makeMetalCompatiblePixelBuffer(
                width: Int(extent.width),
                height: Int(extent.height)
              ) else {
            return nil
        }

        let normalizedImage = ciImage.transformed(
            by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
        )
        ciContext.render(
            normalizedImage,
            to: pixelBuffer,
            bounds: CGRect(origin: .zero, size: extent.size),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return DecodedPixelBufferFrame(
            pixelBuffer: pixelBuffer,
            width: Int(extent.width),
            height: Int(extent.height),
            presentationTimeStamp: nextDecodePresentationTimeStamp()
        )
    }

    func makeDisplaySampleBufferFrame(
        from pixelBufferFrame: DecodedPixelBufferFrame,
        format: String?
    ) -> DisplaySampleBufferFrame? {
        guard let sampleBuffer = makeImageBufferSampleBuffer(
            pixelBuffer: pixelBufferFrame.pixelBuffer,
            presentationTimeStamp: pixelBufferFrame.presentationTimeStamp
        ) else {
            return nil
        }
        _ = format
        return DisplaySampleBufferFrame(
            sampleBuffer: sampleBuffer,
            width: pixelBufferFrame.width,
            height: pixelBufferFrame.height,
            presentationTimeStamp: pixelBufferFrame.presentationTimeStamp
        )
    }

    private func makeImageBufferSampleBuffer(
        pixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime
    ) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let descriptionStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard descriptionStatus == noErr, let formatDescription else { return nil }

        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return nil }
        setDisplayImmediatelyAttachment(on: sampleBuffer)
        return sampleBuffer
    }

    private func setDisplayImmediatelyAttachment(on sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) else {
            return
        }
        guard CFArrayGetCount(attachments) > 0 else { return }
        let dictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    private func makeBGRAFramePixelBuffer(
        data: Data,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let bytesPerRow = width * 4
        let storage = data as NSData
        let retained = Unmanaged.passRetained(storage)
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            UnsafeMutableRawPointer(mutating: storage.bytes),
            bytesPerRow,
            RemoteDesktopReleasePixelBufferBytes,
            retained.toOpaque(),
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess else {
            retained.release()
            return nil
        }
        return pixelBuffer
    }

    private func makeMetalCompatiblePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    private func parseNALUnits(from data: Data) -> [Data] {
        if data.count >= 4, data.starts(with: [0x00, 0x00, 0x00, 0x01]) || data.starts(with: [0x00, 0x00, 0x01]) {
            return parseAnnexBNALUnits(from: data)
        }
        return parseLengthPrefixedNALUnits(from: data)
    }

    private func makeDecoderSampleData(from data: Data, codec: Codec) -> Data? {
        let nalus = parseNALUnits(from: data)
        guard !nalus.isEmpty else { return data.isEmpty ? nil : data }

        var hasRenderableNALU = false
        var output = Data()
        output.reserveCapacity(data.count + (nalus.count * 4))

        for nalu in nalus {
            guard !nalu.isEmpty else { continue }
            // Skip parameter set NALUs — they are already conveyed via
            // CMVideoFormatDescription.  Including them in-band causes
            // AVSampleBufferDisplayLayer to silently stop decoding after
            // the first IDR frame (the "first-frame-only-freeze" symptom).
            if isParameterSetNALU(nalu, codec: codec) {
                continue
            }
            if isRenderableNALU(nalu, codec: codec) {
                hasRenderableNALU = true
            }

            var length = UInt32(nalu.count).bigEndian
            withUnsafeBytes(of: &length) { rawBuffer in
                output.append(contentsOf: rawBuffer)
            }
            output.append(nalu)
        }

        guard hasRenderableNALU else { return nil }
        return output.isEmpty ? nil : output
    }

    private func isParameterSetNALU(_ nalu: Data, codec: Codec) -> Bool {
        guard let first = nalu.first else { return false }
        switch codec {
        case .h264:
            let type = Int(first & 0x1F)
            // 7 = SPS, 8 = PPS
            return type == 7 || type == 8
        case .hevc:
            let type = Int((first >> 1) & 0x3F)
            // 32 = VPS, 33 = SPS, 34 = PPS
            return (32...34).contains(type)
        }
    }

    private func isRenderableNALU(_ nalu: Data, codec: Codec) -> Bool {
        guard let first = nalu.first else { return false }
        switch codec {
        case .h264:
            let type = Int(first & 0x1F)
            return (1...5).contains(type)
        case .hevc:
            let type = Int((first >> 1) & 0x3F)
            return (0...31).contains(type)
        }
    }

    private func parseLengthPrefixedNALUnits(from data: Data) -> [Data] {
        var nalus: [Data] = []
        var offset = 0
        while offset + 4 <= data.count {
            let length = data.withUnsafeBytes { raw -> Int in
                let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                return Int(UInt32(bigEndian: v))
            }
            offset += 4
            guard length > 0, offset + length <= data.count else { break }
            nalus.append(data.subdata(in: offset..<(offset + length)))
            offset += length
        }
        return nalus
    }

    private func parseAnnexBNALUnits(from data: Data) -> [Data] {
        func isStartCode(at i: Int) -> Int? {
            guard i + 3 <= data.count else { return nil }
            if i + 4 <= data.count,
               data[i] == 0x00, data[i + 1] == 0x00, data[i + 2] == 0x00, data[i + 3] == 0x01 {
                return 4
            }
            if data[i] == 0x00, data[i + 1] == 0x00, data[i + 2] == 0x01 {
                return 3
            }
            return nil
        }

        var nalus: [Data] = []
        var i = 0
        var currentStart: Int?
        var currentSkip = 0

        while i < data.count {
            if let skip = isStartCode(at: i) {
                if let start = currentStart {
                    let naluStart = start + currentSkip
                    if naluStart < i {
                        nalus.append(data.subdata(in: naluStart..<i))
                    }
                }
                currentStart = i
                currentSkip = skip
                i += skip
            } else {
                i += 1
            }
        }

        if let start = currentStart {
            let naluStart = start + currentSkip
            if naluStart < data.count {
                nalus.append(data.subdata(in: naluStart..<data.count))
            }
        }
        return nalus
    }

    func cleanup() {
        resetDecoderState(keepLastFrame: false)
        activeCodec = nil
        activeVideoDimensions = nil
        waitingForSyncFrame = false
        lastPresentationTimeStamp = nil
        lastDecodeFailureReason = nil
        clearVideoParameterSets()
    }

    func resetPreservingLastFrame() {
        resetDecoderState(keepLastFrame: true)
        waitingForSyncFrame = true
        clearVideoParameterSets()
    }

    func consumeLastFailureReason() -> String? {
        defer { lastDecodeFailureReason = nil }
        return lastDecodeFailureReason
    }

    private func logDecodeFailureIfNeeded(codec: Codec, dataSize: Int, reason: String) {
        lastDecodeFailureReason = reason
        let now = Date()
        guard now.timeIntervalSince(lastDecodeFailureLogTime) >= 1.0 else { return }
        lastDecodeFailureLogTime = now
        SkyBridgeLogger.shared.warning("⚠️ 视频解码失败: codec=\(String(describing: codec)) bytes=\(dataSize) reason=\(reason)")
    }
}
