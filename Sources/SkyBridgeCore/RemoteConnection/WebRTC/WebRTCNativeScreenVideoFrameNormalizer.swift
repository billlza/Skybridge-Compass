import Foundation
import CoreVideo
import VideoToolbox

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

#if canImport(WebRTC)
final class WebRTCNativeScreenVideoFrameNormalizer: @unchecked Sendable {
    private struct PixelBufferPoolKey: Hashable {
        let width: Int
        let height: Int
        let pixelFormat: OSType
    }

    struct NormalizedFrame {
        let pixelBuffer: CVPixelBuffer
        let visibleWidth: Int
        let visibleHeight: Int
        let rawPixelFormat: OSType
        let submittedPixelFormat: OSType
        let wasNormalized: Bool

        var requiresVisibleCrop: Bool {
            visibleWidth != CVPixelBufferGetWidth(pixelBuffer)
                || visibleHeight != CVPixelBufferGetHeight(pixelBuffer)
        }
    }

    private let lock = NSLock()
    private var pools: [PixelBufferPoolKey: CVPixelBufferPool] = [:]
    private var transferSession: VTPixelTransferSession?
    private let supportedPixelFormats: Set<OSType>
    private let preferredNormalizedPixelFormat: OSType
    private var cachedRawPixelBuffer: CVPixelBuffer?
    private var cachedRawPixelBufferIdentity: ObjectIdentifier?
    private var cachedRawTimestampNs: Int64?
    private var cachedRawPixelFormat: OSType?
    private var cachedVisibleWidth: Int?
    private var cachedVisibleHeight: Int?
    private var cachedNormalizedFrame: NormalizedFrame?

    init() {
        let supported = Set(RTCCVPixelBuffer.supportedPixelFormats().map { OSType(truncating: $0) })
        supportedPixelFormats = supported
        preferredNormalizedPixelFormat = Self.selectPreferredNormalizedPixelFormat(supportedPixelFormats: supported)
    }

    func normalize(_ pixelBuffer: CVPixelBuffer, rawTimestampNs: Int64? = nil) throws -> NormalizedFrame {
        let rawPixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let visibleWidth = CVPixelBufferGetWidth(pixelBuffer)
        let visibleHeight = CVPixelBufferGetHeight(pixelBuffer)
        let pixelBufferIdentity = ObjectIdentifier(pixelBuffer)
        if let cached = cachedFrame(
            pixelBufferIdentity: pixelBufferIdentity,
            rawTimestampNs: rawTimestampNs,
            rawPixelFormat: rawPixelFormat,
            visibleWidth: visibleWidth,
            visibleHeight: visibleHeight
        ) {
            return cached
        }
        if shouldSubmitDirectly(pixelFormat: rawPixelFormat, width: visibleWidth, height: visibleHeight) {
            let frame = NormalizedFrame(
                pixelBuffer: pixelBuffer,
                visibleWidth: visibleWidth,
                visibleHeight: visibleHeight,
                rawPixelFormat: rawPixelFormat,
                submittedPixelFormat: rawPixelFormat,
                wasNormalized: false
            )
            storeCachedFrame(
                frame,
                rawPixelBuffer: pixelBuffer,
                pixelBufferIdentity: pixelBufferIdentity,
                rawTimestampNs: rawTimestampNs
            )
            return frame
        }

        let submittedPixelFormat = preferredNormalizedPixelFormat
        let submittedWidth = Self.evenBackingDimension(for: visibleWidth)
        let submittedHeight = Self.evenBackingDimension(for: visibleHeight)
        if submittedWidth == visibleWidth && submittedHeight == visibleHeight {
            let output = try normalizedPixelBuffer(
                width: visibleWidth,
                height: visibleHeight,
                pixelFormat: submittedPixelFormat
            )
            try transferImage(from: pixelBuffer, to: output)
            let frame = NormalizedFrame(
                pixelBuffer: output,
                visibleWidth: visibleWidth,
                visibleHeight: visibleHeight,
                rawPixelFormat: rawPixelFormat,
                submittedPixelFormat: submittedPixelFormat,
                wasNormalized: true
            )
            storeCachedFrame(
                frame,
                rawPixelBuffer: pixelBuffer,
                pixelBufferIdentity: pixelBufferIdentity,
                rawTimestampNs: rawTimestampNs
            )
            return frame
        }

        let visibleOutput = try normalizedPixelBuffer(
            width: visibleWidth,
            height: visibleHeight,
            pixelFormat: submittedPixelFormat
        )
        try transferImage(from: pixelBuffer, to: visibleOutput)
        let output = try normalizedPixelBuffer(
            width: submittedWidth,
            height: submittedHeight,
            pixelFormat: submittedPixelFormat
        )
        try copyVisibleFrame(from: visibleOutput, to: output)
        let frame = NormalizedFrame(
            pixelBuffer: output,
            visibleWidth: visibleWidth,
            visibleHeight: visibleHeight,
            rawPixelFormat: rawPixelFormat,
            submittedPixelFormat: submittedPixelFormat,
            wasNormalized: true
        )
        storeCachedFrame(
            frame,
            rawPixelBuffer: pixelBuffer,
            pixelBufferIdentity: pixelBufferIdentity,
            rawTimestampNs: rawTimestampNs
        )
        return frame
    }

