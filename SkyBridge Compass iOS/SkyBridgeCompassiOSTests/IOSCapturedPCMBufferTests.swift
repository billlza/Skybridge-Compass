import XCTest
import Foundation
import CoreMedia
import CryptoKit
import Network
import AudioToolbox
import os
import SwiftUI
import UIKit
import SkyBridgeProtocolCore
@testable import SkyBridgeCompass_iOS

/// Real CoreMedia descriptors, owned PCM block buffers and timing records.
/// These are constructed samples, not recordings from ReplayKit/ScreenCaptureKit.
@MainActor
final class IOSCapturedPCMBufferTests: XCTestCase {
    func testNativeBufferStaysInsideProducerTaskAndOnlyOwnedBytesCrossActors() async throws {
        let bytes = pcmBytes([0x80000000, 1, 0x3f800001, 0xbf800000], width: 4)
        let result = try await Task.detached(priority: .utility) {
            let sample = try makeSample(asbd: pcmDescription(floating: true), planes: [bytes])
            return try IOSCapturedPCMBlock.copy(from: sample)
        }.value
        XCTAssertEqual(result.bytes, bytes); XCTAssertEqual(result.frameCount, 2)
    }

    func testInterleavedFloat32PreservesSignedZeroSubnormalAndExactSampleBits() throws {
        let words: [UInt64] = [0x80000000, 0, 1, 0x007fffff, 0x3f800001, 0xbf800000]
        let bytes = pcmBytes(words, width: 4)
        let sample = try makeSample(asbd: pcmDescription(floating: true), planes: [bytes])
        let block = try IOSCapturedPCMBlock.copy(from: sample)
        XCTAssertEqual(block.bytes, bytes); XCTAssertEqual(block.frameCount, 3)
        XCTAssertEqual(block.format.encoding, .float32); XCTAssertEqual(block.format.sampleRate, 48_000)
        XCTAssertEqual(block.format.declaredValidBits, 32); XCTAssertEqual(block.format.waveChannelMask, 3)
        XCTAssertFalse(block.sourceWasPlanar)
        let message = AudioStreamingMessage(streamID: UUID(), body: .pcmData(byteOffset: 0, bytes: block.bytes))
        XCTAssertEqual(try AudioStreamingWire.decode(AudioStreamingWire.encode(message)), message)
    }

    func testPlanarFloat32ReordersMemoryWithoutChangingAnySampleBits() throws {
        let left: [UInt64] = [0x80000000, 1, 0x3f800001]
        let right: [UInt64] = [0, 0x007fffff, 0xbf800000]
        let sample = try makeSample(asbd: pcmDescription(floating: true, planar: true),
            planes: [pcmBytes(left, width: 4), pcmBytes(right, width: 4)])
        let block = try IOSCapturedPCMBlock.copy(from: sample)
        XCTAssertEqual(block.bytes, pcmBytes(zip(left, right).flatMap { [$0.0, $0.1] }, width: 4))
        XCTAssertTrue(block.sourceWasPlanar); XCTAssertEqual(block.format.channels, 2)
    }

    func testFloat64AndIntegerPrecisionsRemainUnchanged() throws {
        let cases: [(Int, Int, Bool, AudioStreamingPCMFormat.Encoding, [UInt64])] = [
            (1, 8, false, .unsigned8, [0, 0xff]),
            (2, 16, false, .signed16, [0x8000, 0x7fff]),
            (3, 24, false, .signed24, [0x800000, 0x7fffff]),
            (4, 24, false, .signed32, [0x80000000, 0x7fffff00]),
            (4, 32, false, .signed32, [0x80000001, 0x7fffffff]),
            (8, 64, false, .signed64, [0x8000000000000001, 0x7fffffffffffffff]),
            (8, 64, true, .float64, [0x8000000000000000, 1])
        ]
        for (width, bits, floating, encoding, words) in cases {
            let bytes = pcmBytes(words, width: width)
            let sample = try makeSample(asbd: pcmDescription(width: width, bits: bits, floating: floating), planes: [bytes])
            let block = try IOSCapturedPCMBlock.copy(from: sample)
            XCTAssertEqual(block.bytes, bytes); XCTAssertEqual(block.format.encoding, encoding)
            XCTAssertEqual(block.format.declaredValidBits, UInt8(bits))
            XCTAssertEqual(block.format.bytesPerFrame, UInt32(width * 2))
        }
    }

    func testNonFiniteFloatSamplesFailInsteadOfEnteringOutput() throws {
        for (width, bits) in [(4, UInt64(0x7f800000)), (4, 0xff800000), (4, 0x7fc01234),
                              (8, 0x7ff0000000000000), (8, 0xfff0000000000000), (8, 0x7ff8000000001234)] {
            let sample = try makeSample(asbd: pcmDescription(width: width, floating: true), planes: [pcmBytes([bits, 0], width: width)])
            XCTAssertThrowsError(try IOSCapturedPCMBlock.copy(from: sample)) {
                XCTAssertEqual($0 as? IOSCapturedPCMError, .nonFiniteSample)
            }
        }
    }

