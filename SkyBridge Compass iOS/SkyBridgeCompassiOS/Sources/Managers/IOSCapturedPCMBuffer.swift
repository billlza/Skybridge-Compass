import Foundation
import CoreMedia
import AudioToolbox
import SkyBridgeProtocolCore

enum IOSCapturedPCMError: Error, Equatable, Sendable {
    case invalidBuffer, notReady, dataFailed(OSStatus), unknownReadiness, notAudio, unsupportedFormat
    case unsupportedLayout, unsupportedProfile, profileMismatch, oversized, bufferShape
    case nonFiniteSample, unsupportedPresentation, invalidTiming, impreciseTiming
    case discontinuity, formatChanged, counterOverflow
}

/// ScreenCaptureKit's documented capture configuration, never the source music
/// file's format. Unsupported settings are rejected before the framework can
/// substitute its default. A native driver must configure this same profile.
struct IOSScreenCaptureAudioProfile: Equatable, Sendable {
    let sampleRate: UInt32
    let channels: UInt16
    var channelMask: UInt32 { channels == 1 ? 4 : 3 }

    init(sampleRate: UInt32, channels: UInt16) throws {
        guard [8_000, 16_000, 24_000, 48_000].contains(sampleRate), [1, 2].contains(channels) else {
            throw IOSCapturedPCMError.unsupportedProfile
        }
        self.sampleRate = sampleRate; self.channels = channels
    }
}

/// An owned canonical interleaved copy. Planar input changes memory ordering
/// only: each sample's bytes, precision, rate and channel position are retained.
/// No CMSampleBuffer or borrowed AudioBuffer pointer crosses an actor boundary.
struct IOSCapturedPCMBlock: Sendable {
    enum LayoutEvidence: Sendable { case formatDescription, screenCaptureKitProfile, undeclared }
    let format: AudioStreamingPCMFormat
    let bytes: Data
    let frameCount: UInt64
    let presentationTime: CMTime
    let layoutEvidence: LayoutEvidence
    let sourceWasPlanar: Bool

    static let maximumFrames = 16_384
    static let maximumBytes = 262_144

