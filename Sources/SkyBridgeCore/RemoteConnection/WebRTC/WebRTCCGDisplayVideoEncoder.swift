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

    private let stateLock = NSLock()
    private var encodeInFlight = false

    var onEncodedFrame: ((Data, Int, Int, RemoteFrameType) -> Void)?

    private final class CompressionCallbackContext {
        private let lock = NSLock()
        weak var encoder: WebRTCCGDisplayVideoEncoder?
        private var isActive = true

        init(encoder: WebRTCCGDisplayVideoEncoder) {
            self.encoder = encoder
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

    func start(
        preferredCodec: RemoteFrameType,
        preferredSize: CGSize,
        targetFPS: Int,
        keyFrameInterval: Int,
        bitstreamFormat: EncodedBitstreamFormat = .native
    ) throws {
        stop()

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
        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
            print("🧪 cg-vt start codec=\(preferredCodec) size=\(width)x\(height) fps=\(configuredFPS)")
        }
    }

    func stop() {
        started = false
        stateLock.lock()
        encodeInFlight = false
        stateLock.unlock()
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
        guard started else { return }
        guard beginEncodeCycle() else { return }

        let presentationTime = CMTime(
            value: CMTimeValue(max(timestamp, 0) * 1000.0),
            timescale: 1000
        )

        encodeQueue.async { [weak self] in
            guard let self else { return }
            guard let pixelBuffer = self.makePixelBuffer(from: image) else {
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print("🧪 cg-vt pixel-buffer-failed")
                }
                self.finishEncodeCycle()
                return
            }

            guard let compressionSession = self.compressionSession else {
                self.finishEncodeCycle()
                return
            }

            var flags = VTEncodeInfoFlags()
            let status = VTCompressionSessionEncodeFrame(
                compressionSession,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: presentationTime,
                duration: .invalid,
                frameProperties: self.nextFramePropertiesForEncode(),
                sourceFrameRefcon: nil,
                infoFlagsOut: &flags
            )
            if status != noErr {
                self.logger.error("❌ CGDisplay VT encode failed status=\(status, privacy: .public)")
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print("🧪 cg-vt encode-status=\(status)")
                }
                self.finishEncodeCycle()
            }
        }
    }

    private func beginEncodeCycle() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !encodeInFlight else { return false }
        encodeInFlight = true
        return true
    }

    private func finishEncodeCycle() {
        stateLock.lock()
        encodeInFlight = false
        stateLock.unlock()
    }

    func requestKeyFrameRefresh(reason: String, count: Int = 2) {
        let clampedCount = max(1, min(count, 4))
        stateLock.lock()
        pendingForcedKeyFrames = max(pendingForcedKeyFrames, clampedCount)
        stateLock.unlock()
        logger.info("🪄 WebRTC 直连编码器请求关键帧刷新: \(reason, privacy: .public)")
    }

    private func nextFramePropertiesForEncode() -> CFDictionary? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard pendingForcedKeyFrames > 0 else { return nil }
        pendingForcedKeyFrames -= 1
        return [kVTEncodeFrameOptionKey_ForceKeyFrame as String: kCFBooleanTrue as Any] as CFDictionary
    }

    private func setupCompressionSession(width: Int, height: Int, codec: CMVideoCodecType) throws {
        var session: VTCompressionSession?
        let callbackRefcon = makeCompressionCallbackRefcon()
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

    private func makeCompressionCallbackRefcon() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(Unmanaged.passRetained(CompressionCallbackContext(encoder: self)).toOpaque())
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
        let unmanaged = Unmanaged<CompressionCallbackContext>.fromOpaque(refcon)
        _ = unmanaged.retain()
        let context = unmanaged.takeUnretainedValue()
        defer { unmanaged.release() }
        guard let encoder = context.activeEncoder() else { return }
        defer { encoder.finishEncodeCycle() }
        guard status == noErr, let sampleBuffer else { return }
        encoder.handleCompressedSample(sampleBuffer)
    }

    private func makePixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        WebRTCCGDisplayPixelBufferRenderer.makePixelBuffer(from: image, width: width, height: height)
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
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print("🧪 cg-vt annexb-failed")
                }
                return
            }
            payload = annexBPayload
        }

        let type: RemoteFrameType = codecType == kCMVideoCodecType_HEVC ? .hevc : .h264
        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
            print("🧪 cg-vt encoded bytes=\(payload.count) codec=\(type)")
        }
        onEncodedFrame?(payload, width, height, type)
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