    func testOwnedCopySurvivesMutationAndInvalidationOfNativeBuffer() throws {
        let bytes = pcmBytes([0x12345678, 0x87654321], width: 4)
        let sample = try makeSample(asbd: pcmDescription(), planes: [bytes])
        let result = try IOSCapturedPCMBlock.copy(from: sample)
        let native = try XCTUnwrap(sample.dataBuffer)
        let zeros = Data(repeating: 0, count: bytes.count)
        let status = try zeros.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: try XCTUnwrap(raw.baseAddress), blockBuffer: native, offsetIntoDestination: 0, dataLength: raw.count)
        }
        XCTAssertEqual(status, noErr)
        try sample.invalidate()
        XCTAssertEqual(result.bytes, bytes)
    }

    func testUnknownLayoutStaysUnknownUnlessTheCaptureAPIDeclaresIt() throws {
        let sample = try makeSample(asbd: pcmDescription(floating: true), planes: [Data(repeating: 0, count: 16)], layout: nil)
        let unknown = try IOSCapturedPCMBlock.copy(from: sample)
        XCTAssertNil(unknown.format.waveChannelMask)
        let profile = try IOSScreenCaptureAudioProfile(sampleRate: 48_000, channels: 2)
        let declared = try IOSCapturedPCMBlock.copy(from: sample, profile: profile)
        XCTAssertEqual(declared.format.waveChannelMask, 3)
        if case .screenCaptureKitProfile = declared.layoutEvidence {} else { XCTFail("Missing layout provenance") }
    }

    func testCaptureProfileRejectsUnsupportedSettingsAndObservedSubstitution() throws {
        for rate: UInt32 in [0, 44_100, 88_200, 96_000] {
            XCTAssertThrowsError(try IOSScreenCaptureAudioProfile(sampleRate: rate, channels: 2))
        }
        XCTAssertThrowsError(try IOSScreenCaptureAudioProfile(sampleRate: 48_000, channels: 6))
        let sample = try makeSample(asbd: pcmDescription(rate: 44_100, floating: true), planes: [Data(repeating: 0, count: 16)], layout: nil)
        let profile = try IOSScreenCaptureAudioProfile(sampleRate: 48_000, channels: 2)
        XCTAssertThrowsError(try IOSCapturedPCMBlock.copy(from: sample, profile: profile)) {
            XCTAssertEqual($0 as? IOSCapturedPCMError, .profileMismatch)
        }
        // Without a ScreenCaptureKit declaration, 44.1 kHz PCM remains 44.1 kHz.
        XCTAssertEqual(try IOSCapturedPCMBlock.copy(from: sample).format.sampleRate, 44_100)
    }

    func testMonoBitmapAndDiscreteLayoutsKeepTheirDeclaredMeaning() throws {
        for (channels, tag, bitmap, expected): (UInt32, UInt32, UInt32, UInt32) in [
            (1, kAudioChannelLayoutTag_Mono, 0, 4),
            (2, kAudioChannelLayoutTag_UseChannelBitmap, 3, 3),
            (2, kAudioChannelLayoutTag_DiscreteInOrder | 2, 0, 0)
        ] {
            let sample = try makeSample(asbd: pcmDescription(channels: channels),
                planes: [Data(repeating: 0, count: Int(channels) * 4)], layout: tag, bitmap: bitmap)
            XCTAssertEqual(try IOSCapturedPCMBlock.copy(from: sample).format.waveChannelMask, expected)
        }
    }

    func testProfileCannotOverwriteAnExplicitlyDifferentLayout() throws {
        let sample = try makeSample(asbd: pcmDescription(), planes: [Data(repeating: 0, count: 16)],
            layout: kAudioChannelLayoutTag_DiscreteInOrder | 2)
        XCTAssertThrowsError(try IOSCapturedPCMBlock.copy(from: sample,
            profile: IOSScreenCaptureAudioProfile(sampleRate: 48_000, channels: 2))) {
                XCTAssertEqual($0 as? IOSCapturedPCMError, .profileMismatch)
            }
    }

    func testUnreadyInvalidAndFailedBuffersRemainFailures() throws {
        let sample = try makeSample(asbd: pcmDescription(), planes: [Data(repeating: 0, count: 8)], ready: false)
        XCTAssertThrowsError(try IOSCapturedPCMBlock.copy(from: sample)) { XCTAssertEqual($0 as? IOSCapturedPCMError, .notReady) }
        try sample.setDataReadiness(.failed(-12_345))
        XCTAssertThrowsError(try IOSCapturedPCMBlock.copy(from: sample)) { XCTAssertEqual($0 as? IOSCapturedPCMError, .dataFailed(-12_345)) }
        try sample.invalidate()
        XCTAssertThrowsError(try IOSCapturedPCMBlock.copy(from: sample)) { XCTAssertEqual($0 as? IOSCapturedPCMError, .invalidBuffer) }
    }

    func testUnsupportedEndianPrecisionAndSignedEightBitNeverConvert() throws {
        var bigEndian = pcmDescription(); bigEndian.mFormatFlags |= kAudioFormatFlagIsBigEndian
        var lowAligned = pcmDescription(bits: 24); lowAligned.mFormatFlags &= ~kAudioFormatFlagIsAlignedHigh
        var signed8 = pcmDescription(width: 1); signed8.mFormatFlags |= kAudioFormatFlagIsSignedInteger
        for asbd in [bigEndian, lowAligned, signed8] {
            let sample = try makeSample(asbd: asbd, planes: [Data(repeating: 0, count: Int(asbd.mBytesPerFrame))])
            XCTAssertThrowsError(try IOSCapturedPCMBlock.copy(from: sample)) {
                XCTAssertEqual($0 as? IOSCapturedPCMError, .unsupportedFormat)
            }
        }
    }

    func testOversizedBufferIsRejectedBeforeCopyingItsSamples() throws {
        let asbd = pcmDescription()
        let sample = try makeSample(asbd: asbd, planes: [Data(repeating: 0, count: Int(asbd.mBytesPerFrame) * 16_385)])
        XCTAssertThrowsError(try IOSCapturedPCMBlock.copy(from: sample)) { XCTAssertEqual($0 as? IOSCapturedPCMError, .oversized) }
    }

    func testPresentationEditsAndSyntheticSilenceAreNotSilentlyApplied() throws {
        let make = { try makeSample(asbd: pcmDescription(), planes: [Data(repeating: 0, count: 16)]) }
        for key in [kCMSampleBufferAttachmentKey_Reverse, kCMSampleBufferAttachmentKey_FillDiscontinuitiesWithSilence,
                    kCMSampleBufferAttachmentKey_EmptyMedia, kCMSampleBufferAttachmentKey_PermanentEmptyMedia] {
            let sample = try make()
            CMSetAttachment(sample, key: key, value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
            XCTAssertThrowsError(try IOSCapturedPCMBlock.copy(from: sample)) { XCTAssertEqual($0 as? IOSCapturedPCMError, .unsupportedPresentation) }
        }
        let trimmed = try make()
        CMSetAttachment(trimmed, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
            value: try XCTUnwrap(CMTimeCopyAsDictionary(CMTime(value: 1, timescale: 48_000), allocator: kCFAllocatorDefault)),
            attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertThrowsError(try IOSCapturedPCMBlock.copy(from: trimmed)) { XCTAssertEqual($0 as? IOSCapturedPCMError, .unsupportedPresentation) }
        let sped = try make()
        CMSetAttachment(sped, key: kCMSampleBufferAttachmentKey_SpeedMultiplier, value: NSNumber(value: 2), attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertThrowsError(try IOSCapturedPCMBlock.copy(from: sped)) { XCTAssertEqual($0 as? IOSCapturedPCMError, .unsupportedPresentation) }
    }

    func testExplicitIdentityPresentationAttachmentsAreAllowed() throws {
        let sample = try makeSample(asbd: pcmDescription(), planes: [Data(repeating: 0, count: 16)])
        CMSetAttachment(sample, key: kCMSampleBufferAttachmentKey_Reverse, value: kCFBooleanFalse, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        CMSetAttachment(sample, key: kCMSampleBufferAttachmentKey_SpeedMultiplier, value: NSNumber(value: 1), attachmentMode: kCMAttachmentMode_ShouldPropagate)
        CMSetAttachment(sample, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
            value: try XCTUnwrap(CMTimeCopyAsDictionary(.zero, allocator: kCFAllocatorDefault)), attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertEqual(try IOSCapturedPCMBlock.copy(from: sample).frameCount, 2)
    }

    func testExactSampleClockContinuesAcrossDifferentBlockSizes() throws {
        var sequence = IOSCapturedPCMSequence()
        for (offset, frames): (Int64, Int) in [(0, 3), (3, 17), (20, 1)] {
            let sample = try makeSample(asbd: pcmDescription(), planes: [Data(repeating: 0, count: frames * 8)],
                pts: CMTime(value: 480_000 + offset, timescale: 48_000))
            XCTAssertEqual(try sequence.consume(sample).frameOffset, UInt64(offset))
        }
        XCTAssertEqual(sequence.frames, 21)
    }

    func testNanosecondTimestampRoundingDoesNotRequireResampling() throws {
        var sequence = IOSCapturedPCMSequence(maximumTimestampDeviation: CMTime(value: 3, timescale: 1_000_000_000))
        for block in 0..<50 {
            let frame = Int64(block * 256)
            let sample = try makeSample(asbd: pcmDescription(), planes: [Data(repeating: 0, count: 256 * 8)],
                pts: CMTime(value: 10_000_000_000 + frame * 1_000_000_000 / 48_000, timescale: 1_000_000_000))
            XCTAssertEqual(try sequence.consume(sample).frameOffset, UInt64(frame))
        }
    }

    func testRepresentationTimescaleMayChangeWithoutChangingTheAudioClock() throws {
        var sequence = IOSCapturedPCMSequence(maximumTimestampDeviation: CMTime(value: 3, timescale: 1_000_000_000))
        let first = try makeSample(asbd: pcmDescription(), planes: [Data(repeating: 0, count: 8)],
            pts: CMTime(value: 480_000, timescale: 48_000))
        _ = try sequence.consume(first)
        let second = try makeSample(asbd: pcmDescription(), planes: [Data(repeating: 0, count: 8)],
            pts: CMTime(value: 10_000_020_833, timescale: 1_000_000_000))
        XCTAssertEqual(try sequence.consume(second).frameOffset, 1)
    }

    func testMissingOrRepeatedFrameIsTerminalAndDoesNotResetTheAnchor() throws {
        for delta: Int64 in [-1, 1] {
            var sequence = IOSCapturedPCMSequence()
            _ = try sequence.consume(makeSample(asbd: pcmDescription(), planes: [Data(repeating: 0, count: 8 * 10)]))
            let wrong = try makeSample(asbd: pcmDescription(), planes: [Data(repeating: 0, count: 8)],
                pts: CMTime(value: 480_000 + 10 + delta, timescale: 48_000))
            XCTAssertThrowsError(try sequence.consume(wrong)) { XCTAssertEqual($0 as? IOSCapturedPCMError, .discontinuity) }
            let correct = try makeSample(asbd: pcmDescription(), planes: [Data(repeating: 0, count: 8)],
                pts: CMTime(value: 480_010, timescale: 48_000))
            XCTAssertThrowsError(try sequence.consume(correct)) { XCTAssertEqual($0 as? IOSCapturedPCMError, .discontinuity) }
            XCTAssertEqual(sequence.frames, 10)
        }
    }

    func testRoundingToleranceCannotAccumulateAcrossBlocks() throws {
        var sequence = IOSCapturedPCMSequence(maximumTimestampDeviation: CMTime(value: 3, timescale: 1_000_000_000))
        var rejected = false
        for index in 0..<12 {
            let sample = try makeSample(asbd: pcmDescription(), planes: [Data(repeating: 0, count: 256 * 8)],
                pts: CMTime(value: 10_000_000_000 + Int64(index * 256) * 1_000_000_000 / 48_000 + Int64(index * 2), timescale: 1_000_000_000))
            do { _ = try sequence.consume(sample) }
            catch { XCTAssertEqual(error as? IOSCapturedPCMError, .discontinuity); rejected = true; break }
        }
        XCTAssertTrue(rejected, "A fresh tolerance for each block would accumulate drift")
    }

    func testCoarseClockAndFormatChangeFailExplicitly() throws {
        let coarse = try makeSample(asbd: pcmDescription(), planes: [Data(repeating: 0, count: 8)], pts: CMTime(value: 10_000, timescale: 1000, flags: [.valid, .hasBeenRounded], epoch: 0))
        var coarseSequence = IOSCapturedPCMSequence()
        XCTAssertThrowsError(try coarseSequence.consume(coarse)) { XCTAssertEqual($0 as? IOSCapturedPCMError, .impreciseTiming) }
        var sequence = IOSCapturedPCMSequence()
        _ = try sequence.consume(makeSample(asbd: pcmDescription(), planes: [Data(repeating: 0, count: 8)]))
        let changed = try makeSample(asbd: pcmDescription(rate: 24_000), planes: [Data(repeating: 0, count: 8)],
            pts: CMTime(value: 480_001, timescale: 48_000))
        XCTAssertThrowsError(try sequence.consume(changed)) { XCTAssertEqual($0 as? IOSCapturedPCMError, .formatChanged) }
    }

    func testTimelineRejectsClockEpochChangeAndArithmeticOverflow() throws {
        XCTAssertThrowsError(try IOSCapturedPCMTimeline.validate(CMTime(value: 0, timescale: 48_000, flags: .valid, epoch: 2),
            origin: CMTime(value: 0, timescale: 48_000, flags: .valid, epoch: 1), frameOffset: 0, sampleRate: 48_000))
        XCTAssertThrowsError(try IOSCapturedPCMTimeline.validate(CMTime(value: Int64.max, timescale: 48_000),
            origin: CMTime(value: Int64.max, timescale: 48_000), frameOffset: 1, sampleRate: 48_000))
    }

    func testCompactRationalTimeDoesNotImplyAnImpreciseClock() throws {
        var sequence = IOSCapturedPCMSequence()
        _ = try sequence.consume(makeSample(asbd: pcmDescription(), planes: [Data(repeating: 0, count: 8)],
            pts: CMTime(value: 10, timescale: 1)))
        let next = try makeSample(asbd: pcmDescription(), planes: [Data(repeating: 0, count: 8)],
            pts: CMTime(value: 480_001, timescale: 48_000))
        XCTAssertEqual(try sequence.consume(next).frameOffset, 1)
    }

    func testInheritedRoundingNeedsAnExplicitBoundAndWholeFrameAllowanceIsRejected() throws {
        let sample = try makeSample(asbd: pcmDescription(), planes: [Data(repeating: 0, count: 8)],
            pts: CMTime(value: 10_000_000_000, timescale: 1_000_000_000, flags: [.valid, .hasBeenRounded], epoch: 0))
        var exact = IOSCapturedPCMSequence()
        XCTAssertThrowsError(try exact.consume(sample)) { XCTAssertEqual($0 as? IOSCapturedPCMError, .impreciseTiming) }
        // This bound is justified by this fixture's constructed timestamp; it is
        // not evidence that a real capture backend has a three-nanosecond bound.
        var bounded = IOSCapturedPCMSequence(maximumTimestampDeviation: CMTime(value: 3, timescale: 1_000_000_000))
        XCTAssertEqual(try bounded.consume(sample).frameOffset, 0)
        var tooWide = IOSCapturedPCMSequence(maximumTimestampDeviation: CMTime(value: 1, timescale: 48_000))
        XCTAssertThrowsError(try tooWide.consume(sample)) { XCTAssertEqual($0 as? IOSCapturedPCMError, .impreciseTiming) }
    }

    func testNativeStorageLengthIsBoundedBeforeAudioBufferListConsolidation() throws {
        let sample = try makeSample(asbd: pcmDescription(), planes: [Data(repeating: 0, count: 262_144)], framesOverride: 1)
        XCTAssertEqual(sample.numSamples, 1)
        XCTAssertThrowsError(try IOSCapturedPCMBlock.copy(from: sample)) { XCTAssertEqual($0 as? IOSCapturedPCMError, .bufferShape) }
    }

    func testPerSampleTimingCannotHideAnInternalMissingFrame() throws {
        let first = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: 480_000, timescale: 48_000), decodeTimeStamp: .invalid)
        for missing in [false, true] {
            let second = CMSampleTimingInfo(duration: first.duration,
                presentationTimeStamp: CMTime(value: missing ? 480_002 : 480_001, timescale: 48_000), decodeTimeStamp: .invalid)
            let sample = try makeSample(asbd: pcmDescription(), planes: [Data(repeating: 0, count: 16)],
                timingsOverride: [first, second])
            if missing {
                XCTAssertThrowsError(try IOSCapturedPCMBlock.copy(from: sample)) { XCTAssertEqual($0 as? IOSCapturedPCMError, .discontinuity) }
            } else { XCTAssertEqual(try IOSCapturedPCMBlock.copy(from: sample).frameCount, 2) }
        }
    }
}

private func pcmDescription(width: Int = 4, bits: Int? = nil, rate: Double = 48_000,
                            channels: UInt32 = 2, floating: Bool = false, planar: Bool = false) -> AudioStreamBasicDescription {
    let precision = bits ?? width * 8
    var flags = precision == width * 8 ? kAudioFormatFlagIsPacked : kAudioFormatFlagIsAlignedHigh
    if floating { flags |= kAudioFormatFlagIsFloat }
    else if width != 1 { flags |= kAudioFormatFlagIsSignedInteger }
    if planar { flags |= kAudioFormatFlagIsNonInterleaved }
    let frameBytes = UInt32(width) * (planar ? 1 : channels)
    return AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
        mBytesPerPacket: frameBytes, mFramesPerPacket: 1, mBytesPerFrame: frameBytes, mChannelsPerFrame: channels,
        mBitsPerChannel: UInt32(precision), mReserved: 0)
}

private func pcmBytes(_ words: [UInt64], width: Int) -> Data {
    Data(words.flatMap { value in (0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } })
}

private func makeSample(asbd: AudioStreamBasicDescription, planes: [Data],
                        pts: CMTime = CMTime(value: 480_000, timescale: 48_000),
                        layout: UInt32? = kAudioChannelLayoutTag_Stereo, bitmap: UInt32 = 0,
                        ready: Bool = true, framesOverride: Int? = nil,
                        timingsOverride: [CMSampleTimingInfo]? = nil) throws -> CMSampleBuffer {
    var description: CMAudioFormatDescription?
    var asbd = asbd
    let status: OSStatus
    if let tag = layout {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = tag; layout.mChannelBitmap = AudioChannelBitmap(rawValue: bitmap); layout.mNumberChannelDescriptions = 0
        status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
    } else {
        status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
    }
    XCTAssertEqual(status, noErr, "Native fixture format must be accepted before testing the product boundary")
    let format = try XCTUnwrap(description)
    let frames = try framesOverride ?? XCTUnwrap(planes.first).count / Int(asbd.mBytesPerFrame)
    let timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(asbd.mSampleRate)),
                                   presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    if framesOverride != nil || timingsOverride != nil {
        // These fixtures deliberately exercise metadata/storage shapes that the
        // AudioBufferList convenience setter refuses to construct. Build the
        // actual CoreMedia block and sample directly; do not bypass the decoder.
        guard planes.count == 1, asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0, ready else {
            throw IOSCapturedPCMError.bufferShape
        }
        let bytes = try XCTUnwrap(planes.first)
        var block: CMBlockBuffer?
        let created = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        XCTAssertEqual(created, noErr)
        let native = try XCTUnwrap(block)
        let copied = try bytes.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: try XCTUnwrap(raw.baseAddress), blockBuffer: native,
                offsetIntoDestination: 0, dataLength: raw.count)
        }
        XCTAssertEqual(copied, noErr)
        return try CMSampleBuffer(dataBuffer: native, formatDescription: format, numSamples: frames,
            sampleTimings: timingsOverride ?? [timing], sampleSizes: [Int(asbd.mBytesPerFrame)])
    }
    let sample = try CMSampleBuffer(dataBuffer: nil, dataReady: false, formatDescription: format,
        numSamples: frames, sampleTimings: timingsOverride ?? [timing], sampleSizes: [], makeDataReadyHandler: { _ in kCMSampleBufferError_BufferNotReady })
    let list = AudioBufferList.allocate(maximumBuffers: planes.count)
    defer { list.unsafeMutablePointer.deallocate() }
    var storage: [UnsafeMutableRawPointer] = []
    defer { storage.forEach { $0.deallocate() } }
    for (index, data) in planes.enumerated() {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: max(1, data.count), alignment: 16)
        storage.append(memory)
        data.withUnsafeBytes { raw in if let source = raw.baseAddress { memory.copyMemory(from: source, byteCount: raw.count) } }
        list[index] = AudioBuffer(mNumberChannels: planes.count == 1 ? asbd.mChannelsPerFrame : 1,
                                 mDataByteSize: UInt32(data.count), mData: memory)
    }
    if ready {
        try sample.setDataBuffer(fromAudioBufferList: list.unsafePointer)
        try sample.setDataReadiness(.ready)
    }
    return sample
}


