#if os(macOS)
import AudioToolbox
import CoreAudio
import Foundation
import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

final class CoreAudioExactPcmPreflightTests: XCTestCase {
    func testMatchingFloat32WithOnlyMixableHALFormatsReportsMixingRequirement() throws {
        let offered = try AudioStreamingPCMFormat(sampleRate: 48_000, channels: 2,
            encoding: .float32, declaredValidBits: 32, waveChannelMask: 3)
        let mixable = description(offered, nonmixable: false)
        let supported = AudioStreamRangedDescription(mFormat: mixable,
            mSampleRateRange: .init(mMinimum: 48_000, mMaximum: 48_000))
        XCTAssertThrowsError(try CoreAudioExactPcmPolicy.selectSupportedFormat(offered,
            current: mixable, requireNonmixable: true, available: { [supported] })) { error in
            XCTAssertEqual(error as? CoreAudioExactPcmError, .mixableVirtualFormat,
                "Matching PCM cannot be mislabeled as an unsupported representation")
        }
    }

    func testFormatSelectionRetainsExactCurrentFormatWithoutCapabilityRead() throws {
        let offered = try format(.float32)
        let current = description(offered)
        let selected = try CoreAudioExactPcmPolicy.selectSupportedFormat(offered, current: current,
            requireNonmixable: true, available: { XCTFail("Unnecessary HAL read"); return [] })
        XCTAssertEqual(selected.mFormatFlags, current.mFormatFlags)
        XCTAssertTrue(CoreAudioExactPcmPolicy.matches(offered, description: selected))
        let physical = try CoreAudioExactPcmPolicy.selectSupportedFormat(offered,
            current: description(offered, nonmixable: false), requireNonmixable: false,
            available: { XCTFail("Unnecessary physical-format read"); return [] })
        XCTAssertEqual(physical.mFormatFlags & kAudioFormatFlagIsNonMixable, 0)
    }

    func testFormatSelectionFindsAdvertisedNonmixableRepresentationWithoutConversion() throws {
        let offered = try format(.float32)
        let mixable = description(offered, nonmixable: false)
        var exact = description(offered)
        exact.mSampleRate = 0 // HAL range, rather than this placeholder, supplies the supported rates.
        let selected = try CoreAudioExactPcmPolicy.selectSupportedFormat(offered, current: mixable,
            requireNonmixable: true, available: {
                [.init(mFormat: mixable, mSampleRateRange: .init(mMinimum: 44_100, mMaximum: 48_000)),
                 .init(mFormat: exact, mSampleRateRange: .init(mMinimum: 44_100, mMaximum: 48_000))]
            })
        XCTAssertTrue(CoreAudioExactPcmPolicy.matches(offered, description: selected))
        XCTAssertNotEqual(selected.mFormatFlags & kAudioFormatFlagIsNonMixable, 0)
    }

    func testMixableRangeMatchIsRecognizedEvenWhenCurrentRepresentationDiffers() throws {
        let offered = try format(.float32)
        let current = description(try format(.signed16))
        let available = AudioStreamRangedDescription(mFormat: description(offered, nonmixable: false),
            mSampleRateRange: .init(mMinimum: 44_100, mMaximum: 48_000))
        XCTAssertThrowsError(try CoreAudioExactPcmPolicy.selectSupportedFormat(offered, current: current,
            requireNonmixable: true, available: { [available] })) { error in
            XCTAssertEqual(error as? CoreAudioExactPcmError, .mixableVirtualFormat)
        }
    }

    func testAbsentRepresentationAndInvalidRangesRemainFormatMismatch() throws {
        let offered = try format(.float32)
        let current = description(try format(.signed16))
        for rateRange in [AudioValueRange(mMinimum: 48_000, mMaximum: 96_000),
                          .init(mMinimum: .nan, mMaximum: 48_000),
                          .init(mMinimum: 48_000, mMaximum: 44_100)] {
            let available = AudioStreamRangedDescription(mFormat: description(offered, nonmixable: false),
                mSampleRateRange: rateRange)
            XCTAssertThrowsError(try CoreAudioExactPcmPolicy.selectSupportedFormat(offered, current: current,
                requireNonmixable: true, available: { [available] })) { error in
                XCTAssertEqual(error as? CoreAudioExactPcmError, .formatMismatch)
            }
        }
        XCTAssertThrowsError(try CoreAudioExactPcmPolicy.selectSupportedFormat(offered, current: current,
            requireNonmixable: true, available: { [] })) { error in
            XCTAssertEqual(error as? CoreAudioExactPcmError, .formatMismatch)
        }
    }