    private func cachedFrame(
        pixelBufferIdentity: ObjectIdentifier,
        rawTimestampNs: Int64?,
        rawPixelFormat: OSType,
        visibleWidth: Int,
        visibleHeight: Int
    ) -> NormalizedFrame? {
        guard let rawTimestampNs else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard cachedRawPixelBufferIdentity == pixelBufferIdentity,
              cachedRawTimestampNs == rawTimestampNs,
              cachedRawPixelFormat == rawPixelFormat,
              cachedVisibleWidth == visibleWidth,
              cachedVisibleHeight == visibleHeight else {
            return nil
        }
        return cachedNormalizedFrame
    }

    private func storeCachedFrame(
        _ frame: NormalizedFrame,
        rawPixelBuffer: CVPixelBuffer,
        pixelBufferIdentity: ObjectIdentifier,
        rawTimestampNs: Int64?
    ) {
        guard let rawTimestampNs else { return }
        lock.lock()
        cachedRawPixelBuffer = rawPixelBuffer
        cachedRawPixelBufferIdentity = pixelBufferIdentity
        cachedRawTimestampNs = rawTimestampNs
        cachedRawPixelFormat = frame.rawPixelFormat
        cachedVisibleWidth = frame.visibleWidth
        cachedVisibleHeight = frame.visibleHeight
        cachedNormalizedFrame = frame
        lock.unlock()
    }

    private func shouldSubmitDirectly(pixelFormat: OSType, width: Int, height: Int) -> Bool {
        supportedPixelFormats.contains(pixelFormat)
            && pixelFormat != kCVPixelFormatType_32BGRA
            && width.isMultiple(of: 2)
            && height.isMultiple(of: 2)
    }

    private static func evenBackingDimension(for visibleDimension: Int) -> Int {
        let sanitized = max(1, visibleDimension)
        return sanitized.isMultiple(of: 2) ? sanitized : sanitized + 1
    }

    private static func selectPreferredNormalizedPixelFormat(supportedPixelFormats: Set<OSType>) -> OSType {
        if supportedPixelFormats.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        if supportedPixelFormats.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
        return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    private func normalizedPixelBuffer(width: Int, height: Int, pixelFormat: OSType) throws -> CVPixelBuffer {
        lock.lock()
        defer { lock.unlock() }

        let key = PixelBufferPoolKey(width: width, height: height, pixelFormat: pixelFormat)
        if pools[key] == nil {
            pools[key] = try Self.makePixelBufferPool(width: width, height: height, pixelFormat: pixelFormat)
        }

        let allocationAttributes: [String: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey as String: 8
        ]
        var output: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pools[key]!,
            allocationAttributes as CFDictionary,
            &output
        )
        guard status == kCVReturnSuccess, let output else {
            throw NSError(
                domain: "com.skybridge.webrtc.video-normalizer",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferPoolCreatePixelBuffer failed with status \(status)"]
            )
        }
        return output
    }