/// Lifecycle effects below are explicitly controlled native receipts. PCM data
/// still goes through real CoreMedia objects and the production ingress.
@MainActor
final class IOSAudioCaptureSourceTests: XCTestCase {
    private enum FixtureError: Error, Equatable { case native, close, wait }
    @MainActor private final class AvailabilityState {
        var value = IOSSystemAudioCaptureAvailability.available
    }

    func testRuntimeCaptureUnavailabilityCannotOpenAChannelOrAcquireASource() throws {
        for availability in [IOSSystemAudioCaptureAvailability.requiresNewerSystem, .systemUnavailable] {
            let owner = IOSAudioCaptureSourceOwner(screenCaptureAvailability: { availability })
            let service = IOSDeviceAudioPlaybackService(captureSources: owner)
            let identity = try AudioProtocolIdentity(deviceID: "capture-availability-test", algorithm: .ed25519,
                                                    fingerprint: String(repeating: "ab", count: 32))
            let target = IOSAudioPlaybackTarget(deviceID: identity.deviceID, name: "Computer", identity: identity,
                                                sources: [.systemCapture])
            XCTAssertEqual(service.systemCaptureAvailability, availability)
            XCTAssertThrowsError(try service.startSystemCapture(target: target, openChannel: {
                XCTFail("Unavailable capture opened a channel"); throw FixtureError.native
            })) { XCTAssertEqual($0 as? IOSAudioCaptureError, .unavailable) }
            XCTAssertNil(owner.current); XCTAssertNil(service.captureOperation)
            XCTAssertFalse(service.isPresentationLocked); XCTAssertFalse(service.isRunning)
        }
    }

    func testCaptureAvailabilityIsRecheckedAfterPresentationBeforeOpeningAChannel() throws {
        let availability = AvailabilityState()
        let owner = IOSAudioCaptureSourceOwner(screenCaptureAvailability: { availability.value })
        let service = IOSDeviceAudioPlaybackService(captureSources: owner)
        XCTAssertEqual(service.systemCaptureAvailability, .available)
        availability.value = .systemUnavailable
        let identity = try AudioProtocolIdentity(deviceID: "capture-availability-test", algorithm: .ed25519,
                                                fingerprint: String(repeating: "ab", count: 32))
        let target = IOSAudioPlaybackTarget(deviceID: identity.deviceID, name: "Computer", identity: identity,
                                            sources: [.systemCapture])
        XCTAssertThrowsError(try service.startSystemCapture(target: target, openChannel: {
            XCTFail("Stale availability opened a channel"); throw FixtureError.native
        })) { XCTAssertEqual($0 as? IOSAudioCaptureError, .unavailable) }
        XCTAssertEqual(service.systemCaptureAvailability, .systemUnavailable)
        XCTAssertNil(owner.current); XCTAssertFalse(service.isPresentationLocked)
    }