    func testCapabilityReadFailureDoesNotBecomeAFormatOrMixingClaim() throws {
        let offered = try format(.float32)
        let failure = CoreAudioExactPcmError.propertyFailure(kAudioStreamPropertyAvailableVirtualFormats, -1)
        XCTAssertThrowsError(try CoreAudioExactPcmPolicy.selectSupportedFormat(offered,
            current: description(offered, nonmixable: false), requireNonmixable: true,
            available: { throw failure })) { error in
            XCTAssertEqual(error as? CoreAudioExactPcmError, failure)
        }
    }

    private func format(_ encoding: AudioStreamingPCMFormat.Encoding = .signed24,
                        bits: UInt8? = nil, channels: UInt16 = 2, mask: UInt32? = 3) throws -> AudioStreamingPCMFormat {
        try .init(sampleRate: 44_100, channels: channels, encoding: encoding,
                  declaredValidBits: bits ?? encoding.containerBits, waveChannelMask: mask)
    }

    private func description(_ format: AudioStreamingPCMFormat, nonmixable: Bool = true) -> AudioStreamBasicDescription {
        var flags: AudioFormatFlags = nonmixable ? kAudioFormatFlagIsNonMixable : 0
        if format.encoding.isFloatingPoint { flags |= kAudioFormatFlagIsFloat }
        else if format.encoding != .unsigned8 { flags |= kAudioFormatFlagIsSignedInteger }
        flags |= format.declaredValidBits == format.encoding.containerBits ? kAudioFormatFlagIsPacked : kAudioFormatFlagIsAlignedHigh
        return .init(mSampleRate: Double(format.sampleRate), mFormatID: kAudioFormatLinearPCM,
                     mFormatFlags: flags, mBytesPerPacket: format.bytesPerFrame, mFramesPerPacket: 1,
                     mBytesPerFrame: format.bytesPerFrame, mChannelsPerFrame: UInt32(format.channels),
                     mBitsPerChannel: UInt32(format.declaredValidBits), mReserved: 0)
    }

    func testEveryExactEncodingAndDeclaredIntegerWidth() throws {
        for encoding in AudioStreamingPCMFormat.Encoding.allCases {
            let widths: [UInt8] = encoding.isFloatingPoint ? [encoding.containerBits] : [1, encoding.containerBits]
            for width in widths {
                let offered = try format(encoding, bits: width)
                try CoreAudioExactPcmPolicy.validateFormat(offered, virtual: description(offered),
                    physical: description(offered, nonmixable: false), nominalSampleRate: 44_100)
            }
        }
        let in32 = try format(.signed32, bits: 24)
        let asbd = description(in32)
        XCTAssertEqual(asbd.mBitsPerChannel, 24)
        XCTAssertEqual(asbd.mBytesPerFrame, 8)
        XCTAssertNotEqual(asbd.mFormatFlags & kAudioFormatFlagIsAlignedHigh, 0)
        XCTAssertEqual(asbd.mFormatFlags & kAudioFormatFlagIsPacked, 0)
        try CoreAudioExactPcmPolicy.validateFormat(in32, virtual: asbd, physical: asbd, nominalSampleRate: 44_100)
    }

    func testVirtualAndPhysicalFormatsAreIndependentlyRequired() throws {
        let offered = try format()
        let exact = description(offered)
        let mutations: [(inout AudioStreamBasicDescription) -> Void] = [
            { $0.mSampleRate = 48_000 }, { $0.mSampleRate = .nan },
            { $0.mChannelsPerFrame = 1 }, { $0.mBitsPerChannel = 16 },
            { $0.mBytesPerFrame = 8 }, { $0.mBytesPerPacket = 8 },
            { $0.mFramesPerPacket = 0 }, { $0.mFramesPerPacket = 2 },
            { $0.mFormatID = kAudioFormatMPEG4AAC }, { $0.mReserved = 1 },
            { $0.mFormatFlags |= kAudioFormatFlagIsBigEndian },
            { $0.mFormatFlags |= kAudioFormatFlagIsNonInterleaved },
            { $0.mFormatFlags |= kAudioFormatFlagIsFloat },
            { $0.mFormatFlags &= ~kAudioFormatFlagIsSignedInteger },
            { $0.mFormatFlags |= kAudioFormatFlagIsAlignedHigh },
            { $0.mFormatFlags |= 0x8000_0000 }
        ]
        for mutate in mutations {
            var different = exact; mutate(&different)
            XCTAssertThrowsError(try CoreAudioExactPcmPolicy.validateFormat(offered, virtual: different,
                physical: exact, nominalSampleRate: 44_100))
            XCTAssertThrowsError(try CoreAudioExactPcmPolicy.validateFormat(offered, virtual: exact,
                physical: different, nominalSampleRate: 44_100))
        }
        XCTAssertThrowsError(try CoreAudioExactPcmPolicy.validateFormat(offered, virtual: exact,
            physical: exact, nominalSampleRate: 48_000))
    }

