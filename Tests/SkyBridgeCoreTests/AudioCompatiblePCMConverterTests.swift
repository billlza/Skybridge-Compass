import AVFAudio
import Foundation
import SkyBridgeAudioFile
import SkyBridgeProtocolCore
import XCTest

@MainActor
final class AudioCompatiblePCMConverterTests: XCTestCase {
    private enum Failure: Error, Equatable { case revoked, sink, allocation }

    func testSameRatePCM16IsExactWithoutDitherOrResampling() throws {
        for channels: UInt16 in [1, 2] {
            let source = (0..<(3517 * Int(channels))).map { Int16(truncatingIfNeeded: $0 * 7919) }
            let converted = try convert(bytes: pcm16(source), rate: 48000, channels: channels, frames: 3517,
                                        partitions: [1, 7, 959, 4096])
            XCTAssertEqual(converted.pcm, source)
            XCTAssertFalse(converted.receipt.dithered); XCTAssertFalse(converted.receipt.resampled)
            XCTAssertEqual(converted.receipt.clippedSamples, 0)
        }
    }

    func testFiniteCountsAndPartitionIndependenceAcrossRateExtremesAndShortTails() throws {
        for rate: UInt32 in [8000, 11025, 44100, 48000, 96000, 384000] {
            for frames in [1, 17, 441, 960, 3517] {
                for channels: UInt16 in [1, 2] {
                    let bytes = pcm16(signal(rate: rate, channels: channels, frames: frames))
                    let full = try convert(bytes: bytes, rate: rate, channels: channels, frames: frames, partitions: [4096])
                    let split = try convert(bytes: bytes, rate: rate, channels: channels, frames: frames, partitions: [1, 7, 127])
                    let expected = (UInt64(frames) * 48000 + UInt64(rate) - 1) / UInt64(rate)
                    XCTAssertEqual(full.receipt.convertedFrames, expected, "rate=\(rate), frames=\(frames)")
                    XCTAssertEqual(split.pcm, full.pcm, "rate=\(rate), frames=\(frames), channels=\(channels)")
                    XCTAssertEqual(split.receipt, full.receipt)
                }
            }
        }
    }

    func testStreamedSamplesMatchIndependentContinuousNativeReference() throws {
        for rate: UInt32 in [8000, 11025, 44100, 96000, 192000, 384000] {
            let source = signal(rate: rate, channels: 2, frames: 8517)
            let converted = try convert(bytes: pcm16(source), rate: rate, channels: 2, frames: 8517,
                                        partitions: [13, 960, 2048])
            let reference = try nativeReference(source: source, rate: rate, channels: 2)
            XCTAssertEqual(converted.pcm.count, reference.count)
            for (sample, expected) in zip(converted.pcm, reference) {
                // Reference has no dither. TPDF plus final rounding is bounded by 1.5 PCM16 LSB.
                XCTAssertLessThanOrEqual(abs(Double(sample) - Double(expected) * 32768), 1.51)
            }
        }
    }

    func testIntegerNormalizationRetainsLowBitSourceScaling() throws {
        for (encoding, validBits, raw, expected) in [
            (AudioStreamingPCMFormat.Encoding.unsigned8, UInt8(4), Data([0, 128, 240]), [Int16(-32768), 0, 28672]),
            (.unsigned8, 8, Data([0, 128, 255]), [-32768, 0, 32512]),
            (.signed16, 12, Data([0, 128, 0, 0, 0xf0, 0x7f]), [-32768, 0, 32752]),
            (.signed24, 16, Data([0, 0, 0x80, 0, 0, 0, 0, 0xff, 0x7f]), [-32768, 0, 32767]),
            (.signed32, 16, Data([0, 0, 0, 0x80, 0, 0, 0, 0, 0, 0, 0xff, 0x7f]), [-32768, 0, 32767])
        ] {
            let format = try format(encoding: encoding, bits: validBits)
            let converter = try AudioCompatiblePCMConverter(sourceFormat: format, sourceFrames: 3, ditherSeed: 1, requireAuthorization: {})
            var pcm: [Int16] = []
            try converter.append(raw) { pcm += $0 }
            let receipt = try converter.finish { pcm += $0 }
            XCTAssertEqual(pcm, expected); XCTAssertFalse(receipt.dithered); XCTAssertTrue(converter.resourcesReleased)
        }
    }