    func testUnavailableCaptureDoesNotReplaceAnOwnedSource() async throws {
        let owner = IOSAudioCaptureSourceOwner(screenCaptureAvailability: { .systemUnavailable })
        let backend = try CaptureBackendFixture()
        let source = try owner.make(backend: backend)
        XCTAssertThrowsError(try owner.makeScreenCapture(profile: .init(sampleRate: 48_000, channels: 2))) {
            XCTAssertEqual($0 as? IOSAudioCaptureError, .busy)
        }
        XCTAssertTrue(owner.current === source)
        try await source.stop(); XCTAssertEqual(source.phase, .closed)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < end else { XCTFail("Expected native boundary was not reached"); throw FixtureError.wait }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func sample(_ frame: Int64, words: [UInt64] = [0x80000000, 1]) throws -> CMSampleBuffer {
        try makeSample(asbd: pcmDescription(floating: true), planes: [pcmBytes(words, width: 4)],
                       pts: CMTime(value: frame, timescale: 48_000))
    }

    func testIngressPreservesOrderedSamplesAndDrainsOnlyAfterSeal() async throws {
        let backend = try CaptureBackendFixture()
        for frame in 0..<3 { backend.ingress.receive(try sample(Int64(frame)), from: ObjectIdentifier(backend)) }
        XCTAssertEqual(backend.ingress.snapshot.bufferedBytes, 24)
        backend.ingress.seal()
        for frame in 0..<3 {
            let block = try await backend.ingress.next()
            XCTAssertEqual(block?.frameOffset, UInt64(frame))
            XCTAssertEqual(block?.block.bytes, pcmBytes([0x80000000, 1], width: 4))
        }
        let end = try await backend.ingress.next(); XCTAssertNil(end)
        XCTAssertEqual(backend.ingress.snapshot.bufferedBytes, 0)
    }

    func testWrongNativeOwnerIsIgnoredBeforeParsingAnInvalidBuffer() async throws {
        let backend = try CaptureBackendFixture(), other = NSObject()
        let invalid = try sample(0); try invalid.invalidate()
        backend.ingress.receive(invalid, from: ObjectIdentifier(other))
        XCTAssertFalse(backend.ingress.snapshot.failed); XCTAssertEqual(backend.ingress.snapshot.frames, 0)
        backend.ingress.receive(try sample(0), from: ObjectIdentifier(backend))
        let block = try await backend.ingress.next(); XCTAssertEqual(block?.frameOffset, 0)
        backend.ingress.seal()
        backend.ingress.receive(invalid, from: ObjectIdentifier(backend))
        let end = try await backend.ingress.next(); XCTAssertNil(end)
    }

    func testByteAndBlockOverflowFailAndInvalidateEveryQueuedBlock() async throws {
        for limits in [IOSAudioCaptureIngress.Limits(bytes: 16, blocks: 64), .init(bytes: 1024, blocks: 2)] {
            let backend = try CaptureBackendFixture(limits: limits)
            let failures = OSAllocatedUnfairLock(initialState: 0)
            try backend.ingress.installFailureHandler { _ in failures.withLock { $0 += 1 } }
            for frame in 0..<4 { backend.ingress.receive(try sample(Int64(frame)), from: ObjectIdentifier(backend)) }
            XCTAssertEqual(backend.ingress.snapshot.bufferedBytes, 0)
            XCTAssertEqual(backend.ingress.snapshot.bufferedBlocks, 0)
            do { _ = try await backend.ingress.next(); XCTFail("Overflow returned queued data") }
            catch { XCTAssertEqual(error as? IOSAudioCaptureError, .overflow) }
            XCTAssertEqual(failures.withLock { $0 }, 1)
        }
    }

    func testConsumerCancellationWakesAndTerminatesTheSource() async throws {
        let backend = try CaptureBackendFixture()
        let waiting = Task { try await backend.ingress.next() }
        try await waitFor { backend.ingress.snapshot.waiting }
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Cancelled read succeeded") }
        catch { XCTAssertEqual(error as? IOSAudioCaptureError, .cancelled) }
        backend.ingress.receive(try sample(0), from: ObjectIdentifier(backend))
        XCTAssertEqual(backend.ingress.snapshot.frames, 0)
    }

    func testFailureAfterDeliveryBeforeConsumerResumeCannotLeakABlock() async throws {
        let backend = try CaptureBackendFixture()
        let waiting = Task { try await backend.ingress.next() }
        try await waitFor { backend.ingress.snapshot.waiting }
        backend.ingress.receive(try sample(0), from: ObjectIdentifier(backend))
        backend.ingress.abort(FixtureError.native)
        do { _ = try await waiting.value; XCTFail("A retired block escaped after failure") }
        catch { XCTAssertTrue(error is FixtureError) }
    }

    func testSecondPendingConsumerCannotStealOrCancelTheFirst() async throws {
        let backend = try CaptureBackendFixture()
        let first = Task { try await backend.ingress.next() }
        try await waitFor { backend.ingress.snapshot.waiting }
        do { _ = try await backend.ingress.next(); XCTFail("Two consumers were admitted") }
        catch { XCTAssertEqual(error as? IOSAudioCaptureError, .duplicateConsumer) }
        backend.ingress.receive(try sample(0), from: ObjectIdentifier(backend))
        let block = try await first.value; XCTAssertEqual(block?.frameOffset, 0)
        XCTAssertFalse(backend.ingress.snapshot.failed)
    }

    func testPCMFailureRemainsTerminalWhenValidSamplesArriveLater() async throws {
        let backend = try CaptureBackendFixture()
        backend.ingress.receive(try sample(0, words: [0x7f800000, 0]), from: ObjectIdentifier(backend))
        backend.ingress.receive(try sample(0), from: ObjectIdentifier(backend))
        do { _ = try await backend.ingress.next(); XCTFail("Non-finite PCM became success") }
        catch { XCTAssertEqual(error as? IOSCapturedPCMError, .nonFiniteSample) }
    }

    func testSelectionNeverStartsCaptureAndNormalStopPreservesQueuedData() async throws {
        let backend = try CaptureBackendFixture(), owner = IOSAudioCaptureSourceOwner()
        let source = try owner.make(backend: backend)
        try await source.prepare()
        XCTAssertEqual(source.phase, .prepared); XCTAssertEqual(backend.startCalls, 0)
        try await source.start()
        backend.ingress.receive(try sample(0), from: ObjectIdentifier(backend))
        try await source.stop()
        XCTAssertEqual(source.phase, .closed); XCTAssertFalse(source.cleanupPending)
        XCTAssertEqual(backend.startCalls, 1); XCTAssertEqual(backend.stopCalls, 1); XCTAssertEqual(backend.closeCalls, 1)
        let block = try await source.ingress.next(); XCTAssertEqual(block?.frameOffset, 0)
        let end = try await source.ingress.next(); XCTAssertNil(end)
    }

    func testCancelledSelectionRetainsOwnerUntilActualPickerResult() async throws {
        let backend = try CaptureBackendFixture(); backend.automaticPrepare = false
        let owner = IOSAudioCaptureSourceOwner(), source = try owner.make(backend: backend)
        let selecting = Task { try await source.prepare() }
        try await waitFor { backend.prepareCalls == 1 }
        source.cancel()
        do { try await selecting.value; XCTFail("Cancelled picker succeeded") }
        catch { XCTAssertEqual(error as? IOSAudioCaptureError, .cancelled) }
        XCTAssertTrue(source.cleanupPending); XCTAssertEqual(backend.closeCalls, 0)
        XCTAssertThrowsError(try owner.make(backend: CaptureBackendFixture()))
        backend.prepareCompletions[0](.success(()))
        XCTAssertEqual(source.phase, .closed); XCTAssertEqual(backend.startCalls, 0); XCTAssertEqual(backend.closeCalls, 1)
        backend.prepareCompletions[0](.success(()))
        XCTAssertEqual(backend.closeCalls, 1)
        _ = try owner.make(backend: CaptureBackendFixture())
    }

    func testSelectionTimeoutDoesNotDismissOrReplacePendingNativePicker() async throws {
        let backend = try CaptureBackendFixture(); backend.automaticPrepare = false
        var options = IOSAudioCaptureSource.Options(); options.selectionTimeout = .milliseconds(10)
        let source = try IOSAudioCaptureSource(backend: backend, options: options)
        do { try await source.prepare(); XCTFail("Unanswered picker succeeded") }
        catch { XCTAssertEqual(error as? IOSAudioCaptureError, .timedOut) }
        XCTAssertEqual(source.phase, .cleanupRequired); XCTAssertEqual(backend.closeCalls, 0)
        do { try await source.retryCleanup(); XCTFail("Pending selection was replayed") }
        catch { XCTAssertEqual(error as? IOSAudioCaptureError, .cleanupPending) }
        XCTAssertEqual(backend.prepareCalls, 1)
        backend.prepareCompletions[0](.failure(IOSAudioCaptureError.cancelled))
        XCTAssertEqual(source.phase, .closed)
        XCTAssertEqual(source.failure as? IOSAudioCaptureError, .timedOut)
    }

    func testCancelledStartWaitsForLateNativeStartThenStopsExactlyThatSource() async throws {
        let backend = try CaptureBackendFixture(); backend.automaticStart = false; backend.automaticStop = false
        let source = try IOSAudioCaptureSource(backend: backend)
        try await source.prepare()
        let starting = Task { try await source.start() }
        try await waitFor { backend.startCalls == 1 }
        source.cancel()
        do { try await starting.value; XCTFail("Cancelled start succeeded") }
        catch { XCTAssertEqual(error as? IOSAudioCaptureError, .cancelled) }
        XCTAssertEqual(backend.stopCalls, 0); XCTAssertEqual(backend.closeCalls, 0)
        backend.startCompletions[0](.success(()))
        XCTAssertEqual(backend.stopCalls, 1); XCTAssertEqual(backend.closeCalls, 0)
        backend.stopCompletions[0](.success(()))
        XCTAssertEqual(source.phase, .closed); XCTAssertEqual(backend.closeCalls, 1)
        backend.startCompletions[0](.failure(FixtureError.native))
        XCTAssertEqual(backend.stopCalls, 1); XCTAssertEqual(backend.closeCalls, 1)
    }

    func testNativeStopFailureRequiresExplicitRetryWithoutErasingFailure() async throws {
        let backend = try CaptureBackendFixture(); backend.stopError = FixtureError.native
        let source = try IOSAudioCaptureSource(backend: backend)
        try await source.prepare(); try await source.start()
        do { try await source.stop(); XCTFail("Failed native stop reported success") }
        catch { XCTAssertTrue(error is FixtureError) }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(source.phase, .cleanupRequired); XCTAssertEqual(backend.stopCalls, 1); XCTAssertEqual(backend.closeCalls, 0)
        backend.stopError = nil
        try await source.retryCleanup()
        XCTAssertEqual(source.phase, .closed); XCTAssertEqual(backend.stopCalls, 2)
        XCTAssertTrue(source.failure is FixtureError)
    }

    func testNativeStopTimeoutRetainsInFlightOperationAndAcceptsItsLateReceipt() async throws {
        let backend = try CaptureBackendFixture(); backend.automaticStop = false
        var options = IOSAudioCaptureSource.Options(); options.stopTimeout = .milliseconds(10)
        let source = try IOSAudioCaptureSource(backend: backend, options: options)
        try await source.prepare(); try await source.start()
        do { try await source.stop(); XCTFail("Pending stop succeeded") }
        catch { XCTAssertEqual(error as? IOSAudioCaptureError, .timedOut) }
        XCTAssertEqual(source.phase, .cleanupRequired); XCTAssertEqual(backend.closeCalls, 0)
        do { try await source.retryCleanup(); XCTFail("A second native stop was submitted") }
        catch { XCTAssertEqual(error as? IOSAudioCaptureError, .cleanupPending) }
        XCTAssertEqual(backend.stopCalls, 1)
        backend.stopCompletions[0](.success(()))
        XCTAssertEqual(source.phase, .closed); XCTAssertFalse(source.cleanupPending)
    }

    func testSystemStopDuringPendingStartCannotReleaseTheLateStart() async throws {
        let backend = try CaptureBackendFixture(); backend.automaticStart = false; backend.automaticStop = false
        let source = try IOSAudioCaptureSource(backend: backend)
        try await source.prepare()
        let starting = Task { try await source.start() }
        try await waitFor { backend.startCalls == 1 }
        backend.didStop?(FixtureError.native)
        do { try await starting.value; XCTFail("System failure became successful start") } catch { XCTAssertTrue(error is FixtureError) }
        XCTAssertEqual(backend.closeCalls, 0); XCTAssertEqual(backend.stopCalls, 0)
        backend.startCompletions[0](.success(()))
        XCTAssertEqual(backend.stopCalls, 1)
        backend.stopCompletions[0](.success(()))
        XCTAssertEqual(source.phase, .closed)
    }

    func testOutputRemovalFailureRetainsOwnerAndRetriesOnlyRemoval() async throws {
        let backend = try CaptureBackendFixture(); backend.closeError = FixtureError.close
        let source = try IOSAudioCaptureSource(backend: backend)
        try await source.prepare(); try await source.start()
        do { try await source.stop(); XCTFail("Output removal failed silently") } catch { XCTAssertTrue(error is FixtureError) }
        XCTAssertEqual(source.phase, .cleanupRequired); XCTAssertEqual(backend.stopCalls, 1)
        backend.closeError = nil
        try await source.retryCleanup()
        XCTAssertEqual(source.phase, .closed); XCTAssertEqual(backend.stopCalls, 1); XCTAssertEqual(backend.closeCalls, 2)
    }

    func testIngressOverflowStopsTheOwnedNativeSource() async throws {
        let backend = try CaptureBackendFixture(limits: .init(bytes: 8, blocks: 1))
        let source = try IOSAudioCaptureSource(backend: backend)
        try await source.prepare(); try await source.start()
        backend.ingress.receive(try sample(0), from: ObjectIdentifier(backend))
        backend.ingress.receive(try sample(1), from: ObjectIdentifier(backend))
        try await waitFor { source.phase == .closed }
        XCTAssertEqual(source.failure as? IOSAudioCaptureError, .overflow)
        XCTAssertEqual(backend.stopCalls, 1); XCTAssertEqual(backend.closeCalls, 1)
    }

    func testCancellationBeforePrepareCreatesNoPickerOrRecording() async throws {
        let backend = try CaptureBackendFixture(), source = try IOSAudioCaptureSource(backend: backend)
        source.cancel()
        do { try await source.prepare(); XCTFail("Cancelled source acquired permission") }
        catch { XCTAssertEqual(error as? IOSAudioCaptureError, .alreadyStarted) }
        XCTAssertEqual(backend.prepareCalls, 0); XCTAssertEqual(backend.startCalls, 0)
        XCTAssertEqual(backend.stopCalls, 0); XCTAssertEqual(backend.closeCalls, 1)
    }

    func testSecondSourceCannotReplaceTheFirstBackendsStopHandler() async throws {
        let backend = try CaptureBackendFixture(), source = try IOSAudioCaptureSource(backend: backend)
        try await source.prepare(); try await source.start()
        XCTAssertThrowsError(try IOSAudioCaptureSource(backend: backend)) {
            XCTAssertEqual($0 as? IOSAudioCaptureError, .alreadyBound)
        }
        backend.didStop?(FixtureError.native)
        XCTAssertEqual(source.phase, .closed)
        XCTAssertTrue(source.failure is FixtureError)
    }

    func testLateNativeStopCannotPoisonAnAlreadyClosedSourcesTail() async throws {
        let backend = try CaptureBackendFixture(), source = try IOSAudioCaptureSource(backend: backend)
        try await source.prepare(); try await source.start()
        backend.ingress.receive(try sample(0), from: ObjectIdentifier(backend))
        try await source.stop()
        XCTAssertFalse(backend.ingress.reportNativeStop(FixtureError.native, from: ObjectIdentifier(backend)))
        let tail = try await source.ingress.next(); XCTAssertEqual(tail?.frameOffset, 0)
        let end = try await source.ingress.next(); XCTAssertNil(end)
        XCTAssertNil(source.failure)
    }

    func testProductOwnerRejectsFileReplacementWhileNativeSelectionRemainsPending() async throws {
        let backend = try CaptureBackendFixture(); backend.automaticPrepare = false
        let owner = IOSAudioCaptureSourceOwner(), source = try owner.make(backend: backend)
        let service = IOSDeviceAudioPlaybackService(captureSources: owner)
        let selecting = Task { try await source.prepare() }
        try await waitFor { backend.prepareCalls == 1 }
        source.cancel()
        do { try await selecting.value; XCTFail("Cancelled picker succeeded") } catch { XCTAssertEqual(error as? IOSAudioCaptureError, .cancelled) }
        var opened = false
        let identity = try AudioProtocolIdentity(deviceID: "capture-test-peer-identity", algorithm: .ed25519,
                                               fingerprint: String(repeating: "a", count: 64))
        let target = IOSAudioPlaybackTarget(deviceID: "capture-test-peer-identity", name: "Receiver", identity: identity, sources: [.originalFile])
        XCTAssertThrowsError(try service.start(url: URL(fileURLWithPath: "/unused-capture-test.wav"), target: target) {
            opened = true; throw FixtureError.native
        }) { XCTAssertEqual($0 as? IOSDeviceAudioPlaybackError, .busy) }
        XCTAssertFalse(opened); XCTAssertTrue(service.captureSource === source)
        backend.prepareCompletions[0](.failure(IOSAudioCaptureError.cancelled))
        XCTAssertEqual(source.phase, .closed)
    }

    func testProductOwnerPublishesRawSourceCleanupBeforeAnySenderExists() async throws {
        let backend = try CaptureBackendFixture()
        let owner = IOSAudioCaptureSourceOwner(), source = try owner.make(backend: backend)
        let service = IOSDeviceAudioPlaybackService(captureSources: owner)
        backend.closeError = FixtureError.close
        source.cancel(FixtureError.native)
        XCTAssertEqual(source.phase, .cleanupRequired)
        for _ in 0..<8 { await Task.yield() }
        XCTAssertTrue(service.cleanupPending, "The UI must retain cleanup controls even when channel opening never began")
        XCTAssertNil(service.captureOperation)
        backend.closeError = nil
        try await source.retryCleanup()
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(source.phase, .closed)
        XCTAssertFalse(service.cleanupPending)
    }

    func testChannelOpeningFailureKeepsItsCauseAndExposesCleanupRetry() async throws {
        let backend = try CaptureBackendFixture(), owner = IOSAudioCaptureSourceOwner()
        let source = try owner.make(backend: backend)
        let service = IOSDeviceAudioPlaybackService(captureSources: owner)
        let identity = try AudioProtocolIdentity(deviceID: "capture-open-failure", algorithm: .ed25519,
                                                fingerprint: String(repeating: "ab", count: 32))
        let target = IOSAudioPlaybackTarget(deviceID: identity.deviceID, name: "Computer", identity: identity,
                                            sources: [.systemCapture])
        backend.closeError = FixtureError.close
        XCTAssertThrowsError(try service.startCapture(source: source, target: target,
            openChannel: { throw FixtureError.native })) { XCTAssertEqual($0 as? FixtureError, .native) }
        XCTAssertEqual(source.failure as? FixtureError, .native)
        XCTAssertEqual(service.lastError as? FixtureError, .native)
        XCTAssertTrue(service.cleanupPending); XCTAssertTrue(service.isPresentationLocked)
        XCTAssertNil(service.captureOperation); XCTAssertFalse(service.isRunning)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds; window.overrideUserInterfaceStyle = .light
        let host = AudioCaptureSnapshotHost(rootView: AnyView(DeviceAudioPlaybackView(target: target, service: service,
            openChannel: { XCTFail("Cleanup presentation opened a channel"); throw FixtureError.native }, captureAvailability: .available)))
        addTeardownBlock { @MainActor in try await host.close(window: window, restoring: previous) }
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await host.waitForAppearance(visible: true)
        try await attachAudioPlaybackSnapshot(window: window, name: "system-audio-cleanup-required", to: self)
        backend.closeError = nil
        try await service.retryCleanup()
        XCTAssertEqual(source.phase, .closed); XCTAssertFalse(service.cleanupPending)
        XCTAssertFalse(service.isPresentationLocked)
    }

    #if !canImport(ScreenCaptureKit)
    func testUnavailableSystemCaptureCannotOpenAChannelOrAcquireASource() throws {
        if #available(iOS 27.0, *) {
            XCTAssertEqual(IOSAudioCaptureSourceOwner.systemScreenCaptureAvailability, .systemUnavailable)
        } else {
            XCTAssertEqual(IOSAudioCaptureSourceOwner.systemScreenCaptureAvailability, .requiresNewerSystem)
        }
        let service = IOSDeviceAudioPlaybackService()
        let identity = try AudioProtocolIdentity(deviceID: "capture-platform-test", algorithm: .ed25519,
                                                fingerprint: String(repeating: "ab", count: 32))
        let target = IOSAudioPlaybackTarget(deviceID: identity.deviceID, name: "Computer", identity: identity,
                                            sources: [.systemCapture])
        XCTAssertThrowsError(try service.startSystemCapture(target: target, openChannel: {
            XCTFail("Unsupported platform opened a channel"); throw FixtureError.native
        })) { XCTAssertEqual($0 as? IOSAudioCaptureError, .unavailable) }
        XCTAssertNil(service.captureSource); XCTAssertFalse(service.isPresentationLocked)
    }
    #endif