    func testNoMixableFormatOrFloatRepresentationFallback() throws {
        let offered = try format()
        XCTAssertThrowsError(try CoreAudioExactPcmPolicy.validateFormat(offered, virtual: description(offered, nonmixable: false),
            physical: description(offered), nominalSampleRate: 44_100)) { error in
                XCTAssertEqual(error as? CoreAudioExactPcmError, .mixableVirtualFormat)
            }
        let floating = try format(.float32)
        XCTAssertThrowsError(try CoreAudioExactPcmPolicy.validateFormat(offered, virtual: description(floating),
            physical: description(offered), nominalSampleRate: 44_100))
    }

    func testA24BitSourceDoesNotSilentlyBecomeA24In32Container() throws {
        let packed = try format(.signed24)
        let in32 = try format(.signed32, bits: 24)
        XCTAssertThrowsError(try CoreAudioExactPcmPolicy.validateFormat(packed, virtual: description(in32),
            physical: description(in32), nominalSampleRate: 44_100))
    }

    func testUnknownLayoutIsNotDirectOutAndNoSpeakerRemappingIsInvented() throws {
        XCTAssertThrowsError(try CoreAudioExactPcmPolicy.validateLayout(format(mask: nil), channelLabels: [1, 2]))
        try CoreAudioExactPcmPolicy.validateLayout(format(mask: 0), channelLabels: nil)
        try CoreAudioExactPcmPolicy.validateLayout(format(mask: 3), channelLabels: [kAudioChannelLabel_Left, kAudioChannelLabel_Right])
        try CoreAudioExactPcmPolicy.validateLayout(format(channels: 1, mask: 4), channelLabels: [kAudioChannelLabel_Center])
        XCTAssertThrowsError(try CoreAudioExactPcmPolicy.validateLayout(format(), channelLabels: [kAudioChannelLabel_Right, kAudioChannelLabel_Left]))
        XCTAssertThrowsError(try CoreAudioExactPcmPolicy.validateLayout(format(), channelLabels: nil))
        XCTAssertThrowsError(try CoreAudioExactPcmPolicy.validateLayout(format(mask: 7), channelLabels: [1, 2]))
        XCTAssertThrowsError(try CoreAudioExactPcmPolicy.validateLayout(format(channels: 6, mask: 0x3f), channelLabels: [1, 2, 3, 4, 5, 6]))
    }

    func testOnlyOneFullInterleavedBufferMatches() throws {
        let offered = try format()
        try CoreAudioExactPcmPolicy.validateBuffers(offered, channels: [2])
        let invalid: [[UInt32]] = [[], [1], [1, 1], [2, 2], [0], [6]]
        for channels in invalid {
            XCTAssertThrowsError(try CoreAudioExactPcmPolicy.validateBuffers(offered, channels: channels))
        }
    }

    func testNativeChannelBitmapUsesSDKOptionSetAndBoundedRawBufferParsing() throws {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap
        layout.mChannelBitmap = [.bit_Left, .bit_Right]
        var bytes = withUnsafeBytes(of: &layout) { Data($0) }
        XCTAssertEqual(try CoreAudioExactPcmEndpointInspector.channelLabels(propertyData: bytes),
                       [kAudioChannelLabel_Left, kAudioChannelLabel_Right])
        layout.mChannelBitmap = .bit_Center
        bytes = withUnsafeBytes(of: &layout) { Data($0) }
        XCTAssertEqual(try CoreAudioExactPcmEndpointInspector.channelLabels(propertyData: bytes), [kAudioChannelLabel_Center])
        layout.mChannelBitmap = .bit_Left
        bytes = withUnsafeBytes(of: &layout) { Data($0) }
        XCTAssertThrowsError(try CoreAudioExactPcmEndpointInspector.channelLabels(propertyData: bytes))
        let headerSize = try XCTUnwrap(MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions))
        for size in 0..<headerSize {
            XCTAssertThrowsError(try CoreAudioExactPcmEndpointInspector.channelLabels(propertyData: bytes.prefix(size)))
        }
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        layout.mChannelBitmap = []
        layout.mNumberChannelDescriptions = 1
        layout.mChannelDescriptions.mChannelLabel = kAudioChannelLabel_Center
        bytes = withUnsafeBytes(of: &layout) { Data($0) }
        XCTAssertEqual(try CoreAudioExactPcmEndpointInspector.channelLabels(propertyData: bytes), [kAudioChannelLabel_Center])
        XCTAssertThrowsError(try CoreAudioExactPcmEndpointInspector.channelLabels(propertyData: bytes.dropLast()))
    }
}
#endif