    static func copy(from sample: CMSampleBuffer,
                     profile: IOSScreenCaptureAudioProfile? = nil,
                     maximumTimestampDeviation: CMTime = .zero) throws -> Self {
        guard sample.isValid else { throw IOSCapturedPCMError.invalidBuffer }
        switch sample.dataReadiness {
        case .ready: break
        case .notReady: throw IOSCapturedPCMError.notReady
        case .failed(let status): throw IOSCapturedPCMError.dataFailed(status)
        @unknown default: throw IOSCapturedPCMError.unknownReadiness
        }
        guard let description = CMSampleBufferGetFormatDescription(sample),
              CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
              let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            throw IOSCapturedPCMError.notAudio
        }
        let asbd = pointer.pointee
        let shape = try formatShape(asbd)
        let frames = sample.numSamples
        guard frames > 0 else { throw IOSCapturedPCMError.invalidBuffer }
        guard frames <= maximumFrames, frames <= maximumBytes / shape.frameBytes else { throw IOSCapturedPCMError.oversized }
        var mask = try channelMask(description, channels: Int(asbd.mChannelsPerFrame))
        var evidence: LayoutEvidence = mask == nil ? .undeclared : .formatDescription
        if let profile {
            guard profile.sampleRate == UInt32(asbd.mSampleRate), profile.channels == asbd.mChannelsPerFrame,
                  mask == nil || mask == profile.channelMask else { throw IOSCapturedPCMError.profileMismatch }
            if mask == nil { mask = profile.channelMask; evidence = .screenCaptureKitProfile }
        }
        let format = try AudioStreamingPCMFormat(sampleRate: UInt32(asbd.mSampleRate), channels: UInt16(asbd.mChannelsPerFrame),
            encoding: shape.encoding, declaredValidBits: UInt8(asbd.mBitsPerChannel), waveChannelMask: mask)
        try validatePresentation(sample)
        try validateTiming(sample, frames: frames, rate: format.sampleRate, maximumTimestampDeviation: maximumTimestampDeviation)
        let byteCount = frames * shape.frameBytes
        guard let nativeData = sample.dataBuffer else { throw IOSCapturedPCMError.bufferShape }
        let nativeLength = CMBlockBufferGetDataLength(nativeData)
        // Bound the native helper before it can consolidate discontiguous data.
        // CoreMedia may add up to 16 bytes of alignment storage per plane.
        let nativeMaximum = byteCount + 16 * (shape.planar ? Int(format.channels) : 1)
        guard nativeLength >= byteCount, nativeLength <= nativeMaximum else { throw IOSCapturedPCMError.bufferShape }
        let bytes = try sample.withAudioBufferList { buffers, retainedBlock in
            try withExtendedLifetime(retainedBlock) {
                let expectedCount = shape.planar ? Int(format.channels) : 1
                guard buffers.count == expectedCount else { throw IOSCapturedPCMError.bufferShape }
                for buffer in buffers {
                    guard buffer.mNumberChannels == (shape.planar ? 1 : UInt32(format.channels)),
                          buffer.mDataByteSize == frames * Int(asbd.mBytesPerFrame), buffer.mData != nil else {
                        throw IOSCapturedPCMError.bufferShape
                    }
                }
                if !shape.planar {
                    guard let data = buffers[0].mData else { throw IOSCapturedPCMError.bufferShape }
                    return Data(bytes: data, count: byteCount)
                }
                var result = Data(count: byteCount)
                try result.withUnsafeMutableBytes { output in
                    guard let destination = output.baseAddress else { throw IOSCapturedPCMError.bufferShape }
                    for frame in 0..<frames {
                        for channel in 0..<Int(format.channels) {
                            guard let source = buffers[channel].mData else { throw IOSCapturedPCMError.bufferShape }
                            destination.advanced(by: frame * shape.frameBytes + channel * shape.sampleBytes)
                                .copyMemory(from: source.advanced(by: frame * shape.sampleBytes), byteCount: shape.sampleBytes)
                        }
                    }
                }
                return result
            }
        }
        try validateFinite(bytes, encoding: format.encoding)
        return Self(format: format, bytes: bytes, frameCount: UInt64(frames), presentationTime: sample.presentationTimeStamp,
                    layoutEvidence: evidence, sourceWasPlanar: shape.planar)
    }

    private struct Shape {
        let planar: Bool
        let sampleBytes: Int
        let frameBytes: Int
        let encoding: AudioStreamingPCMFormat.Encoding
    }

    private static func formatShape(_ asbd: AudioStreamBasicDescription) throws -> Shape {
        let allowed = kAudioFormatFlagIsFloat | kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
            | kAudioFormatFlagIsAlignedHigh | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsNonMixable
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate.isFinite,
              asbd.mSampleRate > 0, asbd.mSampleRate <= Double(Int32.max), asbd.mSampleRate.rounded() == asbd.mSampleRate,
              (1...2).contains(asbd.mChannelsPerFrame), asbd.mFramesPerPacket == 1,
              asbd.mBytesPerPacket == asbd.mBytesPerFrame, asbd.mBytesPerFrame > 0, asbd.mReserved == 0,
              asbd.mFormatFlags & ~allowed == 0 else { throw IOSCapturedPCMError.unsupportedFormat }
        let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let divisor = planar ? 1 : asbd.mChannelsPerFrame
        guard asbd.mBytesPerFrame % divisor == 0 else { throw IOSCapturedPCMError.unsupportedFormat }
        let sampleBytes = Int(asbd.mBytesPerFrame / divisor), containerBits = sampleBytes * 8
        guard [1, 2, 3, 4, 8].contains(sampleBytes), asbd.mBitsPerChannel > 0,
              asbd.mBitsPerChannel <= containerBits else { throw IOSCapturedPCMError.unsupportedFormat }
        let floating = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let signed = asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let packed = asbd.mFormatFlags & kAudioFormatFlagIsPacked != 0
        let high = asbd.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0
        guard packed == (asbd.mBitsPerChannel == containerBits), high == !packed else {
            throw IOSCapturedPCMError.unsupportedFormat
        }
        let encoding: AudioStreamingPCMFormat.Encoding
        if floating {
            guard !signed, packed, [4, 8].contains(sampleBytes) else { throw IOSCapturedPCMError.unsupportedFormat }
            encoding = sampleBytes == 4 ? .float32 : .float64
        } else if sampleBytes == 1 {
            guard !signed, packed else { throw IOSCapturedPCMError.unsupportedFormat }
            encoding = .unsigned8
        } else {
            guard signed else { throw IOSCapturedPCMError.unsupportedFormat }
            switch sampleBytes {
            case 2: encoding = .signed16
            case 3: encoding = .signed24
            case 4: encoding = .signed32
            case 8: encoding = .signed64
            default: throw IOSCapturedPCMError.unsupportedFormat
            }
        }
        return Shape(planar: planar, sampleBytes: sampleBytes,
                     frameBytes: sampleBytes * Int(asbd.mChannelsPerFrame), encoding: encoding)
    }

    private static func channelMask(_ description: CMAudioFormatDescription, channels: Int) throws -> UInt32? {
        var size = 0
        guard let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &size) else { return nil }
        guard let header = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions), size >= header else {
            throw IOSCapturedPCMError.unsupportedLayout
        }
        // The C API can return only the three-field header for a named layout;
        // loading an entire AudioChannelLayout would read its absent first entry.
        let raw = UnsafeRawPointer(layout)
        let tag = raw.loadUnaligned(as: UInt32.self)
        let bitmap = raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let count = raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
        if tag == kAudioChannelLayoutTag_Mono, channels == 1, count == 0 { return 4 }
        if tag == kAudioChannelLayoutTag_Stereo, channels == 2, count == 0 { return 3 }
        if tag == kAudioChannelLayoutTag_UseChannelBitmap, count == 0,
           bitmap == (channels == 1 ? 4 : 3) { return bitmap }
        if tag & 0xffff0000 == kAudioChannelLayoutTag_DiscreteInOrder,
           tag & 0xffff == channels, count == 0 { return 0 }
        if tag & 0xffff0000 == kAudioChannelLayoutTag_Unknown, count == 0 { return nil }
        guard tag == kAudioChannelLayoutTag_UseChannelDescriptions, count == channels,
              size >= header + channels * MemoryLayout<AudioChannelDescription>.stride else {
            throw IOSCapturedPCMError.unsupportedLayout
        }
        let labels = (0..<channels).map {
            raw.loadUnaligned(fromByteOffset: header + $0 * MemoryLayout<AudioChannelDescription>.stride,
                              as: AudioChannelDescription.self).mChannelLabel
        }
        if labels == [kAudioChannelLabel_Center] { return 4 }
        if labels == [kAudioChannelLabel_Left, kAudioChannelLabel_Right] { return 3 }
        if labels == (0..<channels).map({ kAudioChannelLabel_Discrete_0 + UInt32($0) }) { return 0 }
        if labels.allSatisfy({ $0 == kAudioChannelLabel_Unknown }) { return nil }
        throw IOSCapturedPCMError.unsupportedLayout
    }

    private static func validatePresentation(_ sample: CMSampleBuffer) throws {
        for key in [kCMSampleBufferAttachmentKey_Reverse, kCMSampleBufferAttachmentKey_FillDiscontinuitiesWithSilence,
                    kCMSampleBufferAttachmentKey_EmptyMedia, kCMSampleBufferAttachmentKey_PermanentEmptyMedia] {
            if let value = CMGetAttachment(sample, key: key, attachmentModeOut: nil),
               CFGetTypeID(value) != CFBooleanGetTypeID() || !CFEqual(value, kCFBooleanFalse) {
                throw IOSCapturedPCMError.unsupportedPresentation
            }
        }
        for key in [kCMSampleBufferAttachmentKey_TrimDurationAtStart, kCMSampleBufferAttachmentKey_TrimDurationAtEnd] {
            if let value = CMGetAttachment(sample, key: key, attachmentModeOut: nil) {
                guard CFGetTypeID(value) == CFDictionaryGetTypeID(), let dictionary = value as? [String: Any] else {
                    throw IOSCapturedPCMError.unsupportedPresentation
                }
                let time = CMTimeMakeFromDictionary(dictionary as CFDictionary)
                guard time.isNumeric, CMTimeCompare(time, .zero) == 0 else { throw IOSCapturedPCMError.unsupportedPresentation }
            }
        }
        if let value = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_SpeedMultiplier, attachmentModeOut: nil) {
            guard CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber,
                  number.doubleValue == 1 else { throw IOSCapturedPCMError.unsupportedPresentation }
        }
        guard sample.presentationTimeStamp.isNumeric, sample.outputPresentationTimeStamp.isNumeric,
              sample.duration.isNumeric, sample.outputDuration.isNumeric,
              CMTimeCompare(sample.presentationTimeStamp, sample.outputPresentationTimeStamp) == 0,
              CMTimeCompare(sample.duration, sample.outputDuration) == 0 else {
            throw IOSCapturedPCMError.unsupportedPresentation
        }
    }

    private static func validateTiming(_ sample: CMSampleBuffer, frames: Int, rate: UInt32,
                                       maximumTimestampDeviation: CMTime) throws {
        var needed = 0
        let status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &needed)
        guard status == noErr else { throw IOSCapturedPCMError.dataFailed(status) }
        guard needed == 1 || needed == frames else { throw IOSCapturedPCMError.invalidTiming }
        let timings = try sample.sampleTimingInfos()
        guard timings.count == needed else { throw IOSCapturedPCMError.invalidTiming }
        let unit = CMTime(value: 1, timescale: Int32(rate))
        for (index, timing) in timings.enumerated() {
            guard timing.duration.isNumeric, CMTimeCompare(timing.duration, unit) == 0 else {
                throw IOSCapturedPCMError.invalidTiming
            }
            if index == 0 {
                guard timing.presentationTimeStamp.isNumeric,
                      CMTimeCompare(timing.presentationTimeStamp, sample.presentationTimeStamp) == 0 else {
                    throw IOSCapturedPCMError.invalidTiming
                }
            } else {
                try IOSCapturedPCMTimeline.validate(timing.presentationTimeStamp, origin: sample.presentationTimeStamp,
                    frameOffset: UInt64(index), sampleRate: rate, maximumDeviation: maximumTimestampDeviation)
            }
        }
        guard CMTimeCompare(sample.duration, CMTime(value: Int64(frames), timescale: Int32(rate))) == 0 else {
            throw IOSCapturedPCMError.invalidTiming
        }
    }

    private static func validateFinite(_ bytes: Data, encoding: AudioStreamingPCMFormat.Encoding) throws {
        guard encoding.isFloatingPoint else { return }
        let stride = Int(encoding.containerBits / 8)
        try bytes.withUnsafeBytes { raw in
            for offset in Swift.stride(from: 0, to: raw.count, by: stride) {
                var bits: UInt64 = 0
                for byte in 0..<stride { bits |= UInt64(raw[offset + byte]) << (8 * byte) }
                let exponent: UInt64 = stride == 4 ? 0x7f800000 : 0x7ff0000000000000
                if bits & exponent == exponent { throw IOSCapturedPCMError.nonFiniteSample }
            }
        }
    }
}