    func testAlreadyCancelledSecondConsumerCannotAbortTheExistingRead() async throws {
        let backend = try CaptureBackendFixture()
        let first = Task { try await backend.ingress.next() }
        try await waitFor { backend.ingress.snapshot.waiting }
        let second = Task { try await backend.ingress.next() }
        second.cancel()
        do { _ = try await second.value; XCTFail("Second reader succeeded") }
        catch { XCTAssertEqual(error as? IOSAudioCaptureError, .duplicateConsumer) }
        backend.ingress.receive(try sample(0), from: ObjectIdentifier(backend))
        do {
            let block = try await first.value; XCTAssertEqual(block?.frameOffset, 0)
        } catch { XCTFail("Second reader cancelled the first: \(error)") }
        XCTAssertFalse(backend.ingress.snapshot.failed)
    }
}

@MainActor
private final class CaptureBackendFixture: IOSAudioCaptureBackend {
    let ingress: IOSAudioCaptureIngress
    var didStop: (@MainActor (any Error) -> Void)?
    var automaticPrepare = true, automaticStart = true, automaticStop = true
    var prepareCalls = 0, startCalls = 0, stopCalls = 0, closeCalls = 0
    var stopError: (any Error)?, closeError: (any Error)?
    var prepareCompletions: [@MainActor (Result<Void, Error>) -> Void] = []
    var startCompletions: [@MainActor (Result<Void, Error>) -> Void] = []
    var stopCompletions: [@MainActor (Result<Void, Error>) -> Void] = []
    init(limits: IOSAudioCaptureIngress.Limits = .init(),
         admission: IOSAudioCaptureIngress.Admission = .streamFromFirstBuffer) throws {
        ingress = try IOSAudioCaptureIngress(profile: .init(sampleRate: 48_000, channels: 2), admission: admission, limits: limits)
        try ingress.bind(ObjectIdentifier(self))
    }
    func prepare(completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        prepareCalls += 1; prepareCompletions.append(completion)
        if automaticPrepare { completion(.success(())) }
    }
    func start(completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        startCalls += 1; startCompletions.append(completion)
        if automaticStart { completion(.success(())) }
    }
    func stop(completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        stopCalls += 1; stopCompletions.append(completion)
        if automaticStop {
            if let stopError { completion(.failure(stopError)) } else { completion(.success(())) }
        }
    }
    func close() throws { closeCalls += 1; if let closeError { throw closeError } }
}


@MainActor
final class IOSCapturePreparationTests: XCTestCase {
    func testPreparationRetainsMetadataWithoutQueueingAudioAndCannotBeRead() async throws {
        let b = try CaptureBackendFixture(limits: .init(bytes: 8, blocks: 1), admission: .awaitingReceiver)
        for frame in 0..<200 {
            let sample = try makeSample(asbd: pcmDescription(floating: true), planes: [pcmBytes([0, 1], width: 4)],
                                       pts: CMTime(value: Int64(frame), timescale: 48_000))
            b.ingress.receive(sample, from: ObjectIdentifier(b))
        }
        XCTAssertEqual(b.ingress.snapshot.preparationFrames, 200)
        XCTAssertEqual(b.ingress.snapshot.frames, 0); XCTAssertEqual(b.ingress.snapshot.bufferedBytes, 0)
        XCTAssertEqual(b.ingress.snapshot.bufferedBlocks, 0); XCTAssertFalse(b.ingress.snapshot.failed)
        XCTAssertEqual(b.ingress.snapshot.format?.encoding, .float32)
        do { _ = try await b.ingress.next(); XCTFail("Preparation PCM escaped") }
        catch { XCTAssertEqual(error as? IOSAudioCaptureError, .notAdmitted) }
        XCTAssertFalse(b.ingress.snapshot.failed)
    }

    func testAdmissionBeginsAtTheFirstLaterSampleWithoutReusingPreparationClockOrBytes() async throws {
        let b = try CaptureBackendFixture(admission: .awaitingReceiver)
        let first = try makeSample(asbd: pcmDescription(floating: true), planes: [pcmBytes([0x3f000000, 0], width: 4)])
        b.ingress.receive(first, from: ObjectIdentifier(b))
        let format = try XCTUnwrap(b.ingress.snapshot.format)
        try b.ingress.beginTransmission(expectedFormat: format)
        let bytes = pcmBytes([0x80000000, 1], width: 4)
        let formal = try makeSample(asbd: pcmDescription(floating: true), planes: [bytes], pts: CMTime(value: 10, timescale: 1))
        b.ingress.receive(formal, from: ObjectIdentifier(b))
        let block = try await b.ingress.next()
        XCTAssertEqual(block?.frameOffset, 0); XCTAssertEqual(block?.block.bytes, bytes)
        XCTAssertEqual(b.ingress.snapshot.preparationFrames, 1); XCTAssertEqual(b.ingress.snapshot.frames, 1)
        XCTAssertThrowsError(try b.ingress.beginTransmission(expectedFormat: format))
    }

    func testAdmissionRequiresObservedExactFormatAndNeverConvertsAnObservedChange() throws {
        let b = try CaptureBackendFixture(admission: .awaitingReceiver)
        let expected = try AudioStreamingPCMFormat(sampleRate: 48_000, channels: 2, encoding: .float32,
                                                   declaredValidBits: 32, waveChannelMask: 3)
        XCTAssertThrowsError(try b.ingress.beginTransmission(expectedFormat: expected)) {
            XCTAssertEqual($0 as? IOSAudioCaptureError, .formatUnavailable)
        }
        b.ingress.receive(try makeSample(asbd: pcmDescription(width: 3, bits: 24), planes: [Data(repeating: 0, count: 6)]),
                          from: ObjectIdentifier(b))
        XCTAssertThrowsError(try b.ingress.beginTransmission(expectedFormat: expected)) {
            XCTAssertEqual($0 as? IOSAudioCaptureError, .formatMismatch)
        }
        XCTAssertFalse(b.ingress.snapshot.isTransmitting)
        b.ingress.receive(try makeSample(asbd: pcmDescription(floating: true), planes: [Data(repeating: 0, count: 8)]),
                          from: ObjectIdentifier(b))
        XCTAssertThrowsError(try b.ingress.requireHealthy()) {
            XCTAssertEqual($0 as? IOSAudioCaptureError, .formatMismatch)
        }
    }

    func testFormatChangeAfterAdmissionCannotCreateAReplacementStream() async throws {
        let b = try CaptureBackendFixture(admission: .awaitingReceiver)
        b.ingress.receive(try makeSample(asbd: pcmDescription(floating: true), planes: [Data(repeating: 0, count: 8)]),
                          from: ObjectIdentifier(b))
        try b.ingress.beginTransmission(expectedFormat: XCTUnwrap(b.ingress.snapshot.format))
        b.ingress.receive(try makeSample(asbd: pcmDescription(), planes: [Data(repeating: 0, count: 8)]), from: ObjectIdentifier(b))
        do { _ = try await b.ingress.next(); XCTFail("Changed encoding was forwarded") }
        catch { XCTAssertEqual(error as? IOSAudioCaptureError, .formatMismatch) }
        XCTAssertEqual(b.ingress.snapshot.bufferedBytes, 0)
    }
}

@MainActor
final class IOSCaptureSendSessionTests: XCTestCase {
    func testTerminalRenewalFailureStopsCaptureWithoutTransmittingNewSamples() async throws {
        let f = try CaptureSenderFixture()
        let membership = try IOSPlaybackMembershipFixture(channel: f.channel, authorization: f.authorization)
        membership.renewalFailure = URLError(.secureConnectionFailed); f.membership = membership
        do {
            let sender = f.start(); try await f.offer()
            try f.reply(.accept(receiveWindowBytes: 8))
            try f.reply(.outputReady(XCTUnwrap(sender.format)))
            try await f.expectFailure(.accountRevoked)
            XCTAssertEqual((sender.lastAuthorizationRenewalFailure as? URLError)?.code, .secureConnectionFailed)
            XCTAssertTrue(f.dataMessages.isEmpty)
            XCTAssertEqual(membership.renewalCalls, 1)
            XCTAssertEqual(f.source.phase, .closed)
            try await f.close()
        } catch {
            let primary = error
            do { try await f.close() } catch { XCTFail("Capture cleanup failed: \(error)") }
            throw primary
        }
    }

    func testRenewalWaitsForAcceptanceAndExactOutputThenPreservesCapturedSamples() async throws {
        let f = try CaptureSenderFixture()
        let membership = try IOSPlaybackMembershipFixture(channel: f.channel, authorization: f.authorization)
        f.membership = membership
        do {
            let sender = f.start()
            try await f.offer()
            XCTAssertEqual(membership.renewalCalls, 0)
            try f.reply(.accept(receiveWindowBytes: 8))
            XCTAssertEqual(membership.renewalCalls, 0)
            let format = try XCTUnwrap(sender.format)
            try f.reply(.outputReady(format))
            try await f.until { membership.renewalCalls == 1 && sender.authorizationRenewalState == .waiting }
            f.automaticCreditAndReceipts()
            try f.feed(frame: 100, words: [1, 2])
            try await f.until { f.dataMessages.count == 1 }
            sender.finishCapture()
            let result = try await f.result()
            XCTAssertEqual(result.format, format)
            XCTAssertEqual(result.sha256, Data(SHA256.hash(data: pcmBytes([1, 2], width: 4))))
            XCTAssertEqual(membership.renewalCalls, 1)
            try await f.close()
        } catch {
            let primary = error
            do { try await f.close() } catch { XCTFail("Capture cleanup failed: \(error)") }
            throw primary
        }
    }

