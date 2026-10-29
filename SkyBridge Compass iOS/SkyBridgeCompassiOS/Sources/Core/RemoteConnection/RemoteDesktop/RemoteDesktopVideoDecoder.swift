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
private enum VideoDecodeResultHandleError: Error, LocalizedError, Sendable {
    case callbackTimedOut

    var errorDescription: String? {
        "VideoToolbox did not complete the frame within the 2-second decode deadline."
    }
}

@available(iOS 17.0, *)
final class VideoDecodeResultHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<DecodeOutput?, Error>?
    private var continuations: [UUID: CheckedContinuation<DecodeOutput?, Error>] = [:]
    private var timeoutTask: Task<Void, Never>?

    init() {
        timeoutTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            self?.complete(.failure(VideoDecodeResultHandleError.callbackTimedOut))
        }
    }

    func complete(_ result: Result<DecodeOutput?, Error>) {
        let waiters: [CheckedContinuation<DecodeOutput?, Error>]
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        timeoutTask?.cancel()
        timeoutTask = nil
        waiters = Array(continuations.values)
        continuations.removeAll(keepingCapacity: false)
        lock.unlock()

        for continuation in waiters {
            continuation.resume(with: result)
        }
    }

    func wait() async throws -> DecodeOutput? {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completed: Result<DecodeOutput?, Error>?
                lock.lock()
                completed = result
                if completed == nil, !Task.isCancelled {
                    continuations[waiterID] = continuation
                }
                lock.unlock()

                if let completed {
                    continuation.resume(with: completed)
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: { [weak self] in
            self?.cancelWaiter(waiterID)
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: waiterID)
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
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

@available(iOS 17.0, *)
enum RemoteDesktopVideoDecoderInputError: Error, Equatable, LocalizedError, Sendable {
    case invalidDimensions
    case dimensionLimitExceeded(actual: Int, maximum: Int)
    case decodedFrameTooLarge(actualBytes: Int, maximumBytes: Int)
    case encodedImageTooLarge(actualBytes: Int, maximumBytes: Int)
    case invalidStaticImageMetadata
    case staticImageSourceUnavailable
    case staticImageDecodeFailed
    case bgraByteCountMismatch(expected: Int, actual: Int)
    case accessUnitTooLarge(actualBytes: Int, maximumBytes: Int)
    case tooManyNALUnits(actual: Int, maximum: Int)
    case nalUnitTooLarge(actualBytes: Int, maximumBytes: Int)
    case malformedAccessUnit

    var errorDescription: String? {
        switch self {
        case .invalidDimensions:
            return "Decoded frame dimensions must be finite, positive integers."
        case .dimensionLimitExceeded(let actual, let maximum):
            return "Decoded frame dimension \(actual) exceeds the published \(maximum)-pixel limit."
        case .decodedFrameTooLarge(let actualBytes, let maximumBytes):
            return "Decoded BGRA frame requires \(actualBytes) bytes, exceeding the \(maximumBytes)-byte limit."
        case .encodedImageTooLarge(let actualBytes, let maximumBytes):
            return "Encoded still image contains \(actualBytes) bytes, exceeding the \(maximumBytes)-byte limit."
        case .invalidStaticImageMetadata:
            return "The still image does not contain valid bounded pixel metadata."
        case .staticImageSourceUnavailable:
            return "The still-image payload is not a supported ImageIO source."
        case .staticImageDecodeFailed:
            return "ImageIO could not decode the validated still-image payload."
        case .bgraByteCountMismatch(let expected, let actual):
            return "BGRA payload size mismatch: expected \(expected) bytes, received \(actual)."
        case .accessUnitTooLarge(let actualBytes, let maximumBytes):
            return "Video access unit contains \(actualBytes) bytes, exceeding the \(maximumBytes)-byte limit."
        case .tooManyNALUnits(let actual, let maximum):
            return "Video access unit contains \(actual) NAL units, exceeding the \(maximum)-unit limit."
        case .nalUnitTooLarge(let actualBytes, let maximumBytes):
            return "NAL unit contains \(actualBytes) bytes, exceeding the \(maximumBytes)-byte limit."
        case .malformedAccessUnit:
            return "Video access unit is neither complete Annex-B nor complete 4-byte length-prefixed data."
        }
    }
}

@available(iOS 17.0, *)
struct RemoteDesktopValidatedPixelDimensions: Equatable, Sendable {
    let width: Int
    let height: Int
    let pixelBytes: Int
}

@available(iOS 17.0, *)
enum RemoteDesktopVideoDecoderLimits {
    // The public remote-desktop protocol tops out at 5K. A single-dimension
    // cap plus the 5K pixel budget also permits an equivalent portrait frame.
    static let maximumDimension = 5_120
    static let maximumPixelCount = 5_120 * 2_880
    static let maximumDecodedPixelBytes = maximumPixelCount * 4
    static let maximumEncodedImageBytes = 8 * 1_024 * 1_024
    static let maximumAccessUnitBytes = 8 * 1_024 * 1_024
    static let maximumNALUnits = 512
    static let maximumParameterSetBytes = 64 * 1_024
}

@available(iOS 17.0, *)
enum RemoteDesktopVideoDecoderInputValidator {
    static func validatedPixelDimensions(
        width: Int,
        height: Int
    ) throws -> RemoteDesktopValidatedPixelDimensions {
        guard width > 0, height > 0 else {
            throw RemoteDesktopVideoDecoderInputError.invalidDimensions
        }

        let largestDimension = max(width, height)
        guard largestDimension <= RemoteDesktopVideoDecoderLimits.maximumDimension else {
            throw RemoteDesktopVideoDecoderInputError.dimensionLimitExceeded(
                actual: largestDimension,
                maximum: RemoteDesktopVideoDecoderLimits.maximumDimension
            )
        }

        let (pixelCount, pixelCountOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelCountOverflow else {
            throw RemoteDesktopVideoDecoderInputError.invalidDimensions
        }
        let (pixelBytes, pixelByteCountOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelByteCountOverflow else {
            throw RemoteDesktopVideoDecoderInputError.invalidDimensions
        }
        guard pixelCount <= RemoteDesktopVideoDecoderLimits.maximumPixelCount,
              pixelBytes <= RemoteDesktopVideoDecoderLimits.maximumDecodedPixelBytes else {
            throw RemoteDesktopVideoDecoderInputError.decodedFrameTooLarge(
                actualBytes: pixelBytes,
                maximumBytes: RemoteDesktopVideoDecoderLimits.maximumDecodedPixelBytes
            )
        }

        return RemoteDesktopValidatedPixelDimensions(
            width: width,
            height: height,
            pixelBytes: pixelBytes
        )
    }

    static func validatedPixelDimensions(
        width: Double,
        height: Double
    ) throws -> RemoteDesktopValidatedPixelDimensions {
        guard width.isFinite,
              height.isFinite,
              let integerWidth = Int(exactly: width),
              let integerHeight = Int(exactly: height) else {
            throw RemoteDesktopVideoDecoderInputError.invalidDimensions
        }
        return try validatedPixelDimensions(width: integerWidth, height: integerHeight)
    }

    static func validatedPixelDimensions(
        of formatDescription: CMVideoFormatDescription
    ) throws -> RemoteDesktopValidatedPixelDimensions {
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        return try validatedPixelDimensions(
            width: Int(dimensions.width),
            height: Int(dimensions.height)
        )
    }

    static func validateEncodedImageByteCount(_ byteCount: Int) throws {
        guard byteCount > 0 else {
            throw RemoteDesktopVideoDecoderInputError.staticImageSourceUnavailable
        }
        guard byteCount <= RemoteDesktopVideoDecoderLimits.maximumEncodedImageBytes else {
            throw RemoteDesktopVideoDecoderInputError.encodedImageTooLarge(
                actualBytes: byteCount,
                maximumBytes: RemoteDesktopVideoDecoderLimits.maximumEncodedImageBytes
            )
        }
    }
}

@available(iOS 17.0, *)
enum RemoteDesktopVideoParameterSetKind: Sendable {
    case vps
    case sps
    case pps
}

@available(iOS 17.0, *)
enum RemoteDesktopVideoCodec: Equatable, Sendable {
    case h264
    case hevc

    var minimumNALUnitBytes: Int {
        switch self {
        case .h264: return 1
        case .hevc: return 2
        }
    }

    func parameterSetKind(firstByte: UInt8) -> RemoteDesktopVideoParameterSetKind? {
        switch self {
        case .h264:
            let type = Int(firstByte & 0x1F)
            switch type {
            case 7: return .sps
            case 8: return .pps
            default: return nil
            }
        case .hevc:
            let type = Int((firstByte >> 1) & 0x3F)
            switch type {
            case 32: return .vps
            case 33: return .sps
            case 34: return .pps
            default: return nil
            }
        }
    }

    func isParameterSet(firstByte: UInt8) -> Bool {
        parameterSetKind(firstByte: firstByte) != nil
    }
}

@available(iOS 17.0, *)
struct RemoteDesktopVideoParameterSetSnapshot: Equatable, Sendable {
    let codec: RemoteDesktopVideoCodec
    let vps: Data?
    let sps: Data
    let pps: Data
}

@available(iOS 17.0, *)
enum RemoteDesktopVideoParameterSetUpdate: Equatable, Sendable {
    case noChange
    case committed(changed: Bool)
    case requiresCompleteSyncSet
}

@available(iOS 17.0, *)
struct RemoteDesktopVideoParameterSetCoordinator: Sendable {
    private(set) var activeSnapshot: RemoteDesktopVideoParameterSetSnapshot?
    private(set) var isWaitingForCompleteSyncSet = true

    mutating func consume(
        nalus: [Data],
        codec: RemoteDesktopVideoCodec,
        containsSyncFrame: Bool
    ) -> RemoteDesktopVideoParameterSetUpdate {
        var candidateVPS: Data?
        var candidateSPS: Data?
        var candidatePPS: Data?

        for nalu in nalus {
            guard let firstByte = nalu.first,
                  let kind = codec.parameterSetKind(firstByte: firstByte) else {
                continue
            }
            switch kind {
            case .vps:
                candidateVPS = nalu
            case .sps:
                candidateSPS = nalu
            case .pps:
                candidatePPS = nalu
            }
        }

        let containsAnyParameterSet = candidateVPS != nil
            || candidateSPS != nil
            || candidatePPS != nil
        guard containsAnyParameterSet else {
            return isWaitingForCompleteSyncSet ? .requiresCompleteSyncSet : .noChange
        }

        let completeSnapshot = makeCompleteSnapshot(
            codec: codec,
            vps: candidateVPS,
            sps: candidateSPS,
            pps: candidatePPS
        )
        if isWaitingForCompleteSyncSet {
            guard containsSyncFrame, let completeSnapshot else {
                return .requiresCompleteSyncSet
            }
            let changed = activeSnapshot != completeSnapshot
            activeSnapshot = completeSnapshot
            isWaitingForCompleteSyncSet = false
            return .committed(changed: changed)
        }

        let containsChangedParameterSet = parameterSetValuesDifferFromActiveSnapshot(
            codec: codec,
            vps: candidateVPS,
            sps: candidateSPS,
            pps: candidatePPS
        )
        guard containsChangedParameterSet else { return .noChange }

        guard containsSyncFrame, let completeSnapshot else {
            isWaitingForCompleteSyncSet = true
            return .requiresCompleteSyncSet
        }

        let changed = activeSnapshot != completeSnapshot
        activeSnapshot = completeSnapshot
        isWaitingForCompleteSyncSet = false
        return .committed(changed: changed)
    }

    mutating func clear(requiresCompleteSyncSet: Bool) {
        activeSnapshot = nil
        isWaitingForCompleteSyncSet = requiresCompleteSyncSet
    }

    private func parameterSetValuesDifferFromActiveSnapshot(
        codec: RemoteDesktopVideoCodec,
        vps: Data?,
        sps: Data?,
        pps: Data?
    ) -> Bool {
        guard let activeSnapshot, activeSnapshot.codec == codec else { return true }
        if let vps, vps != activeSnapshot.vps { return true }
        if let sps, sps != activeSnapshot.sps { return true }
        if let pps, pps != activeSnapshot.pps { return true }
        return false
    }

    private func makeCompleteSnapshot(
        codec: RemoteDesktopVideoCodec,
        vps: Data?,
        sps: Data?,
        pps: Data?
    ) -> RemoteDesktopVideoParameterSetSnapshot? {
        guard let sps, let pps else { return nil }
        switch codec {
        case .h264:
            return RemoteDesktopVideoParameterSetSnapshot(
                codec: codec,
                vps: nil,
                sps: sps,
                pps: pps
            )
        case .hevc:
            guard let vps else { return nil }
            return RemoteDesktopVideoParameterSetSnapshot(
                codec: codec,
                vps: vps,
                sps: sps,
                pps: pps
            )
        }
    }
}

@available(iOS 17.0, *)
enum RemoteDesktopVideoAccessUnitParser {
    static func parse(_ data: Data, codec: RemoteDesktopVideoCodec) throws -> [Data] {
        guard !data.isEmpty else {
            throw RemoteDesktopVideoDecoderInputError.malformedAccessUnit
        }
        guard data.count <= RemoteDesktopVideoDecoderLimits.maximumAccessUnitBytes else {
            throw RemoteDesktopVideoDecoderInputError.accessUnitTooLarge(
                actualBytes: data.count,
                maximumBytes: RemoteDesktopVideoDecoderLimits.maximumAccessUnitBytes
            )
        }

        if startCodeLength(in: data, at: 0) != nil {
            return try parseAnnexB(data, codec: codec)
        }
        return try parseLengthPrefixed(data, codec: codec)
    }

    private static func parseLengthPrefixed(
        _ data: Data,
        codec: RemoteDesktopVideoCodec
    ) throws -> [Data] {
        var nalus: [Data] = []
        nalus.reserveCapacity(min(16, RemoteDesktopVideoDecoderLimits.maximumNALUnits))
        var offset = 0

        while offset < data.count {
            guard data.count - offset >= 4 else {
                throw RemoteDesktopVideoDecoderInputError.malformedAccessUnit
            }
            let declaredLength =
                (Int(byte(in: data, at: offset)) << 24)
                | (Int(byte(in: data, at: offset + 1)) << 16)
                | (Int(byte(in: data, at: offset + 2)) << 8)
                | Int(byte(in: data, at: offset + 3))
            offset += 4

            guard declaredLength > 0 else {
                throw RemoteDesktopVideoDecoderInputError.malformedAccessUnit
            }
            guard declaredLength <= data.count - offset else {
                throw RemoteDesktopVideoDecoderInputError.malformedAccessUnit
            }
            try appendNALUnit(
                from: data,
                byteRange: offset..<(offset + declaredLength),
                codec: codec,
                to: &nalus
            )
            offset += declaredLength
        }

        guard !nalus.isEmpty else {
            throw RemoteDesktopVideoDecoderInputError.malformedAccessUnit
        }
        return nalus
    }

    private static func parseAnnexB(
        _ data: Data,
        codec: RemoteDesktopVideoCodec
    ) throws -> [Data] {
        guard let firstStartCodeLength = startCodeLength(in: data, at: 0) else {
            throw RemoteDesktopVideoDecoderInputError.malformedAccessUnit
        }

        var nalus: [Data] = []
        nalus.reserveCapacity(min(16, RemoteDesktopVideoDecoderLimits.maximumNALUnits))
        var naluStart = firstStartCodeLength
        var searchOffset = naluStart

        while let nextStartCode = findStartCode(in: data, from: searchOffset) {
            try appendNALUnit(
                from: data,
                byteRange: naluStart..<nextStartCode.offset,
                codec: codec,
                to: &nalus
            )
            naluStart = nextStartCode.offset + nextStartCode.length
            searchOffset = naluStart
        }

        try appendNALUnit(
            from: data,
            byteRange: naluStart..<data.count,
            codec: codec,
            to: &nalus
        )
        return nalus
    }

    private static func appendNALUnit(
        from data: Data,
        byteRange: Range<Int>,
        codec: RemoteDesktopVideoCodec,
        to nalus: inout [Data]
    ) throws {
        let length = byteRange.count
        guard length >= codec.minimumNALUnitBytes else {
            throw RemoteDesktopVideoDecoderInputError.malformedAccessUnit
        }
        let firstByte = byte(in: data, at: byteRange.lowerBound)
        if codec.isParameterSet(firstByte: firstByte),
           length > RemoteDesktopVideoDecoderLimits.maximumParameterSetBytes {
            throw RemoteDesktopVideoDecoderInputError.nalUnitTooLarge(
                actualBytes: length,
                maximumBytes: RemoteDesktopVideoDecoderLimits.maximumParameterSetBytes
            )
        }
        guard nalus.count < RemoteDesktopVideoDecoderLimits.maximumNALUnits else {
            throw RemoteDesktopVideoDecoderInputError.tooManyNALUnits(
                actual: nalus.count + 1,
                maximum: RemoteDesktopVideoDecoderLimits.maximumNALUnits
            )
        }

        let lowerBound = data.index(data.startIndex, offsetBy: byteRange.lowerBound)
        let upperBound = data.index(data.startIndex, offsetBy: byteRange.upperBound)
        nalus.append(Data(data[lowerBound..<upperBound]))
    }

    private static func findStartCode(
        in data: Data,
        from startOffset: Int
    ) -> (offset: Int, length: Int)? {
        var offset = startOffset
        while offset + 3 <= data.count {
            if let length = startCodeLength(in: data, at: offset) {
                return (offset, length)
            }
            offset += 1
        }
        return nil
    }

    private static func startCodeLength(in data: Data, at offset: Int) -> Int? {
        guard offset >= 0, offset + 3 <= data.count else { return nil }
        if offset + 4 <= data.count,
           byte(in: data, at: offset) == 0,
           byte(in: data, at: offset + 1) == 0,
           byte(in: data, at: offset + 2) == 0,
           byte(in: data, at: offset + 3) == 1 {
            return 4
        }
        if byte(in: data, at: offset) == 0,
           byte(in: data, at: offset + 1) == 0,
           byte(in: data, at: offset + 2) == 1 {
            return 3
        }
        return nil
    }

    private static func byte(in data: Data, at offset: Int) -> UInt8 {
        data[data.index(data.startIndex, offsetBy: offset)]
    }
}

// MARK: - Video Decoder

/// 视频解码器
@available(iOS 17.0, *)
actor VideoDecoder {
    private typealias Codec = RemoteDesktopVideoCodec
    private let nominalPresentationStep = CMTime(value: 1, timescale: 60)
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var decompressionSessionFormatDescription: CMVideoFormatDescription?
    private var activeCodec: Codec?
    private var parameterSetCoordinator = RemoteDesktopVideoParameterSetCoordinator()
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
                output: .completed(try decodeStaticImage(payload)),
                failureReason: lastDecodeFailureReason
            )
        }

        switch format {
        case "jpeg", "jpg":
            return VideoDecodeSubmission(
                output: .completed(try decodeJPEG(payload)),
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
                output: .completed(
                    try decodeBGRA(
                        payload,
                        width: screenData.width,
                        height: screenData.height
                    )
                ),
                failureReason: lastDecodeFailureReason
            )
        default:
            throw RemoteDesktopError.notSupported("remote desktop frame format")
        }
    }

    private func decodeJPEG(_ data: Data) throws -> DecodeOutput {
        try decodeStaticImage(data)
    }

    private struct ValidatedStaticImage {
        let source: CGImageSource
        let dimensions: RemoteDesktopValidatedPixelDimensions
    }

    private func decodeStaticImage(_ data: Data) throws -> DecodeOutput {
        let validatedImage = try makeValidatedStaticImage(from: data)
        if let pixelBufferFrame = try makeStillImagePixelBufferFrame(
            from: data,
            expectedDimensions: validatedImage.dimensions
        ) {
            return .pixelBuffer(pixelBufferFrame)
        }

        let decodeOptions: CFDictionary = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(
            validatedImage.source,
            0,
            decodeOptions
        ) else {
            throw RemoteDesktopVideoDecoderInputError.staticImageDecodeFailed
        }
        let decodedDimensions = try RemoteDesktopVideoDecoderInputValidator.validatedPixelDimensions(
            width: image.width,
            height: image.height
        )
        guard decodedDimensions == validatedImage.dimensions else {
            throw RemoteDesktopVideoDecoderInputError.invalidStaticImageMetadata
        }
        return .image(DecodedImageFrame(image: image))
    }

    private func decodeBGRA(_ data: Data, width: Int, height: Int) throws -> DecodeOutput {
        let dimensions = try RemoteDesktopVideoDecoderInputValidator.validatedPixelDimensions(
            width: width,
            height: height
        )
        guard data.count == dimensions.pixelBytes else {
            throw RemoteDesktopVideoDecoderInputError.bgraByteCountMismatch(
                expected: dimensions.pixelBytes,
                actual: data.count
            )
        }

        if let pixelBuffer = makeBGRAFramePixelBuffer(data: data, width: width, height: height) {
            let pixelBufferFrame = DecodedPixelBufferFrame(
                pixelBuffer: pixelBuffer,
                width: width,
                height: height,
                presentationTimeStamp: nextDecodePresentationTimeStamp()
            )
            return .pixelBuffer(pixelBufferFrame)
        }

        guard let provider = CGDataProvider(data: data as CFData) else {
            throw RemoteDesktopError.decodingFailed("Failed to create the validated BGRA data provider")
        }
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
            throw RemoteDesktopError.decodingFailed("Failed to create the validated BGRA image")
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
            clearVideoParameterSets(requiresCompleteSyncSet: false)
            return
        }

        guard let codec = codec(for: normalized) else { return }
        resetDecoderState(keepLastFrame: true)
        activeCodec = codec
        activeVideoDimensions = CGSize(width: width, height: height)
        waitingForSyncFrame = true
        clearVideoParameterSets(requiresCompleteSyncSet: true)
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
        _ = try RemoteDesktopVideoDecoderInputValidator.validatedPixelDimensions(
            width: width,
            height: height
        )
        let nalus = try RemoteDesktopVideoAccessUnitParser.parse(data, codec: codec)
        let dimensions = CGSize(width: width, height: height)
        let streamChanged = activeCodec != codec || activeVideoDimensions != dimensions
        if streamChanged {
            resetDecoderState(keepLastFrame: true)
            activeCodec = codec
            activeVideoDimensions = dimensions
            waitingForSyncFrame = true
            clearVideoParameterSets(requiresCompleteSyncSet: true)
        }

        let accessUnitSummary = videoAccessUnitSummary(codec: codec, nalus: nalus)
        let containsSyncFrame = containsSyncFrame(in: nalus, codec: codec)
        let parameterSetUpdate = parameterSetCoordinator.consume(
            nalus: nalus,
            codec: codec,
            containsSyncFrame: containsSyncFrame
        )
        switch parameterSetUpdate {
        case .noChange:
            break
        case .committed(let changed):
            if changed {
                resetDecoderState(keepLastFrame: true)
                waitingForSyncFrame = true
            }
        case .requiresCompleteSyncSet:
            waitingForSyncFrame = true
            logDecodeFailureIfNeeded(
                codec: codec,
                dataSize: data.count,
                reason: "parameter-set-transition-requires-complete-sync-set \(accessUnitSummary)"
            )
            return VideoDecodeSubmission(
                output: .completed(nil),
                failureReason: lastDecodeFailureReason
            )
        }

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

        guard let sampleData = try makeDecoderSampleData(from: nalus, codec: codec) else {
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
        decompressionSessionFormatDescription = nil
        formatDescription = nil
        hasLoggedFirstVideoAccessUnit = false
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

    private func clearVideoParameterSets(requiresCompleteSyncSet: Bool) {
        parameterSetCoordinator.clear(requiresCompleteSyncSet: requiresCompleteSyncSet)
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
        guard let parameterSets = parameterSetCoordinator.activeSnapshot,
              parameterSets.codec == codec else {
            return
        }
        switch codec {
        case .h264:
            let sps = parameterSets.sps
            let pps = parameterSets.pps
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
            _ = try RemoteDesktopVideoDecoderInputValidator.validatedPixelDimensions(of: desc)
            formatDescription = desc

        case .hevc:
            guard let vps = parameterSets.vps else { return }
            let sps = parameterSets.sps
            let pps = parameterSets.pps
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
            _ = try RemoteDesktopVideoDecoderInputValidator.validatedPixelDimensions(of: desc)
            formatDescription = desc
        }
    }

    private func ensureDecompressionSession(
        codec: Codec,
        formatDescription: CMVideoFormatDescription
    ) throws {
        // CMVideoFormatDescription is derived from untrusted SPS/VPS data.
        // Validate its actual coded dimensions before any IOSurface-backed VT
        // session can allocate decoder output buffers.
        _ = try RemoteDesktopVideoDecoderInputValidator.validatedPixelDimensions(
            of: formatDescription
        )
        if decompressionSession != nil,
           let activeDescription = decompressionSessionFormatDescription,
           CMFormatDescriptionEqual(activeDescription, otherFormatDescription: formatDescription) {
            _ = codec
            return
        }

        if let decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
            VTDecompressionSessionInvalidate(decompressionSession)
            self.decompressionSession = nil
            decompressionSessionFormatDescription = nil
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
            VTDecompressionSessionInvalidate(session)
            throw RemoteDesktopError.decodingFailed(
                "Failed to enable realtime hardware decode (status=\(realtimeStatus))"
            )
        }
        decompressionSession = session
        decompressionSessionFormatDescription = formatDescription
    }

    private func submitPixelBufferDecode(
        _ sampleBuffer: CMSampleBuffer,
        codec: Codec,
        accessUnitSummary: String
    ) throws -> VideoDecodeResultHandle {
        guard let formatDescription else {
            throw RemoteDesktopError.decodingFailed(
                "Decoder state lost its format description before frame submission"
            )
        }
        try ensureDecompressionSession(codec: codec, formatDescription: formatDescription)
        guard let decompressionSession else {
            throw RemoteDesktopError.decodingFailed(
                "VideoToolbox session was unavailable after successful creation"
            )
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
            let decodedWidth = CVPixelBufferGetWidth(pixelBuffer)
            let decodedHeight = CVPixelBufferGetHeight(pixelBuffer)
            handle.complete(
                .success(
                    .pixelBuffer(
                        DecodedPixelBufferFrame(
                        pixelBuffer: pixelBuffer,
                            width: decodedWidth,
                            height: decodedHeight,
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
        guard !naluData.isEmpty else {
            throw RemoteDesktopVideoDecoderInputError.malformedAccessUnit
        }
        guard naluData.count <= RemoteDesktopVideoDecoderLimits.maximumAccessUnitBytes else {
            throw RemoteDesktopVideoDecoderInputError.accessUnitTooLarge(
                actualBytes: naluData.count,
                maximumBytes: RemoteDesktopVideoDecoderLimits.maximumAccessUnitBytes
            )
        }
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
        SkyBridgeDiagnosticTrace.appendStatus(line)
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

    private func makeValidatedStaticImage(from data: Data) throws -> ValidatedStaticImage {
        try RemoteDesktopVideoDecoderInputValidator.validateEncodedImageByteCount(data.count)
        let sourceOptions: CFDictionary = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0 else {
            throw RemoteDesktopVideoDecoderInputError.staticImageSourceUnavailable
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) else {
            throw RemoteDesktopVideoDecoderInputError.invalidStaticImageMetadata
        }
        let metadata = properties as NSDictionary
        guard let width = metadata[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = metadata[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw RemoteDesktopVideoDecoderInputError.invalidStaticImageMetadata
        }
        let dimensions = try RemoteDesktopVideoDecoderInputValidator.validatedPixelDimensions(
            width: width.doubleValue,
            height: height.doubleValue
        )
        return ValidatedStaticImage(source: source, dimensions: dimensions)
    }

    private func makeStillImagePixelBufferFrame(
        from data: Data,
        expectedDimensions: RemoteDesktopValidatedPixelDimensions
    ) throws -> DecodedPixelBufferFrame? {
        guard let ciImage = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        let extent = ciImage.extent.integral
        let renderedDimensions = try RemoteDesktopVideoDecoderInputValidator.validatedPixelDimensions(
            width: Double(extent.width),
            height: Double(extent.height)
        )
        let matchesMetadata =
            renderedDimensions.width == expectedDimensions.width
            && renderedDimensions.height == expectedDimensions.height
        let matchesOrientedMetadata =
            renderedDimensions.width == expectedDimensions.height
            && renderedDimensions.height == expectedDimensions.width
        guard matchesMetadata || matchesOrientedMetadata else {
            throw RemoteDesktopVideoDecoderInputError.invalidStaticImageMetadata
        }
        guard let pixelBuffer = makeMetalCompatiblePixelBuffer(
            width: renderedDimensions.width,
            height: renderedDimensions.height
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
            width: renderedDimensions.width,
            height: renderedDimensions.height,
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
            presentationTimeStamp: pixelBufferFrame.presentationTimeStamp,
            cameraPresentationContext: pixelBufferFrame.cameraPresentationContext,
            framePresentationContext: pixelBufferFrame.framePresentationContext
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

    private func makeDecoderSampleData(from nalus: [Data], codec: Codec) throws -> Data? {
        var hasRenderableNALU = false
        var outputByteCount = 0

        for nalu in nalus {
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

            let (encodedNALUnitBytes, encodedNALUnitOverflow) = nalu.count.addingReportingOverflow(4)
            let (nextOutputByteCount, outputByteCountOverflow) = outputByteCount.addingReportingOverflow(
                encodedNALUnitBytes
            )
            guard !encodedNALUnitOverflow,
                  !outputByteCountOverflow,
                  nextOutputByteCount <= RemoteDesktopVideoDecoderLimits.maximumAccessUnitBytes else {
                throw RemoteDesktopVideoDecoderInputError.accessUnitTooLarge(
                    actualBytes: outputByteCountOverflow ? Int.max : nextOutputByteCount,
                    maximumBytes: RemoteDesktopVideoDecoderLimits.maximumAccessUnitBytes
                )
            }
            outputByteCount = nextOutputByteCount
        }

        guard hasRenderableNALU, outputByteCount > 0 else { return nil }

        var output = Data()
        output.reserveCapacity(outputByteCount)
        for nalu in nalus where !isParameterSetNALU(nalu, codec: codec) {

            var length = UInt32(nalu.count).bigEndian
            withUnsafeBytes(of: &length) { rawBuffer in
                output.append(contentsOf: rawBuffer)
            }
            output.append(nalu)
        }
        return output
    }

    private func isParameterSetNALU(_ nalu: Data, codec: Codec) -> Bool {
        guard let first = nalu.first else { return false }
        return codec.isParameterSet(firstByte: first)
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

    func cleanup() {
        resetDecoderState(keepLastFrame: false)
        activeCodec = nil
        activeVideoDimensions = nil
        waitingForSyncFrame = false
        lastPresentationTimeStamp = nil
        lastDecodeFailureReason = nil
        clearVideoParameterSets(requiresCompleteSyncSet: false)
    }

    func resetPreservingLastFrame() {
        resetDecoderState(keepLastFrame: true)
        waitingForSyncFrame = true
        clearVideoParameterSets(requiresCompleteSyncSet: true)
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