/// Audits a declared fixed sample clock. A nonzero allowance must come from an
/// independently justified backend clock contract; CMTime's rounded flag can be
/// inherited from an arbitrarily older conversion and cannot supply that bound.
/// The exact default never invents a tolerance from a timestamp's denominator.
enum IOSCapturedPCMTimeline {
    static func validate(_ actual: CMTime, origin: CMTime, frameOffset: UInt64, sampleRate: UInt32,
                         maximumDeviation: CMTime = .zero) throws {
        guard actual.isNumeric, origin.isNumeric, actual.epoch == origin.epoch,
              actual.timescale > 0, origin.timescale > 0, sampleRate > 0, sampleRate <= UInt32(Int32.max),
              frameOffset <= UInt64(Int64.max), maximumDeviation.isNumeric, maximumDeviation.timescale > 0,
              maximumDeviation.epoch == 0, !maximumDeviation.flags.contains(.hasBeenRounded),
              CMTimeCompare(maximumDeviation, .zero) >= 0 else { throw IOSCapturedPCMError.invalidTiming }
        let exact = CMTimeCompare(maximumDeviation, .zero) == 0
        if exact, actual.flags.contains(.hasBeenRounded) || origin.flags.contains(.hasBeenRounded) {
            throw IOSCapturedPCMError.impreciseTiming
        }
        // This is arithmetic on the reported rational origin, not a replacement
        // of its source metadata. Its historical rounding is covered only by the
        // explicit backend bound. Clearing that flag locally detects NEW rounding.
        let rationalOrigin = CMTime(value: origin.value, timescale: origin.timescale, flags: .valid, epoch: origin.epoch)
        let expected = frameOffset == 0 ? rationalOrigin
            : CMTimeAdd(rationalOrigin, CMTime(value: Int64(frameOffset), timescale: Int32(sampleRate)))
        guard expected.isNumeric else { throw IOSCapturedPCMError.invalidTiming }
        if exact, expected.flags.contains(.hasBeenRounded) { throw IOSCapturedPCMError.impreciseTiming }
        let arithmeticError = expected.flags.contains(.hasBeenRounded) ? CMTime(value: 1, timescale: expected.timescale) : .zero
        let radius = CMTimeAdd(maximumDeviation, arithmeticError)
        let rationalExpected = CMTime(value: expected.value, timescale: expected.timescale, flags: .valid, epoch: expected.epoch)
        let lower = CMTimeSubtract(rationalExpected, radius), upper = CMTimeAdd(rationalExpected, radius)
        let width = CMTimeSubtract(upper, lower)
        guard radius.isNumeric, lower.isNumeric, upper.isNumeric, width.isNumeric,
              CMTimeCompare(lower, rationalExpected) <= 0, CMTimeCompare(upper, rationalExpected) >= 0,
              CMTimeCompare(width, CMTime(value: 1, timescale: Int32(sampleRate))) < 0 else {
            throw IOSCapturedPCMError.impreciseTiming
        }
        guard CMTimeCompare(actual, lower) >= 0, CMTimeCompare(actual, upper) <= 0 else {
            throw IOSCapturedPCMError.discontinuity
        }
    }
}

