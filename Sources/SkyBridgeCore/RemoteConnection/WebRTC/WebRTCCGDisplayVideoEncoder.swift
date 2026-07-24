import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import OSLog
import VideoToolbox

enum WebRTCCGDisplayPixelBufferRenderer {
    static func makePixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .medium
        // CGDisplayCreateImage already matches the top-left-oriented desktop raster.
        // Flipping again here inverts the entire remote desktop frame.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }
}

final class WebRTCCGDisplayVideoEncoder: @unchecked Sendable {
    enum EncodedBitstreamFormat: Sendable {
        case native
        case annexB
    }

    private let logger = Logger(subsystem: "com.skybridge.connection", category: "WebRTCCGEncoder")
    private let encodeQueue = DispatchQueue(
        label: "com.skybridge.connection.webrtc.cg-encoder",
        qos: .userInteractive
    )
    private let encodeQueueKey = DispatchSpecificKey<UInt8>()
    private let encodeQueueValue: UInt8 = 1

    // Accessed only on encodeQueue.
    private var compressionSession: VTCompressionSession?
    private var codecType: CMVideoCodecType = kCMVideoCodecType_H264
    private var width: Int = 1280
    private var height: Int = 720
    private var configuredFPS: Int = 60
    private var configuredKeyInterval: Int = 60
    private var bitstreamFormat: EncodedBitstreamFormat = .native
    private var hasEmittedParameterSets = false
    private var pendingForcedKeyFrames = 0
    private var started = false
    private var compressionCallbackRefcon: UnsafeMutableRawPointer?
    private var activeGeneration: UInt64 = 0
    private var encodeInFlight = false

    private struct PendingEncode: @unchecked Sendable {
        let image: CGImage
        let timestamp: TimeInterval
        let generation: UInt64
    }

    // Admission is the only cross-queue state. It retains at most one pending
    // CGImage while encodeQueue owns the in-flight frame and VT session state.
    private let admissionLock = NSLock()
    private var admissionGeneration: UInt64 = 0
    private var acceptsFrames = false
    private var pendingEncode: PendingEncode?
    private var drainScheduled = false

    private let callbackLock = NSLock()
    private var encodedFrameHandler: ((Data, Int, Int, RemoteFrameType) -> Void)?