    func testWideIntegerAndFloatingInputsDitherOnceAndCountSaturation() throws {
        for (encoding, raw) in [
            (AudioStreamingPCMFormat.Encoding.signed24, integers([0x400000, 0xc00000], width: 3)),
            (.signed32, integers([0x40000000, 0xc0000000], width: 4)),
            (.signed64, integers([0x4000000000000000, 0xc000000000000000], width: 8)),
            (.float32, integers([UInt64(Float(0.5).bitPattern), UInt64(Float(-0.5).bitPattern)], width: 4)),
            (.float64, integers([Double(0.5).bitPattern, Double(-0.5).bitPattern], width: 8))
        ] {
            let converter = try AudioCompatiblePCMConverter(sourceFormat: format(encoding: encoding, bits: encoding.containerBits),
                sourceFrames: 2, ditherSeed: 42, requireAuthorization: {})
            var values: [Int16] = []
            try converter.append(raw) { values += $0 }
            let receipt = try converter.finish { values += $0 }
            XCTAssertEqual(values.count, 2); XCTAssertTrue(receipt.dithered)
            XCTAssertLessThanOrEqual(abs(Int(values[0]) - 16384), 1)
            XCTAssertLessThanOrEqual(abs(Int(values[1]) + 16384), 1)
            XCTAssertEqual(receipt.clippedSamples, 0)
        }
        let converter = try AudioCompatiblePCMConverter(sourceFormat: format(encoding: .float64, bits: 64),
            sourceFrames: 2, ditherSeed: 1, requireAuthorization: {})
        var values: [Int16] = []
        try converter.append(integers([Double(2).bitPattern, Double(-2).bitPattern], width: 8)) { values += $0 }
        let receipt = try converter.finish { values += $0 }
        XCTAssertEqual(values, [32767, -32768]); XCTAssertEqual(receipt.clippedSamples, 2)
    }

    func testMalformedSampleRejectsWholeBlockAndFailureRemainsTerminal() throws {
        for (encoding, bits, bytes, expected) in [
            (AudioStreamingPCMFormat.Encoding.float32, UInt8(32), integers([0, UInt64(Float.nan.bitPattern)], width: 4), AudioCompatiblePCMConversionError.nonFiniteSample),
            (.float64, 64, integers([0, Double.infinity.bitPattern], width: 8), .nonFiniteSample),
            (.signed24, 20, Data([0, 0, 0, 1, 0, 0]), .nonzeroPadding)
        ] {
            let converter = try AudioCompatiblePCMConverter(sourceFormat: format(encoding: encoding, bits: bits), sourceFrames: 2, requireAuthorization: {})
            XCTAssertThrowsError(try converter.append(bytes) { _ in XCTFail("Malformed block emitted PCM") }) {
                XCTAssertEqual($0 as? AudioCompatiblePCMConversionError, expected)
            }
            XCTAssertThrowsError(try converter.finish { _ in XCTFail("Failed source completed") }) {
                XCTAssertEqual($0 as? AudioCompatiblePCMConversionError, expected)
            }
            XCTAssertTrue(converter.resourcesReleased)
        }
    }

    func testUnsupportedRateLayoutAndDurationAreRejected() throws {
        for candidate in [try format(rate: 7999), try format(rate: 384001),
                          try format(channels: 6, mask: 63), try format(mask: nil), try format(mask: 0)] {
            XCTAssertThrowsError(try AudioCompatiblePCMConverter(sourceFormat: candidate, sourceFrames: 1, requireAuthorization: {})) {
                XCTAssertEqual($0 as? AudioCompatiblePCMConversionError, .invalidFormat)
            }
        }
        for frames: UInt64 in [0, 48000 * 14400 + 1, UInt64.max] {
            XCTAssertThrowsError(try AudioCompatiblePCMConverter(sourceFormat: format(), sourceFrames: frames, requireAuthorization: {})) {
                XCTAssertEqual($0 as? AudioCompatiblePCMConversionError, .invalidFrameCount)
            }
        }
    }