    func testStopClosesCaptureAndChannelBeforeRenewalRequestReturns() async throws {
        let f = try CaptureSenderFixture()
        let membership = try IOSPlaybackMembershipFixture(channel: f.channel, authorization: f.authorization)
        let gate = IOSPlaybackRenewalGate(); membership.renewalGate = gate; f.membership = membership
        defer { gate.finish() }
        do {
            let sender = f.start()
            try await f.offer(); try await f.approve(window: 8)
            try await f.until { gate.arrived }
            sender.cancel()
            try await f.until { gate.cancelled && f.source.phase == .closed && !f.channel.isCurrentForMembership() }
            XCTAssertFalse(f.finished); XCTAssertTrue(f.dataMessages.isEmpty)
            gate.finish()
            try await f.expectFailure(.userStopped)
            try await f.close()
        } catch {
            let primary = error; gate.finish()
            do { try await f.close() } catch { XCTFail("Capture cleanup failed: \(error)") }
            throw primary
        }
    }

    func testFileAuthorizationAlreadyOwnsTheChannelBeforeItsFirstOffer() async throws {
        let f = try CaptureSenderFixture(capabilities: [AudioStreamingWire.captureReceiveCapability, AudioStreamingWire.fileReceiveCapability], filePort: 2345)
        let untouched = OSAllocatedUnfairLock(initialState: 0)
        let file = try IOSPreparedAudioFile(url: URL(fileURLWithPath: "/unused-file-before-offer.wav"),
            startScope: { _ in untouched.withLock { $0 += 1 }; return false })
        let gate = CaptureAuthorizationGate()
        let first = IOSOriginalFileSendSession(renewMembership: nil, source: file, channel: f.channel, authorize: { channel in
            await gate.wait()
            return try makeControlledAudioMembershipLease(channel: channel)
        })
        let running = Task { try await first.run() }
        defer { first.stop(); gate.finish() }
        try await f.until { gate.arrived }
        XCTAssertTrue(f.transport.messages.isEmpty)
        let capture = IOSCaptureSendSession(renewMembership: nil, source: f.source, channel: f.channel,
            authorize: { try makeControlledAudioMembershipLease(channel: $0) })
        do { _ = try await capture.run(); XCTFail("Capture stole the authorizing file channel") }
        catch let failure as IOSCaptureSendFailure { XCTAssertEqual(failure.underlying as? AudioStreamingChannelError, .alreadyRegistered) }
        XCTAssertEqual(first.phase, .authorizing); try f.channel.requireCurrent()
        XCTAssertEqual(untouched.withLock { $0 }, 0)
        first.stop(); gate.finish()
        do { _ = try await running.value; XCTFail("Stopped file succeeded") }
        catch let failure as IOSOriginalFileSendFailure { XCTAssertEqual(failure.reason, .userStopped) }
        let closed = await file.isClosed; XCTAssertTrue(closed)
        try await f.close()
    }

    func testCompetingFileLeavesTheCaptureAndUnclaimedFileSourceUntouched() async throws {
        let f = try CaptureSenderFixture(); let sender = f.start(); try await f.offer()
        let accesses = OSAllocatedUnfairLock(initialState: 0)
        let file = try IOSPreparedAudioFile(url: URL(fileURLWithPath: "/unused-file-during-capture.wav"),
            startScope: { _ in accesses.withLock { $0 += 1 }; return false })
        let other = IOSOriginalFileSendSession(renewMembership: nil, source: file, channel: f.channel,
            authorize: { try makeControlledAudioMembershipLease(channel: $0) })
        do { _ = try await other.run(); XCTFail("File stole the capture channel") }
        catch let failure as IOSOriginalFileSendFailure { XCTAssertEqual(failure.underlying as? AudioStreamingChannelError, .alreadyRegistered) }
        XCTAssertEqual(accesses.withLock { $0 }, 0)
        let closed = await file.isClosed; XCTAssertFalse(closed)
        try f.channel.requireCurrent(); XCTAssertEqual(f.source.phase, .running)
        try await f.approve(window: 8); f.automaticCreditAndReceipts()
        try f.feed(frame: 100_000); try await f.until { f.dataMessages.count == 1 }
        sender.finishCapture(); _ = try await f.result()
        try await file.close(); try await f.close()
    }

    func testCompetingSourceCannotCloseTheFirstOperationsAudioChannel() async throws {
        let first = try CaptureSenderFixture(); let firstSender = first.start(); try await first.offer()
        let other = try CaptureSenderFixture()
        let competing = IOSCaptureSendSession(renewMembership: nil, source: other.source, channel: first.channel,
            authorize: { try makeControlledAudioMembershipLease(channel: $0) })
        do { _ = try await competing.run(); XCTFail("Two operations claimed one channel") }
        catch let failure as IOSCaptureSendFailure { XCTAssertEqual(failure.underlying as? AudioStreamingChannelError, .alreadyRegistered) }
        try first.channel.requireCurrent()
        XCTAssertNil(firstSender.failure); XCTAssertEqual(first.source.phase, .running)
        XCTAssertEqual(other.source.phase, .closed); XCTAssertEqual(first.transport.messages.count, 1)
        try await first.approve(window: 8); first.automaticCreditAndReceipts()
        try first.feed(frame: 100_000); try await first.until { first.dataMessages.count == 1 }
        firstSender.finishCapture(); _ = try await first.result()
        try await other.close(); try await first.close()
    }

    func testCompetingChannelCannotCancelAnAlreadyOwnedCaptureSource() async throws {
        let first = try CaptureSenderFixture(); let sender = first.start(); try await first.offer()
        let other = try CaptureSenderFixture()
        let competing = IOSCaptureSendSession(renewMembership: nil, source: first.source, channel: other.channel,
            authorize: { try makeControlledAudioMembershipLease(channel: $0) })
        do { _ = try await competing.run(); XCTFail("A second sender claimed the capture") }
        catch let failure as IOSCaptureSendFailure { XCTAssertEqual(failure.underlying as? IOSAudioCaptureError, .alreadyBound) }
        XCTAssertEqual(first.source.phase, .running); XCTAssertFalse(competing.cleanupPending)
        try first.channel.requireCurrent(); try other.channel.requireCurrent()
        try await first.approve(window: 8); first.automaticCreditAndReceipts()
        try first.feed(frame: 100_000); try await first.until { first.dataMessages.count == 1 }
        sender.finishCapture(); _ = try await first.result()
        try await other.close(); try await first.close()
    }

    func testEndingBeforeAnyFormalSampleNeverReportsPlaybackSuccess() async throws {
        let f = try CaptureSenderFixture(); let sender = f.start()
        try await f.offer(); try await f.approve(window: 8)
        sender.finishCapture(); try await f.expectFailure(.sourceFailed)
        XCTAssertTrue(f.dataMessages.isEmpty); XCTAssertNil(f.end); XCTAssertNil(sender.receipt)
        try await f.close()
    }

    func testDuplicateAcceptanceDoesNotRestartOrReadmitCapture() async throws {
        let f = try CaptureSenderFixture(); _ = f.start()
        try await f.offer(); try await f.approve(window: 8)
        try f.reply(.accept(receiveWindowBytes: 8)); try await f.expectFailure(.protocolViolation)
        XCTAssertTrue(f.dataMessages.isEmpty); XCTAssertEqual(f.backend.startCalls, 1)
        try await f.close()
    }

    func testActualPacked24SamplesCrossEncryptedCarrierOnlyAfterBothApprovals() async throws {
        let f = try CaptureSenderFixture(); let sender = f.start()
        try await f.offer(width: 3, bits: 24, floating: false)
        let offered = try XCTUnwrap(sender.format)
        XCTAssertEqual(offered.encoding, .signed24); XCTAssertEqual(offered.declaredValidBits, 24)
        try f.reply(.accept(receiveWindowBytes: 12))
        try f.feed(frame: 1, words: [0, 0], width: 3, bits: 24, floating: false)
        XCTAssertTrue(f.dataMessages.isEmpty); XCTAssertFalse(f.source.ingress.snapshot.isTransmitting)
        try f.reply(.outputReady(offered))
        try await f.until { sender.phase == .streaming }
        f.automaticCreditAndReceipts()
        let words: [UInt64] = [0x800000, 0x7fffff, 1, 0, 0xabcdef, 0x123456, 2, 3]
        let expected = pcmBytes(words, width: 3)
        try f.feed(frame: 100_000, words: words, width: 3, bits: 24, floating: false)
        try await f.until { f.dataMessages.count == 2 }
        sender.finishCapture()
        let result = try await f.result()
        XCTAssertEqual(result.sentBytes, UInt64(expected.count)); XCTAssertEqual(result.sourceFrames, 4)
        XCTAssertEqual(result.sha256, Data(SHA256.hash(data: expected)))
        XCTAssertEqual(result.preparationFrames, 2); XCTAssertEqual(result.format, offered)
        XCTAssertEqual(f.dataMessages.map(\.offset), [0, 12])
        XCTAssertEqual(f.dataMessages.reduce(Data()) { $0 + $1.bytes }, expected)
        XCTAssertEqual(sender.phase, .completed); XCTAssertFalse(sender.cleanupPending)
        XCTAssertEqual(f.backend.stopCalls, 1); XCTAssertEqual(f.source.phase, .closed)
        try await f.close()
    }

    func testLargeNativeBlockSplitsAtWholeFramesAndWireLimitWithoutChangingBits() async throws {
        let f = try CaptureSenderFixture(); let sender = f.start()
        try await f.offer(); try await f.approve(window: AudioStreamingWire.maximumReceiveWindowBytes)
        f.automaticCreditAndReceipts()
        let words: [UInt64] = (0..<4000).map { $0 % 2 == 0 ? 0x80000000 : 1 }
        let expected = pcmBytes(words, width: 4)
        try f.feed(frame: 100_000, words: words)
        try await f.until { f.dataMessages.reduce(0) { $0 + $1.bytes.count } == expected.count }
        XCTAssertEqual(f.dataMessages.count, 2)
        XCTAssertTrue(f.dataMessages.allSatisfy { $0.bytes.count % 8 == 0 && $0.bytes.count <= AudioStreamingWire.maximumPCMDataBytes })
        sender.finishCapture(); let result = try await f.result()
        XCTAssertEqual(result.sourceFrames, 2000); XCTAssertEqual(result.sha256, Data(SHA256.hash(data: expected)))
        XCTAssertEqual(f.dataMessages.reduce(Data()) { $0 + $1.bytes }, expected)
        try await f.close()
    }

    func testCreditMayArriveBeforeNativeWriteCompletionButCannotReleaseAnotherWrite() async throws {
        let f = try CaptureSenderFixture(); let sender = f.start()
        try await f.offer(); try await f.approve(window: 8)
        f.transport.hook = { [weak f] message, completion in
            guard let f else { return true }
            if case .pcmData(let offset, let bytes) = message.body {
                try f.reply(.credit(retiredBytes: offset + UInt64(bytes.count)))
                f.held.append(completion); return false
            }
            return true
        }
        try f.feed(frame: 100_000, words: [0, 1, 2, 3])
        try await f.until { f.held.count == 1 }
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(f.dataMessages.count, 1); XCTAssertEqual(sender.phase, .streaming)
        f.held[0].completeWrite(.success(()))
        try await f.until { f.held.count == 2 }
        f.held[1].completeWrite(.success(()))
        f.automaticCreditAndReceipts(); sender.finishCapture()
        let result = try await f.result(); XCTAssertEqual(result.sentBytes, 16)
        try await f.close()
    }