    var onEncodedFrame: ((Data, Int, Int, RemoteFrameType) -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return encodedFrameHandler
        }
        set {
            callbackLock.lock()
            encodedFrameHandler = newValue
            callbackLock.unlock()
        }
    }

    init() {
        encodeQueue.setSpecific(key: encodeQueueKey, value: encodeQueueValue)
    }

    private func emitSmokeLog(_ message: String) {
#if DEBUG || SKYBRIDGE_TESTING
        guard ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil else { return }
        logger.info("\(message, privacy: .public)")
#endif
    }

    private final class CompressionCallbackContext: @unchecked Sendable {
        private let lock = NSLock()
        weak var encoder: WebRTCCGDisplayVideoEncoder?
        let generation: UInt64
        private var isActive = true

        init(encoder: WebRTCCGDisplayVideoEncoder, generation: UInt64) {
            self.encoder = encoder
            self.generation = generation
        }

        func deactivate() {
            lock.lock()
            isActive = false
            lock.unlock()
        }

        func activeEncoder() -> WebRTCCGDisplayVideoEncoder? {
            lock.lock()
            defer { lock.unlock() }
            guard isActive else { return nil }
            return encoder
        }
    }

    /// CMSampleBuffer is an immutable callback payload for this delivery. The
    /// box transfers its lifetime to encodeQueue without claiming the mutable
    /// VideoToolbox session itself is cross-queue safe.
    private final class CompressionCallbackDelivery: @unchecked Sendable {
        let context: CompressionCallbackContext
        let status: OSStatus
        let sampleBuffer: CMSampleBuffer?

        init(
            context: CompressionCallbackContext,
            status: OSStatus,
            sampleBuffer: CMSampleBuffer?
        ) {
            self.context = context
            self.status = status
            self.sampleBuffer = sampleBuffer
        }
    }

    func start(
        preferredCodec: RemoteFrameType,
        preferredSize: CGSize,
        targetFPS: Int,
        keyFrameInterval: Int,
        bitstreamFormat: EncodedBitstreamFormat = .native
    ) throws {
        let generation = closeAdmissionAndAdvanceGeneration()
        do {
            try syncOnEncodeQueue {
                stopOnEncodeQueue()
                activeGeneration = generation
                width = max(1, Int(preferredSize.width.rounded()))
                height = max(1, Int(preferredSize.height.rounded()))
                configuredFPS = max(1, targetFPS)
                configuredKeyInterval = max(1, keyFrameInterval)
                self.bitstreamFormat = bitstreamFormat
                hasEmittedParameterSets = false
                pendingForcedKeyFrames = 2
                codecType = preferredCodec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264

                try setupCompressionSession(width: width, height: height, codec: codecType)
                started = true
                emitSmokeLog("🧪 cg-vt start codec=\(preferredCodec) size=\(width)x\(height) fps=\(configuredFPS)")
            }
            openAdmission(for: generation)
        } catch {
            syncOnEncodeQueue {
                stopOnEncodeQueue()
            }
            throw error
        }
    }

    func stop() {
        let generation = closeAdmissionAndAdvanceGeneration()
        syncOnEncodeQueue {
            stopOnEncodeQueue()
            activeGeneration = generation
        }
    }

    private func stopOnEncodeQueue() {
        dispatchPrecondition(condition: .onQueue(encodeQueue))
        started = false
        encodeInFlight = false
        hasEmittedParameterSets = false
        pendingForcedKeyFrames = 0
        deactivateCompressionCallbackContext()
        if let compressionSession {
            VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(compressionSession)
        }
        compressionSession = nil
        releaseCompressionCallbackContext()
    }

    func encode(image: CGImage, timestamp: TimeInterval) {
        let shouldSchedule: Bool
        admissionLock.lock()
        guard acceptsFrames else {
            admissionLock.unlock()
            return
        }
        pendingEncode = PendingEncode(
            image: image,
            timestamp: timestamp,
            generation: admissionGeneration
        )
        shouldSchedule = !drainScheduled
        if shouldSchedule {
            drainScheduled = true
        }
        admissionLock.unlock()

        guard shouldSchedule else { return }
        encodeQueue.async { [weak self] in
            self?.drainLatestEncodeOnQueue()
        }
    }

    func requestKeyFrameRefresh(reason: String, count: Int = 2) {
        let clampedCount = max(1, min(count, 4))
        encodeQueue.async { [weak self] in
            guard let self, self.started else { return }
            self.pendingForcedKeyFrames = max(self.pendingForcedKeyFrames, clampedCount)
            self.logger.info("🪄 WebRTC 直连编码器请求关键帧刷新: \(reason, privacy: .public)")
        }
    }

    private func nextFramePropertiesForEncode() -> CFDictionary? {
        dispatchPrecondition(condition: .onQueue(encodeQueue))
        guard pendingForcedKeyFrames > 0 else { return nil }
        pendingForcedKeyFrames -= 1
        return [kVTEncodeFrameOptionKey_ForceKeyFrame as String: kCFBooleanTrue as Any] as CFDictionary
    }

    private func closeAdmissionAndAdvanceGeneration() -> UInt64 {
        admissionLock.lock()
        acceptsFrames = false
        pendingEncode = nil
        drainScheduled = false
        admissionGeneration = admissionGeneration == UInt64.max
            ? 1
            : admissionGeneration + 1
        let generation = admissionGeneration
        admissionLock.unlock()
        return generation
    }

    private func openAdmission(for generation: UInt64) {
        admissionLock.lock()
        if admissionGeneration == generation {
            acceptsFrames = true
        }
        admissionLock.unlock()
    }

    private func syncOnEncodeQueue<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: encodeQueueKey) == encodeQueueValue {
            return try operation()
        }
        return try encodeQueue.sync(execute: operation)
    }

    private func takeLatestPendingEncode() -> PendingEncode? {
        admissionLock.lock()
        defer { admissionLock.unlock() }
        guard acceptsFrames else {
            pendingEncode = nil
            drainScheduled = false
            return nil
        }
        defer { pendingEncode = nil }
        return pendingEncode
    }

    private func clearDrainScheduledIfIdle() {
        admissionLock.lock()
        if pendingEncode == nil {
            drainScheduled = false
        }
        admissionLock.unlock()
    }

    private func drainLatestEncodeOnQueue() {
        dispatchPrecondition(condition: .onQueue(encodeQueue))
        guard !encodeInFlight else { return }

        while let pending = takeLatestPendingEncode() {
            guard started,
                  pending.generation == activeGeneration,
                  let compressionSession else {
                continue
            }
            guard let pixelBuffer = makePixelBuffer(from: pending.image) else {
                emitSmokeLog("🧪 cg-vt pixel-buffer-failed")
                continue
            }

            let presentationTime = CMTime(
                value: CMTimeValue(max(pending.timestamp, 0) * 1_000.0),
                timescale: 1_000
            )
            var flags = VTEncodeInfoFlags()
            encodeInFlight = true
            let status = VTCompressionSessionEncodeFrame(
                compressionSession,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: presentationTime,
                duration: .invalid,
                frameProperties: nextFramePropertiesForEncode(),
                sourceFrameRefcon: nil,
                infoFlagsOut: &flags
            )
            if status == noErr {
                // Completion resumes the bounded drain on this same queue.
                return
            }

            encodeInFlight = false
            logger.error("❌ CGDisplay VT encode failed status=\(status, privacy: .public)")
            emitSmokeLog("🧪 cg-vt encode-status=\(status)")
        }

        clearDrainScheduledIfIdle()
    }

    private func setupCompressionSession(width: Int, height: Int, codec: CMVideoCodecType) throws {
        dispatchPrecondition(condition: .onQueue(encodeQueue))
        var session: VTCompressionSession?
        let callbackRefcon = makeCompressionCallbackRefcon(generation: activeGeneration)
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, _, sampleBuffer in
                WebRTCCGDisplayVideoEncoder.handleCompressionCallback(
                    refcon: refcon,
                    status: status,
                    sampleBuffer: sampleBuffer
                )
            },
            refcon: callbackRefcon,
            compressionSessionOut: &session
        )

        if status != noErr || session == nil {
            Self.releaseCompressionCallbackRefcon(callbackRefcon)
            if codec == kCMVideoCodecType_HEVC {
                logger.error("HEVC VT session unavailable; refusing automatic H.264 fallback")
            }
            throw CocoaError(.featureUnsupported)
        }

        compressionSession = session
        compressionCallbackRefcon = callbackRefcon
        guard let session else { throw CocoaError(.featureUnsupported) }

        let profileLevel: CFString = {
            switch codecType {
            case kCMVideoCodecType_HEVC:
                return kVTProfileLevel_HEVC_Main_AutoLevel
            case kCMVideoCodecType_H264:
                return kVTProfileLevel_H264_High_AutoLevel
            default:
                return kVTProfileLevel_H264_High_AutoLevel
            }
        }()

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profileLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: configuredFPS))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: configuredKeyInterval))
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private func makeCompressionCallbackRefcon(generation: UInt64) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(
            Unmanaged.passRetained(
                CompressionCallbackContext(encoder: self, generation: generation)
            ).toOpaque()
        )
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
        guard let refcon else { return }
        let context = Unmanaged<CompressionCallbackContext>
            .fromOpaque(refcon)
            .takeUnretainedValue()
        guard let encoder = context.activeEncoder() else { return }
        let delivery = CompressionCallbackDelivery(
            context: context,
            status: status,
            sampleBuffer: sampleBuffer
        )
        encoder.encodeQueue.async { [weak encoder, delivery] in
            guard let encoder,
                  delivery.context.activeEncoder() === encoder,
                  encoder.started,
                  encoder.activeGeneration == delivery.context.generation else {
                return
            }
            defer {
                encoder.encodeInFlight = false
                encoder.drainLatestEncodeOnQueue()
            }
            guard delivery.status == noErr,
                  let sampleBuffer = delivery.sampleBuffer else { return }
            encoder.handleCompressedSample(sampleBuffer)
        }
    }

    private func makePixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        dispatchPrecondition(condition: .onQueue(encodeQueue))
        return WebRTCCGDisplayPixelBufferRenderer.makePixelBuffer(
            from: image,
            width: width,
            height: height
        )
    }

    private func handleCompressedSample(_ sampleBuffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(encodeQueue))
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
                emitSmokeLog("🧪 cg-vt annexb-failed")
                return
            }
            payload = annexBPayload
        }

        let type: RemoteFrameType = codecType == kCMVideoCodecType_HEVC ? .hevc : .h264
        emitSmokeLog("🧪 cg-vt encoded bytes=\(payload.count) codec=\(type)")
        let handler = onEncodedFrame
        handler?(payload, width, height, type)
    }

    private func annexBPayload(from sampleBuffer: CMSampleBuffer, payload: Data) -> Data? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        let headerLength = max(1, nalUnitHeaderLength(from: formatDescription))
        guard headerLength <= 4 else { return nil }

        let shouldPrependParameterSets = isSyncSample(sampleBuffer) || !hasEmittedParameterSets
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

        guard offset == payload.count, !output.isEmpty else { return nil }
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
}