    func testEarlyEOFAndOverrunAreStickyFailures() throws {
        for overrun in [false, true] {
            let converter = try AudioCompatiblePCMConverter(sourceFormat: format(), sourceFrames: 2, requireAuthorization: {})
            let expected: AudioCompatiblePCMConversionError = overrun ? .sourceOverrun : .incompleteSource
            if overrun {
                XCTAssertThrowsError(try converter.append(pcm16([0, 0, 0])) { _ in XCTFail("Overrun emitted PCM") }) {
                    XCTAssertEqual($0 as? AudioCompatiblePCMConversionError, expected)
                }
            }
            XCTAssertThrowsError(try converter.finish { _ in XCTFail("Incomplete input completed") }) {
                XCTAssertEqual($0 as? AudioCompatiblePCMConversionError, expected)
            }
            XCTAssertThrowsError(try converter.append(pcm16([0])) { _ in XCTFail("Failed source resumed") }) {
                XCTAssertEqual($0 as? AudioCompatiblePCMConversionError, expected)
            }
            XCTAssertTrue(converter.resourcesReleased)
        }
    }

    func testRevocationSinkFailureAndCallbackReentryStopDelivery() throws {
        var allowed = true
        let converter = try AudioCompatiblePCMConverter(sourceFormat: format(rate: 44100), sourceFrames: 4096,
            requireAuthorization: { if !allowed { throw Failure.revoked } })
        allowed = false
        XCTAssertThrowsError(try converter.append(pcm16([1])) { _ in XCTFail("Revoked source emitted") }) {
            XCTAssertEqual($0 as? Failure, .revoked)
        }
        allowed = true
        XCTAssertThrowsError(try converter.append(pcm16([1])) { _ in XCTFail("Revoked source resumed") }) {
            XCTAssertEqual($0 as? Failure, .revoked)
        }
        XCTAssertTrue(converter.resourcesReleased)
        for reentry in [false, true] {
            let value = try AudioCompatiblePCMConverter(sourceFormat: format(), sourceFrames: 2, requireAuthorization: {})
            XCTAssertThrowsError(try value.append(pcm16([1])) { _ in
                if reentry { XCTAssertThrowsError(try value.append(pcm16([2])) { _ in XCTFail("Reentry emitted") }) }
                else { throw Failure.sink }
            }) { error in
                if reentry { XCTAssertEqual(error as? AudioCompatiblePCMConversionError, .invalidState) }
                else { XCTAssertEqual(error as? Failure, .sink) }
            }
            XCTAssertTrue(value.resourcesReleased)
        }
    }

    func testCancelInsideAuthorizationDefersNativeReleaseAndEmitsNothing() throws {
        var converter: AudioCompatiblePCMConverter?
        let value = try AudioCompatiblePCMConverter(sourceFormat: format(rate: 44100), sourceFrames: 2,
            requireAuthorization: { converter?.cancel() })
        converter = value
        XCTAssertThrowsError(try value.append(pcm16([1, 2])) { _ in XCTFail("Cancelled native owner emitted") })
        XCTAssertEqual(value.state, .cancelled); XCTAssertTrue(value.resourcesReleased)
        converter = nil
    }