    func testPeerReceiptsBeforeEndWriteCompletionCannotCompleteTheOperation() async throws {
        let f = try CaptureSenderFixture(); let sender = f.start()
        try await f.offer(); try await f.approve(window: 8)
        f.automaticCreditAndReceipts(holdEnd: true)
        try f.feed(frame: 100_000)
        try await f.until { f.dataMessages.count == 1 }
        sender.finishCapture()
        try await f.until { f.held.count == 1 }
        for _ in 0..<8 { await Task.yield() }
        XCTAssertFalse(f.finished); XCTAssertNil(sender.receipt)
        f.held[0].completeWrite(.success(()))
        let result = try await f.result(); XCTAssertEqual(result.sourceFrames, 1)
        try await f.close()
    }

    func testWrongLeaseBindingFailsBeforeSystemPickerOrAudioOffer() async throws {
        for wrong in 0..<3 {
            let f = try CaptureSenderFixture(); f.wrongBinding = wrong
            _ = f.start(); try await f.expectFailure(.accountRevoked)
            XCTAssertEqual(f.backend.prepareCalls, 0); XCTAssertEqual(f.backend.startCalls, 0)
            XCTAssertTrue(f.transport.messages.isEmpty)
            try await f.close()
        }
    }

    func testUnsupportedAuthenticatedPeerFailsBeforeAccountLookupAndPicker() async throws {
        let f = try CaptureSenderFixture(capabilities: [AudioStreamingWire.fileReceiveCapability])
        _ = f.start(); try await f.expectFailure(.unsupportedOutput)
        XCTAssertEqual(f.authorizationCalls, 0); XCTAssertEqual(f.backend.prepareCalls, 0)
        XCTAssertTrue(f.transport.messages.isEmpty)
        try await f.close()
    }

    func testDeclineDuringPreparationStopsSourceWithoutSendingPCMOrEchoingStop() async throws {
        let f = try CaptureSenderFixture(); _ = f.start(); try await f.offer()
        try f.reply(.stop(.receiverDeclined)); try await f.expectFailure(.receiverDeclined)
        XCTAssertTrue(f.dataMessages.isEmpty); XCTAssertEqual(f.transport.messages.count, 1)
        XCTAssertEqual(f.source.phase, .closed); try await f.close()
    }

    func testInvalidWindowsAndOutputOrderNeverAdmitSamples() async throws {
        for mode in 0..<4 {
            let f = try CaptureSenderFixture(); let sender = f.start(); try await f.offer()
            switch mode {
            case 0: try f.reply(.accept(receiveWindowBytes: 0))
            case 1: try f.reply(.accept(receiveWindowBytes: 7))
            case 2: try f.reply(.outputReady(XCTUnwrap(sender.format)))
            default:
                try f.reply(.accept(receiveWindowBytes: 8))
                try f.reply(.outputReady(AudioStreamingPCMFormat(sampleRate: 48_000, channels: 2,
                    encoding: .signed32, declaredValidBits: 32, waveChannelMask: 3)))
            }
            try await f.expectFailure(.protocolViolation)
            XCTAssertTrue(f.dataMessages.isEmpty); try await f.close()
        }
    }

    func testInvalidCreditAndWrongCompletionCannotBecomePlaybackSuccess() async throws {
        for mode in 0..<4 {
            let f = try CaptureSenderFixture(); let sender = f.start()
            try await f.offer(); try await f.approve(window: 16)
            try f.feed(frame: 100_000)
            try await f.until { f.dataMessages.count == 1 }
            if mode == 0 { try f.reply(.credit(retiredBytes: 16)) }
            else if mode == 1 { try f.reply(.credit(retiredBytes: 7)) }
            else {
                sender.finishCapture(); try await f.until { f.end != nil }
                let end = try XCTUnwrap(f.end)
                if mode == 2 { try f.reply(.contentVerified(totalBytes: end.total, sha256: Data(repeating: 0, count: 32))) }
                else {
                    try f.reply(.contentVerified(totalBytes: end.total, sha256: end.digest))
                    try f.reply(.playbackComplete(sourceFrames: 2, trailingPaddingFrames: 0))
                }
            }
            try await f.expectFailure(mode == 2 ? .contentMismatch : .protocolViolation)
            XCTAssertNil(sender.receipt); try await f.close()
        }
    }

    func testRevocationAtFirstNativeWritePreventsAllLaterPCMAndEnd() async throws {
        let f = try CaptureSenderFixture(); _ = f.start(); try await f.offer(); try await f.approve(window: 8)
        f.transport.hook = { [weak f] message, _ in
            if case .pcmData = message.body { f?.authorization.revoke() }
            return true
        }
        try f.feed(frame: 100_000, words: [0, 1, 2, 3])
        try await f.expectFailure(.accountRevoked)
        XCTAssertEqual(f.dataMessages.count, 1); XCTAssertNil(f.end)
        XCTAssertEqual(f.source.phase, .closed); try await f.close()
    }

    func testChannelReplacementWhileWaitingForCreditCannotBorrowItsSuccessor() async throws {
        let f = try CaptureSenderFixture(); _ = f.start(); try await f.offer(); try await f.approve(window: 8)
        try f.feed(frame: 100_000, words: [0, 1, 2, 3])
        try await f.until { f.dataMessages.count == 1 }
        f.session.invalidate()
        try await f.expectFailure(.sessionReplaced)
        XCTAssertEqual(f.dataMessages.count, 1); XCTAssertNil(f.end)
        try await f.close()
    }

    func testFormatCreditAndCompletionWaitsHaveIndependentDeadlines() async throws {
        for mode in 0..<3 {
            let f = try CaptureSenderFixture()
            var options = IOSCaptureSendSession.Options(); options.pollInterval = .milliseconds(2)
            if mode == 0 { options.formatTimeout = .milliseconds(20) }
            if mode == 1 { options.creditTimeout = .milliseconds(20) }
            if mode == 2 { options.completionTimeout = .milliseconds(20) }
            let sender = f.start(options: options)
            if mode > 0 {
                try await f.offer(); try await f.approve(window: 8)
                try f.feed(frame: 100_000, words: mode == 1 ? [0, 1, 2, 3] : [0, 1])
                try await f.until { f.dataMessages.count == 1 }
                if mode == 2 {
                    sender.finishCapture(); try await f.until { f.end != nil }
                    let end = try XCTUnwrap(f.end)
                    try f.reply(.contentVerified(totalBytes: end.total, sha256: end.digest))
                }
            }
            try await f.expectFailure(.timedOut); XCTAssertNil(sender.receipt)
            try await f.close()
        }
    }

    func testCaptureOverflowAndCleanupFailureDoNotSendASuccessfulEnd() async throws {
        let f = try CaptureSenderFixture(limits: .init(bytes: 8, blocks: 1))
        f.backend.closeError = CaptureSenderFixture.Failure.native
        let sender = f.start(); try await f.offer(); try await f.approve(window: 8)
        // One main-actor turn, before the consumer can resume: bounded pending
        // delivery plus the next queued block, then a third exceeds the queue.
        for n in 0..<4 { try f.feed(frame: 100_000 + Int64(n)) }
        try await f.expectFailure(.queueOverflow)
        XCTAssertTrue(sender.cleanupPending); XCTAssertEqual(f.source.phase, .cleanupRequired)
        XCTAssertNil(f.end); XCTAssertNil(sender.receipt)
        f.backend.closeError = nil; try await sender.retryCleanup()
        XCTAssertFalse(sender.cleanupPending); XCTAssertEqual(f.source.phase, .closed)
        try await f.close()
    }

    func testNativeStopMustFinishBeforeEndEvenIfInputQueueAlreadySealed() async throws {
        let f = try CaptureSenderFixture(); let sender = f.start()
        try await f.offer(); try await f.approve(window: 8); f.automaticCreditAndReceipts()
        try f.feed(frame: 100_000); try await f.until { f.dataMessages.count == 1 }
        f.backend.automaticStop = false
        sender.finishCapture(); try await f.until { f.backend.stopCalls == 1 }
        f.source.ingress.seal()
        for _ in 0..<8 { await Task.yield() }
        XCTAssertNil(f.end); XCTAssertFalse(f.finished)
        f.backend.stopCompletions[0](.success(()))
        _ = try await f.result(); XCTAssertNotNil(f.end)
        try await f.close()
    }

    func testProductOwnerRemainsBusyWhileClosedSourceStillAwaitsPeerCompletion() async throws {
        let f = try CaptureSenderFixture()
        let service = IOSDeviceAudioPlaybackService(captureSources: f.owner, makeCaptureSession: { source, channel in
            IOSCaptureSendSession(renewMembership: nil, source: source, channel: channel, authorize: {
                try makeControlledAudioMembershipLease(channel: $0, authorization: f.authorization)
            })
        })
        let target = IOSAudioPlaybackTarget(deviceID: f.channel.remoteIdentity.deviceID, name: "Receiver", identity: f.channel.remoteIdentity, sources: [.systemCapture])
        try service.startCapture(source: f.source, target: target, openChannel: { f.channel })
        let sender = try XCTUnwrap(service.captureOperation); f.sender = sender
        try await f.offer(); try await f.approve(window: 8)
        try f.feed(frame: 100_000); try await f.until { f.dataMessages.count == 1 }
        service.finishCapture(); try await f.until { f.end != nil }
        XCTAssertEqual(f.source.phase, .closed); XCTAssertTrue(service.isRunning)
        var opened = false
        XCTAssertThrowsError(try service.start(url: URL(fileURLWithPath: "/unused-capture-replacement.wav"), target: target) {
            opened = true; return f.channel
        }) { XCTAssertEqual($0 as? IOSDeviceAudioPlaybackError, .busy) }
        XCTAssertFalse(opened)
        let end = try XCTUnwrap(f.end)
        try f.reply(.contentVerified(totalBytes: end.total, sha256: end.digest))
        try f.reply(.playbackComplete(sourceFrames: 1, trailingPaddingFrames: 0))
        try await f.until { !service.isRunning }
        XCTAssertNil(service.lastError); XCTAssertEqual(sender.phase, .completed)
        await service.stopAndWait(); try await f.close()
    }

    func testBackgroundCaptureKeepsSendingButForegroundPresentationRemovalCancels() async throws {
        let f = try CaptureSenderFixture()
        let service = IOSDeviceAudioPlaybackService(captureSources: f.owner, makeCaptureSession: { source, channel in
            IOSCaptureSendSession(renewMembership: nil, source: source, channel: channel, authorize: {
                try makeControlledAudioMembershipLease(channel: $0, authorization: f.authorization)
            })
        })
        let target = IOSAudioPlaybackTarget(deviceID: f.channel.remoteIdentity.deviceID, name: "Computer",
            identity: f.channel.remoteIdentity, sources: [.systemCapture])
        try service.startCapture(source: f.source, target: target, openChannel: { f.channel })
        f.sender = try XCTUnwrap(service.captureOperation)
        try await f.offer(); try await f.approve(window: 8); f.automaticCreditAndReceipts()
        try f.feed(frame: 100_000); try await f.until { f.dataMessages.count == 1 }
        service.didEnterBackground(); service.presentationDidDisappear(isBackground: true)
        try f.feed(frame: 100_001); try await f.until { f.dataMessages.count == 2 }
        XCTAssertEqual(f.source.phase, .running); XCTAssertTrue(service.isRunning)
        XCTAssertEqual(f.sender?.phase, .streaming); XCTAssertNil(f.end)
        service.presentationDidDisappear(isBackground: false)
        try await f.until { !service.isRunning }
        XCTAssertEqual(f.sender?.failure?.reason, .userStopped)
        XCTAssertEqual(f.source.phase, .closed); XCTAssertNil(f.sender?.receipt)
        XCTAssertFalse(service.isPresentationLocked)
        try await f.close()
    }