    private func copyVisibleFrame(from source: CVPixelBuffer, to destination: CVPixelBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(source) == CVPixelBufferGetPixelFormatType(destination) else {
            throw Self.copyError("source and destination pixel formats differ")
        }

        let sourceLockStatus = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard sourceLockStatus == kCVReturnSuccess else {
            throw Self.copyError("CVPixelBufferLockBaseAddress(source) failed with status \(sourceLockStatus)")
        }
        var destinationLocked = false
        defer {
            if destinationLocked {
                CVPixelBufferUnlockBaseAddress(destination, [])
            }
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        let destinationLockStatus = CVPixelBufferLockBaseAddress(destination, [])
        guard destinationLockStatus == kCVReturnSuccess else {
            throw Self.copyError("CVPixelBufferLockBaseAddress(destination) failed with status \(destinationLockStatus)")
        }
        destinationLocked = true

        if CVPixelBufferIsPlanar(source), CVPixelBufferIsPlanar(destination) {
            let planeCount = min(CVPixelBufferGetPlaneCount(source), CVPixelBufferGetPlaneCount(destination))
            guard planeCount > 0 else {
                throw Self.copyError("planar pixel buffer has no planes")
            }
            for plane in 0..<planeCount {
                guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let destinationBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else {
                    throw Self.copyError("missing base address for plane \(plane)")
                }
                Self.copyPlaneRows(
                    sourceBase: sourceBase,
                    sourceBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                    sourceHeight: CVPixelBufferGetHeightOfPlane(source, plane),
                    destinationBase: destinationBase,
                    destinationBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(destination, plane),
                    destinationHeight: CVPixelBufferGetHeightOfPlane(destination, plane),
                    neutralFill: plane == 0 ? 0 : 128
                )
            }
            return
        }

        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationBase = CVPixelBufferGetBaseAddress(destination) else {
            throw Self.copyError("missing base address for non-planar pixel buffer")
        }
        Self.copyPlaneRows(
            sourceBase: sourceBase,
            sourceBytesPerRow: CVPixelBufferGetBytesPerRow(source),
            sourceHeight: CVPixelBufferGetHeight(source),
            destinationBase: destinationBase,
            destinationBytesPerRow: CVPixelBufferGetBytesPerRow(destination),
            destinationHeight: CVPixelBufferGetHeight(destination),
            neutralFill: 0
        )
    }

    private static func copyPlaneRows(
        sourceBase: UnsafeMutableRawPointer,
        sourceBytesPerRow: Int,
        sourceHeight: Int,
        destinationBase: UnsafeMutableRawPointer,
        destinationBytesPerRow: Int,
        destinationHeight: Int,
        neutralFill: Int32
    ) {
        let copiedHeight = min(sourceHeight, destinationHeight)
        let copiedBytesPerRow = min(sourceBytesPerRow, destinationBytesPerRow)
        guard destinationHeight > 0, destinationBytesPerRow > 0 else { return }
        guard copiedHeight > 0, copiedBytesPerRow > 0 else {
            memset(destinationBase, neutralFill, destinationBytesPerRow * destinationHeight)
            return
        }

        for row in 0..<copiedHeight {
            let sourceRow = sourceBase.advanced(by: row * sourceBytesPerRow)
            let destinationRow = destinationBase.advanced(by: row * destinationBytesPerRow)
            memcpy(destinationRow, sourceRow, copiedBytesPerRow)
            if destinationBytesPerRow > copiedBytesPerRow {
                memset(
                    destinationRow.advanced(by: copiedBytesPerRow),
                    neutralFill,
                    destinationBytesPerRow - copiedBytesPerRow
                )
            }
        }

        guard destinationHeight > copiedHeight else { return }
        let lastVisibleRow = destinationBase.advanced(by: (copiedHeight - 1) * destinationBytesPerRow)
        for row in copiedHeight..<destinationHeight {
            memcpy(
                destinationBase.advanced(by: row * destinationBytesPerRow),
                lastVisibleRow,
                destinationBytesPerRow
            )
        }
    }

    private static func copyError(_ description: String) -> NSError {
        NSError(
            domain: "com.skybridge.webrtc.video-normalizer",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    private func transferImage(from source: CVPixelBuffer, to destination: CVPixelBuffer) throws {
        lock.lock()
        defer { lock.unlock() }

        if transferSession == nil {
            transferSession = try Self.makePixelTransferSession()
        }

        let status = VTPixelTransferSessionTransferImage(transferSession!, from: source, to: destination)
        guard status == noErr else {
            throw NSError(
                domain: "com.skybridge.webrtc.video-normalizer",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "VTPixelTransferSessionTransferImage failed with status \(status)"]
            )
        }
    }

    private static func makePixelTransferSession() throws -> VTPixelTransferSession {
        var created: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault,
            pixelTransferSessionOut: &created
        )
        guard status == noErr, let created else {
            throw NSError(
                domain: "com.skybridge.webrtc.video-normalizer",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "VTPixelTransferSessionCreate failed with status \(status)"]
            )
        }
        VTSessionSetProperty(created, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
        return created
    }

    private static func makePixelBufferPool(width: Int, height: Int, pixelFormat: OSType) throws -> CVPixelBufferPool {
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
            kCVPixelBufferPoolMaximumBufferAgeKey as String: 0
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw NSError(
                domain: "com.skybridge.webrtc.video-normalizer",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferPoolCreate failed with status \(status)"]
            )
        }
        return pool
    }
}
#endif