/// One serial capture callback owner consumes this value. The first failure is
/// terminal; a new stream requires a new value and an independently admitted owner.
struct IOSCapturedPCMSequence: Sendable {
    struct Chunk: Sendable {
        let block: IOSCapturedPCMBlock
        let frameOffset: UInt64
    }
    private let profile: IOSScreenCaptureAudioProfile?
    private let maximumTimestampDeviation: CMTime
    private var format: AudioStreamingPCMFormat?
    private var origin: CMTime?
    private(set) var frames: UInt64 = 0
    private var terminal: (any Error)?

    init(profile: IOSScreenCaptureAudioProfile? = nil, maximumTimestampDeviation: CMTime = .zero) {
        self.profile = profile; self.maximumTimestampDeviation = maximumTimestampDeviation
    }

    mutating func consume(_ sample: CMSampleBuffer) throws -> Chunk {
        if let terminal { throw terminal }
        do {
            let block = try IOSCapturedPCMBlock.copy(from: sample, profile: profile, maximumTimestampDeviation: maximumTimestampDeviation)
            if let format, format != block.format { throw IOSCapturedPCMError.formatChanged }
            let origin = self.origin ?? block.presentationTime
            try IOSCapturedPCMTimeline.validate(block.presentationTime, origin: origin,
                frameOffset: frames, sampleRate: block.format.sampleRate, maximumDeviation: maximumTimestampDeviation)
            let next = frames.addingReportingOverflow(block.frameCount)
            guard !next.overflow, next.partialValue <= AudioStreamingWire.maximumCounter / UInt64(block.format.bytesPerFrame) else {
                throw IOSCapturedPCMError.counterOverflow
            }
            let chunk = Chunk(block: block, frameOffset: frames)
            self.origin = origin; format = block.format; frames = next.partialValue
            return chunk
        } catch { terminal = error; throw error }
    }
}