    func testCaptureStreamingAndReceiptProduceNativePresentationSnapshots() async throws {
        let f = try CaptureSenderFixture()
        let membership = try IOSPlaybackMembershipFixture(channel: f.channel, authorization: f.authorization)
        let service = IOSDeviceAudioPlaybackService(captureSources: f.owner, makeCaptureSession: { source, channel in
            IOSCaptureSendSession(renewMembership: membership.renew, source: source, channel: channel,
                authorize: membership.authorize)
        })
        let target = IOSAudioPlaybackTarget(deviceID: f.channel.remoteIdentity.deviceID, name: "Studio Computer",
            identity: f.channel.remoteIdentity, sources: [.systemCapture])
        try service.startCapture(source: f.source, target: target, openChannel: { f.channel })
        f.sender = try XCTUnwrap(service.captureOperation)
        try await f.offer(); try await f.approve(window: 8); f.automaticCreditAndReceipts()
        try await f.until { membership.renewalCalls == 1 && f.sender?.authorizationRenewalState == .waiting }
        try f.feed(frame: 100_000); try await f.until { f.dataMessages.count == 1 }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds; window.overrideUserInterfaceStyle = .dark
        let view = DeviceAudioPlaybackView(target: target, service: service,
            openChannel: { XCTFail("Rendering opened another channel"); throw AudioStreamingChannelError.unavailable },
            captureAvailability: .available)
        let host = AudioCaptureSnapshotHost(rootView: AnyView(view))
        addTeardownBlock { @MainActor in try await host.close(window: window, restoring: previous) }
        window.rootViewController = host; window.makeKeyAndVisible()
        try await host.waitForAppearance(visible: true)
        for completed in [false, true] {
            if completed {
                service.finishCapture(); try await f.until { !service.isRunning }
                XCTAssertEqual(f.sender?.phase, .completed); XCTAssertNotNil(f.sender?.receipt)
            }
            try await attachAudioPlaybackSnapshot(window: window,
                name: completed ? "system-audio-completed-dark" : "system-audio-streaming-dark", to: self)
            if completed {
                host.rootView = AnyView(view.frame(width: 390, height: 600))
                try await attachAudioPlaybackSnapshot(window: window, name: "system-audio-completed-bottom-dark",
                    scrollToEnd: true, to: self)
            }
        }
        await service.stopAndWait(); try await f.close()
    }
}

/// Snapshot windows must retain their host through UIKit's actual appearance
/// callbacks. Clearing a visible root synchronously can abandon a transition
/// that completes during the next test, obscuring product lifecycle diagnostics.
@MainActor
private final class AudioCaptureSnapshotHost: UIHostingController<AnyView> {
    private var visible = false
    private var transitioning = false
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); transitioning = true
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); visible = true; transitioning = false
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated); transitioning = true
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated); visible = false; transitioning = false
    }
    func waitForAppearance(visible expected: Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while visible != expected || transitioning {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "AudioCaptureSnapshotAppearance", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "UIKit did not finish the expected appearance transition"])
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func close(window: UIWindow, restoring previous: UIWindow?) async throws {
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        // Removing the root while its window is still visible gives UIKit the
        // matching disappearance transition. Hiding first does not deliver it.
        try await waitForAppearance(visible: true)
        window.rootViewController = nil
        try await waitForAppearance(visible: false)
    }
}

@MainActor
private final class CaptureSenderTransport {
    let key: Data
    var messages: [AudioStreamingMessage] = []
    var hook: (@MainActor (AudioStreamingMessage, AudioStreamingSendCompletion) throws -> Bool)?
    init(key: Data) { self.key = key }
    func send(_ frame: Data, completion: AudioStreamingSendCompletion) {
        do {
            guard frame.count >= 4 else { throw CaptureSenderFixture.Failure.wire }
            let size = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard try P2PControlFramePolicy.inboundBodyByteCount(from: size) == frame.count - 4 else { throw CaptureSenderFixture.Failure.wire }
            let ciphertext = try SkyBridgeCompass_iOS.TrafficPadding.unwrapIfNeeded(Data(frame.dropFirst(4)), label: "capture-test",
                maximumOutputByteCount: P2PControlFramePolicy.maximumBodyByteCount)
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: SymmetricKey(data: key))
            guard let message = try AudioStreamingLANEnvelope.decodeIfPresent(plain) else { throw CaptureSenderFixture.Failure.wire }
            messages.append(message)
            if try hook?(message, completion) ?? true { completion.completeWrite(.success(())) }
        } catch { XCTFail("Actual encrypted carrier frame failed to decode: \(error)"); completion.completeWrite(.failure(error)) }
    }
}

@MainActor
private final class CaptureSenderFixture {
    enum Failure: Error { case timeout, native, wire }
    let backend: CaptureBackendFixture
    let owner: IOSAudioCaptureSourceOwner
    let source: IOSAudioCaptureSource
    let session: IOSAudioSession
    let channel: IOSAudioChannel
    let transport: CaptureSenderTransport
    let authorization = AccountAudioAuthorization()
    var authorizationCalls = 0
    var wrongBinding: Int?
    var sender: IOSCaptureSendSession?
    var membership: IOSPlaybackMembershipFixture?
    var running: Task<IOSCaptureSendReceipt, Error>?
    var held: [AudioStreamingSendCompletion] = []
    var finished = false
    private var watchdog: Task<Void, Never>?
    var dataMessages: [(offset: UInt64, bytes: Data)] {
        transport.messages.compactMap { if case .pcmData(let offset, let bytes) = $0.body { return (offset, bytes) }; return nil }
    }
    var end: (total: UInt64, digest: Data)? {
        for message in transport.messages { if case .end(let total, let digest) = message.body { return (total, digest) } }
        return nil
    }
    init(limits: IOSAudioCaptureIngress.Limits = .init(), capabilities: Set<String> = [AudioStreamingWire.captureReceiveCapability],
         filePort: UInt16? = nil) throws {
        backend = try CaptureBackendFixture(limits: limits, admission: .awaitingReceiver)
        owner = IOSAudioCaptureSourceOwner(); source = try owner.make(backend: backend)
        let local = try ProtocolIdentityBinding(deviceId: "capture-session-ios-local", protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: Data(repeating: 0x19, count: 32))
        let keys = SkyBridgeCompass_iOS.SessionKeys(sendKey: Data(repeating: 0x21, count: 32), receiveKey: Data(repeating: 0x43, count: 32),
            negotiatedSuite: .qperiaptABI2PolicyBound, role: .initiator, transcriptHash: Data(repeating: 0x65, count: 32))
        let generation = UUID(), transport = CaptureSenderTransport(key: keys.sendKey); self.transport = transport
        let peer = IOSAudioPeerSnapshot(generation: generation, sessionID: keys.sessionId,
            identity: try AudioProtocolIdentity(deviceID: "capture-session-desktop-peer", algorithm: .ed25519,
                fingerprint: String(repeating: "ab", count: 32)), capabilities: capabilities,
            filePort: filePort, acceptedMaterialDigest: Data(repeating: 0x34, count: 32))
        let endpoint: NWEndpoint?
        if let filePort { endpoint = .hostPort(host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: filePort))) }
        else { endpoint = nil }
        session = try IOSAudioSession(generation: generation, keys: keys, localIdentity: local, peer: peer,
            fileRoute: endpoint.map(IOSAudioFileRoute.network), requireConnection: {}, sendFrame: { transport.send($0, completion: $1) },
            cancelTransport: { XCTFail("Capture closed the shared MAIN transport") })
        channel = try session.open(requiringFingerprint: peer.identity.fingerprint)
    }
    func start(options: IOSCaptureSendSession.Options = .init()) -> IOSCaptureSendSession {
        let renewal: IOSAudioMembershipRenewal?
        if let membership {
            renewal = { channel, lease in try await membership.renew(channel, lease) }
        } else { renewal = nil }
        let sender = IOSCaptureSendSession(renewMembership: renewal,
            source: source, channel: channel, options: options, authorize: { [weak self] channel in
            guard let self else { throw CancellationError() }
            authorizationCalls += 1
            if let membership { return try await membership.authorize(channel) }
            return try makeControlledAudioMembershipLease(channel: channel, authorization: authorization,
                ownerID: wrongBinding == 0 ? UUID() : channel.ownerID,
                localOverride: wrongBinding == 1 ? AudioProtocolIdentity(deviceID: "different-capture-local", algorithm: .ed25519,
                    fingerprint: String(repeating: "cd", count: 32)) : nil,
                peerOverride: wrongBinding == 2 ? AudioProtocolIdentity(deviceID: "different-capture-remote", algorithm: .ed25519,
                    fingerprint: String(repeating: "ef", count: 32)) : nil)
        })
        self.sender = sender
        running = Task { [self] in defer { finished = true }; return try await sender.run() }
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch is CancellationError { return }
            catch { XCTFail("Capture watchdog failed: \(error)"); return }
            guard let self, !finished else { return }
            XCTFail("Capture session exceeded test deadline"); sender.cancel()
            for completion in held { completion.completeWrite(.failure(Failure.timeout)) }
            backend.automaticStop = true
            backend.stopCompletions.forEach { $0(.success(())) }
        }
        return sender
    }
    func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    func feed(frame: Int64, words: [UInt64] = [0x80000000, 1], width: Int = 4, bits: Int? = nil, floating: Bool = true) throws {
        let sample = try makeSample(asbd: pcmDescription(width: width, bits: bits, floating: floating),
            planes: [pcmBytes(words, width: width)], pts: CMTime(value: frame, timescale: 48_000))
        source.ingress.receive(sample, from: ObjectIdentifier(backend))
    }
    func offer(width: Int = 4, bits: Int? = nil, floating: Bool = true) async throws {
        try await until { self.backend.startCalls == 1 }
        try feed(frame: 0, words: [0, 0], width: width, bits: bits, floating: floating)
        try await until { self.transport.messages.contains { if case .captureOffer = $0.body { return true }; return false } }
    }
    func approve(window: UInt32) async throws {
        let sender = try XCTUnwrap(sender), format = try XCTUnwrap(sender.format)
        try reply(.accept(receiveWindowBytes: window)); try reply(.outputReady(format))
        try await until { sender.phase == .streaming }
    }
    func reply(_ body: AudioStreamingMessage.Body) throws {
        let sender = try XCTUnwrap(sender)
        XCTAssertEqual(try session.receive(.init(streamID: sender.streamID, body: body)), .delivered)
    }
    func automaticCreditAndReceipts(holdEnd: Bool = false) {
        transport.hook = { [weak self] message, completion in
            guard let self else { return true }
            switch message.body {
            case .pcmData(let offset, let bytes): try reply(.credit(retiredBytes: offset + UInt64(bytes.count)))
            case .end(let total, let digest):
                let format = try XCTUnwrap(sender?.format)
                try reply(.contentVerified(totalBytes: total, sha256: digest))
                try reply(.playbackComplete(sourceFrames: total / UInt64(format.bytesPerFrame), trailingPaddingFrames: 0))
                if holdEnd { held.append(completion); return false }
            default: break
            }
            return true
        }
    }
    func result() async throws -> IOSCaptureSendReceipt { try await XCTUnwrap(running).value }
    func expectFailure(_ reason: AudioStreamingStopReason) async throws {
        do { _ = try await result(); XCTFail("Expected capture failure \(reason)") }
        catch let error as IOSCaptureSendFailure { XCTAssertEqual(error.reason, reason) }
        XCTAssertEqual(sender?.phase, .failed); XCTAssertNil(sender?.receipt)
    }
    func close() async throws {
        membership?.renewalGate?.finish()
        watchdog?.cancel(); sender?.cancel()
        held.forEach { $0.completeWrite(.failure(Failure.native)) }
        backend.automaticPrepare = true; backend.automaticStart = true; backend.automaticStop = true
        backend.stopError = nil; backend.closeError = nil
        backend.prepareCompletions.forEach { $0(.failure(IOSAudioCaptureError.cancelled)) }
        backend.startCompletions.forEach { $0(.failure(IOSAudioCaptureError.cancelled)) }
        backend.stopCompletions.forEach { $0(.success(())) }
        if let running { _ = await running.result }
        if source.phase == .cleanupRequired { try await source.retryCleanup() }
        source.cancel(); channel.close(); session.invalidate()
    }
}


@MainActor
private final class CaptureAuthorizationGate {
    private(set) var arrived = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var ended = false
    func wait() async {
        arrived = true
        if ended { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        ended = true
        let waiting = continuation; continuation = nil; waiting?.resume()
    }
}