    func testDownsamplingRejectsAboveNyquistToneAndPreservesChannelIsolation() throws {
        func tone(_ frequency: Double) -> [Int16] {
            (0..<96000).flatMap { frame in
                [Int16((sin(Double(frame) * 2 * .pi * frequency / 96000) * 12000).rounded()), 0]
            }
        }
        func levels(_ samples: [Int16]) -> (left: Double, right: Double) {
            var left = 0.0, right = 0.0
            let frames = samples.count / 2
            for frame in 1024..<(frames - 1024) {
                left += pow(Double(samples[frame * 2]), 2)
                right += pow(Double(samples[frame * 2 + 1]), 2)
            }
            return (sqrt(left / Double(frames - 2048)), sqrt(right / Double(frames - 2048)))
        }
        let pass = try convert(bytes: pcm16(tone(1000)), rate: 96000, channels: 2, frames: 96000, partitions: [4096, 960])
        let stop = try convert(bytes: pcm16(tone(40000)), rate: 96000, channels: 2, frames: 96000, partitions: [4096, 960])
        let inBand = levels(pass.pcm), aliased = levels(stop.pcm)
        XCTAssertEqual(inBand.left, 12000 / sqrt(2), accuracy: 20)
        XCTAssertLessThan(inBand.right, 1.0)
        // A broad regression floor, not a universal quality specification or listening result.
        XCTAssertLessThan(aliased.left, inBand.left / 1000, "Above-Nyquist tone aliases by more than -60 dB")
        XCTAssertEqual(pass.receipt.clippedSamples, 0); XCTAssertEqual(stop.receipt.clippedSamples, 0)
    }

    func testResampledImpulseKeepsItsTimelineIncludingTheLastSourceSample() throws {
        for rate: UInt32 in [8000, 44100, 96000, 384000] {
            let frames = Int(rate / 10)
            let positions = rate == 8000 ? [Int(rate / 100), frames - 1] : [Int(rate / 100)]
            for index in positions {
                var source = [Int16](repeating: 0, count: frames); source[index] = 16000
                let result = try convert(bytes: pcm16(source), rate: rate, channels: 1, frames: frames, partitions: [127, 4096])
                let peak = try XCTUnwrap(result.pcm.enumerated().max { abs(Int($0.element)) < abs(Int($1.element)) })
                let expected = Int((Double(index) * 48000 / Double(rate)).rounded())
                XCTAssertLessThanOrEqual(abs(peak.offset - expected), 1, "rate=\(rate), index=\(index)")
            }
        }
    }

    func testTPDFOnSilentWidePCMIsZeroMeanAndNotSilentlyDisabled() throws {
        let converter = try AudioCompatiblePCMConverter(sourceFormat: format(encoding: .signed24, bits: 24),
            sourceFrames: 4096, ditherSeed: 812, requireAuthorization: {})
        var values: [Int16] = []
        try converter.append(Data(repeating: 0, count: 4096 * 3)) { values += $0 }
        _ = try converter.finish { values += $0 }
        let mean = values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
        let power = values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(values.count)
        XCTAssertLessThan(abs(mean), 0.04)
        XCTAssertGreaterThan(power, 0.20); XCTAssertLessThan(power, 0.30)
        XCTAssertTrue(values.allSatisfy { (-1...1).contains($0) })
    }

    func testRevocationAfterFirstNativeDeliveryPreventsAllRemainingBlocks() throws {
        var allowed = true
        let converter = try AudioCompatiblePCMConverter(sourceFormat: format(rate: 8000), sourceFrames: 4096,
            requireAuthorization: { if !allowed { throw Failure.revoked } })
        var deliveries = 0
        XCTAssertThrowsError(try converter.append(pcm16([Int16](repeating: 100, count: 4096))) { _ in
            deliveries += 1; allowed = false
        }) { XCTAssertEqual($0 as? Failure, .revoked) }
        XCTAssertEqual(deliveries, 1); XCTAssertTrue(converter.resourcesReleased)
    }

    func testCancellationInsideFinishAuthorizationCannotProduceCompletion() async throws {
        let task = Task { @MainActor in
            var cancel = false
            let converter = try AudioCompatiblePCMConverter(sourceFormat: format(), sourceFrames: 1,
                requireAuthorization: { if cancel { withUnsafeCurrentTask { $0?.cancel() } } })
            try converter.append(pcm16([0])) { _ in }
            cancel = true
            XCTAssertThrowsError(try converter.finish { _ in XCTFail("Cancelled source emitted") }) {
                XCTAssertTrue($0 is CancellationError)
            }
            XCTAssertEqual(converter.state, .failed); XCTAssertTrue(converter.resourcesReleased)
        }
        try await task.value
    }

    private func format(rate: UInt32 = 48000, channels: UInt16 = 1,
                        encoding: AudioStreamingPCMFormat.Encoding = .signed16, bits: UInt8 = 16,
                        mask: UInt32? = 4) throws -> AudioStreamingPCMFormat {
        try AudioStreamingPCMFormat(sampleRate: rate, channels: channels, encoding: encoding, declaredValidBits: bits, waveChannelMask: mask)
    }

    private func integers(_ values: [UInt64], width: Int) -> Data {
        Data(values.flatMap { value in (0..<width).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } })
    }
    private func pcm16(_ values: [Int16]) -> Data { integers(values.map { UInt64(UInt16(bitPattern: $0)) }, width: 2) }
    private func signal(rate: UInt32, channels: UInt16, frames: Int) -> [Int16] {
        (0..<frames).flatMap { frame -> [Int16] in
            let sample = Int16((sin(Double(frame) * 2 * .pi * 997 / Double(rate) + 0.3) * 12000).rounded())
            return channels == 1 ? [sample] : [sample, -sample]
        }
    }
    private func convert(bytes: Data, rate: UInt32, channels: UInt16, frames: Int, partitions: [Int]) throws
        -> (pcm: [Int16], receipt: AudioCompatiblePCMCompletion) {
        let converter = try AudioCompatiblePCMConverter(sourceFormat: format(rate: rate, channels: channels, mask: channels == 1 ? 4 : 3),
            sourceFrames: UInt64(frames), ditherSeed: 731, requireAuthorization: {})
        var output: [Int16] = [], offset = 0, turn = 0
        let frameBytes = Int(channels) * 2
        while offset < frames {
            let count = min(partitions[turn % partitions.count], frames - offset)
            try converter.append(bytes.subdata(in: (offset * frameBytes)..<((offset + count) * frameBytes))) { samples in
                XCTAssertLessThanOrEqual(samples.count, 4096 * Int(channels)); output += samples
            }
            offset += count; turn += 1
        }
        let receipt = try converter.finish { output += $0 }
        XCTAssertEqual(converter.state, .completed); XCTAssertTrue(converter.resourcesReleased)
        XCTAssertLessThanOrEqual(converter.tailInputFrames, UInt64(rate))
        XCTAssertEqual(output.count, Int(receipt.convertedFrames) * Int(channels))
        return (output, receipt)
    }

    private func nativeReference(source: [Int16], rate: UInt32, channels: UInt16) throws -> [Float] {
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: UInt32(channels), interleaved: true),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: UInt32(channels), interleaved: true),
              let native = AVAudioConverter(from: inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 701),
              let inputData = input.floatChannelData?[0], let outputData = output.floatChannelData?[0] else { throw Failure.allocation }
        native.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        native.sampleRateConverterQuality = Int(AVAudioQuality.max.rawValue); native.primeMethod = .normal
        // Continuous native input includes a full second of post-source silence before EOF.
        // This reference never uses the product's padding loop or noDataNow. Only the original
        // declared duration is compared: iPad native EOF was observed to omit its filter tail.
        let total = source.count / Int(channels) + Int(rate)
        var offset = 0, result: [Float] = []
        for _ in 0..<1000 {
            var error: NSError?
            let status = native.convert(to: output, error: &error) { wanted, state in
                if offset == total { state.pointee = .endOfStream; return nil }
                let count = min(Int(wanted), total - offset, 4096)
                for i in 0..<(count * Int(channels)) {
                    let index = offset * Int(channels) + i
                    inputData[i] = index < source.count ? Float(source[index]) / 32768 : 0
                }
                input.frameLength = UInt32(count); offset += count; state.pointee = .haveData; return input
            }
            if let error { throw error }
            result += Array(UnsafeBufferPointer(start: outputData, count: Int(output.frameLength) * Int(channels)))
            if status == .endOfStream {
                let count = ((source.count / Int(channels)) * 48000 + Int(rate) - 1) / Int(rate) * Int(channels)
                XCTAssertGreaterThanOrEqual(result.count, count)
                return Array(result.prefix(count))
            }
            guard status == .haveData else { throw Failure.allocation }
        }
        throw Failure.allocation
    }
}
